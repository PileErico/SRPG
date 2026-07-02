extends SceneTree
## M1a 回归：WorldState/SaveIO/uid/campaign 单位序列化 全链往返。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_worldstate.gd（退出码 0=PASS）

const WorldState := preload("res://WorldState.gd")
const SaveIO := preload("res://SaveIO.gd")
const UnitFactory := preload("res://UnitFactory.gd")

const SLOT := "_test_m1a"
var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _initialize() -> void:
	print("=== WorldState/SaveIO 往返测试开始 ===")

	# 1) 无战役时的临时 uid：单调递增
	WorldState.current = null
	var t1 := WorldState.mint_uid()
	var t2 := WorldState.mint_uid()
	ck(t2 == t1 + 1, "transient mint 递增")

	# 2) 建战役：从真实原型造两个单位入册（含装备/技能/特性的完整 proto）
	var protos := UnitFactory.all_prototypes()
	ck(not protos.is_empty(), "有内置原型可用")
	var ws = WorldState.new()
	WorldState.current = ws
	var u1 = UnitFactory.make_unit(protos[0], "player", -1, -1)
	var u2 = UnitFactory.make_unit(protos[protos.size() - 1], "ally", -1, -1)
	ws.add_to_roster(u1)
	ws.add_to_roster(u2)
	# 注：make_unit 装备原型武器会创建物品实例、也消耗共享计数器（unit/item 共用 🔒）——
	# 所以只断言「唯一 + 单调」，不硬编码具体值。
	ck(u1.uid > 0 and u2.uid > 0 and u1.uid != u2.uid, "入册补发 uid 唯一（实得 %d/%d）" % [u1.uid, u2.uid])
	ws.add_to_roster(u1)
	ck(ws.roster.size() == 2, "重复入册忽略")
	var before_mint: int = ws.next_uid
	var m := WorldState.mint_uid()
	ck(m == before_mint and ws.next_uid == before_mint + 1, "mint 走档内计数器且单调（实得 %d, next=%d）" % [m, ws.next_uid])

	# 3) 模拟战后状态：战损 + 养成 + 世界状态
	u1.stats["HP"] = maxi(1, int(u1.stats.get("HP", 10)) - 3)   # 带伤
	u1.exp = 42
	u1.exp_max = 120
	var hp_saved: int = u1.stats["HP"]
	ws.clock_hours = 37
	ws.ironman = true
	ws.flags["chapter"] = 2
	ws.flags["met_smith"] = true
	ws.reputation["empire"] = 10
	ws.reputation["lizard"] = -5

	# 4) 存 → 读 → 逐字段断言
	ck(SaveIO.save_campaign(ws, SLOT), "save_campaign 成功")
	var ld = SaveIO.load_campaign(SLOT)
	ck(ld != null, "load_campaign 非空")
	if ld != null:
		ck(ld.save_version == WorldState.SAVE_VERSION, "save_version")
		ck(ld.next_uid == ws.next_uid, "next_uid 续存（要 %d 实得 %d）" % [ws.next_uid, ld.next_uid])
		ck(ld.clock_hours == 37, "clock_hours")
		ck(ld.ironman == true, "ironman flag")
		ck(int(ld.flags.get("chapter", 0)) == 2 and bool(ld.flags.get("met_smith", false)), "flags")
		ck(int(ld.reputation.get("empire", 0)) == 10 and int(ld.reputation.get("lizard", 0)) == -5, "reputation")
		ck(ld.roster.size() == 2, "roster 数量")
		var r1 = ld.roster_by_uid(u1.uid)
		var r2 = ld.roster_by_uid(u2.uid)
		ck(r1 != null and r2 != null, "按 uid 找回两单位")
		if r1 != null:
			ck(r1.unit_name == u1.unit_name, "u1 名字")
			ck(r1.faction == "player", "u1 阵营（default_faction 往返）")
			ck(int(r1.stats["HP"]) == hp_saved, "u1 战损 HP 保留（要 %d 实得 %d）——绕开 init_vitals 注满" % [hp_saved, int(r1.stats["HP"])])
			ck(r1.level == u1.level and r1.exp == 42 and r1.exp_max == 120, "u1 level/exp/exp_max（含 exp_max 往返缺口修复）")
			ck(int(r1.stats["STR"]) == int(u1.stats["STR"]) and int(r1.stats["STA"]) == int(u1.stats["STA"]), "u1 四维")
			ck(r1.trait_id == u1.trait_id, "u1 特性")
			for sid in u1.skills:
				ck(r1.skill_level(sid) == u1.skill_level(sid), "u1 技能 %s 等级" % sid)
			for slot in u1.equipment:
				ck(r1.equipment.has(slot), "u1 装备槽 %s 在" % slot)
			ck(r1.col == -1 and r1.row == -1, "u1 待命位 col/row=-1")

	# 5) 槽位管理
	ck(SaveIO.list_slots().has(SLOT), "list_slots 含测试槽")
	ck(SaveIO.delete_slot(SLOT), "delete_slot")
	ck(not SaveIO.list_slots().has(SLOT), "删除后不在列表")
	ck(SaveIO.load_campaign(SLOT) == null, "读不存在槽返回 null")

	WorldState.current = null
	if _fail == 0:
		print("=== 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
