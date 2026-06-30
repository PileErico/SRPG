extends VBoxContainer
## 右侧「单位编辑器」（布置阶段）：编辑底部栏选中的那个单位（等级/经验/四维/属性/特性/技能/物品/阵营）。
## + 把当前单位「保存为预设」（存其配置，与场上位置无关，下次从底部栏「＋」可再取）。
## + 「开始游戏」交给宿主开跑回合。host = Sandbox 实例。单位的增删/布置在底部 RosterBar。
## 战斗阶段 set_battle_mode(true) → 整个面板隐藏（编辑停用；只读查看走角色状态页）。

const ItemDB := preload("res://ItemDB.gd")
const SkillDB := preload("res://SkillDB.gd")
const TraitDB := preload("res://TraitDB.gd")

const FACTIONS := [["player", "我方"], ["ally", "友方"], ["enemy", "敌方"], ["neutral", "中立"]]
const FOUR_KEYS := ["STR", "DEX", "INT", "STA"]
const FOUR_CN := {"STR": "力量", "DEX": "灵巧", "INT": "智力", "STA": "体力"}
const EDIT_STATS := ["move", "speed", "AP_max", "armor_max", "atk_eff", "def_eff",
	"res_phys", "res_fire", "res_thunder", "res_ice", "res_holy"]
const RO_STATS := ["HP_max", "atk", "mag", "acc", "eva", "crit_rate", "crit_dmg",
	"block_rate", "block_power", "res_status"]

var host
var _sel = null
var _battle := false
var _editor_box: VBoxContainer
var _msg: Label
var _save_btn: Button
var _save_map_btn: Button
var _start_btn: Button
var _ro_labels := {}
var _trait_ids := []
var _name_dlg: ConfirmationDialog
var _name_edit: LineEdit

func _ready() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 6)

	var title := Label.new()
	title.text = "● 单位编辑器"
	title.add_theme_font_size_override("font_size", 18)
	add_child(title)
	var hint := Label.new()
	hint.text = "在底部栏点单位来编辑；拖到地图布置"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", Color(0.7, 0.74, 0.82))
	add_child(hint)

	var ms := ScrollContainer.new()
	ms.size_flags_vertical = Control.SIZE_EXPAND_FILL
	ms.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_editor_box = VBoxContainer.new()
	_editor_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_editor_box.add_theme_constant_override("separation", 4)
	ms.add_child(_editor_box)
	add_child(ms)

	_msg = Label.new()
	_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_msg.add_theme_color_override("font_color", Color(0.85, 0.8, 0.5))
	add_child(_msg)

	_save_btn = Button.new()
	_save_btn.text = "保存为预设"
	_save_btn.pressed.connect(_on_save_preset)
	add_child(_save_btn)

	_save_map_btn = Button.new()
	_save_map_btn.text = "⤓ 存单位进地图"
	_save_map_btn.tooltip_text = "把当前场上所有单位（含 AI 配置）写进当前地图文件的 units 字段，作为关卡预置；下次加载该图即自动落子。"
	_save_map_btn.pressed.connect(_on_save_units)
	add_child(_save_map_btn)

	_start_btn = Button.new()
	_start_btn.text = "▶ 开始游戏"
	_start_btn.custom_minimum_size = Vector2(0, 40)
	_start_btn.pressed.connect(_on_start)
	add_child(_start_btn)

	# 预设命名弹窗
	_name_dlg = ConfirmationDialog.new()
	_name_dlg.title = "保存为预设"
	_name_dlg.ok_button_text = "保存"
	_name_dlg.get_cancel_button().text = "取消"
	var box := VBoxContainer.new()
	box.add_child(_mklabel("预设名"))
	_name_edit = LineEdit.new()
	_name_edit.custom_minimum_size = Vector2(260, 0)
	box.add_child(_name_edit)
	_name_dlg.add_child(box)
	_name_dlg.register_text_enter(_name_edit)
	_name_dlg.confirmed.connect(_do_save_preset)
	add_child(_name_dlg)

	_rebuild_editor()

# 战斗阶段：整个编辑器隐藏（编辑停用）
func set_battle_mode(on: bool) -> void:
	_battle = on
	visible = not on
	if on:
		_sel = null

func select_unit(u) -> void:
	_sel = u
	_rebuild_editor()

# 宿主侧消息（如部署区限制提示）显示到底部消息行
func notify(t: String) -> void:
	if _msg != null:
		_msg.text = t

# ---- 编辑器 ----

