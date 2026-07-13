extends "res://ListEditorShell.gd"
## 效果库编辑器：编 data/effects.json 条目（有 id 的 buff/debuff），写盘走 EffectDB.save_effect。
## 🔒 设计真值＝docs/模块_技能_设计.md §2.2（schema）/§2.8（duration_model 两模型）/决策20（on_expire_apply 两段式）。
## 与技能编辑器成对（标题栏分段互切）：技能 apply_effect / 武器 inflict 引用这里的效果 id。
## 「可编不可跑」警示：duration.per_stat 现引擎只读 base；sustain_by_caster 预留——均黄条，字段保留原样。
## （round_end tick 已实现 2026-07-11：BattleState._wrap_round 先 tick 再重排出手序，🔒 §2.2 过渡序。）
## 矛盾组合联动（§25 提案 2026-07-12）：resist 模型缺 fort_* tag（豁免纯 tag 归轨 🔒 §2.8/§5，缺 tag＝静默按
##   fixed 走）→ 黄条；on_expire_apply 连锁沿 EffectDB 走链、成环/悬空→ 黄条；stackable/permanent 不适用位灰化。
## 收集校验与 lint 对齐（编辑器先拦，别让 lint 红）：tags 须在 tags.json 注册（规则6）；其余形状（kind/模型/
##   数值）由控件天然保证；悬空 on_expire_apply 沿 §3-1 保值决策只警示不拦（lint 10c 另行标红）。

const EffectDB := preload("res://EffectDB.gd")
const TagDB := preload("res://TagDB.gd")
const StatMeta := preload("res://StatMeta.gd")

const ICON_DIR := "res://icons/Skills"
const KINDS := [["buff", "增益 buff"], ["debuff", "减益 debuff"]]
const DURATION_MODELS := [["fixed", "固定时长 fixed（按施加者求值、逐回合 −1）"],
	["resist", "强韧豁免 resist（按 fort_* tag 归轨；遭受时+每回合掷豁免）"]]
const EXPIRE_TIMINGS := [["turn_end", "回合末 turn_end（默认）"], ["turn_start", "回合开始 turn_start"],
	["round_end", "大回合末 round_end（集中攻势层/鼓舞倒计时；到期先于新 round 排序）"]]
const WARN_COLOR := Color(0.95, 0.8, 0.35)

# —— 状态 ——
var _current: Dictionary = {}
var _tags: Array = []
var _mod_rows: Array = []

# —— 控件 ——
var _form: VBoxContainer
var _file_dialog: FileDialog
var _icon_thumb: TextureRect
var _w_id: LineEdit
var _w_name: LineEdit
var _w_icon: LineEdit
var _w_desc: TextEdit
var _w_kind: OptionButton
var _w_dmodel: OptionButton
var _w_duration: SpinBox
var _w_perm: CheckBox
var _w_timing: OptionButton
var _w_stackable: CheckBox
var _w_maxstacks: SpinBox
var _w_dot: SpinBox
var _w_hot: SpinBox
var _w_expire_apply: OptionButton
var _w_model_warn: Label    # §25：resist↔fort tag 错配黄条（模型/标签任一变动即刷新）
var _w_chain_hint: Label    # §25：on_expire_apply 连锁链提示（成环/悬空警示）


# —— §26 跨编辑器定位口 ——
# SkillEditor apply_effect 块「↗」先写本静态位再切场景；_ready 消费即清（同型先例＝SandboxConfig.battle_setup）。
static var _open_with_id := ""

func _ready() -> void:
	super._ready()
	if _open_with_id != "":
		var jump_id := _open_with_id
		_open_with_id = ""
		if EffectDB.get_effect(jump_id) != null:
			_shell_load(jump_id)
		else:
			_err("跳转定位失败：效果「%s」不在库（悬空引用？）" % jump_id)


# —— 外壳钩子（ListEditorShell）——

func _shell_title() -> String:
	return "效果库"

func _shell_new_label() -> String:
	return "＋ 新建效果"

func _shell_new_entry() -> void:
	_open_effect(_skeleton(), true)
	_select_row("")
	_info("新建效果——填好 id（唯一）后点保存")

