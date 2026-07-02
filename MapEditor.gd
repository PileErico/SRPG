extends Control
## 地图编辑器（地形层）。
## 闭环：选画笔铺地形 -> 保存 JSON -> 读取 JSON 渲染并可继续编辑。
## 网格：flat-top / odd-q 六边形（见 HexCanvas.gd）。
## 操作：左键画 / 右键取色 / 中键拖拽平移 / 滚轮缩放 /
##       Ctrl+Z 撤销 / Ctrl+Y(或 Ctrl+Shift+Z) 重做 / Ctrl+S 保存。

const HexCanvas := preload("res://HexCanvas.gd")
const EditorCanvas := preload("res://EditorCanvas.gd")
const TerrainDB := preload("res://TerrainDB.gd")
const MapIO := preload("res://MapIO.gd")   # 地图读 / 写单一入口（与 Sandbox 共用）
const UnitFactory := preload("res://UnitFactory.gd")   # 造单位/序列化单一入口（与 Sandbox 共用）
const DeployPanel := preload("res://DeployPanel.gd")   # 复用单位编辑器（editor_mode 编 placed 单位）
const EnvDB := preload("res://EnvDB.gd")   # 环境注册表（天气/日夜，环境面板下拉数据源）
const TagDB := preload("res://TagDB.gd")   # faction→中文走单一源

const MAX_W := 50
const MAX_H := 50
const MAX_UNDO := 50
const HISTORY_SHOWN := 14
const DEFAULT_TERRAIN := "plain"
const DEFAULT_VARIANT := "grassland"

# 战斗地图（与 Sandbox 共享的同一张图）：编辑器启动即载入它、Ctrl+S 写回它；
# Sandbox 启动也读它 —— 「编辑器改 → 沙盒看到」靠这条路径打通。
const MAP_PATH := "res://maps/sandbox.json"

# 地图库：选一个文件夹作默认路径，侧栏列出其中 *.json，点击快捷切换/编辑。
const DEFAULT_MAP_DIR := "res://maps"
const CONFIG_PATH := "user://map_editor.cfg"   # 记住上次选的地图文件夹

# 地形定义：单一数据源 res://terrains.json，经 TerrainDB（编辑器/战斗共用、O(1) 查表）读取。
# terrain 管战斗属性，variant 管外观，tags 供效果/交互统一判断。
# tags 属于“地形类型”，不写进每个格子；地图 JSON 仍只存 terrain/variant，tag 按表查得。
# 每格仅两色：color（底色）+ accent（纹理线条色）。decor 决定线稿图案。
var PALETTE := []

# 新建画布的尺寸预设（下拉第 0 项是占位提示）
const SIZE_PRESETS := [
	{"label": "尺寸…", "w": 0,  "h": 0},
	{"label": "10×10", "w": 10, "h": 10},
	{"label": "15×15", "w": 15, "h": 15},
	{"label": "20×20", "w": 20, "h": 20},
	{"label": "25×25", "w": 25, "h": 25},
	{"label": "30×30", "w": 30, "h": 30},
	{"label": "40×40", "w": 40, "h": 40},
	{"label": "50×50", "w": 50, "h": 50},
]

var width := 15
var height := 15
var tiles := []            # tiles[row][col] = {"terrain":..., "variant":...}
var map_units := []        # 预置单位（地图 units 字段）：单位层可编辑（选原型+阵营落子/删）；存盘写回、含撤销
var map_triggers := []     # 触发器（地图 triggers 字段）：触发器层可编辑（列表+when 表单+do 动作）；存盘写回、含撤销
var map_terrain_overrides := {}   # 图级地形覆盖 { "terrain/variant": {move} }：地形数据「本图」范围写的，只改这张图；存盘写回、含撤销
var map_environment := {}   # 环境 { time, weather_table:[{weather,weight,min_rounds,max_rounds}] }：环境面板写的；存盘写回、含撤销
var brush_index := 0
var embedded := false      # 嵌入 Game 统一宿主时为 true：隐藏自己的「主菜单」按钮（由 Game 顶栏统一提供）

# —— 图层（地形底层 + 叠加层）。四层齐：terrain / region / unit / trigger ——
# 区域层：给一片格子命名（"前厅"/"守军房"），喂战斗侧 AI 的 ai_region 仇恨触发。
# 内存形：regions[i] = {id, label, color, kind, cells:{Vector2i:true}}；存盘转 cells:[[x,y],…]（见 _regions_to_json）。
# kind=区域类型：aggro=AI 仇恨/触发区（敌人 ai_region 引用）；deploy=玩家部署区（战斗只许玩家放区内）。缺省 aggro。
var current_layer := "terrain"      # "terrain" | "region" | "unit" | "trigger"
var regions := []
var _active_region_idx := -1
# 区域配色循环池（新建区域时按序取）
const REGION_COLORS := ["#D5453A", "#EBBC04", "#4FAE5A", "#3A7BD5", "#9B59B6", "#E0822A", "#2AB0B0", "#C84BD5"]
# 区域类型：[id, 中文]（写进地图 regions[].kind，战斗侧据此分派）
const REGION_KINDS := [["aggro", "触发区"], ["deploy", "部署区"]]

# —— 单位层：在编辑器里摆「这一关的单位」（authoring 关卡内容，存进地图 units 字段）——
# 与沙盒「自由测试」不同：这里摆的是关卡固定内容（敌人/预置友军/中立），随地图持久化。
const UNIT_FACTIONS := ["enemy", "player", "ally", "neutral"]   # 顺序=下拉顺序；中文走 TagDB.cn
const FACTION_COLORS := {
	"player": Color(0.30, 0.55, 0.95), "ally": Color(0.30, 0.55, 0.95),
	"enemy": Color(0.90, 0.30, 0.30), "neutral": Color(0.90, 0.80, 0.30),
}
var _unit_panel: Control   # 单位工具区（当前层=单位时显示）
var _unit_list: ItemList   # 单位原型选择列表
var _unit_proto = null     # 当前要落子的原型（null=未选）
var _unit_faction := "enemy"   # 落子阵营（关卡敌人居多，默认敌方）
var _unit_protos := []     # 内置原型缓存（data/unit_prototypes.json）
# —— placed 单位深度编辑（复用 DeployPanel，editor_mode）——
var _unit_edit_win: PanelContainer   # 右侧浮动编辑面板（编辑某个已放置单位时显示）
var _unit_edit_panel                 # DeployPanel 实例（host=本编辑器）
var _editing_unit = null             # 当前编辑的活 Unit（改完序列化回 map_units）
var _editing_index := -1             # 被编辑单位在 map_units 的下标
var _unit_edit_snap_pushed := false  # 本次编辑会话是否已压过撤销快照（整段编辑 = 一步撤销）
var _unit_stroke_action := ""        # 单位层一次拖动的动作锁（""未定 / "edit" 编辑 / "place" 落子）

# —— 触发器层：authoring 关卡事件（when 条件 → do 动作），存进地图 triggers 字段 ——
const TRIG_FACTIONS := [["player", "玩家"], ["any", "任意"]]
const TRIG_ACTION_TYPES := [["show_message", "弹消息"], ["spawn_unit", "召唤单位"], ["activate_aggro", "激活AI组"]]
var _trigger_panel: Control
var _trigger_list: ItemList
var _active_trigger_idx := -1
var _trig_label_edit: LineEdit
var _trig_region_opt: OptionButton
var _trig_faction_opt: OptionButton
var _trig_once_chk: CheckBox
var _trig_do_box: VBoxContainer   # do 动作行容器
var _trig_loading := false        # 填表单时抑制回写（避免 set 信号回写到错对象）

var current_path := ""     # 当前地图对应的本地文件（空＝尚未存盘）
var _dirty := false        # 自上次存/读以来是否有改动

var width_spin: SpinBox
var height_spin: SpinBox
var status_label: Label
var canvas
var brush_buttons := []
# —— 图层切换 + 区域工具（左侧栏）——
# 地形数据编辑（选中笔刷的战斗属性 → 写回 terrains.json，全局共用）
const TERR_PASS_OPTS := [["all", "任何单位"], ["none", "不可通行"], ["tag", "限定tag"]]
# 移动型 tag（passable_by 限定可进哪些；如深水仅 flying）。与 docs/标签词典 的移动型一致。
const PASS_TAGS := [["ground", "地面"], ["flying", "飞行"], ["spectral", "灵体"]]
var _terr_cost_spin: SpinBox
var _terr_pass_opt: OptionButton
var _terr_pass_tag_row: HBoxContainer   # 通行=限定tag 时显示的勾选行
var _terr_pass_checks := {}             # tag → CheckBox
var _terr_tagcost_checks := {}          # tag_cost：tag → 启用 CheckBox
var _terr_tagcost_spins := {}           # tag_cost：tag → 成本 SpinBox
var _terr_data_loading := false
# 地形数据编辑范围：global=改全局 terrains.json（所有图）/ map=只覆盖本图（map_terrain_overrides）
var _terr_scope := "global"
var _terr_scope_opt: OptionButton
var _terr_ov_label: Label
var _terr_save_btn: Button              # 「保存到 terrains.json」（global 范围）
var _terr_clear_btn: Button            # 「清除本图覆盖」（map 范围）
var _terrain_panel: Control            # 地形笔刷区（当前层=地形时显示）
var _region_panel: Control             # 区域工具区（当前层=区域时显示）
var _region_list: ItemList             # 区域列表
var _region_color_btn: ColorPickerButton
var _region_kind_opt: OptionButton     # 区域类型下拉（触发区/部署区）
var _env_time_opt: OptionButton        # 环境·日夜下拉（昼/夜…）
var _env_weather_box: VBoxContainer    # 环境·天气表行容器（每行 = 天气/权重/最短·最长回合 + 删）
var _region_rename_dlg: ConfirmationDialog
var _region_rename_edit: LineEdit
var _save_dlg: FileDialog
var _load_dlg: FileDialog
var _history_list: ItemList
var _file_label: Label
var _confirm_dlg: ConfirmationDialog   # 未保存改动时的「确定丢弃？」确认框
var _pending: Callable                 # 确认后要执行的动作（新建 / 加载 / 切换地图）

# —— 地图库（文件夹 + 其中的地图列表）——
var _map_dir := DEFAULT_MAP_DIR
var _map_list: ItemList                # 侧栏：当前文件夹内的地图文件
var _map_paths := []                   # 与 _map_list 行一一对应的完整路径
var _dir_label: Label                  # 显示当前文件夹
var _dir_dlg: FileDialog               # 选文件夹对话框
var _newmap_dlg: ConfirmationDialog    # 「新建地图」弹窗（输入文件名）
var _newmap_name: LineEdit             # 新建地图的文件名输入框

# 撤销/重做：以整图快照为单位，每项 {"snap":Dictionary, "label":String}
var _undo_stack := []
var _redo_stack := []
var _stroke_snapshot = null
var _stroke_dirty := false
var _stroke_count := 0

