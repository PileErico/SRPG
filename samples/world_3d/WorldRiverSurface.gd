extends RefCounted
## 河格的单份真实地表：河床、岸坡与岸顶在同一细分三角网中生成。
## 水面按这份网格裁切，高度查询也在同一三角面内插值。

const SUBDIVISIONS := 8
const SQRT3 := 1.7320508075688772
const SAMPLE_SNAP := 100000.0
const EDGE_EPSILON := 0.00002

var _centers: Dictionary = {}
var _ground_field: Callable
var _break_lines: Array = []
var _bed_level := -0.24
var _land_level := 0.25
var _water_level := 0.0
var _meshes: Dictionary = {}
var _water_meshes: Dictionary = {}
var _triangles: Dictionary = {}


func configure(cells: Dictionary, centers: Dictionary, ground_field: Callable,
		break_lines: Array, bed_level: float, land_level: float, water_level: float = 0.0) -> void:
	_centers.clear()
	for cell: Vector2i in cells:
		if str(cells[cell].terrain) == "river":
			_centers[cell] = centers[cell]
	_ground_field = ground_field
	_break_lines = break_lines.duplicate()
	_bed_level = bed_level
	_land_level = land_level
	_water_level = water_level
	_meshes.clear()
	_water_meshes.clear()
	_triangles.clear()


func mesh_for(cell: Vector2i) -> ArrayMesh:
	if _meshes.has(cell):
		return _meshes[cell]
	if not _centers.has(cell):
		return ArrayMesh.new()
	var center: Vector2 = _centers[cell]
	var unique: Dictionary = {}
	var hex := PackedVector2Array()
	for side in range(6):
		hex.append(_snapped(center + _corner(side)))
		var a := _corner(side)
		var b := _corner((side + 1) % 6)
		for i in range(SUBDIVISIONS + 1):
			for j in range(SUBDIVISIONS - i + 1):
				_add_point(unique, center + (a * float(i) + b * float(j)) / float(SUBDIVISIONS))
	# 岸顶/坡脚/水线及保留岸形的所有折点，均成为同一地表的真实顶点。
	for polygon: PackedVector2Array in _break_lines:
		for i in range(polygon.size()):
			var a := polygon[i]
			var b := polygon[(i + 1) % polygon.size()]
			if _inside_hex(a - center):
				_add_point(unique, a)
			for side in range(6):
				var hit: Variant = Geometry2D.segment_intersects_segment(a, b, hex[side], hex[(side + 1) % 6])
				if hit is Vector2:
					_add_point(unique, hit)
	var points := PackedVector2Array()
	var heights := PackedFloat32Array()
	for point: Vector2 in unique.values():
		points.append(point)
		heights.append(clampf(float(_ground_field.call(cell, point)), _bed_level, _land_level))
	var indices := Geometry2D.triangulate_delaunay(points)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var triangles := PackedVector3Array()
	for i in range(0, indices.size(), 3):
		var a := Vector3(points[indices[i]].x, heights[indices[i]], points[indices[i]].y)
		var b := Vector3(points[indices[i + 1]].x, heights[indices[i + 1]], points[indices[i + 1]].y)
		var c := Vector3(points[indices[i + 2]].x, heights[indices[i + 2]], points[indices[i + 2]].y)
		var cross := Vector2(b.x - a.x, b.z - a.z).cross(Vector2(c.x - a.x, c.z - a.z))
		if absf(cross) < 0.00000001:
			continue
		var normal := (c - a).cross(b - a).normalized()
		if normal.y < 0.0:
			normal = -normal
		for point: Vector3 in ([a, b, c] if cross > 0.0 else [a, c, b]):
			surface.set_normal(normal)
			surface.set_uv(Vector2(point.x, point.z))
			surface.add_vertex(point)
			triangles.append(point)
	var mesh := surface.commit()
	_meshes[cell] = mesh
	_triangles[cell] = triangles
	return mesh


func water_mesh_for(cell: Vector2i) -> ArrayMesh:
	if _water_meshes.has(cell):
		return _water_meshes[cell]
	mesh_for(cell)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var triangles: PackedVector3Array = _triangles.get(cell, PackedVector3Array())
	var count := 0
	for i in range(0, triangles.size(), 3):
		var polygon := _clip_below(PackedVector3Array([triangles[i], triangles[i + 1], triangles[i + 2]]), _water_level)
		for j in range(1, polygon.size() - 1):
			var a := polygon[0]
			var b := polygon[j]
			var c := polygon[j + 1]
			if absf(Vector2(b.x - a.x, b.z - a.z).cross(Vector2(c.x - a.x, c.z - a.z))) < 0.00000001:
				continue
			for point: Vector3 in [a, b, c]:
				surface.set_normal(Vector3.UP)
				surface.set_uv(Vector2(point.x, point.z))
				surface.add_vertex(Vector3(point.x, _water_level, point.z))
			count += 1
	var mesh := surface.commit() if count > 0 else ArrayMesh.new()
	_water_meshes[cell] = mesh
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
	return float(_ground_field.call(cell, point))


func surface_breakpoints() -> PackedVector2Array:
	var unique: Dictionary = {}
	for cell: Vector2i in _centers:
		mesh_for(cell)
		for point: Vector3 in _triangles[cell]:
			_add_point(unique, Vector2(point.x, point.z))
		# y=水位的新交点也是河口折点，海格必须采用相同的水线边界。
		var water := water_mesh_for(cell)
		if water.get_surface_count() > 0:
			var vertices: PackedVector3Array = water.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			for point in vertices:
				_add_point(unique, Vector2(point.x, point.z))
	var result := PackedVector2Array()
	for point: Vector2 in unique.values():
		result.append(point)
	return result


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


static func _add_point(points: Dictionary, point: Vector2) -> void:
	var key := Vector2i(roundi(point.x * SAMPLE_SNAP), roundi(point.y * SAMPLE_SNAP))
	points[key] = Vector2(key) / SAMPLE_SNAP


static func _snapped(point: Vector2) -> Vector2:
	return Vector2(roundf(point.x * SAMPLE_SNAP), roundf(point.y * SAMPLE_SNAP)) / SAMPLE_SNAP


static func _inside_hex(local: Vector2) -> bool:
	return absf(local.y) <= SQRT3 * 0.5 + EDGE_EPSILON and absf(local.x) + absf(local.y) / SQRT3 <= 1.0 + EDGE_EPSILON


static func _corner(index: int) -> Vector2:
	return [Vector2(1, 0), Vector2(0.5, SQRT3 * 0.5), Vector2(-0.5, SQRT3 * 0.5),
		Vector2(-1, 0), Vector2(-0.5, -SQRT3 * 0.5), Vector2(0.5, -SQRT3 * 0.5)][index]
