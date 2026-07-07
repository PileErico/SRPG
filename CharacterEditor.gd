extends Control
## 角色编辑器：创作单位预设（内置原型），写回 res://data/unit_prototypes.json。
## 入口 StartMenu →「角色编辑器」；地图编辑器落子 / 沙盒 / 事件 spawn_unit 都读同一份（UnitFactory.all_prototypes）。
##
## 界面＝**真·角色状态页照搬**（复用 UnitStatusPanel 的 editor_mode）：
##   · 右侧一张**可编辑角色状态卡**——头像点选、四维直接填、姓名/等级/特性、装备槽点选（按槽筛物品）、背包（暂不入档）；
##     其余属性面板＝派生结果只读实时刷新（左改右看在卡内：四维在左、派生在右）。
##   · 卡上方一条**身份/标签条**（角色卡不显示的编辑器元数据）：id / 默认阵营 / 精英 elite / 种族 / 其他标签 / 敌方 AI。
## 编辑对象＝活的 scratch Unit（表单/卡直接改它）→ 保存时 UnitFactory.unit_to_proto(u) 落盘（复用单一序列化口）。

const UnitFactory := preload("res://UnitFactory.gd")
const UnitStatusPanel := preload("res://UnitStatusPanel.gd")   # 复用真·角色状态页（editor_mode 可编辑）
const TagDB := preload("res://TagDB.gd")
const ItemDB := preload("res://ItemDB.gd")
const EquipSlots := preload("res://EquipSlots.gd")             # 槽位资格（装备选择器按槽筛物品）
const FactionDB := preload("res://FactionDB.gd")              # 派系单一数据源（派系下拉）
const TextureCache := preload("res://TextureCache.gd")        # 棋子图标缩略图
const EditorTheme := preload("res://EditorTheme.gd")
const EditorUI := preload("res://EditorUI.gd")
const RaceDB := preload("res://RaceDB.gd")                    # 种族底值（种族下拉同时驱动 race_id+底值，🔒 属性重做 §3）
const Unit := preload("res://Unit.gd")                        # 换种族先重置引擎基线（防旧种族键残留）

const FACTIONS := ["player", "ally", "enemy", "neutral"]
const MANAGED_CATS := ["faction", "race", "biotype", "camp"]   # 有专属下拉（阵营/种族/生物类型/派系）→ 从「其他标签」排除
const MOVEMENT_ALL := ["ground", "spectral", "flying"] # 移动型（判断单位有无移动型；ground 默认、flying 运行时）
const RUNTIME_TAGS := ["flying", "deaths_door", "injured", "dead"]   # 运行时/战斗态，绝不入预设
# 描述物品/技能/地块，永不属于单位（仿 ItemEditor.NON_ITEM_CATS）→ 自由标签选择器全排除，只留 unit 能用的
const NON_UNIT_CATS := ["terrain", "rarity", "wtype", "wcat_melee", "wcat_ranged",
	"wcat_catalyst", "wcat_shield", "handedness", "gear_type", "armor_weight",
	"weapon_attr", "skill_type", "target", "damage", "effect", "effect_dim"]
const PORTRAIT_DIR := "res://icons/Characters"
const ICON_DIR := "res://icons/Unit_Icons"

# —— 状态 ——
var _unit                    # 当前编辑的活 scratch Unit
var _is_new := false
var _loaded_id := ""
var _dirty := false
var _free_tags: Array = []   # 自由标签（char_* + 自定义）
var _bag: Array = []         # 背包内容（8 格，"" = 空；仅编辑器显示，不入档）
# —— 外观组（成对绑定：一套外观 = 一张立绘 + 一个棋子；编辑器侧状态，经 proto 出入，不入 Unit）——
# 每条 = {id, name, portrait, icon}。顶层 proto.portrait/icon 镜像「默认外观」→ 现有消费方零改动。
# 引用/条件切换是后续步骤；本步只管在编辑器里增删/命名/管理多套。
var _appearances: Array = []   # [{id,name,portrait,icon}]（至少 1 条）
var _default_appear := ""      # 默认外观 id（无条件时用它；镜像到顶层 portrait/icon）
var _editing_appear := ""      # 当前在卡上预览/编辑的外观 id（UI 态，可 ≠ 默认）

# —— 控件 ——
# 左侧原型清单：按阵营分折叠组 + 行卡片（棋子图标+名字〔阵营色〕/ id）+ 选中金框（仿物品编辑器）
var _list_scroll: ScrollContainer
var _list_root: VBoxContainer
var _rows: Dictionary = {}            # id -> 行 Button（选中高亮 / 滚动定位）
var _selected_id := ""
var _fac_collapsed: Dictionary = {}   # 阵营 -> 折叠态（跨刷新保留）
var _search: LineEdit
var _msg: Label
var _save_btn: Button
var _dup_btn: Button
var _del_btn: Button
var _strip: VBoxContainer
var _panel                   # UnitStatusPanel 实例
var _free_box: HBoxContainer
var _file_dialog: FileDialog

