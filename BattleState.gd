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
var _map_rivers := []              # 线特征 v4（大地图专属语义；战斗侧只透传保真）
var _map_roads := []
var _map_bridges := []

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

# 单位当前【实际】视野半径：面板 sight × 日夜最终乘子，再叠视觉状态（夜视/无视力）——逻辑在 Unit.effective_sight。
func _effective_sight(u) -> int:
	return u.effective_sight(_time_sight_mult)

# ============ 地块效果（惰性接入攻防效能；grant→战斗效能桶映射的单一处）============

# grant.stat（人话属性名）→ 战斗效能桶。地块效果以「修正对象」语义进管线，但**不材质化持久 buff**：
# 命中/伤害结算时读所在地块 effects、评估 when、按此表折成连乘因子（docs/单位系统设计.md「森林掩蔽」🔒）。
const _TERRAIN_EFF_BUCKET := {
	"evasion": "eva_eff",   # 守方：压低敌命中（减免向）
	"accuracy": "hit_eff",  # 攻方：抬升命中（增益向）
	"attack": "atk_eff",    # 攻方：增伤（增益向）
	"defense": "def_eff",   # 守方：减伤（减免向，折进全域减伤 G）
}

# 单位所站地块的地形定义（越界/无单位＝null）。地块效果按 tile identity 取，图级 move 覆盖不改 effects。
func _terrain_at_unit(u):
	if u == null or not _cell_in_bounds(u.col, u.row):
		return null
	return _terrain_entry(tiles[u.row][u.col])

# 单位所站地块对某效能桶的连乘因子（惰性、占据者视角）。无地块/无匹配效果＝1.0（与无地形一致）。
# gain_dir=true：增益向 ×(1+percent/100)（命中/攻击效能）；false：减免向 ×(1−percent/100)（闪避/防御效能）。
# nature=debuff 取负；同桶多条连乘（与 eff_mult/eff_reduce 同律）；下限 clamp 0（防负因子翻转，同效能层🔒）。
func _terrain_eff_factor(u, bucket: String, gain_dir: bool) -> float:
	var entry = _terrain_at_unit(u)
	if entry == null:
		return 1.0
	var factor := 1.0
	for g in TerrainDB.active_grants(entry, u.tags):
		if str(g.get("layer", "效能")) != "效能":
			continue   # 只折效能层；补正层（flat/pct）不在攻防乘算链里
		if str(_TERRAIN_EFF_BUCKET.get(str(g.get("stat", "")), "")) != bucket:
			continue
		var p := float(g.get("percent", 0.0))
		if str(g.get("nature", "buff")) == "debuff":
			p = -p
		factor *= maxf(0.0, (1.0 + p / 100.0) if gain_dir else (1.0 - p / 100.0))
	return factor

# ============ 战斗结算（掷骰/伤害/异常；展示渲染在宿主 _resolve_one）============

# 命中率（%）= clamp( (命中 − 闪避) × Π命中效能, 5, 95 )，读 effective_stat。
# Π命中效能 = 攻方命中效能(增益向) × 守方闪避效能(减免向) × 攻方地块命中效能 × 守方地块闪避效能（森林掩蔽）——
# 无效能修正 / 无地块效果时 =1.0（与旧行为一致）。地块贡献惰性读取，见 _terrain_eff_factor。
func _hit_chance(attacker, target) -> int:
	var base: int = attacker.effective_stat("acc") - target.effective_stat("eva")
	var eff: float = attacker.eff_mult("hit_eff") * target.eff_reduce("eva_eff")
	eff *= _terrain_eff_factor(attacker, "hit_eff", true)    # 攻方地块命中效能（增益向）
	eff *= _terrain_eff_factor(target, "eva_eff", false)     # 守方地块闪避效能（森林掩蔽·减免向）
	return clampi(int(round(float(base) * eff)), 5, 95)

