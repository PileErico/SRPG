extends RefCounted
## 造单位 / 序列化 / 原型·预设读写的单一入口（仿 *DB 伪单例：preload + 静态函数，不用 class_name）。
## 供 Sandbox（战斗/布置）、MapEditor（单位层深度编辑）、将来角色编辑器共用——
## 「proto 字典 ↔ 活的 Unit」往返都收在这里，任何一方都不必自己拼装。
##
## 用法：const UnitFactory := preload("res://UnitFactory.gd")
##       var u = UnitFactory.make_unit(proto, "enemy", 10, 7)   # proto → Unit
##       var proto = UnitFactory.unit_to_proto(u)               # Unit → proto

const Unit := preload("res://Unit.gd")
const ItemInstances := preload("res://ItemInstances.gd")   # 装备实例库（equipment 存 uid、proto 存模板 id，此处互转）
const StatMeta := preload("res://StatMeta.gd")             # stat 序列化白名单单一源
const RaceDB := preload("res://RaceDB.gd")                 # 种族底值注册表（属性重做 🔒：基础面板值按种族给定）

const PROTOS_PATH := "res://data/unit_prototypes.json"   # 内置原型
const PRESETS_PATH := "user://unit_presets.json"         # 用户自存预设（跨次启动保留）

# proto 字典 → 配置完毕的 Unit（种族底值/特性/装备/技能/AI 全组装，收尾 init_vitals）。
static func make_unit(proto: Dictionary, fac: String, col: int, row: int):
	var u = Unit.new(str(proto.get("name", "新兵")), fac, col, row)
	u.proto_id = str(proto.get("id", ""))   # 模板身份（图鉴/击杀统计按它归类；手捏单位=空）
	u.portrait = str(proto.get("portrait", ""))
	u.icon = str(proto.get("icon", ""))
	for t in proto.get("tags", []):
		if not u.tags.has(str(t)):
			u.tags.append(str(t))
	RaceDB.apply_to(u, str(proto.get("race", "")))   # 种族底值先落（stats 基础值+种族 tags）；下方 proto.stats 再叠差异覆盖
	if proto.get("speed", null) != null:
		u.stats["speed"] = int(proto["speed"])
	u.level = int(proto.get("level", 1))
	for _i in range(maxi(0, u.level - 1)):
		u._apply_level_growth()   # 🔒 §10.6 自动轨追溯：level>1 原型补齐种族成长（原型×等级纯函数；proto.stats 覆盖仍在下方后置生效）
	u.exp = int(proto.get("exp", 0))
	u.exp_max = int(proto.get("exp_max", u.exp_max))
	var tr := str(proto.get("trait", ""))
	if tr != "":
		u.set_trait(tr)
	for it in proto.get("equip", []):
		u.equip(str(it))
	u.ensure_natural_weapon()   # 🔒 §10.4：主手空 → 种族天生武器（拳脚）实装入位
	u.attr_picks = int(proto.get("attr_picks", 0))
	# 属性覆盖（与种族底值的差异：HP_max/atk/acc/…全部面板值均可覆盖）
	var ov = proto.get("stats", {})
	if typeof(ov) == TYPE_DICTIONARY:
		for k in ov:
			u.stats[k] = ov[k]
	# 技能：列表（各学到 1 级）或字典 {id:level}（学到该等级）
	var sk_src = proto.get("skills", [])
	if typeof(sk_src) == TYPE_DICTIONARY:
		for sid in sk_src:
			for _n in range(maxi(1, int(sk_src[sid]))):
				if u.learn_skill(str(sid)) == 0:
					break
	else:
		for sk in sk_src:
			u.learn_skill(str(sk))
	# 技艺（可选 profs 块）：{known:[...], slots:[...], xp:{id:int}}——出身自带/敌方烘焙预设（🔒 §6 烘焙不走槽位校验）
	var pf = proto.get("profs", {})
	if typeof(pf) == TYPE_DICTIONARY and not pf.is_empty():
		var pxp = pf.get("xp", {})
		if typeof(pxp) == TYPE_DICTIONARY:
			for pid in pxp:
				u.prof_xp[str(pid)] = int(pxp[pid])
		for pid in pf.get("known", []):
			if not u.prof_known.has(str(pid)):
				u.prof_known.append(str(pid))
		for pid in pf.get("slots", []):
			u.slot_prof(str(pid), true)
	# 敌方 AI 字段（玩家/友方忽略）
	u.ai_threat = bool(proto.get("ai_threat", true))
	u.ai_region = str(proto.get("ai_region", ""))
	u.ai_group = str(proto.get("ai_group", ""))
	u.init_vitals()
	u._sync_hands_to_state()   # 维持不变式：主手＝当前地/空态偏好的武器（比路兹专属；覆盖直接带 flying tag 构造等绕过 set_airborne 的路径）；无 prefer 单位 no-op
	return u

