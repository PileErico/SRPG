extends RefCounted
## 地点注册表（M7；DB 范式：preload + static，无 class_name）：读 res://data/locations.json，类型/服务定义单一源。
## 三层分工：类型与服务定义＝本文件的数据（数据/代码分离）；地点实例（谁在哪）＝地图 locations 字段
## （与 units/triggers 同级，MapIO 透传）；运行时状态（据点上次肃清时刻）＝WorldState.location_cleared_at（随档）。
## 据点刷新 🔒 语义＝惰性判定（site_ready 读时算），不占 WorldClock 每小时调度——无状态可漏算。

const PATH := "res://data/locations.json"

static var _types := []          # 有序类型定义
static var _type_by_id := {}     # type_id -> entry
static var _services := []       # 有序服务定义
static var _service_by_id := {}  # service_id -> entry
static var _loaded := false

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	_types = []
	_type_by_id = {}
	_services = []
	_service_by_id = {}
	if FileAccess.file_exists(PATH):
		var f = FileAccess.open(PATH, FileAccess.READ)
		var data = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(data) == TYPE_DICTIONARY:
			for e in data.get("types", []):
				if typeof(e) == TYPE_DICTIONARY and e.has("id"):
					_types.append(e)
					_type_by_id[str(e["id"])] = e
			for e in data.get("services", []):
				if typeof(e) == TYPE_DICTIONARY and e.has("id"):
					_services.append(e)
					_service_by_id[str(e["id"])] = e

static func all_types() -> Array:
	_ensure()
	return _types

# 类型定义；不存在返回 null
static func type_def(id: String):
	_ensure()
	return _type_by_id.get(id)

static func type_label(id: String) -> String:
	var t = type_def(id)
	return str(t.get("label", id)) if t != null else id

static func type_color(id: String) -> Color:
	var t = type_def(id)
	return Color.html(str(t.get("color", "#CCCCCC"))) if t != null else Color(0.8, 0.8, 0.8)

# 该类型是否为可讨伐据点（遗迹/野外据点）；城市/村落＝服务型
static func is_site(type_id: String) -> bool:
	var t = type_def(type_id)
	return t != null and bool(t.get("site", false))

# 服务定义；不存在返回 null
static func service(id: String):
	_ensure()
	return _service_by_id.get(id)

# 类型的服务定义列表（按类型 services 数组序解析；未登记的服务 id 跳过并警告）
static func services_of(type_id: String) -> Array:
	var out := []
	var t = type_def(type_id)
	if t == null:
		return out
	for sid in t.get("services", []):
		var s = service(str(sid))
		if s != null:
			out.append(s)
		else:
			push_warning("LocationDB：类型「%s」引用未登记服务「%s」" % [type_id, str(sid)])
	return out

# ============ 据点刷新（惰性判定；loc=地图实例 {id,type,…}，状态在 ws.location_cleared_at）============

# 据点当前是否可挑战：从未肃清＝可；respawn_hours<=0＝一次性（肃清即永久关）；否则到点刷新
static func site_ready(loc: Dictionary, ws) -> bool:
	var t = type_def(str(loc.get("type", "")))
	if t == null or not bool(t.get("site", false)):
		return false
	var lid := str(loc.get("id", ""))
	if ws == null or not ws.location_cleared_at.has(lid):
		return true
	var rh := int(t.get("respawn_hours", 0))
	return rh > 0 and ws.clock_hours >= int(ws.location_cleared_at[lid]) + rh

# 距刷新还差几小时：>0=倒计时；0=已可挑战/从未肃清；-1=不再刷新（一次性已肃清）
static func site_respawn_in(loc: Dictionary, ws) -> int:
	if site_ready(loc, ws):
		return 0
	var t = type_def(str(loc.get("type", "")))
	if t == null:
		return -1
	var rh := int(t.get("respawn_hours", 0))
	if rh <= 0 or ws == null:
		return -1
	return maxi(0, int(ws.location_cleared_at.get(str(loc.get("id", "")), 0)) + rh - ws.clock_hours)
