extends Control
## 地块绘制工坊：给每种地形手绘像素 hex 瓦片（含差分变体），HexTileRender 渲染时优先于程序烘。
## 独立场景，与外观工坊平级（主菜单进）；结构仿 AppearanceWorkshop（左清单+右预览+overlay 绘制），
## 复用 EditorUI/EditorTheme/PixelDrawCanvas/HexTileRender/TextureCache/TerrainDB（数据/代码分离、DRY）。
## 只碰渲染器 + 新文件，不动 MapEditor/Sandbox/Overworld。瓦片存 res://icons/Tiles/<terrain>_<variant>/<n>.png，
## 注册进 terrains.json 的 art 数组（TerrainDB.set_art + save，单一写口）。
## 绘制浮层＝PixelDrawOverlay 共享组件（提案 §16，与外观工坊同一份）；左栏＝分类两级折叠+过滤+懒构建（§12）。

const EditorUI := preload("res://EditorUI.gd")
const EditorTheme := preload("res://EditorTheme.gd")
const TerrainDB := preload("res://TerrainDB.gd")
const TextureCache := preload("res://TextureCache.gd")
const TerrainSwatch := preload("res://TerrainSwatch.gd")
const TilePreview := preload("res://TilePreview.gd")
const PixelDrawOverlay := preload("res://PixelDrawOverlay.gd")
const HexTileRender := preload("res://HexTileRender.gd")

const TILE := 52   # 变体缩略图边长
const SWATCHES_PATH := "res://data/terrain_swatches.json"   # 取色器色块预设持久化（与外观侧各一份，用户增删预设才写）
const LIVE_ART_PATH := "live://terrain_edit"                # §28 实时拼贴预览：画布内容挂 TextureCache 虚拟路径

var _root: VBoxContainer
var _variant_tiles := {}   # key -> { idx(int): Button }（idx=-1＝程序兜底缩略）
var _preview: TilePreview
var _msg: Label
var _sel_key := ""
var _sel_idx := 0
# 左栏态（§10/§12：跨 _rebuild 保活）
var _filter := ""          # 过滤词（小写；匹配 label/terrain/variant）
var _fold_cat := {}        # 分类折叠：cat -> bool(collapsed)
var _fold := {}            # 地形行折叠：entry_key -> bool(collapsed)
var _left_scroll: ScrollContainer
var _left_list: VBoxContainer
# 绘制态
var _ov                    # PixelDrawOverlay（浮层开着才非 null）
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
	# 确保有合法选中（首次 / 重建后所选地形没了）——先于建左栏：含选中的分类组要自动展开
	if _sel_key == "" or _entry_by_key(_sel_key) == null:
		var pal := TerrainDB.palette()
		if not pal.is_empty():
			_sel_key = _entry_key(pal[0])
			_sel_idx = 0 if not TerrainDB.art_of(pal[0]).is_empty() else -1
	_root.add_child(_titlebar())
	var split := HSplitContainer.new()
	split.split_offset = 380
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(_build_left())
	split.add_child(_build_right())
	_root.add_child(split)
	_refresh_selection()
	_update_preview()

# §10：重建前记滚动位置、重建后回填（折叠态在 _fold/_fold_cat 随开合即时记录，天然跨重建）。
func _rebuild() -> void:
	var sv: int = _left_scroll.scroll_vertical if (_left_scroll != null and is_instance_valid(_left_scroll)) else 0
	_build_ui()
	_restore_left_scroll(sv)

func _restore_left_scroll(v: int) -> void:
	await get_tree().process_frame   # 等一帧布局，scroll 上限才就位
	if _left_scroll != null and is_instance_valid(_left_scroll):
		_left_scroll.scroll_vertical = v

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

# —— 左栏（§12）：过滤框 + 分类两级折叠（TerrainDB.categories() 既有分组直接吃，与 MapEditor 笔刷同序）——
func _build_left() -> Control:
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 4)
	outer.custom_minimum_size = Vector2(360, 0)
	var fbox := LineEdit.new()
	fbox.placeholder_text = "🔍 过滤地形（名称 / id）"
	fbox.text = _filter
	fbox.clear_button_enabled = true
	fbox.text_changed.connect(func(t: String):
		_filter = t.strip_edges().to_lower()
		_populate_left_list())   # 只重灌清单、不整页重建——输入框焦点不丢
	outer.add_child(fbox)
	_left_scroll = ScrollContainer.new()
	_left_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_left_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_left_list = VBoxContainer.new()
	_left_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_left_list.add_theme_constant_override("separation", 5)
	_left_scroll.add_child(_left_list)
	outer.add_child(_left_scroll)
	_populate_left_list()
	return EditorUI.panelize(outer)

