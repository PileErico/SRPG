extends RefCounted
## 世界地图的地域地标：树群、聚落和桥梁，底面中心为 (0, 0, 0)。
## 半径 1 的平顶六边形内使用；树群和聚落沿 X 方向留出道路空间。
## 最终尺寸生成面 UV，沿用共享 32 色与 16 纹素/单位；无碰撞或描边。
## 树和房屋各带小接触影，合批后添加并由共享描边按元数据排除。
## 可选 ground_at(local_anchor) 返回相对根的地面高度，每棵树/房屋/田地刚性升降。

const Kit := preload("res://samples/forest_3d/PixelOutpostKit.gd")
const Faces := preload("res://samples/forest_3d/PixelPropFaces.gd")
const ContactShadow := preload("res://samples/forest_3d/PixelContactShadow.gd")


static func make_forest(seed: int = 0, ground_at: Callable = Callable()) -> Node3D:
	var root := Node3D.new()
	root.name = "WorldForest"
	var random := RandomNumberGenerator.new()
	random.seed = seed
	var centers := [Vector2(-0.35, -0.43), Vector2(0.27, -0.425),
		Vector2(-0.28, 0.425), Vector2(0.35, 0.42)]
	var shadow_points: Array[Vector3] = []
	for i in range(centers.size()):
		var at: Vector2 = centers[i] + Vector2(random.randf_range(-0.035, 0.035), random.randf_range(-0.008, 0.008))
		var height := random.randf_range(0.72, 0.96)
		var turn := random.randf_range(-0.26, 0.26)
		var radius := random.randf_range(0.185, 0.23)
		# 任意整组转向都留在六边形内；树冠不会挤入中央道路。
		radius = minf(radius, (0.85 - at.length()) / sqrt(2.0))
		radius = minf(radius, (absf(at.y) - 0.155) / (absf(cos(turn)) + absf(sin(turn))))
		var point := _grounded_anchor(Vector3(at.x, 0, at.y), ground_at)
		_tree(root, point, radius, height, turn, "pine" if i == 1 else "leaves")
		shadow_points.append(point)
	Kit._finish(root)
	for point in shadow_points:
		_add_shadow(root, point, Vector2(0.3125, 0.3125))
	return root


static func make_village(ground_at: Callable = Callable()) -> Node3D:
	var root := Node3D.new()
	root.name = "WorldVillage"
	# 专门为世界尺度制作的三个体块，围绕小路组成聚落。
	var house_points: Array[Vector3] = [
		_grounded_anchor(Vector3(-0.36, 0, -0.375), ground_at),
		_grounded_anchor(Vector3(0.35, 0, -0.375), ground_at),
		_grounded_anchor(Vector3(-0.36, 0, 0.375), ground_at)]
	_house(root, house_points[0], Vector2(0.375, 0.375), 0.375, 0.25, PI)
	_house(root, house_points[1], Vector2(0.4375, 0.4375), 0.4375, 0.25, PI)
	_house(root, house_points[2], Vector2(0.4375, 0.375), 0.3125, 0.25, 0.0)
	_field(root, _grounded_anchor(Vector3(0.35, 0, 0.375), ground_at))
	Kit._finish(root)
	_add_shadow(root, house_points[0], Vector2(0.4375, 0.4375), true)
	_add_shadow(root, house_points[1], Vector2(0.50, 0.50), true)
	_add_shadow(root, house_points[2], Vector2(0.50, 0.4375), true)
	return root


static func _grounded_anchor(at: Vector3, ground_at: Callable) -> Vector3:
	# 回调吃模型局部底部锚点，返回相对根节点的高度；每个物件仅查询一次。
	# 高度在合批前平移整个刚体，阴影复用同一锚点，不扭曲物件几何。
	if ground_at.is_valid():
		at.y += float(ground_at.call(Vector3(at.x, 0.0, at.z)))
	return at


static func _add_shadow(root: Node3D, at: Vector3, size: Vector2, rectangular: bool = false) -> void:
	var shadow := ContactShadow.make(size, rectangular)
	shadow.position += at
	root.add_child(shadow)


static func _surface() -> SurfaceTool:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	return surface


static func _square(radius: float, y: float) -> PackedVector3Array:
	return PackedVector3Array([Vector3(-radius, y, -radius), Vector3(radius, y, -radius),
		Vector3(radius, y, radius), Vector3(-radius, y, radius)])


