extends "res://ListEditorShell.gd"
## 技能编辑器（能力 Ability）：拼装/调参 data/skills.json 条目，写盘走 SkillDB.save_skill。
## 🔒 设计真值＝docs/模块_技能_设计.md（schema §2.1 / 效果块调色盘 §3 / 公式 §2.4 / 护栏 §10）。
## 本质＝用预设「效果块」模板拼装技能（非通用 DSL）；复杂专属逻辑走 scripted 逃生舱。
## v1 可编块：attack(单 hit+公式) / heal / passive_stat_mods / apply_effect / scripted。
## 「可编不可跑」护栏（§10）：多 hits / riders＝阶段6 禁入库（块锁定只读）；weapon_source＝3b、
##   passive_stat_mods＝阶段4 均已生效（绿条说明）；scripted 需代码注册——黄条警示；未编辑高级字段保存原样保留。
##   conditional_mod 块＝阶段4 引擎可跑（when 词表 §4 v1），编辑器表单待做——现存原样保留（未知块黄条）。
## 存盘校验与 test_data_lint 规则7 对齐（编辑器先拦，别让 lint 红）：BAS 约束 / target 三旗全 false /
##   seq 撞格 / per_level 长度==max_level / costs.ap 与顶层 ap_cost 禁双写（收集时剥旧键）。
## 效果库（EffectDB）＝独立 EffectEditor 场景，标题栏分段切换（仿工坊切换器，脏守卫接管）。

const SkillDB := preload("res://SkillDB.gd")
const EffectDB := preload("res://EffectDB.gd")
const TagDB := preload("res://TagDB.gd")
const StatMeta := preload("res://StatMeta.gd")

const ICON_DIR := "res://icons/Skills"
const NATURES := [["skill", "技巧 skill"], ["spell", "魔法 spell（魔法系统后置）"]]
const DAMAGE_KINDS := ["physical", "fire", "ice", "thunder", "holy"]
const HAND_SLOTS := [["main_hand", "主手"], ["off_hand", "副手"]]
const BLOCK_KINDS := [["attack", "攻击 attack"], ["heal", "治疗 heal"],
	["passive_stat_mods", "被动修正 passive_stat_mods"],
	["apply_effect", "施加效果 apply_effect"], ["scripted", "脚本 scripted"]]
# 技能 tag 下拉预设的类别（§2.1 tags：verbal 等玩家可读/可筛词；其余手动）
const SKILL_TAG_CATS := ["skill_type", "target", "damage"]
const WARN_COLOR := Color(0.95, 0.8, 0.35)    # 黄＝可编不可跑警示
const LOCK_COLOR := Color(0.92, 0.5, 0.45)    # 红＝阶段6 前禁入库（块锁定）
const HINT_COLOR := Color(0.55, 0.75, 0.55)   # 绿＝纯说明（字段已生效，非警示）

# —— 状态 ——
var _current: Dictionary = {}
var _tags: Array = []
var _hand_rows: Array = []    # requires_hands 行：[{row, slot:OptionButton, all:LineEdit, any:LineEdit}]
var _blocks: Array = []       # 效果块：[{data, kind, panel, ...控件}]（data＝原始块，collect 时 duplicate+更新）

# —— 控件 ——
var _form: VBoxContainer
var _file_dialog: FileDialog
var _icon_thumb: TextureRect
var _w_id: LineEdit
var _w_name: LineEdit
var _w_icon: LineEdit
var _w_desc: TextEdit
var _w_nature: OptionButton
var _w_active: CheckBox
var _w_seq: SpinBox
var _w_ap: SpinBox
var _w_cd: SpinBox
var _w_uses: SpinBox
var _w_maxlv: SpinBox
var _w_range: SpinBox
var _w_t_enemy: CheckBox
var _w_t_ally: CheckBox
var _w_t_self: CheckBox
var _hands_box: VBoxContainer
var _blocks_box: VBoxContainer
var _block_pick: OptionButton


# —— 外壳钩子（ListEditorShell）——

func _shell_title() -> String:
	return "技能编辑器"

func _shell_new_label() -> String:
	return "＋ 新建能力"

func _shell_new_entry() -> void:
	_open_skill(_skeleton(), true)
	_select_row("")
	_info("新建能力——填好 id（唯一）后点保存")

func _shell_load(id: String) -> void:
	var def = SkillDB.get_skill(id)
	if def == null:
		return
	_open_skill((def as Dictionary).duplicate(true), false)
	_select_row(id)
	_info("编辑「%s」" % str(_current.get("name", id)))

func _shell_discard_text() -> String:
	return "当前能力有未保存的修改，继续将丢弃。"

func _shell_has_entry() -> bool:
	return _w_id != null and is_instance_valid(_w_id)

