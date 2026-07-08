extends SceneTree
## M3 回归：EventEngine——动作注册表 / 执行转发 / enter_region·enter_tile·timer 评估 / 闸门(once·chance·冷却·全局间隔)
## / enter_tile 地形条件(when.terrain，不传参数=旧行为) / 事件状态存档往返。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_eventengine.gd（退出码 0=PASS）

const EventEngine := preload("res://EventEngine.gd")
const WorldState := preload("res://WorldState.gd")
const SaveIO := preload("res://SaveIO.gd")

const SLOT := "_test_m3"
var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

# 宿主替身：只收集原语调用（引擎是鸭子类型转发，够用）
class MockHost:
	extends RefCounted
	var logs := []
	var aggros := []
	var weathers := []
	var spawns := []
	func event_log(t: String) -> void: logs.append(t)
	func event_activate_aggro(g: String) -> void: aggros.append(g)
	func event_set_weather(w: String, d: int) -> void: weathers.append([w, d])
	func event_spawn_unit(pid: String, fac: String, c: int, r: int) -> void: spawns.append([pid, fac, c, r])

class FakeUnit:
	extends RefCounted
	var col := 0
	var row := 0
	var faction := "player"

func _initialize() -> void:
	print("=== EventEngine 测试开始 ===")

	# 1) 动作注册表：四动作齐、缺省值生成、中文名
	var ids := []
	for d in EventEngine.action_defs():
		ids.append(str(d["id"]))
	for want in ["show_message", "spawn_unit", "activate_aggro", "set_weather"]:
		ck(ids.has(want), "注册表含 %s" % want)
	var da := EventEngine.default_action("spawn_unit")
	ck(da["action"] == "spawn_unit" and da.has("proto_id") and da.has("faction") and da.has("col") and da.has("row"), "default_action 字段齐")
	ck(EventEngine.action_label("set_weather") == "变天", "action_label 中文")
	ck(EventEngine.action_label("no_such") == "no_such", "未知动作 label 回退 id")

	# 2) 执行转发：参数解析 + 缺省 + 守卫
	var h := MockHost.new()
	EventEngine.execute_action({"action": "show_message", "text": "你好"}, h)
	ck(h.logs == ["你好"], "show_message 转发")
	EventEngine.execute_action({"action": "show_message"}, h, "触发器甲")
	ck(h.logs.back() == "触发器甲", "show_message 缺 text 用触发器 label（现状契约）")
	EventEngine.execute_action({"action": "set_weather", "weather": "fog", "duration": -3}, h)
	ck(h.weathers == [["fog", 0]], "set_weather 负 duration clamp 0")
	EventEngine.execute_action({"action": "spawn_unit", "proto_id": "", "col": 3}, h)
	ck(h.spawns.is_empty(), "spawn 缺 proto_id 不转发")
	EventEngine.execute_action({"action": "spawn_unit", "proto_id": "p1", "col": 3, "row": 4}, h)
	ck(h.spawns == [["p1", "", 3, 4]], "spawn 转发（faction 空=宿主兜底）")
	EventEngine.execute_action({"action": "no_such_action"}, h)          # 未知动作：警告不炸
	EventEngine.execute_action({"action": "show_message"}, RefCounted.new())   # 宿主缺能力：警告不炸
	EventEngine.fire_trigger({"label": "乙", "do": [{"action": "show_message"}, {"action": "activate_aggro", "group": "g1"}]}, h)
	ck(h.logs.back() == "乙" and h.aggros == ["g1"], "fire_trigger 逐动作执行 + label fallback")

	# 3) enter_region：命中/阵营过滤/once/无 id 下标 key
	var region_cells := {"r1": {Vector2i(2, 2): true}}
	var trigs := [
		{"id": "t1", "when": {"event": "enter_region", "region": "r1"}, "do": [{"action": "show_message", "text": "R1"}]},
		{"when": {"event": "enter_region", "region": "r1", "by_faction": "any"}, "do": [{"action": "show_message", "text": "ANY"}]},
	]
	var u := FakeUnit.new()
	u.col = 2; u.row = 2
	var fired := {}
	h = MockHost.new()
	EventEngine.check_enter_region(trigs, u, region_cells, fired, h)
	ck(h.logs == ["R1", "ANY"], "enter_region 双触发（缺省 player + any）")
	EventEngine.check_enter_region(trigs, u, region_cells, fired, h)
	ck(h.logs.size() == 2, "once 缺省 true：二次踏入不重复（含无 id 触发器的下标 key）")
	u.faction = "enemy"
	fired.clear()
	h = MockHost.new()
	EventEngine.check_enter_region(trigs, u, region_cells, fired, h)
	ck(h.logs == ["ANY"], "敌方只触发 by_faction:any（缺省 player 被过滤）")
	u.col = 5
	fired.clear()
	h = MockHost.new()
	EventEngine.check_enter_region(trigs, u, region_cells, fired, h)
	ck(h.logs.is_empty(), "不在区域格不触发")

	# 4) enter_tile：任意格 / 指定格 / chance 0·100
	var tile_trigs := [
		{"id": "a1", "when": {"event": "enter_tile", "once": false}, "do": [{"action": "show_message", "text": "任意"}]},
		{"id": "a2", "when": {"event": "enter_tile", "col": 7, "row": 8, "once": false}, "do": [{"action": "show_message", "text": "定点"}]},
		{"id": "a3", "when": {"event": "enter_tile", "once": false, "chance": 0}, "do": [{"action": "show_message", "text": "永不"}]},
	]
	h = MockHost.new()
	fired.clear()
	EventEngine.check_enter_tile(tile_trigs, Vector2i(1, 1), "player", fired, h)
	ck(h.logs == ["任意"], "enter_tile：任意格中、定点不中、chance0 永不")
	h = MockHost.new()
	EventEngine.check_enter_tile(tile_trigs, Vector2i(7, 8), "player", fired, h)
	ck(h.logs == ["任意", "定点"], "enter_tile 定点格命中（once:false 任意格再触发）")

	# 4b) enter_tile 地形条件：when.terrain 只在与传入有效地形 id 相等时放行；不传参数＝旧行为（带地形条件者不中）
	var terr_trigs := [
		{"id": "tt1", "when": {"event": "enter_tile", "terrain": "fh_spring", "once": false}, "do": [{"action": "show_message", "text": "泉"}]},
		{"id": "tt2", "when": {"event": "enter_tile", "once": false}, "do": [{"action": "show_message", "text": "无谓"}]},
	]
	h = MockHost.new()
	fired.clear()
	EventEngine.check_enter_tile(terr_trigs, Vector2i(0, 0), "player", fired, h, null, "fh_spring")
	ck(h.logs == ["泉", "无谓"], "terrain 匹配触发（无地形条件者照常）")
	h = MockHost.new()
	EventEngine.check_enter_tile(terr_trigs, Vector2i(0, 0), "player", fired, h, null, "plain")
	ck(h.logs == ["无谓"], "terrain 不匹配不触发")
	h = MockHost.new()
	EventEngine.check_enter_tile(terr_trigs, Vector2i(0, 0), "player", fired, h)
	ck(h.logs == ["无谓"], "不传 terrain＝旧行为（带地形条件者不中、其余不变）")

	# 5) 冷却 + 全局间隔（世界层，需要 ws）
	var ws = WorldState.new()
	WorldState.current = ws
	var cd_trigs := [
		{"id": "c1", "when": {"event": "enter_tile", "once": false, "cooldown_hours": 5}, "do": [{"action": "show_message", "text": "冷"}]},
	]
	h = MockHost.new()
	ws.clock_hours = 10
	EventEngine.check_enter_tile(cd_trigs, Vector2i(0, 0), "player", ws.event_fired, h, ws)
	EventEngine.check_enter_tile(cd_trigs, Vector2i(0, 0), "player", ws.event_fired, h, ws)
	ck(h.logs.size() == 1, "冷却期内不重复触发")
	ws.clock_hours = 14
	EventEngine.check_enter_tile(cd_trigs, Vector2i(0, 0), "player", ws.event_fired, h, ws)
	ck(h.logs.size() == 1, "冷却差 1 小时仍卡")
	ws.clock_hours = 15
	EventEngine.check_enter_tile(cd_trigs, Vector2i(0, 0), "player", ws.event_fired, h, ws)
	ck(h.logs.size() == 2, "冷却到期再触发")
	var gap_trigs := [
		{"id": "g1", "when": {"event": "enter_tile", "once": false, "global_gap": true}, "do": [{"action": "show_message", "text": "甲"}]},
		{"id": "g2", "when": {"event": "enter_tile", "once": false, "global_gap": true}, "do": [{"action": "show_message", "text": "乙"}]},
	]
	h = MockHost.new()
	ws.clock_hours = 100
	EventEngine.check_enter_tile(gap_trigs, Vector2i(0, 0), "player", ws.event_fired, h, ws)
	ck(h.logs == ["甲"], "全局间隔：同小时第二个 global_gap 事件被卡")
	ws.clock_hours = 100 + EventEngine.GLOBAL_EVENT_GAP_HOURS
	# 只评估 g2：若连 g1 一起评估，g1（once:false）会先触发并刷新全局时间戳、再次卡住 g2——先到先得是预期语义
	EventEngine.check_enter_tile([gap_trigs[1]], Vector2i(0, 0), "player", ws.event_fired, h, ws)
	ck(h.logs == ["甲", "乙"], "全局间隔到期后放行")

	# 6) timer：every 节拍 / 跨大步只触发一次 / once
	var tm_trigs := [
		{"id": "tm1", "when": {"event": "timer", "every_hours": 6}, "do": [{"action": "show_message", "text": "钟"}]},
		{"id": "tm2", "when": {"event": "timer", "every_hours": 6, "once": true}, "do": [{"action": "show_message", "text": "一次"}]},
	]
	var ws2 = WorldState.new()
	WorldState.current = ws2
	h = MockHost.new()
	ws2.clock_hours = 5
	EventEngine.check_timer(tm_trigs, ws2, h)
	ck(h.logs.is_empty(), "timer 未到节拍不触发")
	ws2.clock_hours = 6
	EventEngine.check_timer(tm_trigs, ws2, h)
	ck(h.logs == ["钟", "一次"], "timer 到节拍触发（once 缺省 false + 显式 once）")
	ws2.clock_hours = 8
	EventEngine.check_timer(tm_trigs, ws2, h)
	ck(h.logs.size() == 2, "节拍内不重复")
	ws2.clock_hours = 100
	EventEngine.check_timer(tm_trigs, ws2, h)
	ck(h.logs.size() == 3 and h.logs.back() == "钟", "跨大步只触发一次 + once 触发器不再来")
	EventEngine.check_timer(tm_trigs, null, h)   # 无档不炸
	ck(h.logs.size() == 3, "无档 no-op")

	# 7) 事件状态存档往返（值 int 化）
	ws2.event_cooldown_until["c9"] = 123
	ws2.last_world_event_hours = 77
	ck(SaveIO.save_campaign(ws2, SLOT), "save_campaign 成功")
	var ld = SaveIO.load_campaign(SLOT)
	ck(ld != null, "load 非空")
	if ld != null:
		ck(ld.event_fired.has("tm2"), "event_fired 往返")
		ck(int(ld.event_timer_last.get("tm1", -1)) == 100 and typeof(ld.event_timer_last["tm1"]) == TYPE_INT, "timer_last 往返且 int 化")
		ck(int(ld.event_cooldown_until.get("c9", -1)) == 123, "cooldown_until 往返")
		ck(ld.last_world_event_hours == 77, "last_world_event_hours 往返")
	SaveIO.delete_slot(SLOT)

	WorldState.current = null
	if _fail == 0:
		print("=== 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
