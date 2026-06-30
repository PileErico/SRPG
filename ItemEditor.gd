extends Control
## 物品编辑器：创作游戏正式物品（武器 / 防具 / 饰品），写回 res://data/*.json。
## 单独入口（StartMenu →「物品编辑器」），自包含 procedural 面板——之后可整合进游戏内置编辑器。
## 数据契约对准代码（不是设计文档）：mod = {stat, op, value}，op∈flat/pct；stat 用 Unit.stats 真实键。
## 稀有度 = tag（不是字段）；护甲池 = stat "armor_max" 的 mod；落盘按 slot 路由（ItemDB.save_item）。

const ItemDB := preload("res://ItemDB.gd")
const EquipSlots := preload("res://EquipSlots.gd")   # 槽位 / 槽位tag 单一数据源（授权侧 + 运行时共用）
const TagDB := preload("res://TagDB.gd")             # tag 词典（cn / color / 分类，单一数据源 data/tags.json）

const KIND_CN := {"weapon": "武器", "armor": "防具", "accessory": "饰品"}

# 稀有度（互斥，作 tag）：id 列表 / 中文 / 颜色都从 TagDB 读（data/tags.json 单一数据源）。
var _rarities: Array = []   # 稀有度 id 列表（_ready 从 TagDB 取，顺序=tags.json）

# 伤害类型（武器 attack.damage_kind）；目前战斗只消费 physical，其余为元素系统预留。
const DAMAGE_KINDS := ["physical", "fire", "ice", "thunder", "holy"]

# mod 的 op
const OPS := [["flat", "固定"], ["pct", "百分比%"]]

# stat 可选表（对准 Unit.gd 的 stats 字典 + _resolve_one 实际消费）。
# 每项 [key, 中文, 战斗是否已消费]；⚠ = 仅面板、对应系统未接（如元素抗性）。
const STAT_GROUPS := [
	["四维", [
		["STR", "力量", true], ["DEX", "灵巧", true], ["INT", "智力", true], ["STA", "体力", true],
	]],
	["进攻", [
		["atk", "攻击", true], ["acc", "命中", true], ["crit_rate", "暴击率", true],
		["crit_dmg", "暴击威力", true], ["atk_eff", "攻击效能", true], ["mag", "理术", false],
	]],
	["生存", [
		["HP_max", "生命上限", true], ["eva", "闪避", true], ["block_rate", "格挡率", true],
		["block_power", "格挡性能", true], ["def_eff", "防御效能", false], ["armor_max", "护甲池", true],
	]],
	["抗性", [
		["res_phys", "物理抗性", true], ["res_status", "异常抗性", true], ["res_fire", "火焰抗性", false],
		["res_thunder", "雷电抗性", false], ["res_ice", "冰冻抗性", false], ["res_holy", "神圣抗性", false],
	]],
	["行动", [
		["move", "移动力", true], ["speed", "速度", true], ["AP_max", "AP上限", true],
	]],
]

# —— 状态 ——
var _current: Dictionary = {}      # 正在编辑的物品（含未识别字段，保存时整体写回保留）
var _current_kind: String = ""     # weapon/armor/accessory（决定表单布局）
var _is_new: bool = false

# —— 控件引用 ——
var _list: ItemList
var _list_ids: Array = []          # 与列表行一一对应的 id
var _msg: Label
var _form: VBoxContainer           # 右侧表单容器（按类别重建）
var _save_btn: Button
var _del_btn: Button