# Unit → proto 字典（可被 make_unit 复原）。阵营立场/flying/死门 不入 tags（单独存/运行时态）。
static func unit_to_proto(u) -> Dictionary:
	var keep_tags := []
	for t in u.tags:
		if t in ["player", "ally", "enemy", "neutral", "flying", "deaths_door"]:
			continue
		keep_tags.append(t)
	# equipment 存实例 uid → proto 存模板 id（定义层）。按 uid 去重（双手占两槽=同一件），
	# 两件同模板不同词条的实例在 proto 层各记一条模板 id（词条属实例态、campaign 层才保真）。
	var equip_ids := []
	var seen_uids := []
	for slot in u.equipment:
		var uid: int = int(u.equipment[slot])
		if seen_uids.has(uid):
			continue
		seen_uids.append(uid)
		var it = ItemInstances.view(uid)
		if it != null and it.get("natural", false):
			continue   # 默认型天生武器（拳脚）不入 proto——make_unit 经 ensure_natural_weapon 再造 🔒 §10.4
		var tpl := ItemInstances.tpl_id(uid)
		if tpl != "":
			equip_ids.append(tpl)
	var skill_lv := {}
	for sid in u.skills:
		skill_lv[sid] = u.skill_level(sid)
	# 技艺（有内容才写，旧档零影响）
	var profs := {}
	if not u.prof_known.is_empty():
		profs["known"] = u.prof_known.duplicate()
	if not u.prof_slots.is_empty():
		profs["slots"] = u.prof_slots.duplicate()
	if not u.prof_xp.is_empty():
		profs["xp"] = u.prof_xp.duplicate()
	# 白名单单一源＝StatMeta.SERIALIZABLE_BASE_STATS；**只写与「引擎基线+种族底值」的差异**
	# （🔒 属性重做 §3：原型 stats 只写差异——调 races.json 平衡能传导既有原型，不被全量快照冻结；对抗 review 修复）
	var ref: Dictionary = Unit.new().stats.duplicate()
	var rst = RaceDB.get_race(u.race_id).get("stats", {})
	if typeof(rst) == TYPE_DICTIONARY:
		for k in rst:
			ref[k] = rst[k]
	var stat_ov := {}
	for k in StatMeta.SERIALIZABLE_BASE_STATS:
		if u.stats.has(k) and (not ref.has(k) or float(u.stats[k]) != float(ref[k])):
			stat_ov[k] = u.stats[k]
	var proto := {
		"name": u.unit_name,
		"id": u.proto_id,
		"default_faction": u.faction,
		"portrait": u.portrait,
		"icon": u.icon,
		"tags": keep_tags,
		"race": u.race_id,
		"level": u.level,
		"exp": u.exp,
		"exp_max": u.exp_max,
		"trait": u.trait_id,
		"equip": equip_ids,
		"skills": skill_lv,
		"stats": stat_ov,
		"_preset": true,
	}
	if not profs.is_empty():
		proto["profs"] = profs
	if u.attr_picks > 0:
		proto["attr_picks"] = u.attr_picks   # 待分配加点（战后结算 🔒 §10.6；0 不写、旧档零影响）
	# 敌方 AI 警觉字段：仅对 enemy/neutral 写出（player/ally 忽略这些字段——不写省噪音）。
	# make_unit 读回时按缺省兜底（ai_threat 默认 true）；补上后 proto/preset 往返不再丢 AI 配置。
	if u.faction in ["enemy", "neutral"]:
		proto["ai_threat"] = u.ai_threat
		if u.ai_region != "":
			proto["ai_region"] = u.ai_region
		if u.ai_group != "":
			proto["ai_group"] = u.ai_group
	return proto

