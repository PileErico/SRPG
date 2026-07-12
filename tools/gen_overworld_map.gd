extends SceneTree
## 一次性生成默认大地图 res://maps/overworld/world.json（可重跑覆盖；手感不满意直接用地图编辑器改）。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/gen_overworld_map.gd
## v5（2026-07-12）：40×28 大世界——北境雪原/帝国腹地/南野密林/黄沙残境四区；双城三村双巢双遗迹；
## FantasyHex 风味瓦片转正（fh_* 城市/农场/营地/遗迹/野兽/矿点/灵泉——overworld_cost 已在 terrains.json 补齐）；
## regions 描边（区域解锁可视化预热）。v4 起线特征转正：道路＝overlay 格对、河＝边线、桥＝豁免点。
## ⚠ 测试地标同步：tools/test_overworld.gd 顶部 v5 常量、tools/test_worldsim.gd 全动态推导——改布局先对表。

const MapIO := preload("res://MapIO.gd")
const HexGrid := preload("res://HexGrid.gd")

const W := 40
const H := 28

# 基础地形 id → (terrain, variant)（fh_* 规则化：terrain="fh"、variant=去前缀）
const BASE := {
	"grassland": ["plain", "grassland"], "wasteland": ["plain", "wasteland"],
	"forest": ["forest", "forest"], "mountain": ["mountain", "mountain"], "hill": ["hill", "hill"],
	"shallow": ["water", "shallow"], "deep": ["water", "deep"],
	"sand": ["sand", "sand"], "snow": ["snow", "snow"], "tundra": ["tundra", "tundra"],
	"swamp": ["swamp", "swamp"], "farmland": ["farmland", "farmland"],
}

var tiles := []