# 表单控件（每次重建表单后重新赋值）
var _w_id: LineEdit
var _w_name: LineEdit
var _w_slot: OptionButton
var _slot_hint: Label
var _w_rarity: OptionButton
var _w_icon: LineEdit
var _w_tags: LineEdit
var _w_requires: LineEdit
var _mods_box: VBoxContainer
var _mod_rows: Array = []          # 每行 {stat:OptionButton, op:OptionButton, value:SpinBox}
# 武器
var _w_two_handed: CheckBox
var _w_innate: CheckBox
var _w_atk_name: LineEdit
var _w_atk_icon: LineEdit
var _w_atk_coeff: SpinBox
var _w_atk_range: SpinBox
var _w_atk_ap: SpinBox
var _w_atk_dmgkind: OptionButton
var _w_atk_tags: LineEdit


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_rarities = TagDB.ids_in_cat("rarity")
	if _rarities.is_empty():   # tags.json 缺失时的兜底，避免稀有度下拉空
		_rarities = ["common", "uncommon", "rare", "epic", "legendary", "special"]

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 20
	root.offset_top = 14
	root.offset_right = -20
	root.offset_bottom = -14
	root.add_theme_constant_override("separation", 10)
	add_child(root)

	# 标题行
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

	# 主体：左列表 + 右表单
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.split_offset = 300
	root.add_child(split)

	split.add_child(_build_left_pane())

	var right_scroll := ScrollContainer.new()
	right_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_form = VBoxContainer.new()
	_form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_form.add_theme_constant_override("separation", 8)
	right_scroll.add_child(_form)
	split.add_child(right_scroll)

	# 底栏：消息 + 保存
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


# 列出 ItemDB 全部物品（按 类别 → 名字 排序），行文本带类别 + 稀有度。
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
		var rar := _rarity_of(it)
		var txt := "[%s] %s  (%s)" % [KIND_CN.get(kind, kind), str(it.get("name", id)), id]
		_list.add_item(txt)
		var idx := _list.item_count - 1
		_list.set_item_custom_fg_color(idx, _rarity_color(rar))
		_list_ids.append(id)


func _on_list_select(idx: int) -> void:
	if idx < 0 or idx >= _list_ids.size():
		return
	_load_item(_list_ids[idx])


# —— 新建 / 加载 ——
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


func _update_slot_hint() -> void:
	if _slot_hint == null or not is_instance_valid(_slot_hint):
		return
	if _current_kind == "weapon":
		var h := "无（天生武器）"
		if not _innate_checked():
			h = "two_handed" if _two_handed_checked() else "one_handed"
		_slot_hint.text = "↳ 武器：槽位＝默认放置（单手可装主手/副手任一）；持握 tag「%s」（由双手/天生勾选决定，不带 main_hand/off_hand）" % h
	else:
		var it := EquipSlots.intrinsic_tag(_current_kind, _w_slot.get_selected_metadata(), false, false)
		_slot_hint.text = "↳ 自动带 tag「%s」（tag 驱动装备资格）" % it


func _two_handed_checked() -> bool:
	return _current_kind == "weapon" and _w_two_handed != null and is_instance_valid(_w_two_handed) and _w_two_handed.button_pressed


func _innate_checked() -> bool:
	return _current_kind == "weapon" and _w_innate != null and is_instance_valid(_w_innate) and _w_innate.button_pressed


# 各类别的预设骨架（点＋新建时的默认值）
func _skeleton(kind: String) -> Dictionary:
	match kind:
		"weapon":
			return {
				"id": "", "name": "新武器", "slot": "main_hand", "icon": "",
				"tags": ["common", "melee"], "requires": [], "mods": [],
				"two_handed": false, "innate": false,
				"attack": {
					"name": "普通攻击", "icon": "", "coeff": 1.0, "range": 1,
					"ap_cost": 1, "damage_kind": "physical", "tags": ["single_target"],
				},
			}
		"armor":
			return {
				"id": "", "name": "新防具", "slot": "armor", "icon": "",
				"tags": ["common"], "requires": [],
				"mods": [{"stat": "armor_max", "op": "flat", "value": 10}],   # 护甲池 = armor_max 的 mod
			}
		_:
			return {
				"id": "", "name": "新饰品", "slot": "accessory_1", "icon": "",
				"tags": ["common"], "requires": [], "mods": [],
			}


# —— 表单构建（按 _current_kind 重建）——
func _clear_form() -> void:
	for c in _form.get_children():
		c.queue_free()
	_mod_rows.clear()


