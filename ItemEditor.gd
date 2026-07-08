extends Control
## 物品编辑器：创作游戏正式物品（武器 / 防具 / 饰品），写回 res://data/*.json。
## 入口 StartMenu →「物品编辑器」；自包含 procedural 面板。
## tag 设计（用户校准）：槽位非物品 tag、自动派生；类型/种类等用「分类下拉」（读 TagDB.by_cat）。
##  武器：先选【类型】(近战/投掷/远程/触媒/盾，单选互斥) → 类型级联决定【种类】可选项；投掷无种类、盾不显握持。
##  防具：部位(头盔/身甲)+种类(轻/中/重)。其他标签：下拉(选中即加)+手动(确认)。只「天生武器」需勾选。

const ItemDB := preload("res://ItemDB.gd")
const EquipSlots := preload("res://EquipSlots.gd")
const TagDB := preload("res://TagDB.gd")
const TextureCache := preload("res://TextureCache.gd")   # 图标加载 + 缓存单一入口
const ItemTooltip := preload("res://ItemTooltip.gd")     # 物品富 tooltip 通用渲染组件（与角色状态页共用）
const StatMeta := preload("res://StatMeta.gd")           # stat 键→中文单一源（本编辑器不再自带并行对照表）
const EditorTheme := preload("res://EditorTheme.gd")     # 编辑器统一深色主题（与地图编辑器共用）
const EditorUI := preload("res://EditorUI.gd")           # 编辑器公共 UI 控件工厂（分节/字段行/确认框/文件对话框，与地图编辑器共用）

const ICON_DIR := {
	"weapon": "res://icons/Items/Weapons",
	"armor": "res://icons/Items/Armors",
	"accessory": "res://icons/Items/Accessories",
	"item": "res://icons/Items",
}
const DAMAGE_KINDS := ["physical", "fire", "ice", "thunder", "holy"]
const OPS := [["flat", "固定"], ["pct", "百分比%"]]
# 物品大类下拉（基础区，id 上方）：kind 选择器——替掉旧的 4 个「＋类别」按钮
const KIND_PAIRS := [["weapon", "武器"], ["armor", "防具"], ["accessory", "饰品"], ["item", "物品"]]
const USE_TARGETS := [["ally", "友方单位"], ["enemy", "敌对单位"], ["self", "自身"]]   # on_use 作用对象（可使用物品；敌对=投掷类攻击道具）
# on_use 使用效果类型（动态行下拉；键＝on_use 字典键，复用技能效果负载）
const OU_EFFECTS := [["heal_pct_max_hp", "回复生命（最大生命 %）"], ["heal_flat", "回复生命（固定值）"], ["restore_fatigue_pct", "回复疲劳（最大疲劳 %·待疲劳系统）"]]
# 「物品」表单里由勾选管理的结构性 tag（从「其他标签」自由区排除，防取消勾选后残留）
const ITEM_FLAG_TAGS := ["usable", "quest_item"]

# 「自动管理」的 tag 类别（这些 tag 由专门控件管，从「其他标签」自由区排除）
const MANAGED_CATS := ["rarity", "wtype", "wcat_melee", "wcat_ranged", "wcat_catalyst",
	"wcat_shield", "handedness", "gear_type", "armor_weight", "weapon_attr"]

# 自定义 tag 下拉的类别过滤（据「物品前面已填选项」排除无意义项，见 _tag_offered 各 mode）：
const NON_ITEM_CATS := ["faction", "movement", "terrain", "unit_status"]   # 描述单位/世界，永不属于物品 → 全排除
const REQUIRE_CATS := ["char", "race"]                                     # 「装备需求」只给"谁能装"＝身份类
const ATTACK_CATS := ["target", "damage", "skill_type", "effect"]          # 「攻击标签」只给攻击/技能行为类
const CATEGORY_CN := {   # 下拉分隔标题的类别中文（缺省回退原 id）
	"char": "角色", "race": "种族", "target": "目标", "damage": "物理伤害型",
	"skill_type": "技能类型", "effect": "效果",
}

# 🔒 属性重做（docs/模块_属性成长_设计.md §4/§5）：四维/mag/res_status/五元素抗已删；
# 抗性两轨=物理/自然（人/甲分算）；**强韧（will_fort/body_fort）不入物品**——防具/词条只有抗性、永不提供强韧。
# 中文标签一律 StatMeta.label（D2 收敛 2026-07-07：本表只留 分组×键序，不再复挂并行对照表）。
const STAT_GROUPS := [
	["进攻", ["atk", "acc", "crit_rate", "crit_dmg", "atk_eff"]],
	["生存", ["HP_max", "eva", "block_rate", "block_power", "def_eff", "armor_max"]],
	["人抗（减对血量伤害·%）", ["res_phys", "res_nature"]],
	["甲抗（减护甲承伤·防具专属·%）", ["armor_res_phys", "armor_res_nature"]],
	["固定减伤（承伤最后减固定值·非%）", ["dr_flat_armor", "dr_flat_human"]],
	["行动", ["move", "speed", "sight", "AP_max"]],
]

# 视觉状态（非数值 mod）：不进面板/数值管线，经 Unit.has_vision_state 影响视野计算。目前两种。
const VISION_STATES := [
	["nightvision", "黑夜视觉（无视夜间视野减半）"],
	["blind", "无视力（视野 ×0）"],
]

# —— 状态 ——
var _rarities: Array = []
var _managed_tag_set: Dictionary = {}
var _current: Dictionary = {}
var _current_kind: String = ""
var _is_new: bool = false
var _loaded_id: String = ""   # 载入时的 id（改名判定：保存时 id≠此值 → 走 replace_id 换名而非复制）
var _dirty: bool = false      # 有未保存改动（切换/新建/删除前确认；表单任何变化置真、build/save 清零）
var _free_tags: Array = []
var _atk_tags: Array = []
var _requires: Array = []   # 装备需求 tag（装备者须全部具备，如 char_desmond）

# —— 控件 ——
var _list_scroll: ScrollContainer         # 分类清单滚动区
var _list_root: VBoxContainer             # 三大分类折叠组的容器
var _rows: Dictionary = {}                # id -> 物品行 Button（选中高亮 / 滚动定位）
var _selected_id: String = ""            # 当前高亮的物品 id（"" = 无）
var _cat_collapsed: Dictionary = {"weapon": false, "armor": false, "accessory": false, "item": false}   # 各分类折叠态（跨刷新保留）
var _search: LineEdit
# —— 物品（可使用/道具）表单控件 ——
var _w_kind: OptionButton                # 基础区「物品大类」下拉（kind 选择器）
var _w_usable: CheckBox                   # 可使用（=usable tag，门控 on_use 段）
var _w_quest: CheckBox                    # 任务物品（=quest_item tag）
var _ou_box: VBoxContainer               # 使用效果 on_use 段容器（勾「可使用」才显）
var _w_use_target: OptionButton
var _w_use_range: SpinBox                 # 使用距离（格；作用对象=友方时生效）
var _range_row                            # 距离字段行（作用对象=自身时藏）
var _w_stack: CheckBox
var _ou_rows_box: VBoxContainer           # 使用效果行容器（动态·仿武器 mods）
var _ou_rows: Array = []                  # 效果行：[{type:OptionButton, value:SpinBox, row}]
var _msg: Label
var _form: VBoxContainer
var _preview: VBoxContainer
var _save_btn: Button
var _dup_btn: Button
var _del_btn: Button
var _file_dialog: FileDialog
var _icon_thumb: TextureRect

