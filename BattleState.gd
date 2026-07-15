extends RefCounted
## BattleState：战斗模型层（纯数据 + 规则，非 Node）——2026-07-02 解耦 Phase 1~3（架构见 docs/架构.md「战斗侧」）。
## 持有战斗领域状态（棋盘/单位/回合/视野/环境/区域/触发器/击杀账）+ 纯查询/变更方法；
## **不认识 canvas / UI / 场景树**——日志、飘字、重绘、回合编排全留宿主（Sandbox）。
## Sandbox 经同名薄访问器属性委托到这里（画布 editor.* 契约、测试直调签名零破坏）。

const Unit := preload("res://Unit.gd")
const UnitFactory := preload("res://UnitFactory.gd")
const CombatResolver := preload("res://CombatResolver.gd")
const HexGrid := preload("res://HexGrid.gd")
const TerrainDB := preload("res://TerrainDB.gd")
const WorldState := preload("res://WorldState.gd")
const EffectDB := preload("res://EffectDB.gd")
const SkillDB := preload("res://SkillDB.gd")   # 技能施放（apply_skill：def/skill_ap_cost/resolve_num）
const ProfDB := preload("res://ProfDB.gd")   # 技能（熟练度域）注册表——战斗涨值挂钩用（🔒 模块_属性成长_设计.md §2.4）
const ItemInstances := preload("res://ItemInstances.gd")   # 副手惩罚盾豁免查装备（§7.1 阶段3b）
const MinHeap := preload("res://MinHeap.gd") # 寻路优先队列（_dijkstra；与 Overworld.find_path 共用实现）

const DEFAULT_TERRAIN := "plain"
const DEFAULT_VARIANT := "grassland"

# 战斗掷骰统一源（技改 §1-1）：全部判定骰走 rng（命中/暴击/格挡/施加/豁免/士气）——
# 测试注入定序（s.rng.seed = X）＝逐骰确定化；默认构造即随机（游戏行为不变）。回放/录像的地基。
var rng := RandomNumberGenerator.new()

func _init() -> void:
	rng.randomize()

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
var ironman := false        # 开战捕获（技改 §1-10）：模型层不读全局 WorldState.current——纯度+死门测试免布景；随快照

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

# 友方立场单一源（技改 §1-9）：三处消费（下两函数 + Sandbox 悬停条），convert 转换内容轮前收口；
# const 亦免去热路径（Dijkstra/ZOC/士气循环里的 _is_hostile）每调分配临时数组。
const FRIENDLY_STANCES := ["player", "ally"]

func _is_friendly(u) -> bool:
	return u != null and u.faction in FRIENDLY_STANCES

# 敌友判定：玩家/友军 为一方，敌方/中立 为另一方；跨方=敌对
func _is_hostile(a, b) -> bool:
	if a == null or b == null:
		return false
	return (a.faction in FRIENDLY_STANCES) != (b.faction in FRIENDLY_STANCES)

# ============ 移动力 / 寻路 ============

# 单位脚下（任意格）地块的 tags——种族条件移动力（move_overrides when_tile_tag）等地形判据用；越界=[]。
func _tile_tags_at(col: int, row: int) -> Array:
	if not _cell_in_bounds(col, row):
		return []
	var e = TerrainDB.entry_for(tiles[row][col])
	return e.get("tags", []) if e != null else []

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
# 玩家移动范围、敌方 AI 走位共用。性能（规模化 2026-07-07）：open＝二叉堆（原线性扫描 O(V²)）；
# 占位格/敌 ZOC 预计算成集合（原每邻居/每 pop 都 O(单位数) 重扫）。
func _dijkstra(unit, budget: int) -> Dictionary:
	var start := Vector2i(unit.col, unit.row)
	var best := {start: 0}
	var came := {}
	var occupied := {}
	var zoc := {}
	for u in units:
		if u == unit:
			continue
		occupied[Vector2i(u.col, u.row)] = true
		if _is_hostile(unit, u):
			for nb in _neighbors(u.col, u.row):
				zoc[nb] = true
	var open = MinHeap.new()
	open.push(0, start)
	while not open.is_empty():
		var e: Array = open.pop()
		var cur: Vector2i = e[1]
		if int(e[0]) > int(best.get(cur, -1)):
			continue   # 懒删除：该格已有更优成本，此堆项过期
		# ZOC：踏入敌对控制区即停（该格可达但不能从它继续外扩）；起点格除外
		if cur != start and zoc.has(cur):
			continue
		for nb in _neighbors(cur.x, cur.y):
			if not _cell_in_bounds(nb.x, nb.y):
				continue
			if occupied.has(nb):
				continue
			var step := _move_cost_at(nb.x, nb.y, unit)
			if step < 0:
				continue
			var nc: int = int(best[cur]) + step
			if nc > budget:
				continue
			if not best.has(nb) or nc < int(best[nb]):
				best[nb] = nc
				came[nb] = cur
				open.push(nc, nb)
	return {"best": best, "came_from": came}

# 单位的「理论最远」移动 + 攻击范围（预览用）。
func _compute_ranges(unit) -> Dictionary:
	var start := Vector2i(unit.col, unit.row)
	var data := _dijkstra(unit, unit.move_allowance(_tile_tags_at(unit.col, unit.row)))
	var best: Dictionary = data["best"]
	best.erase(start)
	var reach := best
	var rng := SkillDB.skill_reach(unit.basic_attack())   # 形状掩码优先、range 兜底（决策30 粗口径）
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

# round 轮转（唯一实现处；调用方＝宿主 end_turn 走完一轮 / _handle_deaths_state 行动者阵亡越界）：
# round_end 效果 tick → 序列重排 + 借机去重清空。宿主侧的天气计时等表现层 tick 不在此（模型不管表现）。
# 🔒 §2.2 round 过渡序锁定：到期递减+连锁施加 **先于** _rebuild_turn_order——
# 速度类 buff 在 round_end 到期后不再污染新 round 排序。返回 tick 事件（带 who），宿主渲染。
func _wrap_round() -> Array:
	var events := _apply_round_end_effects()
	active_index = 0
	round_num += 1
	_rebuild_turn_order()
	zoc_triggered = {}
	return events

# 大回合末对称 tick（§2.2 第三时点）：只递减/到期 expire_timing=="round_end" 的效果
# （集中攻势层/鼓舞倒计时族）。不结算 DoT/HoT（恒 turn_end）、不掷豁免（恒 turn_start）。
func _apply_round_end_effects() -> Array:
	var events := []
	for u in units:
		if u == null or not ("effects" in u) or u.effects.is_empty():
			continue
		var keep := []
		var chains := []
		var uev := []
		for e in u.effects:
			if e.get("permanent", false) or str(e.get("expire_timing", "turn_end")) != "round_end":
				keep.append(e)
			else:
				_countdown_and_expire(u, e, keep, uev, chains)
		u.effects = keep
		_apply_expire_chains(u, chains, uev)
		for ev in uev:
			ev["who"] = u   # round tick 跨单位，事件补归属供宿主 _cname
		events.append_array(uev)
	return events

# 按速度（effective_stat，含修正）大→小排序；同速我方/友方优先。
func _sorted_by_speed(arr: Array) -> Array:
	var out := arr.duplicate()
	out.sort_custom(_speed_cmp)
	return out

