extends RefCounted
## 气势兑付/参数表（data/momentum.json 单一数据源；真值 docs/模块_战斗_气势.md）。
## 仿 *DB 伪单例：preload + 静态缓存；刷新叫 reload_data（DB 铁律：不叫 reload，防命中 Script.reload）。
## 用法：const MomentumDB := preload("res://MomentumDB.gd") → MomentumDB.bonus("unarmed", 3, "acc")

const PATH := "res://data/momentum.json"

static var _data := {}
static var _loaded := false
static var _path_override := ""   # 测试缝：注入临时数据文件，reload_data 后生效

static func _path() -> String:
	return _path_override if _path_override != "" else PATH


static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	_data = {}
	if not FileAccess.file_exists(_path()):
		push_warning("MomentumDB：找不到 %s——气势加成全 0" % _path())
		return
	var f := FileAccess.open(_path(), FileAccess.READ)
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(d) != TYPE_DICTIONARY:
		push_warning("MomentumDB：%s 解析失败（顶层须为字典）" % _path())
		return
	_data = d


static func reload_data() -> void:
	_loaded = false


## 兑付查询：profile 表内键按层取值（层 1..5 → 下标 0..4；层 0/无键＝0）。
## key=="speed" 走顶层全表通用数组（4/5 层 +1/+2），与 profile 无关。
static func bonus(profile: String, layer: int, key: String) -> float:
	_ensure()
	if layer <= 0:
		return 0.0
	var idx := clampi(layer, 1, 5) - 1
	if key == "speed":
		var sp = _data.get("speed", [])
		return float(sp[idx]) if typeof(sp) == TYPE_ARRAY and idx < sp.size() else 0.0
	var profs = _data.get("profiles", {})
	if typeof(profs) != TYPE_DICTIONARY:
		return 0.0
	var prof = profs.get(profile, {})
	if typeof(prof) != TYPE_DICTIONARY:
		return 0.0
	var arr = prof.get(key, null)
	if typeof(arr) != TYPE_ARRAY or idx >= arr.size():
		return 0.0
	return float(arr[idx])


static func speed_bonus(layer: int) -> float:
	return bonus("", layer, "speed")


static func unarmed_flat_coef() -> float:
	_ensure()
	return float(_data.get("unarmed_flat_per_level_layer", 0.3))


static func decay_fail_drop() -> int:
	_ensure()
	return int(_data.get("decay_fail_drop", 4))


static func decay_fail_floor() -> int:
	_ensure()
	return int(_data.get("decay_fail_floor", 19))


static func ap_chance_coef() -> float:
	_ensure()
	return float(_data.get("ap_chance_coef", 0.1))
