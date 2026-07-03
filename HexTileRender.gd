extends RefCounted
## 地块渲染单一实现：把「一个六边形地块」（底色多边形 + 黑描边 + accent 线稿 decor）画到任意 CanvasItem。
## 谁用：HexCanvas 地图主循环（编辑器/战斗/大地图三画布）＋ 编辑器笔刷图块（TerrainSwatch）＋ 任何要显示「地块长什么样」的地方。
## 目的＝DRY：decor 线稿只此一处，改一处三画布 + 笔刷格全一致（杜绝「笔刷格 != 地图格」）。
## 纯静态无状态：绘制目标 ci、格心、半径、扰动种子由调用方传入（决定性——同种子同输出，_draw 每帧重入不闪）。
## 范式：extends RefCounted + 静态方法 + 无 class_name（headless 友好，仿 TerrainDB/HexGrid）。
## 注意：decor 偏移按半径 24（地图原始尺寸）设计；draw_tile 的 size 只改六边形大小，decor 用原生偏移——
##       故笔刷缩略图用接近 24 的半径（如 21）即与地图格一致；要更小的缩略图再引入 scale。

const OUTLINE := Color(0, 0, 0, 0.35)
const DECOR_WIDTH := 1.6

# 画一个地块：hex 多边形(color) + 黑描边 + decor(accent 线稿)。
# center=格心；size=中心到顶点半径；seed=decor 扰动种子（0＝不扰动，用于笔刷缩略图）；with_decor=false 时只画底色+描边。
static func draw_tile(ci: CanvasItem, center: Vector2, size: float, color: Color, accent: Color, decor: String, seed: int = 0, with_decor: bool = true) -> void:
	var pts := corners(center, size)
	ci.draw_colored_polygon(pts, color)
	var outline := PackedVector2Array(pts)
	outline.append(pts[0])
	ci.draw_polyline(outline, OUTLINE, 1.0)
	if with_decor:
		draw_decor(ci, decor, center, accent, seed)

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
