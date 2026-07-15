extends SceneTree
## 技能全量冒烟（🔒 模块_技能_设计 §10 全程护栏#2，阶段2 起）：遍历 skills.json 每个主动技能，
## 最小模型战局强制施放——断言 AP 扣减==skill_ap_cost / 冷却置位 / 按效果块 kind 验方向性
## （heal→HP↑ / apply_effect→产出 inflict 事件）。**每新增技能条目零成本获得覆盖。**
## 另：目标三旗 _valid_skill_target 语义（§2.7）+ heal 试料定向断言（schema/resolve_num/下沉验收——
## 救护 first_aid 数据条目已删 2026-07-13 用户令，heal/cleanse/per_level 机制仍在，注入临时副本回归）
## + resolve_num/skill_ap_cost 读取器契约。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_skill_smoke.gd（退出码 0=PASS）

const SkillDB := preload("res://SkillDB.gd")
const BattleStateScript := preload("res://BattleState.gd")
const SandboxScript := preload("res://Sandbox.gd")
const UnitFactory := preload("res://UnitFactory.gd")
const WorldState := preload("res://WorldState.gd")

const BARE := {"id": "_smoke_bare", "name": "冒烟兵", "race": "human",
	"default_faction": "player", "tags": ["ground", "human"], "equip": [], "skills": {}, "trait": ""}

# heal/cleanse/per_level 机制试料（形＝原救护条目；数据条目已退役，机制回归靠它）
const T_HEAL := {"id": "t_heal", "name": "试料救护", "icon": "", "category": "skill", "desc": "",
	"active": true, "tags": [],
	"costs": {"ap": 1}, "cooldown": {"base": 2}, "uses_per_battle": {"base": 0},
	"max_level": 3, "target": {"enemy": false, "ally": true, "self": true},
	"range": 1,
	"effects": [{"kind": "heal", "heal_pct_max_hp": {"per_level": [15, 25, 35]}, "cleanse_tags": ["bleeding"]}]}

