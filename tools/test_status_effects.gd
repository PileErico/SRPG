extends SceneTree
## 异常体系整理回归（🔒 2026-07-17 用户拍板·决策37）：
## 流血多实例 instanced（独立实例各自倒数/不刷新/高低级共存/per-instance source 到期各摘各的）→
## 单击 on-hit 合并新规（同 id 概率**相加**合掷一次〔翻案原「取高」〕/同族异 id 只掷高优先级）→
## 踉跄→倒地升级链 reapply_escalates_to（再施加=升级/倒地免疫踉跄/直接施加倒地顶掉踉跄）→
## 倒地起身成本 expire_ap_cost（turn_start 到期扣 AP）→ 失能（不自主闪避/格挡）→
## 暴击防御 crit_def（暴击率 −〔运气＋crit_def〕，踉跄类 debuff 挂载口）→
## 缴械 disarmed（BWS 退徒手/EWS 锁/固有面板+词条休眠/带武器要求 perk 失效/盾与天生武器豁免）。
## 经 EffectDB._path_override 注入临时效果库，绝不碰真数据。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_status_effects.gd（退出码 0=PASS）

const BattleState := preload("res://BattleState.gd")
const Unit := preload("res://Unit.gd")
const EffectDB := preload("res://EffectDB.gd")
const P := "user://test_status_effects_tmp.json"

var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func mk(nm := "试兵", fac := "player", col := 2, row := 2) -> Unit:
	var u := Unit.new(nm, fac, col, row)
	u.stats["HP"] = int(u.stats.get("HP_max", 40))
	return u

func _count(u, eid: String) -> int:
	var n := 0
	for e in u.effects:
		if str(e.get("id", "")) == eid:
			n += 1
	return n

func _mods_of(u, prefix: String) -> int:
	var n := 0
	for m in u.modifiers:
		if str(m.get("source", "")).begins_with(prefix):
			n += 1
	return n

# 定序循环等第一个命中样本（test_displace 同法）
func first_hit(s, a, d, skill: Dictionary) -> Dictionary:
	for _i in range(64):
		var r: Dictionary = s._resolve_compute(a, d, skill)
		if r.get("hit", false):
			return r
		d.stats["HP"] = int(d.stats["HP_max"])
	return {}

