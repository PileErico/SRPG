extends RefCounted
## 地图存档 I/O：编辑器与战斗共用的单一读 / 写入口（仿 DB：preload + 静态函数，不用 class_name）。
## 取代 MapEditor.load_from_file 与 Sandbox._load_map 各自分叉的解析逻辑——尤其统一「尺寸钳制策略」
## （旧坑：编辑器钳到 MAX、沙盒只 max(1,…) 不钳上限 → 同一张大图两边读出来尺寸不一致）。
## 用法：const MapIO := preload("res://MapIO.gd")；MapIO.read_file(path) / MapIO.write_map(...)。
##
## schema（format_version 4，向后兼容：读端全用 .get 兜底，旧 v1/v2/v3 图照常读）：
##   { format_version, grid:"hex_flat_oddq", map_type:"battle"|"overworld"（缺省 battle，旧图兼容）, width, height,
##     tiles:  [[{terrain,variant}]]  —— 行优先 [row][col]，每格只两键，其余按 terrains.json 查表,
##     regions:[{id,label,color,kind,cells:[[x,y]]}]  —— 命名区域（kind: aggro 触发区 / deploy 部署区）,
##     units:  [{proto, col, row, faction}],          —— 预置单位（proto = UnitFactory.unit_to_proto 输出）
##     triggers:[{id,label,when,do}],                 —— 关卡触发器（enter_region → show_message/spawn_unit/activate_aggro/set_weather）
##     terrain_overrides:{ "terrain/variant": {move?,effects?} },  —— 图级地形覆盖（只改本图、不动全局 terrains.json）
##     environment:{ time, weather_table:[{weather,weight,min_rounds,max_rounds}] },  —— 环境（日夜/天气，见 docs/感知系统.md）
##     locations:[{id,type,label,col,row,battle_map?,dialogue_id?}],  —— 地点实例（大地图 M7；类型定义在 data/locations.json）
##     —— 线特征（v4，大地图专属 authoring；格对=[[x1,y1],[x2,y2]] 两相邻格，边键归一走 HexGrid.edge_key）——
##     rivers: [{id,label,pairs:[格对,…]}],  —— 边线河：每格对=一条共享边上的河段；通行=硬阻断（跨该边须有桥）
##     roads:  [{id,label,pairs:[格对,…]}],  —— 道路 overlay：格心连线；跨该边成本折为 min(格成本,1)
##     bridges:[格对,…] }                    —— 桥：河边豁免点（可跨），且同享道路折扣

const FORMAT_VERSION := 4
const GRID := "hex_flat_oddq"
const MAX_W := 50
const MAX_H := 50
const DEFAULT_TERRAIN := "plain"
const DEFAULT_VARIANT := "grassland"

# 读地图文件 → 规整后的字典；失败返回 {"ok": false}。
# 成功：{ok=true, format_version, width, height, tiles(规整+钳制+逐格兜底), regions(原样透传), units(原样透传)}
# 注：regions / units 原样透传（各调用方按自己内存形再转：编辑器把 region cells 转 Vector2i 集合，沙盒直接用 [[x,y]]）。
static func read_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false}
	var text := f.get_as_text()
	f.close()
	return normalize(JSON.parse_string(text))

# 轻量探测地图类型（不规整 tiles）：读不出/无键返回 "battle"（与 normalize 缺省一致）。
# 供地图列表过滤/标注（MapSelect 沙盒列表、编辑器地图库）——避免为个标签跑全量 normalize。
static func peek_type(path: String) -> String:
	if not FileAccess.file_exists(path):
		return "battle"
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "battle"
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(data) == TYPE_DICTIONARY:
		return str(data.get("map_type", "battle"))
	return "battle"

# 把内存地图字典规整成统一形（校验 + 钳制 + tiles 逐格兜底）。失败返回 {"ok": false}。
# 供 read_file（读文件）与「编辑器一键试玩」（内存直传、免存盘）共用同一套规整逻辑。
static func normalize(data) -> Dictionary:
	if typeof(data) != TYPE_DICTIONARY:
		return {"ok": false}
	if not (data.has("width") and data.has("height") and data.has("tiles")):
		return {"ok": false}
	# 统一钳制：尺寸先钳进 [1, MAX]，再按钳后尺寸重建 tiles —— 避免 tiles 比 width/height 大、两侧读出不一致
	var w := clampi(int(data["width"]), 1, MAX_W)
	var h := clampi(int(data["height"]), 1, MAX_H)
	var regions = data.get("regions", [])
	if typeof(regions) != TYPE_ARRAY:
		regions = []
	var units = data.get("units", [])
	if typeof(units) != TYPE_ARRAY:
		units = []
	var triggers = data.get("triggers", [])
	if typeof(triggers) != TYPE_ARRAY:
		triggers = []
	var terrain_overrides = data.get("terrain_overrides", {})
	if typeof(terrain_overrides) != TYPE_DICTIONARY:
		terrain_overrides = {}
	var environment = data.get("environment", {})
	if typeof(environment) != TYPE_DICTIONARY:
		environment = {}
	var locations = _dicts_only(data.get("locations", []))   # 逐项清洗：丢弃非字典项（与 rivers/roads 对称；防手改 JSON 的 junk 项错位编辑器地点列表下标）
	return {
		"ok": true,
		"format_version": int(data.get("format_version", 0)),
		"map_type": str(data.get("map_type", "battle")),   # overworld / battle（缺省 battle：旧图全兼容）
		"width": w, "height": h,
		"tiles": _normalize_tiles(data["tiles"], w, h),
		"regions": regions,
		"units": units,
		"triggers": triggers,
		"terrain_overrides": terrain_overrides,   # 图级地形覆盖：{ "terrain/variant": {move?, effects?} }（只改本图，向后兼容默认{}）
		"environment": environment,   # 环境：{time, weather_table:[{weather,weight,min_rounds,max_rounds}]}（向后兼容默认{}）
		"locations": locations,   # 地点实例（大地图 M7；向后兼容默认[]）
		"rivers": _normalize_features(data.get("rivers")),   # 线特征 v4（向后兼容默认[]）
		"roads": _normalize_features(data.get("roads")),
		"bridges": _normalize_pairs(data.get("bridges")),
	}

