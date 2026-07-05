extends SceneTree
## 数据 lint（技能与效果系统.md §10 全程护栏#1，阶段1 起）——机械执法数据规范、防回流。
## 当前覆盖（随阶段推进增补 bas→skills / 树/原型引用 / 双键期收口等）：
##  1) 禁键 element：data/*.json 任意层出现即 FAIL——守 damage_kind 正字（§7.2）不回流。
##  2) effects.json 形状：id 非空且唯一 / kind∈{buff,debuff} / tags 是数组 / duration_model∈{fixed,resist} /
##     stackable 为 bool / dot_pct_max_hp、hot_flat 数值。
##  3) 效果引用完整性：weapons/skills 里 inflict/apply 的 {effect:<id>} 引用必须在 EffectDB 存在
##     （当前无引用形态即空过；阶段1.2b bleed 迁引用后此项开始守护悬空 id）。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_data_lint.gd（退出码 0=PASS）

const EffectDB := preload("res://EffectDB.gd")

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

	if _fail == 0:
		print("=== 数据 lint 全 PASS ===")
		quit(0)
	else:
		print("=== lint 失败 %d 项 ===" % _fail)
		quit(1)
