extends "res://ListEditorShell.gd"
## 物品编辑器：创作游戏正式物品（武器 / 防具 / 饰品），写回 res://data/*.json。
## 入口 StartMenu →「物品编辑器」；CRUD 外壳（清单/行卡/保存删除流程/脏守卫）＝ListEditorShell 基类，本类只管表单+预览。
## tag 设计（用户校准）：槽位非物品 tag、自动派生；类型/种类等用「分类下拉」（读 TagDB.by_cat）。
##  武器：先选【类型】(近战/投掷/远程/触媒/盾，单选互斥) → 类型级联决定【种类】可选项；投掷无种类、盾不显握持。
##  防具：部位(头盔/身甲)+种类(轻/中/重)。其他标签：下拉(选中即加)+手动(确认)。只「天生武器」需勾选。

const ItemDB := preload("res://ItemDB.gd")
const EquipSlots := preload("res://EquipSlots.gd")
const TagDB := preload("res://TagDB.gd")
const ItemTooltip := preload("res://ItemTooltip.gd")     # 物品富 tooltip 通用渲染组件（与角色状态页共用）
const StatMeta := preload("res://StatMeta.gd")           # stat 键→中文单一源（本编辑器不再自带并行对照表）
const SkillDB := preload("res://SkillDB.gd")             # 武器技能引用位（BWS 下拉/EWS 行，🔒 决策25/26 引用制）
const ProfDB := preload("res://ProfDB.gd")               # EWS 解锁条件（技艺域下拉+档位名提示）
# EditorTheme / EditorUI / TextureCache 由 ListEditorShell 继承

const ICON_DIR := {
	"weapon": "res://icons/Items/Weapons",
	"armor": "res://icons/Items/Armors",
	"accessory": "res://icons/Items/Accessories",
	"item": "res://icons/Items",
}
const OPS := [["flat", "固定"], ["pct", "百分比%"]]
const PREFER_PAIRS := [["", "（无）"], ["ground", "地面（落地换进主手）"], ["air", "空中（起飞换进主手）"]]   # 比路兹式起降换手
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

# —— 状态（外壳态 _is_new/_loaded_id/_dirty/_rows/_selected_id 等在 ListEditorShell）——
var _rarities: Array = []
var _managed_tag_set: Dictionary = {}
var _current: Dictionary = {}
var _current_kind: String = ""
var _free_tags: Array = []
var _requires: Array = []   # 装备需求 tag（装备者须全部具备，如 char_desmond）

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
var _form: VBoxContainer
var _preview: VBoxContainer
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
# 修正 / 武器技能（🔒 决策25/26 引用制：BWS 普攻位 + EWS 额外技能位；招式本体在技能编辑器）
var _mods_box: VBoxContainer
var _mod_rows: Array = []
var _w_bws: OptionButton         # 普攻 BWS 下拉（is_bas_shaped 形状过滤，决策27；（无）＝不提供普攻，如盾）
var _w_prefer: OptionButton      # 地/空偏好（比路兹式起降换手；一般武器（无））
var _ews_box: VBoxContainer      # EWS 行容器
var _ews_rows: Array = []        # EWS 行：[{panel, skill:OptionButton, reqs:[{row,prof,value,hint}], reqs_box}]
var _building: bool = false      # _build_form 进行中（抑制「选盾自动清 BWS」等用户动作专属逻辑）


# —— 外壳钩子（ListEditorShell）——

func _shell_init() -> void:
	_rarities = TagDB.ids_in_cat("rarity")
	if _rarities.is_empty():
		_rarities = ["common", "uncommon", "rare", "epic", "legendary", "special"]
	_build_managed_set()

func _shell_title() -> String:
	return "物品编辑器"

func _shell_new_label() -> String:
	return "＋ 新建（大类在表单里选）"

func _shell_new_entry() -> void:
	_do_new_item("weapon")   # 默认武器；基础区「物品大类」下拉可改成防具/饰品/物品

func _shell_load(id: String) -> void:
	_load_item(id)

