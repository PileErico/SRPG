extends SceneTree
## 武器技能（BWS/EWS 🔒 决策26 阶段3a）回归：
##  · flatten_bws：BWS 技能条目 → legacy attack dict（顶层字段从技能级取 + hit 键全透传）
##  · EWS 解锁判定：requires 复数 AND〔技艺域+裸数值〕；空/缺省=装备即用；边界（差1不解锁）
##  · ews_state 生命周期：就绪→consume→冷却随 turn 递减→次数用尽→战斗开始重置
##  · apply_skill EWS 分支：非已学消耗走 ews_state（skills 不受污染、AP 扣减一致）
##  · 战斗快照：ews_state 往返（护栏#3 白名单同 PR 扩展）
##  · 审查修复回归：flatten_bws 无 attack 块→{}（防幻影攻击）/ apply_skill 无可跑块拒发零消耗
##  · EWS 恒读主手（🔒 决策28）：副手不供给能力表（ItemDB._paths_override 注入临时武器库）
## SkillDB 经 _path_override 注入 user:// 临时库，不碰真数据。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_weapon_skills.gd（退出码 0=PASS）

const SkillDB := preload("res://SkillDB.gd")
const Unit := preload("res://Unit.gd")
const UnitFactory := preload("res://UnitFactory.gd")
const BattleState := preload("res://BattleState.gd")
const ItemDB := preload("res://ItemDB.gd")
const ItemInstances := preload("res://ItemInstances.gd")

var _fail := 0
func ck(c: bool, m: String) -> void:
	if not c:
		_fail += 1
		push_error("[FAIL] " + m)

