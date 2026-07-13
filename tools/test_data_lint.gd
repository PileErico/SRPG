extends SceneTree
## 数据 lint（模块_技能_设计.md §10 全程护栏#1，阶段1 起）——机械执法数据规范、防回流。
## 当前覆盖（随阶段推进增补 bas→skills / 树/原型引用 / 双键期收口等）：
##  1) 禁键 element：data/*.json 任意层出现即 FAIL——守 damage_kind 正字（§7.2）不回流。
##  2) effects.json 形状：id 非空且唯一 / kind∈{buff,debuff} / tags 是数组 / duration_model∈{fixed,resist} /
##     stackable 为 bool / dot_pct_max_hp、hot_flat 数值。
##  3) 效果引用完整性：weapons/skills 里 inflict/apply 的 {effect:<id>} 引用必须在 EffectDB 存在
##     （当前无引用形态即空过；阶段1.2b bleed 迁引用后此项开始守护悬空 id）。
##  4) 强韧不入物品（🔒 模块_属性成长_设计.md §5）：weapons/armor/accessories 的 mods 出现 will_fort/body_fort 即 FAIL。
##  5) damage_kind 白名单：data/ 任意处的 damage_kind 值必须 ∈ {physical,fire,ice,thunder,holy}
##     （未知种别在 CombatResolver 会告警回退物理轨；数据侧在此挡住）。
##  6) tag 引用完整性（🔒 tag 统一词表）：data/*.json 与 terrains.json 里任意 "tags" 数组的字符串
##     必须 ∈ tags.json——防「用了没注册」的词表漂移（曾漏 cold/road/wall）。
##  7) skills.json 阶段2 形状闸门（🔒 设计 §10 护栏#1 机械执法）：target 三旗不得全 false / seq 撞格 /
##     per_level 长度==max_level / costs.ap 与顶层 ap_cost 禁双写 / 阶段6 前 hits.size()>1 或 riders 出现即 FAIL
##     （防「可编不可跑」内容入库）。WS 形约束已随决策27 关系制移到规则8 引用处执法。
##  8) weapons.json 武器技能引用（🔒 决策25/26/27）：bws/bas → 技能存在+WS 形（is_ws_shaped：含 attack 块+
##     冷却0+无级+无手门槛——攻击路径不结算冷却/次数/等级）；ews → 技能存在+主动+含 ≥1 可跑块（纯 attack＝阶段6），
##     requires 的 prof/value 合法。BWS/EWS＝武器引用方式非技能种类：同一技能可既是 A 的 BWS 又是 B 的 EWS。
##     内联 attack 残留＝FAIL（2026-07-12 技改 §4-11 收口：weapons.json 已全量迁引用制）。
##  9) 原型引用完整性（技改 §4-1）：unit_prototypes 的 equip/bag→ItemDB、trait→TraitDB、race→RaceDB、
##     profs.known/slots/xp→ProfDB、skills→SkillDB——改 id 即静默断链，逐类存在性校验。
## 10) 事件/对话/地图引用（技改 §4-2/§4-6，EventEngine.ACTIONS 注册表驱动）：events.json 与 maps/*.json 触发器的
##     do[] 动作——action id 已注册 + proto_id/faction(_id)/dialogue_id/item_id/map/weather 按键查对应 DB；
##     dialogues.json 节点 next/choices.next 指向存在节点、choices.rep 派系已登记；effects.json on_expire_apply→EffectDB；
##     maps 地点（瓦片=地点 🔒）：overworld 图派生校验（注记无孤儿/同格唯一/id 全图唯一/battle_map 存在）、
##     world_units.json battle_map 文件存在。
##     maps/*.json 同时纳入规则 1/5/6 扫描集（禁键/damage_kind/tags）。
## 11) 战中快照白名单（技改 §1-3 lint 化）：Unit 脚本字段 vs unit_to_battle_snapshot 键集 diff——
##     新运行态字段忘扩白名单＝suspend 静默丢数据；瞬态豁免表（faction 视图/last_hit_by 另存/combat_ctx 瞬态）。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_data_lint.gd（退出码 0=PASS）

