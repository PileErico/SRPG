extends RefCounted
## 粗像素建筑部件：大块几何确定轮廓，共享材质负责木纹、砖缝与瓦片。
## 全部底部 y=0，仅视觉；占格、碰撞和破坏由场景负责。

const PixelMaterials := preload("res://samples/forest_3d/PixelMaterials.gd")
const PixelMeshUV := preload("res://samples/forest_3d/PixelMeshUV.gd")
const WALL_LENGTH := 1.7320508075688772

static func _mat(kind: String, tint: Color = Color.WHITE) -> Material:
	return PixelMaterials.get_material(kind, tint, true)

static func _mesh(root: Node3D, geometry: Mesh, material: Material, at: Vector3, generate_uv: bool = true) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	part.mesh = PixelMeshUV.convert(geometry) if generate_uv else geometry
	part.material_override = material
	part.position = at
	root.add_child(part)
	return part

static func _box(root: Node3D, dimensions: Vector3, at: Vector3, material: Material) -> MeshInstance3D:
	var geometry := BoxMesh.new()
	geometry.size = dimensions
	return _mesh(root, geometry, material, at)

static func _beam(root: Node3D, a: Vector3, b: Vector3, thickness: float, material: Material) -> MeshInstance3D:
	var part := _box(root, Vector3(thickness, a.distance_to(b), thickness), (a + b) * 0.5, material)
	part.quaternion = Quaternion(Vector3.UP, (b - a).normalized())
	return part

static func _cylinder(root: Node3D, radius: float, height: float, at: Vector3, material: Material, tip: float = -1.0, sides: int = 8) -> MeshInstance3D:
	var geometry := CylinderMesh.new()
	geometry.bottom_radius = radius
	geometry.top_radius = radius if tip < 0.0 else tip
	geometry.height = height
	geometry.radial_segments = sides
	return _mesh(root, geometry, material, at)

static func _triangle(root: Node3D, a: Vector3, b: Vector3, c: Vector3, normal: Vector3, material: Material) -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_normal(normal)
	surface.add_vertex(a)
	surface.add_vertex(b)
	surface.add_vertex(c)
	_mesh(root, surface.commit(), material, Vector3.ZERO)

static func _finish(root: Node3D) -> Node3D:
	var batches: Dictionary = {}
	var materials: Dictionary = {}
	for child in root.get_children():
		if child is not MeshInstance3D:
			continue
		var part := child as MeshInstance3D
		var key := part.material_override.get_instance_id()
		if not batches.has(key):
			var surface := SurfaceTool.new()
			surface.begin(Mesh.PRIMITIVE_TRIANGLES)
			batches[key] = surface
			materials[key] = part.material_override
		for i in range(part.mesh.get_surface_count()):
			batches[key].append_from(part.mesh, i, part.transform)
	for child in root.get_children():
		if child is MeshInstance3D:
			child.free()
	for key in batches:
		# append_from 只变换几何，保留各部件旋转前生成的 UV。
		_mesh(root, batches[key].commit(), materials[key], Vector3.ZERO, false)
	return root

static func make_wall(cracked: bool = false) -> Node3D:
	var root := Node3D.new()
	root.name = "PixelCrackedWall" if cracked else "PixelStoneWall"
	_box(root, Vector3(0.52, 1.18, WALL_LENGTH), Vector3(0, 0.59, 0), _mat("stone_brick"))
	_box(root, Vector3(0.60, 0.12, WALL_LENGTH), Vector3(0, 1.24, 0), _mat("stone"))
	if cracked:
		# 裂隙与浅色破损边留出粗像素宽度；两面都能辨认。
		var path := [Vector2(-0.20, 1.27), Vector2(-0.20, 1.01), Vector2(0.08, 1.01),
			Vector2(0.08, 0.76), Vector2(-0.08, 0.76), Vector2(-0.08, 0.51),
			Vector2(0.19, 0.51), Vector2(0.19, 0.26), Vector2(0.08, 0.26), Vector2(0.08, 0.06)]
		for side in [-1.0, 1.0]:
			for i in range(path.size() - 1):
				var a: Vector2 = path[i]
				var b: Vector2 = path[i + 1]
				var span := Vector3(0.014, absf(a.y - b.y) + 0.16, absf(a.x - b.x) + 0.16)
				var center := Vector3(side * 0.269, (a.y + b.y) * 0.5, (a.x + b.x) * 0.5)
				_box(root, span + Vector3(0, 0.08, 0.08), center + Vector3(side * 0.003, 0.0, 0.05), _mat("plaster"))
				_box(root, span, center + Vector3(side * 0.012, 0.0, 0.0), _mat("dark"))
		_box(root, Vector3(0.61, 0.012, 0.20), Vector3(0, 1.306, -0.20), _mat("dark"))
	return _finish(root)