func _initialize() -> void:
	for r in H:
		var line := []
		for c in W:
			line.append(_tile("grassland"))
		tiles.append(line)

	# ============ 大区块（先大后小，后画覆盖先画）============
	_fill_rect(0, 2, 0, H - 1, "wasteland")        # 西缘荒原条（山脉以西的边陲）
	_fill_rect(5, W - 1, 0, 4, "snow")             # 北境雪原（rows 0..4）
	_fill_rect(5, W - 1, 5, 5, "tundra")           # 冻原过渡带（row 5）
	_fill_rect(26, W - 1, 18, H - 1, "sand")       # 东南黄沙残境
	_fill_rect(24, 25, 18, H - 1, "wasteland")     # 沙漠西缘过渡
	_fill_rect(26, 31, 17, 17, "wasteland")        # 沙漠北缘过渡

	for r in range(0, 22):                          # 西侧南北山脉（cols 3~4），row 10 山口
		for c in [3, 4]:
			_put(c, r, "mountain")
	_put(3, 10, "hill")                             # 山口（接东西大道）
	_put(4, 10, "hill")
	for p in [[10, 1], [11, 1], [24, 0], [25, 1], [31, 0], [15, 0]]:   # 北缘散山
		_put(p[0], p[1], "mountain")

	_fill_rect(33, W - 1, 2, 7, "shallow")          # 东北大湖：浅水盘
	_fill_rect(35, 38, 3, 5, "deep")                # 湖心深水（空 tags 队伍不可入＝天然屏障）

	_fill_rect(6, 16, 17, 23, "forest")             # 南野密林（劫道者的地盘）
	_fill_rect(22, 26, 15, 16, "forest")            # 河南岸东林
	_fill_rect(19, 22, 15, 17, "swamp")             # 南岸湿地
	_fill_rect(6, 18, 24, H - 1, "wasteland")       # 极南荒原
	for p in [[8, 2], [9, 3], [14, 1], [15, 2], [26, 2], [27, 3]]:     # 雪原针叶林斑块
		_put(p[0], p[1], "fh_tundraforest")
	for p in [[13, 12], [14, 12], [13, 13], [25, 13], [26, 12], [12, 12]]:   # 腹地丘陵
		_put(p[0], p[1], "hill")

	# ============ 城郊农田 + 风味瓦片（fh_* 转正）============
	for p in [[8, 9], [10, 9], [8, 11], [10, 11], [7, 10], [11, 10]]:  # 阿斯特拉城郊
		_put(p[0], p[1], "farmland")
	for p in [[28, 9], [30, 9], [28, 11], [30, 11], [27, 10], [31, 10]]:   # 维林城郊
		_put(p[0], p[1], "farmland")
	_put(12, 9, "fh_grassland_farm")
	_put(6, 12, "fh_grassland_farm")
	_put(26, 9, "fh_grassland_farm")
	_put(22, 7, "fh_fountain_of_youth")             # 灵泉（全局事件「灵泉驻足」认这块地）
	_put(12, 7, "fh_fountain_of_youth")
	_put(16, 6, "fh_deer")                          # 野兽风味（兽群游荡区）
	_put(10, 18, "fh_deer")
	_put(24, 11, "fh_horses")
	_put(7, 13, "fh_bison")
	_put(9, 25, "fh_bison")
	_put(5, 9, "fh_copper")                         # 西山矿脉
	_put(14, 13, "fh_hillmine")
	_put(26, 13, "fh_iron")
	_put(30, 20, "fh_oasis")                        # 沙漠绿洲
	_put(36, 22, "fh_oasis")
	_put(28, 25, "fh_grand_mesa")                   # 沙漠地标：孤山台地
	_put(8, 16, "fh_lakes")                         # 内陆小湖
	_put(22, 24, "fh_lakes")

	# ============ 地点格（最后画，压过大区块）============
	_put(9, 10, "fh_city_center")                   # 阿斯特拉（西都）
	_put(29, 10, "fh_city_center_medieval_era")     # 维林（东都）
	_put(33, 8, "fh_grassland_farm")                # 洛苇村（湖畔）
	_put(16, 17, "fh_grassland_farm")               # 清溪村（南林北缘）
	_put(20, 3, "fh_snow_farm")                     # 寒风村（雪原）
	_put(12, 20, "fh_barbarian_encampment")         # 劫道者营地（南林深处）
	_put(28, 2, "fh_barbarian_encampment_snow")     # 雪原匪帮营地
	_put(33, 24, "fh_ancient_ruins_sand")           # 沙没之殿
	_put(7, 2, "fh_ancient_ruins_snow")             # 冰封遗迹

	# ============ 边线河：北河（雪原界河）+ 主河（南野界河）============
	var rivers := [
		{"id": "river_north", "label": "霜河", "pairs": _band_pairs(5, 12, 32)},
		{"id": "river_main", "label": "界河", "pairs": _band_pairs(13, 6, W - 1)},
	]

	# ============ 道路 overlay：东西大道 + 三条岔道 ============
	var road_cells := []
	for c in range(3, 30):                          # 东西大道沿 row 10（穿山口→东都）
		road_cells.append(Vector2i(c, 10))
	var road_pairs := _chain_pairs(road_cells)
	road_pairs.append_array(_chain_pairs([Vector2i(20, 10), Vector2i(20, 3)]))          # 北岔：寒风村（跨霜河）
	road_pairs.append_array(_chain_pairs([Vector2i(16, 10), Vector2i(16, 17)]))         # 南岔：清溪村（跨界河）
	road_pairs.append_array(_chain_pairs([Vector2i(29, 10), Vector2i(31, 9), Vector2i(33, 8)]))   # 东岔：洛苇村
	var roads := [{"id": "road_main", "label": "东西大道", "pairs": road_pairs}]

	# ============ 桥：路过河点 + 东都南渡口（无路野桥）============
	var bridges := [[[20, 5], [20, 6]], [[16, 13], [16, 14]], [[29, 13], [29, 14]]]

	var triggers := [
		{"id": "ow_merchant", "label": "游商", "when": {"event": "enter_tile", "once": false, "chance": 15, "cooldown_hours": 12},
			"do": [{"action": "dialogue", "dialogue_id": "dlg_merchant"}]},
		{"id": "ow_dawn", "label": "每日", "when": {"event": "timer", "every_hours": 24},
			"do": [{"action": "show_message", "text": "又是新的一天。"}]},
		{"id": "ow_ambush", "label": "劫道者", "when": {"event": "enter_tile", "col": 16, "row": 14, "once": false, "cooldown_hours": 24},
			"do": [{"action": "show_message", "text": "劫道者从桥头的苇丛里窜了出来！"}, {"action": "start_battle", "map": "res://maps/bandit_ambush.json"}]},
	]

	# 地点实例（M7；类型定义在 data/locations.json，运行时状态在 WorldState.location_cleared_at）
	var locations := [
		{"id": "city_astra", "type": "city", "label": "阿斯特拉", "col": 9, "row": 10, "dialogue_id": "dlg_elder_astra"},
		{"id": "city_veylin", "type": "city", "label": "维林", "col": 29, "row": 10},
		{"id": "village_luowei", "type": "village", "label": "洛苇村", "col": 33, "row": 8},
		{"id": "village_qingxi", "type": "village", "label": "清溪村", "col": 16, "row": 17},
		{"id": "village_hanfeng", "type": "village", "label": "寒风村", "col": 20, "row": 3},
		{"id": "lair_bandit", "type": "lair", "label": "劫道者营地", "col": 12, "row": 20, "battle_map": "res://maps/bandit_ambush.json"},
		{"id": "lair_snow", "type": "lair", "label": "雪原匪帮营地", "col": 28, "row": 2, "battle_map": "res://maps/bandit_ambush.json"},
		{"id": "ruin_sand", "type": "ruin", "label": "沙没之殿", "col": 33, "row": 24, "battle_map": "res://maps/sandbox.json"},
		{"id": "ruin_snow", "type": "ruin", "label": "冰封遗迹", "col": 7, "row": 2, "battle_map": "res://maps/sandbox.json"},
	]

	# regions 描边（纯视觉；区域解锁可视化预热——kind 留空＝非战斗语义）
	var regions := [
		{"id": "reg_north", "label": "北境雪原", "color": "#9FC7E8", "cells": _rect_cells(3, W - 1, 0, 5)},
		{"id": "reg_heart", "label": "帝国腹地", "color": "#E8C15A", "cells": _rect_cells(3, W - 1, 6, 13)},
		{"id": "reg_desert", "label": "黄沙残境", "color": "#D8B36A", "cells": _rect_cells(24, W - 1, 17, H - 1)},
	]

	DirAccess.make_dir_recursive_absolute("res://maps/overworld")
	# environment 留空＝日夜不显式指定 → 消费端走「战役时钟推导」（M2 优先级的正确演示）
	var ok := MapIO.write_map("res://maps/overworld/world.json", W, H, tiles, {
		"triggers": triggers, "map_type": "overworld", "locations": locations,
		"rivers": rivers, "roads": roads, "bridges": bridges, "regions": regions,
	})
	print("world.json 生成（v5 %d×%d）：%s" % [W, H, "OK" if ok else "FAILED"])
	quit(0 if ok else 1)