func _initialize() -> void:
	print("=== 异常体系整理（决策37）测试开始 ===")
	EffectDB._path_override = P
	var f = FileAccess.open(P, FileAccess.WRITE)
	f.store_string(JSON.stringify([
		{"id": "t_bleed_lo", "name": "流血", "kind": "debuff", "duration": {"base": 3},
			"dot_pct_max_hp": 5, "tags": ["bleeding"], "instanced": true,
			"mods": [{"stat": "eva", "op": "flat", "value": -2}]},
		{"id": "t_bleed_hi", "name": "大出血", "kind": "debuff", "duration": {"base": 3},
			"dot_pct_max_hp": 10, "tags": ["bleeding"], "instanced": true, "priority": 5},
		{"id": "t_stagger", "name": "踉跄", "kind": "debuff", "duration": {"base": 2},
			"reapply_escalates_to": "t_prone",
			"mods": [{"stat": "crit_def", "op": "flat", "value": -10}, {"stat": "eva", "op": "flat", "value": -10}]},
		{"id": "t_prone", "name": "倒地", "kind": "debuff", "duration": {"base": 1},
			"expire_timing": "turn_start", "expire_ap_cost": 1, "tags": ["incapacitated"]},
		{"id": "t_stun", "name": "眩晕", "kind": "debuff", "duration": {"base": 2}, "tags": ["incapacitated"]},
		{"id": "t_disarm", "name": "缴械", "kind": "debuff", "duration": {"base": 2}, "tags": ["disarmed"]},
	], "  "))
	f.close()
	EffectDB.reload_data()

	var s = BattleState.new()
	s._new_grassland(9, 7)
	s.rng.seed = 20260717

	# —— 1) 流血多实例：独立实例各自倒数、不刷新、高低级共存、DoT 逐实例结算 ——
	var u = mk()
	s._add_effect(u, {"id": "t_bleed_lo"})
	s._apply_turn_end_effects(u)   # A 实例 tick：3→2
	s._add_effect(u, {"id": "t_bleed_lo"})
	ck(_count(u, "t_bleed_lo") == 2, "同 id 再施加＝独立新实例（现 %d 条）" % _count(u, "t_bleed_lo"))
	var durs := []
	for e in u.effects:
		if str(e.get("id", "")) == "t_bleed_lo":
			durs.append(int(e.get("duration", 0)))
	durs.sort()
	ck(durs == [2, 3], "实例各自倒数不刷新（A 剩 2、B 剩 3；实得 %s）" % str(durs))
	ck(_mods_of(u, "buff:t_bleed_lo") == 2, "per-instance source：两实例各挂各的修正")
	var hp0 := int(u.stats["HP"])
	s._apply_turn_end_effects(u)
	ck(hp0 - int(u.stats["HP"]) == 2 * int(round(u.effective_stat_f("HP_max") * 0.05)),
		"DoT 逐实例结算（两道伤口两份血）")
	s._add_effect(u, {"id": "t_bleed_hi"})
	ck(_count(u, "t_bleed_lo") >= 1 and _count(u, "t_bleed_hi") == 1,
		"高低级流血实例共存（不同伤口，不顶替不压制）")
	# A 实例到期只摘自己的修正（B 仍在）
	var u2 = mk()
	s._add_effect(u2, {"id": "t_bleed_lo"})
	s._apply_turn_end_effects(u2)
	s._apply_turn_end_effects(u2)
	s._add_effect(u2, {"id": "t_bleed_lo"})
	s._apply_turn_end_effects(u2)   # A 到期（3 tick）；B 剩 2
	ck(_count(u2, "t_bleed_lo") == 1 and _mods_of(u2, "buff:t_bleed_lo") == 1,
		"实例到期各摘各的修正（A 走 B 留）")

	# —— 2) 单击合并新规：同 id 概率相加合掷一次；同族异 id 只掷高优先级 ——
	var a = mk("攻手", "player", 3, 3)
	var d = mk("靶子", "enemy", 4, 3)
	a.stats["acc"] = 100.0
	d.stats["eva"] = 0.0
	d.stats["block_rate"] = 0.0
	d.stats["body_fort"] = 0.0
	s.units = [a, d]
	var r := first_hit(s, a, d, {"coeff": 0.0,
		"on_hit_effects": [{"effect": "t_bleed_lo", "chance": 50}, {"effect": "t_bleed_lo", "chance": 60}]})
	ck(not r.is_empty() and _count(d, "t_bleed_lo") == 1,
		"同 id 概率相加（50+60=110 必中）且合掷一次＝只落一实例")
	var d2 = mk("靶子乙", "enemy", 5, 3)
	d2.stats["eva"] = 0.0
	d2.stats["block_rate"] = 0.0
	s.units = [a, d2]
	r = first_hit(s, a, d2, {"coeff": 0.0,
		"on_hit_effects": [{"effect": "t_bleed_lo", "chance": 200}, {"effect": "t_bleed_hi", "chance": 200}]})
	ck(not r.is_empty() and _count(d2, "t_bleed_hi") == 1 and _count(d2, "t_bleed_lo") == 0,
		"同族异 id 单击内只掷高优先级（普通流血+大出血→只算大出血）")

	# —— 3) 踉跄→倒地升级链 + 互斥 + 起身扣 AP ——
	var w = mk("步卒")
	s._add_effect(w, {"id": "t_stagger"})
	ck(_count(w, "t_stagger") == 1, "踉跄首次施加正常")
	s._add_effect(w, {"id": "t_stagger"})
	ck(_count(w, "t_stagger") == 0 and _count(w, "t_prone") == 1, "踉跄+踉跄=升级为倒地（踉跄移除）")
	ck(_mods_of(w, "buff:t_stagger") == 0, "升级时踉跄修正一并摘除")
	ck(not s._add_effect(w, {"id": "t_stagger"}), "已倒地：踉跄免疫不生效")
	ck(w.has_state("incapacitated"), "倒地携带失能")
	w.ap = 3
	var evs: Array = s._apply_turn_start_effects(w)
	var got_ap_ev := false
	for ev in evs:
		if str(ev.get("type", "")) == "expired" and int(ev.get("ap_cost", 0)) == 1:
			got_ap_ev = true
	ck(_count(w, "t_prone") == 0 and w.ap == 2 and got_ap_ev,
		"倒地于自身 turn 开始移除并扣 1 AP（起身成本；事件带 ap_cost）")
	var w2 = mk("步卒乙")
	s._add_effect(w2, {"id": "t_stagger"})
	s._add_effect(w2, {"id": "t_prone"})
	ck(_count(w2, "t_stagger") == 0 and _count(w2, "t_prone") == 1,
		"直接施加倒地＝顶掉在场踉跄（两者不并存）")

	# —— 4) 失能：不自主闪避/格挡（结算序 tick→失能 已由 _begin_active_turn 顺序保证）——
	var v = mk("失能者", "enemy", 4, 3)
	v.stats["eva"] = 50.0
	v.stats["block_rate"] = 100.0
	s._add_effect(v, {"id": "t_stun"})
	s.units = [a, v]
	var hd: Dictionary = s._hit_chance_detail(a, v, null)
	ck(int(hd["eva"]) == 0, "失能：闪避归零（面板 eva 50 不参与）")
	r = first_hit(s, a, v, {"coeff": 0.0})
	ck(not r.is_empty() and not bool(r.get("blocked", false)), "失能：不格挡（block_rate 100 不掷）")

	# —— 5) 暴击防御 crit_def：暴击率 −(运气+crit_def)；踉跄挂负修正即扣 ——
	var t3 = mk("被暴者", "enemy", 4, 3)
	t3.stats["eva"] = 0.0
	t3.stats["block_rate"] = 0.0
	t3.stats["luck"] = 0.0
	a.stats["crit_rate"] = 170.0
	s.units = [a, t3]
	r = first_hit(s, a, t3, {"coeff": 0.0})
	ck(not r.is_empty() and bool(r.get("crit", false)), "crit 170−0=必暴（对照组）")
	t3.modifiers.append({"stat": "crit_def", "op": "flat", "value": 200.0, "source": "test", "nature": "buff"})
	r = first_hit(s, a, t3, {"coeff": 0.0})
	ck(not r.is_empty() and not bool(r.get("crit", false)), "crit_def 200：170−200<0 必不暴（暴击防御生效）")
	a.stats["crit_rate"] = 0.0

	# —— 6) 缴械：武器技能+武器本身双禁用；盾/天生武器豁免；ZOC 退徒手 ——
	var g = mk("矛兵")
	var naked_atk := g.effective_stat_f("atk")
	g.equip("spear_winged")
	ck(g.basic_attack().get("name", "") != "徒手", "装矛：普攻非徒手（对照组）")
	ck(not g.ews_entries().is_empty(), "装矛：EWS 列表非空（对照组）")
	ck(g.prof_perk_weapon_ok("perk_spear_set"), "装矛：立矛武器门槛过（对照组）")
	var armed_atk := g.effective_stat_f("atk")
	ck(armed_atk > naked_atk, "装矛：固有面板 atk 生效（对照组）")
	s._add_effect(g, {"id": "t_disarm"})
	ck(g.weapon_disabled("main_hand"), "缴械：主手矛被禁用")
	ck(g.basic_attack().get("name", "") == "徒手", "缴械：普攻退徒手")
	ck(g.ews_entries().is_empty(), "缴械：该件 EWS 整体不可用")
	ck(not g.prof_perk_weapon_ok("perk_spear_set"), "缴械：带武器要求的 perk 失效")
	ck(g.effective_stat_f("atk") == naked_atk, "缴械：固有面板/词条修正休眠（atk 回徒手值）")
	ck(g.zoc_base() == 1, "缴械：ZOC 底值退徒手＝天生近战 1")
	var g2 = mk("盾卫")
	g2.equip("wood_kite_shield")
	s._add_effect(g2, {"id": "t_disarm"})
	ck(not g2.weapon_disabled("off_hand"), "缴械：盾豁免（绑臂不可夺，固有面板保留）")
	var c = mk("龙裔")
	c.equip("Desmond_Claw")
	s._add_effect(c, {"id": "t_disarm"})
	ck(not c.weapon_disabled("main_hand"), "天生武器（innate_weapon）不受缴械")

	EffectDB._path_override = ""
	EffectDB.reload_data()
	if _fail == 0:
		print("=== 全部断言 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
