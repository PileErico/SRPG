extends RefCounted
## 换装换色合成核：把「一份外观配方」合成为一张角色图（Image / ImageTexture / 导出 PNG）。
## 纯静态无状态，仿 HexTileRender/TextureCache：extends RefCounted + 静态 + 无 class_name（headless 友好）。
##
## 配方 recipe := { "parts": {slot_id: part_id}, "palettes": {slot_id: palette_id} }
##   parts 缺某槽＝该槽不画；palettes 缺某槽＝用该部件的 default_palette（部件 recolorable=false 则原样不染）。
## 换色＝按像素亮度映射到调色板渐变（灰度源 + 调色板，免多发 PNG）。合成＝按槽位 z 序 alpha 叠加。
## 导出＝把合成 Image 落成 PNG——**这张 PNG 就是本模块唯一对外产物**，其他模块经现有 Unit.portrait/icon 路径消费。
## 分层只是编辑态；不改地图即时模式渲染（解耦）。

const AppearanceDB := preload("res://AppearanceDB.gd")
const TextureCache := preload("res://TextureCache.gd")

# 亮度权重（Rec.601），与换色 shader 一致。
const LUMA := Vector3(0.299, 0.587, 0.114)

static var _bake_cache := {}   # 配方签名 -> ImageTexture（换装/换色才重烘）
static var _img_cache := {}    # 部件贴图 Image 缓存（编辑部件后须 clear_cache 清，否则显示旧图）

# —— 换色（纯函数）——

# 把一张图按亮度重映射到调色板渐变；返回**新** Image（不改入参）。stops 为 PackedColorArray（≥1）。
static func recolor(src: Image, stops: PackedColorArray) -> Image:
	var w := src.get_width()
	var h := src.get_height()
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	if stops.is_empty():
		out.copy_from(src)
		return out
	for y in h:
		for x in w:
			var c := src.get_pixel(x, y)
			if c.a <= 0.0:
				out.set_pixel(x, y, Color(0, 0, 0, 0))
				continue
			var l: float = clampf(c.r * LUMA.x + c.g * LUMA.y + c.b * LUMA.z, 0.0, 1.0)
			var mapped := _ramp(stops, l)
			out.set_pixel(x, y, Color(mapped.r, mapped.g, mapped.b, c.a))
	return out

# 在色标间线性插值（t∈[0,1]）。N 个色标均匀分布。端点返回精确色标（避免 clamp 掉最后 1/255）。
static func _ramp(stops: PackedColorArray, t: float) -> Color:
	var n := stops.size()
	if n == 1:
		return stops[0]
	t = clampf(t, 0.0, 1.0)
	if t >= 1.0:
		return stops[n - 1]
	var s := t * float(n - 1)
	var i := int(floor(s))
	if i >= n - 1:
		return stops[n - 1]
	var f := s - float(i)
	return stops[i].lerp(stops[i + 1], f)

# 调色板 id → PackedColorArray（读 DB 的 hex 色标）。找不到返回空。
static func stops_of(palette_id: String) -> PackedColorArray:
	var out := PackedColorArray()
	var pal = AppearanceDB.get_palette(palette_id)
	if pal == null:
		return out
	for hex in pal.get("stops", []):
		out.append(Color.html(str(hex)))
	return out

# —— 合成 ——

# 取部件贴图为 RGBA8 Image。**直接从磁盘 Image.load**（不走 TextureCache 的 load() 优先——
# 运行期编辑覆写 PNG 后 load()/导入资源会返回旧图；这里读原始字节，配合 _img_cache + clear_cache 保证编辑后即时刷新）。
# 结果只读（调用方 recolor 返回新图、blend_rect/create_from_image 只读它）。缺失返回 null。
static func _part_image(path: String) -> Image:
	if _img_cache.has(path):
		return _img_cache[path] as Image
	var img := Image.new()
	if path == "" or not FileAccess.file_exists(path) or img.load(path) != OK:
		_img_cache[path] = null
		return null
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	_img_cache[path] = img
	return img

# 按配方合成为一张 Image（RGBA8，边长＝AppearanceDB.canvas_size）。
static func compose(recipe: Dictionary) -> Image:
	var size := AppearanceDB.canvas_size()
	var base := Image.create(size, size, false, Image.FORMAT_RGBA8)
	base.fill(Color(0, 0, 0, 0))
	var parts: Dictionary = recipe.get("parts", {})
	var palettes: Dictionary = recipe.get("palettes", {})
	for slot in AppearanceDB.slots():
		var slot_id := str(slot.get("id", ""))
		var part_id := str(parts.get(slot_id, ""))
		if part_id == "":
			continue
		var part = AppearanceDB.get_part(part_id)
		if part == null:
			continue
		var img := _part_image(str(part.get("path", "")))
		if img == null:
			continue
		# 换色：配方指定的调色板优先，否则用部件 default_palette；recolorable=false 则原样
		if bool(part.get("recolorable", false)):
			var pal_id := str(palettes.get(slot_id, part.get("default_palette", "")))
			if pal_id != "":
				var stops := stops_of(pal_id)
				if not stops.is_empty():
					img = recolor(img, stops)
		# 同尺寸同锚点，直接叠在 (0,0)；尺寸不符则居中裁贴（宽容）
		var dst := Vector2i(int((size - img.get_width()) / 2.0), int((size - img.get_height()) / 2.0))
		base.blend_rect(img, Rect2i(0, 0, img.get_width(), img.get_height()), dst)
	return base

# 合成为 ImageTexture（按配方签名缓存；换装/换色才重烘）。
static func bake(recipe: Dictionary) -> ImageTexture:
	var sig := _sig(recipe)
	if _bake_cache.has(sig):
		return _bake_cache[sig]
	var tex := ImageTexture.create_from_image(compose(recipe))
	_bake_cache[sig] = tex
	return tex

# 导出 PNG（scale≥1，最近邻放大）。这张 PNG＝本模块对外产物。写盘失败返回 false。
static func export_png(recipe: Dictionary, path: String, scale: int = 1) -> bool:
	var img := compose(recipe)
	if scale > 1:
		img.resize(img.get_width() * scale, img.get_height() * scale, Image.INTERPOLATE_NEAREST)
	return img.save_png(path) == OK

static func clear_cache() -> void:
	_bake_cache.clear()
	_img_cache.clear()

static func _sig(recipe: Dictionary) -> String:
	var parts: Dictionary = recipe.get("parts", {})
	var palettes: Dictionary = recipe.get("palettes", {})
	var keys := parts.keys()
	keys.sort()
	var s := ""
	for k in keys:
		s += "%s=%s:%s|" % [k, parts[k], palettes.get(k, "")]
	return s
