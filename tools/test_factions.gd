extends SceneTree
## M9 回归：FactionDB 注册表/默认声望/敌对阈值/钳制写口 / 对话 rep 收敛 / 敌对遭伏伪触发器（chance·冷却）
## / EventEngine add_rep·set_flag 动作 / 声望存档往返。不触碰玩家 auto 档。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_factions.gd（退出码 0=PASS）

const FactionDB := preload("res://FactionDB.gd")
const WorldState := preload("res://WorldState.gd")
const SaveIO := preload("res://SaveIO.gd")
const EventEngine := preload("res://EventEngine.gd")
const DialogueUI := preload("res://DialogueUI.gd")
const OverworldScript := preload("res://Overworld.gd")
const SandboxConfig := preload("res://SandboxConfig.gd")

const SLOT := "_test_m9"
var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _initialize() -> void:
	print("=== M9 派系声望测试开始 ===")

	# 1) 注册表
	for want in ["empire", "lizardmen", "bandits"]:
		ck(FactionDB.faction(want) != null, "派系表含 %s" % want)
	ck(FactionDB.label("empire") == "帝国", "label 中文")
	ck(FactionDB.faction("no_such") == null and FactionDB.label("no_such") == "no_such", "未登记派系兜底")

	# 2) 默认声望 + 敌对阈值（数据：bandits start_rep=-50 < hostile_below=-20）
	var ws = WorldState.start_new()
	ck(FactionDB.rep_of(ws, "empire") == 0, "帝国默认 0")
	ck(FactionDB.rep_of(ws, "bandits") == -50, "劫道者默认 -50（未记录走 start_rep）")
	ck(FactionDB.hostile(ws, "bandits") and not FactionDB.hostile(ws, "empire"), "初始敌对：仅劫道者")
	ck(not FactionDB.hostile(ws, "no_such"), "未登记派系永不敌对")

	# 3) add_rep：写口 + 钳制 + 敌对翻转
	FactionDB.add_rep(ws, "empire", -30)
	ck(FactionDB.rep_of(ws, "empire") == -30 and FactionDB.hostile(ws, "empire"), "帝国 -30 → 敌对")
	FactionDB.add_rep(ws, "empire", 300)
	ck(FactionDB.rep_of(ws, "empire") == 100, "上限钳 100")
	FactionDB.add_rep(ws, "empire", -999)
	ck(FactionDB.rep_of(ws, "empire") == -100, "下限钳 -100")
	FactionDB.add_rep(ws, "wildlings", 5)
	ck(FactionDB.rep_of(ws, "wildlings") == 5, "未登记派系可记数（开放键）")
	ws.reputation.erase("empire")

	# 4) 对话 rep 收敛到 FactionDB 写口（dlg_elder_astra 选项0＝empire +5）
	var ui = DialogueUI.new()
	ui.start("dlg_elder_astra", ws)
	ui.advance()
	ui.choose(0)
	ck(FactionDB.rep_of(ws, "empire") == 5, "对话选项经 FactionDB 写口（+5）")
	ui.free()
	ws.reputation.erase("empire")

	# 5) 敌对遭伏伪触发器：仅敌对派系生成；chance/冷却走 EventEngine 世界层闸门
	var ow = OverworldScript.new()
	ow._save_slot = SLOT
	ow._ensure_campaign()
	var trigs: Array = ow._hostile_ambush_triggers()
	ck(trigs.size() == 1 and str(trigs[0]["id"]) == "faction_ambush_bandits", "仅敌对派系生成伪触发器")
	FactionDB.add_rep(ws, "empire", -30)
	ck(ow._hostile_ambush_triggers().size() == 2, "帝国转敌对 → 两条")
	ws.reputation.erase("empire")
	# chance 临时改 100（测定性；测完还原）
	var bdef = FactionDB.faction("bandits")
	var bak_chance = bdef["ambush"]["chance"]
	bdef["ambush"]["chance"] = 100
	SandboxConfig.battle_setup = null
	EventEngine.check_enter_tile(ow._hostile_ambush_triggers(), Vector2i(9, 8), "player", ws.event_fired, ow, ws)
	ck(SandboxConfig.battle_setup != null, "敌对遭伏 → 进战斗（battle_setup 写入）")
	SandboxConfig.battle_setup = null
	EventEngine.check_enter_tile(ow._hostile_ambush_triggers(), Vector2i(10, 8), "player", ws.event_fired, ow, ws)
	ck(SandboxConfig.battle_setup == null, "冷却期内不再触发")
	ck(int(ws.event_cooldown_until.get("faction_ambush_bandits", 0)) > ws.clock_hours, "冷却随档记账（tid 稳定）")
	bdef["ambush"]["chance"] = bak_chance
	ow.free()

	# 6) EventEngine 动作：add_rep / set_flag 注册 + 转发 + bool 解析
	ck(not EventEngine.action_def("add_rep").is_empty() and not EventEngine.action_def("set_flag").is_empty(), "动作注册表含 add_rep/set_flag")
	var ow2 = OverworldScript.new()
	EventEngine.execute_action({"action": "add_rep", "faction_id": "lizardmen", "delta": -25}, ow2)
	ck(FactionDB.rep_of(ws, "lizardmen") == -25 and FactionDB.hostile(ws, "lizardmen"), "add_rep 动作落账并敌对")
	EventEngine.execute_action({"action": "set_flag", "key": "helped_lizard", "value": "true"}, ow2)
	ck(ws.flags.get("helped_lizard") == true, "set_flag 动作：\"true\" 解析为 bool")
	EventEngine.execute_action({"action": "set_flag", "key": "route", "value": "north"}, ow2)
	ck(str(ws.flags.get("route")) == "north", "set_flag 动作：文本原样存")
	ow2.free()

	# 7) 声望存档往返
	ck(SaveIO.save_campaign(ws, SLOT), "save 成功")
	var ld = SaveIO.load_campaign(SLOT)
	ck(ld != null and FactionDB.rep_of(ld, "lizardmen") == -25, "声望往返")
	ck(FactionDB.rep_of(ld, "bandits") == -50, "读档后未记录派系仍走默认")
	SaveIO.delete_slot(SLOT)

	WorldState.current = null
	if _fail == 0:
		print("=== 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