func _shell_load(id: String) -> void:
	var def = EffectDB.get_effect(id)
	if def == null:
		return
	_open_effect((def as Dictionary).duplicate(true), false)
	_select_row(id)
	_info("编辑「%s」" % str(_current.get("name", id)))

func _shell_discard_text() -> String:
	return "当前效果有未保存的修改，继续将丢弃。"

func _shell_has_entry() -> bool:
	return _w_id != null and is_instance_valid(_w_id)

func _shell_titlebar_extras(titlebar: HBoxContainer) -> void:
	titlebar.add_child(EditorUI.scene_switch(self, "effect",
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
	_w_id = null
	var hint := Label.new()
	hint.text = "← 选左侧效果编辑，或点「＋ 新建效果」；技能/武器经 {effect,chance} 引用这里的 id"
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.72))
	_form.add_child(hint)
	_dirty = false

# 清单：增益 / 减益 两折叠组，组内按名字排序。
func _shell_populate_list(q: String) -> void:
	var searching := q != ""
	var groups := {"buff": [], "debuff": []}
	for id in EffectDB.all():
		var e = EffectDB.all()[id]
		var nm := str(e.get("name", id))
		if searching and not (str(id).to_lower().contains(q) or nm.to_lower().contains(q)):
			continue
		var k := str(e.get("kind", "debuff"))
		groups[k if groups.has(k) else "debuff"].append(e)
	for g in [["debuff", "减益 debuff"], ["buff", "增益 buff"]]:
		var key := str(g[0])
		var arr: Array = groups[key]
		arr.sort_custom(func(a, b): return str(a.get("name", "")) < str(b.get("name", "")))
		var section := VBoxContainer.new()
		section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		section.add_theme_constant_override("separation", 2)
		for e in arr:
			var id := str(e.get("id", ""))
			var row := _make_row_card(id, TextureCache.get_tex(str(e.get("icon", ""))),
				str(e.get("name", id)), null, 42, Vector2(32, 32), str(e.get("desc", "")))
			section.add_child(row)
			_rows[id] = row
		if arr.is_empty():
			var hint := Label.new()
			hint.text = "（无匹配）" if searching else "（暂无）"
			hint.add_theme_color_override("font_color", Color(0.5, 0.54, 0.6))
			hint.add_theme_font_size_override("font_size", 12)
			section.add_child(hint)
		_add_fold_group(key, "%s (%d)" % [str(g[1]), arr.size()], section, searching)


# —— 新建 / 载入 / 副本 ——

# 骨架＝canonical 键序（照 bleeding 条目；字节级往返靠 duplicate+按键更新保序）
func _skeleton() -> Dictionary:
	return {"id": "", "name": "新效果", "icon": "", "desc": "", "kind": "debuff", "tags": [],
		"duration_model": "fixed", "duration": {"base": 2, "per_stat": {}},
		"permanent": false, "expire_timing": "turn_end", "stackable": false, "max_stacks": 0,
		"dot_pct_max_hp": 0, "hot_flat": 0, "mods": [], "on_expire_apply": ""}

func _open_effect(def: Dictionary, is_new: bool) -> void:
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
	_mod_rows = []

