extends SceneTree
## WorldSim 回归：注册表 / 开局生成（幂等·uid）/ 存档往返 / budget 速度语义 / 商路到站
## / 敌对追击→engage→战斗上下文→战胜移除 / 冷静期 / 中立不追 / 摩擦战
## / v2 计划移动（航点 route·歇脚·商路缓存·trail 表现钩·route 存档往返）。不触碰玩家 auto 档。
## 几何不硬编码：城市格/生成数量从地图与类型表动态推导（地图改版测试不陪葬）。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_worldsim.gd（退出码 0=PASS）

const WorldState := preload("res://WorldState.gd")
const WorldSim := preload("res://WorldSim.gd")
const WorldUnitDB := preload("res://WorldUnitDB.gd")
const SaveIO := preload("res://SaveIO.gd")
const BattleIO := preload("res://BattleIO.gd")
const SandboxConfig := preload("res://SandboxConfig.gd")
const HexGrid := preload("res://HexGrid.gd")
const OverworldScript := preload("res://Overworld.gd")

const SLOT := "_test_wsim"
var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _mk(ws, type_id: String, col: int, row: int, home := "") -> Dictionary:
	var u := {"uid": ws.next_uid, "type": type_id, "faction": str(WorldUnitDB.type_def(type_id).get("faction", "")),
		"col": col, "row": row, "budget": 0.0, "target_loc": "", "wait_until": 0, "calm_until": 0, "home": home}
	ws.next_uid += 1
	ws.world_units.append(u)
	return u