func _speed_cmp(a, b) -> bool:
	var sa: int = a.initiative()   # 战斗速度＝speed 面板＋灵活（🔒 §10.6）
	var sb: int = b.initiative()
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
# 命中/伤害结算时读所在地块 effects、评估 when、按此表折成连乘因子（docs/模块_战斗_设计.md「森林掩蔽」🔒）。
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

# 地块 tick（回合末结算，占据者视角）：读所在地块 tick 类效果（grant.layer=="tick"）、按 when 过滤 tag，
# 结算回血(kind:heal，钳 HP_max)/掉血(kind:damage，无视护甲直扣)——与 HoT/DoT 同律。amount＝点数。
# 返回结构化事件供宿主记日志/判死：[{type:"terrain_heal", name, heal} | {type:"terrain_damage", name, dmg}]。
# 不写日志、不判死（宿主 Sandbox._tick_turn_end_effects 与 DoT 同点收口）。
func _apply_terrain_ticks(u) -> Array:
	var events := []
	if u == null:
		return events
	var entry = _terrain_at_unit(u)
	if entry == null:
		return events
	for ef in TerrainDB.active_effects(entry, u.tags):
		var g = ef.get("grant", null)
		if typeof(g) != TYPE_DICTIONARY or str(g.get("layer", "")) != "tick":
			continue
		var amt := int(round(float(g.get("amount", 0))))
		if amt <= 0:
			continue
		var nm := str(ef.get("name", "地块"))
		match str(g.get("kind", "")):
			"heal":
				var hpmax := int(u.effective_stat("HP_max"))
				var cur := int(u.stats.get("HP", 0))
				var newhp := mini(hpmax, cur + amt)
				if newhp > cur:
					u.stats["HP"] = newhp
					events.append({"type": "terrain_heal", "name": nm, "heal": newhp - cur})
			"damage":
				u.stats["HP"] = int(u.stats.get("HP", 0)) - amt
				events.append({"type": "terrain_damage", "name": nm, "dmg": amt})
	return events

# ============ 战斗结算（掷骰/伤害/异常；展示渲染在宿主 _resolve_one）============

# 命中率（%）= clamp( (技能基准命中+武器命中+技巧 − 闪避−灵活) × Π命中效能, 5, 95 )　🔒 §10.6 数值定案
# （⚠ 2026-07-13 用户拍板追加：技能基准命中＝武器技能 hit 字段〔攻击块 hits[0]，flatten 透传顶层〕，缺省 0 零回归）：
# 角色命中修正＝技巧＋acc 属性桶（面板底 0——武器/饰品 mods、熟练度 stage_mods、特性全汇入）；人身闪避＝灵活（eva 同理）。
# Π命中效能 = 攻方命中效能(增益向) × 守方闪避效能(减免向) × 攻方地块命中效能 × 守方地块闪避效能（森林掩蔽）——
# 无效能修正 / 无地块效果时 =1.0（与旧行为一致）。地块贡献惰性读取，见 _terrain_eff_factor。
func _hit_chance(attacker, target, skill = null) -> int:
	return int(_hit_chance_detail(attacker, target, skill)["hc"])

# 明细版（技改 §1-5 判定/展示口径合一）：{hc, acc, eva}——acc/eva＝含技能基准/技巧/灵活/士气的合计口径，
# 判定（_resolve_compute_body 掷骰）与展示（战斗记录）同吃这一份，不再各自分算。
func _hit_chance_detail(attacker, target, skill = null) -> Dictionary:
	var base_hit := 0.0
	if typeof(skill) == TYPE_DICTIONARY:
		base_hit = float(skill.get("hit", 0.0))   # 武器技能面板命中（横扫低/刺击高——逐技能定基准）
	var acc: int = int(round(base_hit + attacker.effective_stat_f("acc") + attacker.effective_stat_f("finesse"))) \
		+ attacker.morale_combat_mod()   # 士气档位 🔒 §10.7：命中平加 ±5/10（稳定 0）
	var eva := int(round(target.effective_stat_f("eva") + target.effective_stat_f("agility")))
	var eff: float = attacker.eff_mult("hit_eff") * target.eff_reduce("eva_eff")
	eff *= _terrain_eff_factor(attacker, "hit_eff", true)    # 攻方地块命中效能（增益向）
	eff *= _terrain_eff_factor(target, "eva_eff", false)     # 守方地块闪避效能（森林掩蔽·减免向）
	return {"hc": clampi(int(round(float(acc - eva) * eff)), 5, 95), "acc": acc, "eva": eva}

# 技能伤害补正（flat、不吃效能）：bonus = Σ(指定四维/属性) × mult。无则 0。
func _skill_bonus(attacker, skill) -> float:
	var b = skill.get("bonus", null)
	if typeof(b) != TYPE_DICTIONARY:
		return 0.0
	var sum := 0.0
	for s in b.get("stats", []):
		sum += attacker.effective_stat_f(str(s))
	return Unit.round1(sum * float(b.get("mult", 0.0)))

const DUAL_STRIKE_AP := 1     # 双武器连携普攻 AP（🔒 决策31；占位——数值轮调）
const REACTION_RATE := 0.75   # 反应系数（🔒 决策31：借机/反击＝普攻构成 ×此值；占位——数值轮调）

# 普攻 AP 成本单口（🔒 决策31）：连携激活＝DUAL_STRIKE_AP 常量（两段合一次动作）；否则＝主手技能费。
# 消费点：Sandbox._can_attack/_do_attack ＋ _ai_plan 攻击门槛（三处同口，禁再手抄 skill_ap_cost(basic_attack)）。
func attack_ap_cost(u) -> int:
	return DUAL_STRIKE_AP if u.dual_strike_active() else SkillDB.skill_ap_cost(u.basic_attack())

# 普攻构成段（🔒 决策31 双武器连携）：恒 [主手段]；dual_strike 激活 → 追加副手段
# （副手 bws 扁平＋weapon_source=off_hand，结算天然吃 offhand_eff 链——不硬编码 0.5）。
# 普攻执行（Sandbox._do_attack）与借机（_resolve_aoo）同吃此口——借机 ×REACTION_RATE 对两段自动成立（勿特判）。
func attack_segments(u) -> Array:
	var segs: Array = [u.basic_attack()]
	if u.dual_strike_active():
		segs.append(u.offhand_weapon_attack())
	return segs

# 单次攻击完整结算——命中/暴击/格挡掷骰、伤害分量落血、死门条 −1+结算、异常施加。
# 只改单位状态，不写日志/飘字；返回展示所需全部数值（未命中时只有 hit/roll/hc/acc/eva）。
# 副手是否持盾（🔒 §7.1：盾上的 off_hand 攻击不吃副手惩罚——盾击类语义另算）
func _offhand_is_shield(u) -> bool:
	var item = ItemInstances.view(int(u.equipment.get("off_hand", 0)))
	return item != null and (item.get("tags", []) as Array).has("shield")

# 主手武器 tag（动态武器技能 tag 解析用；空手/天生武器无实例＝[]）
func _main_hand_tags(u) -> Array:
	var item = ItemInstances.view(int(u.equipment.get("main_hand", 0)))
	return item.get("tags", []) if item != null else []