var _w_id: LineEdit
var _w_name: LineEdit
var _w_rarity: OptionButton
var _w_icon: LineEdit
# 武器
var _w_wtype: OptionButton
var _w_wcat: OptionButton
var _wcat_row: Control
var _w_handed: OptionButton
var _handed_row: Control
var _w_innate: CheckBox
var _w_innate_slot: OptionButton
var _innate_slot_row: Control
# 防具
var _w_gear: OptionButton
var _w_weight: OptionButton
# 修正 / 攻击
var _mods_box: VBoxContainer
var _mod_rows: Array = []
var _w_atk_name: LineEdit
var _w_atk_icon: LineEdit
var _w_atk_coeff: SpinBox
var _w_atk_range: SpinBox
var _w_atk_ap: SpinBox
var _w_atk_dmgkind: OptionButton
var _w_has_bas: CheckBox         # 是否含基础攻击技能 BAS（关＝武器不提供基础攻击，如盾）
var _bas_box: VBoxContainer      # BAS 字段容器（随 _w_has_bas 显隐）
var _building: bool = false      # _build_form 进行中（抑制「选盾自动关 BAS」等用户动作专属逻辑）


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = EditorTheme.build()   # 统一深色主题（公共层，与地图编辑器共用）
	add_child(EditorUI.background())   # 深色背景铺满垫底，去引擎默认灰
	_rarities = TagDB.ids_in_cat("rarity")
	if _rarities.is_empty():
		_rarities = ["common", "uncommon", "rare", "epic", "legendary", "special"]
	_build_managed_set()

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
	title.text = "物品编辑器"
	title.add_theme_font_size_override("font_size", 26)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titlebar.add_child(title)
	var back := Button.new()
	back.text = "返回主菜单"
	back.custom_minimum_size = Vector2(120, 0)
	# 返回也走未保存守卫（切换/新建已有，唯独这里漏了会静默丢改动）
	back.pressed.connect(func(): _confirm_discard(func(): get_tree().change_scene_to_file("res://StartMenu.tscn")))
	titlebar.add_child(back)
	root.add_child(titlebar)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.split_offset = 300
	root.add_child(split)
	split.add_child(_build_left_pane())

	var right_split := HSplitContainer.new()
	right_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_split.split_offset = 380
	split.add_child(right_split)

	var right_scroll := ScrollContainer.new()
	right_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_form = VBoxContainer.new()
	_form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_form.add_theme_constant_override("separation", 8)
	right_scroll.add_child(_form)
	right_split.add_child(right_scroll)

	var prev_scroll := ScrollContainer.new()
	prev_scroll.custom_minimum_size = Vector2(230, 0)
	prev_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview = VBoxContainer.new()
	_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview.add_theme_constant_override("separation", 6)
	prev_scroll.add_child(_preview)
	right_split.add_child(prev_scroll)

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
	_dup_btn.tooltip_text = "以当前表单内容复制出一件新物品（id 自动加 _copy）"
	_dup_btn.pressed.connect(_on_duplicate)
	bottom.add_child(_dup_btn)
	_save_btn = Button.new()
	_save_btn.text = "保存 ⤓ (Ctrl+S)"
	_save_btn.custom_minimum_size = Vector2(140, 38)
	_save_btn.disabled = true
	_save_btn.pressed.connect(_on_save)
	bottom.add_child(_save_btn)
	root.add_child(bottom)

	_refresh_list()
	_show_empty_form()


func _build_managed_set() -> void:
	_managed_tag_set = {}
	for cat in MANAGED_CATS:
		for id in TagDB.ids_in_cat(cat):
			_managed_tag_set[id] = true
	for s in ["main_hand", "off_hand"]:
		_managed_tag_set[s] = true


func _build_left_pane() -> Control:
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(300, 0)
	box.add_theme_constant_override("separation", 8)
	var newbtn := Button.new()
	newbtn.text = "＋ 新建（大类在表单里选）"
	newbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	newbtn.pressed.connect(_new_item.bind("weapon"))   # 默认武器；基础区「物品大类」下拉可改成防具/饰品/物品
	box.add_child(newbtn)
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


# 分类清单：三大折叠组（武器/防具/饰品）+ 组内按 类型→种类→名字 排序 + 类型分隔标签。
func _refresh_list() -> void:
	if _list_root == null or not is_instance_valid(_list_root):
		return
	for c in _list_root.get_children():
		c.queue_free()
	_rows = {}
	var q := (_search.text.strip_edges().to_lower() if _search != null else "")
	var searching := q != ""
	var items := ItemDB.all()
	var by_kind := {"weapon": [], "armor": [], "accessory": [], "item": []}
	for id in items.keys():
		var itf = items[id]
		if searching and not (str(id).to_lower().contains(q) or str(itf.get("name", "")).to_lower().contains(q)):
			continue   # 搜索过滤：id / 名字 子串（不分大小写）
		var k := ItemDB.kind_of(itf)
		if by_kind.has(k):
			by_kind[k].append(id)
	for kind in ["weapon", "armor", "accessory", "item"]:
		var ids: Array = by_kind[kind]
		ids.sort_custom(func(a, b): return _sort_key(items[a], kind) < _sort_key(items[b], kind))
		var section := VBoxContainer.new()
		section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		section.add_theme_constant_override("separation", 2)
		var last_div := "￿"
		for id in ids:
			var it = items[id]
			var dk := _type_divider_key(it, kind)
			if dk != "" and dk != last_div:
				section.add_child(_type_divider(dk))   # 类型变化处插分隔（仅标示排序，不可折叠）
			last_div = dk
			var row := _make_item_row(id, it)
			section.add_child(row)
			_rows[id] = row
		if ids.is_empty():
			var hint := Label.new()
			hint.text = "（无匹配）" if searching else "（暂无——点上方「＋新建」、大类选「%s」）" % ItemDB.kind_cn(kind)
			hint.add_theme_color_override("font_color", Color(0.5, 0.54, 0.6))
			hint.add_theme_font_size_override("font_size", 12)
			section.add_child(hint)
		var collapsed := false if searching else bool(_cat_collapsed.get(kind, false))
		var fold := EditorUI.make_foldable("%s (%d)" % [ItemDB.kind_cn(kind), ids.size()], section, collapsed, false,
			func(open): _cat_collapsed[kind] = not open)
		_list_root.add_child(fold)
	if _selected_id != "" and _rows.has(_selected_id):
		_apply_row_selected(_rows[_selected_id], true)


# 组内排序键：类型 rank → 种类 rank → 名字（拼字符串比较，避免 Array 比较不确定性）
func _sort_key(item, kind: String) -> String:
	var nm := str(item.get("name", "")).to_lower()
	match kind:
		"weapon":
			var wt := _tag_in_cat(item.get("tags", []), "wtype")
			var wc := _tag_in_cat(item.get("tags", []), "wcat_" + wt)
			return "%02d|%02d|%s" % [_rank_in_cat(wt, "wtype"), _rank_in_cat(wc, "wcat_" + wt), nm]
		"armor":
			var g := _tag_in_cat(item.get("tags", []), "gear_type")
			var w := _tag_in_cat(item.get("tags", []), "armor_weight")
			return "%02d|%02d|%s" % [_rank_in_cat(g, "gear_type"), _rank_in_cat(w, "armor_weight"), nm]
		_:
			return "00|00|%s" % nm

