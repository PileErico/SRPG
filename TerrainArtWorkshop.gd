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
var _px_w_spin: SpinBox        # 画布规格：宽（六边形满宽；比例恒定 √3/2，宽定则六边形定）
var _px_head_spin: SpinBox     # 画布规格：顶部留白（界外物件头部空间；高＝六边形高+留白）
var _px_info: Label
var _px_loading := false
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
	# 素材整理（2026-07-20 用户令：整理功能进工坊，不再只靠 MapEditor 笔刷侧）
	var mrow := HBoxContainer.new()
	mrow.add_theme_constant_override("separation", 6)
	var addcat := Button.new()
	addcat.text = "＋ 新建分类"
	addcat.tooltip_text = "新建一个空分类（立即写盘；空分类也显示，随后可往里新建地块/移入条目）"
	addcat.pressed.connect(_on_new_category)
	mrow.add_child(addcat)
	var addent := Button.new()
	addent.text = "＋ 新建地块"
	addent.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	addent.tooltip_text = "新建一条地形/放置物条目（起名+归类+本色；通行/效果等数据细调在地图编辑器·地形数据）"
	addent.pressed.connect(_on_new_entry)
	mrow.add_child(addent)
	outer.add_child(mrow)
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
		if entries.is_empty() and (str(cat) == TerrainDB.DEFAULT_CATEGORY or _filter != ""):
			continue   # 空的「待定」不占位；过滤中空组不占位。用户分类空也显示——新建分类后可见、可收新条目
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
	# 一级（分类）头：深底+金字区分层级 + ↑↓ 排序（待定恒垫底不参与排序）
	var extra: Control = null
	if cat != TerrainDB.DEFAULT_CATEGORY:
		extra = _order_btns(func(d: int): _move_category(cat, d))
	return EditorUI.make_foldable("%s (%d)" % [cat, entries.size()], content, collapsed, false,
		func(open: bool):
			_fold_cat[cat] = not open
			if open:
				build.call(),
		extra, Color(0.07, 0.09, 0.13), Color(0.93, 0.80, 0.45))

# 单个地形行（原左栏一行：折叠标题 + 变体条）；折叠态按 entry_key 记（§10）。
# 二级头保留缺省浅底色（与一级深色区分）；↑↓＝分类内排序（与 MapEditor 笔刷栏同源同序）。
func _terrain_row(entry: Dictionary) -> Control:
	var key := _entry_key(entry)
	var art := TerrainDB.art_of(entry)
	var title := "%s  ·  %d 变体" % [str(entry.get("label", entry.get("id", "?"))), art.size()]
	var collapsed := bool(_fold.get(key, false))
	var tile := {"terrain": entry.get("terrain"), "variant": entry.get("variant")}
	return EditorUI.make_foldable(title, _terrain_content(entry), collapsed, false,
		func(open: bool): _fold[key] = not open,
		_order_btns(func(d: int): _move_entry_order(tile, d)))

# ↑↓ 排序钮对（header_extra 用；on_move 收 -1/+1）
func _order_btns(on_move: Callable) -> Control:
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 2)
	for pair in [["↑", -1], ["↓", 1]]:
		var b := Button.new()
		b.text = str(pair[0])
		b.custom_minimum_size = Vector2(26, 0)
		b.focus_mode = Control.FOCUS_NONE
		var d := int(pair[1])
		b.pressed.connect(func(): on_move.call(d))
		hb.add_child(b)
	return hb

# 分类排序：categories 数组相邻交换（待定不在数组、恒垫底——与 MapEditor 同规则）
func _move_category(cat: String, delta: int) -> void:
	var cats: Array = TerrainDB.categories()
	var idx := cats.find(cat)
	var j := idx + delta
	if idx < 0 or j < 0 or j >= cats.size():
		return
	var tmp = cats[idx]
	cats[idx] = cats[j]
	cats[j] = tmp
	TerrainDB.set_categories(cats)
	if not TerrainDB.save():
		_set_msg("分类排序写盘失败", false); return
	_rebuild()

