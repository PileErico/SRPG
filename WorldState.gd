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

signal flag_changed(key: String, value)   # set_flag 唯一写口广播（任务线地基：任务系统/UI 订阅它，零轮询）

static var current = null           # 当前战役（WorldState 实例）或 null
static var _transient_next_uid := 1 # 无战役时的临时计数（沙盒等；与档内 uid 域天然隔离——库也各是一个）

const START_HOUR := 8    # 新战役开局时刻：第 1 天 8 点（白天开局；0 点=夜，见 WorldClock.day_number 注）
const START_GOLD := 200  # 开局资金（占位：经济数值层后调；金钱是 §1.3 交易/招募、§1.6 词条转移的共同货币）

var save_version := SAVE_VERSION
var next_uid := 1        # 存档域自增 uid 计数器（unit/item 共用）
var clock_hours := 0     # 世界时钟：单调小时计数（日夜=小时区间→EnvDB time 映射，WorldClock 语义 M2 起）
var party_col := -1      # 大地图队伍位置（-1=未落位，Overworld 首进时按地图找可走格）
var party_row := -1
var ironman := false     # 铁人模式 flag（强制单槽覆盖；SaveIO 第一版即预留）
var gold := 0            # 队伍资金（M7 起：休整消费；交易/招募/铁匠后续同用）
var flags := {}          # 世界 flag {key: value}——任务/事件状态起步先用它兜底。⚠ 写入走 set_flag 唯一写口（裸写＝无广播）
var reputation := {}     # 派系声望 {faction_id: int}
var roster := []         # 花名册：活 Unit 对象列表（存档时经 unit_to_campaign 快照、读档重建）
var item_instances := {} # 本档物品实例库 {uid(int): inst}——ItemInstances 门面在 current==self 时路由到这
var inventory := {}      # 队伍背包：可堆叠消耗品/素材 {tpl_id: count(int)}——不进 item_instances（那装带个体状态的装备）；品质=分档 id
var kill_stats := {}     # 击杀统计 {proto_id: 累计击杀数}——BattleIO 战后累计；情报解锁（图鉴）的输入源
var camp_jobs := {}      # 营地职务指派 {job_id: unit_uid}（职务定义在 JobDB；0/缺键=空缺）
var location_cleared_at := {}   # 据点上次肃清时刻 {loc_id: clock_hours}——刷新=LocationDB.site_ready 惰性判定（M7）
var world_units := []    # 大地图动态单位实例（🟡 v1）：纯 dict 列表（类型定义在 WorldUnitDB、推进在 WorldSim）
# —— 世界层事件状态（EventEngine 持久层；战斗局部 fired 在 Sandbox、每战清零，两层分离 🔒）——
var event_fired := {}            # 已触发事件 {tid: true}（once 消费）
var event_timer_last := {}       # timer 事件上次节拍时刻 {tid: clock_hours}
var event_cooldown_until := {}   # 事件冷却到期时刻 {tid: clock_hours}
var last_world_event_hours := -1000000   # 上次 global_gap 事件时刻（全局事件间隔用；极小初值＝开局不卡）
var event_disabled := {}          # 📜事件管理器里被玩家禁用的事件 {tid: true}（含伪触发器 tid 如 faction_ambush_bandits）——引擎硬闸跳过
var overworld_combat_off := false # 大地图遭遇战总开关：关＝无派系伏击 + 世界单位不主动追上开战（「给我关咯」）

# ============ 战役生命周期入口（场景入口层专用；底层模块别碰 current，改收显式参数）============

# 新建战役：建档（含开局默认值 + 初始队伍）+ 激活，一步原子完成。返回新档。
# 初始队伍＝全部 player 原型各一（占位阵容；正式开局/招募流程后置）。先激活再造单位——装备实例经门面路由进本档库。
static func start_new():
	var ws = new()
	ws.clock_hours = START_HOUR
	ws.gold = START_GOLD
	current = ws
	for p in UnitFactory.all_prototypes():
		if str(p.get("default_faction", "")) == "player":
			ws.add_to_roster(UnitFactory.make_unit(p, "player", -1, -1))
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