func _shell_titlebar_extras(titlebar: HBoxContainer) -> void:
	titlebar.add_child(EditorUI.scene_switch(self, "skill",
		[["skill", "⚔ 能力库", "res://SkillEditor.tscn"], ["effect", "✨ 效果库", "res://EffectEditor.tscn"]],
		_confirm_discard))

func _shell_build_right(split: HSplitContainer) -> void:
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_form = VBoxContainer.new()
	_form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_form.add_theme_constant_override("separation", 8)
	scroll.add_child(_form)
	split.add_child(scroll)

func _shell_show_empty() -> void:
	_clear_form()
	_select_row("")
	_w_id = null   # 无表单态（外壳按 _shell_has_entry 走）
	var hint := Label.new()
	hint.text = "← 选左侧能力编辑，或点「＋ 新建能力」；效果（buff/debuff）在右上「✨ 效果库」"
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.72))
	_form.add_child(hint)
	_dirty = false

# 清单：武器普攻 BWS / 主动 / 被动 三折叠组；组内按 seq→名字 排序。
func _shell_populate_list(q: String) -> void:
	var searching := q != ""
	var groups := {"bws": [], "active": [], "passive": []}
	for id in SkillDB.all():
		var s = SkillDB.all()[id]
		var nm := str(s.get("name", id))
		if searching and not (str(id).to_lower().contains(q) or nm.to_lower().contains(q)):
			continue
		if SkillDB.is_bas_shaped(s):
			groups["bws"].append(s)   # 计算判定非声明（决策27）：分组只是导航便利，编辑器不感知 BWS/EWS 角色
		elif bool(s.get("active", true)):
			groups["active"].append(s)
		else:
			groups["passive"].append(s)
	for g in [["active", "主动能力"], ["passive", "被动能力"], ["bws", "普攻形（可被武器引为 BWS）"]]:
		var key := str(g[0])
		var arr: Array = groups[key]
		arr.sort_custom(func(a, b): return _sort_key(a) < _sort_key(b))
		var section := VBoxContainer.new()
		section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		section.add_theme_constant_override("separation", 2)
		for s in arr:
			var id := str(s.get("id", ""))
			var row := _make_row_card(id, TextureCache.get_tex(str(s.get("icon", ""))),
				str(s.get("name", id)), null, 42, Vector2(32, 32), str(s.get("desc", "")))
			section.add_child(row)
			_rows[id] = row
		if arr.is_empty():
			var hint := Label.new()
			hint.text = "（无匹配）" if searching else "（暂无）"
			hint.add_theme_color_override("font_color", Color(0.5, 0.54, 0.6))
			hint.add_theme_font_size_override("font_size", 12)
			section.add_child(hint)
		_add_fold_group(key, "%s (%d)" % [str(g[1]), arr.size()], section, searching)

func _sort_key(s: Dictionary) -> String:
	return "%02d|%s" % [int(s.get("seq", 99)), str(s.get("name", "")).to_lower()]


# —— 新建 / 载入 / 副本 ——

# 骨架＝canonical 键序（§2.1 示例序；字节级往返靠「duplicate 原条目+按键更新」保序）
func _skeleton() -> Dictionary:
	return {"id": "", "name": "新能力", "icon": "", "nature": "skill", "desc": "",
		"active": true, "tags": [],
		"costs": {"ap": 1}, "cooldown": {"base": 0}, "uses_per_battle": {"base": 0},
		"max_level": 1, "target": {"enemy": true, "ally": false, "self": false},
		"range": 1, "requires_hands": [], "effects": []}

func _open_skill(def: Dictionary, is_new: bool) -> void:
	_current = def
	_is_new = is_new
	_loaded_id = "" if is_new else str(def.get("id", ""))
	_build_form()
	_update_buttons()

func _shell_open_as_new(entry: Dictionary) -> void:
	_current = entry
	_is_new = true
	_loaded_id = ""
	_build_form()


# —— 表单 ——

func _clear_form() -> void:
	for c in _form.get_children():
		c.queue_free()
	_tags = []
	_hand_rows = []
	_blocks = []

