extends RefCounted
## 大地图动态单位模拟器（🟡 v1 框架；DB 范式：preload + static，无 class_name）。设计 → docs/模块_大地图_动态单位.md。
## 核心语义 🔒对齐：**玩家移动＝世界回合**——时间只随玩家活动流逝（M2），本模块只在 WorldClock 推进后被喂小时数；
## 玩家不动，世界单位不动。每单位按 hours_per_cell 折算步数（budget 累积制，跨 tick 不丢零头）。
## 职责：① ensure_spawned＝按类型生成规则落初始单位（进 ws.world_units，随档）
##      ② tick(ws, hours, world)＝逐单位推进（trade_route/patrol/wander/hunt 四行为）+ 交互判定，
##         返回事件列表交宿主表现（engage_player=追上玩家→战斗 / skirmish=单位间摩擦战 / caravan_arrive）。
## world＝宿主鸭子接口（Overworld）：find_path(a,b) / _move_cost_at(c,r) / _map_locations / width/height
## + 可选 _move_cost_between(fc,fr,c,r)（边感知通行：河阻断/桥豁免——游荡邻格判定优先用它，缺省退格通行）。
## 本模块不认识场景节点，headless new() 的 Overworld 即可测。
## 实例形（纯 JSON 兼容 dict，随档）：{uid,type,faction,col,row,budget,target_loc,wait_until,calm_until}。

const WorldUnitDB := preload("res://WorldUnitDB.gd")
const FactionDB := preload("res://FactionDB.gd")
const HexGrid := preload("res://HexGrid.gd")

const MAX_STEPS_PER_TICK := 12   # 单 tick 步数上限（长休整一次喂 8h+ 时防病态循环）
const CALM_HOURS := 12           # 交战后的冷静期（占位）：战败/弃战归来不被原地连环追击

# ============ 生成（开局一次；重生成/刷新规则＝待定，见设计文档）============

# 按类型生成规则落初始单位。幂等：flags.world_units_seeded 已置则跳过。
static func ensure_spawned(ws, world) -> void:
	if ws == null or bool(ws.flags.get("world_units_seeded", false)):
		return
	ws.flags["world_units_seeded"] = true
	for t in WorldUnitDB.all_types():
		var tid := str(t["id"])
		# per_city：每座城一支（home=城）
		if int(t.get("per_city", 0)) > 0:
			for loc in world._map_locations:
				if str(loc.get("type", "")) == "city":
					for i in int(t["per_city"]):
						_spawn(ws, world, tid, t, Vector2i(int(loc.get("col", 0)), int(loc.get("row", 0))), str(loc.get("id", "")))
			continue
		# home：固定巢穴附近
		var home_id := str(t.get("home", ""))
		var anchor := _loc_cell(world, home_id)
		for i in int(t.get("count", 0)):
			var at := anchor if anchor.x >= 0 else _random_passable(world)
			_spawn(ws, world, tid, t, at, home_id)

static func _spawn(ws, world, tid: String, t: Dictionary, near: Vector2i, home_id: String) -> void:
	var cell := _passable_near(world, near)
	if cell.x < 0:
		return
	cell = _unoccupied_near(ws, world, cell)   # 同锚点多支不叠格（确定性 BFS 会撞同一格）
	ws.world_units.append({
		"uid": ws.next_uid, "type": tid, "faction": str(t.get("faction", "")),
		"col": cell.x, "row": cell.y, "budget": 0.0,
		"target_loc": "", "wait_until": 0, "calm_until": 0, "home": home_id,
	})
	ws.next_uid += 1

# ============ 世界回合（宿主在每次推进时钟后调用）============