# ============ campaign 层（战役续存，供 WorldState 调用）============
# campaign 条目 = proto（定义/养成）⊕ 跨战运行态（uid / 当前 HP / 当前护甲）。
# 战斗内瞬态（AP/位置/buff/冷却）不入——那是战中临时存档（BattleState）的事。
static func unit_to_campaign(u) -> Dictionary:
	var equip_uids := {}   # slot -> 实例 uid（实例本体在 WorldState 的 item_instances 整库里，这里只存引用）
	for slot in u.equipment:
		equip_uids[slot] = int(u.equipment[slot])
	return {
		"uid": u.uid,
		"proto": unit_to_proto(u),
		"equip_uids": equip_uids,
		"hp": int(u.stats.get("HP", 0)),
		"armor": int(u.stats.get("armor", 0)),
		"injured_until": u.injured_until,
	}

# 读档复原：make_unit 会 init_vitals 注满 —— 之后再覆写 HP/armor（绕开注满，战损跨存档保留）。
# 装备走实例重挂（equip_uids → equip_instance，词条/耐久保真）；前提＝ItemInstances 已先于 roster 载入。
# 旧档无 equip_uids 时回退 proto.equip 模板路径（造新实例）。
static func unit_from_campaign(entry: Dictionary):
	var proto = entry.get("proto", {})
	if typeof(proto) != TYPE_DICTIONARY:
		proto = {}
	var has_inst: bool = typeof(entry.get("equip_uids", null)) == TYPE_DICTIONARY
	if has_inst:
		proto = proto.duplicate(true)
		proto.erase("equip")   # 防 make_unit 按模板另造一套新实例
	var u = make_unit(proto, str(proto.get("default_faction", "player")), -1, -1)   # col/row=-1＝待命（非战斗中）
	if has_inst:
		var done := []
		for slot in entry["equip_uids"]:
			var iuid := int(entry["equip_uids"][slot])
			if iuid > 0 and not done.has(iuid):
				done.append(iuid)
				if not u.equip_instance(iuid):
					# 实例缺失/模板被删/资格不再满足：响亮警告 + 按模板补新件兜底（能查到模板时），拒绝无声空手
					var tpl := ItemInstances.tpl_id(iuid)
					var salvaged := tpl != "" and u.equip(tpl)
					push_warning("读档重挂装备失败：unit=%s slot=%s iuid=%d tpl=%s%s" % [u.unit_name, str(slot), iuid, tpl if tpl != "" else "?", "，已按模板补新件（词条丢失）" if salvaged else "，该件丢失"])
	u.uid = int(entry.get("uid", 0))
	u.stats["HP"] = clampi(int(entry.get("hp", u.stats.get("HP", 0))), 0, int(u.effective_stat("HP_max")))
	u.stats["armor"] = clampi(int(entry.get("armor", u.stats.get("armor", 0))), 0, int(u.effective_stat("armor_max")))
	u.injured_until = int(entry.get("injured_until", 0))
	return u

# ============ battle 层（战中 suspend 快照，供 BattleState.to_dict/restore 调用）============
# 与 proto/campaign 层的区别：**全量运行态**（位置/AP/移动点/effects/modifiers/死门条/技能 cd·uses/
# ai_aggroed/tags 原样含 stance·flying·deaths_door）逐字段原样存，复原＝new 后整份覆写——
# 刻意绕开 make_unit 的重置陷阱（init_vitals 注满 / learn_skill 充能重置 / set_trait·equip 重挂修正）🔒。
# last_hit_by 是对象引用，不在此处理（BattleState 层按单位池下标另存）。
static func unit_to_battle_snapshot(u) -> Dictionary:
	return {
		"uid": u.uid, "proto_id": u.proto_id, "unit_name": u.unit_name,
		"portrait": u.portrait, "icon": u.icon, "trait_id": u.trait_id,
		"race_id": u.race_id,
		"level": u.level, "exp": u.exp, "exp_max": u.exp_max,
		"injured_until": u.injured_until,
		"col": u.col, "row": u.row,
		"tags": u.tags.duplicate(),
		"stats": u.stats.duplicate(),
		"prof_xp": u.prof_xp.duplicate(), "prof_known": u.prof_known.duplicate(), "prof_slots": u.prof_slots.duplicate(),
		"ap": u.ap, "move_points": u.move_points,
		"morale": u.morale, "attr_picks": u.attr_picks,
		"door_gauge": u.door_gauge, "door_checks": u.door_checks,
		"effects": u.effects.duplicate(true),
		"modifiers": u.modifiers.duplicate(true),   # 整份含 trait/equip 烘焙条 + buff:/env: 临时条（source 配对保真 🔒）
		"equipment": u.equipment.duplicate(),        # slot -> 实例 uid（实例本体：战役随档；沙盒 _transient 不落盘 ⚠️）
		"skills": u.skills.duplicate(true),          # 含 cd/uses 运行态
		"ai_threat": u.ai_threat, "ai_region": u.ai_region, "ai_group": u.ai_group, "ai_aggroed": u.ai_aggroed,
	}