# 本段持械槽（🔒 决策33 件归属，同 offhand_eff/格挡休眠先例）：hit 带 weapon_source=off_hand → 副手件，否则主手件
func _seg_slot(skill) -> String:
	return "off_hand" if str(skill.get("weapon_source", "")) == "off_hand" else "main_hand"

# 甲伤·百分比因子（🔒 决策33 钝器对护甲额外伤害）：1 + (持械件固有 armor_dmg_pct + 该件 mods 词条 + 非装备源修正)/100。
# 件侧直读（固有键+词条），不走 effective_stat——装备源修正扫描排除（防双计、防双武跨件串味）；
# perk/buff/特性等非装备源经 _mod_active 照常计入（修正是对象 🔒）。旧键 armor_dmg 双读窗口（迁 armor_dmg_pct）。
func _seg_armor_dmg_factor(attacker, skill) -> float:
	return maxf(0.0, 1.0 + _seg_armor_dmg_sum(attacker, skill, "armor_dmg_pct", "armor_dmg") / 100.0)

# 甲伤·固定值（🔒 2026-07-15）：固定点数额外护甲破坏（持械件固有 armor_dmg_flat + 该件词条 + 非装备源修正）。
func _seg_armor_dmg_flat(attacker, skill) -> float:
	return maxf(0.0, _seg_armor_dmg_sum(attacker, skill, "armor_dmg_flat", ""))

# 按段汇总某甲伤键（件固有 key〔legacy 兜底旧键〕+ 件 mods 词条 + 非 equip 源修正）——两模式共用采集。
func _seg_armor_dmg_sum(attacker, skill, key: String, legacy_key: String) -> float:
	var sum := 0.0
	var item = ItemInstances.view(int(attacker.equipment.get(_seg_slot(skill), 0)))
	if item != null:
		sum += float(item.get(key, item.get(legacy_key, 0) if legacy_key != "" else 0))
		for m in item.get("mods", []):
			if typeof(m) == TYPE_DICTIONARY and str(m.get("stat", "")) == key:
				sum += float(m.get("value", 0))
	for m in attacker.modifiers:
		if typeof(m) == TYPE_DICTIONARY and str(m.get("stat", "")) == key \
				and not str(m.get("source", "")).begins_with("equip:") and attacker._mod_active(m):
			sum += float(m.get("value", 0))
	return sum

func _resolve_compute(attacker, target, skill) -> Dictionary:
	# 交互语境（🔒 §4.2 阶段4）：结算期内两侧互挂 combat_ctx，when 条件（target_tag/skill_tag/target_effect）
	# 惰性读取（屠龙者 triple_vs / 受击向条件同口）；出结算即清——结算外交互条件恒不满足。
	# skill_tags 含动态武器技能 tag（🔒 决策29）：占位 skill_weapon + 按主手武器种类解析 skill_<种类>
	# （恒读主手 🔒 与普攻同族——武器技能被谁持有＝主手武器说了算）。
	var ctx_tags := SkillDB.skill_ctx_tags(skill, _main_hand_tags(attacker))
	attacker.combat_ctx = {"target": target, "skill_tags": ctx_tags}
	target.combat_ctx = {"target": attacker, "skill_tags": ctx_tags}
	var r := _resolve_compute_body(attacker, target, skill)
	attacker.combat_ctx = {}
	target.combat_ctx = {}
	return r