# 推进全部单位并判交互。返回事件（宿主表现层消费）：
#   {kind:"engage_player", unit}        —— 敌对单位追上玩家（同格/邻格）；本 tick 至多一起
#   {kind:"skirmish", hunter, prey, prey_died}  —— 巡逻队×猎物摩擦战
#   {kind:"caravan_arrive", unit, loc_id}       —— 商队到站（表现可选）
static func tick(ws, hours: int, world) -> Array:
	var events := []
	if ws == null or hours <= 0:
		return events
	for u in ws.world_units.duplicate():   # 遍历副本：摩擦战会移除单位
		if not ws.world_units.has(u):
			continue   # 已被本 tick 的摩擦战移除
		var t = WorldUnitDB.type_def(str(u.get("type", "")))
		if t == null:
			push_warning("WorldSim：档内单位类型「%s」未登记，跳过" % str(u.get("type", "")))
			continue
		if int(u.get("wait_until", 0)) > ws.clock_hours:
			u["budget"] = 0.0   # 停靠中不攒步（醒来不补走）
			continue
		u["budget"] = float(u.get("budget", 0.0)) + hours
		var hpc := maxf(1.0, float(t.get("hours_per_cell", 2)))
		var steps := 0
		while u["budget"] >= hpc and steps < MAX_STEPS_PER_TICK:
			u["budget"] -= hpc
			steps += 1
			_step(ws, u, t, world, events)
			if _check_engage_player(ws, u, t, world, events):
				break   # 追上玩家：本单位停下（事件交宿主开战）
			if not ws.world_units.has(u):
				break   # 摩擦战里输了
			if int(u.get("wait_until", 0)) > ws.clock_hours:
				break   # 本步到站停靠
		if _has_engage(events):
			break   # 一次只打一场：其余单位本 tick 不再动（下次推进继续，budget 不丢）
	return events

static func _has_engage(events: Array) -> bool:
	for e in events:
		if str(e.get("kind", "")) == "engage_player":
			return true
	return false

# ============ 行为（一步）============

static func _step(ws, u: Dictionary, t: Dictionary, world, events: Array) -> void:
	match str(t.get("behavior", "wander")):
		"trade_route":
			_step_trade(ws, u, t, world, events)
		"patrol":
			_step_patrol(ws, u, t, world)
		"hunt":
			_step_hunt(ws, u, t, world)
		_:
			_step_wander(u, t, world)
	# 巡逻类：落位后判猎物摩擦战（同格/边可跨的邻格）
	if (t.get("hunts", []) as Array).size() > 0:
		_check_skirmish(ws, u, t, world, events)

# 商队：无目标 → 随机挑一个城/村；有目标 → 沿最短路走一步；到站 → 停靠 rest_hours 再换目标
static func _step_trade(ws, u: Dictionary, t: Dictionary, world, events: Array) -> void:
	var cur := _cell(u)
	var tgt_id := str(u.get("target_loc", ""))
	if tgt_id == "":
		tgt_id = _pick_settlement(world, cur)
		u["target_loc"] = tgt_id
	var tgt := _loc_cell(world, tgt_id)
	if tgt.x < 0:
		_step_wander(u, t, world)   # 目标地点不存在（地图改版）：游荡兜底
		u["target_loc"] = ""
		return
	if cur == tgt:
		u["wait_until"] = ws.clock_hours + int(t.get("rest_hours", 6))
		u["target_loc"] = ""
		events.append({"kind": "caravan_arrive", "unit": u, "loc_id": tgt_id})
		return
	_step_along_path(u, cur, tgt, world)

# 巡逻队：视野内有猎物（hunts 派系单位 / 敌对玩家）→ 追；否则在 home 半径内游荡
static func _step_patrol(ws, u: Dictionary, t: Dictionary, world) -> void:
	var cur := _cell(u)
	var sight := int(t.get("sight", 3))
	var prey = _nearest_prey(ws, u, t, sight)
	if prey != null:
		_step_along_path(u, cur, _cell(prey), world)
		return
	if FactionDB.hostile(ws, str(u.get("faction", ""))) and HexGrid.distance(cur, _party_cell(ws)) <= sight \
			and ws.clock_hours >= int(u.get("calm_until", 0)):
		_step_along_path(u, cur, _party_cell(ws), world)
		return
	_step_wander_near_home(u, t, world)

# 游团：己方派系对玩家敌对且玩家进视野 → 追击；否则绕巢游荡
static func _step_hunt(ws, u: Dictionary, t: Dictionary, world) -> void:
	var cur := _cell(u)
	if FactionDB.hostile(ws, str(u.get("faction", ""))) \
			and HexGrid.distance(cur, _party_cell(ws)) <= int(t.get("sight", 4)) \
			and ws.clock_hours >= int(u.get("calm_until", 0)):
		_step_along_path(u, cur, _party_cell(ws), world)
		return
	_step_wander_near_home(u, t, world)

