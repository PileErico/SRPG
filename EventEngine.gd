extends RefCounted
## 统一 when/do 事件引擎（M3；DB 范式：preload + static，无 class_name）——战斗触发器与大地图事件共用一套评估/执行。
## 职责三块：
## ① 动作元数据注册表＝动作「唯一登记处」（id/中文名/参数字段）。运行时执行与编辑器表单都据此生成——
##    加新动作只改本文件 ACTIONS + 宿主实现原语，编辑器 UI 自动跟上（治「编辑器/运行时动作表分叉」）。
## ② 执行：execute_action 解析参数（默认值/clamp 单一处）→ 转发宿主原语（event_* 鸭子类型，has_method 守卫）——
##    宿主没实现的能力＝警告跳过（大地图宿主可不支持战斗动作，反之亦然）。
## ③ 评估：when 三事件 enter_region（战斗现状迁入）/ enter_tile / timer + 闸门（once / chance / 冷却 / 全局间隔）；
##    enter_tile 另支持 col/row/terrain 硬条件（terrain＝有效地形 id，调用方传入才参与匹配——不传＝带地形条件的事件不中）。
## fired/冷却状态分两层 🔒：战斗局部（宿主自持字典、每战清零）vs 世界持久（WorldState.event_* 字段随档落盘）；
## 冷却与全局间隔按世界时间（clock_hours）计，仅传入 ws 时生效——战斗侧 ws=null＝只有 once/chance 闸门。
## once 缺省值按事件类型：enter_region/enter_tile＝true（现状契约），timer＝false（周期语义）。
## ④ schema 描述：event_status（活状态徽章）/ when_text / gate_text——事件 UI（📜 面板等）只消费这里，
##    闸门判定单一源＝gate_status（评估与展示同一实现，杜绝面板复述引擎逻辑的双源漂移）。
## 宿主原语约定（实现即支持该动作）：event_log(text) / event_activate_aggro(group)
##   / event_set_weather(weather, duration) / event_spawn_unit(proto_id, faction, col, row)
##   / event_start_battle(map_path) / event_dialogue(dialogue_id)
##   / event_add_rep(faction_id, delta) / event_set_flag(key, value) / event_give_item(item_id, count)。

const TerrainDB := preload("res://TerrainDB.gd")   # 仅 ④ 描述层用（when.terrain → 地形中文名）；无反向依赖
const GLOBAL_EVENT_GAP_HOURS := 24   # 全局事件间隔（BB 式防世界事件刷屏）：占位值，将来挪难度/设定层

