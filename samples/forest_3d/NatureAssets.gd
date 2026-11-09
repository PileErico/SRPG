extends RefCounted
## Kenney Nature Kit 的小样用选集：运行时读 GLB，不依赖编辑器预导入。
## 返回纯视觉节点，阻挡与砍伐规则由场景宿主管理。

const DIR := "res://samples/forest_3d/assets/nature/"
const FILES := {
	"oak": "tree_oak.glb",
	"broadleaf": "tree_detailed.glb",
	"pine": "tree_pineDefaultA.glb",
	"rock": "stone_tallE.glb",
	"rock_flat": "stone_smallFlatA.glb",
	"bush": "plant_bushDetailed.glb",
	"grass": "grass.glb",
	"stump": "stump_roundDetailed.glb",
	"logs": "log_stack.glb",
	"flower": "flower_yellowA.glb",
}
const HEIGHTS := {
	"oak": 2.5, "broadleaf": 2.65, "pine": 3.1,
	"rock": 0.55, "rock_flat": 0.15, "bush": 0.42,
	"grass": 0.16, "stump": 0.25, "logs": 0.4, "flower": 0.22,
}
const COLORS := {
	"leafsGreen": Color("657b47"),
	"leafsDark": Color("3f614c"),
	"leafsOrange": Color("a88c51"),
	"leafsYellow": Color("b3a066"),
	"grass": Color("77814d"),
	"woodBark": Color("675040"),
	"woodBarkDark": Color("51473a"),
	"wood": Color("ad8b5b"),
	"woodLight": Color("c1a175"),
	"woodInner": Color("c1a175"),
	"stone": Color("8d9184"),
	"dirt": Color("7b7057"),
	"flowerYellow": Color("d4b461"),
	"colorYellow": Color("d4b461"),
}

static var _templates: Dictionary = {}
static var _original_bounds: Dictionary = {}

static func instantiate_model(kind: String, target_height: float = -1.0) -> Node3D:
	if not FILES.has(kind):
		push_error("Unknown nature model: " + kind)
		return Node3D.new()
	if not _templates.has(kind):
		_load_template(kind)
	if not _templates.has(kind):
		return Node3D.new()
	var result: Node3D = _templates[kind].instantiate()
	var original: AABB = _original_bounds[kind]
	var height: float = target_height if target_height > 0.0 else HEIGHTS[kind]
	result.scale = Vector3.ONE * height / maxf(original.size.y, 0.001)
	return result

static func original_bounds(kind: String) -> AABB:
	if not _templates.has(kind) and FILES.has(kind):
		_load_template(kind)
	return _original_bounds.get(kind, AABB())

static func _load_template(kind: String) -> void:
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	var error := document.append_from_file(DIR + FILES[kind], state)
	if error != OK:
		push_error("Cannot load nature model %s (error %d)" % [kind, error])
		return
	var model: Node3D = document.generate_scene(state)
	if model == null:
		return
	var bounds: Array[AABB] = []
	_collect_bounds(model, Transform3D.IDENTITY, bounds)
	var box := AABB()
	if not bounds.is_empty():
		box = bounds[0]
		for i in range(1, bounds.size()):
			box = box.merge(bounds[i])
	_original_bounds[kind] = box
	var wrapper := Node3D.new()
	wrapper.name = "Nature_" + kind
	wrapper.add_child(model)
	# 不改原始 GLB；由包装节点将底面和水平中心归到摆放点。
	model.position -= Vector3(box.get_center().x, box.position.y, box.get_center().z)
	_prepare_nodes(model, wrapper)
	var packed := PackedScene.new()
	if packed.pack(wrapper) == OK:
		_templates[kind] = packed
	wrapper.free()

static func _collect_bounds(node: Node, inherited: Transform3D, result: Array[AABB]) -> void:
	var current := inherited
	if node is Node3D:
		current = inherited * node.transform
	if node is MeshInstance3D:
		result.append(current * node.get_aabb())
	for child in node.get_children():
		_collect_bounds(child, current, result)

static func _prepare_nodes(node: Node, owner_root: Node) -> void:
	node.owner = owner_root
	if node is MeshInstance3D and node.mesh != null:
		for i in range(node.mesh.get_surface_count()):
			var source: Material = node.get_active_material(i)
			if source is StandardMaterial3D:
				var material: StandardMaterial3D = source.duplicate()
				material.albedo_color = COLORS.get(source.resource_name, source.albedo_color)
				material.metallic = 0.0
				material.roughness = 1.0
				node.set_surface_override_material(i, material)
	for child in node.get_children():
		_prepare_nodes(child, owner_root)