# 随机游荡一步（可通行邻格；无处可去＝原地）
static func _step_wander(u: Dictionary, _t: Dictionary, world) -> void:
	var opts := _passable_neighbors(world, _cell(u))
	if not opts.is_empty():
		var pick: Vector2i = opts[randi() % opts.size()]
		u["col"] = pick.x
		u["row"] = pick.y

# 绕 home 游荡：越出活动半径 → 往回走；否则随机走不越界的邻格
static func _step_wander_near_home(u: Dictionary, t: Dictionary, world) -> void:
	var cur := _cell(u)
	var home := _loc_cell(world, str(u.get("home", "")))
	var radius := int(t.get("radius", 4))
	if home.x >= 0 and HexGrid.distance(cur, home) > radius:
		_step_along_path(u, cur, home, world)
		return
	var opts := []
	for nb in _passable_neighbors(world, cur):
		if home.x < 0 or HexGrid.distance(nb, home) <= radius:
			opts.append(nb)
	if not opts.is_empty():
		var pick: Vector2i = opts[randi() % opts.size()]
		u["col"] = pick.x
		u["row"] = pick.y

# 沿最短路走一步（不可达＝原地）
static func _step_along_path(u: Dictionary, from: Vector2i, to: Vector2i, world) -> void:
	if from == to:
		return
	var path: Array = world.find_path(from, to)
	if path.size() >= 2:
		u["col"] = path[1].x
		u["row"] = path[1].y

# ============ 交互判定 ============

# 边感知相邻：几何相邻 + 该边可跨（河阻断/桥豁免——与移动同源）。宿主未实现 _move_cost_between 时退回纯几何相邻。
# 交战/摩擦战都用它，杜绝「隔着过不去的河 engage/结算」（与 find_path/_travel 的河屏障语义一致）。
static func _reachable_adjacent(world, a: Vector2i, b: Vector2i) -> bool:
	if a == b:
		return true
	if HexGrid.distance(a, b) != 1:
		return false
	if world != null and world.has_method("_move_cost_between"):
		return world._move_cost_between(a.x, a.y, b.x, b.y) >= 0
	return true

# 敌对单位追上玩家（同格/边可跨的邻格）→ engage 事件 + 冷静期（防战败归来原地连环追击）
static func _check_engage_player(ws, u: Dictionary, _t: Dictionary, world, events: Array) -> bool:
	if not FactionDB.hostile(ws, str(u.get("faction", ""))):
		return false
	if ws.clock_hours < int(u.get("calm_until", 0)):
		return false
	if not _reachable_adjacent(world, _cell(u), _party_cell(ws)):
		return false   # 隔着无桥的河够不到玩家：不硬拽进战斗（与移动侧河屏障一致）
	u["calm_until"] = ws.clock_hours + CALM_HOURS
	events.append({"kind": "engage_player", "unit": u})
	return true

# 摩擦战：hunts 派系的单位在同格/边可跨的邻格 → d4+power 高者胜、输家移除（平＝猎手胜）。抽象结算，不进战斗场景。
static func _check_skirmish(ws, u: Dictionary, t: Dictionary, world, events: Array) -> void:
	var hunts: Array = t.get("hunts", [])
	for other in ws.world_units.duplicate():
		if other == u or not hunts.has(str(other.get("faction", ""))):
			continue
		if not _reachable_adjacent(world, _cell(u), _cell(other)):
			continue   # 隔着无桥的河：不能隔河「击溃」对岸单位
		var ot = WorldUnitDB.type_def(str(other.get("type", "")))
		var atk := int(t.get("power", 1)) + randi() % 4
		var def := (int(ot.get("power", 1)) if ot != null else 1) + randi() % 4
		var prey_died := atk >= def
		if prey_died:
			ws.world_units.erase(other)
		else:
			ws.world_units.erase(u)
		events.append({"kind": "skirmish", "hunter": u, "prey": other, "prey_died": prey_died})
		return   # 一步至多一场

# ============ 小工具 ============

