extends RefCounted
## 地块渲染单一实现：把「一个六边形地块」（底色多边形 + 黑描边 + accent 线稿 decor）画到任意 CanvasItem。
## 谁用：HexCanvas 地图主循环（编辑器/战斗/大地图三画布）＋ 编辑器笔刷图块（TerrainSwatch）＋ 任何要显示「地块长什么样」的地方。
## 目的＝DRY：decor 线稿只此一处，改一处三画布 + 笔刷格全一致（杜绝「笔刷格 != 地图格」）。
## 纯静态无状态：绘制目标 ci、格心、半径、扰动种子由调用方传入（决定性——同种子同输出，_draw 每帧重入不闪）。
## 范式：extends RefCounted + 静态方法 + 无 class_name（headless 友好，仿 TerrainDB/HexGrid）。
## 注意：decor 偏移按半径 24（地图原始尺寸）设计；draw_tile 的 size 只改六边形大小，decor 用原生偏移——
##       故笔刷缩略图用接近 24 的半径（如 21）即与地图格一致；要更小的缩略图再引入 scale。

const TextureCache := preload("res://TextureCache.gd")   # 手绘瓦片贴图加载（get_tex：优先导入资源，回落 Image.load）

const DECOR_WIDTH := 1.6
# —— 像素地块烘焙参数 ——
# 瓦片美术分辨率（flat-top hex 外接框 宽×高）＝对齐 Unciv FantasyHex 底地形 32×28，也与角色 32px 素材统一像素密度。
# 32/28=1.143 正是 flat-top 比例（2/√3）；地图格宽 48 → 贴图 32 → NEAREST 放大 1.5× 呈块状像素。
const TILE_W := 32
const TILE_H := 28
const SQRT3 := 1.7320508
const TILE_VARIANTS := 3     # 每地形烘几张变体，散列选用破"印章"重复感
const SHADE_TOP := 0.08      # 顶光：上缘提亮
const SHADE_BOT := 0.10      # 顶光：下缘压暗
const EDGE_DARK := 0.14      # 像素边缘一圈压暗（格网可读 + 立体；别太重免鳞缝感）
# —— 对齐规范🔒（2026-07-04）——
# 平顶六边形「最宽处」＝左右两顶点、在竖直正中，称「赤道」。瓦片按【最宽行 ↔ 格心水平线】对齐，
# 等比缩放（目标宽 2·size / 贴图宽；art 32px → 48px 即 1.5×）。竖向的探出(山峰/树冠在赤道之上)
# 与收缩(水/冰画得矮、缩在赤道附近)全由 art 像素自带 → 不手算竖向锚点、不放大基准六边形。
# （旧 TILE_OVERLAP=1.14 会把「基准六边形」本身一起放大 → 美术溢出数学格、边线/点击错位，已废。）
const NOISE_HI := 0.90       # 抖色阈值：> 提亮（稀疏——只点缀 ~10% 像素，避免"重噪糊感"）
const NOISE_LO := 0.10       # 抖色阈值：< 压暗（~10%）
# 已烘成像素 decor 的地形（这些不再叠矢量 decor；其余仍走矢量线稿，后续逐步补）
const BAKED_DECOR := ["grass", "wave"]

static var _tile_cache := {}   # "颜色_accent_decor_变体" -> ImageTexture（程序烘焙，缓存复用）
static var _widest_cache := {}  # tex RID id -> 赤道行(最宽像素行中点)，加载时扫一遍缓存、per-frame 零成本

# 画一个地块：程序烘焙的像素 hex 底(含已像素化的 decor) + 未像素化 decor 暂留矢量线稿。
# center=格心；size=中心到顶点半径；seed=变体/扰动种子（0＝变体0，用于笔刷缩略图）；with_decor=false 时只画底。
## anchor：固定锚行（art 像素行）——放置物（道路/河流等非六边形叠加）用它钉赤道，缺省 -1＝回落最宽行（六边形地块本身）。
static func draw_tile(ci: CanvasItem, center: Vector2, size: float, color: Color, accent: Color, decor: String, seed: int = 0, with_decor: bool = true, art: Array = [], anchor: float = -1.0) -> void:
	# 赤道对齐 + 等比 1.5×（见文件头「对齐规范」）：贴图最宽行钉在格心水平线、宽=2·size，竖向由 art 自带。
	var dw := 2.0 * size
	# 优先：手绘变体贴图（按 seed 确定性选一张）；自带 decor/边缘，不再叠程序 decor
	# get_tex_file＝强制原始文件解码，免工坊运行期覆写后命中旧 .ctex
	if not art.is_empty():
		var htex := TextureCache.get_tex_file(pick_art(art, seed))
		if htex != null:
			_draw_equator(ci, htex, center, dw, anchor)
			return
	# 兜底：程序烘焙像素底（顶光/轻噪/像素 decor/像素边缘都已烘进纹理）
	var tex := _tile_tex(color, accent, decor, absi(seed) % TILE_VARIANTS)
	_draw_equator(ci, tex, center, dw)
	if with_decor and not BAKED_DECOR.has(decor):
		draw_decor(ci, decor, center, accent, seed)

