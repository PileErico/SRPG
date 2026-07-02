extends Control
## 六边形地图画布。
## 输入：左键绘制 / 右键取色 / 中键按住拖拽平移 / 滚轮缩放。
## 反馈：悬停高亮当前格，左下角显示坐标 + 地块信息。
## 坐标系：flat-top（平顶），odd-q 偏移（奇数列向下错半格）。
## 视图变换由 view_offset(平移) + view_zoom(缩放) 表达，绘制时统一套用。

const HexGrid := preload("res://HexGrid.gd")   # 纯六边形几何前置（取整器 single source）
const HEX_SIZE := 24.0
const MIN_ZOOM := 0.2
const MAX_ZOOM := 4.0
const ZOOM_STEP := 1.1
const DECOR_MIN_ZOOM := 0.45   # 缩得太小就不画纹理装饰，免得糊成噪点

var hex_w := 2.0 * HEX_SIZE
var hex_h := sqrt(3.0) * HEX_SIZE
var col_step := 1.5 * HEX_SIZE
var row_step := sqrt(3.0) * HEX_SIZE

var editor
var painting := false
var panning := false
var view_offset := Vector2(20, 20)
var view_zoom := 1.0
var hover_cell := Vector2i(-1, -1)
var info_label: Label             # 地形信息文字（底段，永远显示当前格）
var _info_panel: PanelContainer   # 左下可扩展信息栏（含底 + 内边距）
var _info_extra: VBoxContainer    # 扩展段（宿主经 hover_extra 填，如单位卡）；无则空
var _need_fit := false   # 新建/加载后置位：待布局尺寸就绪时在 _draw 里自动适配窗口

func _ready() -> void:
	clip_contents = true  # 缩放/平移后越界的格子裁掉，不溢出到侧边栏
	mouse_exited.connect(_on_mouse_exit)
	_make_info_label()

# 左下「光标位置信息」栏：可扩展——底段永远是地形文字；宿主可经 hover_extra 在其上叠一段（如单位卡）。
func _make_info_label() -> void:
	_info_panel = PanelContainer.new()
	_info_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_info_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN   # 内容变多向上生长（底边固定）
	_info_panel.offset_left = 8
	_info_panel.offset_bottom = -8
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0, 0, 0, 0.55)
	box.set_content_margin_all(6)
	_info_panel.add_theme_stylebox_override("panel", box)
	_info_panel.visible = false
	add_child(_info_panel)

	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_theme_constant_override("separation", 6)
	_info_panel.add_child(vb)

	_info_extra = VBoxContainer.new()   # 扩展段（上），默认空；宿主填单位卡时才有内容
	_info_extra.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(_info_extra)

	info_label = Label.new()            # 地形文字（下），永远显示
	info_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_label.add_theme_color_override("font_color", Color.WHITE)
	vb.add_child(info_label)

func reset_view() -> void:
	view_offset = Vector2(20, 20)
	view_zoom = 1.0
	queue_redraw()

# 请求「适配窗口」：布局尺寸此刻可能还没就绪（如启动/新建时），
# 故只置位，等 _draw 拿到有效 size 再真正适配（见 _draw 顶部）。
func request_fit() -> void:
	_need_fit = true
	queue_redraw()

# 整张地图缩放居中铺满画布（留一点边距）；尺寸未就绪则退回安全默认
func fit_to_view() -> void:
	if editor == null or size.x < 1.0 or size.y < 1.0:
		reset_view()
		return
	var b := _map_bounds()
	if b.size.x <= 0.0 or b.size.y <= 0.0:
		reset_view()
		return
	var z := minf(size.x / b.size.x, size.y / b.size.y) * 0.94  # 0.94＝四周留点边
	z = clampf(z, MIN_ZOOM, MAX_ZOOM)
	view_zoom = z
	view_offset = size * 0.5 - b.get_center() * z
	queue_redraw()

# 全部格子的世界坐标包围盒（含六边形自身半径）
func _map_bounds() -> Rect2:
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for row in editor.height:
		for col in editor.width:
			var c := hex_center(col, row)
			mn.x = minf(mn.x, c.x - HEX_SIZE)
			mn.y = minf(mn.y, c.y - hex_h * 0.5)
			mx.x = maxf(mx.x, c.x + HEX_SIZE)
			mx.y = maxf(mx.y, c.y + hex_h * 0.5)
	return Rect2(mn, mx - mn)

