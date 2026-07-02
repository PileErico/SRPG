extends SceneTree
## M1b 回归：ItemInstances / 合成视图 / Unit.equipment 改 uid / 三个雷 / campaign 带词条往返。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_iteminstances.gd（退出码 0=PASS）

const Unit := preload("res://Unit.gd")
const UnitFactory := preload("res://UnitFactory.gd")
const ItemInstances := preload("res://ItemInstances.gd")
const ItemDB := preload("res://ItemDB.gd")
const WorldState := preload("res://WorldState.gd")
const SaveIO := preload("res://SaveIO.gd")

const SLOT := "_test_m1b"
var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _fresh_unit(nm: String) -> Object:
	var u = Unit.new(nm, "player", -1, -1)
	u.recompute_derived()
	return u

func _initialize() -> void:
	print("=== ItemInstances/装备实例化 测试开始 ===")
	WorldState.current = null
	ItemInstances.clear()

	# 1) create/view：模板合成 + uid/tpl 透传
	var uid1 := ItemInstances.create("long_sword")
	ck(uid1 > 0, "create 返回 uid")
	ck(ItemInstances.create("不存在的模板") == 0, "坏模板返回 0")
	var v1 = ItemInstances.view(uid1)
	ck(v1 != null and int(v1["uid"]) == uid1 and str(v1["tpl_id"]) == "long_sword", "view uid/tpl_id")
	ck((v1["mods"] as Array).size() == 2, "view 继承模板 2 条 mods")

	# 2) 雷①：view 是深拷，改视图不污染全局模板
	v1["name"] = "被篡改"
	(v1["mods"] as Array).append({"stat": "atk", "op": "flat", "value": 999})
	var tpl = ItemDB.get_item("long_sword")
	ck(str(tpl.get("name", "")) != "被篡改", "模板 name 未被污染")
	ck((tpl.get("mods", []) as Array).size() == 2, "模板 mods 未被污染")
	ck((ItemInstances.view(uid1)["mods"] as Array).size() == 2, "重取 view 干净")

	# 3) equip 模板便捷入口（兼容路径）：equipment 存 int uid、模板 mods 生效
	var u1 = _fresh_unit("甲")
	var base_atk: float = u1.effective_stat_f("atk")
	ck(u1.equip("long_sword"), "equip(模板id) 成功")
	ck(typeof(u1.equipment.get("main_hand")) == TYPE_INT and int(u1.equipment["main_hand"]) > 0, "equipment 存 int uid")
	ck(absf(u1.effective_stat_f("atk") - (base_atk + 5.0)) < 0.001, "模板 atk+5 生效")

	# 4) 雷③：模板 mod 与词条 mod 同 stat 同 op —— 都要生效（不被「同 source 去重取高」吃掉）
	var uid2 := ItemInstances.create("long_sword")
	ItemInstances.add_affix(uid2, {"name": "锋利", "mods": [{"stat": "atk", "op": "flat", "value": 3}]})
	var u2 = _fresh_unit("乙")
	var b2: float = u2.effective_stat_f("atk")
	ck(u2.equip_instance(uid2), "equip_instance 成功")
	ck(absf(u2.effective_stat_f("atk") - (b2 + 8.0)) < 0.001, "模板+5 与词条+3 都生效（=+8，去重雷已排）；实得 +%.1f" % (u2.effective_stat_f("atk") - b2))

	# 5) unequip：修正按前缀全摘、槽清空、实例不销毁
	u2.unequip("main_hand")
	ck(u2.equipment.is_empty(), "unequip 清槽")
	ck(absf(u2.effective_stat_f("atk") - b2) < 0.001, "unequip 后修正全摘")
	ck(ItemInstances.exists(uid2), "unequip 不销毁实例（词条保留）")
	ck((ItemInstances.view(uid2)["affixes"] as Array).size() == 1, "实例词条仍在")

	# 6) 雷②：双手武器按 uid 配对（占两槽同 uid、任一槽卸都连带清两槽）
	var u3 = _fresh_unit("丙")
	u3.tags.append("char_veiken")
	var b3: float = u3.effective_stat_f("atk")
	ck(u3.equip("spear_dragon_calamity"), "装双手武器")
	ck(int(u3.equipment.get("main_hand", 0)) == int(u3.equipment.get("off_hand", -1)), "双手两槽同 uid")
	u3.unequip("off_hand")
	ck(u3.equipment.is_empty(), "从副手卸→两槽连带清")
	ck(absf(u3.effective_stat_f("atk") - b3) < 0.001, "双手卸后修正全摘")

	# 7) 换装：同槽第二件顶掉第一件，旧实例存活
	var u4 = _fresh_unit("丁")
	ck(u4.equip("wood_kite_shield"), "装盾1")
	var old_uid := int(u4.equipment["off_hand"])
	ck(u4.equip("wood_kite_shield"), "装盾2（顶掉盾1）")
	var new_uid := int(u4.equipment["off_hand"])
	ck(new_uid != old_uid, "换装后是新实例")
	ck(ItemInstances.exists(old_uid), "被顶掉的旧实例存活（将来进背包）")
	var br: float = u4.effective_stat_f("block_rate")
	ck(absf(br - (_fresh_unit("对照").effective_stat_f("block_rate") + 15.0)) < 0.001, "只有一份盾 mods 生效")

	# 8) proto 层：uid → 模板 id 映射（定义层不带实例态）
	var u5 = _fresh_unit("戊")
	u5.equip("long_sword")
	u5.equip("breast_plate")
	var proto := UnitFactory.unit_to_proto(u5)
	var eq: Array = proto.get("equip", [])
	ck(eq.has("long_sword") and eq.has("breast_plate") and eq.size() == 2, "proto.equip=模板 id 各一条")

	# 9) campaign 带词条全链往返（存 → 换会话 → 读 → 激活 → 实例/词条/装配保真）+ 存档 GC
	ItemInstances.clear()   # 清临时域：档内与临时是两个独立 uid 域、数值可重合，先清避免同号干扰断言
	var ws = WorldState.new()
	WorldState.current = ws
	var u6 = UnitFactory.make_unit({"name": "队长", "four": {"STR": 8, "DEX": 6, "INT": 4, "STA": 7}}, "player", -1, -1)
	ws.add_to_roster(u6)
	var sword := ItemInstances.create("long_sword")
	ItemInstances.add_affix(sword, {"name": "锋利", "mods": [{"stat": "atk", "op": "flat", "value": 3}]})
	ck(u6.equip_instance(sword), "队长装词条剑")
	var orphan := ItemInstances.create("wood_kite_shield")   # 无人穿的孤儿——存档 GC 应丢弃
	ck(orphan > 0, "孤儿实例已造")
	var atk_before: float = u6.effective_stat_f("atk")
	u6.stats["HP"] = 5   # 带伤
	ck(SaveIO.save_campaign(ws, SLOT), "存档")
	# 模拟重启：脱离战役（库归属 ws，current 置空即切走，无需清库）
	WorldState.current = null
	var ld = SaveIO.load_campaign(SLOT)
	ck(ld != null and ld.roster.size() == 1, "读档 roster")
	# 无副作用：读档只构建、不激活——当前（无战役）域看不到档内实例
	ck(ItemInstances.view(sword) == null, "未激活前档内实例不可见（from_dict 无全局副作用）")
	if ld != null and ld.roster.size() == 1:
		WorldState.current = ld   # 激活＝换 current，库随之切换
		var r = ld.roster_by_uid(u6.uid)
		ck(r != null, "按 uid 找回队长")
		if r != null:
			ck(int(r.equipment.get("main_hand", 0)) == sword, "装备重挂到同一实例 uid")
			ck((ItemInstances.view(sword)["affixes"] as Array).size() == 1, "词条随档还原")
			ck(absf(r.effective_stat_f("atk") - atk_before) < 0.001, "含词条的有效攻击一致（要 %.1f 实得 %.1f）" % [atk_before, r.effective_stat_f("atk")])
			ck(int(r.stats["HP"]) == 5, "战损 HP 保留")
		ck(not ItemInstances.exists(orphan), "孤儿实例被存档 GC 丢弃（档只存 roster 可达）")
	SaveIO.delete_slot(SLOT)
	WorldState.current = null

	# 10) innate 占槽守卫：天生武器不可被顶（否则其烘焙修正泄漏）
	var u7 = _fresh_unit("狼人")
	u7.tags.append("char_desmond")
	ck(u7.equip("Desmond_Claw"), "装天生爪")
	var claw_uid := int(u7.equipment.get("main_hand", 0))
	var atk_claw: float = u7.effective_stat_f("atk")
	ck(not u7.equip("long_sword"), "长剑顶天生爪被拒")
	ck(int(u7.equipment.get("main_hand", 0)) == claw_uid, "爪仍在原槽")
	ck(absf(u7.effective_stat_f("atk") - atk_claw) < 0.001, "修正无泄漏/无重复")

	# 11) 收编迁移：沙盒（无战役）装备的单位入册 → 实例迁进档内库、修正 source 重写、数值不变
	WorldState.current = null
	var u8 = _fresh_unit("新兵")
	ck(u8.equip("long_sword"), "沙盒域装剑")
	var t_uid := int(u8.equipment["main_hand"])
	var atk_t: float = u8.effective_stat_f("atk")
	var ws2 = WorldState.new()
	WorldState.current = ws2
	ws2.add_to_roster(u8)
	var new_iuid := int(u8.equipment["main_hand"])
	ck(ws2.item_instances.has(new_iuid), "实例已迁入档内库")
	ck(ItemInstances.view(new_iuid) != null and str(ItemInstances.view(new_iuid)["tpl_id"]) == "long_sword", "迁移后视图可解析")
	ck(absf(u8.effective_stat_f("atk") - atk_t) < 0.001, "迁移后修正数值不变（source 重写成功）")
	WorldState.current = null
	ck(not ItemInstances.exists(t_uid), "临时库原实例已被取走")
	WorldState.current = null

	# 12) 读档健壮性：roster:null 不炸；计数器自愈（next_uid 被改小于存量 uid 的档）
	var bad = WorldState.from_dict({"roster": null})
	ck(bad != null and bad.roster.is_empty(), "roster:null 安全返回空册")
	var heal = WorldState.from_dict({"next_uid": 1,
		"item_instances": [{"uid": 5, "tpl_id": "long_sword"}],
		"roster": [{"uid": 3, "proto": {"name": "残卷"}, "hp": 1, "armor": 0, "equip_uids": {}}]})
	ck(heal.next_uid == 6, "计数器自愈到 max(uid)+1（实得 %d）" % heal.next_uid)

	# 13) slot 名净化：路径穿越被拒
	ck(not SaveIO.save_campaign(WorldState.new(), "../evil"), "save ../ 被拒")
	ck(SaveIO.load_campaign("..\\x") == null, "load ..\\ 被拒")
	ck(not SaveIO.delete_slot("a/b"), "delete 带分隔符被拒")

	WorldState.current = null

	if _fail == 0:
		print("=== 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