func _ready() -> void:
	_load_terrains()
	_load_config()        # 恢复上次选的地图文件夹
	_build_ui()
	_scan_maps()          # 列出文件夹内的地图
	# 启动即打开战斗地图（与 Sandbox 共享）；不存在则建空白图并把它指向战斗地图路径，
	# 这样首次 Ctrl+S 就会生成它，沙盒随即能读到。
	if FileAccess.file_exists(MAP_PATH):
		load_from_file(MAP_PATH)
	else:
		new_map(width, height)
		current_path = MAP_PATH
		_update_file_label()
		_refresh_map_highlight()

# 地形定义经 TerrainDB 载入（单一数据源；缺失/损坏的兜底也在 TerrainDB 内）
func _load_terrains() -> void:
	PALETTE = TerrainDB.palette()

# ------------------------------------------------------------------ UI

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	# ---- 顶部工具栏 ----
	var bar := HBoxContainer.new()
	root.add_child(bar)

	if not embedded:   # 嵌入 Game 时由 Game 顶栏提供「主菜单」，这里不重复
		var menu_btn := Button.new()
		menu_btn.text = "主菜单"
		menu_btn.pressed.connect(_on_back_to_menu)
		bar.add_child(menu_btn)
		bar.add_child(VSeparator.new())

	bar.add_child(_make_label("宽"))
	width_spin = SpinBox.new()
	width_spin.min_value = 1
	width_spin.max_value = MAX_W
	width_spin.value = width
	bar.add_child(width_spin)

	bar.add_child(_make_label("高"))
	height_spin = SpinBox.new()
	height_spin.min_value = 1
	height_spin.max_value = MAX_H
	height_spin.value = height
	bar.add_child(height_spin)

	bar.add_child(_make_label("预设"))
	var preset_option := OptionButton.new()
	for p in SIZE_PRESETS:
		preset_option.add_item(p.label)
	preset_option.item_selected.connect(_on_preset_selected)
	bar.add_child(preset_option)

	var new_btn := Button.new()
	new_btn.text = "新建"
	new_btn.pressed.connect(_on_new_pressed)
	bar.add_child(new_btn)

	bar.add_child(VSeparator.new())

	var save_btn := Button.new()
	save_btn.text = "保存"
	save_btn.pressed.connect(_save_shortcut)
	bar.add_child(save_btn)

	var save_as_btn := Button.new()
	save_as_btn.text = "另存为"
	save_as_btn.pressed.connect(_on_save_as_pressed)
	bar.add_child(save_as_btn)

	var load_btn := Button.new()
	load_btn.text = "加载"
	load_btn.pressed.connect(_on_load_pressed)
	bar.add_child(load_btn)

	bar.add_child(VSeparator.new())

	var undo_btn := Button.new()
	undo_btn.text = "撤销"
	undo_btn.pressed.connect(undo)
	bar.add_child(undo_btn)

	var redo_btn := Button.new()
	redo_btn.text = "重做"
	redo_btn.pressed.connect(redo)
	bar.add_child(redo_btn)

	bar.add_child(VSeparator.new())

	var reset_view_btn := Button.new()
	reset_view_btn.text = "适配窗口"
	reset_view_btn.pressed.connect(_on_reset_view)
	bar.add_child(reset_view_btn)

	bar.add_child(VSeparator.new())
	status_label = Label.new()
	bar.add_child(status_label)

	# ---- 主体：左笔刷栏 + 中画布 + 右历史栏 ----
	var main := HBoxContainer.new()
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(main)

	main.add_child(_build_brush_sidebar())

	canvas = EditorCanvas.new()
	canvas.editor = self
	canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_child(canvas)

	main.add_child(_build_side_panel())

	# ---- 文件对话框（建一次复用）----
	_save_dlg = _make_file_dialog(FileDialog.FILE_MODE_SAVE_FILE)
	_save_dlg.current_file = "map.json"
	_save_dlg.file_selected.connect(save_to_file)
	add_child(_save_dlg)

	_load_dlg = _make_file_dialog(FileDialog.FILE_MODE_OPEN_FILE)
	_load_dlg.file_selected.connect(load_from_file)
	add_child(_load_dlg)

	# 选文件夹对话框（地图库默认路径）
	_dir_dlg = FileDialog.new()
	_dir_dlg.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_dir_dlg.access = FileDialog.ACCESS_FILESYSTEM
	_dir_dlg.use_native_dialog = true
	_dir_dlg.dir_selected.connect(_set_map_dir)
	add_child(_dir_dlg)

	# 未保存改动确认框（新建/加载/切换前若 _dirty 则先问一次）
	_confirm_dlg = ConfirmationDialog.new()
	_confirm_dlg.title = "未保存的改动"
	_confirm_dlg.dialog_text = "当前地图有未保存的改动，确定要丢弃吗？"
	_confirm_dlg.ok_button_text = "丢弃"
	_confirm_dlg.get_cancel_button().text = "取消"
	_confirm_dlg.confirmed.connect(func():
		if _pending.is_valid():
			_pending.call())
	_confirm_dlg.canceled.connect(_refresh_map_highlight)  # 取消切换则恢复列表选中
	add_child(_confirm_dlg)

	# 新建地图弹窗（输入文件名，尺寸用顶栏的宽/高）
	_newmap_dlg = ConfirmationDialog.new()
	_newmap_dlg.title = "新建地图"
	_newmap_dlg.ok_button_text = "创建"
	_newmap_dlg.get_cancel_button().text = "取消"
	var nm_box := VBoxContainer.new()
	nm_box.add_child(_make_label("文件名（存到当前文件夹）"))
	_newmap_name = LineEdit.new()
	_newmap_name.text = "new_map.json"
	_newmap_name.custom_minimum_size = Vector2(280, 0)
	nm_box.add_child(_newmap_name)
	_newmap_dlg.add_child(nm_box)
	_newmap_dlg.register_text_enter(_newmap_name)
	_newmap_dlg.confirmed.connect(_create_map)
	add_child(_newmap_dlg)

	# 区域改名弹窗
	_region_rename_dlg = ConfirmationDialog.new()
	_region_rename_dlg.title = "区域改名"
	_region_rename_dlg.ok_button_text = "确定"
	_region_rename_dlg.get_cancel_button().text = "取消"
	var rr_box := VBoxContainer.new()
	rr_box.add_child(_make_label("区域名"))
	_region_rename_edit = LineEdit.new()
	_region_rename_edit.custom_minimum_size = Vector2(260, 0)
	rr_box.add_child(_region_rename_edit)
	_region_rename_dlg.add_child(rr_box)
	_region_rename_dlg.register_text_enter(_region_rename_edit)
	_region_rename_dlg.confirmed.connect(_apply_region_rename)
	add_child(_region_rename_dlg)

	brush_buttons[0].button_pressed = true  # 默认选第一支画笔
	_refresh_history()
	_refresh_region_list()
	_refresh_env_panel()
	_update_file_label()
	_build_unit_edit_win()

func _build_brush_sidebar() -> Control:
	var sidebar := VBoxContainer.new()
	sidebar.custom_minimum_size = Vector2(180, 0)

	# —— 图层切换：地形 / 区域（互斥）——
	sidebar.add_child(_make_label("图层"))
	var layer_row := HBoxContainer.new()
	var lg := ButtonGroup.new()
	var terr_btn := _layer_button("地形", "terrain", lg)
	terr_btn.button_pressed = true
	layer_row.add_child(terr_btn)
	layer_row.add_child(_layer_button("区域", "region", lg))
	layer_row.add_child(_layer_button("单位", "unit", lg))
	layer_row.add_child(_layer_button("触发", "trigger", lg))
	sidebar.add_child(layer_row)
	sidebar.add_child(HSeparator.new())

	# 地形笔刷区（当前层=地形时显示）
	_terrain_panel = _build_terrain_brushes()
	sidebar.add_child(_terrain_panel)
	# 区域工具区（当前层=区域时显示）
	_region_panel = _build_region_tools()
	_region_panel.visible = false
	sidebar.add_child(_region_panel)
	# 单位工具区（当前层=单位时显示）
	_unit_panel = _build_unit_tools()
	_unit_panel.visible = false
	sidebar.add_child(_unit_panel)
	# 触发器工具区（当前层=触发器时显示）
	_trigger_panel = _build_trigger_tools()
	_trigger_panel.visible = false
	sidebar.add_child(_trigger_panel)
	return sidebar

# 图层切换按钮（toggle，分组互斥）
func _layer_button(label: String, layer_id: String, group: ButtonGroup) -> Button:
	var b := Button.new()
	b.text = label
	b.toggle_mode = true
	b.button_group = group
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.toggled.connect(func(pressed: bool):
		if pressed:
			_set_layer(layer_id))
	return b

func _set_layer(id: String) -> void:
	current_layer = id
	if id != "unit":
		_close_unit_edit()   # 离开单位层，关掉深编面板
	if _terrain_panel: _terrain_panel.visible = (id == "terrain")
	if _region_panel: _region_panel.visible = (id == "region")
	if _unit_panel: _unit_panel.visible = (id == "unit")
	if _trigger_panel: _trigger_panel.visible = (id == "trigger")
	if id == "trigger":
		_refresh_trigger_list()
		if _active_trigger_idx < 0 and not map_triggers.is_empty():
			_active_trigger_idx = 0
		_load_trigger_form()
	if canvas: canvas.queue_redraw()
	if id == "region" and regions.is_empty():
		set_status("区域层：点「＋ 新建区域」再左键画、右键擦")
	elif id == "unit":
		set_status("单位层：选原型 + 阵营 → 左键落子 / 右键删除（摆这一关的单位）")
	elif id == "trigger":
		set_status("触发器层：＋新建 → 选区域 + 事件 + 配 do 动作（关卡事件）")
	else:
		set_status("当前层：%s" % ("地形" if id == "terrain" else "区域"))

