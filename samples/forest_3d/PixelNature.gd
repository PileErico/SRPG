extends RefCounted
## 原创方块自然物件：少量硬边体块，共用粗像素材料；纯视觉，无碰撞。

const PixelMaterials := preload("res://samples/forest_3d/PixelMaterials.gd")
const PixelMeshUV := preload("res://samples/forest_3d/PixelMeshUV.gd")
const HEIGHTS := {
	"oak": 2.6, "broadleaf": 2.65, "pine": 3.0,
	"rock": 0.65, "rock_flat": 0.13, "bush": 0.38,
	"grass": 0.18, "stump": 0.23, "logs": 0.40, "flower": 0.22,
}
static var _templates: Dictionary = {}
static var _heights: Dictionary = {}

static func instantiate_model(kind: String, target_height: float = -1.0) -> Node3D:
	if not HEIGHTS.has(kind):
		push_error("Unknown pixel nature model: " + kind)
		return Node3D.new()
	if not _templates.has(kind):
		_cache_model(kind)
	var instance: Node3D = _templates[kind].instantiate()
	var height: float = target_height if target_height > 0.0 else HEIGHTS[kind]
	instance.scale = Vector3.ONE * height / maxf(float(_heights[kind]), 0.001)
	# UV 随物件旋转；按最终等比尺寸补偿，大小不同的树仍使用相近像素密度。
	for geometry in instance.get_children():
		for part in geometry.get_children():
			if part is MeshInstance3D:
				part.mesh = PixelMeshUV.scaled_uv(part.mesh, instance.scale.x)
	return instance

static func _box(root: Node3D, dimensions: Vector3, at: Vector3, kind: String, tint: Color = Color.WHITE) -> MeshInstance3D:
	var geometry := BoxMesh.new()
	geometry.size = dimensions
	var part := MeshInstance3D.new()
	part.mesh = PixelMeshUV.convert(geometry)
	part.material_override = PixelMaterials.get_material(kind, tint, true)
	part.position = at
	root.add_child(part)
	return part

static func _branch(root: Node3D, start: Vector3, end: Vector3, width: float) -> void:
	var part := _box(root, Vector3(width, start.distance_to(end), width), (start + end) * 0.5, "bark")
	part.quaternion = Quaternion(Vector3.UP, (end - start).normalized())

static func _make_tree(root: Node3D, kind: String) -> void:
	if kind == "pine":
		_box(root, Vector3(0.23, 1.75, 0.23), Vector3(0, 0.875, 0), "bark")
		# 方形阶梯层保留松树的锥形剪影，不依赖细叶和圆锥面。
		_box(root, Vector3(1.40, 0.46, 1.30), Vector3(0, 1.18, 0), "pine")
		_box(root, Vector3(1.08, 0.44, 1.02), Vector3(-0.04, 1.57, 0.02), "pine", Color("aebdaa"))
		_box(root, Vector3(0.76, 0.43, 0.72), Vector3(0.03, 1.94, -0.02), "pine")
		_box(root, Vector3(0.44, 0.41, 0.42), Vector3(0.0, 2.28, 0), "pine", Color("b8c5ad"))
		_box(root, Vector3(0.20, 0.31, 0.20), Vector3(0, 2.60, 0), "pine")
		return
	_box(root, Vector3(0.28, 1.95, 0.28), Vector3(0.0, 0.975, 0), "bark")
	_branch(root, Vector3(0, 1.05, 0), Vector3(-0.53, 1.72, 0.15), 0.16)
	_branch(root, Vector3(0, 1.18, 0), Vector3(0.48, 1.90, -0.10), 0.16)
	if kind == "oak":
		_box(root, Vector3(1.45, 0.70, 1.22), Vector3(-0.05, 1.92, 0.02), "leaves")
		_box(root, Vector3(1.04, 0.60, 1.00), Vector3(0.10, 2.43, -0.03), "leaves", Color("b8c9a8"))
		_box(root, Vector3(0.71, 0.58, 0.80), Vector3(-0.57, 1.68, 0.16), "leaves", Color("a1b292"))
		_box(root, Vector3(0.65, 0.56, 0.66), Vector3(0.58, 2.02, -0.10), "leaves")
	else:
		_box(root, Vector3(1.16, 0.72, 1.05), Vector3(-0.20, 2.06, 0.08), "leaves")
		_box(root, Vector3(0.82, 0.69, 0.84), Vector3(0.23, 2.57, -0.12), "leaves", Color("c1c9a7"))
		_box(root, Vector3(0.75, 0.69, 0.74), Vector3(-0.58, 1.62, 0.15), "leaves", Color("a6b394"))
		_box(root, Vector3(0.80, 0.61, 0.78), Vector3(0.48, 1.90, -0.14), "leaves")
		_box(root, Vector3(0.71, 0.55, 0.65), Vector3(0.05, 1.74, 0.50), "leaves", Color("a8b899"))
	# 根部只留两块粗体积，便于与砍伐后的方树桩对应。
	_box(root, Vector3(0.49, 0.13, 0.24), Vector3(0.04, 0.065, 0), "bark")
	_box(root, Vector3(0.24, 0.13, 0.45), Vector3(0, 0.065, -0.03), "bark")

