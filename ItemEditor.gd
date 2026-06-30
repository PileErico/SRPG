extends Control
## 物品编辑器：创作游戏正式物品（武器 / 防具 / 饰品），写回 res://data/*.json。
## 入口 StartMenu →「物品编辑器」；自包含 procedural 面板。
## tag 设计（用户校准）：槽位非物品 tag、自动派生；类型/种类等用「分类下拉」（读 TagDB.by_cat）。
##  武器：先选【类型】(近战/投掷/远程/触媒/盾，单选互斥) → 类型级联决定【种类】可选项；投掷无种类、盾不显握持。
##  防具：部位(头盔/身甲)+种类(轻/中/重)。其他标签：下拉(选中即加)+手动(确认)。只「天生武器」需勾选。

const ItemDB := preload("res://ItemDB.gd")
const EquipSlots := preload("res://EquipSlots.gd")
const TagDB := preload("res://TagDB.gd")

const KIND_CN := {"weapon": "武器", "armor": "防具", "accessory": "饰品"}
const ICON_DIR := {
	"weapon": "res://icons/Items/Weapons",
	"armor": "res://icons/Items/Armors",
	"accessory": "res://icons/Items/Accessories",
}
const DAMAGE_KINDS := ["physical", "fire", "ice", "thunder", "holy"]
const OPS := [["flat", "固定"], ["pct", "百分比%"]]

# 「自动管理」的 tag 类别（这些 tag 由专门控件管，从「其他标签」自由区排除）
const MANAGED_CATS := ["rarity", "wtype", "wcat_melee", "wcat_ranged", "wcat_catalyst",
	"wcat_shield", "handedness", "gear_type", "armor_weight", "weapon_attr"]

const STAT_GROUPS := [
	["四维", [["STR", "力量", true], ["DEX", "灵巧", true], ["INT", "智力", true], ["STA", "体力", true]]],
	["进攻", [["atk", "攻击", true], ["acc", "命中", true], ["crit_rate", "暴击率", true],
		["crit_dmg", "暴击威力", true], ["atk_eff", "攻击效能", true], ["mag", "理术", false]]],
	["生存", [["HP_max", "生命上限", true], ["eva", "闪避", true], ["block_rate", "格挡率", true],
		["block_power", "格挡性能", true], ["def_eff", "防御效能", false], ["armor_max", "护甲池", true]]],
	["抗性", [["res_phys", "物理抗性", true], ["res_status", "异常抗性", true], ["res_fire", "火焰抗性", false],
		["res_thunder", "雷电抗性", false], ["res_ice", "冰冻抗性", false], ["res_holy", "神圣抗性", false]]],
	["行动", [["move", "移动力", true], ["speed", "速度", true], ["AP_max", "AP上限", true]]],
]

# —— 状态 ——
var _rarities: Array = []
var _managed_tag_set: Dictionary = {}
var _current: Dictionary = {}
var _current_kind: String = ""
var _is_new: bool = false
var _free_tags: Array = []
var _atk_tags: Array = []

# —— 控件 ——
var _list: ItemList
var _list_ids: Array = []
var _msg: Label
var _form: VBoxContainer
var _preview: VBoxContainer
var _save_btn: Button
var _del_btn: Button
var _file_dialog: FileDialog

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


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
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
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://StartMenu.tscn"))
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
	_save_btn = Button.new()
	_save_btn.text = "保存 ⤓"
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
	box.custom_minimum_size = Vector2(280, 0)
	box.add_theme_constant_override("separation", 8)
	var newbar := HBoxContainer.new()
	newbar.add_theme_constant_override("separation", 6)
	for kind in ["weapon", "armor", "accessory"]:
		var b := Button.new()
		b.text = "＋" + KIND_CN[kind]
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_new_item.bind(kind))
		newbar.add_child(b)
	box.add_child(newbar)
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_list_select)
	box.add_child(_list)
	_del_btn = Button.new()
	_del_btn.text = "删除选中"
	_del_btn.disabled = true
	_del_btn.pressed.connect(_on_delete)
	box.add_child(_del_btn)
	return box