# 赤道对齐画贴图：按目标宽 dw 等比缩放，令贴图「最宽行(赤道)」落在格心 center.y 上。
# 竖向探出/收缩全由 art 像素相对赤道的位置决定（山峰在赤道上方、土坎在下方），不做额外锚点。
static func _draw_equator(ci: CanvasItem, tex: Texture2D, center: Vector2, dw: float, anchor: float = -1.0) -> void:
	var tw := float(maxi(1, tex.get_width()))
	var scale := dw / tw
	var dh := float(tex.get_height()) * scale
	# 放置物（道路/河流等非六边形叠加）的「最宽行」在与六边形边接触处、不在赤道，按 _widest_row 会上下乱窜；
	# 给定 anchor(art 像素行) 则钉该行到格心 → 末端准落各边（与同格底地块共用赤道，见文件头对齐规范）。
	var row := anchor if anchor >= 0.0 else _widest_row(tex)
	var top := center.y - row * scale
	ci.draw_texture_rect(tex, Rect2(center.x - dw * 0.5, top, dw, dh), false)

# 取贴图「赤道行」＝不透明像素最多的行里【最高(最靠上)的那一行】。
# 为何取最高：最下面 3 行固定是崖裙（边线/假高度1/假高度2），会让贴图下半也接近满宽 → 最宽带向下延伸；
# 取中点会被崖裙带偏低（贴图整体偏高、黄框看着比地块低）。最宽带的顶沿才是六边形真赤道。按 tex RID 缓存、只扫一次。
static func _widest_row(tex: Texture2D) -> float:
	var rid_id := tex.get_rid().get_id()
	if _widest_cache.has(rid_id):
		return _widest_cache[rid_id]
	var row := _compute_widest_row(tex)
	_widest_cache[rid_id] = row
	return row

static func _compute_widest_row(tex: Texture2D) -> float:
	var img := tex.get_image()
	if img == null:
		return float(tex.get_height()) * 0.5   # 兜底：几何中点
	var h := img.get_height()
	var w := img.get_width()
	var counts := PackedInt32Array()
	counts.resize(h)
	var best := 0
	for y in h:
		var cnt := 0
		for x in w:
			if img.get_pixel(x, y).a > 0.4:
				cnt += 1
		counts[y] = cnt
		best = maxi(best, cnt)
	if best <= 0:
		return float(h) * 0.5
	# 最宽带里【最高的一行】＝真赤道（崖裙在其下、会把最宽带向下拖，故不取中点/底沿）。
	for y in h:
		if counts[y] >= best:
			return float(y)
	return float(h) * 0.5

# 手绘瓦片贴图分辨率（＝程序烘的 24×21，两条路 1:1 对齐）。
static func tile_px_size() -> Vector2i:
	return Vector2i(TILE_W, TILE_H)

# 像素坐标 (x,y) 是否落在瓦片 flat-top 六边形内（工坊 mask/轮廓与烘焙同一判定，永不漂移）。
static func tile_hex_contains(x: int, y: int) -> bool:
	var s := tile_px_size()
	return _in_hex(float(x) - float(s.x - 1) * 0.5, float(y) - float(s.y - 1) * 0.5, float(s.x) * 0.5)

# 按 seed 从变体数组确定性选一张路径（空→""）。纯函数、可测。
static func pick_art(art: Array, seed: int) -> String:
	return "" if art.is_empty() else str(art[absi(seed) % art.size()])

