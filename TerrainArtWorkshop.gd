extends Control
## 地块绘制工坊：给每种地形手绘像素 hex 瓦片（含差分变体），HexTileRender 渲染时优先于程序烘。
## 独立场景，与外观工坊平级（主菜单进）；结构仿 AppearanceWorkshop（左清单+右预览+overlay 绘制），
## 复用 EditorUI/EditorTheme/PixelDrawCanvas/HexTileRender/TextureCache/TerrainDB（数据/代码分离、DRY）。
## 只碰渲染器 + 新文件，不动 MapEditor/Sandbox/Overworld。瓦片存 res://icons/Tiles/<terrain>_<variant>/<n>.png，
## 注册进 terrains.json 的 art 数组（TerrainDB.set_art + save，单一写口）。

const EditorUI := preload("res://EditorUI.gd")
const EditorTheme := preload("res://EditorTheme.gd")
const TerrainDB := preload("res://TerrainDB.gd")
const TextureCache := preload("res://TextureCache.gd")
const TerrainSwatch := preload("res://TerrainSwatch.gd")
const TilePreview := preload("res://TilePreview.gd")
const PixelDrawCanvas := preload("res://PixelDrawCanvas.gd")
const HexTileRender := preload("res://HexTileRender.gd")

const TILE := 52   # 变体缩略图边长
const TOOL_KEYS := {"pencil": "B", "eraser": "E", "line": "L", "rect": "R", "rectf": "F", "fill": "G", "pick": "I", "select": "M", "wand": "W"}

var _root: VBoxContainer
var _variant_tiles := {}   # key -> { idx(int): Button }（idx=-1＝程序兜底缩略）
var _preview: TilePreview
var _msg: Label
var _sel_key := ""
var _sel_idx := 0
# 绘制态
var _overlay: Control
var _paint: PixelDrawCanvas
var _tool_btns := {}
var _color_btn
var _draw_entry := {}
var _draw_idx := -1

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = EditorTheme.build()
	add_child(EditorUI.background())
	TerrainDB.reload_data()
	_build_ui()

# 整页构建（存盘/增删后重建；选中 _sel_key/_sel_idx 在内存里存活）。
func _build_ui() -> void:
	if _root != null and is_instance_valid(_root):
		_root.queue_free()
	_variant_tiles.clear()
	_root = VBoxContainer.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_theme_constant_override("separation", 0)
	add_child(_root)
	_root.add_child(_titlebar())
	var split := HSplitContainer.new()
	split.split_offset = 380
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(_build_left())
	split.add_child(_build_right())
	_root.add_child(split)
	# 确保有合法选中（首次 / 重建后所选地形没了）
	if _sel_key == "" or _entry_by_key(_sel_key) == null:
		var pal := TerrainDB.palette()
		if not pal.is_empty():
			_sel_key = _entry_key(pal[0])
			_sel_idx = 0 if not TerrainDB.art_of(pal[0]).is_empty() else -1
	_refresh_selection()
	_update_preview()

func _rebuild() -> void:
	_build_ui()

func _titlebar() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", EditorTheme.sb(Color(0.13, 0.14, 0.17), Color(0.26, 0.29, 0.35)))
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 10)
	var title := Label.new()
	title.text = "  地块绘制工坊"
	title.add_theme_font_size_override("font_size", 22)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(title)
	bar.add_child(EditorUI.workshop_switch(self, "terrain"))   # 角色⇄地块 直达（共享组件）
	var back := Button.new()
	back.text = "返回主菜单"
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://StartMenu.tscn"))
	bar.add_child(back)
	panel.add_child(bar)
	return panel

# —— 左栏：地形清单（每种一行折叠 + 变体条）——
func _build_left() -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(360, 0)
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 5)
	scroll.add_child(vb)
	var pal := TerrainDB.palette()
	for i in pal.size():
		var entry: Dictionary = pal[i]
		var art := TerrainDB.art_of(entry)
		var title := "%s  ·  %d 变体" % [str(entry.get("label", entry.get("id", "?"))), art.size()]
		vb.add_child(EditorUI.make_foldable(title, _terrain_content(entry), i >= 4))
	return EditorUI.panelize(scroll)

