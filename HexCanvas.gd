extends Control
## 六边形地图画布。
## 输入：左键绘制 / 右键取色 / 中键按住拖拽平移 / 滚轮缩放。
## 反馈：悬停高亮当前格，左下角显示坐标 + 地块信息。
## 坐标系：flat-top（平顶），odd-q 偏移（奇数列向下错半格）。
## 视图变换由 view_offset(平移) + view_zoom(缩放) 表达，绘制时统一套用。

const HexGrid := preload("res://HexGrid.gd")
const TextureCache := preload("res://TextureCache.gd")   # 纹理加载缓存（子类画布 token/图标用，经继承共享）   # 纯六边形几何前置（取整器 single source）
const HexTileRender := preload("res://HexTileRender.gd")   # 地块渲染单一实现（底色+decor；笔刷缩略图同用）
const TerrainDB := preload("res://TerrainDB.gd")   # 取地形 entry 的手绘瓦片 art（有则优先于程序烘）
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

# 悬停格变化通知：宿主据此更新自己的 UI（如战斗常驻底边栏），tile 数据仍经 hover_text 单一源读。
signal hover_changed(col: int, row: int)
# 弹窗是否内含地形段：默认 true（编辑器/大地图）；战斗宿主设 false → 地形移交常驻栏、弹窗只留单位卡。
var terrain_in_popup := true
var _need_fit := false   # 新建/加载后置位：待布局尺寸就绪时在 _draw 里自动适配窗口

# —— 静态层：地形/过渡边**分块** + 线特征/区域轮廓，拆成独立子树（§7 性能·分块版）——
# 结构：_static_root(Node2D，承载视图变换 position/scale) 下挂 ①_chunks 网格（每块画自己那片格+过渡边）
# ②_line_layer（线特征+区域轮廓，画在块之上）。收益：**涂一格只重画所在块**（~9ms 而非全图 93ms）；
# 平移/缩放走 _static_root 节点变换（GPU、不重画）；Godot 按各块**内容 AABB 自动剔除离屏块** →
# 成本 ∝ 可见面积、与地图总大小无关（大图可行）。用 Node2D（按内容剔除，规避 Control size=(0,0) 被误剔的坑）。
const CHUNK := 16   # 每块 16×16 格

class _StaticNode extends Node2D:
	var host
	var cx := -1   # 地形块列/行；cx<0 ＝ 线特征层（非地形块）
	var cy := -1
	func _draw() -> void:
		if host == null:
			return
		if cx < 0:
			host._paint_line_layer(self)
		else:
			host._paint_chunk(self, cx, cy)

var _static_root: Node2D
var _chunks := []          # _chunks[cy][cx] = _StaticNode（地形块）
var _line_layer: _StaticNode
var _chunk_cols := 0
var _chunk_rows := 0

func _ready() -> void:
	clip_contents = true  # 缩放/平移越界的格子裁掉、不溢出侧边栏（裁整棵静态子树）
	_static_root = Node2D.new()
	_static_root.show_behind_parent = true   # 整棵静态子树画在本体动态层之下
	_static_root.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # 像素地块贴图放大不糊（子块继承）
	add_child(_static_root)
	_sync_static_transform()
	mouse_exited.connect(_on_mouse_exit)
	_make_info_label()

# 视图变换（平移 view_offset + 缩放 view_zoom）→ _static_root 节点变换。平移/缩放只调这个（GPU、不重画）。
func _sync_static_transform() -> void:
	if _static_root != null:
		_static_root.position = view_offset.round()   # 整像素对齐：像素地块平移不撕裂（Stage 1 再做缩放量化+动态层同源）
		_static_root.scale = Vector2(view_zoom, view_zoom)

# 纯视图变化（平移/缩放）：只移 _static_root + 重画动态层。块随之移动、Godot 自动剔除离屏块 → 不卡。
func _apply_view() -> void:
	_sync_static_transform()
	queue_redraw()   # 动态层（悬停/范围/单位）随新变换重画，成本低