func _rank_in_cat(tag: String, cat: String) -> int:
	if tag == "":
		return 99
	var idx := TagDB.ids_in_cat(cat).find(tag)
	return idx if idx >= 0 else 98

# 类型分隔 key（武器＝武器类型 / 防具＝部位；饰品不分组＝""）
func _type_divider_key(item, kind: String) -> String:
	match kind:
		"weapon":
			var wt := _tag_in_cat(item.get("tags", []), "wtype")
			return TagDB.cn(wt) if wt != "" else "其他"
		"armor":
			var g := _tag_in_cat(item.get("tags", []), "gear_type")
			return TagDB.cn(g) if g != "" else "其他"
		_:
			return ""

func _type_divider(text: String) -> Control:
	var l := Label.new()
	l.text = "· " + text
	l.add_theme_color_override("font_color", Color(0.5, 0.62, 0.72))
	l.add_theme_font_size_override("font_size", 11)
	return l

# 物品行卡片：图标 + 名字（稀有度色）/ id（灰小字）两行；悬停微亮、选中金框。
func _make_item_row(id: String, item) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 42)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.clip_contents = true
	b.tooltip_text = _row_tooltip(item)
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
	icon.custom_minimum_size = Vector2(32, 32)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var tex = TextureCache.get_tex(str(item.get("icon", "")))
	if tex != null:
		icon.texture = tex
	else:
		icon.modulate = Color(1, 1, 1, 0.2)   # 无图标：占位淡显
	hb.add_child(icon)
	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	vb.add_theme_constant_override("separation", 0)
	var nm := Label.new()
	nm.text = str(item.get("name", id))
	nm.add_theme_color_override("font_color", _rarity_color(_rarity_of(item)))
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
	_apply_row_selected(b, false)
	return b

func _row_tooltip(item) -> String:
	var parts := []
	var rar := _rarity_of(item)
	if rar != "":
		parts.append(TagDB.cn(rar))
	var k := ItemDB.kind_of(item)
	if k == "weapon":
		var wt := _tag_in_cat(item.get("tags", []), "wtype")
		if wt != "":
			parts.append(TagDB.cn(wt))
		var wc := _tag_in_cat(item.get("tags", []), "wcat_" + wt)
		if wc != "":
			parts.append(TagDB.cn(wc))
	elif k == "armor":
		var g := _tag_in_cat(item.get("tags", []), "gear_type")
		if g != "":
			parts.append(TagDB.cn(g))
		var w := _tag_in_cat(item.get("tags", []), "armor_weight")
		if w != "":
			parts.append(TagDB.cn(w))
	return "%s\n%s · slot=%s" % [str(item.get("name", "")), " · ".join(parts), str(item.get("slot", ""))]

# 行选中/非选中样式（选中＝金框亮底；非选中＝中性深底 + 悬停微亮）。
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

# 点击物品行：已在编辑它＝忽略；否则守卫后加载（取消丢弃＝旧高亮原地保留）。
func _on_row_click(id: String) -> void:
	if id == _selected_id:
		return
	_confirm_discard(_load_item.bind(id))

# 移动选中高亮到某 id（""＝清空），并滚动到可见。
func _select_row(id: String) -> void:
	if _selected_id != id and _rows.has(_selected_id):
		_apply_row_selected(_rows[_selected_id], false)
	_selected_id = id
	if id != "" and _rows.has(id):
		_apply_row_selected(_rows[id], true)
		if _list_scroll != null and is_instance_valid(_list_scroll):
			_list_scroll.ensure_control_visible(_rows[id])


func _new_item(kind: String) -> void:
	_confirm_discard(_do_new_item.bind(kind))

func _do_new_item(kind: String) -> void:
	_current = _skeleton(kind)
	_current_kind = kind
	_is_new = true
	_loaded_id = ""
	_select_row("")
	_build_form()
	_save_btn.disabled = false
	_dup_btn.disabled = true
	_del_btn.disabled = true
	_info("新建%s——填好后点保存（id 必须唯一）" % ItemDB.kind_cn(kind))


func _load_item(id: String) -> void:
	var it = ItemDB.get_item(id)
	if it == null:
		return
	_current = it.duplicate(true)
	_current_kind = ItemDB.kind_of(_current)
	_is_new = false
	_loaded_id = id
	_build_form()
	_save_btn.disabled = false
	_dup_btn.disabled = false
	_del_btn.disabled = false
	_info("编辑「%s」" % str(_current.get("name", id)))
	_select_row(id)


# 另存副本：当前表单内容 → 新物品（id 自动唯一化），进「新建未保存」态
func _on_duplicate() -> void:
	if _w_id == null or not is_instance_valid(_w_id):
		return
	var item := _collect()
	item["id"] = _unique_copy_id(str(item.get("id", "item")))
	item["name"] = str(item.get("name", "")) + "（副本）"
	_current = item
	_current_kind = ItemDB.kind_of(item)
	_is_new = true
	_loaded_id = ""
	_select_row("")
	_build_form()
	_dirty = true   # 副本＝未保存的新内容
	_dup_btn.disabled = true
	_del_btn.disabled = true
	_info("已生成副本「%s」——改好后保存" % str(item["id"]))

func _unique_copy_id(base: String) -> String:
	var cand := base + "_copy"
	var i := 2
	while ItemDB.get_item(cand) != null:
		cand = "%s_copy%d" % [base, i]
		i += 1
	return cand


func _show_empty_form() -> void:
	_clear_form()
	_select_row("")
	_w_id = null   # 表单已拆：预览/脏标记按「无表单」走（_clear_form 只 queue_free，引用得手动断）
	var hint := Label.new()
	hint.text = "← 选左侧物品编辑，或点＋新建一件"
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.72))
	_form.add_child(hint)
	_refresh_preview()
	_dirty = false


func _skeleton(kind: String) -> Dictionary:
	match kind:
		"weapon":
			return {"id": "", "name": "新武器", "slot": "main_hand", "icon": "",
				"tags": ["common", "melee", "weapon_sword", "one_handed"], "requires": [], "mods": [],
				"two_handed": false, "innate": false,
				"attack": {"name": "普通攻击", "icon": "", "coeff": 1.0, "range": 1,
					"ap_cost": 1, "damage_kind": "physical", "tags": ["single_target"]}}
		"armor":
			return {"id": "", "name": "新防具", "slot": "body", "icon": "",
				"tags": ["common", "body", "medium_armor"], "requires": [],
				"mods": [{"stat": "armor_max", "op": "flat", "value": 10}]}
		"item":
			return {"id": "", "name": "新物品", "kind": "item", "icon": "",
				"tags": ["common", "usable"], "target": "ally", "range": 1, "stack": true, "on_use": {}}
		_:
			return {"id": "", "name": "新饰品", "slot": "accessory_1", "icon": "",
				"tags": ["common", "accessory"], "requires": [], "mods": []}


