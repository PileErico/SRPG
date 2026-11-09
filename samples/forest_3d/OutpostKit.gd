extends RefCounted
## 林地哨站：底部归零的可复用视觉模块；占格、碰撞与破坏由场景负责。
## 各部件最终按材质合并，细小木料/石块不会保留成大量绘制节点。

const WALL_LENGTH := 1.7320508075688772
static var _materials: Dictionary = {}

static func _mat(key: String, color: String) -> StandardMaterial3D:
	if not _materials.has(key):
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(color)
		material.roughness = 0.95
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		_materials[key] = material
	return _materials[key]

static func _wood(index: int = 0) -> StandardMaterial3D:
	var colors := ["5b4331", "72523b", "836047", "4a382c"]
	return _mat("wood%d" % posmod(index, 4), colors[posmod(index, 4)])

static func _stone(index: int = 0) -> StandardMaterial3D:
	var colors := ["878477", "979184", "797d72", "a29b88", "72756d"]
	return _mat("stone%d" % posmod(index, 5), colors[posmod(index, 5)])

static func _roof_material(index: int = 0) -> StandardMaterial3D:
	var colors := ["795344", "885c49", "936751", "684a3f"]
	return _mat("roof%d" % posmod(index, 4), colors[posmod(index, 4)])

static func _mesh(root: Node3D, geometry: Mesh, material: Material, at: Vector3) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	part.mesh = geometry
	part.material_override = material
	part.position = at
	root.add_child(part)
	return part

static func _box(root: Node3D, size: Vector3, at: Vector3, material: Material) -> MeshInstance3D:
	var geometry := BoxMesh.new()
	geometry.size = size
	return _mesh(root, geometry, material, at)

static func _beam(root: Node3D, a: Vector3, b: Vector3, thickness: float, material: Material) -> MeshInstance3D:
	var part := _box(root, Vector3(thickness, a.distance_to(b), thickness), (a + b) * 0.5, material)
	part.quaternion = Quaternion(Vector3.UP, (b - a).normalized())
	return part

static func _cylinder(root: Node3D, radius: float, height: float, at: Vector3, material: Material, tip: float = -1.0) -> MeshInstance3D:
	var geometry := CylinderMesh.new()
	geometry.bottom_radius = radius
	geometry.top_radius = radius if tip < 0.0 else tip
	geometry.height = height
	geometry.radial_segments = 7
	return _mesh(root, geometry, material, at)

static func _triangles(root: Node3D, points: Array, material: Material) -> MeshInstance3D:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for point: Vector3 in points:
		surface.add_vertex(point)
	surface.generate_normals()
	return _mesh(root, surface.commit(), material, Vector3.ZERO)

static func _stone_block(root: Node3D, size: Vector3, at: Vector3, material: Material) -> MeshInstance3D:
	# 八边截面让石头边角吃光；平顶便于墙段接缝。
	var hx := size.x * 0.5
	var hz := size.z * 0.5
	var bevel := minf(0.045, minf(hx, hz) * 0.22)
	var ring := [Vector2(-hx + bevel, -hz), Vector2(hx - bevel, -hz),
		Vector2(hx, -hz + bevel), Vector2(hx, hz - bevel), Vector2(hx - bevel, hz),
		Vector2(-hx + bevel, hz), Vector2(-hx, hz - bevel), Vector2(-hx, -hz + bevel)]
	var vertices: Array = []
	var y0 := -size.y * 0.5
	var y1 := size.y * 0.5
	for i in range(8):
		var a: Vector2 = ring[i]
		var b: Vector2 = ring[(i + 1) % 8]
		vertices.append_array([Vector3(a.x, y0, a.y), Vector3(b.x, y0, b.y), Vector3(b.x, y1, b.y),
			Vector3(a.x, y0, a.y), Vector3(b.x, y1, b.y), Vector3(a.x, y1, a.y),
			Vector3(0, y1, 0), Vector3(a.x, y1, a.y), Vector3(b.x, y1, b.y),
			Vector3(0, y0, 0), Vector3(b.x, y0, b.y), Vector3(a.x, y0, a.y)])
	var part := _triangles(root, vertices, material)
	part.position = at
	return part

