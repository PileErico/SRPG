extends Control
## 外观工坊：开发者用的「分层换装 + 亮度换色 + 内置像素绘制」角色合成器（独立模块，主菜单进）。
## 左＝逐槽位部件缩略图选择（含 ∅无 / ＋绘制）+ 每槽调色板 + ＋新增部件总类；右＝实时大预览 + 导出/导入。
## 内置绘制：就着角色本体（洋葱皮）在 32×32 画布上画部件 → 存盘即成该槽部件（锚点天然对齐，免外部 PNG 对位）。
## 产物＝导出的单张 PNG（其他模块经 Unit.portrait/icon 消费、不碰渲染管线）。复用 EditorUI/EditorTheme/TextureCache/AppearanceDB/PaperDoll。

const EditorUI := preload("res://EditorUI.gd")
const EditorTheme := preload("res://EditorTheme.gd")
const AppearanceDB := preload("res://AppearanceDB.gd")
const PaperDoll := preload("res://PaperDoll.gd")
const TextureCache := preload("res://TextureCache.gd")
const PixelDrawCanvas := preload("res://PixelDrawCanvas.gd")
const UnitFactory := preload("res://UnitFactory.gd")
const PiecePreview := preload("res://PiecePreview.gd")

# 棋子放置微调（存进 look，供战场 UnitPiece 用）：scale 0=自动
const FAC_COLORS := {"player": Color(0.36, 0.62, 0.32), "enemy": Color(0.72, 0.28, 0.26), "ally": Color(0.30, 0.55, 0.70), "neutral": Color(0.55, 0.55, 0.58)}

const PREVIEW_SCALE := 8
const TILE := 52
const TOOL_KEYS := {"pencil": "B", "eraser": "E", "line": "L", "rect": "R", "rectf": "F", "fill": "G", "pick": "I", "select": "M", "wand": "W"}

var _recipe := {"parts": {}, "palettes": {}}
var _root: VBoxContainer
var _overlay: Control
var _preview: TextureRect
var _msg: Label
var _fname: LineEdit
var _scale_opt: OptionButton
var _import_slot: OptionButton
var _part_tiles := {}   # slot_id -> { part_id_or_"": Button }
var _pal_tiles := {}    # slot_id -> { pal_id: Button }
var _piece := {"scale": 2.0, "dx": 0.0, "dy": 24.0}   # 棋子放置微调（scale＝画布像素→世界像素）默认对齐值
var _piece_preview: PiecePreview
var _piece_fac := Color(0.36, 0.62, 0.32)
var _piece_sliders := {}
# 绘制态
var _paint: PixelDrawCanvas
var _draw_slot := ""
var _draw_id_edit: LineEdit
var _tool_btns := {}

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = EditorTheme.build()
	add_child(EditorUI.background())
	AppearanceDB.reload_data()
	_init_recipe()
	_build_ui()

# 整页构建（新增槽/导入/绘制存盘后重建；保留 _recipe）。
func _build_ui() -> void:
	if _root != null and is_instance_valid(_root):
		_root.queue_free()
	_part_tiles.clear()
	_pal_tiles.clear()
	_root = VBoxContainer.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_theme_constant_override("separation", 0)
	add_child(_root)
	_root.add_child(_titlebar())
	var split := HSplitContainer.new()
	split.split_offset = 380
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_root.add_child(split)
	split.add_child(_build_left())
	split.add_child(_build_right())
	_refresh_selection()
	_update_preview()

func _rebuild() -> void:
	_build_ui()

# —— 顶栏 ——
func _titlebar() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", EditorTheme.sb(Color(0.13, 0.14, 0.17), Color(0.26, 0.29, 0.35)))
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 10)
	var title := Label.new()
	title.text = "  外观工坊"
	title.add_theme_font_size_override("font_size", 22)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(title)
	var back := Button.new()
	back.text = "返回主菜单"
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://StartMenu.tscn"))
	bar.add_child(back)
	panel.add_child(bar)
	return panel

# —— 左栏 ——
func _build_left() -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(370, 0)
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 6)
	scroll.add_child(vb)

	var slots := AppearanceDB.slots()
	for i in slots.size():
		var slot: Dictionary = slots[i]
		var collapsed := i >= 3
		var content := _slot_content(slot)
		var title := "%s  ·  %d 款" % [str(slot.get("cn", slot.get("id"))), AppearanceDB.parts_in_slot(str(slot.get("id"))).size()]
		vb.add_child(EditorUI.make_foldable(title, content, collapsed))

	# 新增部件总类 / 清理失效部件
	var add_slot := Button.new()
	add_slot.text = "＋ 新增部件总类"
	add_slot.pressed.connect(_add_slot_dialog)
	vb.add_child(add_slot)
	var prune := Button.new()
	prune.text = "🧹 清理失效部件（PNG 已删）"
	prune.tooltip_text = "移除所有指向不存在文件的部件条目"
	prune.pressed.connect(_prune_missing)
	vb.add_child(prune)

	return EditorUI.panelize(scroll)