func _shell_discard_text() -> String:
	return "当前物品有未保存的修改，继续将丢弃。"

func _shell_has_entry() -> bool:
	return _w_id != null and is_instance_valid(_w_id)

# 右侧＝再一道 HSplit：表单（中）+ 即时预览（右）
func _shell_build_right(split: HSplitContainer) -> void:
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


func _build_managed_set() -> void:
	_managed_tag_set = {}
	for cat in MANAGED_CATS:
		for id in TagDB.ids_in_cat(cat):
			_managed_tag_set[id] = true
	for s in ["main_hand", "off_hand"]:
		_managed_tag_set[s] = true


# 分类清单：三大折叠组（武器/防具/饰品）+ 组内按 类型→种类→名字 排序 + 类型分隔标签。
func _shell_populate_list(q: String) -> void:
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
			var row := _make_row_card(id, TextureCache.get_tex(str(it.get("icon", ""))),
				str(it.get("name", id)), _rarity_color(_rarity_of(it)), 42, Vector2(32, 32), _row_tooltip(it))
			section.add_child(row)
			_rows[id] = row
		if ids.is_empty():
			var hint := Label.new()
			hint.text = "（无匹配）" if searching else "（暂无——点上方「＋新建」、大类选「%s」）" % ItemDB.kind_cn(kind)
			hint.add_theme_color_override("font_color", Color(0.5, 0.54, 0.6))
			hint.add_theme_font_size_override("font_size", 12)
			section.add_child(hint)
		_add_fold_group(kind, "%s (%d)" % [ItemDB.kind_cn(kind), ids.size()], section, searching)


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

func _do_new_item(kind: String) -> void:
	_current = _skeleton(kind)
	_current_kind = kind
	_is_new = true
	_loaded_id = ""
	_select_row("")
	_build_form()
	_update_buttons()
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
	_update_buttons()
	_info("编辑「%s」" % str(_current.get("name", id)))
	_select_row(id)


# 副本以「新建未保存」态打开（外壳 _on_duplicate 已做 id 唯一化/置脏/消息）
func _shell_open_as_new(entry: Dictionary) -> void:
	_current = entry
	_current_kind = ItemDB.kind_of(entry)
	_is_new = true
	_loaded_id = ""
	_build_form()


func _shell_show_empty() -> void:
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
			# 武器技能＝引用制（🔒 决策25/26）：bws/ews 引用技能库条目，不再内嵌 attack；新武器待选 BWS
			return {"id": "", "name": "新武器", "slot": "main_hand", "icon": "",
				"tags": ["common", "melee", "weapon_sword", "one_handed"], "requires": [], "mods": [],
				"two_handed": false, "innate": false}
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
	_ews_rows = []
	_free_tags = []
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

	# 4. 武器技能（仅武器，放底部）：BWS/EWS 引用位（🔒 决策25/26）
	if _current_kind == "weapon":
		_build_weapon_skills_section()

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
	# 盾不提供普攻：用户切到盾时自动清 BWS 选择（仍可手动选回；载入初始化 _building 时不强改）
	if not _building and wtype == "shield" and _w_bws != null and is_instance_valid(_w_bws):
		_select_meta(_w_bws, "")
	_refresh_preview()


# ============ 武器技能段（🔒 决策25/26 引用制：只引用技能库、不内嵌创建；招式参数去技能编辑器改）============