# 地形笔刷竖列（原 _build_brush_sidebar 内容）
func _build_terrain_brushes() -> Control:
	var box := VBoxContainer.new()
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_make_label("地形笔刷"))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	var bg := ButtonGroup.new()
	brush_buttons = []
	for i in PALETTE.size():
		var b := _make_brush_button(PALETTE[i], bg)
		b.toggled.connect(_on_brush_toggled.bind(i))
		list.add_child(b)
		brush_buttons.append(b)
	# —— 地形数据（编辑选中笔刷的战斗属性）——
	# 范围：全局＝写回 terrains.json（影响所有图）；本图＝只覆盖这张图（存进地图 terrain_overrides）
	box.add_child(HSeparator.new())
	box.add_child(_make_label("地形数据（选中笔刷）"))
	var srow := HBoxContainer.new()
	srow.add_child(_make_label("范围"))
	_terr_scope_opt = OptionButton.new()
	_terr_scope_opt.add_item("全局 (terrains.json)", 0)
	_terr_scope_opt.add_item("本图 (仅此图)", 1)
	_terr_scope_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_terr_scope_opt.item_selected.connect(_on_terr_scope_changed)
	srow.add_child(_terr_scope_opt)
	box.add_child(srow)
	_terr_ov_label = _make_label("")
	_terr_ov_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_terr_ov_label)
	var crow := HBoxContainer.new()
	crow.add_child(_make_label("移动成本"))
	_terr_cost_spin = SpinBox.new()
	_terr_cost_spin.min_value = 0
	_terr_cost_spin.max_value = 9
	_terr_cost_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_terr_cost_spin.value_changed.connect(_on_terr_cost_changed)
	crow.add_child(_terr_cost_spin)
	box.add_child(crow)
	var prow := HBoxContainer.new()
	prow.add_child(_make_label("通行"))
	_terr_pass_opt = OptionButton.new()
	for i in TERR_PASS_OPTS.size():
		_terr_pass_opt.add_item(TERR_PASS_OPTS[i][1], i)
	_terr_pass_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_terr_pass_opt.item_selected.connect(_on_terr_pass_changed)
	prow.add_child(_terr_pass_opt)
	box.add_child(prow)
	# 通行=限定tag 时：勾选哪些移动型可进（如深水仅勾「飞行」）
	_terr_pass_tag_row = HBoxContainer.new()
	_terr_pass_tag_row.add_child(_make_label("可进"))
	_terr_pass_checks = {}
	for pair in PASS_TAGS:
		var cb := CheckBox.new()
		cb.text = str(pair[1])
		cb.toggled.connect(func(_on: bool): _on_terr_pass_tag_toggled())
		_terr_pass_tag_row.add_child(cb)
		_terr_pass_checks[str(pair[0])] = cb
	_terr_pass_tag_row.visible = false
	box.add_child(_terr_pass_tag_row)
	# tag_cost：按移动型覆盖移动成本（勾启用 + 成本；如森林 flying→1）。不勾＝用基础 cost。
	box.add_child(_make_label("tag 成本（按移动型取更优）"))
	_terr_tagcost_checks = {}
	_terr_tagcost_spins = {}
	for pair in PASS_TAGS:
		var row := HBoxContainer.new()
		var cb := CheckBox.new()
		cb.text = str(pair[1])
		cb.toggled.connect(func(_on: bool): _on_terr_tagcost_changed())
		row.add_child(cb)
		var sp := SpinBox.new()
		sp.min_value = 0
		sp.max_value = 9
		sp.value = 1
		sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sp.value_changed.connect(func(_v: float): _on_terr_tagcost_changed())
		row.add_child(sp)
		_terr_tagcost_checks[str(pair[0])] = cb
		_terr_tagcost_spins[str(pair[0])] = sp
		box.add_child(row)
	_terr_save_btn = Button.new()
	_terr_save_btn.text = "保存到 terrains.json"
	_terr_save_btn.tooltip_text = "把改过的地形战斗属性写回 terrains.json（影响所有地图；编辑器与战斗共用同一份）"
	_terr_save_btn.pressed.connect(_on_save_terrain_data)
	box.add_child(_terr_save_btn)
	_terr_clear_btn = Button.new()
	_terr_clear_btn.text = "清除本图覆盖"
	_terr_clear_btn.tooltip_text = "移除本图对该地形的覆盖，回到全局值（本图覆盖随地图 Ctrl+S 存盘）"
	_terr_clear_btn.pressed.connect(_on_terr_clear_override)
	_terr_clear_btn.visible = false
	box.add_child(_terr_clear_btn)
	return box

# 选中笔刷时刷新「地形数据」编辑区
func _refresh_terrain_data() -> void:
	if _terr_cost_spin == null or brush_index < 0 or brush_index >= PALETTE.size():
		return
	_terr_data_loading = true
	# 显示值：本图范围优先本图覆盖、无覆盖则显全局作基线；全局范围显全局
	var mv
	if _terr_scope == "map":
		mv = _map_move_override(false)
		if mv.is_empty():
			mv = PALETTE[brush_index].get("move", {})
	else:
		mv = PALETTE[brush_index].get("move", {})
	if typeof(mv) != TYPE_DICTIONARY:
		mv = {}
	_terr_cost_spin.value = int(mv.get("cost", 1))
	var pb = mv.get("passable_by", "all")
	if typeof(pb) == TYPE_STRING and pb == "all":
		_terr_pass_opt.select(0)
		_terr_pass_tag_row.visible = false
	elif typeof(pb) == TYPE_STRING and pb == "none":
		_terr_pass_opt.select(1)
		_terr_pass_tag_row.visible = false
	else:   # 数组 = 限定tag
		_terr_pass_opt.select(2)
		_terr_pass_tag_row.visible = true
		for pair in PASS_TAGS:
			_terr_pass_checks[str(pair[0])].button_pressed = (typeof(pb) == TYPE_ARRAY and pb.has(str(pair[0])))
	# tag_cost 行：勾选并填入有覆盖的 tag
	var tc = mv.get("tag_cost", {})
	for pair in PASS_TAGS:
		var tag := str(pair[0])
		var has_tc: bool = typeof(tc) == TYPE_DICTIONARY and tc.has(tag)
		_terr_tagcost_checks[tag].button_pressed = has_tc
		if has_tc:
			_terr_tagcost_spins[tag].value = int(tc[tag])
	_terr_data_loading = false
	if _terr_save_btn: _terr_save_btn.visible = (_terr_scope == "global")
	if _terr_clear_btn: _terr_clear_btn.visible = (_terr_scope == "map")
	_refresh_terr_ov_label()

# 取选中笔刷要编辑的 move 块（live 引用，没有则建）：
# 全局范围＝改 PALETTE（写回 terrains.json）；本图范围＝改 map_terrain_overrides[terrain/variant].move
func _terr_move() -> Dictionary:
	if _terr_scope == "map":
		return _map_move_override(true)
	var e = PALETTE[brush_index]
	if typeof(e.get("move")) != TYPE_DICTIONARY:
		e["move"] = {}
	return e["move"]

# 当前笔刷的覆盖 key = "terrain/variant"
func _map_move_key() -> String:
	var e = PALETTE[brush_index]
	return "%s/%s" % [str(e.get("terrain", "")), str(e.get("variant", ""))]

# 取本图对当前笔刷的 move 覆盖；ensure=true 时若无则以「当前全局 move 深拷贝」为起点创建（整块覆盖，避免丢 passable/tag_cost）
func _map_move_override(ensure: bool) -> Dictionary:
	var key := _map_move_key()
	if not map_terrain_overrides.has(key):
		if not ensure:
			return {}
		var gmv = PALETTE[brush_index].get("move", {})
		map_terrain_overrides[key] = {"move": (gmv.duplicate(true) if typeof(gmv) == TYPE_DICTIONARY else {})}
	var ov = map_terrain_overrides[key]
	if typeof(ov.get("move")) != TYPE_DICTIONARY:
		ov["move"] = {}
	return ov["move"]

func _refresh_terr_ov_label() -> void:
	if _terr_ov_label == null:
		return
	if _terr_scope != "map":
		_terr_ov_label.text = "改动写回 terrains.json（影响所有地图）"
		_terr_ov_label.add_theme_color_override("font_color", Color(0.7, 0.74, 0.82))
	elif _map_move_override(false).is_empty():
		_terr_ov_label.text = "本图未覆盖此地形——改任一项即创建本图覆盖（随地图存盘）"
		_terr_ov_label.add_theme_color_override("font_color", Color(0.7, 0.74, 0.82))
	else:
		_terr_ov_label.text = "● 本图已覆盖此地形（只改这张图；下方可清除）"
		_terr_ov_label.add_theme_color_override("font_color", Color(0.55, 0.85, 0.55))

# 范围切换：全局 / 本图
func _on_terr_scope_changed(idx: int) -> void:
	_terr_scope = "map" if idx == 1 else "global"
	_refresh_terrain_data()
	set_status("地形数据范围：%s" % ("本图（仅此图）" if _terr_scope == "map" else "全局（terrains.json）"))

# 本图范围下每次改动 → 标脏（随地图 Ctrl+S 存盘）+ 刷新覆盖状态标
func _terr_edit_touched() -> void:
	if _terr_scope == "map":
		_dirty = true
		_update_file_label()
		_refresh_terr_ov_label()

# 清除当前笔刷的本图覆盖（回到全局值）
func _on_terr_clear_override() -> void:
	var key := _map_move_key()
	if map_terrain_overrides.has(key):
		map_terrain_overrides.erase(key)
		_dirty = true
		_update_file_label()
		set_status("已清除「%s」的本图覆盖（回到全局）" % str(PALETTE[brush_index].label))
	_refresh_terrain_data()
	if canvas: canvas.queue_redraw()

func _on_terr_cost_changed(v: float) -> void:
	if _terr_data_loading or brush_index < 0 or brush_index >= PALETTE.size():
		return
	_terr_move()["cost"] = int(v)
	set_status("「%s」移动成本=%d" % [str(PALETTE[brush_index].label), int(v)])
	_terr_edit_touched()

func _on_terr_pass_changed(idx: int) -> void:
	if _terr_data_loading or brush_index < 0 or brush_index >= PALETTE.size():
		return
	if idx == 0:
		_terr_move()["passable_by"] = "all"
		_terr_pass_tag_row.visible = false
		set_status("「%s」通行=任何单位（点保存写回）" % str(PALETTE[brush_index].label))
	elif idx == 1:
		_terr_move()["passable_by"] = "none"
		_terr_pass_tag_row.visible = false
		set_status("「%s」通行=不可通行（点保存写回）" % str(PALETTE[brush_index].label))
	else:   # 限定tag：切到数组形（非数组则初始全勾，用户取消以限制），显示勾选行
		if typeof(_terr_move().get("passable_by")) != TYPE_ARRAY:
			var all_tags := []
			for pair in PASS_TAGS:
				all_tags.append(str(pair[0]))
			_terr_move()["passable_by"] = all_tags
		_terr_pass_tag_row.visible = true
		_terr_data_loading = true
		var arr = _terr_move().get("passable_by", [])
		for pair in PASS_TAGS:
			_terr_pass_checks[str(pair[0])].button_pressed = (typeof(arr) == TYPE_ARRAY and arr.has(str(pair[0])))
		_terr_data_loading = false
		set_status("「%s」通行=限定tag：勾选可进的移动型（取消＝禁止该类）" % str(PALETTE[brush_index].label))
	_terr_edit_touched()

# 限定tag 勾选变化 → 从勾选项重建 passable_by 数组
func _on_terr_pass_tag_toggled() -> void:
	if _terr_data_loading or brush_index < 0 or brush_index >= PALETTE.size():
		return
	var arr := []
	for pair in PASS_TAGS:
		if _terr_pass_checks[str(pair[0])].button_pressed:
			arr.append(str(pair[0]))
	_terr_move()["passable_by"] = arr
	set_status("「%s」通行=限定[%s]" % [str(PALETTE[brush_index].label), ", ".join(arr)])
	_terr_edit_touched()

# tag_cost 勾选 / 成本变化 → 从勾选的 tag 重建 move.tag_cost（空则移除该键）
func _on_terr_tagcost_changed() -> void:
	if _terr_data_loading or brush_index < 0 or brush_index >= PALETTE.size():
		return
	var tc := {}
	for pair in PASS_TAGS:
		var tag := str(pair[0])
		if _terr_tagcost_checks[tag].button_pressed:
			tc[tag] = int(_terr_tagcost_spins[tag].value)
	var mv := _terr_move()
	if tc.is_empty():
		mv.erase("tag_cost")
	else:
		mv["tag_cost"] = tc
	set_status("「%s」tag 成本已改" % str(PALETTE[brush_index].label))
	_terr_edit_touched()

