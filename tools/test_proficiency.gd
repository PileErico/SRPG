extends SceneTree
## 技艺（熟练度域）子系统回归——🔒 docs/模块_属性成长_设计.md §2。
## 覆盖：ProfDB 表/阶段阈值 → 学习/装载/卸载（装载=总开关、容量节拍）→ 涨值/进阶重挂 →
## 前置资格（AND/OR·一次性闸门·浮现）→ proto profs 块往返 → 战中快照往返 → 战斗涨值挂钩。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_proficiency.gd（退出码 0=PASS）

const Unit := preload("res://Unit.gd")
const UnitFactory := preload("res://UnitFactory.gd")
const ProfDB := preload("res://ProfDB.gd")
const BattleState := preload("res://BattleState.gd")
const ItemInstances := preload("res://ItemInstances.gd")

var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _initialize() -> void:
	print("=== 技艺/熟练度 子系统 测试开始 ===")
	ItemInstances.clear()

	# 1) 注册表与阶段曲线
	ck(ProfDB.all_ids().size() == 32, "32 个域（实得 %d）" % ProfDB.all_ids().size())
	ck(ProfDB.ids_by_page("style").size() == 11 and ProfDB.ids_by_page("weapon").size() == 11
		and ProfDB.ids_by_page("life").size() == 10, "三页 11/11/10（2026-07-07 +style_block 格挡域 §10.3）")
	ck(ProfDB.stage_of(0) == 1 and ProfDB.stage_of(99) == 1 and ProfDB.stage_of(100) == 2
		and ProfDB.stage_of(300) == 3 and ProfDB.stage_of(599) == 3 and ProfDB.stage_of(600) == 4
		and ProfDB.stage_of(999) == 4 and ProfDB.stage_of(1000) == 5, "阶段阈值 0/100/300/600/1000（🔒 2026-07-06 用户定曲线）")
	ck(int(ProfDB.MASTER_XP_CAP) == 1500, "大师计量满值 1500")
	ck(ProfDB.stage_name(3) == "老练" and ProfDB.stage_name(5) == "大师", "阶段名")

	# 2) 槽位容量=等级解锁节拍 1/4/8/11/16（🔒 §10.1 二次修订 20 级表）
	var u = Unit.new("练习生", "player", -1, -1)
	ck(u.prof_slot_capacity() == 1, "1 级容量 1")
	u.level = 9
	ck(u.prof_slot_capacity() == 3, "9 级容量 3（1/4/8）")
	u.level = 15
	ck(u.prof_slot_capacity() == 4, "15 级容量 4（16 未到）")
	u.level = 16
	ck(u.prof_slot_capacity() == 5, "16 级容量 5（满）")

	# 3) 学习/装载/卸载：未学不可装；装载挂阶段补正、卸载全摘（装载=总开关）；熟练度冻结保留
	u.level = 1
	ck(not u.slot_prof("wp_sword"), "未学不可装载")
	ck(u.learn_prof("wp_sword"), "学会 剑")
	ck(not u.learn_prof("wp_sword"), "重复学习被拒")
	u.prof_xp["wp_sword"] = 300   # 老练
	var acc0 := u.effective_stat_f("acc")
	ck(u.slot_prof("wp_sword"), "装载 剑")
	ck(u.effective_stat_f("acc") == acc0 + 3.0 and u.effective_stat_f("atk") > 0.0, "老练补正 acc+3 生效（实得 %.1f 基 %.1f）" % [u.effective_stat_f("acc"), acc0])
	ck(u.learn_prof("wp_dagger") and not u.slot_prof("wp_dagger"), "容量满（1级1格）第二个装不进")
	u.unslot_prof("wp_sword")
	ck(u.effective_stat_f("acc") == acc0, "卸载=总开关：补正全摘")
	ck(int(u.prof_xp.get("wp_sword", 0)) == 300, "卸载后熟练度冻结保留")

	# 4) 涨值：仅装载中可涨；进阶重挂补正
	ck(u.gain_prof("wp_sword", 100) == 0 and int(u.prof_xp.get("wp_sword", 0)) == 300, "卸载中不涨（冻结）")
	u.slot_prof("wp_sword")
	ck(u.gain_prof("wp_sword", 100) == 0, "涨值未跨阶不报进阶")
	var ns := u.gain_prof("wp_sword", 300)   # 300+100+300=700 → 专家
	ck(ns == 4, "跨阶报进阶（专家，实得 %d）" % ns)
	ck(u.effective_stat_f("acc") == acc0 + 4.0, "进阶重挂：acc+4（实得 %.1f）" % u.effective_stat_f("acc"))

	# 5) 前置资格：一次性闸门 + AND/OR + 浮现
	var v = Unit.new("修行者", "player", -1, -1)
	v.level = 17
	ck(not v.prof_visible("wp_katana"), "太刀前置未达=隐藏")
	ck(not v.learn_prof("wp_katana"), "资格不足学不了")
	v.prof_xp["wp_sword"] = 300           # 剑 老练（AND）
	ck(not v.prof_requires_met("wp_katana"), "只满足 all 不满足 any 仍不资格")
	v.prof_xp["style_two_handed"] = 300   # 双手 老练（OR 之一）
	ck(v.prof_visible("wp_katana") and v.learn_prof("wp_katana"), "剑+双手达老练 → 太刀浮现可学")
	v.prof_xp["wp_sword"] = 0             # 一次性闸门：学会后卸掉前置不影响
	ck(v.prof_known.has("wp_katana") and v.slot_prof("wp_katana"), "学会后前置清零仍可装载（一次性资格 🔒）")
	# 镰刀=纯 AND：双手已老练但长柄未达 → 不资格
	ck(not v.prof_requires_met("wp_scythe"), "镰刀 AND 前置（缺长柄）不资格")

	# 6) proto profs 块 → make_unit → unit_to_proto 往返
	var protos := UnitFactory.all_prototypes()
	var bel := {}
	for p in protos:
		if str(p.get("id", "")) == "belooz":
			bel = p
			break
	ck(not bel.is_empty(), "belooz 原型在")
	var bu = UnitFactory.make_unit(bel, "player", 0, 0)
	ck(bu.prof_slots.has("style_unarmed") and bu.prof_stage("style_unarmed") == 3, "比路兹体术老练已装载")
	var has_prof_mod := false
	for m in bu.modifiers:
		if str(m.get("source", "")) == "prof:style_unarmed":
			has_prof_mod = true
	ck(has_prof_mod, "装载补正已挂（prof: source）")
	var back := UnitFactory.unit_to_proto(bu)
	ck(back.get("profs", {}).get("xp", {}).get("style_unarmed", 0) == 300, "unit_to_proto 写回 profs")

	# 7) 战中快照往返（modifiers 整份走、prof 三字段原样）
	var snap := UnitFactory.unit_to_battle_snapshot(bu)
	var bu2 = UnitFactory.unit_from_battle_snapshot(JSON.parse_string(JSON.stringify(snap)))
	ck(bu2.prof_slots.has("style_unarmed") and int(bu2.prof_xp.get("style_unarmed", 0)) == 300, "快照往返 prof 字段")
	var mod2 := false
	for m in bu2.modifiers:
		if str(m.get("source", "")) == "prof:style_unarmed":
			mod2 = true
	ck(mod2, "快照往返 prof 修正（随 modifiers 整份）")

	# 8) 战斗涨值挂钩：爪击（unarmed/weapon_claw tags）喂 体术；挥空也算练习
	var bs = BattleState.new()
	var foe = Unit.new("靶子", "enemy", 1, 0)
	var xp0 := int(bu.prof_xp.get("style_unarmed", 0))
	var evs: Array = bs.grant_combat_prof(bu, foe, {"hit": false, "blocked": false, "hp_loss": 0, "armor_loss": 0})
	ck(int(bu.prof_xp.get("style_unarmed", 0)) > xp0, "攻击（挥空）喂养体术（%d→%d）" % [xp0, int(bu.prof_xp.get("style_unarmed", 0))])
	# 目标格挡喂盾：给靶子装盾+装载盾技艺
	foe.learn_prof("style_shield")
	foe.slot_prof("style_shield", true)
	foe.equip("wood_kite_shield")
	var sxp0 := int(foe.prof_xp.get("style_shield", 0))
	bs.grant_combat_prof(bu, foe, {"hit": true, "blocked": true, "hp_loss": 0, "armor_loss": 1})
	ck(int(foe.prof_xp.get("style_shield", 0)) > sxp0, "格挡喂养盾")
	ck(evs is Array, "事件形状")

	if _fail == 0:
		print("=== 全部断言 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
