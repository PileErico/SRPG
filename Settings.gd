extends Control
## 设置覆盖层：音频（全局音量）/ 图像（分辨率）两页。主菜单叠加打开、返回/ESC 即 free。
## 纯代码 UI（与 StartMenu 一致）；读写经 GameSettings（即改即存即用）。

const GameSettings := preload("res://GameSettings.gd")
const UIScale := preload("res://UIScale.gd")

signal closed

var _panel: PanelContainer

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)   # 运行时叠加：强制铺满父级（菜单）
	mouse_filter = Control.MOUSE_FILTER_STOP   # 挡住背后菜单

	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.55)
	add_child(dim)

	# 面板直接挂 self（不套 CenterContainer）：容器每次布局会把子节点 scale 重置回 1、
	# 缩放被吃掉 → 改手动定位居中（同角色卡 _card 的做法）。
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(560, 430)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.13, 0.16)
	sb.set_corner_radius_all(8)
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.12)
	sb.set_content_margin_all(20)
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)
	_panel = panel                              # UI 同比缩放（1080p 基准）
	# 覆盖层自身 FULL_RECT、随视口变化重排 → self.resized 驱动重算（读当前视口，无竞态）。
	resized.connect(_apply_ui_scale)
	_apply_ui_scale.call_deferred()

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	panel.add_child(v)

	var title := Label.new()
	title.text = "设置"
	title.add_theme_font_size_override("font_size", 28)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)

	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.custom_minimum_size = Vector2(0, 280)
	v.add_child(tabs)
	var audio := _build_audio_page()
	audio.name = "音频"
	tabs.add_child(audio)
	var video := _build_video_page()
	video.name = "图像"
	tabs.add_child(video)

	var back := Button.new()
	back.text = "返回"
	back.custom_minimum_size = Vector2(0, 42)
	back.pressed.connect(_close)
	v.add_child(back)

# 音频页：全局音量滑条（0..100 → Master 总线）
func _build_audio_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 12)
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(0, 8)
	page.add_child(pad)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	page.add_child(row)
	var lbl := Label.new()
	lbl.text = "全局音量"
	lbl.custom_minimum_size = Vector2(90, 0)
	row.add_child(lbl)
	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = 100
	slider.step = 1
	slider.value = roundf(GameSettings.get_volume() * 100.0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(slider)
	var pct := Label.new()
	pct.text = "%d%%" % int(slider.value)
	pct.custom_minimum_size = Vector2(52, 0)
	pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(pct)
	slider.value_changed.connect(func(val: float):
		pct.text = "%d%%" % int(val)
		GameSettings.set_volume(val / 100.0))
	return page

# 图像页：分辨率下拉（窗口尺寸）
func _build_video_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 12)
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(0, 8)
	page.add_child(pad)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	page.add_child(row)
	var lbl := Label.new()
	lbl.text = "分辨率"
	lbl.custom_minimum_size = Vector2(90, 0)
	row.add_child(lbl)
	var ob := OptionButton.new()
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var cur := GameSettings.get_resolution()
	for i in GameSettings.RESOLUTIONS.size():
		var r: Vector2i = GameSettings.RESOLUTIONS[i]
		ob.add_item("%d × %d" % [r.x, r.y])
		ob.set_item_metadata(i, r)
		if r == cur:
			ob.select(i)
	row.add_child(ob)
	ob.item_selected.connect(func(idx: int):
		var r = ob.get_item_metadata(idx)
		if r is Vector2i:
			GameSettings.set_resolution(r))
	var note := Label.new()
	note.text = "窗口模式尺寸（界面以 1080p 为基准随之等比缩放）"
	note.add_theme_color_override("font_color", Color(0.6, 0.65, 0.72))
	note.add_theme_font_size_override("font_size", 12)
	page.add_child(note)
	return page

# UI 同比缩放：对话框整体按 1080p 基准缩放；居中枢轴 → 在 CenterContainer 内保持居中。
func _apply_ui_scale() -> void:
	if _panel == null or not is_instance_valid(_panel):
		return
	var f := UIScale.factor(get_viewport_rect().size)
	_panel.size = _panel.get_combined_minimum_size()   # 自适应内容（≥560×430）
	_panel.pivot_offset = Vector2.ZERO                 # 左上角缩放 → 手动居中
	_panel.scale = Vector2.ONE * f
	_panel.position = ((get_viewport_rect().size - _panel.size * f) * 0.5).floor()

func _close() -> void:
	closed.emit()
	queue_free()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		_close()
		get_viewport().set_input_as_handled()
