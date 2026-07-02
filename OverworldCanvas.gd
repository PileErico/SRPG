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

func _draw() -> void:
	super()   # 地形 + 悬停高亮；draw_set_transform 已是视图变换，下面直接用世界坐标
	if editor == null:
		return
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
