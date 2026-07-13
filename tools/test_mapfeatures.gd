extends SceneTree
## 线特征 + 地形 scope 回归（地块美术升级 P1/P2/P3 转正）：
## MapIO v4 rivers/roads/bridges 往返与旧图缺省 / HexGrid.edge_key / TerrainDB.in_scope 与新地形 /
## Overworld 边感知通行（河阻断·桥豁免·道路折扣＝寻路与扣时同源）/ WorldSim 游荡吃边 /
## 编辑器线特征与地点层纯逻辑（画/擦/撤销/存盘往返，不进树）/ decor 扰动确定性 /
## 编辑器批次 2026-07-13：单位拖移·Ctrl取样复制（§8）/ 尺寸调整逐层钳制（§30）/
## Ctrl+S 静默保存（§13）/ 全局地形脏旗（§19）/ 原型过滤（§20）/ 地点移注记。
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
const TMP_SAVE := "user://_test_feat_save.json"
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
	# 地点层（瓦片=地点 🔒）：画瓦片即地点（兜底 id/类型推导）→ 表单回写物化注记 → 删注记/撤销 → 铲瓦片出孤儿
	ed.tiles[2][2] = {"terrain": "fh", "variant": "city_center"}
	var dv0: Dictionary = ed.derived_locations()
	var dloc: Dictionary = (dv0["by_cell"] as Dictionary).get(Vector2i(2, 2), {})
	ck((dv0["list"] as Array).size() == 1 and str(dloc.get("id", "")) == "city_c2_r2", "画瓦片即地点（兜底 id）")
	ck(str(dloc.get("type", "")) == "city" and str(dloc.get("label", "")) == LocationDB.type_label("city"), "类型/名字由瓦片推导")
	ed._active_loc_cell = Vector2i(2, 2)
	ed._set_loc_field("label", "试炼城")
	ck(ed.map_locations.size() == 1 and str(ed.map_locations[0].get("label", "")) == "试炼城", "表单回写物化注记")
	ed._set_loc_field("id", "city_trial")
	var dloc2: Dictionary = (ed.derived_locations()["by_cell"] as Dictionary).get(Vector2i(2, 2), {})
	ck(str(dloc2.get("id", "")) == "city_trial" and str(dloc2.get("label", "")) == "试炼城", "注记 id/label 覆盖兜底")
	ed.tiles[3][3] = {"terrain": "fh", "variant": "barbarian_encampment"}
	var dloc3: Dictionary = (ed.derived_locations()["by_cell"] as Dictionary).get(Vector2i(3, 3), {})
	ck(str(dloc3.get("type", "")) == "lair" and str(dloc3.get("battle_map", "")) == "res://maps/sandbox.json", "site 型兜底可打图")
	ed._loc_remove(2, 2)
	ck(ed.map_locations.is_empty() and (ed.derived_locations()["by_cell"] as Dictionary).has(Vector2i(2, 2)), "删注记不删地点（回兜底）")
	ed.undo()
	ck(ed.map_locations.size() == 1, "删注记可撤销")
	ed.tiles[3][3] = {"terrain": "plain", "variant": "grassland"}   # 铲掉营地瓦片（注记在 (2,2)，不受影响）
	ed.tiles[2][2] = {"terrain": "plain", "variant": "grassland"}   # 铲掉城市瓦片 → (2,2) 注记成孤儿
	var dv1: Dictionary = ed.derived_locations()
	ck((dv1["orphans"] as Array).size() == 1 and not (dv1["by_cell"] as Dictionary).has(Vector2i(2, 2)), "铲瓦片→注记成孤儿")
	ed.tiles[2][2] = {"terrain": "fh", "variant": "city_center"}   # 补画回去（后续断言以 1 条注记为基）
	# 快照含 map_type：撤销跨类型切换不丢
	ck(str(ed._snapshot().get("map_type", "")) == "overworld", "快照含 map_type")
	# 存盘往返：to_json_dict 带全部新字段
	var d := ed.to_json_dict()
	var norm := MapIO.normalize(d)
	ck((norm["rivers"] as Array).size() == 1 and (norm["roads"] as Array).size() == 1 and (norm["locations"] as Array).size() == 1, "编辑器存盘往返（试玩直传同形；locations=注记）")
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
	ck(ed.map_locations.size() == 1 and ed.map_rivers.size() == 1 and ed.map_roads.size() == 1, "回滚：地点注记/线特征层")
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

	# 10) 编辑器批次 2026-07-13：§8 单位拖移/取样复制 + §30 尺寸调整逐层钳制 + §13/§19/§20 纯逻辑
	var e3 = MapEditorScript.new()
	e3._load_terrains()
	e3.new_map(6, 6)
	e3.map_units = [
		{"proto": {"id": "ua", "name": "甲"}, "col": 1, "row": 1, "faction": "enemy"},
		{"proto": {"id": "ub", "name": "乙"}, "col": 2, "row": 2, "faction": "player"},
	]
	# §8 拖移：首格锁 move（headless 无 Ctrl）→ 拖到空格＝挪格，一次拖动一步撤销，proto 不丢
	var undo_before: int = e3._undo_stack.size()
	e3.begin_stroke()
	e3._unit_paint(1, 1)
	e3._unit_paint(3, 1)
	e3._unit_paint(4, 2)
	e3.end_stroke()
	ck(int(e3.map_units[0]["col"]) == 4 and int(e3.map_units[0]["row"]) == 2, "§8 拖移落点 (4,2)")
	ck(str((e3.map_units[0]["proto"] as Dictionary).get("name", "")) == "甲", "§8 拖移不丢 proto 数据")
	ck(e3._undo_stack.size() == undo_before + 1, "§8 一次拖动＝一步撤销")
	e3.undo()
	ck(int(e3.map_units[0]["col"]) == 1 and int(e3.map_units[0]["row"]) == 1, "§8 拖移撤销回原位")
	e3.redo()
	# §8 拖到已占格＝拒绝（继续拖到空格落下）
	e3.begin_stroke()
	e3._unit_paint(4, 2)
	e3._unit_paint(2, 2)   # 乙占着 → 拒绝
	ck(int(e3.map_units[0]["col"]) == 4 and int(e3.map_units[0]["row"]) == 2, "§8 拖到已占格拒绝")
	e3._unit_paint(3, 3)
	e3.end_stroke()
	ck(int(e3.map_units[0]["col"]) == 3 and int(e3.map_units[0]["row"]) == 3, "§8 拒绝后继续拖到空格")
	ck(int(e3.map_units[1]["col"]) == 2 and int(e3.map_units[1]["row"]) == 2, "§8 被占单位不动")
	# §8 Ctrl 取样复制：深拷 proto 成当前笔刷（隔离），再落子＝副本
	e3._sample_unit(1)
	ck(str((e3._unit_proto as Dictionary).get("id", "")) == "ub" and e3._unit_faction == "player", "§8 取样得 proto+阵营")
	e3._unit_proto["name"] = "乙改"
	ck(str((e3.map_units[1]["proto"] as Dictionary).get("name", "")) == "乙", "§8 取样深拷贝隔离")
	e3.begin_stroke()
	e3._unit_paint(5, 5)   # 空格 → place（放取样副本）
	e3.end_stroke()
	ck(e3.map_units.size() == 3 and str((e3.map_units[2]["proto"] as Dictionary).get("name", "")) == "乙改" \
		and str(e3.map_units[2]["faction"]) == "player", "§8 取样后连放副本")
	e3.free()

	# §30 尺寸调整：裁剪逐层钳制 + 一步撤销全量回退 + 扩图铺草原
	var e4 = MapEditorScript.new()
	e4._load_terrains()
	e4.new_map(6, 6)
	e4.map_type = "overworld"
	e4.tiles[5][5] = {"terrain": "mountain", "variant": "mountain"}
	e4.regions = [{"id": "r1", "label": "区", "color": "#FFFFFF", "kind": "aggro", "cells": {Vector2i(1, 1): true, Vector2i(5, 5): true}}]
	e4.map_units = [{"proto": {"id": "u1"}, "col": 1, "row": 1, "faction": "enemy"}, {"proto": {"id": "u2"}, "col": 5, "row": 2, "faction": "enemy"}]
	e4.map_locations = [{"col": 2, "row": 2, "label": "内"}, {"col": 5, "row": 5, "label": "外"}]
	e4.map_rivers = [{"id": "r", "label": "河", "pairs": [[[1, 1], [1, 2]], [[5, 4], [5, 5]]]}]
	e4.map_bridges = [[[1, 1], [1, 2]], [[5, 4], [5, 5]]]
	e4.map_triggers = [{"id": "t1", "label": "触", "when": {"event": "enter_region"}, "do": [{"action": "spawn_unit", "col": 5, "row": 5}]}]
	e4.resize_map(4, 4)
	ck(e4.width == 4 and e4.height == 4 and e4.tiles.size() == 4 and (e4.tiles[0] as Array).size() == 4, "§30 裁剪后尺寸/tiles 4×4")
	ck(e4.map_units.size() == 1 and int(e4.map_units[0]["col"]) == 1, "§30 出界单位删除、界内保留")
	ck((e4.regions[0]["cells"] as Dictionary).size() == 1 and (e4.regions[0]["cells"] as Dictionary).has(Vector2i(1, 1)), "§30 区域出界格过滤")
	ck(e4.map_locations.size() == 1 and int(e4.map_locations[0]["col"]) == 2, "§30 出界地点注记删除")
	ck(((e4.map_rivers[0] as Dictionary)["pairs"] as Array).size() == 1 and (e4.map_bridges as Array).size() == 1, "§30 出界线特征格对丢弃")
	var act0: Dictionary = (e4.map_triggers[0]["do"] as Array)[0]
	ck(int(act0["col"]) == 3 and int(act0["row"]) == 3, "§30 触发器 spawn 坐标钳入界内")
	e4.undo()
	ck(e4.width == 6 and e4.map_units.size() == 2 and e4.map_locations.size() == 2 \
		and ((e4.map_rivers[0] as Dictionary)["pairs"] as Array).size() == 2 and (e4.map_bridges as Array).size() == 2, "§30 一步撤销全量回退")
	ck(int(((e4.map_triggers[0]["do"] as Array)[0] as Dictionary)["col"]) == 5, "§30 撤销回退触发器坐标")
	e4.resize_map(8, 8)
	ck(e4.width == 8 and str((e4.tiles[7][7] as Dictionary)["terrain"]) == "plain", "§30 扩图新格铺草原")
	ck(str((e4.tiles[5][5] as Dictionary)["terrain"]) == "mountain", "§30 扩图保留原内容")
	ck(str(e4.map_type) == "overworld", "§30 尺寸调整不动 map_type")
	e4.free()

	# §13 静默保存 + §19 全局地形脏旗 + §20 原型过滤 + §8 地点移注记（纯逻辑）
	var e5 = MapEditorScript.new()
	e5._load_terrains()
	e5.new_map(3, 3)
	e5.current_path = TMP_SAVE
	e5._dirty = true
	e5._save_shortcut()   # §13：有路径＝直接写盘（不再弹确认——headless 直调可过即证明无对话框依赖）
	ck(FileAccess.file_exists(TMP_SAVE) and not e5._dirty, "§13 Ctrl+S 静默保存写盘+清脏")
	DirAccess.remove_absolute(TMP_SAVE)
	e5._terr_scope = "global"
	e5._terr_edit_touched()
	ck(e5._terr_global_dirty, "§19 全局地形改动标脏")
	e5._terr_global_dirty = false
	e5._dirty = false
	e5._terr_scope = "map"
	e5._terr_edit_touched()
	ck(not e5._terr_global_dirty and e5._dirty, "§19 本图范围只标地图脏、不动全局旗")
	e5._unit_protos = [
		{"id": "empire_infantry", "name": "帝国步兵", "level": 1, "race": "human", "default_faction": "enemy"},
		{"id": "belooz", "name": "比路兹", "level": 5, "race": "harpy", "default_faction": "player"},
	]
	e5._unit_filter = "帝国"
	ck(e5._unit_rows_filtered() == [0], "§20 过滤：中文名匹配")
	e5._unit_filter = "belooz"
	ck(e5._unit_rows_filtered() == [1], "§20 过滤：id 匹配")
	e5._unit_filter = "lv5"
	ck(e5._unit_rows_filtered() == [1], "§20 过滤：等级文本匹配（大小写不敏感）")
	e5._unit_filter = ""
	ck(e5._unit_rows_filtered().size() == 2, "§20 空过滤＝全部")
	ck(e5._unit_row_text(e5._unit_protos[0]).contains("Lv1"), "§20 行文本含等级")
	# §8 地点移注记：注记搬格（含撤销）；目标已有注记拒绝
	e5.map_locations = [{"col": 1, "row": 1, "id": "loc_a", "label": "甲"}, {"col": 2, "row": 2, "id": "loc_b"}]
	e5._active_loc_cell = Vector2i(1, 1)
	e5._loc_move_ann_to(2, 2)
	ck(int(e5.map_locations[0]["col"]) == 1, "§8 移注记：目标已有注记拒绝")
	e5._loc_move_ann_to(0, 2)
	ck(int(e5.map_locations[0]["col"]) == 0 and int(e5.map_locations[0]["row"]) == 2 \
		and str(e5.map_locations[0]["id"]) == "loc_a", "§8 移注记：搬格保注记内容")
	e5.undo()
	ck(int(e5.map_locations[0]["col"]) == 1, "§8 移注记可撤销")
	e5.free()

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
