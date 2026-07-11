extends SceneTree
## M4 回归：map_type schema / TerrainDB.move_cost 单一实现 / WorldState party 往返 / Overworld 寻路与耗时 /
## 伪即时行军（_tick_time 直调模拟帧：插值/整点推钟/自动暂停；纯逻辑，不进树）。
## 注意：不触碰 "auto" 存档槽（那是玩家真档）；本测试用独立槽并清理。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_overworld.gd（退出码 0=PASS）

const MapIO := preload("res://MapIO.gd")
const TerrainDB := preload("res://TerrainDB.gd")
const WorldState := preload("res://WorldState.gd")
const SaveIO := preload("res://SaveIO.gd")
const EnvDB := preload("res://EnvDB.gd")
const OverworldScript := preload("res://Overworld.gd")
const EventDB := preload("res://EventDB.gd")   # 全局事件池：行军测试须整池禁用（chance 类=非确定性）

const SandboxConfig := preload("res://SandboxConfig.gd")

const SLOT := "_test_m4"
const TMP_MAP := "user://_test_m4_map.json"
var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _initialize() -> void:
	print("=== Overworld/M4 测试开始 ===")

	# 1) MapIO map_type：写读往返 + 旧图缺省 battle
	var tiles := MapIO.grassland(4, 4)
	ck(MapIO.write_map(TMP_MAP, 4, 4, tiles, {"map_type": "overworld"}), "write_map(map_type) 成功")
	var res := MapIO.read_file(TMP_MAP)
	ck(res.get("ok", false) and str(res.get("map_type")) == "overworld", "map_type 往返")
	ck(str(MapIO.normalize({"width": 3, "height": 3, "tiles": []}).get("map_type")) == "battle", "旧图缺省 battle")
	DirAccess.remove_absolute(TMP_MAP)

	# 2) TerrainDB.move_cost：通行/禁行/tag 门槛/tag_cost 取优
	ck(TerrainDB.move_cost({"cost": 2, "passable_by": "all"}, []) == 2, "all 可通行取 cost")
	ck(TerrainDB.move_cost({"cost": 1, "passable_by": "none"}, ["flying"]) == -1, "none 禁行")
	ck(TerrainDB.move_cost({"cost": 1, "passable_by": ["flying"]}, []) == -1, "tag 门槛：空 tags 不可入")
	ck(TerrainDB.move_cost({"cost": 1, "passable_by": ["flying"]}, ["flying"]) == 1, "tag 门槛：含 tag 可入")
	ck(TerrainDB.move_cost({"cost": 3, "passable_by": "all", "tag_cost": {"flying": 1}}, ["flying"]) == 1, "tag_cost 取更优")
	ck(TerrainDB.move_cost(null, []) == -1, "非法 move 块＝禁行")

	# 3) WorldState：start_new 开局时刻 + party 往返
	var ws = WorldState.start_new()
	ck(ws.clock_hours == WorldState.START_HOUR, "新档开局＝第 1 天 %d 点" % WorldState.START_HOUR)
	ws.party_col = 12
	ws.party_row = 8
	ck(SaveIO.save_campaign(ws, SLOT), "save 成功")
	var ld = SaveIO.load_campaign(SLOT)
	ck(ld != null and ld.party_col == 12 and ld.party_row == 8, "party 位置往返")
	SaveIO.delete_slot(SLOT)

	# 4) 默认大地图：可读、map_type=overworld、带触发器
	var world := MapIO.read_file("res://maps/overworld/world.json")
	ck(world.get("ok", false), "world.json 可读")
	ck(str(world.get("map_type")) == "overworld", "world.json map_type=overworld")
	ck((world.get("triggers", []) as Array).size() >= 3, "world.json 带示例触发器")

	# 5) Overworld 纯逻辑（new() 不进树）：落位 / 寻路 / 悬停文字
	var ow = OverworldScript.new()
	ow._ensure_campaign()   # current 已是 ws（上面 start_new 的）
	ow._load_map()
	ck(ow.width == 24 and ow.height == 16, "大地图尺寸 24×16")
	ow._ensure_party_placed()
	var pc := ow.party_cell()
	ck(pc.x >= 0 and ow._move_cost_at(pc.x, pc.y) >= 0, "party 落位在可走格（%s）" % pc)
	# 道路直走可达（山口在 row 8）
	var p1: Array = ow.find_path(Vector2i(8, 8), Vector2i(20, 8))
	ck(p1.size() >= 2 and p1.front() == Vector2i(8, 8) and p1.back() == Vector2i(20, 8), "道路寻路可达")
	# 山脉以西（col 0~2）↔ 以东：必须存在路（山口/道路），且路径绕开山格（成本 3 的山可走但更贵，最优路走山口道路）
	var p2: Array = ow.find_path(Vector2i(1, 8), Vector2i(8, 8))
	ck(p2.size() >= 2, "跨山脉可达（山口）")
	# 深水（湖心 19,2 附近）对空 tags 队伍不可达
	var p3: Array = ow.find_path(Vector2i(12, 8), Vector2i(19, 2))
	ck(p3.is_empty(), "深水目标不可达（空 tags）")
	ck(ow._move_cost_at(19, 2) == -1, "深水格 move_cost=-1")
	# 悬停文字（不依赖 UI）
	ck(ow.hover_text(19, 2).contains("不可通行"), "悬停：深水显示不可通行")
	ck(ow.hover_text(8, 8).contains("小时"), "悬停：可走格显示行程耗时")
	ow.free()   # Control 是 Node：手动释放（未进树无人管）

	# 6) 伪即时行军/_on_camp 闭环（2026-07-08 重写自 _travel：_tick_time 直调模拟帧；断言等价——终点/时钟增量/事件钩/自动存档）
	var ow2 = OverworldScript.new()
	var ws2 = WorldState.start_new()
	ow2._save_slot = "_test_m4_travel"
	ow2._ensure_campaign()   # current 已有 → 非 transient（真存档路径）
	ck(not ow2._transient, "已有档不标 transient")
	ow2._load_map()
	# 换成受控触发器：every_hours=1 的 timer——每整点必触发，验证行军中事件评估在跑
	ow2._map_triggers = [{"id": "t_test", "when": {"event": "timer", "every_hours": 1}, "do": [{"action": "show_message", "text": "tick"}]}]
	# 受控环境：中和开局敌对派系（流寇 start_rep=-50）——遭伏概率触发会按新语义正当地中停行军，测试要确定性
	ws2.reputation["bandits"] = 0
	# 受控环境②：全局事件池整池禁用（event_disabled 硬闸）——chance 事件随机开火会打断行军
	# （商人对话=模态自动暂停；波2 起池子持续扩容，逐条豁免不可维护）。本测试只验每图 triggers 钩子。
	for pe in EventDB.all_events():
		ws2.event_disabled[str(pe.get("id", ""))] = true
	SandboxConfig.battle_setup = null   # 静态跨场景通道：清残留，防误判「战斗待切」暂停
	ws2.party_col = 8
	ws2.party_row = 8
	var tpath: Array = ow2.find_path(Vector2i(8, 8), Vector2i(11, 8))   # 沿道路 3 格（cost 1/格）
	ck(tpath.size() == 4, "道路 3 格路径（含起点 4 节点）")
	var t0: int = ws2.clock_hours
	ow2.simulate_travel_to_arrival(tpath)
	ck(ws2.party_col == 11 and ws2.party_row == 8, "行军落终点")
	ck(ws2.clock_hours == t0 + 3 * 1 * ow2.HOURS_PER_COST, "行军推钟（路径总成本 3×cost1×%dh，实得 +%d）" % [ow2.HOURS_PER_COST, ws2.clock_hours - t0])
	ck(not ow2._time_playing, "抵达自动暂停")
	ck(ow2._route.is_empty() and ow2.move_target() == Vector2i(-1, -1), "抵达清路径/目的地标记")
	ck(ws2.event_timer_last.has("t_test"), "行军中 timer 事件被评估（timer_last 记账）")
	ck(SandboxConfig.battle_setup == null, "受控环境无战斗排队（有＝遭伏没被中和）")
	ck(SaveIO.list_slots().has("_test_m4_travel"), "抵达自动存档写入注入槽")
	# 6b) 段内插值 + 半路改令：道路段＝1h（cost1×HOURS_PER_COST1），推 0.5h＝半段——token 半途、未落格、整点未跨
	var tb0: int = ws2.clock_hours
	ow2._hour_acc = 0.0   # 清整点累加器零头，令下面整点断言干净
	ow2._set_route(ow2.find_path(Vector2i(11, 8), Vector2i(8, 8)))
	ow2._time_playing = true
	ow2._tick_time(0.5)
	ck(ws2.party_col == 11 and absf(ow2._seg_progress - 0.5) < 0.001, "半段：未落格、seg_progress=0.5")
	ck(ws2.clock_hours == tb0, "半段未跨整点（sub-hour 不进位，clock_hours 恒整数）")
	var seg: Dictionary = ow2.party_seg()
	ck(seg["from"] == Vector2i(11, 8) and seg["to"] == Vector2i(10, 8) and absf(float(seg["t"]) - 0.5) < 0.001, "party_seg 插值钩子透出半途段")
	ow2.left_click_cell(10, 8)   # 半路改令：从当前格重新寻路（段内进度作废）
	ck(ow2._seg_progress == 0.0 and ow2._time_playing, "半路重新寻路：段进度重置、自动播放")
	for i in 100:
		if not ow2._time_playing:
			break
		ow2._tick_time(0.5)
	ck(ws2.party_col == 10 and ws2.party_row == 8 and not ow2._time_playing, "改令后抵达新目的地并自动暂停")
	ck(ws2.clock_hours == tb0 + 1, "改令重走整段：累计跨 1 整点 → +1h（clock_hours 恒整数）")
	# 6c) 原地等待：无路径播放＝时间照常流逝（WorldSim/timer 逐整点推进），不自动暂停
	var tw0: int = ws2.clock_hours
	ow2._time_playing = true
	ow2._tick_time(2.0)
	ck(ws2.clock_hours == tw0 + 2 and ow2._time_playing, "原地等待推钟 +2h、不自动暂停")
	ow2._pause_time()
	# 6d) 扎营维持离散休整（本刀不动）
	var t1: int = ws2.clock_hours
	ow2._on_camp()
	ck(ws2.clock_hours == t1 + ow2.CAMP_HOURS, "扎营 +%dh" % ow2.CAMP_HOURS)
	SaveIO.delete_slot("_test_m4_travel")
	ow2.free()

	# 7) 无档兜底＝transient：绝不自动落盘（审查确认的「兜底档覆盖玩家 auto 真档」防线）
	WorldState.current = null
	var ow3 = OverworldScript.new()
	ow3._save_slot = "_test_m4_transient"
	ow3._ensure_campaign()
	ck(ow3._transient, "无档兜底标记 transient")
	ow3._autosave()
	ck(not SaveIO.list_slots().has("_test_m4_transient"), "transient 档不落盘")
	ow3.free()

	# 8) EnvDB.time_for_hour 数据分支（临时替换静态表、测完恢复）
	EnvDB.time_for_hour(0)   # 触发 _ensure 加载
	var bak_times: Array = EnvDB._times
	EnvDB._times = [{"id": "special", "label": "特"}, {"id": "day", "label": "昼", "from_hour": 6}]
	ck(EnvDB.time_for_hour(3) == "day", "无 from_hour 时段不参与映射（3 点环回唯一有效时段）")
	EnvDB._times = [{"id": "special", "label": "特"}]
	ck(EnvDB.time_for_hour(12) == "special", "全无 from_hour → 第一个时段兜底")
	EnvDB._times = bak_times

	WorldState.current = null
	if _fail == 0:
		print("=== 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