const EffectDB := preload("res://EffectDB.gd")
const TagDB := preload("res://TagDB.gd")
const SkillDB := preload("res://SkillDB.gd")
const StatMeta := preload("res://StatMeta.gd")
const CombatResolver := preload("res://CombatResolver.gd")
const ProfDB := preload("res://ProfDB.gd")   # 规则8：EWS requires.prof 引用完整性（决策26）
const ItemDB := preload("res://ItemDB.gd")           # 规则4 文件清单单一源 + 规则9/10 物品引用
const TraitDB := preload("res://TraitDB.gd")         # 规则9
const RaceDB := preload("res://RaceDB.gd")           # 规则9
const FactionDB := preload("res://FactionDB.gd")     # 规则10
const DialogueDB := preload("res://DialogueDB.gd")   # 规则10
const EnvDB := preload("res://EnvDB.gd")             # 规则10（weather 引用）
const EventEngine := preload("res://EventEngine.gd") # 规则10（ACTIONS 注册表驱动）
const LocationDB := preload("res://LocationDB.gd")   # 规则10（地图地点类型）
const UnitFactory := preload("res://UnitFactory.gd") # 规则10（proto 引用）+ 规则11（快照白名单）
const Unit := preload("res://Unit.gd")               # 规则11

var _fail := 0
func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _read_json(path: String):
	if not FileAccess.file_exists(path):
		return null
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	return data

# 列 res://data 下所有 *.json 的 res:// 路径
func _data_files() -> Array:
	return _json_files_in("res://data", false)

# 列目录下所有 *.json（可递归——maps/ 有 overworld/ 子目录）
func _json_files_in(root: String, recursive := true) -> Array:
	var out := []
	var dir = DirAccess.open(root)
	if dir == null:
		return out
	dir.list_dir_begin()
	var fn = dir.get_next()
	while fn != "":
		if dir.current_is_dir():
			if recursive and not fn.begins_with("."):
				out.append_array(_json_files_in(root + "/" + fn, true))
		elif fn.ends_with(".json"):
			out.append(root + "/" + fn)
		fn = dir.get_next()
	dir.list_dir_end()
	return out

# 递归找某 key 出现处，命中路径 append 进 hits
func _find_key(v, key: String, path: String, hits: Array) -> void:
	match typeof(v):
		TYPE_DICTIONARY:
			for k in v:
				var kp := path + "/" + str(k)
				if str(k) == key:
					hits.append(kp)
				_find_key(v[k], key, kp, hits)
		TYPE_ARRAY:
			for i in (v as Array).size():
				_find_key(v[i], key, path + "[" + str(i) + "]", hits)

# 递归找 mods 条目 {stat: <key>}（形状=修正对象），命中处 append 进 hits
func _find_stat_refs(v, key: String, path: String, hits: Array) -> void:
	match typeof(v):
		TYPE_DICTIONARY:
			if str(v.get("stat", "")) == key:
				hits.append(path + ":" + key)
			for k in v:
				_find_stat_refs(v[k], key, path, hits)
		TYPE_ARRAY:
			for e in v:
				_find_stat_refs(e, key, path, hits)

# 递归收集某 key 的「白名单外取值」
func _collect_bad_values(v, key: String, allow: Array, bad: Array) -> void:
	match typeof(v):
		TYPE_DICTIONARY:
			for k in v:
				if str(k) == key and typeof(v[k]) == TYPE_STRING and not allow.has(str(v[k])):
					bad.append(str(v[k]))
				_collect_bad_values(v[k], key, allow, bad)
		TYPE_ARRAY:
			for e in v:
				_collect_bad_values(e, key, allow, bad)

# 递归收集所有「inflict / apply_effect 引用的 effect id」：dict 里 key=="effect" 的字符串值
func _collect_effect_refs(v, refs: Array) -> void:
	match typeof(v):
		TYPE_DICTIONARY:
			for k in v:
				if str(k) == "effect" and typeof(v[k]) == TYPE_STRING and str(v[k]) != "":
					refs.append(str(v[k]))
				_collect_effect_refs(v[k], refs)
		TYPE_ARRAY:
			for e in v:
				_collect_effect_refs(e, refs)

