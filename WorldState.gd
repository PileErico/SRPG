extends RefCounted
## Campaign 层聚合根（战斗外世界状态 single source）：时钟 / roster / 物品实例库 / 声望 / 世界 flag。
## 纯数据、不认识任何场景节点——场景（Overworld/营地/战斗入口）是它的消费者。
## 落盘经 SaveIO（user://saves/）；序列化套路同地图 v3：save_version + 读端 .get 兜底。
## 生命周期：`WorldState.current`＝当前战役（静态引用，跨 change_scene 存活，仿 SandboxConfig 范式）；
##          null＝无战役——沙盒/编辑器模式不建档、不落盘 🔒。**物品实例库归属本实例**（item_instances 成员），
##          ItemInstances 门面按 current 路由——换档=换 current，无全局副作用（读档预览安全）。
## uid 铁律 🔒：unit / item 实例共用**一个**存档域自增计数器（mint_uid）；0＝未分配（临时对象）。
## 时间铁律 🔒：clock_hours＝单调小时计数器（战斗不消耗世界时间；仅大地图移动/扎营推进）。
## 用法：const WorldState := preload("res://WorldState.gd") → WorldState.current / WorldState.mint_uid()。

const UnitFactory := preload("res://UnitFactory.gd")
const ItemInstances := preload("res://ItemInstances.gd")

const SAVE_VERSION := 1

static var current = null           # 当前战役（WorldState 实例）或 null
static var _transient_next_uid := 1 # 无战役时的临时计数（沙盒等；与档内 uid 域天然隔离——库也各是一个）

var save_version := SAVE_VERSION
var next_uid := 1        # 存档域自增 uid 计数器（unit/item 共用）
var clock_hours := 0     # 世界时钟：单调小时计数（日夜=小时区间→EnvDB time 映射，WorldClock 于 M2 接管语义）
var ironman := false     # 铁人模式 flag（强制单槽覆盖；SaveIO 第一版即预留）
var flags := {}          # 世界 flag {key: value}——任务/事件状态起步先用它兜底
var reputation := {}     # 派系声望 {faction_id: int}
var roster := []         # 花名册：活 Unit 对象列表（存档时经 unit_to_campaign 快照、读档重建）
var item_instances := {} # 本档物品实例库 {uid(int): inst}——ItemInstances 门面在 current==self 时路由到这
# —— 世界层事件状态（EventEngine 持久层；战斗局部 fired 在 Sandbox、每战清零，两层分离 🔒）——
var event_fired := {}            # 已触发事件 {tid: true}（once 消费）
var event_timer_last := {}       # timer 事件上次节拍时刻 {tid: clock_hours}
var event_cooldown_until := {}   # 事件冷却到期时刻 {tid: clock_hours}
var last_world_event_hours := -1000000   # 上次 global_gap 事件时刻（全局事件间隔用；极小初值＝开局不卡）

# ============ 战役生命周期入口（场景入口层专用；底层模块别碰 current，改收显式参数）============

# 新建战役：建档 + 激活，一步原子完成。返回新档。
static func start_new():
	var ws = new()
	current = ws
	return ws

# 激活一个已构建的档（如 SaveIO.load_campaign 的返回值）。传 null＝退出战役（回沙盒/菜单语义）。
static func activate(ws) -> void:
	current = ws

# 分配一个存档域唯一 uid。有战役走档内计数器；无战役给临时 uid（临时库独立，不与任何档相交）。
static func mint_uid() -> int:
	if current != null:
		var id: int = current.next_uid
		current.next_uid += 1
		return id
	var tid := _transient_next_uid
	_transient_next_uid += 1
	return tid

# 单位入册：uid 为 0 / 与册内撞号则补发；装备实例若来自临时库（沙盒造的）则收编迁移进本档库。
func add_to_roster(u) -> void:
	if u == null or roster.has(u):
		return
	if u.uid == 0 or roster_by_uid(u.uid) != null:
		u.uid = next_uid
		next_uid += 1
	_adopt_equipment(u)
	roster.append(u)

