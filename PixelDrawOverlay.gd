extends Control
## 绘制浮层共享组件（编辑器优化提案 §16 抽取）：全屏压暗 + 面板〔标题 / 左工具列 / 中像素画布 / 右调色列 / 底部行〕。
## 地块工坊 TerrainArtWorkshop 与外观工坊 AppearanceWorkshop 共用一份——原两侧 ~150 行逐字重复已删；
## 漂移项取两侧较优实现：色块预设持久化（原只有外观侧）两侧都有、工具 tooltip/选区提示（原只有外观侧）两侧都有。
## 宿主差异全经 setup(opts) 注入；本组件**不写盘**——保存＝emit save_pressed，宿主读 canvas.get_image()
## （及 id_text()）自行落盘、成功后调 close()。色块预设仅在用户增删取色器预设时写 opts.swatches_path。
##
## opts 键（全部可缺省）：
##   title:String                       标题行文本
##   canvas_w / canvas_h:int            画布尺寸（外观侧方形传同值）
##   initial:Image                      初始内容（编辑现有变体 / §27 底稿复制）
##   onion:Texture2D                    洋葱皮/对照参考底图
##   paint_mask:Dictionary              {Vector2i:true} 落笔遮罩（空＝自由画；地块侧锁 hex 内）
##   brush:Color                        初始笔色
##   edit_alpha:bool                    取色器带 alpha（地块侧 true / 外观侧 false）
##   ramp_label:String  ramp_colors:Array   快捷色行（地块＝地形本色系 / 外观＝灰度）
##   save_text:String                   保存钮文本
##   id_label:String  id_value:String   底部 id 输入行（""＝无此行；外观侧＝部件 id）
##   extra_tools:Array                  [[text, tooltip, Callable], ...] 追加到工具列（如「载入所选部件」）
##   swatches_path:String               取色器色块预设持久化 json（""＝不持久化）
##   side_extra:Control  side_extra_label:String   注入右列底部（§28 mini 拼贴/棋子实时预览）

signal save_pressed   # 宿主：读 canvas.get_image() / id_text() 落盘，成功后调 close()
signal closed         # 关闭（取消 / 宿主调 close）——宿主清引用

const EditorUI := preload("res://EditorUI.gd")
const EditorTheme := preload("res://EditorTheme.gd")
const PixelDrawCanvas := preload("res://PixelDrawCanvas.gd")

const TOOL_KEYS := {"pencil": "B", "eraser": "E", "line": "L", "rect": "R", "rectf": "F", "fill": "G", "pick": "I", "select": "M", "wand": "W"}
const TOOLS := [["pencil", "✏ 铅笔"], ["eraser", "◧ 橡皮"], ["line", "／ 直线"], ["rect", "▭ 矩形"], ["rectf", "▬ 实心矩形"], ["fill", "🪣 填充"], ["pick", "💉 吸管"], ["select", "⬚ 选区"], ["wand", "✨ 魔棒"]]

var canvas               # PixelDrawCanvas（公开：宿主接 image_changed / 读 img）
var id_edit: LineEdit    # opts.id_label 提供时才建，否则 null
var _tool_btns := {}
var _brush_btns := {}
var _color_btn: ColorPicker
var _swatches_path := ""
var _edit_alpha := false