func _terrain_content(entry: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	var grid := HFlowContainer.new()
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	var art := TerrainDB.art_of(entry)
	if art.is_empty():
		grid.add_child(_variant_tile(entry, -1))   # 程序兜底缩略（尚无手绘）
	else:
		for i in art.size():
			grid.add_child(_variant_tile(entry, i))
	grid.add_child(_add_variant_tile(entry))
	box.add_child(grid)
	return box

func _variant_tile(entry: Dictionary, idx: int) -> Button:
	var key := _entry_key(entry)
	var b := Button.new()
	b.custom_minimum_size = Vector2(TILE, TILE)
	b.focus_mode = Control.FOCUS_NONE
	var art := TerrainDB.art_of(entry)
	if idx >= 0 and idx < art.size():
		var tr := TextureRect.new()
		tr.texture = TextureCache.get_tex_file(str(art[idx]))
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		tr.set_anchors_preset(Control.PRESET_FULL_RECT)
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(tr)
		b.tooltip_text = "变体 %d（右键删除）" % idx
		b.gui_input.connect(func(e):
			if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_RIGHT and e.pressed:
				_delete_variant_confirm(entry, idx))
	else:
		# 程序烘兜底缩略（与地图/笔刷同一 HexTileRender）
		var sw := TerrainSwatch.new()
		sw.set_anchors_preset(Control.PRESET_FULL_RECT)
		sw.set_tile(str(entry.get("terrain", "")), str(entry.get("variant", "")))
		b.add_child(sw)
		b.tooltip_text = "程序生成（尚无手绘变体）"
	b.pressed.connect(func(): _pick(key, idx))
	if not _variant_tiles.has(key):
		_variant_tiles[key] = {}
	_variant_tiles[key][idx] = b
	return b

func _add_variant_tile(entry: Dictionary) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(TILE, TILE)
	b.focus_mode = Control.FOCUS_NONE
	b.text = "✎"
	b.tooltip_text = "画一张新变体（六边形对照对齐）"
	b.add_theme_stylebox_override("normal", EditorTheme.sb(Color(0.16, 0.22, 0.18), Color(0.35, 0.55, 0.4)))
	b.pressed.connect(func(): _open_draw(entry, -1))
	return b

func _refresh_selection() -> void:
	var gold := EditorTheme.sb(Color(0.20, 0.22, 0.27), Color(0.95, 0.78, 0.25))
	var norm := EditorTheme.sb(Color(0.16, 0.17, 0.21), Color(0.28, 0.31, 0.37))
	for key in _variant_tiles:
		for idx in _variant_tiles[key]:
			var b: Button = _variant_tiles[key][idx]
			var on: bool = (key == _sel_key and idx == _sel_idx)
			b.add_theme_stylebox_override("normal", gold if on else norm)
			b.add_theme_stylebox_override("hover", gold if on else norm)
			b.add_theme_stylebox_override("pressed", gold)

func _pick(key: String, idx: int) -> void:
	_sel_key = key
	_sel_idx = idx
	_refresh_selection()
	_update_preview()

# —— 右栏：对照预览 + 操作 ——
func _build_right() -> Control:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	var frame := PanelContainer.new()
	frame.add_theme_stylebox_override("panel", EditorTheme.sb(Color(0.10, 0.11, 0.13), Color(0.26, 0.29, 0.35)))
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var pv := VBoxContainer.new()
	var pt := Label.new()
	pt.text = "对照预览（这格 + 邻格拼贴）"
	pt.add_theme_font_size_override("font_size", 12)
	pv.add_child(pt)
	_preview = TilePreview.new()
	_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pv.add_child(_preview)
	frame.add_child(pv)
	vb.add_child(frame)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var edit := Button.new(); edit.text = "✎ 编辑所选变体"; edit.pressed.connect(_edit_selected)
	var imp := Button.new(); imp.text = "＋ 导入 PNG"; imp.pressed.connect(_import_variant)
	var del := Button.new(); del.text = "🗑 删除变体"; del.pressed.connect(_delete_selected)
	row.add_child(edit); row.add_child(imp); row.add_child(del)
	vb.add_child(row)
	_msg = Label.new()
	_msg.add_theme_font_size_override("font_size", 12)
	vb.add_child(_msg)
	return EditorUI.panelize(vb)

func _update_preview() -> void:
	if _preview == null or not is_instance_valid(_preview):
		return
	var entry = _entry_by_key(_sel_key)
	if entry == null:
		return
	_preview.set_tile(Color.html(str(entry.get("color", "#888888"))), Color.html(str(entry.get("accent", "#aaaaaa"))),
		str(entry.get("decor", "none")), TerrainDB.art_of(entry), _sel_idx)

# —— 绘制变体（overlay + 像素画布 + 六边形轮廓/遮罩对照）——
func _open_draw(entry, idx: int) -> void:
	_draw_entry = entry
	_draw_idx = idx
	var sz := HexTileRender.tile_px_size()
	var art := TerrainDB.art_of(entry)
	var initial: Image = null
	if idx >= 0 and idx < art.size():
		var tex := TextureCache.get_tex_file(str(art[idx]))
		if tex != null:
			initial = tex.get_image()
	var ref := _build_hex_ref(sz.x, sz.y)

	var ov := _make_overlay()
	var pad := MarginContainer.new()
	pad.set_anchors_preset(Control.PRESET_FULL_RECT)
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		pad.add_theme_constant_override(m, 18)
	ov.add_child(pad)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", EditorTheme.sb(Color(0.12, 0.13, 0.16), Color(0.4, 0.44, 0.52)))
	pad.add_child(panel)
	var col := VBoxContainer.new(); col.add_theme_constant_override("separation", 8); panel.add_child(col)
	var nlabel := ("变体 #%d" % idx) if idx >= 0 else ("新变体 #%d" % art.size())
	var title := Label.new()
	title.text = "绘制地块 · %s · %s　（银白线＝六边形轮廓 · 暗区＝界外不可画 · 滚轮缩放 · 中键平移 · 右键吸管）" % [str(entry.get("label", "?")), nlabel]
	title.add_theme_font_size_override("font_size", 16); col.add_child(title)

	var mid := HBoxContainer.new(); mid.add_theme_constant_override("separation", 12)
	mid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(mid)

	# 左：工具
	var tools := VBoxContainer.new(); tools.add_theme_constant_override("separation", 4); tools.custom_minimum_size = Vector2(120, 0)
	_tool_btns.clear()
	for t in [["pencil", "✏ 铅笔"], ["eraser", "◧ 橡皮"], ["line", "／ 直线"], ["rect", "▭ 矩形"], ["rectf", "▬ 实心矩形"], ["fill", "🪣 填充"], ["pick", "💉 吸管"], ["select", "⬚ 选区"], ["wand", "✨ 魔棒"]]:
		var tid := str(t[0])
		var key := str(TOOL_KEYS.get(tid, ""))
		var tb := Button.new(); tb.text = "%s  (%s)" % [str(t[1]), key]; tb.focus_mode = Control.FOCUS_NONE
		tb.pressed.connect(func(): _set_tool(tid))
		_tool_btns[tid] = tb
		tools.add_child(tb)
	var mir := CheckBox.new(); mir.text = "水平镜像"; mir.toggled.connect(func(on): _paint.mirror_x = on)
	tools.add_child(mir)
	var selrow := HFlowContainer.new(); selrow.add_theme_constant_override("h_separation", 3)
	for sc in [["复制", func(): _paint.copy_sel()], ["剪切", func(): _paint.cut_sel()], ["粘贴", func(): _paint.paste()], ["删除", func(): _paint.delete_sel()]]:
		var sbn := Button.new(); sbn.text = str(sc[0]); sbn.focus_mode = Control.FOCUS_NONE
		var cbk: Callable = sc[1]
		sbn.pressed.connect(func(): cbk.call())
		selrow.add_child(sbn)
	tools.add_child(selrow)
	tools.add_child(_vsep())
	var zrow := HBoxContainer.new(); zrow.add_theme_constant_override("separation", 3)
	var zin := Button.new(); zin.text = "🔍＋"; zin.focus_mode = Control.FOCUS_NONE; zin.pressed.connect(func(): _paint.zoom_in())
	var zout := Button.new(); zout.text = "🔍－"; zout.focus_mode = Control.FOCUS_NONE; zout.pressed.connect(func(): _paint.zoom_out())
	var zfit := Button.new(); zfit.text = "适应"; zfit.focus_mode = Control.FOCUS_NONE; zfit.pressed.connect(func(): _paint.fit())
	zrow.add_child(zin); zrow.add_child(zout); zrow.add_child(zfit)
	tools.add_child(zrow)
	tools.add_child(_vsep())
	var undo := Button.new(); undo.text = "↶ 撤销"; undo.pressed.connect(func(): _paint.undo())
	var clr := Button.new(); clr.text = "🗑 清空"; clr.pressed.connect(func(): _paint.clear_img())
	tools.add_child(undo); tools.add_child(clr)
	mid.add_child(tools)

	# 中：画布（24×21 六边形；paint_mask 锁在 hex 内）
	var canvas_wrap := PanelContainer.new()
	canvas_wrap.add_theme_stylebox_override("panel", EditorTheme.sb(Color(0.08, 0.09, 0.11), Color(0.3, 0.33, 0.4)))
	canvas_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_paint = PixelDrawCanvas.new()
	_paint.setup_wh(sz.x, sz.y, initial, ref)
	_paint.paint_mask = _build_hex_mask(sz.x, sz.y)
	_paint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_paint.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_paint.color_picked.connect(func(c): _sync_color(c))
	canvas_wrap.add_child(_paint)
	mid.add_child(canvas_wrap)

	# 右：颜色（地块＝成品彩色、无换色；给地形本色系快捷 + 取色器）
	var side := VBoxContainer.new(); side.add_theme_constant_override("separation", 6); side.custom_minimum_size = Vector2(250, 0)
	side.add_child(_mini_label("快捷色（地形本色系）"))
	var ramp := HFlowContainer.new()
	var base := Color.html(str(entry.get("color", "#888888")))
	var acc := Color.html(str(entry.get("accent", "#aaaaaa")))
	for cv: Color in [base.darkened(0.35), base.darkened(0.15), base, base.lightened(0.15), acc.darkened(0.15), acc, acc.lightened(0.2), Color(0, 0, 0, 1), Color(1, 1, 1, 1)]:
		var sw := Button.new(); sw.custom_minimum_size = Vector2(30, 26); sw.focus_mode = Control.FOCUS_NONE
		sw.add_theme_stylebox_override("normal", EditorTheme.sb(cv, Color(0.3, 0.33, 0.4)))
		sw.add_theme_stylebox_override("hover", EditorTheme.sb(cv, Color(0.9, 0.9, 0.9)))
		var c2 := cv
		sw.pressed.connect(func(): _sync_color(c2))
		ramp.add_child(sw)
	side.add_child(ramp)
	var gridchk := CheckBox.new(); gridchk.text = "像素网格"; gridchk.button_pressed = true
	gridchk.toggled.connect(func(on): _paint.set_grid(on))
	side.add_child(gridchk)
	var cp := ColorPicker.new(); cp.edit_alpha = true; cp.color = base; cp.custom_minimum_size = Vector2(240, 0)
	cp.color_changed.connect(func(c): _paint.brush = c)
	_color_btn = cp
	_paint.brush = base
	side.add_child(cp)
	mid.add_child(side)

	# 底：保存/取消
	var bottom := HBoxContainer.new(); bottom.add_theme_constant_override("separation", 8); col.add_child(bottom)
	bottom.add_child(_hspacer())
	var cancel := Button.new(); cancel.text = "取消"; cancel.pressed.connect(_close_overlay)
	var save := Button.new(); save.text = "💾 保存变体"; save.add_theme_stylebox_override("normal", EditorTheme.sb(Color(0.24, 0.42, 0.24), Color(0.4, 0.7, 0.4)))
	save.pressed.connect(_save_variant)
	bottom.add_child(cancel); bottom.add_child(save)

	_set_tool("pencil")

func _save_variant() -> void:
	if _paint == null or _draw_entry.is_empty():
		return
	var key := _entry_key(_draw_entry)
	var art := TerrainDB.art_of(_draw_entry)
	var dir := "res://icons/Tiles/" + key
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var new_art: Array = art.duplicate()
	var path: String
	if _draw_idx >= 0 and _draw_idx < art.size():
		path = str(art[_draw_idx])   # 覆盖：写回原文件、注册不变
	else:
		path = "%s/%d.png" % [dir, _next_free_index(dir)]   # 新变体：下一个空档号（避开已存文件，删后不撞号）
		new_art.append(path)
	var out_img := _paint.get_image()
	_hex_mask_image(out_img)   # 界外清透（belt-and-suspenders，即使 paint_mask 漏了）
	if out_img.save_png(path) != OK:
		_set_msg("保存失败（写盘）：%s" % path, false); return
	var tile := {"terrain": str(_draw_entry.get("terrain", "")), "variant": str(_draw_entry.get("variant", ""))}
	TerrainDB.set_art(tile, new_art)
	if not TerrainDB.save():
		TerrainDB.set_art(tile, art)   # 回滚为进入时的 art
		if _draw_idx < 0:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))   # 删掉新写的 N.png（重试复用同一空档号，不累积）
		_set_msg("保存失败（terrains.json 写盘）", false); return
	TextureCache.clear()   # 新 PNG 立即生效（否则命中旧 null/旧图缓存）
	_set_msg("已保存 %s → %s" % [str(_draw_entry.get("label", key)), path], true)
	_close_overlay()
	_rebuild()
	_pick(key, new_art.find(path))