# 快照 → Unit：new 后**全量覆写**（不跑 make_unit / init_vitals——
# stats 整份原样回写即自洽：同输入同输出，避免任何「重算基线错位」）。
# 数值经 JSON 往返变 float，语义为 int 的字段一律 int() 钳制。
static func unit_from_battle_snapshot(d: Dictionary):
	var u = Unit.new()
	u.uid = int(d.get("uid", 0))
	u.proto_id = str(d.get("proto_id", ""))
	u.unit_name = str(d.get("unit_name", "新兵"))
	u.portrait = str(d.get("portrait", ""))
	u.icon = str(d.get("icon", ""))
	u.trait_id = str(d.get("trait_id", ""))   # 直写不走 set_trait：其修正已在 modifiers 整份快照里
	u.race_id = str(d.get("race_id", ""))
	u.level = int(d.get("level", 1))
	u.exp = int(d.get("exp", 0))
	u.exp_max = int(d.get("exp_max", 100))
	u.injured_until = int(d.get("injured_until", 0))
	u.col = int(d.get("col", -1))
	u.row = int(d.get("row", -1))
	var tags := []
	for t in d.get("tags", []):
		tags.append(str(t))
	u.tags = tags   # 原样含 stance/flying/deaths_door（faction 是 tags 的视图，自动复原）
	var stats := {}
	var src = d.get("stats", {})
	if typeof(src) == TYPE_DICTIONARY:
		for k in src:
			stats[str(k)] = src[k]
	u.stats = stats
	var pxp := {}
	var pxs = d.get("prof_xp", {})
	if typeof(pxs) == TYPE_DICTIONARY:
		for k in pxs:
			pxp[str(k)] = int(pxs[k])
	u.prof_xp = pxp
	var pkn := []
	for t in d.get("prof_known", []):
		pkn.append(str(t))
	u.prof_known = pkn
	var psl := []
	for t in d.get("prof_slots", []):
		psl.append(str(t))
	u.prof_slots = psl   # 阶段补正随 modifiers 整份快照走（prof: source），不重挂——与 trait/equip 同律
	u.ap = int(d.get("ap", 0))
	u.move_points = int(d.get("move_points", 0))
	u.morale = int(d.get("morale", 25))   # 旧快照缺省＝常态 25
	u.attr_picks = int(d.get("attr_picks", 0))
	u.door_gauge = int(d.get("door_gauge", 0))
	u.door_checks = int(d.get("door_checks", 0))
	u.effects = d.get("effects", []) if typeof(d.get("effects", [])) == TYPE_ARRAY else []
	u.modifiers = d.get("modifiers", []) if typeof(d.get("modifiers", [])) == TYPE_ARRAY else []
	var equip := {}
	var esrc = d.get("equipment", {})
	if typeof(esrc) == TYPE_DICTIONARY:
		for slot in esrc:
			equip[str(slot)] = int(esrc[slot])
	u.equipment = equip
	var skills := {}
	var ssrc = d.get("skills", {})
	if typeof(ssrc) == TYPE_DICTIONARY:
		for sid in ssrc:
			var e = ssrc[sid]
			if typeof(e) == TYPE_DICTIONARY:
				skills[str(sid)] = {"level": int(e.get("level", 1)), "cd": int(e.get("cd", 0)), "uses": int(e.get("uses", 0))}
	u.skills = skills
	u.ai_threat = bool(d.get("ai_threat", true))
	u.ai_region = str(d.get("ai_region", ""))
	u.ai_group = str(d.get("ai_group", ""))
	u.ai_aggroed = bool(d.get("ai_aggroed", false))
	return u