# 数组逐项只留字典（非数组归 []）——locations 等「对象列表」字段的坏项清洗，防非字典项流入下游按下标消费的 UI。
static func _dicts_only(raw) -> Array:
	var out := []
	if typeof(raw) == TYPE_ARRAY:
		for e in raw:
			if typeof(e) == TYPE_DICTIONARY:
				out.append(e)
	return out

# 线特征列表规整：[{id,label,pairs:[[[x,y],[x,y]],…]}]——非数组归 []，逐条坏项跳过、pairs 内坏格对丢弃。
static func _normalize_features(raw) -> Array:
	var out := []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for f in raw:
		if typeof(f) != TYPE_DICTIONARY:
			continue
		out.append({
			"id": str(f.get("id", "")),
			"label": str(f.get("label", "")),
			"pairs": _normalize_pairs(f.get("pairs")),
		})
	return out

# 格对列表规整：[[[x1,y1],[x2,y2]],…]——坏形丢弃、坐标 int 化（越界判定留读端消费方，与 regions 同待遇）
static func _normalize_pairs(raw) -> Array:
	var out := []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for p in raw:
		if typeof(p) != TYPE_ARRAY or p.size() < 2:
			continue
		var a = p[0]
		var b = p[1]
		if typeof(a) != TYPE_ARRAY or a.size() < 2 or typeof(b) != TYPE_ARRAY or b.size() < 2:
			continue
		out.append([[int(a[0]), int(a[1])], [int(b[0]), int(b[1])]])
	return out

# tiles 规整：建 h×w 二维数组，逐格取 {terrain,variant}，缺 / 坏格回退默认地形（草原）
static func _normalize_tiles(raw, w: int, h: int) -> Array:
	var out := []
	for row in h:
		var line := []
		for col in w:
			var t := {"terrain": DEFAULT_TERRAIN, "variant": DEFAULT_VARIANT}
			if typeof(raw) == TYPE_ARRAY and row < raw.size() \
					and typeof(raw[row]) == TYPE_ARRAY and col < raw[row].size():
				var src = raw[row][col]
				if typeof(src) == TYPE_DICTIONARY and src.has("terrain") and src.has("variant"):
					t = {"terrain": String(src["terrain"]), "variant": String(src["variant"])}
			line.append(t)
		out.append(line)
	return out

# 全草原（加载失败 / 新建兜底用）
static func grassland(w: int, h: int) -> Array:
	return _normalize_tiles([], maxi(1, w), maxi(1, h))

# 组装完整 schema 字典。opts＝可选字段包（原 8 个尾置位置参数收敛成字典，防再加字段时全调用面连坐）：
#   regions:[{…cells:[[x,y]]}] / units:[{proto,col,row,faction}] / triggers:[{id,when,do}]
#   terrain_overrides:{"terrain/variant":{move?,effects?}} / environment:{time?,weather_table?}
#   map_type:"battle"|"overworld" / locations:[…] / rivers:[…] / roads:[…] / bridges:[…]
static func to_dict(w: int, h: int, tiles: Array, opts: Dictionary = {}) -> Dictionary:
	return {
		"format_version": FORMAT_VERSION,
		"grid": GRID,
		"map_type": str(opts.get("map_type", "battle")),
		"width": w,
		"height": h,
		"tiles": tiles,
		"regions": opts.get("regions", []),
		"units": opts.get("units", []),
		"triggers": opts.get("triggers", []),
		"terrain_overrides": opts.get("terrain_overrides", {}),
		"environment": opts.get("environment", {}),
		"locations": opts.get("locations", []),
		"rivers": opts.get("rivers", []),
		"roads": opts.get("roads", []),
		"bridges": opts.get("bridges", []),
	}

# 写地图文件（2 空格缩进，与原编辑器一致）；成功返回 true。opts 同 to_dict。
static func write_map(path: String, w: int, h: int, tiles: Array, opts: Dictionary = {}) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(to_dict(w, h, tiles, opts), "  "))
	f.close()
	return true