var _f_id: LineEdit
var _f_faction: OptionButton        # 阵营立场（默认；关卡可改）
var _f_home_faction: OptionButton   # 派系归属（FactionDB）
var _f_race: OptionButton
var _f_biotype: OptionButton
var _f_elite: CheckBox
var _icon_thumb: TextureRect
var _icon_edit: LineEdit
var _file_target := ""              # 文件对话框回填目标："portrait" | "icon"
var _appear_row: HBoxContainer      # 外观 chip 行
var _appear_id_edit: LineEdit       # 选中外观的 id（引用条件用；焦点离开/回车提交）
var _appear_name_edit: LineEdit     # 选中外观的显示名（即时）


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = EditorTheme.build()
	add_child(EditorUI.background())

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 20
	root.offset_top = 14
	root.offset_right = -20
	root.offset_bottom = -14
	root.add_theme_constant_override("separation", 10)
	add_child(root)

	var titlebar := HBoxContainer.new()
	titlebar.add_theme_constant_override("separation", 12)
	var title := Label.new()
	title.text = "角色编辑器"
	title.add_theme_font_size_override("font_size", 26)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titlebar.add_child(title)
	var back := Button.new()
	back.text = "返回主菜单"
	back.custom_minimum_size = Vector2(120, 0)
	back.pressed.connect(func(): _confirm_discard(func(): get_tree().change_scene_to_file("res://StartMenu.tscn")))
	titlebar.add_child(back)
	root.add_child(titlebar)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.split_offset = 260
	root.add_child(split)
	split.add_child(_build_left_pane())

	# 右侧：身份/标签条（上） + 可编辑角色状态卡（下，填满）
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 8)
	split.add_child(right)

	_strip = VBoxContainer.new()
	_strip.add_theme_constant_override("separation", 4)
	right.add_child(EditorUI.panelize(_strip))

	# 角色卡固定尺寸（CARD_SIZE），不随窗口拉伸；套 ScrollContainer 兜住窗口偏小时的溢出。
	var panel_scroll := ScrollContainer.new()
	panel_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(panel_scroll)
	_panel = UnitStatusPanel.new()
	_panel.editor_mode = true
	_panel.custom_minimum_size = UnitStatusPanel.CARD_SIZE   # 钉死卡片尺寸
	_panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN  # 不被 ScrollContainer 拉伸
	_panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_panel.on_portrait_pick = _on_portrait_pick
	_panel.on_equip_slot = _on_equip_slot
	_panel.on_bag_slot = _on_bag_slot
	_panel.on_edit = _on_panel_edit
	panel_scroll.add_child(_panel)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 12)
	_msg = Label.new()
	_msg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_msg.add_theme_color_override("font_color", Color(0.72, 0.78, 0.86))
	bottom.add_child(_msg)
	_dup_btn = Button.new()
	_dup_btn.text = "另存副本"
	_dup_btn.custom_minimum_size = Vector2(110, 38)
	_dup_btn.disabled = true
	_dup_btn.pressed.connect(_on_duplicate)
	bottom.add_child(_dup_btn)
	_save_btn = Button.new()
	_save_btn.text = "保存 ⤓ (Ctrl+S)"
	_save_btn.custom_minimum_size = Vector2(150, 38)
	_save_btn.disabled = true
	_save_btn.pressed.connect(_on_save)
	bottom.add_child(_save_btn)
	root.add_child(bottom)

	_refresh_list()
	_show_empty()


func _build_left_pane() -> Control:
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(240, 0)
	box.add_theme_constant_override("separation", 8)
	var newb := Button.new()
	newb.text = "＋ 新建角色"
	newb.pressed.connect(_new_unit)
	box.add_child(newb)
	_search = LineEdit.new()
	_search.placeholder_text = "🔍 搜 id / 名字"
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_t): _refresh_list())
	box.add_child(_search)
	_list_scroll = ScrollContainer.new()
	_list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_list_root = VBoxContainer.new()
	_list_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_root.add_theme_constant_override("separation", 4)
	_list_scroll.add_child(_list_root)
	box.add_child(_list_scroll)
	_del_btn = Button.new()
	_del_btn.text = "删除选中"
	_del_btn.disabled = true
	_del_btn.pressed.connect(_on_delete)
	box.add_child(_del_btn)
	return box


# 原型清单：按阵营分折叠组（我方/友方/敌方/中立 + 其它）+ 组内按名字排序 + 行卡片（图标+名字/id）。
func _refresh_list() -> void:
	if _list_root == null or not is_instance_valid(_list_root):
		return
	for c in _list_root.get_children():
		c.queue_free()
	_rows = {}
	var q := (_search.text.strip_edges().to_lower() if _search != null else "")
	var searching := q != ""
	var protos := UnitFactory.all_prototypes()
	var by_fac := {}      # faction -> [proto]
	var order := []       # 阵营出现顺序（FACTIONS 优先，其余 append）
	for f in FACTIONS:
		by_fac[f] = []
		order.append(f)
	for p in protos:
		var id := str(p.get("id", ""))
		var nm := str(p.get("name", id))
		if searching and not (id.to_lower().contains(q) or nm.to_lower().contains(q)):
			continue
		var fac := str(p.get("default_faction", "neutral"))
		if not by_fac.has(fac):
			by_fac[fac] = []
			order.append(fac)
		by_fac[fac].append(p)
	for fac in order:
		var arr: Array = by_fac[fac]
		if arr.is_empty():
			continue
		arr.sort_custom(func(a, b): return str(a.get("name", "")) < str(b.get("name", "")))
		var section := VBoxContainer.new()
		section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		section.add_theme_constant_override("separation", 2)
		for p in arr:
			var id := str(p.get("id", ""))
			var row := _make_unit_row(p, fac)
			section.add_child(row)
			_rows[id] = row
		var collapsed := false if searching else bool(_fac_collapsed.get(fac, false))
		var fold := EditorUI.make_foldable("%s (%d)" % [TagDB.cn(fac), arr.size()], section, collapsed, false,
			func(open): _fac_collapsed[fac] = not open)
		_list_root.add_child(fold)
	if _selected_id != "" and _rows.has(_selected_id):
		_apply_row_selected(_rows[_selected_id], true)


# 一行原型卡片：立绘缩略（无则退棋子图标/淡显）+ 名字（阵营色）/ id（小灰）。
func _make_unit_row(proto: Dictionary, fac: String) -> Button:
	var id := str(proto.get("id", ""))
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 54)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.clip_contents = true
	b.pressed.connect(func(): _on_row_click(id))
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 6)
	margin.add_theme_constant_override("margin_right", 6)
	var hb := HBoxContainer.new()
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_theme_constant_override("separation", 8)
	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(42, 48)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# 优先立绘（大图更直观；棋子图标常抽象）→ 退棋子图标 → 淡显占位
	var tex = TextureCache.get_tex(str(proto.get("portrait", "")))
	if tex == null:
		tex = TextureCache.get_tex(str(proto.get("icon", "")))
	if tex != null:
		icon.texture = tex
	else:
		icon.modulate = Color(1, 1, 1, 0.2)
	hb.add_child(icon)
	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	vb.add_theme_constant_override("separation", 0)
	var nm := Label.new()
	nm.text = str(proto.get("name", id))
	var hex := TagDB.color(fac)
	if hex != "":
		nm.add_theme_color_override("font_color", Color(hex))
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	nm.clip_text = true
	vb.add_child(nm)
	var idl := Label.new()
	idl.text = id
	idl.add_theme_color_override("font_color", Color(0.55, 0.58, 0.64))
	idl.add_theme_font_size_override("font_size", 10)
	idl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	idl.clip_text = true
	vb.add_child(idl)
	hb.add_child(vb)
	margin.add_child(hb)
	b.add_child(margin)
	_apply_row_selected(b, id == _selected_id)
	return b