# 按地图尺寸(重)建分块网格（尺寸变才重建；否则复用）。每块一个 Node2D，画世界坐标下自己那片格。
func _rebuild_chunks() -> void:
	if editor == null or _static_root == null:
		return
	var ncols := int(ceil(float(editor.width) / float(CHUNK)))
	var nrows := int(ceil(float(editor.height) / float(CHUNK)))
	if ncols == _chunk_cols and nrows == _chunk_rows and not _chunks.is_empty():
		return
	for line in _chunks:
		for ch in line:
			ch.queue_free()
	_chunks = []
	_chunk_cols = ncols
	_chunk_rows = nrows
	for cy in nrows:
		var line := []
		for cx in ncols:
			var ch := _StaticNode.new()
			ch.host = self
			ch.cx = cx
			ch.cy = cy
			_static_root.add_child(ch)
			line.append(ch)
		_chunks.append(line)
	if _line_layer == null:
		_line_layer = _StaticNode.new()
		_line_layer.host = self
		_static_root.add_child(_line_layer)   # 最后加＝画在块之上（线特征/区域轮廓压地形）
	else:
		_static_root.move_child(_line_layer, _static_root.get_child_count() - 1)

# 地图数据变化（加载/新建/线特征/区域/terrain 数据编辑…）：全量重画所有块 + 线层 + 同步变换 + 动态层。
func refresh_static() -> void:
	_rebuild_chunks()
	_sync_static_transform()
	for line in _chunks:
		for ch in line:
			ch.queue_redraw()
	if _line_layer != null:
		_line_layer.queue_redraw()
	queue_redraw()

# 涂/改单格（编辑器涂格用）：只重画该格所在块 + 邻格所在块（含跨块过渡边）。不动线层/动态层 → 便宜。
func refresh_cell(col: int, row: int) -> void:
	_queue_chunk_at(col, row)
	for nb in HexGrid.neighbors(Vector2i(col, row)):
		_queue_chunk_at(nb.x, nb.y)

@warning_ignore("integer_division")
func _queue_chunk_at(col: int, row: int) -> void:
	if col < 0 or row < 0 or _chunks.is_empty():
		return
	var cx := col / CHUNK
	var cy := row / CHUNK
	if cy < _chunks.size() and cx < _chunks[cy].size():
		_chunks[cy][cx].queue_redraw()

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
	refresh_static()   # 视图变换：静态层随新变换重绘

# 请求「适配窗口」：布局尺寸此刻可能还没就绪（如启动/新建时），
# 故只置位，等 _draw 拿到有效 size 再真正适配（见 _draw 顶部）。
func request_fit() -> void:
	_need_fit = true
	refresh_static()

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
	refresh_static()

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
# 纯视图变换 → 走 _apply_view（GPU 变换，与平移/缩放同路径）；原 refresh_static 全图重烘（≈93ms）是浪费。
func center_on_cell(col: int, row: int) -> void:
	view_offset = size * 0.5 - hex_center(col, row) * view_zoom
	_apply_view()

# ---- 六边形几何（世界坐标，未经视图变换）----

func hex_center(col: int, row: int) -> Vector2:
	var x := col_step * col + HEX_SIZE
	var y := row_step * (row + 0.5 * (col % 2)) + hex_h * 0.5
	return Vector2(x, y)

# 六角偏移常量（角度恒定 → 三角函数只算一次；hex_corners 是迷雾/范围/ZOC 每帧每格热路径）
static var _CORNER_OFF: PackedVector2Array = _make_corner_off()

static func _make_corner_off() -> PackedVector2Array:
	var off := PackedVector2Array()
	for i in 6:
		var ang := deg_to_rad(60.0 * i)
		off.append(Vector2(cos(ang), sin(ang)) * HEX_SIZE)
	return off

func hex_corners(center: Vector2) -> PackedVector2Array:
	var pts := PackedVector2Array()
	pts.resize(6)
	for i in 6:
		pts[i] = center + _CORNER_OFF[i]
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