func _clear_form() -> void:
	for c in _form.get_children():
		c.queue_free()
	_mod_rows.clear()
	_free_tags = []
	_atk_tags = []
	_requires = []


func _build_form() -> void:
	_clear_form()
	_building = true   # 建表单期间抑制用户动作专属逻辑（选盾自动关 BAS）

	# 1. 基础
	_form.add_child(EditorUI.section_title("基础"))
	_w_kind = OptionButton.new()
	for p in KIND_PAIRS:
		_w_kind.add_item(str(p[1]))
		_w_kind.set_item_metadata(_w_kind.item_count - 1, str(p[0]))
	_select_meta(_w_kind, _current_kind)
	_w_kind.item_selected.connect(func(i): _on_kind_changed(str(_w_kind.get_item_metadata(i))))
	_form.add_child(EditorUI.field_row("物品大类", _w_kind))
	_w_id = _add_line(_form, "id（唯一主键）", str(_current.get("id", "")))
	_w_name = _add_line(_form, "名字", str(_current.get("name", "")))
	_build_icon_row()

	# 物品（非装备类：消耗品/任务物品/素材/食物/医疗物品）——独立表单，无装备槽/mods/BAS
	if _current_kind == "item":
		_build_item_form()
		_building = false
		_refresh_preview()
		_dirty = false
		return

	# 2. 标签
	_form.add_child(EditorUI.section_title("标签"))
	_w_rarity = _cat_dropdown_inline("稀有度", "rarity", false)
	_select_meta(_w_rarity, _rarity_of(_current))
	if _current_kind == "weapon":
		_build_weapon_tags()
	elif _current_kind == "armor":
		_w_gear = _cat_dropdown_inline("防具部位", "gear_type", false, ["accessory"])
		_select_meta(_w_gear, _tag_in_cat(_current.get("tags", []), "gear_type"))
		_w_weight = _cat_dropdown_inline("防具种类", "armor_weight", true)
		_select_meta(_w_weight, _tag_in_cat(_current.get("tags", []), "armor_weight"))
	# 装备需求 requires（所有类别；装备者须全部具备，如 char_desmond）
	_requires = []
	for r in _current.get("requires", []):
		_requires.append(str(r))
	_build_free_tag_ui(_form, "requires", "装备需求 requires", _requires)
	# 其他标签（自由）
	_free_tags = _collect_free_from(_current.get("tags", []))
	_build_free_tag_ui(_form, "other", "其他标签", _free_tags)

	# 3. 修正 mods
	_form.add_child(EditorUI.section_title("修正 mods（每条加在装备者属性上）"))
	_mods_box = VBoxContainer.new()
	_mods_box.add_theme_constant_override("separation", 4)
	_form.add_child(_mods_box)
	for m in _current.get("mods", []):
		if typeof(m) == TYPE_DICTIONARY:
			_add_mod_row(str(m.get("stat", "atk")), str(m.get("op", "flat")), m.get("value", 0))
	var addmod := Button.new()
	addmod.text = "＋ 添加修正"
	addmod.pressed.connect(func():
		_add_mod_row("atk", "flat", 0.0)
		_refresh_preview())
	_form.add_child(addmod)

	# 4. 基础攻击技能 BAS（仅武器，放底部）
	if _current_kind == "weapon":
		_build_bas_section()

	if _current_kind == "weapon":
		_on_wtype_changed()   # 级联 + 显隐初始化
	_building = false
	_refresh_preview()
	_dirty = false   # 建表单过程的控件信号会把 _dirty 打真——载入完成＝干净基线


# 基础区「物品大类」下拉改选 → 换 kind、按新骨架重建表单（保留 id/名/图标）。等价旧的 4 个「＋类别」按钮。
func _on_kind_changed(new_kind: String) -> void:
	if _building or new_kind == _current_kind:
		return
	var kid := _w_id.text.strip_edges()
	var knm := _w_name.text.strip_edges()
	var kic := _w_icon.text.strip_edges()
	_current = _skeleton(new_kind)
	_current["id"] = kid
	_current["name"] = knm
	_current["icon"] = kic
	_current_kind = new_kind
	_build_form()


# —— 物品（非装备类）授权表单 ——
# 标签区：稀有度 + ☑可使用（=usable tag，门控 on_use）+ ☑任务物品（=quest_item）+ 其他标签自由区（食物/医疗/素材…可叠）。
# 无装备槽/mods/BAS。可使用＝战斗/大地图皆可直接 on_use（故无 use_scope）。使用机制(消耗→施 on_use)+队伍背包=后续切片。
func _build_item_form() -> void:
	_form.add_child(EditorUI.section_title("标签"))
	_w_rarity = _cat_dropdown_inline("稀有度", "rarity", false)
	_select_meta(_w_rarity, _rarity_of(_current))
	var cur_tags: Array = _current.get("tags", [])
	# 结构性标记（勾选即 tag）：可使用（门控 on_use）/ 任务物品
	_w_usable = _add_check(_form, "可使用（可直接使用·战斗/大地图皆可 → 下方使用效果）", cur_tags.has("usable"))
	_w_usable.toggled.connect(func(_v): _on_usable_toggled())
	_w_quest = _add_check(_form, "任务物品", cur_tags.has("quest_item"))
	# 其他标签自由区：食物/医疗物品/素材… 手动置入、可叠（结构性标记 tag 已由上面勾选管，排除防残留）
	_free_tags = _collect_free_from(cur_tags).filter(func(t): return not ITEM_FLAG_TAGS.has(str(t)))
	_build_free_tag_ui(_form, "other", "其他标签（食物/医疗物品/素材… 可多个）", _free_tags)
	# 使用效果 on_use（仅勾「可使用」时显）：使用设置(作用对象/距离/可叠加) + 动态效果行（仿武器 mods）
	_ou_box = VBoxContainer.new()
	_ou_box.add_theme_constant_override("separation", 6)
	_ou_box.add_child(EditorUI.section_title("使用设置"))
	_w_use_target = _dropdown_pairs(_ou_box, "作用对象 target", USE_TARGETS, str(_current.get("target", "ally")))
	_w_use_target.item_selected.connect(func(_i): _update_range_visible())
	_w_use_range = _add_spin(_ou_box, "使用距离 range（格；0=同格/自身，作用对象≠自身时生效）", float(_current.get("range", 1)), 0, 20, 1)
	_range_row = _w_use_range.get_parent()
	_w_stack = _add_check(_ou_box, "可叠加计数 stack", bool(_current.get("stack", true)))
	_ou_box.add_child(EditorUI.section_title("使用效果 on_use（消耗时施加；每条一项，＋添加）"))
	_ou_rows = []
	_ou_rows_box = VBoxContainer.new()
	_ou_rows_box.add_theme_constant_override("separation", 4)
	_ou_box.add_child(_ou_rows_box)
	var ou = _current.get("on_use", {})
	if typeof(ou) == TYPE_DICTIONARY:
		for k in ou:
			_add_ou_row(str(k), ou[k])
	var add_ou := Button.new()
	add_ou.text = "＋ 添加使用效果"
	add_ou.pressed.connect(func():
		_add_ou_row("heal_pct_max_hp", 0)
		_refresh_preview())
	_ou_box.add_child(add_ou)
	_form.add_child(_ou_box)
	_on_usable_toggled()      # on_use 段显隐（可使用）
	_update_range_visible()   # 距离行显隐（作用对象）


