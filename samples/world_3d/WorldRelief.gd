extends RefCounted
## 连续世界地貌：陆地有小幅共同基础起伏，丘山在其上按邻域形成高地。
## mesh_for 的顶点使用世界 XZ 与绝对 Y，可挂在原点；height_at 返回实际三角面插值。
## 仅生成地表，不附加材质、描边、侧壁、河槽或碰撞。

const SUBDIVISIONS := 8
const SQRT3 := 1.7320508075688772
const EDGE_FADE := 0.55
const LOWLAND_MAX_RISE := 0.12
const LOWLAND_NEIGHBOR_RESPONSE := 0.06
const HILL_RISE := 0.18
const HILL_MIN_RISE := 0.10
const HILL_MAX_RISE := 0.40
const MOUNTAIN_BASE_RISE := 2.40
const MOUNTAIN_MIN_RISE := 0.75
const MOUNTAIN_FOOT_RATIO := 0.08
const MOUNTAIN_PEAK_RADIUS := 1.10
const MOUNTAIN_RIDGE_WIDTH := 0.60
const MOUNTAIN_SADDLE_RATIO := 0.65
const SAMPLE_SNAP := 100000.0
const NORMAL_STEP := 0.025
const HexGrid := preload("res://HexGrid.gd")

var _base_height := 0.25
var _centers: Dictionary = {}
var _flat_centers: Array[Vector2] = []
var _hill_centers: Array[Vector2] = []
var _water_centers: Array[Vector2] = []
var _sources: Array[Dictionary] = []
var _profiles: Dictionary = {}
var _ridges: Array[Dictionary] = []
var _samples: Dictionary = {}
var _meshes: Dictionary = {}
var _triangles: Dictionary = {}


func configure(cells: Dictionary, centers: Dictionary, base_height: float) -> void:
	_base_height = base_height
	_centers = centers.duplicate()
	_flat_centers.clear()
	_hill_centers.clear()
	_water_centers.clear()
	_sources.clear()
	_profiles.clear()
	_ridges.clear()
	_samples.clear()
	_meshes.clear()
	_triangles.clear()
	var ordered := centers.keys()
	ordered.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.x < b.x or (a.x == b.x and a.y < b.y))
	for cell: Vector2i in ordered:
		var data: Dictionary = cells.get(cell, {})
		var terrain := str(data.get("terrain", "grass"))
		var center: Vector2 = centers[cell]
		if terrain == "river" or terrain == "sea":
			_flat_centers.append(center)
			_water_centers.append(center)
			continue
		var mountain := terrain == "mountains"
		var level := 2 if mountain else (1 if terrain == "hills" else 0)
		if level == 1:
			_hill_centers.append(center)
		elif level == 0:
			_flat_centers.append(center)
		var profile := _neighbor_profile(cell, cells, level)
		# 峰顶固定在格中心采样点，使实际峰高直接遵循邻域目标。
		var source := {"cell": cell, "center": center, "radius": 2.15, "mountain": mountain,
			"counts": profile.counts, "level": profile.level, "mean_level": profile.mean_level,
			"target_rise": profile.target_rise,
			"base_rise": clampf(LOWLAND_NEIGHBOR_RESPONSE * profile.mean_level, 0.0, LOWLAND_MAX_RISE)}
		_sources.append(source)
		_profiles[cell] = source
	for cell: Vector2i in ordered:
		if not _profiles.has(cell) or not _profiles[cell].mountain:
			continue
		for neighbor: Vector2i in HexGrid.neighbors(cell):
			if not _profiles.has(neighbor) or not _profiles[neighbor].mountain:
				continue
			if cell.x > neighbor.x or (cell.x == neighbor.x and cell.y >= neighbor.y):
				continue
			var a: Dictionary = _profiles[cell]
			var b: Dictionary = _profiles[neighbor]
			_ridges.append({"a": a.center, "b": b.center, "a_rise": a.target_rise, "b_rise": b.target_rise,
				"saddle": minf(a.target_rise, b.target_rise) * MOUNTAIN_SADDLE_RATIO})


func relief_profile(cell: Vector2i) -> Dictionary:
	if not _profiles.has(cell):
		return {}
	var source: Dictionary = _profiles[cell]
	return {"counts": source.counts.duplicate(), "level": source.level,
		"mean_level": source.mean_level, "target_rise": source.target_rise}