# 技能伤害补正（flat、不吃效能）：bonus = Σ(指定四维/属性) × mult。无则 0。
func _skill_bonus(attacker, skill) -> float:
	var b = skill.get("bonus", null)
	if typeof(b) != TYPE_DICTIONARY:
		return 0.0
	var sum := 0.0
	for s in b.get("stats", []):
		sum += attacker.effective_stat_f(str(s))
	return Unit.round1(sum * float(b.get("mult", 0.0)))

# 单次攻击完整结算——命中/暴击/格挡掷骰、伤害分量落血、死门条 −1+结算、异常施加。
# 只改单位状态，不写日志/飘字；返回展示所需全部数值（未命中时只有 hit/roll/hc/acc/eva）。
func _resolve_compute(attacker, target, skill) -> Dictionary:
	# 命中
	var acc := int(attacker.effective_stat("acc"))
	var eva := int(target.effective_stat("eva"))
	var hc := _hit_chance(attacker, target)   # 命中公式单一来源（见 _hit_chance）
	var roll := int(randf() * 100.0)
	var hit := roll < hc
	var r := {"hit": hit, "roll": roll, "hc": hc, "acc": acc, "eva": eva}
	if not hit:
		return r
	# 暴击（属性吃 1 位小数：crit_rate 等可为 X.5）
	var cr := float(attacker.effective_stat_f("crit_rate"))
	var crit := randf() * 100.0 < cr
	# 伤害 = 攻击 × 系数 [× 暴击] [× 效能≠100%]
	var coeff := float(skill.get("coeff", 1.0))
	var cmult := (float(attacker.effective_stat_f("crit_dmg")) / 100.0) if crit else 1.0
	var aeff: float = attacker.eff_mult("atk_eff") * _terrain_eff_factor(attacker, "atk_eff", true)   # 攻击效能桶：面板 atk_eff/100 × Π效能修正 × 攻方地块攻击效能
	var atk := float(attacker.effective_stat_f("atk"))
	var out := atk * coeff * cmult * aeff
	# 伤害补正：额外 flat 伤害，不吃效能（如撕裂/抓取的 (力量+灵巧)×0.5）
	var bonus := _skill_bonus(attacker, skill)
	if bonus > 0.0:
		out += bonus
	# 格挡 + 全域减伤 G = max(0, 1−格挡性能/100) × 防御效能因子（下限 clamp🔒）
	var br := float(target.effective_stat_f("block_rate"))
	var blocked := randf() * 100.0 < br
	var bp := float(target.effective_stat_f("block_power")) if blocked else 0.0
	# 防御效能 def_eff：base 100=中性、越高越减伤。def_factor = max(0, 2 − def_eff/100)
	var deff: float = float(target.effective_stat_f("def_eff"))
	var def_factor := maxf(0.0, 2.0 - deff / 100.0) * _terrain_eff_factor(target, "def_eff", false)   # ×守方地块防御效能（减免向，折进减伤链）
	var g := maxf(0.0, 1.0 - bp / 100.0) * def_factor
	# 分量：普攻单分量(先进甲)；穿甲 armor_pen 拆 人/甲 两分量。damage_kind 默认物理（element 已废弃 §7.2）。
	var dkind := str(skill.get("damage_kind", "physical"))
	var pen := clampf(float(skill.get("armor_pen", 0.0)), 0.0, 1.0)
	var components := []
	if pen > 0.0:
		components.append({"lane": "human", "damage_kind": dkind, "ratio": pen})
		components.append({"lane": "armor_first", "damage_kind": dkind, "ratio": 1.0 - pen})
	else:
		components.append({"lane": "armor_first", "damage_kind": dkind, "ratio": 1.0})
	# 结算落血（分量减伤链在 CombatResolver：逐分量 甲抗/人抗/固减 + 破甲溢出保留元素）
	var dres := CombatResolver.resolve(target, out, g, components)
	var hp_loss := int(round(float(dres["hp_loss"])))
	var armor_loss := int(round(float(dres["armor_loss"])))
	if armor_loss > 0:
		target.stats["armor"] = maxi(0, int(target.stats.get("armor", 0)) - armor_loss)
	if hp_loss > 0:
		target.stats["HP"] = int(target.stats.get("HP", 0)) - hp_loss
	target.last_hit_by = attacker   # 击杀归属记录点（死者收尸时读；经验+情报解锁共用）
	r["crit"] = crit
	r["cr"] = cr
	r["atk"] = atk
	r["coeff"] = coeff
	r["cmult"] = cmult
	r["aeff"] = aeff
	r["bonus"] = bonus
	r["out"] = out
	r["blocked"] = blocked
	r["br"] = br
	r["bp"] = bp
	r["def_factor"] = def_factor
	r["damage_kind"] = dkind
	r["pen"] = pen
	r["res_pct"] = float(target.effective_stat_f("res_" + CombatResolver.res_suffix(dkind)))
	r["armor_res_pct"] = float(target.effective_stat_f("armor_res_" + CombatResolver.res_suffix(dkind)))
	r["had_armor"] = int(target.stats.get("armor", 0)) > 0 or armor_loss > 0   # 展示口径：结算时有甲（含本次被打光）
	r["hp_loss"] = hp_loss
	r["armor_loss"] = armor_loss
	r["hp_after"] = int(target.stats.get("HP", 0))
	# 死门单位被命中：门条 −1（无论伤害多少，HP 恒钳 0）；−3 由外层攻击流程的 _handle_deaths 统一收尸
	if target.tags.has("deaths_door"):
		target.door_gauge -= 1
		target.stats["HP"] = 0
		r["door_gauge"] = target.door_gauge
		r["door_result"] = _door_settle_state(target)
	# 施加异常（如撕裂的流血）：基础概率 × (1 − 异常抵抗)，命中即挂效果
	r["inflict"] = _try_inflict_state(target, skill)
	return r

