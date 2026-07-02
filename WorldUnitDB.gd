extends RefCounted
## 大地图动态单位类型注册表（🟡 v1；DB 范式：preload + static，无 class_name）：读 res://data/world_units.json。
## 数据/代码分离：类型（行为/速度/派系/生成规则）＝数据；实例（谁在哪）＝WorldState.world_units（随档）；
## 移动/追击/摩擦战逻辑＝WorldSim。

const PATH := "res://data/world_units.json"

static var _types := []
static var _by_id := {}
static var _loaded := false

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	_types = []
	_by_id = {}
	if FileAccess.file_exists(PATH):
		var f = FileAccess.open(PATH, FileAccess.READ)
		var data = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(data) == TYPE_DICTIONARY:
			for e in data.get("types", []):
				if typeof(e) == TYPE_DICTIONARY and e.has("id"):
					_types.append(e)
					_by_id[str(e["id"])] = e

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