static func _finish(root: Node3D) -> Node3D:
	var batches: Dictionary = {}
	var materials: Dictionary = {}
	for child in root.get_children():
		if child is not MeshInstance3D:
			continue
		var part := child as MeshInstance3D
		var key := part.material_override.get_instance_id()
		if not batches.has(key):
			var builder := SurfaceTool.new()
			builder.begin(Mesh.PRIMITIVE_TRIANGLES)
			batches[key] = builder
			materials[key] = part.material_override
		for surface_index in range(part.mesh.get_surface_count()):
			batches[key].append_from(part.mesh, surface_index, part.transform)
	for child in root.get_children():
		if child is MeshInstance3D:
			child.free()
	for key in batches:
		_mesh(root, batches[key].commit(), materials[key], Vector3.ZERO)
	return root

static func make_wall(cracked: bool = false) -> Node3D:
	var root := Node3D.new()
	root.name = "CrackedStoneWall" if cracked else "StoneWall"
	_box(root, Vector3(0.43, 1.17, WALL_LENGTH - 0.012), Vector3(0, 0.585, 0), _mat("mortar", "5f6259"))
	for row in range(4):
		var widths: Array = [0.433, 0.433, 0.433, 0.433] if row % 2 == 0 else [0.2165, 0.433, 0.433, 0.433, 0.2165]
		var edge := -WALL_LENGTH * 0.5
		for i in range(widths.size()):
			var width: float = widths[i]
			var material := _stone(i + row * 2 + (1 if cracked else 0))
			var stone := _stone_block(root, Vector3(0.50 + 0.018 * sin(float(i + row)), 0.274, width - 0.018),
				Vector3(0, 0.15 + float(row) * 0.285, edge + width * 0.5), material)
			stone.rotation.y = 0.013 * sin(float(i * 7 + row))
			edge += width
	for i in range(4):
		_stone_block(root, Vector3(0.60, 0.15, WALL_LENGTH * 0.25 - 0.014),
			Vector3(0, 1.225, -WALL_LENGTH * 0.5 + (float(i) + 0.5) * WALL_LENGTH * 0.25), _stone(i + 2))
	if cracked:
		var crack := [Vector2(1.30, -0.25), Vector2(1.04, 0.05), Vector2(0.81, -0.12), Vector2(0.56, 0.17), Vector2(0.26, 0.04), Vector2(0.04, 0.20)]
		for side in [-1.0, 1.0]:
			for i in range(crack.size() - 1):
				var a := Vector3(side * 0.269, crack[i].x, crack[i].y)
				var b := Vector3(side * 0.269, crack[i + 1].x, crack[i + 1].y)
				_beam(root, a, b, 0.055, _mat("crack", "353b33"))
				_beam(root, a + Vector3(0.003 * side, 0, 0.043), b + Vector3(0.003 * side, 0, 0.043), 0.019, _mat("crack_edge", "d5c6a2"))
			_beam(root, Vector3(side * 0.269, 0.81, -0.12), Vector3(side * 0.269, 0.66, -0.40), 0.035, _mat("crack", "353b33"))
	return _finish(root)

static func _roof(root: Node3D, width: float, length: float, eave: float, rise: float, columns: int, courses: int) -> void:
	var run := width * 0.5
	var slope_length := sqrt(run * run + rise * rise)
	var angle := atan2(rise, run)
	for side in [-1.0, 1.0]:
		var under := _box(root, Vector3(slope_length + 0.03, 0.07, length),
			Vector3(side * run * 0.5, eave + rise * 0.5, 0), _wood(3))
		under.rotation.z = -side * angle
		for row in range(courses):
			var t := (float(row) + 0.5) / float(courses)
			for col in range(columns):
				var tile := _box(root, Vector3(slope_length / float(courses) + 0.035, 0.045, length / float(columns) - 0.012),
					Vector3(side * run * t, eave + rise * (1.0 - t) + 0.045, -length * 0.5 + (float(col) + 0.5) * length / float(columns)),
					_roof_material(col * 3 + row))
				tile.rotation.z = -side * angle
		_box(root, Vector3(0.10, 0.13, length + 0.08), Vector3(side * run, eave - 0.025, 0), _wood(3))
	for i in range(columns):
		var ridge := _cylinder(root, 0.07, length / float(columns) - 0.008,
			Vector3(0, eave + rise + 0.072, -length * 0.5 + (float(i) + 0.5) * length / float(columns)), _roof_material(3))
		ridge.rotation.x = PI * 0.5
	for z in [-length * 0.5 - 0.015, length * 0.5 + 0.015]:
		for side in [-1.0, 1.0]:
			_beam(root, Vector3(0, eave + rise + 0.01, z), Vector3(side * run, eave, z), 0.08, _wood(2))

