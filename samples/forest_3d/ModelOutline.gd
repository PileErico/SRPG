extends RefCounted
## 场景物件黑描边：整个物件共用一层倒壳，不改变原材质、深度、阴影或碰撞。
## 壳的共享位置法线跨材质合并，移除完全重合的相反面；轮廓保留真实孔洞。

const OutlineShader := preload("res://samples/forest_3d/model_outline.gdshader")
const OUTLINE_META := &"sample_model_outline"
const APPLIED_META := &"sample_model_outline_applied"

static var _mesh_cache: Dictionary = {}
static var _material: ShaderMaterial

static func apply_to(root: Node3D) -> void:
	if root.has_meta(APPLIED_META):
		return
	_prune_cache()
	var sources: Array = []
	_collect_sources(root, Transform3D.IDENTITY, sources, true)
	if sources.is_empty():
		return
	var shell_mesh := _get_shell_mesh(sources)
	if shell_mesh.get_surface_count() == 0:
		return
	var shell := MeshInstance3D.new()
	shell.name = "ModelOutline"
	shell.set_meta(OUTLINE_META, true)
	shell.mesh = shell_mesh
	shell.material_override = _get_material()
	shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shell.extra_cull_margin = 0.25
	# 使用物件根的局部坐标；根节点缩放、旋转、显隐和删除仍自动作用于壳。
	root.add_child(shell)
	root.set_meta(APPLIED_META, true)

static func set_visible(root: Node, visible: bool) -> void:
	if root.has_meta(OUTLINE_META) and root is GeometryInstance3D:
		root.visible = visible
		return
	for child in root.get_children():
		set_visible(child, visible)

static func _collect_sources(node: Node, inherited: Transform3D, result: Array, is_root: bool = false) -> void:
	if node.has_meta(OUTLINE_META) or node.has_meta(&"sample_contact_shadow"):
		return
	if not is_root and node.has_meta(APPLIED_META):
		return
	var transform := inherited
	if node is Node3D:
		if not node.visible:
			return
		if not is_root:
			transform = inherited * node.transform
	if node is MeshInstance3D and node.mesh != null:
		if node.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
			result.append({"mesh": node.mesh, "transform": transform})
	for child in node.get_children():
		_collect_sources(child, transform, result)

static func _get_material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = OutlineShader
		_material.set_shader_parameter("outline_color", Color.BLACK)
		_material.set_shader_parameter("outline_pixels", 1.0)
	return _material

static func set_pixel_width(width: float) -> void:
	_get_material().set_shader_parameter("outline_pixels", maxf(width, 0.0))

static func set_color(color: Color) -> void:
	_get_material().set_shader_parameter("outline_color", color)

static func _position_key(point: Vector3) -> Vector3i:
	return Vector3i(roundi(point.x * 10000.0), roundi(point.y * 10000.0), roundi(point.z * 10000.0))

static func _prune_cache() -> void:
	for key in _mesh_cache.keys():
		for source: WeakRef in _mesh_cache[key].sources:
			if source.get_ref() == null:
				_mesh_cache.erase(key)
				break

static func _get_shell_mesh(sources: Array) -> ArrayMesh:
	var keys := PackedStringArray()
	for source: Dictionary in sources:
		keys.append("%d:%s" % [source.mesh.get_instance_id(), str(source.transform)])
	var cache_key := "|".join(keys)
	if _mesh_cache.has(cache_key):
		return _mesh_cache[cache_key].shell
	var faces: Array = []
	var coincident: Dictionary = {}
	for source: Dictionary in sources:
		_append_faces(source.mesh, source.transform, faces, coincident)
	var normal_buckets: Dictionary = {}
	for face: Dictionary in faces:
		if not face.keep:
			continue
		for i in range(3):
			var key := _position_key(face.positions[i])
			if not normal_buckets.has(key):
				normal_buckets[key] = {}
			normal_buckets[key][_position_key(face.normals[i])] = face.normals[i]
	var smooth: Dictionary = {}
	for key in normal_buckets:
		var total := Vector3.ZERO
		for normal: Vector3 in normal_buckets[key].values():
			total += normal
		smooth[key] = total.normalized()
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	for face: Dictionary in faces:
		if not face.keep:
			continue
		for i in range(3):
			var point: Vector3 = face.positions[i]
			var normal: Vector3 = smooth[_position_key(point)]
			vertices.append(point)
			normals.append(normal if normal.length_squared() > 0.001 else face.normals[i])
	var shell := ArrayMesh.new()
	if not vertices.is_empty():
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = normals
		shell.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var references: Array[WeakRef] = []
	for source: Dictionary in sources:
		references.append(weakref(source.mesh))
	_mesh_cache[cache_key] = {"sources": references, "shell": shell}
	return shell

static func _append_faces(mesh: Mesh, transform: Transform3D, faces: Array, coincident: Dictionary) -> void:
	var normal_basis := transform.basis.inverse().transposed()
	for surface_index in range(mesh.get_surface_count()):
		if mesh is ArrayMesh and mesh.surface_get_primitive_type(surface_index) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays := mesh.surface_get_arrays(surface_index)
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if arrays[Mesh.ARRAY_NORMAL] == null:
			continue
		var source_normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		if source_normals.size() != positions.size():
			continue
		var indices := PackedInt32Array()
		if arrays[Mesh.ARRAY_INDEX] != null:
			indices = arrays[Mesh.ARRAY_INDEX]
		var count := indices.size() if not indices.is_empty() else positions.size()
		for i in range(0, count - 2, 3):
			var points: Array[Vector3] = []
			var normals: Array[Vector3] = []
			for j in range(3):
				var index: int = indices[i + j] if not indices.is_empty() else i + j
				points.append(transform * positions[index])
				normals.append((normal_basis * source_normals[index]).normalized())
			if transform.basis.determinant() < 0.0:
				var point := points[1]
				points[1] = points[2]
				points[2] = point
				var normal := normals[1]
				normals[1] = normals[2]
				normals[2] = normal
			var direction := (points[2] - points[0]).cross(points[1] - points[0])
			if direction.length_squared() < 0.0000000001:
				continue
			direction = direction.normalized()
			var sorted_keys: Array[String] = []
			for point in points:
				sorted_keys.append(str(_position_key(point)))
			sorted_keys.sort()
			var key := "|".join(sorted_keys)
			var matched := false
			for previous: int in coincident.get(key, []):
				if faces[previous].keep and direction.dot(faces[previous].direction) < -0.99:
					faces[previous].keep = false
					matched = true
					break
			if matched:
				continue
			if not coincident.has(key):
				coincident[key] = []
			coincident[key].append(faces.size())
			faces.append({"positions": points, "normals": normals, "direction": direction, "keep": true})
