extends RefCounted
## 场景共用32色；16×16手排图案，每材质三个基础色、每世界单位16个纹素。
## 草地与树冠明度分离；颜色统一由色板控制，不生成任意 tint 衍生色。

const SurfaceShader := preload("res://samples/forest_3d/pixel_surface.gdshader")
const SIZE := 16
const TEXELS_PER_UNIT := 16.0
const SCENE_PALETTE := {
	"outline": "141c18",
	"contact_shadow": "26352b",
	"ground_shadow": "727c5c",
	"ground": "929a72",
	"ground_light": "a8ad84",
	"earth_dark": "494133",
	"earth": "6d5941",
	"earth_light": "8b7454",
	"sand_dark": "9a805c",
	"sand": "b39a6d",
	"sand_light": "cab486",
	"wood_dark": "493427",
	"wood": "795335",
	"wood_light": "a17b4e",
	"foliage_dark": "253d33",
	"foliage": "3d6047",
	"foliage_light": "5d8058",
	"pine_mid": "334c3d",
	"stone_dark": "535c58",
	"stone": "848c83",
	"stone_light": "b4b9a7",
	"roof_dark": "533b34",
	"roof": "875844",
	"roof_light": "b47c58",
	"plaster": "b8ae91",
	"plaster_light": "d6ccb1",
	"iron": "46534e",
	"cloth": "58747b",
	"cloth_light": "8aa6a6",
	"ochre": "c2a66c",
	"cutwood": "b9935f",
	"cutwood_light": "d5b681",
}

# 每种材料只引用同一张色板里的三个名字，不另建近似色。
const PALETTES := {
	"grass": ["ground_shadow", "ground", "ground_light"],
	"dirt": ["sand_dark", "sand", "sand_light"],
	"earth": ["earth_dark", "earth", "earth_light"],
	"stone": ["stone_dark", "stone", "stone_light"],
	"stone_brick": ["stone_dark", "stone", "stone_light"],
	"wood": ["wood_dark", "wood", "wood_light"],
	"bark": ["wood_dark", "wood", "earth_light"],
	"leaves": ["foliage_dark", "foliage", "foliage_light"],
	"pine": ["foliage_dark", "pine_mid", "foliage"],
	"roof": ["roof_dark", "roof", "roof_light"],
	"plaster": ["earth_light", "plaster", "plaster_light"],
	"iron": ["outline", "iron", "stone"],
	"cloth": ["contact_shadow", "cloth", "cloth_light"],
	"cutwood": ["wood_light", "cutwood", "cutwood_light"],
	"dark": ["outline", "contact_shadow", "foliage_dark"],
}

# 0=暗色，1=主色，2=亮色。设计格放大成2×2纹素色簇，输出仍是16×16源图。
# 稀疏主色面为主，纹理变化只取几个明确色区。
const PATTERNS := {
	"grass": [
		"11111111", "11221111", "11111111", "11111111",
		"11111001", "11111011", "11111111", "11111111"],
	"dirt": [
		"11111111", "11111111", "12211111", "11111111",
		"11111111", "11111001", "11111101", "11111111"],
	"earth": [
		"11111111", "11111111", "22221111", "11111111",
		"11111111", "11111111", "00000000", "11111111"],
	"stone": [
		"11111111", "11222111", "11111111", "11111111",
		"11111111", "11111001", "11111011", "11111111"],
	"stone_brick": [
		"00000000", "01111111", "01111111", "01222111",
		"00000000", "11110111", "11110111", "22110122"],
	"wood": [
		"01110111", "02110111", "02110111", "01110111",
		"01110111", "01110121", "01110121", "01110111"],
	"bark": [
		"11110111", "11110111", "21110111", "21111101",
		"11111101", "11111101", "11110111", "11110111"],
	"leaves": [
		"11111111", "11221111", "11121111", "11111111",
		"11111111", "11111000", "11111100", "11111111"],
	"pine": [
		"11111111", "11122111", "11111111", "11111111",
		"11111111", "00111111", "00011111", "11111111"],
	"roof": [
		"00000000", "11110111", "11110111", "12210122",
		"00000000", "01111111", "01111111", "01221111"],
	"plaster": [
		"11111111", "11111111", "11111111", "11111111",
		"11111011", "11111111", "11111111", "11111111"],
	"iron": [
		"11111111", "12111111", "11111111", "11111111",
		"11111111", "11111111", "11111111", "11111111"],
	"cloth": [
		"11111111", "11111111", "11111111", "11111111",
		"11111111", "11111111", "11111111", "00000000"],
	"cutwood": [
		"11111111", "10000001", "10222201", "10211201",
		"10211201", "10222201", "10000001", "11111111"],
	"dark": [
		"11111111", "11111111", "11111111", "11111111",
		"11111111", "11111111", "11111111", "11111110"],
}

static var _textures: Dictionary = {}
static var _materials: Dictionary = {}

@warning_ignore("unused_parameter")
static func get_material(kind: String, tint: Color = Color.WHITE, use_mesh_uv: bool = false) -> Material:
	if not PALETTES.has(kind):
		push_error("Unknown pixel material: " + kind)
		kind = "stone"
	# 保留 tint 调用接口；本版每种材料只有一套固定色板。
	var key := kind + (":uv" if use_mesh_uv else ":world")
	if _materials.has(key):
		return _materials[key]
	if not _textures.has(kind):
		_textures[kind] = ImageTexture.create_from_image(make_texture_image(kind))
	var material := ShaderMaterial.new()
	material.shader = SurfaceShader
	material.set_shader_parameter("pixel_texture", _textures[kind])
	material.set_shader_parameter("texels_per_unit", TEXELS_PER_UNIT)
	material.set_shader_parameter("use_mesh_uv", use_mesh_uv)
	material.set_shader_parameter("palette_dark", palette_color(kind, 0))
	material.set_shader_parameter("palette_mid", palette_color(kind, 1))
	material.set_shader_parameter("palette_light", palette_color(kind, 2))
	_materials[key] = material
	return material

static func color(name: String) -> Color:
	if not SCENE_PALETTE.has(name):
		push_error("Unknown scene color: " + name)
		return Color(SCENE_PALETTE.outline)
	return Color(SCENE_PALETTE[name])

static func palette_color(kind: String, index: int) -> Color:
	var palette: Array = PALETTES.get(kind, PALETTES.stone)
	return color(palette[clampi(index, 0, palette.size() - 1)])

static func make_texture_image(kind: String) -> Image:
	var pattern: Array = PATTERNS.get(kind, PATTERNS.stone)
	var picture := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	for y in range(SIZE):
		var row: String = pattern[y / 2]
		for x in range(SIZE):
			picture.set_pixel(x, y, palette_color(kind, int(row.substr(x / 2, 1))))
	return picture
