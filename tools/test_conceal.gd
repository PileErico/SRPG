extends SceneTree
## 隐蔽与视野 🔒（2026-07-19）回归：单位级可见性（隐蔽/邻近揭示/暴露/飞行豁免）+ 地块 tags 放置物合并 +
## ZOC 预览零泄露/借机门槛 + AI 对称 + 暴露快照往返。模型层独立跑（不建 Sandbox 场景）。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_conceal.gd（退出码 0=PASS）

const BattleState := preload("res://BattleState.gd")
const UnitFactory := preload("res://UnitFactory.gd")
const WorldState := preload("res://WorldState.gd")
const TerrainDB := preload("res://TerrainDB.gd")

var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _initialize() -> void:
	print("=== 隐蔽与视野 测试开始 ===")
	WorldState.current = null
	var protos := UnitFactory.all_prototypes()
	ck(not protos.is_empty(), "有内置原型可用")

	var s = BattleState.new()
	s._new_grassland(9, 9)
	s.phase = "battle"
	# 列 3 竖直走廊（flat-top 同列＝直线）：森林 (3,2)、(3,4)
	s.tiles[2][3] = {"terrain": "forest", "variant": "forest"}
	s.tiles[4][3] = {"terrain": "forest", "variant": "forest"}

	# —— 1) 生效数据＝放置物压过底地形 🔒（2026-07-19 用户令）——
	ck("cover" in s._tile_tags_at(3, 2) and "blocks_sight" in s._tile_tags_at(3, 2), "森林整块含 cover/blocks_sight")
	s.tiles[6][6] = {"terrain": "plain", "variant": "grassland", "object": {"terrain": "forest", "variant": "forest"}}
	ck("cover" in s._tile_tags_at(6, 6) and "blocks_sight" in s._tile_tags_at(6, 6), "放置物森林：tags 按放置物计算（挡视线/可隐蔽）")
	ck(not ("open" in s._tile_tags_at(6, 6)), "tags 覆盖非并集：底地形独有 tag 不保留")
	ck(s._tile_conceals(6, 6) and s._tile_blocks_sight(6, 6), "放置物森林：隐蔽+挡视线判定生效")
	ck(not s._tile_conceals(3, 3), "草地不隐蔽")
	# 道路放置物铺森林底 → 整格变开阔道路（tags/move 全随放置物）
	s.tiles[6][5] = {"terrain": "forest", "variant": "forest", "object": {"terrain": "randr", "variant": "road_0"}}
	ck(not s._tile_conceals(5, 6) and not s._tile_blocks_sight(5, 6), "道路铺森林：不挡视线不可隐蔽")
	# 效果合并：同类取高 / 不同类放置物压过（临时改内存 live 表模拟「要塞+20」，测完还原、不落盘）
	var road_e = TerrainDB.entry_for({"terrain": "randr", "variant": "road_0"})
	var saved_fx = road_e.get("effects", [])
	var otile := {"terrain": "forest", "variant": "forest", "object": {"terrain": "randr", "variant": "road_0"}}
	road_e["effects"] = [{"name": "要塞工事", "grant": {"layer": "效能", "stat": "evasion", "percent": 20, "nature": "buff"}}]
	var mfx: Array = TerrainDB.applied_effects(otile)
	ck(mfx.size() == 1 and int(mfx[0]["grant"]["percent"]) == 20, "同类取高：森林15底×放置物20→按20")
	road_e["effects"] = [{"name": "要塞工事", "grant": {"layer": "效能", "stat": "evasion", "percent": 10, "nature": "buff"}}]
	mfx = TerrainDB.applied_effects(otile)
	ck(mfx.size() == 1 and int(mfx[0]["grant"]["percent"]) == 15, "同类取高：放置物10<底15→取底15（整条随强者）")
	road_e["effects"] = [{"name": "路损", "grant": {"layer": "tick", "kind": "damage", "amount": 3}}]
	mfx = TerrainDB.applied_effects(otile)
	ck(mfx.size() == 1 and str(mfx[0]["grant"]["layer"]) == "tick", "不同类：放置物压过去，底地形独有效果不生效")
	road_e["effects"] = saved_fx
	ck(TerrainDB.applied_effects({"terrain": "forest", "variant": "forest"}).size() == 1, "无放置物＝底地形效果，零回归")

	# —— 2) LOS：挡中间格、终点格不挡 ——
	ck(not s._has_los(Vector2i(3, 0), Vector2i(3, 4)), "森林(3,2)挡背后：(3,0)看不见(3,4)")
	ck(s._has_los(Vector2i(3, 0), Vector2i(3, 2)), "终点格自身不挡：森林格本身可见")

	# —— 3) 单位级可见性：隐蔽/邻近揭示（全队共享）/暴露/飞行 ——
	var pa = UnitFactory.make_unit(protos[0], "player", 3, 0)   # 观察者甲
	var pb = UnitFactory.make_unit(protos[0], "player", 6, 0)   # 观察者乙（远处，吃共享揭示）
	var ec = UnitFactory.make_unit(protos[0], "enemy", 3, 2)    # 藏进森林的敌人
	for u in [pa, pb, ec]:
		u.stats["sight"] = 8
	s.units = [pa, pb, ec]
	s.roster = [pa, pb]
	ck(s._move_cost_at(6, 6, pa) == 2, "放置物森林：移动成本按放置物（草底也 2）")
	ck(s._move_cost_at(5, 6, pa) == 1, "道路铺森林：成本按道路 1")
	s._recompute_vision_state()
	ck(s._vis_visible.has(Vector2i(3, 2)), "森林格本身在团队视野内")
	ck(not s._unit_visible_to_side(pa, ec), "隐蔽：格可见但单位不可见")
	ck(s._unit_hidden_by_fog(ec), "渲染口径：隐蔽单位对玩家隐藏")
	pb.col = 3; pb.row = 1   # 乙贴脸（距离1）
	ck(s._unit_visible_to_side(pa, ec), "邻近揭示：任一己方邻近→全队可见（甲也看见）")
	pb.col = 6; pb.row = 0   # 乙撤走→复归隐蔽
	ck(not s._unit_visible_to_side(pa, ec), "邻近者离开→复归隐蔽")
	s.exposed[ec.get_instance_id()] = true
	ck(s._unit_visible_to_side(pa, ec), "暴露＝隐蔽失效（远距即可见）")
	s._wrap_round()
	ck(s.exposed.is_empty() and not s._unit_visible_to_side(pa, ec), "round 末暴露到期→复归隐蔽")
	# 飞行目标对所有人可见：森林里的飞行单位不隐蔽；森林背后的飞行单位不受遮挡
	ec.tags.append("flying")
	ck(s._unit_visible_to_side(pa, ec), "飞行不能隐蔽（森林格上仍可见）")
	ec.col = 3; ec.row = 4   # 森林(3,2)背后
	ck(s._unit_visible_to_side(pa, ec), "飞行目标不受中间格遮挡（距离≤视野即可见）")
	ec.tags.erase("flying")
	ck(not s._unit_visible_to_side(pa, ec), "落地即恢复地形遮挡（格不可见→单位不可见）")
	# 飞行观察者免 LOS 裁剪
	pa.tags.append("flying")
	ck(s._unit_visible_cells(pa).has(Vector2i(3, 4)), "飞行观察者：视野圈内无视 blocks_sight")
	pa.tags.erase("flying")

	# —— 4) 攻击 targeting：单体需单位可见（隐蔽格＝点空）——
	ec.col = 3; ec.row = 2
	s._recompute_vision_state()
	ck(s._attack_targets(pa, Vector2i(3, 2), pa.basic_attack()).is_empty(), "隐蔽未揭示：单体攻击点不中")
	s.exposed[ec.get_instance_id()] = true
	ck(s._attack_targets(pa, Vector2i(3, 2), pa.basic_attack()).size() == 1, "暴露后可正常锁定")
	s.exposed.clear()

	# —— 5) 暴露钩子：出手即暴露；被命中才暴露 ——
	s.rng.seed = 20260719
	var r: Dictionary = s._resolve_compute(ec, pa, ec.basic_attack())
	ck(s.exposed.has(ec.get_instance_id()), "攻击者出手即暴露（无论命中）")
	ck(s.exposed.has(pa.get_instance_id()) == bool(r.get("hit", false)), "被攻击：命中才暴露")

	# —— 6) ZOC（三格宽墙走廊，几何可控）：预览零泄露 / 停步集 / 内部耗尽 / 借机门槛 ——
	var s6 = BattleState.new()
	s6._new_grassland(3, 7)
	s6.phase = "battle"
	for rr in 7:
		s6.tiles[rr][0] = {"terrain": "wall", "variant": "wall"}
		s6.tiles[rr][2] = {"terrain": "wall", "variant": "wall"}
	s6.tiles[1][1] = {"terrain": "forest", "variant": "forest"}   # 藏匿点 (1,1)
	var em = UnitFactory.make_unit(protos[0], "enemy", 1, 1)      # 藏进森林的伏击者
	var pm = UnitFactory.make_unit(protos[0], "player", 1, 5)     # 走廊里的移动者
	em.stats["sight"] = 8
	pm.stats["sight"] = 8
	s6.units = [pm, em]
	s6.roster = [pm]
	s6._rebuild_turn_order()
	s6._add_effect(em, {"name": "测试扩圈", "kind": "buff", "duration": 9,
		"mods": [{"stat": "zoc_radius", "op": "flat", "value": 1}]})   # 半径 2：ZOC 盖 (1,2)/(1,3)
	ck(s6._zoc_radius(em) == em.zoc_base() + 1, "ZOC 半径修正挂载")
	ck(not s6._unit_visible_to_side(pm, em), "走廊：森林里的伏击者不可见（格可见、单位隐蔽）")
	var reach_probe := {Vector2i(1, 2): true, Vector2i(1, 3): true}
	ck(s6._enemy_zoc_in_range(pm, reach_probe).is_empty(), "隐蔽拥有者的 ZOC 不标红（预览零泄露）")
	ck(s6._dijkstra(pm, 4)["best"].has(Vector2i(1, 2)), "隐蔽 ZOC 不入寻路停步集（可穿 (1,3) 达 (1,2)）")
	s6.exposed[em.get_instance_id()] = true
	ck(not s6._dijkstra(pm, 4)["best"].has(Vector2i(1, 2)), "暴露后踏入 (1,3) 即停：(1,2) 不可达")
	ck(not s6._enemy_zoc_in_range(pm, reach_probe).is_empty(), "暴露后 ZOC 照常标红")
	s6.exposed.clear()
	ck(not s6._in_hostile_zoc(Vector2i(1, 3), pm, true) and s6._in_hostile_zoc(Vector2i(1, 3), pm),
		"内部耗尽类判定只认可见拥有者（visible_only）")
	# 反向豁免：拥有者看不见（隐蔽的）移动者 → 其 ZOC 不停步不标红（「隐蔽单位进敌 ZOC 不触发借机/停步」）
	s6.tiles[5][1] = {"terrain": "forest", "variant": "forest"}   # 移动者脚下变森林＝隐蔽
	s6.exposed[em.get_instance_id()] = true                       # 伏击者暴露＝对移动方可见
	ck(s6._dijkstra(pm, 4)["best"].has(Vector2i(1, 2)), "隐蔽移动者：可见敌 ZOC 也不停步（畅行）")
	ck(s6._enemy_zoc_in_range(pm, reach_probe).is_empty(), "隐蔽移动者：ZOC 不标红（对它无压力）")
	s6.exposed[pm.get_instance_id()] = true                       # 双方可见→回归常规
	ck(not s6._dijkstra(pm, 4)["best"].has(Vector2i(1, 2)), "双方可见：踏入即停恢复")
	s6.exposed.clear()
	# 借机门槛：移动者也藏进森林 (1,3)（距伏击者 2、无人邻近）→ 拥有者看不见＝不借机
	s6.tiles[3][1] = {"terrain": "forest", "variant": "forest"}
	pm.col = 1; pm.row = 3
	ck(s6._first_zoc_owner(Vector2i(1, 3), pm) == null, "拥有者看不见隐蔽移动者→不借机（不可见不反应）")
	s6.exposed[pm.get_instance_id()] = true
	ck(s6._first_zoc_owner(Vector2i(1, 3), pm) == em, "移动者暴露→借机照常")
	s6.exposed.clear()

	# —— 7) AI 对称：看不见就当不存在 ——
	ck(s6._ai_nearest_hostile(em) == null, "AI 选目标：隐蔽单位不入选")
	em.ai_threat = true
	ck(not s6._ai_should_aggro(em), "AI 视野警觉：隐蔽不触发")
	s6.exposed[pm.get_instance_id()] = true
	ck(s6._ai_nearest_hostile(em) == pm and s6._ai_should_aggro(em), "暴露后 AI 照常感知")
	# ①视野警觉＝本单位自己的视距（不升格全侧共享——同伴看见≠我警觉，分批遭遇/连锁编组语义保全）
	var s7 = BattleState.new()
	s7._new_grassland(1, 9)
	s7.phase = "battle"
	var p7 = UnitFactory.make_unit(protos[0], "player", 0, 0)
	var e_near = UnitFactory.make_unit(protos[0], "enemy", 0, 2)
	var e_far = UnitFactory.make_unit(protos[0], "enemy", 0, 8)
	p7.stats["sight"] = 8
	e_near.stats["sight"] = 8
	e_far.stats["sight"] = 2   # 视距 2 够不到 (0,0) 的玩家（距 8）
	e_near.ai_threat = true
	e_far.ai_threat = true
	s7.units = [p7, e_near, e_far]
	s7.roster = [p7]
	ck(s7._ai_should_aggro(e_near), "①视野警觉：近哨自己看得见→警觉")
	ck(not s7._ai_should_aggro(e_far), "①视野警觉：远兵超出自身视距→不因同伴看见而警觉")

	# —— 8) 暴露快照往返 ——
	var d: Dictionary = s6.to_dict()
	var d2 = JSON.parse_string(JSON.stringify(d))
	var s2 = BattleState.new()
	ck(s2.restore(d2), "快照复原成功")
	var restored = null
	for u in s2.units:
		if u.col == pm.col and u.row == pm.row:
			restored = u
	ck(restored != null and s2.exposed.has(restored.get_instance_id()), "暴露状态随快照往返（新 instance_id 重铸）")

	if _fail == 0:
		print("=== 全部断言 PASS ===")
	else:
		print("=== FAIL x%d ===" % _fail)
	quit(1 if _fail > 0 else 0)
