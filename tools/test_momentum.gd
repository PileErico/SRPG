extends SceneTree
## 气势系统回归（🔒 真值 docs/模块_战斗_气势.md）：层数公式（冗余区）/loadout 兑付表 resolver/
## 暗加成（effective_stat_f 平加＋速度）/攒泄缓冲与行动末结算（本击不吃本击·击倒翻倍·地板 0）/
## 衰减检定（必败/必过/落点公式）/满气势 AP 检定/徒手附加伤害/双手总伤系数/清零/快照往返（旧 morale 键忽略）。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_momentum.gd（退出码 0=PASS）

const BattleState := preload("res://BattleState.gd")
const Unit := preload("res://Unit.gd")
const UnitFactory := preload("res://UnitFactory.gd")
const ItemInstances := preload("res://ItemInstances.gd")
const WorldState := preload("res://WorldState.gd")

var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func mk(nm: String, fac: String, col: int, row: int) -> Unit:
	var u := Unit.new(nm, fac, col, row)
	u.stats["HP"] = int(u.stats.get("HP_max", 40))
	return u

func _initialize() -> void:
	print("=== 气势系统 测试开始 ===")
	WorldState.current = null

	# —— 1) 初始 0 / 层数公式（🔒 §2：min(5, 点数/4)，21~25 冗余区）/ init_vitals 清零 ——
	var u = mk("样本", "player", 3, 3)
	ck(u.momentum == 0 and u._momentum_pending == 0, "初始气势 0、缓冲 0")
	for pair in [[0, 0], [3, 0], [4, 1], [8, 2], [12, 3], [16, 4], [19, 4], [20, 5], [24, 5], [25, 5]]:
		u.momentum = int(pair[0])
		ck(u.momentum_layer() == int(pair[1]), "层数：%d 点 → %d 层（实际 %d）" % [int(pair[0]), int(pair[1]), u.momentum_layer()])
	u.momentum = 12
	u._momentum_pending = 3
	u.init_vitals()
	ck(u.momentum == 0 and u._momentum_pending == 0, "init_vitals 清零（战斗结束不跨带 🔒 §2）")

	# —— 2) loadout resolver（🔒 §4：优先级链＋副手分支＋天生武器＝徒手）——
	ItemInstances.clear()
	ck(u.momentum_profile() == "unarmed", "空手＝徒手表")
	u.equipment["main_hand"] = ItemInstances.create("rusty_dagger")
	ck(u.momentum_profile() == "one_hand", "单手武器·副手空＝单手表")
	u.equipment["off_hand"] = ItemInstances.create("wood_kite_shield")
	ck(u.momentum_profile() == "sword_board", "单手＋盾＝坚壁表")
	u.equipment["off_hand"] = ItemInstances.create("wooden_club")
	ck(u.momentum_profile() == "dual", "副手为武器＝双武器表")
	u.equipment["off_hand"] = 0
	u.equipment["main_hand"] = ItemInstances.create("sword_zweihande")
	ck(u.momentum_profile() == "two_handed", "双手武器＝破阵表")
	u.equipment["main_hand"] = ItemInstances.create("claw_wing")
	ck(u.momentum_profile() == "unarmed", "天生武器(innate)一律按徒手（🔒 §4）")
	u.equipment["main_hand"] = 0
	ItemInstances.clear()

	# —— 3) 暗加成（🔒 §4 表值经 effective_stat_f 平加；不可见＝不走修正管线）——
	u.momentum = 0
	var acc0 := u.effective_stat_f("acc")
	var spd0 := u.effective_stat("speed")
	u.momentum = 4    # 徒手 1 层：命中/闪避/暴防 +3
	ck(is_equal_approx(u.effective_stat_f("acc"), acc0 + 3.0), "徒手 1 层：acc +3（实际 %s）" % str(u.effective_stat_f("acc") - acc0))
	u.momentum = 20   # 5 层：+12；速度全表通用 +2
	ck(is_equal_approx(u.effective_stat_f("acc"), acc0 + 12.0), "徒手 5 层：acc +12")
	ck(is_equal_approx(u.effective_stat_f("crit_def"), 12.0), "徒手 5 层：暴击防御 +12（人底 0）")
	ck(u.effective_stat("speed") == spd0 + 2, "5 层速度 +2（🔒 §4 全表通用）")
	u.momentum = 16
	ck(u.effective_stat("speed") == spd0 + 1, "4 层速度 +1")
	u.momentum = 12
	ck(u.effective_stat("speed") == spd0, "3 层无速度加成")
	ck(is_equal_approx(u.momentum_bonus("atk_pct"), 0.0), "徒手表无总伤系数键＝0")
	u.momentum = 0

	# —— 4) 攒/泄缓冲 → 行动末结算（🔒 §3：本击不吃本击；地板 0；击倒翻倍）——
	var s = BattleState.new()
	s._new_grassland(9, 7)
	s.rng.seed = 20260720
	var a = mk("攻手", "player", 3, 3)
	var d = mk("靶子", "enemy", 4, 3)
	s.units = [a, d]
	a.stats["atk"] = 20.0
	a.stats["acc"] = 100.0   # hc 钳 95：循环内等首次命中（seed 固定）
	var r := {}
	for _i in range(64):
		a._momentum_pending = 0
		d._momentum_pending = 0
		r = s._resolve_compute(a, d, {"coeff": 1.0})
		if r.get("hit", false):
			break
		d.stats["HP"] = int(d.stats["HP_max"])
	ck(bool(r.get("hit", false)) and a._momentum_pending >= 1 and a.momentum == 0, "命中进缓冲、点数不动（本击不吃本击）")
	var dres: Dictionary = s._handle_deaths_state()
	ck(a._momentum_pending == 0 and a.momentum >= 1, "结算入账：缓冲清零、攻方 ≥1 点（实际 %d）" % a.momentum)
	ck(d.momentum == 0, "守方 −1 钳地板 0（零点单位泄点无效 🔒 §3）")
	var mevs: Array = dres.get("momentum", [])
	ck(mevs.size() >= 1, "结算事件上抛（供 debug/测试；宿主不渲染）")

	# 击倒翻倍：目标 1 HP，命中即打空 → 此击原始获取 ×2
	var a2 = mk("补刀手", "player", 3, 4)
	var d2 = mk("残敌", "enemy", 4, 4)
	s.units = [a2, d2]
	a2.stats["atk"] = 20.0
	a2.stats["acc"] = 100.0
	var rk := {}
	for _i in range(64):
		a2._momentum_pending = 0
		d2.stats["HP"] = 1
		d2.stats["armor"] = 0
		rk = s._resolve_compute(a2, d2, {"coeff": 1.0})
		if rk.get("hit", false) and not bool(rk.get("crit", false)) and not bool(rk.get("blocked", false)):
			break
	ck(int(rk.get("momentum_gain", 0)) == 2, "击倒翻倍：1(有效命中)×2＝2（实际 %d）" % int(rk.get("momentum_gain", 0)))
	var dres2: Dictionary = s._handle_deaths_state()
	ck((dres2["dead"] as Array).has(d2), "残敌离场")
	ck(a2.momentum == 2 and a2._momentum_pending == 0, "击倒者入账 2 点")

	# 上限钳 25 / 冗余区 chip 容错（掉点不掉层）
	a2.momentum = 24
	a2._momentum_pending = 5
	s.units = [a2]
	s._handle_deaths_state()
	ck(a2.momentum == 25, "上限钳 25（🔒 §2）")
	a2._momentum_pending = -3
	s._handle_deaths_state()
	ck(a2.momentum == 22 and a2.momentum_layer() == 5, "冗余区挨打掉点不掉层（22 点仍 5 层）")

	# —— 5) 衰减检定（🔒 §5：DC=10+层×5；失败＝min(点数−4, 19)）——
	var w = mk("持势者", "player", 1, 1)
	s.units = [w]
	w.stats["resolve"] = 0
	w.level = 1   # 修正 +0：DC 35 必败（d20 封顶 20）
	w.momentum = 25
	var dev: Dictionary = s._momentum_decay_tick(w)
	ck(not bool(dev.get("ok", true)) and w.momentum == 19, "满仓 25 必败 → 直落 19＝4 层上界（🔒 冗余软着陆）")
	w.momentum = 20
	dev = s._momentum_decay_tick(w)
	ck(w.momentum == 16, "20 点失败 → 16（非冗余区恰掉一层）")
	w.momentum = 17
	dev = s._momentum_decay_tick(w)
	ck(w.momentum == 13, "17 点失败 → 13（−4）")
	w.momentum = 3
	ck(s._momentum_decay_tick(w).is_empty(), "0 层不检定")
	w.stats["resolve"] = 30   # 修正 +30：1 层 DC 15 必过（最低总 31）
	w.momentum = 4
	dev = s._momentum_decay_tick(w)
	ck(bool(dev.get("ok", false)) and w.momentum == 4, "必过：点数不动")

	# —— 6) 满气势 AP 检定（🔒 §6：5 层＝满气势即可掷，非满点数）——
	w.stats["resolve"] = 1000   # 0.1×(1000+1)≈100.1% 必中
	w.momentum = 20             # 满气势＝5 层（20 点即可，非 25）
	w.ap = 2
	var apev: Dictionary = s._momentum_turn_start(w)
	ck(not apev.is_empty() and w.ap == 3, "满气势(20 点=5 层)必中：+1 AP（实际 %d）" % w.ap)
	w.momentum = 19             # 4 层＝不掷
	w.ap = 2
	ck(s._momentum_turn_start(w).is_empty() and w.ap == 2, "4 层不掷（满气势≠满点数的区分 🔒）")

	# —— 7) 徒手附加物理伤害（🔒 §4：ceil(等级×0.3×层数)，flat 添头不吃效能）——
	var m = mk("武僧", "player", 2, 2)
	m.level = 10
	m.momentum = 12   # 3 层 → ceil(10×0.3×3)=9
	ck(is_equal_approx(m.momentum_unarmed_flat(), 9.0), "徒手附加＝ceil(10×0.3×3)=9（实际 %s）" % str(m.momentum_unarmed_flat()))
	var dm = mk("木桩", "enemy", 3, 2)
	s.units = [m, dm]
	m.stats["atk"] = 20.0
	m.stats["acc"] = 100.0
	var rm := {}
	for _i in range(64):
		rm = s._resolve_compute(m, dm, {"coeff": 1.0})
		if rm.get("hit", false) and not bool(rm.get("crit", false)):
			break
		dm.stats["HP"] = int(dm.stats["HP_max"])
	ck(is_equal_approx(float(rm["out"]), 29.0), "徒手 out=20+9（附加不吃效能，实际 %s）" % str(rm.get("out")))

	# —— 8) 双手总伤系数（🔒 §4：atk_pct 走 atk_eff 因子）——
	ItemInstances.clear()
	var g = mk("大剑手", "player", 5, 5)
	g.equipment["main_hand"] = ItemInstances.create("sword_zweihande")
	g.momentum = 20   # 破阵 5 层：总伤 +12%
	var dg = mk("陪练", "enemy", 6, 5)
	s.units = [g, dg]
	g.stats["atk"] = 20.0
	g.stats["acc"] = 100.0
	var rg := {}
	for _i in range(64):
		rg = s._resolve_compute(g, dg, {"coeff": 1.0})
		if rg.get("hit", false):
			break
		dg.stats["HP"] = int(dg.stats["HP_max"])
	ck(is_equal_approx(float(rg["aeff"]), 1.12), "破阵 5 层：atk_eff 因子 ×1.12（实际 %s）" % str(rg.get("aeff")))
	g.equipment["main_hand"] = 0
	ItemInstances.clear()

	# —— 9) 快照往返（🔒 §8：momentum 入白名单；旧快照 morale 键忽略缺省 0）——
	var pa = mk("快照样本", "player", 0, 0)
	pa.momentum = 17
	var snap: Dictionary = UnitFactory.unit_to_battle_snapshot(pa)
	var back = UnitFactory.unit_from_battle_snapshot(JSON.parse_string(JSON.stringify(snap)))
	ck(back.momentum == 17, "battle 快照 momentum 往返（实际 %d）" % back.momentum)
	var legacy_snap: Dictionary = UnitFactory.unit_to_battle_snapshot(pa)
	legacy_snap.erase("momentum")
	legacy_snap["morale"] = 37   # 旧档字段：一律忽略
	var legacy = UnitFactory.unit_from_battle_snapshot(legacy_snap)
	ck(legacy.momentum == 0, "旧快照（morale 键）忽略 → momentum 0")

	if _fail == 0:
		print("=== 气势系统 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