func _initialize() -> void:
	print("=== WorldSim v1 测试开始 ===")

	# 1) 注册表
	for want in ["caravan", "patrol", "herd", "marauders"]:
		ck(WorldUnitDB.type_def(want) != null, "类型表含 %s" % want)
	ck(WorldUnitDB.label("caravan") == "商队", "label 中文")

	# 2) 开局生成：数量/home/uid 唯一 + 幂等（期望数从类型表×地图城数动态推导）
	var ws = WorldState.start_new()
	var ow = OverworldScript.new()
	ow._save_slot = SLOT
	ow._ensure_campaign()
	ow._load_map()
	var city_cell := Vector2i(-1, -1)
	var city_id := ""
	var cities := 0
	for loc in ow._map_locations:
		if str(loc.get("type", "")) == "city":
			cities += 1
			if city_id == "":
				city_id = str(loc.get("id", ""))
				city_cell = Vector2i(int(loc.get("col", 0)), int(loc.get("row", 0)))
	ck(cities >= 1 and city_cell.x >= 0, "地图至少一座城（找到 %d）" % cities)
	WorldSim.ensure_spawned(ws, ow)
	var n0: int = ws.world_units.size()
	var expect := 0
	for t in WorldUnitDB.all_types():
		expect += int(t.get("count", 0)) + int(t.get("per_city", 0)) * cities
	ck(n0 == expect, "生成 %d 支（类型表 count+per_city×%d 城），实得 %d" % [expect, cities, n0])
	var uids := {}
	for u in ws.world_units:
		uids[int(u["uid"])] = true
	ck(uids.size() == n0, "uid 全唯一")
	WorldSim.ensure_spawned(ws, ow)
	ck(ws.world_units.size() == n0, "重复调用幂等（flags 记账）")

	# 3) 存档往返 + next_uid 自愈 + route 计划随档（JSON 读回 float，消费口 int() 兜底）
	ws.world_units[0]["route"] = [[1, 2], [2, 2]]
	ws.world_units[0]["route_kind"] = "idle"
	ck(SaveIO.save_campaign(ws, SLOT), "save 成功")
	var ld = SaveIO.load_campaign(SLOT)
	ck(ld != null and ld.world_units.size() == n0, "world_units 往返")
	var r0: Array = ld.world_units[0].get("route", [])
	ck(r0.size() == 2 and int(r0[0][0]) == 1 and int(r0[0][1]) == 2, "route 计划随档往返（int 兜底可消费）")
	ck(str(ld.world_units[0].get("route_kind", "")) == "idle", "route_kind 随档")
	var mx := 0
	for u in ld.world_units:
		mx = maxi(mx, int(u["uid"]))
	ck(ld.next_uid > mx, "next_uid 覆盖 world_units 自愈")
	SaveIO.delete_slot(SLOT)

	# 4) budget 速度语义（受控单位：兽群 hpc=4）
	ws.world_units.clear()
	ws.party_col = 0
	ws.party_row = 0
	var herd_start := WorldSim._passable_near(ow, Vector2i(12, 5))
	var herd := _mk(ws, "herd", herd_start.x, herd_start.y)
	WorldSim.tick(ws, 2, ow)   # 2h < 4h/格：攒着不动
	ck(_at(herd) == herd_start and is_equal_approx(float(herd["budget"]), 2.0), "不足一格＝攒 budget 不动")
	WorldSim.tick(ws, 2, ow)   # 累计 4h：走一步（航点计划、可通行）
	ck(HexGrid.distance(_at(herd), herd_start) <= 1, "攒够一格走一步（≤1 格）")
	ck(ow._move_cost_at(_at(herd).x, _at(herd).y) >= 0, "落点可通行")

	# 5) 商路：定向逼近目标城，全程路径缓存（v2），到站停靠 + caravan_arrive
	ws.world_units.clear()
	var car_start := WorldSim._passable_near(ow, city_cell + Vector2i(3, 0))
	var car := _mk(ws, "caravan", car_start.x, car_start.y)
	car["target_loc"] = city_id
	var arrived := false
	var saw_cached := false
	for i in 24:
		for e in WorldSim.tick(ws, 3, ow):   # 3h=商队一格
			if str(e.get("kind", "")) == "caravan_arrive":
				arrived = true
		if not arrived and str(car.get("route_kind", "")) == "trade" and not (car.get("route", []) as Array).is_empty():
			saw_cached = true
		if arrived:
			break
	ck(arrived, "商队到站（caravan_arrive）")
	ck(saw_cached or HexGrid.distance(car_start, city_cell) <= 1, "商路途中路径已缓存（route_kind=trade）")
	ck(_at(car) == city_cell and int(car["wait_until"]) > ws.clock_hours, "到站落位 + 停靠计时")

	# 6) 敌对追击 → engage + 冷静期；战胜 → 移除
	ws.world_units.clear()
	ws.party_col = city_cell.x
	ws.party_row = city_cell.y
	var mar_start := WorldSim._passable_near(ow, city_cell + Vector2i(3, 0))
	# 布景前置（地图改版时红在这里而不是「永不 engage」——诊断友好）：起点距玩家 ≤ sight 4 且寻路可达
	ck(HexGrid.distance(mar_start, city_cell) <= 4, "布景前提：游团起点距玩家 ≤ sight 4（实距 %d）" % HexGrid.distance(mar_start, city_cell))
	ck(not ow.find_path(mar_start, city_cell).is_empty(), "布景前提：游团起点→玩家寻路可达")
	var mar := _mk(ws, "marauders", mar_start.x, mar_start.y, "lair_bandit")   # 劫道者默认敌对
	var engaged := false
	for i in 6:
		for e in WorldSim.tick(ws, 2, ow):
			if str(e.get("kind", "")) == "engage_player":
				engaged = true
		if engaged:
			break
	ck(engaged, "敌对游团追上玩家（engage_player）")
	ck(int(mar["calm_until"]) > ws.clock_hours, "engage 即入冷静期")
	ck(not WorldSim.tick(ws, 2, ow).any(func(e): return str(e.get("kind", "")) == "engage_player"), "冷静期内不再 engage")
	# Overworld 表现层：engage → battle_setup 带 world_unit_uid（宿主统一入口 _advance_world）
	mar["calm_until"] = 0
	var adj := WorldSim._passable_neighbors(ow, Vector2i(int(ws.party_col), int(ws.party_row)))
	ck(not adj.is_empty(), "玩家旁有可通行邻格（布景前提）")
	if not adj.is_empty():
		mar["col"] = (adj[0] as Vector2i).x
		mar["row"] = (adj[0] as Vector2i).y
	SandboxConfig.battle_setup = null
	ow._advance_world(2)
	ck(SandboxConfig.battle_setup != null and int((SandboxConfig.battle_setup.get("context", {}) as Dictionary).get("world_unit_uid", 0)) == int(mar["uid"]), "engage → battle_setup 带 world_unit_uid")
	ck(int((SandboxConfig.battle_setup.get("context", {}) as Dictionary).get("bounty", 0)) == 40, "engage context 带类型赏金（marauders=40）")
	# 战胜回写：单位覆灭 + 讨伐赏金入账（apply_result 返回结算摘要 dict——任务线地基 §2-2）
	var gold_before := int(ws.gold)
	var summary: Dictionary = BattleIO.apply_result(ws, BattleIO.collect_result([], [], true, SandboxConfig.battle_setup["context"]))
	ck(ws.world_unit_by_uid(int(mar["uid"])) == null, "战胜 → 世界单位移除")
	ck(int(summary["bounty"]) == 40 and int(ws.gold) == gold_before + 40, "战胜 → 讨伐赏金 40 入账（apply_result 单点）")
	ck(int(summary["removed_world_unit"]) == int(mar["uid"]), "摘要带 removed_world_unit（任务战斗类目标消费口）")
	ck(bool(summary["win"]), "摘要带 win")
	SandboxConfig.battle_setup = null

	# 7) 中立不追不打：商队/兽群贴脸玩家也无 engage
	ws.world_units.clear()
	_mk(ws, "caravan", int(ws.party_col), int(ws.party_row))
	if not adj.is_empty():
		_mk(ws, "herd", (adj[0] as Vector2i).x, (adj[0] as Vector2i).y)
	ck(not WorldSim.tick(ws, 6, ow).any(func(e): return str(e.get("kind", "")) == "engage_player"), "中立单位不 engage")

	# 8) 摩擦战：巡逻队 × 游团 邻格 → 一方覆灭 + skirmish 事件
	ws.world_units.clear()
	ws.party_col = 0
	ws.party_row = ow.height - 1
	var p1 := WorldSim._passable_near(ow, city_cell + Vector2i(1, 0))
	var p1_adj := WorldSim._passable_neighbors(ow, p1)
	ck(not p1_adj.is_empty(), "摩擦战布景：p1 旁有可通行邻格")
	_mk(ws, "patrol", p1.x, p1.y, city_id)
	if not p1_adj.is_empty():
		_mk(ws, "marauders", (p1_adj[0] as Vector2i).x, (p1_adj[0] as Vector2i).y, "lair_bandit")
	var skirmished := false
	for i in 8:
		for e in WorldSim.tick(ws, 2, ow):
			if str(e.get("kind", "")) == "skirmish":
				skirmished = true
		if skirmished:
			break
	ck(skirmished, "巡逻队×游团摩擦战发生")
	ck(ws.world_units.size() == 1, "摩擦战一方覆灭（余 %d）" % ws.world_units.size())

	# 9) v2 计划移动：巡逻航点整段走 → 到航点歇脚；步步相邻；last_trails 表现钩
	ws.world_units.clear()
	ws.party_col = 0
	ws.party_row = ow.height - 1
	var guard := _mk(ws, "patrol", city_cell.x, city_cell.y, city_id)
	var walked := 0
	var paused_after_walk := false
	var adjacent_ok := true
	var trail_ok := true
	var prev := _at(guard)
	for i in 60:
		ws.clock_hours += 2   # 模拟宿主推钟（宿主序：先推钟再 tick）
		WorldSim.tick(ws, 2, ow)
		var now := _at(guard)
		if now != prev:
			walked += 1
			if HexGrid.distance(prev, now) != 1:
				adjacent_ok = false
			var tr: Array = WorldSim.last_trails.get(int(guard["uid"]), [])
			if tr.is_empty() or (tr.back() as Vector2i) != now:
				trail_ok = false
		prev = now
		if walked >= 2 and int(guard["wait_until"]) > ws.clock_hours and (guard.get("route", []) as Array).is_empty():
			paused_after_walk = true
			break
	ck(walked >= 2, "巡逻连走多步（航点计划），实走 %d 步" % walked)
	ck(paused_after_walk, "走完整段才在航点歇脚（route 清空 + wait_until 置位）")
	ck(adjacent_ok, "步步相邻（无跳格）")
	ck(trail_ok, "last_trails 表现钩：每移动步 trail 尾＝落位格")
	var at_pause := _at(guard)
	WorldSim.tick(ws, 2, ow)   # 不推钟：仍在歇脚窗口
	ck(_at(guard) == at_pause, "歇脚期间不移动")

	# 9b) 多步大 tick（扎营/客栈 8h 路径）：单 tick 连走多步，last_trails 逐格链完整（滑行队列供粮面）
	ws.world_units.clear()
	var far := WorldSim._passable_near(ow, city_cell + Vector2i(8, 0))
	var g2 := _mk(ws, "patrol", city_cell.x, city_cell.y, city_id)
	ck(ow.find_path(city_cell, far).size() >= 6, "9b 布景：城→远格路径 ≥6 节点")
	WorldSim._plan_route(g2, city_cell, far, ow, "idle")
	ws.clock_hours += 8
	WorldSim.tick(ws, 8, ow)
	var tr8: Array = WorldSim.last_trails.get(int(g2["uid"]), [])
	ck(tr8.size() == 4, "8h 单 tick 连走 4 步（hpc=2），trail 逐格链长 4（实得 %d）" % tr8.size())
	var chain_ok := true
	var prev8 := city_cell
	for c in tr8:
		if HexGrid.distance(prev8, c as Vector2i) != 1:
			chain_ok = false
		prev8 = c
	ck(chain_ok, "9b trail 逐格相邻（无覆写/跳格）")
	ck(prev8 == _at(g2), "9b trail 尾＝当前位置")

	# 9c) 跨窗结算（审查修复）：歇脚被单次大 tick 跨过 → 只记醒来后的小时，歇脚时数不回充
	ws.world_units.clear()
	var g3 := _mk(ws, "patrol", city_cell.x, city_cell.y, city_id)
	g3["wait_until"] = ws.clock_hours + 6   # 睡 6h
	g3["budget"] = 0.0
	ws.clock_hours += 8                     # 单次跨窗 8h（模拟扎营）
	WorldSim.tick(ws, 8, ow)
	ck(float(g3["budget"]) <= 2.0 + 0.001, "跨窗只记醒来后 2h（歇脚 6h 不回充；余 budget=%.1f）" % float(g3["budget"]))
	ck(HexGrid.distance(_at(g3), city_cell) <= 1, "跨窗后至多走 1 步（无爆发式补走，实距 %d）" % HexGrid.distance(_at(g3), city_cell))

	ow.free()
	WorldState.current = null
	if _fail == 0:
		print("=== 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)

func _at(u: Dictionary) -> Vector2i:
	return Vector2i(int(u["col"]), int(u["row"]))