# BWS 普攻位（is_bas_shaped 形状过滤——决策27 关系制：BWS 身份由本引用决定，技能库不声明） + 地/空偏好
# + EWS 行（每条：技能引用+复数 AND 解锁条件）。同一技能可既是 A 武器 BWS 又是 B 武器 EWS。
func _build_weapon_skills_section() -> void:
	_form.add_child(EditorUI.section_title("武器技能（引用技能库条目；招式参数在技能编辑器改——决策25 引用制）"))
	_w_bws = OptionButton.new()
	_w_bws.add_item("（无——不提供普攻，如盾）")
	_w_bws.set_item_metadata(0, "")
	for id in SkillDB.all():
		var def = SkillDB.get_skill(id)
		if SkillDB.is_bas_shaped(def):
			_w_bws.add_item("%s（%s）" % [str(def.get("name", id)), str(id)])
			_w_bws.set_item_metadata(_w_bws.item_count - 1, str(id))
	var cur_bws := str(_current.get("bws", _current.get("bas", "")))
	_ensure_meta_option(_w_bws, cur_bws)
	_select_meta(_w_bws, cur_bws)
	_w_bws.item_selected.connect(func(_i): _refresh_preview())
	_form.add_child(EditorUI.field_row("普攻 BWS（装备即用；列 BAS 形＝含攻击块·无冷却·无级·无手门槛·次数无限）", _w_bws))
	# prefer 初值双读 attack.prefer（同 Unit._weapon_prefer 口径）：未迁移武器打开不丢偏好
	var atk0 = _current.get("attack", {})
	var prefer0 := str(_current.get("prefer", atk0.get("prefer", "") if typeof(atk0) == TYPE_DICTIONARY else ""))
	_w_prefer = _dropdown_pairs(_form, "地/空偏好 prefer（比路兹式起降换手）", PREFER_PAIRS, prefer0)
	# 旧内联 attack 残留（未迁移数据）：提示——未选 BWS 时保存原样保留、选了 BWS 保存即移除（被引用取代）
	if typeof(_current.get("attack", null)) == TYPE_DICTIONARY:
		var warn := Label.new()
		warn.text = "⚠ 本武器仍带旧内联 attack：未选 BWS＝保存原样保留（双读窗口）；选了 BWS＝保存时移除（引用取代）"
		warn.add_theme_color_override("font_color", Color(0.95, 0.8, 0.35))
		warn.add_theme_font_size_override("font_size", 12)
		warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_form.add_child(warn)
	# EWS 额外技能位：装备授予、达标解锁、以能力形式使用（🔒 决策26；运行时恒读主手——决策28）
	_form.add_child(EditorUI.section_title("额外技能 EWS（装备授予；每条可配复数 AND 解锁条件〔技艺+熟练度裸数值〕；运行时恒读主手）"))
	_ews_rows = []
	_ews_box = VBoxContainer.new()
	_ews_box.add_theme_constant_override("separation", 6)
	_form.add_child(_ews_box)
	for e in _current.get("ews", []):
		if typeof(e) == TYPE_DICTIONARY:
			_add_ews_row(str(e.get("skill", "")), e.get("requires", []))
		else:
			_add_ews_row(str(e), [])   # 决策22 兼容：裸 id＝无条件
	var addews := Button.new()
	addews.text = "＋ 添加额外技能"
	addews.pressed.connect(func():
		_add_ews_row("", [])
		_refresh_preview())
	_form.add_child(addews)

# 载入引用不在下拉（技能被删/被新过滤规则挡）→ 补「⚠ 悬空引用」项保值：
# 否则 _select_meta 静默回退首项，随手保存＝剥掉数据里的引用（审查确认项3）。lint 会另行标红悬空数据。
func _ensure_meta_option(ob: OptionButton, key: String) -> void:
	if key == "":
		return
	for i in ob.item_count:
		var m = ob.get_item_metadata(i)
		if m != null and str(m) == key:
			return
	ob.add_item("⚠ 悬空引用：%s" % key)
	ob.set_item_metadata(ob.item_count - 1, key)