func _build_form() -> void:
	_clear_form()
	# 1. 基础
	_form.add_child(EditorUI.section_title("基础"))
	_w_id = EditorUI.add_line(_form, "id（唯一主键）", str(_current.get("id", "")), _mark_dirty)
	_w_name = EditorUI.add_line(_form, "名字", str(_current.get("name", "")), _mark_dirty)
	_build_icon_row()
	_w_desc = TextEdit.new()
	_w_desc.text = str(_current.get("desc", ""))
	_w_desc.custom_minimum_size = Vector2(0, 64)
	_w_desc.scroll_fit_content_height = true
	_w_desc.text_changed.connect(_mark_dirty)
	_form.add_child(EditorUI.field_row("描述 desc", _w_desc))
	_w_nature = _dropdown_pairs("性质 nature", NATURES, str(_current.get("nature", "skill")))
	_w_active = EditorUI.add_check(_form, "主动能力 active（关＝被动，状态页圆框陈列）", bool(_current.get("active", true)), _mark_dirty)
	# 无 usable_as_bas 勾选（决策27 关系制）：技能编辑器只管技能做什么；能否被引为 BWS＝形状（is_bas_shaped）在物品编辑器/lint 判
	_w_seq = EditorUI.add_spin(_form, "通用序列槽 seq（0=不占；1-13 全库唯一）", float(_current.get("seq", 0)), 0, 13, 1, _mark_dirty)

	# 2. 标签
	_form.add_child(EditorUI.section_title("技能标签（verbal=需发声、失语时禁用）"))
	_tags = []
	for t in _current.get("tags", []):
		_tags.append(str(t))
	EditorUI.add_tag_list(_form, "tags", _tags, _tag_options(), _mark_dirty)

	# 3. 成本 / 限制
	_form.add_child(EditorUI.section_title("成本 / 限制"))
	var costs = _current.get("costs", {})
	_w_ap = EditorUI.add_spin(_form, "AP 消耗 costs.ap（运行时钳底 1——决策21）",
		float(costs.get("ap", 1) if typeof(costs) == TYPE_DICTIONARY else _current.get("ap_cost", 1)), 0, 9, 1, _mark_dirty)
	_w_cd = EditorUI.add_spin(_form, "冷却 cooldown.base（回合；0=无冷却）",
		float((_current.get("cooldown", {}) as Dictionary).get("base", 0)), 0, 9, 1, _mark_dirty)
	_w_uses = EditorUI.add_spin(_form, "每战次数 uses_per_battle.base（0=无限 ∞）",
		float((_current.get("uses_per_battle", {}) as Dictionary).get("base", 0)), 0, 9, 1, _mark_dirty)
	_w_maxlv = EditorUI.add_spin(_form, "技能等级数 max_level（各级参数=per_level 数组长度）",
		float(_current.get("max_level", 1)), 1, 5, 1, _mark_dirty)
	_w_range = EditorUI.add_spin(_form, "射程 range（格；0=自身/同格）", float(_current.get("range", 1)), 0, 20, 1, _mark_dirty)
	# 目标三旗（🔒 §2.7 正交自由组合；全 false=永不可施放，存盘拦）
	var trow := HBoxContainer.new()
	trow.add_theme_constant_override("separation", 12)
	var tg = _current.get("target", {"enemy": false, "ally": true, "self": true})
	if typeof(tg) != TYPE_DICTIONARY:
		tg = {}
	_w_t_enemy = _flag_check(trow, "敌方 enemy", bool(tg.get("enemy", false)))
	_w_t_ally = _flag_check(trow, "友方 ally", bool(tg.get("ally", false)))
	_w_t_self = _flag_check(trow, "自身 self", bool(tg.get("self", false)))
	_form.add_child(EditorUI.field_row("目标资格 target", trow))

	# 4. 手部门槛 requires_hands（§2.5；BAS 必须空）
	_form.add_child(EditorUI.section_title("手部门槛 requires_hands（逐槽查武器 tag；BAS 必须空）"))
	_hands_box = VBoxContainer.new()
	_hands_box.add_theme_constant_override("separation", 4)
	_form.add_child(_hands_box)
	for h in _current.get("requires_hands", []):
		if typeof(h) == TYPE_DICTIONARY:
			_add_hand_row(str(h.get("slot", "main_hand")), h.get("all_tags", []), h.get("any_tags", []))
	var addh := Button.new()
	addh.text = "＋ 添加手部门槛"
	addh.pressed.connect(func():
		_add_hand_row("main_hand", [], [])
		_mark_dirty())
	_form.add_child(addh)

	# 5. 效果块 effects[]（§3 调色盘；v1 五种可编）
	_form.add_child(EditorUI.section_title("效果块 effects（技能＝效果块拼装；按序结算）"))
	_blocks_box = VBoxContainer.new()
	_blocks_box.add_theme_constant_override("separation", 8)
	_form.add_child(_blocks_box)
	for b in _current.get("effects", []):
		if typeof(b) == TYPE_DICTIONARY:
			_add_block(b)
	var addrow := HBoxContainer.new()
	addrow.add_theme_constant_override("separation", 6)
	_block_pick = OptionButton.new()
	for p in BLOCK_KINDS:
		_block_pick.add_item(str(p[1]))
		_block_pick.set_item_metadata(_block_pick.item_count - 1, str(p[0]))
	addrow.add_child(_block_pick)
	var addb := Button.new()
	addb.text = "＋ 添加效果块"
	addb.pressed.connect(func():
		_add_block(_block_skeleton(str(_block_pick.get_selected_metadata())))
		_mark_dirty())
	addrow.add_child(addb)
	_form.add_child(addrow)

	_dirty = false   # 建表单期间控件信号可能置脏——载入完成＝干净基线