# 把某格移到画布正中（保持当前缩放）。world = view_offset + w*zoom，令其 = 画布中心。
func center_on_cell(col: int, row: int) -> void:
	view_offset = size * 0.5 - hex_center(col, row) * view_zoom
	queue_redraw()

# ---- 六边形几何（世界坐标，未经视图变换）----

func hex_center(col: int, row: int) -> Vector2:
	var x := col_step * col + HEX_SIZE
	var y := row_step * (row + 0.5 * (col % 2)) + hex_h * 0.5
	return Vector2(x, y)

func hex_corners(center: Vector2) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 6:
		var ang := deg_to_rad(60.0 * i)
		pts.append(center + Vector2(cos(ang), sin(ang)) * HEX_SIZE)
	return pts

func axial_round(qf: float, rf: float) -> Vector2i:
	# axial(q,r,s) 映射到 cube(x,y,z) 后复用唯一取整器；分支/取整与旧实现逐位一致（对拍验证）。
	var c := HexGrid.cube_round(qf, rf, -qf - rf)
	return Vector2i(c.x, c.y)

func pixel_to_offset(world: Vector2) -> Vector2i:
	var px := world.x - HEX_SIZE
	var py := world.y - hex_h * 0.5
	var qf := (2.0 / 3.0 * px) / HEX_SIZE
	var rf := (-1.0 / 3.0 * px + sqrt(3.0) / 3.0 * py) / HEX_SIZE
	# axial(q,r) → odd-q offset 复用 HexGrid（消最后一处开写的 (col-(col&1))/2）
	return HexGrid.axial_to_offset(axial_round(qf, rf))

func _world_from_screen(p: Vector2) -> Vector2:
	return (p - view_offset) / view_zoom

# ---- 绘制 ----

func _draw() -> void:
	if editor == null:
		return
	if _need_fit and size.x >= 1.0 and size.y >= 1.0:
		_need_fit = false
		fit_to_view()   # 此刻直接更新 view_offset/zoom，本帧即用新值绘制
	draw_set_transform(view_offset, 0.0, Vector2(view_zoom, view_zoom))
	var show_decor := view_zoom >= DECOR_MIN_ZOOM
	for row in editor.height:
		for col in editor.width:
			var tile = editor.tiles[row][col]
			var color: Color = editor.color_for_tile(tile)
			var center := hex_center(col, row)
			var pts := hex_corners(center)
			draw_colored_polygon(pts, color)
			var outline := PackedVector2Array(pts)
			outline.append(pts[0])
			draw_polyline(outline, Color(0, 0, 0, 0.35), 1.0)
			if show_decor:
				_draw_decor(editor.decor_for_tile(tile), center, editor.accent_for_tile(tile))
	# 悬停高亮（黄框，线宽按缩放反算，保持屏幕上恒定粗细）
	if _in_bounds(hover_cell):
		var hp := hex_corners(hex_center(hover_cell.x, hover_cell.y))
		hp.append(hp[0])
		draw_polyline(hp, Color(1.0, 0.95, 0.2, 0.95), 2.5 / view_zoom)

# 所有纹理＝单一 accent 色的线稿（描边，不填充），每格仅“底色 + 纹理色”两色。
const DECOR_WIDTH := 1.6

func _draw_decor(decor: String, center: Vector2, accent: Color) -> void:
	match decor:
		"tree":
			_draw_trees(center, accent)
		"wave":
			_draw_waves(center, accent)
		"peak":
			_draw_peak(center, accent)
		"grass":
			_draw_grass(center, accent)
		"crack":
			_draw_crack(center, accent)
		"path":
			_draw_path(center, accent)
		"bush":
			_draw_bush(center, accent)
		"hill":
			_draw_hill(center, accent)
		"dune":
			_draw_dune(center, accent)
		"snow":
			_draw_snow(center, accent)
		"rubble":
			_draw_rubble(center, accent)
		"brick":
			_draw_brick(center, accent)