func _on_save_terrain_data() -> void:
	if TerrainDB.save():
		set_status("已保存地形数据 → terrains.json（影响所有地图，编辑器与战斗共用）")
	else:
		set_status("保存失败：无法写入 terrains.json")

# 区域工具：列表（选当前）+ 新建/改名/删除 + 颜色
func _build_region_tools() -> Control:
	var v := VBoxContainer.new()
	v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_make_label("区域（左键画 / 右键擦）"))
	_region_list = ItemList.new()
	_region_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_region_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_region_list.custom_minimum_size = Vector2(0, 150)
	_region_list.item_selected.connect(_on_region_selected)
	v.add_child(_region_list)
	var btns := HBoxContainer.new()
	var add_b := Button.new()
	add_b.text = "＋ 新建区域"
	add_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_b.pressed.connect(_on_add_region)
	btns.add_child(add_b)
	v.add_child(btns)
	var btns2 := HBoxContainer.new()
	var ren_b := Button.new()
	ren_b.text = "改名"
	ren_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ren_b.pressed.connect(_on_rename_region)
	btns2.add_child(ren_b)
	var del_b := Button.new()
	del_b.text = "删除"
	del_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del_b.pressed.connect(_on_delete_region)
	btns2.add_child(del_b)
	v.add_child(btns2)
	var crow := HBoxContainer.new()
	crow.add_child(_make_label("颜色"))
	_region_color_btn = ColorPickerButton.new()
	_region_color_btn.custom_minimum_size = Vector2(0, 26)
	_region_color_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_region_color_btn.color_changed.connect(_on_region_color_changed)
	crow.add_child(_region_color_btn)
	v.add_child(crow)
	# 区域类型：触发区(aggro) / 部署区(deploy)——写进地图，战斗侧据此分派
	var krow := HBoxContainer.new()
	krow.add_child(_make_label("类型"))
	_region_kind_opt = OptionButton.new()
	for i in REGION_KINDS.size():
		_region_kind_opt.add_item(REGION_KINDS[i][1], i)
	_region_kind_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_region_kind_opt.item_selected.connect(_on_region_kind_changed)
	krow.add_child(_region_kind_opt)
	v.add_child(krow)
	return v

# 单位工具：阵营选择 + 原型列表（选一个再到画布上左键落子）
func _build_unit_tools() -> Control:
	var v := VBoxContainer.new()
	v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_make_label("单位（左键落子 / 右键删）"))
	var frow := HBoxContainer.new()
	frow.add_child(_make_label("阵营"))
	var fopt := OptionButton.new()
	for i in UNIT_FACTIONS.size():
		fopt.add_item(TagDB.cn(UNIT_FACTIONS[i]), i)
	fopt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fopt.item_selected.connect(func(idx: int): _unit_faction = UNIT_FACTIONS[idx])
	frow.add_child(fopt)
	v.add_child(frow)
	v.add_child(_make_label("原型（选一个再落子）"))
	_unit_list = ItemList.new()
	_unit_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_unit_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_unit_list.custom_minimum_size = Vector2(0, 180)
	_unit_list.item_selected.connect(_on_unit_proto_selected)
	v.add_child(_unit_list)
	_refresh_unit_protos()
	return v

func _refresh_unit_protos() -> void:
	_unit_protos = UnitFactory.all_prototypes()   # 与 Sandbox 共用同一原型读取
	if _unit_list == null:
		return
	_unit_list.clear()
	for p in _unit_protos:
		_unit_list.add_item("%s（%s）" % [str(p.get("name", "单位")), TagDB.cn(str(p.get("default_faction", "enemy")))])

func _on_unit_proto_selected(idx: int) -> void:
	if idx >= 0 and idx < _unit_protos.size():
		_unit_proto = _unit_protos[idx]
		_unit_faction = str(_unit_proto.get("default_faction", _unit_faction))   # 选原型即取其默认阵营（仍可改）
		set_status("将落子：%s（%s）— 左键放到格上" % [str(_unit_proto.get("name", "单位")), TagDB.cn(_unit_faction)])


# 单位层棋子色（供 EditorCanvas 画 token；与战斗一致：我方/友方蓝、敌方红、中立黄）
func faction_color(fac: String) -> Color:
	return FACTION_COLORS.get(fac, Color(0.8, 0.8, 0.8))

# 单位层：在 (col,row) 落子当前选中的原型（替换该格已有单位）。走 stroke → 一次撤销。
func _place_unit(col: int, row: int) -> void:
	if _unit_proto == null:
		set_status("先在左侧选一个原型")
		return
	for i in range(map_units.size() - 1, -1, -1):
		var e = map_units[i]
		if typeof(e) == TYPE_DICTIONARY and int(e.get("col", -1)) == col and int(e.get("row", -1)) == row:
			map_units.remove_at(i)
	map_units.append({"proto": (_unit_proto as Dictionary).duplicate(true), "col": col, "row": row, "faction": _unit_faction})
	_stroke_dirty = true
	if canvas: canvas.queue_redraw()

# 单位层：删除 (col,row) 上的单位
func _remove_unit(col: int, row: int) -> void:
	var removed := false
	for i in range(map_units.size() - 1, -1, -1):
		var e = map_units[i]
		if typeof(e) == TYPE_DICTIONARY and int(e.get("col", -1)) == col and int(e.get("row", -1)) == row:
			map_units.remove_at(i)
			_stroke_dirty = true
			removed = true
	if removed and _editing_unit != null:
		_close_unit_edit()   # 删单位会移动下标 → 关掉深编面板，避免序列化写错条目
	if canvas: canvas.queue_redraw()

# ============ placed 单位深度编辑（点已放单位 → 复用 DeployPanel 改四维/装备/技能/特性/AI）============
# 右侧浮动面板（DeployPanel，editor_mode）。改动即时经宿主回调序列化回 map_units[i].proto。

func _build_unit_edit_win() -> void:
	_unit_edit_win = PanelContainer.new()
	_unit_edit_win.visible = false
	_unit_edit_win.anchor_left = 1.0
	_unit_edit_win.anchor_right = 1.0
	_unit_edit_win.anchor_top = 0.0
	_unit_edit_win.anchor_bottom = 1.0
	_unit_edit_win.offset_left = -340
	_unit_edit_win.offset_right = -8
	_unit_edit_win.offset_top = 48
	_unit_edit_win.offset_bottom = -8
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.11, 0.12, 0.15, 0.98)
	sb.set_border_width_all(1)
	sb.border_color = Color(0.42, 0.52, 0.66)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	_unit_edit_win.add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	var head := HBoxContainer.new()
	var t := Label.new()
	t.text = "编辑放置的单位"
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	head.add_child(t)
	var close_b := Button.new()
	close_b.text = "✕"
	close_b.pressed.connect(_close_unit_edit)
	head.add_child(close_b)
	v.add_child(head)
	v.add_child(HSeparator.new())
	_unit_edit_panel = DeployPanel.new()
	_unit_edit_panel.host = self
	_unit_edit_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_unit_edit_panel)
	_unit_edit_win.add_child(v)
	add_child(_unit_edit_win)   # 加在 root 之后 → 浮在画布上层
	_unit_edit_panel.set_editor_mode(true)   # 隐藏「开始游戏/存单位进地图」等战斗宿主专属钮

# 打开某个 map_units[idx] 的深度编辑：从 proto 造活 Unit 交给 DeployPanel
func _edit_placed_unit(idx: int) -> void:
	if idx < 0 or idx >= map_units.size():
		return
	var e = map_units[idx]
	var proto = e.get("proto", {})
	if typeof(proto) != TYPE_DICTIONARY:
		proto = {}
	_editing_index = idx
	_editing_unit = UnitFactory.make_unit(proto, str(e.get("faction", "enemy")), int(e.get("col", 0)), int(e.get("row", 0)))
	_unit_edit_snap_pushed = false
	if _unit_edit_win: _unit_edit_win.visible = true
	if _unit_edit_panel: _unit_edit_panel.select_unit(_editing_unit)
	set_status("编辑单位：%s（改动即时写回关卡；右上 ✕ 关闭）" % _editing_unit.unit_name)

func _close_unit_edit() -> void:
	if _unit_edit_win: _unit_edit_win.visible = false
	if _unit_edit_panel: _unit_edit_panel.select_unit(null)
	_editing_unit = null
	_editing_index = -1
	_unit_edit_snap_pushed = false

# 找 (col,row) 上的单位在 map_units 的下标（无则 -1；后放的在上，取最后一个）
func _unit_index_at(col: int, row: int) -> int:
	for i in range(map_units.size() - 1, -1, -1):
		var e = map_units[i]
		if typeof(e) == TYPE_DICTIONARY and int(e.get("col", -1)) == col and int(e.get("row", -1)) == row:
			return i
	return -1

# 把当前编辑的活 Unit 序列化回 map_units[_editing_index]（proto + faction 都更新）
func _serialize_editing_unit() -> void:
	if _editing_unit == null or _editing_index < 0 or _editing_index >= map_units.size():
		return
	var e = map_units[_editing_index]
	e["proto"] = UnitFactory.unit_to_proto(_editing_unit)
	e["faction"] = _editing_unit.faction   # 阵营在面板里可能改过
	_dirty = true
	_update_file_label()

# 本次编辑会话首次改动前压一次撤销快照（整段编辑 = 一步撤销）
func _unit_edit_before_change() -> void:
	if not _unit_edit_snap_pushed:
		_push_undo(_snapshot(), "编辑单位")
		_unit_edit_snap_pushed = true

# —— DeployPanel 的宿主回调（editor_mode 下需要的最小契约）——
# 改四维/属性/特性/装备 → 重算派生 + 序列化回 map_units
func _commit_unit(u) -> void:
	if u == null:
		return
	_unit_edit_before_change()
	u.recompute_derived()
	u.init_vitals()
	_serialize_editing_unit()
	if canvas: canvas.queue_redraw()

# 改名字/阵营 → DeployPanel 调此（战斗宿主里刷底部栏；编辑器里=序列化回关卡 + 重绘 token）
func _refresh_roster_bar() -> void:
	if _editing_unit == null:
		return
	_unit_edit_before_change()
	_serialize_editing_unit()
	if canvas: canvas.queue_redraw()

# DeployPanel 改阵营时会调（战斗宿主里高亮被查看单位）；编辑器里无需，空实现
func set_viewed_unit(_u) -> void:
	pass

# DeployPanel「保存为预设」→ 走 UnitFactory 写 user://unit_presets.json
func save_unit_preset(u, preset_name: String) -> void:
	UnitFactory.save_preset(u, preset_name)

# ============ 触发器层（authoring 关卡事件：when 条件 → do 动作）============

