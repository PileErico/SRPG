extends SceneTree
## WorldSim v1 回归：注册表 / 开局生成（幂等·uid）/ 存档往返 / budget 速度语义 / 商路到站
## / 敌对追击→engage→战斗上下文→战胜移除 / 冷静期 / 中立不追 / 摩擦战。不触碰玩家 auto 档。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_worldsim.gd（退出码 0=PASS）

const WorldState := preload("res://WorldState.gd")
const WorldSim := preload("res://WorldSim.gd")
const WorldUnitDB := preload("res://WorldUnitDB.gd")
const SaveIO := preload("res://SaveIO.gd")
const BattleIO := preload("res://BattleIO.gd")
const SandboxConfig := preload("res://SandboxConfig.gd")
const HexGrid := preload("res://HexGrid.gd")
const OverworldScript := preload("res://Overworld.gd")

const SLOT := "_test_wsim"
var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _mk(ws, type_id: String, col: int, row: int, home := "") -> Dictionary:
	var u := {"uid": ws.next_uid, "type": type_id, "faction": str(WorldUnitDB.type_def(type_id).get("faction", "")),
		"col": col, "row": row, "budget": 0.0, "target_loc": "", "wait_until": 0, "calm_until": 0, "home": home}
	ws.next_uid += 1
	ws.world_units.append(u)
	return u

