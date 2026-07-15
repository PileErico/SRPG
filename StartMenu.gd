extends Control
## 开始菜单：整个 app 的入口（project.godot 主场景）。
## 战役（M4 起）＝新开局建档进大地图 / 继续读自动档；沙盒/编辑器不挂档 🔒。
## 纯代码建 UI（与本工程其它场景一致，省得维护 .tscn 细节）。

const WorldState := preload("res://WorldState.gd")
const SaveIO := preload("res://SaveIO.gd")
const GameSettings := preload("res://GameSettings.gd")
const SettingsOverlay := preload("res://Settings.gd")
const WorldClock := preload("res://WorldClock.gd")   # 读档面板速览（第N天 HH:MM）

var _load_popup: PopupPanel   # 读档选档面板（懒建）

func _ready() -> void:
	# 回到菜单＝退出战役语义：清 current（活档已由 Overworld 落盘、「继续」从磁盘重读，保留无收益）。
	# 不清则 current 泄漏进沙盒/编辑器——日夜跟战役时钟走、实例/uid 写进战役档，违反「沙盒不挂档 🔒」。
	WorldState.activate(null)
	GameSettings.apply_all()   # 应用已存设置（音量 + 玩家显式选过的分辨率）
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	center.add_child(box)

	var title := Label.new()
	title.text = "战棋"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 56)
	box.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "hex SRPG · 战术战斗 · 沙盒经营"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_color_override("font_color", Color(0.7, 0.74, 0.82))
	box.add_child(subtitle)

	box.add_child(_spacer(18))
	# 双列布局（2026-07-15 用户校准：玩家菜单 vs 开发工具左右分排——一眼定位，暂不做二级页）
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 56)
	cols.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(cols)
	# 左列：游戏（玩家入口）
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 14)
	cols.add_child(left)
	left.add_child(_col_header("游戏"))
	left.add_child(_menu_button("战役 · 新开局", _on_new_campaign, false))
	left.add_child(_menu_button("战役 · 继续", _on_continue_campaign, not SaveIO.list_slots().has(SaveIO.AUTO_SLOT)))
	left.add_child(_menu_button("战役 · 读档", _on_load_campaign, SaveIO.list_slots().is_empty()))
	left.add_child(_menu_button("沙盒模式", _on_sandbox, false))
	left.add_child(_spacer(8))
	left.add_child(_menu_button("设置", _on_settings, false))
	left.add_child(_menu_button("退出", _on_quit, false))
	# 右列：开发工具（编辑器 · 工坊）
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 14)
	cols.add_child(right)
	right.add_child(_col_header("开发工具"))
	right.add_child(_menu_button("🎮 编辑器（编辑 · 试玩）", _on_game, false, true))
	right.add_child(_menu_button("🗺️ 地图编辑", _on_map_editor, false, true))
	right.add_child(_menu_button("👤 角色编辑器", _on_char_editor, false, true))
	right.add_child(_menu_button("⚔️ 物品编辑器", _on_item_editor, false, true))
	right.add_child(_menu_button("🤺 技能编辑器（能力 · 效果）", _on_skill_editor, false, true))
	right.add_child(_menu_button("🎨 外观工坊（换装换色）", _on_appearance_workshop, false, true))
	right.add_child(_menu_button("🗻 地块绘制工坊", _on_terrain_workshop, false, true))

# align_left：图标列左对齐（图标竖向对齐成一列，扫视更快——2026-07-15 用户校准）；缺省居中（玩家列）
func _menu_button(text: String, cb: Callable, disabled: bool, align_left := false) -> Button:
	var b := Button.new()
	b.text = ("  " + text) if align_left else text   # 左对齐补两空格呼吸位（默认 stylebox 内边距太贴边）
	if align_left:
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = Vector2(280, 46)
	b.disabled = disabled
	if not disabled and cb.is_valid():
		b.pressed.connect(cb)
	return b

# 列头小标（双列布局）：居中灰字
func _col_header(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color(0.55, 0.6, 0.68))
	return l

func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c

func _on_new_campaign() -> void:
	WorldState.start_new()   # 覆盖 current（旧档若没存自动档就丢——铁人/多槽位后续再细化）
	get_tree().change_scene_to_file("res://Overworld.tscn")

func _on_continue_campaign() -> void:
	_load_slot(SaveIO.AUTO_SLOT)

# 读档选档面板：自动档 + 手动槽逐行（速览＋读取按钮）；空槽不列。
func _on_load_campaign() -> void:
	if _load_popup != null and is_instance_valid(_load_popup):
		_load_popup.queue_free()
	_load_popup = PopupPanel.new()
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(430, 0)
	v.add_theme_constant_override("separation", 8)
	_load_popup.add_child(v)
	var title := Label.new()
	title.text = "读取存档"
	title.add_theme_font_size_override("font_size", 18)
	v.add_child(title)
	v.add_child(HSeparator.new())
	var slots: Array = [SaveIO.AUTO_SLOT]
	slots.append_array(SaveIO.MANUAL_SLOTS)
	var listed := 0
	for slot in slots:
		var info: Dictionary = SaveIO.slot_info(str(slot))
		if info.is_empty():
			continue
		listed += 1
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var name_l := Label.new()
		name_l.text = "自动档" if str(slot) == SaveIO.AUTO_SLOT else "存档位 %s" % str(slot).trim_prefix("save")
		name_l.custom_minimum_size = Vector2(90, 0)
		row.add_child(name_l)
		var desc := Label.new()
		desc.text = "%s · 队伍%d人 · 💰%d%s" % [WorldClock.describe(int(info.get("clock_hours", 0))),
			int(info.get("party", 0)), int(info.get("gold", 0)),
			"　🔒铁人" if bool(info.get("ironman", false)) else ""]
		desc.add_theme_color_override("font_color", Color(0.65, 0.7, 0.78))
		desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(desc)
		var b := Button.new()
		b.text = "读取"
		b.pressed.connect(_load_slot.bind(str(slot)))
		row.add_child(b)
		v.add_child(row)
	if listed == 0:
		var none := Label.new()
		none.text = "（暂无可读存档）"
		none.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		v.add_child(none)
	add_child(_load_popup)
	_load_popup.popup_centered()

func _load_slot(slot: String) -> void:
	var ws = SaveIO.load_campaign(slot)
	if ws == null:
		push_warning("StartMenu：存档「%s」读取失败（主档与 .bak 双失）" % slot)
		return
	WorldState.activate(ws)
	get_tree().change_scene_to_file("res://Overworld.tscn")

func _on_game() -> void:
	get_tree().change_scene_to_file("res://Game.tscn")

func _on_sandbox() -> void:
	get_tree().change_scene_to_file("res://MapSelect.tscn")

func _on_map_editor() -> void:
	get_tree().change_scene_to_file("res://MapEditor.tscn")

func _on_item_editor() -> void:
	get_tree().change_scene_to_file("res://ItemEditor.tscn")

func _on_char_editor() -> void:
	get_tree().change_scene_to_file("res://CharacterEditor.tscn")

func _on_skill_editor() -> void:
	get_tree().change_scene_to_file("res://SkillEditor.tscn")

func _on_appearance_workshop() -> void:
	get_tree().change_scene_to_file("res://AppearanceWorkshop.tscn")

func _on_terrain_workshop() -> void:
	get_tree().change_scene_to_file("res://TerrainArtWorkshop.tscn")

func _on_settings() -> void:
	add_child(SettingsOverlay.new())   # 叠加在菜单上；返回/ESC 自行 free

func _on_quit() -> void:
	get_tree().quit()