# 行选中/非选中样式（选中＝金框亮底；非选中＝中性深底 + 悬停微亮）——仿物品编辑器。
func _apply_row_selected(b: Button, selected: bool) -> void:
	if b == null or not is_instance_valid(b):
		return
	if selected:
		var sel := EditorTheme.sb(Color(0.26, 0.30, 0.36), Color(1.0, 0.82, 0.30))
		sel.set_border_width_all(2)
		for s in ["normal", "hover", "pressed", "focus"]:
			b.add_theme_stylebox_override(s, sel)
	else:
		b.add_theme_stylebox_override("normal", EditorTheme.sb(Color(0.16, 0.17, 0.20), Color(0, 0, 0, 0)))
		b.add_theme_stylebox_override("hover", EditorTheme.sb(Color(0.22, 0.24, 0.28), Color(0, 0, 0, 0)))
		b.add_theme_stylebox_override("pressed", EditorTheme.sb(Color(0.24, 0.27, 0.32), Color(0, 0, 0, 0)))
		b.add_theme_stylebox_override("focus", EditorTheme.sb(Color(0.16, 0.17, 0.20), Color(0, 0, 0, 0)))

# 点行：已在编辑它＝忽略；否则守卫后加载（取消丢弃＝旧高亮原地保留）。
func _on_row_click(id: String) -> void:
	if id == _selected_id and not _is_new:
		return
	_confirm_discard(_load_proto.bind(id))

# 移动选中高亮到某 id（""＝清空），并滚动到可见。
func _select_row(id: String) -> void:
	if _selected_id != id and _rows.has(_selected_id):
		_apply_row_selected(_rows[_selected_id], false)
	_selected_id = id
	if id != "" and _rows.has(id):
		_apply_row_selected(_rows[id], true)
		if _list_scroll != null and is_instance_valid(_list_scroll):
			_list_scroll.ensure_control_visible(_rows[id])


# —— 新建 / 载入 / 副本 ——

func _new_unit() -> void:
	_confirm_discard(_do_new_unit)

func _do_new_unit() -> void:
	_open_proto(_skeleton(), true)
	_select_row("")
	_info("新建角色——填好 id（唯一）后点保存")

func _skeleton() -> Dictionary:
	return {"id": "", "name": "新单位", "default_faction": "enemy",
		"tags": ["human"], "race": "human", "level": 1}

func _load_proto(id: String) -> void:
	var p := UnitFactory.get_prototype(id)
	if p.is_empty():
		return
	_open_proto(p.duplicate(true), false)
	_select_row(id)
	_info("编辑「%s」" % str(p.get("name", id)))

func _on_duplicate() -> void:
	if _unit == null:
		return
	var proto := _collect_proto()
	proto["id"] = _unique_id(str(proto.get("id", "unit")))
	proto["name"] = str(proto.get("name", "")) + "（副本）"
	_open_proto(proto, true)
	_select_row("")
	_dirty = true
	_info("已生成副本「%s」——改好后保存" % str(proto["id"]))

func _unique_id(base: String) -> String:
	var cand := base + "_copy"
	var i := 2
	while not UnitFactory.get_prototype(cand).is_empty():
		cand = "%s_copy%d" % [base, i]
		i += 1
	return cand

func _open_proto(proto: Dictionary, is_new: bool) -> void:
	_unit = UnitFactory.make_unit(proto, str(proto.get("default_faction", "enemy")), 0, 0)
	_unit.proto_id = str(proto.get("id", ""))
	_is_new = is_new
	_loaded_id = "" if is_new else str(proto.get("id", ""))
	_bag = ["", "", "", "", "", "", "", ""]   # 背包每次载入清空（不入档）
	_init_appearances(proto)                  # 外观组：从 proto 载入（缺省=旧 portrait/icon 合成一条 base）
	_build_strip()
	_rebuild_panel()
	_dirty = false
	_update_buttons()


# —— 身份/标签条（角色卡不显示的编辑器元数据）——

func _show_empty() -> void:
	_unit = null
	_select_row("")
	for c in _strip.get_children():
		c.queue_free()
	var hint := Label.new()
	hint.text = "← 选左侧角色编辑，或点「＋ 新建角色」"
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.72))
	_strip.add_child(hint)
	_update_buttons()

