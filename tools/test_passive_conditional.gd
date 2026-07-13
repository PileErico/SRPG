extends SceneTree
## 阶段4 被动桥 + 条件系统回归（🔒 设计 §10 阶段4 / §4 条件词表 / §4.3 递归防护 / §7.4 scale）：
##  · passive_stat_mods：learn_skill 挂 source="skill:<id>"、升级按源重挂（公式随级、替换不叠加）
##  · HP_max 被动 → 当前值按比例缩放（scale，杜绝穿脱刷血）
##  · conditional_mod：when 惰性判（_mod_active 三循环全接）；stat_threshold 读裸 stats（递归防护）
##  · 条件词表 v1：stat_threshold(pct_of) / equip_state(empty|has_tag) / self_tag / target_tag / skill_tag
##  · 交互语境 combat_ctx：_resolve_compute 结算期内生效、出结算即清；triple_vs（屠龙者）经 set_trait 兑现
## SkillDB 经 _path_override 注入临时库；武器经 ItemDB._paths_override——不碰真数据。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_passive_conditional.gd（退出码 0=PASS）

const SkillDB := preload("res://SkillDB.gd")
const Unit := preload("res://Unit.gd")
const BattleState := preload("res://BattleState.gd")
const ItemDB := preload("res://ItemDB.gd")
const ItemInstances := preload("res://ItemInstances.gd")
const TraitDB := preload("res://TraitDB.gd")

var _fail := 0
func ck(c: bool, m: String) -> void:
	if not c:
		_fail += 1
		push_error("[FAIL] " + m)

