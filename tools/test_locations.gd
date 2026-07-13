extends SceneTree
## M7 回归：LocationDB 注册表 / 瓦片=地点派生 🔒（存在性=瓦片 location_type、locations=注记层）
## / 据点刷新惰性判定 / WorldState gold+location_cleared_at 往返
## / MapIO locations 透传 / BattleIO context 落肃清账 / Overworld 地点消费（索引·悬停·休整·讨伐）。
## 注意：不触碰 "auto" 存档槽；用独立槽并清理。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_locations.gd（退出码 0=PASS）

const LocationDB := preload("res://LocationDB.gd")
const WorldState := preload("res://WorldState.gd")
const WorldClock := preload("res://WorldClock.gd")
const SaveIO := preload("res://SaveIO.gd")
const MapIO := preload("res://MapIO.gd")
const BattleIO := preload("res://BattleIO.gd")
const SandboxConfig := preload("res://SandboxConfig.gd")
const OverworldScript := preload("res://Overworld.gd")
const SandboxScript := preload("res://Sandbox.gd")

const SLOT := "_test_m7"
const TMP_MAP := "user://_test_m7_map.json"
var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _initialize() -> void:
	print("=== M7 地点系统测试开始 ===")

	# 1) LocationDB 注册表：四类型 + 服务解析
	for want in ["city", "village", "ruin", "lair"]:
		ck(LocationDB.type_def(want) != null, "类型表含 %s" % want)
	ck(LocationDB.type_label("city") == "城市", "type_label 中文")
	ck(LocationDB.is_site("lair") and LocationDB.is_site("ruin") and not LocationDB.is_site("city"), "site 判定")
	var city_svcs := LocationDB.services_of("city")
	ck(city_svcs.size() == 4, "城市 4 服务（rest/trade/recruit/smith）")
	ck(str(LocationDB.service("rest").get("status")) == "in_use", "rest 已接入标记")
	ck(int(LocationDB.service("rest").get("gold", 0)) > 0, "rest 带占位价格")
	ck(LocationDB.services_of("village").size() == 2, "村落 2 服务")

	# 1b) 瓦片=地点派生 🔒：存在性由瓦片 location_type、注记按格合并（id/label/图/对话）、
	#     无注记兜底 id/label、site 型兜底可打图、孤儿注记（落在非地点瓦片）检出、注记残留 type 忽略
	var g := {"terrain": "plain", "variant": "grassland"}
	var tl := [
		[{"terrain": "fh", "variant": "city_center"}, g],
		[{"terrain": "fh", "variant": "ancient_ruins"}, g],
	]
	var anns := [
		{"id": "cap", "label": "王都", "col": 0, "row": 0, "dialogue_id": "dlg_x", "type": "ruin"},   # type 残留＝忽略（瓦片说了算）
		{"id": "ghost", "label": "幽灵", "col": 1, "row": 1},                                          # 草地格＝孤儿
	]
	var dv := LocationDB.derive_locations(tl, anns)
	ck((dv["list"] as Array).size() == 2, "派生地点数=地点瓦片数")
	var cap: Dictionary = (dv["by_cell"] as Dictionary).get(Vector2i(0, 0), {})
	ck(str(cap.get("id", "")) == "cap" and str(cap.get("label", "")) == "王都" and str(cap.get("dialogue_id", "")) == "dlg_x", "注记合并（id/label/对话）")
	ck(str(cap.get("type", "")) == "city", "类型由瓦片推导（注记残留 type 忽略）")
	var rn: Dictionary = (dv["by_cell"] as Dictionary).get(Vector2i(0, 1), {})
	ck(str(rn.get("id", "")) == "ruin_c0_r1" and str(rn.get("label", "")) == LocationDB.type_label("ruin"), "无注记兜底 id/label")
	ck(str(rn.get("battle_map", "")) == "res://maps/sandbox.json", "site 型兜底可打图")
	var orphs: Array = dv["orphans"]
	ck(orphs.size() == 1 and str((orphs[0] as Dictionary).get("id", "")) == "ghost", "孤儿注记检出")

	# 2) 据点刷新（惰性判定 🔒）：未肃清=可 → 肃清=关 → lair 到点刷新 / ruin 一次性永久关
	var ws = WorldState.start_new()
	var lair := {"id": "lair_t", "type": "lair"}
	var ruin := {"id": "ruin_t", "type": "ruin"}
	var city := {"id": "city_t", "type": "city"}
	ck(LocationDB.site_ready(lair, ws) and LocationDB.site_ready(ruin, ws), "未肃清 → 可挑战")
	ck(not LocationDB.site_ready(city, ws), "服务型地点非据点")
	ws.mark_location_cleared("lair_t")
	ws.mark_location_cleared("ruin_t")
	ck(not LocationDB.site_ready(lair, ws) and not LocationDB.site_ready(ruin, ws), "肃清 → 关")
	var rh := int(LocationDB.type_def("lair").get("respawn_hours", 0))
	ck(LocationDB.site_respawn_in(lair, ws) == rh, "lair 刷新倒计时=%d" % rh)
	ck(LocationDB.site_respawn_in(ruin, ws) == -1, "ruin 一次性：不再刷新")
	ws.clock_hours += rh
	ck(LocationDB.site_ready(lair, ws), "lair 到点刷新")
	ck(not LocationDB.site_ready(ruin, ws), "ruin 永久关")

	# 3) WorldState：开局资金 + gold/location_cleared_at 存档往返
	ck(ws.gold == WorldState.START_GOLD, "新档开局资金=%d" % WorldState.START_GOLD)
	ws.gold = 137
	ck(SaveIO.save_campaign(ws, SLOT), "save 成功")
	var ld = SaveIO.load_campaign(SLOT)
	ck(ld != null and ld.gold == 137, "gold 往返")
	ck(int(ld.location_cleared_at.get("ruin_t", -1)) == int(ws.location_cleared_at["ruin_t"]), "location_cleared_at 往返（值 int 化）")
	SaveIO.delete_slot(SLOT)

	# 4) MapIO：locations 透传 + 旧图缺省 []
	var locs := [{"id": "a", "type": "city", "label": "甲城", "col": 1, "row": 1}]
	ck(MapIO.write_map(TMP_MAP, 4, 4, MapIO.grassland(4, 4), {"map_type": "overworld", "locations": locs}), "write_map(locations) 成功")
	var res := MapIO.read_file(TMP_MAP)
	var rl: Array = res.get("locations", [])
	ck(rl.size() == 1 and str(rl[0].get("id")) == "a", "locations 往返")
	ck((MapIO.normalize({"width": 3, "height": 3, "tiles": []}).get("locations", [1]) as Array).is_empty(), "旧图缺省 []")
	DirAccess.remove_absolute(TMP_MAP)

	# 5) BattleIO context：setup→result 透传；胜=落肃清账、败=不落
	var setup := BattleIO.make_setup("res://maps/sandbox.json", [], [], {"location_id": "lair_ctx"})
	ck(str((setup.get("context", {}) as Dictionary).get("location_id")) == "lair_ctx", "make_setup 带 context")
	var r_win := BattleIO.collect_result([], [], true, setup["context"])
	ck(str((r_win.get("context", {}) as Dictionary).get("location_id")) == "lair_ctx", "collect_result 嵌 context")
	BattleIO.apply_result(ws, BattleIO.collect_result([], [], false, setup["context"]))
	ck(not ws.location_cleared_at.has("lair_ctx"), "战败不落肃清账")
	BattleIO.apply_result(ws, r_win)
	ck(int(ws.location_cleared_at.get("lair_ctx", -1)) == ws.clock_hours, "战胜落肃清账（时刻=当前时钟）")

	# 6) Overworld 地点消费（new() 不进树）：world.json 地点装载 + 索引 + 悬停 + 标记数据
	var ow = OverworldScript.new()
	ow._ensure_campaign()   # current 已是 ws
	ow._save_slot = SLOT    # 绝不碰玩家 auto 档
	ow._load_map()
	# v5 地标（与 tools/gen_overworld_map.gd 对表 ⚠）：城 (9,10)、沙没之殿 (33,24)、劫道者营地 (12,20)；地点数从图数据推导
	var n_locs: int = ow._map_locations.size()
	ck(n_locs >= 4, "world.json 至少 4 个地点（实得 %d）" % n_locs)
	ck(ow._loc_by_cell.has(Vector2i(9, 10)) and ow._loc_by_cell.has(Vector2i(33, 24)), "落格索引（城/遗迹）")
	ck(ow.hover_text(9, 10).contains("阿斯特拉") and ow.hover_text(9, 10).contains("城市"), "悬停显示地点名+类型")
	ck(ow.hover_text(12, 20).contains("可挑战"), "悬停显示据点状态")
	ck(ow.locations_for_draw().size() == n_locs and bool(ow.locations_for_draw()[0].get("active")), "画布标记数据")

	# 7) 休整（rest 首个城市功能）：扣钱+推钟+回满；钱不够=拒绝无副作用
	var u = ws.roster[0]
	var mx: int = u.effective_stat("HP_max")
	u.stats["HP"] = 3
	ws.gold = 100
	var t0: int = ws.clock_hours
	var svc = LocationDB.service("rest")
	ck(ow._do_rest({"id": "city_t", "type": "city", "label": "甲城"}), "休整成交")
	ck(ws.gold == 100 - int(svc.get("gold", 0)), "扣占位房钱")
	ck(ws.clock_hours == t0 + int(svc.get("hours", 0)), "推进时钟 +%d" % int(svc.get("hours", 0)))
	ck(int(u.stats["HP"]) == mx, "全员生命回满")
	ws.gold = 0
	u.stats["HP"] = 3
	var t1: int = ws.clock_hours
	ck(not ow._do_rest({"id": "city_t", "type": "city", "label": "甲城"}), "钱不够 → 拒绝")
	ck(ws.clock_hours == t1 and int(u.stats["HP"]) == 3, "拒绝无副作用")

	# 8) 讨伐据点：可挑战 → 写 battle_setup（带 location_id）；已肃清 → 不开战
	SandboxConfig.battle_setup = null
	ow._challenge_site({"id": "lair_go", "type": "lair", "battle_map": "res://maps/sandbox.json"})
	ck(SandboxConfig.battle_setup != null, "讨伐写入 battle_setup")
	if SandboxConfig.battle_setup != null:
		ck(str((SandboxConfig.battle_setup.get("context", {}) as Dictionary).get("location_id")) == "lair_go", "setup.context 带 location_id")
	SandboxConfig.battle_setup = null
	ws.mark_location_cleared("lair_done")
	ow._challenge_site({"id": "lair_done", "type": "lair", "battle_map": "res://maps/sandbox.json"})
	ck(SandboxConfig.battle_setup == null, "已肃清据点不开战")
	ow.free()
	SaveIO.delete_slot(SLOT)

	# 9) Sandbox 透传：battle_setup.context → _battle_context（结算时随 result 回到 apply_result）
	var sb = SandboxScript.new()
	SandboxConfig.battle_setup = BattleIO.make_setup("res://maps/sandbox.json", [], [], {"location_id": "lair_sb"})
	sb._setup_campaign_battle()
	ck(sb.campaign_battle and str(sb._battle_context.get("location_id")) == "lair_sb", "Sandbox 读入 setup.context")
	ck(SandboxConfig.battle_setup == null, "通道读后即清")
	SandboxConfig.map_path = ""   # 还原（_setup_campaign_battle 会写它）
	sb.free()

	WorldState.current = null
	if _fail == 0:
		print("=== 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