func _build_form() -> void:
	_clear_form()
	_form.add_child(EditorUI.section_title("基础"))
	_w_id = EditorUI.add_line(_form, "id（唯一主键；技能/武器引用它）", str(_current.get("id", "")), _mark_dirty)
	_w_name = EditorUI.add_line(_form, "名字", str(_current.get("name", "")), _mark_dirty)
	_build_icon_row()
	_w_desc = TextEdit.new()
	_w_desc.text = str(_current.get("desc", ""))
	_w_desc.custom_minimum_size = Vector2(0, 56)
	_w_desc.scroll_fit_content_height = true
	_w_desc.text_changed.connect(_mark_dirty)
	_form.add_child(EditorUI.field_row("描述 desc（buff 栏 tooltip）", _w_desc))
	_w_kind = _dropdown_pairs("类别 kind", KINDS, str(_current.get("kind", "debuff")))

	_form.add_child(EditorUI.section_title("标签（fort_will/fort_body=豁免归轨；incapacitated=失能跳回合；silenced=失语）"))
	_tags = []
	for t in _current.get("tags", []):
		_tags.append(str(t))
	var opts := []
	for c in ["effect", "effect_dim"]:
		var ids := TagDB.ids_in_cat(c)
		if ids.is_empty():
			continue
		opts.append(["sep", c])
		for id in ids:
			opts.append([id, "%s（%s）" % [TagDB.cn(id), id]])
	EditorUI.add_tag_list(_form, "tags", _tags, opts, _on_tags_changed)

	_form.add_child(EditorUI.section_title("时长"))
	_w_dmodel = _dropdown_pairs("时长模型 duration_model（🔒 §2.8）", DURATION_MODELS, str(_current.get("duration_model", "fixed")))
	_w_dmodel.item_selected.connect(func(_i): _update_links())
	_w_model_warn = _warn("")   # resist↔fort tag 错配黄条（文案在 _update_links 联动填）
	_w_model_warn.visible = false
	_form.add_child(_w_model_warn)
	var dur = _current.get("duration", {})
	var dur_base := float(dur.get("base", 0)) if typeof(dur) == TYPE_DICTIONARY else float(dur if typeof(dur) in [TYPE_INT, TYPE_FLOAT] else 0)
	_w_duration = EditorUI.add_spin(_form, "时长 duration.base（回合）", dur_base, 0, 99, 1, _mark_dirty)
	if typeof(dur) == TYPE_DICTIONARY and typeof(dur.get("per_stat", {})) == TYPE_DICTIONARY and not (dur.get("per_stat", {}) as Dictionary).is_empty():
		_form.add_child(_warn("duration.per_stat 非空——现引擎只读 base（公式求值待接 resolve_num），字段保留原样"))
	_w_perm = EditorUI.add_check(_form, "永久 permanent（不递减不到期）", bool(_current.get("permanent", false)), _mark_dirty)
	_w_perm.toggled.connect(func(_v): _update_links())
	_w_timing = _dropdown_pairs("到期时点 expire_timing", EXPIRE_TIMINGS, str(_current.get("expire_timing", "turn_end")))

	_form.add_child(EditorUI.section_title("叠层 / 每回合结算"))
	_w_stackable = EditorUI.add_check(_form, "可叠层 stackable（关＝同 id 重置时长不叠）", bool(_current.get("stackable", false)), _mark_dirty)
	_w_stackable.toggled.connect(func(_v): _update_links())
	_w_maxstacks = EditorUI.add_spin(_form, "叠层上限 max_stacks（0=无硬上限）", float(_current.get("max_stacks", 0)), 0, 99, 1, _mark_dirty)
	_w_dot = EditorUI.add_spin(_form, "持续伤害 dot_pct_max_hp（%最大生命/回合末；无视护甲）", float(_current.get("dot_pct_max_hp", 0)), 0, 100, 1, _mark_dirty)
	_w_hot = EditorUI.add_spin(_form, "持续回复 hot_flat（固定值/回合末）", float(_current.get("hot_flat", 0)), 0, 999, 1, _mark_dirty)

	_form.add_child(EditorUI.section_title("挂载修正 mods（走修正管线；到期/清除自动摘）"))
	_mod_rows = []
	var mods_box := VBoxContainer.new()
	mods_box.add_theme_constant_override("separation", 4)
	_form.add_child(mods_box)
	for m in _current.get("mods", []):
		if typeof(m) == TYPE_DICTIONARY:
			EditorUI.add_mod_row(mods_box, _mod_rows, StatMeta.EDITOR_STATS,
				str(m.get("stat", "atk")), str(m.get("op", "flat")), float(m.get("value", 0)), _mark_dirty)
	var addm := Button.new()
	addm.text = "＋ 添加修正"
	addm.pressed.connect(func():
		EditorUI.add_mod_row(mods_box, _mod_rows, StatMeta.EDITOR_STATS, "atk", "flat", 0.0, _mark_dirty)
		_mark_dirty())
	_form.add_child(addm)

	_form.add_child(EditorUI.section_title("到期连锁（🔒 决策20 两段式：倒计时引信/叠满质变同家族）"))
	_w_expire_apply = OptionButton.new()
	_w_expire_apply.add_item("（无）")
	_w_expire_apply.set_item_metadata(0, "")
	for id in EffectDB.all():
		if str(id) == _loaded_id:
			continue   # 不给自我连锁（无限循环）
		var e = EffectDB.all()[id]
		_w_expire_apply.add_item("%s（%s）" % [str(e.get("name", id)), str(id)])
		_w_expire_apply.set_item_metadata(_w_expire_apply.item_count - 1, str(id))
	_ensure_meta_option(_w_expire_apply, str(_current.get("on_expire_apply", "")))   # 悬空引用保值（§3-1 守卫上提后补挂）
	_select_meta(_w_expire_apply, str(_current.get("on_expire_apply", "")))
	_w_expire_apply.item_selected.connect(func(_i):
		_mark_dirty()
		_update_links())
	_form.add_child(EditorUI.field_row("消失时施加 on_expire_apply", _w_expire_apply))
	_w_chain_hint = _warn("")   # 连锁链提示（文案在 _update_chain_hint 联动填）
	_w_chain_hint.visible = false
	_form.add_child(_w_chain_hint)

	if str(_current.get("sustain_by_caster", "")) != "" and bool(_current.get("sustain_by_caster", false)):
		_form.add_child(_warn("sustain_by_caster 预留（光环轮）——现不生效，字段保留原样"))

	_update_links()   # §25 矛盾组合初始联动（灰化/黄条按载入值刷一遍）
	_dirty = false   # 建表单信号可能置脏——载入完成＝干净基线