# 读 unit_prototypes.json 的内置原型列表
static func all_prototypes() -> Array:
	var out := []
	if FileAccess.file_exists(PROTOS_PATH):
		var f := FileAccess.open(PROTOS_PATH, FileAccess.READ)
		var d = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(d) == TYPE_ARRAY:
			for e in d:
				if typeof(e) == TYPE_DICTIONARY:
					out.append(e)
	return out

# ============ 原型库写盘（角色编辑器编内置原型 res://data/unit_prototypes.json，仿 ItemDB.save_item）============
# all_prototypes 每次现读文件、无内存缓存，故写盘后无需 reload——下次读即最新（编辑器/沙盒各自 _ready 现取）。

# 按 id 取一条内置原型（找不到返回 {}）。
static func get_prototype(id: String) -> Dictionary:
	if id == "":
		return {}
	for p in all_prototypes():
		if str(p.get("id", "")) == id:
			return p
	return {}

# 保存一条原型（按 id upsert）→ 写回 unit_prototypes.json。返回是否写盘成功。
# replace_id：改 id 时传旧 id——旧条目一并移除（否则「改名」变「复制」，旧 id 残留）。
static func save_prototype(proto: Dictionary, replace_id := "") -> bool:
	var id := str(proto.get("id", ""))
	if id == "":
		return false
	var arr := all_prototypes()
	var out := []
	var replaced := false
	for e in arr:
		var eid := str(e.get("id", ""))
		if replace_id != "" and replace_id != id and eid == replace_id:
			continue   # 改 id：旧条目移除
		if eid == id:
			out.append(proto)   # upsert：同 id 覆盖
			replaced = true
		else:
			out.append(e)
	if not replaced:
		out.append(proto)
	return _write_protos(out)

# 删除一条原型（按 id）→ 写回。写盘失败＝false。
static func delete_prototype(id: String) -> bool:
	if id == "":
		return false
	var arr := all_prototypes()
	var out := arr.filter(func(e): return str(e.get("id", "")) != id)
	if out.size() == arr.size():
		return false   # 没找到＝没删
	return _write_protos(out)

# 写数组（2 空格缩进，与工程其它数据文件一致）；写前整数归一化（JSON 读回全是 float，避免 1→1.0 噪音 diff）。
static func _write_protos(arr: Array) -> bool:
	var f := FileAccess.open(PROTOS_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("UnitFactory：写入失败（%s）——文件被占用/只读？" % PROTOS_PATH)
		return false
	f.store_string(JSON.stringify(_intify(arr), "  "))
	f.close()
	return true

# 递归把「值为整数的 float」还原为 int（1.0→1；1.5 保留）——只影响落盘表示，不改语义（仿 ItemDB._intify）。
static func _intify(v):
	match typeof(v):
		TYPE_FLOAT:
			return int(v) if v == floorf(v) else v
		TYPE_ARRAY:
			var a := []
			for e in v:
				a.append(_intify(e))
			return a
		TYPE_DICTIONARY:
			var d := {}
			for k in v:
				d[k] = _intify(v[k])
			return d
	return v

static func load_presets() -> Array:
	if not FileAccess.file_exists(PRESETS_PATH):
		return []
	var f := FileAccess.open(PRESETS_PATH, FileAccess.READ)
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	return d if typeof(d) == TYPE_ARRAY else []

# 把单位存成预设（名 preset_name），写进 user://unit_presets.json（同名覆盖）
static func save_preset(u, preset_name: String) -> void:
	if u == null or preset_name.strip_edges() == "":
		return
	var proto := unit_to_proto(u)
	proto["name"] = preset_name
	var arr := load_presets()
	var replaced := false
	for i in arr.size():
		if str(arr[i].get("name", "")) == preset_name:
			arr[i] = proto
			replaced = true
			break
	if not replaced:
		arr.append(proto)
	var f := FileAccess.open(PRESETS_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(arr, "  "))
		f.close()