func _initialize() -> void:
	print("=== 被动桥/条件系统 测试开始 ===")
	var skills := [
		{"id": "t_elite", "name": "精锐化", "nature": "skill", "active": false, "tags": [],
			"costs": {"ap": 1}, "cooldown": {"base": 0}, "uses_per_battle": {"base": 0},
			"max_level": 2, "target": {"enemy": false, "ally": false, "self": true}, "range": 0,
			"effects": [{"kind": "passive_stat_mods", "mods": [
				{"stat": "atk", "op": "flat", "value": {"per_level": [3, 6]}},
				{"stat": "HP_max", "op": "flat", "value": 10}]}]},
		{"id": "t_trained", "name": "训练有素", "nature": "skill", "active": false, "tags": [],
			"costs": {"ap": 1}, "cooldown": {"base": 0}, "uses_per_battle": {"base": 0},
			"max_level": 1, "target": {"enemy": false, "ally": false, "self": true}, "range": 0,
			"effects": [{"kind": "conditional_mod",
				"when": [{"type": "stat_threshold", "stat": "HP", "op": "<=", "value": 50, "pct_of": "HP_max"}],
				"mods": [{"stat": "acc", "op": "flat", "value": 10}]}]},
	]
	var f = FileAccess.open("user://test_pc_skills.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(skills, "  "))
	f.close()
	SkillDB._path_override = "user://test_pc_skills.json"
	SkillDB.reload_data()

	# 1) passive_stat_mods：学得即挂 + 公式随级 + 升级重挂不叠加
	var u = Unit.new("精锐", "player", 0, 0)
	var atk0 := u.effective_stat_f("atk")
	ck(u.learn_skill("t_elite") == 1, "首学 → level 1")
	ck(is_equal_approx(u.effective_stat_f("atk"), atk0 + 3.0), "L1 被动：atk +3（per_level 首档）")
	ck(u.learn_skill("t_elite") == 2, "再学 → level 2")
	ck(is_equal_approx(u.effective_stat_f("atk"), atk0 + 6.0), "L2 重挂：atk +6（替换不叠加）")
	var n_src := 0
	for m in u.modifiers:
		if str(m.get("source", "")) == "skill:t_elite":
			n_src += 1
	ck(n_src == 2, "source=skill:t_elite 恰 2 条（atk+HP_max，重挂无残留）")

	# 2) §7.4 scale：HP_max +10 → 当前 HP 按比例缩放
	var u2 = Unit.new("血靶", "player", 1, 0)
	u2.stats["HP"] = 20   # 40 上限的一半
	u2.learn_skill("t_elite")
	ck(u2.effective_stat("HP_max") == 50 and int(u2.stats["HP"]) == 25,
		"HP_max 40→50：当前 20→25（保 50%%，实际 %d/%d）" % [int(u2.stats["HP"]), u2.effective_stat("HP_max")])

	# 3) conditional_mod stat_threshold（训练有素形）：HP%≤50 才生效；读裸 stats（§4.3 递归防护）
	var u3 = Unit.new("残卒", "player", 2, 0)
	var acc0 := u3.effective_stat_f("acc")
	u3.learn_skill("t_trained")
	ck(is_equal_approx(u3.effective_stat_f("acc"), acc0), "满血：条件不满足 → acc 不变")
	u3.stats["HP"] = 20
	ck(is_equal_approx(u3.effective_stat_f("acc"), acc0 + 10.0), "半血（裸 HP/HP_max=50%）→ acc +10")
	u3.stats["HP"] = 21
	ck(is_equal_approx(u3.effective_stat_f("acc"), acc0), "52.5% > 50 → 复原（边界）")

	# 4) equip_state / self_tag（直接挂 mod 验词表；同走 _mod_active）
	var u4 = Unit.new("空手", "player", 3, 0)
	var eva0 := u4.effective_stat_f("eva")
	u4.modifiers.append({"stat": "eva", "op": "flat", "value": 5, "source": "perk:补偿",
		"when": [{"type": "equip_state", "slot": "off_hand", "empty": true}]})
	ck(is_equal_approx(u4.effective_stat_f("eva"), eva0 + 5.0), "副手空 → 单手补偿 +5 生效")
	ItemInstances.clear()
	u4.equipment["off_hand"] = ItemInstances.create("wood_kite_shield")
	ck(is_equal_approx(u4.effective_stat_f("eva"), eva0), "副手持盾 → 补偿失效")
	u4.modifiers.append({"stat": "atk", "op": "flat", "value": 7, "source": "perk:水战",
		"when": [{"type": "self_tag", "tag": "aquatic"}]})
	var atk4 := u4.effective_stat_f("atk")
	u4.tags.append("aquatic")
	ck(is_equal_approx(u4.effective_stat_f("atk"), atk4 + 7.0), "self_tag：得 aquatic 后 +7")

	# 5) 交互语境 + triple_vs：屠龙者特性 vs monster/beast 三倍（经 set_trait 条件条兑现）
	var td := TraitDB.all()
	var slayer_id := ""
	for tid in td:
		if typeof(td[tid]) == TYPE_DICTIONARY and not (td[tid].get("triple_vs", []) as Array).is_empty():
			slayer_id = str(tid)
			break
	ck(slayer_id != "", "traits.json 存在 triple_vs 特性（屠龙者）")
	if slayer_id != "":
		var s = BattleState.new()
		s._new_grassland(9, 7)
		s.rng.seed = 20260713   # 注入定序（战斗骰统一过 BattleState.rng——技改 §1-1；防抽签碎裂）
		var slayer = Unit.new("屠龙者", "player", 3, 3)
		slayer.set_trait(slayer_id)
		var beast = Unit.new("野兽", "enemy", 4, 3)
		beast.tags.append("beast")
		var plain = Unit.new("路人", "enemy", 5, 3)
		s.units = [slayer, beast, plain]
		var base_mult := 1.0
		for m in TraitDB.get_trait(slayer_id).get("mods", []):
			if str(m.get("stat", "")) == "atk_eff":
				base_mult = 1.0 + float(m.get("value", 0)) * 3.0 / 100.0   # 三倍口径：5% → 15%
		slayer.stats["atk"] = 20
		slayer.stats["acc"] = 200.0   # hc 钳 95：64 次内必出命中样本（本段测 aeff 数学，不测命运）
		var rb := {}
		for _i in range(64):
			slayer.morale = 25
			rb = s._resolve_compute(slayer, beast, {"coeff": 1.0})
			if rb.get("hit", false) and not bool(rb.get("crit", false)):
				break
			beast.stats["HP"] = int(beast.stats["HP_max"])
		ck(is_equal_approx(float(rb["aeff"]), base_mult),
			"对 beast：aeff=%.2f（5%%×3 条件条 5+10 相加）" % base_mult)
		var rp := {}
		for _i in range(64):
			slayer.morale = 25
			rp = s._resolve_compute(slayer, plain, {"coeff": 1.0})
			if rp.get("hit", false) and not bool(rp.get("crit", false)):
				break
			plain.stats["HP"] = int(plain.stats["HP_max"])
		ck(is_equal_approx(float(rp["aeff"]), 1.05), "对无 tag 路人：aeff=1.05（仅基础 5%）")
		ck(slayer.combat_ctx.is_empty() and beast.combat_ctx.is_empty(), "出结算 → combat_ctx 两侧已清")
		# 重设特性：前缀摘 trait* 无残留
		slayer.set_trait("")
		var leak := 0
		for m in slayer.modifiers:
			if str(m.get("source", "")).begins_with("trait"):
				leak += 1
		ck(leak == 0, "set_trait 重设：trait/trait_triple 前缀全摘无泄漏")

	# 6) skill_tag 交互条件 + 结算外恒 false
	var u6 = Unit.new("咒手", "player", 6, 0)
	u6.modifiers.append({"stat": "atk", "op": "flat", "value": 9, "source": "perk:咒刃",
		"when": [{"type": "skill_tag", "tag": "verbal"}]})
	var atk6 := u6.effective_stat_f("atk")
	u6.combat_ctx = {"target": null, "skill_tags": ["verbal"]}
	ck(is_equal_approx(u6.effective_stat_f("atk"), atk6 + 9.0), "结算期（ctx 带 verbal）→ +9")
	u6.combat_ctx = {}
	ck(is_equal_approx(u6.effective_stat_f("atk"), atk6), "结算外 → 交互条件恒不满足")

	SkillDB._path_override = ""
	SkillDB.reload_data()
	ItemInstances.clear()
	if _fail == 0:
		print("=== 全 PASS ===")
	else:
		print("=== 失败 %d 项 ===" % _fail)
	quit(_fail)
