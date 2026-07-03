extends SceneTree
## M4 回归：map_type schema / TerrainDB.move_cost 单一实现 / WorldState party 往返 / Overworld 寻路与耗时（纯逻辑，不进树）。
## 注意：不触碰 "auto" 存档槽（那是玩家真档）；本测试用独立槽并清理。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_overworld.gd（退出码 0=PASS）

const MapIO := preload("res://MapIO.gd")
const TerrainDB := preload("res://TerrainDB.gd")
const WorldState := preload("res://WorldState.gd")
const SaveIO := preload("res://SaveIO.gd")
const EnvDB := preload("res://EnvDB.gd")
const OverworldScript := preload("res://Overworld.gd")

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

	# 6) _travel/_on_camp 闭环（M4 审查补：核心语义逐格推钟+事件钩+自动存档；注入独立槽，绝不碰玩家 auto 档）
	var ow2 = OverworldScript.new()
	var ws2 = WorldState.start_new()
	ow2._save_slot = "_test_m4_travel"
	ow2._ensure_campaign()   # current 已有 → 非 transient（真存档路径）
	ck(not ow2._transient, "已有档不标 transient")
	ow2._load_map()
	# 换成受控触发器：every_hours=1 的 timer——每格推 2h 必触发，验证行进中事件评估在跑
	ow2._map_triggers = [{"id": "t_test", "when": {"event": "timer", "every_hours": 1}, "do": [{"action": "show_message", "text": "tick"}]}]
	ws2.party_col = 8
	ws2.party_row = 8
	var tpath: Array = ow2.find_path(Vector2i(8, 8), Vector2i(11, 8))   # 沿道路 3 格（cost 1/格）
	ck(tpath.size() == 4, "道路 3 格路径（含起点 4 节点）")
	var t0: int = ws2.clock_hours
	await ow2._travel(tpath)
	ck(ws2.party_col == 11 and ws2.party_row == 8, "travel 落终点")
	ck(ws2.clock_hours == t0 + 3 * 1 * ow2.HOURS_PER_COST, "travel 逐格推钟（3 格×cost1×%dh，实得 +%d）" % [ow2.HOURS_PER_COST, ws2.clock_hours - t0])
	ck(ws2.event_timer_last.has("t_test"), "行进中 timer 事件被评估（timer_last 记账）")
	ck(SaveIO.list_slots().has("_test_m4_travel"), "travel 完成自动存档写入注入槽")
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