# 一条 EWS：技能下拉（主动+可跑块过滤）+ ✕；下挂条件行列表 + ＋添加条件
func _add_ews_row(skill_id: String, requires) -> void:
	var panel := PanelContainer.new()
	var sb := EditorTheme.sb(Color(0.14, 0.15, 0.19), Color(0.3, 0.34, 0.42))
	sb.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	panel.add_child(box)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	var pick := OptionButton.new()
	pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pick.add_item("（选技能…）")
	pick.set_item_metadata(0, "")
	for id in SkillDB.all():
		var def = SkillDB.get_skill(id)
		# 纯 attack 块技能排除：能力路径跑不了（apply_skill 守卫拒发）——attack 类 EWS＝阶段6 放开；lint 规则8 同闸
		if bool(def.get("active", false)) and SkillDB.has_runnable_block(def):
			pick.add_item("%s（%s）" % [str(def.get("name", id)), str(id)])
			pick.set_item_metadata(pick.item_count - 1, str(id))
	_ensure_meta_option(pick, skill_id)
	_select_meta(pick, skill_id)
	pick.item_selected.connect(func(_i): _refresh_preview())
	head.add_child(pick)
	var rm := Button.new()
	rm.text = "✕"
	head.add_child(rm)
	box.add_child(head)
	var reqs_box := VBoxContainer.new()
	reqs_box.add_theme_constant_override("separation", 3)
	box.add_child(reqs_box)
	var entry := {"panel": panel, "skill": pick, "reqs": [], "reqs_box": reqs_box}
	rm.pressed.connect(func():
		_ews_rows.erase(entry)
		panel.queue_free()
		_refresh_preview())
	if typeof(requires) == TYPE_ARRAY:
		for r in requires:
			if typeof(r) == TYPE_DICTIONARY:
				_add_ews_req_row(entry, str(r.get("prof", "")), int(r.get("value", 0)))
	var addr := Button.new()
	addr.text = "＋ 添加解锁条件"
	addr.pressed.connect(func():
		_add_ews_req_row(entry, "", 100)
		_refresh_preview())
	box.add_child(addr)
	_ews_box.add_child(panel)
	_ews_rows.append(entry)

# 一条解锁条件：技艺域下拉 + ≥ 裸数值 + 档位名提示（🔒 决策26 阈值口径＝裸数值，旁标档位辅助可读）
func _add_ews_req_row(entry: Dictionary, prof: String, value: int) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.add_child(EditorUI.label("　需"))
	var pf := OptionButton.new()
	pf.custom_minimum_size = Vector2(190, 0)
	pf.add_item("（选技艺…）")
	pf.set_item_metadata(0, "")
	for pid in ProfDB.all_ids():
		pf.add_item("%s（%s）" % [ProfDB.prof_name(str(pid)), str(pid)])
		pf.set_item_metadata(pf.item_count - 1, str(pid))
	_ensure_meta_option(pf, prof)
	_select_meta(pf, prof)
	pf.item_selected.connect(func(_i): _refresh_preview())
	row.add_child(pf)
	row.add_child(EditorUI.label("≥"))
	var val := SpinBox.new()
	val.min_value = 0
	val.max_value = 1500
	val.step = 10
	val.value = value
	val.custom_minimum_size = Vector2(100, 0)
	row.add_child(val)
	var hint := Label.new()
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.72))
	hint.add_theme_font_size_override("font_size", 12)
	var sync_hint := func():
		hint.text = "（%s）" % ProfDB.stage_name(ProfDB.stage_of(int(val.value)))
	sync_hint.call()
	val.value_changed.connect(func(_v):
		sync_hint.call()
		_refresh_preview())
	row.add_child(hint)
	var rm := Button.new()
	rm.text = "✕"
	var rentry := {"row": row, "prof": pf, "value": val}
	rm.pressed.connect(func():
		(entry["reqs"] as Array).erase(rentry)
		row.queue_free()
		_refresh_preview())
	row.add_child(rm)
	(entry["reqs_box"] as VBoxContainer).add_child(row)
	(entry["reqs"] as Array).append(rentry)


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


# —— 自由标签 UI → 公共件 EditorUI.add_tag_list（🔒 技能设计 §10 阶段2.4 抽通用）——
# 本类只出「该 mode 下拉给哪些预设」（_tag_offered 过滤 + 按类别分隔）。
func _build_free_tag_ui(parent: VBoxContainer, mode: String, label: String, arr: Array) -> void:
	EditorUI.add_tag_list(parent, label, arr, _tag_options(mode), _refresh_preview)