static func _join_rings(surface: SurfaceTool, lower: PackedVector3Array, upper: PackedVector3Array) -> void:
	for i in range(lower.size()):
		var j := (i + 1) % lower.size()
		var outward := (lower[i] + lower[j]) * 0.5
		outward.y = 0
		if is_equal_approx(lower[i].y, upper[i].y):
			outward = Vector3.DOWN if upper[i].length_squared() > lower[i].length_squared() else Vector3.UP
		Faces.quad(surface, lower[i], lower[j], upper[j], upper[i], outward)


static func _tree(root: Node3D, at: Vector3, radius: float, height: float, turn: float, foliage: String) -> void:
	var bark := _surface()
	var leaves := _surface()
	var foot := _square(0.046875, 0.0)
	var trunk_top := _square(0.046875, 0.25)
	var crown_bottom := _square(radius * 0.82, 0.25)
	var crown_wide := _square(radius, height * 0.59)
	var crown_top := _square(radius * 0.56, height)
	_join_rings(bark, foot, trunk_top)
	Faces.quad(bark, foot[0], foot[1], foot[2], foot[3], Vector3.DOWN)
	# 树干与树冠是连续外壳；接合处不留内部盖面。
	_join_rings(leaves, trunk_top, crown_bottom)
	_join_rings(leaves, crown_bottom, crown_wide)
	_join_rings(leaves, crown_wide, crown_top)
	Faces.quad(leaves, crown_top[0], crown_top[1], crown_top[2], crown_top[3], Vector3.UP)
	var trunk := Kit._mesh(root, bark.commit(), Kit._mat("bark"), at)
	var crown := Kit._mesh(root, leaves.commit(), Kit._mat(foliage), at)
	trunk.rotation.y = turn
	crown.rotation.y = turn


static func _house(root: Node3D, at: Vector3, footprint: Vector2, eave: float, rise: float, turn: float) -> void:
	var plaster := _surface()
	var roof := _surface()
	var wood := _surface()
	var half_x := footprint.x * 0.5
	var half_z := footprint.y * 0.5
	var bottom := PackedVector3Array([Vector3(-half_x, 0, -half_z), Vector3(half_x, 0, -half_z),
		Vector3(half_x, 0, half_z), Vector3(-half_x, 0, half_z)])
	var top := PackedVector3Array([Vector3(-half_x, eave, -half_z), Vector3(half_x, eave, -half_z),
		Vector3(half_x, eave, half_z), Vector3(-half_x, eave, half_z)])
	var peak_front := Vector3(0, eave + rise, -half_z)
	var peak_back := Vector3(0, eave + rise, half_z)
	# 前墙的门直接分配材质，避免贴在墙前的一层薄片。
	var door_half := 0.0625
	var door_height := 0.1875
	Faces.quad(plaster, bottom[0], Vector3(-door_half, 0, -half_z),
		Vector3(-door_half, eave, -half_z), top[0], Vector3.FORWARD)
	Faces.quad(plaster, Vector3(door_half, 0, -half_z), bottom[1],
		top[1], Vector3(door_half, eave, -half_z), Vector3.FORWARD)
	Faces.quad(plaster, Vector3(-door_half, door_height, -half_z),
		Vector3(door_half, door_height, -half_z), Vector3(door_half, eave, -half_z),
		Vector3(-door_half, eave, -half_z), Vector3.FORWARD)
	Faces.quad(wood, Vector3(-door_half, 0, -half_z), Vector3(door_half, 0, -half_z),
		Vector3(door_half, door_height, -half_z), Vector3(-door_half, door_height, -half_z), Vector3.FORWARD)
	Faces.quad(plaster, bottom[1], bottom[2], top[2], top[1], Vector3.RIGHT)
	Faces.quad(plaster, bottom[2], bottom[3], top[3], top[2], Vector3.BACK)
	Faces.quad(plaster, bottom[3], bottom[0], top[0], top[3], Vector3.LEFT)
	Faces.quad(plaster, bottom[0], bottom[1], bottom[2], bottom[3], Vector3.DOWN)
	Faces.triangle(plaster, top[0], top[1], peak_front, Vector3.FORWARD)
	Faces.triangle(plaster, top[2], top[3], peak_back, Vector3.BACK)
	Faces.quad(roof, top[0], top[3], peak_back, peak_front, Vector3(-1, 1, 0))
	Faces.quad(roof, top[1], top[2], peak_back, peak_front, Vector3(1, 1, 0))
	for entry in [[plaster, "plaster"], [roof, "roof"], [wood, "wood"]]:
		var surface: SurfaceTool = entry[0]
		var part := Kit._mesh(root, surface.commit(), Kit._mat(entry[1]), at)
		part.rotation.y = turn


