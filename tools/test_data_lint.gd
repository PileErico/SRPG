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
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_data_lint.gd（退出码 0=PASS）

const EffectDB := preload("res://EffectDB.gd")
const TagDB := preload("res://TagDB.gd")
const StatMeta := preload("res://StatMeta.gd")
const CombatResolver := preload("res://CombatResolver.gd")

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
	var out := []
	var dir = DirAccess.open("res://data")
	if dir == null:
		return out
	dir.list_dir_begin()
	var fn = dir.get_next()
	while fn != "":
		if not dir.current_is_dir() and fn.ends_with(".json"):
			out.append("res://data/" + fn)
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

# 递归收集所有 "tags" 数组里的字符串成员（tag 用点；去重）
func _collect_tag_uses(v, out: Array) -> void:
	match typeof(v):
		TYPE_DICTIONARY:
			for k in v:
				if str(k) == "tags" and typeof(v[k]) == TYPE_ARRAY:
					for t in v[k]:
						if typeof(t) == TYPE_STRING and str(t) != "" and not out.has(str(t)):
							out.append(str(t))
				_collect_tag_uses(v[k], out)
		TYPE_ARRAY:
			for e in v:
				_collect_tag_uses(e, out)

func _initialize() -> void:
	print("=== 数据 lint 开始 ===")
	var files := _data_files()
	ck(not files.is_empty(), "data/ 下有 json 文件")

	# 1) 禁键 element
	for path in files:
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
	#    禁键清单从 StatMeta.ITEM_FORBIDDEN_STATS 单一源取（运行时护栏 ItemInstances._affix_valid 同源）。
	for path in ["res://data/weapons.json", "res://data/armor.json", "res://data/accessories.json"]:
		var data = _read_json(path)
		if data == null:
			continue
		var fort_hits := []
		for key in StatMeta.ITEM_FORBIDDEN_STATS:
			_find_stat_refs(data, str(key), path.get_file(), fort_hits)
		ck(fort_hits.is_empty(), "物品数据无强韧 mod（命中：%s）" % ", ".join(fort_hits))

	# 5) damage_kind 白名单（直接取 CombatResolver.RES_SUFFIX 键集单一源；未知种别=抗性旁路陷阱）
	for path in files:
		var data = _read_json(path)
		if data == null:
			continue
		var bad_kinds := []
		_collect_bad_values(data, "damage_kind", CombatResolver.RES_SUFFIX.keys(), bad_kinds)
		ck(bad_kinds.is_empty(), "%s damage_kind 全在白名单（越界：%s）" % [path.get_file(), ", ".join(bad_kinds)])

	# 6) tag 引用完整性：所有 "tags" 数组成员必须在 tags.json 注册（tags.json 自身除外——它是词表本体）
	var tag_paths := files.duplicate()
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

	if _fail == 0:
		print("=== 数据 lint 全 PASS ===")
		quit(0)
	else:
		print("=== lint 失败 %d 项 ===" % _fail)
		quit(1)
