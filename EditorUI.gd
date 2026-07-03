extends RefCounted
## 编辑器公共 UI 控件工厂——地图/物品等编辑器共用一套 chrome（DRY 单一出处）。
## 全 static；发信号的控件（add_line/check/spin）把刷新逻辑经 on_change 回调传入，
## 不耦合具体编辑器的 _refresh；确认框经 host 挂子节点。
## 用法：const EditorUI := preload("res://EditorUI.gd")，再 EditorUI.section_title(...) 等。
## （不用 class_name：与 *DB / EditorTheme 同理，headless 扫描找不到全局类。）

const EditorTheme := preload("res://EditorTheme.gd")

# —— 基础构件 ——

# 纯文本标签（编辑器里散用；比 Label.new()+set text 省一行）。
static func label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l

# 分节标题：一条淡蓝底色条 + 亮字，给侧栏各段清晰的视觉分隔。
static func section_title(text: String) -> Control:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.22, 0.36, 0.55, 0.5)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 7
	sb.content_margin_right = 6
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	p.add_theme_stylebox_override("panel", sb)
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0))
	p.add_child(l)
	return p

# 「标签 + 控件」一行：左侧定宽标签，右侧控件撑满。
static func field_row(text: String, control: Control, label_w := 200) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(label_w, 0)
	row.add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row

# 把侧栏 VBox 包进带深色底 + 内边距的面板（与画布视觉分开）。
static func panelize(inner: Control) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.13, 0.16)
	sb.set_content_margin_all(7)
	p.add_theme_stylebox_override("panel", sb)
	p.add_child(inner)
	return p

# 铺满垫底的深色背景 ColorRect（去掉引擎默认灰；加到编辑器根最底层）。
static func background() -> ColorRect:
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = EditorTheme.bg_color()
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return bg

# —— 折叠区 ——

# 点标题栏收起/展开 content。进阶/占空间的段默认收起，给主内容让位。
# expand_up=true：底部停靠段——content 在 header 之上（向上展开），header 钉死在底部原地不随开合上下跳。
static func make_foldable(title: String, content: Control, collapsed: bool, expand_up: bool = false, on_toggle := Callable()) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var hdr := Button.new()
	hdr.toggle_mode = true
	hdr.button_pressed = not collapsed
	hdr.alignment = HORIZONTAL_ALIGNMENT_LEFT
	hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.focus_mode = Control.FOCUS_NONE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.18, 0.22, 0.28)
	sb.set_corner_radius_all(3)
	sb.set_content_margin_all(4)
	hdr.add_theme_stylebox_override("normal", sb)
	hdr.add_theme_stylebox_override("hover", sb)
	hdr.add_theme_stylebox_override("pressed", sb)
	hdr.add_theme_color_override("font_color", Color(0.86, 0.9, 0.96))
	# 箭头：普通段 ▸收起/▾展开；向上展开段 ▴收起(点了向上开)/▾展开(点了向下收)
	var _upd := func(open: bool):
		var a := ("▾ " if open else "▴ ") if expand_up else ("▾ " if open else "▸ ")
		hdr.text = a + title
	_upd.call(not collapsed)
	content.visible = not collapsed
	hdr.toggled.connect(func(pressed: bool):
		content.visible = pressed
		_upd.call(pressed)
		if on_toggle.is_valid():
			on_toggle.call(pressed))
	if expand_up:
		box.add_child(content)   # content 在上、header 在下 → 展开时内容向上长，header 留在底部
		box.add_child(hdr)
	else:
		box.add_child(hdr)
		box.add_child(content)
	return box

# —— 顶栏下拉菜单（绘图软件式：文件/编辑/视图）——
# 弹出项由调用方 get_popup().add_item(...) 填、再接 id_pressed。
static func make_menu(title: String) -> MenuButton:
	var mb := MenuButton.new()
	mb.text = title
	mb.focus_mode = Control.FOCUS_NONE
	mb.get_popup().add_theme_constant_override("v_separation", 3)
	return mb

# —— 表单动态字段（信号经 on_change 回调，不耦合具体编辑器刷新）——

static func add_line(parent: Node, text: String, value: String, on_change := Callable()) -> LineEdit:
	var le := LineEdit.new()
	le.text = value
	if on_change.is_valid():
		le.text_changed.connect(func(_t): on_change.call())
	parent.add_child(field_row(text, le))
	return le

static func add_check(parent: Node, text: String, value: bool, on_change := Callable()) -> CheckBox:
	var cb := CheckBox.new()
	cb.button_pressed = value
	if on_change.is_valid():
		cb.toggled.connect(func(_v): on_change.call())
	parent.add_child(field_row(text, cb))
	return cb

static func add_spin(parent: Node, text: String, value: float, mn: float, mx: float, step: float, on_change := Callable()) -> SpinBox:
	var sb := SpinBox.new()
	sb.min_value = mn
	sb.max_value = mx
	sb.step = step
	sb.value = value
	if on_change.is_valid():
		sb.value_changed.connect(func(_v): on_change.call())
	parent.add_child(field_row(text, sb))
	return sb

# —— 文件对话框工厂 ——
# filters：[[pattern, desc], ...]，如 [["*.json","地图 JSON"]]。native RES 对话框不存在→资源访问传 native=false。
static func make_file_dialog(mode: int, access: int, filters: Array, native := true) -> FileDialog:
	var dlg := FileDialog.new()
	dlg.file_mode = mode
	dlg.access = access
	dlg.use_native_dialog = native
	for f in filters:
		if typeof(f) == TYPE_ARRAY and f.size() >= 2:
			dlg.add_filter(str(f[0]), str(f[1]))
	return dlg

# —— 确认框 ——

# 通用确认：弹出 → 确定执行 on_ok / 取消执行 on_cancel，两路都 queue_free（一次性、不残留节点）。
static func confirm(host: Node, text: String, ok_text: String, on_ok: Callable,
		on_cancel := Callable(), title := "确认", cancel_text := "取消") -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = title
	dlg.dialog_text = text
	dlg.ok_button_text = ok_text
	dlg.get_cancel_button().text = cancel_text
	host.add_child(dlg)
	dlg.confirmed.connect(func():
		if on_ok.is_valid():
			on_ok.call()
		dlg.queue_free())
	dlg.canceled.connect(func():
		if on_cancel.is_valid():
			on_cancel.call()
		dlg.queue_free())
	dlg.popup_centered()

# 未保存改动守卫：干净 → 直接 on_ok；脏 → 弹确认（丢弃→on_ok / 留下→on_cancel）。
static func confirm_discard(host: Node, dirty: bool, on_ok: Callable, on_cancel := Callable(),
		text := "当前有未保存的改动，继续将丢弃。", ok_text := "丢弃", cancel_text := "取消") -> void:
	if not dirty:
		if on_ok.is_valid():
			on_ok.call()
		return
	confirm(host, text, ok_text, on_ok, on_cancel, "未保存的改动", cancel_text)