func _refresh_list() -> void:
	_list.clear()
	_list_ids.clear()
	var items := ItemDB.all()
	var ids := items.keys()
	ids.sort_custom(func(a, b):
		var ka := ItemDB.kind_of(items[a])
		var kb := ItemDB.kind_of(items[b])
		if ka != kb:
			return ka < kb
		return str(items[a].get("name", a)) < str(items[b].get("name", b)))
	for id in ids:
		var it = items[id]
		var kind := ItemDB.kind_of(it)
		_list.add_item("[%s] %s  (%s)" % [KIND_CN.get(kind, kind), str(it.get("name", id)), id])
		_list.set_item_custom_fg_color(_list.item_count - 1, _rarity_color(_rarity_of(it)))
		_list_ids.append(id)


func _on_list_select(idx: int) -> void:
	if idx < 0 or idx >= _list_ids.size():
		return
	_load_item(_list_ids[idx])


func _new_item(kind: String) -> void:
	_current = _skeleton(kind)
	_current_kind = kind
	_is_new = true
	_list.deselect_all()
	_build_form()
	_save_btn.disabled = false
	_del_btn.disabled = true
	_msg.text = "新建%s——填好后点保存（id 必须唯一）" % KIND_CN[kind]


func _load_item(id: String) -> void:
	var it = ItemDB.get_item(id)
	if it == null:
		return
	_current = it.duplicate(true)
	_current_kind = ItemDB.kind_of(_current)
	_is_new = false
	_build_form()
	_save_btn.disabled = false
	_del_btn.disabled = false
	_msg.text = "编辑「%s」" % str(_current.get("name", id))


func _show_empty_form() -> void:
	_clear_form()
	var hint := Label.new()
	hint.text = "← 选左侧物品编辑，或点＋新建一件"
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.72))
	_form.add_child(hint)
	_refresh_preview()


func _skeleton(kind: String) -> Dictionary:
	match kind:
		"weapon":
			return {"id": "", "name": "新武器", "slot": "main_hand", "icon": "",
				"tags": ["common", "melee", "weapon_sword", "one_handed"], "requires": [], "mods": [],
				"two_handed": false, "innate": false,
				"attack": {"name": "普通攻击", "icon": "", "coeff": 1.0, "range": 1,
					"ap_cost": 1, "damage_kind": "physical", "tags": ["single_target"]}}
		"armor":
			return {"id": "", "name": "新防具", "slot": "armor", "icon": "",
				"tags": ["common", "armor", "medium_armor"], "requires": [],
				"mods": [{"stat": "armor_max", "op": "flat", "value": 10}]}
		_:
			return {"id": "", "name": "新饰品", "slot": "accessory_1", "icon": "",
				"tags": ["common", "accessory"], "requires": [], "mods": []}


func _clear_form() -> void:
	for c in _form.get_children():
		c.queue_free()
	_mod_rows.clear()
	_free_tags = []
	_atk_tags = []


func _build_form() -> void:
	_clear_form()

	# 1. 基础
	_form.add_child(_section_label("基础"))
	_w_id = _add_line(_form, "id（唯一主键）", str(_current.get("id", "")))
	_w_name = _add_line(_form, "名字", str(_current.get("name", "")))
	_build_icon_row()

	# 2. 标签
	_form.add_child(_section_label("标签"))
	_w_rarity = _cat_dropdown_inline("稀有度", "rarity", false)
	_select_meta(_w_rarity, _rarity_of(_current))
	if _current_kind == "weapon":
		_build_weapon_tags()
	elif _current_kind == "armor":
		_w_gear = _cat_dropdown_inline("防具部位", "gear_type", false, ["accessory"])
		_select_meta(_w_gear, _tag_in_cat(_current.get("tags", []), "gear_type"))
		_w_weight = _cat_dropdown_inline("防具种类", "armor_weight", true)
		_select_meta(_w_weight, _tag_in_cat(_current.get("tags", []), "armor_weight"))
	# 其他标签（自由）
	_free_tags = _collect_free_from(_current.get("tags", []))
	_build_free_tag_ui("其他标签", _free_tags)

	# 3. 修正 mods
	_form.add_child(_section_label("修正 mods（每条加在装备者属性上）"))
	_mods_box = VBoxContainer.new()
	_mods_box.add_theme_constant_override("separation", 4)
	_form.add_child(_mods_box)
	for m in _current.get("mods", []):
		if typeof(m) == TYPE_DICTIONARY:
			_add_mod_row(str(m.get("stat", "atk")), str(m.get("op", "flat")), float(m.get("value", 0)))
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
	_refresh_preview()


