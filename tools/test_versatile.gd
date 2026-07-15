extends SceneTree
## 决策35 执行回归（🔒 docs/模块_技能_设计.md「决策35」）：兼用型武器 versatile + 技能握持条件 grip。
##  · 槽位资格：versatile 主手/副手皆可入（EquipSlots）
##  · 有效握持 effective_grip：另一手空置（或只有拳脚 natural）→ 双手；有物 → 单手；与装在哪个槽无关
##    （副手单件同样算双手——「事实层面只装备了这一把」用户拍板 2026-07-14）；单/双手件静态；盾/天生/徒手 ""
##  · 双固有面板：顶层三键=双手形态（source i_）+ one_handed 子面板=单手形态（i1_）——
##    _grip_source_active 按握持只放行一套（格挡休眠同族 source 门控，零重挂）
##  · 熟练度喂养动态跟随：current_attack_tags 注入有效握持 tag
##  · 武器侧握持组（🔒 决策35 修订 2026-07-15：握持是武器的属性）：BWS 双槽（bws/bws_2h 随握持切、
##    单槽共用回退）+ EWS 两桶（ews=单手组/ews_2h=双手组，ews_grip_ok 菜单/守卫同口）
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_versatile.gd（退出码 0=PASS）

const SandboxScript := preload("res://Sandbox.gd")
const UnitC := preload("res://Unit.gd")
const SkillDB := preload("res://SkillDB.gd")
const ItemDB := preload("res://ItemDB.gd")
const ItemInstances := preload("res://ItemInstances.gd")
const EquipSlots := preload("res://EquipSlots.gd")

var _fail := 0
func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

# 裸单位（dual_strike mk 同法）：清修正/装备、中性可控 stats。
func mk(nm: String, fac: String, col: int, row: int):
	var u = UnitC.new(nm, fac, col, row)
	u.modifiers = []
	u.equipment = {}
	u.stats = {
		"HP": 400, "HP_max": 500, "armor": 0, "armor_max": 0,
		"AP_max": 4, "move": 4, "speed": 0, "sight": 5,
		"atk": 20, "atk_eff": 100, "def_eff": 100, "offhand_eff": 50,
		"acc": 200, "eva": 0, "crit_rate": 0, "crit_dmg": 150,
		"block_rate": 0, "block_power": 0,
		"res_phys": 0, "res_nature": 0, "will_fort": 0, "body_fort": 0,
		"finesse": 0, "agility": 0, "luck": 0, "resolve": 0,
		"armor_res_phys": 0, "armor_res_nature": 0,
		"dr_flat_human": 0, "dr_flat_armor": 0,
	}
	u.morale = 25
	return u