static func _neighbor_profile(cell: Vector2i, cells: Dictionary, level: int) -> Dictionary:
	var counts := {"low": 0, "hills": 0, "mountains": 0, "missing": 0}
	for neighbor: Vector2i in HexGrid.neighbors(cell):
		if not cells.has(neighbor):
			counts.missing += 1
			continue
		var terrain := str(cells[neighbor].get("terrain", "grass"))
		if terrain == "mountains":
			counts.mountains += 1
		elif terrain == "hills":
			counts.hills += 1
		else:
			counts.low += 1
	var present: int = 6 - counts.missing
	var mean_level := float(counts.hills + 2 * counts.mountains) / float(present) if present > 0 else float(level)
	var delta := mean_level - float(level)
	var target := 0.0
	if level == 0:
		target = clampf(LOWLAND_NEIGHBOR_RESPONSE * mean_level, 0.0, LOWLAND_MAX_RISE)
	elif level == 1:
		target = clampf(HILL_RISE + delta * (0.08 if delta < 0.0 else 0.22), HILL_MIN_RISE, HILL_MAX_RISE)
	else:
		target = clampf(MOUNTAIN_BASE_RISE + 0.825 * delta, MOUNTAIN_MIN_RISE, MOUNTAIN_BASE_RISE)
	return {"counts": counts, "level": level, "mean_level": mean_level, "target_rise": target}


func mesh_for(cell: Vector2i) -> ArrayMesh:
	if _meshes.has(cell):
		return _meshes[cell]
	if not _centers.has(cell):
		return ArrayMesh.new()
	var center: Vector2 = _centers[cell]
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var triangles := PackedVector3Array()
	for sector in range(6):
		var a := _corner(sector)
		var b := _corner((sector + 1) % 6)
		var points: Dictionary = {}
		for i in range(SUBDIVISIONS + 1):
			for j in range(SUBDIVISIONS - i + 1):
				var point := center + (a * float(i) + b * float(j)) / float(SUBDIVISIONS)
				points[Vector2i(i, j)] = _sample(point)
		for i in range(SUBDIVISIONS):
			for j in range(SUBDIVISIONS - i):
				_emit_triangle(surface, triangles, points[Vector2i(i, j)],
					points[Vector2i(i + 1, j)], points[Vector2i(i, j + 1)])
				if i + j < SUBDIVISIONS - 1:
					_emit_triangle(surface, triangles, points[Vector2i(i + 1, j)],
						points[Vector2i(i + 1, j + 1)], points[Vector2i(i, j + 1)])
	var mesh := surface.commit()
	_meshes[cell] = mesh
	_triangles[cell] = triangles
	return mesh


func height_at(cell: Vector2i, point: Vector2) -> float:
	if not _centers.has(cell):
		return _base_height
	if not _triangles.has(cell):
		mesh_for(cell)
	var triangles: PackedVector3Array = _triangles[cell]
	for i in range(0, triangles.size(), 3):
		var a := triangles[i]
		var b := triangles[i + 1]
		var c := triangles[i + 2]
		var u := Vector2(b.x - a.x, b.z - a.z)
		var v := Vector2(c.x - a.x, c.z - a.z)
		var p := point - Vector2(a.x, a.z)
		var determinant := u.cross(v)
		var weight_b := p.cross(v) / determinant
		var weight_c := u.cross(p) / determinant
		if weight_b >= -0.0001 and weight_c >= -0.0001 and weight_b + weight_c <= 1.0001:
			return a.y + (b.y - a.y) * weight_b + (c.y - a.y) * weight_c
	# 查询点略越过格边时仍给出同一全局地貌，不依赖调用格的类别权重。
	return _height_field(point)


func _sample(point: Vector2) -> Dictionary:
	var key := Vector2i(roundi(point.x * SAMPLE_SNAP), roundi(point.y * SAMPLE_SNAP))
	if _samples.has(key):
		return _samples[key]
	var at := Vector2(key) / SAMPLE_SNAP
	var height := _height_field(at)
	var dx := _height_field(at + Vector2(NORMAL_STEP, 0)) - _height_field(at - Vector2(NORMAL_STEP, 0))
	var dz := _height_field(at + Vector2(0, NORMAL_STEP)) - _height_field(at - Vector2(0, NORMAL_STEP))
	var sample := {"point": Vector3(at.x, height, at.y), "normal": Vector3(-dx, 2.0 * NORMAL_STEP, -dz).normalized()}
	_samples[key] = sample
	return sample