# 武器标签：类型(级联) + 种类 + 握持 + 天生(+主副手)
func _build_weapon_tags() -> void:
	_w_wtype = _cat_dropdown_inline("武器类型", "wtype", false)
	_select_meta(_w_wtype, _tag_in_cat(_current.get("tags", []), "wtype"))
	_w_wtype.item_selected.connect(func(_i): _on_wtype_changed())

	_w_wcat = OptionButton.new()   # 内容由 _refill_wcat 级联填充
	_w_wcat.item_selected.connect(func(_i): _refresh_preview())
	_wcat_row = _field_row("武器种类", _w_wcat)
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
	_innate_slot_row = _field_row("天生武器放在（主/副手）", _w_innate_slot)
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
	_refresh_preview()


# 基础攻击技能（BAS）：底部段
func _build_bas_section() -> void:
	var atk = _current.get("attack", {})
	if typeof(atk) != TYPE_DICTIONARY:
		atk = {}
	_form.add_child(_section_label("基础攻击技能 BAS（装备武器 = 设定该单位的基础攻击）"))
	_w_atk_name = _add_line(_form, "攻击名", str(atk.get("name", "")))
	_w_atk_icon = _add_line(_form, "攻击 icon", str(atk.get("icon", "")))
	_w_atk_coeff = _add_spin(_form, "伤害系数 coeff", float(atk.get("coeff", 1.0)), 0.0, 10.0, 0.05)
	_w_atk_range = _add_spin(_form, "射程 range", float(atk.get("range", 1)), 0, 20, 1)
	_w_atk_ap = _add_spin(_form, "AP 消耗 ap_cost", float(atk.get("ap_cost", 1)), 0, 9, 1)
	_w_atk_dmgkind = OptionButton.new()
	for dk in DAMAGE_KINDS:
		_w_atk_dmgkind.add_item(dk)
		_w_atk_dmgkind.set_item_metadata(_w_atk_dmgkind.item_count - 1, dk)
	_select_meta(_w_atk_dmgkind, str(atk.get("damage_kind", "physical")))
	_w_atk_dmgkind.item_selected.connect(func(_i): _refresh_preview())
	_form.add_child(_field_row("伤害类型 damage_kind", _w_atk_dmgkind))
	_atk_tags = []
	for t in atk.get("tags", []):
		_atk_tags.append(str(t))
	_build_free_tag_ui("攻击标签", _atk_tags)
	var note := Label.new()
	note.text = "（aoe / bonus / inflict / armor_pen 等高级字段本版不编辑，保存时原样保留）"
	note.add_theme_color_override("font_color", Color(0.6, 0.62, 0.68))
	note.add_theme_font_size_override("font_size", 12)
	_form.add_child(note)


# —— 通用：分类下拉（建并加进表单，返回 OptionButton）——
func _cat_dropdown_inline(label: String, cat: String, with_none: bool, exclude: Array = []) -> OptionButton:
	var ob := OptionButton.new()
	_fill_cat_dropdown(ob, cat, exclude, with_none)
	ob.item_selected.connect(func(_i): _refresh_preview())
	_form.add_child(_field_row(label, ob))
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
func _build_free_tag_ui(label: String, arr: Array) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	var adder := HBoxContainer.new()
	adder.add_theme_constant_override("separation", 6)
	var pick := OptionButton.new()
	pick.custom_minimum_size = Vector2(170, 0)
	_fill_all_tags(pick)
	pick.item_selected.connect(func(idx):
		var tg = pick.get_item_metadata(idx)
		if tg != null and str(tg) != "" and not arr.has(str(tg)):
			arr.append(str(tg))
			_rebuild_free_box(box, arr)
			_refresh_preview()
		pick.select(0))
	adder.add_child(pick)
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
	_form.add_child(_field_row(label, adder))
	_form.add_child(box)
	_rebuild_free_box(box, arr)