# 底边中点 base_mid 处画一个等腰三角形描边
func _tri_outline(base_mid: Vector2, half_w: float, h: float, color: Color) -> void:
	var apex := base_mid + Vector2(0, -h)
	var bl := base_mid + Vector2(-half_w, 0)
	var br := base_mid + Vector2(half_w, 0)
	draw_polyline(PackedVector2Array([bl, apex, br, bl]), color, DECOR_WIDTH)

func _draw_peak(center: Vector2, accent: Color) -> void:
	# 两个简单三角形（描边），仿参考图：左小右大，略重叠
	_tri_outline(center + Vector2(-5, 6), 8.0, 11.0, accent)
	_tri_outline(center + Vector2(6, 6), 11.0, 15.0, accent)

func _draw_trees(center: Vector2, accent: Color) -> void:
	# 两棵松树：小三角 + 短树干
	for s in [Vector2(-7, 2), Vector2(6, 6)]:
		var b: Vector2 = center + s
		_tri_outline(b, 5.0, 12.0, accent)
		draw_line(b, b + Vector2(0, 4), accent, DECOR_WIDTH)

func _draw_grass(center: Vector2, accent: Color) -> void:
	# 三丛草：每丛两短斜线
	for s in [Vector2(-6, 6), Vector2(2, 7), Vector2(8, 5)]:
		var b: Vector2 = center + s
		draw_line(b, b + Vector2(-2, -6), accent, DECOR_WIDTH)
		draw_line(b, b + Vector2(2, -6), accent, DECOR_WIDTH)

func _draw_crack(center: Vector2, accent: Color) -> void:
	# 两道干裂短纹
	draw_line(center + Vector2(-7, -2), center + Vector2(-1, 1), accent, DECOR_WIDTH)
	draw_line(center + Vector2(3, 3), center + Vector2(8, 0), accent, DECOR_WIDTH)

func _draw_waves(center: Vector2, accent: Color) -> void:
	# 两道水波线
	for ry in [-5.0, 4.0]:
		var pts := PackedVector2Array([
			center + Vector2(-10, ry),
			center + Vector2(-5, ry - 2.5),
			center + Vector2(0, ry),
			center + Vector2(5, ry - 2.5),
			center + Vector2(10, ry),
		])
		draw_polyline(pts, accent, DECOR_WIDTH)

func _draw_path(center: Vector2, accent: Color) -> void:
	# 两行虚线＝路面车辙
	for ry in [-4.0, 5.0]:
		for dx in [-10.0, -1.0, 8.0]:
			var a: Vector2 = center + Vector2(dx, ry)
			draw_line(a, a + Vector2(5, 0), accent, DECOR_WIDTH)

func _draw_bush(center: Vector2, accent: Color) -> void:
	# 三丛圆灌木（上半弧）
	for s in [Vector2(-6, 5), Vector2(3, 6), Vector2(8, 3)]:
		draw_arc(center + s, 4.0, PI, TAU, 10, accent, DECOR_WIDTH)

func _draw_hill(center: Vector2, accent: Color) -> void:
	# 两道低缓圆丘（区别于山地的尖三角）
	draw_arc(center + Vector2(-3, 7), 9.0, PI, TAU, 14, accent, DECOR_WIDTH)
	draw_arc(center + Vector2(8, 7), 5.0, PI, TAU, 10, accent, DECOR_WIDTH)

func _draw_dune(center: Vector2, accent: Color) -> void:
	# 平缓沙丘曲线 + 两粒沙点
	var pts := PackedVector2Array([
		center + Vector2(-10, 2),
		center + Vector2(-3, -2),
		center + Vector2(4, 1),
		center + Vector2(10, -2),
	])
	draw_polyline(pts, accent, DECOR_WIDTH)
	draw_line(center + Vector2(-5, 7), center + Vector2(-4, 7), accent, DECOR_WIDTH)
	draw_line(center + Vector2(4, 6), center + Vector2(5, 6), accent, DECOR_WIDTH)

func _draw_snow(center: Vector2, accent: Color) -> void:
	# 几片雪＝小十字
	for s in [Vector2(-6, -2), Vector2(4, 2), Vector2(8, -5), Vector2(-2, 6)]:
		var b: Vector2 = center + s
		draw_line(b + Vector2(-2.5, 0), b + Vector2(2.5, 0), accent, DECOR_WIDTH)
		draw_line(b + Vector2(0, -2.5), b + Vector2(0, 2.5), accent, DECOR_WIDTH)

