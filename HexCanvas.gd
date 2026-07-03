extends Control
## 六边形地图画布。
## 输入：左键绘制 / 右键取色 / 中键按住拖拽平移 / 滚轮缩放。
## 反馈：悬停高亮当前格，左下角显示坐标 + 地块信息。
## 坐标系：flat-top（平顶），odd-q 偏移（奇数列向下错半格）。
## 视图变换由 view_offset(平移) + view_zoom(缩放) 表达，绘制时统一套用。

const HexGrid := preload("res://HexGrid.gd")   # 纯六边形几何前置（取整器 single source）
const HexTileRender := preload("res://HexTileRender.gd")   # 地块渲染单一实现（底色+decor；笔刷缩略图同用）
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

# 相邻格对 (a,b) 的共享边两端点（世界坐标）。任意相邻方向通用：
# 边中点＝两格心中点，边向量⊥心连线、半长＝HEX_SIZE/2（flat-top 六边形边长＝HEX_SIZE）。
func edge_points(a: Vector2i, b: Vector2i) -> PackedVector2Array:
	var ca := hex_center(a.x, a.y)
	var cb := hex_center(b.x, b.y)
	var mid := (ca + cb) * 0.5
	var perp := (cb - ca).normalized().orthogonal() * (HEX_SIZE * 0.5)
	return PackedVector2Array([mid - perp, mid + perp])

# 世界坐标 → 最近的格间共享边（[格A, 格B]；出界/无界内邻居返回 []）。编辑器河刷/桥刷的边拾取原语。
func nearest_edge_at(world: Vector2) -> Array:
	var cell := pixel_to_offset(world)
	if not _in_bounds(cell):
		return []
	var best := []
	var best_d := INF
	var ca := hex_center(cell.x, cell.y)
	for nb in HexGrid.neighbors(cell):
		if not _in_bounds(nb):
			continue
		var mid := (ca + hex_center(nb.x, nb.y)) * 0.5
		var d := world.distance_squared_to(mid)
		if d < best_d:
			best_d = d
			best = [cell, Vector2i(nb)]
	return best

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
			# 地块渲染（底色+描边+decor 扰动）走 HexTileRender 单一实现——与笔刷缩略图逐笔一致
			var seed: int = col * 73856093 ^ row * 19349663   # 每格确定性种子（扰动去印章感；纯函数、重绘不闪）
			HexTileRender.draw_tile(self, hex_center(col, row), HEX_SIZE, editor.color_for_tile(tile), editor.accent_for_tile(tile), editor.decor_for_tile(tile), seed, show_decor)
	_draw_line_features()   # 线特征 overlay（河/路/桥；宿主经 line_features() 可选提供）
	# 悬停高亮（黄框，线宽按缩放反算，保持屏幕上恒定粗细）
	if _in_bounds(hover_cell):
		var hp := hex_corners(hex_center(hover_cell.x, hover_cell.y))
		hp.append(hp[0])
		draw_polyline(hp, Color(1.0, 0.95, 0.2, 0.95), 2.5 / view_zoom)

# ---- 线特征 overlay（v4 schema：rivers/roads/bridges，格对＝相邻两格共享边）----
# 宿主可选契约：editor.line_features() -> {rivers:[{pairs:[…]}], roads:[{pairs:[…]}], bridges:[格对…]}。
# 三画布（编辑器/战斗/大地图）共享这一份渲染；通行语义只在大地图（Overworld），这里纯视觉。
const RIVER_UNDER := Color(0.10, 0.22, 0.38, 0.9)   # 河：深色衬底
const RIVER_WATER := Color(0.38, 0.66, 0.92, 0.95)  # 河：亮水面
const ROAD_COLOR := Color(0.72, 0.24, 0.16, 0.85)   # 路：红虚线（格心连线，参考图同款）
const BRIDGE_DARK := Color(0.30, 0.20, 0.10, 0.95)  # 桥：深木衬底
const BRIDGE_WOOD := Color(0.62, 0.44, 0.24, 1.0)   # 桥：亮木面