# 条目排序：分类内与最近邻交换（TerrainDB.move_entry；顺序与 MapEditor 笔刷栏共用 _palette 单一源）
func _move_entry_order(tile: Dictionary, delta: int) -> void:
	if not TerrainDB.move_entry(tile, delta):
		return   # 到头
	if not TerrainDB.save():
		_set_msg("条目排序写盘失败", false); return
	_rebuild()

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
	# 画布规格（像素密度**逐条目可调**；六边形比例/外形恒定——宽定则六边形定，高＝六边形高+顶部留白）
	var pxrow := HBoxContainer.new()
	pxrow.add_theme_constant_override("separation", 6)
	var pl := Label.new(); pl.text = "画布宽"; pl.add_theme_font_size_override("font_size", 12)
	pxrow.add_child(pl)
	# ⚠️ 先配 min/max/step、**最后**连 value_changed：min_value 赋值会把默认 value(0) 钳到下限并发信号——
	# 先连后配＝建 UI 瞬间对选中条目静默写入 16 宽规格（2026-07-20 草原被污染事故，勿回退此序）
	_px_w_spin = SpinBox.new()
	_px_w_spin.min_value = 16; _px_w_spin.max_value = 256; _px_w_spin.step = 2
	_px_w_spin.tooltip_text = "六边形满宽像素数（32=旧规格 / 96=PHBT 参考密度）；六边形高按 √3/2 比例自动跟随"
	pxrow.add_child(_px_w_spin)
	var hl := Label.new(); hl.text = "顶部留白"; hl.add_theme_font_size_override("font_size", 12)
	pxrow.add_child(hl)
	_px_head_spin = SpinBox.new()
	_px_head_spin.min_value = 0; _px_head_spin.max_value = 64
	_px_head_spin.tooltip_text = "六边形上方的界外物件空间（树冠/道具探头用；96 宽配 12＝PHBT 同款 96×96）"
	pxrow.add_child(_px_head_spin)
	_px_w_spin.value_changed.connect(func(_v: float): _on_px_changed())
	_px_head_spin.value_changed.connect(func(_v: float): _on_px_changed())
	_px_info = Label.new()
	_px_info.add_theme_font_size_override("font_size", 12)
	_px_info.add_theme_color_override("font_color", Color(0.65, 0.7, 0.78))
	_px_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pxrow.add_child(_px_info)
	vb.add_child(pxrow)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var edit := Button.new(); edit.text = "✎ 编辑所选变体"; edit.pressed.connect(_edit_selected)
	var dup := Button.new(); dup.text = "⧉ 复制为新变体"; dup.tooltip_text = "以所选变体为底稿另起一张（保存为新变体，不覆盖原图）——差分变体不用从零画"
	dup.pressed.connect(_copy_selected_as_new)
	var base := Button.new(); base.text = "🎨 以其他地块为底稿…"
	base.tooltip_text = "从任意已有手绘变体里挑一张当底稿，画进当前地形的新变体（跨条目版「复制为新变体」；尺寸不符自动缩放）"
	base.pressed.connect(_pick_base_dialog)
	var imp := Button.new(); imp.text = "＋ 导入 PNG"; imp.pressed.connect(_import_variant)
	var del := Button.new(); del.text = "🗑 删除变体"; del.pressed.connect(_delete_selected)
	row.add_child(edit); row.add_child(dup); row.add_child(base); row.add_child(imp); row.add_child(del)
	vb.add_child(row)
	# 条目整理行（2026-07-20 用户令：整理功能进工坊）——作用于左栏当前选中的条目
	var orow := HBoxContainer.new()
	orow.add_theme_constant_override("separation", 6)
	var ren := Button.new(); ren.text = "✏ 条目改名"; ren.pressed.connect(_rename_entry)
	orow.add_child(ren)
	var mv := EditorUI.make_menu("📁 移到分类")
	var mpop := mv.get_popup()
	var cats := _all_category_names()
	for ci in cats.size():
		mpop.add_item("→ " + str(cats[ci]), ci)
	mpop.id_pressed.connect(func(id: int):
		if id >= 0 and id < cats.size():
			_move_entry_category(str(cats[id])))
	orow.add_child(mv)
	var dele := Button.new(); dele.text = "🗑 删除条目"
	dele.tooltip_text = "从 terrains.json 整条移除（已画 PNG 保留在 icons/Tiles/ 不删）"
	dele.pressed.connect(_delete_entry_sel)
	orow.add_child(dele)
	vb.add_child(orow)
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
	# 对齐与地图同口径：放置物按 art_anchor 钉赤道 + 先铺兜底地面再叠 art（HexCanvas 两遍绘制）
	_preview.set_tile(Color.html(str(entry.get("color", "#888888"))), Color.html(str(entry.get("accent", "#aaaaaa"))),
		str(entry.get("decor", "none")), TerrainDB.art_of(entry), _sel_idx,
		TerrainDB.art_anchor_of(entry), bool(entry.get("is_object", false)))
	_refresh_px_row(entry)