func _resolve_compute_body(attacker, target, skill) -> Dictionary:
	# 命中：判定与展示同吃 _hit_chance_detail 一份明细（§1-5 口径合一；acc/eva 供战斗记录展示；技能基准命中入 acc 项）
	var hd := _hit_chance_detail(attacker, target, skill)
	var hc := int(hd["hc"])
	var roll := int(rng.randf() * 100.0)
	var hit := roll < hc
	var r := {"hit": hit, "roll": roll, "hc": hc, "acc": int(hd["acc"]), "eva": int(hd["eva"])}
	if not hit:
		r["morale_att"] = _morale_add(attacker, -1)   # 士气：失手 −1（🔒 §10.7）
		return r
	# 暴击 🔒 §10.6：无人身底率——crit_rate 面板（招式/武器承载）＋技巧×0.5 −受击方运气，钳底 0
	var cr := maxf(0.0, float(attacker.effective_stat_f("crit_rate")) \
		+ float(attacker.effective_stat_f("finesse")) * 0.5 - float(target.effective_stat_f("luck")))
	var crit := rng.randf() * 100.0 < cr
	# 伤害 = 攻击 × 系数 [× 暴击] [× 效能≠100%]；暴击威力＝crit_dmg ＋ 运气×0.5（🔒 §10.6 二次修订：运气加爆伤）
	var coeff := float(skill.get("coeff", 1.0))
	var cmult := ((float(attacker.effective_stat_f("crit_dmg")) \
		+ float(attacker.effective_stat_f("luck")) * 0.5) / 100.0) if crit else 1.0
	var aeff: float = attacker.eff_mult("atk_eff") * _terrain_eff_factor(attacker, "atk_eff", true) \
		* (1.0 + attacker.morale_combat_mod() / 100.0)   # 攻击效能桶：面板 atk_eff/100 × Π效能修正 × 攻方地块 × 士气档位因子（🔒 §10.7）
	# 副手惩罚（🔒 决策5/§7.1 阶段3b）：hit 带 weapon_source=="off_hand" 且副手非盾 → ×offhand_eff/100
	# （基础 50、单手精通 perk 经修正管线 ≤75）；offhand_factor（偷击类 hit 自带再乘，per-round 账本＝阶段6 反应侧）
	var ohf := 1.0
	if str(skill.get("weapon_source", "")) == "off_hand" and not _offhand_is_shield(attacker):
		ohf = maxf(0.0, attacker.effective_stat_f("offhand_eff") / 100.0)
	ohf *= maxf(0.0, float(skill.get("offhand_factor", 1.0)))
	var atk := float(attacker.effective_stat_f("atk"))
	var out := atk * coeff * cmult * aeff * ohf
	# 伤害补正：额外 flat 伤害，不吃效能（如撕裂/抓取的 (力量+灵巧)×0.5）
	var bonus := _skill_bonus(attacker, skill)
	if bonus > 0.0:
		out += bonus
	# 反应系数（🔒 决策31）：借机/反击段的 hit 带 atk_rate（借机注入 REACTION_RATE；缺省 1＝普攻零影响）——
	# 段输出整体等比缩放（含补正），命中/暴击/格挡掷骰不受影响
	var rrate := maxf(0.0, float(skill.get("atk_rate", 1.0)))
	out *= rrate
	# 格挡 + 全域减伤 G = max(0, 1−格挡性能/100) × 防御效能因子（下限 clamp🔒）
	var br := float(target.effective_stat_f("block_rate"))
	var blocked := rng.randf() * 100.0 < br
	if not blocked:
		r["morale_att"] = _morale_add(attacker, 2)   # 士气：命中 +2、被格挡无变化（🔒 §10.7）
	var bp := float(target.effective_stat_f("block_power")) if blocked else 0.0
	# 防御效能 def_eff：base 100=中性、越高越减伤。def_factor = max(0, 2 − def_eff/100)
	var deff: float = float(target.effective_stat_f("def_eff"))
	var def_factor := maxf(0.0, 2.0 - deff / 100.0) * _terrain_eff_factor(target, "def_eff", false)   # ×守方地块防御效能（减免向，折进减伤链）
	var g := maxf(0.0, 1.0 - bp / 100.0) * def_factor
	# 分量：普攻单分量(先进甲)；穿甲 armor_pen 拆 人/甲 两分量。damage_category 默认物理（damage_kind 已改词 2026-07-13；element 已废弃 §7.2）。
	var dkind := str(skill.get("damage_category", "physical"))
	var pen := clampf(float(skill.get("armor_pen", 0.0)), 0.0, 1.0)
	var components := []
	if pen > 0.0:
		components.append({"lane": "human", "damage_category": dkind, "ratio": pen})
		components.append({"lane": "armor_first", "damage_category": dkind, "ratio": 1.0 - pen})
	else:
		components.append({"lane": "armor_first", "damage_category": dkind, "ratio": 1.0})
	# 结算落血（分量减伤链在 CombatResolver：逐分量 甲抗/人抗/固减 + 破甲溢出保留元素；甲伤按段取件——百分比+固定值两模式）
	var dres := CombatResolver.resolve(target, out, g, components,
		_seg_armor_dmg_factor(attacker, skill), _seg_armor_dmg_flat(attacker, skill))
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
	r["offhand"] = ohf
	r["atk_rate"] = rrate
	r["bonus"] = bonus
	r["out"] = out
	r["blocked"] = blocked
	r["br"] = br
	r["bp"] = bp
	r["def_factor"] = def_factor
	r["damage_category"] = dkind
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
	# On-Hit Effects 双挂点合并——技能侧＋武器侧同性质只是来源不同（🔒 2026-07-15 键级统一：
	# 技能攻击块旧单条 inflict → 与武器同形的 on_hit_effects 数组；旧键双读窗口，lint 禁回流）。
	# 单击合并规则（🔒 决策33/34，用户口径）：
	# ①同 effect id：**概率取高只掷一次**（施加概率在武器/技能侧、不在异常本身；ignore_fort 取或）；
	# ②异 id 同族（共享 cat=effect 异常 tag——各种出血变体都带 bleeding）：**只按优先级更高的那条施加**
	#   （概率与效果都取高者，低者本次不掷）；③无关异常各自独立掷。
	# 目标身上已挂同族旧效果的覆盖/压制＝_add_effect_by_id 优先级闸（跨击语义）。空手/无实例＝无武器侧。
	var cands := []   # [{inf, from_skill}]
	for se in skill.get("on_hit_effects", []):
		if typeof(se) == TYPE_DICTIONARY and str(se.get("effect", "")) != "":
			cands.append({"inf": se.duplicate(true), "from_skill": true})
	var sinf = skill.get("inflict", null)   # 旧键双读窗口（含无 effect 键的匿名内联形，原样入候选）
	if typeof(sinf) == TYPE_DICTIONARY:
		cands.append({"inf": sinf.duplicate(true), "from_skill": true})
	var w_item = ItemInstances.view(int(attacker.equipment.get(_seg_slot(skill), 0)))
	if w_item != null:
		for e in w_item.get("on_hit_effects", []):
			if typeof(e) == TYPE_DICTIONARY and str(e.get("effect", "")) != "":
				cands.append({"inf": e.duplicate(true), "from_skill": false})
	var final := []
	for c in cands:
		var cinf: Dictionary = c["inf"]
		var ceid := str(cinf.get("effect", ""))
		var absorbed := false
		for f in final:
			var finf: Dictionary = f["inf"]
			var fid := str(finf.get("effect", ""))
			if ceid != "" and ceid == fid:                      # ①同 id：概率取高
				finf["chance"] = maxf(float(finf.get("chance", 100.0)), float(cinf.get("chance", 100.0)))
				if bool(cinf.get("ignore_fort", false)):
					finf["ignore_fort"] = true
				f["from_skill"] = bool(f["from_skill"]) or bool(c["from_skill"])
				absorbed = true
				break
			if ceid != "" and fid != "" and _same_effect_family(ceid, fid):   # ②同族异 id：高优先级独占
				if _effect_priority(ceid) > _effect_priority(fid):
					f["inf"] = cinf
					f["from_skill"] = c["from_skill"]
				absorbed = true   # 低者本次直接丢弃（不掷）
				break
		if not absorbed:
			final.append(c)
	# 结果归一（键级统一 2026-07-15）：技能侧/武器侧同入 r["on_hit"] 数组（原 r["inflict"] 单列已并轨）
	var onhit := []
	for f in final:
		var ires := _try_inflict_state(target, {"inflict": f["inf"]})
		if not ires.is_empty():
			onhit.append(ires)
	if not onhit.is_empty():
		r["on_hit"] = onhit
	return r

# 决策34 小工具：两效果是否同族（共享 cat=effect 异常 tag）/ 效果优先级（缺省 0）
func _same_effect_family(a: String, b: String) -> bool:
	var fa: Array = EffectDB.family_tags(EffectDB.get_effect(a))
	for t in EffectDB.family_tags(EffectDB.get_effect(b)):
		if fa.has(t):
			return true
	return false

func _effect_priority(eid: String) -> int:
	var d = EffectDB.get_effect(eid)
	return int(d.get("priority", 0)) if d != null else 0

# 命中后尝试施加异常（流血等）：先掷施加概率，命中再掷**强韧豁免**（🔒 模块_属性成长_设计.md §5：
# 遭受第一时间豁免一次，成功＝完全不受影响；之后每回合豁免见 _apply_turn_start_effects）。
# inflict 引用形态🔒（§2.2）：`{effect:"<id>", chance:N, ignore_fort?:bool}`——effect id 查 EffectDB、
# chance 缺省 100；ignore_fort=true＝无视强韧（施加豁免与每回合豁免一并跳过）。
# 兼容旧内联形态（name+mods，无 effect 键，chance 缺省 0）——匿名路径无维度 tag、天然不参与豁免。
# 返回掷骰事件 {name, base_ch, roll, applied, fort, fort_roll, shrugged}；skill 无 inflict ＝ 空 {}。
func _try_inflict_state(target, skill) -> Dictionary:
	var inf = skill.get("inflict", null)
	if typeof(inf) != TYPE_DICTIONARY:
		return {}
	var eid := str(inf.get("effect", ""))
	var base_ch := float(inf.get("chance", 100.0 if eid != "" else 0.0))
	var iroll := rng.randf() * 100.0
	var applied := iroll < base_ch
	var ignore_fort := bool(inf.get("ignore_fort", false))
	var fort := 0.0
	var fort_roll := -1.0
	var shrugged := false
	var nm := ""
	if eid != "":
		var def = EffectDB.get_effect(eid)
		nm = str(def.get("name", eid)) if def != null else eid
		if applied and not ignore_fort and def != null:
			var fk := _fort_key_for(def.get("tags", []))
			if fk != "":
				fort = float(target.effective_stat_f(fk))
				if fort > 0.0:
					fort_roll = rng.randf() * 100.0
					shrugged = fort_roll < fort
	var landed := true   # 决策34：优先级压制＝掷中但不生效，如实回报（suppressed 供播报区分「未中」）
	if eid != "":
		if applied and not shrugged:
			landed = _add_effect(target, {"id": eid, "ignore_fort": ignore_fort})   # id 路径：定义查 EffectDB
	else:
		nm = str(inf.get("name", ""))          # 旧内联形态
		if applied:
			_add_effect(target, inf)
	return {"name": nm, "base_ch": base_ch, "roll": iroll, "applied": applied and not shrugged and landed,
		"fort": fort, "fort_roll": fort_roll, "shrugged": shrugged,
		"suppressed": applied and not shrugged and not landed}