func setup(opts: Dictionary) -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.55)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP   # 挡住底层输入
	add_child(dim)
	var pad := MarginContainer.new()
	pad.set_anchors_preset(Control.PRESET_FULL_RECT)
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		pad.add_theme_constant_override(m, 18)
	add_child(pad)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", EditorTheme.sb(Color(0.12, 0.13, 0.16), Color(0.4, 0.44, 0.52)))
	pad.add_child(panel)
	var col := VBoxContainer.new(); col.add_theme_constant_override("separation", 8); panel.add_child(col)
	var title := Label.new()
	title.text = str(opts.get("title", ""))
	title.add_theme_font_size_override("font_size", 16)
	col.add_child(title)

	var mid := HBoxContainer.new(); mid.add_theme_constant_override("separation", 12)
	mid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(mid)

	# 中：画布（先建——工具/调色列的回调都指向它）
	canvas = PixelDrawCanvas.new()
	canvas.setup_wh(int(opts.get("canvas_w", 32)), int(opts.get("canvas_h", 32)), opts.get("initial"), opts.get("onion"))
	canvas.paint_mask = opts.get("paint_mask", {})
	canvas.brush = opts.get("brush", Color(0.5, 0.5, 0.5, 1.0))
	canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas.color_picked.connect(_sync_color)

	mid.add_child(_build_tools(opts))
	var wrap := PanelContainer.new()
	wrap.add_theme_stylebox_override("panel", EditorTheme.sb(Color(0.08, 0.09, 0.11), Color(0.3, 0.33, 0.4)))
	wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	wrap.add_child(canvas)
	mid.add_child(wrap)
	mid.add_child(_build_side(opts))
	col.add_child(_build_bottom(opts))
	_set_tool("pencil")
	_set_brush_px(1)

func close() -> void:
	closed.emit()
	queue_free()

func id_text() -> String:
	return id_edit.text if id_edit != null and is_instance_valid(id_edit) else ""

# —— 左：工具列 ——
func _build_tools(opts: Dictionary) -> Control:
	var tools := VBoxContainer.new()
	tools.add_theme_constant_override("separation", 4)
	tools.custom_minimum_size = Vector2(120, 0)
	for t in TOOLS:
		var tid := str(t[0])
		var key := str(TOOL_KEYS.get(tid, ""))
		var tb := Button.new()
		tb.text = "%s  (%s)" % [str(t[1]), key]
		tb.focus_mode = Control.FOCUS_NONE
		tb.tooltip_text = "快捷键 %s" % key
		tb.pressed.connect(func(): _set_tool(tid))
		_tool_btns[tid] = tb
		tools.add_child(tb)
	var mir := CheckBox.new(); mir.text = "水平镜像"
	mir.toggled.connect(func(on): canvas.mirror_x = on)
	tools.add_child(mir)
	# 笔刷粗细（§29）
	var brow := HBoxContainer.new(); brow.add_theme_constant_override("separation", 3)
	brow.add_child(_mini_label("笔刷"))
	for n in [1, 2, 3]:
		var nn: int = n
		var bb := Button.new(); bb.text = str(nn); bb.focus_mode = Control.FOCUS_NONE
		bb.custom_minimum_size = Vector2(28, 0)
		bb.tooltip_text = "笔刷粗细 %dpx（铅笔/橡皮/形状落点）" % nn
		bb.pressed.connect(func(): _set_brush_px(nn))
		_brush_btns[nn] = bb
		brow.add_child(bb)
	tools.add_child(brow)
	# 选区操作
	var selrow := HFlowContainer.new(); selrow.add_theme_constant_override("h_separation", 3)
	for sc in [["复制", func(): canvas.copy_sel()], ["剪切", func(): canvas.cut_sel()], ["粘贴", func(): canvas.paste()], ["删除", func(): canvas.delete_sel()]]:
		var sbn := Button.new(); sbn.text = str(sc[0]); sbn.focus_mode = Control.FOCUS_NONE
		var cbk: Callable = sc[1]
		sbn.pressed.connect(func(): cbk.call())
		selrow.add_child(sbn)
	tools.add_child(selrow)
	var selhint := Label.new(); selhint.text = "选区拖动=移动 · Ctrl+C/V/X · Del"
	selhint.add_theme_color_override("font_color", Color(0.55, 0.58, 0.64))
	selhint.add_theme_font_size_override("font_size", 10)
	selhint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tools.add_child(selhint)
	tools.add_child(_vsep())
	var zrow := HBoxContainer.new(); zrow.add_theme_constant_override("separation", 3)
	var zin := Button.new(); zin.text = "🔍＋"; zin.focus_mode = Control.FOCUS_NONE; zin.pressed.connect(func(): canvas.zoom_in())
	var zout := Button.new(); zout.text = "🔍－"; zout.focus_mode = Control.FOCUS_NONE; zout.pressed.connect(func(): canvas.zoom_out())
	var zfit := Button.new(); zfit.text = "适应"; zfit.focus_mode = Control.FOCUS_NONE; zfit.pressed.connect(func(): canvas.fit())
	zrow.add_child(zin); zrow.add_child(zout); zrow.add_child(zfit)
	tools.add_child(zrow)
	tools.add_child(_vsep())
	var urow := HBoxContainer.new(); urow.add_theme_constant_override("separation", 3)
	var undo := Button.new(); undo.text = "↶ 撤销"; undo.tooltip_text = "Ctrl+Z"; undo.pressed.connect(func(): canvas.undo())
	var redo := Button.new(); redo.text = "↷ 重做"; redo.tooltip_text = "Ctrl+Y / Ctrl+Shift+Z"; redo.pressed.connect(func(): canvas.redo())
	urow.add_child(undo); urow.add_child(redo)
	tools.add_child(urow)
	var clr := Button.new(); clr.text = "🗑 清空"; clr.pressed.connect(func(): canvas.clear_img())
	tools.add_child(clr)
	for et in opts.get("extra_tools", []):
		var eb := Button.new(); eb.text = str(et[0]); eb.tooltip_text = str(et[1])
		var ecb: Callable = et[2]
		eb.pressed.connect(func(): ecb.call())
		tools.add_child(eb)
	return tools

