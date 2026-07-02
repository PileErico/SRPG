extends RefCounted
## 环境注册表（天气 + 日夜）：读 res://data/environment.json，做「环境真值」单一来源（代码侧）。
## 用法：const EnvDB := preload("res://EnvDB.gd")，再 EnvDB.weather(id) / EnvDB.weather_sight(id) / EnvDB.all_weathers()。
## （仿 TerrainDB/ItemDB：preload + 静态变量 = 全局单例，不用 class_name 免编辑器扫描；headless 也能用。）
## 数据/代码分离：具体天气/日夜及其 sight 修正是「数据」(environment.json)；这里只做加载 + O(1) 查表。
## 见 docs/感知系统.md「环境：日夜 + 天气」🔒。近期环境只影响视野(sight)，将来影响别的 = 数据加字段 + 消费端多读。

const ENV_PATH := "res://data/environment.json"

static var _weathers := []          # 有序天气定义（编辑器天气下拉按此顺序）
static var _times := []             # 有序日夜定义
static var _weather_by_id := {}     # id -> 天气 entry
static var _time_by_id := {}        # id -> 日夜 entry
static var _loaded := false

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	_weathers = []
	_times = []
	_weather_by_id = {}
	_time_by_id = {}
	if FileAccess.file_exists(ENV_PATH):
		var f = FileAccess.open(ENV_PATH, FileAccess.READ)
		var data = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(data) == TYPE_DICTIONARY:
			for e in data.get("weathers", []):
				if typeof(e) == TYPE_DICTIONARY and e.has("id"):
					_weathers.append(e)
					_weather_by_id[str(e["id"])] = e
			for e in data.get("times", []):
				if typeof(e) == TYPE_DICTIONARY and e.has("id"):
					_times.append(e)
					_time_by_id[str(e["id"])] = e
	if _weathers.is_empty():   # 兜底：至少有个晴
		var clear := {"id": "clear", "label": "晴", "sight": 0, "desc": "晴"}
		_weathers = [clear]
		_weather_by_id = {"clear": clear}
	if _times.is_empty():
		var day := {"id": "day", "label": "昼", "sight": 0, "desc": "昼"}
		_times = [day]
		_time_by_id = {"day": day}

# —— 天气 ——
static func all_weathers() -> Array:
	_ensure()
	return _weathers

static func weather(id: String):
	_ensure()
	return _weather_by_id.get(id)

static func weather_label(id: String) -> String:
	var e = weather(id)
	return str(e.get("label", id)) if e != null else id

static func weather_sight(id: String) -> int:
	var e = weather(id)
	return int(e.get("sight", 0)) if e != null else 0

static func weather_desc(id: String) -> String:
	var e = weather(id)
	return str(e.get("desc", "")) if e != null else ""

# —— 日夜 ——
static func all_times() -> Array:
	_ensure()
	return _times

static func time(id: String):
	_ensure()
	return _time_by_id.get(id)

static func time_label(id: String) -> String:
	var e = time(id)
	return str(e.get("label", id)) if e != null else id

# 当日小时(0~23) → 日夜 id：取 from_hour<=h 的最大者；h 在最早时段之前＝环回前一日最后时段（如 0~5 点＝夜）。
# 无 from_hour 的时段不参与映射（只能被地图显式指定，如特殊剧本时段）；全无 from_hour → 第一个时段兜底。
static func time_for_hour(h: int) -> String:
	_ensure()
	var best_id := ""
	var best_from := -1
	var wrap_id := ""    # from_hour 最大者＝跨午夜环回的归属时段
	var wrap_from := -1
	for e in _times:
		if not e.has("from_hour"):
			continue
		var fh := int(e["from_hour"])
		if fh <= h and fh > best_from:
			best_from = fh
			best_id = str(e["id"])
		if fh > wrap_from:
			wrap_from = fh
			wrap_id = str(e["id"])
	if best_id != "":
		return best_id
	if wrap_id != "":
		return wrap_id
	return str(_times[0].get("id", "day"))

# 日夜的视野【最终乘子】：在天气/装备/技能等所有加减之后再乘（夜=0.5 减半）。默认 1.0。
static func time_sight_mult(id: String) -> float:
	var e = time(id)
	return float(e.get("sight_mult", 1.0)) if e != null else 1.0

# 日夜的全屏变暗滤镜色（含 alpha 的 hex，空＝不变暗）
static func time_tint(id: String) -> String:
	var e = time(id)
	return str(e.get("tint", "")) if e != null else ""

# —— 日夜变暗叠层小工具（战斗/大地图共用；「tint 空串＝无叠层」语义的唯一实现处）——

# 造一个标准变暗叠层（满铺、点击穿透、初始隐藏）；调用方自行 add_child 定层级
static func make_time_overlay() -> ColorRect:
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.visible = false
	return rect

# 按日夜 id 刷新叠层：有 tint 上色显示、无 tint 隐藏
static func apply_time_tint(rect: ColorRect, id: String) -> void:
	if rect == null:
		return
	var tint := time_tint(id)
	if tint != "":
		rect.color = Color.html(tint)
		rect.visible = true
	else:
		rect.visible = false