func _tag_options(mode: String) -> Array:
	var cats := {}
	var all := TagDB.all()
	for id in all:
		if not _tag_offered(str(id), all[id], mode):
			continue
		var c := str(all[id].get("cat", "其他"))
		if not cats.has(c):
			cats[c] = []
		cats[c].append(id)
	var out := []
	for c in cats:
		out.append(["sep", str(CATEGORY_CN.get(c, c))])
		for id in cats[c]:
			out.append([id, "%s（%s）" % [TagDB.cn(id), id]])
	return out


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


# —— 保存 / 删除（流程在外壳，这里只挂库口与消息）——

func _shell_collect() -> Dictionary:
	return _collect()

func _shell_exists(id: String) -> bool:
	return ItemDB.get_item(id) != null

func _shell_db_save(entry: Dictionary, replace_id: String) -> bool:
	return ItemDB.save_item(entry, replace_id)

func _shell_db_delete(id: String) -> bool:
	return ItemDB.delete_item(id)

func _shell_after_save(entry: Dictionary, id: String, renaming: bool) -> void:
	if renaming:
		_info("✓ 已保存并改 id：%s → %s　⚠ 旧战役档里引用旧 id 的装备实例会失效" % [_loaded_id, id])
		push_warning("ItemEditor：物品 id %s → %s——已有存档中的实例 tpl_id 不随迁" % [_loaded_id, id])
	else:
		_info("✓ 已保存「%s」→ %s" % [str(entry.get("name", id)), ItemDB.kind_of(entry) + ".json"])
	_current = entry

func _shell_delete_confirm_text(id: String) -> String:
	return "确认删除「%s」(%s)？此操作直接写盘。" % [str(_current.get("name", id)), id]


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
			# 武器技能（🔒 决策25/26 引用制）：BWS 选中→写 bws、移除旧内联 attack（被引用取代）+ 收口旧键 bas；
			# 未选→清 bws（不提供普攻，如盾）、旧内联 attack 原样保留（双读窗口，未迁移数据不破坏）
			var bws_id := str(_w_bws.get_selected_metadata()) if _w_bws != null and is_instance_valid(_w_bws) else ""
			if bws_id != "":
				out["bws"] = bws_id
				out.erase("bas")
				out.erase("attack")
			else:
				out.erase("bws")
				out.erase("bas")
			var prefer := str(_w_prefer.get_selected_metadata()) if _w_prefer != null and is_instance_valid(_w_prefer) else ""
			if prefer != "":
				out["prefer"] = prefer
			else:
				out.erase("prefer")
			# EWS：每条 {skill, requires:[{prof,value},…]}（requires 空省略＝装备即用；空技能行跳过）
			var ews := []
			for e in _ews_rows:
				var sid := str(e["skill"].get_selected_metadata())
				if sid == "":
					continue
				var entry := {"skill": sid}
				var reqs := []
				for rr in e["reqs"]:
					var pid := str(rr["prof"].get_selected_metadata())
					if pid == "":
						continue
					reqs.append({"prof": pid, "value": int(rr["value"].value)})
				if not reqs.is_empty():
					entry["requires"] = reqs
				ews.append(entry)
			if ews.is_empty():
				out.erase("ews")
			else:
				out["ews"] = ews
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
	for k in ["slot", "mods", "requires", "two_handed", "innate", "attack", "bws", "bas", "ews", "prefer", "use_scope"]:
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

# _select_meta 在 ListEditorShell（按 metadata 选中 + 回退首个有效项）

# 表单动态字段 → 公共层 EditorUI（信号统一走 _refresh_preview）
func _add_line(parent: VBoxContainer, label: String, value: String) -> LineEdit:
	return EditorUI.add_line(parent, label, value, _refresh_preview)

func _add_check(parent: VBoxContainer, label: String, value: bool) -> CheckBox:
	return EditorUI.add_check(parent, label, value, _refresh_preview)

func _add_spin(parent: VBoxContainer, label: String, value: float, mn: float, mx: float, step: float) -> SpinBox:
	return EditorUI.add_spin(parent, label, value, mn, mx, step, _refresh_preview)
