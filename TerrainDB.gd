extends RefCounted
## 地形注册表：读 res://terrains.json，做编辑器与战斗的「地形真值」单一来源（代码侧）。
## 用法：const TerrainDB := preload("res://TerrainDB.gd")，再 TerrainDB.palette() / TerrainDB.entry_for(tile)。
## （仿 ItemDB：preload + 静态变量 = 全局单例，不用 class_name 免编辑器扫描；headless 也能用。）
## 数据/代码分离：地形属性是「数据」(terrains.json)；这里只做加载 + 按 terrain/variant 的 O(1) 查表。
## 取代了 MapEditor / Sandbox 各自的 _load_terrains + 逐格线性扫描查表（每帧 ×格数 的开销）。

const TERRAINS_PATH := "res://terrains.json"

static var _palette := []      # 有序地形定义（笔刷栏顺序 / 战斗调色都按这个）
static var _by_key := {}       # "terrain/variant" -> entry，O(1) 查表
static var _loaded := false

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	_palette = []
	_by_key = {}
	if FileAccess.file_exists(TERRAINS_PATH):
		var f = FileAccess.open(TERRAINS_PATH, FileAccess.READ)
		var data = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(data) == TYPE_DICTIONARY and typeof(data.get("terrains")) == TYPE_ARRAY:
			for entry in data["terrains"]:
				if typeof(entry) == TYPE_DICTIONARY and entry.has("terrain") and entry.has("variant"):
					_palette.append(entry)
					_by_key[_key(entry["terrain"], entry["variant"])] = entry
	if _palette.is_empty():
		push_warning("terrains.json 缺失或无效，使用内置兜底地形")
		var g := {"label": "草原", "terrain": "plain", "variant": "grassland",
			"color": "#4A7C3A", "accent": "#7BB35C", "decor": "grass", "tags": ["ground", "open"],
			"move": {"cost": 1, "passable_by": "all"}, "effects": []}
		_palette = [g]
		_by_key = {_key("plain", "grassland"): g}

static func _key(terrain, variant) -> String:
	return "%s/%s" % [terrain, variant]

# 有序地形定义列表（笔刷栏 / 调色按这个顺序）
static func palette() -> Array:
	_ensure()
	return _palette

# 按 tile({terrain,variant}) 查地形定义，找不到返回 null
static func entry_for(tile):
	_ensure()
	if typeof(tile) == TYPE_DICTIONARY:
		return _by_key.get(_key(tile.get("terrain"), tile.get("variant")))
	return null

# 以下为画布常用的取值封装（找不到地形 → 品红/none/未知，便于发现数据异常）
static func color_of(tile) -> Color:
	var e = entry_for(tile)
	return Color.html(e.color) if e != null else Color(1, 0, 1)

static func accent_of(tile) -> Color:
	var e = entry_for(tile)
	return Color.html(e.accent) if e != null else Color(1, 0, 1)

static func decor_of(tile) -> String:
	var e = entry_for(tile)
	return str(e.decor) if e != null else "none"

static func label_of(tile) -> String:
	var e = entry_for(tile)
	return str(e.label) if e != null else "未知"