# 画一个地形块（cx,cy）：本块覆盖的格（底色+描边+decor）+ 这些格「向后」方向的过渡边（去重、每内边一次）。
# 按世界坐标细分（视图变换由 _static_root 承载）；decor 恒画（细分只在数据变时发生、随节点缩放，不卡）。
func _paint_chunk(ci: CanvasItem, cx: int, cy: int) -> void:
	if editor == null:
		return
	var col0 := cx * CHUNK
	var row0 := cy * CHUNK
	var col1 := mini(editor.width, col0 + CHUNK)
	var row1 := mini(editor.height, row0 + CHUNK)
	# Diamond Down：按屏幕 y 升序画（下方格后画→盖住上方格的左下+右下侧壁），内部无缝、只边界/无下邻格处露边。
	var _cells := []
	for row in range(row0, row1):
		for col in range(col0, col1):
			_cells.append(Vector2i(col, row))
	_cells.sort_custom(func(a, b): return hex_center(a.x, a.y).y < hex_center(b.x, b.y).y)
	for _c: Vector2i in _cells:
		var col := _c.x
		var row := _c.y
		var tile = editor.tiles[row][col]
		var seed: int = col * 73856093 ^ row * 19349663   # 每格确定性种子（扰动去印章感；纯函数、重绘不闪）
		var _e = TerrainDB.entry_for(tile)                 # O(1) 取地形 entry → 手绘 art（有则优先）
		var _art: Array = TerrainDB.art_of(_e)             # 经单一源守卫访问器：null/非数组都安全返 []
		HexTileRender.draw_tile(ci, hex_center(col, row), HEX_SIZE, editor.color_for_tile(tile), editor.accent_for_tile(tile), editor.decor_for_tile(tile), seed, true, _art)
	for row in range(row0, row1):
		for col in range(col0, col1):
			_seam_cell(ci, col, row)
	# 放置物层：地形+过渡边之后，第二遍按 Diamond-Down 画带 object 的格 → 盖在地形之上
	# （单位在动态层、仍高于此静态放置物层 → 单位＞放置物＞地形）。同 HexTileRender 赤道对齐，静态缓存。
	for _c: Vector2i in _cells:
		var ocell = editor.tiles[_c.y][_c.x]
		if not (ocell is Dictionary):
			continue
		var obj = ocell.get("object")
		if typeof(obj) != TYPE_DICTIONARY:
			continue
		var oseed: int = _c.x * 73856093 ^ _c.y * 19349663
		var oentry = TerrainDB.entry_for(obj)
		var oart: Array = TerrainDB.art_of(oentry)
		var oanchor: float = TerrainDB.art_anchor_of(oentry)   # 道路/河流等叠加物按固定锚行钉赤道（末端落边）
		HexTileRender.draw_tile(ci, hex_center(_c.x, _c.y), HEX_SIZE, TerrainDB.color_of(obj), TerrainDB.accent_of(obj), TerrainDB.decor_of(obj), oseed, true, oart, oanchor)

# 单格的地形过渡边（§4.4）：向「更靠后」邻格（下方/同行右侧）的**不同底色**公共边描一道「同色系更深」软线，
# 让地形分界比同地形内边更清晰、柔化平涂拼接（极简：只加深、不渐变贴图）。去重使每条内边恰好画一次
# （含跨块边——从「更靠前」那格所在块画，涂格时 refresh_cell 连带重画邻块保证边随两侧色更新）。
func _seam_cell(ci: CanvasItem, col: int, row: int) -> void:
	# 过渡边只给「无 art 的程序兜底块」描：art 瓦片自带像素边缘，再描一道纯属噪 → 有 art 直接跳过。
	# （悬停高亮不受影响；整图皆 art 时等同关闭过渡边。见 HexTileRender 对齐规范。）
	if not TerrainDB.art_of(TerrainDB.entry_for(editor.tiles[row][col])).is_empty():
		return
	var c0: Color = editor.color_for_tile(editor.tiles[row][col])
	for nb in HexGrid.neighbors(Vector2i(col, row)):
		if not _in_bounds(nb) or nb.y < row or (nb.y == row and nb.x <= col):
			continue
		var c1: Color = editor.color_for_tile(editor.tiles[nb.y][nb.x])
		var diff := absf(c0.r - c1.r) + absf(c0.g - c1.g) + absf(c0.b - c1.b)
		if diff < 0.12:   # 近似同色（同地形/同色系变体）→ 不额外描，免噪
			continue
		var pts := edge_points(Vector2i(col, row), nb)
		var seam := c0.lerp(c1, 0.5).darkened(0.4)   # 两侧同色系的更深调
		seam.a = 0.5
		ci.draw_line(pts[0], pts[1], seam, 2.2)

# 线特征层：河/路/桥 + 子类静态覆盖（大地图区域轮廓）。只随数据变（refresh_static）重画，涂格不动它。
func _paint_line_layer(ci: CanvasItem) -> void:
	if editor == null:
		return
	_draw_line_features(ci)   # 线特征 overlay（河/路/桥；宿主经 line_features() 可选提供）
	_static_overlay(ci)       # 子类静态覆盖（如大地图区域外轮廓虚线）

