extends RefCounted
## 大地图动态单位类型注册表（🟡 v1；DB 范式：preload + static，无 class_name）：读 res://data/world_units.json。
## 数据/代码分离：类型（行为/速度/派系/生成规则）＝数据；实例（谁在哪）＝WorldState.world_units（随档）；
## 移动/追击/摩擦战逻辑＝WorldSim。

const JsonRegistry := preload("res://JsonRegistry.gd")
const PATH := "res://data/world_units.json"

static var _types := []
static var _by_id := {}
static var _loaded := false
static var _path_override := ""   # 测试注入缝

static func _path() -> String:
	return _path_override if _path_override != "" else PATH

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	var r = JsonRegistry.load_indexed(_path(), "types")
	_types = r["list"]
	_by_id = r["by_id"]

static func reload_data() -> void:
	_loaded = false
	_ensure()

static func all_types() -> Array:
	_ensure()
	return _types

# 类型定义；未登记返回 null（档里留存的旧类型单位会被 WorldSim 跳过并警告）
static func type_def(id: String):
	_ensure()
	return _by_id.get(id)

static func label(id: String) -> String:
	var t = type_def(id)
	return str(t.get("label", id)) if t != null else id