func _initialize() -> void:
	print("=== 决策35 兼用武器/握持条件 测试开始 ===")
	# —— 临时技能库（🔒 决策35 修订：技能侧无 grip 键——握持组在武器侧）：
	# 两条 BWS（双槽试料）+ 两条 EWS（heal 形＝可跑块，供 apply_skill 守卫测试）——
	var skills := [
		{"id": "vt_bws", "name": "矛刺", "active": true, "weapon_skill": true, "tags": [],
			"costs": {"ap": 1}, "cooldown": {"base": 0}, "max_level": 1,
			"target": {"enemy": true, "ally": false, "self": false}, "range": 1,
			"effects": [{"kind": "attack", "hits": [{"coeff": 1.0}]}]},
		{"id": "vt_bws2", "name": "双手贯刺", "active": true, "weapon_skill": true, "tags": [],
			"costs": {"ap": 1}, "cooldown": {"base": 0}, "max_level": 1,
			"target": {"enemy": true, "ally": false, "self": false}, "range": 1,
			"effects": [{"kind": "attack", "hits": [{"coeff": 1.2}]}]},
		{"id": "vt_2h", "name": "双手上劈", "active": true, "weapon_skill": true, "tags": [],
			"costs": {"ap": 1}, "cooldown": {"base": 0}, "max_level": 1,
			"target": {"enemy": false, "ally": false, "self": true}, "range": 0,
			"effects": [{"kind": "heal", "heal_pct_max_hp": 10}]},
		{"id": "vt_1h", "name": "单手突刺", "active": true, "weapon_skill": true, "tags": [],
			"costs": {"ap": 1}, "cooldown": {"base": 0}, "max_level": 1,
			"target": {"enemy": false, "ally": false, "self": true}, "range": 0,
			"effects": [{"kind": "heal", "heal_pct_max_hp": 10}]},
	]
	var sf = FileAccess.open("user://test_vt_skills.json", FileAccess.WRITE)
	sf.store_string(JSON.stringify(skills, "  "))
	sf.close()
	SkillDB._path_override = "user://test_vt_skills.json"
	SkillDB.reload_data()
	# —— 临时物品库：兼用矛（双面板+BWS 双槽+EWS 两桶）/ 只配单槽的兼用枪（共用回退试料）/ 普通单手剑 / 盾 / 拳脚 ——
	var weapons := [
		{"id": "vt_spear", "name": "翼矛", "slot": "main_hand", "tags": ["versatile"],
			"bws": "vt_bws", "bws_2h": "vt_bws2",
			"atk": 8, "block_rate": 10, "block_power": 0,
			"one_handed": {"atk": 5, "block_rate": 4, "block_power": 0},
			"ews": [{"skill": "vt_1h"}], "ews_2h": [{"skill": "vt_2h"}]},
		{"id": "vt_lance", "name": "短枪", "slot": "main_hand", "tags": ["versatile"],
			"bws": "vt_bws",
			"atk": 6, "block_rate": 0, "block_power": 0,
			"one_handed": {"atk": 4, "block_rate": 0, "block_power": 0}},
		{"id": "vt_sword", "name": "素剑", "slot": "main_hand", "tags": ["one_handed"], "bws": "vt_bws",
			"atk": 0, "block_rate": 0, "block_power": 0},
		{"id": "vt_shield", "name": "木盾", "slot": "off_hand", "tags": ["shield"]},
		{"id": "vt_fists", "name": "拳脚", "slot": "main_hand", "tags": [], "innate": true, "natural": true},
	]
	var wf = FileAccess.open("user://test_vt_weapons.json", FileAccess.WRITE)
	wf.store_string(JSON.stringify(weapons, "  "))
	wf.close()
	ItemDB._paths_override = {"weapon": "user://test_vt_weapons.json"}
	ItemDB.reload_data()
	ItemInstances.clear()

	# —— 1) 槽位资格：versatile 主/副手皆可 ——
	var spear_tpl = ItemDB.get_item("vt_spear")
	ck(EquipSlots.accepts("main_hand", spear_tpl), "versatile 可入主手")
	ck(EquipSlots.accepts("off_hand", spear_tpl), "versatile 可入副手")
	ck(not EquipSlots.accepts("head", spear_tpl), "versatile 不入非手槽")

	# —— 2) 有效握持 + 双固有面板切换（主手线）——
	var a = mk("翼矛手", "player", 3, 3)
	ck(a.equip("vt_spear"), "装翼矛（主手）")
	ck(a.effective_grip("main_hand") == "two_handed", "单持 → 双手形态")
	ck(absf(a.effective_stat_f("atk") - 28.0) < 0.001, "单持 atk＝20+8（双手面板放行，单手面板 i1_ 门控关）")
	a.modifiers.append({"stat": "weapon_block", "op": "flat", "value": 1, "source": "perk:格挡"})
	ck(a.effective_stat("block_rate") == 10, "单持 block_rate＝双手面板 10（weapon_block 激活）")
	ck(a.equip("vt_shield"), "副手装盾")
	ck(a.effective_grip("main_hand") == "one_handed", "配盾 → 单手形态")
	ck(absf(a.effective_stat_f("atk") - 25.0) < 0.001, "配盾 atk＝20+5（单手面板放行，双手面板 i_ 门控关）")
	ck(a.effective_stat("block_rate") == 4, "配盾 block_rate＝单手面板 4")
	a.unequip("off_hand")
	ck(a.effective_grip("main_hand") == "two_handed" and absf(a.effective_stat_f("atk") - 28.0) < 0.001,
		"卸盾即回双手形态（动态读、零重挂）")

	# —— 3) 副手单件＝双手（用户拍板：判据=另一手是否空置，拳脚视同空手）——
	var b = mk("副手流", "player", 4, 3)
	ck(b.equip("vt_fists"), "主手拳脚（natural 试料）")
	ck(b.equip("vt_spear", "off_hand"), "翼矛装进副手")
	ck(b.effective_grip("off_hand") == "two_handed", "副手单件+主手拳脚 → 仍算双手（拳脚≠装备）")
	ck(absf(b.effective_stat_f("atk") - 28.0) < 0.001, "副手单件吃双手面板 atk 8")
	ck(b.equip("vt_sword"), "主手装真武器（顶掉拳脚）")
	ck(b.effective_grip("off_hand") == "one_handed", "主手有物 → 副手件转单手形态")
	ck(absf(b.effective_stat_f("atk") - 25.0) < 0.001, "转单手面板 atk 5")

	# —— 4) 双持两把兼用（双长剑式）：各自的另一手都有物 → 双双单手 ——
	var c = mk("双翼矛", "player", 5, 3)
	ck(c.equip("vt_spear") and c.equip("vt_spear", "off_hand"), "双持两把翼矛")
	ck(c.effective_grip("main_hand") == "one_handed" and c.effective_grip("off_hand") == "one_handed",
		"双持 → 两件各自单手形态")
	ck(absf(c.effective_stat_f("atk") - 30.0) < 0.001, "双持 atk＝20+5+5（两件单手面板）")

	# —— 5) 静态件/无握持件的 effective_grip ——
	var d = mk("对照", "player", 6, 3)
	ck(d.effective_grip("main_hand") == "", "空手 → 无握持")
	ck(d.equip("vt_sword") and d.effective_grip("main_hand") == "one_handed", "单手件 → 静态 one_handed")

	# —— 6) 熟练度喂养动态跟随：current_attack_tags 注入有效握持 tag ——
	var e = mk("喂养", "player", 3, 5)
	ck(e.equip("vt_spear"), "装翼矛")
	var t1: Array = e.current_attack_tags()
	ck(t1.has("versatile") and t1.has("two_handed") and not t1.has("one_handed"), "单持喂「双手」style（注入 two_handed）")
	ck(e.equip("vt_shield"), "配盾")
	var t2: Array = e.current_attack_tags()
	ck(t2.has("one_handed") and not t2.has("two_handed"), "配盾喂「单手」style（注入 one_handed）")

	# —— 7) 武器侧握持组（🔒 决策35 修订）：BWS 双槽随握持切 + EWS 两桶 ews_grip_ok + apply_skill 守卫 ——
	var sb = SandboxScript.new()
	sb._new_grassland(7, 7)
	var g = mk("施放者", "player", 3, 3)
	ck(g.equip("vt_spear"), "装翼矛（单持=双手）")
	sb.units = [g]
	ck(str(g.basic_attack().get("name", "")) == "双手贯刺", "单持 → 普攻走双手槽 bws_2h（双手贯刺）")
	ck(g.ews_grip_ok("vt_2h") and not g.ews_grip_ok("vt_1h"), "单持：双手组 EWS 可用、单手组灰（ews_grip_ok）")
	g.ap = 4
	var ev_fail: Array = sb._state.apply_skill(g, "vt_1h", g)
	ck(ev_fail.is_empty() and g.ap == 4, "守卫：握持组不匹配 → 拒发零消耗（AP 不动）")
	var hp0 := int(g.stats["HP"])
	var ev_ok: Array = sb._state.apply_skill(g, "vt_2h", g)
	ck(not ev_ok.is_empty() and g.ap == 3 and int(g.stats["HP"]) > hp0, "握持组匹配 → 正常施放（扣 AP+生效）")
	ck(g.equip("vt_shield"), "配盾切单手")
	ck(str(g.basic_attack().get("name", "")) == "矛刺", "配盾 → 普攻走单手槽 bws（矛刺）")
	ck(not g.ews_grip_ok("vt_2h") and g.ews_grip_ok("vt_1h"), "配盾：单手组亮、双手组灰（战斗中即时翻转）")
	var ev_fail2: Array = sb._state.apply_skill(g, "vt_2h", g)
	ck(ev_fail2.is_empty() and g.ap == 3, "守卫：配盾后双手组拒发零消耗")
	# 菜单口径：EWS 条目带 grip_req（Sandbox 灰显同吃）
	var reqs := {}
	for en in g.ews_entries():
		reqs[str(en["id"])] = str(en.get("grip_req", ""))
	ck(str(reqs.get("vt_1h", "")) == "one_handed" and str(reqs.get("vt_2h", "")) == "two_handed",
		"ews_entries 两桶各带 grip_req（单手组/双手组）")

	# —— 8) BWS 单槽共用回退（只配 bws 的兼用件：双手形态共用单手槽）+ 非 EWS 无握持概念 ——
	var g2 = mk("短枪手", "player", 4, 3)
	ck(g2.equip("vt_lance"), "装短枪（兼用·只配单手槽 bws）")
	ck(str(g2.basic_attack().get("name", "")) == "矛刺", "单持无 bws_2h → 共用单手槽（矛刺）")
	ck(g.ews_grip_ok("vt_bws"), "非 EWS 引用（bws/已学技能）＝无握持概念恒可用")

	# —— 清场：撤 override、清实例 ——
	SkillDB._path_override = ""
	SkillDB.reload_data()
	ItemDB._paths_override = {}
	ItemDB.reload_data()
	ItemInstances.clear()
	sb.free()

	if _fail == 0:
		print("=== 全部断言 PASS ===")
	else:
		print("=== 失败 %d 项 ===" % _fail)
	quit(0 if _fail == 0 else 1)
