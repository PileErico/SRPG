extends RefCounted
## 河流/海面共用现有色板和世界投影；16×16静态图案、每单位16纹素。
## 2～4纹素宽的短横波纹，不使用透明、反射、动画或额外颜色。

const Materials := preload("res://samples/forest_3d/PixelMaterials.gd")
const SurfaceShader := preload("res://samples/forest_3d/pixel_surface.gdshader")
const SHALLOW_PATTERN := [
	"11111111", "11221111", "11111111", "11111111",
	"11111001", "11111111", "21111111", "11111111",
]
const DEEP_PATTERN := [
	"00000000", "00011000", "00000000", "00000000",
	"01000000", "00000000", "00000020", "00000000",
]

static var _materials: Dictionary = {}

static func get_material(deep: bool = false) -> ShaderMaterial:
	if _materials.has(deep):
		return _materials[deep]
	var colors := [Materials.color("iron"), Materials.color("cloth"), Materials.color("cloth_light")]
	var pattern: Array = DEEP_PATTERN if deep else SHALLOW_PATTERN
	var picture := Image.create(Materials.SIZE, Materials.SIZE, false, Image.FORMAT_RGBA8)
	for y in range(Materials.SIZE):
		var row: String = pattern[y / 2]
		for x in range(Materials.SIZE):
			picture.set_pixel(x, y, colors[int(row.substr(x / 2, 1))])
	var material := ShaderMaterial.new()
	material.resource_name = "PixelSeaWater" if deep else "PixelRiverWater"
	material.shader = SurfaceShader
	material.set_shader_parameter("pixel_texture", ImageTexture.create_from_image(picture))
	material.set_shader_parameter("texels_per_unit", Materials.TEXELS_PER_UNIT)
	material.set_shader_parameter("use_mesh_uv", false)
	material.set_shader_parameter("palette_dark", colors[0])
	material.set_shader_parameter("palette_mid", colors[1])
	material.set_shader_parameter("palette_light", colors[2])
	_materials[deep] = material
	return material