func _initialize() -> void:
	print("=== WorldSim v1 测试开始 ===")

	# 1) 注册表
	for want in ["caravan", "patrol", "herd", "marauders"]:
		ck(WorldUnitDB.type_def(want) != null, "类型表含 %s" % want)
	ck(WorldUnitDB.label("caravan") == "商队", "label 中文")

	# 2) 开局生成：数量/home/uid 唯一 + 幂等
	var ws = WorldState.start_new()
	var ow = OverworldScript.new()
	ow._save_slot = SLOT
	ow._ensure_campaign()
	ow._load_map()
	WorldSim.ensure_spawned(ws, ow)
	var n0: int = ws.world_units.size()
	ck(n0 == 7, "生成 7 支（商队2+每城巡逻1+兽群2+游团2），实得 %d" % n0)
	var uids := {}
	for u in ws.world_units:
		uids[int(u["uid"])] = true
	ck(uids.size() == n0, "uid 全唯一")
	WorldSim.ensure_spawned(ws, ow)
	ck(ws.world_units.size() == n0, "重复调用幂等（flags 记账）")

	# 3) 存档往返 + next_uid 自愈
	ck(SaveIO.save_campaign(ws, SLOT), "save 成功")
	var ld = SaveIO.load_campaign(SLOT)
	ck(ld != null and ld.world_units.size() == n0, "world_units 往返")
	var mx := 0
	for u in ld.world_units:
		mx = maxi(mx, int(u["uid"]))
	ck(ld.next_uid > mx, "next_uid 覆盖 world_units 自愈")
	SaveIO.delete_slot(SLOT)

	# 4) budget 速度语义（受控单位：兽群 hpc=4）
	ws.world_units.clear()
	ws.party_col = 0
	ws.party_row = 0
	var herd := _mk(ws, "herd", 12, 5)
	WorldSim.tick(ws, 2, ow)   # 2h < 4h/格：攒着不动
	ck(_at(herd) == Vector2i(12, 5) and is_equal_approx(float(herd["budget"]), 2.0), "不足一格＝攒 budget 不动")
	WorldSim.tick(ws, 2, ow)   # 累计 4h：走一步（随机邻格、可通行）
	ck(HexGrid.distance(_at(herd), Vector2i(12, 5)) <= 1, "攒够一格走一步（≤1 格）")
	ck(ow._move_cost_at(_at(herd).x, _at(herd).y) >= 0, "落点可通行")

	# 5) 商路：定向逼近目标城/村，到站停靠 + caravan_arrive
	ws.world_units.clear()
	var car := _mk(ws, "caravan", 10, 8)
	car["target_loc"] = "city_astra"   # 城在 (8,8)，路上直线可达
	var arrived := false
	for i in 12:
		for e in WorldSim.tick(ws, 3, ow):   # 3h=商队一格
			if str(e.get("kind", "")) == "caravan_arrive":
				arrived = true
		if arrived:
			break
	ck(arrived, "商队到站（caravan_arrive）")
	ck(_at(car) == Vector2i(8, 8) and int(car["wait_until"]) > ws.clock_hours, "到站落位 + 停靠计时")

	# 6) 敌对追击 → engage + 冷静期；战胜 → 移除
	ws.world_units.clear()
	ws.party_col = 14
	ws.party_row = 8
	var mar := _mk(ws, "marauders", 17, 8, "lair_bandit")   # 距 3 ≤ sight 4；劫道者默认敌对
	var engaged := false
	for i in 6:
		for e in WorldSim.tick(ws, 2, ow):
			if str(e.get("kind", "")) == "engage_player":
				engaged = true
		if engaged:
			break
	ck(engaged, "敌对游团追上玩家（engage_player）")
	ck(int(mar["calm_until"]) > ws.clock_hours, "engage 即入冷静期")
	ck(not WorldSim.tick(ws, 2, ow).any(func(e): return str(e.get("kind", "")) == "engage_player"), "冷静期内不再 engage")
	# Overworld 表现层：engage → battle_setup 带 world_unit_uid（宿主统一入口 _advance_world）
	mar["calm_until"] = 0
	mar["col"] = 14
	mar["row"] = 9
	SandboxConfig.battle_setup = null
	ow._advance_world(2)
	ck(SandboxConfig.battle_setup != null and int((SandboxConfig.battle_setup.get("context", {}) as Dictionary).get("world_unit_uid", 0)) == int(mar["uid"]), "engage → battle_setup 带 world_unit_uid")
	ck(int((SandboxConfig.battle_setup.get("context", {}) as Dictionary).get("bounty", 0)) == 40, "engage context 带类型赏金（marauders=40）")
	# 战胜回写：单位覆灭 + 讨伐赏金入账（apply_result 返回入账额）
	var gold_before := int(ws.gold)
	var bounty: int = BattleIO.apply_result(ws, BattleIO.collect_result([], [], true, SandboxConfig.battle_setup["context"]))
	ck(ws.world_unit_by_uid(int(mar["uid"])) == null, "战胜 → 世界单位移除")
	ck(bounty == 40 and int(ws.gold) == gold_before + 40, "战胜 → 讨伐赏金 40 入账（apply_result 单点）")
	SandboxConfig.battle_setup = null

	# 7) 中立不追不打：商队/兽群贴脸玩家也无 engage
	ws.world_units.clear()
	_mk(ws, "caravan", 14, 9)
	_mk(ws, "herd", 15, 8)
	ck(not WorldSim.tick(ws, 6, ow).any(func(e): return str(e.get("kind", "")) == "engage_player"), "中立单位不 engage")

	# 8) 摩擦战：巡逻队 × 游团 邻格 → 一方覆灭 + skirmish 事件
	ws.world_units.clear()
	ws.party_col = 0
	ws.party_row = 15
	_mk(ws, "patrol", 9, 8, "city_astra")
	_mk(ws, "marauders", 10, 8, "lair_bandit")
	var skirmished := false
	for i in 8:
		for e in WorldSim.tick(ws, 2, ow):
			if str(e.get("kind", "")) == "skirmish":
				skirmished = true
		if skirmished:
			break
	ck(skirmished, "巡逻队×游团摩擦战发生")
	ck(ws.world_units.size() == 1, "摩擦战一方覆灭（余 %d）" % ws.world_units.size())

	ow.free()
	WorldState.current = null
	if _fail == 0:
		print("=== 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)

func _at(u: Dictionary) -> Vector2i:
	return Vector2i(int(u["col"]), int(u["row"]))