func _rebuild_free_box(box: VBoxContainer, arr: Array) -> void:
	if box == null or not is_instance_valid(box):
		return
	for c in box.get_children():
		c.free()
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
func _fill_all_tags(ob: OptionButton) -> void:
	ob.add_item("（下拉添加…）")
	ob.set_item_metadata(ob.item_count - 1, "")
	var cats := {}
	var all := TagDB.all()
	for id in all:
		var c := str(all[id].get("cat", "其他"))
		if not cats.has(c):
			cats[c] = []
		cats[c].append(id)
	for c in cats:
		ob.add_separator(c)
		for id in cats[c]:
			ob.add_item("%s（%s）" % [TagDB.cn(id), id])
			ob.set_item_metadata(ob.item_count - 1, id)


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
		_file_dialog = FileDialog.new()
		_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_file_dialog.access = FileDialog.ACCESS_RESOURCES
		_file_dialog.filters = PackedStringArray(["*.png ; PNG", "*.jpg, *.jpeg ; JPG", "*.webp ; WebP"])
		_file_dialog.file_selected.connect(_on_icon_picked)
		add_child(_file_dialog)
	_file_dialog.current_dir = ICON_DIR.get(_current_kind, "res://icons/Items")
	_file_dialog.popup_centered(Vector2i(760, 520))


func _on_icon_picked(path: String) -> void:
	if _w_icon != null and is_instance_valid(_w_icon):
		_w_icon.text = path
		_refresh_preview()


# —— mods 动态行 ——
func _add_mod_row(stat: String, op: String, value: float) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var st := OptionButton.new()
	st.custom_minimum_size = Vector2(180, 0)
	_fill_stat_options(st)
	_select_meta(st, stat)
	st.item_selected.connect(func(_i): _refresh_preview())
	row.add_child(st)
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
	val.value = value
	val.custom_minimum_size = Vector2(110, 0)
	val.value_changed.connect(func(_v): _refresh_preview())
	row.add_child(val)
	var rm := Button.new()
	rm.text = "✕"
	var entry := {"stat": st, "op": opb, "value": val, "row": row}
	rm.pressed.connect(func():
		_mod_rows.erase(entry)
		row.queue_free()
		_refresh_preview())
	row.add_child(rm)
	_mods_box.add_child(row)
	_mod_rows.append(entry)


func _fill_stat_options(ob: OptionButton) -> void:
	for grp in STAT_GROUPS:
		ob.add_separator(grp[0])
		for s in grp[1]:
			var label: String = "%s %s" % [s[0], s[1]]
			if not s[2]:
				label += " ⚠未参战"
			ob.add_item(label)
			ob.set_item_metadata(ob.item_count - 1, s[0])


# —— 保存 / 删除 ——
func _on_save() -> void:
	var item := _collect()
	if str(item.get("id", "")) == "":
		_msg.text = "✗ id 不能为空"
		return
	if _is_new and ItemDB.get_item(str(item["id"])) != null:
		_msg.text = "✗ id「%s」已存在，请换一个" % str(item["id"])
		return
	if not ItemDB.save_item(item):
		_msg.text = "✗ 保存失败"
		return
	var saved_id := str(item["id"])
	_is_new = false
	_current = item
	_refresh_list()
	_select_list_by_id(saved_id)
	_del_btn.disabled = false
	_msg.text = "✓ 已保存「%s」→ %s" % [str(item.get("name", saved_id)), ItemDB.kind_of(item) + ".json"]


func _on_delete() -> void:
	var id := str(_current.get("id", ""))
	if id == "" or _is_new:
		return
	if not ItemDB.delete_item(id):
		_msg.text = "✗ 删除失败"
		return
	_refresh_list()
	_show_empty_form()
	_save_btn.disabled = true
	_del_btn.disabled = true
	_msg.text = "✓ 已删除「%s」" % id


# 收集表单 → 物品 dict（tags 由 稀有度 + 类型/种类/握持(或部位/甲重) + innate + 自由 组成；slot 自动派生）
func _collect() -> Dictionary:
	var out: Dictionary = _current.duplicate(true)
	out["id"] = _w_id.text.strip_edges()
	out["name"] = _w_name.text.strip_edges()
	out["icon"] = _w_icon.text.strip_edges()

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
			# attack
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
		"armor":
			var g: String = str(_w_gear.get_selected_metadata())
			if g != "":
				tags.append(g)
				slot = g
			else:
				slot = "armor"
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

	var mods := []
	for e in _mod_rows:
		mods.append({"stat": e["stat"].get_selected_metadata(), "op": e["op"].get_selected_metadata(), "value": _num(e["value"].value)})
	out["mods"] = mods
	return out


