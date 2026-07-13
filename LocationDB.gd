extends RefCounted
## 地点注册表（M7；DB 范式：preload + static，无 class_name）：读 res://data/locations.json，类型/服务定义单一源。
## 三层分工（瓦片=地点 🔒 2026-07-13）：类型与服务定义＝本文件的数据（数据/代码分离）；
## 地点**存在性**＝瓦片（terrains.json 条目 location_type，画上即是）；地图 locations 字段降级为**注记层**
## （按格挂 id/label/battle_map/dialogue_id——身份与内容；type 由瓦片推导不再手选；MapIO 照旧透传）；
## 运行时状态（据点上次肃清时刻）＝WorldState.location_cleared_at（随档，按地点 id 记账）。
## 据点刷新 🔒 语义＝惰性判定（site_ready 读时算），不占 WorldClock 每小时调度——无状态可漏算。

const JsonRegistry := preload("res://JsonRegistry.gd")
const TerrainDB := preload("res://TerrainDB.gd")
const PATH := "res://data/locations.json"

static var _types := []          # 有序类型定义
static var _type_by_id := {}     # type_id -> entry
static var _services := []       # 有序服务定义
static var _service_by_id := {}  # service_id -> entry
static var _loaded := false
static var _path_override := ""   # 测试注入缝

static func _path() -> String:
	return _path_override if _path_override != "" else PATH

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	var rt = JsonRegistry.load_indexed(_path(), "types")
	_types = rt["list"]
	_type_by_id = rt["by_id"]
	var rs = JsonRegistry.load_indexed(_path(), "services")
	_services = rs["list"]
	_service_by_id = rs["by_id"]

static func reload_data() -> void:
	_loaded = false
	_ensure()

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

# ============ 瓦片=地点派生（🔒 2026-07-13；Overworld/MapEditor/lint 三方共用的单一实现）============

# tiles（行主序 [[{terrain,variant}…]…]）× annotations（地图 locations 注记数组）→
#   {list:[{id,type,label,col,row,battle_map?,dialogue_id?}…] 行主序, by_cell:{Vector2i:loc}, orphans:[注记…]}
# 无注记的地点格自动兜底：id="<type>_c<col>_r<row>"（格坐标稳定可入存档/引用）、label=类型名；
# site 型（lair/ruin）缺 battle_map 给默认可打图（原编辑器放置默认，语义搬到派生）。
# 注记落在非地点瓦片格＝孤儿（改图后没同步的死引用），进 orphans 由调用方告警/lint FAIL。
# 同格多条注记后者胜（与旧 _loc_index_at 倒序检索同序）；注记里残留的 type 字段一律忽略（瓦片说了算）。
static func derive_locations(tiles: Array, annotations: Array) -> Dictionary:
	var ann_by_cell := {}
	for a in annotations:
		if typeof(a) == TYPE_DICTIONARY:
			ann_by_cell[Vector2i(int(a.get("col", -1)), int(a.get("row", -1)))] = a
	var list := []
	var by_cell := {}
	for r in tiles.size():
		var row = tiles[r]
		if typeof(row) != TYPE_ARRAY:
			continue
		for c in (row as Array).size():
			var lt := TerrainDB.location_type_of(row[c])
			if lt == "":
				continue
			var cell := Vector2i(c, r)
			var ann: Dictionary = ann_by_cell.get(cell, {})
			ann_by_cell.erase(cell)
			var loc := {
				"id": str(ann["id"]) if str(ann.get("id", "")) != "" else "%s_c%d_r%d" % [lt, c, r],
				"type": lt,
				"label": str(ann["label"]) if str(ann.get("label", "")) != "" else type_label(lt),
				"col": c, "row": r,
			}
			if str(ann.get("battle_map", "")) != "":
				loc["battle_map"] = str(ann["battle_map"])
			elif is_site(lt):
				loc["battle_map"] = "res://maps/sandbox.json"
			if str(ann.get("dialogue_id", "")) != "":
				loc["dialogue_id"] = str(ann["dialogue_id"])
			list.append(loc)
			by_cell[cell] = loc
	return {"list": list, "by_cell": by_cell, "orphans": ann_by_cell.values()}

# ============ 据点刷新（惰性判定；loc=派生地点 {id,type,…}，状态在 ws.location_cleared_at）============

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
