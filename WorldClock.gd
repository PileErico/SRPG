extends RefCounted
## 世界时钟（战外时间语义单一源；DB 范式：preload + static，无 class_name）。
## 时间铁律 🔒：时间＝WorldState.clock_hours 的单调小时计数（本质是计数、非钟表模拟）；
##            战斗不消耗世界时间（战场日夜冻结、夜进夜出）；只有大地图移动/扎营等战外活动推进（M4 接）。
## 职责：① advance(ws, hours)＝唯一推进入口——逐小时结算「每小时」节拍的调度表（跨多小时＝多次结算，不跳步漏算）
##      ② 小时→日夜映射 time_of_day()：当日小时经 EnvDB.time_for_hour 查 from_hour 区间（数据在 environment.json）
##      ③ 计数换算 hour_of_day / day_number / describe
## 调度表现状：恢复结算（数值占位，重伤细则待需求 §2.3）；M3 事件冷却、M6 职务速率、M7 据点刷新在 _tick_hour 扩展。
## 边界：不碰 WorldState.current——advance 收显式 ws 参数（谁持档谁传，同 WorldState「底层模块收显式参数」约定）。

const EnvDB := preload("res://EnvDB.gd")

const HOURS_PER_DAY := 24
const REGEN_HP_PER_HOUR := 1.0   # 占位：战外每小时自然恢复 HP（重伤/恢复细则＝需求 §2.3）
const MEDIC_REGEN_MULT := 2.0    # 占位：医生在岗的恢复倍率（承载=改每小时速率 🔒 §6.2；数值待 §2.2）

# 推进世界时间 n 小时（n<=0 / 无档＝no-op）。逐小时调度：恢复/冷却/刷新全按「每小时」节拍结算。
static func advance(ws, hours: int) -> void:
	if ws == null or hours <= 0:
		return
	for i in hours:
		ws.clock_hours += 1
		_tick_hour(ws)

# 一小时的调度表结算。M3 事件冷却 / M6 职务速率 / M7 据点刷新在此扩展。
static func _tick_hour(ws) -> void:
	_settle_recovery(ws)

# 恢复结算（占位）：roster 全员每小时回 REGEN_HP_PER_HOUR、不超上限；HP<=0（倒下）不自然恢复。
# 医生在岗（M6 职务框架首个消费端）＝速率 ×MEDIC_REGEN_MULT——职务加成一律走「改每小时速率」🔒。
static func _settle_recovery(ws) -> void:
	var rate := REGEN_HP_PER_HOUR * (MEDIC_REGEN_MULT if ws.job_holder("medic") != null else 1.0)
	for u in ws.roster:
		var mx: float = u.effective_stat("HP_max")
		var cur := float(u.stats.get("HP", mx))
		if cur > 0.0 and cur < mx:
			u.stats["HP"] = minf(cur + rate, mx)

# ============ 计数换算（纯函数，直接喂 clock_hours；不依赖档）============

static func hour_of_day(hours: int) -> int:
	return posmod(hours, HOURS_PER_DAY)

# 第几天（1-based：开局＝第 1 天）。注意 clock_hours=0 是 0 点＝夜——战役开局想在白天就把初始值设到 6~17。
static func day_number(hours: int) -> int:
	return floori(float(hours) / HOURS_PER_DAY) + 1

# 当前日夜 id（EnvDB times 的 from_hour 区间映射；喂 sight_mult/tint 等既有消费端，零改动）
static func time_of_day(hours: int) -> String:
	return EnvDB.time_for_hour(hour_of_day(hours))

# 「第 3 天 14:00·昼」——日志 / 大地图 UI 通用显示
static func describe(hours: int) -> String:
	return "第 %d 天 %02d:00·%s" % [day_number(hours), hour_of_day(hours), EnvDB.time_label(time_of_day(hours))]
