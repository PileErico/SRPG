extends RefCounted
## 固定种子的 91 格地域样板；仅提供视觉布局，不连接正式地图或战役状态。
## 坐标为 flat-top / odd-q。河流自北向南，道路只在中心桥跨河。

const HexGrid := preload("res://HexGrid.gd")
const CENTER := Vector2i(7, 6)
const RADIUS := 5
const SEED := 1109
const SQRT3 := 1.7320508075688772
const PLAIN_HEIGHT := 0.25
const RIVER_BED := -0.24
const SEA_BED := -0.48
const DEEP_SEA_BED := -0.62
const PARTY_CELL := Vector2i(3, 9)
const RIVER_SOURCE := Vector2i(7, 0)
const RIVER_OUTLET := Vector2i(8, 9)
const RIVER_PATH := [
	Vector2i(7, 1), Vector2i(7, 2), Vector2i(6, 3), Vector2i(5, 3),
	Vector2i(5, 4), Vector2i(6, 5), Vector2i(7, 5), Vector2i(7, 6),
	Vector2i(7, 7), Vector2i(8, 8),
]
const VILLAGES := {
	Vector2i(3, 6): "松风村",
	Vector2i(10, 6): "苔丘村",
	Vector2i(5, 9): "海角村",
}


static func build() -> Dictionary:
	var cells: Dictionary = {}
	var river_cells: Array = RIVER_PATH.duplicate()
	var random := RandomNumberGenerator.new()
	random.seed = SEED
	for row in range(CENTER.y - RADIUS, CENTER.y + RADIUS + 1):
		for col in range(CENTER.x - RADIUS, CENTER.x + RADIUS + 1):
			var cell := Vector2i(col, row)
			if HexGrid.distance(CENTER, cell) > RADIUS:
				continue
			var point := Vector2(1.5 * float(col - CENTER.x),
				SQRT3 * (float(row - CENTER.y) + 0.5 * float((col & 1) - (CENTER.x & 1))))
			var terrain := _land_terrain(point, random.randf_range(-0.16, 0.16))
			if _is_sea(cell):
				terrain = "sea"
			elif river_cells.has(cell):
				terrain = "river"
			var height := SEA_BED if terrain == "sea" else PLAIN_HEIGHT
			cells[cell] = {
				"terrain": terrain, "height": height,
				"bed_height": RIVER_BED if terrain == "river" else height,
				"water_level": 0.0, "road": false,
				"location": VILLAGES.get(cell, ""), "deep_water": false,
			}
	# 只有周围没有陆地的海格使用深海；河口仍保留浅海色。
	for cell: Vector2i in cells:
		if cells[cell].terrain != "sea":
			continue
		var coastal := false
		for neighbor: Vector2i in HexGrid.neighbors(cell):
			if cells.has(neighbor) and cells[neighbor].terrain != "sea":
				coastal = true
				break
		cells[cell].deep_water = not coastal
		if not coastal:
			cells[cell].height = DEEP_SEA_BED
			cells[cell].bed_height = DEEP_SEA_BED
	var main_road: Array[Vector2i] = []
	for col in range(2, 13):
		main_road.append(Vector2i(col, 6))
	var road_paths: Array = [main_road, [
		Vector2i(4, 6), Vector2i(4, 7), Vector2i(4, 8),
		Vector2i(4, 9), Vector2i(5, 9), Vector2i(6, 9),
	]]
	for path: Array in road_paths:
		for i in range(path.size()):
			var cell: Vector2i = path[i]
			assert(cells.has(cell), "Every road region must exist in the sample")
			assert(cells[cell].terrain not in ["sea", "mountains"], "Roads follow lowland corridors")
			assert(cells[cell].terrain != "river" or cell == CENTER, "Only the central bridge crosses water")
			if i > 0:
				assert(HexGrid.adjacent(path[i - 1], cell), "Road regions share an edge")
			cells[cell].road = true
			# 道路经过的低地留出完整开敞走廊，避免弯道穿过树群。
			if cell != CENTER:
				cells[cell].terrain = "grass"
	cells[PARTY_CELL].terrain = "grass"
	assert(HexGrid.adjacent(RIVER_SOURCE, river_cells.front()) and not cells.has(RIVER_SOURCE))
	assert(HexGrid.adjacent(river_cells.back(), RIVER_OUTLET) and cells[RIVER_OUTLET].terrain == "sea")
	for i in range(river_cells.size()):
		assert(cells[river_cells[i]].terrain == "river")
		if i > 0:
			assert(HexGrid.adjacent(river_cells[i - 1], river_cells[i]))
	return {
		"cells": cells, "road_paths": road_paths, "river_cells": river_cells,
		"river_source": RIVER_SOURCE, "river_outlet": RIVER_OUTLET,
		"party_cell": PARTY_CELL, "title": "山海之间",
		"subtitle": "连绵山脉 · 曲折河谷 · 三村海湾",
	}


static func _land_terrain(point: Vector2, variation: float) -> String:
	# 缓弯的北部山脉及两侧丘陵带；小变化只修饰边缘，不制造散点山峰。
	var ridge_z := -6.2 + 0.055 * point.x * point.x + 0.28 * sin(point.x * 0.85)
	var ridge_distance := absf(point.y - ridge_z)
	if ridge_distance < 1.22 + variation:
		return "mountains"
	if ridge_distance < 2.65 + variation:
		return "hills"
	# 两片宽阔林地沿河谷两侧展开，中央与南侧保留平原空隙。
	var west := Vector2((point.x + 4.6) / 3.5, (point.y - 1.7) / 4.4).length_squared()
	var east := Vector2((point.x - 5.0) / 3.0, (point.y - 0.4) / 3.0).length_squared()
	var forest_edge := 1.0 + 0.13 * sin(point.y * 1.1 + point.x * 0.6) + variation
	if minf(west, east) < forest_edge:
		return "forest"
	return "grass"


static func _is_sea(cell: Vector2i) -> bool:
	if cell.x <= 4:
		return cell.y >= 11
	if cell.x <= 6:
		return cell.y >= 10
	if cell.x <= 8:
		return cell.y >= 9
	return cell.y >= 8