static func _make_small(root: Node3D, kind: String) -> void:
	match kind:
		"rock":
			_box(root, Vector3(0.85, 0.56, 0.76), Vector3(0, 0.28, 0), "stone")
			_box(root, Vector3(0.59, 0.20, 0.56), Vector3(0.10, 0.66, -0.05), "stone", Color("b8bdb0"))
			_box(root, Vector3(0.24, 0.29, 0.38), Vector3(-0.45, 0.145, 0.13), "stone")
		"rock_flat":
			_box(root, Vector3(0.82, 0.13, 0.68), Vector3(0, 0.065, 0), "stone")
		"bush":
			_box(root, Vector3(0.82, 0.32, 0.65), Vector3(0, 0.16, 0), "leaves", Color("b0bda0"))
			_box(root, Vector3(0.47, 0.23, 0.44), Vector3(-0.10, 0.42, 0.02), "leaves")
			_box(root, Vector3(0.30, 0.24, 0.37), Vector3(0.40, 0.12, 0.07), "leaves")
		"grass":
			_box(root, Vector3(0.06, 0.32, 0.06), Vector3(-0.10, 0.16, 0), "grass")
			_box(root, Vector3(0.07, 0.42, 0.07), Vector3(0.02, 0.21, 0.03), "grass")
			_box(root, Vector3(0.06, 0.24, 0.06), Vector3(0.14, 0.12, -0.02), "grass")
			_box(root, Vector3(0.11, 0.07, 0.06), Vector3(-0.14, 0.23, 0), "grass")
			_box(root, Vector3(0.11, 0.07, 0.06), Vector3(0.07, 0.33, 0.03), "grass")
		"stump":
			_box(root, Vector3(0.34, 0.25, 0.34), Vector3(0, 0.125, 0), "bark")
			_box(root, Vector3(0.32, 0.025, 0.32), Vector3(0, 0.2625, 0), "cutwood")
			_box(root, Vector3(0.52, 0.09, 0.22), Vector3(0.01, 0.045, 0), "bark")
			_box(root, Vector3(0.22, 0.09, 0.49), Vector3(0, 0.045, 0.02), "bark")
		"logs":
			for position in [Vector3(-0.16, 0.15, 0), Vector3(0.16, 0.15, 0), Vector3(0, 0.44, 0.02)]:
				_box(root, Vector3(0.28, 0.28, 1.05), position, "bark")
				for sign_value in [-1.0, 1.0]:
					_box(root, Vector3(0.24, 0.24, 0.012), position + Vector3(0, 0, sign_value * 0.53), "cutwood")
		"flower":
			_box(root, Vector3(0.04, 0.25, 0.04), Vector3(0, 0.125, 0), "grass")
			_box(root, Vector3(0.19, 0.05, 0.13), Vector3(0.01, 0.27, 0), "plaster", Color("d3b168"))
			_box(root, Vector3(0.09, 0.05, 0.21), Vector3(0.01, 0.27, 0), "plaster", Color("d3b168"))
			_box(root, Vector3(0.06, 0.025, 0.06), Vector3(0.01, 0.3075, 0), "cutwood")

static func _cache_model(kind: String) -> void:
	var model := Node3D.new()
	model.name = "BlockGeometry"
	if kind in ["oak", "broadleaf", "pine"]:
		_make_tree(model, kind)
	else:
		_make_small(model, kind)
	var bounds := AABB()
	var first := true
	for child: MeshInstance3D in model.get_children():
		var box: AABB = child.transform * child.get_aabb()
		bounds = box if first else bounds.merge(box)
		first = false
	_merge_by_material(model)
	_heights[kind] = bounds.size.y
	model.position = -Vector3(bounds.get_center().x, bounds.position.y, bounds.get_center().z)
	var wrapper := Node3D.new()
	wrapper.name = "PixelNature_" + kind
	wrapper.add_child(model)
	model.owner = wrapper
	for child in model.get_children():
		child.owner = wrapper
	var packed := PackedScene.new()
	var error := packed.pack(wrapper)
	if error == OK:
		_templates[kind] = packed
	else:
		push_error("Failed to pack pixel nature model %s: %d" % [kind, error])
	wrapper.free()

static func _merge_by_material(root: Node3D) -> void:
	# 在原型入缓存前合批：每丛草只需一个网格，树冠与树干也按共用材质合并。
	var batches: Dictionary = {}
	var materials: Dictionary = {}
	for child: MeshInstance3D in root.get_children():
		var key := child.material_override.get_instance_id()
		if not batches.has(key):
			var builder := SurfaceTool.new()
			builder.begin(Mesh.PRIMITIVE_TRIANGLES)
			batches[key] = builder
			materials[key] = child.material_override
		for surface_index in range(child.mesh.get_surface_count()):
			batches[key].append_from(child.mesh, surface_index, child.transform)
	for child in root.get_children():
		child.free()
	for key in batches:
		var merged := MeshInstance3D.new()
		merged.mesh = batches[key].commit()
		merged.material_override = materials[key]
		root.add_child(merged)