func _rebuild_editor() -> void:
	if _editor_box == null:
		return
	for c in _editor_box.get_children():
		c.queue_free()
	_ro_labels.clear()
	var has := _sel != null
	if _save_btn: _save_btn.disabled = not has
	if not has:
		var l := Label.new()
		l.text = "（在底部「可用单位」栏点一个单位来编辑）"
		l.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_editor_box.add_child(l)
		return

	_editor_box.add_child(_section("编辑：%s" % _sel.unit_name))

	# 名字
	var nr := HBoxContainer.new()
	nr.add_child(_lblw("名字", 110))
	var ne := LineEdit.new()
	ne.text = _sel.unit_name
	ne.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ne.text_changed.connect(_on_name_changed)
	nr.add_child(ne)
	_editor_box.add_child(nr)

	# 阵营
	var fr := HBoxContainer.new()
	fr.add_child(_lblw("阵营", 110))
	var fo := OptionButton.new()
	for i in FACTIONS.size():
		fo.add_item(FACTIONS[i][1], i)
		if FACTIONS[i][0] == _sel.faction:
			fo.select(i)
	fo.item_selected.connect(_on_faction_changed)
	fr.add_child(fo)
	_editor_box.add_child(fr)

	# 等级 / 经验
	_editor_box.add_child(_int_row("等级", _sel.level, 1, 99, "level"))
	_editor_box.add_child(_int_row("经验", _sel.exp, 0, 999999, "exp"))
	_editor_box.add_child(_int_row("经验上限", _sel.exp_max, 1, 999999, "exp_max"))

	# 四维
	_editor_box.add_child(_section("四维（改后重算派生）"))
	for k in FOUR_KEYS:
		_editor_box.add_child(_stat_row(k))

	# 可改属性
	_editor_box.add_child(_section("属性（可改）"))
	for k in EDIT_STATS:
		_editor_box.add_child(_stat_row(k))

	# 只读派生
	_editor_box.add_child(_section("派生 / 当前（只读）"))
	for k in RO_STATS:
		_editor_box.add_child(_ro_row(k))
	_editor_box.add_child(_ro_row("HP"))

	# 特性
	_editor_box.add_child(_section("特性"))
	_editor_box.add_child(_trait_picker())

	# 技能
	_editor_box.add_child(_section("技能（点学习/升级）"))
	_build_skill_list()

	# 物品
	_editor_box.add_child(_section("物品（点装备到该单位）"))
	_build_item_list()

func _trait_picker() -> Control:
	var opt := OptionButton.new()
	_trait_ids = [""]
	opt.add_item("（无）", 0)
	var i := 1
	for id in TraitDB.all().keys():
		var t = TraitDB.all()[id]
		opt.add_item(str(t.get("name", id)), i)
		_trait_ids.append(id)
		if _sel.trait_id == id:
			opt.select(i)
		i += 1
	if _sel.trait_id == "":
		opt.select(0)
	opt.item_selected.connect(_on_trait_changed)
	return opt

func _build_skill_list() -> void:
	for id in SkillDB.all().keys():
		var def = SkillDB.all()[id]
		var row := HBoxContainer.new()
		var lv: int = _sel.skill_level(id)
		var maxl := int(def.get("max_level", 1))
		var sk_name := str(def.get("name", id))
		var lab := _lbl("%s  Lv%d/%d" % [sk_name, lv, maxl])
		lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(lab)
		var b := Button.new()
		b.text = "学/升" if lv < maxl else "满"
		b.disabled = lv >= maxl
		b.pressed.connect(_on_learn_skill.bind(id))
		row.add_child(b)
		_editor_box.add_child(row)

func _build_item_list() -> void:
	var equipped := _lbl("已装：" + _equipped_text())
	equipped.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_editor_box.add_child(equipped)
	for id in ItemDB.all().keys():
		var item = ItemDB.all()[id]
		var row := HBoxContainer.new()
		var lab := _lbl(str(item.get("name", id)))
		lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(lab)
		var b := Button.new()
		b.text = "装备"
		b.pressed.connect(_on_equip_item.bind(id))
		row.add_child(b)
		_editor_box.add_child(row)

func _equipped_text() -> String:
	if _sel.equipment.is_empty():
		return "（无）"
	var parts := []
	for slot in _sel.equipment:
		var it = ItemDB.get_item(str(_sel.equipment[slot]))
		parts.append(str(it.get("name", _sel.equipment[slot])) if it != null else str(_sel.equipment[slot]))
	return "、".join(parts)

# ---- 回调 ----

func _on_name_changed(t: String) -> void:
	if _sel == null: return
	_sel.unit_name = t
	if host: host._refresh_roster_bar()

