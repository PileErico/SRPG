extends RefCounted
## 单格水井：1.4375 × 1.6875 × 1.25（X/Y/Z），底部 y=0、XZ 中心为原点。
## 当前不可破坏；此文件只生成视觉，碰撞/描边由场景添加。
## 共用 stone_brick / wood / dark / cutwood，32 色、16 纹素/单位。
## 井体、柱帽与悬桶为连续壳体；木柱从井沿顶起，不贯穿石壁。

const Kit := preload("res://samples/forest_3d/PixelOutpostKit.gd")
const Faces := preload("res://samples/forest_3d/PixelPropFaces.gd")

static func make_model() -> Node3D:
	var root := Node3D.new()
	root.name = "PixelVillageWell"
	var masonry := Kit._mat("stone_brick")
	var timber := Kit._mat("wood")
	var dark := Kit._mat("dark")
	var cord := Kit._mat("cutwood")
	_add_well_shell(root, masonry, dark)
	_add_posts(root, timber)
	# 单一八角横轴，不再套入相互交叠的绳卷和小挡片。
	var axle := Kit._cylinder(root, 0.09375, 1.4375, Vector3(0, 1.34375, 0), timber)
	axle.rotation.z = PI * 0.5
	Kit._box(root, Vector3(0.0625, 0.375, 0.0625), Vector3(0.625, 1.1875, 0), dark)
	Kit._box(root, Vector3(0.125, 0.0625, 0.0625), Vector3(0.65625, 1.03125, 0), timber)
	Kit._box(root, Vector3(0.0625, 0.1875, 0.0625), Vector3(0, 1.15625, 0), cord)
	_add_bucket(root, timber, dark)
	return Kit._finish(root)

static func _surface() -> SurfaceTool:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	return surface

static func _square(half_size: float, y: float, center_x: float = 0.0) -> Array[Vector3]:
	return [Vector3(center_x - half_size, y, -half_size), Vector3(center_x + half_size, y, -half_size),
		Vector3(center_x + half_size, y, half_size), Vector3(center_x - half_size, y, half_size)]

static func _join(surface: SurfaceTool, lower: Array[Vector3], upper: Array[Vector3], inside: bool = false) -> void:
	for i in range(4):
		var next := (i + 1) % 4
		var midpoint := (lower[i] + lower[next]) * 0.5
		var center := (lower[0] + lower[2]) * 0.5
		var normal := Vector3(midpoint.x - center.x, 0, midpoint.z - center.z)
		Faces.quad(surface, lower[i], lower[next], upper[next], upper[i], -normal if inside else normal)

static func _annulus(surface: SurfaceTool, outer: Array[Vector3], inner: Array[Vector3], normal: Vector3) -> void:
	for i in range(4):
		var next := (i + 1) % 4
		Faces.quad(surface, outer[i], outer[next], inner[next], inner[i], normal)

static func _cap(surface: SurfaceTool, corners: Array[Vector3], normal: Vector3) -> void:
	Faces.quad(surface, corners[0], corners[1], corners[2], corners[3], normal)

static func _add_well_shell(root: Node3D, masonry: Material, dark: Material) -> void:
	var stone := _surface()
	_join(stone, _square(0.5625, 0.0), _square(0.5625, 0.50))
	_annulus(stone, _square(0.625, 0.50), _square(0.5625, 0.50), Vector3.DOWN)
	_join(stone, _square(0.625, 0.50), _square(0.625, 0.625))
	_annulus(stone, _square(0.625, 0.625), _square(0.375, 0.625), Vector3.UP)
	_join(stone, _square(0.375, 0.03125), _square(0.375, 0.625), true)
	_cap(stone, _square(0.5625, 0.0), Vector3.DOWN)
	Kit._mesh(root, stone.commit(), masonry, Vector3.ZERO)
	var floor_surface := _surface()
	_cap(floor_surface, _square(0.375, 0.03125), Vector3.UP)
	Kit._mesh(root, floor_surface.commit(), dark, Vector3.ZERO)

static func _add_posts(root: Node3D, timber: Material) -> void:
	var surface := _surface()
	for x in [-0.50, 0.50]:
		# 柱帽与柱身之间只留外露台阶，不生成两张重叠的封口面。
		_join(surface, _square(0.0625, 0.625, x), _square(0.0625, 1.5625, x))
		_annulus(surface, _square(0.09375, 1.5625, x), _square(0.0625, 1.5625, x), Vector3.DOWN)
		_join(surface, _square(0.09375, 1.5625, x), _square(0.09375, 1.6875, x))
		_cap(surface, _square(0.09375, 1.6875, x), Vector3.UP)
	Kit._mesh(root, surface.commit(), timber, Vector3.ZERO)

static func _add_bucket(root: Node3D, timber: Material, dark: Material) -> void:
	var wooden := _surface()
	var metal := _surface()
	_join(wooden, _square(0.125, 0.6875), _square(0.125, 0.78125))
	_join(metal, _square(0.125, 0.78125), _square(0.125, 0.8125))
	_join(wooden, _square(0.125, 0.8125), _square(0.125, 0.9375))
	_annulus(wooden, _square(0.125, 0.9375), _square(0.0625, 0.9375), Vector3.UP)
	_join(wooden, _square(0.0625, 0.71875), _square(0.0625, 0.9375), true)
	_cap(wooden, _square(0.125, 0.6875), Vector3.DOWN)
	_cap(metal, _square(0.0625, 0.71875), Vector3.UP)
	Kit._mesh(root, wooden.commit(), timber, Vector3.ZERO)
	Kit._mesh(root, metal.commit(), dark, Vector3.ZERO)
	# 桶把是一片 U 形挤出，避免三根细杆的相交封口面。
	var handle := PackedVector2Array([Vector2(-0.125, 0.9375), Vector2(-0.09375, 0.9375),
		Vector2(-0.09375, 1.03125), Vector2(0.09375, 1.03125), Vector2(0.09375, 0.9375),
		Vector2(0.125, 0.9375), Vector2(0.125, 1.0625), Vector2(-0.125, 1.0625)])
	Faces.extrude(root, handle, 0.03125, 0.0, dark)