# 命中后尝试施加异常（流血等）：概率 × (1−异常抵抗)；成功则挂进 target.effects（同名刷新时长）。
# 返回掷骰事件 {name, base_ch, resist, ch, roll, applied}；skill 无 inflict ＝ 空 {}。
func _try_inflict_state(target, skill) -> Dictionary:
	var inf = skill.get("inflict", null)
	if typeof(inf) != TYPE_DICTIONARY:
		return {}
	var base_ch := float(inf.get("chance", 0))
	var resist := float(target.effective_stat_f("res_status"))
	var ch := base_ch * (1.0 - resist / 100.0)
	var iroll := randf() * 100.0
	var applied := iroll < ch
	if applied:
		_add_effect(target, inf)
	return {"name": str(inf.get("name", "")), "base_ch": base_ch, "resist": resist, "ch": ch, "roll": iroll, "applied": applied}

# ============ 效果 / buff↔modifier 桥 ============

# 给单位挂一个效果（同名则刷新时长/数值、不叠层）。
# **buff↔modifier 桥 🔒**：若 inf 带 mods（[{stat,op,value}]），同时往 target.modifiers 挂（source="buff:名"）。
func _add_effect(target, inf: Dictionary) -> void:
	var nm := str(inf.get("name", ""))
	var source := "buff:" + nm
	_remove_mods_by_source(target, source)   # 刷新：先摘旧的同名修正，按最新重挂
	var refreshed := false
	for e in target.effects:
		if str(e.get("name", "")) == nm:
			e["duration"] = int(inf.get("duration", e.get("duration", 0)))
			e["dot_pct_max_hp"] = float(inf.get("dot_pct_max_hp", e.get("dot_pct_max_hp", 0)))
			refreshed = true
			break
	if not refreshed:
		target.effects.append({
			"name": nm,
			"kind": str(inf.get("kind", "debuff")),
			"permanent": bool(inf.get("permanent", false)),   # 透传：死门/重伤/食物 buff 等「至战斗结束」效果用
			"duration": int(inf.get("duration", 1)),
			"dot_pct_max_hp": float(inf.get("dot_pct_max_hp", 0)),
			"tags": inf.get("tags", []),   # 效果 tag（如 bleeding）：供「按 tag 驱散/清除」用
			"source": source,              # 与其挂的修正共用，便于到期/清除时按 source 摘
		})
	var touched_four := false
	for m in inf.get("mods", []):
		if typeof(m) != TYPE_DICTIONARY:
			continue
		var st := str(m.get("stat", ""))
		target.modifiers.append({"stat": st, "op": str(m.get("op", "flat")), "value": float(m.get("value", 0)), "source": source, "nature": str(inf.get("kind", "debuff"))})
		if st in ["STR", "DEX", "INT", "STA"]:
			touched_four = true
	if touched_four:
		target.recompute_derived()   # 改了四维 → 重算派生（让减速等传导到派生属性）