func _build_trigger_tools() -> Control:
	var v := VBoxContainer.new()
	v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(_make_label("触发器"))
	_trigger_list = ItemList.new()
	_trigger_list.custom_minimum_size = Vector2(0, 84)
	_trigger_list.item_selected.connect(_on_trigger_selected)
	v.add_child(_trigger_list)
	var brow := HBoxContainer.new()
	var add_b := Button.new()
	add_b.text = "＋新建"
	add_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_b.pressed.connect(_on_add_trigger)
	brow.add_child(add_b)
	var del_b := Button.new()
	del_b.text = "删除"
	del_b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del_b.pressed.connect(_on_delete_trigger)
	brow.add_child(del_b)
	v.add_child(brow)
	v.add_child(HSeparator.new())
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var form := VBoxContainer.new()
	form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(form)
	v.add_child(scroll)
	form.add_child(_make_label("标签"))
	_trig_label_edit = LineEdit.new()
	_trig_label_edit.text_changed.connect(func(t: String): _set_trig_field("label", t))
	form.add_child(_trig_label_edit)
	form.add_child(_make_label("事件：踏入区域"))
	form.add_child(_make_label("区域"))
	_trig_region_opt = OptionButton.new()
	_trig_region_opt.item_selected.connect(_on_trig_region_selected)
	form.add_child(_trig_region_opt)
	form.add_child(_make_label("触发方"))
	_trig_faction_opt = OptionButton.new()
	for i in TRIG_FACTIONS.size():
		_trig_faction_opt.add_item(TRIG_FACTIONS[i][1], i)
	_trig_faction_opt.item_selected.connect(func(idx: int): _set_trig_when("by_faction", TRIG_FACTIONS[idx][0]))
	form.add_child(_trig_faction_opt)
	_trig_once_chk = CheckBox.new()
	_trig_once_chk.text = "只触发一次"
	_trig_once_chk.toggled.connect(func(on: bool): _set_trig_when("once", on))
	form.add_child(_trig_once_chk)
	form.add_child(HSeparator.new())
	form.add_child(_make_label("动作（do）"))
	_trig_do_box = VBoxContainer.new()
	_trig_do_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	form.add_child(_trig_do_box)
	return v

func active_trigger() -> Dictionary:
	if _active_trigger_idx >= 0 and _active_trigger_idx < map_triggers.size():
		return map_triggers[_active_trigger_idx] as Dictionary
	return {}

func _unique_trigger_id() -> String:
	var used := {}
	for t in map_triggers:
		used[str(t.get("id", ""))] = true
	var n := 1
	while used.has("trig_%d" % n):
		n += 1
	return "trig_%d" % n

func _on_add_trigger() -> void:
	_push_undo(_snapshot(), "新建触发器")
	map_triggers.append({"id": _unique_trigger_id(), "label": "触发器%d" % (map_triggers.size() + 1),
		"when": {"event": "enter_region", "region": "", "by_faction": "player", "once": true}, "do": []})
	_active_trigger_idx = map_triggers.size() - 1
	_dirty = true
	_refresh_trigger_list()
	_load_trigger_form()

func _on_delete_trigger() -> void:
	if active_trigger().is_empty():
		return
	_push_undo(_snapshot(), "删除触发器")
	map_triggers.remove_at(_active_trigger_idx)
	_active_trigger_idx = mini(_active_trigger_idx, map_triggers.size() - 1)
	_dirty = true
	_refresh_trigger_list()
	_load_trigger_form()

func _on_trigger_selected(idx: int) -> void:
	_active_trigger_idx = idx
	_load_trigger_form()

func _refresh_trigger_list() -> void:
	if _trigger_list == null:
		return
	_trigger_list.clear()
	for t in map_triggers:
		_trigger_list.add_item(str(t.get("label", t.get("id", "触发器"))))
	if _active_trigger_idx >= 0 and _active_trigger_idx < map_triggers.size():
		_trigger_list.select(_active_trigger_idx)

func _set_trig_field(key: String, val) -> void:
	if _trig_loading:
		return
	var t := active_trigger()
	if t.is_empty():
		return
	t[key] = val
	_dirty = true
	if key == "label" and _trigger_list != null and _active_trigger_idx >= 0:
		_trigger_list.set_item_text(_active_trigger_idx, str(val))

func _set_trig_when(key: String, val) -> void:
	if _trig_loading:
		return
	var t := active_trigger()
	if t.is_empty():
		return
	if typeof(t.get("when")) != TYPE_DICTIONARY:
		t["when"] = {}
	t["when"][key] = val
	_dirty = true

func _on_trig_region_selected(idx: int) -> void:
	if _trig_loading:
		return
	if idx >= 0 and idx < regions.size():
		_set_trig_when("region", str(regions[idx].get("id", "")))

func _load_trigger_form() -> void:
	_trig_loading = true
	var t := active_trigger()
	var has := not t.is_empty()
	_trig_label_edit.editable = has
	_trig_label_edit.text = str(t.get("label", "")) if has else ""
	_trig_region_opt.clear()
	if regions.is_empty():
		_trig_region_opt.add_item("（无区域，先去区域层建）")
	else:
		for i in regions.size():
			_trig_region_opt.add_item("%s (%s)" % [str(regions[i].get("label", "区域")), str(regions[i].get("id", ""))])
	var when = t.get("when", {}) if has else {}
	if typeof(when) == TYPE_DICTIONARY:
		var rid := str(when.get("region", ""))
		for i in regions.size():
			if str(regions[i].get("id", "")) == rid:
				_trig_region_opt.select(i)
				break
		var by := str(when.get("by_faction", "player"))
		for i in TRIG_FACTIONS.size():
			if TRIG_FACTIONS[i][0] == by:
				_trig_faction_opt.select(i)
		_trig_once_chk.button_pressed = bool(when.get("once", true))
	_refresh_do_list()
	_trig_loading = false

func _refresh_do_list() -> void:
	if _trig_do_box == null:
		return
	for c in _trig_do_box.get_children():
		c.queue_free()
	var t := active_trigger()
	if t.is_empty():
		_trig_do_box.add_child(_make_label("（先选 / 建一个触发器）"))
		return
	var dolist = t.get("do", [])
	if typeof(dolist) == TYPE_ARRAY:
		for i in dolist.size():
			if typeof(dolist[i]) == TYPE_DICTIONARY:
				_trig_do_box.add_child(_build_action_row(dolist[i], i))
	var mb := MenuButton.new()
	mb.text = "＋ 添加动作"
	mb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var pop := mb.get_popup()
	for i in TRIG_ACTION_TYPES.size():
		pop.add_item(TRIG_ACTION_TYPES[i][1], i)
	pop.id_pressed.connect(func(id: int): _on_add_action(TRIG_ACTION_TYPES[id][0]))
	_trig_do_box.add_child(mb)

func _action_cn(act: String) -> String:
	for pair in TRIG_ACTION_TYPES:
		if pair[0] == act:
			return str(pair[1])
	return act

func _default_action(act: String) -> Dictionary:
	match act:
		"show_message":
			return {"action": "show_message", "text": "消息"}
		"spawn_unit":
			return {"action": "spawn_unit", "proto_id": "", "faction": "enemy", "col": 0, "row": 0}
		"activate_aggro":
			return {"action": "activate_aggro", "group": ""}
	return {"action": act}

func _on_add_action(act: String) -> void:
	var t := active_trigger()
	if t.is_empty():
		return
	_push_undo(_snapshot(), "添加动作")
	if typeof(t.get("do")) != TYPE_ARRAY:
		t["do"] = []
	t["do"].append(_default_action(act))
	_dirty = true
	_refresh_do_list()

func _on_remove_action(idx: int) -> void:
	var t := active_trigger()
	if t.is_empty():
		return
	var dolist = t.get("do", [])
	if typeof(dolist) == TYPE_ARRAY and idx >= 0 and idx < dolist.size():
		_push_undo(_snapshot(), "删除动作")
		dolist.remove_at(idx)
		_dirty = true
		_refresh_do_list()

func _set_action_field(a: Dictionary, key: String, val) -> void:
	a[key] = val
	_dirty = true

func _build_action_row(a: Dictionary, idx: int) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var head := HBoxContainer.new()
	var lbl := _make_label("• " + _action_cn(str(a.get("action", ""))))
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(lbl)
	var x := Button.new()
	x.text = "✕"
	x.pressed.connect(_on_remove_action.bind(idx))
	head.add_child(x)
	box.add_child(head)
	match str(a.get("action", "")):
		"show_message":
			var le := LineEdit.new()
			le.text = str(a.get("text", ""))
			le.text_changed.connect(func(t: String): _set_action_field(a, "text", t))
			box.add_child(le)
		"activate_aggro":
			var le := LineEdit.new()
			le.placeholder_text = "组id（空=全敌方）"
			le.text = str(a.get("group", ""))
			le.text_changed.connect(func(t: String): _set_action_field(a, "group", t))
			box.add_child(le)
		"spawn_unit":
			var protos := UnitFactory.all_prototypes()
			var po := OptionButton.new()
			for i in protos.size():
				po.add_item(str(protos[i].get("name", "")))
			for i in protos.size():
				if str(protos[i].get("id", "")) == str(a.get("proto_id", "")):
					po.select(i)
			po.item_selected.connect(func(i: int): _set_action_field(a, "proto_id", str(protos[i].get("id", ""))))
			box.add_child(po)
			var fo := OptionButton.new()
			for i in UNIT_FACTIONS.size():
				fo.add_item(TagDB.cn(UNIT_FACTIONS[i]))
				if UNIT_FACTIONS[i] == str(a.get("faction", "enemy")):
					fo.select(i)
			fo.item_selected.connect(func(i: int): _set_action_field(a, "faction", UNIT_FACTIONS[i]))
			box.add_child(fo)
			var cr := HBoxContainer.new()
			cr.add_child(_make_label("col"))
			var cs := SpinBox.new()
			cs.min_value = 0
			cs.max_value = MAX_W - 1
			cs.value = int(a.get("col", 0))
			cs.value_changed.connect(func(val: float): _set_action_field(a, "col", int(val)))
			cr.add_child(cs)
			cr.add_child(_make_label("row"))
			var rs := SpinBox.new()
			rs.min_value = 0
			rs.max_value = MAX_H - 1
			rs.value = int(a.get("row", 0))
			rs.value_changed.connect(func(val: float): _set_action_field(a, "row", int(val)))
			cr.add_child(rs)
			box.add_child(cr)
	box.add_child(HSeparator.new())
	return box