# 灌左栏清单：分类 -> [entry…]（保 palette 顺序；用户分类在前、待定垫底——与 MapEditor._rebuild_terrain_brushes 同序）。
func _populate_left_list() -> void:
	for c in _left_list.get_children():
		c.queue_free()
	_variant_tiles.clear()
	var groups := {}
	var order := []
	for cat in TerrainDB.categories():
		var cs := str(cat)
		if not groups.has(cs):
			groups[cs] = []
			order.append(cs)
	for e in TerrainDB.palette():
		if not _match_filter(e):
			continue
		var cat := TerrainDB.category_of(e)
		if not groups.has(cat):
			groups[cat] = []
			order.append(cat)
		groups[cat].append(e)
	order.erase(TerrainDB.DEFAULT_CATEGORY)
	order.append(TerrainDB.DEFAULT_CATEGORY)
	for cat in order:
		var entries: Array = groups.get(cat, [])
		if entries.is_empty():
			continue   # 空分类不占位（分类增删管理在 MapEditor 笔刷侧，这里纯浏览）
		_left_list.add_child(_category_group(str(cat), entries))
	_refresh_selection()

func _match_filter(e: Dictionary) -> bool:
	if _filter == "":
		return true
	var hay := ("%s %s %s" % [str(e.get("label", "")), str(e.get("terrain", "")), str(e.get("variant", ""))]).to_lower()
	return hay.find(_filter) >= 0

# 分类组（懒构建：折叠组展开才建行——145 地形全量建曾是打开卡顿源；过滤中/含选中组即时建）。
func _category_group(cat: String, entries: Array) -> Control:
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 5)
	var built := {"done": false}
	var build := func():
		if built["done"]:
			return
		built["done"] = true
		for e in entries:
			content.add_child(_terrain_row(e))
		_refresh_selection()
	var has_sel := entries.any(func(e): return _entry_key(e) == _sel_key)
	var collapsed: bool
	if _filter != "":
		collapsed = false                       # 过滤中：命中组全展开
	elif _fold_cat.has(cat):
		collapsed = bool(_fold_cat[cat])
	else:
		collapsed = not has_sel                 # 首见默认：含当前选中的组展开、其余收起
	if not collapsed:
		build.call()
	return EditorUI.make_foldable("%s (%d)" % [cat, entries.size()], content, collapsed, false,
		func(open: bool):
			_fold_cat[cat] = not open
			if open:
				build.call())

# 单个地形行（原左栏一行：折叠标题 + 变体条）；折叠态按 entry_key 记（§10）。
func _terrain_row(entry: Dictionary) -> Control:
	var key := _entry_key(entry)
	var art := TerrainDB.art_of(entry)
	var title := "%s  ·  %d 变体" % [str(entry.get("label", entry.get("id", "?"))), art.size()]
	var collapsed := bool(_fold.get(key, false))
	return EditorUI.make_foldable(title, _terrain_content(entry), collapsed, false,
		func(open: bool): _fold[key] = not open)

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
	var dup := Button.new(); dup.text = "⧉ 复制为新变体"; dup.tooltip_text = "以所选变体为底稿另起一张（保存为新变体，不覆盖原图）——差分变体不用从零画"
	dup.pressed.connect(_copy_selected_as_new)
	var imp := Button.new(); imp.text = "＋ 导入 PNG"; imp.pressed.connect(_import_variant)
	var del := Button.new(); del.text = "🗑 删除变体"; del.pressed.connect(_delete_selected)
	row.add_child(edit); row.add_child(dup); row.add_child(imp); row.add_child(del)
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