func _slot_content(slot: Dictionary) -> Control:
	var slot_id := str(slot.get("id", ""))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)

	# 层序控制行：⬆/⬇ 调整该总类的叠放层级（z）＋ 删除
	var ctl := HBoxContainer.new()
	ctl.add_theme_constant_override("separation", 4)
	var zl := Label.new(); zl.text = "层序 z=%d" % int(slot.get("z", 0)); zl.add_theme_color_override("font_color", Color(0.6, 0.64, 0.7)); zl.add_theme_font_size_override("font_size", 11)
	ctl.add_child(zl)
	var up := Button.new(); up.text = "⬆ 上移"; up.focus_mode = Control.FOCUS_NONE; up.tooltip_text = "更靠前（盖住别的）"; up.pressed.connect(func(): _move_slot(slot_id, 1))
	var dn := Button.new(); dn.text = "⬇ 下移"; dn.focus_mode = Control.FOCUS_NONE; dn.tooltip_text = "更靠后（被别的盖住）"; dn.pressed.connect(func(): _move_slot(slot_id, -1))
	ctl.add_child(up); ctl.add_child(dn)
	ctl.add_child(_hspacer())
	var del := Button.new(); del.text = "✕"; del.focus_mode = Control.FOCUS_NONE; del.tooltip_text = "删除该部件总类（连同其部件）"
	del.pressed.connect(func(): _delete_slot_confirm(slot_id, str(slot.get("cn", slot_id))))
	ctl.add_child(del)
	box.add_child(ctl)

	var grid := HFlowContainer.new()
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	_part_tiles[slot_id] = {}
	grid.add_child(_part_tile(slot_id, "", null))          # ∅ 无
	for part in AppearanceDB.parts_in_slot(slot_id):
		grid.add_child(_part_tile(slot_id, str(part.get("id", "")), part))
	grid.add_child(_draw_tile(slot_id))                    # ＋ 绘制
	box.add_child(grid)

	if AppearanceDB.parts_in_slot(slot_id).any(func(p): return bool(p.get("recolorable", false))):
		var pl := Label.new()
		pl.text = "调色板"
		pl.add_theme_color_override("font_color", Color(0.6, 0.64, 0.7))
		pl.add_theme_font_size_override("font_size", 11)
		box.add_child(pl)
		var pal_grid := HFlowContainer.new()
		pal_grid.add_theme_constant_override("h_separation", 3)
		pal_grid.add_theme_constant_override("v_separation", 3)
		_pal_tiles[slot_id] = {}
		pal_grid.add_child(_palette_swatch_none(slot_id))   # 无＝不换色（部件原色）
		for pal in AppearanceDB.palettes():
			pal_grid.add_child(_palette_swatch(slot_id, pal))
		box.add_child(pal_grid)
	return box

func _part_tile(slot_id: String, part_id: String, part) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(TILE, TILE)
	b.focus_mode = Control.FOCUS_NONE
	b.tooltip_text = (str(part.get("cn", part_id)) + "（右键删除）") if part != null else "无（移除该部件）"
	if part != null:
		var tr := TextureRect.new()
		tr.texture = _part_preview_texture(part)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		tr.set_anchors_preset(Control.PRESET_FULL_RECT)
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(tr)
		# 缺失文件标记
		if not FileAccess.file_exists(str(part.get("path", ""))):
			var warn := Label.new(); warn.text = "⚠"; warn.tooltip_text = "文件缺失"
			warn.add_theme_color_override("font_color", Color(1, 0.7, 0.2))
			warn.mouse_filter = Control.MOUSE_FILTER_IGNORE
			b.add_child(warn)
		var pid := str(part.get("id", "")); var cn := str(part.get("cn", pid)); var ppath := str(part.get("path", ""))
		b.gui_input.connect(func(e):
			if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_RIGHT and e.pressed:
				_delete_part_dialog(slot_id, pid, cn, ppath))
	else:
		b.text = "∅"
	b.pressed.connect(func(): _pick_part(slot_id, part_id))
	_part_tiles[slot_id][part_id] = b
	return b

func _draw_tile(slot_id: String) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(TILE, TILE)
	b.focus_mode = Control.FOCUS_NONE
	b.text = "✎"
	b.tooltip_text = "在此绘制新部件（就着角色本体画）"
	b.add_theme_stylebox_override("normal", EditorTheme.sb(Color(0.16, 0.22, 0.18), Color(0.35, 0.55, 0.4)))
	b.pressed.connect(func(): _open_draw(slot_id))
	return b

func _palette_swatch_none(slot_id: String) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(30, 20)
	b.focus_mode = Control.FOCUS_NONE
	b.text = "无"
	b.add_theme_font_size_override("font_size", 10)
	b.tooltip_text = "不换色（用部件原色）"
	b.pressed.connect(func(): _pick_palette(slot_id, ""))
	_pal_tiles[slot_id][""] = b
	return b

func _palette_swatch(slot_id: String, pal: Dictionary) -> Button:
	var pal_id := str(pal.get("id", ""))
	var b := Button.new()
	b.custom_minimum_size = Vector2(30, 20)
	b.focus_mode = Control.FOCUS_NONE
	b.tooltip_text = str(pal.get("cn", pal_id))
	var tr := TextureRect.new()
	tr.texture = _swatch_texture(pal)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	tr.offset_left = 3; tr.offset_top = 3; tr.offset_right = -3; tr.offset_bottom = -3
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(tr)
	b.pressed.connect(func(): _pick_palette(slot_id, pal_id))
	_pal_tiles[slot_id][pal_id] = b
	return b

