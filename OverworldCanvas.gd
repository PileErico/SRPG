extends "res://HexCanvas.gd"
## 大地图画布（M4）：地形渲染/平移/缩放/悬停沿用 HexCanvas；在其上叠画玩家队伍 token 与移动目的地标记。
## 左键＝移动指令（点目标格），右键＝取消，中键/滚轮/悬停沿用父类。宿主＝Overworld。

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			var off := pixel_to_offset(_world_from_screen(event.position))
			if _in_bounds(off):
				editor.left_click_cell(off.x, off.y)
			accept_event()
			return
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if editor != null:
				editor.cancel_action()
			accept_event()
			return
	super(event)

# 静态覆盖（画在线特征层、地形块之上）：区域外轮廓虚线（派系领地/区域解锁可视化，纯视觉）。
# 区域是静态地图数据（游玩中不变）→ 随地图/视图变化重绘，不参与悬停/涂格重绘。
func _static_overlay(ci: CanvasItem) -> void:
	if editor != null and editor.has_method("regions_for_draw"):
		for reg in editor.regions_for_draw():
			draw_region_outline(ci, reg["cells"], reg["color"], 2.0)

func _draw() -> void:
	super()   # 地形 + 悬停高亮；draw_set_transform 已是视图变换，下面直接用世界坐标
	if editor == null:
		return
	# 地点标记（M7）：按类型线稿符号 + 名字（据点已肃清＝灰显）——绘制单一实现在 HexCanvas.draw_location_marker（编辑器地点层同用）
	var font := get_theme_default_font()
	for loc in editor.locations_for_draw():
		var cell2: Vector2i = loc["cell"]
		draw_location_marker(hex_center(cell2.x, cell2.y), str(loc.get("type", "")), loc["color"], str(loc["label"]), loc["active"], str(loc.get("icon", "")))
	# 动态单位 token（WorldSim v1）：派系色圆 + 类型字形；敌对加红外环
	for wu in editor.world_units_for_draw():
		var wc: Vector2i = wu["cell"]
		var wp := hex_center(wc.x, wc.y)
		var wcol: Color = wu["color"]
		draw_circle(wp, 8.0, wcol.darkened(0.15))
		draw_arc(wp, 8.0, 0.0, TAU, 20, Color(0.12, 0.1, 0.06, 0.9), 1.8)
		if wu["hostile"]:
			draw_arc(wp, 11.0, 0.0, TAU, 20, Color(0.95, 0.3, 0.25, 0.9), 2.0)
		var g: String = wu["glyph"]
		var gw := font.get_string_size(g, HORIZONTAL_ALIGNMENT_CENTER, -1, 10).x
		draw_string(font, wp + Vector2(-gw * 0.5, 3.5), g, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.99, 0.97, 0.9))
	# 移动目的地标记（行进中显示）：目标格描金框
	var tgt: Vector2i = editor.move_target()
	if tgt.x >= 0:
		var tp := hex_corners(hex_center(tgt.x, tgt.y))
		tp.append(tp[0])
		draw_polyline(tp, Color(1.0, 0.85, 0.25, 0.95), 3.0 / view_zoom, true)
	# 队伍 token：主金圆 + 深边 + 白心（大地图上只有这一枚棋子）
	var cell: Vector2i = editor.party_cell()
	if cell.x < 0:
		return
	var c := hex_center(cell.x, cell.y)
	var r := HEX_SIZE * 0.52
	draw_circle(c, r, Color(0.93, 0.78, 0.25))
	draw_arc(c, r, 0.0, TAU, 28, Color(0.25, 0.18, 0.02, 0.9), 2.5)
	draw_circle(c, r * 0.42, Color(0.99, 0.97, 0.88))
