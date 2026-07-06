extends RefCounted
## 种族底值注册表（data/races.json 单一数据源）——属性重做 🔒（docs/属性与成长系统.md §3）：
## 四维派生已删，基础面板值（HP_max/atk/acc/eva/速度/移动/视野…）按种族给定、同种族底色趋同；
## 原型 stats 只写与种族底值的差异。扁平血量：底值不随等级增长。
## 仿 *DB 伪单例：preload + 静态缓存；刷新叫 reload_data（DB 铁律：不叫 reload，防命中 Script.reload）。
## 用法：const RaceDB := preload("res://RaceDB.gd") → RaceDB.apply_to(u, "human")

const PATH := "res://data/races.json"

static var _races := {}
static var _loaded := false

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	_races = {}
	if not FileAccess.file_exists(PATH):
		push_warning("RaceDB：找不到 %s——种族底值缺失，单位将用引擎默认基线" % PATH)
		return
	var f := FileAccess.open(PATH, FileAccess.READ)
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(d) != TYPE_DICTIONARY:
		push_warning("RaceDB：%s 解析失败（顶层须为 {race_id: {...}}）" % PATH)
		return
	_races = d

static func reload_data() -> void:
	_loaded = false

static func get_race(id: String) -> Dictionary:
	_ensure()
	var r = _races.get(id, null)
	return r if typeof(r) == TYPE_DICTIONARY else {}

static func all_ids() -> Array:
	_ensure()
	return _races.keys()

# 把种族底值写进单位：stats 基础值直写（作为面板 base，修正管线再叠）+ 种族 tags 并入 + 记 race_id。
# race 空/未知 → no-op（保持引擎默认基线＝人类基线，见 Unit.stats 默认值）。
static func apply_to(u, race_id: String) -> void:
	var r := get_race(race_id)
	if r.is_empty():
		return
	u.race_id = race_id
	var st = r.get("stats", {})
	if typeof(st) == TYPE_DICTIONARY:
		for k in st:
			u.stats[k] = st[k]
	for t in r.get("tags", []):
		if not u.tags.has(str(t)):
			u.tags.append(str(t))