# —— 右栏 ——
func _build_right() -> Control:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# 平铺预览（大、填满）
	var frame := PanelContainer.new()
	frame.add_theme_stylebox_override("panel", EditorTheme.sb(Color(0.10, 0.11, 0.13), Color(0.26, 0.29, 0.35)))
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var fvb := VBoxContainer.new(); fvb.add_theme_constant_override("separation", 4); frame.add_child(fvb)
	fvb.add_child(_mini_label("平铺预览"))
	var checker := TextureRect.new()
	checker.texture = _checker_texture()
	checker.stretch_mode = TextureRect.STRETCH_TILE
	checker.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	checker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	checker.size_flags_vertical = Control.SIZE_EXPAND_FILL
	checker.custom_minimum_size = Vector2(220, 220)
	fvb.add_child(checker)
	_preview = TextureRect.new()
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_preview.set_anchors_preset(Control.PRESET_FULL_RECT)
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	checker.add_child(_preview)

	# 平铺预览 + 棋子预览 并排，撑满上方大区域
	var prow := HBoxContainer.new(); prow.add_theme_constant_override("separation", 12)
	prow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	prow.size_flags_vertical = Control.SIZE_EXPAND_FILL
	prow.add_child(frame)
	prow.add_child(_build_piece_section())
	vb.add_child(prow)

	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 8)
	var rnd := Button.new(); rnd.text = "🎲 随机"; rnd.pressed.connect(_randomize)
	var rst := Button.new(); rst.text = "↺ 重置"; rst.pressed.connect(func(): _init_recipe(); _refresh_selection(); _update_preview())
	row1.add_child(rnd); row1.add_child(rst)
	row1.add_child(_hspacer())
	var imp := Button.new(); imp.text = "＋ 导入部件 PNG"; imp.pressed.connect(_on_import)
	_import_slot = OptionButton.new()
	for slot in AppearanceDB.slots():
		_import_slot.add_item(str(slot.get("cn", slot.get("id"))))
		_import_slot.set_item_metadata(_import_slot.item_count - 1, str(slot.get("id")))
	row1.add_child(imp); row1.add_child(_import_slot)
	vb.add_child(row1)

	# 应用到单位 / 从单位载入（打通「外观→单位」闭环，走 UnitFactory 公开口）
	var rowu := HBoxContainer.new()
	rowu.add_theme_constant_override("separation", 8)
	var apply := Button.new(); apply.text = "🎭 应用到单位…"; apply.tooltip_text = "把当前外观导出并设为某单位原型的立绘/棋子图标"
	apply.add_theme_stylebox_override("normal", EditorTheme.sb(Color(0.24, 0.36, 0.52), Color(0.46, 0.62, 0.85)))
	apply.pressed.connect(_on_apply_to_unit)
	var loadu := Button.new(); loadu.text = "📥 从单位载入外观"; loadu.tooltip_text = "载入某单位已保存的外观配方以继续编辑"
	loadu.pressed.connect(_on_load_from_unit)
	rowu.add_child(apply); rowu.add_child(loadu); rowu.add_child(_hspacer())
	vb.add_child(rowu)

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 8)
	row2.add_child(EditorUI.label("文件名"))
	_fname = LineEdit.new(); _fname.text = "character"; _fname.custom_minimum_size = Vector2(160, 0)
	row2.add_child(_fname)
	row2.add_child(EditorUI.label("倍数"))
	_scale_opt = OptionButton.new()
	for s in [1, 2, 4, 8]:
		_scale_opt.add_item("%d×" % s); _scale_opt.set_item_metadata(_scale_opt.item_count - 1, s)
	row2.add_child(_scale_opt)
	row2.add_child(_hspacer())
	var exp := Button.new(); exp.text = "⬇ 导出 PNG"; exp.pressed.connect(_on_export)
	exp.add_theme_stylebox_override("normal", EditorTheme.sb(Color(0.24, 0.42, 0.24), Color(0.4, 0.7, 0.4)))
	row2.add_child(exp)
	vb.add_child(row2)

	_msg = Label.new()
	_msg.add_theme_color_override("font_color", Color(0.6, 0.7, 0.6))
	vb.add_child(_msg)
	return EditorUI.panelize(vb)

func _hspacer() -> Control:
	var c := Control.new(); c.size_flags_horizontal = Control.SIZE_EXPAND_FILL; return c

# —— 棋子效果预览 + 微调 ——
func _build_piece_section() -> Control:
	var frame := PanelContainer.new()
	frame.add_theme_stylebox_override("panel", EditorTheme.sb(Color(0.10, 0.11, 0.13), Color(0.26, 0.29, 0.35)))
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var vb := VBoxContainer.new(); vb.add_theme_constant_override("separation", 4); frame.add_child(vb)
	var head := HBoxContainer.new()
	var t := Label.new(); t.text = "棋子效果（脚下阵营环）"; t.add_theme_font_size_override("font_size", 12); t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)
	var facopt := OptionButton.new()
	for k in [["player", "玩家"], ["enemy", "敌方"], ["ally", "友军"], ["neutral", "中立"]]:
		facopt.add_item(str(k[1])); facopt.set_item_metadata(facopt.item_count - 1, str(k[0]))
	facopt.item_selected.connect(func(i): _piece_fac = FAC_COLORS[str(facopt.get_item_metadata(i))]; _update_piece_preview())
	head.add_child(facopt)
	vb.add_child(head)
	_piece_preview = PiecePreview.new()
	_piece_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(_piece_preview)
	_piece_sliders = {}
	_piece_sliders["scale"] = _slider(vb, "缩放", 0.3, 5.0, 0.05, float(_piece["scale"]), func(v): _piece["scale"] = v; _update_piece_preview())
	_piece_sliders["dx"] = _slider(vb, "水平", -32, 32, 1, float(_piece["dx"]), func(v): _piece["dx"] = v; _update_piece_preview())
	_piece_sliders["dy"] = _slider(vb, "垂直", -24, 24, 1, float(_piece["dy"]), func(v): _piece["dy"] = v; _update_piece_preview())
	var rst := Button.new(); rst.text = "↺ 复位微调"; rst.focus_mode = Control.FOCUS_NONE
	rst.pressed.connect(func(): _piece = _default_piece(); _sync_piece_sliders(); _update_piece_preview())
	vb.add_child(rst)
	return frame

func _default_piece() -> Dictionary:
	return {"scale": 2.0, "dx": 0.0, "dy": 24.0}

func _mini_label(text: String) -> Label:
	var l := Label.new(); l.text = text; l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.62, 0.66, 0.72))
	return l

func _slider(parent: Node, label: String, mn: float, mx: float, step: float, val: float, on_change: Callable) -> HSlider:
	var row := HBoxContainer.new(); row.add_theme_constant_override("separation", 6)
	var l := Label.new(); l.text = label; l.custom_minimum_size = Vector2(36, 0); l.add_theme_font_size_override("font_size", 11)
	row.add_child(l)
	var s := HSlider.new(); s.min_value = mn; s.max_value = mx; s.step = step; s.value = val
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL; s.custom_minimum_size = Vector2(110, 0)
	var vl := Label.new(); vl.custom_minimum_size = Vector2(40, 0); vl.add_theme_font_size_override("font_size", 11)
	vl.text = ("%.2f" % val) if step < 1.0 else str(int(val))
	s.value_changed.connect(func(v):
		vl.text = ("%.2f" % v) if step < 1.0 else str(int(v))
		on_change.call(v))
	row.add_child(s); row.add_child(vl)
	parent.add_child(row)
	return s