# —— 即时预览 ——
func _refresh_preview() -> void:
	if _preview == null or not is_instance_valid(_preview):
		return
	for c in _preview.get_children():
		c.free()
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
	_preview.add_child(_render_item_tooltip(_collect()))


func _render_item_tooltip(item: Dictionary) -> Control:
	var rc := _rarity_color(_rarity_of(item))
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 1)
	sb.border_color = rc
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	panel.add_child(v)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var itex = _load_icon(str(item.get("icon", "")))
	if itex != null:
		head.add_child(_icon_rect(itex, 44))
	var headv := VBoxContainer.new()
	headv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var nm := str(item.get("name", ""))
	var name_l := Label.new()
	name_l.text = nm if nm != "" else "（未命名）"
	name_l.add_theme_font_size_override("font_size", 18)
	name_l.add_theme_color_override("font_color", rc)
	headv.add_child(name_l)
	var sub := Label.new()
	sub.text = "%s · %s" % [KIND_CN.get(_current_kind, _current_kind), EquipSlots.SLOT_CN.get(str(item.get("slot", "")), str(item.get("slot", "")))]
	sub.add_theme_font_size_override("font_size", 12)
	sub.add_theme_color_override("font_color", Color(0.66, 0.7, 0.78))
	headv.add_child(sub)
	head.add_child(headv)
	v.add_child(head)

	_preview_tags(v, item.get("tags", []))

	var req = item.get("requires", [])
	if typeof(req) == TYPE_ARRAY and not req.is_empty():
		var rn := []
		for q in req:
			rn.append(TagDB.cn(str(q)))
		var rl := Label.new()
		rl.text = "需求：" + "、".join(rn)
		rl.add_theme_font_size_override("font_size", 12)
		rl.add_theme_color_override("font_color", Color(0.95, 0.62, 0.5))
		v.add_child(rl)

	for m in item.get("mods", []):
		if typeof(m) == TYPE_DICTIONARY:
			v.add_child(_preview_mod_line(m))

	var atk = item.get("attack", null)
	if typeof(atk) == TYPE_DICTIONARY:
		v.add_child(HSeparator.new())
		var ahb := HBoxContainer.new()
		ahb.add_theme_constant_override("separation", 8)
		var atex = _load_icon(str(atk.get("icon", "")))
		if atex != null:
			ahb.add_child(_icon_rect(atex, 34))
		var an := Label.new()
		an.text = "攻击：" + str(atk.get("name", ""))
		an.add_theme_font_size_override("font_size", 15)
		an.add_theme_color_override("font_color", Color("#EBBC04"))
		an.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		ahb.add_child(an)
		v.add_child(ahb)
		_preview_tags(v, atk.get("tags", []))
		v.add_child(_kv("距离", "%d" % int(atk.get("range", 1))))
		v.add_child(_kv("伤害系数", "%d%%" % int(round(float(atk.get("coeff", 1.0)) * 100.0))))
		v.add_child(_kv("AP 消耗", "%d" % int(atk.get("ap_cost", 1))))
		v.add_child(_kv("伤害类型", str(atk.get("damage_kind", "physical"))))
		var bspec = atk.get("bonus", null)
		if typeof(bspec) == TYPE_DICTIONARY:
			var ns := []
			for s in bspec.get("stats", []):
				ns.append(_stat_cn(str(s)))
			v.add_child(_kv("伤害补正", "（%s）×%s" % ["＋".join(ns), _numfmt(float(bspec.get("mult", 0)))]))
		var pen := float(atk.get("armor_pen", 0))
		if pen > 0.0:
			v.add_child(_kv("穿甲", "%d%%" % int(round(pen * 100.0))))
		var inf = atk.get("inflict", null)
		if typeof(inf) == TYPE_DICTIONARY:
			v.add_child(_kv("异常", "%d%% 施加 %s" % [int(float(inf.get("chance", 0))), str(inf.get("name", ""))]))
		var aoe = atk.get("aoe", null)
		if typeof(aoe) == TYPE_DICTIONARY:
			var ff := "（友伤）" if bool(aoe.get("friendly_fire", false)) else ""
			v.add_child(_kv("范围", "%s·长%d%s" % [str(aoe.get("shape", "")), int(aoe.get("length", 1)), ff]))
		var prefer := str(atk.get("prefer", ""))
		if prefer == "ground" or prefer == "air":
			var note := Label.new()
			note.text = "地面优先" if prefer == "ground" else "天空优先"
			note.add_theme_font_size_override("font_size", 12)
			note.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
			v.add_child(note)
	return panel


