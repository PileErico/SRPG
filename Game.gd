extends Control
## 游戏内置编辑器（合一）：编辑 ⇄ 试玩 双模式、同一场景（决策 A1）。
## 编辑模式 = MapEditor 子场景；试玩模式 = Sandbox 子场景。
## 「试玩」把编辑器当前内存地图直接喂给战斗（决策 B1：内存直传、免存盘）；
## 「编辑」切回，编辑器状态原样保留。规划见 docs/编辑器合并规划.md（阶段 2）。
##
## 实现：两个子场景同时实例化、叠放在同一容器，按 mode 切 visible + process_mode
## （隐藏的一方 DISABLED，停其 _process/_input，避免快捷键/动画串台）。子场景之间零回调耦合——
## Game 单向调用 _editor.to_json_dict() / _battle.load_from_memory()。

const MapEditorScene := preload("res://MapEditor.tscn")
const SandboxScene := preload("res://Sandbox.tscn")

var mode := "edit"          # "edit" | "battle"
var _editor                 # MapEditor 实例（编辑模式）
var _battle                 # Sandbox 实例（试玩模式）
var _edit_tab: Button
var _play_tab: Button

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	# 顶部模式条：主菜单 + 编辑/试玩 互斥切换
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 4)
	var menu_btn := Button.new()
	menu_btn.text = "主菜单"
	menu_btn.pressed.connect(_on_menu)
	bar.add_child(menu_btn)
	bar.add_child(VSeparator.new())
	var grp := ButtonGroup.new()
	_edit_tab = _make_tab("✎ 编辑", grp, enter_edit)
	bar.add_child(_edit_tab)
	_play_tab = _make_tab("▶ 试玩", grp, enter_playtest)
	bar.add_child(_play_tab)
	var hint := Label.new()
	hint.text = "  编辑地形 / 区域 → 试玩（内存直传、免存盘）→ 返回编辑"
	hint.add_theme_color_override("font_color", Color(0.62, 0.66, 0.74))
	bar.add_child(hint)
	root.add_child(bar)

	# 子场景容器（叠放，按 mode 显隐）；clip 防止战斗 HUD 盖到顶栏
	var stack := Control.new()
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stack.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stack.clip_contents = true
	root.add_child(stack)

	_editor = MapEditorScene.instantiate()
	_editor.embedded = true          # 隐藏 MapEditor 自己的「主菜单」（Game 顶栏已提供）
	stack.add_child(_editor)
	_battle = SandboxScene.instantiate()
	stack.add_child(_battle)

	_apply_mode()   # 默认进编辑模式

func _make_tab(text: String, grp: ButtonGroup, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.button_group = grp
	b.custom_minimum_size = Vector2(96, 34)
	b.pressed.connect(cb)
	return b

# 试玩：把编辑器当前内存地图直接喂给战斗（免存盘），切到战斗模式停在布置阶段
func enter_playtest() -> void:
	if _editor != null and _battle != null:
		_battle.load_from_memory(_editor.to_json_dict())
	mode = "battle"
	_apply_mode()

func enter_edit() -> void:
	mode = "edit"
	_apply_mode()

func _apply_mode() -> void:
	var editing := (mode == "edit")
	if _editor != null:
		_editor.visible = editing
		_editor.process_mode = Node.PROCESS_MODE_INHERIT if editing else Node.PROCESS_MODE_DISABLED
	if _battle != null:
		_battle.visible = not editing
		_battle.process_mode = Node.PROCESS_MODE_DISABLED if editing else Node.PROCESS_MODE_INHERIT
	# 同步 tab 高亮（programmatic 设 button_pressed 不会触发 pressed 信号，无递归）
	if _edit_tab != null:
		_edit_tab.button_pressed = editing
	if _play_tab != null:
		_play_tab.button_pressed = not editing

func _on_menu() -> void:
	get_tree().change_scene_to_file("res://StartMenu.tscn")
