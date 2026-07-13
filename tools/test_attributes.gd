extends SceneTree
## 四属性+成长定案回归（🔒 模块_属性成长_设计.md §10.1/§10.4/§10.6，2026-07-07 数值定案）：
## 种族重基（HP40/四属性底值）/ 命中=武器命中+技巧−闪避−灵活 / 暴击=招式+技巧×0.5−对方运气 /
## 回合序=speed+floor(灵活/2) / 自动轨成长（种族节奏数组）/ 20 级帽 / 属性点 9 节点 18 点（可同投）/ 水生·条件移动力 /
## 天生武器实装（拳脚入位/被顶替/回位/proto 不序列化）/ 格挡装备取高 / 条件 mod requires_prof。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_attributes.gd（退出码 0=PASS）

const BattleState := preload("res://BattleState.gd")
const UnitFactory := preload("res://UnitFactory.gd")
const ItemInstances := preload("res://ItemInstances.gd")
const WorldState := preload("res://WorldState.gd")
const Unit := preload("res://Unit.gd")
const RaceDB := preload("res://RaceDB.gd")

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
	ck(not proto_by_id(protos, "empire_infantry").is_empty(), "帝国步兵模板存在")
	# 裸人类模板由测试自带（不绑出货内容——empire_infantry 已配装备，内容允许演进；拳脚/底值基线须无装备）
	var inf := {"id": "_test_bare_human", "name": "裸人", "race": "human",
		"default_faction": "player", "tags": ["ground", "human"], "equip": [], "skills": {}, "trait": ""}

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
	ck(is_equal_approx(u.effective_stat_f("acc"), 0.0), "acc 面板 0（基准命中在武器技能 hit——决策33 三轮校准）")
	# 顶替：装长剑 → 拳脚收回；卸下 → 拳脚回位
	ck(u.equip("long_sword"), "装长剑成功（顶掉拳脚）")
	ck(is_equal_approx(u.effective_stat_f("atk"), 5.0) and is_equal_approx(u.effective_stat_f("acc"), 0.0),
		"长剑数值生效且拳脚修正无残留（atk=5；acc 非武器固有——基准命中已迁武器技能 hit，决策33 三轮校准）")
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
	# 命中 = 武器技能基准25（bws_unarmed hit——决策33 三轮校准：基准命中在技能侧非武器 acc）+ 技巧10 − (闪避0+灵活10) = 25
	var ua: Dictionary = u.basic_attack()
	ck(int(ua.get("hit", 0)) == 25, "拳脚 BWS 携带基准命中 25（原武器 acc 迁移）")
	ck(s._hit_chance(u, e, ua) == 25, "命中公式：25+10−10=25（实际 %d）" % s._hit_chance(u, e, ua))
	ck(s._hit_chance(u, e, {"hit": 20}) == 20, "技能基准命中 hit=20 → 20+10−10=20（实际 %d）" % s._hit_chance(u, e, {"hit": 20}))
	ck(int(s._hit_chance_detail(u, e, {"hit": 20})["acc"]) == int(s._hit_chance_detail(u, e)["acc"]) + 20,
		"技能基准并入 acc 展示项（判定/战斗记录口径合一）")
	# 暴击 = 0 + 技巧10×0.5 − 对方运气5 = 0（钳底）；技巧 20 → 10−5 = 5
	s.rng.seed = 20260707   # 注入定序（战斗骰统一过 BattleState.rng——技改 §1-1）
	var r: Dictionary = s._resolve_compute(u, e, {"coeff": 1.0})
	if r.get("hit", false):
		ck(is_equal_approx(float(r.get("cr", -1)), 0.0), "基线互殴暴击率=0（5−5 钳底）")
	u.stats["finesse"] = 20
	s.rng.seed = 20260707
	r = s._resolve_compute(u, e, {"coeff": 1.0})
	if r.get("hit", false):
		ck(is_equal_approx(float(r.get("cr", -1)), 5.0), "技巧20：暴击率=10−5=5（实际 %s）" % str(r.get("cr")))
	u.stats["finesse"] = 10
	ck(u.initiative() == 5, "回合序＝speed0＋灵活10/2 向下取整（🔒 2026-07-08 减半修订）")
	u.modifiers.append({"stat": "agility", "op": "flat", "value": -3, "source": "equip:900:0"})
	ck(u.initiative() == 3, "防具减灵活 → 回合序减半降（floor(7/2)=3）")
	ck(s._hit_chance(e, u, e.basic_attack()) == 25 + 3, "灵活降 3 → 被命中 +3（闪避仍吃满灵活）")
	u.modifiers.pop_back()

	# —— 4) 自动轨成长（节奏数组）+ 20 级帽 + 加点（🔒 §10.1 二次修订 2026-07-08）——
	var g = UnitFactory.make_unit(inf, "player", 0, 0)
	var hp0 := float(g.stats["HP"])
	g.gain_exp(100)   # → 2 级（属性点节点）
	ck(g.level == 2, "升到 2 级")
	ck(int(g.effective_stat("HP_max")) == 41, "HP_max 40→41（人类逢双升 [1,0]）")
	ck(is_equal_approx(float(g.stats["HP"]), hp0 + 1.0), "当前 HP 随上限 +1")
	ck(int(g.stats["will_fort"]) == 2 and int(g.stats["body_fort"]) == 2, "双强韧每级 +2")
	ck(g.attr_picks == 2, "属性点节点得 2 点")
	ck(g.apply_attr_pick("finesse") and int(g.stats["finesse"]) == 11, "技巧加点 +1/点（增量统一）")
	ck(g.can_attr_pick("finesse") and g.apply_attr_pick("finesse") and int(g.stats["finesse"]) == 12,
		"双点可同投一属性（🔒 配对约束已废除）")
	ck(not g.apply_attr_pick("luck"), "点数用尽")
	g.gain_exp(10000000)
	ck(g.level == 20, "等级帽 20（实际 %d）" % g.level)
	ck(int(g.effective_stat("HP_max")) == 50, "满级 HP_max=50（40+逢双升×10）")
	ck(int(g.stats["will_fort"]) == 38, "满级意志强韧 38（19 级×2）")
	ck(g.attr_picks == 9 * 2 - 2, "满级累计 18 点（9 节点；已花 2）")
	ck(g.prof_slot_capacity() == 5, "满级技艺槽 5（1/4/8/11/16）")
	var g2 = UnitFactory.make_unit(inf, "player", 0, 0)
	g2.gain_exp(100 + 120 + 144)   # → 4 级
	ck(g2.prof_slot_capacity() == 2, "4 级技艺槽 2 格")
	# level>1 原型的自动轨追溯（逐级行走）：比路兹 level 5 → 鸟妖 35 + 仅 3 级那次 +1（[1,0,0] 逢三升）
	var bel := proto_by_id(protos, "belooz")
	if not bel.is_empty():
		var b5 = UnitFactory.make_unit(bel, "player", 0, 0)
		ck(int(b5.stats["HP_max"]) == 36, "5 级鸟妖原型面板 HP_max=36（逢三升；effective 另含特性 +15）")
		ck(int(b5.stats["will_fort"]) == 8 and int(b5.stats["body_fort"]) == 4, "5 级鸟妖双韧追溯 意志+8/肉体+4")

	# —— 4b) 种族终表 + 条件移动力（🔒 2026-07-08 二次修订：中庸/敏捷/坚韧三人设）——
	var liz = Unit.new("蜥候", "player", 0, 0)
	RaceDB.apply_to(liz, "lizardmen")
	ck(int(liz.stats["HP_max"]) == 45 and int(liz.stats["move"]) == 3 and int(liz.stats["sight"]) == 4,
		"蜥蜴人底值 HP45/移动3/视野4")
	ck(int(liz.stats["finesse"]) == 8 and int(liz.stats["agility"]) == 6 and int(liz.stats["luck"]) == 3
		and int(liz.stats["resolve"]) == 4 and int(liz.stats["body_fort"]) == 5,
		"蜥蜴人 技巧8/灵活6/运气3/决心4/肉韧5（坚韧）")
	ck(liz.tags.has("aquatic"), "蜥蜴人种族自带〈水生动物〉tag")
	ck(liz.move_allowance() == 3 and liz.move_allowance(["water", "shallow"]) == 4,
		"蜥蜴人条件移动力：陆 3 / 水域 4（when_tile_tag）")
	liz.init_vitals()
	ck(liz.morale == 29, "决心4 → 初始士气 25+4=29（🔒 +1/点）")
	liz.level = 2
	liz._apply_level_growth()
	ck(int(liz.stats["HP_max"]) == 46 and int(liz.stats["will_fort"]) == 1 and int(liz.stats["body_fort"]) == 7,
		"蜥蜴人 2 级：HP+1（交替从1起）/意志+1/肉体+2")
	liz.level = 3
	liz._apply_level_growth()
	ck(int(liz.stats["HP_max"]) == 48, "蜥蜴人 3 级：HP+2（1/2 交替）")
	var hp = Unit.new("鸟候", "player", 0, 0)
	RaceDB.apply_to(hp, "harpy")
	ck(int(hp.stats["finesse"]) == 12 and int(hp.stats["agility"]) == 14 and int(hp.stats["luck"]) == 3,
		"鸟妖 技巧12/灵活14/运气3（敏捷）")
	ck(int(hp.stats["sight"]) == 6 and int(hp.stats["move"]) == 4, "鸟妖 视野6/移动4")
	ck(hp.initiative() == 7, "鸟妖先攻 14/2=7")
	ck(hp.move_allowance() == 4, "鸟妖步行移动 4")
	hp.tags.append("flying")
	ck(hp.move_allowance() == 6, "鸟妖飞行移动 6（when_self_tag）")
	hp.modifiers.append({"stat": "move", "op": "flat", "value": 1, "source": "equip:900:0"})
	ck(hp.move_allowance() == 7, "条件覆盖后修正差量照叠（6+1）")
	# 深水通行：普通人不可进、水生/飞行可进且成本 1；浅水 水生 1（普通人 2）
	var s6 = BattleState.new()
	s6._new_grassland(5, 5)
	s6.tiles[2][2] = {"terrain": "water", "variant": "deep"}
	s6.tiles[2][3] = {"terrain": "water", "variant": "shallow"}
	var walker = UnitFactory.make_unit(inf, "player", 1, 2)
	s6.units = [walker]
	ck(s6._move_cost_at(2, 2, walker) == -1, "深水：普通人不可进")
	ck(s6._move_cost_at(3, 2, walker) == 2, "浅水：普通人成本 2")
	var lz2 = UnitFactory.make_unit({"id": "lz", "name": "蜥兵", "race": "lizardmen"}, "player", 1, 1)
	s6.units.append(lz2)
	ck(s6._move_cost_at(2, 2, lz2) == 1 and s6._move_cost_at(3, 2, lz2) == 1, "水生：深/浅水成本恒 1")

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
