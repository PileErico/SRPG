extends RefCounted
## 统一 when/do 事件引擎（M3；DB 范式：preload + static，无 class_name）——战斗触发器与大地图事件共用一套评估/执行。
## 职责三块：
## ① 动作元数据注册表＝动作「唯一登记处」（id/中文名/参数字段）。运行时执行与编辑器表单都据此生成——
##    加新动作只改本文件 ACTIONS + 宿主实现原语，编辑器 UI 自动跟上（治「编辑器/运行时动作表分叉」）。
## ② 执行：execute_action 解析参数（默认值/clamp 单一处）→ 转发宿主原语（event_* 鸭子类型，has_method 守卫）——
##    宿主没实现的能力＝警告跳过（大地图宿主可不支持战斗动作，反之亦然）。
## ③ 评估：when 三事件 enter_region（战斗现状迁入）/ enter_tile / timer + 闸门（once / chance / 冷却 / 全局间隔）。
## fired/冷却状态分两层 🔒：战斗局部（宿主自持字典、每战清零）vs 世界持久（WorldState.event_* 字段随档落盘）；
## 冷却与全局间隔按世界时间（clock_hours）计，仅传入 ws 时生效——战斗侧 ws=null＝只有 once/chance 闸门。
## once 缺省值按事件类型：enter_region/enter_tile＝true（现状契约），timer＝false（周期语义）。
## 宿主原语约定（实现即支持该动作）：event_log(text) / event_activate_aggro(group)
##   / event_set_weather(weather, duration) / event_spawn_unit(proto_id, faction, col, row)。

const GLOBAL_EVENT_GAP_HOURS := 24   # 全局事件间隔（BB 式防世界事件刷屏）：占位值，将来挪难度/设定层

# ============ ① 动作元数据注册表（单一源：运行时 execute_action 与编辑器动作表单共用）============
# fields.type → 编辑器控件：text＝单行文本(placeholder=label) / int＝SpinBox(min/max) / proto＝原型下拉
#             / faction＝阵营下拉 / weather＝天气下拉。col/row 的 max 是宽泛上限——运行时按地图尺寸 clamp 兜底。
const ACTIONS := [
	{"id": "show_message", "label": "弹消息", "fields": [
		{"key": "text", "label": "内容", "type": "text", "default": "消息"},
	]},
	{"id": "spawn_unit", "label": "召唤单位", "fields": [
		{"key": "proto_id", "label": "原型", "type": "proto", "default": ""},
		{"key": "faction", "label": "阵营", "type": "faction", "default": "enemy"},
		{"key": "col", "label": "col", "type": "int", "default": 0, "min": 0, "max": 999},
		{"key": "row", "label": "row", "type": "int", "default": 0, "min": 0, "max": 999},
	]},
	{"id": "activate_aggro", "label": "激活AI组", "fields": [
		{"key": "group", "label": "组id（空=全敌方）", "type": "text", "default": ""},
	]},
	{"id": "set_weather", "label": "变天", "fields": [
		{"key": "weather", "label": "天气", "type": "weather", "default": "clear"},
		{"key": "duration", "label": "持续回合（0=常驻）", "type": "int", "default": 0, "min": 0, "max": 99},
	]},
]

static func action_defs() -> Array:
	return ACTIONS

static func action_def(id: String) -> Dictionary:
	for d in ACTIONS:
		if str(d["id"]) == id:
			return d
	return {}

static func action_label(id: String) -> String:
	var d := action_def(id)
	return str(d.get("label", id)) if not d.is_empty() else id

# 新建动作的缺省数据（编辑器「＋添加动作」用）：{action: id} ⊕ 各字段 default
static func default_action(id: String) -> Dictionary:
	var a := {"action": id}
	for f in action_def(id).get("fields", []):
		a[str(f["key"])] = f.get("default")
	return a

# ============ ② 执行 ============

# 执行触发器全部动作。fallback_text：show_message 缺 text 时用触发器 label（沿现状契约）。
static func fire_trigger(trig: Dictionary, host) -> void:
	var label := str(trig.get("label", trig.get("id", "")))
	for a in trig.get("do", []):
		if typeof(a) == TYPE_DICTIONARY:
			execute_action(a, host, label)

# 单动作执行：参数解析（默认值）单一处 → 宿主原语转发
static func execute_action(a: Dictionary, host, fallback_text := "") -> void:
	match str(a.get("action", "")):
		"show_message":
			_host_call(host, "event_log", [str(a.get("text", fallback_text))])
		"activate_aggro":
			_host_call(host, "event_activate_aggro", [str(a.get("group", ""))])
		"set_weather":
			_host_call(host, "event_set_weather", [str(a.get("weather", "clear")), maxi(0, int(a.get("duration", 0)))])
		"spawn_unit":
			var pid := str(a.get("proto_id", ""))
			if pid == "":
				return
			# faction 传空＝宿主按原型 default_faction 兜底；col/row 由宿主按地图尺寸 clamp
			_host_call(host, "event_spawn_unit", [pid, str(a.get("faction", "")), int(a.get("col", 0)), int(a.get("row", 0))])
		var unknown:
			push_warning("EventEngine：未知动作「%s」跳过" % unknown)

static func _host_call(host, method: String, args: Array) -> void:
	if host != null and host.has_method(method):
		host.callv(method, args)
	else:
		push_warning("EventEngine：宿主未实现能力 %s——动作跳过" % method)

