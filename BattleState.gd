extends RefCounted
## BattleState：战斗模型层（纯数据 + 规则，非 Node）——解耦规划 Phase 1~3（见 docs/解耦规划.md）。
## 持有战斗领域状态（棋盘/单位/回合/视野/环境/区域/触发器/击杀账）+ 纯查询/变更方法；
## **不认识 canvas / UI / 场景树**——日志、飘字、重绘、回合编排全留宿主（Sandbox）。
## Sandbox 经同名薄访问器属性委托到这里（画布 editor.* 契约、测试直调签名零破坏）。

const Unit := preload("res://Unit.gd")
const UnitFactory := preload("res://UnitFactory.gd")
const CombatResolver := preload("res://CombatResolver.gd")
const HexGrid := preload("res://HexGrid.gd")
const TerrainDB := preload("res://TerrainDB.gd")
const WorldState := preload("res://WorldState.gd")

const DEFAULT_TERRAIN := "plain"
const DEFAULT_VARIANT := "grassland"

# —— 棋盘（地块＝战斗权威棋盘）——
var width := 15
var height := 15
var tiles := []            # tiles[row][col] = {"terrain":..,"variant":..}

# —— 单位 ——
var units := []            # 场上单位（Unit 对象列表；元素自带运行态）
var roster := []           # 可用单位池（含未布置；units ⊆ roster ∪ 地图预置）

# —— 地图原始数据（读图落入；存图/试玩透传保真）——
var _map_regions := []             # regions 原始数据：[{id,label,color,cells:[[x,y]…],kind?}]
var _map_units := []               # units 原始数据：[{proto,col,row,faction}]
var _map_triggers := []            # triggers 原始数据：[{id,label,when,do}]
var _map_terrain_overrides := {}   # 图级地形覆盖 { "terrain/variant": {move?,effects?} }
var _map_locations := []           # locations 原始数据（大地图 M7；战斗侧只透传）
var _map_environment := {}         # environment {time, weather_table:[…]}
var _map_type := "battle"          # 地图类型（overworld/battle）

# —— 区域派生（由 _map_regions 经 _setup_regions 全量重建，不入存档）——
var aggro_regions := {}      # {region_id: {Vector2i:true}}（仇恨/触发区）
var _all_region_cells := {}  # {region_id: {Vector2i:true}}（不分 kind，供触发器引用）
var _deploy_cells := {}      # 部署区格并集 {Vector2i:true}

# —— 事件 / 击杀 / 战役 ——
var _fired_triggers := {}   # 已触发 trigger id（战斗局部 once；EventEngine 经引用回写）
var _battle_kills := []     # 本战击杀记录 [{proto_id, victim_uid, faction, by_uid}]
var campaign_battle := false
var _battle_context := {}   # BattleSetup.context 透传（location_id/world_unit_uid…）

# —— 感知 / 战争迷雾（玩家侧）——
var _vis_visible := {}    # 当前可见格 {Vector2i:true}（派生：可由单位位置重算）
var _vis_seen := {}       # 曾见格 {Vector2i:true}（只增不减——唯一不可重建的历史，必存）
var omniscient := false   # 调试全知（门控 targeting/迷雾规则，属规则输入）

# —— 环境：日夜 + 天气（战斗级状态）——
var _cur_time := "day"
var _cur_weather := "clear"
var _weather_left := 0       # 当前天气剩余回合（<=0 ＝ 不自动变）
var _time_sight_mult := 1.0  # 日夜视野最终乘子（由 _cur_time 派生，随存无害——恢复时宿主仍应重挂环境）

# —— 回合（round/turn 双层）——
var round_num := 1
var turn_order := []       # 本 round 出手序列（Unit 引用）
var active_index := 0
var zoc_triggered := {}    # 本 round「拥有者→移动者」借机去重（key=instance_id 对）

# —— 阶段 / 胜负 ——
var phase := "deploy"      # deploy=布置 / battle=战斗
var battle_over := false

# ==================================================================
# 规则方法（自 Sandbox 迁入，方法体保持原样；宿主经同名薄包装委托）
# ==================================================================

# ============ 棋盘 / 地图 ============