func _build_strip() -> void:
	for c in _strip.get_children():
		c.queue_free()
	if _unit == null:
		return
	# 第一行：id / 默认阵营 / 精英
	var r1 := HBoxContainer.new()
	r1.add_theme_constant_override("separation", 8)
	r1.add_child(_lbl("id"))
	_f_id = LineEdit.new()
	_f_id.text = _unit.proto_id
	_f_id.custom_minimum_size = Vector2(150, 0)
	_f_id.tooltip_text = "唯一主键（字母/数字/下划线）"
	_f_id.text_changed.connect(_on_id_changed)
	r1.add_child(_f_id)
	r1.add_child(_lbl("默认阵营"))
	_f_faction = _dropdown(FACTIONS, _unit.faction, _on_faction_changed)
	r1.add_child(_f_faction)
	_f_elite = CheckBox.new()
	_f_elite.text = "精英 elite"
	_f_elite.tooltip_text = "非我方单位带此 tag 才有死门资格（BattleState 已接）"
	_f_elite.button_pressed = _unit.tags.has("elite")
	_f_elite.toggled.connect(func(_v): _sync_tags())
	r1.add_child(_f_elite)
	_strip.add_child(r1)
	# 第二行：种族 / 生物类型（正交两轴） / 派系归属
	var r2 := HBoxContainer.new()
	r2.add_theme_constant_override("separation", 8)
	r2.add_child(_lbl("种族"))
	_f_race = _cat_dropdown("race", _tag_in_cat("race"), _on_race_changed)
	r2.add_child(_f_race)
	r2.add_child(_lbl("生物类型"))
	_f_biotype = _cat_dropdown("biotype", _tag_in_cat("biotype"), _on_biotype_changed)
	r2.add_child(_f_biotype)
	r2.add_child(_lbl("派系"))
	_f_home_faction = _faction_dropdown(_tag_in_cat("camp"))
	_f_home_faction.tooltip_text = "单位内在派系（camp_* tag；FactionDB 影响声望/敌对）。区别于「默认阵营」立场(本关站哪边)"
	r2.add_child(_f_home_faction)
	_strip.add_child(r2)
	# 外观组：多套「立绘+棋子」成对管理（选中某套 → 卡片立绘 + 下方棋子图标都编辑它）
	_build_appear_ui()
	# 第三行：棋子图标（叠在六边形 token 上的小图；立绘在角色卡头像「＋」处点选）——编辑当前选中外观
	var r3 := HBoxContainer.new()
	r3.add_theme_constant_override("separation", 6)
	r3.add_child(_lbl("棋子图标"))
	_icon_thumb = TextureRect.new()
	_icon_thumb.custom_minimum_size = Vector2(28, 28)
	_icon_thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon_thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon_thumb.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_icon_thumb.texture = TextureCache.get_tex(_unit.icon)
	r3.add_child(_icon_thumb)
	_icon_edit = LineEdit.new()
	_icon_edit.text = _unit.icon
	_icon_edit.placeholder_text = ICON_DIR + "/...png"
	_icon_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_icon_edit.text_changed.connect(_on_icon_text)
	r3.add_child(_icon_edit)
	var icon_browse := Button.new()
	icon_browse.text = "浏览…"
	icon_browse.pressed.connect(func(): _open_file_dialog("icon", ICON_DIR))
	r3.add_child(icon_browse)
	_strip.add_child(r3)
	_build_free_tag_ui()


func _rebuild_panel() -> void:
	if _panel == null:
		return
	_panel.bag_items = _bag
	if _unit != null:
		_panel.open(_unit)


# —— 标签同步（阵营/种族/精英/自由 → _unit.tags；保留移动型）——

func _sync_tags() -> void:
	if _unit == null:
		return
	var tags := [str(_f_faction.get_selected_metadata())]   # 阵营立场
	var race := str(_f_race.get_selected_metadata())
	if race != "" and not tags.has(race):
		tags.append(race)
	var biotype := str(_f_biotype.get_selected_metadata())
	if biotype != "" and not tags.has(biotype):
		tags.append(biotype)
	var camp := str(_f_home_faction.get_selected_metadata())   # 派系归属＝ camp_<id> tag
	if camp != "" and not tags.has(camp):
		tags.append(camp)
	if _f_elite.button_pressed and not tags.has("elite"):
		tags.append("elite")
	for t in _free_tags:                     # 自由标签里可含 spectral（移动型走这条）
		var s := str(t)
		if not tags.has(s) and not RUNTIME_TAGS.has(s):
			tags.append(s)
	# 确保有移动型：自由标签含 spectral/flying 则用它，否则补默认 ground
	var has_move := false
	for t in tags:
		if str(t) in MOVEMENT_ALL:
			has_move = true
			break
	if not has_move:
		tags.append("ground")
	_unit.tags = tags
	_mark_dirty()

func _on_faction_changed() -> void:
	_sync_tags()
	_rebuild_panel()   # 阵营显示在卡片抬头，重建反映

func _on_race_changed() -> void:
	_sync_tags()
	# 种族 tag 同时驱动种族底值 🔒（模块_属性成长_设计.md §3）：tag id 与 races.json id 同词表。
	# 换族＝先重置引擎基线、再叠新种族底值——防旧种族的键在新种族未定义时残留（对抗 review 发现）；
	# 未建档种族 → 仅记 tag、面板回引擎基线（race_id 清空）。
	if _unit != null:
		var race := str(_f_race.get_selected_metadata())
		var fresh = Unit.new()
		for k in fresh.stats:
			_unit.stats[k] = fresh.stats[k]
		_unit.race_id = ""
		if not RaceDB.get_race(race).is_empty():
			RaceDB.apply_to(_unit, race)   # 内部写 race_id
		_unit.init_vitals()
		_rebuild_panel()

func _on_biotype_changed() -> void:
	_sync_tags()

func _on_id_changed(_t := "") -> void:
	if _unit == null: return
	_unit.proto_id = _f_id.text.strip_edges()
	_mark_dirty()

func _on_icon_text(t: String) -> void:
	if _unit == null: return
	_unit.icon = t.strip_edges()
	if _icon_thumb != null and is_instance_valid(_icon_thumb):
		_icon_thumb.texture = TextureCache.get_tex(_unit.icon)
	_writeback_appearance(false)   # 写回当前外观（不逐键重建 chip 行，避免抢焦点）
	_mark_dirty()


# —— 外观组（成对绑定：一套 = 立绘 + 棋子；编辑器侧管理，经 proto 出入）——

# 从 proto 载入外观组；缺省则用顶层 portrait/icon 合成单条 base（旧原型无缝）。
func _init_appearances(proto: Dictionary) -> void:
	_appearances = []
	var raw = proto.get("appearances", [])
	if raw is Array:
		for e in raw:
			if e is Dictionary:
				_appearances.append({
					"id": str(e.get("id", "")), "name": str(e.get("name", "")),
					"portrait": str(e.get("portrait", "")), "icon": str(e.get("icon", "")),
				})
	if _appearances.is_empty():
		_appearances.append({"id": "base", "name": "默认",
			"portrait": _unit.portrait, "icon": _unit.icon})
	_ensure_appear_ids()
	_default_appear = str(proto.get("default_appearance", ""))
	if not _appear_has(_default_appear):
		_default_appear = str(_appearances[0]["id"])
	_editing_appear = _default_appear
	_apply_appearance(_editing_appear)   # 让 _unit.portrait/icon = 编辑对象（卡片/棋子预览它）