func _flag_check(parent: Node, label: String, v: bool) -> CheckBox:
	var cb := CheckBox.new()
	cb.text = label
	cb.button_pressed = v
	cb.toggled.connect(func(_v): _mark_dirty())
	parent.add_child(cb)
	return cb

func _dropdown_pairs(label: String, pairs: Array, sel: String) -> OptionButton:
	var ob := OptionButton.new()
	for p in pairs:
		ob.add_item(str(p[1]))
		ob.set_item_metadata(ob.item_count - 1, str(p[0]))
	_select_meta(ob, sel)
	ob.item_selected.connect(func(_i): _mark_dirty())
	_form.add_child(EditorUI.field_row(label, ob))
	return ob

func _build_icon_row() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var lbl := Label.new()
	lbl.text = "图标 icon"
	lbl.custom_minimum_size = Vector2(200, 0)
	row.add_child(lbl)
	_icon_thumb = TextureRect.new()
	_icon_thumb.custom_minimum_size = Vector2(28, 28)
	_icon_thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon_thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon_thumb.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_icon_thumb.texture = TextureCache.get_tex(str(_current.get("icon", "")))
	row.add_child(_icon_thumb)
	_w_icon = LineEdit.new()
	_w_icon.text = str(_current.get("icon", ""))
	_w_icon.placeholder_text = ICON_DIR + "/...png"
	_w_icon.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_w_icon.text_changed.connect(func(_t):
		_icon_thumb.texture = TextureCache.get_tex(_w_icon.text.strip_edges())
		_mark_dirty())
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
		_file_dialog.file_selected.connect(func(path):
			if _w_icon != null and is_instance_valid(_w_icon):
				_w_icon.text = path
				_icon_thumb.texture = TextureCache.get_tex(path)
				_mark_dirty())
		add_child(_file_dialog)
	_file_dialog.current_dir = ICON_DIR
	_file_dialog.popup_centered(Vector2i(760, 520))

# 技能 tag 下拉预设：技能行为类别 + 手动（weapon_* 等门槛词走 requires_hands，不进 tags）
func _tag_options() -> Array:
	var out := []
	for c in SKILL_TAG_CATS:
		var ids := TagDB.ids_in_cat(c)
		if ids.is_empty():
			continue
		out.append(["sep", c])
		for id in ids:
			out.append([id, "%s（%s）" % [TagDB.cn(id), id]])
	return out


# —— requires_hands 行 ——

func _add_hand_row(slot: String, all_tags, any_tags) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var sl := OptionButton.new()
	for p in HAND_SLOTS:
		sl.add_item(str(p[1]))
		sl.set_item_metadata(sl.item_count - 1, str(p[0]))
	_select_meta(sl, slot)
	sl.item_selected.connect(func(_i): _mark_dirty())
	row.add_child(sl)
	row.add_child(EditorUI.label("全要"))
	var al := LineEdit.new()
	al.text = ", ".join(_str_arr(all_tags))
	al.placeholder_text = "all_tags 逗号分隔（如 two_handed, weapon_sword）"
	al.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	al.text_changed.connect(func(_t): _mark_dirty())
	row.add_child(al)
	row.add_child(EditorUI.label("任一"))
	var an := LineEdit.new()
	an.text = ", ".join(_str_arr(any_tags))
	an.placeholder_text = "any_tags 逗号分隔"
	an.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	an.text_changed.connect(func(_t): _mark_dirty())
	row.add_child(an)
	var rm := Button.new()
	rm.text = "✕"
	var entry := {"row": row, "slot": sl, "all": al, "any": an}
	rm.pressed.connect(func():
		_hand_rows.erase(entry)
		row.queue_free()
		_mark_dirty())
	row.add_child(rm)
	_hands_box.add_child(row)
	_hand_rows.append(entry)

func _str_arr(v) -> PackedStringArray:
	var out := PackedStringArray()
	if typeof(v) == TYPE_ARRAY:
		for e in v:
			out.append(str(e))
	return out

func _split_tags(text: String) -> Array:
	var out := []
	for p in text.split(","):
		var t := str(p).strip_edges()
		if t != "" and not out.has(t):
			out.append(t)
	return out


# —— 效果块 ——

func _block_skeleton(kind: String) -> Dictionary:
	match kind:
		"attack":
			return {"kind": "attack", "hits": [{"coeff": 1.0, "damage_kind": "physical"}]}
		"heal":
			return {"kind": "heal", "heal_pct_max_hp": 0, "cleanse_tags": []}
		"passive_stat_mods":
			return {"kind": "passive_stat_mods", "mods": []}
		"apply_effect":
			return {"kind": "apply_effect", "effect": "", "chance": 100}
		_:
			return {"kind": "scripted", "script_id": "", "params": {}}