# 子类可覆盖：在静态层（线层）上叠额外静态内容（如大地图区域外轮廓虚线）。基类空。
func _static_overlay(_ci: CanvasItem) -> void:
	pass

func _draw() -> void:
	if editor == null:
		return
	# 自愈：宿主某些进场路径未显式 refresh_static/request_fit（如 Sandbox 默认图）→ 有 editor 却无静态块时补建。
	# 延迟调用避免在 _draw 内 add_child；块建好后 _chunks 非空、不再触发（幂等）。
	if _chunks.is_empty() and editor.width > 0 and editor.height > 0:
		call_deferred("request_fit")
	if _need_fit and size.x >= 1.0 and size.y >= 1.0:
		_need_fit = false
		fit_to_view()   # 视图适配只在本体 _draw 解析（size 就绪时）；fit_to_view 会 refresh_static 同步静态层变换+细分
	draw_set_transform(view_offset, 0.0, Vector2(view_zoom, view_zoom))
	# 悬停高亮（黄框，线宽按缩放反算，保持屏幕上恒定粗细）——动态层，随鼠标换格重绘（地形/线特征在静态层，不动）
	if _in_bounds(hover_cell):
		var hp := hex_corners(hex_center(hover_cell.x, hover_cell.y))
		hp.append(hp[0])
		draw_polyline(hp, Color(1.0, 0.95, 0.2, 0.95), 2.5 / view_zoom)

# ---- 线特征 overlay（v4 schema：rivers/roads/bridges，格对＝相邻两格共享边）----
# 宿主可选契约：editor.line_features() -> {rivers:[{pairs:[…]}], roads:[{pairs:[…]}], bridges:[格对…]}。
# 三画布（编辑器/战斗/大地图）共享这一份渲染；通行语义只在大地图（Overworld），这里纯视觉。
const RIVER_WATER := Color(0.227, 0.431, 0.647)     # 河：＝浅水底色 #3A6EA5（保持一致；无深蓝描边）
const RIVER_WIDTH := 6.0                            # 河宽（世界坐标，略宽于旧 4px 水面）
const ROAD_COLOR := Color(0.72, 0.24, 0.16, 0.88)   # 路：红虚线（蜿蜒土径，参考图同款）
const ROAD_DASH := [7.0, 6.5, 3.0, 6.5]             # 交错虚线图案（世界单位）：长划-空-短划-空（空隙拉开、划段更疏朗）
const ROAD_WIDTH := 2.6                              # 路线宽（世界坐标，随缩放同比）
const BRIDGE_DARK := Color(0.30, 0.20, 0.10, 0.95)  # 桥：深木衬底
const BRIDGE_WOOD := Color(0.62, 0.44, 0.24, 1.0)   # 桥：亮木面

func _draw_line_features(ci: CanvasItem) -> void:
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
	# 河：单色（＝浅水底色）连续线，无深色描边；端点补圆头使相邻段接缝连续
	for s in segs:
		ci.draw_line(s[0], s[1], RIVER_WATER, RIVER_WIDTH)
		ci.draw_circle(s[0], RIVER_WIDTH * 0.5, RIVER_WATER)
		ci.draw_circle(s[1], RIVER_WIDTH * 0.5, RIVER_WATER)
	# 路：柔化的蜿蜒土径。锚点＝格间边中点（穿越位置固定、点位准确），格内穿过一个「抖动过的格心」，
	# 用 Chaikin 平滑成弧（拐角变柔），再按长短交错虚线画（土路观感）。逐格渲染：共享边中点两侧各画一半，
	# 天然在边中点接续 → 无缝、且穿越点始终落在正确的边上。路径下的格保持地形底色（overlay，不吞地形）。
	for road in lf.get("roads", []):
		if typeof(road) != TYPE_DICTIONARY:
			continue
		_draw_road_group(ci, road.get("pairs", []))
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
		ci.draw_line(mid - half, mid + half, BRIDGE_DARK, 9.0)
		ci.draw_line(mid - half, mid + half, BRIDGE_WOOD, 6.0)
		var perp := dir.orthogonal() * 3.4
		for t: float in [-0.4, 0.0, 0.4]:
			var q: Vector2 = mid + dir * (HEX_SIZE * 0.34 * t)
			ci.draw_line(q - perp, q + perp, BRIDGE_DARK, 1.2)

