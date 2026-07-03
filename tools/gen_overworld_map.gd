extends SceneTree
## 一次性生成默认大地图 res://maps/overworld/world.json（可重跑覆盖；手感不满意直接用地图编辑器改）。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/gen_overworld_map.gd
## v4 起线特征转正：道路＝overlay 格对（不再吞整格地形）、河＝边线（行带分隔边收集，天然蜿蜒）、桥＝河上豁免点。

const MapIO := preload("res://MapIO.gd")
const HexGrid := preload("res://HexGrid.gd")

const W := 24
const H := 16

func _initialize() -> void:
	var tiles := []
	for r in H:
		var line := []
		for c in W:
			line.append({"terrain": "plain", "variant": "grassland"})
		tiles.append(line)
	for r in H:   # 西侧南北山脉（col 3~4）
		for c in [3, 4]:
			tiles[r][c] = {"terrain": "mountain", "variant": "mountain"}
	tiles[8][3] = {"terrain": "hill", "variant": "hill"}   # row 8 山口（接道路）
	tiles[8][4] = {"terrain": "hill", "variant": "hill"}
	for r in range(1, 5):   # 东北湖：浅水圈
		for c in range(17, 22):
			tiles[r][c] = {"terrain": "water", "variant": "shallow"}
	for r in range(2, 4):   # 湖心深水（空 tags 队伍不可入＝天然屏障）
		for c in range(18, 21):
			tiles[r][c] = {"terrain": "water", "variant": "deep"}
	for r in range(9, 13):   # 南森林
		for c in range(7, 11):
			tiles[r][c] = {"terrain": "forest", "variant": "forest"}
	for r in range(3, 6):    # 北森林
		for c in range(10, 14):
			tiles[r][c] = {"terrain": "forest", "variant": "forest"}
	for r in range(13, H):   # 东南沙地
		for c in range(16, W):
			tiles[r][c] = {"terrain": "sand", "variant": "sand"}
	for r in range(11, 13):  # 南林东侧湿地（新地形展示：沼泽）
		for c in range(14, 16):
			tiles[r][c] = {"terrain": "swamp", "variant": "swamp"}
	for c in range(5, 9):    # 城郊农田（新地形展示；沿大道北侧一线，不吃南森林）
		tiles[7][c] = {"terrain": "farmland", "variant": "farmland"}
	tiles[9][5] = {"terrain": "farmland", "variant": "farmland"}
	tiles[9][6] = {"terrain": "farmland", "variant": "farmland"}

	# —— 边线河：rows 5/6 之间自西向东（col 6→19，湖口收尾）。
	# 行带分隔边收集：上带（row≤5）与下带（row≥6）之间的所有相邻格对——含奇数列斜边，天然蜿蜒连续。
	var river_pairs := []
	for c in range(6, 20):
		var top := Vector2i(c, 5)
		for nb in HexGrid.neighbors(top):
			if nb.y == 6 and nb.x >= 6 and nb.x <= 19:
				river_pairs.append([[top.x, top.y], [nb.x, nb.y]])

	# —— 道路 overlay：东西大道沿 row 8（col 3→23，穿山口贯东缘）＋ 北岔道 (13,8)→(13,5)→洛苇村 (15,5)。
	var road_cells := []
	for c in range(3, W):
		road_cells.append(Vector2i(c, 8))
	var road_pairs := _chain_pairs(road_cells)
	road_pairs.append_array(_chain_pairs([Vector2i(13, 8), Vector2i(13, 7), Vector2i(13, 6), Vector2i(13, 5), Vector2i(14, 5), Vector2i(15, 5)]))

	# —— 桥：北岔道过河点（河边 (13,5)-(13,6) 上）——
	var bridges := [[[13, 5], [13, 6]]]

	var rivers := [{"id": "river_main", "label": "界河", "pairs": river_pairs}]
	var roads := [{"id": "road_main", "label": "东西大道", "pairs": road_pairs}]

	var triggers := [
		{"id": "ow_merchant", "label": "游商", "when": {"event": "enter_tile", "once": false, "chance": 15, "cooldown_hours": 12},
			"do": [{"action": "dialogue", "dialogue_id": "dlg_merchant"}]},   # M8：大地图事件对话演示
		{"id": "ow_dawn", "label": "每日", "when": {"event": "timer", "every_hours": 24},
			"do": [{"action": "show_message", "text": "又是新的一天。"}]},
		{"id": "ow_ambush", "label": "劫道者", "when": {"event": "enter_tile", "col": 14, "row": 8, "once": false, "cooldown_hours": 24},
			"do": [{"action": "show_message", "text": "劫道者从路旁的灌木里窜了出来！"}, {"action": "start_battle", "map": "res://maps/sandbox.json"}]},
	]
	# 地点实例（M7；类型定义在 data/locations.json，运行时状态在 WorldState.location_cleared_at）。
	var locations := [
		{"id": "city_astra", "type": "city", "label": "阿斯特拉", "col": 8, "row": 8, "dialogue_id": "dlg_elder_astra"},
		{"id": "village_luowei", "type": "village", "label": "洛苇村", "col": 15, "row": 5},
		{"id": "ruin_sand", "type": "ruin", "label": "沙没之殿", "col": 20, "row": 14, "battle_map": "res://maps/sandbox.json"},
		{"id": "lair_bandit", "type": "lair", "label": "劫道者营地", "col": 11, "row": 11, "battle_map": "res://maps/sandbox.json"},
	]
	DirAccess.make_dir_recursive_absolute("res://maps/overworld")
	# environment 留空＝日夜不显式指定 → 消费端走「战役时钟推导」（M2 优先级的正确演示）
	var ok := MapIO.write_map("res://maps/overworld/world.json", W, H, tiles, {
		"triggers": triggers, "map_type": "overworld", "locations": locations,
		"rivers": rivers, "roads": roads, "bridges": bridges,
	})
	print("world.json 生成：", "OK" if ok else "FAILED")
	quit(0 if ok else 1)

# 格序列 → 相邻格对序列（非相邻的跳段用 HexGrid.line 补齐——防手写路点漏格）
func _chain_pairs(cells: Array) -> Array:
	var out := []
	for i in range(cells.size() - 1):
		var chain := [cells[i], cells[i + 1]] if HexGrid.adjacent(cells[i], cells[i + 1]) else HexGrid.line(cells[i], cells[i + 1])
		for j in range(chain.size() - 1):
			out.append([[chain[j].x, chain[j].y], [chain[j + 1].x, chain[j + 1].y]])
	return out
