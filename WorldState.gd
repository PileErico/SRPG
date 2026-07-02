extends RefCounted
## Campaign 层聚合根（战斗外世界状态 single source）：时钟 / roster / 声望 / 世界 flag。
## 纯数据、不认识任何场景节点——场景（Overworld/营地/战斗入口）是它的消费者。
## 落盘经 SaveIO（user://saves/）；序列化套路同地图 v3：save_version + 读端 .get 兜底。
## 生命周期：`WorldState.current`＝当前战役（静态引用，跨 change_scene 存活，仿 SandboxConfig 范式）；
##          null＝无战役——沙盒/编辑器模式不建档、不落盘 🔒。
## uid 铁律 🔒：unit / item 实例共用**一个**存档域自增计数器（mint_uid）；0＝未分配（临时对象）。
## 时间铁律 🔒：clock_hours＝单调小时计数器（战斗不消耗世界时间；仅大地图移动/扎营推进）。
## 用法：const WorldState := preload("res://WorldState.gd") → WorldState.current / WorldState.mint_uid()。

const UnitFactory := preload("res://UnitFactory.gd")
const ItemInstances := preload("res://ItemInstances.gd")   # 物品实例整库随档序列化（roster 只存 uid 引用）

const SAVE_VERSION := 1

static var current = null           # 当前战役（WorldState 实例）或 null
static var _transient_next_uid := 1 # 无战役时的临时计数（沙盒等；不落盘、载档即被替换）

var save_version := SAVE_VERSION
var next_uid := 1        # 存档域自增 uid 计数器（unit/item 共用）
var clock_hours := 0     # 世界时钟：单调小时计数（日夜=小时区间→EnvDB time 映射，WorldClock 于 M2 接管语义）
var ironman := false     # 铁人模式 flag（强制单槽覆盖；SaveIO 第一版即预留）
var flags := {}          # 世界 flag {key: value}——任务/事件状态起步先用它兜底
var reputation := {}     # 派系声望 {faction_id: int}
var roster := []         # 花名册：活 Unit 对象列表（存档时经 unit_to_campaign 快照、读档重建）

# 分配一个存档域唯一 uid。有战役走档内计数器；无战役给临时 uid（不持久、无碰撞风险——载档会整体替换）。
static func mint_uid() -> int:
	if current != null:
		var id: int = current.next_uid
		current.next_uid += 1
		return id
	var tid := _transient_next_uid
	_transient_next_uid += 1
	return tid

# 单位入册：未分配 uid 的补发，再进 roster（重复入册忽略）。
func add_to_roster(u) -> void:
	if u == null or roster.has(u):
		return
	if u.uid == 0:
		u.uid = next_uid
		next_uid += 1
	roster.append(u)

func roster_by_uid(uid: int):
	for u in roster:
		if u.uid == uid:
			return u
	return null

# ============ 序列化（SaveIO 调用） ============

func to_dict() -> Dictionary:
	var roster_json := []
	for u in roster:
		roster_json.append(UnitFactory.unit_to_campaign(u))
	return {
		"save_version": save_version,
		"next_uid": next_uid,
		"clock_hours": clock_hours,
		"ironman": ironman,
		"flags": flags.duplicate(true),
		"reputation": reputation.duplicate(true),
		"item_instances": ItemInstances.to_json(),
		"roster": roster_json,
	}

static func from_dict(d: Dictionary):
	var ws = new()
	ws.save_version = int(d.get("save_version", SAVE_VERSION))
	ws.next_uid = int(d.get("next_uid", 1))
	ws.clock_hours = int(d.get("clock_hours", 0))
	ws.ironman = bool(d.get("ironman", false))
	var fl = d.get("flags", {})
	ws.flags = fl if typeof(fl) == TYPE_DICTIONARY else {}
	var rep = d.get("reputation", {})
	ws.reputation = rep if typeof(rep) == TYPE_DICTIONARY else {}
	ItemInstances.load_json(d.get("item_instances", []))   # 必须先于 roster：单位重挂装备要在库里找到实例
	for e in d.get("roster", []):
		if typeof(e) == TYPE_DICTIONARY:
			ws.roster.append(UnitFactory.unit_from_campaign(e))
	return ws
