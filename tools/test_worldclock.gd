extends SceneTree
## M2 回归：WorldClock 时钟本体（推进/换算/日夜映射）+ 调度表恢复结算 + 存档往返。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_worldclock.gd（退出码 0=PASS）

const WorldState := preload("res://WorldState.gd")
const WorldClock := preload("res://WorldClock.gd")
const EnvDB := preload("res://EnvDB.gd")
const SaveIO := preload("res://SaveIO.gd")
const UnitFactory := preload("res://UnitFactory.gd")

const SLOT := "_test_m2"
var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _initialize() -> void:
	print("=== WorldClock 测试开始 ===")

	# 1) 小时 → 日夜映射（environment.json：day from 6 / night from 18，0~5 环回夜）
	for h in [0, 3, 5]:
		ck(EnvDB.time_for_hour(h) == "night", "%d 点＝夜（跨午夜环回）" % h)
	for h in [6, 12, 17]:
		ck(EnvDB.time_for_hour(h) == "day", "%d 点＝昼" % h)
	for h in [18, 23]:
		ck(EnvDB.time_for_hour(h) == "night", "%d 点＝夜" % h)

	# 2) 计数换算（纯函数，不依赖档）
	ck(WorldClock.hour_of_day(0) == 0 and WorldClock.day_number(0) == 1, "开局＝第 1 天 0 点")
	ck(WorldClock.hour_of_day(37) == 13 and WorldClock.day_number(37) == 2, "37h＝第 2 天 13 点")
	ck(WorldClock.time_of_day(37) == "day", "37h＝昼")
	ck(WorldClock.hour_of_day(48) == 0 and WorldClock.day_number(48) == 3, "48h＝第 3 天 0 点")
	ck(WorldClock.time_of_day(48) == "night", "48h＝夜")
	var desc := WorldClock.describe(37)
	ck(desc.contains("2") and desc.contains("13"), "describe 含天数与时辰（实得「%s」）" % desc)

	# 3) advance：推进 + 边界（n<=0 / null 档均 no-op、不炸）
	var ws = WorldState.new()
	WorldState.current = ws
	WorldClock.advance(ws, 5)
	ck(ws.clock_hours == 5, "advance(5) → clock=5（实得 %d）" % ws.clock_hours)
	WorldClock.advance(ws, 0)
	WorldClock.advance(ws, -3)
	ck(ws.clock_hours == 5, "advance(0/负) 不动时钟")
	WorldClock.advance(null, 4)   # 不应崩

	# 4) 调度表·恢复结算（占位速率 REGEN_HP_PER_HOUR）：带伤回血 / 上限 clamp / 倒下(HP<=0)不恢复
	var protos := UnitFactory.all_prototypes()
	ck(not protos.is_empty(), "有内置原型可用")
	var u = UnitFactory.make_unit(protos[0], "player", -1, -1)
	ws.add_to_roster(u)
	var mx: float = u.effective_stat("HP_max")
	u.stats["HP"] = mx - 5.0
	WorldClock.advance(ws, 3)
	var want := mx - 5.0 + 3.0 * WorldClock.REGEN_HP_PER_HOUR
	ck(is_equal_approx(float(u.stats["HP"]), want), "带伤 3h 回 3×速率（要 %s 实得 %s）" % [want, u.stats["HP"]])
	WorldClock.advance(ws, 9999)
	ck(is_equal_approx(float(u.stats["HP"]), mx), "回满后 clamp 上限（实得 %s / max %s）" % [u.stats["HP"], mx])
	u.stats["HP"] = 0.0
	WorldClock.advance(ws, 10)
	ck(float(u.stats["HP"]) <= 0.0, "倒下(HP<=0)不自然恢复（细则待 M5）")

	# 5) 时钟随档往返（clock_hours 已在 M1 序列化，这里验推进后的值经 SaveIO 存活）
	u.stats["HP"] = mx   # 回满免噪声
	var saved_clock: int = ws.clock_hours
	ck(SaveIO.save_campaign(ws, SLOT), "save_campaign 成功")
	var ld = SaveIO.load_campaign(SLOT)
	ck(ld != null and ld.clock_hours == saved_clock, "clock_hours 往返（要 %d）" % saved_clock)
	if ld != null:
		ck(WorldClock.time_of_day(ld.clock_hours) == WorldClock.time_of_day(saved_clock), "读档后日夜推导一致")
	SaveIO.delete_slot(SLOT)

	WorldState.current = null
	if _fail == 0:
		print("=== 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
