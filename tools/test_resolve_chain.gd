extends SceneTree
## 战斗结算链定向回归（路线图·技术债 P2「战斗结算链定向测试」2026-07-07 补齐）：
## _resolve_compute 分支（命中/暴击/格挡/穿甲分量/士气挂点，用钳位边界与超阈值 stat 造确定性分支）/
## end_turn DoT 致死（真死收尸链 + 死门转入 + 击杀/同伴之死士气）/ ZOC 借机模型（去重键/控制区/入区截断）/
## _dijkstra 行为锚（草原成本/ZOC 截断——二叉堆重构的保绿基线）。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_resolve_chain.gd（退出码 0=PASS）

const BattleState := preload("res://BattleState.gd")
const Unit := preload("res://Unit.gd")

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
	seed(20260707)

	# —— 1) _resolve_compute：确定性分支（钳位/超阈值构造，不依赖赌骰）——
	var s = BattleState.new()
	s._new_grassland(9, 7)
	var a = mk("攻手", "player", 3, 3)
	var d = mk("靶子", "enemy", 4, 3)
	s.units = [a, d]
	# 必不暴击：cr = 0 + 10×0.5 − 5 = 0；必不格挡：block_rate 0
	a.stats["atk"] = 20.0
	a.stats["acc"] = 100.0   # hc 钳 95，循环内等第一次命中（seed 固定＝序列确定）
	var r := {}
	for _i in range(64):
		a.morale = 25   # 失手会 −1，重置保证命中样本的士气断言干净
		r = s._resolve_compute(a, d, {"coeff": 1.0})
		if r.get("hit", false):
			break
		d.stats["HP"] = int(d.stats["HP_max"])   # 失手不掉血，防御性重置
	ck(bool(r.get("hit", false)), "64 次内必出命中（hc=95）")
	ck(not bool(r["crit"]) or is_equal_approx(float(r["cmult"]), float(a.stats["crit_dmg"]) / 100.0),
		"暴击时 cmult=crit_dmg/100")
	ck(is_equal_approx(float(r["cr"]), 0.0) and not bool(r["crit"]), "基线 cr=0 必不暴击")
	ck(not bool(r["blocked"]) and is_equal_approx(float(r["bp"]), 0.0), "block_rate 0 必不格挡（bp=0）")
	ck(int(r["morale_att"]) == 2 and a.morale == 27, "命中未格挡：攻方士气 +2")
	ck(is_equal_approx(float(r["out"]), 20.0), "无暴击无效能：out=atk×coeff=20")
	ck(int(r["hp_after"]) == int(d.stats["HP"]), "r.hp_after 与靶子实血一致")
	ck(d.last_hit_by == a, "last_hit_by 记录击杀归属")

	# 必暴击：crit_rate 200 → cr≥100；必格挡：block_rate 100
	var d2 = mk("盾手", "enemy", 5, 3)
	d2.stats["block_rate"] = 100.0
	d2.stats["block_power"] = 50.0
	s.units = [a, d2]
	a.stats["crit_rate"] = 200.0
	a.morale = 25
	var r2 := {}
	for _i in range(64):
		r2 = s._resolve_compute(a, d2, {"coeff": 1.0})
		if r2.get("hit", false):
			break
	ck(bool(r2["crit"]) and float(r2["cr"]) >= 100.0, "crit_rate 200 必暴击")
	ck(bool(r2["blocked"]) and is_equal_approx(float(r2["bp"]), 50.0), "block_rate 100 必格挡（bp=50）")
	ck(not r2.has("morale_att") or int(r2.get("morale_att", 0)) == 0, "被格挡＝士气无变化")
	ck(a.morale == 25, "被格挡后攻方士气不动")
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

	# 未命中分支：eva 拉满 → hc 钳 5，等第一次失手
	var dodge = mk("闪客", "enemy", 4, 2)
	dodge.stats["eva"] = 300.0
	s.units = [a, dodge]
	a.morale = 25
	var r4 := {}
	for _i in range(64):
		r4 = s._resolve_compute(a, dodge, {"coeff": 1.0})
		if not r4.get("hit", true):
			break
	ck(not bool(r4.get("hit", true)), "64 次内必出失手（hc=5）")
	ck(int(r4["morale_att"]) == -1, "失手：攻方士气 −1（决心 0 保底 1）")

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
	ck(hero.morale == 28, "击杀归属（DoT 记 last_hit_by）：+3")
	ck(mate.morale == 20, "同伙目睹真死：−5")
	var mevs: Array = dres.get("morale", [])
	ck(mevs.size() == 2, "士气事件上抛 2 条（kill+ally_death，实得 %d）" % mevs.size())

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

	if _fail == 0:
		print("=== 战斗结算链 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