# 一组道路（格对集合）→ 逐格蜿蜒虚线。建「格→有路的邻格」邻接后逐格画：
# 2 端口（穿越格）＝两边中点 + 抖动格心的 Chaikin 平滑弧；其余（端点/岔路口）＝每条边中点直连格心一段。
# 端口＝相邻格心中点＝共享边中点：两侧格用同一端口 → 接缝处严丝合缝、穿越点恒在正确边上。
func _draw_road_group(ci: CanvasItem, pairs) -> void:
	if typeof(pairs) != TYPE_ARRAY:
		return
	var inc := {}   # Vector2i 格 -> Array[Vector2i] 有路邻格
	var seen := {}  # 归一化边键去重：手编地图若把同一边写两次/正反各一次，端口数不该虚增（否则穿越格误落岔路分支、半路重叠）
	for p in pairs:
		var e := _edge_from_pair(p)
		if e.is_empty():
			continue
		var a: Vector2i = e[0]
		var b: Vector2i = e[1]
		var ek := HexGrid.edge_key(a, b)   # 无向归一（编辑器/通行索引同一口径）
		if seen.has(ek):
			continue
		seen[ek] = true
		if not inc.has(a):
			inc[a] = []
		if not inc.has(b):
			inc[b] = []
		inc[a].append(b)
		inc[b].append(a)
	for cell in inc:
		var base := hex_center(cell.x, cell.y)
		var ctr := base + _road_jitter(cell)           # 抖动过的格心（去笔直感；确定性、重绘不闪）
		var ports := []
		for nb in inc[cell]:
			ports.append((base + hex_center(nb.x, nb.y)) * 0.5)   # 边中点＝穿越锚点
		if ports.size() == 2:
			_draw_road_dash(ci, _chaikin([ports[0], ctr, ports[1]], 2), ROAD_WIDTH)
		else:
			for pt in ports:
				_draw_road_dash(ci, PackedVector2Array([pt, ctr]), ROAD_WIDTH)

# 道路格心的确定性微扰（纯格坐标 hash，重绘不闪）。幅度小（0.06~0.18 HEX）——只弯路身、不动边中点锚点。
func _road_jitter(cell: Vector2i) -> Vector2:
	var h: int = (cell.x * 73856093) ^ (cell.y * 19349663)
	var ang := float(h & 1023) / 1023.0 * TAU
	var mag := (0.06 + float((h >> 10) & 255) / 255.0 * 0.12) * HEX_SIZE
	return Vector2(cos(ang), sin(ang)) * mag

# Chaikin 切角平滑（保端点）：每段取 1/4、3/4 点替换拐角，迭代后折线变圆滑；首尾端点不动＝道路穿越锚点稳定。
static func _chaikin(pts: Array, iterations: int) -> PackedVector2Array:
	var p := PackedVector2Array(pts)
	for _it in iterations:
		if p.size() < 3:
			break
		var out := PackedVector2Array()
		out.append(p[0])
		for i in range(p.size() - 1):
			out.append(p[i].lerp(p[i + 1], 0.25))
			out.append(p[i].lerp(p[i + 1], 0.75))
		out.append(p[p.size() - 1])
		p = out
	return p

# 沿折线按弧长走 ROAD_DASH 图案，把「实线区间」逐段画成圆头子折线（长短交错 + 柔和端头）。
func _draw_road_dash(ci: CanvasItem, poly: PackedVector2Array, w: float) -> void:
	var n := poly.size()
	if n < 2:
		return
	var pat := ROAD_DASH
	var pat_i := 0
	var rem: float = pat[0]
	var drawing := true          # 图案首元素＝实线
	var cur: Vector2 = poly[0]
	var span := PackedVector2Array()
	span.append(cur)
	var i := 1
	while i < n:
		var nxt: Vector2 = poly[i]
		var seg := cur.distance_to(nxt)
		if seg <= 0.0001:
			cur = nxt
			i += 1
			continue
		if seg < rem:
			rem -= seg
			cur = nxt
			if drawing:
				span.append(cur)
			i += 1
		else:
			var cut := cur.lerp(nxt, rem / seg)   # 在图案元素边界处切断
			if drawing:
				span.append(cut)
				_road_stroke(ci, span, w)
				span = PackedVector2Array()
			pat_i = (pat_i + 1) % pat.size()
			rem = pat[pat_i]
			drawing = not drawing
			cur = cut
			if drawing:
				span.append(cur)
	if drawing and span.size() >= 2:
		_road_stroke(ci, span, w)