# ============ 小工具 ============

func _tile(id: String) -> Dictionary:
	if id.begins_with("fh_"):
		return {"terrain": "fh", "variant": id.trim_prefix("fh_")}
	var tv: Array = BASE[id]
	return {"terrain": tv[0], "variant": tv[1]}

func _put(c: int, r: int, id: String) -> void:
	tiles[r][c] = _tile(id)

func _fill_rect(c0: int, c1: int, r0: int, r1: int, id: String) -> void:
	for r in range(r0, r1 + 1):
		for c in range(c0, c1 + 1):
			tiles[r][c] = _tile(id)

func _rect_cells(c0: int, c1: int, r0: int, r1: int) -> Array:
	var out := []
	for r in range(r0, r1 + 1):
		for c in range(c0, c1 + 1):
			out.append([c, r])
	return out

# 行带分隔边收集：上带（row≤top）与下带（row=top+1）之间所有相邻格对——含奇数列斜边，天然蜿蜒连续
func _band_pairs(top: int, c_min: int, c_max: int) -> Array:
	var out := []
	for c in range(c_min, c_max + 1):
		var t := Vector2i(c, top)
		for nb in HexGrid.neighbors(t):
			if nb.y == top + 1 and nb.x >= c_min and nb.x <= c_max:
				out.append([[t.x, t.y], [nb.x, nb.y]])
	return out

# 格序列 → 相邻格对序列（非相邻的跳段用 HexGrid.line 补齐——防手写路点漏格）
func _chain_pairs(cells: Array) -> Array:
	var out := []
	for i in range(cells.size() - 1):
		var chain := [cells[i], cells[i + 1]] if HexGrid.adjacent(cells[i], cells[i + 1]) else HexGrid.line(cells[i], cells[i + 1])
		for j in range(chain.size() - 1):
			out.append([[chain[j].x, chain[j].y], [chain[j + 1].x, chain[j + 1].y]])
	return out