# 给缺 id / 重复 id 的条目补唯一 id（防脏数据）。
func _ensure_appear_ids() -> void:
	var seen := {}
	for a in _appearances:
		var id := str(a["id"])
		if id == "" or seen.has(id):
			id = _unique_appear_id("look")
			a["id"] = id
		seen[id] = true

func _appear_index(id: String) -> int:
	for i in _appearances.size():
		if str(_appearances[i]["id"]) == id:
			return i
	return -1

func _appear_has(id: String) -> bool:
	return id != "" and _appear_index(id) >= 0

func _appear_get(id: String):
	var i := _appear_index(id)
	return _appearances[i] if i >= 0 else null

func _unique_appear_id(base: String) -> String:
	var i := 1
	var cand := "%s_%d" % [base, i]
	while _appear_has(cand):
		i += 1
		cand = "%s_%d" % [base, i]
	return cand

# 把某外观的图应用到活 _unit（供卡片/棋子预览）；不动 UI。
func _apply_appearance(id: String) -> void:
	var a = _appear_get(id)
	if a == null or _unit == null:
		return
	_unit.portrait = str(a["portrait"])
	_unit.icon = str(a["icon"])

# 把 _unit 当前 portrait/icon 写回当前编辑外观（图改了就同步进外观组）。
func _writeback_appearance(rebuild_chips: bool) -> void:
	var a = _appear_get(_editing_appear)
	if a == null:
		return
	a["portrait"] = _unit.portrait
	a["icon"] = _unit.icon
	if rebuild_chips:
		_rebuild_appear_row()

func _build_appear_ui() -> void:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	head.add_child(_lbl("外观组"))
	var addb := Button.new()
	addb.text = "＋ 添加外观"
	addb.tooltip_text = "新增一套空白外观（立绘+棋子），选它后再点选图片"
	addb.pressed.connect(_add_appearance)
	head.add_child(addb)
	var defb := Button.new()
	defb.text = "设为默认 ★"
	defb.tooltip_text = "默认外观 = 无触发条件时使用；同步到顶层 portrait/icon，落子/大地图/战斗当前即用它"
	defb.pressed.connect(_set_default_appearance)
	head.add_child(defb)
	var delb := Button.new()
	delb.text = "✕ 删除当前"
	delb.pressed.connect(_remove_appearance)
	head.add_child(delb)
	_strip.add_child(head)

	_appear_row = HBoxContainer.new()
	_appear_row.add_theme_constant_override("separation", 6)
	_strip.add_child(_appear_row)

	var meta := HBoxContainer.new()
	meta.add_theme_constant_override("separation", 6)
	meta.add_child(_lbl("外观 id"))
	_appear_id_edit = LineEdit.new()
	_appear_id_edit.custom_minimum_size = Vector2(110, 0)
	_appear_id_edit.tooltip_text = "外观 id（字母/数字/下划线，唯一）——将来「引用条件」按它指定；回车/移开焦点提交"
	_appear_id_edit.text_submitted.connect(func(_t): _commit_appear_id())
	_appear_id_edit.focus_exited.connect(_commit_appear_id)
	meta.add_child(_appear_id_edit)
	meta.add_child(_lbl("名称"))
	_appear_name_edit = LineEdit.new()
	_appear_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_appear_name_edit.placeholder_text = "显示名（如 常态 / 狼形 / 精英版）"
	_appear_name_edit.text_changed.connect(_on_appear_name_changed)
	meta.add_child(_appear_name_edit)
	_strip.add_child(meta)

	_rebuild_appear_row()
	_sync_appear_meta()

# 重建 chip 行：每套外观一个缩略按钮（立绘→退棋子→淡显占位），选中金框、默认加 ★。
func _rebuild_appear_row() -> void:
	if _appear_row == null or not is_instance_valid(_appear_row):
		return
	for c in _appear_row.get_children():
		c.queue_free()
	for a in _appearances:
		var id := str(a["id"])
		var chip := Button.new()
		chip.custom_minimum_size = Vector2(52, 60)
		chip.clip_contents = true
		chip.tooltip_text = "%s（%s）" % [str(a["name"]), id]
		var tex = TextureCache.get_tex(str(a["portrait"]))
		if tex == null:
			tex = TextureCache.get_tex(str(a["icon"]))
		var tr := TextureRect.new()
		tr.set_anchors_preset(Control.PRESET_FULL_RECT)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if tex != null:
			tr.texture = tex
		else:
			tr.modulate = Color(1, 1, 1, 0.2)
		chip.add_child(tr)
		if id == _default_appear:
			var star := Label.new()
			star.text = "★"
			star.add_theme_color_override("font_color", Color("#EBBC04"))
			star.add_theme_font_size_override("font_size", 12)
			star.mouse_filter = Control.MOUSE_FILTER_IGNORE
			chip.add_child(star)
		var cid := id
		chip.pressed.connect(func(): _select_appearance(cid))
		_apply_row_selected(chip, id == _editing_appear)
		_appear_row.add_child(chip)

# 同步「选中外观」的 id/名称输入框到 UI（程序化设 .text 不触发 text_changed）。
func _sync_appear_meta() -> void:
	var a = _appear_get(_editing_appear)
	if a == null:
		return
	if _appear_id_edit != null and is_instance_valid(_appear_id_edit):
		_appear_id_edit.text = str(a["id"])
	if _appear_name_edit != null and is_instance_valid(_appear_name_edit):
		_appear_name_edit.text = str(a["name"])