# 一个效果块＝带边框面板：头（kind 名 + ✕）+ kind 专属字段。data 原样持有，collect 时 duplicate+更新。
func _add_block(data: Dictionary) -> void:
	var kind := str(data.get("kind", ""))
	var panel := PanelContainer.new()
	var sb := EditorTheme.sb(Color(0.14, 0.15, 0.19), Color(0.3, 0.34, 0.42))
	sb.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	panel.add_child(box)
	var head := HBoxContainer.new()
	var kind_cn := kind
	for p in BLOCK_KINDS:
		if str(p[0]) == kind:
			kind_cn = str(p[1])
			break
	var title := Label.new()
	title.text = "▪ " + kind_cn
	title.add_theme_color_override("font_color", Color(0.75, 0.85, 1.0))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var rm := Button.new()
	rm.text = "✕"
	head.add_child(rm)
	box.add_child(head)
	var entry := {"data": data, "kind": kind, "panel": panel, "locked": false}
	rm.pressed.connect(func():
		_blocks.erase(entry)
		panel.queue_free()
		_mark_dirty())
	match kind:
		"attack":
			_build_attack_block(box, entry)
		"heal":
			_build_heal_block(box, entry)
		"passive_stat_mods":
			_build_passive_block(box, entry)
		"apply_effect":
			_build_apply_effect_block(box, entry)
		"scripted":
			_build_scripted_block(box, entry)
		_:
			entry["locked"] = true
			box.add_child(_warn("未知块 kind「%s」——本版不编辑，保存原样保留（运行时警告跳过）" % kind, WARN_COLOR))
	_blocks_box.add_child(panel)
	_blocks.append(entry)

func _warn(text: String, color: Color) -> Label:
	var l := Label.new()
	l.text = "⚠ " + text
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", 12)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l

# attack：v1 只编单 hit 的 coeff/damage_kind/armor_pen/sure_hit；多 hits/riders＝阶段6 禁入库→锁定只读。
func _build_attack_block(box: VBoxContainer, entry: Dictionary) -> void:
	var hits: Array = entry["data"].get("hits", [])
	var has_riders := false
	for h in hits:
		if typeof(h) == TYPE_DICTIONARY and h.has("riders"):
			has_riders = true
	if hits.size() > 1 or has_riders:
		entry["locked"] = true
		box.add_child(_warn("多段 hits / riders＝阶段6（lint 护栏#1 现禁入库）——本块锁定只读，保存原样保留", LOCK_COLOR))
		return
	var hit: Dictionary = hits[0] if hits.size() == 1 and typeof(hits[0]) == TYPE_DICTIONARY else {}
	if hit.has("weapon_source"):
		box.add_child(_warn("weapon_source=off_hand：结算吃副手惩罚 ×offhand_eff/100（🔒 决策5 阶段3b 已生效；盾豁免）", HINT_COLOR))
	entry["coeff"] = _add_formula(box, "伤害系数 coeff", hit.get("coeff", 1.0))
	var dk := OptionButton.new()
	for d in DAMAGE_KINDS:
		dk.add_item(d)
		dk.set_item_metadata(dk.item_count - 1, d)
	_select_meta(dk, str(hit.get("damage_kind", "physical")))
	dk.item_selected.connect(func(_i): _mark_dirty())
	box.add_child(EditorUI.field_row("伤害类型 damage_kind", dk))
	entry["damage_kind"] = dk
	entry["armor_pen"] = EditorUI.add_spin(box, "破甲 armor_pen（0=无）", float(hit.get("armor_pen", 0)), 0, 100, 1, _mark_dirty)
	entry["sure_hit"] = EditorUI.add_check(box, "必中 sure_hit（跳过命中掷骰）", bool(hit.get("sure_hit", false)), _mark_dirty)
	box.add_child(_warn("aoe / bonus / ignore_* 等高级字段本版不编辑，保存原样保留", WARN_COLOR))

func _build_heal_block(box: VBoxContainer, entry: Dictionary) -> void:
	entry["heal_pct"] = _add_formula(box, "治疗量 heal_pct_max_hp（%最大生命）", entry["data"].get("heal_pct_max_hp", 0))
	var ct := []
	for t in entry["data"].get("cleanse_tags", []):
		ct.append(str(t))
	entry["cleanse"] = ct
	var opts := []
	for c in ["effect", "effect_dim"]:
		for id in TagDB.ids_in_cat(c):
			opts.append([id, "%s（%s）" % [TagDB.cn(id), id]])
	EditorUI.add_tag_list(box, "清除效果 tag cleanse_tags", ct, opts, _mark_dirty)