static func make_gate() -> Node3D:
	var root := Node3D.new()
	root.name = "RoofedTimberGate"
	for z in [-0.74, 0.74]:
		_stone_block(root, Vector3(0.31, 0.21, 0.31), Vector3(0, 0.105, z), _stone(1))
		_box(root, Vector3(0.22, 1.94, 0.22), Vector3(0, 1.15, z), _wood(0))
		_box(root, Vector3(0.242, 0.065, 0.242), Vector3(0, 0.46, z), _mat("iron", "3d4643"))
		_box(root, Vector3(0.242, 0.065, 0.242), Vector3(0, 1.58, z), _mat("iron", "3d4643"))
		_beam(root, Vector3(0, 1.58, z), Vector3(0, 1.99, z * 0.48), 0.12, _wood(1))
	_box(root, Vector3(0.25, 0.21, 1.83), Vector3(0, 2.035, 0), _wood(1))
	_roof(root, 1.08, 2.10, 2.12, 0.30, 6, 2)
	# 旗布放在门柱外侧，不降低净空。
	for side in [-1.0, 1.0]:
		var z: float = side * 0.91
		_box(root, Vector3(0.06, 0.06, 0.42), Vector3(-0.20, 1.80, z), _wood(0))
		var x := -0.24
		var points := [Vector3(x, 1.76, z - 0.16), Vector3(x, 1.76, z + 0.16), Vector3(x - 0.035, 1.10, z + 0.16),
			Vector3(x, 1.76, z - 0.16), Vector3(x - 0.035, 1.10, z + 0.16), Vector3(x - 0.06, 1.19, z),
			Vector3(x, 1.76, z - 0.16), Vector3(x - 0.06, 1.19, z), Vector3(x - 0.035, 1.10, z - 0.16)]
		_triangles(root, points, _mat("banner", "596b73"))
		_box(root, Vector3(0.009, 0.29, 0.045), Vector3(x - 0.026, 1.54, z), _mat("banner_mark", "c4b98f"))
	return _finish(root)

static func make_palisade() -> Node3D:
	var root := Node3D.new()
	root.name = "TimberPalisade"
	for i in range(8):
		var z := -WALL_LENGTH * 0.5 + (float(i) + 0.5) * WALL_LENGTH / 8.0
		var height := 1.12 + 0.055 * sin(float(i) * 1.9)
		_cylinder(root, 0.115, height - 0.19, Vector3(0, (height - 0.19) * 0.5, z), _wood(i))
		_cylinder(root, 0.115, 0.23, Vector3(0, height - 0.19 + 0.115, z), _wood(i + 1), 0.012)
	for y in [0.35, 0.79]:
		_box(root, Vector3(0.09, 0.11, WALL_LENGTH), Vector3(0.14, y, 0), _wood(3))
	for z in [-0.61, 0.61]:
		for y in [0.35, 0.79]:
			var peg := _cylinder(root, 0.024, 0.025, Vector3(0.197, y, z), _mat("iron", "3d4643"))
			peg.rotation.z = PI * 0.5
	return _finish(root)