func _initialize() -> void:
	print("=== 武器技能 BWS/EWS 测试开始 ===")
	var skills := [
		{"id": "t_bws", "name": "试斩", "icon": "res://x.png", "nature": "skill", "desc": "",
			"active": true, "tags": ["single_target"],
			"costs": {"ap": 1}, "cooldown": {"base": 0}, "uses_per_battle": {"base": 0},
			"max_level": 1, "target": {"enemy": true, "ally": false, "self": false},
			"range": 2, "requires_hands": [],
			"effects": [{"kind": "attack", "hits": [{"coeff": 0.9, "damage_kind": "fire", "armor_pen": 5}]}]},
		{"id": "t_ews_heal", "name": "战地包扎", "icon": "", "nature": "skill", "desc": "",
			"active": true, "tags": [],
			"costs": {"ap": 1}, "cooldown": {"base": 2}, "uses_per_battle": {"base": 1},
			"max_level": 1, "target": {"enemy": false, "ally": true, "self": true},
			"range": 1, "requires_hands": [],
			"effects": [{"kind": "heal", "heal_pct_max_hp": 20, "cleanse_tags": []}]},
	]
	var f = FileAccess.open("user://test_ws_skills.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(skills, "  "))
	f.close()
	SkillDB._path_override = "user://test_ws_skills.json"
	SkillDB.reload_data()

	# 1) flatten_bws
	var flat: Dictionary = SkillDB.flatten_bws(SkillDB.get_skill("t_bws"))
	ck(str(flat.get("name")) == "试斩" and int(flat.get("range")) == 2 and int(flat.get("ap_cost")) == 1
		and str(flat.get("icon")) == "res://x.png", "flatten 顶层字段（name/icon/range/ap_cost 双键桥）")
	ck(absf(float(flat.get("coeff", 0)) - 0.9) < 0.0001 and str(flat.get("damage_kind")) == "fire"
		and int(flat.get("armor_pen", 0)) == 5, "flatten hit 键透传（coeff/damage_kind/armor_pen）")
	ck((flat.get("tags") as Array) == ["single_target"], "flatten tags 从技能级取")
	ck(SkillDB.flatten_bws({"name": "空壳"}).is_empty(), "无 attack 块 → 空 dict（勿造幻影攻击；basic_attack 兜 UNARMED）")
	ck(SkillDB.flatten_bws(SkillDB.get_skill("t_ews_heal")).is_empty(), "heal 技能被引用为 BWS → 空 dict（审查确认项2）")

	# 1b) is_bas_shaped 正反两向（🔒 决策27；FAIL 方向＝lint 规则8/ItemEditor 过滤的守卫本体）
	var bas_ok := {"cooldown": {"base": 0}, "max_level": 1, "requires_hands": [], "uses_per_battle": {"base": 0},
		"effects": [{"kind": "attack", "hits": [{"coeff": 1.0}]}]}
	ck(SkillDB.is_bas_shaped(bas_ok), "标准 BAS 形 → true")
	var v: Dictionary
	v = bas_ok.duplicate(true); v["cooldown"] = {"base": 2}
	ck(not SkillDB.is_bas_shaped(v), "冷却≠0 → 非 BAS 形")
	v = bas_ok.duplicate(true); v["max_level"] = 3
	ck(not SkillDB.is_bas_shaped(v), "有级 → 非 BAS 形")
	v = bas_ok.duplicate(true); v["requires_hands"] = [{"slot": "main_hand"}]
	ck(not SkillDB.is_bas_shaped(v), "有手门槛 → 非 BAS 形")
	v = bas_ok.duplicate(true); v["uses_per_battle"] = {"base": 2}
	ck(not SkillDB.is_bas_shaped(v), "限次 → 非 BAS 形（攻击路径不结算次数——决策18 BAS 无次数限制）")
	v = bas_ok.duplicate(true); v["effects"] = [{"kind": "heal"}]
	ck(not SkillDB.is_bas_shaped(v), "无 attack 块 → 非 BAS 形")
	# 1c) 多 attack 块口径同一：gate 放行 ⇔ flatten 有产出（首个异形块跳过继续扫，勿分叉）
	v = bas_ok.duplicate(true)
	v["effects"] = [{"kind": "attack", "hits": []}, {"kind": "attack", "hits": [{"coeff": 0.5}]}]
	ck(SkillDB.is_bas_shaped(v) and absf(float(SkillDB.flatten_bws(v).get("coeff", 0)) - 0.5) < 0.0001,
		"首块异形+次块合法 → gate 放行且 flatten 取到合法块（口径同一）")

	# 2) EWS 解锁判定（🔒 决策26：复数 AND + 裸数值）
	var u = Unit.new("试兵", "player", 0, 0)
	ck(u.ews_requires_met([]), "空 requires＝装备即用（决策22 兼容）")
	var req := [{"prof": "wp_axe", "value": 300}, {"prof": "style_thrown", "value": 100}]
	ck(not u.ews_requires_met(req), "零熟练度 → 未解锁")
	u.prof_xp["wp_axe"] = 300
	ck(not u.ews_requires_met(req), "单条达标（AND 未全）→ 仍未解锁")
	u.prof_xp["style_thrown"] = 99
	ck(not u.ews_requires_met(req), "99 < 100 裸数值边界 → 未解锁")
	u.prof_xp["style_thrown"] = 100
	ck(u.ews_requires_met(req), "两条全达标（AND）→ 解锁（飞斧＝斧∧投掷 用例）")

	# 3) ews_state 生命周期
	ck(u.ews_ready("t_ews_heal"), "本战未用过＝就绪")
	u.consume_ews("t_ews_heal", 2)
	ck(not u.ews_ready("t_ews_heal"), "施放后冷却中")
	ck(int(u.ews_state["t_ews_heal"]["uses"]) == 0, "uses_per_battle 1 → 用后 0")
	u.refresh_for_turn()
	u.refresh_for_turn()
	ck(int(u.ews_state["t_ews_heal"]["cd"]) == 0, "冷却随本单位 turn 递减归零")
	ck(not u.ews_ready("t_ews_heal"), "冷却完但次数尽 → 仍不可用")
	u.reset_skill_charges()
	ck(u.ews_state.is_empty() and u.ews_ready("t_ews_heal"), "战斗开始重置 → ews_state 清空全就绪")

	# 4) apply_skill EWS 分支（模型层）：非已学 → 消耗走 ews_state
	var st = BattleState.new()
	var caster = Unit.new("军医", "player", 0, 0)
	var target = Unit.new("伤员", "player", 1, 0)
	target.stats["HP"] = 10
	caster.ap = 3
	var evs: Array = st.apply_skill(caster, "t_ews_heal", target)
	ck(evs.size() > 0 and int(target.stats["HP"]) > 10, "EWS 经 apply_skill 生效（治疗落地）")
	ck(not caster.skills.has("t_ews_heal"), "EWS 不入已学 skills（装备授予非已学）")
	ck(caster.ews_state.has("t_ews_heal") and int(caster.ews_state["t_ews_heal"]["cd"]) == 2, "消耗走 ews_state（cd 置位）")
	ck(caster.ap == 2, "AP 扣减 == skill_ap_cost")

	# 5) 战斗快照往返（护栏#3）
	caster.ews_state = {"t_ews_heal": {"cd": 1, "uses": 0}}
	var back = UnitFactory.unit_from_battle_snapshot(UnitFactory.unit_to_battle_snapshot(caster))
	ck(int(back.ews_state["t_ews_heal"]["cd"]) == 1 and int(back.ews_state["t_ews_heal"]["uses"]) == 0,
		"★ ews_state 战斗快照往返（护栏#3 白名单）")
	var old = UnitFactory.unit_from_battle_snapshot({"uid": 1})
	ck(typeof(old.ews_state) == TYPE_DICTIONARY and old.ews_state.is_empty(), "旧快照无 ews_state 键 → 空表安全")

	# 6) apply_skill 前置守卫（审查确认项1）：纯 attack 块技能经能力路径 → 拒发且零消耗
	var brute = Unit.new("莽兵", "player", 2, 0)
	brute.ap = 3
	brute.learn_skill("t_bws")
	var guard_evs: Array = st.apply_skill(brute, "t_bws", target)
	ck(guard_evs.is_empty(), "无可跑块（纯 attack）→ 拒发空事件")
	ck(brute.ap == 3, "守卫零消耗：AP 不扣")
	ck(int((brute.skills["t_bws"] as Dictionary).get("cd", 0)) == 0, "守卫零消耗：冷却不置位")
	var brute2 = Unit.new("莽兵·未学", "player", 3, 0)
	brute2.ap = 3
	st.apply_skill(brute2, "t_bws", target)
	ck(brute2.ap == 3 and brute2.ews_state.is_empty(), "EWS 分支同守卫：零消耗、ews_state 干净")

	# 7) ews_entries 恒读主手（🔒 决策28）：副手武器不供给能力表（双持型攻击＝perk 授予，非武器 EWS）
	var weapons := [
		{"id": "t_axe", "name": "试斧", "slot": "main_hand",
			"ews": [{"skill": "t_ews_heal", "requires": [{"prof": "wp_axe", "value": 600}]}]},
		{"id": "t_kit", "name": "试包", "slot": "off_hand",
			"ews": [{"skill": "t_ews_heal"}]},
	]
	var wf = FileAccess.open("user://test_ws_weapons.json", FileAccess.WRITE)
	wf.store_string(JSON.stringify(weapons, "  "))
	wf.close()
	ItemDB._paths_override = {"weapon": "user://test_ws_weapons.json"}
	ItemDB.reload_data()
	ItemInstances.clear()
	var holder = Unit.new("持械", "player", 4, 0)
	holder.equipment["main_hand"] = ItemInstances.create("t_axe")
	holder.equipment["off_hand"] = ItemInstances.create("t_kit")
	var ents: Array = holder.ews_entries()
	ck(ents.size() == 1 and str(ents[0]["slot"]) == "main_hand" and not bool(ents[0]["unlocked"]),
		"副手无条件授予被忽略——主手条目（锁：斧600未达）是唯一条目")
	holder.equipment["main_hand"] = int(holder.equipment["off_hand"])   # t_kit 换上主手
	ents = holder.ews_entries()
	ck(ents.size() == 1 and bool(ents[0]["unlocked"]), "换到主手 → 无条件条目供给且解锁")
	holder.equipment["main_hand"] = 0
	ck(holder.ews_entries().is_empty(), "主手空 → 能力表无 EWS（副手仍持械也不读）")
	ItemDB._paths_override = {}
	ItemDB.reload_data()
	ItemInstances.clear()

	SkillDB._path_override = ""
	SkillDB.reload_data()
	if _fail == 0:
		print("=== 全 PASS ===")
	else:
		print("=== 失败 %d 项 ===" % _fail)
	quit(_fail)