# 按 source 摘掉单位的修正（buff 到期/被清除时）。若摘掉的含四维修正 → 重算派生。
func _remove_mods_by_source(u, source: String) -> void:
	if u == null or typeof(u.modifiers) != TYPE_ARRAY:
		return
	var had_four := false
	var kept := []
	for m in u.modifiers:
		if str(m.get("source", "")) == source:
			if str(m.get("stat", "")) in ["STR", "DEX", "INT", "STA"]:
				had_four = true
			continue
		kept.append(m)
	u.modifiers = kept
	if had_four:
		u.recompute_derived()

# 清空单位的效果 + 所有 buff 来源的临时修正（重开/退战/换图用）；装备/特性等常驻修正保留。
func _clear_effects_and_buffs(u) -> void:
	u.effects = []
	if typeof(u.modifiers) == TYPE_ARRAY:
		u.modifiers = u.modifiers.filter(func(m): return not str(m.get("source", "")).begins_with("buff:"))
	u.recompute_derived()

# 移除单位身上所有带某 tag 的效果 + 连带摘掉它们挂的修正；返回移除条数。
func _cleanse_effects_with_tag(u, tag: String) -> int:
	if u == null or not ("effects" in u) or typeof(u.effects) != TYPE_ARRAY:
		return 0
	var kept := []
	var removed := 0
	for e in u.effects:
		if (e.get("tags", []) as Array).has(tag):
			_remove_mods_by_source(u, str(e.get("source", "buff:" + str(e.get("name", "")))))
			removed += 1
		else:
			kept.append(e)
	u.effects = kept
	return removed

# 结算回合末效果——DoT 落血 + 非 permanent 时长递减、到期连带摘修正。
# 返回结构化事件 [{type:"dot", name, dmg, pct} | {type:"expired", name}]；不写日志。
func _apply_turn_end_effects(u) -> Array:
	var events := []
	if u == null or not ("effects" in u) or u.effects.is_empty():
		return events
	var keep := []
	for e in u.effects:
		var pct := float(e.get("dot_pct_max_hp", 0))
		if pct > 0.0:
			var d := int(round(float(u.effective_stat("HP_max")) * pct / 100.0))
			if d > 0:
				u.stats["HP"] = int(u.stats.get("HP", 0)) - d
				events.append({"type": "dot", "name": str(e.get("name", "流血")), "dmg": d, "pct": pct})
		if e.get("permanent", false):
			keep.append(e)
		else:
			var dur := int(e.get("duration", 0)) - 1
			if dur > 0:
				e["duration"] = dur
				keep.append(e)
			else:
				_remove_mods_by_source(u, str(e.get("source", "buff:" + str(e.get("name", "")))))   # 到期：连带摘掉其挂的修正
				events.append({"type": "expired", "name": str(e.get("name", ""))})
	u.effects = keep
	return events

# ============ 死门 + 收尸（需求 §1.11 🔒；日志/编排在宿主）============

# 死门资格：我方/友方全体 + 敌方精锐（elite tag，数据标记）；常规敌兵无资格＝HP 归零即死
func _door_eligible(u) -> bool:
	return _is_friendly(u) or u.tags.has("elite")

# 转入死门——HP 钳 0、条归 0；挂 tag（统一判断）+ permanent effect（闪避/防御效能 pct −50，走修正管线）。
func _enter_deaths_door_state(u) -> void:
	u.stats["HP"] = 0
	u.door_gauge = 0
	u.door_checks = 0
	u.ap = 0
	u.move_points = 0
	if not u.tags.has("deaths_door"):
		u.tags.append("deaths_door")
	_add_effect(u, {"name": "死门", "kind": "debuff", "permanent": true, "tags": ["deaths_door"],
		"mods": [{"stat": "eva", "op": "pct", "value": -50}, {"stat": "def_eff", "op": "pct", "value": -50}]})