func _height_field(point: Vector2) -> float:
	var foundation := _foundation_rise(point) * _distance_fade(point, _water_centers)
	var fade := _boundary_fade(point)
	if fade <= 0.0:
		return _base_height + foundation
	var rise := 0.0
	for source in _sources:
		if source.level == 0:
			continue
		var center: Vector2 = source.center
		var distance := point.distance_to(center) / float(source.radius)
		if distance >= 1.0:
			continue
		var broad_profile := pow(1.0 - distance * distance, 2.0)
		var target: float = source.target_rise
		if source.mountain:
			# 山麓和尖峰都随同一目标变化；山麓只占少量高度，邻丘仍保持浅起伏。
			var peak_distance := clampf(point.distance_to(center) / MOUNTAIN_PEAK_RADIUS, 0.0, 1.0)
			var peak_profile := (1.0 - peak_distance) * (1.0 - peak_distance * peak_distance)
			rise = maxf(rise, target * (MOUNTAIN_FOOT_RATIO * broad_profile + (1.0 - MOUNTAIN_FOOT_RATIO) * peak_profile))
		else:
			rise = maxf(rise, target * broad_profile)
	var hill_edge_fade := _distance_fade(point, _hill_centers) if not _ridges.is_empty() else 1.0
	for ridge in _ridges:
		var a: Vector2 = ridge.a
		var span: Vector2 = ridge.b - a
		var t := clampf((point - a).dot(span) / span.length_squared(), 0.0, 1.0)
		var lateral := point.distance_to(a + span * t) / MOUNTAIN_RIDGE_WIDTH
		if lateral >= 1.0:
			continue
		var crest := lerpf(ridge.a_rise, ridge.saddle, t * 2.0) if t <= 0.5 else lerpf(ridge.saddle, ridge.b_rise, (t - 0.5) * 2.0)
		# 宽脊只连接山山格对，在丘陵边界淡出；max 合成不会叠出额外峰高。
		rise = maxf(rise, crest * pow(1.0 - lateral * lateral, 2.0) * hill_edge_fade)
	# 基础起伏与高地取较高者，避免相加后突破邻域目标的上下界。
	return _base_height + maxf(foundation, rise * fade)


func _foundation_rise(point: Vector2) -> float:
	var total := 0.0
	var weights := 0.0
	for source in _sources:
		var center: Vector2 = source.center
		var distance_squared := point.distance_squared_to(center)
		if distance_squared < 0.0000000001:
			return source.base_rise
		var fraction := distance_squared / (float(source.radius) * float(source.radius))
		if fraction >= 1.0:
			continue
		var weight := pow(1.0 - fraction, 2.0) / distance_squared
		total += float(source.base_rise) * weight
		weights += weight
	return total / weights if weights > 0.0 else 0.0


func _boundary_fade(point: Vector2) -> float:
	return _distance_fade(point, _flat_centers)


static func _distance_fade(point: Vector2, flat_centers: Array[Vector2]) -> float:
	var nearest := EDGE_FADE
	for center in flat_centers:
		var local := point - center
		if local.length_squared() > (1.0 + EDGE_FADE) * (1.0 + EDGE_FADE):
			continue
		if absf(local.y) <= SQRT3 * 0.5 + 0.00001 and absf(local.x) + absf(local.y) / SQRT3 <= 1.00001:
			return 0.0
		for edge in range(6):
			var a := _corner(edge)
			var b := _corner((edge + 1) % 6)
			var span := b - a
			var t := clampf((local - a).dot(span) / span.length_squared(), 0.0, 1.0)
			nearest = minf(nearest, local.distance_to(a + span * t))
	var t := nearest / EDGE_FADE
	return t * t * (3.0 - 2.0 * t)


static func _corner(index: int) -> Vector2:
	# 显式六角顶点，避免三角函数在相邻格产生不同的共边浮点结果。
	return [Vector2(1, 0), Vector2(0.5, SQRT3 * 0.5), Vector2(-0.5, SQRT3 * 0.5),
		Vector2(-1, 0), Vector2(-0.5, -SQRT3 * 0.5), Vector2(0.5, -SQRT3 * 0.5)][index]


static func _emit_triangle(surface: SurfaceTool, triangles: PackedVector3Array, a: Dictionary, b: Dictionary, c: Dictionary) -> void:
	# XZ 逆时针对应 Godot 从上方观察的顺时针正面。
	for vertex in [a, b, c]:
		var point: Vector3 = vertex.point
		surface.set_normal(vertex.normal)
		surface.set_uv(Vector2(point.x, point.z))
		surface.add_vertex(point)
		triangles.append(point)
