extends SceneTree
## 装备穿卸/背包（2026-07-12 用户实装令）回归：
##  · unequip_to_bag：卸下进包 / 拳脚回位 / innate 拒 / 包满拒
##  · equip_from_bag：从包装备 / 被顶旧件落包（_displace_slot「将来进背包」兑现）/ 悬空引用自清
##  · transfer_hand：主→副（拳脚回主）/ 副→主（顶拳脚收回）/ 双件互换 / 盾进主手资格拒
##  · 序列化：campaign bag_uids 往返 / 战斗快照 bag 往返（护栏#3 白名单）/ proto bag 模板 / remap 含 bag
## 战斗内 1 AP 费用闸在宿主（Sandbox._equip_gate），模型层不涉费——此处只测模型与序列化。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_bag_equip.gd（退出码 0=PASS）

const Unit := preload("res://Unit.gd")
const UnitFactory := preload("res://UnitFactory.gd")
const ItemInstances := preload("res://ItemInstances.gd")

var _fail := 0
func ck(c: bool, m: String) -> void:
	if not c:
		_fail += 1
		push_error("[FAIL] " + m)

func mk():
	return UnitFactory.make_unit({"name": "试兵", "race": "human"}, "player", 0, 0)

func _initialize() -> void:
	print("=== 装备穿卸/背包 测试开始 ===")
	ItemInstances.clear()

	# 1) 卸下进包 + 拳脚回位 + innate 拒
	var u = mk()
	ck(u.equip("long_sword"), "装长剑")
	var sword := int(u.equipment["main_hand"])
	ck(u.unequip_to_bag("main_hand"), "卸下主手进包")
	ck(u.bag.has(sword), "长剑在背包")
	var fist = ItemInstances.view(int(u.equipment.get("main_hand", 0)))
	ck(fist != null and bool(fist.get("natural", false)), "拳脚自动回位（🔒 §10.4）")
	ck(not u.unequip_to_bag("main_hand"), "拳脚（innate）不可卸")

	# 2) 从包装备 + 被顶旧件落包
	ck(u.equip("rusty_dagger"), "装匕首（顶拳脚＝销毁不入包）")
	var dagger := int(u.equipment["main_hand"])
	ck(not u.bag.has(dagger), "匕首不在包（在手上）")
	ck(u.equip_from_bag(sword), "从背包装长剑")
	ck(int(u.equipment["main_hand"]) == sword, "长剑上主手")
	ck(u.bag.has(dagger) and not u.bag.has(sword), "被顶匕首落包、长剑离包")

	# 3) 换手：主→副（拳脚回主）→ 副→主（顶拳脚收回）
	ck(u.transfer_hand("main_hand", "off_hand"), "长剑主→副")
	ck(int(u.equipment.get("off_hand", 0)) == sword, "长剑在副手")
	var f2 = ItemInstances.view(int(u.equipment.get("main_hand", 0)))
	ck(f2 != null and bool(f2.get("natural", false)), "主手腾空 → 拳脚回位")
	ck(u.transfer_hand("off_hand", "main_hand"), "长剑副→主（顶拳脚）")
	ck(int(u.equipment.get("main_hand", 0)) == sword and not u.equipment.has("off_hand"), "回主手、副手空、拳脚收回销毁")

	# 4) 双件互换 + 盾资格拒
	ck(u.equip_from_bag(dagger, "off_hand"), "匕首从包装副手")
	ck(u.transfer_hand("main_hand", "off_hand"), "剑↔匕首互换")
	ck(int(u.equipment.get("main_hand", 0)) == dagger and int(u.equipment.get("off_hand", 0)) == sword, "互换成立")
	var u2 = mk()
	ck(u2.equip("wood_kite_shield"), "装盾（副手）")
	ck(not u2.transfer_hand("off_hand", "main_hand"), "盾进主手 → 槽位资格拒（EquipSlots）")

	# 5) 包满拒（模型层护栏；UI 侧菜单灰显/拖放拒同口）
	var u3 = mk()
	u3.equip("long_sword")
	for i in Unit.BAG_CAP:
		u3.bag.append(ItemInstances.create("rusty_dagger"))
	ck(not u3.unequip_to_bag("main_hand"), "包满 → 卸下拒")
	ck(not u3.equip_from_bag(0), "非包内 iuid → 拒")

	# 6) 序列化：campaign / 战斗快照 / proto / remap
	var entry: Dictionary = UnitFactory.unit_to_campaign(u)
	ck((entry.get("bag_uids", []) as Array) == u.bag, "campaign 出包含 bag_uids")
	var back = UnitFactory.unit_from_campaign(entry)
	ck(back.bag == u.bag, "campaign 往返 bag 保真（实例引用）")
	var snap: Dictionary = UnitFactory.unit_to_battle_snapshot(u)
	var bu = UnitFactory.unit_from_battle_snapshot(snap)
	ck(bu.bag == u.bag, "★ 战斗快照 bag 往返（护栏#3 白名单）")
	var old = UnitFactory.unit_from_battle_snapshot({"uid": 1})
	ck(typeof(old.bag) == TYPE_ARRAY and old.bag.is_empty(), "旧快照无 bag 键 → 空包安全")
	var proto: Dictionary = UnitFactory.unit_to_proto(u)
	ck((proto.get("bag", []) as Array).size() == u.bag.size(), "proto bag 模板 id 数量一致")
	var u4 = mk()
	u4.bag = [111]
	u4.remap_equip_uid(111, 222)
	ck(int(u4.bag[0]) == 222, "remap_equip_uid 含 bag 条目重写")

	ItemInstances.clear()
	if _fail == 0:
		print("=== 全 PASS ===")
	else:
		print("=== 失败 %d 项 ===" % _fail)
	quit(_fail)
