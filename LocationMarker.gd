extends RefCounted
## 地点标记线稿库：按地点类型（city/village/ruin/lair）画各自的矢量符号（填充色 + 深描边 + 底座阴影）。
## 与地形 decor 同为**程序化矢量**——免分辨率、任意缩放清晰；底座阴影把标记"立"在格上、区别于平铺 decor。
## 将来引入更精细**位图**素材时，渲染方（HexCanvas.draw_location_marker）优先用 icon 位图、缺省回退本库。
## 范式：extends RefCounted + 静态方法 + 无 class_name（headless 友好，仿 HexTileRender/TerrainDB）。
## 坐标：相对 center（格心）；符号立在格上，base≈+7、顶≈-10（约 17px 高，世界坐标 HEX_SIZE=24 语境）。

const OUTLINE := Color(0.12, 0.10, 0.08, 0.92)   # 统一深描边（任意地形上都撑得住轮廓）
const OUTLINE_W := 1.4

# 画一个地点标记（type_id 决定符号；color＝类型色，已由调用方按 active 处理明暗）。
# 极简线稿风：**不投阴影**（全局无投影，符号靠深描边 + 建筑平底自然坐在格上）。
static func draw(ci: CanvasItem, center: Vector2, type_id: String, color: Color) -> void:
	match type_id:
		"city": _city(ci, center, color)
		"village": _village(ci, center, color)
		"ruin": _ruin(ci, center, color)
		"lair": _lair(ci, center, color)
		_: _pin(ci, center, color)   # 未知类型回退：小旗

# —— 基元 ——
static func _poly(ci: CanvasItem, pts: PackedVector2Array, fill: Color, outline: Color = OUTLINE) -> void:
	ci.draw_colored_polygon(pts, fill)
	var o := PackedVector2Array(pts)
	o.append(pts[0])
	ci.draw_polyline(o, outline, OUTLINE_W)

static func _rect(ci: CanvasItem, c: Vector2, x0: float, y0: float, x1: float, y1: float, fill: Color, outline: Color = OUTLINE) -> void:
	_poly(ci, PackedVector2Array([c + Vector2(x0, y0), c + Vector2(x1, y0), c + Vector2(x1, y1), c + Vector2(x0, y1)]), fill, outline)

# —— 城市：城墙 + 三城齿 + 中央城门 ——
static func _city(ci: CanvasItem, c: Vector2, col: Color) -> void:
	_rect(ci, c, -8, 4, 8, -2, col)                      # 墙体
	for mx in [-8.0, -2.0, 4.0]:                          # 三城齿（垛口）
		_rect(ci, c, mx, -2, mx + 4, -6, col)
	ci.draw_colored_polygon(PackedVector2Array([          # 城门（深色拱口）
		c + Vector2(-2.5, 4), c + Vector2(2.5, 4), c + Vector2(2.5, -0.5), c + Vector2(-2.5, -0.5)]), OUTLINE)

# —— 村落：两间尖顶小屋（大左·小右）——
static func _village(ci: CanvasItem, c: Vector2, col: Color) -> void:
	_rect(ci, c, -8, 4, -1, -1, col)                     # 屋1 墙体
	_poly(ci, PackedVector2Array([c + Vector2(-9, -1), c + Vector2(-4.5, -5.5), c + Vector2(0, -1)]), col)  # 屋1 屋顶
	ci.draw_colored_polygon(PackedVector2Array([          # 屋1 门
		c + Vector2(-5.5, 4), c + Vector2(-3.5, 4), c + Vector2(-3.5, 1), c + Vector2(-5.5, 1)]), OUTLINE)
	_rect(ci, c, 1, 4, 6, 0, col)                        # 屋2 墙体
	_poly(ci, PackedVector2Array([c + Vector2(0, 0), c + Vector2(3.5, -4), c + Vector2(7, 0)]), col)  # 屋2 屋顶

# —— 遗迹：碎石基 + 三根高低不齐的断柱 ——
static func _ruin(ci: CanvasItem, c: Vector2, col: Color) -> void:
	_rect(ci, c, -8, 5, 8, 3, col.darkened(0.28))        # 碎石基座
	_rect(ci, c, -6.5, 3, -3.5, -7, col)                 # 断柱A（高）
	_rect(ci, c, -1.5, 3, 1.5, -1.5, col)                # 断柱B（残短）
	_poly(ci, PackedVector2Array([                        # 断柱C（斜断顶）
		c + Vector2(3.5, 3), c + Vector2(6.5, 3), c + Vector2(6.5, -4), c + Vector2(3.5, -5.5)]), col)

# —— 野外据点：尖顶帐篷 + 顶旗（敌对营地感）——
static func _lair(ci: CanvasItem, c: Vector2, col: Color) -> void:
	_poly(ci, PackedVector2Array([c + Vector2(-7, 5), c + Vector2(7, 5), c + Vector2(0, -6)]), col)  # 帐篷
	ci.draw_colored_polygon(PackedVector2Array([          # 帐门（深色）
		c + Vector2(-1.6, 5), c + Vector2(1.6, 5), c + Vector2(0, -1)]), OUTLINE)
	ci.draw_line(c + Vector2(0, -6), c + Vector2(0, -10.5), OUTLINE, OUTLINE_W)  # 旗杆
	_poly(ci, PackedVector2Array([c + Vector2(0, -10.5), c + Vector2(4.5, -9), c + Vector2(0, -7.5)]), col)  # 顶旗

# —— 回退：小旗（未知类型；仿原 draw_location_flag 的旗形）——
static func _pin(ci: CanvasItem, c: Vector2, col: Color) -> void:
	ci.draw_line(c + Vector2(0, 6), c + Vector2(0, -10), OUTLINE, 2.0)
	_poly(ci, PackedVector2Array([c + Vector2(0, -10), c + Vector2(9, -6.5), c + Vector2(0, -3)]), col)
