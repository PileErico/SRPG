extends SceneTree
## 战斗结算链定向回归（路线图·技术债 P2「战斗结算链定向测试」2026-07-07 补齐）：
## _resolve_compute 分支（命中/暴击/格挡/穿甲分量/气势挂点，用钳位边界与超阈值 stat 造确定性分支）/
## end_turn DoT 致死（真死收尸链 + 死门转入 + 气势零事件——DoT 无命中判定不攒）/ ZOC 借机模型（去重键/控制区/入区截断）/
## _dijkstra 行为锚（草原成本/ZOC 截断——二叉堆重构的保绿基线）。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_resolve_chain.gd（退出码 0=PASS）

const BattleState := preload("res://BattleState.gd")
const Unit := preload("res://Unit.gd")
const ItemInstances := preload("res://ItemInstances.gd")   # 副手惩罚盾豁免用例（阶段3b）

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
	print("=== 战斗结算链 测试开始 ===")

	# —— 1) _resolve_compute：确定性分支（钳位/超阈值构造，不依赖赌骰）——
	var s = BattleState.new()
	s._new_grassland(9, 7)
	s.rng.seed = 20260707   # 注入定序（战斗骰统一过 BattleState.rng——技改 §1-1）
	var a = mk("攻手", "player", 3, 3)
	var d = mk("靶子", "enemy", 4, 3)
	s.units = [a, d]
	# 必不暴击：cr = 0 + 10×0.5 − 5 = 0；必不格挡：block_rate 0
	a.stats["atk"] = 20.0
	a.stats["acc"] = 100.0   # hc 钳 95，循环内等第一次命中（seed 固定＝序列确定）
	var r := {}
	for _i in range(64):
		a._momentum_pending = 0   # 重置缓冲，保证命中样本的气势断言干净（失手本就无事件）
		d._momentum_pending = 0
		r = s._resolve_compute(a, d, {"coeff": 1.0})
		if r.get("hit", false):
			break
		d.stats["HP"] = int(d.stats["HP_max"])   # 失手不掉血，防御性重置
	ck(bool(r.get("hit", false)), "64 次内必出命中（hc=95）")
	ck(not bool(r["crit"]) or is_equal_approx(float(r["cmult"]),
		(float(a.stats["crit_dmg"]) + float(a.stats["luck"]) * 0.5) / 100.0),
		"暴击时 cmult=(crit_dmg+运气×0.5)/100（🔒 运气加爆伤）")
	ck(is_equal_approx(float(r["cr"]), 0.0) and not bool(r["crit"]), "基线 cr=0 必不暴击")
	ck(not bool(r["blocked"]) and is_equal_approx(float(r["bp"]), 0.0), "block_rate 0 必不格挡（bp=0）")
	ck(int(r.get("momentum_gain", 0)) == 1 and a._momentum_pending == 1, "命中未格挡：攻方气势缓冲 +1（🔒 气势档 §3）")
	ck(d._momentum_pending == -1 and a.momentum == 0 and d.momentum == 0, "被有效命中：守方缓冲 −1；结算前点数不动（本击不吃本击）")
	ck(is_equal_approx(float(r["out"]), 20.0), "无暴击无效能：out=atk×coeff=20")
	ck(int(r["hp_after"]) == int(d.stats["HP"]), "r.hp_after 与靶子实血一致")
	ck(d.last_hit_by == a, "last_hit_by 记录击杀归属")

	# 必暴击：crit_rate 200 → cr≥100；必格挡：block_rate 100
	var d2 = mk("盾手", "enemy", 5, 3)
	d2.stats["block_rate"] = 100.0
	d2.stats["block_power"] = 50.0
	s.units = [a, d2]
	a.stats["crit_rate"] = 200.0
	a._momentum_pending = 0
	d2._momentum_pending = 0
	var r2 := {}
	for _i in range(64):
		r2 = s._resolve_compute(a, d2, {"coeff": 1.0})
		if r2.get("hit", false):
			break
	ck(bool(r2["crit"]) and float(r2["cr"]) >= 100.0, "crit_rate 200 必暴击")
	ck(bool(r2["blocked"]) and is_equal_approx(float(r2["bp"]), 50.0), "block_rate 100 必格挡（bp=50）")
	ck(int(r2.get("momentum_gain", 0)) == 1, "被格挡的暴击仍 +1（暴击点不受格挡影响 🔒 气势档 §3）")
	ck(d2._momentum_pending == -1, "被格挡的暴击：守方对称 −1")
	a.stats["crit_rate"] = 0.0

	# 穿甲分量：armor_pen 0.5 → 人/甲各半（atk20 → hp 10 + 甲 10）
	var d3 = mk("甲靶", "enemy", 4, 4)
	d3.stats["armor"] = 10.0
	d3.stats["armor_max"] = 10.0
	d3.stats["block_rate"] = 0.0
	s.units = [a, d3]
	var r3 := {}
	for _i in range(64):
		r3 = s._resolve_compute(a, d3, {"coeff": 1.0, "armor_pen": 0.5})
		if r3.get("hit", false) and not bool(r3.get("crit", false)):
			break
		d3.stats["HP"] = int(d3.stats["HP_max"])
		d3.stats["armor"] = 10.0
	ck(int(r3["hp_loss"]) == 10 and int(r3["armor_loss"]) == 10,
		"穿甲 0.5：血甲各失 10（实际 %d/%d）" % [int(r3["hp_loss"]), int(r3["armor_loss"])])

	# 副手惩罚（🔒 决策5/§7.1 阶段3b）：weapon_source=off_hand → out ×offhand_eff/100；offhand_factor 再乘；盾豁免
	var d5 = mk("副手靶", "enemy", 5, 4)
	d5.stats["block_rate"] = 0.0
	s.units = [a, d5]
	var r5 := {}
	for _i in range(64):
		a._momentum_pending = 0
		r5 = s._resolve_compute(a, d5, {"coeff": 1.0, "weapon_source": "off_hand"})
		if r5.get("hit", false):
			break
		d5.stats["HP"] = int(d5.stats["HP_max"])
	ck(is_equal_approx(float(r5["offhand"]), 0.5) and is_equal_approx(float(r5["out"]), 10.0),
		"off_hand 无盾：×offhand_eff 50/100 → out=10")
	a.modifiers.append({"stat": "offhand_eff", "op": "flat", "value": 25, "source": "perk:单手精通"})
	for _i in range(64):
		a._momentum_pending = 0
		r5 = s._resolve_compute(a, d5, {"coeff": 1.0, "weapon_source": "off_hand"})
		if r5.get("hit", false):
			break
		d5.stats["HP"] = int(d5.stats["HP_max"])
	ck(is_equal_approx(float(r5["offhand"]), 0.75), "单手精通 perk flat+25 → ×0.75（走修正管线）")
	for _i in range(64):
		a._momentum_pending = 0
		r5 = s._resolve_compute(a, d5, {"coeff": 1.0, "weapon_source": "off_hand", "offhand_factor": 0.5})
		if r5.get("hit", false):
			break
		d5.stats["HP"] = int(d5.stats["HP_max"])
	ck(is_equal_approx(float(r5["offhand"]), 0.375), "偷击 offhand_factor 0.5 再乘 → 0.75×0.5=0.375（§7.1 恒定 1.5 倍关系）")
	a.modifiers.clear()
	for _i in range(64):
		a._momentum_pending = 0
		r5 = s._resolve_compute(a, d5, {"coeff": 1.0})
		if r5.get("hit", false):
			break
		d5.stats["HP"] = int(d5.stats["HP_max"])
	ck(is_equal_approx(float(r5["offhand"]), 1.0), "无 weapon_source（主手/缺省）→ 不吃惩罚")
	ItemInstances.clear()
	a.equipment["off_hand"] = ItemInstances.create("wood_kite_shield")
	for _i in range(64):
		a._momentum_pending = 0
		r5 = s._resolve_compute(a, d5, {"coeff": 1.0, "weapon_source": "off_hand"})
		if r5.get("hit", false):
			break
		d5.stats["HP"] = int(d5.stats["HP_max"])
	ck(is_equal_approx(float(r5["offhand"]), 1.0), "副手持盾 → 豁免副手惩罚（§7.1 非盾条件）")
	a.equipment["off_hand"] = 0
	ItemInstances.clear()

	# 未命中分支：eva 拉满 → hc 钳 5，等第一次失手
	var dodge = mk("闪客", "enemy", 4, 2)
	dodge.stats["eva"] = 300.0
	s.units = [a, dodge]
	var r4 := {}
	for _i in range(64):
		r4 = s._resolve_compute(a, dodge, {"coeff": 1.0})
		if not r4.get("hit", true):
			break
	ck(not bool(r4.get("hit", true)), "64 次内必出失手（hc=5）")
	ck(not r4.has("momentum_gain"), "失手：气势两侧均无事件（骰运不双重计费 🔒 气势档 §3）")

	# —— 2) end_turn DoT 致死：真死收尸链 + 士气挂点 ——
	var s2 = BattleState.new()
	s2._new_grassland(9, 7)
	var hero = mk("英雄", "player", 1, 1)
	var victim = mk("毒亡卒", "enemy", 5, 5)
	var mate = mk("同伙", "enemy", 6, 5)
	s2.units = [hero, victim, mate]
	s2.turn_order = s2._sorted_by_speed(s2.units)
	victim.stats["HP"] = 3
	victim.effects = [{"name": "剧毒", "dot_pct_max_hp": 10, "duration": 3}]   # 40×10%=4 > 3
	victim.last_hit_by = hero
	var evs: Array = s2._apply_turn_end_effects(victim)
	ck(evs.size() >= 1 and str(evs[0]["type"]) == "dot" and int(evs[0]["dmg"]) == 4, "DoT 事件：-4（HP_max 10%）")
	ck(int(victim.stats["HP"]) <= 0, "DoT 扣穿血线")
	var dres: Dictionary = s2._handle_deaths_state()
	ck((dres["dead"] as Array).has(victim), "无死门资格敌兵：DoT 即死")
	ck(not s2.units.has(victim) and not s2.turn_order.has(victim), "死者移出 units/turn_order")
	ck(hero.momentum == 0 and hero._momentum_pending == 0, "DoT 致死无命中判定：不攒气势（🔒 气势档 §3）")
	var mevs: Array = dres.get("momentum", [])
	ck(mevs.is_empty(), "无缓冲＝零气势事件（实得 %d）" % mevs.size())

	# DoT 打入死门（我方＝有资格）：转入而非死
	var s3 = BattleState.new()
	s3._new_grassland(9, 7)
	var ally = mk("重伤兵", "player", 2, 2)
	s3.units = [ally, mk("路人敌", "enemy", 6, 6)]
	s3.turn_order = s3._sorted_by_speed(s3.units)
	ally.stats["HP"] = 2
	ally.effects = [{"name": "流血", "dot_pct_max_hp": 10, "duration": 2}]
	s3._apply_turn_end_effects(ally)
	var dres3: Dictionary = s3._handle_deaths_state()
	ck((dres3["entered_door"] as Array).has(ally), "我方 DoT 归零：转入死门")
	ck(ally.tags.has("deaths_door") and int(ally.stats["HP"]) == 0, "死门态：挂 tag、HP 钳 0")
	ck(is_equal_approx(ally.effective_stat_f("agility"), 5.0), "死门 debuff：灵活减半（🔒§10.6 改打灵活）")
	ck(s3.units.has(ally), "死门单位仍在场占格")

	# —— 3) ZOC 借机模型：控制区 / 去重键 / 每 round 一次 ——
	var s4 = BattleState.new()
	s4._new_grassland(9, 7)
	var mover = mk("走位者", "player", 1, 1)
	var guard = mk("拦路敌", "enemy", 3, 1)
	s4.units = [mover, guard]
	ck(s4._in_hostile_zoc(Vector2i(2, 1), mover), "敌邻格＝敌 ZOC")
	ck(not s4._in_hostile_zoc(Vector2i(1, 1), mover), "距 2 格不在 ZOC")
	ck(s4._first_zoc_owner(Vector2i(2, 1), mover) == guard, "借机拥有者＝拦路敌")
	s4.zoc_triggered[s4._zoc_key(guard, mover)] = true
	ck(s4._first_zoc_owner(Vector2i(2, 1), mover) == null, "同 round 同对子已触发＝不再借机")
	ck(s4._first_zoc_owner(Vector2i(0, 1), mover) == null, "仅邻己方/自己的格＝无借机拥有者")
	var dij: Dictionary = s4._dijkstra(mover, 4)
	var reach: Dictionary = dij["best"]
	var zmarks: Dictionary = s4._enemy_zoc_in_range(mover, reach)
	ck(zmarks.has(Vector2i(2, 1)), "范围内敌 ZOC 格被标出")

	# —— 4) _dijkstra 行为锚（重构保绿基线）：草原直线成本 + ZOC 入区截断 ——
	ck(int(reach.get(Vector2i(2, 1), -1)) == 1, "ZOC 格本身可达（成本 1）")
	var via_zoc := false   # 入区即停：前驱树里不允许出现 ZOC 中转格
	var came: Dictionary = dij["came_from"]
	var origin := Vector2i(mover.col, mover.row)
	for c in came:
		var p: Vector2i = came[c]
		if p != origin and s4._in_hostile_zoc(p, mover):
			via_zoc = true
	ck(not via_zoc, "无任何格经 ZOC 格外扩（前驱树不含 ZOC 中转）")
	var s5 = BattleState.new()
	s5._new_grassland(9, 7)
	var free = mk("自由人", "player", 0, 3)
	s5.units = [free]
	var b5: Dictionary = s5._dijkstra(free, 3)["best"]
	ck(int(b5.get(Vector2i(3, 3), -1)) == 3 and int(b5.get(Vector2i(0, 3), -1)) == 0,
		"无敌图：草原直线 3 格成本 3、原地 0")
	ck(not b5.has(Vector2i(4, 3)), "预算 3 不含第 4 格")

	# —— 5) 甲伤因子 armor_f（🔒 决策33）：只放大啃甲、人身溢出按原口径；f=1 与旧行为等价 ——
	var CR := preload("res://CombatResolver.gd")
	var t_arm = mk("重甲", "enemy", 6, 3)
	t_arm.stats["armor"] = 20
	var comp := [{"lane": "armor_first", "damage_category": "physical", "ratio": 1.0}]
	var r_base: Dictionary = CR.resolve(t_arm, 10.0, 1.0, comp)             # 10 全进甲，池够
	ck(is_equal_approx(float(r_base["armor_loss"]), 10.0) and is_equal_approx(float(r_base["hp_loss"]), 0.0),
		"f=1 基线：啃甲 10、无溢出")
	var r_f2: Dictionary = CR.resolve(t_arm, 10.0, 1.0, comp, 2.0)          # 甲伤 ×2：啃 20、仍无人身溢出
	ck(is_equal_approx(float(r_f2["armor_loss"]), 20.0) and is_equal_approx(float(r_f2["hp_loss"]), 0.0),
		"f=2：啃甲翻倍 20、溢出仍按原口径为 0（甲伤只多毁甲不多打人）")
	var r_of: Dictionary = CR.resolve(t_arm, 30.0, 1.0, comp, 2.0)          # 原口径溢出 30−20=10 不受 f 影响
	ck(is_equal_approx(float(r_of["armor_loss"]), 20.0) and is_equal_approx(float(r_of["hp_loss"]), 10.0),
		"f=2 破甲：armor_loss 封顶池 20、人身溢出 10＝原口径")

	# —— 5b) 甲伤·固定值 armor_flat（🔒 2026-07-15）：定额额外毁甲、过甲抗+甲固减、只扣甲池不溢人身 ——
	var t_fl = mk("固定甲靶", "enemy", 6, 4)
	t_fl.stats["armor"] = 20
	# 主伤 10 啃甲 + 固定甲伤 5 → 甲失 15，无人身溢出（甲够）
	var r_fl: Dictionary = CR.resolve(t_fl, 10.0, 1.0, comp, 1.0, 5.0)
	ck(is_equal_approx(float(r_fl["armor_loss"]), 15.0) and is_equal_approx(float(r_fl["hp_loss"]), 0.0),
		"固定甲伤 5：主伤 10 啃甲 + 定额 5 → 甲失 15、不溢人身（实得 %s/%s）" % [str(r_fl["armor_loss"]), str(r_fl["hp_loss"])])
	# 甲池不够：主伤 18 先啃 → 剩 2 甲，固定甲伤 5 只能再扣 2（封顶剩余池），多出的 3 浪费·不溢人身
	var r_fl2: Dictionary = CR.resolve(t_fl, 18.0, 1.0, comp, 1.0, 5.0)
	ck(is_equal_approx(float(r_fl2["armor_loss"]), 20.0) and is_equal_approx(float(r_fl2["hp_loss"]), 0.0),
		"固定甲伤封顶剩余池：主伤 18 + 定额 5 → 甲失封顶 20、余量浪费不溢人身（实得 %s/%s）" % [str(r_fl2["armor_loss"]), str(r_fl2["hp_loss"])])
	# 甲抗 50%：固定甲伤 8 过甲抗 → 实际 4 点毁甲
	t_fl.modifiers.append({"stat": "armor_res_phys", "op": "flat", "value": 50, "source": "buff:测试甲抗"})
	var r_fl3: Dictionary = CR.resolve(t_fl, 0.0, 1.0, comp, 1.0, 8.0)
	ck(is_equal_approx(float(r_fl3["armor_loss"]), 4.0),
		"固定甲伤过甲抗：甲抗 50%% → 8 点定额毁甲实收 4（实得 %s）" % str(r_fl3["armor_loss"]))
	t_fl.modifiers.clear()

	if _fail == 0:
		print("=== 战斗结算链 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