func _on_faction_changed(idx: int) -> void:
	if _sel == null: return
	_sel.faction = FACTIONS[idx][0]
	if host:
		host.set_viewed_unit(_sel)
		host._refresh_roster_bar()

func _on_int_changed(value: float, field: String) -> void:
	if _sel == null: return
	_sel.set(field, int(value))

func _on_stat_changed(value: float, key: String) -> void:
	if _sel == null: return
	_sel.stats[key] = int(value)
	if host: host._commit_unit(_sel)
	_refresh_ro()

func _on_trait_changed(idx: int) -> void:
	if _sel == null: return
	_sel.set_trait(_trait_ids[idx] if idx < _trait_ids.size() else "")
	if host: host._commit_unit(_sel)
	_refresh_ro()

func _on_learn_skill(id: String) -> void:
	if _sel == null: return
	_sel.learn_skill(id)
	_rebuild_editor()

func _on_equip_item(id: String) -> void:
	if _sel == null: return
	var item = ItemDB.get_item(id)
	var nm := str(item.get("name", id)) if item != null else id
	if _sel.equip(id):
		if host: host._commit_unit(_sel)
		_msg.text = "已装备：%s" % nm
		_rebuild_editor()
	else:
		_msg.text = "✗ 无法装备「%s」：需求未满足（requires tag / 天性武者禁外来武器）" % nm

func _on_save_preset() -> void:
	if _sel == null:
		return
	_name_edit.text = _sel.unit_name
	_name_dlg.popup_centered()

func _do_save_preset() -> void:
	if _sel == null or host == null:
		return
	var nm := _name_edit.text.strip_edges()
	if nm == "":
		nm = _sel.unit_name
	host.save_unit_preset(_sel, nm)
	_msg.text = "已保存预设：%s（底部栏「＋」可再取）" % nm

func _on_save_units() -> void:
	if host == null:
		return
	if host.units.is_empty():
		_msg.text = "✗ 场上没有单位可存（先拖单位到地图）"
		return
	if host.save_units_to_map():
		_msg.text = "✓ 已存 %d 个单位进地图（下次加载该图自动落子）" % host.units.size()
	else:
		_msg.text = "✗ 写入地图文件失败"

func _on_start() -> void:
	if host == null:
		return
	if host.units.is_empty():
		_msg.text = "✗ 先把至少一个单位拖到地图上再开始"
		return
	host.begin_game()

# ---- 小构件 ----

func _refresh_ro() -> void:
	for k in _ro_labels:
		_ro_labels[k].text = _ro_value(k)

func _ro_value(key: String) -> String:
	return str(_sel.effective_stat_f(key)) if _sel != null else "-"

func _ro_row(key: String) -> Control:
	var row := HBoxContainer.new()
	row.add_child(_lblw(_label_for(key), 110))
	var v := Label.new()
	v.text = _ro_value(key)
	v.add_theme_color_override("font_color", Color(0.75, 0.78, 0.85))
	_ro_labels[key] = v
	row.add_child(v)
	return row

func _stat_row(key: String) -> Control:
	var row := HBoxContainer.new()
	row.add_child(_lblw(_label_for(key), 110))
	var sp := SpinBox.new()
	sp.min_value = -999
	sp.max_value = 9999
	sp.step = 1
	sp.value = float(_sel.stats.get(key, 0))
	sp.custom_minimum_size = Vector2(86, 0)
	sp.value_changed.connect(_on_stat_changed.bind(key))
	row.add_child(sp)
	return row

func _int_row(label: String, val: int, mn: int, mx: int, field: String) -> Control:
	var row := HBoxContainer.new()
	row.add_child(_lblw(label, 110))
	var sp := SpinBox.new()
	sp.min_value = mn
	sp.max_value = mx
	sp.step = 1
	sp.value = val
	sp.custom_minimum_size = Vector2(86, 0)
	sp.value_changed.connect(_on_int_changed.bind(field))
	row.add_child(sp)
	return row

func _section(t: String) -> Control:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color(0.62, 0.78, 0.95))
	return l

func _lbl(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l

func _lblw(t: String, w: int) -> Label:
	var l := _lbl(t)
	l.custom_minimum_size = Vector2(w, 0)
	return l

func _mklabel(t: String) -> Label:
	return _lbl(t)

func _label_for(key: String) -> String:
	if FOUR_CN.has(key):
		return str(FOUR_CN[key])
	if host != null and host.STAT_LABELS.has(key):
		return str(host.STAT_LABELS[key])
	return key