# 门条 ±3 结算（只改状态、不移除、不写日志）。返回 ""=未触发 / "down_dead"（铁人真死）/ "down_injured"（重伤离场）/ "climb"（爬回）。
# −3＝倒下（非铁人挂 injured 重伤离场 / 铁人挂 dead 真死 🔒）；+3＝爬回（HP 保底占位 1，挂重伤 debuff 至战斗结束）。
func _door_settle_state(u) -> String:
	if u.door_gauge <= -3:
		var ironman: bool = WorldState.current != null and WorldState.current.ironman
		u.tags.append("dead" if ironman else "injured")
		u.stats["HP"] = 0
		return "down_dead" if ironman else "down_injured"
	elif u.door_gauge >= 3:
		_door_clear(u)
		u.stats["HP"] = 1   # 自爬保底占位（细则待需求 §2.3）
		_add_effect(u, {"name": "重伤", "kind": "debuff", "permanent": true, "tags": ["injured"]})   # 战斗内效果待 §2.3，先只挂名
		return "climb"
	return ""

# 清死门状态：摘 tag + 死门 effect（连带其 eva/def_eff 修正）
func _door_clear(u) -> void:
	u.tags.erase("deaths_door")
	_cleanse_effects_with_tag(u, "deaths_door")
	u.recompute_derived()

# 收尸：死门资格者转入死门、门条 −3/无资格者移出战斗（含击杀账、出手序列剔除、active 下标推进/进新 round）。
# 返回 {dead, entered_door, active_died, new_round}；日志/选中清理/天气·胜负·下一 turn 编排留宿主。
func _handle_deaths_state() -> Dictionary:
	var dead := []
	var entered_door := []
	for u in units:
		if int(u.stats.get("HP", 0)) > 0:
			continue
		if u.tags.has("deaths_door"):
			if u.door_gauge <= -3:
				dead.append(u)   # 死门倒下：离场（重伤/真死标记已由 _door_settle 挂）
			else:
				u.stats["HP"] = 0   # 门内挺着：HP 钳 0（不再负血），条数结算在命中/检定处
			continue
		if _door_eligible(u):
			_enter_deaths_door_state(u)
			entered_door.append(u)
			continue
		dead.append(u)   # 无死门资格（常规敌兵）：原路径即死
	# 击杀记录（经验结算 + 情报解锁共用一份；铺垫见 docs/情报与烹饪系统.md §3.1）
	for u in dead:
		_battle_kills.append({"proto_id": u.proto_id, "victim_uid": u.uid, "faction": u.faction,
			"by_uid": (u.last_hit_by.uid if u.last_hit_by != null else 0)})
	var res := {"dead": dead, "entered_door": entered_door, "active_died": false, "new_round": false}
	if dead.is_empty():
		return res
	var cur = active_unit()
	res["active_died"] = cur != null and cur in dead   # 当前行动者阵亡（借机可致）
	for u in dead:
		units.erase(u)
	# 从出手序列剔除死者
	turn_order = turn_order.filter(func(x): return not (x in dead))
	if res["active_died"]:
		# 行动者阵亡 → 其 turn 结束；下一个已被 filter 前移到同下标（越界则进新 round）
		if active_index >= turn_order.size():
			active_index = 0
			round_num += 1
			_rebuild_turn_order()
			zoc_triggered = {}
			res["new_round"] = true
	else:
		var idx: int = turn_order.find(cur)
		active_index = idx if idx >= 0 else clampi(active_index, 0, max(turn_order.size() - 1, 0))
	return res

# ============ 视野 / 战争迷雾（玩家侧；见 docs/感知系统.md 🔒）============

