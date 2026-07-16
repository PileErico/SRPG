extends SceneTree
## 矛·娴熟首行 perk 回归：选择/互斥/装载总开关/序列化、逼退动态 skill_spear 条件、
## 立矛 AP/时长/ZOC2/每 round 一次进入触发/双手最终调整，以及强制位移路径可供进入判定。

const Unit := preload("res://Unit.gd")
const UnitFactory := preload("res://UnitFactory.gd")
const BattleState := preload("res://BattleState.gd")
const SkillDB := preload("res://SkillDB.gd")
const ProfDB := preload("res://ProfDB.gd")
const ItemInstances := preload("res://ItemInstances.gd")
const SandboxScript := preload("res://Sandbox.gd")

var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _initialize() -> void:
	print("=== 矛娴熟 Perk 测试开始 ===")
	ItemInstances.clear()
	ck(ProfDB.perks_at_stage("wp_spear", 2) == ["perk_spear_set", "perk_spear_force_back"], "娴熟行候选入库")

	var u := Unit.new("矛兵", "player", 2, 2)
	u.level = 8
	u.learn_prof("wp_spear")
	u.set_prof_xp("wp_spear", 100)
	ck(u.select_prof_perk("wp_spear", 2, "perk_spear_force_back"), "选择逼退")
	u.slot_prof("wp_spear", true)
	ck(u.selected_prof_perk("wp_spear", 2) == "perk_spear_force_back", "选择落账")
	# 条件修正只在攻击判定的动态矛 tag 语境中出现。
	ck(u.effective_stat_f("knockback_chance") == 0.0, "结算外不污染全局击退")
	u.combat_ctx = {"skill_tags": ["skill_spear"]}
	ck(u.effective_stat_f("knockback_chance") == 15.0, "矛攻击获得逼退15")
	u.combat_ctx = {"skill_tags": ["skill_sword"]}
	ck(u.effective_stat_f("knockback_chance") == 0.0, "非矛攻击不吃逼退")
	u.combat_ctx = {}
	u.unslot_prof("wp_spear")
	ck(u.selected_prof_perk("wp_spear", 2) == "perk_spear_force_back" and u.effective_stat_f("knockback_chance") == 0.0,
		"卸载停用但保留选择")
	u.slot_prof("wp_spear", true)
	ck(u.select_prof_perk("wp_spear", 2, "perk_spear_set"), "同层改选立矛")
	ck(u.selected_prof_perk("wp_spear", 2) == "perk_spear_set" and not u.has_active_prof_perk("perk_spear_force_back"),
		"同层互斥替换")

	# proto + 战斗快照均保留选择；主动运行态独立于永久 skills。
	var proto := UnitFactory.unit_to_proto(u)
	ck(str(proto.get("profs", {}).get("perks", {}).get("wp_spear", {}).get("2", "")) == "perk_spear_set", "proto 写回 perk")
	var snap := UnitFactory.unit_to_battle_snapshot(u)
	var u2 = UnitFactory.unit_from_battle_snapshot(JSON.parse_string(JSON.stringify(snap)))
	ck(u2.selected_prof_perk("wp_spear", 2) == "perk_spear_set", "战斗快照往返 perk")

	# 装备翼矛后施放立矛：2AP、自身 buff、ZOC=2；到下一次自身 turn_start 到期。
	u.equip("spear_winged")
	ck(u.prof_perk_weapon_ok("perk_spear_set"), "立矛要求当前主手为矛")
	var s := BattleState.new()
	s._new_grassland(9, 7)
	var enemy := Unit.new("来敌", "enemy", 5, 2)
	s.units = [u, enemy]
	u.ap = 4
	var evs := s.apply_skill(u, "perk_spear_set", u)
	ck(u.ap == 2 and not evs.is_empty() and u.has_state("spear_stance"), "立矛消耗2AP并施加架势")
	ck(s._zoc_radius(u) == 2 and s._zoc_cells(u).has(Vector2i(4, 2)), "立矛ZOC扩大到2")
	var path := [Vector2i(5, 2), Vector2i(4, 2)]
	var revent := {"unit": enemy, "path": path, "kind": "voluntary"}
	var candidates := s.reaction_candidates("unit_entered_zoc", revent)
	ck(candidates.size() == 1 and candidates[0].owner == u, "从圈外进入触发立矛")
	u.consume_reaction_limit(candidates[0].state_key, candidates[0].reaction.get("limit", {}), candidates[0].reset_token)
	ck(s.reaction_candidates("unit_entered_zoc", revent).is_empty(), "同一拥有者每round只触发一次")
	ck(s.reaction_candidates("unit_entered_zoc", {"unit": enemy, "path": path, "kind": "voluntary", "is_reaction": true}).is_empty(),
		"反应动作不能再次触发反应")
	var rsnap := UnitFactory.unit_to_battle_snapshot(u)
	var ur = UnitFactory.unit_from_battle_snapshot(JSON.parse_string(JSON.stringify(rsnap)))
	ck(not ur.reaction_state.is_empty(), "reaction limit 账本战斗快照往返")
	s.round_num += 1
	candidates = s.reaction_candidates("unit_entered_zoc", revent)
	ck(candidates.size() == 1, "新 round 重置反应次数")
	# 表现层统一分发器实际消费候选并走完整 _resolve_one，而非专用立矛攻击代码。
	var sb = SandboxScript.new()
	sb._state = s
	u.stats["acc"] = 100.0
	enemy.stats["eva"] = 0.0
	enemy.stats["block_rate"] = 0.0
	enemy.stats["HP_max"] = 999.0
	enemy.stats["HP"] = 999.0
	var hp_before := float(enemy.stats["HP"])
	sb._dispatch_reaction_event("unit_entered_zoc", revent)
	ck(float(enemy.stats["HP"]) < hp_before and s.reaction_candidates("unit_entered_zoc", revent).is_empty(),
		"通用 Reaction 分发器执行 BWS 并消费次数")
	sb.free()
	# 强制位移解算返回逐格路径，供同一个“进入”判定口消费。
	enemy.col = 5
	enemy.row = 2
	var dr := s.displace_push(enemy, s._dir_away(Vector2i(6, 2), Vector2i(5, 2)), 2)
	ck((dr.get("path", []) as Array).size() == int(dr.get("steps", 0)) + 1, "强制位移保留逐格路径")

	# 双手持兼用翼矛时，迎击使用独立 final_damage_factor，而非 atk_rate/反应系数。
	var atk: Dictionary = u.basic_attack().duplicate(true)
	var action: Dictionary = candidates[0].reaction.get("actions", [])[0]
	for override in action.get("overrides", []):
		if u.when_all(override.get("when", []), candidates[0].context):
			for key in override.get("set", {}).keys():
				atk[key] = override["set"][key]
	u.stats["acc"] = 100
	var rr := {}
	for _i in 64:
		rr = s._resolve_compute(u, enemy, atk)
		if rr.get("hit", false):
			break
	ck(float(rr.get("final_damage_factor", 1.0)) == 1.2 and float(rr.get("atk_rate", 1.0)) == 1.0,
		"双手立矛=最终调整1.2，非借机反应系数")
	s._apply_turn_start_effects(u)
	ck(not u.has_state("spear_stance") and s._zoc_radius(u) == 1 and u.reaction_state.is_empty(),
		"下一次自身turn开始架势到期并清反应账本")

	if _fail == 0:
		print("=== 全部断言 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
