extends RefCounted
## 海格内的连续坡岸：共边保持陆岸/河口高度，向海内降至海床。
## 地表、查询与裁水共用同一细分网格；只生成几何，不附加材质或碰撞。

const HexGrid := preload("res://HexGrid.gd")
const SUBDIVISIONS := 8
const SLOPE_WIDTH := 0.85
const SQRT3 := 1.7320508075688772
const SAMPLE_SNAP := 100000.0
const EDGE_EPSILON := 0.00002
const NORMAL_STEP := 0.015

var _base_height := 0.25
var _centers: Dictionary = {}
var _sea_beds: Array[Dictionary] = []
var _edges: Array[Dictionary] = []
var _river_height: Callable
var _breakpoints := PackedVector2Array()
var _samples: Dictionary = {}
var _meshes: Dictionary = {}
var _water_meshes: Dictionary = {}
var _triangles: Dictionary = {}


func configure(cells: Dictionary, centers: Dictionary, base_height: float,
		river_height: Callable, river_breakpoints: PackedVector2Array = PackedVector2Array()) -> void:
	_base_height = base_height
	_centers = centers.duplicate()
	_river_height = river_height
	_breakpoints = river_breakpoints.duplicate()
	_sea_beds.clear()
	_edges.clear()
	_samples.clear()
	_meshes.clear()
	_water_meshes.clear()
	_triangles.clear()
	for cell: Vector2i in cells:
		if str(cells[cell].terrain) != "sea":
			continue
		var center: Vector2 = centers[cell]
		_sea_beds.append({"center": center, "height": float(cells[cell].bed_height)})
		for neighbor: Vector2i in HexGrid.neighbors(cell):
			if not cells.has(neighbor) or str(cells[neighbor].terrain) not in ["grass", "forest", "river"]:
				continue
			var direction: Vector2 = (Vector2(centers[neighbor]) - center).normalized()
			for side in range(6):
				var a := _corner(side)
				var b := _corner((side + 1) % 6)
				if ((a + b) * 0.5).normalized().dot(direction) < 0.99:
					continue
				_edges.append({"a": _snapped(center + a), "b": _snapped(center + b),
					"river": str(cells[neighbor].terrain) == "river", "cell": neighbor})
				break


func mesh_for(cell: Vector2i) -> ArrayMesh:
	if _meshes.has(cell):
		return _meshes[cell]
	if not _centers.has(cell):
		return ArrayMesh.new()
	var center: Vector2 = _centers[cell]
	var unique: Dictionary = {}
	for side in range(6):
		var a := _corner(side)
		var b := _corner((side + 1) % 6)
		for i in range(SUBDIVISIONS + 1):
			for j in range(SUBDIVISIONS - i + 1):
				var point := center + (a * float(i) + b * float(j)) / float(SUBDIVISIONS)
				unique[_key(point)] = _snapped(point)
	# 河口的岸顶、床底及水线折点作为真实顶点，避免三角形跨过折线。
	for point in _breakpoints:
		if _inside_hex(point - center):
			unique[_key(point)] = _snapped(point)
	var points := PackedVector2Array()
	for point: Vector2 in unique.values():
		points.append(point)
	var indices := Geometry2D.triangulate_delaunay(points)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var triangles := PackedVector3Array()
	for i in range(0, indices.size(), 3):
		var a := _sample(points[indices[i]])
		var b := _sample(points[indices[i + 1]])
		var c := _sample(points[indices[i + 2]])
		var pa: Vector3 = a.point
		var pb: Vector3 = b.point
		var pc: Vector3 = c.point
		var cross := Vector2(pb.x - pa.x, pb.z - pa.z).cross(Vector2(pc.x - pa.x, pc.z - pa.z))
		if absf(cross) < 0.00000001:
			continue
		# XZ 正绕序从上方看为 Godot 的顺时针正面。
		for vertex: Dictionary in ([a, b, c] if cross > 0.0 else [a, c, b]):
			var at: Vector3 = vertex.point
			surface.set_normal(vertex.normal)
			surface.set_uv(Vector2(at.x, at.z))
			surface.add_vertex(at)
			triangles.append(at)
	var mesh := surface.commit()
	_meshes[cell] = mesh
	_triangles[cell] = triangles
	return mesh