# 变体文件下一个空档号（0.png,1.png… 首个不存在的；删后不与残留文件撞号）。
func _next_free_index(dir: String) -> int:
	var i := 0
	while FileAccess.file_exists("%s/%d.png" % [dir, i]):
		i += 1
	return i

# 把界外像素清透（保存兜底：与 paint_mask 同一 tile_hex_contains 判定）。
func _hex_mask_image(im: Image) -> void:
	for y in im.get_height():
		for x in im.get_width():
			if not HexTileRender.tile_hex_contains(x, y):
				im.set_pixel(x, y, Color(0, 0, 0, 0))

# 画布对照参考图（onion）：界外暗块 + hex 内缘银白轮廓（供对齐；被绘制像素盖住即已画到位）。
func _build_hex_ref(w: int, h: int) -> ImageTexture:
	var im := Image.create(w, h, false, Image.FORMAT_RGBA8)
	im.fill(Color(0, 0, 0, 0))
	for y in h:
		for x in w:
			if not HexTileRender.tile_hex_contains(x, y):
				im.set_pixel(x, y, Color(0, 0, 0, 1))          # 界外禁区（onion 0.30α 后淡显）
	for y in h:
		for x in w:
			if not HexTileRender.tile_hex_contains(x, y):
				continue
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				if not HexTileRender.tile_hex_contains(x + d.x, y + d.y):
					im.set_pixel(x, y, Color(1, 1, 1, 1))       # hex 内缘＝轮廓
					break
	return ImageTexture.create_from_image(im)