# ============ 队伍背包（inventory：可堆叠消耗品/素材 {tpl_id: count}；装备走 item_instances，两库不混）============

# 入库 n 件（n>0）：撞已有则累加。tpl_id 空 / n≤0 ＝空操作。
func inv_add(tpl_id: String, n := 1) -> void:
	if tpl_id == "" or n <= 0:
		return
	inventory[tpl_id] = inv_count(tpl_id) + n

# 出库 n 件：够才扣、返回是否成功；扣到 0 抹键（背包不留 0 计数条目）。
func inv_remove(tpl_id: String, n := 1) -> bool:
	var have := inv_count(tpl_id)
	if n <= 0 or have < n:
		return false
	if have == n:
		inventory.erase(tpl_id)
	else:
		inventory[tpl_id] = have - n
	return true

func inv_count(tpl_id: String) -> int:
	return int(inventory.get(tpl_id, 0))

# 职务在任者：uid 有效、人在册、且不在重伤休整中（重伤=无法参与任何活动 §1.11）才算在岗；否则 null。
# 消费端按 job_id 读（首个＝WorldClock 恢复结算读 medic；加成承载=改每小时速率 🔒）。
func job_holder(job_id: String):
	var uid := int(camp_jobs.get(job_id, 0))
	if uid <= 0:
		return null
	var u = roster_by_uid(uid)
	if u == null or int(u.injured_until) > clock_hours:
		return null
	return u

# 据点肃清落账（BattleIO 战后按 context 调；刷新判定在 LocationDB.site_ready）
func mark_location_cleared(loc_id: String) -> void:
	if loc_id != "":
		location_cleared_at[loc_id] = clock_hours

# 世界 flag 唯一写口（任务线地基 §2-1）：写入并广播 flag_changed（值没变＝不重播，任务系统幂等友好）。
# 三处散写（事件 set_flag 动作/对话 set_flags/沙盒宿主原语）已全部收拢到此。
func set_flag(key: String, value) -> void:
	var k := str(key)
	if flags.has(k) and typeof(flags[k]) == typeof(value) and flags[k] == value:
		return
	flags[k] = value
	flag_changed.emit(k, value)

# 大地图动态单位：按 uid 查/移除（BattleIO 战胜回写、WorldSim 摩擦战用）。
# uid<=0＝无效（未分配/坏档），直接 null——防 context 缺键时 get 默认 0 误中坏数据单位。
func world_unit_by_uid(uid: int):
	if uid <= 0:
		return null
	for u in world_units:
		if int(u.get("uid", 0)) == uid:
			return u
	return null

func remove_world_unit(uid: int) -> void:
	var u = world_unit_by_uid(uid)
	if u != null:
		world_units.erase(u)

# 收编：单位装备/背包引用的实例若不在本档库（来自沙盒 transient 域），迁移进来并重铸 uid（修正 source 同步重写）。
func _adopt_equipment(u) -> void:
	var missing := {}
	for s in u.equipment:
		var iuid: int = int(u.equipment[s])
		if iuid > 0 and not item_instances.has(iuid):
			missing[iuid] = true
	for biuid in u.bag:   # 背包同律（remap_equip_uid 已含 bag 条目重写）
		if int(biuid) > 0 and not item_instances.has(int(biuid)):
			missing[int(biuid)] = true
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