func _preview_tags(parent: Node, tags) -> void:
	if typeof(tags) != TYPE_ARRAY or tags.is_empty():
		return
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 4)
	flow.add_theme_constant_override("v_separation", 4)
	for t in tags:
		flow.add_child(_tag_chip(TagDB.cn(str(t))))
	parent.add_child(flow)


func _tag_chip(text: String) -> Control:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.14)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 1
	sb.content_margin_bottom = 1
	p.add_theme_stylebox_override("panel", sb)
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	p.add_child(l)
	return p


func _icon_rect(tex, sz: int) -> TextureRect:
	var ic := TextureRect.new()
	ic.texture = tex
	ic.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ic.custom_minimum_size = Vector2(sz, sz)
	return ic


func _load_icon(path: String):
	if path == "":
		return null
	if ResourceLoader.exists(path):
		var t = load(path)
		if t is Texture2D:
			return t
	var img := Image.new()
	if img.load(path) == OK:
		return ImageTexture.create_from_image(img)
	return null


func _preview_mod_line(m) -> Label:
	var l := Label.new()
	var key := str(m.get("stat", ""))
	var op := str(m.get("op", "flat"))
	var val := float(m.get("value", 0))
	var sfx := "%" if op == "pct" else ""
	var sign := "+" if val >= 0 else ""
	l.text = "%s %s%s%s" % [_stat_cn(key), sign, _numfmt(val), sfx]
	l.add_theme_color_override("font_color", Color(0.45, 0.85, 0.5) if val >= 0 else Color(0.92, 0.5, 0.5))
	return l


func _kv(label: String, value: String) -> Label:
	var l := Label.new()
	l.text = "%s：%s" % [label, value]
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color(0.82, 0.85, 0.9))
	return l


func _stat_cn(key: String) -> String:
	for grp in STAT_GROUPS:
		for s in grp[1]:
			if str(s[0]) == key:
				return str(s[1])
	return key


func _numfmt(v: float) -> String:
	return str(int(v)) if v == floor(v) else str(v)


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

func _split(s: String) -> Array:
	var out := []
	for part in s.split(",", false):
		var t := part.strip_edges()
		if t != "":
			out.append(t)
	return out

func _select_meta(ob: OptionButton, key) -> void:
	for i in ob.item_count:
		if ob.get_item_metadata(i) == key:
			ob.select(i)
			return
	for i in ob.item_count:
		if not ob.is_item_disabled(i) and ob.get_item_metadata(i) != null:
			ob.select(i)
			return

func _select_list_by_id(id: String) -> void:
	var idx := _list_ids.find(id)
	if idx >= 0:
		_list.select(idx)

func _section_label(text: String) -> Label:
	var l := Label.new()
	l.text = "── " + text
	l.add_theme_color_override("font_color", Color(0.55, 0.78, 0.95))
	l.add_theme_font_size_override("font_size", 15)
	return l

func _field_row(label: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(200, 0)
	row.add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row

func _add_line(parent: VBoxContainer, label: String, value: String) -> LineEdit:
	var le := LineEdit.new()
	le.text = value
	le.text_changed.connect(func(_t): _refresh_preview())
	parent.add_child(_field_row(label, le))
	return le

func _add_check(parent: VBoxContainer, label: String, value: bool) -> CheckBox:
	var cb := CheckBox.new()
	cb.button_pressed = value
	cb.toggled.connect(func(_v): _refresh_preview())
	parent.add_child(_field_row(label, cb))
	return cb

func _add_spin(parent: VBoxContainer, label: String, value: float, mn: float, mx: float, step: float) -> SpinBox:
	var sb := SpinBox.new()
	sb.min_value = mn
	sb.max_value = mx
	sb.step = step
	sb.value = value
	sb.value_changed.connect(func(_v): _refresh_preview())
	parent.add_child(_field_row(label, sb))
	return sb