# —— 画布规格行（像素密度逐条目可调；六边形比例恒定）——

# 该宽度下的六边形像素高（√3/2 比例向上取整；32 宽＝旧规格 28 特例，与既有居中判定一致）
func _hex_rows_for(w: int) -> int:
	if w == 32:
		return 28
	return int(ceil(HexTileRender.SQRT3 * 0.5 * float(w)))

func _refresh_px_row(entry) -> void:
	if _px_w_spin == null or not is_instance_valid(_px_w_spin):
		return
	_px_loading = true
	var px := TerrainDB.art_px_of(entry)
	_px_w_spin.value = px.x
	_px_head_spin.value = maxi(0, px.y - _hex_rows_for(px.x))
	var anc := TerrainDB.art_anchor_of(entry)
	_px_info.text = "＝%d×%d · 锚行 %s" % [px.x, px.y,
		(str(int(anc)) if anc >= 0.0 else str(int(_hex_equator_row(px))) + "(存盘时写死)")]
	_px_loading = false

# 规格改动→写 entry.art_px + 自动锚行（已有手绘且自带锚行＝不动它，防覆写 randr 类手调值）→ 立即写盘。
# 回到 32 宽 0 留白＝抹掉 art_px/art_anchor（回归旧规格居中判定，JSON 保持干净）。
func _on_px_changed() -> void:
	if _px_loading:
		return
	var entry = _entry_by_key(_sel_key)
	if entry == null:
		return
	var w := int(_px_w_spin.value)
	var h := _hex_rows_for(w) + int(_px_head_spin.value)
	if Vector2i(w, h) == TerrainDB.art_px_of(entry):
		return   # 无变化（UI 重建回填/同值重设）＝不写盘不动锚
	if w == 32 and h == 28:
		entry.erase("art_px")
		if TerrainDB.art_of(entry).is_empty():
			entry.erase("art_anchor")
	else:
		entry["art_px"] = [w, h]
		var keep_anchor: bool = TerrainDB.art_anchor_of(entry) >= 0.0 and not TerrainDB.art_of(entry).is_empty()
		if not keep_anchor:
			entry["art_anchor"] = HexTileRender.hex_anchor_row(w, h)
	if TerrainDB.save():
		_set_msg("「%s」画布规格 → %d×%d（已写盘；已有变体尺寸不符时编辑会按新画布缩放——建议定稿密度后再批量画）" % [str(entry.get("label", "?")), w, h], true)
	else:
		_set_msg("画布规格写盘失败", false)
	_refresh_px_row(entry)
	_update_preview()