# 声明式字段清单：常规字段的三处维护（var 声明 / to_dict / from_dict）收敛为一处——**新增可存字段＝var 声明 + 此表加一行**。
# kind：int/bool＝标量（default 兜底）；dict＝字典透传（typeof 校验）；dict_int＝字典且值 int 化（JSON 数字回读 float）；
#       dict_arr＝字典数组逐条深拷（坏项丢弃）。roster / item_instances 需专门重建（GC 可达 / current 域切换），单列手写。
const SERIAL_FIELDS := [
	{"key": "save_version", "kind": "int", "default": SAVE_VERSION},
	{"key": "next_uid", "kind": "int", "default": 1},
	{"key": "clock_hours", "kind": "int", "default": 0},
	{"key": "party_col", "kind": "int", "default": -1},
	{"key": "party_row", "kind": "int", "default": -1},
	{"key": "ironman", "kind": "bool", "default": false},
	{"key": "gold", "kind": "int", "default": 0},
	{"key": "flags", "kind": "dict"},
	{"key": "reputation", "kind": "dict_int"},
	{"key": "kill_stats", "kind": "dict_int"},
	{"key": "camp_jobs", "kind": "dict_int"},
	{"key": "location_cleared_at", "kind": "dict_int"},
	{"key": "world_units", "kind": "dict_arr"},
	{"key": "event_fired", "kind": "dict"},
	{"key": "event_timer_last", "kind": "dict_int"},
	{"key": "event_cooldown_until", "kind": "dict_int"},
	{"key": "last_world_event_hours", "kind": "int", "default": -1000000},
	{"key": "event_disabled", "kind": "dict"},
	{"key": "overworld_combat_off", "kind": "bool", "default": false},
	{"key": "inventory", "kind": "dict_int"},
]

# 导出＝表驱动搬运 + 两个手写特例。**roster 可达的实例才落盘**（GC：换装顶掉的孤儿/战斗临时单位造的实例
# 不进档，防存档单调膨胀）。将来加背包/仓库容器时，把它们的引用并进 reachable 即可。
func to_dict() -> Dictionary:
	var out := {}
	for f in SERIAL_FIELDS:
		var key := str(f["key"])
		match str(f["kind"]):
			"dict", "dict_int", "dict_arr":
				out[key] = get(key).duplicate(true)
			_:
				out[key] = get(key)
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
	out["item_instances"] = items_json
	out["roster"] = roster_json
	return out

# 只构建、不激活：库装进 ws 自己的成员（不碰全局/当前档）。roster 重建期间临时把 current 指向 ws
# ——单位重挂装备/旧档回退造新件的 mint 与实例路由都落在本档域（结束即还原，不违反「不自动写 current」契约）。
static func from_dict(d: Dictionary):
	d = _migrate(d)
	var ws = new()
	for f in SERIAL_FIELDS:
		var key := str(f["key"])
		match str(f["kind"]):
			"int":
				ws.set(key, int(d.get(key, f.get("default", 0))))
			"bool":
				ws.set(key, bool(d.get(key, f.get("default", false))))
			"dict":
				var v = d.get(key, {})
				ws.set(key, v if typeof(v) == TYPE_DICTIONARY else {})
			"dict_int":
				ws.set(key, _int_valued(d.get(key, {})))
			"dict_arr":
				var arr := []
				var raw = d.get(key, [])
				if typeof(raw) == TYPE_ARRAY:
					for e in raw:
						if typeof(e) == TYPE_DICTIONARY:
							arr.append(e.duplicate(true))
				ws.set(key, arr)
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
	for u in ws.world_units:
		mx = maxi(mx, int(u.get("uid", 0)) + 1)
	ws.next_uid = mx
	return ws

# 存档迁移缝：按 save_version 逐级 vN→vN+1 升级（现无历史版本差异＝空实现留位，首次破坏性字段变更前就位）。
# 未来版本护栏：档比代码新（来自更新的游戏版本）→ 警告后按已知字段容错读（.get 缺省兜底），不静默装懂。
static func _migrate(d: Dictionary) -> Dictionary:
	var v := int(d.get("save_version", SAVE_VERSION))
	if v > SAVE_VERSION:
		push_warning("WorldState：存档版本 %d 新于当前代码 %d——按已知字段读取，未知字段忽略" % [v, SAVE_VERSION])
	return d

# 值 int 化的字典兜底（JSON 数字一律 float；键是 tid 字符串、天然无损）
static func _int_valued(v) -> Dictionary:
	var out := {}
	if typeof(v) == TYPE_DICTIONARY:
		for k in v:
			out[str(k)] = int(v[k])
	return out
