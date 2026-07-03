extends "res://HexCanvas.gd"

const UnitPiece := preload("res://UnitPiece.gd")   # 单位棋子渲染（与战场同一出处；有工坊外观→精灵棋子）

func _ready() -> void:
	super()   # 保留 HexCanvas._ready
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # 像素精灵放大不糊（与 SandboxCanvas 一致）
## 编辑器画布：在 HexCanvas（地形底图 + 悬停高亮）之上叠加「图层编辑」。
## 仿 SandboxCanvas 的「底图 + 叠加层」模式；不改动 HexCanvas（它被 SandboxCanvas 共用），
## 编辑器专属的「区域层绘制 + 按当前层分派输入」都收在本文件里。
##
## 左右键按 editor.current_layer 分派（经 editor.primary_paint / secondary_paint）：
##   地形层：左＝画地形 / 右＝取色（父类原语义）
##   区域层：左＝把格加入当前区域 / 右＝从当前区域移除（均支持拖动）
## 中键平移 / 滚轮缩放 / 悬停 复用父类几何与状态。

var _secondary_down := false   # 右键是否按住（区域层用来拖动擦除）
var _hover_edge := []          # 线特征层悬停的格间边 [Vector2i a, Vector2i b]（空＝无）

func _draw() -> void:
	super()   # 先画地形 + 线特征 + 悬停高亮（父类已 draw_set_transform 视图变换，且保留到本函数）
	if editor == null:
		return
	_draw_regions()
	_draw_units()
	_draw_locations()
	_draw_hover_edge()

# 线特征层：悬停边高亮（黄色短线，指示河刷/桥刷/擦除将作用的边）
func _draw_hover_edge() -> void:
	if editor.current_layer != "line" or _hover_edge.size() != 2:
		return
	var pts := edge_points(_hover_edge[0], _hover_edge[1])
	draw_line(pts[0], pts[1], Color(1.0, 0.95, 0.2, 0.9), 3.0 / view_zoom)

# 地点层：按类型画标记（绘制单一实现在 HexCanvas.draw_location_marker，与大地图同款）；选中地点加金圈
func _draw_locations() -> void:
	if not editor.has_method("locations_for_draw"):
		return
	var active := {}
	if editor.has_method("active_location"):
		active = editor.active_location()
	var acell := Vector2i(int(active.get("col", -1)), int(active.get("row", -1))) if not active.is_empty() else Vector2i(-1, -1)
	for loc in editor.locations_for_draw():
		var cell: Vector2i = loc["cell"]
		if not _in_bounds(cell):
			continue
		var c := hex_center(cell.x, cell.y)
		if editor.current_layer == "location" and cell == acell:
			draw_arc(c, HEX_SIZE * 0.72, 0.0, TAU, 24, Color(1.0, 0.85, 0.25, 0.95), 2.5 / view_zoom)
		draw_location_marker(c, str(loc.get("type", "")), loc["color"], str(loc["label"]), true, str(loc.get("icon", "")))

# 单位层：画「这一关的单位」棋子（阵营色圆 + 黑描边 + 原型图标）。
# 非单位层时半透明，便于一边看地形/区域一边知道单位在哪。
func _draw_units() -> void:
	if editor.map_units.is_empty():
		return
	var on_unit: bool = editor.current_layer == "unit"
	for e in editor.map_units:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var col := int(e.get("col", 0))
		var row := int(e.get("row", 0))
		if not _in_bounds(Vector2i(col, row)):
			continue
		var c := hex_center(col, row)
		var r := HEX_SIZE * 0.62
		var fac: Color = editor.faction_color(str(e.get("faction", "enemy")))
		var proto = e.get("proto", {})
		var pid := str(proto.get("id", "")) if typeof(proto) == TYPE_DICTIONARY else ""
		var icon := str(proto.get("icon", "")) if typeof(proto) == TYPE_DICTIONARY else ""
		# 有工坊拼装外观 → 精灵棋子（与战场同一 UnitPiece + 同一 look 判定，非单位层压淡）
		var look := UnitPiece.look_for(pid)
		if not look.is_empty() and icon != "":
			var opts := UnitPiece.piece_opts(look)
			opts["tint"] = Color(1, 1, 1, 1.0 if on_unit else 0.6)
			UnitPiece.draw_piece(self, c, r, TextureCache.get_tex(icon), fac, opts)
			continue
		# 无外观 → 圆底 token
		var fill := fac
		fill.a = 1.0 if on_unit else 0.5
		draw_circle(c, r, fill)
		draw_arc(c, r, 0.0, TAU, 28, Color(0, 0, 0, 0.7), 2.0)
		var tex = TextureCache.get_tex(icon)
		if tex != null:
			var s := r * 1.6
			draw_texture_rect(tex, Rect2(c - Vector2(s, s) * 0.5, Vector2(s, s)), false, Color(1, 1, 1, 1.0 if on_unit else 0.6))