func _build_passive_block(box: VBoxContainer, entry: Dictionary) -> void:
	box.add_child(_warn("被动桥已生效（🔒 阶段4 2026-07-11）：学得即挂修正 source=skill:<id>，升级重挂、数值可用公式随级", HINT_COLOR))
	var rows := []
	entry["mods"] = rows
	var mods_box := VBoxContainer.new()
	mods_box.add_theme_constant_override("separation", 4)
	box.add_child(mods_box)
	for m in entry["data"].get("mods", []):
		if typeof(m) == TYPE_DICTIONARY:
			EditorUI.add_mod_row(mods_box, rows, StatMeta.EDITOR_STATS,
				str(m.get("stat", "atk")), str(m.get("op", "flat")), float(m.get("value", 0)), _mark_dirty)
	var addm := Button.new()
	addm.text = "＋ 添加修正"
	addm.pressed.connect(func():
		EditorUI.add_mod_row(mods_box, rows, StatMeta.EDITOR_STATS, "atk", "flat", 0.0, _mark_dirty)
		_mark_dirty())
	box.add_child(addm)

func _build_apply_effect_block(box: VBoxContainer, entry: Dictionary) -> void:
	var ob := OptionButton.new()
	ob.add_item("（选效果…）")
	ob.set_item_metadata(0, "")
	for id in EffectDB.all():
		var e = EffectDB.all()[id]
		ob.add_item("%s（%s）" % [str(e.get("name", id)), str(id)])
		ob.set_item_metadata(ob.item_count - 1, str(id))
	_select_meta(ob, str(entry["data"].get("effect", "")))
	ob.item_selected.connect(func(_i): _mark_dirty())
	box.add_child(EditorUI.field_row("效果 effect（EffectDB 引用；🔒 对象形禁裸串）", ob))
	entry["effect"] = ob
	entry["chance"] = EditorUI.add_spin(box, "施加概率 chance（%；resist 效果另有强韧豁免）",
		float(entry["data"].get("chance", 100)), 1, 100, 1, _mark_dirty)
	if EffectDB.all().is_empty():
		box.add_child(_warn("效果库为空——先去「✨ 效果库」建效果", WARN_COLOR))

func _build_scripted_block(box: VBoxContainer, entry: Dictionary) -> void:
	box.add_child(_warn("scripted＝逃生舱：script_id 需代码侧注册，未注册＝运行时警告跳过", WARN_COLOR))
	entry["script_id"] = EditorUI.add_line(box, "脚本 id script_id", str(entry["data"].get("script_id", "")), _mark_dirty)
	var pt := TextEdit.new()
	var params = entry["data"].get("params", {})
	pt.text = JSON.stringify(params, "  ") if typeof(params) == TYPE_DICTIONARY and not params.is_empty() else ""
	pt.custom_minimum_size = Vector2(0, 56)
	pt.scroll_fit_content_height = true
	pt.placeholder_text = "{ \"key\": value } 参数字典 JSON（空=无参数；存盘时解析校验）"
	pt.text_changed.connect(_mark_dirty)
	box.add_child(EditorUI.field_row("参数 params", pt))
	entry["params"] = pt


# —— 公式三段控件（🔒 §2.4：基础值 + 缩放属性×系数 + 逐级数组；无表达式解析器）——
# 收集规则（canonical 最小键）：无 per_stat 且无 per_level → 落标量；否则对象 {base?, per_stat?, per_level?}
# （base=0 省略、空段省略——与 first_aid 的 {"per_level":[...]} 形一致，保字节级往返）。
func _add_formula(box: VBoxContainer, label: String, v) -> Dictionary:
	var base := 0.0
	var stat := ""
	var weight := 0.0
	var levels := ""
	match typeof(v):
		TYPE_INT, TYPE_FLOAT:
			base = float(v)
		TYPE_DICTIONARY:
			base = float(v.get("base", 0.0))
			var per = v.get("per_stat", {})
			if typeof(per) == TYPE_DICTIONARY and per.size() > 0:
				stat = str(per.keys()[0])
				weight = float(per[per.keys()[0]])
			var pl = v.get("per_level", [])
			if typeof(pl) == TYPE_ARRAY and pl.size() > 0:
				levels = ", ".join(pl.map(func(x): return str(x)))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.add_child(EditorUI.label("基础"))
	var bs := SpinBox.new()
	bs.min_value = 0
	bs.max_value = 999
	bs.step = 0.05
	bs.value = base
	bs.custom_minimum_size = Vector2(90, 0)
	bs.value_changed.connect(func(_v): _mark_dirty())
	row.add_child(bs)
	row.add_child(EditorUI.label("＋属性"))
	var st := OptionButton.new()
	st.add_item("（无）")
	st.set_item_metadata(0, "")
	for key in StatMeta.EDITOR_STATS:
		st.add_item("%s %s" % [key, StatMeta.label(str(key))])
		st.set_item_metadata(st.item_count - 1, str(key))
	_select_meta(st, stat)
	st.item_selected.connect(func(_i): _mark_dirty())
	row.add_child(st)
	row.add_child(EditorUI.label("×"))
	var ws := SpinBox.new()
	ws.min_value = -99
	ws.max_value = 99
	ws.step = 0.01
	ws.value = weight
	ws.custom_minimum_size = Vector2(90, 0)
	ws.value_changed.connect(func(_v): _mark_dirty())
	row.add_child(ws)
	box.add_child(EditorUI.field_row(label, row))
	var lv := LineEdit.new()
	lv.text = levels
	lv.placeholder_text = "逐级数组 per_level 逗号分隔（长度须==max_level；填了则替代基础值档）"
	lv.text_changed.connect(func(_t): _mark_dirty())
	box.add_child(EditorUI.field_row("　　逐级 per_level", lv))
	var multi_per := typeof(v) == TYPE_DICTIONARY and typeof(v.get("per_stat", {})) == TYPE_DICTIONARY and (v.get("per_stat", {}) as Dictionary).size() > 1
	if multi_per:
		box.add_child(_warn("per_stat 多键——控件只编首键，其余保存原样保留", WARN_COLOR))
	return {"base": bs, "stat": st, "weight": ws, "levels": lv, "orig": v, "multi_per": multi_per}