func _draw_rubble(center: Vector2, accent: Color) -> void:
	# 散落碎石＝两个小方块 + 一个小三角描边
	draw_rect(Rect2(center + Vector2(-9, 0), Vector2(6, 5)), accent, false, DECOR_WIDTH)
	draw_rect(Rect2(center + Vector2(1, 3), Vector2(5, 4)), accent, false, DECOR_WIDTH)
	_tri_outline(center + Vector2(6, -2), 4.0, 6.0, accent)

func _draw_brick(center: Vector2, accent: Color) -> void:
	# 砖墙：三道横向砖缝 + 错缝竖隔
	for y in [-7.0, -1.0, 5.0]:
		draw_line(center + Vector2(-11, y), center + Vector2(11, y), accent, DECOR_WIDTH)
	for x in [-5.0, 5.0]:  # 上排竖缝
		draw_line(center + Vector2(x, -7), center + Vector2(x, -1), accent, DECOR_WIDTH)
	for x in [-10.0, 0.0, 10.0]:  # 下排错缝
		draw_line(center + Vector2(x, -1), center + Vector2(x, 5), accent, DECOR_WIDTH)

# ---- 输入 ----

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				painting = event.pressed
				if event.pressed:
					editor.begin_stroke()
					_paint_at(event.position)
				else:
					editor.end_stroke()
			MOUSE_BUTTON_RIGHT:
				if event.pressed:
					_pick_at(event.position)
			MOUSE_BUTTON_MIDDLE:
				panning = event.pressed
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					_zoom_at(event.position, ZOOM_STEP)
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					_zoom_at(event.position, 1.0 / ZOOM_STEP)
	elif event is InputEventMouseMotion:
		if panning:
			view_offset += event.relative
			queue_redraw()
		elif painting:
			_paint_at(event.position)
		_update_hover(event.position)

func _paint_at(screen_pos: Vector2) -> void:
	var off := pixel_to_offset(_world_from_screen(screen_pos))
	if _in_bounds(off):
		editor.paint_cell(off.x, off.y)

func _pick_at(screen_pos: Vector2) -> void:
	var off := pixel_to_offset(_world_from_screen(screen_pos))
	if _in_bounds(off):
		editor.pick_brush_at(off.x, off.y)

func _update_hover(screen_pos: Vector2) -> void:
	var off := pixel_to_offset(_world_from_screen(screen_pos))
	if not _in_bounds(off):
		off = Vector2i(-1, -1)
	if off != hover_cell:
		hover_cell = off
		_update_info_label()
		queue_redraw()

func _update_info_label() -> void:
	if _info_panel == null:
		return
	# 每次换格：先清扩展段（立即移出树，不残留一帧）
	for c in _info_extra.get_children():
		_info_extra.remove_child(c)
		c.queue_free()
	if hover_cell.x < 0:
		_info_panel.visible = false
		info_label.text = ""
		return
	info_label.text = editor.hover_text(hover_cell.x, hover_cell.y)
	_info_panel.visible = true
	# 宿主可选钩子：给该格提供一个扩展控件（有单位→单位卡，否则 null）。编辑器无此方法 = 只显示地形。
	if editor != null and editor.has_method("hover_extra"):
		var extra = editor.hover_extra(hover_cell.x, hover_cell.y)
		if extra != null:
			_info_extra.add_child(extra)
			_info_extra.add_child(HSeparator.new())   # 单位段与地形段之间的分隔

func _on_mouse_exit() -> void:
	if hover_cell.x >= 0:
		hover_cell = Vector2i(-1, -1)
		_update_info_label()
		queue_redraw()

func _in_bounds(off: Vector2i) -> bool:
	return editor != null and off.x >= 0 and off.x < editor.width and off.y >= 0 and off.y < editor.height

func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var nz := clampf(view_zoom * factor, MIN_ZOOM, MAX_ZOOM)
	if is_equal_approx(nz, view_zoom):
		return
	var world := (screen_pos - view_offset) / view_zoom  # 缩放围绕光标下的世界点保持不动
	view_offset = screen_pos - world * nz
	view_zoom = nz
	queue_redraw()
