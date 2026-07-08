extends SceneTree
## 士气骨架 v1 回归（🔒 模块_属性成长_设计.md §10.7）：初始/决心耦合/损失抵消保底/回合开始步
## （邻近差·常态回归·不叠加）/击杀+3/真死全场−5（重伤离场不触发）/档位边界/快照往返。
## 档位战斗判定（±命中/伤害）延后批次，不在此覆盖。邻格一律经 _neighbors() 程序化布置（不猜奇偶）。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_morale.gd（退出码 0=PASS）

const BattleState := preload("res://BattleState.gd")
const UnitFactory := preload("res://UnitFactory.gd")
const WorldState := preload("res://WorldState.gd")

var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _initialize() -> void:
	print("=== 士气骨架 测试开始 ===")
	WorldState.current = null   # 纯沙盒域（非铁人）
	var protos := UnitFactory.all_prototypes()
	ck(not protos.is_empty(), "有内置原型可用")

	# —— 1) 初始值与决心耦合（init_vitals）——
	var s = BattleState.new()
	s._new_grassland(9, 7)
	var nbs: Array = s._neighbors(3, 3)   # 中心 (3,3) 的六个邻格
	ck(nbs.size() == 6, "中心格有 6 邻格")
	var pa = UnitFactory.make_unit(protos[0], "player", 3, 3)
	ck(pa.morale == 25, "决心 0 → 初始士气 25（实际 %d）" % pa.morale)
	ck(pa.morale_band() == 2 and pa.morale_band_name() == "稳定", "25 落稳定档")
	var pb = UnitFactory.make_unit(protos[0], "player", nbs[0].x, nbs[0].y)   # 友军贴脸
	pb.stats["resolve"] = 3
	pb.init_vitals()
	ck(pb.morale == 28, "决心 3 → 初始 25+3=28（🔒 二次修订 +1/点，实际 %d）" % pb.morale)
	ck(pb.morale_band_name() == "稳定", "28 落稳定档（档界 20~29）")
	# 档界全边界（🔒 每 10 一档：0~9/10~19/20~29/30~39/40~50）
	var edges := {0: "崩溃", 9: "崩溃", 10: "动摇", 19: "动摇", 20: "稳定", 29: "稳定",
		30: "高昂", 39: "高昂", 40: "狂热", 50: "狂热"}
	for v in edges:
		pb.morale = v
		ck(pb.morale_band_name() == edges[v], "档界 %d → %s（实际 %s）" % [v, edges[v], pb.morale_band_name()])
	pb.morale = 31

	# —— 2) _morale_add：决心抵消、保底 1、上下钳 ——
	var e1 = UnitFactory.make_unit(protos[0], "enemy", nbs[1].x, nbs[1].y)   # 敌贴脸
	var e2 = UnitFactory.make_unit(protos[0], "enemy", 7, 6)                  # 敌远处
	s.units = [pa, pb, e1, e2]
	ck(s._morale_add(pa, -5) == -5 and pa.morale == 20, "决心 0：−5 全额（→20）")
	ck(s._morale_add(pb, -5) == -4 and pb.morale == 27, "决心 3：抵 floor(1.5)=1 → −4（→27，🔒 0.5/点）")
	ck(s._morale_add(pb, -1) == -1, "决心 3：−1 保底仍 −1")
	pa.morale = 1
	ck(s._morale_add(pa, -5) == -1 and pa.morale == 0, "下限钳 0")
	pa.morale = 49
	ck(s._morale_add(pa, 3) == 1 and pa.morale == 50, "上限钳 50")
	ck(pa.morale_band_name() == "狂热", "50 归狂热档")
	ck(s._morale_add(pa, 0) == 0, "0 变化＝无事发生")

	# —— 3) 回合开始步：邻近差 / 常态回归 / 不叠加 ——
	pa.morale = 40
	var ev: Dictionary = s._morale_turn_tick(pa)   # 邻敌1(e1) 邻友1(pb) → 差 0，无损失；有邻敌也不衰减
	ck(ev.is_empty() and pa.morale == 40, "邻敌1友1：差 0 无损失、且不衰减（不叠加规则）")
	e2.col = nbs[2].x
	e2.row = nbs[2].y                              # 第二个敌贴脸 → 邻敌2 友1 = 损失 1
	ev = s._morale_turn_tick(pa)
	ck(ev.get("delta", 0) == -1 and pa.morale == 39, "邻敌2友1：−1（→%d）" % pa.morale)
	var lone = UnitFactory.make_unit(protos[0], "player", 0, 6)   # 角落无邻居
	s.units.append(lone)
	lone.morale = 30
	ev = s._morale_turn_tick(lone)
	ck(ev.get("delta", 0) == -1 and lone.morale == 29, "无邻敌 >25：−1 回归")
	lone.morale = 10
	ev = s._morale_turn_tick(lone)
	ck(ev.get("delta", 0) == 1 and lone.morale == 11, "无邻敌 <25：+1 回归")
	lone.morale = 25
	ev = s._morale_turn_tick(lone)
	ck(ev.is_empty() and lone.morale == 25, "无邻敌 =25：常态不动")
	pb.morale = 30
	pb.col = 0
	pb.row = 0                                     # 挪去空角：决心不影响 −1 回归（保底 1）
	ev = s._morale_turn_tick(pb)
	ck(pb.morale == 29, "决心 3 的 >25 回归仍 −1（保底）")

	# —— 4) 收尸士气：击败者 +3；真死全场同侧 −5；重伤离场无全场事件 ——
	pa.morale = 25
	pb.morale = 25
	e1.morale = 25
	lone.morale = 25
	e2.stats["HP"] = 0                             # 常规敌兵（无死门资格）被 pa 击杀
	e2.last_hit_by = pa
	var hd: Dictionary = s._handle_deaths_state()
	ck(hd["dead"].has(e2), "常规敌兵即死离场")
	ck(pa.morale == 28, "击败者 +3（实际 %d）" % pa.morale)
	ck(e1.morale == 20, "同侧存活者全场 −5（实际 %d）" % e1.morale)
	ck(pb.morale == 25 and lone.morale == 25, "敌方之死不影响我方全场士气")
	pb.stats["HP"] = 0                             # 我方转死门（不死）→ 无士气事件
	pb.last_hit_by = e1
	hd = s._handle_deaths_state()
	ck(hd["entered_door"].has(pb), "我方归零转死门")
	ck(pa.morale == 28 and lone.morale == 25 and e1.morale == 20, "进死门无士气事件")
	pb.door_gauge = -3
	ck(s._door_settle_state(pb) == "down_injured", "非铁人 −3＝重伤离场")
	e1.morale = 25
	hd = s._handle_deaths_state()
	ck(hd["dead"].has(pb), "重伤离场移出战斗")
	ck(e1.morale == 28, "击败者 +3（重伤离场也算击败）")
	ck(pa.morale == 28 and lone.morale == 25, "重伤离场≠挂了：无全场 −5")

	# —— 4b) 档位战斗判定 🔒（§10.7 表，2026-07-08 接线）：命中平加 ±5/10 + 伤害 atk_eff 因子 ——
	var atk_u = UnitFactory.make_unit(protos[0], "player", 3, 3)
	var def_u = UnitFactory.make_unit(protos[0], "enemy", 4, 3)
	s.units = [atk_u, def_u]
	for pair in [[0, -10], [15, -5], [25, 0], [35, 5], [50, 10]]:
		atk_u.morale = int(pair[0])
		ck(atk_u.morale_combat_mod() == int(pair[1]), "档位判定值：士气 %d → %+d" % [int(pair[0]), int(pair[1])])
	atk_u.morale = 25
	var hc_base: int = s._hit_chance(atk_u, def_u)
	atk_u.morale = 50
	ck(s._hit_chance(atk_u, def_u) == hc_base + 10, "狂热：命中 +10（%d→%d）" % [hc_base, s._hit_chance(atk_u, def_u)])
	atk_u.morale = 5
	ck(s._hit_chance(atk_u, def_u) == hc_base - 10, "崩溃：命中 −10")
	atk_u.stats["acc"] = 200.0   # 钳 95 内必命中，取 aeff 断言伤害因子
	var rr := {}
	for _i in range(64):
		atk_u.morale = 50
		rr = s._resolve_compute(atk_u, def_u, {"coeff": 1.0})
		if rr.get("hit", false):
			break
		def_u.stats["HP"] = int(def_u.stats["HP_max"])
	ck(rr.get("hit", false) and is_equal_approx(float(rr["aeff"]), 1.1), "狂热：atk_eff 因子 ×1.1（实际 %s）" % str(rr.get("aeff")))

	# —— 5) 快照往返：morale 字段 ——
	pa.morale = 37
	var snap: Dictionary = UnitFactory.unit_to_battle_snapshot(pa)
	var back = UnitFactory.unit_from_battle_snapshot(JSON.parse_string(JSON.stringify(snap)))
	ck(back.morale == 37, "battle 快照 morale 往返（实际 %d）" % back.morale)
	var legacy_snap: Dictionary = UnitFactory.unit_to_battle_snapshot(pa)
	legacy_snap.erase("morale")
	var legacy = UnitFactory.unit_from_battle_snapshot(legacy_snap)
	ck(legacy.morale == 25, "旧快照缺省 morale=25")

	if _fail == 0:
		print("=== 士气骨架 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
