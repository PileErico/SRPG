extends RefCounted
## 静态三角网格的物体面 UV：一个 UV 单位等于一个模型长度单位。
## UV 随网格移动/旋转；各面使用正交基，斜面不会像主轴投影那样压缩。
## uniform uv_scale 用于补偿实例后续的等比缩放，不支持非等比实例缩放。

static func convert(mesh: Mesh, uv_scale: float = 1.0) -> ArrayMesh:
	return _convert_mesh(mesh, uv_scale)

static func _convert_mesh(mesh: Mesh, uv_scale: float) -> ArrayMesh:
	var result := ArrayMesh.new()
	for surface_index in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()
		var uv2: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2] if arrays[Mesh.ARRAY_TEX_UV2] != null else PackedVector2Array()
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var count := indices.size() if not indices.is_empty() else vertices.size()
		var builder := SurfaceTool.new()
		builder.begin(Mesh.PRIMITIVE_TRIANGLES)
		builder.set_material(mesh.surface_get_material(surface_index))
		for offset in range(0, count - 2, 3):
			var ia := indices[offset] if not indices.is_empty() else offset
			var ib := indices[offset + 1] if not indices.is_empty() else offset + 1
			var ic := indices[offset + 2] if not indices.is_empty() else offset + 2
			var a := vertices[ia]
			var b := vertices[ib]
			var c := vertices[ic]
			# Godot 正面使用顺时针三角形，几何法线取叉积的反向。
			var face_normal := -(b - a).cross(c - a)
			if face_normal.length_squared() < 0.000000001:
				continue
			face_normal = face_normal.normalized()
			var basis := _face_basis(face_normal)
			for index in [ia, ib, ic]:
				var vertex := vertices[index]
				builder.set_normal(normals[index] if not normals.is_empty() else face_normal)
				builder.set_uv(Vector2(vertex.dot(basis[0]), vertex.dot(basis[1])) * uv_scale)
				if not colors.is_empty():
					builder.set_color(colors[index])
				if not uv2.is_empty():
					builder.set_uv2(uv2[index])
				builder.add_vertex(vertex)
		builder.commit(result)
	return result

static func scaled_uv(mesh: Mesh, uniform_scale: float) -> ArrayMesh:
	# 仅缩放已有 UV；几何、法线、颜色与表面材质保持原样。
	var result := ArrayMesh.new()
	for surface_index in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface_index)
		if arrays[Mesh.ARRAY_TEX_UV] == null:
			return _convert_mesh(mesh, uniform_scale)
		var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		for i in range(uv.size()):
			uv[i] *= uniform_scale
		arrays[Mesh.ARRAY_TEX_UV] = uv
		result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		result.surface_set_material(surface_index, mesh.surface_get_material(surface_index))
	return result

static func _face_basis(normal: Vector3) -> Array[Vector3]:
	var reference := Vector3.RIGHT if absf(normal.x) < 0.9 else Vector3.BACK
	var u := (reference - normal * reference.dot(normal)).normalized()
	var v := normal.cross(u).normalized()
	# 轴对齐立面保持纹理向上，水平面保持 +Z；正反面不会倒置木纹。
	var up := Vector3.BACK if absf(normal.y) > 0.9 else Vector3.UP
	if v.dot(up) < 0.0:
		v = -v
	return [u, v]