static func make_hut() -> Node3D:
	var root := Node3D.new()
	root.name = "TimberWatchHut"
	# 体积约 2.1 × 2.5；屋檐略外挑。门朝 -X。
	_box(root, Vector3(2.08, 0.26, 2.48), Vector3(0, 0.13, 0), _stone(0))
	_box(root, Vector3(1.94, 1.40, 2.34), Vector3(0, 0.96, 0), _mat("plaster", "b8af91"))
	for x in [-0.98, 0.98]:
		for z in [-1.18, 1.18]:
			_box(root, Vector3(0.14, 1.52, 0.14), Vector3(x, 0.98, z), _wood(0))
		_box(root, Vector3(0.12, 0.14, 2.47), Vector3(x, 1.65, 0), _wood(0))
		_box(root, Vector3(0.12, 0.12, 2.47), Vector3(x, 0.40, 0), _wood(1))
		_box(root, Vector3(0.13, 1.24, 0.12), Vector3(x, 1.02, 0.18), _wood(1))
		_beam(root, Vector3(x, 0.49, 0.28), Vector3(x, 1.56, 1.08), 0.10, _wood(1))
	for z in [-1.18, 1.18]:
		_box(root, Vector3(2.09, 0.13, 0.12), Vector3(0, 1.65, z), _wood(0))
		_box(root, Vector3(2.09, 0.12, 0.12), Vector3(0, 0.40, z), _wood(1))
		_box(root, Vector3(0.13, 1.24, 0.12), Vector3(0, 1.02, z), _wood(1))
		for side in [-1.0, 1.0]:
			_beam(root, Vector3(0.08 * side, 0.49, z), Vector3(0.87 * side, 1.54, z), 0.10, _wood(1))
		_triangles(root, [Vector3(-0.98, 1.66, z), Vector3(0.98, 1.66, z), Vector3(0, 2.28, z)], _mat("gable", "a59c7e"))
		_box(root, Vector3(0.10, 0.61, 0.12), Vector3(0, 1.95, z), _wood(0))
	# 入户门：五块木板、门框、铁铰链和踏步。
	var door_z := -0.56
	_box(root, Vector3(0.045, 1.23, 0.76), Vector3(-0.994, 0.88, door_z), _mat("opening", "29302c"))
	for i in range(5):
		_box(root, Vector3(0.055, 1.12, 0.127), Vector3(-1.025, 0.84, door_z - 0.29 + float(i) * 0.145), _wood(i + 1))
	for z in [door_z - 0.43, door_z + 0.43]:
		_box(root, Vector3(0.15, 1.30, 0.09), Vector3(-1.025, 0.89, z), _wood(0))
	_box(root, Vector3(0.15, 0.12, 0.94), Vector3(-1.025, 1.50, door_z), _wood(0))
	for y in [0.54, 1.14]:
		_box(root, Vector3(0.028, 0.055, 0.63), Vector3(-1.067, y, door_z), _mat("iron", "3d4643"))
	_stone_block(root, Vector3(0.40, 0.17, 1.0), Vector3(-1.16, 0.085, door_z), _stone(3))
	var handle := _cylinder(root, 0.045, 0.03, Vector3(-1.09, 0.88, door_z + 0.19), _mat("iron", "3d4643"))
	handle.rotation.z = PI * 0.5
	# 每面各一个深色小窗，木框在远景也有清楚的轮廓。
	for side in [-1.0, 1.0]:
		var x: float = side * 1.004
		var z := 0.65
		_box(root, Vector3(0.035, 0.56, 0.61), Vector3(x, 1.12, z), _mat("opening", "29302c"))
		for yy in [0.81, 1.43]:
			_box(root, Vector3(0.10, 0.075, 0.76), Vector3(x, yy, z), _wood(2))
		for zz in [z - 0.34, z + 0.34]:
			_box(root, Vector3(0.10, 0.69, 0.065), Vector3(x, 1.12, zz), _wood(0))
		_box(root, Vector3(0.07, 0.55, 0.045), Vector3(x + side * 0.03, 1.12, z), _wood(1))
		_box(root, Vector3(0.07, 0.045, 0.61), Vector3(x + side * 0.03, 1.12, z), _wood(1))
	_roof(root, 2.40, 2.78, 1.76, 0.63, 8, 3)
	# 短烟囱嵌在靠后坡面，给剪影一点生活痕迹。
	_stone_block(root, Vector3(0.31, 0.74, 0.37), Vector3(0.55, 2.10, 0.70), _stone(1))
	_stone_block(root, Vector3(0.39, 0.10, 0.44), Vector3(0.55, 2.49, 0.70), _stone(0))
	_box(root, Vector3(0.23, 0.008, 0.28), Vector3(0.55, 2.545, 0.70), _mat("opening", "29302c"))
	return _finish(root)

static func make_rubble() -> Node3D:
	var root := Node3D.new()
	root.name = "WallRubble"
	for i in range(9):
		var angle := float(i) * 2.399963
		var radius := 0.12 + float(i % 3) * 0.20
		var height := 0.12 + float(i % 2) * 0.08
		var stone := _stone_block(root, Vector3(0.23 + float(i % 3) * 0.055, height, 0.20 + float((i + 1) % 3) * 0.07),
			Vector3(sin(angle) * radius * 0.8, height * 0.5, cos(angle) * radius * 1.2), _stone(i))
		stone.rotation.y = angle
	return _finish(root)