func roster_by_uid(uid: int):
	for u in roster:
		if u.uid == uid:
			return u
	return null

# 收编：单位装备引用的实例若不在本档库（来自沙盒 transient 域），迁移进来并重铸 uid（修正 source 同步重写）。
func _adopt_equipment(u) -> void:
	var missing := {}
	for s in u.equipment:
		var iuid: int = int(u.equipment[s])
		if iuid > 0 and not item_instances.has(iuid):
			missing[iuid] = true
	for old_uid in missing:
		var inst = ItemInstances.take_transient(old_uid)
		if inst == null:
			push_warning("WorldState 收编：单位「%s」的装备实例 %d 无处可寻，装备引用保留但档内无实体（读档后将丢失）" % [u.unit_name, old_uid])
			continue
		var new_uid := next_uid
		next_uid += 1
		inst["uid"] = new_uid
		item_instances[new_uid] = inst
		u.remap_equip_uid(old_uid, new_uid)

# ============ 序列化（SaveIO 调用） ============

# 导出＝**roster 可达的实例才落盘**（GC：换装顶掉的孤儿/战斗临时单位造的实例不进档，防存档单调膨胀）。
# 将来加背包/仓库容器时，把它们的引用并进 reachable 即可。
func to_dict() -> Dictionary:
	var roster_json := []
	var reachable := {}
	for u in roster:
		roster_json.append(UnitFactory.unit_to_campaign(u))
		for s in u.equipment:
			reachable[int(u.equipment[s])] = true
	var items_json := []
	for iuid in item_instances:
		if reachable.has(int(iuid)):
			items_json.append((item_instances[iuid] as Dictionary).duplicate(true))
	return {
		"save_version": save_version,
		"next_uid": next_uid,
		"clock_hours": clock_hours,
		"ironman": ironman,
		"flags": flags.duplicate(true),
		"reputation": reputation.duplicate(true),
		"event_fired": event_fired.duplicate(true),
		"event_timer_last": event_timer_last.duplicate(true),
		"event_cooldown_until": event_cooldown_until.duplicate(true),
		"last_world_event_hours": last_world_event_hours,
		"item_instances": items_json,
		"roster": roster_json,
	}

# 只构建、不激活：库装进 ws 自己的成员（不碰全局/当前档）。roster 重建期间临时把 current 指向 ws
# ——单位重挂装备/旧档回退造新件的 mint 与实例路由都落在本档域（结束即还原，不违反「不自动写 current」契约）。
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
	var ef = d.get("event_fired", {})
	ws.event_fired = ef if typeof(ef) == TYPE_DICTIONARY else {}
	ws.event_timer_last = _int_valued(d.get("event_timer_last", {}))
	ws.event_cooldown_until = _int_valued(d.get("event_cooldown_until", {}))
	ws.last_world_event_hours = int(d.get("last_world_event_hours", -1000000))
	ws.item_instances = ItemInstances.parse_json(d.get("item_instances", []))
	var prev = current
	current = ws
	var ro = d.get("roster", [])
	if typeof(ro) == TYPE_ARRAY:
		for e in ro:
			if typeof(e) == TYPE_DICTIONARY:
				ws.roster.append(UnitFactory.unit_from_campaign(e))
	current = prev
	# 计数器自愈：兜住 next_uid 缺失/被手改小于存量 uid 的档（否则 mint 撞号会被 create 跳号、但 unit uid 仍可能重复）
	var mx: int = ws.next_uid
	for iuid in ws.item_instances:
		mx = maxi(mx, int(iuid) + 1)
	for u in ws.roster:
		mx = maxi(mx, int(u.uid) + 1)
	ws.next_uid = mx
	return ws

# 值 int 化的字典兜底（JSON 数字一律 float；键是 tid 字符串、天然无损）
static func _int_valued(v) -> Dictionary:
	var out := {}
	if typeof(v) == TYPE_DICTIONARY:
		for k in v:
			out[str(k)] = int(v[k])
	return out
