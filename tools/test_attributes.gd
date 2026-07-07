extends SceneTree
## 四属性+成长定案回归（🔒 模块_属性成长_设计.md §10.1/§10.4/§10.6，2026-07-07 数值定案）：
## 种族重基（HP40/四属性底值）/ 命中=武器命中+技巧−闪避−灵活 / 暴击=招式+技巧×0.5−对方运气 /
## 回合序=speed+灵活 / 自动轨成长（HP+1·双韧+2）/ 15 级帽 / c 节点加点（四选二×5=10 次，幅度各异）/
## 天生武器实装（拳脚入位/被顶替/回位/proto 不序列化）/ 格挡装备取高 / 条件 mod requires_prof。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_attributes.gd（退出码 0=PASS）

const BattleState := preload("res://BattleState.gd")
const UnitFactory := preload("res://UnitFactory.gd")
const ItemInstances := preload("res://ItemInstances.gd")
const WorldState := preload("res://WorldState.gd")

var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func proto_by_id(protos: Array, id: String) -> Dictionary:
	for p in protos:
		if str(p.get("id", "")) == id:
			return p
	return {}

func _initialize() -> void:
	print("=== 四属性/成长定案 测试开始 ===")
	WorldState.current = null
	var protos := UnitFactory.all_prototypes()
	var inf := proto_by_id(protos, "empire_infantry")   # 无装备、无 stats 覆盖的纯人类模板
	ck(not inf.is_empty(), "帝国步兵模板存在")

	# —— 1) 种族重基与四属性底值 ——
	var u = UnitFactory.make_unit(inf, "player", 3, 3)
	ck(int(u.effective_stat("HP_max")) == 40, "人类 HP_max=40（实际 %d）" % u.effective_stat("HP_max"))
	ck(int(u.stats.get("finesse", -1)) == 10, "技巧底值 10")
	ck(int(u.stats.get("agility", -1)) == 10, "灵活底值 10")
	ck(int(u.stats.get("luck", -1)) == 5, "运气底值 5")
	ck(int(u.stats.get("resolve", -1)) == 0, "决心底值 0")
	ck(int(u.stats.get("crit_rate", -1)) == 0 and int(u.stats.get("block_rate", -1)) == 0, "暴击/格挡人身底率归零")

	# —— 2) 天生武器实装（🔒 §10.4）——
	ck(u.equipment.has("main_hand"), "生成即主手非空（拳脚入位）")
	var fist = ItemInstances.view(int(u.equipment["main_hand"]))
	ck(fist != null and bool(fist.get("natural", false)), "主手＝默认型天生武器")
	ck(str(u.basic_attack().get("name", "")) == "徒手", "普攻＝拳脚攻击行为")
	ck(is_equal_approx(u.effective_stat_f("atk"), 2.5), "徒手攻击力 2.5（数值在拳脚条目）")
	ck(is_equal_approx(u.effective_stat_f("acc"), 25.0), "徒手命中 25（武器侧承载）")
	# 顶替：装长剑 → 拳脚收回；卸下 → 拳脚回位
	ck(u.equip("long_sword"), "装长剑成功（顶掉拳脚）")
	ck(is_equal_approx(u.effective_stat_f("atk"), 5.0) and is_equal_approx(u.effective_stat_f("acc"), 30.0),
		"长剑数值生效且拳脚修正无残留（atk=5 acc=30）")
	var sword_uid: int = int(u.equipment["main_hand"])
	u.unequip("main_hand")
	ck(u.equipment.has("main_hand") and int(u.equipment["main_hand"]) != sword_uid, "卸剑后拳脚自动回位")
	ck(is_equal_approx(u.effective_stat_f("atk"), 2.5), "回位后徒手数值恢复")
	ck(not u.apply_attr_pick("HP_max"), "非四属性键不可加点")
	# proto 序列化不带拳脚
	var proto := UnitFactory.unit_to_proto(u)
	ck(not proto.get("equip", []).has("unarmed_fists"), "拳脚不入 proto（make_unit 再造）")

	# —— 3) 命中/暴击/回合序公式（🔒 §10.6）——
	var s = BattleState.new()
	s._new_grassland(9, 7)
	var e = UnitFactory.make_unit(inf, "enemy", 4, 3)
	s.units = [u, e]
	# 命中 = 拳脚25 + 技巧10 − (闪避0 + 灵活10) = 25
	ck(s._hit_chance(u, e) == 25, "命中公式：25+10−10=25（实际 %d）" % s._hit_chance(u, e))
	# 暴击 = 0 + 技巧10×0.5 − 对方运气5 = 0（钳底）；技巧 20 → 10−5 = 5
	seed(20260707)
	var r: Dictionary = s._resolve_compute(u, e, {"coeff": 1.0})
	if r.get("hit", false):
		ck(is_equal_approx(float(r.get("cr", -1)), 0.0), "基线互殴暴击率=0（5−5 钳底）")
	u.stats["finesse"] = 20
	seed(20260707)
	r = s._resolve_compute(u, e, {"coeff": 1.0})
	if r.get("hit", false):
		ck(is_equal_approx(float(r.get("cr", -1)), 5.0), "技巧20：暴击率=10−5=5（实际 %s）" % str(r.get("cr")))
	u.stats["finesse"] = 10
	ck(u.initiative() == 10, "回合序＝speed0+灵活10")
	u.modifiers.append({"stat": "agility", "op": "flat", "value": -3, "source": "equip:900:0"})
	ck(u.initiative() == 7, "防具减灵活 → 回合序同降（10−3=7）")
	ck(s._hit_chance(e, u) == 25 + 3, "灵活降 3 → 被命中 +3（实际 %d）" % s._hit_chance(e, u))
	u.modifiers.pop_back()

	# —— 4) 自动轨成长 + 15 级帽 + 加点（🔒 §10.1/§10.6）——
	var g = UnitFactory.make_unit(inf, "player", 0, 0)
	var hp0 := float(g.stats["HP"])
	g.gain_exp(100)   # → 2 级（c 节点）
	ck(g.level == 2, "升到 2 级")
	ck(int(g.effective_stat("HP_max")) == 41, "HP_max 40→41（种族曲线 +1）")
	ck(is_equal_approx(float(g.stats["HP"]), hp0 + 1.0), "当前 HP 随上限 +1")
	ck(int(g.stats["will_fort"]) == 2 and int(g.stats["body_fort"]) == 2, "双强韧每级 +2")
	ck(g.attr_picks == 2, "c 节点得 2 次加点")
	ck(g.apply_attr_pick("finesse") and int(g.stats["finesse"]) == 12, "技巧加点 +2/次")
	ck(g.apply_attr_pick("luck") and int(g.stats["luck"]) == 6, "运气加点 +1/次")
	ck(not g.apply_attr_pick("luck"), "加点次数用尽")
	g.gain_exp(10000000)
	ck(g.level == 15, "等级帽 15（实际 %d）" % g.level)
	ck(int(g.effective_stat("HP_max")) == 40 + 14, "满级 HP_max=54（40+14 级成长）")
	ck(int(g.stats["will_fort"]) == 28, "满级意志强韧 28（14 级×2）")
	ck(g.attr_picks == 2 * 5 - 2, "满级累计加点 10 次（已花 2）")
	ck(g.prof_slot_capacity() == 5, "满级技艺槽 5（1/4/7/10/13）")
	var g2 = UnitFactory.make_unit(inf, "player", 0, 0)
	g2.gain_exp(100 + 120 + 144)   # → 4 级
	ck(g2.prof_slot_capacity() == 2, "4 级技艺槽 2 格")
	# level>1 原型的自动轨追溯（review 修复）：比路兹 level 5 → 鸟妖 35 + 4 级成长
	var bel := proto_by_id(protos, "belooz")
	if not bel.is_empty():
		var b5 = UnitFactory.make_unit(bel, "player", 0, 0)
		ck(int(b5.stats["HP_max"]) == 35 + 4, "5 级鸟妖原型面板 HP_max=39（追溯成长；effective 另含特性 +15）")
		ck(int(b5.stats["will_fort"]) == 8 and int(b5.stats["body_fort"]) == 8, "5 级原型双强韧追溯 +8")

	# —— 5) 格挡装备取高 + 条件 mod（🔒 §10.3）——
	var b = UnitFactory.make_unit(inf, "player", 0, 0)
	b.modifiers.append({"stat": "block_rate", "op": "flat", "value": 15, "source": "equip:101:0"})
	b.modifiers.append({"stat": "block_rate", "op": "flat", "value": 10, "source": "equip:102:0"})
	ck(is_equal_approx(b.effective_stat_f("block_rate"), 15.0), "装备格挡件间取高（15,10→15 不叠加）")
	b.modifiers.append({"stat": "block_rate", "op": "flat", "value": 5, "source": "buff:操典"})
	ck(is_equal_approx(b.effective_stat_f("block_rate"), 20.0), "buff 来源叠加其上（15+5=20）")
	b.modifiers.append({"stat": "block_rate", "op": "flat", "value": 40, "source": "equip:103:0", "requires_prof": "style_block"})
	ck(is_equal_approx(b.effective_stat_f("block_rate"), 20.0), "未装载格挡域：武器格挡不激活")
	b.prof_slots.append("style_block")
	ck(is_equal_approx(b.effective_stat_f("block_rate"), 45.0), "装载格挡域：武器格挡激活并取高（40+5）")
	# 盾（无门槛）直接生效
	var d = UnitFactory.make_unit(inf, "player", 0, 0)
	ck(d.equip("wood_kite_shield"), "装斗盾")
	ck(is_equal_approx(d.effective_stat_f("block_rate"), 15.0) and is_equal_approx(d.effective_stat_f("block_power"), 35.0),
		"盾格挡天生激活（15/35）")

	# —— 6) attr_picks 序列化往返 ——
	g.attr_picks = 7
	var snap: Dictionary = UnitFactory.unit_to_battle_snapshot(g)
	var back = UnitFactory.unit_from_battle_snapshot(JSON.parse_string(JSON.stringify(snap)))
	ck(back.attr_picks == 7, "battle 快照 attr_picks 往返")
	var p2 := UnitFactory.unit_to_proto(g)
	ck(int(p2.get("attr_picks", 0)) == 7, "proto 层 attr_picks 保留")

	if _fail == 0:
		print("=== 四属性/成长定案 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
