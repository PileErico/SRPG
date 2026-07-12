extends SceneTree
## 线特征 + 地形 scope 回归（地块美术升级 P1/P2/P3 转正）：
## MapIO v4 rivers/roads/bridges 往返与旧图缺省 / HexGrid.edge_key / TerrainDB.in_scope 与新地形 /
## Overworld 边感知通行（河阻断·桥豁免·道路折扣＝寻路与扣时同源）/ WorldSim 游荡吃边 /
## 编辑器线特征与地点层纯逻辑（画/擦/撤销/存盘往返，不进树）/ decor 扰动确定性。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_mapfeatures.gd（退出码 0=PASS）

const MapIO := preload("res://MapIO.gd")
const HexGrid := preload("res://HexGrid.gd")
const TerrainDB := preload("res://TerrainDB.gd")
const WorldState := preload("res://WorldState.gd")
const WorldSim := preload("res://WorldSim.gd")
const OverworldScript := preload("res://Overworld.gd")
const MapEditorScript := preload("res://MapEditor.gd")
const HexTileRender := preload("res://HexTileRender.gd")
const LocationDB := preload("res://LocationDB.gd")

const TMP_MAP := "user://_test_feat_map.json"
var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _initialize() -> void:
	print("=== 线特征/scope 测试开始 ===")

	# 1) HexGrid 边原语：edge_key 无向归一 + adjacent
	ck(HexGrid.edge_key(Vector2i(3, 4), Vector2i(3, 5)) == HexGrid.edge_key(Vector2i(3, 5), Vector2i(3, 4)), "edge_key 无向归一")
	ck(HexGrid.edge_key(Vector2i(1, 1), Vector2i(2, 1)) != HexGrid.edge_key(Vector2i(1, 1), Vector2i(1, 2)), "不同边不同键")
	ck(HexGrid.adjacent(Vector2i(5, 5), Vector2i(5, 6)) and not HexGrid.adjacent(Vector2i(5, 5), Vector2i(5, 7)), "adjacent 判定")

	# 2) MapIO v4：线特征写读往返 + 旧图缺省空 + 坏格对清洗
	var rivers := [{"id": "r1", "label": "河", "pairs": [[[1, 1], [1, 2]], [[2, 1], [2, 2]]]}]
	var roads := [{"id": "d1", "label": "路", "pairs": [[[0, 0], [1, 0]]]}]
	var bridges := [[[1, 1], [1, 2]]]
	ck(MapIO.write_map(TMP_MAP, 4, 4, MapIO.grassland(4, 4), {"map_type": "overworld", "rivers": rivers, "roads": roads, "bridges": bridges}), "write_map(线特征) 成功")
	var res := MapIO.read_file(TMP_MAP)
	ck(res.get("ok", false), "读回成功")
	ck((res.get("rivers", []) as Array).size() == 1 and ((res["rivers"][0] as Dictionary).get("pairs") as Array).size() == 2, "rivers 往返")
	ck((res.get("roads", []) as Array).size() == 1, "roads 往返")
	ck((res.get("bridges", []) as Array).size() == 1, "bridges 往返")
	var old := MapIO.normalize({"width": 3, "height": 3, "tiles": []})
	ck((old.get("rivers", [1]) as Array).is_empty() and (old.get("roads", [1]) as Array).is_empty() and (old.get("bridges", [1]) as Array).is_empty(), "旧图缺省空线特征")
	var dirty := MapIO.normalize({"width": 3, "height": 3, "tiles": [], "rivers": [{"pairs": [[[1, 1]], "bad", [[0, 0], [1, 0]]]}, "junk"], "bridges": ["x", [[1, 1], [1, 2]]]})
	ck(((dirty["rivers"][0] as Dictionary)["pairs"] as Array).size() == 1, "坏格对清洗（保留合法项）")
	ck((dirty["bridges"] as Array).size() == 1, "bridges 坏项清洗")
	DirAccess.remove_absolute(TMP_MAP)

	# 3) TerrainDB scope：新地形注册 + in_scope 过滤语义（缺省 both）
	for want in ["swamp", "farmland", "tundra", "coast", "bridge"]:
		ck(TerrainDB.entry_for({"terrain": want, "variant": want}) != null, "新地形注册：%s" % want)
	ck(TerrainDB.in_scope({"scope": "both"}, "battle") and TerrainDB.in_scope({"scope": "both"}, "overworld"), "both 全适用")
	ck(TerrainDB.in_scope({}, "battle"), "缺省＝both（旧数据零迁移）")
	ck(TerrainDB.in_scope({"scope": "overworld"}, "overworld") and not TerrainDB.in_scope({"scope": "overworld"}, "battle"), "overworld 专属")
	ck(not TerrainDB.in_scope(TerrainDB.entry_for({"terrain": "wall", "variant": "wall"}), "overworld"), "墙＝战场专属")
	ck(not TerrainDB.in_scope(TerrainDB.entry_for({"terrain": "road", "variant": "road"}), "overworld"), "road 地块退居战场（大地图用道路 overlay）")

	# 4) Overworld 边感知通行（合成小图，不进树）：河阻断 / 桥豁免 / 道路折扣 / 寻路绕行
	var ws = WorldState.start_new()
	var ow = OverworldScript.new()
	ow.width = 6
	ow.height = 6
	ow.tiles = MapIO.grassland(6, 6)
	ow.tiles[3][2] = {"terrain": "forest", "variant": "forest"}   # (col2,row3) 森林（大世界成本 4）：道路折扣验证格
	# 横贯全图的河（rows 2/3 之间全部分隔边）+ 唯一桥在 (4,2)-(4,3)
	var pairs := []
	for c in 6:
		var top := Vector2i(c, 2)
		for nb in HexGrid.neighbors(top):
			if nb.y == 3 and nb.x >= 0 and nb.x < 6:
				pairs.append([[top.x, top.y], [nb.x, nb.y]])
	ow._setup_line_features({"rivers": [{"id": "r", "label": "河", "pairs": pairs}],
		"roads": [{"id": "d", "label": "路", "pairs": [[[2, 2], [2, 3]], [[1, 3], [2, 3]]]}],
		"bridges": [[[4, 2], [4, 3]]]})
	ck(ow._move_cost_at(2, 3) == 4, "森林格大世界成本 4（OVERWORLD_COST）")
	ck(ow._move_cost_between(2, 2, 2, 3) == -1, "河边无桥＝硬阻断（道路也过不去）")
	ck(ow._move_cost_between(4, 2, 4, 3) == 1, "桥豁免可跨（享道路折扣）")
	ck(ow._move_cost_between(1, 3, 2, 3) == 1, "道路折扣：森林 4 → 1")
	ck(ow._move_cost_between(2, 3, 1, 3) == 1, "道路折扣无向")
	ck(ow._move_cost_between(0, 0, 1, 0) == 2, "无线特征边＝格成本（草原大世界 2）")
	var p := ow.find_path(Vector2i(4, 1), Vector2i(4, 4))
	ck(p.size() >= 4 and p.has(Vector2i(4, 2)) and p.has(Vector2i(4, 3)), "过河走桥")
	var p2 := ow.find_path(Vector2i(0, 1), Vector2i(0, 4))
	ck(not p2.is_empty(), "远端过河可达（绕桥）")
	var crosses_bridge := false
	for i in range(1, p2.size()):
		var k := HexGrid.edge_key(p2[i - 1], p2[i])
		ck(not (ow._river_edges.has(k) and not ow._bridge_edges.has(k)), "路径不踩无桥河边")
		if ow._bridge_edges.has(k):
			crosses_bridge = true
	ck(crosses_bridge, "绕行路径经过桥")

	# 5) WorldSim 游荡吃边：河边邻格不进候选
	var nbs: Array = WorldSim._passable_neighbors(ow, Vector2i(2, 2))
	ck(not nbs.has(Vector2i(2, 3)), "游荡候选排除无桥河对岸")
	var nbs2: Array = WorldSim._passable_neighbors(ow, Vector2i(4, 2))
	ck(nbs2.has(Vector2i(4, 3)), "游荡候选保留桥对岸")
	# 5b) 边感知相邻（交战/摩擦战结算门槛，review#4/#5 修复）：隔无桥河边≠可达相邻，桥边算
	ck(not WorldSim._reachable_adjacent(ow, Vector2i(2, 2), Vector2i(2, 3)), "隔无桥河边≠可达相邻（不隔河 engage/erase）")
	ck(WorldSim._reachable_adjacent(ow, Vector2i(4, 2), Vector2i(4, 3)), "桥边=可达相邻")
	ck(WorldSim._reachable_adjacent(ow, Vector2i(0, 0), Vector2i(1, 0)), "普通相邻=可达")
	ck(WorldSim._reachable_adjacent(ow, Vector2i(3, 3), Vector2i(3, 3)), "同格=可达（自身）")
	ck(not WorldSim._reachable_adjacent(ow, Vector2i(0, 0), Vector2i(2, 0)), "非相邻≠可达相邻")
	ck(WorldSim._reachable_adjacent(null, Vector2i(0, 0), Vector2i(1, 0)), "无宿主 _move_cost_between → 退回纯几何相邻")
	ow.free()

	# 6) 真实 world.json：线特征转正落地 + 城→村跨河（走桥）+ 无桥边阻断
	var world := MapIO.read_file("res://maps/overworld/world.json")
	ck((world.get("rivers", []) as Array).size() >= 1 and (world.get("roads", []) as Array).size() >= 1 and (world.get("bridges", []) as Array).size() >= 1, "world.json 带河/路/桥")
	# v5 地标（与 tools/gen_overworld_map.gd 对表 ⚠）：霜河 rows 5|6 cols 12..32、桥 (20,5)-(20,6)、主道 row 10
	var ow2 = OverworldScript.new()
	ow2._ensure_campaign()
	ow2._load_map()
	ck(ow2._move_cost_between(25, 5, 25, 6) == -1, "world 河边无桥阻断 (25,5)-(25,6)")
	ck(ow2._move_cost_between(20, 5, 20, 6) == 1, "world 桥可跨 (20,5)-(20,6)")
	var pcity := ow2.find_path(Vector2i(9, 10), Vector2i(20, 3))
	ck(not pcity.is_empty(), "城→村可达（跨河走桥）")
	ck(pcity.has(Vector2i(20, 5)) and pcity.has(Vector2i(20, 6)), "城→村路径经过桥")
	var proad := ow2.find_path(Vector2i(8, 10), Vector2i(20, 10))
	ck(proad.size() >= 2, "东西大道仍可达（道路 overlay 化后）")
	ow2.free()

	# 7) 编辑器线特征/地点层纯逻辑（new() 不进树、不 _build_ui）：画/擦/桥规则/撤销/存盘往返
	var ed = MapEditorScript.new()
	ed._load_terrains()
	ed.new_map(5, 5)
	ed.map_type = "overworld"
	# 河刷：加两条边；重复加去重
	ed.begin_stroke()
	ed._river_add_edge(Vector2i(1, 1), Vector2i(1, 2))
	ed._river_add_edge(Vector2i(2, 1), Vector2i(2, 2))
	ed._river_add_edge(Vector2i(1, 2), Vector2i(1, 1))   # 反向重复＝无效
	ed.end_stroke()
	ck(((ed.map_rivers[0] as Dictionary)["pairs"] as Array).size() == 2, "河刷加边（无向去重）")
	# 桥规则：非河边拒绝、河边可架
	ed.begin_stroke()
	ed._bridge_add_edge(Vector2i(3, 3), Vector2i(3, 4))
	ck(ed.map_bridges.is_empty(), "桥须架在河上（非河边拒绝）")
	ed._bridge_add_edge(Vector2i(1, 1), Vector2i(1, 2))
	ck(ed.map_bridges.size() == 1, "河边架桥")
	ed.end_stroke()
	# 擦河顺带拆桥
	ed.begin_stroke()
	ed._river_remove_edge(Vector2i(1, 1), Vector2i(1, 2))
	ed.end_stroke()
	ck(((ed.map_rivers[0] as Dictionary)["pairs"] as Array).size() == 1 and ed.map_bridges.is_empty(), "擦河顺带拆桥")
	# 路刷：格轨迹连线（跳格补齐）
	ed.begin_stroke()
	ed.road_paint_cell(0, 0)
	ed.road_paint_cell(1, 0)
	ed.road_paint_cell(3, 0)   # 跳格 → HexGrid.line 补中间
	ed.end_stroke()
	var road_n: int = ((ed.map_roads[0] as Dictionary)["pairs"] as Array).size()
	ck(road_n >= 3, "路刷连线（跳格补齐，实得 %d 段）" % road_n)
	# 撤销：一段 stroke 一步回退
	var before_rivers: int = ((ed.map_rivers[0] as Dictionary)["pairs"] as Array).size()
	ed.begin_stroke()
	ed._river_add_edge(Vector2i(3, 1), Vector2i(3, 2))
	ed.end_stroke()
	ed.undo()
	ck(((ed.map_rivers[0] as Dictionary)["pairs"] as Array).size() == before_rivers, "线特征撤销回退")
	# 地点层：放置/唯一 id/删除/撤销
	ed._loc_types = LocationDB.all_types()
	ed._loc_type_idx = 0
	ed.begin_stroke()
	ed._loc_paint(2, 2)
	ed.end_stroke()
	ck(ed.map_locations.size() == 1 and str(ed.map_locations[0].get("type", "")) == str(ed._loc_types[0].get("id", "")), "地点放置")
	var lid := str(ed.map_locations[0].get("id", ""))
	ed.begin_stroke()
	ed._loc_paint(3, 3)
	ed.end_stroke()
	ck(ed.map_locations.size() == 2 and str(ed.map_locations[1].get("id", "")) != lid, "地点 id 唯一")
	ed._loc_remove(3, 3)
	ck(ed.map_locations.size() == 1, "地点删除")
	ed.undo()
	ck(ed.map_locations.size() == 2, "地点删除可撤销")
	# 快照含 map_type：撤销跨类型切换不丢
	ck(str(ed._snapshot().get("map_type", "")) == "overworld", "快照含 map_type")
	# 存盘往返：to_json_dict 带全部新字段
	var d := ed.to_json_dict()
	var norm := MapIO.normalize(d)
	ck((norm["rivers"] as Array).size() == 1 and (norm["roads"] as Array).size() == 1 and (norm["locations"] as Array).size() == 2, "编辑器存盘往返（试玩直传同形）")
	ck(str(norm.get("map_type", "")) == "overworld", "map_type 随存")
	# 笔刷全通用（SCOPE_FILTER_ON=false）：不分大/小地图，road 和 swamp 两种地图都出现（scope 机制仍在，见上 in_scope 断言，只是编辑器不再据此过滤）
	ed.map_type = "battle"
	var vis_b := ed._visible_brush_indices()
	ed.map_type = "overworld"
	var vis_o := ed._visible_brush_indices()
	var has := func(vis: Array, id: String) -> bool:
		for i in vis:
			if str(ed.PALETTE[i].get("id", "")) == id:
				return true
		return false
	ck(has.call(vis_b, "road") and has.call(vis_b, "swamp"), "笔刷全通用：battle 也含 swamp")
	ck(has.call(vis_o, "swamp") and has.call(vis_o, "road"), "笔刷全通用：overworld 也含 road")
	ck(has.call(vis_b, "grassland") and has.call(vis_o, "grassland"), "both 地形两边都在")

	# 8) Layer 容器（2026-07-07 注册表化）：全数据层快照往返 / new_map 清空 / _map_opts 字段齐全 / 深隔离
	ed.regions = [{"id": "r1", "label": "区", "color": "#FFFFFF", "kind": "aggro", "cells": {Vector2i(1, 1): true}}]
	ed.map_units = [{"proto": {"id": "empire_infantry", "name": "步"}, "col": 2, "row": 2, "faction": "enemy"}]
	ed.map_triggers = [{"id": "t1", "label": "触", "when": {"region": "r1"}, "do": []}]
	ed.map_terrain_overrides = {"plain/grassland": {"move": {"cost": 2}}}
	ed.map_environment = {"time": "night"}
	var snap: Dictionary = ed._snapshot()
	for l in ed.LAYERS:
		ck(snap.has(l[0]), "快照含层 %s" % l[0])
	var opts: Dictionary = ed._map_opts()
	for l in ed.LAYERS:
		ck(opts.has(l[1]), "_map_opts 含磁盘字段 %s" % l[1])
	ed.map_units[0]["proto"]["name"] = "改"   # 拍完快照改活数据 → 快照不受染（深拷贝隔离）
	ck(str(((snap["map_units"][0] as Dictionary)["proto"] as Dictionary).get("name", "")) == "步", "快照与活数据深隔离（units proto）")
	ed.new_map(4, 4)
	ck(ed.regions.is_empty() and ed.map_units.is_empty() and ed.map_triggers.is_empty() \
		and ed.map_terrain_overrides.is_empty() and ed.map_environment.is_empty() \
		and ed.map_rivers.is_empty() and ed.map_locations.is_empty() and ed.map_type == "battle", "new_map 全层清空+类型回缺省")
	ed._apply_snapshot(snap)
	ck(ed.regions.size() == 1 and (ed.regions[0]["cells"] as Dictionary).has(Vector2i(1, 1)), "回滚：区域层（cells 集合形）")
	ck(ed.map_units.size() == 1 and str((ed.map_units[0]["proto"] as Dictionary).get("name", "")) == "步", "回滚：单位层（快照时点值）")
	ck(ed.map_triggers.size() == 1 and str(ed.map_triggers[0].get("id", "")) == "t1", "回滚：触发器层")
	ck(int((ed.map_terrain_overrides.get("plain/grassland", {}) as Dictionary).get("move", {}).get("cost", 0)) == 2, "回滚：图级地形覆盖")
	ck(str(ed.map_environment.get("time", "")) == "night", "回滚：环境层")
	ck(ed.map_locations.size() == 2 and ed.map_rivers.size() == 1 and ed.map_roads.size() == 1, "回滚：地点/线特征层")
	ck(ed.map_type == "overworld", "回滚：map_type 随快照")
	ed.free()

	# 9) 地形工具（2026-07-07）：油漆桶 / 画笔半径 / 矩形·直线 两点工具
	var e2 = MapEditorScript.new()
	e2._load_terrains()
	e2.new_map(6, 6)
	var bi := -1
	for i in e2.PALETTE.size():
		var pb: Dictionary = e2.PALETTE[i]
		# 必须选「地形」刷（工坊扩容后同名条目可能是放置物刷——那种写 object 子字段不动地形；森林即已放置物化）
		if str(pb.get("terrain", "")) == "mountain" and not TerrainDB.is_object(pb):
			bi = i
			break
	ck(bi >= 0, "找到山地地形笔刷（非放置物）")
	e2.brush_index = bi
	var count_mnt := func() -> int:
		var n := 0
		for r in 6:
			for c in 6:
				if str(e2.tiles[r][c].get("terrain")) == "mountain":
					n += 1
		return n
	e2.terrain_tool = "fill"
	e2.begin_stroke()
	e2.primary_paint(2, 2)
	e2.primary_paint(3, 3)   # 拖动第二格：一次按下只填一回
	e2.end_stroke()
	ck(count_mnt.call() == 36, "油漆桶：连通草原整片染山（实得 %d/36）" % count_mnt.call())
	e2.undo()
	ck(str(e2.tiles[2][2].get("terrain")) == "plain", "油漆桶一步撤销")
	e2.terrain_tool = "brush"
	e2.brush_radius = 1
	e2.begin_stroke()
	e2.primary_paint(3, 3)
	e2.end_stroke()
	ck(count_mnt.call() == 7, "画笔半径1＝中心+六邻 7 格（实得 %d）" % count_mnt.call())
	e2.new_map(6, 6)
	e2.brush_index = bi
	e2.terrain_tool = "rect"
	e2.begin_stroke()
	e2.primary_paint(0, 0)
	e2.primary_paint(2, 1)   # 拖到对角
	e2.end_stroke()
	ck(count_mnt.call() == 6, "矩形工具 3×2＝6 格（实得 %d）" % count_mnt.call())
	e2.terrain_tool = "line"
	e2.begin_stroke()
	e2.primary_paint(0, 3)
	e2.primary_paint(4, 3)
	e2.end_stroke()
	ck(str(e2.tiles[3][0].get("terrain")) == "mountain" and str(e2.tiles[3][4].get("terrain")) == "mountain", "直线工具两端落形")
	e2.undo()
	ck(str(e2.tiles[3][0].get("terrain")) == "plain", "直线一步撤销")
	e2.free()

	# 8) decor 扰动（HexTileRender 单一实现）：确定性（同种子同输出）+ 幅度有界（±2.5px）+ seed 0=零偏移（笔刷缩略图规整）
	var a: Vector2 = HexTileRender._jo(12345, 0)
	var b: Vector2 = HexTileRender._jo(12345, 0)
	var c: Vector2 = HexTileRender._jo(54321, 0)
	ck(a == b, "扰动确定性（同种子同输出）")
	ck(a != c, "不同种子不同扰动")
	ck(HexTileRender._jo(0, 0) == Vector2.ZERO and HexTileRender._jo(0, 3) == Vector2.ZERO, "seed=0 → 零偏移（笔刷缩略图不抖）")
	for i in 8:
		var v: Vector2 = HexTileRender._jo(777, i)
		ck(absf(v.x) <= 2.5 and absf(v.y) <= 2.5, "扰动幅度有界（元素 %d）" % i)

	WorldState.current = null
	if _fail == 0:
		print("=== 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