func water_mesh_for(cell: Vector2i, water_level: float = 0.0) -> ArrayMesh:
	var key := Vector3(cell.x, cell.y, water_level)
	if _water_meshes.has(key):
		return _water_meshes[key]
	mesh_for(cell)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var triangles: PackedVector3Array = _triangles.get(cell, PackedVector3Array())
	var count := 0
	for i in range(0, triangles.size(), 3):
		var polygon := _clip_below(PackedVector3Array([triangles[i], triangles[i + 1], triangles[i + 2]]), water_level)
		for j in range(1, polygon.size() - 1):
			var a := polygon[0]
			var b := polygon[j]
			var c := polygon[j + 1]
			if absf(Vector2(b.x - a.x, b.z - a.z).cross(Vector2(c.x - a.x, c.z - a.z))) < 0.00000001:
				continue
			for point: Vector3 in [a, b, c]:
				surface.set_normal(Vector3.UP)
				surface.set_uv(Vector2(point.x, point.z))
				surface.add_vertex(Vector3(point.x, water_level, point.z))
			count += 1
	var mesh := surface.commit() if count > 0 else ArrayMesh.new()
	_water_meshes[key] = mesh
	return mesh


func height_at(cell: Vector2i, point: Vector2) -> float:
	mesh_for(cell)
	var triangles: PackedVector3Array = _triangles.get(cell, PackedVector3Array())
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
	return _height_field(point)


func _height_field(point: Vector2) -> float:
	var bed := _seabed_height(point)
	var total := 0.0
	var weights := 0.0
	var nearest := SLOPE_WIDTH
	for edge: Dictionary in _edges:
		var a: Vector2 = edge.a
		var span: Vector2 = edge.b - a
		var t := clampf((point - a).dot(span) / span.length_squared(), 0.0, 1.0)
		var foot := a + span * t
		var distance := point.distance_to(foot)
		if distance >= SLOPE_WIDTH:
			continue
		var height := float(_river_height.call(edge.cell, foot)) if edge.river else _base_height
		if distance <= EDGE_EPSILON:
			return height
		nearest = minf(nearest, distance)
		var fraction := distance / SLOPE_WIDTH
		var weight := pow(1.0 - fraction, 2.0) / (distance * distance)
		total += height * weight
		weights += weight
	if weights <= 0.0:
		return bed
	var blend := nearest / SLOPE_WIDTH
	blend = blend * blend * (3.0 - 2.0 * blend)
	return lerpf(total / weights, bed, blend)


func _seabed_height(point: Vector2) -> float:
	var total := 0.0
	var weights := 0.0
	for bed: Dictionary in _sea_beds:
		var distance_squared := point.distance_squared_to(bed.center)
		if distance_squared < 0.000000001:
			return bed.height
		var fraction := distance_squared / 9.0
		if fraction >= 1.0:
			continue
		var weight := pow(1.0 - fraction, 2.0) / distance_squared
		total += float(bed.height) * weight
		weights += weight
	return total / weights if weights > 0.0 else -0.48


func _sample(point: Vector2) -> Dictionary:
	var key := _key(point)
	if _samples.has(key):
		return _samples[key]
	var at := Vector2(key) / SAMPLE_SNAP
	var height := _height_field(at)
	var dx := _height_field(at + Vector2(NORMAL_STEP, 0)) - _height_field(at - Vector2(NORMAL_STEP, 0))
	var dz := _height_field(at + Vector2(0, NORMAL_STEP)) - _height_field(at - Vector2(0, NORMAL_STEP))
	var sample := {"point": Vector3(at.x, height, at.y),
		"normal": Vector3(-dx, 2.0 * NORMAL_STEP, -dz).normalized()}
	_samples[key] = sample
	return sample


static func _clip_below(polygon: PackedVector3Array, level: float) -> PackedVector3Array:
	var result := PackedVector3Array()
	for i in range(polygon.size()):
		var a := polygon[i]
		var b := polygon[(i + 1) % polygon.size()]
		var inside_a := a.y <= level
		var inside_b := b.y <= level
		if inside_a:
			result.append(a)
		if inside_a != inside_b:
			result.append(a.lerp(b, (level - a.y) / (b.y - a.y)))
	return result


static func _inside_hex(local: Vector2) -> bool:
	return absf(local.y) <= SQRT3 * 0.5 + EDGE_EPSILON and absf(local.x) + absf(local.y) / SQRT3 <= 1.0 + EDGE_EPSILON


static func _key(point: Vector2) -> Vector2i:
	return Vector2i(roundi(point.x * SAMPLE_SNAP), roundi(point.y * SAMPLE_SNAP))


static func _snapped(point: Vector2) -> Vector2:
	return Vector2(_key(point)) / SAMPLE_SNAP


static func _corner(index: int) -> Vector2:
	return [Vector2(1, 0), Vector2(0.5, SQRT3 * 0.5), Vector2(-0.5, SQRT3 * 0.5),
		Vector2(-1, 0), Vector2(-0.5, -SQRT3 * 0.5), Vector2(0.5, -SQRT3 * 0.5)][index]