# tag 增删回调：置脏 + 刷矛盾联动（resist↔fort tag 黄条跟着标签走）
func _on_tags_changed() -> void:
	_mark_dirty()
	_update_links()

# §25 矛盾组合联动：改到哪刷到哪——只提示/灰化不动值（勿静默清数据；收集仍读原值，字节级保留）
func _update_links() -> void:
	if _w_dmodel == null or not is_instance_valid(_w_dmodel):
		return
	# 1) resist 模型缺 fort_* tag：豁免纯按 tag 归轨（🔒 §2.8/§5，引擎不读 duration_model）——缺 tag＝静默按 fixed 走
	var has_fort: bool = _tags.has("fort_will") or _tags.has("fort_body")
	if str(_w_dmodel.get_selected_metadata()) == "resist" and not has_fort:
		_w_model_warn.text = "⚠ resist 模型但 tags 缺 fort_will/fort_body——豁免按 tag 归轨（🔒 §2.8），缺维度 tag＝静默按 fixed 走：请补一枚 fort_* tag"
		_w_model_warn.visible = true
	else:
		_w_model_warn.visible = false
	# 2) 不适用位灰化：max_stacks 只在可叠层时生效；permanent 不递减不到期＝时长/到期时点无意义
	_w_maxstacks.editable = _w_stackable.button_pressed
	_w_duration.editable = not _w_perm.button_pressed
	_w_timing.disabled = _w_perm.button_pressed
	_update_chain_hint()

# on_expire_apply 连锁链提示（决策20 两段式）：沿 EffectDB 走链——成环（含二环 A→B→A，运行时互相续挂
# 无限循环）/悬空引用＝黄条警示；多段直链＝纯说明。lint 无环规则故不拦存（口径对齐：只提示）。
func _update_chain_hint() -> void:
	var sel := str(_w_expire_apply.get_selected_metadata())
	if sel == "":
		_w_chain_hint.visible = false
		return
	var self_id := _w_id.text.strip_edges() if (_w_id != null and is_instance_valid(_w_id)) else _loaded_id
	var names := [self_id if self_id != "" else "（本效果）"]
	var seen := {}
	if self_id != "":
		seen[self_id] = true
	var cur := sel
	var cycle := false
	var dangling := false
	for _hop in 8:   # 上限防超长链刷屏（8 段足够暴露环）
		names.append(cur)
		if seen.has(cur):
			cycle = true
			break
		seen[cur] = true
		var d = EffectDB.get_effect(cur)
		if d == null:
			dangling = true
			break
		cur = str(d.get("on_expire_apply", ""))
		if cur == "":
			break
	var chain := " → ".join(PackedStringArray(names))
	if cycle:
		_w_chain_hint.text = "⚠ 到期连锁成环：%s——互相续挂＝运行时无限循环，请断开一环" % chain
		_w_chain_hint.visible = true
	elif dangling:
		_w_chain_hint.text = "⚠ 连锁引用不存在：%s（悬空保值可存盘，lint 规则10c 会红）" % chain
		_w_chain_hint.visible = true
	elif names.size() > 2:
		_w_chain_hint.text = "⚠ 到期连锁多段：%s（两段式引信语义，确认是有意为之）" % chain
		_w_chain_hint.visible = true
	else:
		_w_chain_hint.visible = false

