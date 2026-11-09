extends RefCounted
## 路旁物件：只提供视觉，原点为占地中心，底部 y=0；当前均不可破坏。
## 木桶组合1.224宽×0.844深×0.92高，占一格；路牌1.20宽×0.24深×1.30高。
## 共用 wood/bark/iron/cutwood、16纹素/单位和面UV；桶箍为连续侧面的材料带。
## 碰撞、占格、描边与接触阴影由场景宿主统一提供。

const Kit := preload("res://samples/forest_3d/PixelOutpostKit.gd")
const Faces := preload("res://samples/forest_3d/PixelPropFaces.gd")

static func make_barrels() -> Node3D:
	var root := Node3D.new()
	root.name = "PixelBarrelPair"
	_barrel(root, Vector2(-0.29, -0.10), 0.92, 0.31)
	_barrel(root, Vector2(0.34, 0.15), 0.68, 0.26)
	return Kit._finish(root)

static func _base_radius(y: float, height: float, radius: float) -> float:
	var end_radius := radius * 0.84
	var middle_radius := radius + 0.012
	if y < height * 0.2:
		return lerpf(end_radius, middle_radius, y / (height * 0.2))
	if y > height * 0.8:
		return lerpf(middle_radius, end_radius, minf(1.0, (y - height * 0.8) / (height * 0.2 - 0.025)))
	return middle_radius

static func _ring(center: Vector2, y: float, radius: float) -> Array[Vector3]:
	var points: Array[Vector3] = []
	for i in range(8):
		var angle := float(i) * TAU / 8.0
		points.append(Vector3(center.x + cos(angle) * radius, y, center.y + sin(angle) * radius))
	return points

static func _barrel(root: Node3D, center: Vector2, height: float, radius: float) -> void:
	var surfaces: Array[SurfaceTool] = []
	for i in range(3):
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		surfaces.append(surface)
	# 桶箍只改变连续侧面的材料，不另叠薄环或封口圆盘。
	var levels: Array[float] = [0.0, height * 0.20, height * 0.80, height - 0.025, height]
	for ratio in [0.25, 0.72]:
		levels.append(height * ratio - 0.0375)
		levels.append(height * ratio + 0.0375)
	levels.sort()
	for i in range(1, levels.size()):
		var low := levels[i - 1]
		var high := levels[i]
		var middle := (low + high) * 0.5
		var material_index := 0
		if absf(middle - height * 0.25) < 0.0375 or absf(middle - height * 0.72) < 0.0375:
			material_index = 1
		elif middle > height - 0.025:
			material_index = 2
		var lower := _ring(center, low, _base_radius(low, height, radius))
		var upper := _ring(center, high, _base_radius(high, height, radius))
		for side in range(8):
			var next := (side + 1) % 8
			var midpoint := (lower[side] + lower[next]) * 0.5
			var outward := Vector3(midpoint.x - center.x, 0, midpoint.z - center.y)
			Faces.quad(surfaces[material_index], lower[side], lower[next], upper[next], upper[side], outward)
	# 只在整个桶的顶底封盖，不为桶腹、桶箍或桶盖侧段生成内部圆盘。
	for y in [0.0, height]:
		var ring := _ring(center, y, radius * 0.84)
		for side in range(8):
			Faces.triangle(surfaces[2], Vector3(center.x, y, center.y), ring[side], ring[(side + 1) % 8],
				Vector3.DOWN if y == 0.0 else Vector3.UP)
	var materials := [Kit._mat("wood"), Kit._mat("iron"), Kit._mat("cutwood")]
	for i in range(3):
		Kit._mesh(root, surfaces[i].commit(), materials[i], Vector3.ZERO)

static func make_signpost() -> Node3D:
	var root := Node3D.new()
	root.name = "PixelForkSignpost"
	# 立柱与牌背略有嵌接，外表面不共面；整体前后边界仍为 ±0.12。
	Kit._box(root, Vector3(0.14, 1.25, 0.16), Vector3(0, 0.625, 0.04), Kit._mat("bark"))
	_arrow(root, 1.12, 1.0, 1.20, 0.36)
	_arrow(root, 0.79, -1.0, 1.00, 0.32)
	return Kit._finish(root)

static func _arrow(root: Node3D, y: float, direction: float, width: float, height: float) -> void:
	var half := width * 0.5
	var shoulder := half - 0.30
	var outline := PackedVector2Array([
		Vector2(-half, -height / 3.0), Vector2(shoulder, -height / 3.0),
		Vector2(shoulder, -height * 0.5), Vector2(shoulder + 0.10, -height * 0.5),
		Vector2(shoulder + 0.10, -height / 3.0), Vector2(shoulder + 0.20, -height / 3.0),
		Vector2(shoulder + 0.20, -height / 6.0), Vector2(half, -height / 6.0),
		Vector2(half, height / 6.0), Vector2(shoulder + 0.20, height / 6.0),
		Vector2(shoulder + 0.20, height / 3.0), Vector2(shoulder + 0.10, height / 3.0),
		Vector2(shoulder + 0.10, height * 0.5), Vector2(shoulder, height * 0.5),
		Vector2(shoulder, height / 3.0), Vector2(-half, height / 3.0)])
	for i in range(outline.size()):
		outline[i] = Vector2(outline[i].x * direction, outline[i].y + y)
	Faces.extrude(root, outline, 0.10, -0.07, Kit._mat("wood"))
