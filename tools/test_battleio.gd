extends SceneTree
## M5 回归：Checks 检定原语 / 死门（转门·扣条·±3 结算·铁人·permanent 透传）/ gain_exp / BattleIO（快照进·结果出·回写·kill_stats）。
## 死门用无 UI 的 Sandbox 实例直测核心函数（_log/UI 全 null 守卫）；不触碰玩家 "auto" 存档槽。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_battleio.gd（退出码 0=PASS）

const WorldState := preload("res://WorldState.gd")
const UnitFactory := preload("res://UnitFactory.gd")
const BattleIO := preload("res://BattleIO.gd")
const Checks := preload("res://Checks.gd")
const SaveIO := preload("res://SaveIO.gd")
const SandboxScript := preload("res://Sandbox.gd")

const SLOT := "_test_m5"
var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _initialize() -> void:
	print("=== M5 死门/BattleIO 测试开始 ===")
	var protos := UnitFactory.all_prototypes()
	ck(not protos.is_empty(), "有内置原型可用")

	# 1) Checks：结构 + 恒过/恒败边界（1d20 无法定桩，用极端 DC；🔒 属性重做：死门检定改 check_flat 求生）
	WorldState.current = null
	var cu = UnitFactory.make_unit(protos[0], "player", -1, -1)
	var r: Dictionary = Checks.check(cu, "body_fort", 1)
	ck(r.has("ok") and r.has("roll") and r.has("bonus") and r.has("total") and r.has("dc"), "check 返回结构齐")
	ck(int(r["roll"]) >= 1 and int(r["roll"]) <= 20, "roll 在 1~20")
	ck(bool(Checks.check_flat(5, -100)["ok"]), "check_flat DC=-100 恒过")
	ck(not bool(Checks.check_flat(5, 1000)["ok"]), "check_flat DC=1000 恒败")

	# 2) gain_exp：升级循环（🔒 属性重做：等级零数值——属性/技能点已废除，升级只推解锁节拍）
	var gu = UnitFactory.make_unit(protos[0], "player", -1, -1)
	gu.exp = 0
	gu.exp_max = 100
	var base_lv: int = gu.level
	var ups: int = gu.gain_exp(250)   # 100→升1（exp_max→120）→120→升2（剩30）
	ck(ups == 2 and gu.level == base_lv + 2, "250 exp 升 2 级（实得 %d 级）" % ups)
	ck(gu.exp == 30, "余量经验 30（实得 %d）" % gu.exp)

	# 3) 死门（无 UI Sandbox 实例；WorldState.current=null＝非铁人路径）
	var sb = SandboxScript.new()
	sb._new_grassland(5, 5)
	var a = UnitFactory.make_unit(protos[0], "player", 0, 0)    # 我方：天然死门资格
	var b = UnitFactory.make_unit(protos[0], "enemy", 1, 0)     # 常规敌兵：无资格
	var c = UnitFactory.make_unit(protos[0], "enemy", 2, 0)     # 敌方精锐：elite tag 资格
	c.tags.append("elite")
	var d = UnitFactory.make_unit(protos[0], "enemy", 3, 0)     # 陪站：防 foes==0 触发 _end_battle
	var e = UnitFactory.make_unit(protos[0], "player", 4, 0)    # 陪站：防 friends==0
	a.proto_id = "proto_a"
	b.proto_id = "proto_b"
	b.uid = 0
	sb.units = [a, b, c, d, e]
	var eva_before: float = a.effective_stat("eva")
	a.stats["HP"] = 0
	b.stats["HP"] = 0
	b.last_hit_by = a
	a.uid = 77
	sb._handle_deaths()
	ck(a.tags.has("deaths_door") and int(a.stats["HP"]) == 0 and a.door_gauge == 0, "我方 HP0 → 转入死门（不移除）")
	ck(a in sb.units, "死门单位仍占格在场")
	ck(not (b in sb.units), "常规敌兵 HP0 → 原路径即死移除")
	ck(sb._battle_kills.size() == 1 and str(sb._battle_kills[0]["proto_id"]) == "proto_b" and int(sb._battle_kills[0]["by_uid"]) == 77, "击杀记录 proto_id+归属")
	ck(a.effective_stat("eva") < eva_before, "死门挂上闪避减半修正（eva %.1f → %.1f）" % [eva_before, a.effective_stat("eva")])
	var has_perm := false
	for ef in a.effects:
		if str(ef.get("name", "")) == "死门" and bool(ef.get("permanent", false)):
			has_perm = true
	ck(has_perm, "死门 effect permanent=true（透传修复生效）")
	# 3b) elite 敌人也有死门
	c.stats["HP"] = 0
	sb._handle_deaths()
	ck(c.tags.has("deaths_door"), "elite 敌人 HP0 → 死门")
	# 3c) 检定：gauge ±1、次数递增
	var g0: int = a.door_gauge
	var n0: int = a.door_checks
	sb._door_turn_check(a)
	ck(absi(a.door_gauge - g0) == 1 and a.door_checks == n0 + 1, "检定后条 ±1、次数 +1")
	# 3d) −3 倒下（非铁人＝重伤离场）
	a.door_gauge = -3
	sb._door_settle(a)
	ck(a.tags.has("injured"), "−3 非铁人挂 injured")
	sb._handle_deaths()
	ck(not (a in sb.units), "−3 死门单位经统一收尸离场")
	ck(sb._battle_kills.size() == 2, "离场也进击杀记录（死门倒下）")
	# 3e) +3 爬回
	c.door_gauge = 3
	sb._door_settle(c)
	ck(not c.tags.has("deaths_door") and int(c.stats["HP"]) == 1, "+3 爬回：清门态、HP 保底 1")
	var has_injury_debuff := false
	for ef in c.effects:
		if str(ef.get("name", "")) == "重伤" and bool(ef.get("permanent", false)):
			has_injury_debuff = true
	ck(has_injury_debuff, "+3 挂「重伤」permanent debuff")
	ck(is_equal_approx(c.effective_stat("eva"), UnitFactory.make_unit(protos[0], "enemy", 0, 0).effective_stat("eva")), "爬回后死门修正已摘（eva 复原）")
	# 3f) 铁人＝真死标记
	var iws = WorldState.new()
	iws.ironman = true
	WorldState.current = iws
	var f = UnitFactory.make_unit(protos[0], "player", 0, 1)
	sb.units.append(f)
	f.stats["HP"] = 0
	sb._handle_deaths()
	f.door_gauge = -3
	sb._door_settle(f)
	ck(f.tags.has("dead") and not f.tags.has("injured"), "铁人 −3 挂 dead（真死）")
	WorldState.current = null
	sb.free()

	# 4) BattleIO：快照进 / 结果出 / 回写
	var ws = WorldState.start_new()
	ck(ws.roster.size() >= 1, "新战役有初始队伍（player 原型）")
	var src = ws.roster[0]
	var setup := BattleIO.make_setup("res://maps/sandbox.json", [src.uid])
	ck(setup.has("provisions"), "BattleSetup 带 provisions 挂点（烹饪铺垫）")
	var copies := BattleIO.spawn_battle_units(ws, setup)
	ck(copies.size() == 1 and copies[0] != src and copies[0].uid == src.uid, "快照副本：对象独立、uid 相同")
	copies[0].stats["HP"] = 3
	ck(int(src.stats["HP"]) != 3, "改副本 HP 不影响 roster 原件（双所有权根治）")
	# 收集：副本重伤离场（HP0+injured）+ 击杀 2 个敌兵
	copies[0].tags.append("injured")
	copies[0].stats["HP"] = 0
	var kills := [
		{"proto_id": "bandit", "victim_uid": 0, "faction": "enemy", "by_uid": src.uid},
		{"proto_id": "bandit", "victim_uid": 0, "faction": "enemy", "by_uid": src.uid},
		{"proto_id": "militia", "victim_uid": 5, "faction": "player", "by_uid": 0},   # 我方阵亡：不进 kill_stats
	]
	var result := BattleIO.collect_result(copies, kills, true)
	ck(result["units"].size() == 1, "结果含参战 campaign 单位")
	var entry: Dictionary = result["units"][0]
	ck(bool(entry["injured"]) and int(entry["exp"]) == 2 * BattleIO.EXP_PER_KILL + BattleIO.EXP_PARTICIPATION, "经验＝2 杀 + 参战奖励（实得 %d）" % int(entry["exp"]))
	var hp_before: int = int(src.stats["HP"])
	var exp_before: int = src.exp
	BattleIO.apply_result(ws, result)
	ck(int(src.stats["HP"]) == 1, "重伤离场者回写 HP 保底 1（原 %d）" % hp_before)
	ck(src.injured_until == ws.clock_hours + BattleIO.INJURY_HOURS, "injured_until＝时钟+%d" % BattleIO.INJURY_HOURS)
	ck(not src.tags.has("injured"), "injured tag 转持久字段后清掉")
	ck(src.exp != exp_before or src.level > 1, "经验已入账")
	ck(int(ws.kill_stats.get("bandit", 0)) == 2, "kill_stats 按敌方原型累计（情报输入源）")
	ck(not ws.kill_stats.has("militia"), "我方阵亡不进 kill_stats")
	# 真死：移出 roster
	var before_n: int = ws.roster.size()
	BattleIO.apply_result(ws, {"win": false, "units": [{"uid": src.uid, "dead": true}], "kills": []})
	ck(ws.roster.size() == before_n - 1 and ws.roster_by_uid(src.uid) == null, "真死从 roster 移除")
	# 5) kill_stats / injured_until / 技艺熟练度 存档往返（🔒 属性重做：养成点已废除，成长=技艺）
	var survivor = ws.roster[0] if ws.roster.size() > 0 else null
	if survivor != null:
		survivor.injured_until = 99
		survivor.prof_xp["wp_sword"] = 120   # 熟练度随 campaign（proto.profs）往返
	ck(SaveIO.save_campaign(ws, SLOT), "save 成功")
	var ld = SaveIO.load_campaign(SLOT)
	ck(ld != null and int(ld.kill_stats.get("bandit", 0)) == 2, "kill_stats 往返")
	if survivor != null and ld != null:
		var lu = ld.roster_by_uid(survivor.uid)
		ck(lu != null and lu.injured_until == 99, "injured_until 往返")
		ck(lu != null and int(lu.prof_xp.get("wp_sword", 0)) == 120, "技艺熟练度往返")
		ck(lu.proto_id == survivor.proto_id, "proto_id 往返")
	SaveIO.delete_slot(SLOT)

	WorldState.current = null
	if _fail == 0:
		print("=== 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
