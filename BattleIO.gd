extends RefCounted
## 战斗进出契约（BattleIO，M5；DB 范式：preload + static，无 class_name）——campaign ↔ 战斗场景的唯一数据通道。
## **快照进 / 结果出 🔒**：战斗操作 roster 的序列化副本，campaign 只被 apply_result 显式回写——
## 根治「双所有权」（沙盒 exit_battle 的 init_vitals 回满只影响副本，campaign 战损不再被抹）。
## BattleSetup＝纯数据可序列化：将来战前选人 UI / 可保存预设队伍 / 食物 provisions 都长在它上面
## （铺垫见 docs/情报与烹饪系统.md §3.1；M5 只留 provisions 键位、不消费）。
## 经验/重伤数值全部占位（细则待需求 §2.3 与数值层）。

const WorldState := preload("res://WorldState.gd")
const UnitFactory := preload("res://UnitFactory.gd")

const EXP_PER_KILL := 30       # 占位：击杀经验（归属=最后命中者）
const EXP_PARTICIPATION := 10  # 占位：参战奖励经验（幸存即得，需求 §1.9「参战者结算时也获奖励经验」）
const INJURY_HOURS := 48       # 占位：重伤休整时长（injured_until = 战后时钟 + 此值；量级待 §2.3）

# ============ 快照进 ============

# 出战配置（纯数据，可入档/可存为预设队伍）：unit_uids=出战名单（ws.roster 的 uid）；
# map_path=战斗地图；provisions=战前食物选用（烹饪系统留位，暂不消费）；
# context=战斗来由（如 {location_id}——据点讨伐；Sandbox 原样透传、随 result 回到 apply_result 落账，M7）。
static func make_setup(map_path: String, unit_uids: Array, provisions: Array = [], context: Dictionary = {}) -> Dictionary:
	return {"map_path": map_path, "unit_uids": unit_uids.duplicate(), "provisions": provisions.duplicate(), "context": context.duplicate(true)}

# 按 setup 从 campaign 造战斗副本单位（campaign 序列化往返＝深快照：属性/装备引用独立于 roster 原件；
# 装备实例本体仍共享档内库——将来耐久消耗直写实例即天然同步）。
static func spawn_battle_units(ws, setup: Dictionary) -> Array:
	var out := []
	for uid in setup.get("unit_uids", []):
		var src = ws.roster_by_uid(int(uid))
		if src == null:
			push_warning("BattleIO：setup 引用的 uid=%d 不在 roster，跳过" % int(uid))
			continue
		out.append(UnitFactory.unit_from_campaign(UnitFactory.unit_to_campaign(src)))
	return out

# ============ 结果出 ============

# 从战斗现场收集 BattleResult（在 _end_battle 时调、**必须早于 exit_battle 的 init_vitals 回满**）。
# roster=参战副本全员（含已离场的重伤/阵亡者——它们只从 units 移除、仍在 roster）；kills=Sandbox._battle_kills；
# context=setup 透传的战斗来由（嵌进 result，apply_result 按它落账——如据点肃清）。
static func collect_result(roster: Array, kills: Array, win: bool, context: Dictionary = {}) -> Dictionary:
	var exp_by_uid := {}   # 击杀经验归属（by_uid=0 的沙盒临时单位击杀不计）
	for k in kills:
		var by := int(k.get("by_uid", 0))
		if by > 0:
			exp_by_uid[by] = int(exp_by_uid.get(by, 0)) + EXP_PER_KILL
	var entries := []
	for u in roster:
		if int(u.uid) <= 0:
			continue   # 非 campaign 单位（沙盒手捏）不进结果
		entries.append({
			"uid": u.uid,
			"hp": int(u.stats.get("HP", 0)),
			"dead": u.tags.has("dead"),         # 铁人死门 −3：真死
			"injured": u.tags.has("injured"),   # 死门 −3 重伤离场 / +3 爬回：战后休整
			"exp": int(exp_by_uid.get(u.uid, 0)) + EXP_PARTICIPATION,
		})
	var kills_out := []
	for k in kills:
		kills_out.append({"proto_id": str(k.get("proto_id", "")), "faction": str(k.get("faction", ""))})
	return {"win": win, "units": entries, "kills": kills_out, "context": context.duplicate(true)}

# 战后回写 campaign（结果出的唯一落点）：HP/经验/重伤/真死 → roster；击杀统计 → ws.kill_stats（情报解锁输入源）。
static func apply_result(ws, result: Dictionary) -> void:
	if ws == null:
		return
	for e in result.get("units", []):
		var u = ws.roster_by_uid(int(e.get("uid", 0)))
		if u == null:
			continue
		if bool(e.get("dead", false)):
			ws.roster.erase(u)   # 真死（铁人）：移出花名册；遗留装备实例=GC 不可达即弃（回收进仓库待库存系统）
			continue
		# 战损回写：存活者至少 1 HP（重伤离场者 HP 0 → 拖回来吊着一口气）
		u.stats["HP"] = clampi(maxi(int(e.get("hp", 1)), 1), 1, int(u.effective_stat("HP_max")))
		if bool(e.get("injured", false)):
			u.injured_until = ws.clock_hours + INJURY_HOURS
			u.tags.erase("injured")   # 战斗标记转持久字段后清掉（tag 只活战斗内）
		var lv := int(u.gain_exp(int(e.get("exp", 0))))
		if lv > 0:
			pass   # 升级细节（属性/技能点分配 UI）后置；点数已在 gain_exp 里入账
	# 击杀统计累计（按敌方原型；情报系统「战后按击杀解锁」的输入源，见 docs/情报与烹饪系统.md）
	for k in result.get("kills", []):
		var pid := str(k.get("proto_id", ""))
		if pid != "" and str(k.get("faction", "")) in ["enemy", "neutral"]:
			ws.kill_stats[pid] = int(ws.kill_stats.get(pid, 0)) + 1
	# 战斗来由落账：据点讨伐获胜 → 肃清计时（M7）；动态单位交战获胜 → 该单位覆灭（WorldSim v1）
	var ctx = result.get("context", {})
	if bool(result.get("win", false)) and typeof(ctx) == TYPE_DICTIONARY:
		ws.mark_location_cleared(str(ctx.get("location_id", "")))
		ws.remove_world_unit(int(ctx.get("world_unit_uid", 0)))