# 公式收集：解析失败（per_level 非数字）→ 置 _collect_err
var _collect_err := ""

func _collect_formula(w: Dictionary):
	var base := float(w["base"].value)
	var stat := str(w["stat"].get_selected_metadata())
	var weight := float(w["weight"].value)
	var lv_text := str(w["levels"].text).strip_edges()
	var per_level := []
	if lv_text != "":
		for p in lv_text.split(","):
			var s := str(p).strip_edges()
			if s == "" or not s.is_valid_float():
				_collect_err = "per_level「%s」不是数字（逗号分隔的数值列表）" % s
				return null
			per_level.append(_num(s.to_float()))
	var per_stat := {}
	if w.get("multi_per", false):   # 多键：以原对象为底，只更新首键
		per_stat = (w["orig"].get("per_stat", {}) as Dictionary).duplicate(true)
		if stat != "":
			per_stat[stat] = _num(weight)
	elif stat != "" and weight != 0.0:
		per_stat[stat] = _num(weight)
	if per_stat.is_empty() and per_level.is_empty():
		return _num(base)
	var out := {}
	if base != 0.0:
		out["base"] = _num(base)
	if not per_stat.is_empty():
		out["per_stat"] = per_stat
	if not per_level.is_empty():
		out["per_level"] = per_level
	return out

func _num(v: float):
	return int(v) if v == floorf(v) else v


# —— 收集 / 校验（与 test_data_lint 规则7 对齐）——

func _shell_collect() -> Dictionary:
	_collect_err = ""
	var out: Dictionary = _current.duplicate(true)   # duplicate+按键更新＝保留键序与未编辑字段（字节级往返）
	out["id"] = _w_id.text.strip_edges()
	out["name"] = _w_name.text.strip_edges()
	out["icon"] = _w_icon.text.strip_edges()
	out["nature"] = str(_w_nature.get_selected_metadata())
	out["desc"] = _w_desc.text
	out["active"] = _w_active.button_pressed
	out["tags"] = _tags.duplicate()
	var costs: Dictionary = out.get("costs", {}) if typeof(out.get("costs")) == TYPE_DICTIONARY else {}
	costs["ap"] = int(_w_ap.value)
	out["costs"] = costs
	out.erase("ap_cost")   # 双键禁写（lint 规则7）：数据侧只留 costs.ap，旧顶层键剥掉
	var cd: Dictionary = out.get("cooldown", {}) if typeof(out.get("cooldown")) == TYPE_DICTIONARY else {}
	cd["base"] = int(_w_cd.value)
	out["cooldown"] = cd
	var uses: Dictionary = out.get("uses_per_battle", {}) if typeof(out.get("uses_per_battle")) == TYPE_DICTIONARY else {}
	uses["base"] = int(_w_uses.value)
	out["uses_per_battle"] = uses
	out["max_level"] = int(_w_maxlv.value)
	out["target"] = {"enemy": _w_t_enemy.button_pressed, "ally": _w_t_ally.button_pressed, "self": _w_t_self.button_pressed}
	out["range"] = int(_w_range.value)
	if int(_w_seq.value) > 0:
		out["seq"] = int(_w_seq.value)
	else:
		out.erase("seq")
	# requires_hands
	var hands := []
	for h in _hand_rows:
		var row := {"slot": str(h["slot"].get_selected_metadata())}
		var al := _split_tags(str(h["all"].text))
		var an := _split_tags(str(h["any"].text))
		if not al.is_empty():
			row["all_tags"] = al
		if not an.is_empty():
			row["any_tags"] = an
		hands.append(row)
	out["requires_hands"] = hands
	# effects[]
	var effects := []
	for b in _blocks:
		effects.append(_collect_block(b))
		if _collect_err != "":
			_err(_collect_err)
			return {}
	out["effects"] = effects
	# —— lint 规则7 同步校验（编辑器先拦；BAS 形约束已随决策27 移到引用处＝lint 规则8/ItemEditor 过滤）——
	if not (bool(out["target"]["enemy"]) or bool(out["target"]["ally"]) or bool(out["target"]["self"])):
		_err("目标三旗不得全 false（永不可施放，lint 规则7）")
		return {}
	if out.has("seq"):
		for oid in SkillDB.all():
			if str(oid) == out["id"] or str(oid) == _loaded_id:
				continue
			if int((SkillDB.all()[oid] as Dictionary).get("seq", -1)) == int(out["seq"]):
				_err("seq %d 与「%s」撞格（lint 规则7）" % [int(out["seq"]), str(oid)])
				return {}
	var pls := []
	_collect_per_levels(out, pls)
	for pl in pls:
		if (pl as Array).size() != int(out["max_level"]):
			_err("per_level 长度(%d)须==max_level(%d)（lint 规则7）" % [(pl as Array).size(), int(out["max_level"])])
			return {}
	return out