func _new_grassland(w: int, h: int) -> void:
	width = w
	height = h
	tiles = []
	for row in height:
		var line := []
		for col in width:
			line.append({"terrain": DEFAULT_TERRAIN, "variant": DEFAULT_VARIANT})
		tiles.append(line)

# 仇恨触发区域（mode②）：从地图 regions 字段（_map_regions）构建 {region_id: {Vector2i:true}}。
func _setup_regions() -> void:
	aggro_regions = {}
	_deploy_cells = {}
	_all_region_cells = {}
	for reg in _map_regions:
		if typeof(reg) != TYPE_DICTIONARY:
			continue
		var id := str(reg.get("id", ""))
		var kind := str(reg.get("kind", "aggro"))   # 缺省＝仇恨触发区（向后兼容）
		var cells := {}
		for c in reg.get("cells", []):
			# cells 项形如 [x, y]
			if typeof(c) == TYPE_ARRAY and c.size() >= 2 and _cell_in_bounds(int(c[0]), int(c[1])):
				cells[Vector2i(int(c[0]), int(c[1]))] = true
		if id != "":
			_all_region_cells[id] = cells   # 全区域格集合（不分 kind，供触发器 when.region 引用）
		if kind == "deploy":
			# 部署区（玩家布置区）：并入 _deploy_cells（faction 暂统一按玩家）
			for cell in cells:
				_deploy_cells[cell] = true
		elif id != "":
			aggro_regions[id] = cells   # 仇恨/触发区按 id 存（敌人 ai_region 引用）

# 落子地图预置单位（_map_units → units）：出生点越界钳进界内；make_unit 已收尾 recompute+init_vitals。
func _spawn_map_units() -> void:
	for entry in _map_units:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var proto = entry.get("proto", {})
		if typeof(proto) != TYPE_DICTIONARY or proto.is_empty():
			continue
		var fac := str(entry.get("faction", proto.get("default_faction", "enemy")))
		var col := clampi(int(entry.get("col", 0)), 0, maxi(0, width - 1))
		var row := clampi(int(entry.get("row", 0)), 0, maxi(0, height - 1))
		units.append(UnitFactory.make_unit(proto, fac, col, row))

# 按 tile 的 terrain/variant 查地形定义（经 TerrainDB O(1) 查表，找不到返回 null）
func _terrain_entry(tile):
	return TerrainDB.entry_for(tile)

# 该 tile 的有效 move 块：图级覆盖 ?? 全局（合并规则单一实现在 TerrainDB.effective_move）。
func _effective_move(tile) -> Dictionary:
	return TerrainDB.effective_move(tile, _map_terrain_overrides)

func unit_at(col: int, row: int):
	for u in units:
		if u.col == col and u.row == row:
			return u
	return null

# ============ 六边形几何（一律委托 HexGrid）============

func _hex_dist(a: Vector2i, b: Vector2i) -> int:
	return HexGrid.distance(a, b)

# 两格间的连线采样（cube 插值，含端点）：LOS/寻路用。地形阻挡判定见 _has_los。
func _hex_line(a: Vector2i, b: Vector2i) -> Array:
	return HexGrid.line(a, b)

# 平顶 odd-q：从 c 沿方向 d（0–5）走一格
func _neighbor_in_dir(c: Vector2i, d: int) -> Vector2i:
	return HexGrid.neighbor_in_dir(c, d)

# 从 from 沿某方向直线走 length 格；返回“包含 target 的那条方向线”的格序列（找不到=[]）
func _line_cells(from: Vector2i, target: Vector2i, length: int) -> Array:
	return HexGrid.spoke_through(from, target, length)

func _cell_in_bounds(col: int, row: int) -> bool:
	return col >= 0 and col < width and row >= 0 and row < height

func _neighbors(col: int, row: int) -> Array:
	return HexGrid.neighbors(Vector2i(col, row))

# 把一组格按六边形几何外扩 radius 圈（仅几何、不管通行性）；返回含原格的集合
func _cells_within(cells: Dictionary, radius: int) -> Dictionary:
	return HexGrid.ring_within(cells, radius, func(v: Vector2i) -> bool: return _cell_in_bounds(v.x, v.y))

# ============ 阵营 ============

func _is_friendly(u) -> bool:
	return u != null and u.faction in ["player", "ally"]