# ============ ③ 评估（宿主在各钩子点调用）============

# 触发器去重 key：有 id 用 id；无 id 用数组下标兜底（否则 once 对无 id 触发器失效）
static func trigger_key(trig: Dictionary, index: int) -> String:
	var tid := str(trig.get("id", ""))
	return tid if tid != "" else "#%d" % index

# enter_region：单位落位后评估（战斗侧钩子＝玩家提交移动 + AI 走位）。region_cells＝{region_id:{Vector2i:true}}。
static func check_enter_region(triggers: Array, unit, region_cells: Dictionary, fired: Dictionary, host, ws = null) -> void:
	var cell := Vector2i(unit.col, unit.row)
	for i in triggers.size():
		var trig = triggers[i]
		if typeof(trig) != TYPE_DICTIONARY:
			continue
		var when = trig.get("when", {})
		if typeof(when) != TYPE_DICTIONARY or str(when.get("event", "")) != "enter_region":
			continue
		if not _faction_match(when, unit.faction):
			continue
		var cells: Dictionary = region_cells.get(str(when.get("region", "")), {})
		if not cells.has(cell):
			continue
		var tid := trigger_key(trig, i)
		if not _gates_open(when, tid, fired, ws, true):
			continue
		if not _roll_chance(when):
			continue
		_record_fire(when, tid, fired, ws)
		fire_trigger(trig, host)

# enter_tile：抵达/经过地块（大地图 M4 主用；战斗侧亦可）。when.col/row 缺省＝任意格；chance＝BB 式概率事件。
static func check_enter_tile(triggers: Array, cell: Vector2i, faction: String, fired: Dictionary, host, ws = null) -> void:
	for i in triggers.size():
		var trig = triggers[i]
		if typeof(trig) != TYPE_DICTIONARY:
			continue
		var when = trig.get("when", {})
		if typeof(when) != TYPE_DICTIONARY or str(when.get("event", "")) != "enter_tile":
			continue
		if not _faction_match(when, faction):
			continue
		if when.has("col") and int(when["col"]) != cell.x:
			continue
		if when.has("row") and int(when["row"]) != cell.y:
			continue
		var tid := trigger_key(trig, i)
		if not _gates_open(when, tid, fired, ws, true):
			continue
		if not _roll_chance(when):
			continue
		_record_fire(when, tid, fired, ws)
		fire_trigger(trig, host)

# timer：世界时间节拍（大地图推进时钟后调用；战斗不耗世界时间 🔒 → 战斗侧不会走到）。
# every_hours＝间隔；一次推进跨多个节拍只触发一次（不补触发，BB 式）；chance 不中＝本节拍已消耗、等下个 every。
# fired / 计时状态全在 ws（世界持久层）。
static func check_timer(triggers: Array, ws, host) -> void:
	if ws == null:
		return
	for i in triggers.size():
		var trig = triggers[i]
		if typeof(trig) != TYPE_DICTIONARY:
			continue
		var when = trig.get("when", {})
		if typeof(when) != TYPE_DICTIONARY or str(when.get("event", "")) != "timer":
			continue
		var tid := trigger_key(trig, i)
		var every := maxi(1, int(when.get("every_hours", 24)))
		if ws.clock_hours - int(ws.event_timer_last.get(tid, 0)) < every:
			continue
		if not _gates_open(when, tid, ws.event_fired, ws, false):
			continue
		ws.event_timer_last[tid] = ws.clock_hours   # 硬闸已过＝本节拍消耗（chance 不中也等下个 every）
		if not _roll_chance(when):
			continue
		_record_fire(when, tid, ws.event_fired, ws)
		fire_trigger(trig, host)

# —— 闸门 ——

# by_faction 匹配：缺省 "player"（现状契约）；""/"any" 放行
static func _faction_match(when: Dictionary, faction: String) -> bool:
	var by := str(when.get("by_faction", "player"))
	return by == "" or by == "any" or faction == by

# 硬闸（不通过＝本次评估不消耗任何状态）：once/fired → 冷却 → 全局间隔（后两者仅世界层 ws 生效）
static func _gates_open(when: Dictionary, tid: String, fired: Dictionary, ws, default_once: bool) -> bool:
	if bool(when.get("once", default_once)) and fired.has(tid):
		return false
	if ws != null:
		if ws.clock_hours < int(ws.event_cooldown_until.get(tid, -1)):
			return false
		if bool(when.get("global_gap", false)) and ws.clock_hours - ws.last_world_event_hours < GLOBAL_EVENT_GAP_HOURS:
			return false
	return true

# 软闸：chance（0~100，缺省 100＝必中）。roll 不中＝本次机会已消耗（调用方决定是否记节拍）。
static func _roll_chance(when: Dictionary) -> bool:
	var chance := float(when.get("chance", 100))
	return chance >= 100.0 or randf() * 100.0 < chance

# 触发记录：fired 恒记（once 检查才消费）；世界层再记 冷却到期时刻 + global_gap 时间戳
static func _record_fire(when: Dictionary, tid: String, fired: Dictionary, ws) -> void:
	fired[tid] = true
	if ws != null:
		var cd := int(when.get("cooldown_hours", 0))
		if cd > 0:
			ws.event_cooldown_until[tid] = ws.clock_hours + cd
		if bool(when.get("global_gap", false)):
			ws.last_world_event_hours = ws.clock_hours