var _fail := 0
func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _initialize() -> void:
	print("=== 技能冒烟测试开始 ===")
	WorldState.current = null
	# 数据注入：真 skills.json 临时副本 + T_HEAL 试料（§4 全量冒烟仍覆盖全部真条目）
	var src = FileAccess.open("res://data/skills.json", FileAccess.READ)
	var dst = FileAccess.open("user://test_smoke_skills.json", FileAccess.WRITE)
	dst.store_string(src.get_as_text())
	src.close()
	dst.close()
	var arr := SkillDB._read_array("user://test_smoke_skills.json")
	arr.append(T_HEAL)
	SkillDB._write_array("user://test_smoke_skills.json", arr)
	SkillDB._path_override = "user://test_smoke_skills.json"
	SkillDB.reload_data()
	var bs = BattleStateScript.new()

	# 1) 读取器契约：skill_ap_cost 双键桥 + resolve_num 标量/公式两吃与数值边界（§2.4）
	ck(SkillDB.skill_ap_cost({"costs": {"ap": 2}}) == 2, "skill_ap_cost：costs.ap 优先")
	ck(SkillDB.skill_ap_cost({"ap_cost": 3}) == 3, "skill_ap_cost：旧顶层键回退")
	ck(SkillDB.skill_ap_cost({}) == 1, "skill_ap_cost：缺省 1")
	ck(is_equal_approx(SkillDB.resolve_num(0.75), 0.75), "resolve_num：标量直通")
	ck(is_equal_approx(SkillDB.resolve_num({"base": 1.0, "per_level": [0, 0.5, 1.0]}, null, 2), 1.5), "resolve_num：base+per_level 档")
	ck(is_equal_approx(SkillDB.resolve_num({"per_level": [10, 20]}, null, 99), 20.0), "resolve_num：越界取末档")
	ck(is_equal_approx(SkillDB.resolve_num({"per_level": [10, 20]}, null, 0), 10.0), "resolve_num：level 0 取首档")
	ck(is_equal_approx(SkillDB.resolve_num(null, null, 1, 7.0), 7.0), "resolve_num：null → default")
	ck(is_equal_approx(SkillDB.resolve_num({}, null, 1, 7.0), 7.0), "resolve_num：空对象 → default")
	var stat_u = UnitFactory.make_unit(BARE, "player", 0, 0)
	ck(is_equal_approx(SkillDB.resolve_num({"base": 1, "per_stat": {"finesse": 0.1}}, stat_u, 1), 1.0 + 0.1 * float(stat_u.effective_stat_f("finesse"))), "resolve_num：per_stat 按 effective 求值")

	# 2) 目标三旗 _valid_skill_target（§2.7 正交组合；Sandbox 纯逻辑直调，仿 test_battleio）
	var sb = SandboxScript.new()
	var caster = UnitFactory.make_unit(BARE, "player", 0, 0)
	var ally = UnitFactory.make_unit(BARE, "player", 1, 0)
	var foe = UnitFactory.make_unit(BARE, "enemy", 2, 0)
	var d_heal := {"target": {"enemy": false, "ally": true, "self": true}}
	ck(sb._valid_skill_target(caster, d_heal, caster) and sb._valid_skill_target(caster, d_heal, ally) \
		and not sb._valid_skill_target(caster, d_heal, foe), "三旗 {ally,self}：友/自可、敌不可")
	var d_bite := {"target": {"enemy": true, "ally": false, "self": false}}
	ck(sb._valid_skill_target(caster, d_bite, foe) and not sb._valid_skill_target(caster, d_bite, ally) \
		and not sb._valid_skill_target(caster, d_bite, caster), "三旗 {enemy}：敌可、友/自不可")
	ck(sb._valid_skill_target(caster, {}, ally) and not sb._valid_skill_target(caster, {}, foe), "缺省三旗＝{ally,self}（旧行为）")
	sb.free()

	# 3) heal 试料定向验收（阶段2：schema/resolve_num/heal 下沉/清流血一次到位）
	var healer = UnitFactory.make_unit(BARE, "player", 0, 0)
	var patient = UnitFactory.make_unit(BARE, "player", 1, 0)
	ck(healer.learn_skill("t_heal") == 1, "学会试料救护")
	healer.ap = 5
	bs._add_effect(patient, {"id": "bleeding_basic"})   # 效果 id 随用户重建改（2026-07-15）；cleanse 按 bleeding tag 清不受影响
	ck(patient.effects.size() == 1, "预置流血")
	var maxhp := int(patient.effective_stat("HP_max"))
	patient.stats["HP"] = maxhp / 2
	var evs: Array = bs.apply_skill(healer, "t_heal", patient)
	var expect_heal := int(round(maxhp * 15.0 / 100.0))   # 1 级档 15%
	ck(int(patient.stats["HP"]) == maxhp / 2 + expect_heal, "试料 heal 1 级回 15%%（+%d）" % expect_heal)
	ck(patient.effects.is_empty(), "流血被清除（cleanse_tags: bleeding）")
	ck(healer.ap == 5 - SkillDB.skill_ap_cost(SkillDB.get_skill("t_heal")), "AP 扣减==skill_ap_cost（costs.ap）")
	ck(int(healer.skills["t_heal"]["cd"]) == healer.skill_cooldown_max(SkillDB.get_skill("t_heal")), "冷却置位")
	var has_heal_ev := false
	var has_cleanse_ev := false
	for e in evs:
		if str(e.get("type")) == "heal":
			has_heal_ev = true
		if str(e.get("type")) == "cleanse":
			has_cleanse_ev = true
	ck(has_heal_ev and has_cleanse_ev, "事件流含 heal+cleanse（宿主渲染契约）")

	# 4) 全量冒烟：skills.json 每个主动技能施放一遍（护栏#2——新增条目零成本覆盖）
	var n := 0
	for id in SkillDB.all():
		var def = SkillDB.get_skill(id)
		if not bool(def.get("active", true)):
			continue
		if bool(def.get("weapon_skill", false)) and not SkillDB.has_runnable_block(def):
			continue   # 武器技能无可跑块＝纯 attack 形（阶段6 能力路径时限，冒烟归 test_basic_attack/golden）
			# 或**编辑中的空壳**（决策33 松绑允许存无块武器技能；被引为 BWS 时由 lint 规则8 在引用处执法）；
			# 其余主动技能一律强制施放（护栏#2）——「主动但无可跑块」的死内容（kind 打错/scripted-only）会在此响亮 FAIL
		n += 1
		var c = UnitFactory.make_unit(BARE, "player", 0, 0)
		c.learn_skill(str(id))
		c.ap = 99
		var tg = def.get("target", {"ally": true, "self": true})
		var t = c if bool(tg.get("self", false)) else UnitFactory.make_unit(BARE, "player" if bool(tg.get("ally", false)) else "enemy", 1, 0)
		var tmax := int(t.effective_stat("HP_max"))
		t.stats["HP"] = maxi(1, tmax / 2)
		var ap0: int = c.ap
		var out: Array = bs.apply_skill(c, str(id), t)
		ck(c.ap == ap0 - SkillDB.skill_ap_cost(def), "%s：AP 扣减==skill_ap_cost" % id)
		ck(int(c.skills[id]["cd"]) == c.skill_cooldown_max(def), "%s：冷却置位" % id)
		for block in def.get("effects", []):
			if typeof(block) != TYPE_DICTIONARY:
				continue
			match str(block.get("kind", "")):
				"heal":
					ck(int(t.stats["HP"]) > tmax / 2 or tmax / 2 >= tmax, "%s：heal 块方向性（HP↑）" % id)
				"apply_effect":
					var hit := false
					for e in out:
						if str(e.get("type")) == "inflict" and str(e.get("effect")) == str(block.get("effect")):
							hit = true
					ck(hit, "%s：apply_effect 块产出 inflict 事件" % id)
	print("冒烟覆盖 %d 个主动技能" % n)
	ck(n >= 1, "技能池非空（含 t_heal 试料兜底）")

	if _fail == 0:
		print("=== 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