# 程序烘焙一张像素 hex 地面贴图（flat-top，宽 2·24/PPU、高 √3·24/PPU）：顶光渐变 + 轻噪 + 像素 decor + 像素边缘。
# 按 (color, accent, decor, variant) 缓存——同参只烘一次，画进静态块、per-frame 零成本。
static func _tile_tex(color: Color, accent: Color, decor: String, variant: int) -> ImageTexture:
	var key := "%d_%d_%s_%d" % [color.to_rgba32(), accent.to_rgba32(), decor, variant]
	if _tile_cache.has(key):
		return _tile_cache[key]
	var w := TILE_W    # 32
	var h := TILE_H    # 28
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var cx := (w - 1) * 0.5
	var cy := (h - 1) * 0.5
	var r := w * 0.5
	# 1) 填 hex 内部：顶光竖向渐变 + 稀疏轻噪（点缀而非满屏抖）
	for y in h:
		for x in w:
			if not _in_hex(float(x) - cx, float(y) - cy, r):
				continue
			var vt: float = clampf((float(y) - cy) / (h * 0.5), -1.0, 1.0)
			var c := color.lightened(-vt * SHADE_TOP) if vt < 0.0 else color.darkened(vt * SHADE_BOT)
			var n := _hash01(x, y, variant)
			if n > NOISE_HI:
				c = c.lightened(0.05)
			elif n < NOISE_LO:
				c = c.darkened(0.06)
			img.set_pixel(x, y, c)
	# 2) 像素化 decor（认真做草/水；其余地形靠矢量 decor 暂代）
	match decor:
		"grass": _bake_grass(img, accent, variant)
		"wave": _bake_wave(img, accent, variant)
	# 3) 像素边缘：hex 内、任一四邻为透明的贴边像素压暗（alpha 不变、边判定稳定）
	for y in h:
		for x in w:
			if img.get_pixel(x, y).a <= 0.0:
				continue
			var edge := false
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var nx := x + d.x
				var ny := y + d.y
				if nx < 0 or ny < 0 or nx >= w or ny >= h or img.get_pixel(nx, ny).a <= 0.0:
					edge = true
					break
			if edge:
				img.set_pixel(x, y, img.get_pixel(x, y).darkened(EDGE_DARK))
	var tex := ImageTexture.create_from_image(img)
	_tile_cache[key] = tex
	return tex

# 只在 hex 地面内(不透明)落一个像素——像素 decor 的落笔单元。
static func _put(img: Image, x: int, y: int, c: Color) -> void:
	if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
		return
	if img.get_pixel(x, y).a <= 0.0:
		return
	img.set_pixel(x, y, c)

# 草地：几丛像素草叶（accent 亮绿竖 2~3px + 暗根 + 点缀亮点），位置按 variant 散列。
static func _bake_grass(img: Image, accent: Color, variant: int) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var dark := accent.darkened(0.22)
	for i in 5:
		var bx := int(3.0 + _hash01(i * 13 + 1, variant, 3) * float(w - 6))
		var by := int(float(h) * 0.5 + _hash01(i * 13 + 2, variant, 7) * float(h) * 0.36)
		_put(img, bx, by, dark)          # 根
		_put(img, bx, by - 1, accent)    # 叶
		_put(img, bx, by - 2, accent)
		_put(img, bx + 1, by - 1, dark)  # 旁叶

# 水面：几行像素波纹（accent 亮蓝短横 dash，行间错相），位置按 variant 散列。
static func _bake_wave(img: Image, accent: Color, variant: int) -> void:
	var w := img.get_width()
	var h := img.get_height()
	for ri in 3:
		var ry := int(float(h) * (0.28 + 0.23 * float(ri)))
		var x := 2 + int(_hash01(ri + 1, variant, 5) * 4.0)
		while x < w - 2:
			_put(img, x, ry, accent)
			_put(img, x + 1, ry, accent)
			x += 5

# 点 (px,py)（相对格心）是否在 flat-top 六边形内（外接半径 r）。
static func _in_hex(px: float, py: float, r: float) -> bool:
	var hy := absf(py)
	if hy > r * (SQRT3 * 0.5):
		return false
	return SQRT3 * absf(px) + hy <= SQRT3 * r

# 确定性 [0,1) 值噪声（抖色种子；同 (x,y,variant) 恒定 → 不闪）。
static func _hash01(x: int, y: int, v: int) -> float:
	var hh := (x * 374761393 + y * 668265263 + v * 362437) & 0x7fffffff
	hh = (hh ^ (hh >> 13)) * 1274126177
	hh = hh ^ (hh >> 16)
	return float(hh & 0xffff) / 65535.0