# 勾/取消「可使用」：显隐 on_use 段（只有可使用物品才有使用效果）
func _on_usable_toggled() -> void:
	if _ou_box != null and is_instance_valid(_ou_box):
		_ou_box.visible = _w_usable != null and is_instance_valid(_w_usable) and _w_usable.button_pressed
	_refresh_preview()


# 使用距离只在「作用对象≠自身」时有意义（友方/敌对都要距离）——自身时藏起该行
func _update_range_visible() -> void:
	if _range_row != null and is_instance_valid(_range_row):
		_range_row.visible = _w_use_target != null and is_instance_valid(_w_use_target) and str(_w_use_target.get_selected_metadata()) != "self"
	_refresh_preview()


# 使用效果一行（仿 _add_mod_row）：效果类型下拉 + 数值 + ✕删除。effect_key ∈ OU_EFFECTS 键。
func _add_ou_row(effect_key: String, value) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var type_ob := OptionButton.new()
	type_ob.custom_minimum_size = Vector2(280, 0)
	for e in OU_EFFECTS:
		type_ob.add_item(str(e[1]))
		type_ob.set_item_metadata(type_ob.item_count - 1, str(e[0]))
	_select_meta(type_ob, effect_key)
	type_ob.item_selected.connect(func(_i): _refresh_preview())
	row.add_child(type_ob)
	var val := SpinBox.new()
	val.min_value = 0
	val.max_value = 9999
	val.step = 1
	val.value = float(value)
	val.custom_minimum_size = Vector2(120, 0)
	val.value_changed.connect(func(_v): _refresh_preview())
	row.add_child(val)
	var rm := Button.new()
	rm.text = "✕"
	var entry := {"type": type_ob, "value": val, "row": row}
	rm.pressed.connect(func():
		_ou_rows.erase(entry)
		row.queue_free()
		_refresh_preview())
	row.add_child(rm)
	_ou_rows_box.add_child(row)
	_ou_rows.append(entry)


# 固定枚举下拉（非 TagDB 类别）：pairs=[[value, label],…]，加进 parent，返回 OptionButton
func _dropdown_pairs(parent: VBoxContainer, label: String, pairs: Array, sel: String) -> OptionButton:
	var ob := OptionButton.new()
	for p in pairs:
		ob.add_item(str(p[1]))
		ob.set_item_metadata(ob.item_count - 1, str(p[0]))
	_select_meta(ob, sel)
	ob.item_selected.connect(func(_i): _refresh_preview())
	parent.add_child(EditorUI.field_row(label, ob))
	return ob


# 武器标签：类型(级联) + 种类 + 握持 + 天生(+主副手)
func _build_weapon_tags() -> void:
	_w_wtype = _cat_dropdown_inline("武器类型", "wtype", false)
	_select_meta(_w_wtype, _tag_in_cat(_current.get("tags", []), "wtype"))
	_w_wtype.item_selected.connect(func(_i): _on_wtype_changed())

	_w_wcat = OptionButton.new()   # 内容由 _refill_wcat 级联填充
	_w_wcat.item_selected.connect(func(_i): _refresh_preview())
	_wcat_row = EditorUI.field_row("武器种类", _w_wcat)
	_form.add_child(_wcat_row)

	_w_handed = _cat_dropdown_inline("握持方式", "handedness", false)
	_select_meta(_w_handed, _tag_in_cat(_current.get("tags", []), "handedness"))
	_handed_row = _w_handed.get_parent()   # 其 field_row

	_w_innate = _add_check(_form, "天生武器（永不卸下；无握持/不吃额外加成）", bool(_current.get("innate", false)))
	_w_innate.toggled.connect(func(_v): _on_wtype_changed())
	_w_innate_slot = OptionButton.new()
	for s in ["main_hand", "off_hand"]:
		_w_innate_slot.add_item(EquipSlots.SLOT_CN.get(s, s))
		_w_innate_slot.set_item_metadata(_w_innate_slot.item_count - 1, s)
	_select_meta(_w_innate_slot, str(_current.get("slot", "main_hand")))
	_w_innate_slot.item_selected.connect(func(_i): _refresh_preview())
	_innate_slot_row = EditorUI.field_row("天生武器放在（主/副手）", _w_innate_slot)
	_form.add_child(_innate_slot_row)


# 类型变化（含天生）：级联种类 + 显隐
func _on_wtype_changed() -> void:
	if _w_wtype == null or not is_instance_valid(_w_wtype):
		return
	var wtype: String = str(_w_wtype.get_selected_metadata())
	var innate := _innate_checked()
	# 级联种类
	var cur := _tag_in_cat(_current.get("tags", []), "wcat_" + wtype)
	_fill_cat_dropdown(_w_wcat, "wcat_" + wtype, [], true)
	_select_meta(_w_wcat, cur)
	# 显隐：投掷无种类；盾/天生无握持
	if _wcat_row != null and is_instance_valid(_wcat_row):
		_wcat_row.visible = wtype != "thrown" and TagDB.ids_in_cat("wcat_" + wtype).size() > 0
	if _handed_row != null and is_instance_valid(_handed_row):
		_handed_row.visible = wtype != "shield" and not innate
	if _innate_slot_row != null and is_instance_valid(_innate_slot_row):
		_innate_slot_row.visible = innate
	# 盾不提供基础攻击：用户切到盾时自动关 BAS（仍可手动开回；载入初始化 _building 时不强改）
	if not _building and wtype == "shield" and _w_has_bas != null and is_instance_valid(_w_has_bas) and _w_has_bas.button_pressed:
		_w_has_bas.button_pressed = false
	_refresh_preview()


# 基础攻击技能（BAS）：底部段
func _build_bas_section() -> void:
	var atk = _current.get("attack", {})
	if typeof(atk) != TYPE_DICTIONARY:
		atk = {}
	_form.add_child(EditorUI.section_title("基础攻击技能 BAS（装备武器 = 设定该单位的基础攻击）"))
	# 开关：是否含 BAS。关闭＝武器不提供基础攻击（保存移除 attack 字段）；盾等纯防具武器用。
	_w_has_bas = _add_check(_form, "含基础攻击技能 BAS（盾牌等不提供基础攻击的武器请关闭）", _has_bas_initial())
	_w_has_bas.toggled.connect(func(_v): _on_has_bas_changed())
	# BAS 字段容器（随开关显隐）
	_bas_box = VBoxContainer.new()
	_bas_box.add_theme_constant_override("separation", 8)
	_form.add_child(_bas_box)
	_w_atk_name = _add_line(_bas_box, "攻击名", str(atk.get("name", "")))
	_w_atk_icon = _add_line(_bas_box, "攻击 icon", str(atk.get("icon", "")))
	_w_atk_coeff = _add_spin(_bas_box, "伤害系数 coeff", float(atk.get("coeff", 1.0)), 0.0, 10.0, 0.05)
	_w_atk_range = _add_spin(_bas_box, "射程 range", float(atk.get("range", 1)), 0, 20, 1)
	_w_atk_ap = _add_spin(_bas_box, "AP 消耗 ap_cost", float(atk.get("ap_cost", 1)), 0, 9, 1)
	_w_atk_dmgkind = OptionButton.new()
	for dk in DAMAGE_KINDS:
		_w_atk_dmgkind.add_item(dk)
		_w_atk_dmgkind.set_item_metadata(_w_atk_dmgkind.item_count - 1, dk)
	_select_meta(_w_atk_dmgkind, str(atk.get("damage_kind", "physical")))
	_w_atk_dmgkind.item_selected.connect(func(_i): _refresh_preview())
	_bas_box.add_child(EditorUI.field_row("伤害类型 damage_kind", _w_atk_dmgkind))
	_atk_tags = []
	for t in atk.get("tags", []):
		_atk_tags.append(str(t))
	_build_free_tag_ui(_bas_box, "attack", "攻击标签", _atk_tags)
	var note := Label.new()
	note.text = "（aoe / bonus / inflict / armor_pen 等高级字段本版不编辑，保存时原样保留）"
	note.add_theme_color_override("font_color", Color(0.6, 0.62, 0.68))
	note.add_theme_font_size_override("font_size", 12)
	_bas_box.add_child(note)
	_bas_box.visible = _w_has_bas.button_pressed