static func _field(root: Node3D, at: Vector3) -> void:
	var soil := _surface()
	var crops := _surface()
	var width := 0.4375
	var depth := 0.375
	var height := 0.03125
	var low := PackedVector3Array([Vector3(-width * 0.5, 0, -depth * 0.5),
		Vector3(width * 0.5, 0, -depth * 0.5), Vector3(width * 0.5, 0, depth * 0.5),
		Vector3(-width * 0.5, 0, depth * 0.5)])
	var high := PackedVector3Array()
	for point in low:
		high.append(point + Vector3.UP * height)
	_join_rings(soil, low, high)
	Faces.quad(soil, low[0], low[1], low[2], low[3], Vector3.DOWN)
	for i in range(5):
		var x0 := -width * 0.5 + width * float(i) / 5.0
		var x1 := -width * 0.5 + width * float(i + 1) / 5.0
		Faces.quad(crops if i % 2 == 0 else soil,
			Vector3(x0, height, -depth * 0.5), Vector3(x1, height, -depth * 0.5),
			Vector3(x1, height, depth * 0.5), Vector3(x0, height, depth * 0.5), Vector3.UP)
	Kit._mesh(root, soil.commit(), Kit._mat("earth"), at)
	Kit._mesh(root, crops.commit(), Kit._mat("cutwood"), at)


static func make_bridge() -> Node3D:
	var root := Node3D.new()
	root.name = "WorldBridge"
	var deck := _surface()
	var rails := _surface()
	var half_length := 0.575
	var half_width := 0.20
	var inner_width := 0.1375
	var deck_height := 0.10
	var rail_height := 0.225
	var bottom := PackedVector3Array([Vector3(-half_length, 0, -half_width),
		Vector3(half_length, 0, -half_width), Vector3(half_length, 0, half_width),
		Vector3(-half_length, 0, half_width)])
	var top := PackedVector3Array()
	for point in bottom:
		top.append(point + Vector3.UP * deck_height)
	_join_rings(deck, bottom, top)
	Faces.quad(deck, bottom[0], bottom[1], bottom[2], bottom[3], Vector3.DOWN)
	Faces.quad(deck, Vector3(-half_length, deck_height, -inner_width),
		Vector3(half_length, deck_height, -inner_width), Vector3(half_length, deck_height, inner_width),
		Vector3(-half_length, deck_height, inner_width), Vector3.UP)
	# 矮护栏与桥板共用连续外壳，护栏底部和下方桥板不生成重叠面。
	for side in [-1.0, 1.0]:
		var outer: float = half_width * side
		var inner: float = inner_width * side
		Faces.quad(rails, Vector3(-half_length, deck_height, outer), Vector3(half_length, deck_height, outer),
			Vector3(half_length, rail_height, outer), Vector3(-half_length, rail_height, outer), Vector3(0, 0, side))
		Faces.quad(rails, Vector3(-half_length, deck_height, inner), Vector3(half_length, deck_height, inner),
			Vector3(half_length, rail_height, inner), Vector3(-half_length, rail_height, inner), Vector3(0, 0, -side))
		Faces.quad(rails, Vector3(-half_length, rail_height, inner), Vector3(half_length, rail_height, inner),
			Vector3(half_length, rail_height, outer), Vector3(-half_length, rail_height, outer), Vector3.UP)
		for end in [-1.0, 1.0]:
			var x: float = half_length * end
			Faces.quad(rails, Vector3(x, deck_height, inner), Vector3(x, deck_height, outer),
				Vector3(x, rail_height, outer), Vector3(x, rail_height, inner), Vector3(end, 0, 0))
	Kit._mesh(root, deck.commit(), Kit._mat("wood"), Vector3.ZERO)
	Kit._mesh(root, rails.commit(), Kit._mat("dark"), Vector3.ZERO)
	return Kit._finish(root)