func _collect_block(entry: Dictionary) -> Dictionary:
	var out: Dictionary = (entry["data"] as Dictionary).duplicate(true)
	if entry.get("locked", false):
		return out   # 锁定块（多 hits/riders/未知 kind）原样保留
	match str(entry["kind"]):
		"attack":
			var hits: Array = out.get("hits", [])
			var hit: Dictionary = (hits[0] as Dictionary).duplicate(true) if hits.size() == 1 and typeof(hits[0]) == TYPE_DICTIONARY else {}
			var coeff = _collect_formula(entry["coeff"])
			if _collect_err != "":
				return out
			hit["coeff"] = coeff
			hit["damage_kind"] = str(entry["damage_kind"].get_selected_metadata())
			if int(entry["armor_pen"].value) > 0:
				hit["armor_pen"] = int(entry["armor_pen"].value)
			else:
				hit.erase("armor_pen")
			if entry["sure_hit"].button_pressed:
				hit["sure_hit"] = true
			else:
				hit.erase("sure_hit")
			out["hits"] = [hit]
		"heal":
			var v = _collect_formula(entry["heal_pct"])
			if _collect_err != "":
				return out
			out["heal_pct_max_hp"] = v
			out["cleanse_tags"] = (entry["cleanse"] as Array).duplicate()
		"passive_stat_mods":
			var mods := []
			for m in entry["mods"]:
				mods.append({"stat": str(m["stat"].get_selected_metadata()),
					"op": str(m["op"].get_selected_metadata()), "value": _num(float(m["value"].value))})
			out["mods"] = mods
		"apply_effect":
			var eid := str(entry["effect"].get_selected_metadata())
			if eid == "":
				_collect_err = "apply_effect 块未选效果（🔒 对象形 {effect,chance}，禁空引用）"
				return out
			out["effect"] = eid
			if int(entry["chance"].value) != 100:
				out["chance"] = int(entry["chance"].value)
			else:
				out.erase("chance")   # 缺省 100 不落盘（canonical 最小键）
		"scripted":
			out["script_id"] = str(entry["script_id"].text).strip_edges()
			var ptext := str(entry["params"].text).strip_edges()
			if ptext == "":
				out.erase("params")
			else:
				var parsed = JSON.parse_string(ptext)
				if typeof(parsed) != TYPE_DICTIONARY:
					_collect_err = "scripted params 不是合法 JSON 字典——保存被拒（坏 JSON 响亮报错）"
					return out
				out["params"] = parsed
	return out

# 递归收集 per_level 数组（校验长度；同 lint _collect_key_arrays 口径）
func _collect_per_levels(v, acc: Array) -> void:
	match typeof(v):
		TYPE_DICTIONARY:
			for k in v:
				if str(k) == "per_level" and typeof(v[k]) == TYPE_ARRAY:
					acc.append(v[k])
				else:
					_collect_per_levels(v[k], acc)
		TYPE_ARRAY:
			for e in v:
				_collect_per_levels(e, acc)


# —— 保存 / 删除（流程在外壳）——

func _shell_exists(id: String) -> bool:
	return SkillDB.get_skill(id) != null

func _shell_db_save(entry: Dictionary, replace_id: String) -> bool:
	return SkillDB.save_skill(entry, replace_id)

func _shell_db_delete(id: String) -> bool:
	return SkillDB.delete_skill(id)

func _shell_after_save(entry: Dictionary, id: String, renaming: bool) -> void:
	if renaming:
		_info("✓ 已保存并改 id：%s → %s　⚠ 单位已学技能/树引用旧 id 不随迁" % [_loaded_id, id])
		push_warning("SkillEditor：技能 id %s → %s——unit.skills/树引用不随迁" % [_loaded_id, id])
	else:
		_info("✓ 已保存「%s」→ data/skills.json" % str(entry.get("name", id)))
	_current = entry

func _shell_delete_confirm_text(id: String) -> String:
	return "确认删除能力「%s」(%s)？此操作直接写盘（已学单位/引用不随删）。" % [str(_current.get("name", id)), id]