# ============ ① 动作元数据注册表（单一源：运行时 execute_action 与编辑器动作表单共用）============
# fields.type → 编辑器控件：text＝单行文本(placeholder=label) / int＝SpinBox(min/max) / proto＝原型下拉
#             / faction＝阵营下拉 / weather＝天气下拉 / dialogue＝对话下拉（DialogueDB）。
# 控件渲染单一实现＝EditorUI.event_action_field（触发器 do 表单与对话选项结果动作共用）。
# col/row 的 max 是宽泛上限——运行时按地图尺寸 clamp 兜底。
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
	{"id": "start_battle", "label": "进入战斗", "fields": [
		{"key": "map", "label": "战斗地图路径", "type": "text", "default": "res://maps/sandbox.json"},
	]},
	{"id": "dialogue", "label": "开对话", "fields": [
		{"key": "dialogue_id", "label": "对话", "type": "dialogue", "default": ""},
	]},
	{"id": "add_rep", "label": "改声望", "fields": [
		{"key": "faction_id", "label": "派系id（data/factions.json）", "type": "text", "default": ""},
		{"key": "delta", "label": "增减", "type": "int", "default": 0, "min": -100, "max": 100},
	]},
	{"id": "set_flag", "label": "设世界flag", "fields": [
		{"key": "key", "label": "flag 键", "type": "text", "default": ""},
		{"key": "value", "label": "值（true/false/文本）", "type": "text", "default": "true"},
	]},
	{"id": "give_item", "label": "给予物品", "fields": [
		{"key": "item_id", "label": "物品id（data/items.json）", "type": "text", "default": ""},
		{"key": "count", "label": "数量", "type": "int", "default": 1, "min": 1, "max": 999},
	]},
	{"id": "give_gold", "label": "给予金钱", "fields": [
		{"key": "amount", "label": "数额（负=损失；余额钳 0）", "type": "int", "default": 0, "min": -999, "max": 999},
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
		"start_battle":
			_host_call(host, "event_start_battle", [str(a.get("map", ""))])
		"dialogue":
			var did := str(a.get("dialogue_id", ""))
			if did == "":
				return
			_host_call(host, "event_dialogue", [did])
		"add_rep":
			var fid := str(a.get("faction_id", ""))
			if fid == "":
				return
			_host_call(host, "event_add_rep", [fid, int(a.get("delta", 0))])
		"set_flag":
			var key := str(a.get("key", ""))
			if key == "":
				return
			# "true"/"false" 转 bool（flag 主流形态）；其余按原文本存——单一解析处，宿主只管存
			var raw := str(a.get("value", "true"))
			var val = true if raw == "true" else (false if raw == "false" else raw)
			_host_call(host, "event_set_flag", [key, val])
		"give_item":
			var iid := str(a.get("item_id", ""))
			if iid == "":
				return
			_host_call(host, "event_give_item", [iid, maxi(1, int(a.get("count", 1)))])
		"give_gold":
			var amt := int(a.get("amount", 0))
			if amt == 0:
				return
			_host_call(host, "event_give_gold", [amt])
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
# terrain＝落格的有效地形 id（terrains.json entry.id，可选）：when.terrain 只在两者相等时放行——
# 旧调用方不传（""）＝带地形条件的事件一律不中，其余行为不变（向后兼容）。
static func check_enter_tile(triggers: Array, cell: Vector2i, faction: String, fired: Dictionary, host, ws = null, terrain := "") -> void:
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
		if when.has("terrain") and str(when["terrain"]) != terrain:
			continue
		var tid := trigger_key(trig, i)
		if not _gates_open(when, tid, fired, ws, true):
			continue
		if not _roll_chance(when):
			continue
		_record_fire(when, tid, fired, ws)
		fire_trigger(trig, host)

# enter_location：抵达地点（任务线地基 §2-3；Overworld._arrive 停靠时评估——途经不触发，与地点面板同 BB 式停靠语义）。
# when.location 缺省＝任意地点；when.location_type（可选）＝按类型（city/village/ruin/lair）。
static func check_enter_location(triggers: Array, loc: Dictionary, fired: Dictionary, host, ws = null) -> void:
	for i in triggers.size():
		var trig = triggers[i]
		if typeof(trig) != TYPE_DICTIONARY:
			continue
		var when = trig.get("when", {})
		if typeof(when) != TYPE_DICTIONARY or str(when.get("event", "")) != "enter_location":
			continue
		if when.has("location") and str(when["location"]) != str(loc.get("id", "")):
			continue
		if when.has("location_type") and str(when["location_type"]) != str(loc.get("type", "")):
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
		if timer_beat_left(when, tid, ws) > 0:
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

# 硬闸状态单一源（评估与 📜 面板共用一份实现）：判定序＝禁用 → once/fired → 冷却 → 全局间隔（后两者仅世界层 ws 生效）。
# 返回 {ready, reason, hours_left}：reason ∈ ""(就绪)/disabled/fired/cooldown/global_gap；hours_left 仅后两者有意义。
# 不通过＝本次评估不消耗任何状态。
static func gate_status(when: Dictionary, tid: String, fired: Dictionary, ws, default_once: bool) -> Dictionary:
	if ws != null and ws.event_disabled.has(tid):
		return {"ready": false, "reason": "disabled", "hours_left": 0}   # 玩家在📜面板禁用（含伪触发器；随档持久）
	if bool(when.get("once", default_once)) and fired.has(tid):
		return {"ready": false, "reason": "fired", "hours_left": 0}
	# flag 闸（任务线地基 §2-3）：when.flag=该世界 flag 须为真 / when.flag_not=须为假——任务链纯数据可表达
	#（无 ws＝无档沙盒：带 flag 条件的事件一律不中，与 terrain 条件同款保守语义）
	if when.has("flag") and (ws == null or not bool(ws.flags.get(str(when["flag"]), false))):
		return {"ready": false, "reason": "flag", "hours_left": 0}
	if when.has("flag_not") and ws != null and bool(ws.flags.get(str(when["flag_not"]), false)):
		return {"ready": false, "reason": "flag", "hours_left": 0}
	if ws != null:
		var cd_left: int = int(ws.event_cooldown_until.get(tid, -1)) - ws.clock_hours
		if cd_left > 0:
			return {"ready": false, "reason": "cooldown", "hours_left": cd_left}
		if bool(when.get("global_gap", false)):
			var gap_left: int = GLOBAL_EVENT_GAP_HOURS - (ws.clock_hours - ws.last_world_event_hours)
			if gap_left > 0:
				return {"ready": false, "reason": "global_gap", "hours_left": gap_left}
	return {"ready": true, "reason": "", "hours_left": 0}

# 硬闸布尔视图（评估路径用；实现在 gate_status——改闸门只改那一处）
static func _gates_open(when: Dictionary, tid: String, fired: Dictionary, ws, default_once: bool) -> bool:
	return bool(gate_status(when, tid, fired, ws, default_once)["ready"])

# timer 距下个节拍剩余小时（≤0＝到点）：check_timer 与面板状态共用的节拍判定
static func timer_beat_left(when: Dictionary, tid: String, ws) -> int:
	var every := maxi(1, int(when.get("every_hours", 24)))
	return every - (ws.clock_hours - int(ws.event_timer_last.get(tid, 0)))

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

# ============ ④ schema 描述（事件 UI 共用；引擎＝when/do schema 属主，展示层只消费不复述）============

# 事件活状态（📜 面板徽章）：{ready, text}——判定＝gate_status（与评估同一实现）+ timer 节拍；once 缺省按事件类型（同评估路径）。
static func event_status(ev: Dictionary, ws) -> Dictionary:
	if ws == null:
		return {"ready": false, "text": "无战役档"}
	var when: Dictionary = ev.get("when", {}) if typeof(ev.get("when")) == TYPE_DICTIONARY else {}
	var tid := str(ev.get("id", ""))
	var is_timer := str(when.get("event", "")) == "timer"
	var gs := gate_status(when, tid, ws.event_fired, ws, not is_timer)
	if not bool(gs["ready"]):
		match str(gs["reason"]):
			"disabled":
				return {"ready": false, "text": "已禁用"}
			"fired":
				return {"ready": false, "text": "已触发"}
			"flag":
				return {"ready": false, "text": "前置未达（flag 条件）"}
			"cooldown":
				return {"ready": false, "text": "冷却中（剩 %d 小时）" % int(gs["hours_left"])}
			"global_gap":
				return {"ready": false, "text": "全局间隔中（剩 %d 小时）" % int(gs["hours_left"])}
	if is_timer:
		var beat_left := timer_beat_left(when, tid, ws)
		if beat_left > 0:
			return {"ready": false, "text": "未到节拍（还需 %d 小时）" % beat_left}
	return {"ready": true, "text": "可用"}

# 触发条件中文文案：enter_tile+terrain→进入〈地形名〉/ +col·row→进入（c, r）/ 无限定→任意移动；
# enter_region→进入区域〈id〉；timer→每 N 小时。
static func when_text(when: Dictionary) -> String:
	match str(when.get("event", "")):
		"enter_tile":
			if when.has("terrain"):
				var e = TerrainDB.entry_by_id(str(when["terrain"]))
				return "进入〈%s〉" % (str(e.get("label", when["terrain"])) if e != null else str(when["terrain"]))
			if when.has("col") or when.has("row"):
				var c := str(int(when["col"])) if when.has("col") else "＊"
				var r := str(int(when["row"])) if when.has("row") else "＊"
				return "进入（%s, %s）" % [c, r]
			return "任意移动"
		"enter_region":
			return "进入区域〈%s〉" % str(when.get("region", "?"))
		"enter_location":
			if when.has("location"):
				return "抵达地点〈%s〉" % str(when["location"])
			if when.has("location_type"):
				return "抵达任意〈%s〉" % str(when["location_type"])
			return "抵达任意地点"
		"timer":
			return "每 %d 小时" % maxi(1, int(when.get("every_hours", 24)))
	return "？（%s）" % str(when.get("event", ""))

# 概率/CD 短文案：chance 缺省 100%；cooldown_hours 0/缺省＝无；once 缺省按事件类型（同评估路径）
static func gate_text(when: Dictionary) -> String:
	var chance := float(when.get("chance", 100))
	var chance_txt: String = ("%d%%" % int(chance)) if chance == floorf(chance) else ("%.1f%%" % chance)
	var cd := int(when.get("cooldown_hours", 0))
	var parts := ["概率 %s" % chance_txt, ("CD %d 小时" % cd) if cd > 0 else "CD 无"]
	if bool(when.get("global_gap", false)):
		parts.append("全局间隔")
	if when.has("flag"):
		parts.append("需〈%s〉" % str(when["flag"]))
	if when.has("flag_not"):
		parts.append("需无〈%s〉" % str(when["flag_not"]))
	if bool(when.get("once", str(when.get("event", "")) != "timer")):
		parts.append("仅一次")
	return "｜".join(parts)