# 载入时 BAS 开关初值＝物品当前是否有非空 attack（盾/无 BAS 的旧数据＝关）
func _has_bas_initial() -> bool:
	var a = _current.get("attack", null)
	return typeof(a) == TYPE_DICTIONARY and not a.is_empty()

func _on_has_bas_changed() -> void:
	if _bas_box != null and is_instance_valid(_bas_box):
		_bas_box.visible = _w_has_bas.button_pressed
	_refresh_preview()


# —— 通用：分类下拉（建并加进表单，返回 OptionButton）——
func _cat_dropdown_inline(label: String, cat: String, with_none: bool, exclude: Array = []) -> OptionButton:
	var ob := OptionButton.new()
	_fill_cat_dropdown(ob, cat, exclude, with_none)
	ob.item_selected.connect(func(_i): _refresh_preview())
	_form.add_child(EditorUI.field_row(label, ob))
	return ob


func _fill_cat_dropdown(ob: OptionButton, cat: String, exclude: Array, with_none: bool) -> void:
	ob.clear()
	if with_none:
		ob.add_item("（无）")
		ob.set_item_metadata(ob.item_count - 1, "")
	for e in TagDB.by_cat(cat):
		var id := str(e.get("id", ""))
		if exclude.has(id):
			continue
		ob.add_item("%s（%s）" % [str(e.get("cn", id)), id])
		ob.set_item_metadata(ob.item_count - 1, id)


# —— 通用：自由标签 UI（下拉选中即加 + 手动输入需确认）——
func _build_free_tag_ui(parent: VBoxContainer, mode: String, label: String, arr: Array) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	var adder := HBoxContainer.new()
	adder.add_theme_constant_override("separation", 6)
	var pick := OptionButton.new()
	pick.custom_minimum_size = Vector2(170, 0)
	_fill_all_tags(pick, mode)
	if pick.item_count > 1:   # 有合规预设才显示下拉；否则只留手动输入（该分区当前无预设可选）
		pick.item_selected.connect(func(idx):
			var tg = pick.get_item_metadata(idx)
			if tg != null and str(tg) != "" and not arr.has(str(tg)):
				arr.append(str(tg))
				_rebuild_free_box(box, arr)
				_refresh_preview()
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
			_rebuild_free_box(box, arr)
			_refresh_preview()
		manual.clear())
	adder.add_child(addb)
	parent.add_child(EditorUI.field_row(label, adder))
	parent.add_child(box)
	_rebuild_free_box(box, arr)


func _rebuild_free_box(box: VBoxContainer, arr: Array) -> void:
	if box == null or not is_instance_valid(box):
		return
	for c in box.get_children():
		c.queue_free()   # ⚠ 必须 queue_free：本函数常由行内 ✕ 的 pressed 触发，free() 会当场释放正在发信号的按钮
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
		l.text = "%s（%s）" % [TagDB.cn(t), t]
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		var rm := Button.new()
		rm.text = "✕"
		var tag: String = str(t)
		rm.pressed.connect(func():
			arr.erase(tag)
			_rebuild_free_box(box, arr)
			_refresh_preview())
		row.add_child(rm)
		box.add_child(row)


# 下拉填全部 tag（首项占位 + 按类别分隔），供「其他标签 / 攻击标签」挑
func _fill_all_tags(ob: OptionButton, mode: String) -> void:
	ob.add_item("（下拉添加…）")
	ob.set_item_metadata(ob.item_count - 1, "")
	var cats := {}
	var all := TagDB.all()
	for id in all:
		if not _tag_offered(str(id), all[id], mode):
			continue
		var c := str(all[id].get("cat", "其他"))
		if not cats.has(c):
			cats[c] = []
		cats[c].append(id)
	for c in cats:
		ob.add_separator(str(CATEGORY_CN.get(c, c)))
		for id in cats[c]:
			ob.add_item("%s（%s）" % [TagDB.cn(id), id])
			ob.set_item_metadata(ob.item_count - 1, id)


# 某 tag 是否该出现在指定 mode 的自定义下拉里（据类别 + 是否已被上方专门控件管）。
func _tag_offered(id: String, entry: Dictionary, mode: String) -> bool:
	var cat := str(entry.get("cat", ""))
	if NON_ITEM_CATS.has(cat):
		return false   # 阵营/移动型/地形/单位状态：与物品无关
	if _managed_tag_set.has(id):
		return false   # 稀有度/类型/种类/握持/部位/甲重/天生：上方专门控件已设，不重复
	match mode:
		"requires":
			return REQUIRE_CATS.has(cat)   # 谁能装：角色/种族身份
		"attack":
			return ATTACK_CATS.has(cat)    # 攻击/技能行为
		_:
			return not (REQUIRE_CATS.has(cat) or ATTACK_CATS.has(cat))   # 其他：排除有专属分区的类别，留未来/未知


# 从物品 tags 取「其他标签」（排除所有自动管理的）
func _collect_free_from(tags) -> Array:
	var out := []
	for t in tags:
		var s := str(t)
		if s == "innate" or s == "innate_weapon":
			continue   # 天生由勾选框管（旧 innate 同样剥离、再存换成 innate_weapon）
		if not _managed_tag_set.has(s):
			out.append(s)
	return out


func _build_icon_row() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var lbl := Label.new()
	lbl.text = "立绘 icon"
	lbl.custom_minimum_size = Vector2(200, 0)
	row.add_child(lbl)
	_icon_thumb = TextureRect.new()
	_icon_thumb.custom_minimum_size = Vector2(28, 28)
	_icon_thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon_thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon_thumb.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	row.add_child(_icon_thumb)
	_w_icon = LineEdit.new()
	_w_icon.text = str(_current.get("icon", ""))
	_w_icon.placeholder_text = ICON_DIR.get(_current_kind, "res://icons/Items") + "/...png"
	_w_icon.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_w_icon.text_changed.connect(func(_t): _refresh_preview())
	row.add_child(_w_icon)
	var browse := Button.new()
	browse.text = "浏览…"
	browse.pressed.connect(_open_icon_dialog)
	row.add_child(browse)
	_form.add_child(row)