static func _roof(root: Node3D, width: float, length: float, eave: float, rise: float) -> void:
	var run := width * 0.5
	var slope := sqrt(run * run + rise * rise)
	for side in [-1.0, 1.0]:
		var panel := _box(root, Vector3(slope + 0.03, 0.10, length),
			Vector3(side * run * 0.5, eave + rise * 0.5, 0), _mat("roof"))
		panel.rotation.z = -side * atan2(rise, run)
		_box(root, Vector3(0.10, 0.13, length + 0.06), Vector3(side * run, eave - 0.035, 0), _mat("wood"))
	_box(root, Vector3(0.14, 0.11, length + 0.04), Vector3(0, eave + rise + 0.045, 0), _mat("roof"))

static func make_gate() -> Node3D:
	var root := Node3D.new()
	root.name = "PixelTimberGate"
	for z in [-0.74, 0.74]:
		_box(root, Vector3(0.30, 0.18, 0.30), Vector3(0, 0.09, z), _mat("stone"))
		_box(root, Vector3(0.23, 1.88, 0.23), Vector3(0, 1.08, z), _mat("wood"))
		for y in [0.43, 1.55]:
			_box(root, Vector3(0.25, 0.085, 0.25), Vector3(0, y, z), _mat("iron"))
		_beam(root, Vector3(0, 1.63, z), Vector3(0, 1.97, z * 0.49), 0.12, _mat("wood"))
	_box(root, Vector3(0.25, 0.22, 1.84), Vector3(0, 1.99, 0), _mat("wood"))
	_roof(root, 1.08, 2.04, 2.10, 0.27)
	for z in [-0.91, 0.91]:
		_box(root, Vector3(0.06, 0.07, 0.39), Vector3(-0.18, 1.79, z), _mat("wood"))
		_box(root, Vector3(0.022, 0.59, 0.27), Vector3(-0.23, 1.44, z), _mat("cloth"))
		_box(root, Vector3(0.025, 0.10, 0.14), Vector3(-0.23, 1.095, z), _mat("cloth"))
		_box(root, Vector3(0.024, 0.27, 0.055), Vector3(-0.247, 1.49, z), _mat("plaster"))
	return _finish(root)

static func make_palisade() -> Node3D:
	var root := Node3D.new()
	root.name = "PixelPalisade"
	for i in range(7):
		var z := -WALL_LENGTH * 0.5 + (float(i) + 0.5) * WALL_LENGTH / 7.0
		var height := 0.98 + float(i % 3) * 0.045
		_box(root, Vector3(0.22, height, 0.22), Vector3(0, height * 0.5, z), _mat("bark"))
		var point := _cylinder(root, 0.1556, 0.19, Vector3(0, height + 0.095, z), _mat("cutwood"), 0.0, 4)
		point.rotation.y = PI * 0.25
	for y in [0.34, 0.76]:
		_box(root, Vector3(0.09, 0.13, WALL_LENGTH), Vector3(0.15, y, 0), _mat("wood"))
	return _finish(root)