# —— 绘制变体（PixelDrawOverlay 共享组件 §16；六边形轮廓/遮罩对照 + §28 实时拼贴预览）——
# base_img：§27「复制为新变体」传底稿（idx=-1 时作为初始内容，保存走新变体档号）。
func _open_draw(entry, idx: int, base_img: Image = null) -> void:
	_draw_entry = entry
	_draw_idx = idx
	var sz := HexTileRender.tile_px_size()
	var art := TerrainDB.art_of(entry)
	var initial: Image = base_img
	if initial == null and idx >= 0 and idx < art.size():
		var tex := TextureCache.get_tex_file(str(art[idx]))
		if tex != null:
			initial = tex.get_image()
	var base := Color.html(str(entry.get("color", "#888888")))
	var acc := Color.html(str(entry.get("accent", "#aaaaaa")))
	var nlabel := ("变体 #%d" % idx) if idx >= 0 else ("新变体 #%d" % art.size())

	# §28 实时拼贴预览：live 纹理挂 TextureCache 虚拟路径 → mini TilePreview 与地图完全同一渲染链。
	# 纹理复用同一实例（update），赤道锚钉 hex 遮罩赤道行——免半成品按内容找最宽行上下乱窜。
	var live_tex := ImageTexture.create_from_image(initial if initial != null else Image.create(sz.x, sz.y, false, Image.FORMAT_RGBA8))
	TextureCache.put_file(LIVE_ART_PATH, live_tex)
	var art_pv: Array = art.duplicate()
	var live_idx := idx
	if idx >= 0 and idx < art_pv.size():
		art_pv[idx] = LIVE_ART_PATH      # 编辑现有：该变体位换成 live
	else:
		art_pv.append(LIVE_ART_PATH)     # 新变体：追加 live（邻格照旧混既有变体，看接缝）
		live_idx = art_pv.size() - 1
	var mini := TilePreview.new()
	mini.custom_minimum_size = Vector2(240, 180)
	var eq := _hex_equator_row()
	var refresh := func(im: Image):
		live_tex.update(im)
		mini.set_tile(base, acc, str(entry.get("decor", "none")), art_pv, live_idx, eq)

	var ov = PixelDrawOverlay.new()
	add_child(ov)
	ov.setup({
		"title": "绘制地块 · %s · %s　（银白线＝六边形轮廓 · 暗区＝界外不可画 · 滚轮缩放 · 中键平移 · 右键吸管）" % [str(entry.get("label", "?")), nlabel],
		"canvas_w": sz.x, "canvas_h": sz.y,
		"initial": initial,
		"onion": _build_hex_ref(sz.x, sz.y),
		"paint_mask": _build_hex_mask(sz.x, sz.y),
		"brush": base,
		"edit_alpha": true,
		"ramp_label": "快捷色（地形本色系）",
		"ramp_colors": [base.darkened(0.35), base.darkened(0.15), base, base.lightened(0.15), acc.darkened(0.15), acc, acc.lightened(0.2), Color(0, 0, 0, 1), Color(1, 1, 1, 1)],
		"save_text": "💾 保存变体",
		"swatches_path": SWATCHES_PATH,
		"side_extra": mini,
		"side_extra_label": "拼贴预览（实时）",
	})
	_ov = ov
	ov.canvas.image_changed.connect(refresh)
	refresh.call(ov.canvas.img)
	ov.save_pressed.connect(_save_variant)
	ov.closed.connect(func(): _ov = null)

# §27：以所选变体为底稿新建（差分变体不用从零画）。
func _copy_selected_as_new() -> void:
	var e = _entry_by_key(_sel_key)
	if e == null:
		return
	var art := TerrainDB.art_of(e)
	if _sel_idx < 0 or _sel_idx >= art.size():
		_set_msg("程序兜底没有底稿可复制（先画/导入一张手绘变体）", false); return
	var tex := TextureCache.get_tex_file(str(art[_sel_idx]))
	if tex == null:
		_set_msg("底稿读取失败：%s" % str(art[_sel_idx]), false); return
	_open_draw(e, -1, tex.get_image())
	_set_msg("以变体 #%d 为底稿新建（保存为新变体）" % _sel_idx, true)

# hex 遮罩的赤道行＝最宽带最高行（与 HexTileRender._widest_row 同判定、对遮罩算）；live 预览锚定用。
func _hex_equator_row() -> float:
	var s := HexTileRender.tile_px_size()
	var counts := []
	var best := 0
	for y in s.y:
		var c := 0
		for x in s.x:
			if HexTileRender.tile_hex_contains(x, y):
				c += 1
		counts.append(c)
		best = maxi(best, c)
	for y in s.y:
		if counts[y] >= best:
			return float(y)
	return float(s.y) * 0.5

func _save_variant() -> void:
	if _ov == null or _draw_entry.is_empty():
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
	var out_img: Image = _ov.canvas.get_image()
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
	TextureCache.clear()   # 新 PNG 立即生效（否则命中旧 null/旧图缓存；live 虚拟路径条目一并清掉）
	_set_msg("已保存 %s → %s" % [str(_draw_entry.get("label", key)), path], true)
	_ov.close()
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

# （原绘制态工具/键/色/overlay 基建已上移 PixelDrawOverlay 共享组件——§16）

func _edit_selected() -> void:
	var e = _entry_by_key(_sel_key)
	if e != null:
		_open_draw(e, _sel_idx)

func _import_variant() -> void:
	var e = _entry_by_key(_sel_key)
	if e == null:
		_set_msg("先选一个地形", false); return
	# §35：全文件系统访问（与外观侧 _open_import 对齐）——导入本就复制进 icons/Tiles/，不引用外部源路径
	var dlg := EditorUI.make_file_dialog(FileDialog.FILE_MODE_OPEN_FILE, FileDialog.ACCESS_FILESYSTEM, [["*.png", "PNG 图片"]])
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