static func _cell(u: Dictionary) -> Vector2i:
	return Vector2i(int(u.get("col", 0)), int(u.get("row", 0)))

static func _party_cell(ws) -> Vector2i:
	return Vector2i(int(ws.party_col), int(ws.party_row))

# 视野内最近的猎物单位（hunts 派系）；无 → null
static func _nearest_prey(ws, u: Dictionary, t: Dictionary, sight: int):
	var hunts: Array = t.get("hunts", [])
	var best = null
	var best_d := sight + 1
	for other in ws.world_units:
		if other == u or not hunts.has(str(other.get("faction", ""))):
			continue
		var d := HexGrid.distance(_cell(u), _cell(other))
		if d < best_d:
			best_d = d
			best = other
	return best

static func _loc_cell(world, loc_id: String) -> Vector2i:
	if loc_id != "":
		for loc in world._map_locations:
			if str(loc.get("id", "")) == loc_id:
				return Vector2i(int(loc.get("col", -1)), int(loc.get("row", -1)))
	return Vector2i(-1, -1)

# 随机挑一个服务型地点（城/村）作商路目标；排除当前所在格的地点
static func _pick_settlement(world, cur: Vector2i) -> String:
	var opts := []
	for loc in world._map_locations:
		if str(loc.get("type", "")) in ["city", "village"] and Vector2i(int(loc.get("col", -1)), int(loc.get("row", -1))) != cur:
			opts.append(str(loc.get("id", "")))
	return opts[randi() % opts.size()] if not opts.is_empty() else ""

# 游荡可走邻格：优先跨边成本（河阻断/桥豁免，宿主实现 _move_cost_between 才有边语义；
# 定向移动走 world.find_path 已天然吃边）——否则退回纯格通行（简化宿主/旧契约兼容）。
static func _passable_neighbors(world, cell: Vector2i) -> Array:
	var out := []
	var edge_aware: bool = world.has_method("_move_cost_between")
	for nb in HexGrid.neighbors(cell):
		var ok: bool = world._move_cost_between(cell.x, cell.y, nb.x, nb.y) >= 0 if edge_aware \
			else world._move_cost_at(nb.x, nb.y) >= 0
		if ok:
			out.append(nb)
	return out

# 锚点起 BFS 找最近可通行格（锚点本身可走＝锚点）；全图不可走返回 (-1,-1)
static func _passable_near(world, anchor: Vector2i) -> Vector2i:
	if anchor.x >= 0 and world._move_cost_at(anchor.x, anchor.y) >= 0:
		return anchor
	var seen := {anchor: true}
	var queue := [anchor]
	while not queue.is_empty():
		var cur: Vector2i = queue.pop_front()
		for nb in HexGrid.neighbors(cur):
			if seen.has(nb) or nb.x < 0 or nb.y < 0 or nb.x >= world.width or nb.y >= world.height:
				continue
			seen[nb] = true
			if world._move_cost_at(nb.x, nb.y) >= 0:
				return nb
			queue.append(nb)
	return Vector2i(-1, -1)

# 从 cell 起 BFS 找最近「可通行且无其他世界单位」的格（cell 自身空闲＝原地）
static func _unoccupied_near(ws, world, cell: Vector2i) -> Vector2i:
	if not _occupied(ws, cell):
		return cell
	var seen := {cell: true}
	var queue := [cell]
	while not queue.is_empty():
		var cur: Vector2i = queue.pop_front()
		for nb in HexGrid.neighbors(cur):
			if seen.has(nb) or nb.x < 0 or nb.y < 0 or nb.x >= world.width or nb.y >= world.height:
				continue
			seen[nb] = true
			if world._move_cost_at(nb.x, nb.y) < 0:
				continue
			if not _occupied(ws, nb):
				return nb
			queue.append(nb)
	return cell   # 全占（病态）：容忍叠格

static func _occupied(ws, cell: Vector2i) -> bool:
	for u in ws.world_units:
		if _cell(u) == cell:
			return true
	return false

static func _random_passable(world) -> Vector2i:
	for i in 200:
		var c := Vector2i(randi() % int(world.width), randi() % int(world.height))
		if world._move_cost_at(c.x, c.y) >= 0:
			return c
	return _passable_near(world, Vector2i(0, 0))
