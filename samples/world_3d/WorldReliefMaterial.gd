extends RefCounted
## 连续世界地表专用材料：沿用草/石三色，按世界高度与像素色簇切换。
## 只复用共享纹理与色板；不改战斗材质或共享 shader。

const PixelMaterials := preload("res://samples/forest_3d/PixelMaterials.gd")
const ReliefShader := preload("res://samples/world_3d/world_relief.gdshader")

static var _material: ShaderMaterial

static func get_material() -> ShaderMaterial:
	if _material != null:
		return _material
	_material = ShaderMaterial.new()
	_material.shader = ReliefShader
	# get_material 只借用缓存纹理，参数修改始终发生在本专属材料上。
	var grass := PixelMaterials.get_material("grass") as ShaderMaterial
	var stone := PixelMaterials.get_material("stone") as ShaderMaterial
	_material.set_shader_parameter("grass_texture", grass.get_shader_parameter("pixel_texture"))
	_material.set_shader_parameter("stone_texture", stone.get_shader_parameter("pixel_texture"))
	for index in range(3):
		var suffix: String = ["dark", "mid", "light"][index]
		_material.set_shader_parameter("grass_" + suffix, PixelMaterials.palette_color("grass", index))
		_material.set_shader_parameter("stone_" + suffix, PixelMaterials.palette_color("stone", index))
	_material.set_shader_parameter("texels_per_unit", PixelMaterials.TEXELS_PER_UNIT)
	_material.set_shader_parameter("rock_start", 0.50)
	_material.set_shader_parameter("rock_full", 0.90)
	_material.set_shader_parameter("cluster_texels", 8.0)
	_material.set_shader_parameter("shade_direction", Vector3(-0.6, 0.8, 0.45))
	_material.set_shader_parameter("shadow_threshold", 0.70)
	_material.set_shader_parameter("highlight_threshold", 0.88)
	return _material