# ============ 技能施放（阶段2 下沉 🔒 模块_技能_设计 §3/§10）：模型算+结构化事件出，宿主只渲染 ============
# 修「heal 逻辑违例在宿主」（§3 注*）：AP/冷却/次数消耗与效果块结算全在模型层，Sandbox._do_skill 退成薄渲染壳。
# v1 可跑块：heal（heal_pct_max_hp 标量/公式/逐级 + cleanse_tags）/ apply_effect（{effect,chance} 对象形，
# 复用 _try_inflict_state＝chance 掷 + 强韧豁免单一路径）。attack 块＝阶段3（BAS 统一）后接；
# 未知 kind 警告跳过（「可编≠可跑」护栏——编辑器侧另拦）。
func apply_skill(caster, skill_id: String, target) -> Array:
	var events := []
	var def = SkillDB.get_skill(skill_id)
	if def == null or caster == null or target == null:
		return events
	# 前置守卫（护栏#1 可编≠可跑）：effects 无可跑块 → 拒发且零消耗——
	# 否则纯 attack 块技能经能力路径＝白烧 AP/冷却/次数（attack 经能力施放＝阶段6 再放开）。
	if not SkillDB.has_runnable_block(def):
		push_warning("apply_skill：技能「%s」无可跑效果块（%s）——拒发零消耗（可编≠可跑）" % [skill_id, "/".join(SkillDB.RUNNABLE_KINDS)])
		return events
	# 握持守卫 🔒（决策35 运行时可用性条件，双闸之引擎侧）：grip 不满足 → 拒发零消耗
	# （菜单侧已灰显；判据恒主手——阶段6 副手 EWS 接线时随 weapon_source 改判）。
	if not caster.grip_met(def):
		push_warning("apply_skill：技能「%s」握持条件不满足（需%s持）——拒发零消耗（决策35）" % [skill_id, "双手" if str(def.get("grip", "")) == "two_handed" else "单手"])
		return events
	var lvl := int(caster.skill_level(skill_id))
	caster.ap -= SkillDB.skill_ap_cost(def)
	if caster.has_skill(skill_id):
		caster.consume_skill(skill_id, caster.skill_cooldown_max(def))
	else:
		caster.consume_ews(skill_id, caster.skill_cooldown_max(def))   # EWS＝装备授予非已学，运行态走 ews_state（🔒 决策26）
	for block in def.get("effects", []):
		if typeof(block) != TYPE_DICTIONARY:
			continue
		match str(block.get("kind", "")):
			"heal":
				# 治疗 % 最大生命：resolve_num 两吃标量/公式；治疗语义钳 ≥0（§2.4 负值钳制）
				var pct := maxf(0.0, SkillDB.resolve_num(block.get("heal_pct_max_hp", 0), caster, lvl, 0.0))
				if pct > 0.0:
					var maxhp := int(target.effective_stat("HP_max"))
					var before := int(target.stats.get("HP", 0))
					var healed := maxi(0, mini(int(round(maxhp * pct / 100.0)), maxhp - before))
					target.stats["HP"] = before + healed
					events.append({"type": "heal", "heal": healed, "pct": pct, "before": before, "after": before + healed})
				for tag in block.get("cleanse_tags", []):
					var n := _cleanse_effects_with_tag(target, str(tag))
					if n > 0:
						events.append({"type": "cleanse", "tag": str(tag), "count": n})
			"apply_effect":
				var eid := str(block.get("effect", ""))
				if eid == "":
					continue
				var ch := clampf(SkillDB.resolve_num(block.get("chance", 100), caster, lvl, 100.0), 0.0, 100.0)
				var r := _try_inflict_state(target, {"inflict": {"effect": eid, "chance": ch,
					"ignore_fort": bool(block.get("ignore_fort", false))}})
				events.append({"type": "inflict", "effect": eid, "name": str(r.get("name", eid)),
					"applied": bool(r.get("applied", false)), "shrugged": bool(r.get("shrugged", false))})
			var unknown:
				push_warning("apply_skill：技能「%s」效果块 kind「%s」引擎尚不支持（可编≠可跑）——跳过" % [skill_id, unknown])
	return events

# 强韧豁免的维度归轨 🔒（§5）：效果 tags 带 fort_will→意志强韧 / fort_body→肉体强韧；
# 无维度 tag（一切 buff、纯机制效果如死门/重伤）＝"" ＝不参与豁免。tag 真值见 data/tags.json + 标签词典。
func _fort_key_for(tags_arr) -> String:
	if typeof(tags_arr) != TYPE_ARRAY:
		return ""
	if (tags_arr as Array).has("fort_will"):
		return "will_fort"
	if (tags_arr as Array).has("fort_body"):
		return "body_fort"
	return ""

# ============ 效果 / buff↔modifier 桥 ============

# 给单位挂一个效果。**分派🔒（§2.2）**：入参带非空 id → EffectDB id 路径（同 id 刷新 / stackable 叠层）；
# 无 id 但有 name（+可选 mods）→ 匿名内联旧路径（死门/重伤/内联 inflict/旧测试，行为原样不动）。
# **buff↔modifier 桥 🔒**：带 mods 时同时往 target.modifiers 挂（source="buff:<id|name>"）。
# 返回是否实际生效（🔒 决策34：被更高优先级同族异常压制＝false——施加方据此如实播报）。
func _add_effect(target, inf: Dictionary) -> bool:
	var eid := str(inf.get("id", ""))
	if eid != "":
		return _add_effect_by_id(target, inf, eid)
	_add_effect_anonymous(target, inf)
	return true

# 匿名内联路径（旧行为逐字保留）：同 name 刷新时长/DoT、不叠层；source="buff:<name>"。
func _add_effect_anonymous(target, inf: Dictionary) -> void:
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
	_hang_effect_mods(target, inf.get("mods", []), source, str(inf.get("kind", "debuff")))

