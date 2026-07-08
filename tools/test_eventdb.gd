extends SceneTree
## EventDB 回归：真池读取（all_events/event/id 唯一/when·do 齐/terrain 引用在地形表）/ _path_override 注入 +
## reload_data / 缺文件·坏 JSON·非数组 优雅兜底 / Overworld 事件面板纯逻辑（event_status 徽章 / event_when_text 条件文案）。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_eventdb.gd（退出码 0=PASS）

const EventDB := preload("res://EventDB.gd")
const TerrainDB := preload("res://TerrainDB.gd")
const WorldState := preload("res://WorldState.gd")
const OverworldScript := preload("res://Overworld.gd")

const P := "user://_test_events.json"

var _fail := 0
func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _write(path: String, text: String) -> void:
	var f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()

func _initialize() -> void:
	print("=== EventDB 测试开始 ===")

	# 1) 真池：非空、按 id 命中、schema 卫生（id 唯一 + when/do 齐 + terrain 引用有效）
	var pool := EventDB.all_events()
	ck(not pool.is_empty(), "真池 all_events 非空")
	var seen := {}
	for ev in pool:
		var eid := str(ev.get("id", ""))
		ck(eid != "" and not seen.has(eid), "事件 id 非空且唯一（%s）" % eid)
		seen[eid] = true
		ck(typeof(ev.get("when")) == TYPE_DICTIONARY and typeof(ev.get("do")) == TYPE_ARRAY, "%s：when/do 齐" % eid)
		var terr := str((ev.get("when", {}) as Dictionary).get("terrain", ""))
		if terr != "":
			ck(TerrainDB.entry_by_id(terr) != null, "%s：when.terrain「%s」在地形表" % [eid, terr])
	var fw = EventDB.event("evt_fountain_whisper")
	ck(fw != null, "event(id) 命中灵泉事件")
	if fw != null:
		ck(str((fw.get("when", {}) as Dictionary).get("terrain", "")) == "fh_fountain_of_youth", "灵泉事件地形条件正确")
	ck(EventDB.event("no_such_event") == null, "未知 id → null")

	# 2) _path_override 注入 + reload_data 生效（绝不碰真 data/events.json）
	EventDB._path_override = P
	_write(P, JSON.stringify([{"id": "tmp_e1", "when": {"event": "timer", "every_hours": 6}, "do": []}]))
	EventDB.reload_data()
	ck(EventDB.all_events().size() == 1 and EventDB.event("tmp_e1") != null, "注入路径 + reload_data 生效")

	# 3) 缺文件 / 坏 JSON / 非数组 / 无 id 条目 → 优雅兜底不崩
	DirAccess.remove_absolute(P)
	EventDB.reload_data()
	ck(EventDB.all_events().is_empty(), "缺文件 → 空池不崩")
	_write(P, "{{{ 坏json")
	EventDB.reload_data()
	ck(EventDB.all_events().is_empty(), "坏 JSON → 空池不崩")
	_write(P, JSON.stringify({"not": "array"}))
	EventDB.reload_data()
	ck(EventDB.all_events().is_empty(), "非数组 → 空池不崩")
	_write(P, JSON.stringify([{"no_id": true}, {"id": "ok1", "when": {"event": "enter_tile"}, "do": []}]))
	EventDB.reload_data()
	ck(EventDB.all_events().size() == 1 and EventDB.event("ok1") != null, "无 id 条目被跳过、其余照收")
	DirAccess.remove_absolute(P)
	EventDB._path_override = ""
	EventDB.reload_data()
	ck(EventDB.event("evt_fountain_whisper") != null, "还原后真池回归")

	# 4) 事件面板纯逻辑（Overworld 静态函数，不建节点）：活状态徽章
	var ws = WorldState.new()
	ws.clock_hours = 100
	var ev_tile := {"id": "s1", "when": {"event": "enter_tile", "once": false, "cooldown_hours": 48}, "do": []}
	ck(bool(OverworldScript.event_status(ev_tile, ws).get("ready", false)), "无记录 → 可用")
	ws.event_cooldown_until["s1"] = 130
	var st: Dictionary = OverworldScript.event_status(ev_tile, ws)
	ck(not bool(st.get("ready")) and str(st.get("text")).contains("30"), "冷却中（剩 30 小时）")
	ws.clock_hours = 130
	ck(bool(OverworldScript.event_status(ev_tile, ws).get("ready", false)), "冷却到期 → 可用")
	var ev_once := {"id": "s2", "when": {"event": "enter_tile"}, "do": []}
	ws.event_fired["s2"] = true
	ck(str(OverworldScript.event_status(ev_once, ws).get("text")) == "已触发", "once 消费 → 已触发（enter_tile 缺省 once=true）")
	var ev_tm := {"id": "s3", "when": {"event": "timer", "every_hours": 24}, "do": []}
	ws.event_timer_last["s3"] = 120
	var st2: Dictionary = OverworldScript.event_status(ev_tm, ws)
	ck(not bool(st2.get("ready")) and str(st2.get("text")).contains("14"), "timer 未到节拍（还需 14 小时）")
	ws.clock_hours = 144
	ck(bool(OverworldScript.event_status(ev_tm, ws).get("ready", false)), "timer 到节拍 → 可用")
	var ev_gap := {"id": "s4", "when": {"event": "enter_tile", "once": false, "global_gap": true}, "do": []}
	ws.last_world_event_hours = ws.clock_hours - 1
	ck(not bool(OverworldScript.event_status(ev_gap, ws).get("ready")), "全局间隔未满 → 不可用")
	ck(not bool(OverworldScript.event_status(ev_tile, null).get("ready")), "ws=null 守卫不崩")

	# 5) 条件/概率文案（纯逻辑）
	ck(OverworldScript.event_when_text({"event": "enter_tile", "terrain": "fh_fountain_of_youth"}) == "进入〈灵泉〉", "文案：进入〈灵泉〉（label_of 经 entry_by_id）")
	ck(OverworldScript.event_when_text({"event": "enter_tile", "terrain": "no_such_terrain"}) == "进入〈no_such_terrain〉", "文案：未知地形回退 id")
	ck(OverworldScript.event_when_text({"event": "enter_tile", "col": 7, "row": 8}) == "进入（7, 8）", "文案：定点")
	ck(OverworldScript.event_when_text({"event": "enter_tile"}) == "任意移动", "文案：任意移动")
	ck(OverworldScript.event_when_text({"event": "enter_region", "region": "r9"}) == "进入区域〈r9〉", "文案：区域")
	ck(OverworldScript.event_when_text({"event": "timer", "every_hours": 12}) == "每 12 小时", "文案：timer")
	ck(OverworldScript.event_gate_text({"event": "enter_tile", "once": false, "chance": 4, "cooldown_hours": 24}).contains("4%"), "文案：概率")
	ck(OverworldScript.event_gate_text({"event": "enter_tile", "once": false}).contains("100%"), "文案：概率缺省 100%")
	ck(OverworldScript.event_gate_text({"event": "enter_tile", "once": false}).contains("CD 无"), "文案：无 CD")

	if _fail == 0:
		print("=== 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