# 一段实线：圆头子折线（抗锯齿 + 两端补圆点，使虚线端头柔和而非齐口）
func _road_stroke(ci: CanvasItem, span: PackedVector2Array, w: float) -> void:
	ci.draw_polyline(span, ROAD_COLOR, w, true)
	ci.draw_circle(span[0], w * 0.5, ROAD_COLOR)
	ci.draw_circle(span[span.size() - 1], w * 0.5, ROAD_COLOR)

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

# 地点名字标签（大地图地点 / 编辑器地点层共用）：瓦片=地点 🔒 后图标退役（地点长相＝瓦片美术本身），
# 只补瓦片给不了的两样——名字 + 据点状态：active=false（据点已肃清）→ 格上罩薄灰纱 + 名字灰显。
func draw_location_label(c2: Vector2, loc_label: String, active := true) -> void:
	if not active:
		draw_colored_polygon(hex_corners(c2), Color(0.05, 0.05, 0.08, 0.32))
	if view_zoom >= DECOR_MIN_ZOOM and loc_label != "":
		var font := get_theme_default_font()
		var fs := 9
		var tw := font.get_string_size(loc_label, HORIZONTAL_ALIGNMENT_CENTER, -1, fs).x
		var tp := c2 + Vector2(-tw * 0.5, 19.0)
		draw_string(font, tp + Vector2(0.8, 0.8), loc_label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0, 0, 0, 0.55))
		draw_string(font, tp, loc_label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.98, 0.95, 0.85) if active else Color(0.72, 0.72, 0.74))

# 区域外轮廓虚线（大地图领地/区域解锁可视化，纯视觉；大地图/编辑器可共用）：区域内每格，凡「跨边邻格
# 不在区域内」的边＝边界边，画成虚线（深色衬底 + 区域/派系色）。逐边界边只从区域内那侧画一次（含内孔边界）。
func draw_region_outline(ci: CanvasItem, cells: Array, col: Color, w: float = 2.0, dash: float = 4.0) -> void:
	var inside := {}
	for c in cells:
		inside[c] = true
	for c in cells:
		for nb in HexGrid.neighbors(c):
			if inside.has(nb):
				continue
			var pts := edge_points(c, nb)   # 共享边两端点（几何对越界邻格同样成立）
			ci.draw_dashed_line(pts[0], pts[1], Color(0.05, 0.05, 0.07, 0.55), w + 1.6, dash)   # 深色衬底（对比）
			ci.draw_dashed_line(pts[0], pts[1], col, w, dash)

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
			_apply_view()   # 平移：只移静态层节点变换（不重画地形）→ 不卡
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
	hover_changed.emit(hover_cell.x, hover_cell.y)   # 通知宿主（战斗底边栏据此读 hover_text 更新地形）
	# 每次换格：先清扩展段（立即移出树，不残留一帧）
	for c in _info_extra.get_children():
		_info_extra.remove_child(c)
		c.queue_free()
	if hover_cell.x < 0:
		_info_panel.visible = false
		info_label.text = ""
		return
	# 宿主可选钩子：给该格提供一个扩展控件（有单位→单位卡，否则 null）。编辑器无此方法 = 只显示地形。
	var extra = null
	if editor != null and editor.has_method("hover_extra"):
		extra = editor.hover_extra(hover_cell.x, hover_cell.y)
	if extra != null:
		_info_extra.add_child(extra)
	if terrain_in_popup:   # 编辑器/大地图：弹窗含地形段
		info_label.text = editor.hover_text(hover_cell.x, hover_cell.y)
		if extra != null:
			_info_extra.add_child(HSeparator.new())   # 单位段与地形段之间的分隔
		_info_panel.visible = true
	else:                  # 战斗：地形已在常驻栏 → 弹窗只留单位卡，无卡则隐藏
		info_label.text = ""
		_info_panel.visible = (extra != null)

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
	_apply_view()   # 缩放只移节点变换（GPU），永不重细分地形 → 无卡顿（decor 常驻、随节点缩放，见 _paint_chunk）