# 敌友判定：玩家/友军 为一方，敌方/中立 为另一方；跨方=敌对
func _is_hostile(a, b) -> bool:
	if a == null or b == null:
		return false
	var friendly := ["player", "ally"]
	return (a.faction in friendly) != (b.faction in friendly)

# ============ 移动力 / 寻路 ============

# 单位进入该地块的移动消耗（tag 驱动）：-1 = 不可进入。
func _move_cost_at(col: int, row: int, unit) -> int:
	if not _cell_in_bounds(col, row):
		return -1
	var mv = _effective_move(tiles[row][col])   # 图级覆盖 ?? 全局
	return TerrainDB.move_cost(mv, unit.tags if unit != null else [])   # 通行/成本单一实现（大地图同用）

func _occupied_by_other(col: int, row: int, self_u) -> bool:
	for u in units:
		if u != self_u and u.col == col and u.row == row:
			return true
	return false

# Dijkstra：算 unit 在 budget 内可达的格 + 前驱树。返回 {best:{格:累计消耗,含起点0}, came_from:{格:前驱}}。
# 玩家移动范围、敌方 AI 走位共用。
func _dijkstra(unit, budget: int) -> Dictionary:
	var start := Vector2i(unit.col, unit.row)
	var best := {start: 0}
	var came := {}
	var open := [start]
	while not open.is_empty():
		var bi := 0
		for i in range(1, open.size()):
			if best[open[i]] < best[open[bi]]:
				bi = i
		var cur: Vector2i = open[bi]
		open.remove_at(bi)
		# ZOC：踏入敌对控制区即停（该格可达但不能从它继续外扩）；起点格除外
		if cur != start and _in_hostile_zoc(cur, unit):
			continue
		for nb in _neighbors(cur.x, cur.y):
			if not _cell_in_bounds(nb.x, nb.y):
				continue
			if _occupied_by_other(nb.x, nb.y, unit):
				continue
			var step := _move_cost_at(nb.x, nb.y, unit)
			if step < 0:
				continue
			var nc: int = best[cur] + step
			if nc > budget:
				continue
			if not best.has(nb) or nc < best[nb]:
				best[nb] = nc
				came[nb] = cur
				open.append(nb)
	return {"best": best, "came_from": came}

# 单位的「理论最远」移动 + 攻击范围（预览用）。
func _compute_ranges(unit) -> Dictionary:
	var start := Vector2i(unit.col, unit.row)
	var data := _dijkstra(unit, unit.move_allowance())
	var best: Dictionary = data["best"]
	best.erase(start)
	var reach := best
	var rng := int(unit.basic_attack().get("range", 1))
	var standable := {start: true}
	for c in reach:
		standable[c] = true
	var atk := {}
	for c in _cells_within(standable, rng):
		if not standable.has(c):
			atk[c] = true
	return {"reach": reach, "attack": atk}

# 前驱树 → 从起点到 cell 的路径（含两端）
func _path_via(came: Dictionary, cell: Vector2i) -> Array:
	var path := [cell]
	var cur := cell
	while came.has(cur):
		cur = came[cur]
		path.append(cur)
	path.reverse()
	return path

# ============ ZOC 机制（控制区 + 借机判定的模型部分）============

# 单位的 ZOC（控制区）= 周围一圈在界内的格
func _zoc_cells(unit) -> Dictionary:
	var d := {}
	for nb in _neighbors(unit.col, unit.row):
		if _cell_in_bounds(nb.x, nb.y):
			d[nb] = true
	return d

func _zoc_key(owner, mover) -> String:
	return "%d_%d" % [owner.get_instance_id(), mover.get_instance_id()]

# cell 是否落在「敌对于 mover 的某单位」的 ZOC 内（= 与某敌对单位相邻）
func _in_hostile_zoc(cell: Vector2i, mover) -> bool:
	for u in units:
		if u != mover and _is_hostile(mover, u) and _hex_dist(cell, Vector2i(u.col, u.row)) == 1:
			return true
	return false

# 取 cell 处第一个「本 round 尚未对 mover 触发过」的敌对 ZOC 拥有者（找不到=null）
func _first_zoc_owner(cell: Vector2i, mover):
	for u in units:
		if u != mover and _is_hostile(mover, u) and _hex_dist(cell, Vector2i(u.col, u.row)) == 1:
			if not zoc_triggered.has(_zoc_key(u, mover)):
				return u
	return null

