extends SceneTree
## M6 回归：JobDB 注册表 / WorldState.camp_jobs+job_holder（在岗校验）/ 医生恢复速率钩子 / 指派序列化往返。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_campjobs.gd（退出码 0=PASS）

const WorldState := preload("res://WorldState.gd")
const WorldClock := preload("res://WorldClock.gd")
const JobDB := preload("res://JobDB.gd")
const SaveIO := preload("res://SaveIO.gd")
const UnitFactory := preload("res://UnitFactory.gd")

const SLOT := "_test_m6"
var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _initialize() -> void:
	print("=== M6 营地职务测试开始 ===")

	# 1) JobDB 注册表
	var ids := []
	for j in JobDB.all_jobs():
		ids.append(str(j["id"]))
	for want in ["medic", "cook", "smith", "guard", "scout"]:
		ck(ids.has(want), "注册表含 %s" % want)
	ck(JobDB.job_label("medic") == "医生", "job_label 中文")
	ck(str(JobDB.job("medic").get("effect_status", "")) == "in_use", "医生效果已接入标记")

	# 2) job_holder 在岗校验
	var ws = WorldState.start_new()
	ck(ws.roster.size() >= 1, "初始队伍非空")
	var u = ws.roster[0]
	ck(ws.job_holder("medic") == null, "空缺 → null")
	ws.camp_jobs["medic"] = u.uid
	ck(ws.job_holder("medic") == u, "指派后在岗")
	u.injured_until = ws.clock_hours + 10
	ck(ws.job_holder("medic") == null, "重伤休整中 → 不在岗（§1.11 无法参与任何活动）")
	u.injured_until = 0
	ws.camp_jobs["medic"] = 99999
	ck(ws.job_holder("medic") == null, "uid 不在册 → null")
	ws.camp_jobs["medic"] = u.uid

	# 3) 医生恢复速率（承载=改每小时速率 🔒）：无医生 +N / 有医生 +N×MEDIC_REGEN_MULT
	var mx: float = u.effective_stat("HP_max")
	u.stats["HP"] = mx - 10.0
	ws.camp_jobs["medic"] = 0   # 撤下
	WorldClock.advance(ws, 2)
	ck(is_equal_approx(float(u.stats["HP"]), mx - 10.0 + 2.0 * WorldClock.REGEN_HP_PER_HOUR), "无医生：基础速率")
	u.stats["HP"] = mx - 10.0
	ws.camp_jobs["medic"] = u.uid
	WorldClock.advance(ws, 2)
	var want: float = mx - 10.0 + 2.0 * WorldClock.REGEN_HP_PER_HOUR * WorldClock.MEDIC_REGEN_MULT
	ck(is_equal_approx(float(u.stats["HP"]), want), "医生在岗：速率 ×%s（要 %s 实得 %s）" % [WorldClock.MEDIC_REGEN_MULT, want, u.stats["HP"]])

	# 4) 指派序列化往返
	ws.camp_jobs["scout"] = u.uid
	ck(SaveIO.save_campaign(ws, SLOT), "save 成功")
	var ld = SaveIO.load_campaign(SLOT)
	ck(ld != null and int(ld.camp_jobs.get("medic", 0)) == u.uid and int(ld.camp_jobs.get("scout", 0)) == u.uid, "camp_jobs 往返（值 int 化）")
	if ld != null:
		ck(ld.job_holder("medic") != null, "读档后 job_holder 可用")
	SaveIO.delete_slot(SLOT)

	WorldState.current = null
	if _fail == 0:
		print("=== 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