# EffectDB id 路径（§2.2）：查定义 → 同 id 刷新时长 / stackable 叠层（≤max_stacks）；source="buff:<id>"。
# 入参 inf 只需带 id（+可选运行时覆盖）；定义本体（duration/dot/mods…）从 EffectDB 取。
func _add_effect_by_id(target, inf: Dictionary, eid: String) -> bool:
	var def = EffectDB.get_effect(eid)
	if def == null:
		push_warning("_add_effect: 未知效果 id=%s（EffectDB 无此条目，跳过）" % eid)
		return false
	# 异常优先级（🔒 决策34）：同族（共享 cat=effect 异常 tag）异 id → 恒高优先级起效——
	# 已挂更高者＝新效果被压制不生效；新者更高＝顶掉旧低者（修正一并摘）。
	# 同级＝数据错误（lint 同族禁同级；运行时保守压制新者+告警）。同 id 不走此闸（刷新/叠层照旧）。
	var fam: Array = EffectDB.family_tags(def)
	if not fam.is_empty():
		var prio := int(def.get("priority", 0))
		for e in target.effects.duplicate():
			if str(e.get("id", "")) == eid:
				continue
			var edef = EffectDB.get_effect(str(e.get("id", "")))
			if edef == null:
				continue   # 匿名/悬空效果不参与优先级
			var shared := false
			for t in EffectDB.family_tags(edef):
				if fam.has(t):
					shared = true
					break
			if not shared:
				continue
			var eprio := int(edef.get("priority", 0))
			if eprio > prio:
				return false   # 高者在场：新效果不起效
			if eprio == prio:
				push_warning("_add_effect: 同族同级异常「%s」vs「%s」（priority %d）——数据应错开优先级（lint 拦）；保守压制新者" % [eid, str(e.get("id", "")), prio])
				return false
			_remove_mods_by_source(target, str(e.get("source", "")))   # 新者更高：顶掉旧低者
			target.effects.erase(e)
	var source := "buff:" + eid
	_remove_mods_by_source(target, source)   # 刷新/叠层：先摘旧修正、按最新（含叠层后应有的 mods）重挂
	var dur := _eval_effect_duration(def)
	var stackable := bool(def.get("stackable", false))
	var max_stacks := int(def.get("max_stacks", 0))
	var existing = null
	for e in target.effects:
		if str(e.get("id", "")) == eid:
			existing = e
			break
	if existing != null:
		existing["duration"] = dur   # 同 id：刷新时长
		if stackable:
			var ns := int(existing.get("stacks", 1)) + 1
			if max_stacks > 0:
				ns = mini(ns, max_stacks)
			existing["stacks"] = ns
	else:
		var e := {
			"id": eid,
			"name": str(def.get("name", eid)),
			"kind": str(def.get("kind", "debuff")),
			"permanent": bool(def.get("permanent", false)),
			"duration": dur,
			"dot_pct_max_hp": float(def.get("dot_pct_max_hp", 0)),
			"hot_flat": float(def.get("hot_flat", 0)),          # >0 每回合末回固定血（HoT）
			"tags": def.get("tags", []),
			"expire_timing": str(def.get("expire_timing", "turn_end")),
			"on_expire_apply": str(def.get("on_expire_apply", "")),   # 到期连锁施加另一效果 id（两段式，§决策20）
			"source": source,
		}
		if bool(inf.get("ignore_fort", false)):
			e["ignore_fort"] = true   # 无视强韧 🔒（§5）：每回合豁免也跳过（快照随 effects 原样保真）
		if stackable:
			e["stacks"] = 1
		target.effects.append(e)
	_hang_effect_mods(target, def.get("mods", []), source, str(def.get("kind", "debuff")))
	return true

# buff↔modifier 桥：把效果的 mods 挂进 target.modifiers（同 source）。
func _hang_effect_mods(target, mods, source: String, nature: String) -> void:
	for m in mods:
		if typeof(m) != TYPE_DICTIONARY:
			continue
		target.modifiers.append({"stat": str(m.get("stat", "")), "op": str(m.get("op", "flat")), "value": float(m.get("value", 0)), "source": source, "nature": nature})

# 效果时长求值：兼容旧匿名内联的裸标量 与 EffectDB 的 {base,per_stat} 对象（§2.2 双形前置）。
# v1：对象形只读 base（per_stat 公式求值留阶段2 与 resolve_num 一起；fixed 模型见 §2.8）。整数语义 floor。
func _eval_effect_duration(inf) -> int:
	var d = inf.get("duration", 1)
	if typeof(d) == TYPE_DICTIONARY:
		return int(floor(float(d.get("base", 0))))
	return int(d)

# 按 source 摘掉单位的修正（buff 到期/被清除时）。
func _remove_mods_by_source(u, source: String) -> void:
	if u == null or typeof(u.modifiers) != TYPE_ARRAY:
		return
	u.modifiers = u.modifiers.filter(func(m): return str(m.get("source", "")) != source)

# 清空单位的效果 + 所有 buff 来源的临时修正（重开/退战/换图用）；装备/特性等常驻修正保留。
func _clear_effects_and_buffs(u) -> void:
	u.effects = []
	if typeof(u.modifiers) == TYPE_ARRAY:
		u.modifiers = u.modifiers.filter(func(m): return not str(m.get("source", "")).begins_with("buff:"))

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
	var chains := []   # 到期连锁施加的第二段效果 id（决策20 两段式；循环内先收集、u.effects 重置后再施加，防被 keep 覆盖）
	for e in u.effects:
		# DoT：每回合末按 HP_max 百分比扣血（无视护甲）
		var pct := float(e.get("dot_pct_max_hp", 0))
		if pct > 0.0:
			var d := int(round(float(u.effective_stat("HP_max")) * pct / 100.0))
			if d > 0:
				u.stats["HP"] = int(u.stats.get("HP", 0)) - d
				events.append({"type": "dot", "name": str(e.get("name", "流血")), "dmg": d, "pct": pct})
		# HoT：每回合末回固定血（钳 HP_max、不溢出）
		var hot := float(e.get("hot_flat", 0))
		if hot > 0.0:
			var hpmax := int(u.effective_stat("HP_max"))
			var cur := int(u.stats.get("HP", 0))
			var newhp := mini(hpmax, cur + int(round(hot)))
			if newhp > cur:
				u.stats["HP"] = newhp
				events.append({"type": "hot", "name": str(e.get("name", "回血")), "heal": newhp - cur})
		# 时长递减只对「回合末到期」的效果（turn_end/缺省）；turn_start/round_end 在各自 tick 点递减（DoT/HoT 恒在此）。
		if e.get("permanent", false) or str(e.get("expire_timing", "turn_end")) != "turn_end":
			keep.append(e)
		else:
			_countdown_and_expire(u, e, keep, events, chains)
	u.effects = keep
	_apply_expire_chains(u, chains, events)
	return events

# 回合开始对称 tick（§2.2）：先掷**每回合强韧豁免**（🔒 §5：带维度 tag 的异常，成功＝立即挣脱、
# ignore_fort 不可挣脱），再递减/到期 expire_timing=="turn_start" 的效果（长剑架势等到期在回合开头）。
# 不结算 DoT/HoT（那些恒在 turn_end）。执行顺序锁定：本 tick → 失能检查 → 行动（宿主 _begin_active_turn）。
func _apply_turn_start_effects(u) -> Array:
	var events := []
	if u == null:
		return events
	var mev := _morale_turn_tick(u)   # 士气回合开始步（🔒 §10.7）——先于效果 tick、不依赖 effects 存在
	if not mev.is_empty():
		events.append(mev)
	if not ("effects" in u) or u.effects.is_empty():
		return events
	var keep := []
	var chains := []
	for e in u.effects:
		var fk := _fort_key_for(e.get("tags", []))
		if fk != "" and not bool(e.get("ignore_fort", false)):
			var fort := float(u.effective_stat_f(fk))
			if fort > 0.0 and rng.randf() * 100.0 < fort:
				_remove_mods_by_source(u, str(e.get("source", "buff:" + str(e.get("name", "")))))
				events.append({"type": "fort_shrug", "name": str(e.get("name", ""))})
				continue
		if e.get("permanent", false) or str(e.get("expire_timing", "turn_end")) != "turn_start":
			keep.append(e)
		else:
			_countdown_and_expire(u, e, keep, events, chains)
	u.effects = keep
	_apply_expire_chains(u, chains, events)
	return events