func _sync_piece_sliders() -> void:
	for k in _piece_sliders:
		if is_instance_valid(_piece_sliders[k]):
			_piece_sliders[k].value = float(_piece[k])

func _update_piece_preview() -> void:
	if _piece_preview != null and is_instance_valid(_piece_preview):
		_piece_preview.set_piece(PaperDoll.bake(_recipe), float(_piece["scale"]), float(_piece["dx"]), float(_piece["dy"]), _piece_fac)

# —— recipe 逻辑 ——
func _init_recipe() -> void:
	_recipe = {"parts": {}, "palettes": {}}
	for slot in AppearanceDB.slots():
		var slot_id := str(slot.get("id", ""))
		if slot_id in ["helmet", "weapon"]:
			continue
		var parts := AppearanceDB.parts_in_slot(slot_id)
		if parts.is_empty():
			continue
		var p: Dictionary = parts[0]
		_recipe["parts"][slot_id] = str(p.get("id"))
		_recipe["palettes"][slot_id] = ""   # 默认不换色（部件原色）

func _pick_part(slot_id: String, part_id: String) -> void:
	if part_id == "":
		_recipe["parts"].erase(slot_id)
	else:
		_recipe["parts"][slot_id] = part_id
		if not _recipe["palettes"].has(slot_id):
			_recipe["palettes"][slot_id] = ""   # 默认不换色（部件原色）
	_refresh_selection()
	_update_preview()

func _pick_palette(slot_id: String, pal_id: String) -> void:
	_recipe["palettes"][slot_id] = pal_id
	_refresh_selection()
	_update_preview()

func _refresh_selection() -> void:
	var gold := EditorTheme.sb(Color(0.20, 0.22, 0.27), Color(0.95, 0.78, 0.25))
	var norm := EditorTheme.sb(Color(0.16, 0.17, 0.21), Color(0.28, 0.31, 0.37))
	for slot_id in _part_tiles:
		var sel := str(_recipe["parts"].get(slot_id, ""))
		for pid in _part_tiles[slot_id]:
			var b: Button = _part_tiles[slot_id][pid]
			b.add_theme_stylebox_override("normal", gold if pid == sel else norm)
			b.add_theme_stylebox_override("hover", gold if pid == sel else norm)
			b.add_theme_stylebox_override("pressed", gold)
	for slot_id in _pal_tiles:
		var sel := str(_recipe["palettes"].get(slot_id, ""))
		for pid in _pal_tiles[slot_id]:
			var b: Button = _pal_tiles[slot_id][pid]
			b.add_theme_stylebox_override("normal", gold if pid == sel else norm)
			b.add_theme_stylebox_override("hover", gold if pid == sel else norm)
			b.add_theme_stylebox_override("pressed", gold)

func _update_preview() -> void:
	if _preview != null:
		_preview.texture = PaperDoll.bake(_recipe)
	_update_piece_preview()

func _randomize() -> void:
	for slot in AppearanceDB.slots():
		var slot_id := str(slot.get("id", ""))
		var parts := AppearanceDB.parts_in_slot(slot_id)
		if parts.is_empty():
			continue
		if slot_id in ["helmet", "weapon"] and randf() < 0.4:
			_recipe["parts"].erase(slot_id)
		else:
			_recipe["parts"][slot_id] = str(parts[randi() % parts.size()].get("id"))
		var pals := AppearanceDB.palettes()
		if not pals.is_empty() and _recipe["parts"].has(slot_id):
			_recipe["palettes"][slot_id] = str(pals[randi() % pals.size()].get("id"))
	_refresh_selection()
	_update_preview()