# 落笔遮罩：hex 内的像素集合（PixelDrawCanvas.paint_mask）。
func _build_hex_mask(w: int, h: int) -> Dictionary:
	var m := {}
	for y in h:
		for x in w:
			if HexTileRender.tile_hex_contains(x, y):
				m[Vector2i(x, y)] = true
	return m

# —— 绘制态工具/键/色/overlay（仿 AppearanceWorkshop）——
func _set_tool(t: String) -> void:
	if _paint != null:
		_paint.set_tool(t)
	_highlight_tool(t)

func _highlight_tool(t: String) -> void:
	for tid in _tool_btns:
		var b: Button = _tool_btns[tid]
		if tid == t:
			b.add_theme_stylebox_override("normal", EditorTheme.sb(Color(0.24, 0.36, 0.52), Color(0.46, 0.62, 0.85)))
		else:
			b.remove_theme_stylebox_override("normal")

func _unhandled_key_input(event: InputEvent) -> void:
	if _overlay == null or _paint == null or not is_instance_valid(_paint):
		return
	if not (event is InputEventKey) or not event.pressed:
		return
	var e := event as InputEventKey
	if e.ctrl_pressed or e.meta_pressed:
		match e.keycode:
			KEY_Z: _paint.undo(); accept_event()
			KEY_C: _paint.copy_sel(); accept_event()
			KEY_V: _paint.paste(); _highlight_tool("select"); accept_event()
			KEY_X: _paint.cut_sel(); accept_event()
		return
	var km := {KEY_B: "pencil", KEY_E: "eraser", KEY_L: "line", KEY_R: "rect", KEY_F: "rectf", KEY_G: "fill", KEY_I: "pick", KEY_M: "select", KEY_W: "wand"}
	if km.has(e.keycode):
		_set_tool(str(km[e.keycode])); accept_event()
		return
	match e.keycode:
		KEY_DELETE, KEY_BACKSPACE: _paint.delete_sel(); accept_event()
		KEY_BRACKETLEFT: _paint.zoom_out(); accept_event()
		KEY_BRACKETRIGHT: _paint.zoom_in(); accept_event()