# 单个单位的可见格：以己为心、半径 sight（六边形距离）、逐格被 LOS 裁剪。
func _unit_visible_cells(u) -> Dictionary:
	var out := {}
	var here := Vector2i(u.col, u.row)
	out[here] = true
	var sight: int = _effective_sight(u)   # 含天气加减 + 日夜最终乘子（夜×0.5）
	if sight <= 0:
		return out
	for cell in _cells_within({here: true}, sight):
		if _has_los(here, cell):
			out[cell] = true
	return out

# 重算 _vis_visible（我方/友方可见格并集）、并入 _vis_seen（历史累积）。不碰渲染。
func _recompute_vision_state() -> void:
	_vis_visible = {}
	for u in units:
		if _is_friendly(u):
			for cell in _unit_visible_cells(u):
				_vis_visible[cell] = true
	for cell in _vis_visible:
		_vis_seen[cell] = true

# 某格对玩家的迷雾态：0=黑(未探索) / 1=灰(探索过·无观测) / 2=常态(可见)。全知或非战斗阶段一律常态。
func cell_fog(cell: Vector2i) -> int:
	if omniscient or phase != "battle":
		return 2
	if _vis_visible.has(cell):
		return 2
	if _vis_seen.has(cell):
		return 1
	return 0

# 玩家当前能否「看到」某格（用于 targeting：只能打可见格上的目标）
func _can_see_cell(cell: Vector2i) -> bool:
	return omniscient or phase != "battle" or _vis_visible.has(cell)

# 该单位是否被迷雾藏起（不该渲染）：战斗中、非全知、敌对且其所在格不在当前视野内。我方/友方永远可见。
func _unit_hidden_by_fog(u) -> bool:
	if omniscient or phase != "battle":
		return false
	if _is_friendly(u):
		return false
	return not _vis_visible.has(Vector2i(u.col, u.row))

# ============ AI 判定（走位/动作编排在宿主；这里只有纯判定与状态翻转）============

# 该单位此刻是否应激活仇恨（三通道），不改任何状态。
func _ai_should_aggro(unit) -> bool:
	var here := Vector2i(unit.col, unit.row)
	# ① 视野感知：敌人进入本单位视野(sight)且视线(LOS)不被地形挡（六边形战棋：只有地形挡、单位不挡）
	if unit.ai_threat:
		var sight: int = _effective_sight(unit)   # 含天气加减 + 日夜最终乘子
		for h in units:
			var hp := Vector2i(h.col, h.row)
			if _is_hostile(unit, h) and _hex_dist(here, hp) <= sight and _has_los(here, hp):
				return true
	# ② 区域触发：敌人踏进该单位挂的区域（关卡设计者指定）
	if unit.ai_region != "" and aggro_regions.has(unit.ai_region):
		var cells: Dictionary = aggro_regions[unit.ai_region]
		for h in units:
			if _is_hostile(unit, h) and cells.has(Vector2i(h.col, h.row)):
				return true
	# ③ 连锁：同组任一已激活
	if unit.ai_group != "":
		for g in units:
			if g != unit and g.ai_group == unit.ai_group and g.ai_aggroed:
				return true
	return false

# 激活仇恨——本体 + 连锁同组全部敌方；返回本次新激活的单位列表（已激活＝空）。不写日志。
func _ai_set_aggro_state(unit) -> Array:
	var newly := []
	if unit.ai_aggroed:
		return newly
	unit.ai_aggroed = true
	newly.append(unit)
	if unit.ai_group != "":
		for g in units:
			if g != unit and not _is_friendly(g) and g.ai_group == unit.ai_group and not g.ai_aggroed:
				newly.append_array(_ai_set_aggro_state(g))   # 连锁仇恨
	return newly

# 最近的敌对单位（按六边形距离）
func _ai_nearest_hostile(unit):
	var best = null
	var bd := 1 << 30
	var here := Vector2i(unit.col, unit.row)
	for u in units:
		if not _is_hostile(unit, u):
			continue
		var d := _hex_dist(here, Vector2i(u.col, u.row))
		if d < bd:
			bd = d
			best = u
	return best

