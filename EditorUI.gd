extends RefCounted
## 编辑器公共 UI 控件工厂——地图/物品等编辑器共用一套 chrome（DRY 单一出处）。
## 全 static；发信号的控件（add_line/check/spin）把刷新逻辑经 on_change 回调传入，
## 不耦合具体编辑器的 _refresh；确认框经 host 挂子节点。
## 用法：const EditorUI := preload("res://EditorUI.gd")，再 EditorUI.section_title(...) 等。
## （不用 class_name：与 *DB / EditorTheme 同理，headless 扫描找不到全局类。）

const EditorTheme := preload("res://EditorTheme.gd")
const TagDB := preload("res://TagDB.gd")       # 自由 tag 区 chip 中文标签（tag 单一词表）
const StatMeta := preload("res://StatMeta.gd") # 修正行 stat 中文标签

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

# —— 工坊切换器（角色 ⇄ 地块）——
# scene_switch 的预置参数版（技改 §3-10：原独立实现已删，迁移到参数化通用件）。
static func workshop_switch(host: Node, current: String) -> Control:
	return scene_switch(host, current, [
		["appearance", "🎭 角色", "res://AppearanceWorkshop.tscn"],
		["terrain", "🧱 地块", "res://TerrainArtWorkshop.tscn"],
	])

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


# —— 自由 tag 清单区（🔒 技能设计 §10 阶段2.4 抽通用：Item/Skill/Effect 编辑器共用一份）——
# arr 被就地增删（调用方持有同一数组）；options=[["sep",分组标题] | [id] | [id,显示文本], ...]，
# 空/只有分隔 ⇒ 不显下拉、只留手动输入。on_change＝任何增删后回调（刷新预览/置脏）。
static func add_tag_list(parent: Node, label_text: String, arr: Array, options: Array, on_change := Callable()) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	var adder := HBoxContainer.new()
	adder.add_theme_constant_override("separation", 6)
	var pick := OptionButton.new()
	pick.custom_minimum_size = Vector2(170, 0)
	pick.add_item("（下拉添加…）")
	pick.set_item_metadata(0, "")
	for o in options:
		if typeof(o) != TYPE_ARRAY or o.is_empty():
			continue
		if str(o[0]) == "sep":
			pick.add_separator(str(o[1]) if o.size() > 1 else "")
		else:
			pick.add_item(str(o[1]) if o.size() > 1 else str(o[0]))
			pick.set_item_metadata(pick.item_count - 1, str(o[0]))
	var has_presets := false
	for i in pick.item_count:
		if not pick.is_item_disabled(i) and str(pick.get_item_metadata(i)) != "":
			has_presets = true
			break
	if has_presets:
		pick.item_selected.connect(func(idx):
			var tg = pick.get_item_metadata(idx)
			if tg != null and str(tg) != "" and not arr.has(str(tg)):
				arr.append(str(tg))
				_rebuild_tag_box(box, arr, on_change)
				if on_change.is_valid():
					on_change.call()
			pick.select(0))
		adder.add_child(pick)
	else:
		pick.queue_free()
	var manual := LineEdit.new()
	manual.placeholder_text = "手动 tag"
	manual.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	adder.add_child(manual)
	var addb := Button.new()
	addb.text = "＋"
	addb.pressed.connect(func():
		var tt := manual.text.strip_edges()
		if tt != "" and not arr.has(tt):
			arr.append(tt)
			_rebuild_tag_box(box, arr, on_change)
			if on_change.is_valid():
				on_change.call()
		manual.clear())
	adder.add_child(addb)
	parent.add_child(field_row(label_text, adder))
	parent.add_child(box)
	_rebuild_tag_box(box, arr, on_change)