# 平顶六边形顶点（世界/局部坐标）
static func corners(center: Vector2, size: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 6:
		var ang := deg_to_rad(60.0 * i)
		pts.append(center + Vector2(cos(ang), sin(ang)) * size)
	return pts

# decor 坐标扰动（去印章感）：seed 由调用方按 (col,row) 派生；seed=0 → 零偏移（笔刷缩略图规整）。
# _jo(i)＝该格第 i 个元素的确定性偏移（±2.5px，纯函数——重绘不闪）。
static func _jo(seed: int, i: int) -> Vector2:
	if seed == 0:
		return Vector2.ZERO
	var h := seed ^ (i + 1) * 83492791
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return Vector2(float(absi(h) % 1024) / 1024.0 - 0.5, float(absi(h >> 10) % 1024) / 1024.0 - 0.5) * 5.0

static func draw_decor(ci: CanvasItem, decor: String, center: Vector2, accent: Color, seed: int) -> void:
	match decor:
		"tree": _draw_trees(ci, center, accent, seed)
		"wave": _draw_waves(ci, center, accent, seed)
		"peak": _draw_peak(ci, center, accent, seed)
		"grass": _draw_grass(ci, center, accent, seed)
		"crack": _draw_crack(ci, center, accent, seed)
		"path": _draw_path(ci, center, accent)
		"bush": _draw_bush(ci, center, accent, seed)
		"hill": _draw_hill(ci, center, accent, seed)
		"dune": _draw_dune(ci, center, accent, seed)
		"snow": _draw_snow(ci, center, accent, seed)
		"rubble": _draw_rubble(ci, center, accent, seed)
		"brick": _draw_brick(ci, center, accent)
		"swamp": _draw_swamp(ci, center, accent, seed)
		"farm": _draw_farm(ci, center, accent, seed)
		"tundra": _draw_tundra(ci, center, accent, seed)
		"coast": _draw_coast(ci, center, accent, seed)
		"plank": _draw_plank(ci, center, accent)

# 底边中点 base_mid 处画一个等腰三角形描边
static func _tri_outline(ci: CanvasItem, base_mid: Vector2, half_w: float, h: float, color: Color) -> void:
	var apex := base_mid + Vector2(0, -h)
	var bl := base_mid + Vector2(-half_w, 0)
	var br := base_mid + Vector2(half_w, 0)
	ci.draw_polyline(PackedVector2Array([bl, apex, br, bl]), color, DECOR_WIDTH)

static func _draw_peak(ci: CanvasItem, center: Vector2, accent: Color, seed: int) -> void:
	# 两个简单三角形（描边），仿参考图：左小右大，略重叠
	_tri_outline(ci, center + Vector2(-5, 6) + _jo(seed, 0), 8.0, 11.0, accent)
	_tri_outline(ci, center + Vector2(6, 6) + _jo(seed, 1), 11.0, 15.0, accent)

static func _draw_trees(ci: CanvasItem, center: Vector2, accent: Color, seed: int) -> void:
	# 两棵松树：小三角 + 短树干
	var i := 0
	for s in [Vector2(-7, 2), Vector2(6, 6)]:
		var b: Vector2 = center + s + _jo(seed, i)
		i += 1
		_tri_outline(ci, b, 5.0, 12.0, accent)
		ci.draw_line(b, b + Vector2(0, 4), accent, DECOR_WIDTH)

static func _draw_grass(ci: CanvasItem, center: Vector2, accent: Color, seed: int) -> void:
	# 三丛草：每丛两短斜线
	var i := 0
	for s in [Vector2(-6, 6), Vector2(2, 7), Vector2(8, 5)]:
		var b: Vector2 = center + s + _jo(seed, i)
		i += 1
		ci.draw_line(b, b + Vector2(-2, -6), accent, DECOR_WIDTH)
		ci.draw_line(b, b + Vector2(2, -6), accent, DECOR_WIDTH)

static func _draw_crack(ci: CanvasItem, center: Vector2, accent: Color, seed: int) -> void:
	# 两道干裂短纹
	ci.draw_line(center + Vector2(-7, -2) + _jo(seed, 0), center + Vector2(-1, 1) + _jo(seed, 1), accent, DECOR_WIDTH)
	ci.draw_line(center + Vector2(3, 3) + _jo(seed, 2), center + Vector2(8, 0) + _jo(seed, 3), accent, DECOR_WIDTH)

static func _draw_waves(ci: CanvasItem, center: Vector2, accent: Color, seed: int) -> void:
	# 两道水波线（整体微偏移，波形不变——保持水面规整）
	var off := _jo(seed, 0) * 0.6
	for ry in [-5.0, 4.0]:
		var pts := PackedVector2Array([
			center + off + Vector2(-10, ry),
			center + off + Vector2(-5, ry - 2.5),
			center + off + Vector2(0, ry),
			center + off + Vector2(5, ry - 2.5),
			center + off + Vector2(10, ry),
		])
		ci.draw_polyline(pts, accent, DECOR_WIDTH)

static func _draw_path(ci: CanvasItem, center: Vector2, accent: Color) -> void:
	# 两行虚线＝路面车辙（不扰动：道路要顺直）
	for ry in [-4.0, 5.0]:
		for dx in [-10.0, -1.0, 8.0]:
			var a: Vector2 = center + Vector2(dx, ry)
			ci.draw_line(a, a + Vector2(5, 0), accent, DECOR_WIDTH)

static func _draw_bush(ci: CanvasItem, center: Vector2, accent: Color, seed: int) -> void:
	# 三丛圆灌木（上半弧）
	var i := 0
	for s in [Vector2(-6, 5), Vector2(3, 6), Vector2(8, 3)]:
		ci.draw_arc(center + s + _jo(seed, i), 4.0, PI, TAU, 10, accent, DECOR_WIDTH)
		i += 1

static func _draw_hill(ci: CanvasItem, center: Vector2, accent: Color, seed: int) -> void:
	# 两道低缓圆丘（区别于山地的尖三角）
	ci.draw_arc(center + Vector2(-3, 7) + _jo(seed, 0), 9.0, PI, TAU, 14, accent, DECOR_WIDTH)
	ci.draw_arc(center + Vector2(8, 7) + _jo(seed, 1), 5.0, PI, TAU, 10, accent, DECOR_WIDTH)

static func _draw_dune(ci: CanvasItem, center: Vector2, accent: Color, seed: int) -> void:
	# 平缓沙丘曲线 + 两粒沙点
	var off := _jo(seed, 0) * 0.6
	var pts := PackedVector2Array([
		center + off + Vector2(-10, 2),
		center + off + Vector2(-3, -2),
		center + off + Vector2(4, 1),
		center + off + Vector2(10, -2),
	])
	ci.draw_polyline(pts, accent, DECOR_WIDTH)
	ci.draw_line(center + Vector2(-5, 7) + _jo(seed, 1), center + Vector2(-4, 7) + _jo(seed, 1), accent, DECOR_WIDTH)
	ci.draw_line(center + Vector2(4, 6) + _jo(seed, 2), center + Vector2(5, 6) + _jo(seed, 2), accent, DECOR_WIDTH)

static func _draw_snow(ci: CanvasItem, center: Vector2, accent: Color, seed: int) -> void:
	# 几片雪＝小十字
	var i := 0
	for s in [Vector2(-6, -2), Vector2(4, 2), Vector2(8, -5), Vector2(-2, 6)]:
		var b: Vector2 = center + s + _jo(seed, i)
		i += 1
		ci.draw_line(b + Vector2(-2.5, 0), b + Vector2(2.5, 0), accent, DECOR_WIDTH)
		ci.draw_line(b + Vector2(0, -2.5), b + Vector2(0, 2.5), accent, DECOR_WIDTH)

static func _draw_rubble(ci: CanvasItem, center: Vector2, accent: Color, seed: int) -> void:
	# 散落碎石＝两个小方块 + 一个小三角描边
	ci.draw_rect(Rect2(center + Vector2(-9, 0) + _jo(seed, 0), Vector2(6, 5)), accent, false, DECOR_WIDTH)
	ci.draw_rect(Rect2(center + Vector2(1, 3) + _jo(seed, 1), Vector2(5, 4)), accent, false, DECOR_WIDTH)
	_tri_outline(ci, center + Vector2(6, -2) + _jo(seed, 2), 4.0, 6.0, accent)

static func _draw_swamp(ci: CanvasItem, center: Vector2, accent: Color, seed: int) -> void:
	# 沼泽：两丛苇草（竖茎+斜叶）+ 两道水点短横
	var i := 0
	for s in [Vector2(-6, 4), Vector2(5, 6)]:
		var b: Vector2 = center + s + _jo(seed, i)
		i += 1
		ci.draw_line(b, b + Vector2(0, -8), accent, DECOR_WIDTH)
		ci.draw_line(b + Vector2(0, -5), b + Vector2(3, -8), accent, DECOR_WIDTH)
		ci.draw_line(b + Vector2(0, -3), b + Vector2(-3, -6), accent, DECOR_WIDTH)
	ci.draw_line(center + Vector2(-8, -4) + _jo(seed, 2), center + Vector2(-3, -4) + _jo(seed, 2), accent, DECOR_WIDTH)
	ci.draw_line(center + Vector2(4, -6) + _jo(seed, 3), center + Vector2(8, -6) + _jo(seed, 3), accent, DECOR_WIDTH)

static func _draw_farm(ci: CanvasItem, center: Vector2, accent: Color, seed: int) -> void:
	# 农田：三道田垄横线（参考图同款；不扰动位置、只微扰长短——垄要平行）
	for k in 3:
		var y := -6.0 + k * 6.0
		var ext := _jo(seed, k).x * 0.8
		ci.draw_line(center + Vector2(-9 - ext, y), center + Vector2(9 + ext, y), accent, DECOR_WIDTH)

static func _draw_tundra(ci: CanvasItem, center: Vector2, accent: Color, seed: int) -> void:
	# 冻原：两片雪十字 + 两撮短草（荒寒混合）
	var i := 0
	for s in [Vector2(-6, -2), Vector2(6, 3)]:
		var b: Vector2 = center + s + _jo(seed, i)
		i += 1
		ci.draw_line(b + Vector2(-2.5, 0), b + Vector2(2.5, 0), accent, DECOR_WIDTH)
		ci.draw_line(b + Vector2(0, -2.5), b + Vector2(0, 2.5), accent, DECOR_WIDTH)
	for s in [Vector2(-2, 7), Vector2(8, -5)]:
		var b: Vector2 = center + s + _jo(seed, i)
		i += 1
		ci.draw_line(b, b + Vector2(-1.5, -4), accent, DECOR_WIDTH)
		ci.draw_line(b, b + Vector2(1.5, -4), accent, DECOR_WIDTH)

static func _draw_coast(ci: CanvasItem, center: Vector2, accent: Color, seed: int) -> void:
	# 海岸浅滩：一道水波线 + 三粒沙点
	var off := _jo(seed, 0) * 0.6
	var pts := PackedVector2Array([
		center + off + Vector2(-10, -3),
		center + off + Vector2(-5, -5.5),
		center + off + Vector2(0, -3),
		center + off + Vector2(5, -5.5),
		center + off + Vector2(10, -3),
	])
	ci.draw_polyline(pts, accent, DECOR_WIDTH)
	var i := 1
	for s in [Vector2(-5, 5), Vector2(2, 7), Vector2(7, 4)]:
		var b: Vector2 = center + s + _jo(seed, i)
		i += 1
		ci.draw_line(b, b + Vector2(1.5, 0), accent, DECOR_WIDTH)

static func _draw_plank(ci: CanvasItem, center: Vector2, accent: Color) -> void:
	# 桥面：两道纵梁 + 四道横板（战场桥地形；不扰动——建筑要规整）
	for x in [-8.0, 8.0]:
		ci.draw_line(center + Vector2(x, -9), center + Vector2(x, 9), accent, DECOR_WIDTH)
	for y in [-7.0, -2.0, 3.0, 8.0]:
		ci.draw_line(center + Vector2(-8, y), center + Vector2(8, y), accent, DECOR_WIDTH)

static func _draw_brick(ci: CanvasItem, center: Vector2, accent: Color) -> void:
	# 砖墙：三道横向砖缝 + 错缝竖隔
	for y in [-7.0, -1.0, 5.0]:
		ci.draw_line(center + Vector2(-11, y), center + Vector2(11, y), accent, DECOR_WIDTH)
	for x in [-5.0, 5.0]:  # 上排竖缝
		ci.draw_line(center + Vector2(x, -7), center + Vector2(x, -1), accent, DECOR_WIDTH)
	for x in [-10.0, 0.0, 10.0]:  # 下排错缝
		ci.draw_line(center + Vector2(x, -1), center + Vector2(x, 5), accent, DECOR_WIDTH)