func _build_form() -> void:
	_clear_form()

	_form.add_child(_section_label("基础"))
	_w_id = _add_line(_form, "id（唯一主键）", str(_current.get("id", "")))
	_w_name = _add_line(_form, "名字", str(_current.get("name", "")))

	# 槽位（按类别）
	_w_slot = OptionButton.new()
	for s in EquipSlots.SLOTS_BY_KIND.get(_current_kind, []):
		_w_slot.add_item("%s（%s）" % [EquipSlots.SLOT_CN.get(s, s), s])
		_w_slot.set_item_metadata(_w_slot.item_count - 1, s)
	_select_meta(_w_slot, str(_current.get("slot", "")))
	_form.add_child(_field_row("槽位", _w_slot))
	_slot_hint = Label.new()
	_slot_hint.add_theme_color_override("font_color", Color(0.55, 0.72, 0.6))
	_slot_hint.add_theme_font_size_override("font_size", 12)
	_form.add_child(_slot_hint)
	_w_slot.item_selected.connect(func(_i): _update_slot_hint())
	_update_slot_hint()

	# 稀有度
	_w_rarity = OptionButton.new()
	for r in _rarities:
		_w_rarity.add_item("%s（%s）" % [TagDB.cn(r), r])
		_w_rarity.set_item_metadata(_w_rarity.item_count - 1, r)
	_select_meta(_w_rarity, _rarity_of(_current))
	_form.add_child(_field_row("稀有度", _w_rarity))

	_w_icon = _add_line(_form, "立绘 icon（res://...png）", str(_current.get("icon", "")))
	_w_tags = _add_line(_form, "标签（逗号分隔；稀有度/槽位 tag 已自动管理，勿在此填）", _join(_other_tags(_current)))
	_w_requires = _add_line(_form, "装备需求 requires（逗号分隔 tag）", _join(_current.get("requires", [])))

	# 武器专属
	if _current_kind == "weapon":
		_form.add_child(_section_label("武器"))
		_w_two_handed = _add_check(_form, "双手（占主手+副手）", bool(_current.get("two_handed", false)))
		_w_innate = _add_check(_form, "天生武器（永不卸下；无单/双手词条、豁免天性武者限制）", bool(_current.get("innate", false)))
		_w_two_handed.toggled.connect(func(_v): _update_slot_hint())
		_w_innate.toggled.connect(func(_v): _update_slot_hint())
		_update_slot_hint()   # 双手/天生控件就位后刷新提示（武器持握 tag 取决于它们）
		_build_attack_form()

	# 修正
	_form.add_child(_section_label("修正 mods（每条加在装备者属性上）"))
	_mods_box = VBoxContainer.new()
	_mods_box.add_theme_constant_override("separation", 4)
	_form.add_child(_mods_box)
	for m in _current.get("mods", []):
		if typeof(m) == TYPE_DICTIONARY:
			_add_mod_row(str(m.get("stat", "atk")), str(m.get("op", "flat")), float(m.get("value", 0)))
	var addmod := Button.new()
	addmod.text = "＋ 添加修正"
	addmod.pressed.connect(func(): _add_mod_row("atk", "flat", 0.0))
	_form.add_child(addmod)


func _build_attack_form() -> void:
	var atk = _current.get("attack", {})
	if typeof(atk) != TYPE_DICTIONARY:
		atk = {}
	_form.add_child(_section_label("基础攻击 skill（装备武器 = 设定该单位的基础攻击）"))
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
	_form.add_child(_field_row("伤害类型 damage_kind", _w_atk_dmgkind))
	_w_atk_tags = _add_line(_form, "攻击标签（逗号分隔）", _join(atk.get("tags", [])))
	var note := Label.new()
	note.text = "（aoe / bonus / inflict / armor_pen 等高级字段本版不编辑，保存时原样保留）"
	note.add_theme_color_override("font_color", Color(0.6, 0.62, 0.68))
	note.add_theme_font_size_override("font_size", 12)
	_form.add_child(note)


# —— mods 动态行 ——
func _add_mod_row(stat: String, op: String, value: float) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var st := OptionButton.new()
	st.custom_minimum_size = Vector2(180, 0)
	_fill_stat_options(st)
	_select_meta(st, stat)
	row.add_child(st)

	var opb := OptionButton.new()
	opb.custom_minimum_size = Vector2(110, 0)
	for o in OPS:
		opb.add_item(o[1])
		opb.set_item_metadata(opb.item_count - 1, o[0])
	_select_meta(opb, op)
	row.add_child(opb)

	var val := SpinBox.new()
	val.min_value = -9999
	val.max_value = 9999
	val.step = 0.5
	val.value = value
	val.custom_minimum_size = Vector2(110, 0)
	row.add_child(val)

	var rm := Button.new()
	rm.text = "✕"
	var entry := {"stat": st, "op": opb, "value": val, "row": row}
	rm.pressed.connect(func():
		_mod_rows.erase(entry)
		row.queue_free())
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
	# 新建时禁止 id 撞已存在物品
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