# —— 绘制变体（PixelDrawOverlay 共享组件 §16；六边形轮廓/遮罩对照 + §28 实时拼贴预览）——
# base_img：§27「复制为新变体」传底稿（idx=-1 时作为初始内容，保存走新变体档号）。
func _open_draw(entry, idx: int, base_img: Image = null) -> void:
	_draw_entry = entry
	_draw_idx = idx
	var sz := TerrainDB.art_px_of(entry)   # per-entry 画布规格（battle 词表 96×96；缺省旧 32×28）
	var art := TerrainDB.art_of(entry)
	var initial: Image = base_img
	if initial == null and idx >= 0 and idx < art.size():
		var tex := TextureCache.get_tex_file(str(art[idx]))
		if tex != null:
			initial = tex.get_image()
	if initial != null and (initial.get_width() != sz.x or initial.get_height() != sz.y):
		initial = initial.duplicate()
		initial.resize(sz.x, sz.y, Image.INTERPOLATE_NEAREST)   # 旧变体与当前画布规格不符→按新规格缩放编辑
	var base := Color.html(str(entry.get("color", "#888888")))
	var acc := Color.html(str(entry.get("accent", "#aaaaaa")))
	var nlabel := ("变体 #%d" % idx) if idx >= 0 else ("新变体 #%d" % art.size())

	# §28 实时拼贴预览：live 纹理挂 TextureCache 虚拟路径 → mini TilePreview 与地图完全同一渲染链。
	# 纹理复用同一实例（update），赤道锚钉 hex 遮罩赤道行——免半成品按内容找最宽行上下乱窜。
	# WYSIWYG（2026-07-20 用户令）：7 格**全部**画当前画布——画什么显示什么，绝不混抽既有变体
	# （单元素 art 池：pick_art 任何 seed 都命中 live；此前邻格按 seed 混旧变体＝「乱显示东西」）。
	var live_tex := ImageTexture.create_from_image(initial if initial != null else Image.create(sz.x, sz.y, false, Image.FORMAT_RGBA8))
	TextureCache.put_file(LIVE_ART_PATH, live_tex)
	var art_pv: Array = [LIVE_ART_PATH]
	var live_idx := 0
	var mini := TilePreview.new()
	mini.custom_minimum_size = Vector2(240, 260)
	# 锚行：放置物用 entry 声明的 art_anchor（与地图钉法一致）；地形块钉 hex 遮罩赤道行（免半成品最宽行乱窜）
	var eq := TerrainDB.art_anchor_of(entry)
	if eq < 0.0:
		eq = _hex_equator_row(sz)
	var is_obj := bool(entry.get("is_object", false))
	# 无垫底（2026-07-20 用户令）：不铺任何程序地面——灰白 hex 轮廓参考线（与画板同判定）合成在
	# 画作**下层**进 live 纹理，7 格只见轮廓+已画像素；要铺底自己走「以其他地块为底稿」。
	var ref_img := _hex_border_img(sz.x, sz.y, Color(0.78, 0.80, 0.85, 0.9))
	var refresh := func(im: Image):
		var comp: Image = ref_img.duplicate()
		var src := im
		if src.get_format() != Image.FORMAT_RGBA8:
			src = im.duplicate()
			src.convert(Image.FORMAT_RGBA8)
		comp.blend_rect(src, Rect2i(0, 0, sz.x, sz.y), Vector2i.ZERO)
		live_tex.update(comp)
		mini.set_tile(base, acc, str(entry.get("decor", "none")), art_pv, live_idx, eq, false)

	# 放置物＝全画布可画（界外物件——树冠/道具在六边形界外是正当内容，轮廓线仅作对位参考）；
	# 底地形＝锁 hex 内（存盘时同判定再清一次界外）。
	var ov = PixelDrawOverlay.new()
	add_child(ov)
	ov.setup({
		"title": "绘制地块 · %s · %s　（银白线＝六边形轮廓%s · 滚轮缩放 · 中键平移 · 右键吸管）" % [
			str(entry.get("label", "?")), nlabel, "（放置物：界外可画）" if is_obj else " · 暗区＝界外不可画"],
		"canvas_w": sz.x, "canvas_h": sz.y,
		"initial": initial,
		"onion": _build_hex_ref(sz.x, sz.y, not is_obj),
		"paint_mask": {} if is_obj else _build_hex_mask(sz.x, sz.y),
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
# 按画布规格算（旧 32×28 居中 / 新规格底对齐——判定单一源 hex_contains_px）。
func _hex_equator_row(s: Vector2i) -> float:
	var counts := []
	var best := 0
	for y in s.y:
		var c := 0
		for x in s.x:
			if HexTileRender.hex_contains_px(x, y, s.x, s.y):
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
	if not bool(_draw_entry.get("is_object", false)):
		_hex_mask_image(out_img)   # 底地形界外清透（belt-and-suspenders）；放置物界外物件正当、不清
	# 工坊出品＝画布对齐（所见即所得）：条目无锚行则存盘时写死＝遮罩赤道行（32×28→13 / 96×96→54）。
	# 「最宽行自算」只适用于画满六边形的图，对稀疏内容（一条曲线/几株草）会钉错高度——工坊图不猜。
	if TerrainDB.art_anchor_of(_draw_entry) < 0.0:
		_draw_entry["art_anchor"] = int(_hex_equator_row(TerrainDB.art_px_of(_draw_entry)))
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

# 把界外像素清透（保存兜底：与 paint_mask 同一 hex_contains_px 判定）。放置物不清（界外物件正当）。
func _hex_mask_image(im: Image) -> void:
	var w := im.get_width()
	var h := im.get_height()
	for y in h:
		for x in w:
			if not HexTileRender.hex_contains_px(x, y, w, h):
				im.set_pixel(x, y, Color(0, 0, 0, 0))

# hex 内缘轮廓 Image（单一实现：onion 参考 / live 拼贴预览的灰白参考线共用同一判定）
func _hex_border_img(w: int, h: int, col: Color) -> Image:
	var im := Image.create(w, h, false, Image.FORMAT_RGBA8)
	im.fill(Color(0, 0, 0, 0))
	for y in h:
		for x in w:
			if not HexTileRender.hex_contains_px(x, y, w, h):
				continue
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				if not HexTileRender.hex_contains_px(x + d.x, y + d.y, w, h):
					im.set_pixel(x, y, col)       # hex 内缘＝轮廓
					break
	return im

# 画布对照参考图（onion）：hex 内缘银白轮廓（供对齐）；mask_outside=true 另铺界外暗块（底地形禁区淡显），
# 放置物传 false＝只留轮廓参考线、界外照常可画。
func _build_hex_ref(w: int, h: int, mask_outside := true) -> ImageTexture:
	var im := _hex_border_img(w, h, Color(1, 1, 1, 1))
	if mask_outside:
		for y in h:
			for x in w:
				if not HexTileRender.hex_contains_px(x, y, w, h):
					im.set_pixel(x, y, Color(0, 0, 0, 1))          # 界外禁区（onion 0.30α 后淡显）
	return ImageTexture.create_from_image(im)

# 落笔遮罩：hex 内的像素集合（PixelDrawCanvas.paint_mask）。
func _build_hex_mask(w: int, h: int) -> Dictionary:
	var m := {}
	for y in h:
		for x in w:
			if HexTileRender.hex_contains_px(x, y, w, h):
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
	dlg.current_dir = EditorUI.recall_dir("terrain_import", dlg.current_dir)   # 上次导入目录
	add_child(dlg)
	dlg.file_selected.connect(func(p):
		EditorUI.remember_dir("terrain_import", str(p))
		_do_import(e, str(p)); dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	dlg.popup_centered_ratio(0.7)

func _do_import(entry, src_path: String) -> void:
	var im := Image.new()
	if im.load(src_path) != OK:
		_set_msg("读取失败：%s" % src_path, false); return
	if im.get_format() != Image.FORMAT_RGBA8:
		im.convert(Image.FORMAT_RGBA8)
	var sz := TerrainDB.art_px_of(entry)   # per-entry 画布规格
	if im.get_width() != sz.x or im.get_height() != sz.y:
		im.resize(sz.x, sz.y, Image.INTERPOLATE_NEAREST)   # 尺寸不符→缩到该条目瓦片尺寸（宽容）
	if not bool(entry.get("is_object", false)):
		_hex_mask_image(im)   # 底地形清界外；放置物保留界外物件
	if TerrainDB.art_anchor_of(entry) < 0.0:
		entry["art_anchor"] = int(_hex_equator_row(sz))   # 导入同律：画布对齐、不留给最宽行去猜
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

# —— 素材整理（2026-07-20 用户令：新建分类 / 新建地块 / 底稿选取 / 条目改名·移分类·删除 进工坊）——

func _all_category_names() -> Array:
	var out := []
	for c in TerrainDB.categories():
		out.append(str(c))
	if not out.has(TerrainDB.DEFAULT_CATEGORY):
		out.append(TerrainDB.DEFAULT_CATEGORY)
	return out

func _on_new_category() -> void:
	EditorUI.text_prompt(self, "新建分类名", "", func(nm: String):
		if nm == "" or nm == TerrainDB.DEFAULT_CATEGORY:
			_set_msg("分类名不能为空/「%s」" % TerrainDB.DEFAULT_CATEGORY, false); return
		var cats: Array = TerrainDB.categories()
		if cats.has(nm):
			_set_msg("分类「%s」已存在" % nm, false); return
		cats.append(nm)
		TerrainDB.set_categories(cats)
		if not TerrainDB.save():
			cats.erase(nm)
			TerrainDB.set_categories(cats)
			_set_msg("新建分类写盘失败", false); return
		_fold_cat[nm] = false
		_rebuild()
		_set_msg("已新建分类「%s」——往里「＋新建地块」，或选中条目「📁 移到分类」搬进来" % nm, true))

# 「＋新建地块」弹窗：起名 + 键(组/变体 id) + 归类 + 适用图 + 放置物 + 本/辅色。
# 通行/tag/效果等数据细调走地图编辑器·地形数据面板（单一编辑口，不在工坊复刻表单）。
func _on_new_entry() -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "新建地块"
	dlg.ok_button_text = "创建"
	dlg.get_cancel_button().text = "取消"
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	var cur = _entry_by_key(_sel_key)
	var name_e := LineEdit.new()
	name_e.custom_minimum_size = Vector2(260, 0)
	name_e.placeholder_text = "如 焦土 / 断墙"
	vb.add_child(EditorUI.field_row("显示名", name_e, 90))
	var terr_e := LineEdit.new()
	terr_e.placeholder_text = "组 id，如 bt"
	vb.add_child(EditorUI.field_row("组 id", terr_e, 90))
	var vari_e := LineEdit.new()
	vari_e.placeholder_text = "变体 id，如 scorched"
	vb.add_child(EditorUI.field_row("变体 id", vari_e, 90))
	var hint := Label.new()
	hint.text = "条目键＝组_变体（小写字母/数字/下划线），全库唯一；战斗自绘系沿用组 id「bt」"
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.65, 0.7, 0.78))
	vb.add_child(hint)
	var cat_pairs := []
	for c in _all_category_names():
		cat_pairs.append([str(c)])
	var def_cat := TerrainDB.category_of(cur) if cur != null else TerrainDB.DEFAULT_CATEGORY
	var cat_ob := EditorUI.dropdown(cat_pairs, def_cat)
	vb.add_child(EditorUI.field_row("分类", cat_ob, 90))
	var scope_ob := EditorUI.dropdown([["battle", "战斗"], ["overworld", "大地图"], ["both", "通用"]], "battle")
	vb.add_child(EditorUI.field_row("适用图", scope_ob, 90))
	var obj_cb := CheckBox.new()
	obj_cb.text = "放置物（画在放置物层、界外可画、压过底地形）"
	vb.add_child(obj_cb)
	var c1 := ColorPickerButton.new()
	c1.custom_minimum_size = Vector2(90, 0)
	c1.color = Color.html(str(cur.get("color", "#6b7d5e"))) if cur != null else Color("#6b7d5e")
	vb.add_child(EditorUI.field_row("本色", c1, 90))
	var c2 := ColorPickerButton.new()
	c2.custom_minimum_size = Vector2(90, 0)
	c2.color = Color.html(str(cur.get("accent", "#93a878"))) if cur != null else Color("#93a878")
	vb.add_child(EditorUI.field_row("辅色", c2, 90))
	dlg.add_child(vb)
	dlg.register_text_enter(name_e)
	dlg.confirmed.connect(func():
		var cat_m = cat_ob.get_item_metadata(cat_ob.selected) if cat_ob.selected >= 0 else null
		var scope_m = scope_ob.get_item_metadata(scope_ob.selected) if scope_ob.selected >= 0 else null
		_create_entry(name_e.text, terr_e.text, vari_e.text,
			str(cat_m) if cat_m != null else TerrainDB.DEFAULT_CATEGORY,
			str(scope_m) if scope_m != null else "battle",
			obj_cb.button_pressed, c1.color, c2.color))
	dlg.visibility_changed.connect(func():
		if not dlg.visible:
			dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered(Vector2i(520, 0))
	name_e.grab_focus()

func _create_entry(lbl: String, t: String, v: String, cat: String, scope: String, is_obj: bool, c1: Color, c2: Color) -> void:
	lbl = lbl.strip_edges()
	t = t.strip_edges().to_lower()
	v = v.strip_edges().to_lower()
	if lbl == "":
		_set_msg("新建地块：显示名不能为空", false); return
	if not t.is_valid_ascii_identifier() or not v.is_valid_ascii_identifier():
		_set_msg("新建地块：组/变体 id 须为小写字母/数字/下划线（如 bt / scorched）", false); return
	var entry := {
		"label": lbl, "terrain": t, "variant": v,
		"color": "#" + c1.to_html(false), "accent": "#" + c2.to_html(false),
		"decor": "none", "tags": ["ground"],
		"move": {"cost": 1, "passable_by": "all"}, "effects": [],
	}
	if scope != "both":
		entry["scope"] = scope
	if cat != "" and cat != TerrainDB.DEFAULT_CATEGORY:
		entry["category"] = cat
	if is_obj:
		entry["is_object"] = true
	if not TerrainDB.add_entry(entry):
		_set_msg("新建失败：条目 %s_%s 已存在（换个 id）" % [t, v], false); return
	if not TerrainDB.save():
		TerrainDB.delete_entry({"terrain": t, "variant": v})   # 写盘失败→回滚内存表
		_set_msg("新建失败（terrains.json 写盘）", false); return
	_sel_key = "%s_%s" % [t, v]
	_sel_idx = -1
	_fold_cat[cat if cat != "" else TerrainDB.DEFAULT_CATEGORY] = false
	_rebuild()
	_set_msg("已新建「%s」（%s_%s）——点 ✎ 开画；通行/效果等数据在地图编辑器·地形数据里细调" % [lbl, t, v], true)

# 以任意已有地块的手绘变体为底稿，画进**当前所选条目**的新变体（跨条目版「复制为新变体」）。
func _pick_base_dialog() -> void:
	var target = _entry_by_key(_sel_key)
	if target == null:
		_set_msg("先在左栏选一个地形（底稿会画进它的新变体）", false); return
	var pop := PopupPanel.new()
	add_child(pop)
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(720, 560)
	v.add_theme_constant_override("separation", 6)
	pop.add_child(v)
	var t := Label.new()
	t.text = "选底稿：点任意手绘变体 → 以它为底稿给「%s」画新变体（尺寸不符自动缩放到目标画布）" % str(target.get("label", "?"))
	v.add_child(t)
	var search := LineEdit.new()
	search.placeholder_text = "🔍 过滤地形（名称 / id）"
	search.clear_button_enabled = true
	v.add_child(search)
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(list)
	v.add_child(sc)
	var refill := func():
		for c in list.get_children():
			c.queue_free()
		var q := search.text.strip_edges().to_lower()
		for e in TerrainDB.palette():
			var art := TerrainDB.art_of(e)
			if art.is_empty():
				continue   # 只列有手绘的（程序兜底没有底稿可言）
			var hay := ("%s %s %s" % [str(e.get("label", "")), str(e.get("terrain", "")), str(e.get("variant", ""))]).to_lower()
			if q != "" and hay.find(q) < 0:
				continue
			var row := HBoxContainer.new()
			var lb := Label.new()
			lb.text = str(e.get("label", "?"))
			lb.custom_minimum_size = Vector2(150, 0)
			lb.clip_text = true
			row.add_child(lb)
			var flow := HFlowContainer.new()
			flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			for i in art.size():
				var p := str(art[i])
				var b := Button.new()
				b.custom_minimum_size = Vector2(TILE, TILE)
				b.focus_mode = Control.FOCUS_NONE
				b.tooltip_text = "%s · 变体 %d" % [str(e.get("label", "?")), i]
				var tr := TextureRect.new()
				tr.texture = TextureCache.get_tex_file(p)
				tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
				tr.set_anchors_preset(Control.PRESET_FULL_RECT)
				tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
				b.add_child(tr)
				var src_label := str(e.get("label", "?"))
				b.pressed.connect(func():
					var tex := TextureCache.get_tex_file(p)
					if tex == null:
						_set_msg("底稿读取失败：%s" % p, false); return
					pop.queue_free()
					_open_draw(target, -1, tex.get_image())
					_set_msg("以「%s」变体 #%d 为底稿新建（保存为「%s」的新变体）" % [src_label, i, str(target.get("label", "?"))], true))
				flow.add_child(b)
			row.add_child(flow)
			list.add_child(row)
	refill.call()
	search.text_changed.connect(func(_t2): refill.call())
	var cancel := Button.new()
	cancel.text = "取消"
	cancel.pressed.connect(func(): pop.queue_free())
	v.add_child(cancel)
	pop.popup_centered(Vector2i(740, 600))

func _rename_entry() -> void:
	var e = _entry_by_key(_sel_key)
	if e == null:
		return
	EditorUI.text_prompt(self, "条目改名", str(e.get("label", "")), func(nm: String):
		if nm == "":
			return
		TerrainDB.set_label({"terrain": e.get("terrain"), "variant": e.get("variant")}, nm)
		if not TerrainDB.save():
			_set_msg("改名写盘失败", false); return
		_rebuild()
		_set_msg("已改名 →「%s」" % nm, true))

func _move_entry_category(cat: String) -> void:
	var e = _entry_by_key(_sel_key)
	if e == null:
		return
	TerrainDB.set_category({"terrain": e.get("terrain"), "variant": e.get("variant")}, cat)
	if not TerrainDB.save():
		_set_msg("移分类写盘失败", false); return
	_fold_cat[cat] = false
	_rebuild()
	_set_msg("「%s」→ 分类「%s」" % [str(e.get("label", "?")), cat], true)

func _delete_entry_sel() -> void:
	var e = _entry_by_key(_sel_key)
	if e == null:
		return
	EditorUI.confirm(self, "彻底删除条目「%s」？\n从 terrains.json 整条移除（已画 PNG 保留在 icons/Tiles/ 不删；地图上画过该地形的格会失效显示品红）。" % str(e.get("label", "?")),
		"删除", func():
			var backup: Dictionary = e
			TerrainDB.delete_entry({"terrain": e.get("terrain"), "variant": e.get("variant")})
			if not TerrainDB.save():
				TerrainDB.add_entry(backup)   # 写盘失败→回滚内存表
				_set_msg("删除写盘失败", false); return
			_sel_key = ""
			_sel_idx = 0
			_rebuild()
			_set_msg("已删除条目「%s」（PNG 未删）" % str(e.get("label", "?")), true),
		Callable(), "删除条目")

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