# 递归收集某 key 下的数组值（如 per_level/hits——校验长度/条数）
func _collect_key_arrays(v, key: String, out: Array) -> void:
	match typeof(v):
		TYPE_DICTIONARY:
			for k in v:
				if str(k) == key and typeof(v[k]) == TYPE_ARRAY:
					out.append(v[k])
				_collect_key_arrays(v[k], key, out)
		TYPE_ARRAY:
			for e in v:
				_collect_key_arrays(e, key, out)

# 递归收集某 key 的字符串值（如 bas 引用）
func _collect_key_strings(v, key: String, out: Array) -> void:
	match typeof(v):
		TYPE_DICTIONARY:
			for k in v:
				if str(k) == key and typeof(v[k]) == TYPE_STRING and str(v[k]) != "":
					out.append(str(v[k]))
				_collect_key_strings(v[k], key, out)
		TYPE_ARRAY:
			for e in v:
				_collect_key_strings(e, key, out)

# 递归收集所有 tag 承载键里的字符串成员（tag 用点；去重）。
# 键集（技改 §4-8 扩五类——曾漏 cold/road/wall 的同款漂移面）：
#   数组值＝tags/match_tags/occupant_has_tags/occupant_lacks_tags/passable_by（"all"/"none" 哨兵除外）；
#   字典键＝tag_cost。
const TAG_ARRAY_KEYS := ["tags", "match_tags", "occupant_has_tags", "occupant_lacks_tags", "passable_by"]
const TAG_SENTINELS := ["all", "none"]   # passable_by 的非 tag 哨兵值

func _collect_tag_uses(v, out: Array) -> void:
	match typeof(v):
		TYPE_DICTIONARY:
			for k in v:
				if str(k) in TAG_ARRAY_KEYS and typeof(v[k]) == TYPE_ARRAY:
					for t in v[k]:
						if typeof(t) == TYPE_STRING and str(t) != "" and not TAG_SENTINELS.has(str(t)) and not out.has(str(t)):
							out.append(str(t))
				elif str(k) == "tag_cost" and typeof(v[k]) == TYPE_DICTIONARY:
					for t in v[k]:
						if str(t) != "" and not out.has(str(t)):
							out.append(str(t))
				_collect_tag_uses(v[k], out)
		TYPE_ARRAY:
			for e in v:
				_collect_tag_uses(e, out)

