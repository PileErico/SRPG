extends Control
## 开始菜单：整个 app 的入口（project.godot 主场景）。
## 战役（M4 起）＝新开局建档进大地图 / 继续读自动档；沙盒/编辑器不挂档 🔒。
## 纯代码建 UI（与本工程其它场景一致，省得维护 .tscn 细节）。

const WorldState := preload("res://WorldState.gd")
const SaveIO := preload("res://SaveIO.gd")

const AUTO_SLOT := "auto"   # 与 Overworld.AUTO_SLOT 一致（自动存档槽名）

func _ready() -> void:
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
	box.add_child(_menu_button("战役 · 新开局", _on_new_campaign, false))
	box.add_child(_menu_button("战役 · 继续", _on_continue_campaign, not SaveIO.list_slots().has(AUTO_SLOT)))
	box.add_child(_menu_button("编辑器（编辑 · 试玩）", _on_game, false))
	box.add_child(_menu_button("沙盒模式", _on_sandbox, false))
	box.add_child(_menu_button("地图编辑", _on_map_editor, false))
	box.add_child(_menu_button("物品编辑器", _on_item_editor, false))
	box.add_child(_menu_button("设置（暂未开放）", Callable(), true))
	box.add_child(_spacer(8))
	box.add_child(_menu_button("退出", _on_quit, false))

func _menu_button(text: String, cb: Callable, disabled: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(280, 46)
	b.disabled = disabled
	if not disabled and cb.is_valid():
		b.pressed.connect(cb)
	return b

func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c

func _on_new_campaign() -> void:
	WorldState.start_new()   # 覆盖 current（旧档若没存自动档就丢——铁人/多槽位后续再细化）
	get_tree().change_scene_to_file("res://Overworld.tscn")

func _on_continue_campaign() -> void:
	var ws = SaveIO.load_campaign(AUTO_SLOT)
	if ws == null:
		push_warning("StartMenu：自动档读取失败")
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

func _on_quit() -> void:
	get_tree().quit()