# 同步棋子图标缩略/输入框到当前 _unit.icon（切换外观后刷新）。
func _refresh_icon_field() -> void:
	if _icon_thumb != null and is_instance_valid(_icon_thumb):
		_icon_thumb.texture = TextureCache.get_tex(_unit.icon)
	if _icon_edit != null and is_instance_valid(_icon_edit):
		_icon_edit.text = _unit.icon

# 选一套外观 → 成为编辑对象：卡片立绘 + 棋子图标都切到它。
func _select_appearance(id: String) -> void:
	if not _appear_has(id):
		return
	_editing_appear = id
	_apply_appearance(id)
	_rebuild_panel()        # 立绘
	_refresh_icon_field()   # 棋子
	_sync_appear_meta()
	_rebuild_appear_row()

func _add_appearance() -> void:
	if _unit == null:
		return
	var nid := _unique_appear_id("look")
	_appearances.append({"id": nid, "name": "外观%d" % _appearances.size(),
		"portrait": "", "icon": ""})   # 空白：立即看到占位「＋」提示去选图
	_editing_appear = nid
	_apply_appearance(nid)
	_rebuild_panel()
	_refresh_icon_field()
	_sync_appear_meta()
	_rebuild_appear_row()
	_mark_dirty()
	_info("已加外观「%s」——点卡片头像选立绘、下方选棋子；可「设为默认」" % nid)

func _set_default_appearance() -> void:
	if not _appear_has(_editing_appear):
		return
	_default_appear = _editing_appear
	_rebuild_appear_row()
	_mark_dirty()
	_info("默认外观 → 「%s」（游戏内当前用它）" % _default_appear)

func _remove_appearance() -> void:
	if _appearances.size() <= 1:
		_err("至少保留一套外观")
		return
	var idx := _appear_index(_editing_appear)
	if idx < 0:
		return
	var was_default := (_editing_appear == _default_appear)
	_appearances.remove_at(idx)
	if was_default:
		_default_appear = str(_appearances[0]["id"])
	_editing_appear = _default_appear
	_apply_appearance(_editing_appear)
	_rebuild_panel()
	_refresh_icon_field()
	_sync_appear_meta()
	_rebuild_appear_row()
	_mark_dirty()

# 提交外观 id 改名（回车/失焦）：校验字母数字下划线 + 唯一；无效则回退并报错。
func _commit_appear_id() -> void:
	var a = _appear_get(_editing_appear)
	if a == null or _appear_id_edit == null or not is_instance_valid(_appear_id_edit):
		return
	var nid := _appear_id_edit.text.strip_edges()
	var old := str(a["id"])
	if nid == old:
		return
	if not _valid_id(nid):
		_appear_id_edit.text = old
		_err("外观 id 只能用 字母/数字/下划线")
		return
	for other in _appearances:
		if other != a and str(other["id"]) == nid:
			_appear_id_edit.text = old
			_err("外观 id「%s」已重复" % nid)
			return
	a["id"] = nid
	if _default_appear == old:
		_default_appear = nid
	_editing_appear = nid
	_rebuild_appear_row()
	_mark_dirty()

func _on_appear_name_changed(t: String) -> void:
	var a = _appear_get(_editing_appear)
	if a == null:
		return
	a["name"] = t
	_mark_dirty()


# —— 自由标签（char_* / 自定义；仿 ItemEditor）——

func _build_free_tag_ui() -> void:
	_free_tags = []
	for t in _unit.tags:
		var s := str(t)
		# 排除：阵营 / 运行时态 / 默认 ground / 派系 camp_* / 专属下拉管的类（faction·race·biotype·camp）/ 单位状态（elite=勾选、余=运行时）
		if FACTIONS.has(s) or RUNTIME_TAGS.has(s) or s == "ground" or s.begins_with("camp_"):
			continue
		var c := _cat_of(s)
		if c in MANAGED_CATS or c == "unit_status":
			continue
		if not _free_tags.has(s):     # 余下＝char_* / spectral / 自定义
			_free_tags.append(s)
	var adder := HBoxContainer.new()
	adder.add_theme_constant_override("separation", 6)
	adder.add_child(_lbl("其他标签"))
	var pick := OptionButton.new()
	pick.custom_minimum_size = Vector2(160, 0)
	_fill_free_options(pick)
	pick.item_selected.connect(func(idx):
		var tg = pick.get_item_metadata(idx)
		if tg != null and str(tg) != "" and not _free_tags.has(str(tg)):
			_free_tags.append(str(tg))
			_rebuild_free_box()
			_sync_tags()
		pick.select(0))
	adder.add_child(pick)
	var manual := LineEdit.new()
	manual.placeholder_text = "手动 tag（如 char_xxx）"
	manual.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	adder.add_child(manual)
	var addb := Button.new()
	addb.text = "＋"
	addb.pressed.connect(func():
		var tt := manual.text.strip_edges()
		if tt != "" and not _free_tags.has(tt):
			_free_tags.append(tt)
			_rebuild_free_box()
			_sync_tags()
		manual.clear())
	adder.add_child(addb)
	_strip.add_child(adder)
	_free_box = HBoxContainer.new()
	_free_box.add_theme_constant_override("separation", 6)
	_strip.add_child(_free_box)
	_rebuild_free_box()

# 自由标签选择器：**只列单位能用的 tag**（仿物品编辑器排除不可能应用者）——
# 排除：专属下拉管的类(faction/race/biotype) + 单位状态类(elite勾选/余运行时) + 物品/技能/地块类(NON_UNIT_CATS) + 运行时/默认 id。
# 结果只剩 char_*（身份）与 spectral（灵体移动型）。
func _fill_free_options(ob: OptionButton) -> void:
	ob.add_item("（下拉添加…）")
	ob.set_item_metadata(0, "")
	var cats := {}
	var all := TagDB.all()
	for id in all:
		var c := str(all[id].get("cat", "其他"))
		if c in MANAGED_CATS or c == "unit_status" or c in NON_UNIT_CATS:
			continue
		if id in RUNTIME_TAGS or id == "ground" or id.begins_with("camp_"):
			continue
		if not cats.has(c):
			cats[c] = []
		cats[c].append(id)
	for c in cats:
		ob.add_separator(c)
		for id in cats[c]:
			ob.add_item("%s（%s）" % [TagDB.cn(id), id])
			ob.set_item_metadata(ob.item_count - 1, id)