func _initialize() -> void:
	print("=== 数据 lint 开始 ===")
	var files := _data_files()
	ck(not files.is_empty(), "data/ 下有 json 文件")
	var map_files := _json_files_in("res://maps")
	ck(not map_files.is_empty(), "maps/ 下有 json 文件")
	var scan_all := files + map_files   # 规则 1/5/6 扫描集（技改 §4-6：maps 纳入 lint 视野）

	# 1) 禁键 element
	for path in scan_all:
		var data = _read_json(path)
		if data == null:
			continue
		var hits := []
		_find_key(data, "element", path.get_file(), hits)
		ck(hits.is_empty(), "禁键 element 未出现于 %s（命中：%s）" % [path.get_file(), ", ".join(hits)])

	# 2) effects.json 形状
	var seen := {}
	for e in EffectDB.all().values():
		var eid := str(e.get("id", ""))
		ck(eid != "", "effect id 非空")
		ck(not seen.has(eid), "effect id 唯一（重复：%s）" % eid)
		seen[eid] = true
		ck(str(e.get("kind", "")) in ["buff", "debuff"], "%s kind∈{buff,debuff}" % eid)
		ck(typeof(e.get("tags", [])) == TYPE_ARRAY, "%s tags 是数组" % eid)
		var dm := str(e.get("duration_model", "fixed"))
		ck(dm in ["fixed", "resist"], "%s duration_model∈{fixed,resist}" % eid)
		ck(typeof(e.get("stackable", false)) == TYPE_BOOL, "%s stackable 是 bool" % eid)
		ck(typeof(e.get("dot_pct_max_hp", 0)) in [TYPE_INT, TYPE_FLOAT], "%s dot_pct_max_hp 数值" % eid)

	# 3) 效果引用完整性：weapons/skills 里 {effect:<id>} 必须存在于 EffectDB
	for path in ["res://data/weapons.json", "res://data/skills.json"]:
		var data = _read_json(path)
		if data == null:
			continue
		var refs := []
		_collect_effect_refs(data, refs)
		for rid in refs:
			ck(EffectDB.get_effect(rid) != null, "%s 引用的效果 id 存在：%s" % [path.get_file(), rid])

	# 4) 强韧不入物品（🔒 §5：防具/词条只有抗性、永不提供强韧；特性/种族不受此限）
	#    禁键清单从 StatMeta.ITEM_FORBIDDEN_STATS 单一源取（运行时护栏 ItemInstances._affix_valid 同源）；
	#    文件清单从 ItemDB.FILE_BY_KIND 单一源取（技改 §4-10：原硬编码引用不存在的 accessories.json、漏 items.json）。
	for path in ItemDB.FILE_BY_KIND.values():
		var data = _read_json(path)
		if data == null:
			continue
		var fort_hits := []
		for key in StatMeta.ITEM_FORBIDDEN_STATS:
			_find_stat_refs(data, str(key), path.get_file(), fort_hits)
		ck(fort_hits.is_empty(), "物品数据无强韧 mod（命中：%s）" % ", ".join(fort_hits))

	# 5) damage_kind 白名单（直接取 CombatResolver.RES_SUFFIX 键集单一源；未知种别=抗性旁路陷阱）
	for path in scan_all:
		var data = _read_json(path)
		if data == null:
			continue
		var bad_kinds := []
		_collect_bad_values(data, "damage_kind", CombatResolver.RES_SUFFIX.keys(), bad_kinds)
		ck(bad_kinds.is_empty(), "%s damage_kind 全在白名单（越界：%s）" % [path.get_file(), ", ".join(bad_kinds)])

	# 6) tag 引用完整性：所有 tag 承载键成员必须在 tags.json 注册（tags.json 自身除外——它是词表本体；
	#    键集扩五类见 _collect_tag_uses；maps/ 一并扫描）
	var tag_paths := scan_all.duplicate()
	tag_paths.erase("res://data/tags.json")
	tag_paths.append("res://terrains.json")
	for path in tag_paths:
		var data = _read_json(path)
		if data == null:
			continue
		var used := []
		_collect_tag_uses(data, used)
		for t in used:
			ck(TagDB.get_tag(t) != null, "%s 使用的 tag 已注册：%s" % [path.get_file(), t])

	# 7) skills.json 阶段2 形状闸门（护栏#1 机械执法）
	var sk = _read_json("res://data/skills.json")
	if typeof(sk) == TYPE_ARRAY:
		var seqs := {}
		for s in sk:
			if typeof(s) != TYPE_DICTIONARY:
				continue
			var sid := str(s.get("id", "?"))
			var costs = s.get("costs", {})
			ck(not (s.has("ap_cost") and typeof(costs) == TYPE_DICTIONARY and costs.has("ap")),
				"%s：costs.ap 与顶层 ap_cost 禁双写（双键桥在读取器，数据侧只留一个）" % sid)
			# 禁键（决策27 关系制，同 element 先例）：BWS 身份由武器引用决定，技能库不做角色声明
			ck(not s.has("usable_as_bas"), "%s：usable_as_bas 已废（决策27）——禁回流，WS 形＝is_ws_shaped 计算判定" % sid)
			var tg = s.get("target", null)
			if typeof(tg) == TYPE_DICTIONARY:
				ck(bool(tg.get("enemy", false)) or bool(tg.get("ally", false)) or bool(tg.get("self", false)),
					"%s：target 三旗不得全 false（永不可施放）" % sid)
			if s.has("seq"):
				var q := int(s["seq"])
				ck(not seqs.has(q), "%s：seq %d 与 %s 撞格" % [sid, q, str(seqs.get(q, ""))])
				seqs[q] = sid
			var pls := []
			_collect_key_arrays(s, "per_level", pls)
			for pl in pls:
				ck((pl as Array).size() == maxi(1, int(s.get("max_level", 1))),
					"%s：per_level 长度(%d)==max_level(%d)" % [sid, (pl as Array).size(), int(s.get("max_level", 1))])
			var riders := []
			_find_key(s, "riders", sid, riders)
			ck(riders.is_empty(), "%s：riders 属阶段6（护栏#1）——现禁入库" % sid)
			var hits := []
			_collect_key_arrays(s, "hits", hits)
			for h in hits:
				ck((h as Array).size() <= 1, "%s：hits>1 属阶段6（护栏#1）——现禁入库" % sid)

	# 8) weapons.json 的武器技能引用（🔒 决策25/26/27）：
	#    bws/bas（双键桥）→ 技能存在 + WS 形（约束长在引用处：没被引用的技能不受形状约束）；
	#    ews → 技能存在+主动+可跑块、requires 的 prof/value 合法；
	#    内联 attack 残留＝窗口期提示（迁移后应为 0；收口后改 FAIL）。
	var wd = _read_json("res://data/weapons.json")
	if wd != null:
		var bas_refs := []
		_collect_key_strings(wd, "bas", bas_refs)
		_collect_key_strings(wd, "bws", bas_refs)
		for b in bas_refs:
			var bdef = SkillDB.get_skill(b)
			ck(bdef != null, "weapons 引用的 BWS 技能存在：%s" % b)
			ck(bdef == null or SkillDB.is_ws_shaped(bdef),
				"%s：被引为 BWS 须 WS 形（含 attack 块·冷却0·无级·无手门槛·次数无限——攻击路径不结算冷却/次数/等级）" % b)
		var inline_left := 0
		if typeof(wd) == TYPE_ARRAY:
			for w in wd:
				if typeof(w) != TYPE_DICTIONARY:
					continue
				var wid := str(w.get("id", "?"))
				if w.has("attack") and str(w.get("bws", w.get("bas", ""))) == "":
					inline_left += 1
				for e in w.get("ews", []):
					var sid := str(e.get("skill", "")) if typeof(e) == TYPE_DICTIONARY else str(e)
					var sdef = SkillDB.get_skill(sid)
					ck(sdef != null, "%s：ews 引用的技能存在：%s" % [wid, sid])
					ck(sdef == null or bool(sdef.get("active", false)), "%s：ews「%s」须为主动技能（被动 EWS＝阶段4）" % [wid, sid])
					ck(sdef == null or SkillDB.has_runnable_block(sdef),
						"%s：ews「%s」须含 ≥1 可跑块（%s）——纯 attack 块经能力路径拒发（attack 类 EWS＝阶段6）" % [wid, sid, "/".join(SkillDB.RUNNABLE_KINDS)])
					if typeof(e) == TYPE_DICTIONARY:
						for r in e.get("requires", []):
							if typeof(r) != TYPE_DICTIONARY:
								ck(false, "%s：ews「%s」requires 条目须为对象 {prof,value}" % [wid, sid])
								continue
							var pid := str(r.get("prof", ""))
							ck(not ProfDB.get_prof(pid).is_empty(), "%s：ews「%s」条件域存在于 ProfDB：%s" % [wid, sid, pid])
							ck(int(r.get("value", -1)) >= 0, "%s：ews「%s」条件阈值须 ≥0（裸数值，决策26）" % [wid, sid])
		ck(inline_left == 0, "内联 attack 已清零（技改 §4-11 收口：%d 件武器仍无 bws 引用——决策25 引用制不回流）" % inline_left)

	# 9) 原型引用完整性（技改 §4-1：改物品/技能/种族 id 即静默断链——逐类存在性校验）
	var protos = _read_json("res://data/unit_prototypes.json")
	if typeof(protos) == TYPE_ARRAY:
		for p in protos:
			if typeof(p) != TYPE_DICTIONARY:
				continue
			var pid := str(p.get("id", "?"))
			for eid in p.get("equip", []):
				ck(ItemDB.get_item(str(eid)) != null, "原型 %s：equip 引用的物品存在：%s" % [pid, eid])
			for bid in p.get("bag", []):
				ck(ItemDB.get_item(str(bid)) != null, "原型 %s：bag 引用的物品存在：%s" % [pid, bid])
			var ptr := str(p.get("trait", ""))
			ck(ptr == "" or TraitDB.get_trait(ptr) != null, "原型 %s：trait 存在：%s" % [pid, ptr])
			var prc := str(p.get("race", ""))
			ck(prc == "" or not RaceDB.get_race(prc).is_empty(), "原型 %s：race 存在：%s" % [pid, prc])
			var psk = p.get("skills", [])
			var skill_ids := (psk.keys() if typeof(psk) == TYPE_DICTIONARY else psk) as Array
			for sid in skill_ids:
				ck(SkillDB.get_skill(str(sid)) != null, "原型 %s：skills 引用的技能存在：%s" % [pid, sid])
			var ppf = p.get("profs", {})
			if typeof(ppf) == TYPE_DICTIONARY:
				var prof_ids := []
				prof_ids.append_array(ppf.get("known", []))
				prof_ids.append_array(ppf.get("slots", []))
				prof_ids.append_array((ppf.get("xp", {}) as Dictionary).keys())
				for fid in prof_ids:
					ck(not ProfDB.get_prof(str(fid)).is_empty(), "原型 %s：profs 引用的技艺域存在：%s" % [pid, fid])

	# 10) 事件/对话/地图引用完整性（技改 §4-2/§4-6：EventEngine.ACTIONS 注册表驱动，一份验证三处用）
	# 10a) do[] 动作：events.json 全池 + 每张 maps/*.json 的 triggers
	var ref_keys := ["proto_id", "faction", "faction_id", "dialogue_id", "item_id", "map", "weather"]
	var ev_data = _read_json("res://data/events.json")
	var do_sources := []   # [来源标注, do 数组]
	if typeof(ev_data) == TYPE_DICTIONARY:
		for ev in ev_data.get("events", []):
			if typeof(ev) == TYPE_DICTIONARY:
				do_sources.append(["events.json:%s" % str(ev.get("id", "?")), ev.get("do", [])])
	for mp in map_files:
		var md = _read_json(mp)
		if typeof(md) != TYPE_DICTIONARY:
			continue
		for tg2 in md.get("triggers", []):
			if typeof(tg2) == TYPE_DICTIONARY:
				do_sources.append(["%s:%s" % [mp.get_file(), str(tg2.get("id", "?"))], tg2.get("do", [])])
		# 地图地点（瓦片=地点 🔒）：overworld 图走派生校验——注记无孤儿（落在非地点瓦片＝改图后死引用）、
		# 同格无重复注记、派生 id 全图唯一、battle_map 文件存在；非 overworld 图 locations＝透传数据只查 battle_map
		if str(md.get("map_type", "battle")) == "overworld":
			var dv := LocationDB.derive_locations(md.get("tiles", []), md.get("locations", []))
			for orph in dv["orphans"]:
				ck(false, "%s：注记「%s」落在非地点瓦片 (%d,%d)——画地点瓦片或删注记" % [mp.get_file(), str(orph.get("id", orph.get("label", "?"))), int(orph.get("col", -1)), int(orph.get("row", -1))])
			var loc_cells := {}
			for a2 in md.get("locations", []):
				if typeof(a2) != TYPE_DICTIONARY:
					continue
				var ckey := "%d,%d" % [int(a2.get("col", -1)), int(a2.get("row", -1))]
				ck(not loc_cells.has(ckey), "%s：格 (%s) 只有一条注记（后者会静默压掉前者）" % [mp.get_file(), ckey])
				loc_cells[ckey] = true
			var loc_ids := {}
			for loc in dv["list"]:
				var lid := str(loc["id"])
				ck(not loc_ids.has(lid), "%s：地点 id 全图唯一：%s" % [mp.get_file(), lid])
				loc_ids[lid] = true
				var bm := str(loc.get("battle_map", ""))
				ck(bm == "" or FileAccess.file_exists(bm), "%s：地点「%s」battle_map 文件存在：%s" % [mp.get_file(), lid, bm])
		else:
			for loc in md.get("locations", []):
				if typeof(loc) == TYPE_DICTIONARY:
					var bm := str(loc.get("battle_map", ""))
					ck(bm == "" or FileAccess.file_exists(bm), "%s：地点「%s」battle_map 文件存在：%s" % [mp.get_file(), str(loc.get("id", "?")), bm])
	for src in do_sources:
		for a in (src[1] as Array):
			if typeof(a) != TYPE_DICTIONARY:
				continue
			var aid := str(a.get("action", ""))
			ck(not EventEngine.action_def(aid).is_empty(), "%s：动作已注册：%s" % [src[0], aid])
			for key in ref_keys:
				if not a.has(key):
					continue
				var v := str(a[key])
				var ok := true
				match key:
					"proto_id":
						ok = not UnitFactory.get_prototype(v).is_empty()
					"faction", "faction_id":
						ok = FactionDB.faction(v) != null
					"dialogue_id":
						ok = DialogueDB.dialogue(v) != null
					"item_id":
						ok = ItemDB.get_item(v) != null
					"map":
						ok = FileAccess.file_exists(v)
					"weather":
						ok = EnvDB.weather(v) != null
				ck(ok, "%s：%s 引用有效：「%s」" % [src[0], key, v])
	# 10b) dialogues.json：节点 next/choices.next 指向存在节点（""=收尾合法）；choices.rep 派系已登记
	for dlg in DialogueDB.all_dialogues():
		var did := str(dlg.get("id", "?"))
		var node_ids := {}
		for nd in dlg.get("nodes", []):
			if typeof(nd) == TYPE_DICTIONARY:
				node_ids[str(nd.get("id", ""))] = true
		for nd in dlg.get("nodes", []):
			if typeof(nd) != TYPE_DICTIONARY:
				continue
			var nxt := str(nd.get("next", ""))
			ck(nxt == "" or node_ids.has(nxt), "对话 %s：节点「%s」next 指向存在节点：%s" % [did, str(nd.get("id", "?")), nxt])
			for c in nd.get("choices", []):
				if typeof(c) != TYPE_DICTIONARY:
					continue
				var cn := str(c.get("next", ""))
				ck(cn == "" or node_ids.has(cn), "对话 %s：选项 next 指向存在节点：%s" % [did, cn])
				for fid2 in (c.get("rep", {}) as Dictionary):
					ck(FactionDB.faction(str(fid2)) != null, "对话 %s：选项 rep 派系已登记：%s" % [did, fid2])
	# 10c) effects.json 连锁引用：on_expire_apply → EffectDB（编辑器守卫技改 §3-1 之外的数据侧兜底）
	for e2 in EffectDB.all().values():
		var oea := str(e2.get("on_expire_apply", ""))
		ck(oea == "" or EffectDB.get_effect(oea) != null, "效果 %s：on_expire_apply 引用存在：%s" % [str(e2.get("id", "?")), oea])
	# 10d) world_units.json：battle_map 文件存在（引用型字段唯一游离在 do[] 体系外的一处）
	var wud = _read_json("res://data/world_units.json")
	if typeof(wud) == TYPE_DICTIONARY:
		for wt in wud.get("types", []):
			if typeof(wt) == TYPE_DICTIONARY:
				var wbm := str(wt.get("battle_map", ""))
				ck(wbm == "" or FileAccess.file_exists(wbm), "world_units %s：battle_map 文件存在：%s" % [str(wt.get("id", "?")), wbm])

	# 11) 战中快照白名单机械执法（技改 §1-3：新运行态字段忘扩白名单＝suspend 静默丢数据，原纯靠注释纪律）
	# 瞬态豁免表（新增豁免须在此登记并注明理由）：
	#   faction＝tags 的计算视图（快照存 tags 自动复原）；last_hit_by＝对象引用（BattleState 层按下标另存）；
	#   combat_ctx＝结算瞬态（_resolve_compute 包裹层 set/clear，跨回合无意义）。
	var snap_exempt := ["faction", "last_hit_by", "combat_ctx"]
	var snap_keys: Array = UnitFactory.unit_to_battle_snapshot(Unit.new()).keys()
	var unit_vars := []
	for prop in Unit.new().get_property_list():
		if prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			unit_vars.append(str(prop.name))
	for vn in unit_vars:
		ck(snap_keys.has(vn) or snap_exempt.has(vn),
			"Unit 字段「%s」入快照白名单或豁免表（忘扩＝suspend 静默丢数据；豁免须注明理由）" % vn)
	for kn in snap_keys:
		ck(unit_vars.has(kn), "快照键「%s」对应 Unit 字段存在（死键＝白名单腐化）" % kn)

	if _fail == 0:
		print("=== 数据 lint 全 PASS ===")
		quit(0)
	else:
		print("=== lint 失败 %d 项 ===" % _fail)
		quit(1)
