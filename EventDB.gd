extends RefCounted
## 全局事件池注册表：读 res://data/events.json——跨地图（map-agnostic）的世界事件单一来源。
## 条目复用触发器 schema（{id,label,desc?,when{event,...},do:[{action,...}]}），EventEngine 原样消费；
## 与每图 triggers（Overworld._map_triggers）并行评估——once/冷却/timer 状态同存 WorldState.event_*，
## 故事件 id 必须全局唯一（且不与各图 trigger id 相撞，否则持久状态串档）。
## 用法：const EventDB := preload("res://EventDB.gd")，再 EventDB.all_events() / EventDB.event(id)。
## （DB 范式同 ItemDB/TerrainDB：preload + static，无 class_name；刷新＝reload_data，绝不叫 reload——命中原生 Script.reload()。）

const EVENTS_PATH := "res://data/events.json"
const JsonRegistry := preload("res://JsonRegistry.gd")

static var _events := []       # 有序事件列表（面板按此顺序展示）
static var _by_id := {}        # id -> event，O(1) 查表
static var _loaded := false
static var _path_override := ""   # 测试注入缝：非空则读此路径，绝不碰真 data/events.json（仿 ItemDB/TerrainDB）

static func _path() -> String:
	return _path_override if _path_override != "" else EVENTS_PATH

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	var r = JsonRegistry.load_indexed(_path(), "")   # events.json 顶层即数组
	_events = r["list"]
	_by_id = r["by_id"]

# 全部事件（有序；引擎/面板直接消费）
static func all_events() -> Array:
	_ensure()
	return _events

# 按 id 取一条事件（找不到返回 null）
static func event(id: String):
	_ensure()
	return _by_id.get(id)

# 丢弃内存表、下次查询重读磁盘（events.json 被外部改过时用）
# ⚠️ 不能叫 reload：外部 EventDB.reload() 会命中原生 Script.reload()（重编译+静态全重置），全 DB 统一 reload_data。
static func reload_data() -> void:
	_loaded = false
	_ensure()