# 单条效果时长 −1：>0 留下；≤0 到期（摘修正 + 记 expired 事件 + 收集 on_expire 连锁）。turn_start/turn_end 共用。
func _countdown_and_expire(u, e, keep: Array, events: Array, chains: Array) -> void:
	var dur := int(e.get("duration", 0)) - 1
	if dur > 0:
		e["duration"] = dur
		keep.append(e)
	else:
		_remove_mods_by_source(u, str(e.get("source", "buff:" + str(e.get("name", "")))))   # 到期：连带摘掉其挂的修正
		events.append({"type": "expired", "name": str(e.get("name", ""))})
		var chain := str(e.get("on_expire_apply", ""))
		if chain != "":
			chains.append(chain)

# 两段式连锁：到期效果的 on_expire_apply 第二段（循环外施加，防被 keep 覆盖）。决策20。
func _apply_expire_chains(u, chains: Array, events: Array) -> void:
	for cid in chains:
		_add_effect(u, {"id": cid})
		events.append({"type": "chain", "id": cid})

# ============ 技艺熟练度获取（🔒 模块_属性成长_设计.md §2.4；日志在宿主）============

# 行为基础值 🔒 权重序：攻击＞格挡＞挨打；具体数值=🟡占位（数值层后调）。
const PROF_GAIN_ATTACK := 10
const PROF_GAIN_BLOCK := 6
const PROF_GAIN_HIT_TAKEN := 2

# 一次攻击结算后的熟练度发放：
#   攻击者——按主手武器/攻击 tags 喂养**全部匹配的已装载技艺**（🔒 一次行为同喂；挥空也算练习）；
#   目标——格挡→盾、着甲挨打→防具（须装载对应技艺；防具另须 body 槽有甲）。
# 威胁缩放 🟡（强敌快涨/弱敌趋停）：按双方等级差的线性因子占位。
# 返回进阶事件 [{unit, prof, stage}]（只报进阶；涨值本身静默防刷屏）。
func grant_combat_prof(attacker, target, r: Dictionary) -> Array:
	var events := []
	var af := clampf(1.0 + 0.2 * float(int(target.level) - int(attacker.level)), 0.1, 2.0)
	var atags: Array = attacker.current_attack_tags()
	for pid in attacker.prof_slots:
		if ProfDB.matches_tags(str(pid), atags):
			var ns: int = attacker.gain_prof(str(pid), int(round(PROF_GAIN_ATTACK * af)))
			if ns > 0:
				events.append({"unit": attacker, "prof": str(pid), "stage": ns})
	if bool(r.get("hit", false)):
		var tf := clampf(1.0 + 0.2 * float(int(attacker.level) - int(target.level)), 0.1, 2.0)
		if bool(r.get("blocked", false)) and target.prof_slots.has("style_shield"):
			var ns2: int = target.gain_prof("style_shield", int(round(PROF_GAIN_BLOCK * tf)))
			if ns2 > 0:
				events.append({"unit": target, "prof": "style_shield", "stage": ns2})
		if int(r.get("hp_loss", 0)) + int(r.get("armor_loss", 0)) > 0 \
				and target.prof_slots.has("style_armor") and target.equipment.has("body"):
			var ns3: int = target.gain_prof("style_armor", int(round(PROF_GAIN_HIT_TAKEN * tf)))
			if ns3 > 0:
				events.append({"unit": target, "prof": "style_armor", "stage": ns3})
	return events

# ============ 士气（骨架 v1：数值+事件；档位战斗判定延后批次；🔒 模块_属性成长_设计.md §10.7）============

# 士气变化唯一入口：负向先经决心抵消（每点抵 1、单次损失保底 1）、再钳 0~50。返回实际变化量（0=无事发生）。
func _morale_add(u, delta: int) -> int:
	if u == null or delta == 0:
		return 0
	var d := delta
	if d < 0:
		# 决心抵消 🔒（二次修订 2026-07-08）：每点抵 0.5 向下取整；单次损失保底 1
		d = -maxi(1, -d - int(floorf(u.effective_stat_f("resolve") * 0.5)))
	var before: int = u.morale
	u.morale = clampi(before + d, 0, u.MORALE_MAX)
	return u.morale - before

# 士气·回合开始步：有邻敌＝掉 (邻敌−邻友，钳 0~6)；无邻敌＝向常态 25 回归 ±1。两者不叠加（取其一）。
# 由 _apply_turn_start_effects 每单位 turn 开始调用。返回事件 {type:"morale",...}；无变化＝{}。
func _morale_turn_tick(u) -> Dictionary:
	var enemies := 0
	var friends := 0
	for n in _neighbors(u.col, u.row):
		var o = unit_at(n.x, n.y)
		if o == null:
			continue
		if _is_hostile(u, o):
			enemies += 1
		else:
			friends += 1
	var applied := 0
	if enemies > 0:
		var loss := clampi(enemies - friends, 0, 6)
		if loss > 0:
			applied = _morale_add(u, -loss)
	elif u.morale != u.MORALE_BASELINE:
		applied = _morale_add(u, 1 if u.morale < u.MORALE_BASELINE else -1)
	if applied == 0:
		return {}
	return {"type": "morale", "delta": applied, "morale": u.morale, "band": u.morale_band_name()}

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
		"mods": [{"stat": "agility", "op": "pct", "value": -50}, {"stat": "def_eff", "op": "pct", "value": -50}]})
	# ⚠️ 闪避减半改打 agility（🔒 §10.6 人身闪避＝灵活；eva 面板底 0、pct 打上去无效）——顺带减半回合序，垂死者反正跳过行动。

# 门条 ±3 结算（只改状态、不移除、不写日志）。返回 ""=未触发 / "down_dead"（铁人真死）/ "down_injured"（重伤离场）/ "climb"（爬回）。
# −3＝倒下（非铁人挂 injured 重伤离场 / 铁人挂 dead 真死 🔒）；+3＝爬回（HP 保底占位 1，挂重伤 debuff 至战斗结束）。
func _door_settle_state(u) -> String:
	if u.door_gauge <= -3:
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
	# 击杀记录（经验结算 + 情报解锁共用一份；铺垫见 docs/模块_营地后勤.md §3.1）
	for u in dead:
		_battle_kills.append({"proto_id": u.proto_id, "victim_uid": u.uid, "faction": u.faction,
			"by_uid": (u.last_hit_by.uid if u.last_hit_by != null else 0)})
	# 士气（🔒 §10.7）：击败者 +3（按击杀归属，含重伤离场——"击败"口径）；
	# 真死（dead tag / 无死门资格即死）→ 同侧存活者全场 −5；重伤离场不算"挂了"、无全场事件。
	# 事件上抛宿主渲染（{kind:"kill"|"ally_death"}；模型不写日志）。
	var morale_events := []
	for u in dead:
		if u.last_hit_by != null and not (u.last_hit_by in dead):
			var md: int = _morale_add(u.last_hit_by, 3)
			if md != 0:
				morale_events.append({"kind": "kill", "who": u.last_hit_by, "delta": md})
		if u.tags.has("dead") or not _door_eligible(u):
			var hit_n := 0
			for w in units:
				if w == u or (w in dead):
					continue
				if not _is_hostile(u, w):
					if _morale_add(w, -5) != 0:
						hit_n += 1
			if hit_n > 0:
				morale_events.append({"kind": "ally_death", "victim": u, "count": hit_n})
	var res := {"dead": dead, "entered_door": entered_door, "active_died": false, "new_round": false, "morale": morale_events, "round_events": []}
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
			res["round_events"] = _wrap_round()
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