func _open_icon_dialog() -> void:
	if _file_dialog == null or not is_instance_valid(_file_dialog):
		_file_dialog = EditorUI.make_file_dialog(FileDialog.FILE_MODE_OPEN_FILE, FileDialog.ACCESS_RESOURCES,
			[["*.png", "PNG"], ["*.jpg,*.jpeg", "JPG"], ["*.webp", "WebP"]], false)
		_file_dialog.file_selected.connect(_on_icon_picked)
		add_child(_file_dialog)
	_file_dialog.current_dir = ICON_DIR.get(_current_kind, "res://icons/Items")
	_file_dialog.popup_centered(Vector2i(760, 520))


func _on_icon_picked(path: String) -> void:
	if _w_icon != null and is_instance_valid(_w_icon):
		_w_icon.text = path
		_refresh_preview()


# —— mods 动态行 ——
func _add_mod_row(stat: String, op: String, value) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var st := OptionButton.new()
	st.custom_minimum_size = Vector2(180, 0)
	_fill_stat_options(st)
	_select_meta(st, stat)
	row.add_child(st)
	# 数值型：op（固定/%）+ value（视觉状态时隐藏）
	var opb := OptionButton.new()
	opb.custom_minimum_size = Vector2(110, 0)
	for o in OPS:
		opb.add_item(o[1])
		opb.set_item_metadata(opb.item_count - 1, o[0])
	_select_meta(opb, op)
	opb.item_selected.connect(func(_i): _refresh_preview())
	row.add_child(opb)
	var val := SpinBox.new()
	val.min_value = -9999
	val.max_value = 9999
	val.step = 0.5
	val.value = (float(value) if typeof(value) != TYPE_STRING else 0.0)
	val.custom_minimum_size = Vector2(110, 0)
	val.value_changed.connect(func(_v): _refresh_preview())
	row.add_child(val)
	# 视觉状态型：状态下拉（与 op+value 互斥显示；不是数值，不填百分比/固定）
	var stt := OptionButton.new()
	stt.custom_minimum_size = Vector2(226, 0)
	for vs in VISION_STATES:
		stt.add_item(vs[1])
		stt.set_item_metadata(stt.item_count - 1, vs[0])
	if typeof(value) == TYPE_STRING:
		_select_meta(stt, str(value))
	stt.item_selected.connect(func(_i): _refresh_preview())
	row.add_child(stt)
	var rm := Button.new()
	rm.text = "✕"
	var entry := {"stat": st, "op": opb, "value": val, "state": stt, "row": row}
	st.item_selected.connect(func(_i):
		_update_mod_row_mode(entry)
		_refresh_preview())
	rm.pressed.connect(func():
		_mod_rows.erase(entry)
		row.queue_free()
		_refresh_preview())
	row.add_child(rm)
	_mods_box.add_child(row)
	_mod_rows.append(entry)
	_update_mod_row_mode(entry)

# 据 stat 选择切换 mod 行形态：视觉状态＝显状态下拉、隐 op+value；数值＝反之。
func _update_mod_row_mode(entry: Dictionary) -> void:
	var is_vs := str(entry["stat"].get_selected_metadata()) == "vision_state"
	entry["op"].visible = not is_vs
	entry["value"].visible = not is_vs
	entry["state"].visible = is_vs


func _fill_stat_options(ob: OptionButton) -> void:
	for grp in STAT_GROUPS:
		ob.add_separator(grp[0])
		for key in grp[1]:
			ob.add_item("%s %s" % [key, StatMeta.label(key)])
			ob.set_item_metadata(ob.item_count - 1, key)
	ob.add_separator("视觉（角色面板不显示）")
	ob.add_item("视觉状态（夜视/无视力…）")
	ob.set_item_metadata(ob.item_count - 1, "vision_state")


# —— 保存 / 删除 ——
func _on_save() -> void:
	var item := _collect()
	var id := str(item.get("id", ""))
	if id == "":
		_err("id 不能为空")
		return
	if not _valid_id(id):
		_err("id 只能用 字母/数字/下划线（现为「%s」）" % id)
		return
	var renaming := (not _is_new) and _loaded_id != "" and id != _loaded_id
	if (_is_new or renaming) and ItemDB.get_item(id) != null:
		_err("id「%s」已存在，请换一个" % id)   # 改名撞已有 id 也拦：否则会静默覆盖别的物品
		return
	if not ItemDB.save_item(item, _loaded_id if renaming else ""):
		_err("保存失败（文件被占用/只读？）")
		return
	if renaming:
		_info("✓ 已保存并改 id：%s → %s　⚠ 旧战役档里引用旧 id 的装备实例会失效" % [_loaded_id, id])
		push_warning("ItemEditor：物品 id %s → %s——已有存档中的实例 tpl_id 不随迁" % [_loaded_id, id])
	else:
		_info("✓ 已保存「%s」→ %s" % [str(item.get("name", id)), ItemDB.kind_of(item) + ".json"])
	_is_new = false
	_loaded_id = id
	_current = item
	_dirty = false
	_refresh_list()
	_select_row(id)
	_dup_btn.disabled = false
	_del_btn.disabled = false


func _on_delete() -> void:
	var id := str(_current.get("id", ""))
	if id == "" or _is_new:
		return
	EditorUI.confirm(self, "确认删除「%s」(%s)？此操作直接写盘。" % [str(_current.get("name", id)), id],
		"删除", func(): _do_delete(id), Callable(), "确认删除")

func _do_delete(id: String) -> void:
	if not ItemDB.delete_item(id):
		_err("删除失败（文件被占用/只读？）")
		return
	_dirty = false
	_loaded_id = ""
	_is_new = false
	_refresh_list()
	_show_empty_form()
	_save_btn.disabled = true
	_dup_btn.disabled = true
	_del_btn.disabled = true
	_info("✓ 已删除「%s」" % id)


# 未保存改动守卫：干净直接执行；脏则弹确认（丢弃→执行 on_ok / 留下→执行 on_cancel）
func _confirm_discard(on_ok: Callable, on_cancel := Callable()) -> void:
	# 干净直接执行；脏则弹确认（丢弃→on_ok / 留下→on_cancel）。on_ok 各路径都会重建表单/离场，dirty 自会归零。
	EditorUI.confirm_discard(self, _dirty, on_ok, on_cancel,
		"当前物品有未保存的修改，继续将丢弃。", "丢弃修改", "留下")

# Ctrl+S 保存（表单激活时）
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_S and event.ctrl_pressed:
		if not _save_btn.disabled:
			_on_save()
		get_viewport().set_input_as_handled()