# 移动范围内、属于敌方 ZOC 的格（移动模式自动标红）
func _enemy_zoc_in_range(mover, reach: Dictionary) -> Dictionary:
	var out := {}
	for u in units:
		if u == mover or not _is_hostile(mover, u):
			continue
		for nb in _neighbors(u.col, u.row):
			var c := Vector2i(nb.x, nb.y)
			if reach.has(c):
				out[c] = true
	return out

# ============ 回合（round/turn 双层）============

func _rebuild_turn_order() -> void:
	turn_order = _sorted_by_speed(units)

# 按速度（effective_stat，含修正）大→小排序；同速我方/友方优先。
func _sorted_by_speed(arr: Array) -> Array:
	var out := arr.duplicate()
	out.sort_custom(_speed_cmp)
	return out

func _speed_cmp(a, b) -> bool:
	var sa: int = a.effective_stat("speed")
	var sb: int = b.effective_stat("speed")
	if sa != sb:
		return sa > sb
	var fa := _is_friendly(a)
	var fb := _is_friendly(b)
	if fa != fb:
		return fa   # 同速：友方先
	return false

# 速度中途变化：保留已行动者与当前行动者，仅对「之后未行动」的重排。
func _resort_pending() -> void:
	if turn_order.is_empty() or active_index >= turn_order.size():
		return
	var acted := turn_order.slice(0, active_index)        # 本 round 已行动
	var active = turn_order[active_index]                  # 当前行动者（保持最前）
	var rest := turn_order.slice(active_index + 1)         # 之后未行动 → 重排
	rest = _sorted_by_speed(rest)
	var new_order := acted.duplicate()
	new_order.append(active)
	new_order.append_array(rest)
	turn_order = new_order
	# active_index 不变（= acted.size()）

# 行动顺序槽要显示的条目序列：当前回合剩余（含标记）+ 下一回合全员（按当前速度）。
func _turn_sequence() -> Array:
	var seq := []
	if turn_order.is_empty():
		return seq
	var active = active_unit()
	if active_index < turn_order.size():
		seq.append({"kind": "marker", "round": round_num})
		for i in range(active_index, turn_order.size()):
			var u = turn_order[i]
			seq.append({"kind": "unit", "round": round_num, "unit": u, "active": (u == active)})
	# 下一回合：全员按当前速度重排（尚未开始，无「当前行动者」）
	seq.append({"kind": "marker", "round": round_num + 1})
	for u in _sorted_by_speed(units):
		seq.append({"kind": "unit", "round": round_num + 1, "unit": u, "active": false})
	return seq

func active_unit():
	if active_index < 0 or active_index >= turn_order.size():
		return null
	return turn_order[active_index]

func _has_acted(u) -> bool:
	var idx := turn_order.find(u)
	return idx >= 0 and idx < active_index

func _is_active_unit(u) -> bool:
	return u == active_unit()

# ============ 视线（LOS；视野/迷雾的重算在 Phase 3 后续批迁入）============

# 该格地形是否阻挡视线（读地形 blocks_sight tag；越界＝挡）
func _tile_blocks_sight(col: int, row: int) -> bool:
	if not _cell_in_bounds(col, row):
		return true
	var e = _terrain_entry(tiles[row][col])
	return e != null and ("blocks_sight" in e.get("tags", []))

# a 能否看到 b：连线上「中间格」任一 blocks_sight 即挡。终点 b 自身的 blocks_sight 不挡。
func _has_los(a: Vector2i, b: Vector2i) -> bool:
	if a == b:
		return true
	var line := _hex_line(a, b)
	for i in range(1, line.size() - 1):   # 掐头去尾：只查中间格
		var c: Vector2i = line[i]
		if _tile_blocks_sight(c.x, c.y):
			return false
	return true

# 单位当前【实际】视野半径 ＝ round( 面板 sight〔含所有加减〕 × 日夜最终乘子 )，下限 0。
func _effective_sight(u) -> int:
	return maxi(0, int(round(u.effective_stat("sight") * _time_sight_mult)))