# —— 导出 / 导入 ——
func _on_export() -> void:
	var dlg := EditorUI.make_file_dialog(FileDialog.FILE_MODE_SAVE_FILE, FileDialog.ACCESS_RESOURCES, [["*.png", "PNG 图片"]], false)
	dlg.current_dir = "res://icons/Characters"
	dlg.current_file = str(_fname.text) + ".png"
	add_child(dlg)
	dlg.file_selected.connect(func(path: String):
		var scale := int(_scale_opt.get_item_metadata(_scale_opt.selected))
		if PaperDoll.export_png(_recipe, path, scale):
			_set_msg("已导出：%s（%d×）" % [path, scale], true)
		else:
			_set_msg("导出失败（路径不可写？）：%s" % path, false)
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered_ratio(0.7)

func _on_import() -> void:
	var dlg := EditorUI.make_file_dialog(FileDialog.FILE_MODE_OPEN_FILE, FileDialog.ACCESS_RESOURCES, [["*.png", "PNG 图片"]], false)
	dlg.current_dir = "res://icons/Parts"
	add_child(dlg)
	dlg.file_selected.connect(func(path: String):
		var slot_id := str(_import_slot.get_item_metadata(_import_slot.selected))
		var base := path.get_file().get_basename()
		var pid := _sanitize_id((slot_id + "_" + base).to_lower())
		var part := {"id": pid, "slot": slot_id, "cn": base, "path": path, "tags": [], "recolorable": true}
		var existing := AppearanceDB.parts_in_slot(slot_id)
		if not existing.is_empty() and existing[0].has("default_palette"):
			part["default_palette"] = existing[0]["default_palette"]
		if AppearanceDB.save_part(part):
			TextureCache.clear(); PaperDoll.clear_cache()
			_set_msg("已导入部件：%s → %s 槽" % [pid, slot_id], true)
			_rebuild()
			_pick_part(slot_id, pid)
		else:
			_set_msg("导入失败（写盘）", false)
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered_ratio(0.7)

# —— 部件删除 / 清理 ——
# 统一管理：删条目 + 可选删磁盘 PNG（工坊自绘的默认勾选，外部导入的默认不勾以免误删源文件）。
func _delete_part_dialog(slot_id: String, pid: String, cn: String, path: String) -> void:
	var ov := _make_overlay()
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", EditorTheme.sb(Color(0.14, 0.15, 0.19), Color(0.4, 0.44, 0.52)))
	var cc := CenterContainer.new(); cc.set_anchors_preset(Control.PRESET_FULL_RECT); ov.add_child(cc); cc.add_child(panel)
	var vb := VBoxContainer.new(); vb.add_theme_constant_override("separation", 10); vb.custom_minimum_size = Vector2(400, 0); panel.add_child(vb)
	var t := Label.new(); t.text = "删除部件「%s」（%s）" % [cn, pid]; t.add_theme_font_size_override("font_size", 16); vb.add_child(t)
	var file_exists := path != "" and FileAccess.file_exists(path)
	var owned := path.begins_with("res://icons/Parts/")
	var chk := CheckBox.new()
	chk.text = "同时删除磁盘文件" + ("" if file_exists else "（文件不存在）")
	chk.button_pressed = file_exists and owned
	chk.disabled = not file_exists
	vb.add_child(chk)
	var pl := Label.new(); pl.text = path; pl.add_theme_color_override("font_color", Color(0.6, 0.64, 0.7)); pl.add_theme_font_size_override("font_size", 11)
	pl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; vb.add_child(pl)
	if not owned and file_exists:
		var w := Label.new(); w.text = "⚠ 该文件不在 icons/Parts 内（可能是外部导入的源图），默认不删"; w.add_theme_color_override("font_color", Color(1, 0.7, 0.2)); w.add_theme_font_size_override("font_size", 11)
		w.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; vb.add_child(w)
	var btns := HBoxContainer.new(); btns.add_theme_constant_override("separation", 8); btns.alignment = BoxContainer.ALIGNMENT_END
	var cancel := Button.new(); cancel.text = "取消"; cancel.pressed.connect(_close_overlay)
	var del := Button.new(); del.text = "删除"; del.add_theme_stylebox_override("normal", EditorTheme.sb(Color(0.5, 0.2, 0.2), Color(0.8, 0.4, 0.4)))
	del.pressed.connect(func():
		if str(_recipe["parts"].get(slot_id, "")) == pid:
			_recipe["parts"].erase(slot_id)
		var ok := AppearanceDB.delete_part(pid)
		var extra := ""
		if ok and chk.button_pressed and file_exists:
			if DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK:
				extra = " + 已删文件"
			else:
				extra = "（文件删除失败）"
		_close_overlay()
		if ok:
			TextureCache.clear(); PaperDoll.clear_cache()
			_set_msg("已删除部件：%s%s" % [cn, extra], true)
			_rebuild()
		else:
			_set_msg("删除失败（写盘）", false))
	btns.add_child(cancel); btns.add_child(del)
	vb.add_child(btns)

func _prune_missing() -> void:
	var removed := 0
	var used_ids := {}
	for p in AppearanceDB.all_parts().duplicate():
		var path := str(p.get("path", ""))
		if path == "" or not FileAccess.file_exists(path):
			var pid := str(p.get("id", ""))
			if AppearanceDB.delete_part(pid):
				removed += 1
				# 从 recipe 摘除失效引用
				for slot_id in _recipe["parts"].keys():
					if str(_recipe["parts"][slot_id]) == pid:
						_recipe["parts"].erase(slot_id)
	if removed > 0:
		TextureCache.clear(); PaperDoll.clear_cache()
		_set_msg("已清理 %d 个失效部件（文件不存在）" % removed, true)
	else:
		_set_msg("没有失效部件", true)
	_rebuild()

# —— 应用到单位 / 从单位载入 ——
func _on_apply_to_unit() -> void:
	var protos := UnitFactory.all_prototypes()
	var ov := _make_overlay()
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", EditorTheme.sb(Color(0.14, 0.15, 0.19), Color(0.4, 0.44, 0.52)))
	var cc := CenterContainer.new(); cc.set_anchors_preset(Control.PRESET_FULL_RECT); ov.add_child(cc); cc.add_child(panel)
	var vb := VBoxContainer.new(); vb.add_theme_constant_override("separation", 10); vb.custom_minimum_size = Vector2(400, 0); panel.add_child(vb)
	var t := Label.new(); t.text = "应用外观到单位"; t.add_theme_font_size_override("font_size", 16); vb.add_child(t)
	var list := ItemList.new(); list.custom_minimum_size = Vector2(380, 360)
	for p in protos:
		var pid := str(p.get("id", ""))
		var idx := list.add_item("%s  (%s)" % [str(p.get("name", pid)), pid])
		list.set_item_metadata(idx, pid)
	vb.add_child(list)
	var icon_chk := CheckBox.new(); icon_chk.text = "覆盖 棋子图标 (icon)"; icon_chk.button_pressed = true
	var port_chk := CheckBox.new(); port_chk.text = "覆盖 立绘 (portrait)"; port_chk.button_pressed = true
	vb.add_child(icon_chk); vb.add_child(port_chk)
	var hint := Label.new(); hint.text = "勾选要覆盖的项（可只应用到其中一方）"; hint.add_theme_color_override("font_color", Color(0.6, 0.64, 0.7)); hint.add_theme_font_size_override("font_size", 11)
	vb.add_child(hint)
	var btns := HBoxContainer.new(); btns.add_theme_constant_override("separation", 8); btns.alignment = BoxContainer.ALIGNMENT_END
	var cancel := Button.new(); cancel.text = "取消"; cancel.pressed.connect(_close_overlay)
	var ok := Button.new(); ok.text = "应用"; ok.add_theme_stylebox_override("normal", EditorTheme.sb(Color(0.24, 0.42, 0.24), Color(0.4, 0.7, 0.4)))
	var do_apply := func():
		var sel := list.get_selected_items()
		if sel.is_empty():
			_set_msg("请先选一个单位", false); return
		var pid := str(list.get_item_metadata(sel[0]))
		var si := icon_chk.button_pressed; var sp := port_chk.button_pressed
		_close_overlay()
		_apply_to_proto(pid, si, sp)
	ok.pressed.connect(func(): do_apply.call())
	list.item_activated.connect(func(_i): do_apply.call())
	btns.add_child(cancel); btns.add_child(ok)
	vb.add_child(btns)

func _on_load_from_unit() -> void:
	if AppearanceDB.all_looks().is_empty():
		_set_msg("还没有任何单位保存过外观配方", false); return
	_pick_prototype("从哪个单位载入外观？", true, func(id):
		var look = AppearanceDB.get_look(id)
		if typeof(look) == TYPE_DICTIONARY:
			_recipe = {"parts": look.get("parts", {}).duplicate(), "palettes": look.get("palettes", {}).duplicate()}
			var pc = look.get("piece", {})
			if typeof(pc) == TYPE_DICTIONARY and not pc.is_empty():
				_piece = {"scale": float(pc.get("scale", 2.0)), "dx": float(pc.get("dx", 0.0)), "dy": float(pc.get("dy", 24.0))}
			_rebuild()
			_set_msg("已载入 %s 的外观" % id, true))

func _apply_to_proto(id: String, set_icon: bool, set_portrait: bool) -> void:
	if not set_icon and not set_portrait:
		_set_msg("未选择应用目标（图标/立绘）", false); return
	var proto := UnitFactory.get_prototype(id)
	if proto.is_empty():
		_set_msg("找不到原型：%s" % id, false); return
	var dir := "res://icons/Characters"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var path := "%s/appearance_%s.png" % [dir, id]
	if not PaperDoll.export_png(_recipe, path, 1):
		_set_msg("导出失败（写盘）：%s" % path, false); return
	proto = proto.duplicate(true)
	var which := []
	if set_portrait: proto["portrait"] = path; which.append("立绘")
	if set_icon: proto["icon"] = path; which.append("棋子图标")
	if UnitFactory.save_prototype(proto):
		AppearanceDB.save_look(id, {"parts": _recipe["parts"], "palettes": _recipe["palettes"], "piece": _piece})
		TextureCache.clear(); PaperDoll.clear_cache()
		_set_msg("已应用到「%s」：%s → %s" % [str(proto.get("name", id)), "/".join(which), path], true)
	else:
		_set_msg("保存原型失败（写盘）", false)

# 单位原型选择弹窗。only_with_look=true 时只列已存外观配方的。
func _pick_prototype(title: String, only_with_look: bool, on_pick: Callable) -> void:
	var protos := UnitFactory.all_prototypes()
	var looks := AppearanceDB.all_looks() if only_with_look else {}
	var ov := _make_overlay()
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", EditorTheme.sb(Color(0.14, 0.15, 0.19), Color(0.4, 0.44, 0.52)))
	var cc := CenterContainer.new(); cc.set_anchors_preset(Control.PRESET_FULL_RECT); ov.add_child(cc); cc.add_child(panel)
	var vb := VBoxContainer.new(); vb.add_theme_constant_override("separation", 10); panel.add_child(vb)
	var t := Label.new(); t.text = title; t.add_theme_font_size_override("font_size", 16); vb.add_child(t)
	var list := ItemList.new(); list.custom_minimum_size = Vector2(380, 420)
	for p in protos:
		var pid := str(p.get("id", ""))
		if only_with_look and not looks.has(pid):
			continue
		var idx := list.add_item("%s  (%s)" % [str(p.get("name", pid)), pid])
		list.set_item_metadata(idx, pid)
	vb.add_child(list)
	var pick := func(pid): _close_overlay(); on_pick.call(pid)
	list.item_activated.connect(func(i): pick.call(str(list.get_item_metadata(i))))
	var btns := HBoxContainer.new(); btns.add_theme_constant_override("separation", 8); btns.alignment = BoxContainer.ALIGNMENT_END
	var cancel := Button.new(); cancel.text = "取消"; cancel.pressed.connect(_close_overlay)
	var ok := Button.new(); ok.text = "确定"; ok.add_theme_stylebox_override("normal", EditorTheme.sb(Color(0.24, 0.42, 0.24), Color(0.4, 0.7, 0.4)))
	ok.pressed.connect(func():
		var sel := list.get_selected_items()
		if sel.is_empty():
			return
		pick.call(str(list.get_item_metadata(sel[0]))))
	btns.add_child(cancel); btns.add_child(ok)
	vb.add_child(btns)

# —— 新增部件总类 ——
func _add_slot_dialog() -> void:
	var ov := _make_overlay()
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", EditorTheme.sb(Color(0.14, 0.15, 0.19), Color(0.4, 0.44, 0.52)))
	var cc := CenterContainer.new(); cc.set_anchors_preset(Control.PRESET_FULL_RECT); ov.add_child(cc); cc.add_child(panel)
	var vb := VBoxContainer.new(); vb.add_theme_constant_override("separation", 10); vb.custom_minimum_size = Vector2(320, 0)
	panel.add_child(vb)
	var t := Label.new(); t.text = "新增部件总类"; t.add_theme_font_size_override("font_size", 18); vb.add_child(t)
	var name_edit := LineEdit.new(); name_edit.placeholder_text = "名称，如 披风 / 翅膀 / 尾巴"
	vb.add_child(EditorUI.field_row("名称", name_edit, 60))
	var z_spin := SpinBox.new(); z_spin.min_value = 0; z_spin.max_value = 999; z_spin.step = 1; z_spin.value = AppearanceDB.max_z() + 10
	vb.add_child(EditorUI.field_row("层级 z", z_spin, 60))
	var hint := Label.new(); hint.text = "z 越大越靠前（盖住 z 小的）"; hint.add_theme_color_override("font_color", Color(0.6, 0.64, 0.7)); hint.add_theme_font_size_override("font_size", 11)
	vb.add_child(hint)
	var btns := HBoxContainer.new(); btns.add_theme_constant_override("separation", 8); btns.alignment = BoxContainer.ALIGNMENT_END
	var cancel := Button.new(); cancel.text = "取消"; cancel.pressed.connect(_close_overlay)
	var ok := Button.new(); ok.text = "创建"; ok.add_theme_stylebox_override("normal", EditorTheme.sb(Color(0.24, 0.42, 0.24), Color(0.4, 0.7, 0.4)))
	ok.pressed.connect(func():
		var cn := name_edit.text.strip_edges()
		if cn == "":
			return
		var id := "cslot_1"; var n := 1
		while AppearanceDB.get_slot(id) != null:
			n += 1; id = "cslot_%d" % n
		if AppearanceDB.save_slot({"id": id, "cn": cn, "z": int(z_spin.value)}):
			_set_msg("已新增部件总类：%s" % cn, true)
			_close_overlay()
			_rebuild()
		else:
			_set_msg("新增失败（写盘）", false))
	btns.add_child(cancel); btns.add_child(ok)
	vb.add_child(btns)

# —— 槽位层序 / 删除 ——
# dir: +1 更靠前(更大 z)、-1 更靠后(更小 z)。相邻两槽交换顺序后归一化 z=index*10。
func _move_slot(slot_id: String, dir: int) -> void:
	var ordered := AppearanceDB.slots()   # 升序（index 0＝最底/最先画）
	var i := -1
	for k in ordered.size():
		if str(ordered[k].get("id")) == slot_id:
			i = k; break
	var j := i + dir
	if i < 0 or j < 0 or j >= ordered.size():
		return
	var ids := []
	for s in ordered:
		ids.append(str(s.get("id")))
	var tmp = ids[i]; ids[i] = ids[j]; ids[j] = tmp
	# 归一化重排 z（只写有变化的）
	for k in ids.size():
		var s = AppearanceDB.get_slot(str(ids[k]))
		if s == null:
			continue
		if int(s.get("z", -1)) != k * 10:
			var d = s.duplicate()
			d["z"] = k * 10
			AppearanceDB.save_slot(d)
	_rebuild()

func _delete_slot_confirm(slot_id: String, cn: String) -> void:
	EditorUI.confirm(self, "删除部件总类「%s」及其下所有部件？此操作会改数据文件。" % cn, "删除",
		func():
			# 从 recipe 摘除
			_recipe["parts"].erase(slot_id)
			_recipe["palettes"].erase(slot_id)
			if AppearanceDB.delete_slot(slot_id):
				TextureCache.clear(); PaperDoll.clear_cache()
				_set_msg("已删除部件总类：%s" % cn, true)
				_rebuild()
			else:
				_set_msg("删除失败（写盘）", false),
		Callable(), "删除部件总类")

# —— 内置绘制 ——
func _open_draw(slot_id: String) -> void:
	_draw_slot = slot_id
	var slot = AppearanceDB.get_slot(slot_id)
	var slot_cn := str(slot.get("cn", slot_id)) if slot else slot_id
	# 洋葱皮＝当前角色去掉本槽后的合成图
	var onion_recipe := {"parts": _recipe["parts"].duplicate(), "palettes": _recipe["palettes"].duplicate()}
	onion_recipe["parts"].erase(slot_id)
	var onion := ImageTexture.create_from_image(PaperDoll.compose(onion_recipe))

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
	var title := Label.new(); title.text = "绘制部件 · %s　（画布底下淡显角色本体供对齐 · 滚轮缩放 · 中键拖动平移 · 右键吸管）" % slot_cn
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
		tb.tooltip_text = "快捷键 %s" % key
		tb.pressed.connect(func(): _set_tool(tid))
		_tool_btns[tid] = tb
		tools.add_child(tb)
	var mir := CheckBox.new(); mir.text = "水平镜像"; mir.toggled.connect(func(on): _paint.mirror_x = on)
	tools.add_child(mir)
	# 选区操作
	var selrow := HFlowContainer.new(); selrow.add_theme_constant_override("h_separation", 3)
	for sc in [["复制", func(): _paint.copy_sel()], ["剪切", func(): _paint.cut_sel()], ["粘贴", func(): _paint.paste()], ["删除", func(): _paint.delete_sel()]]:
		var sb := Button.new(); sb.text = str(sc[0]); sb.focus_mode = Control.FOCUS_NONE
		var cbk: Callable = sc[1]
		sb.pressed.connect(func(): cbk.call())
		selrow.add_child(sb)
	tools.add_child(selrow)
	var selhint := Label.new(); selhint.text = "选区拖动=移动 · Ctrl+C/V/X · Del"; selhint.add_theme_color_override("font_color", Color(0.55, 0.58, 0.64)); selhint.add_theme_font_size_override("font_size", 10); selhint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tools.add_child(selhint)
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
	var loadsel := Button.new(); loadsel.text = "载入所选部件"; loadsel.tooltip_text = "把该槽当前所选部件载入编辑（灰度源）"
	loadsel.pressed.connect(func(): _load_selected_into_canvas(slot_id))
	tools.add_child(loadsel)
	mid.add_child(tools)

	# 中：画布（填满）
	var canvas_wrap := PanelContainer.new()
	canvas_wrap.add_theme_stylebox_override("panel", EditorTheme.sb(Color(0.08, 0.09, 0.11), Color(0.3, 0.33, 0.4)))
	canvas_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_paint = PixelDrawCanvas.new()
	_paint.setup(AppearanceDB.canvas_size(), null, onion)
	_paint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_paint.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_paint.color_picked.connect(func(c): _sync_color(c))
	canvas_wrap.add_child(_paint)
	mid.add_child(canvas_wrap)

	# 右：颜色
	var side := VBoxContainer.new(); side.add_theme_constant_override("separation", 6); side.custom_minimum_size = Vector2(250, 0)
	var cl := Label.new(); cl.text = "颜色（灰度＝换色最佳）"; cl.add_theme_font_size_override("font_size", 12); side.add_child(cl)
	var ramp := HFlowContainer.new()
	for v in [0.0, 0.12, 0.25, 0.4, 0.55, 0.7, 0.85, 1.0]:
		var sw := Button.new(); sw.custom_minimum_size = Vector2(32, 28); sw.focus_mode = Control.FOCUS_NONE
		sw.add_theme_stylebox_override("normal", EditorTheme.sb(Color(v, v, v), Color(0.3, 0.33, 0.4)))
		sw.add_theme_stylebox_override("hover", EditorTheme.sb(Color(v, v, v), Color(0.9, 0.9, 0.9)))
		var cv := Color(v, v, v, 1.0)
		sw.pressed.connect(func(): _sync_color(cv))
		ramp.add_child(sw)
	side.add_child(ramp)
	var gridchk := CheckBox.new(); gridchk.text = "像素网格"; gridchk.button_pressed = true
	gridchk.toggled.connect(func(on): _paint.set_grid(on))
	side.add_child(gridchk)
	var cp := ColorPicker.new(); cp.edit_alpha = false; cp.color = _paint.brush; cp.custom_minimum_size = Vector2(240, 0)
	cp.color_changed.connect(func(c): _paint.brush = c)
	_color_btn = cp
	side.add_child(cp)
	mid.add_child(side)

	# 底：id + 保存/取消
	var bottom := HBoxContainer.new(); bottom.add_theme_constant_override("separation", 8); col.add_child(bottom)
	bottom.add_child(EditorUI.label("部件 id"))
	_draw_id_edit = LineEdit.new(); _draw_id_edit.text = "%s_new" % slot_id; _draw_id_edit.custom_minimum_size = Vector2(200, 0)
	bottom.add_child(_draw_id_edit)
	bottom.add_child(_hspacer())
	var cancel := Button.new(); cancel.text = "取消"; cancel.pressed.connect(_close_overlay)
	var save := Button.new(); save.text = "💾 保存为部件"; save.add_theme_stylebox_override("normal", EditorTheme.sb(Color(0.24, 0.42, 0.24), Color(0.4, 0.7, 0.4)))
	save.pressed.connect(_save_drawn_part)
	bottom.add_child(cancel); bottom.add_child(save)

	_set_tool("pencil")

func _load_selected_into_canvas(slot_id: String) -> void:
	if _paint == null:
		return
	var pid := str(_recipe["parts"].get(slot_id, ""))
	if pid == "":
		_set_msg("该槽当前没有所选部件", false); return
	var part = AppearanceDB.get_part(pid)
	if part == null:
		return
	var im := PaperDoll._part_image(str(part.get("path", "")))
	if im != null:
		_paint.load_image(im)
		_draw_id_edit.text = pid

var _color_btn   # ColorPicker（HSV 大取色器）

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

# 绘制态键盘快捷键（浮层开着且非文本框聚焦时才触发——_unhandled_key_input 天然让 LineEdit/取色器 hex 优先）。
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

func _save_drawn_part() -> void:
	var id := _sanitize_id(_draw_id_edit.text)
	if id == "":
		_set_msg("部件 id 不能为空", false); return
	var dir := "res://icons/Parts/" + _draw_slot
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var path := "%s/%s.png" % [dir, id]
	var out_img := _paint.get_image()
	if out_img.save_png(path) != OK:
		_set_msg("保存失败（写盘）：%s" % path, false); return
	TextureCache.clear(); PaperDoll.clear_cache()   # 避免旧 null/旧图缓存命中
	var part := {"id": id, "slot": _draw_slot, "cn": id, "path": path, "tags": [], "recolorable": true}
	var existing := AppearanceDB.parts_in_slot(_draw_slot)
	if not existing.is_empty() and existing[0].has("default_palette"):
		part["default_palette"] = existing[0]["default_palette"]
	if AppearanceDB.save_part(part):
		_set_msg("已保存部件 %s → %s" % [id, path], true)
		var slot := _draw_slot
		_close_overlay()
		_rebuild()
		_pick_part(slot, id)
	else:
		_set_msg("保存失败（DB 写盘）", false)

# —— overlay 基建 ——
func _make_overlay() -> Control:
	_close_overlay()
	var ov := Control.new()
	ov.set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0, 0, 0, 0.55)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP   # 挡住底层输入
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

func _set_msg(text: String, ok: bool) -> void:
	if _msg == null:
		return
	_msg.text = text
	_msg.add_theme_color_override("font_color", Color(0.6, 0.8, 0.6) if ok else Color(0.9, 0.5, 0.5))

# —— 纹理 ——
func _part_preview_texture(part: Dictionary) -> Texture2D:
	# 缩略图＝部件原图（不预染色）——与「默认调色板＝无」一致，所见即所得。
	var img := PaperDoll._part_image(str(part.get("path", "")))
	if img == null:
		return null
	return ImageTexture.create_from_image(img)

func _swatch_texture(pal: Dictionary) -> Texture2D:
	var stops := PackedColorArray()
	for hex in pal.get("stops", []):
		stops.append(Color.html(str(hex)))
	var w := 32
	var img := Image.create(w, 1, false, Image.FORMAT_RGBA8)
	for x in w:
		img.set_pixel(x, 0, PaperDoll._ramp(stops, float(x) / float(w - 1)) if stops.size() > 0 else Color.GRAY)
	return ImageTexture.create_from_image(img)

func _checker_texture() -> Texture2D:
	var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	var a := Color(0.16, 0.17, 0.2); var b := Color(0.21, 0.22, 0.26)
	img.set_pixel(0, 0, a); img.set_pixel(1, 1, a)
	img.set_pixel(1, 0, b); img.set_pixel(0, 1, b)
	return ImageTexture.create_from_image(img)

func _sanitize_id(s: String) -> String:
	var res := ""
	for i in s.length():
		var ch := s[i]
		if (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") or ch == "_":
			res += ch
		else:
			res += "_"
	return res