static func make_hut() -> Node3D:
	var root := Node3D.new()
	root.name = "PixelWatchHut"
	_box(root, Vector3(2.08, 0.25, 2.48), Vector3(0, 0.125, 0), _mat("stone_brick"))
	_box(root, Vector3(1.94, 1.42, 2.34), Vector3(0, 0.96, 0), _mat("plaster"))
	for x in [-0.98, 0.98]:
		for z in [-1.18, 1.18]:
			_box(root, Vector3(0.14, 1.50, 0.14), Vector3(x, 0.99, z), _mat("wood"))
		for y in [0.40, 1.66]:
			_box(root, Vector3(0.13, 0.13, 2.47), Vector3(x, y, 0), _mat("wood"))
		_box(root, Vector3(0.13, 1.24, 0.12), Vector3(x, 1.03, 0.18), _mat("wood"))
	for z in [-1.18, 1.18]:
		for y in [0.40, 1.66]:
			_box(root, Vector3(2.09, 0.13, 0.13), Vector3(0, y, z), _mat("wood"))
		_box(root, Vector3(0.13, 1.24, 0.12), Vector3(0, 1.03, z), _mat("wood"))
		for side in [-1.0, 1.0]:
			_beam(root, Vector3(0.08 * side, 0.49, z), Vector3(0.87 * side, 1.54, z), 0.10, _mat("wood"))
		var a := Vector3(-0.98, 1.67, z)
		var b := Vector3(0, 2.35, z)
		var c := Vector3(0.98, 1.67, z)
		_triangle(root, a if z > 0.0 else c, b, c if z > 0.0 else a, Vector3.BACK if z > 0.0 else Vector3.FORWARD, _mat("plaster"))
		_box(root, Vector3(0.12, 0.65, 0.13), Vector3(0, 1.99, z), _mat("wood"))
	# 门和窗用几块平面层次表示，木板与钉点由共享贴图提供。
	var door_z := -0.56
	_box(root, Vector3(0.045, 1.22, 0.76), Vector3(-0.995, 0.87, door_z), _mat("dark"))
	_box(root, Vector3(0.045, 1.12, 0.66), Vector3(-1.025, 0.84, door_z), _mat("wood"))
	for z in [door_z - 0.43, door_z + 0.43]:
		_box(root, Vector3(0.15, 1.28, 0.09), Vector3(-1.025, 0.89, z), _mat("wood"))
	_box(root, Vector3(0.15, 0.12, 0.94), Vector3(-1.025, 1.50, door_z), _mat("wood"))
	for y in [0.54, 1.14]:
		_box(root, Vector3(0.035, 0.075, 0.66), Vector3(-1.062, y, door_z), _mat("iron"))
	_box(root, Vector3(0.045, 0.095, 0.07), Vector3(-1.09, 0.86, door_z + 0.19), _mat("iron"))
	_box(root, Vector3(0.40, 0.17, 1.0), Vector3(-1.16, 0.085, door_z), _mat("stone"))
	for side in [-1.0, 1.0]:
		var x: float = side * 1.005
		var z := 0.65
		_box(root, Vector3(0.035, 0.54, 0.58), Vector3(x, 1.12, z), _mat("dark"))
		for y in [0.81, 1.43]:
			_box(root, Vector3(0.10, 0.08, 0.74), Vector3(x, y, z), _mat("wood"))
		for edge in [z - 0.33, z + 0.33]:
			_box(root, Vector3(0.10, 0.68, 0.07), Vector3(x, 1.12, edge), _mat("wood"))
		_box(root, Vector3(0.075, 0.54, 0.055), Vector3(x + side * 0.03, 1.12, z), _mat("wood"))
		_box(root, Vector3(0.075, 0.055, 0.58), Vector3(x + side * 0.03, 1.12, z), _mat("wood"))
	_roof(root, 2.40, 2.78, 1.72, 0.66)
	_box(root, Vector3(0.32, 0.68, 0.36), Vector3(0.55, 2.15, 0.70), _mat("stone_brick"))
	_box(root, Vector3(0.40, 0.10, 0.44), Vector3(0.55, 2.54, 0.70), _mat("stone"))
	_box(root, Vector3(0.23, 0.012, 0.27), Vector3(0.55, 2.596, 0.70), _mat("dark"))
	return _finish(root)

static func make_rubble() -> Node3D:
	var root := Node3D.new()
	root.name = "PixelWallRubble"
	for i in range(6):
		var z := -0.57 + float(i % 3) * 0.51
		var x := -0.21 if i < 3 else 0.24
		var height := 0.11 + float(i % 2) * 0.055
		var block := _box(root, Vector3(0.29, height, 0.33), Vector3(x, height * 0.5, z), _mat("stone"))
		block.rotation.y = float(i % 3) * PI / 8.0
	return _finish(root)

static func make_cart() -> Node3D:
	var root := Node3D.new()
	root.name = "PixelSupplyCart"
	# 1.2 × 1.45 米的空货车：四个八角轮、车厢和向前伸出的双杆。
	_box(root, Vector3(0.93, 0.10, 1.03), Vector3(0, 0.48, -0.10), _mat("wood"))
	for x in [-0.43, 0.43]:
		_box(root, Vector3(0.09, 0.35, 1.03), Vector3(x, 0.705, -0.10), _mat("wood"))
		for z in [-0.57, 0.37]:
			_box(root, Vector3(0.11, 0.47, 0.10), Vector3(x, 0.715, z), _mat("wood"))
	for z in [-0.57, 0.37]:
		_box(root, Vector3(0.93, 0.35, 0.085), Vector3(0, 0.705, z), _mat("wood"))
	for z in [-0.44, 0.25]:
		_box(root, Vector3(1.09, 0.095, 0.10), Vector3(0, 0.26, z), _mat("iron"))
		for side in [-1.0, 1.0]:
			var wheel := _cylinder(root, 0.26, 0.10, Vector3(side * 0.54, 0.26, z), _mat("iron"))
			wheel.rotation.z = PI * 0.5
			var disc := _cylinder(root, 0.205, 0.112, Vector3(side * 0.54, 0.26, z), _mat("cutwood"))
			disc.rotation.z = PI * 0.5
			var hub := _cylinder(root, 0.065, 0.14, Vector3(side * 0.54, 0.26, z), _mat("iron"))
			hub.rotation.z = PI * 0.5
	for x in [-0.27, 0.27]:
		_box(root, Vector3(0.09, 0.09, 0.47), Vector3(x, 0.42, 0.535), _mat("wood"))
	return _finish(root)
