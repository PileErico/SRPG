extends RefCounted
## 贴地的双色像素接触影；仅视觉，随所属物件一起生成与删除。

const PixelMaterials := preload("res://samples/forest_3d/PixelMaterials.gd")
static var _materials: Dictionary = {}

static func make(size: Vector2, rectangular: bool = false) -> MeshInstance3D:
	var pixels := Vector2i(maxi(4, roundi(size.x * 16.0)), maxi(4, roundi(size.y * 16.0)))
	var key := "%d:%d:%s" % [pixels.x, pixels.y, rectangular]
	if not _materials.has(key):
		var picture := Image.create(pixels.x, pixels.y, false, Image.FORMAT_RGBA8)
		var mask: Dictionary = {}
		for y in range(pixels.y):
			for x in range(pixels.x):
				var p := (Vector2(x, y) + Vector2.ONE * 0.5) / Vector2(pixels) * 2.0 - Vector2.ONE
				if (rectangular and absf(p.x) + absf(p.y) < 1.85) or (not rectangular and p.length_squared() <= 1.0):
					mask[Vector2i(x, y)] = true
		for point: Vector2i in mask:
			var edge := false
			for direction in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				if not mask.has(point + direction):
					edge = true
			picture.set_pixelv(point, PixelMaterials.color("ground_shadow" if edge else "contact_shadow"))
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		material.alpha_scissor_threshold = 0.5
		material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.albedo_texture = ImageTexture.create_from_image(picture)
		_materials[key] = material
	var shadow := MeshInstance3D.new()
	shadow.name = "ContactShadow"
	shadow.set_meta("sample_contact_shadow", true)
	var plane := PlaneMesh.new()
	plane.size = Vector2(pixels) / 16.0
	shadow.mesh = plane
	shadow.material_override = _materials[key]
	shadow.position.y = 0.003
	shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return shadow