# ============ 序列化（战中 suspend 地基；见 docs/解耦规划.md §3 硬前置）============
# 白名单原则：派生态不存——_vis_visible / aggro_regions·_all_region_cells·_deploy_cells（restore 重算），
# _vis_seen＝唯一不可重建的历史必存；_time_sight_mult 随存（模型自洽），重入场景时宿主仍应重挂环境叠层。
# 单位主键＝快照内「单位池下标」：uid 在沙盒/地图预置单位恒 0 且可重复，不能当战斗内主键 🔒。

# Vector2i 键集合 ↔ JSON [[x,y]]（沿用 MapIO 的 region cells 约定）
static func cells_to_json(cells: Dictionary) -> Array:
	var out := []
	for c in cells:
		out.append([c.x, c.y])
	return out

static func cells_from_json(arr) -> Dictionary:
	var out := {}
	if typeof(arr) != TYPE_ARRAY:
		return out
	for c in arr:
		if typeof(c) == TYPE_ARRAY and c.size() >= 2:
			out[Vector2i(int(c[0]), int(c[1]))] = true
	return out

# 全量快照 → 纯 JSON 字典（可直接 JSON.stringify 落盘）。
func to_dict() -> Dictionary:
	# 单位池 = roster ∪ units（地图预置敌人不在 roster）；顺序即池下标
	var pool := []
	for u in roster:
		pool.append(u)
	for u in units:
		if not (u in pool):
			pool.append(u)
	var idx := {}   # Unit 对象 → 池下标
	for i in pool.size():
		idx[pool[i]] = i
	var snaps := []
	var last_hit := []
	for u in pool:
		snaps.append(UnitFactory.unit_to_battle_snapshot(u))
		last_hit.append(idx.get(u.last_hit_by, -1))   # 攻击者已离场→-1（uid=0 的归属本就不计，语义无损）
	# zoc_triggered：运行时 key=instance_id 对 → 池下标对（映射不到的死者残留键丢弃——round 末本就清空）
	var by_iid := {}
	for u in pool:
		by_iid[u.get_instance_id()] = idx[u]
	var zoc := []
	for k in zoc_triggered:
		var parts: PackedStringArray = str(k).split("_")
		if parts.size() == 2 and by_iid.has(int(parts[0])) and by_iid.has(int(parts[1])):
			zoc.append([by_iid[int(parts[0])], by_iid[int(parts[1])]])
	return {
		"battle_v": 1,
		"width": width, "height": height, "tiles": tiles,
		"map_regions": _map_regions, "map_units": _map_units, "map_triggers": _map_triggers,
		"map_terrain_overrides": _map_terrain_overrides, "map_locations": _map_locations,
		"map_environment": _map_environment, "map_type": _map_type,
		"map_rivers": _map_rivers, "map_roads": _map_roads, "map_bridges": _map_bridges,
		"unit_pool": snaps, "last_hit_by": last_hit,
		"units": units.map(func(u): return idx[u]),
		"roster": roster.map(func(u): return idx[u]),
		"turn_order": turn_order.map(func(u): return idx[u]),
		"active_index": active_index, "round_num": round_num,
		"zoc_triggered": zoc,
		"fired_triggers": _fired_triggers.duplicate(),
		"battle_kills": _battle_kills.duplicate(true),
		"campaign_battle": campaign_battle, "battle_context": _battle_context.duplicate(true),
		"phase": phase, "battle_over": battle_over,
		"cur_time": _cur_time, "cur_weather": _cur_weather, "weather_left": _weather_left,
		"time_sight_mult": _time_sight_mult,
		"vis_seen": cells_to_json(_vis_seen),
		"omniscient": omniscient,
	}