func _warn(text: String) -> Label:
	var l := Label.new()
	l.text = "⚠ " + text
	l.add_theme_color_override("font_color", WARN_COLOR)
	l.add_theme_font_size_override("font_size", 12)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l

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
	browse.pressed.connect(func():
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
		_file_dialog.popup_centered(Vector2i(760, 520)))
	row.add_child(browse)
	_form.add_child(row)


# —— 收集（duplicate+按键更新＝保键序/未编辑字段）——

func _shell_collect() -> Dictionary:
	# —— lint 同步校验（§25：编辑器先拦，别让 lint 红）——规则6：tag 承载键成员须在 tags.json 注册
	# （手动输入是唯一漏点——下拉/控件天然合规；kind/模型/数值等形状由控件保证，无需重检）
	for t in _tags:
		if TagDB.get_tag(str(t)) == null:
			_err("tag「%s」未注册（data/tags.json＝唯一词表，lint 规则6 会红）——先登记再用" % str(t))
			return {}
	var out: Dictionary = _current.duplicate(true)
	out["id"] = _w_id.text.strip_edges()
	out["name"] = _w_name.text.strip_edges()
	out["icon"] = _w_icon.text.strip_edges()
	out["desc"] = _w_desc.text
	out["kind"] = str(_w_kind.get_selected_metadata())
	out["tags"] = _tags.duplicate()
	out["duration_model"] = str(_w_dmodel.get_selected_metadata())
	var dur: Dictionary = out.get("duration", {}) if typeof(out.get("duration")) == TYPE_DICTIONARY else {"base": 0, "per_stat": {}}
	dur["base"] = int(_w_duration.value)
	out["duration"] = dur
	out["permanent"] = _w_perm.button_pressed
	out["expire_timing"] = str(_w_timing.get_selected_metadata())
	out["stackable"] = _w_stackable.button_pressed
	out["max_stacks"] = int(_w_maxstacks.value)
	out["dot_pct_max_hp"] = int(_w_dot.value)
	out["hot_flat"] = int(_w_hot.value)
	var mods := []
	for m in _mod_rows:
		var v := float(m["value"].value)
		mods.append({"stat": str(m["stat"].get_selected_metadata()),
			"op": str(m["op"].get_selected_metadata()), "value": int(v) if v == floorf(v) else v})
	out["mods"] = mods
	out["on_expire_apply"] = str(_w_expire_apply.get_selected_metadata())
	return out


# —— 保存 / 删除（流程在外壳）——

func _shell_exists(id: String) -> bool:
	return EffectDB.get_effect(id) != null

func _shell_db_save(entry: Dictionary, replace_id: String) -> bool:
	return EffectDB.save_effect(entry, replace_id)

func _shell_db_delete(id: String) -> bool:
	return EffectDB.delete_effect(id)

func _shell_after_save(entry: Dictionary, id: String, renaming: bool) -> void:
	if renaming:
		_info("✓ 已保存并改 id：%s → %s　⚠ 引用旧 id 的技能/武器 inflict 需同步（lint 会红）" % [_loaded_id, id])
		push_warning("EffectEditor：效果 id %s → %s——技能/武器引用不随迁" % [_loaded_id, id])
	else:
		_info("✓ 已保存「%s」→ data/effects.json" % str(entry.get("name", id)))
	_current = entry

func _shell_delete_confirm_text(id: String) -> String:
	return "确认删除效果「%s」(%s)？此操作直接写盘（引用它的技能/武器会悬空，lint 会红）。" % [str(_current.get("name", id)), id]