func _build_side_panel() -> Control:
	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(240, 0)

	# —— 地图库（文件夹 + 其中地图列表）——
	side.add_child(_make_label("地图库"))
	_dir_label = _make_label("")
	_dir_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dir_label.add_theme_color_override("font_color", Color(0.75, 0.78, 0.85))
	side.add_child(_dir_label)
	var dir_btns := HBoxContainer.new()
	var pick_btn := Button.new()
	pick_btn.text = "选择文件夹"
	pick_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pick_btn.pressed.connect(_on_pick_dir)
	dir_btns.add_child(pick_btn)
	var refresh_btn := Button.new()
	refresh_btn.text = "刷新"
	refresh_btn.pressed.connect(_scan_maps)
	dir_btns.add_child(refresh_btn)
	side.add_child(dir_btns)

	_map_list = ItemList.new()
	_map_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_map_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_map_list.custom_minimum_size = Vector2(0, 150)
	_map_list.item_selected.connect(_on_map_selected)   # 单击即切换（select() 不触发此信号）
	side.add_child(_map_list)

	var new_map_btn := Button.new()
	new_map_btn.text = "＋ 新建地图…"
	new_map_btn.pressed.connect(_on_new_map_in_dir)
	side.add_child(new_map_btn)

	side.add_child(HSeparator.new())

	# —— 环境（日夜 + 天气表；地图级 authoring，见 docs/感知系统.md 🔒）——
	side.add_child(_build_env_section())

	side.add_child(HSeparator.new())

	# —— 当前文件 ——
	_file_label = _make_label("文件：(未保存)")
	_file_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(_file_label)

	side.add_child(HSeparator.new())

	# —— 最近操作（撤销栈）——
	side.add_child(_make_label("最近操作（顶＝下一个撤销）"))
	_history_list = ItemList.new()
	_history_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_history_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.add_child(_history_list)
	return side

# ------------------------------------------------------------------ 环境（日夜 + 天气表）

# 环境面板：日夜下拉 + 天气表（增删行）。写进 map_environment，随图存盘、含撤销。
func _build_env_section() -> Control:
	var v := VBoxContainer.new()
	v.add_child(_make_label("环境（天气·日夜）"))
	var trow := HBoxContainer.new()
	trow.add_child(_make_label("日夜"))
	_env_time_opt = OptionButton.new()
	_env_time_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for t in EnvDB.all_times():
		_env_time_opt.add_item("%s (%s)" % [str(t.get("label", "")), str(t.get("id", ""))])
	_env_time_opt.item_selected.connect(_on_env_time_selected)
	trow.add_child(_env_time_opt)
	v.add_child(trow)
	v.add_child(_make_label("天气表（随机氛围；空=晴）"))
	_env_weather_box = VBoxContainer.new()
	v.add_child(_env_weather_box)
	var add_b := Button.new()
	add_b.text = "＋ 加天气"
	add_b.pressed.connect(_on_env_add_weather)
	v.add_child(add_b)
	return v

# 当前 weather_table（保证返回 Array，且是 map_environment 里那个引用）
func _env_weather_table() -> Array:
	var t = map_environment.get("weather_table", [])
	return t if typeof(t) == TYPE_ARRAY else []

# 刷新整个环境面板（载入 / 撤销 / 新图后调）：同步日夜下拉 + 重建天气行
func _refresh_env_panel() -> void:
	if _env_time_opt == null:
		return
	var cur_time := str(map_environment.get("time", "day")) if typeof(map_environment) == TYPE_DICTIONARY else "day"
	var times := EnvDB.all_times()
	for i in times.size():
		if str(times[i].get("id", "")) == cur_time:
			_env_time_opt.select(i)
			break
	_refresh_env_weather_rows()

# 重建天气表行控件（每行：天气下拉 / 权重 / 最短·最长回合 / 删）
func _refresh_env_weather_rows() -> void:
	if _env_weather_box == null:
		return
	for c in _env_weather_box.get_children():
		c.queue_free()
	var table := _env_weather_table()
	var weathers := EnvDB.all_weathers()
	for i in table.size():
		var row: Dictionary = table[i] if typeof(table[i]) == TYPE_DICTIONARY else {}
		var hb := HBoxContainer.new()
		var wopt := OptionButton.new()
		wopt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var cur_w := str(row.get("weather", "clear"))
		for j in weathers.size():
			wopt.add_item(str(weathers[j].get("label", "")))
			wopt.set_item_metadata(j, str(weathers[j].get("id", "")))
			if str(weathers[j].get("id", "")) == cur_w:
				wopt.select(j)
		wopt.item_selected.connect(_on_env_weather_id.bind(i, wopt))
		hb.add_child(wopt)
		hb.add_child(_env_spin(int(row.get("weight", 1)), 1, 100, "权", _on_env_weather_num.bind(i, "weight")))
		hb.add_child(_env_spin(int(row.get("min_rounds", 1)), 1, 99, "短", _on_env_weather_num.bind(i, "min_rounds")))
		hb.add_child(_env_spin(int(row.get("max_rounds", 1)), 1, 99, "长", _on_env_weather_num.bind(i, "max_rounds")))
		var del := Button.new()
		del.text = "✕"
		del.pressed.connect(_on_env_del_weather.bind(i))
		hb.add_child(del)
		_env_weather_box.add_child(hb)

func _env_spin(val: int, lo: int, hi: int, prefix: String, cb: Callable) -> SpinBox:
	var sp := SpinBox.new()
	sp.min_value = lo
	sp.max_value = hi
	sp.value = val
	sp.prefix = prefix
	sp.custom_minimum_size = Vector2(58, 0)
	sp.value_changed.connect(cb)
	return sp

# 确保 map_environment 可写 + 有 weather_table
func _env_ensure() -> void:
	if typeof(map_environment) != TYPE_DICTIONARY:
		map_environment = {}
	if typeof(map_environment.get("weather_table")) != TYPE_ARRAY:
		map_environment["weather_table"] = []

func _on_env_time_selected(idx: int) -> void:
	var times := EnvDB.all_times()
	if idx < 0 or idx >= times.size():
		return
	var id := str(times[idx].get("id", "day"))
	if str(map_environment.get("time", "day")) == id:
		return
	_push_undo(_snapshot(), "环境·日夜")
	_env_ensure()
	map_environment["time"] = id
	_dirty = true
	_update_file_label()

func _on_env_add_weather() -> void:
	_push_undo(_snapshot(), "加天气")
	_env_ensure()
	map_environment["weather_table"].append({"weather": "rain", "weight": 1, "min_rounds": 2, "max_rounds": 4})
	_dirty = true
	_refresh_env_weather_rows()
	_update_file_label()

func _on_env_del_weather(i: int) -> void:
	var table := _env_weather_table()
	if i < 0 or i >= table.size():
		return
	_push_undo(_snapshot(), "删天气")
	table.remove_at(i)
	_dirty = true
	_refresh_env_weather_rows()
	_update_file_label()

func _on_env_weather_id(sel: int, i: int, opt: OptionButton) -> void:
	var table := _env_weather_table()
	if i < 0 or i >= table.size() or typeof(table[i]) != TYPE_DICTIONARY:
		return
	_push_undo(_snapshot(), "改天气")
	table[i]["weather"] = str(opt.get_item_metadata(sel))
	_dirty = true
	_update_file_label()

func _on_env_weather_num(val: float, i: int, key: String) -> void:
	var table := _env_weather_table()
	if i < 0 or i >= table.size() or typeof(table[i]) != TYPE_DICTIONARY:
		return
	if int(table[i].get(key, -999999)) == int(val):
		return
	_push_undo(_snapshot(), "天气·" + key)
	table[i][key] = int(val)
	_dirty = true
	_update_file_label()

# ------------------------------------------------------------------ 地图库

# 扫描当前文件夹下的 *.json，填进侧栏列表（并高亮当前文件）
func _scan_maps() -> void:
	if _map_list == null:
		return
	_map_list.clear()
	_map_paths.clear()
	var dir := DirAccess.open(_map_dir)
	if dir == null:
		_dir_label.text = "文件夹：%s（打不开）" % _map_dir
		return
	_dir_label.text = "文件夹：%s" % _map_dir
	var names := []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.to_lower().ends_with(".json"):
			names.append(fname)
		fname = dir.get_next()
	dir.list_dir_end()
	names.sort()
	for n in names:
		_map_paths.append(_join(_map_dir, n))
		_map_list.add_item(n)
	_refresh_map_highlight()

func _join(d: String, f: String) -> String:
	return f if d == "" else (d + f if d.ends_with("/") else d + "/" + f)

# 在列表里选中“当前文件”那一行（按文件名匹配，列表只来自单个文件夹）
func _refresh_map_highlight() -> void:
	if _map_list == null:
		return
	_map_list.deselect_all()
	if current_path == "":
		return
	var cur := current_path.get_file()
	for i in _map_paths.size():
		if _map_paths[i].get_file() == cur:
			_map_list.select(i)   # 静默：select() 不触发 item_selected
			_map_list.ensure_current_is_visible()
			return

# 单击列表项 = 切换到该地图（有未存改动先确认）
func _on_map_selected(idx: int) -> void:
	if idx < 0 or idx >= _map_paths.size():
		return
	var path: String = _map_paths[idx]
	if path == current_path or path.get_file() == current_path.get_file():
		return   # 点的就是当前图，不重复加载
	_confirm_discard(func(): load_from_file(path))

func _on_pick_dir() -> void:
	_dir_dlg.current_dir = ProjectSettings.globalize_path(_map_dir)
	_dir_dlg.popup_centered(Vector2i(900, 600))

func _set_map_dir(path: String) -> void:
	_map_dir = path
	_save_config()
	_scan_maps()
	set_status("地图文件夹：%s" % path)

# 新建地图到当前文件夹：先确认丢弃未存改动，再弹文件名输入
func _on_new_map_in_dir() -> void:
	_confirm_discard(func():
		_newmap_name.text = "new_map.json"
		_newmap_dlg.popup_centered())

func _create_map() -> void:
	var nm := _newmap_name.text.strip_edges()
	if nm == "":
		nm = "new_map"
	if not nm.to_lower().ends_with(".json"):
		nm += ".json"
	new_map(int(width_spin.value), int(height_spin.value))
	save_to_file(_join(_map_dir, nm))   # 立刻落盘到文件夹（save_to_file 会重扫列表）

# ------------------------------------------------------------------ 配置（记住文件夹）

func _load_config() -> void:
	if not FileAccess.file_exists(CONFIG_PATH):
		return
	var f := FileAccess.open(CONFIG_PATH, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(data) == TYPE_DICTIONARY and typeof(data.get("map_dir")) == TYPE_STRING and data["map_dir"] != "":
		_map_dir = data["map_dir"]

func _save_config() -> void:
	var f := FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"map_dir": _map_dir}, "  "))
	f.close()

func _make_label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l

func _make_brush_button(entry: Dictionary, group: ButtonGroup) -> Button:
	var b := Button.new()
	b.text = entry.label
	b.toggle_mode = true
	b.button_group = group
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, 34)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.tooltip_text = "%s（terrain=%s, variant=%s）\ntags: %s" % [
		entry.label, entry.terrain, entry.variant, ", ".join(entry.tags)]

	var swatch := Color.html(entry.color)
	var sb := StyleBoxFlat.new()
	sb.bg_color = swatch
	sb.set_content_margin_all(6)
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", sb)
	var sb_pressed := sb.duplicate()
	sb_pressed.border_color = Color.WHITE
	sb_pressed.set_border_width_all(3)
	b.add_theme_stylebox_override("pressed", sb_pressed)

	var lum := 0.299 * swatch.r + 0.587 * swatch.g + 0.114 * swatch.b
	var fg := Color.BLACK if lum > 0.6 else Color.WHITE
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(c, fg)
	return b

func _make_file_dialog(mode: int) -> FileDialog:
	var dlg := FileDialog.new()
	dlg.file_mode = mode
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	dlg.use_native_dialog = true
	dlg.add_filter("*.json", "地图 JSON")
	return dlg