# 从 to_dict 快照复原（含经 JSON 落盘往返：数值一律 int()/str()/bool() 钳制）。
# 复原绕开 make_unit/init_vitals/learn_skill 的运行态重置（UnitFactory.unit_from_battle_snapshot 全量覆写 🔒）。
# ⚠️ 装备实例本体不在快照内：战役域随档已存；纯沙盒 _transient 不落盘（沙盒 suspend 需另带实例库，可裁剪）。
func restore(d: Dictionary) -> bool:
	if int(d.get("battle_v", 0)) != 1:
		return false
	width = int(d.get("width", 15))
	height = int(d.get("height", 15))
	tiles = d.get("tiles", [])
	_map_regions = d.get("map_regions", [])
	_map_units = d.get("map_units", [])
	_map_triggers = d.get("map_triggers", [])
	_map_terrain_overrides = d.get("map_terrain_overrides", {})
	_map_locations = d.get("map_locations", [])
	_map_environment = d.get("map_environment", {})
	_map_type = str(d.get("map_type", "battle"))
	_map_rivers = d.get("map_rivers", [])
	_map_roads = d.get("map_roads", [])
	_map_bridges = d.get("map_bridges", [])
	var pool := []
	for s in d.get("unit_pool", []):
		pool.append(UnitFactory.unit_from_battle_snapshot(s))
	var lh: Array = d.get("last_hit_by", [])
	for i in pool.size():
		var j: int = int(lh[i]) if i < lh.size() else -1
		pool[i].last_hit_by = pool[j] if j >= 0 and j < pool.size() else null
	units = []
	for i in d.get("units", []):
		units.append(pool[int(i)])
	roster = []
	for i in d.get("roster", []):
		roster.append(pool[int(i)])
	turn_order = []
	for i in d.get("turn_order", []):
		turn_order.append(pool[int(i)])
	active_index = int(d.get("active_index", 0))
	round_num = int(d.get("round_num", 1))
	zoc_triggered = {}
	for pair in d.get("zoc_triggered", []):
		if typeof(pair) == TYPE_ARRAY and pair.size() >= 2:
			var a := int(pair[0])
			var b := int(pair[1])
			if a >= 0 and a < pool.size() and b >= 0 and b < pool.size():
				zoc_triggered[_zoc_key(pool[a], pool[b])] = true   # 用复原对象的新 instance_id 重铸键
	_fired_triggers = {}
	for k in d.get("fired_triggers", {}):
		_fired_triggers[str(k)] = true
	_battle_kills = d.get("battle_kills", []) if typeof(d.get("battle_kills", [])) == TYPE_ARRAY else []
	campaign_battle = bool(d.get("campaign_battle", false))
	_battle_context = d.get("battle_context", {}) if typeof(d.get("battle_context", {})) == TYPE_DICTIONARY else {}
	phase = str(d.get("phase", "deploy"))
	battle_over = bool(d.get("battle_over", false))
	_cur_time = str(d.get("cur_time", "day"))
	_cur_weather = str(d.get("cur_weather", "clear"))
	_weather_left = int(d.get("weather_left", 0))
	_time_sight_mult = float(d.get("time_sight_mult", 1.0))
	_vis_seen = cells_from_json(d.get("vis_seen", []))
	omniscient = bool(d.get("omniscient", false))
	_setup_regions()            # 区域派生（aggro/deploy/all_region_cells）＝重算不存
	_recompute_vision_state()   # _vis_visible＝重算不存（visible 并回 seen，幂等）
	return true

# ============ Targeting ============

# 点击格 → 命中单位列表：直线 AoE 取该方向直线上的单位（友伤按 friendly_fire），否则取该格的敌对单位
func _attack_targets(attacker, cell: Vector2i, skill) -> Array:
	var out := []
	var aoe = skill.get("aoe", null)
	if typeof(aoe) == TYPE_DICTIONARY and aoe.get("shape", "") == "line":
		var cells = _line_cells(Vector2i(attacker.col, attacker.row), cell, int(aoe.get("length", 1)))
		var ff = bool(aoe.get("friendly_fire", false))
		for u in units:
			var p := Vector2i(u.col, u.row)
			if p in cells and (ff or _is_hostile(attacker, u)):
				out.append(u)
	else:
		var t = unit_at(cell.x, cell.y)
		# 只能打「看得到的」：目标在当前视野内(非迷雾) + 攻方到目标有视线
		if t != null and _is_hostile(attacker, t) \
			and _can_see_cell(cell) and _has_los(Vector2i(attacker.col, attacker.row), cell):
			out.append(t)
	return out