# —— 右：调色列（套 Scroll——取色器很高，保证 mini 预览/深段可达；mini 预览排在取色器前保常显）——
func _build_side(opts: Dictionary) -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(270, 0)
	var side := VBoxContainer.new(); side.add_theme_constant_override("separation", 6)
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(side)
	var rl := str(opts.get("ramp_label", ""))
	if rl != "":
		side.add_child(_mini_label(rl))
	var ramp := HFlowContainer.new()
	for cv in opts.get("ramp_colors", []):
		var c2: Color = cv
		var sw := Button.new(); sw.custom_minimum_size = Vector2(30, 26); sw.focus_mode = Control.FOCUS_NONE
		sw.add_theme_stylebox_override("normal", EditorTheme.sb(c2, Color(0.3, 0.33, 0.4)))
		sw.add_theme_stylebox_override("hover", EditorTheme.sb(c2, Color(0.9, 0.9, 0.9)))
		sw.pressed.connect(func(): _sync_color(c2))
		ramp.add_child(sw)
	side.add_child(ramp)
	var gridchk := CheckBox.new(); gridchk.text = "像素网格"; gridchk.button_pressed = true
	gridchk.toggled.connect(func(on): canvas.set_grid(on))
	side.add_child(gridchk)
	var extra = opts.get("side_extra")
	if extra is Control:
		var xl := str(opts.get("side_extra_label", ""))
		if xl != "":
			side.add_child(_mini_label(xl))
		side.add_child(extra)
	_edit_alpha = bool(opts.get("edit_alpha", false))
	var cp := ColorPicker.new(); cp.edit_alpha = _edit_alpha; cp.color = canvas.brush
	cp.custom_minimum_size = Vector2(240, 0)
	cp.color_changed.connect(func(c): canvas.brush = c)
	_color_btn = cp
	_swatches_path = str(opts.get("swatches_path", ""))
	if _swatches_path != "":
		_load_swatches(cp)   # 先载入再连信号，免载入触发重复保存
		cp.preset_added.connect(func(_c): _save_swatches(cp))
		cp.preset_removed.connect(func(_c): _save_swatches(cp))
	side.add_child(cp)
	return scroll

# —— 底：id + 取消/保存 ——
func _build_bottom(opts: Dictionary) -> Control:
	var bottom := HBoxContainer.new(); bottom.add_theme_constant_override("separation", 8)
	var idl := str(opts.get("id_label", ""))
	if idl != "":
		bottom.add_child(EditorUI.label(idl))
		id_edit = LineEdit.new()
		id_edit.text = str(opts.get("id_value", ""))
		id_edit.custom_minimum_size = Vector2(200, 0)
		bottom.add_child(id_edit)
	var sp := Control.new(); sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(sp)
	var cancel := Button.new(); cancel.text = "取消"; cancel.pressed.connect(close)
	var save := Button.new(); save.text = str(opts.get("save_text", "💾 保存"))
	save.add_theme_stylebox_override("normal", EditorTheme.sb(Color(0.24, 0.42, 0.24), Color(0.4, 0.7, 0.4)))
	save.pressed.connect(func(): save_pressed.emit())
	bottom.add_child(cancel); bottom.add_child(save)
	return bottom