func _rebuild_free_box() -> void:
	if _free_box == null or not is_instance_valid(_free_box):
		return
	for c in _free_box.get_children():
		c.queue_free()
	if _free_tags.is_empty():
		var l := Label.new()
		l.text = "（无）"
		l.add_theme_color_override("font_color", Color(0.55, 0.6, 0.66))
		_free_box.add_child(l)
		return
	for t in _free_tags:
		var chip := Button.new()
		chip.text = "%s ✕" % str(t)
		var tag := str(t)
		chip.pressed.connect(func():
			_free_tags.erase(tag)
			_rebuild_free_box()
			_sync_tags())
		_free_box.add_child(chip)


# —— 角色卡编辑回调（UnitStatusPanel editor_mode）——

func _on_panel_edit() -> void:
	_mark_dirty()   # 卡内改姓名/等级/四维/特性

# 立绘选择（角色卡头像「＋」回调）→ 走通用文件对话框
func _on_portrait_pick() -> void:
	_open_file_dialog("portrait", PORTRAIT_DIR)

# 通用图片文件对话框（portrait=立绘 / icon=棋子图标共用一份）
func _open_file_dialog(target: String, dir: String) -> void:
	_file_target = target
	if _file_dialog == null or not is_instance_valid(_file_dialog):
		_file_dialog = EditorUI.make_file_dialog(FileDialog.FILE_MODE_OPEN_FILE, FileDialog.ACCESS_RESOURCES,
			[["*.png", "PNG"], ["*.jpg,*.jpeg", "JPG"], ["*.webp", "WebP"]], false)
		_file_dialog.file_selected.connect(_on_file_picked)
		add_child(_file_dialog)
	_file_dialog.current_dir = dir
	_file_dialog.popup_centered(Vector2i(760, 520))

func _on_file_picked(path: String) -> void:
	if _unit == null: return
	if _file_target == "icon":
		_unit.icon = path
		if _icon_edit != null and is_instance_valid(_icon_edit):
			_icon_edit.text = path
		if _icon_thumb != null and is_instance_valid(_icon_thumb):
			_icon_thumb.texture = TextureCache.get_tex(path)
	else:
		_unit.portrait = path
		_rebuild_panel()   # 立绘显示在角色卡头像，重建反映
	_writeback_appearance(true)   # 写回当前外观 + 刷新 chip 缩略（离散事件，重建无妨）
	_mark_dirty()

func _on_equip_slot(slot_id: String) -> void:
	if _unit == null: return
	var ids := []
	for id in ItemDB.all().keys():
		var it = ItemDB.all()[id]
		if EquipSlots.accepts(slot_id, it) and _unit.can_equip(it):
			ids.append(id)
	var occupied: bool = _unit.equipment.has(slot_id)
	_open_item_picker("装备到「%s」" % EquipSlots.SLOT_CN.get(slot_id, slot_id), ids, occupied,
		func(picked: String):
			if picked == "":
				_unit.unequip(slot_id)
			elif not _unit.equip(picked, slot_id):
				_err("装不上（requires 未满足 / 天性武者禁外来武器 / 天生武器占槽）")
				return
			_mark_dirty()
			_rebuild_panel())

func _on_bag_slot(idx: int) -> void:
	if _unit == null or idx < 0 or idx >= _bag.size(): return
	var ids := ItemDB.all().keys()   # 背包＝任意物品
	var occupied := str(_bag[idx]) != ""
	_open_item_picker("放入背包（暂不入档）", ids, occupied,
		func(picked: String):
			_bag[idx] = picked   # picked=="" 即清空
			_rebuild_panel())    # 背包不入档 → 不标脏


# —— 物品选择器（PopupPanel；allow_clear=显示「清空该槽」）——

func _open_item_picker(title: String, ids: Array, allow_clear: bool, on_pick: Callable) -> void:
	var pop := PopupPanel.new()
	add_child(pop)
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(360, 440)
	v.add_theme_constant_override("separation", 6)
	pop.add_child(v)
	var t := Label.new()
	t.text = title
	t.add_theme_color_override("font_color", Color("#EBBC04"))
	v.add_child(t)
	if allow_clear:
		var cb := Button.new()
		cb.text = "✕ 清空该槽"
		cb.pressed.connect(func():
			on_pick.call("")
			pop.queue_free())
		v.add_child(cb)
	var list := ItemList.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var arr: Array = []
	for id in ids:
		var it = ItemDB.get_item(str(id))
		if it == null:
			continue
		list.add_item("%s（%s）" % [str(it.get("name", id)), str(id)])
		var hex := _rarity_hex(it)
		if hex != "":
			list.set_item_custom_fg_color(list.item_count - 1, Color(hex))
		arr.append(str(id))
	if arr.is_empty():
		v.add_child(_lbl("（无可选物品——先在物品编辑器造）"))
	list.item_selected.connect(func(i: int):
		if i >= 0 and i < arr.size():
			on_pick.call(str(arr[i]))
		pop.queue_free())
	v.add_child(list)
	var cancel := Button.new()
	cancel.text = "取消"
	cancel.pressed.connect(func(): pop.queue_free())
	v.add_child(cancel)
	pop.popup_centered(Vector2i(400, 480))


# —— 保存 / 删除 ——

func _collect_proto() -> Dictionary:
	var proto := UnitFactory.unit_to_proto(_unit)   # _unit 已持全部编辑态（含 tags/AI）；工厂单一序列化口
	# 外观组：编辑器侧状态挂回 proto（Unit/Factory 不参与）。
	# 只在 >1 套时写 appearances/default_appearance——单套即旧格式（顶层 portrait/icon 已由 _unit 携带），零 diff 噪音。
	if _appearances.size() > 1:
		var d = _appear_get(_default_appear)
		if d == null:
			d = _appearances[0]
		proto["portrait"] = str(d["portrait"])   # 顶层镜像默认外观 → 落子/大地图/战斗渲染即用它
		proto["icon"] = str(d["icon"])
		proto["default_appearance"] = str(d["id"])
		var out := []
		for a in _appearances:
			out.append({"id": str(a["id"]), "name": str(a["name"]),
				"portrait": str(a["portrait"]), "icon": str(a["icon"])})
		proto["appearances"] = out
	return proto