func _draw_line_features() -> void:
	if editor == null or not editor.has_method("line_features"):
		return
	var lf: Dictionary = editor.line_features()
	# 收集河边段（世界坐标端点对）；坏格对（非相邻）跳过
	var segs := []
	for riv in lf.get("rivers", []):
		if typeof(riv) != TYPE_DICTIONARY:
			continue
		for p in riv.get("pairs", []):
			var e := _edge_from_pair(p)
			if not e.is_empty():
				segs.append(edge_points(e[0], e[1]))
	# 河：先全画衬底再全画水面（衬底不被相邻段水面盖住）；端点补圆头，接缝连续
	for wpass in [[RIVER_UNDER, 7.0], [RIVER_WATER, 4.0]]:
		var c: Color = wpass[0]
		var w: float = wpass[1]
		for s in segs:
			draw_line(s[0], s[1], c, w)
			draw_circle(s[0], w * 0.5, c)
			draw_circle(s[1], w * 0.5, c)
	# 路：格对＝格心连线虚线（红），路径下的格保持地形底色
	for road in lf.get("roads", []):
		if typeof(road) != TYPE_DICTIONARY:
			continue
		for p in road.get("pairs", []):
			var e := _edge_from_pair(p)
			if e.is_empty():
				continue
			draw_dashed_line(hex_center(e[0].x, e[0].y), hex_center(e[1].x, e[1].y), ROAD_COLOR, 2.4, 5.0)
	# 桥：沿心连线方向横跨河边的木板（深衬底 + 亮木面 + 两道板缝）
	for p in lf.get("bridges", []):
		var e := _edge_from_pair(p)
		if e.is_empty():
			continue
		var ca := hex_center(e[0].x, e[0].y)
		var cb := hex_center(e[1].x, e[1].y)
		var mid := (ca + cb) * 0.5
		var dir := (cb - ca).normalized()
		var half := dir * (HEX_SIZE * 0.34)
		draw_line(mid - half, mid + half, BRIDGE_DARK, 9.0)
		draw_line(mid - half, mid + half, BRIDGE_WOOD, 6.0)
		var perp := dir.orthogonal() * 3.4
		for t: float in [-0.4, 0.0, 0.4]:
			var q: Vector2 = mid + dir * (HEX_SIZE * 0.34 * t)
			draw_line(q - perp, q + perp, BRIDGE_DARK, 1.2)

# 格对 JSON 形 [[x1,y1],[x2,y2]] → [Vector2i, Vector2i]；坏形/非相邻/越界返回 []
func _edge_from_pair(p) -> Array:
	if typeof(p) != TYPE_ARRAY or p.size() < 2:
		return []
	var a = p[0]
	var b = p[1]
	if typeof(a) != TYPE_ARRAY or a.size() < 2 or typeof(b) != TYPE_ARRAY or b.size() < 2:
		return []
	var va := Vector2i(int(a[0]), int(a[1]))
	var vb := Vector2i(int(b[0]), int(b[1]))
	if not (_in_bounds(va) and _in_bounds(vb)) or not HexGrid.adjacent(va, vb):
		return []
	return [va, vb]

# 地点旗帜（大地图地点 / 编辑器地点层共用）：底座 + 旗杆 + 旗面 + 名字（缩放够大才画字）
func draw_location_flag(c2: Vector2, col: Color, loc_label: String) -> void:
	draw_circle(c2 + Vector2(0, 5), 4.5, col.darkened(0.45))
	draw_line(c2 + Vector2(0, 7), c2 + Vector2(0, -11), Color(0.22, 0.17, 0.08), 2.0)
	draw_colored_polygon(PackedVector2Array([c2 + Vector2(0, -11), c2 + Vector2(10, -7.5), c2 + Vector2(0, -4)]), col)
	if view_zoom >= DECOR_MIN_ZOOM and loc_label != "":
		var font := get_theme_default_font()
		var fs := 9
		var tw := font.get_string_size(loc_label, HORIZONTAL_ALIGNMENT_CENTER, -1, fs).x
		var tp := c2 + Vector2(-tw * 0.5, 19.0)
		draw_string(font, tp + Vector2(0.8, 0.8), loc_label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0, 0, 0, 0.55))
		draw_string(font, tp, loc_label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.98, 0.95, 0.85))

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