# 从表单控件收集成物品 dict（以 _current 为底，保留未编辑的字段如 attack 高级项）
func _collect() -> Dictionary:
	var out: Dictionary = _current.duplicate(true)
	out["id"] = _w_id.text.strip_edges()
	out["name"] = _w_name.text.strip_edges()
	var slot = _w_slot.get_selected_metadata()
	out["slot"] = slot
	out["icon"] = _w_icon.text.strip_edges()
	# tags = [稀有度] + [槽位类别 tag] + 其它自由标签（去重；稀有度/槽位 tag 自动管理、置首）
	var rar: String = _w_rarity.get_selected_metadata()
	var tags := [rar]
	var it_tag: String = EquipSlots.intrinsic_tag(_current_kind, slot, _two_handed_checked(), _innate_checked())
	if it_tag != "" and not tags.has(it_tag):
		tags.append(it_tag)
	for t in _split(_w_tags.text):
		if not _rarities.has(t) and not EquipSlots.MANAGED_TAGS.has(t) and not tags.has(t):
			tags.append(t)
	out["tags"] = tags
	out["requires"] = _split(_w_requires.text)
	# mods
	var mods := []
	for e in _mod_rows:
		mods.append({
			"stat": e["stat"].get_selected_metadata(),
			"op": e["op"].get_selected_metadata(),
			"value": _num(e["value"].value),
		})
	out["mods"] = mods
	# 武器专属
	if _current_kind == "weapon":
		out["two_handed"] = _w_two_handed.button_pressed
		out["innate"] = _w_innate.button_pressed
		var atk: Dictionary = out.get("attack", {})
		if typeof(atk) != TYPE_DICTIONARY:
			atk = {}
		atk["name"] = _w_atk_name.text.strip_edges()
		atk["icon"] = _w_atk_icon.text.strip_edges()
		atk["coeff"] = _num(_w_atk_coeff.value)
		atk["range"] = int(_w_atk_range.value)
		atk["ap_cost"] = int(_w_atk_ap.value)
		atk["damage_kind"] = _w_atk_dmgkind.get_selected_metadata()
		atk["tags"] = _split(_w_atk_tags.text)
		out["attack"] = atk
	return out


# —— 小工具 ——
# 整数化无尾巴（4.0→4），否则保留小数：避免 JSON 里全是 x.0
func _num(v: float):
	return int(v) if v == floor(v) else v

func _rarity_of(item) -> String:
	for t in item.get("tags", []):
		if _rarities.has(str(t)):
			return str(t)
	return "common"

func _other_tags(item) -> Array:
	var out := []
	for t in item.get("tags", []):
		var s := str(t)
		if not _rarities.has(s) and not EquipSlots.MANAGED_TAGS.has(s):
			out.append(s)
	return out

func _rarity_color(rar: String) -> Color:
	var c := TagDB.color(rar)
	return Color(c) if c != "" else Color("#E0E0E0")

func _join(arr) -> String:
	var parts := []
	for x in arr:
		parts.append(str(x))
	return ", ".join(parts)

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
	# 没匹配到：选第一个非分隔项
	for i in ob.item_count:
		if ob.is_item_disabled(i) == false and ob.get_item_metadata(i) != null:
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
	parent.add_child(_field_row(label, le))
	return le

func _add_check(parent: VBoxContainer, label: String, value: bool) -> CheckBox:
	var cb := CheckBox.new()
	cb.button_pressed = value
	parent.add_child(_field_row(label, cb))
	return cb

func _add_spin(parent: VBoxContainer, label: String, value: float, mn: float, mx: float, step: float) -> SpinBox:
	var sb := SpinBox.new()
	sb.min_value = mn
	sb.max_value = mx
	sb.step = step
	sb.value = value
	parent.add_child(_field_row(label, sb))
	return sb