func _sync_color(c: Color) -> void:
	if _paint != null:
		_paint.brush = c
	if _color_btn != null and is_instance_valid(_color_btn):
		_color_btn.color = c

func _make_overlay() -> Control:
	_close_overlay()
	var ov := Control.new()
	ov.set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.55)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	ov.add_child(dim)
	add_child(ov)
	_overlay = ov
	return ov

func _close_overlay() -> void:
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.queue_free()
	_overlay = null
	_paint = null

func _vsep() -> Control:
	var c := Control.new(); c.custom_minimum_size = Vector2(0, 6); return c

func _hspacer() -> Control:
	var c := Control.new(); c.size_flags_horizontal = Control.SIZE_EXPAND_FILL; return c

func _mini_label(text: String) -> Label:
	var l := Label.new(); l.text = text; l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.62, 0.66, 0.72))
	return l

func _edit_selected() -> void:
	var e = _entry_by_key(_sel_key)
	if e != null:
		_open_draw(e, _sel_idx)

func _import_variant() -> void:
	var e = _entry_by_key(_sel_key)
	if e == null:
		_set_msg("先选一个地形", false); return
	var dlg := EditorUI.make_file_dialog(FileDialog.FILE_MODE_OPEN_FILE, FileDialog.ACCESS_RESOURCES, [["*.png", "PNG 图片"]], false)
	add_child(dlg)
	dlg.file_selected.connect(func(p): _do_import(e, str(p)); dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered_ratio(0.7)

func _do_import(entry, src_path: String) -> void:
	var im := Image.new()
	if im.load(src_path) != OK:
		_set_msg("读取失败：%s" % src_path, false); return
	if im.get_format() != Image.FORMAT_RGBA8:
		im.convert(Image.FORMAT_RGBA8)
	var sz := HexTileRender.tile_px_size()
	if im.get_width() != sz.x or im.get_height() != sz.y:
		im.resize(sz.x, sz.y, Image.INTERPOLATE_NEAREST)   # 尺寸不符→缩到瓦片尺寸（宽容）
	_hex_mask_image(im)
	var key := _entry_key(entry)
	var dir := "res://icons/Tiles/" + key
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var path := "%s/%d.png" % [dir, _next_free_index(dir)]
	if im.save_png(path) != OK:
		_set_msg("写盘失败：%s" % path, false); return
	var old_art: Array = TerrainDB.art_of(entry).duplicate()
	var new_art: Array = old_art.duplicate()
	new_art.append(path)
	var tile := {"terrain": str(entry.get("terrain", "")), "variant": str(entry.get("variant", ""))}
	TerrainDB.set_art(tile, new_art)
	if not TerrainDB.save():
		TerrainDB.set_art(tile, old_art)   # 回滚内存
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))   # 删掉刚写的孤儿 PNG
		_set_msg("保存失败（terrains.json 写盘）：%s" % path, false); return
	TextureCache.clear()
	_set_msg("已导入变体 → %s" % path, true)
	_rebuild()
	_pick(key, new_art.find(path))