# ------------------------------------------------------------------ 事件

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.ctrl_pressed:
		match event.keycode:
			KEY_Z:
				if event.shift_pressed:
					redo()
				else:
					undo()
				get_viewport().set_input_as_handled()
			KEY_Y:
				redo()
				get_viewport().set_input_as_handled()
			KEY_S:
				_save_shortcut()
				get_viewport().set_input_as_handled()
		return
	# 数字键 1~9 快速选笔刷（仅地形层；焦点在输入框时该键被其消费、不会落到这里）
	if current_layer == "terrain" and event.keycode >= KEY_1 and event.keycode <= KEY_9:
		var idx: int = event.keycode - KEY_1
		if idx < brush_buttons.size():
			brush_buttons[idx].button_pressed = true  # 触发 toggled -> select_brush
			get_viewport().set_input_as_handled()

# 有未保存改动时先确认再执行 action（新建/加载共用）
func _confirm_discard(action: Callable) -> void:
	if not _dirty:
		action.call()
		return
	_pending = action
	_confirm_dlg.popup_centered()

func _on_new_pressed() -> void:
	var w := int(width_spin.value)
	var h := int(height_spin.value)
	_confirm_discard(func(): new_map(w, h))

func _on_preset_selected(idx: int) -> void:
	# 选预设只填入宽/高输入框，真正生成等用户点“新建”，避免误触清空当前地图
	if idx <= 0:
		return
	var p = SIZE_PRESETS[idx]
	width_spin.value = p.w
	height_spin.value = p.h
	set_status("已选预设 %s，点“新建”生成" % p.label)

func _on_brush_toggled(pressed: bool, idx: int) -> void:
	if pressed:
		select_brush(idx)

func _save_shortcut() -> void:
	# 有文件就覆盖，没有就走“另存为”弹窗
	if current_path == "":
		_on_save_as_pressed()
	else:
		save_to_file(current_path)

func _on_save_as_pressed() -> void:
	if current_path != "":
		_save_dlg.current_file = current_path.get_file()
	_save_dlg.current_dir = ProjectSettings.globalize_path(_map_dir)  # 默认存到地图文件夹
	_save_dlg.popup_centered(Vector2i(900, 600))

func _on_load_pressed() -> void:
	_confirm_discard(func(): _load_dlg.popup_centered(Vector2i(900, 600)))

func _on_back_to_menu() -> void:
	# 返回主菜单（有未保存改动先确认）
	_confirm_discard(func(): get_tree().change_scene_to_file("res://StartMenu.tscn"))

func _on_reset_view() -> void:
	if canvas:
		canvas.fit_to_view()
	set_status("已适配窗口")

func select_brush(i: int) -> void:
	brush_index = i
	set_status("画笔：" + PALETTE[i].label)
	_refresh_terrain_data()   # 同步「地形数据」编辑区到选中笔刷

func pick_brush_at(col: int, row: int) -> void:
	var tile = tiles[row][col]
	for i in PALETTE.size():
		var e = PALETTE[i]
		if e.terrain == tile.get("terrain") and e.variant == tile.get("variant"):
			if i < brush_buttons.size():
				brush_buttons[i].button_pressed = true  # 触发 toggled -> select_brush
			set_status("取色：" + e.label)
			return
	set_status("该地块不在当前笔刷列表中")

# ------------------------------------------------------------------ 图层分派 + 区域

# 画布左键 → 按当前层：地形=画地形 / 区域=把格加入当前区域
func primary_paint(col: int, row: int) -> void:
	if current_layer == "region":
		_region_paint(col, row, true)
	elif current_layer == "unit":
		_unit_paint(col, row)
	else:
		paint_cell(col, row)

# 单位层左键：一次拖动在第一格决定并锁定动作——点到已有单位=编辑它；点空格=落子（拖动续落）
func _unit_paint(col: int, row: int) -> void:
	if _unit_stroke_action == "":
		var idx := _unit_index_at(col, row)
		_unit_stroke_action = "edit" if idx >= 0 else "place"
		if _unit_stroke_action == "edit":
			_edit_placed_unit(idx)
			return
	if _unit_stroke_action == "edit":
		return
	_place_unit(col, row)

# 画布右键 → 按当前层：地形=取色 / 区域=从当前区域移除格 / 单位=删除该格单位
func secondary_paint(col: int, row: int) -> void:
	if current_layer == "region":
		_region_paint(col, row, false)
	elif current_layer == "unit":
		_remove_unit(col, row)
	else:
		pick_brush_at(col, row)

# 当前选中的区域（无则返回空字典；调用方用 .is_empty() 判断"没有"）
func active_region() -> Dictionary:
	if _active_region_idx >= 0 and _active_region_idx < regions.size():
		return regions[_active_region_idx] as Dictionary
	return {}

# 给当前区域加/删一格（走 stroke：一段拖动算一次撤销）
func _region_paint(col: int, row: int, add: bool) -> void:
	var reg := active_region()
	if reg.is_empty():
		set_status("先在左侧「＋ 新建区域」或选一个区域")
		return
	var key := Vector2i(col, row)
	var has: bool = reg["cells"].has(key)
	if add and not has:
		reg["cells"][key] = true
	elif (not add) and has:
		reg["cells"].erase(key)
	else:
		return   # 无变化
	_stroke_dirty = true
	_stroke_count += 1
	_dirty = true
	if canvas:
		canvas.queue_redraw()

func _on_region_selected(idx: int) -> void:
	_active_region_idx = idx
	if _region_color_btn and idx >= 0 and idx < regions.size():
		_region_color_btn.color = Color.html(str(regions[idx].get("color", "#FFFFFF")))
	_sync_region_kind_opt()
	if canvas:
		canvas.queue_redraw()

# 把「类型」下拉同步到当前区域的 kind（select() 不触发 item_selected，无回环）
func _sync_region_kind_opt() -> void:
	if _region_kind_opt == null:
		return
	var reg := active_region()
	var k := str(reg.get("kind", "aggro")) if not reg.is_empty() else "aggro"
	for i in REGION_KINDS.size():
		if REGION_KINDS[i][0] == k:
			_region_kind_opt.select(i)
			return
	_region_kind_opt.select(0)

func _on_region_kind_changed(idx: int) -> void:
	var reg := active_region()
	if reg.is_empty() or idx < 0 or idx >= REGION_KINDS.size():
		return
	var k := str(REGION_KINDS[idx][0])
	if str(reg.get("kind", "aggro")) == k:
		return
	_push_undo(_snapshot(), "区域类型")
	reg["kind"] = k
	_dirty = true
	_refresh_region_list()
	_update_file_label()
	if canvas:
		canvas.queue_redraw()

func _on_add_region() -> void:
	_push_undo(_snapshot(), "新建区域")
	regions.append({
		"id": _unique_region_id(),
		"label": "区域%d" % (regions.size() + 1),
		"color": REGION_COLORS[regions.size() % REGION_COLORS.size()],
		"kind": "aggro",   # 默认触发区；可在「类型」下拉改成部署区
		"cells": {},
	})
	_active_region_idx = regions.size() - 1
	_dirty = true
	_refresh_region_list()
	_update_file_label()
	if canvas:
		canvas.queue_redraw()

func _on_rename_region() -> void:
	var reg := active_region()
	if reg.is_empty():
		return
	_region_rename_edit.text = str(reg.get("label", ""))
	_region_rename_dlg.popup_centered()

func _apply_region_rename() -> void:
	var reg := active_region()
	if reg.is_empty():
		return
	var nm := _region_rename_edit.text.strip_edges()
	if nm == "":
		return
	_push_undo(_snapshot(), "区域改名")
	reg["label"] = nm
	_dirty = true
	_refresh_region_list()
	_update_file_label()

func _on_delete_region() -> void:
	if active_region().is_empty():
		return
	_push_undo(_snapshot(), "删除区域")
	regions.remove_at(_active_region_idx)
	_active_region_idx = mini(_active_region_idx, regions.size() - 1)
	_dirty = true
	_refresh_region_list()
	_update_file_label()
	if canvas:
		canvas.queue_redraw()

# 颜色实时改（ColorPicker 拖动会高频触发 → 不入撤销栈、避免刷屏；只标脏）
func _on_region_color_changed(c: Color) -> void:
	var reg := active_region()
	if reg.is_empty():
		return
	reg["color"] = "#" + c.to_html(false)
	_dirty = true
	if canvas:
		canvas.queue_redraw()

func _refresh_region_list() -> void:
	if _region_list == null:
		return
	_region_list.clear()
	for i in regions.size():
		var reg = regions[i]
		var n: int = (reg["cells"] as Dictionary).size()
		var mark := "［部署］" if str(reg.get("kind", "aggro")) == "deploy" else ""
		_region_list.add_item("%s%s (%d)" % [mark, str(reg.get("label", "区域")), n])
		_region_list.set_item_custom_fg_color(i, Color.html(str(reg.get("color", "#FFFFFF"))))
	if _active_region_idx >= 0 and _active_region_idx < regions.size():
		_region_list.select(_active_region_idx)
		if _region_color_btn:
			_region_color_btn.color = Color.html(str(regions[_active_region_idx].get("color", "#FFFFFF")))
	_sync_region_kind_opt()

# 不与现有区域 id 冲突的 region_N
func _unique_region_id() -> String:
	var i := 1
	while true:
		var cand := "region_%d" % i
		var used := false
		for r in regions:
			if str(r.get("id", "")) == cand:
				used = true
				break
		if not used:
			return cand
		i += 1
	return "region_x"

# 某格所属区域名（悬停信息用）
func _regions_at(col: int, row: int) -> String:
	var key := Vector2i(col, row)
	var names := []
	for r in regions:
		if (r["cells"] as Dictionary).has(key):
			names.append(str(r.get("label", "区域")))
	return ", ".join(names)

# ------------------------------------------------------------------ 数据

func new_map(w: int, h: int) -> void:
	_close_unit_edit()   # 换图前关掉深编面板（下标失效）
	var nw := clampi(w, 1, MAX_W)
	var nh := clampi(h, 1, MAX_H)
	if not tiles.is_empty():
		_push_undo(_snapshot(), "新建 %d×%d" % [nw, nh])
	width = nw
	height = nh
	tiles = []
	for row in height:
		var line := []
		for col in width:
			line.append({"terrain": DEFAULT_TERRAIN, "variant": DEFAULT_VARIANT})
		tiles.append(line)
	regions = []                 # 新图：清空区域层
	map_units = []               # 新图：清空预置单位层
	map_triggers = []            # 新图：清空触发器层
	map_terrain_overrides = {}   # 新图：清空图级地形覆盖
	map_environment = {}         # 新图：清空环境
	_active_region_idx = -1
	current_path = ""
	_dirty = false
	if width_spin: width_spin.value = width
	if height_spin: height_spin.value = height
	if canvas: canvas.request_fit()
	_refresh_canvas()
	_refresh_region_list()
	_refresh_env_panel()
	_update_file_label()
	_refresh_map_highlight()
	set_status("新建地图 %d×%d" % [width, height])