func _on_save() -> void:
	if _unit == null:
		return
	var proto := _collect_proto()
	var id := str(proto.get("id", ""))
	if id == "":
		_err("id 不能为空")
		return
	if not _valid_id(id):
		_err("id 只能用 字母/数字/下划线（现为「%s」）" % id)
		return
	var renaming := (not _is_new) and _loaded_id != "" and id != _loaded_id
	if (_is_new or renaming) and not UnitFactory.get_prototype(id).is_empty():
		_err("id「%s」已存在，请换一个" % id)
		return
	if not UnitFactory.save_prototype(proto, _loaded_id if renaming else ""):
		_err("保存失败（文件被占用/只读？）")
		return
	if renaming:
		_info("✓ 已保存并改 id：%s → %s（引用旧 id 的地图/事件需同步）" % [_loaded_id, id])
	else:
		_info("✓ 已保存原型「%s」→ data/unit_prototypes.json" % str(proto.get("name", id)))
	_is_new = false
	_loaded_id = id
	_dirty = false
	_refresh_list()
	_select_row(id)
	_update_buttons()

func _on_delete() -> void:
	if _is_new or _loaded_id == "":
		return
	var id := _loaded_id
	EditorUI.confirm(self, "确认删除原型「%s」(%s)？此操作直接写盘。" % [_unit.unit_name, id],
		"删除", func(): _do_delete(id), Callable(), "确认删除")

func _do_delete(id: String) -> void:
	if not UnitFactory.delete_prototype(id):
		_err("删除失败（文件被占用/只读？）")
		return
	_dirty = false
	_loaded_id = ""
	_is_new = false
	_unit = null
	_refresh_list()
	_show_empty()
	if _panel != null and is_instance_valid(_panel):
		for c in _panel.get_children():
			c.queue_free()
	_info("✓ 已删除「%s」" % id)


func _confirm_discard(on_ok: Callable, on_cancel := Callable()) -> void:
	EditorUI.confirm_discard(self, _dirty, on_ok, on_cancel,
		"当前角色有未保存的修改，继续将丢弃。", "丢弃修改", "留下")

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_S and event.ctrl_pressed:
		if _save_btn != null and not _save_btn.disabled:
			_on_save()
		get_viewport().set_input_as_handled()


# —— 小工具 ——

func _lbl(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l

func _dropdown(values: Array, cur: String, on_change: Callable) -> OptionButton:
	var ob := OptionButton.new()
	for i in values.size():
		ob.add_item(TagDB.cn(str(values[i])))
		ob.set_item_metadata(i, str(values[i]))
		if str(values[i]) == cur:
			ob.select(i)
	ob.item_selected.connect(func(_i): on_change.call())
	return ob

func _cat_dropdown(cat: String, cur: String, on_change: Callable) -> OptionButton:
	var ob := OptionButton.new()
	ob.add_item("（无）")
	ob.set_item_metadata(0, "")
	for e in TagDB.by_cat(cat):
		var id := str(e.get("id", ""))
		ob.add_item("%s（%s）" % [str(e.get("cn", id)), id])
		ob.set_item_metadata(ob.item_count - 1, id)
	_select_meta(ob, cur)
	ob.item_selected.connect(func(_i): on_change.call())
	return ob

# 派系下拉（读 FactionDB 单一数据源的派系名册 + 无）→ 设 `camp_<id>` tag（派系归属＝ tag）。
# metadata 存 camp tag id（camp_<factionid>），与 tags.json cat "camp" 对应；_sync_tags 并入 _unit.tags。
func _faction_dropdown(cur_tag: String) -> OptionButton:
	var ob := OptionButton.new()
	ob.add_item("（无归属）")
	ob.set_item_metadata(0, "")
	for e in FactionDB.all_factions():
		var id := str(e.get("id", ""))
		ob.add_item(str(e.get("label", id)))
		ob.set_item_metadata(ob.item_count - 1, "camp_" + id)
	_select_meta(ob, cur_tag)
	ob.item_selected.connect(func(_i): _sync_tags())
	return ob

func _select_meta(ob: OptionButton, key: String) -> void:
	for i in ob.item_count:
		if str(ob.get_item_metadata(i)) == key:
			ob.select(i)
			return
	if ob.item_count > 0:
		ob.select(0)

func _tag_in_cat(cat: String) -> String:
	var ids := TagDB.ids_in_cat(cat)
	for t in _unit.tags:
		if ids.has(str(t)):
			return str(t)
	return ""

func _cat_of(tag: String) -> String:
	var e = TagDB.get_tag(tag)
	return str(e.get("cat", "")) if e != null else ""

func _rarity_hex(item: Dictionary) -> String:
	for t in item.get("tags", []):
		var hex := TagDB.color(str(t))
		if hex != "":
			return hex
	return ""

func _valid_id(id: String) -> bool:
	if id == "":
		return false
	for i in id.length():
		var c := id.unicode_at(i)
		if not ((c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95):
			return false
	return true

func _update_buttons() -> void:
	var has := _unit != null
	if _save_btn: _save_btn.disabled = not has
	if _dup_btn: _dup_btn.disabled = not has or _is_new
	if _del_btn: _del_btn.disabled = not has or _is_new or _loaded_id == ""

func _mark_dirty() -> void:
	_dirty = true

func _info(text: String) -> void:
	if _msg == null: return
	_msg.add_theme_color_override("font_color", Color(0.72, 0.78, 0.86))
	_msg.text = text

func _err(text: String) -> void:
	if _msg == null: return
	_msg.add_theme_color_override("font_color", Color(0.92, 0.5, 0.45))
	_msg.text = "✗ " + text