func _valid_id(id: String) -> bool:
	for i in id.length():
		var c := id.unicode_at(i)
		if not ((c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95):
			return false
	return true

func _info(text: String) -> void:
	_msg.add_theme_color_override("font_color", Color(0.72, 0.78, 0.86))
	_msg.text = text

func _err(text: String) -> void:
	_msg.add_theme_color_override("font_color", Color(0.92, 0.5, 0.45))
	_msg.text = "✗ " + text


# 收集表单 → 物品 dict（tags 由 稀有度 + 类型/种类/握持(或部位/甲重) + innate + 自由 组成；slot 自动派生）
func _collect() -> Dictionary:
	var out: Dictionary = _current.duplicate(true)
	out["id"] = _w_id.text.strip_edges()
	out["name"] = _w_name.text.strip_edges()
	out["icon"] = _w_icon.text.strip_edges()

	if _current_kind == "item":
		return _collect_item(out)

	var tags: Array = [_w_rarity.get_selected_metadata()]
	var slot := ""
	match _current_kind:
		"weapon":
			var wtype: String = str(_w_wtype.get_selected_metadata())
			if wtype != "":
				tags.append(wtype)
			var innate := _innate_checked()
			out["innate"] = innate
			if innate:
				tags.append("innate_weapon")
			# 种类（投掷无）
			if wtype != "thrown":
				var wc: String = str(_w_wcat.get_selected_metadata())
				if wc != "":
					tags.append(wc)
			# 握持（盾/天生 无）
			if wtype != "shield" and not innate:
				var h: String = str(_w_handed.get_selected_metadata())
				if h != "":
					tags.append(h)
				out["two_handed"] = h == "two_handed"
			else:
				out["two_handed"] = false
			# slot
			if wtype == "shield":
				slot = "off_hand"
			elif innate:
				slot = str(_w_innate_slot.get_selected_metadata())
			else:
				slot = "main_hand"
			# attack（BAS）——开关关闭＝武器不提供基础攻击（如盾），移除 attack 字段；下游 basic_attack() 自会跳过
			if _w_has_bas != null and is_instance_valid(_w_has_bas) and _w_has_bas.button_pressed:
				var atk: Dictionary = out.get("attack", {})
				if typeof(atk) != TYPE_DICTIONARY:
					atk = {}
				atk["name"] = _w_atk_name.text.strip_edges()
				atk["icon"] = _w_atk_icon.text.strip_edges()
				atk["coeff"] = _num(_w_atk_coeff.value)
				atk["range"] = int(_w_atk_range.value)
				atk["ap_cost"] = int(_w_atk_ap.value)
				atk["damage_kind"] = _w_atk_dmgkind.get_selected_metadata()
				atk["tags"] = _atk_tags.duplicate()
				out["attack"] = atk
			else:
				out.erase("attack")
		"armor":
			var g: String = str(_w_gear.get_selected_metadata())
			if g != "":
				tags.append(g)
				slot = g
			else:
				slot = "body"
			var wt: String = str(_w_weight.get_selected_metadata())
			if wt != "":
				tags.append(wt)
		_:
			tags.append("accessory")
			slot = "accessory_1"

	for t in _free_tags:
		if not tags.has(t):
			tags.append(t)
	out["tags"] = tags
	out["slot"] = slot
	out["requires"] = _requires.duplicate()

	var mods := []
	for e in _mod_rows:
		if str(e["stat"].get_selected_metadata()) == "vision_state":
			mods.append({"stat": "vision_state", "op": "state", "value": str(e["state"].get_selected_metadata())})
		else:
			mods.append({"stat": e["stat"].get_selected_metadata(), "op": e["op"].get_selected_metadata(), "value": _num(e["value"].value)})
	out["mods"] = mods
	return out


# 物品（非装备类）表单 → 物品字典：kind=item、类型多选 tag、消耗品时含 on_use/设置。无 slot/mods/requires。
func _collect_item(out: Dictionary) -> Dictionary:
	out["kind"] = "item"
	for k in ["slot", "mods", "requires", "two_handed", "innate", "attack", "use_scope"]:
		out.erase(k)   # 装备专属 + 废弃字段：物品一律不带
	var tags: Array = [_w_rarity.get_selected_metadata()]
	if _w_usable.button_pressed:
		tags.append("usable")
	if _w_quest.button_pressed:
		tags.append("quest_item")
	for t in _free_tags:
		if not tags.has(t):
			tags.append(t)
	out["tags"] = tags
	# on_use 与设置：仅「可使用」时写入，否则整体移除（不可使用＝纯道具/素材/任务物品/食物）
	if _w_usable.button_pressed:
		var ou := {}   # 由动态效果行组装（每条 效果类型→数值；0 值/空类型跳过，同类型后者覆盖）
		for e in _ou_rows:
			var key := str(e["type"].get_selected_metadata())
			var v := int(e["value"].value)
			if key != "" and v != 0:
				ou[key] = v
		out["on_use"] = ou
		out["target"] = str(_w_use_target.get_selected_metadata())
		out["range"] = int(_w_use_range.value)
		out["stack"] = _w_stack.button_pressed
	else:
		for k in ["on_use", "target", "range", "stack"]:
			out.erase(k)
	return out


# —— 即时预览（顺带承担脏标记：任何表单控件信号都会走到这）——
func _refresh_preview() -> void:
	if _preview == null or not is_instance_valid(_preview):
		return
	for c in _preview.get_children():
		c.free()   # 预览子树是纯静态标签（无信号发射中对象），立即释放避免一帧双影
	var title := Label.new()
	title.text = "预览（成品效果）"
	title.add_theme_color_override("font_color", Color("#EBBC04"))
	title.add_theme_font_size_override("font_size", 14)
	_preview.add_child(title)
	if _w_id == null or not is_instance_valid(_w_id):
		var h := Label.new()
		h.text = "（编辑物品时此处即时显示）"
		h.add_theme_color_override("font_color", Color(0.55, 0.6, 0.66))
		h.add_theme_font_size_override("font_size", 12)
		_preview.add_child(h)
		return
	_dirty = true   # 表单激活时到这＝有改动（_build_form 末尾会清回干净基线）
	if _icon_thumb != null and is_instance_valid(_icon_thumb):
		_icon_thumb.texture = TextureCache.get_tex(_w_icon.text.strip_edges())
	_preview.add_child(ItemTooltip.render(_collect()))   # 通用组件（与角色状态页共用一份渲染）


# —— 小工具 ——
func _innate_checked() -> bool:
	return _current_kind == "weapon" and _w_innate != null and is_instance_valid(_w_innate) and _w_innate.button_pressed

func _num(v: float):
	return int(v) if v == floor(v) else v

func _tag_in_cat(tags, cat: String) -> String:
	var ids := TagDB.ids_in_cat(cat)
	for t in tags:
		if ids.has(str(t)):
			return str(t)
	return ""

func _rarity_of(item) -> String:
	for t in item.get("tags", []):
		if _rarities.has(str(t)):
			return str(t)
	return "common"

func _rarity_color(rar: String) -> Color:
	var c := TagDB.color(rar)
	return Color(c) if c != "" else Color("#E0E0E0")

func _select_meta(ob: OptionButton, key) -> void:
	for i in ob.item_count:
		if ob.get_item_metadata(i) == key:
			ob.select(i)
			return
	for i in ob.item_count:
		if not ob.is_item_disabled(i) and ob.get_item_metadata(i) != null:
			ob.select(i)
			return

# 表单动态字段 → 公共层 EditorUI（信号统一走 _refresh_preview）
func _add_line(parent: VBoxContainer, label: String, value: String) -> LineEdit:
	return EditorUI.add_line(parent, label, value, _refresh_preview)

func _add_check(parent: VBoxContainer, label: String, value: bool) -> CheckBox:
	return EditorUI.add_check(parent, label, value, _refresh_preview)

func _add_spin(parent: VBoxContainer, label: String, value: float, mn: float, mx: float, step: float) -> SpinBox:
	return EditorUI.add_spin(parent, label, value, mn, mx, step, _refresh_preview)