static func _rebuild_tag_box(box: VBoxContainer, arr: Array, on_change: Callable) -> void:
	if box == null or not is_instance_valid(box):
		return
	for c in box.get_children():
		c.queue_free()   # ⚠ 必须 queue_free：常由行内 ✕ 的 pressed 触发，free() 会当场释放发信号中的按钮
	if arr.is_empty():
		var l := Label.new()
		l.text = "（无）"
		l.add_theme_color_override("font_color", Color(0.55, 0.6, 0.66))
		l.add_theme_font_size_override("font_size", 12)
		box.add_child(l)
		return
	for t in arr:
		var row := HBoxContainer.new()
		var l := Label.new()
		l.text = "%s（%s）" % [TagDB.cn(str(t)), str(t)]
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		var rm := Button.new()
		rm.text = "✕"
		var tag := str(t)
		rm.pressed.connect(func():
			arr.erase(tag)
			_rebuild_tag_box(box, arr, on_change)
			if on_change.is_valid():
				on_change.call())
		row.add_child(rm)
		box.add_child(row)


# —— 修正行（stat 下拉 + 固定/百分比 + 数值 + ✕）——技能被动块 / 效果 mods 共用；
# ItemEditor 的修正行含 vision_state 特型不并入。stat_keys＝可选 stat 键序（中文经 StatMeta）。
# 返回 {row, stat, op, value}；entries＝调用方的行数组（✕ 时自动 erase 本 entry）。
static func add_mod_row(parent: Node, entries: Array, stat_keys: Array, stat: String, op: String, value: float, on_change := Callable()) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var st := OptionButton.new()
	st.custom_minimum_size = Vector2(180, 0)
	for key in stat_keys:
		st.add_item("%s %s" % [key, StatMeta.label(str(key))])
		st.set_item_metadata(st.item_count - 1, str(key))
	for i in st.item_count:
		if str(st.get_item_metadata(i)) == stat:
			st.select(i)
			break
	if on_change.is_valid():
		st.item_selected.connect(func(_i): on_change.call())
	row.add_child(st)
	var opb := OptionButton.new()
	opb.custom_minimum_size = Vector2(110, 0)
	for o in [["flat", "固定"], ["pct", "百分比%"]]:
		opb.add_item(str(o[1]))
		opb.set_item_metadata(opb.item_count - 1, str(o[0]))
	for i in opb.item_count:
		if str(opb.get_item_metadata(i)) == op:
			opb.select(i)
			break
	if on_change.is_valid():
		opb.item_selected.connect(func(_i): on_change.call())
	row.add_child(opb)
	var val := SpinBox.new()
	val.min_value = -9999
	val.max_value = 9999
	val.step = 0.5
	val.value = value
	val.custom_minimum_size = Vector2(110, 0)
	if on_change.is_valid():
		val.value_changed.connect(func(_v): on_change.call())
	row.add_child(val)
	var rm := Button.new()
	rm.text = "✕"
	var entry := {"row": row, "stat": st, "op": opb, "value": val}
	rm.pressed.connect(func():
		entries.erase(entry)
		row.queue_free()
		if on_change.is_valid():
			on_change.call())
	row.add_child(rm)
	parent.add_child(row)
	entries.append(entry)
	return entry


# —— 通用分段场景切换（workshop_switch 的参数化版）——
# pairs=[[id, 按钮文字, 场景路径], ...]；current＝高亮禁点；guard 有效则切换前先过守卫
# （编辑器传脏守卫 _confirm_discard，防切场景静默丢未保存改动）。
static func scene_switch(host: Node, current: String, pairs: Array, guard := Callable()) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	for d in pairs:
		var id := str(d[0])
		var scene := str(d[2])
		var b := Button.new()
		b.text = str(d[1])
		b.focus_mode = Control.FOCUS_NONE
		if id == current:
			var hl := EditorTheme.sb(Color(0.24, 0.36, 0.52), Color(0.46, 0.62, 0.85))
			b.add_theme_stylebox_override("normal", hl)
			b.add_theme_stylebox_override("disabled", hl)
			b.disabled = true
		else:
			var go := func(): host.get_tree().change_scene_to_file(scene)
			b.pressed.connect(func():
				if guard.is_valid():
					guard.call(go)
				else:
					go.call())
		row.add_child(b)
	return row
