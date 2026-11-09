extends RefCounted
## 静态物件的连续外表面工具；面法线和顺时针绕序同源，UV 交给既有 Kit。

const Kit := preload("res://samples/forest_3d/PixelOutpostKit.gd")

static func triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, outward: Vector3) -> void:
	var normal := (b - a).cross(c - a)
	if normal.length_squared() < 0.000000001:
		return
	normal = normal.normalized()
	if normal.dot(outward) < 0.0:
		normal = -normal
	surface.set_normal(normal)
	var clockwise := -(b - a).cross(c - a).dot(normal) > 0.0
	surface.add_vertex(a)
	surface.add_vertex(b if clockwise else c)
	surface.add_vertex(c if clockwise else b)

static func quad(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, outward: Vector3) -> void:
	triangle(surface, a, b, c, outward)
	triangle(surface, a, c, d, outward)

static func extrude(root: Node3D, polygon: PackedVector2Array, depth: float, z: float, material: Material) -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var indices := Geometry2D.triangulate_polygon(polygon)
	assert(not indices.is_empty(), "Prop profile must be a simple polygon")
	var front := z - depth * 0.5
	var back := z + depth * 0.5
	for i in range(0, indices.size(), 3):
		var a := polygon[indices[i]]
		var b := polygon[indices[i + 1]]
		var c := polygon[indices[i + 2]]
		triangle(surface, Vector3(a.x, a.y, front), Vector3(b.x, b.y, front), Vector3(c.x, c.y, front), Vector3.FORWARD)
		triangle(surface, Vector3(a.x, a.y, back), Vector3(b.x, b.y, back), Vector3(c.x, c.y, back), Vector3.BACK)
	var area := 0.0
	for i in range(polygon.size()):
		area += polygon[i].cross(polygon[(i + 1) % polygon.size()])
	for i in range(polygon.size()):
		var a := polygon[i]
		var b := polygon[(i + 1) % polygon.size()]
		var edge := b - a
		var normal := Vector3(edge.y, -edge.x, 0) * (1.0 if area > 0.0 else -1.0)
		quad(surface, Vector3(a.x, a.y, front), Vector3(b.x, b.y, front),
			Vector3(b.x, b.y, back), Vector3(a.x, a.y, back), normal)
	Kit._mesh(root, surface.commit(), material, Vector3.ZERO)