# 本次「移动」动作的可用预算（格数）：移动点>0 用剩余；=0 有 AP 则一批移动力（提交时才扣 AP）；否则 0。
# （原 Sandbox._move_budget 下沉——玩家预览范围与 AI 决策同口径）
func _ai_move_budget(u) -> int:
	if u == null:
		return 0
	if u.move_points > 0:
		return u.move_points
	if u.ap > 0:
		return u.move_allowance(_tile_tags_at(u.col, u.row))   # effective 口径＋脚下地块条件
	return 0

# AI 单步决策核（技改 §1-2：纯函数、零副作用——掷骰/动画/扣费/ZOC 全在宿主执行侧）。返回 plan：
#   {"action":"attack", "cell":目标格, "target":Unit}
#   {"action":"move", "cell":落点, "path":[起点..落点], "cost":路径耗, "target":Unit}
#   {"action":"none"}   —— 无目标 / 打不着又走不近（宿主收手 end_turn）
# 决策规则（基础版）＝进攻击距离且付得起 AP 就打；否则预算可达格里挑最靠近目标的（平手取耗低）；不能更近＝收手。
func _ai_plan(unit) -> Dictionary:
	var target = _ai_nearest_hostile(unit)
	if target == null:
		return {"action": "none"}
	var here := Vector2i(unit.col, unit.row)
	var tcell := Vector2i(target.col, target.row)
	var atk_range := SkillDB.skill_reach(unit.basic_attack())   # 形状掩码优先（决策30）
	if _hex_dist(here, tcell) <= atk_range and unit.ap >= attack_ap_cost(unit):   # 连携=常量费（🔒 决策31）
		# 形状精确校验：选取形（环形射程等）外的目标不打（_attack_targets 同口设防；空=旧圆盘语义）
		var pickc := _shape_pick_cells(unit, unit.basic_attack())
		if pickc.is_empty() or pickc.has(tcell):
			return {"action": "attack", "cell": tcell, "target": target}
	var budget := _ai_move_budget(unit)
	if budget <= 0:
		return {"action": "none"}
	var data := _dijkstra(unit, budget)
	var best_cells: Dictionary = data["best"]          # {格: 累计消耗}，含起点(0)；不含他人占位格
	var came: Dictionary = data["came_from"]
	var cur_dist := _hex_dist(here, tcell)
	var pick := here
	var pick_dist := cur_dist
	var pick_cost := 0
	for cell in best_cells:
		if cell == here:
			continue
		var dd := _hex_dist(cell, tcell)
		var cc := int(best_cells[cell])
		if dd < pick_dist or (dd == pick_dist and cc < pick_cost):
			pick = cell
			pick_dist = dd
			pick_cost = cc
	if pick == here or pick_dist >= cur_dist:
		return {"action": "none"}   # 没有更靠近的落点
	return {"action": "move", "cell": pick, "path": _path_via(came, pick), "cost": int(best_cells[pick]), "target": target}

# ============ 序列化（战中 suspend 地基；约定 🔒 见 docs/架构.md「战中快照约定」）============
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
		"ironman": ironman,
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
	ironman = bool(d.get("ironman", false))
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

# 点击格 → 命中单位列表：形状掩码 AOE（🔒 决策30，作用形+友伤）＞直线 AoE（legacy）＞该格敌对单位。
# 选取形（pick）在此处也设防：形状外的点击＝非法瞄准返回 []（AI/宿主双保险，UI 层 attack_cells 已先拦）。
func _attack_targets(attacker, cell: Vector2i, skill) -> Array:
	var out := []
	var shp := SkillDB.shape_of(skill)
	var pickc := _shape_pick_cells(attacker, skill)
	if not pickc.is_empty() and not pickc.has(cell):
		return out
	var eff: Array = shp.get("effect", [])
	if not eff.is_empty():
		var cells := _shape_effect_cells(attacker, shp, cell)
		var ff := bool(shp.get("friendly_fire", false))
		for u in units:
			if Vector2i(u.col, u.row) in cells and u != attacker and (ff or _is_hostile(attacker, u)):
				out.append(u)
		return out
	var aoe = skill.get("aoe", null)
	if typeof(aoe) == TYPE_DICTIONARY and aoe.get("shape", "") == "line":
		var cells2 = _line_cells(Vector2i(attacker.col, attacker.row), cell, int(aoe.get("length", 1)))
		var ff2 = bool(aoe.get("friendly_fire", false))
		for u in units:
			var p := Vector2i(u.col, u.row)
			if p in cells2 and (ff2 or _is_hostile(attacker, u)):
				out.append(u)
	else:
		var t = unit_at(cell.x, cell.y)
		# 只能打「看得到的」：目标在当前视野内(非迷雾) + 攻方到目标有视线
		if t != null and _is_hostile(attacker, t) \
			and _can_see_cell(cell) and _has_los(Vector2i(attacker.col, attacker.row), cell):
			out.append(t)
	return out

# 选取形 → 世界格集合（🔒 决策30）：pick 掩码直落；pick 空但作用形锚自身 → 六旋转并集＝可点方向盘；
# 都空 → {}（调用方回退 range 圆盘）。越界格裁掉。
func _shape_pick_cells(u, skill) -> Dictionary:
	var out := {}
	var shp := SkillDB.shape_of(skill)
	var origin := Vector2i(u.col, u.row)
	var pick: Array = shp.get("pick", [])
	if not pick.is_empty():
		for c in HexGrid.mask_cells(origin, pick):
			if _cell_in_bounds(c.x, c.y):
				out[c] = true
		return out
	var eff: Array = shp.get("effect", [])
	if not eff.is_empty() and str(shp.get("anchor", "caster")) == "caster":
		for k in 6:
			for c in HexGrid.mask_cells(origin, eff, k):
				if _cell_in_bounds(c.x, c.y):
					out[c] = true
	return out

# 作用形落地（🔒 决策30）：anchor=target→掩码平移到所点格（火球）；anchor=caster→取「包含所点格」
# 的 60° 旋转档（横扫弧点哪打哪个方向；多解取首个）。找不到＝[]（点在形外）。
func _shape_effect_cells(attacker, shp: Dictionary, clicked: Vector2i) -> Array:
	var mask: Array = shp.get("effect", [])
	if str(shp.get("anchor", "caster")) == "target":
		return HexGrid.mask_cells(clicked, mask)
	var origin := Vector2i(attacker.col, attacker.row)
	for k in 6:
		var cells := HexGrid.mask_cells(origin, mask, k)
		if clicked in cells:
			return cells
	return []