# 区域层：每个区域一片半透明色块。当前层＝区域时正常显示、当前区域更亮 + 描边；
# 当前层＝地形时整体压淡（让你画地形时仍看得见区域、但不抢眼）。
func _draw_regions() -> void:
	if editor.regions.is_empty():
		return
	var on_region: bool = editor.current_layer == "region"
	var active: Dictionary = editor.active_region()
	var active_id := str(active.get("id", ""))   # 空字典 → ""（= 当前无激活区域）
	for reg in editor.regions:
		var base := Color.html(str(reg.get("color", "#FFFFFF")))
		var is_active: bool = on_region and active_id != "" and str(reg.get("id", "")) == active_id
		var fill := base
		fill.a = (0.45 if is_active else 0.30) if on_region else 0.16
		for cell in reg["cells"]:
			draw_colored_polygon(hex_corners(hex_center(cell.x, cell.y)), fill)
		if is_active:
			var oc := base
			oc.a = 0.95
			for cell in reg["cells"]:
				var pts := hex_corners(hex_center(cell.x, cell.y))
				pts.append(pts[0])
				draw_polyline(pts, oc, 2.0 / view_zoom)

# —— 输入：左/右键按当前层分派；中键平移、滚轮缩放、悬停 复用父类逻辑 ——
# 线特征层：河/桥＝边拾取（nearest_edge_at）、路＝格轨迹；右键一律边擦除。均走 stroke=一段拖动一次撤销。
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				painting = event.pressed
				if event.pressed:
					editor.begin_stroke()
					_primary_at(event.position)
				else:
					editor.end_stroke()
			MOUSE_BUTTON_RIGHT:
				if event.pressed:
					if editor.current_layer in ["region", "unit", "line"]:
						_secondary_down = true
						editor.begin_stroke()   # 擦除走 stroke → 整段拖动一次撤销
						_secondary_at(event.position)
					else:
						_secondary_at(event.position)   # 地形：单击取色 / 地点：单击删除
				elif _secondary_down:
					_secondary_down = false
					editor.end_stroke()
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
			_primary_at(event.position)
		elif _secondary_down:
			_secondary_at(event.position)
		_update_hover(event.position)
		_update_hover_edge(event.position)

func _primary_at(screen_pos: Vector2) -> void:
	# 线特征层的河/桥工具吃「边」不吃「格」：拾取最近边交给宿主；路刷仍走格轨迹（primary_paint 分派）
	if editor.current_layer == "line" and editor._line_mode != "road":
		var e := nearest_edge_at(_world_from_screen(screen_pos))
		if e.size() == 2:
			editor.line_paint_edge(e[0], e[1], true)
		return
	var off := pixel_to_offset(_world_from_screen(screen_pos))
	if _in_bounds(off):
		editor.primary_paint(off.x, off.y)

func _secondary_at(screen_pos: Vector2) -> void:
	if editor.current_layer == "line":
		var e := nearest_edge_at(_world_from_screen(screen_pos))
		if e.size() == 2:
			editor.line_paint_edge(e[0], e[1], false)
		return
	var off := pixel_to_offset(_world_from_screen(screen_pos))
	if _in_bounds(off):
		editor.secondary_paint(off.x, off.y)

# 线特征层悬停边（黄色指示线）；非线层清空
func _update_hover_edge(screen_pos: Vector2) -> void:
	var ne := []
	if editor != null and editor.current_layer == "line":
		ne = nearest_edge_at(_world_from_screen(screen_pos))
	if ne != _hover_edge:
		_hover_edge = ne
		queue_redraw()