func _delete_selected() -> void:
	var e = _entry_by_key(_sel_key)
	if e == null or _sel_idx < 0:
		_set_msg("没有可删的手绘变体（程序兜底不可删）", false); return
	_delete_variant_confirm(e, _sel_idx)

func _delete_variant_confirm(entry, idx: int) -> void:
	if idx < 0:
		return
	var key := _entry_key(entry)
	EditorUI.confirm(self, "删除 %s 变体 #%d？（同时删 PNG 文件）" % [str(entry.get("label", key)), idx], "删除",
		func(): _do_delete_variant(entry, idx))

func _do_delete_variant(entry, idx: int) -> void:
	var art := TerrainDB.art_of(entry)
	if idx < 0 or idx >= art.size():
		return
	var path := str(art[idx])
	var new_art: Array = art.duplicate()
	new_art.remove_at(idx)
	var tile := {"terrain": str(entry.get("terrain", "")), "variant": str(entry.get("variant", ""))}
	TerrainDB.set_art(tile, new_art)
	if not TerrainDB.save():
		TerrainDB.set_art(tile, art)   # 回滚：注册表与磁盘一致
		_set_msg("保存失败（terrains.json 写盘）", false); return
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))   # 仅落盘成功后才删 PNG
	TextureCache.clear()
	# 选中回退：仅当删的是【所选地形】才动 _sel_idx，且按其自身位置调（不按被删 idx）
	if _entry_key(entry) == _sel_key:
		if new_art.is_empty():
			_sel_idx = -1
		elif idx < _sel_idx:
			_sel_idx -= 1                              # 删的在所选之前 → 下移一位仍指同一张
		elif idx == _sel_idx:
			_sel_idx = mini(idx, new_art.size() - 1)  # 删的正是所选 → 就地夹取
		# idx > _sel_idx：所选不受影响
	_set_msg("已删除变体 #%d" % idx, true)
	_rebuild()

# —— 工具 ——
func _entry_key(entry) -> String:
	return "%s_%s" % [str(entry.get("terrain", "")), str(entry.get("variant", ""))]

func _entry_by_key(key: String):
	for e in TerrainDB.palette():
		if _entry_key(e) == key:
			return e
	return null

func _set_msg(text: String, ok: bool) -> void:
	if _msg != null and is_instance_valid(_msg):
		_msg.text = text
		_msg.add_theme_color_override("font_color", Color(0.6, 0.85, 0.5) if ok else Color(0.9, 0.62, 0.5))