func paint_cell(col: int, row: int) -> void:
	var b = PALETTE[brush_index]
	var tile = tiles[row][col]
	if tile.get("terrain") == b.terrain and tile.get("variant") == b.variant:
		return
	tiles[row][col] = {"terrain": b.terrain, "variant": b.variant}
	_stroke_dirty = true
	_stroke_count += 1
	_dirty = true
	if canvas:
		canvas.queue_redraw()

# 画布查表（未知地形 -> 品红，便于发现数据异常）；统一走 TerrainDB 的 O(1) 查表
func color_for_tile(tile) -> Color:
	return TerrainDB.color_of(tile)

func decor_for_tile(tile) -> String:
	return TerrainDB.decor_of(tile)

func accent_for_tile(tile) -> Color:
	return TerrainDB.accent_of(tile)

# 左下角悬停信息：坐标 + 地块标签/类型/外观/tags
func hover_text(col: int, row: int) -> String:
	if row < 0 or row >= tiles.size() or col < 0 or col >= tiles[row].size():
		return ""
	var t = tiles[row][col]
	var e = TerrainDB.entry_for(t)
	var label := str(e.label) if e != null else "未知"
	var tags := ", ".join(e.tags) if e != null else ""
	var base := "(%d, %d)  %s  %s/%s\ntags: %s" % [col, row, label, t.get("terrain"), t.get("variant"), tags]
	var rtxt := _regions_at(col, row)
	if rtxt != "":
		base += "\n区域: " + rtxt
	return base

func _refresh_canvas() -> void:
	if canvas:
		canvas.queue_redraw()

func set_status(s: String) -> void:
	if status_label:
		status_label.text = s

func _update_file_label() -> void:
	if _file_label == null:
		return
	var name := "(未保存)" if current_path == "" else current_path.get_file()
	_file_label.text = "文件：%s%s" % [name, "  *" if _dirty else ""]

# ------------------------------------------------------------------ 撤销 / 重做

func _snapshot() -> Dictionary:
	return {"width": width, "height": height, "tiles": _copy_tiles(tiles), "regions": _copy_regions(regions), "map_units": _copy_map_units(map_units), "map_triggers": _copy_map_triggers(map_triggers), "map_terrain_overrides": map_terrain_overrides.duplicate(true), "map_environment": map_environment.duplicate(true)}

# 深拷贝单位层（含 proto 嵌套字典）——撤销快照要把单位层一起拷，否则落子/删单位无法撤销
func _copy_map_units(src: Array) -> Array:
	var out := []
	for e in src:
		if typeof(e) == TYPE_DICTIONARY:
			out.append({"proto": (e.get("proto", {}) as Dictionary).duplicate(true), "col": int(e.get("col", 0)), "row": int(e.get("row", 0)), "faction": str(e.get("faction", "enemy"))})
	return out

# 深拷贝触发器层（含 when/do 嵌套）——撤销快照一起拷，否则建/删触发器与动作无法撤销
func _copy_map_triggers(src: Array) -> Array:
	var out := []
	for t in src:
		if typeof(t) == TYPE_DICTIONARY:
			out.append(t.duplicate(true))
	return out

func _copy_tiles(src: Array) -> Array:
	var out := []
	for row in src:
		var line := []
		for cell in row:
			line.append({"terrain": cell.terrain, "variant": cell.variant})
		out.append(line)
	return out

# 深拷贝区域（含 cells 集合）——撤销快照必须把区域层一起拷，否则画区域无法撤销
# 区域四标量键(id/label/color/kind)统一构造——加字段只改这里；cells 形态各异由调用方补。
# id/label 文本默认按来源不同(内部空串 / 外部 JSON 回退"region"/"区域")作参数传入。
func _region_scalars(r, def_id: String, def_label: String) -> Dictionary:
	return {"id": str(r.get("id", def_id)), "label": str(r.get("label", def_label)), "color": str(r.get("color", "#FFFFFF")), "kind": str(r.get("kind", "aggro"))}

func _copy_regions(src: Array) -> Array:
	var out := []
	for r in src:
		var cells := {}
		for k in r["cells"]:
			cells[k] = true
		var m := _region_scalars(r, "", "")
		m["cells"] = cells
		out.append(m)
	return out

func _push_undo(snap: Dictionary, label: String) -> void:
	_undo_stack.append({"snap": snap, "label": label})
	while _undo_stack.size() > MAX_UNDO:
		_undo_stack.pop_front()
	_redo_stack.clear()  # 任何新操作清空重做栈
	_refresh_history()

func _apply_snapshot(snap: Dictionary) -> void:
	_close_unit_edit()   # map_units 整体替换 → 下标失效，先关掉深编面板
	width = snap.width
	height = snap.height
	tiles = snap.tiles
	regions = snap.get("regions", [])
	map_units = snap.get("map_units", [])
	map_triggers = snap.get("map_triggers", map_triggers)
	map_terrain_overrides = snap.get("map_terrain_overrides", {})
	map_environment = snap.get("map_environment", {})
	_active_region_idx = clampi(_active_region_idx, -1, regions.size() - 1)
	_active_trigger_idx = clampi(_active_trigger_idx, -1, map_triggers.size() - 1)
	if width_spin: width_spin.value = width
	if height_spin: height_spin.value = height
	_refresh_canvas()
	_refresh_region_list()
	_refresh_env_panel()      # 撤销/重做后同步环境面板
	_refresh_terrain_data()   # 覆盖变了 → 刷新地形数据编辑区（若在本图范围）
	if _trigger_panel != null and _trigger_panel.visible:
		_refresh_trigger_list()
		_load_trigger_form()

func begin_stroke() -> void:
	_stroke_snapshot = _snapshot()
	_stroke_dirty = false
	_stroke_count = 0
	_unit_stroke_action = ""   # 单位层：新一次拖动重置动作锁（第一格再定 编辑/落子）

func end_stroke() -> void:
	if _stroke_dirty and _stroke_snapshot != null:
		var lbl := ""
		match current_layer:
			"region": lbl = "区域编辑"
			"unit": lbl = "单位编辑"
			_: lbl = "绘制 %s ×%d" % [PALETTE[brush_index].label, _stroke_count]
		_push_undo(_stroke_snapshot, lbl)
		_update_file_label()
	_stroke_snapshot = null
	_stroke_dirty = false
	_stroke_count = 0

func undo() -> void:
	if _undo_stack.is_empty():
		set_status("无可撤销")
		return
	var entry = _undo_stack.pop_back()
	_redo_stack.append({"snap": _snapshot(), "label": entry.label})
	_apply_snapshot(entry.snap)
	_dirty = true
	_refresh_history()
	_update_file_label()
	set_status("已撤销：" + entry.label)

func redo() -> void:
	if _redo_stack.is_empty():
		set_status("无可重做")
		return
	var entry = _redo_stack.pop_back()
	_undo_stack.append({"snap": _snapshot(), "label": entry.label})
	_apply_snapshot(entry.snap)
	_dirty = true
	_refresh_history()
	_update_file_label()
	set_status("已重做：" + entry.label)

func _refresh_history() -> void:
	if _history_list == null:
		return
	_history_list.clear()
	var n := _undo_stack.size()
	if n == 0:
		_history_list.add_item("（暂无操作）")
		return
	var shown := 0
	var i := n - 1
	while i >= 0 and shown < HISTORY_SHOWN:
		var from_top := n - i  # 1 = 最新（下一个被撤销）
		var prefix := "↩ " if from_top == 1 else "    "
		_history_list.add_item("%s%d. %s" % [prefix, from_top, _undo_stack[i].label])
		shown += 1
		i -= 1

# ------------------------------------------------------------------ 存档 / 读档

func to_json_dict() -> Dictionary:
	return MapIO.to_dict(width, height, tiles, _regions_to_json(), map_units, map_triggers, map_terrain_overrides, map_environment)

# 区域 → JSON：cells 集合转 [[x,y],…]（确定性排序，利于 diff）
func _regions_to_json() -> Array:
	var out := []
	for r in regions:
		var keys: Array = (r["cells"] as Dictionary).keys()
		keys.sort_custom(func(a, b): return a.y < b.y or (a.y == b.y and a.x < b.x))
		var cells := []
		for k in keys:
			cells.append([k.x, k.y])
		var m := _region_scalars(r, "", "")
		m["cells"] = cells
		out.append(m)
	return out

# JSON → 区域（过滤越界格；非数组/坏项跳过）
func _regions_from_json(raw, mw: int, mh: int) -> Array:
	var out := []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for r in raw:
		if typeof(r) != TYPE_DICTIONARY:
			continue
		var cells := {}
		var rc = r.get("cells", [])
		if typeof(rc) == TYPE_ARRAY:
			for pair in rc:
				if typeof(pair) == TYPE_ARRAY and pair.size() >= 2:
					var x := int(pair[0])
					var y := int(pair[1])
					if x >= 0 and x < mw and y >= 0 and y < mh:
						cells[Vector2i(x, y)] = true
		var m := _region_scalars(r, "region", "区域")
		m["cells"] = cells
		out.append(m)
	return out

func save_to_file(path: String) -> void:
	if not MapIO.write_map(path, width, height, tiles, _regions_to_json(), map_units, map_triggers, map_terrain_overrides, map_environment):
		set_status("保存失败：无法写入文件")
		return
	current_path = path
	_dirty = false
	_update_file_label()
	_scan_maps()   # 新文件可能落进当前文件夹 → 刷新列表并高亮
	set_status("已保存：" + path)

func load_from_file(path: String) -> void:
	_close_unit_edit()   # 换图前关掉深编面板（下标失效）
	var res := MapIO.read_file(path)
	if not res.get("ok", false):
		if not FileAccess.file_exists(path):
			set_status("加载失败：文件不存在")
		else:
			set_status("加载失败：JSON 解析错误或缺少 width/height/tiles 字段")
		return
	var nw := int(res["width"])
	var nh := int(res["height"])
	var new_tiles: Array = res["tiles"]
	# regions 仍由编辑器自己转成内存形（Vector2i 集合）；MapIO 透传的是 [[x,y]] 形（_regions_from_json 兼容）
	var new_regions := _regions_from_json(res["regions"], nw, nh)
	if not tiles.is_empty():
		_push_undo(_snapshot(), "加载 %s" % path.get_file())
	width = nw
	height = nh
	tiles = new_tiles
	regions = new_regions
	map_units = res["units"]   # 预置单位（单位层可编辑）
	map_triggers = res["triggers"]   # 触发器（触发器层可编辑）
	map_terrain_overrides = res.get("terrain_overrides", {})   # 图级地形覆盖（地形数据「本图」范围）
	map_environment = res.get("environment", {})   # 环境（日夜/天气）
	_active_region_idx = -1 if regions.is_empty() else 0
	current_path = path
	_dirty = false
	if width_spin: width_spin.value = width
	if height_spin: height_spin.value = height
	if canvas: canvas.request_fit()
	_refresh_canvas()
	_refresh_region_list()
	_refresh_env_panel()      # 载入后同步环境面板
	_update_file_label()
	_refresh_map_highlight()
	set_status("已加载：%s (%d×%d)" % [path, width, height])