# —— 工具态 / 快捷键 ——
func _set_tool(t: String) -> void:
	if canvas != null:
		canvas.set_tool(t)
	_highlight_tool(t)

func _highlight_tool(t: String) -> void:
	for tid in _tool_btns:
		var b: Button = _tool_btns[tid]
		if tid == t:
			b.add_theme_stylebox_override("normal", EditorTheme.sb(Color(0.24, 0.36, 0.52), Color(0.46, 0.62, 0.85)))
		else:
			b.remove_theme_stylebox_override("normal")

func _set_brush_px(n: int) -> void:
	if canvas != null:
		canvas.brush_px = n
	for k in _brush_btns:
		var b: Button = _brush_btns[k]
		if int(k) == n:
			b.add_theme_stylebox_override("normal", EditorTheme.sb(Color(0.24, 0.36, 0.52), Color(0.46, 0.62, 0.85)))
		else:
			b.remove_theme_stylebox_override("normal")

func _sync_color(c: Color) -> void:
	if canvas != null:
		canvas.brush = c
	if _color_btn != null and is_instance_valid(_color_btn):
		_color_btn.color = c

# 绘制态键盘快捷键（_unhandled_key_input 天然让 LineEdit/取色器 hex 输入优先）。
func _unhandled_key_input(event: InputEvent) -> void:
	if canvas == null or not is_instance_valid(canvas):
		return
	if not (event is InputEventKey) or not event.pressed:
		return
	var e := event as InputEventKey
	if e.ctrl_pressed or e.meta_pressed:
		match e.keycode:
			KEY_Z:
				if e.shift_pressed: canvas.redo()
				else: canvas.undo()
				accept_event()
			KEY_Y: canvas.redo(); accept_event()
			KEY_C: canvas.copy_sel(); accept_event()
			KEY_V: canvas.paste(); _highlight_tool("select"); accept_event()
			KEY_X: canvas.cut_sel(); accept_event()
		return
	var km := {KEY_B: "pencil", KEY_E: "eraser", KEY_L: "line", KEY_R: "rect", KEY_F: "rectf", KEY_G: "fill", KEY_I: "pick", KEY_M: "select", KEY_W: "wand"}
	if km.has(e.keycode):
		_set_tool(str(km[e.keycode])); accept_event()
		return
	match e.keycode:
		KEY_DELETE, KEY_BACKSPACE: canvas.delete_sel(); accept_event()
		KEY_BRACKETLEFT: canvas.zoom_out(); accept_event()
		KEY_BRACKETRIGHT: canvas.zoom_in(); accept_event()

# —— 取色器色块预设持久化（RGB(A) hex 列表；两宿主各给各的文件）——
func _load_swatches(cp: ColorPicker) -> void:
	if not FileAccess.file_exists(_swatches_path):
		return
	var f = FileAccess.open(_swatches_path, FileAccess.READ)
	if f == null:
		return
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(d) != TYPE_ARRAY:
		return
	for hex in d:
		var h := str(hex)
		if Color.html_is_valid(h):
			cp.add_preset(Color.html(h))

func _save_swatches(cp: ColorPicker) -> void:
	var arr := []
	for c in cp.get_presets():
		arr.append(c.to_html(_edit_alpha))
	var f = FileAccess.open(_swatches_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(arr, "  "))
		f.close()

# —— 小件 ——
func _vsep() -> Control:
	var c := Control.new(); c.custom_minimum_size = Vector2(0, 6); return c

func _mini_label(text: String) -> Label:
	var l := Label.new(); l.text = text; l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.62, 0.66, 0.72))
	return l
