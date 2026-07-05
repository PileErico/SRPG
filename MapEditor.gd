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
const EventEngine := preload("res://EventEngine.gd")   # 动作元数据注册表单一源：触发器动作菜单/缺省值/表单全据此生成
const HexGrid := preload("res://HexGrid.gd")   # 纯六边形几何（边键归一/相邻判定/连线——线特征层用）
const LocationDB := preload("res://LocationDB.gd")   # 地点类型注册表（地点层类型列表/校验数据源）
const TerrainSwatch := preload("res://TerrainSwatch.gd")   # 地块缩略图控件（笔刷显示完整六边形；与地图格同一份渲染）
const EditorTheme := preload("res://EditorTheme.gd")   # 编辑器统一深色主题（与物品编辑器共用）
const EditorUI := preload("res://EditorUI.gd")   # 编辑器公共 UI 控件工厂（分节/折叠/菜单/面板/确认框，与物品编辑器共用）

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

# scope 过滤开关：false＝笔刷全通用(不分大/小地图)。机制(scope 字段 + in_scope)保留，将来置 true 恢复。
const SCOPE_FILTER_ON := false

# —— 笔刷分类管理（分组折叠 + ⋯ 菜单：新建/改名/删分类、笔刷改名/删除/移动）——
var _brush_list_box: VBoxContainer      # 笔刷分组列表容器（重建时清空重填）
var _brush_group: ButtonGroup           # 笔刷互斥组（重建复用）
var _cat_collapsed := {}                # 分类名 -> 是否折叠（跨重建保留）
var _prompt_dlg: ConfirmationDialog     # 通用文本输入弹窗（新建/改名分类、笔刷改名共用）
var _prompt_edit: LineEdit
var _prompt_lbl: Label
var _prompt_cb := Callable()
var _erase_object := false          # 橡皮·放置物：开则左键清除该格放置物

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
var map_type := "battle"    # 地图类型（battle/overworld）：顶栏可切换；决定笔刷 scope 过滤与 线/地点 层是否可用
var map_locations := []     # 地点实例（地图 locations 字段，大地图 M7）：地点层可编辑（放置/表单/删）；存盘写回、含撤销
var map_rivers := []        # 线特征·河（[{id,label,pairs:[[[x,y],[x,y]],…]}]）：线特征层河刷；存盘写回、含撤销
var map_roads := []         # 线特征·路（同河形；格对＝格心连线段）：线特征层路刷
var map_bridges := []       # 线特征·桥（[格对,…]；须架在河边上）：线特征层桥刷
var brush_index := 0
var embedded := false      # 嵌入 Game 统一宿主时为 true：隐藏自己的「主菜单」按钮（由 Game 顶栏统一提供）

# —— 图层（地形底层 + 叠加层）。六层：terrain / line / region / unit / trigger / location ——
# 区域层：给一片格子命名（"前厅"/"守军房"），喂战斗侧 AI 的 ai_region 仇恨触发。
# 内存形：regions[i] = {id, label, color, kind, cells:{Vector2i:true}}；存盘转 cells:[[x,y],…]（见 _regions_to_json）。
# kind=区域类型：aggro=AI 仇恨/触发区（敌人 ai_region 引用）；deploy=玩家部署区（战斗只许玩家放区内）。缺省 aggro。
# 线特征层（line）/ 地点层（location）＝大地图专属（map_type=overworld 才显示按钮；数据对战斗图仍透传保真）。
var current_layer := "terrain"      # "terrain" | "line" | "region" | "unit" | "trigger" | "location"
var regions := []
var _active_region_idx := -1
# 区域配色循环池（新建区域时按序取）
const REGION_COLORS := ["#D5453A", "#EBBC04", "#4FAE5A", "#3A7BD5", "#9B59B6", "#E0822A", "#2AB0B0", "#C84BD5"]
# 区域类型：[id, 中文]（写进地图 regions[].kind，战斗侧据此分派）
const REGION_KINDS := [["aggro", "触发区"], ["deploy", "部署区"]]

# —— 单位层：在编辑器里摆「这一关的单位」（authoring 关卡内容，存进地图 units 字段）——
# 与沙盒「自由测试」不同：这里摆的是关卡固定内容（敌人/预置友军/中立），随地图持久化。
const UNIT_FACTIONS := ["enemy", "player", "ally", "neutral"]   # 顺序=下拉顺序；中文走 TagDB.cn、颜色走 TagDB.color
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

# —— 线特征层（大地图专属）：河=边刷 / 路=格心连线刷 / 桥=河边豁免点 ——
# 存储即 schema 形（map_rivers/map_roads=[{id,label,pairs}]、map_bridges=[格对]）；边键归一走 HexGrid.edge_key。
const LINE_MODES := [["river", "河流（沿边画）"], ["road", "道路（沿格拖）"], ["bridge", "桥（点河边）"]]
var _line_mode := "river"
var _line_panel: Control
var _road_last_cell := Vector2i(-1, -1)   # 路刷：一次拖动中上一格（连线成对）

# —— 地点层（大地图专属）：放置/编辑地图 locations 实例（类型定义在 data/locations.json）——
var _loc_panel: Control
var _loc_type_list: ItemList        # 放置用类型列表（LocationDB.all_types）
var _loc_types := []                # 与类型列表行对应的类型定义
var _loc_type_idx := 0              # 当前选中的放置类型
var _loc_list: ItemList             # 已放置地点列表
var _active_loc_idx := -1           # 选中的已放置地点（表单编辑对象）
var _loc_id_edit: LineEdit
var _loc_label_edit: LineEdit
var _loc_type_opt: OptionButton     # 选中地点的类型下拉
var _loc_battle_edit: LineEdit
var _loc_dialogue_edit: LineEdit
var _loc_loading := false           # 填表单时抑制回写
var _loc_stroke_placed := false     # place 模式下一次拖动只放一个地点（防拖动连放）
var _loc_stroke_action := ""        # 一次拖动的动作锁（""未定 / "select" 首格命中地点 / "place" 首格空）——仿单位层，防「点选地点后拖出误放」

# —— 触发器层：authoring 关卡事件（when 条件 → do 动作），存进地图 triggers 字段 ——
const TRIG_FACTIONS := [["player", "玩家"], ["any", "任意"]]
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
var _map_type_btn: Button   # 顶栏地图类型切换按钮（点击 战斗图⇄大地图 来回切）——决定笔刷 scope 过滤与 线/地点 层门禁
var _layer_btns := {}             # layer_id → 图层按钮（线/地点按 map_type 显隐）
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

# —— 地图库（文件夹 + 其中的地图列表）——
var _map_dir := DEFAULT_MAP_DIR
var _map_list: ItemList                # 侧栏：当前文件夹内的地图文件
var _map_paths := []                   # 与 _map_list 行一一对应的完整路径
var _dir_label: Label                  # 显示当前文件夹
var _dir_dlg: FileDialog               # 选文件夹对话框
var _newmap_dlg: ConfirmationDialog    # 「新建地图」弹窗（输入文件名，存到文件夹）
var _newmap_name: LineEdit             # 新建地图的文件名输入框
var _newsize_dlg: ConfirmationDialog   # 「新建地图」弹窗（宽/高/预设，文件菜单调；内存新建不落盘）

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
	theme = EditorTheme.build()   # 统一深色控件观感（公共层 EditorTheme，一处改全局）

	add_child(EditorUI.background())   # 深色背景（铺满垫底，去引擎默认灰）——公共层

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	# ---- 顶部工具栏 ----
	var bar := HBoxContainer.new()
	var bar_wrap := EditorUI.panelize(bar)   # 顶栏也给个深底，与画布分开
	root.add_child(bar_wrap)

	# 菜单栏（绘图软件式下拉，替代平铺按钮）：文件 / 编辑 / 视图。仅「类型」+ 状态常驻；返回主菜单＝右上角常驻（高频，不藏子菜单）。
	# 文件菜单：新建地图…(0) / 保存(1) / 另存为…(2) / 加载…(3)
	var file_menu := EditorUI.make_menu("文件")
	var fp := file_menu.get_popup()
	fp.add_item("新建地图…", 0)
	fp.add_separator()
	fp.add_item("保存  (Ctrl+S)", 1)
	fp.add_item("另存为…", 2)
	fp.add_item("加载…", 3)
	fp.id_pressed.connect(_on_file_menu)
	bar.add_child(file_menu)

	var edit_menu := EditorUI.make_menu("编辑")
	var ep := edit_menu.get_popup()
	ep.add_item("撤销  (Ctrl+Z)", 0)
	ep.add_item("重做  (Ctrl+Y)", 1)
	ep.id_pressed.connect(func(id: int): if id == 0: undo() else: redo())
	bar.add_child(edit_menu)

	var view_menu := EditorUI.make_menu("视图")
	var vp := view_menu.get_popup()
	vp.add_item("适配窗口", 0)
	vp.id_pressed.connect(func(_id: int): _on_reset_view())
	bar.add_child(view_menu)

	bar.add_child(VSeparator.new())

	# 地图类型（battle/overworld）＝一个按钮来回切（不用下拉）：显示当前类型，点击换到另一种。
	bar.add_child(_make_label("类型"))
	_map_type_btn = Button.new()
	_map_type_btn.custom_minimum_size = Vector2(76, 0)
	_map_type_btn.tooltip_text = "点击在 战斗图 ⇄ 大地图 间切换。\n影响：地形笔刷按 scope 过滤；线特征（河/路/桥）与地点层仅大地图可编。"
	_map_type_btn.pressed.connect(_on_map_type_toggle)
	bar.add_child(_map_type_btn)

	bar.add_child(VSeparator.new())
	status_label = Label.new()
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(status_label)

	# 返回主菜单＝右上角常驻（高频操作，不藏子菜单；跨编辑器统一习惯）。嵌入 Game 时由 Game 顶栏提供，省略。
	if not embedded:
		var back_btn := Button.new()
		back_btn.text = "← 主菜单"
		back_btn.pressed.connect(_on_back_to_menu)
		bar.add_child(back_btn)

	# ---- 主体：左笔刷栏 + 中画布 + 右历史栏 ----
	var main := HBoxContainer.new()
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(main)

	main.add_child(EditorUI.panelize(_build_brush_sidebar()))

	canvas = EditorCanvas.new()
	canvas.editor = self
	canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_child(canvas)

	main.add_child(EditorUI.panelize(_build_side_panel()))

	# ---- 文件对话框（建一次复用）----
	_save_dlg = EditorUI.make_file_dialog(FileDialog.FILE_MODE_SAVE_FILE, FileDialog.ACCESS_FILESYSTEM, [["*.json", "地图 JSON"]], true)
	_save_dlg.current_file = "map.json"
	_save_dlg.file_selected.connect(save_to_file)
	add_child(_save_dlg)

	_load_dlg = EditorUI.make_file_dialog(FileDialog.FILE_MODE_OPEN_FILE, FileDialog.ACCESS_FILESYSTEM, [["*.json", "地图 JSON"]], true)
	_load_dlg.file_selected.connect(load_from_file)
	add_child(_load_dlg)

	# 选文件夹对话框（地图库默认路径）
	_dir_dlg = FileDialog.new()
	_dir_dlg.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_dir_dlg.access = FileDialog.ACCESS_FILESYSTEM
	_dir_dlg.use_native_dialog = true
	_dir_dlg.dir_selected.connect(_set_map_dir)
	add_child(_dir_dlg)

	# 未保存改动确认 → 公共层 EditorUI.confirm_discard（见 _confirm_discard）；不再持久化对话框节点

	# 新建地图弹窗（输入文件名，尺寸取 width_spin/height_spin＝新尺寸弹窗里的值）
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

	# 新尺寸弹窗（文件菜单「新建地图…」调）：宽/高/预设从顶栏迁进来——width_spin/height_spin 在此创建
	_newsize_dlg = ConfirmationDialog.new()
	_newsize_dlg.title = "新建地图"
	_newsize_dlg.ok_button_text = "创建"
	_newsize_dlg.get_cancel_button().text = "取消"
	var ns_box := VBoxContainer.new()
	var ns_row := HBoxContainer.new()
	ns_row.add_child(_make_label("宽"))
	width_spin = SpinBox.new()
	width_spin.min_value = 1
	width_spin.max_value = MAX_W
	width_spin.value = width
	ns_row.add_child(width_spin)
	ns_row.add_child(_make_label("  高"))
	height_spin = SpinBox.new()
	height_spin.min_value = 1
	height_spin.max_value = MAX_H
	height_spin.value = height
	ns_row.add_child(height_spin)
	ns_box.add_child(ns_row)
	var ns_prow := HBoxContainer.new()
	ns_prow.add_child(_make_label("预设"))
	var preset_option := OptionButton.new()
	for p in SIZE_PRESETS:
		preset_option.add_item(p.label)
	preset_option.item_selected.connect(_on_preset_selected)
	ns_prow.add_child(preset_option)
	ns_box.add_child(ns_prow)
	_newsize_dlg.add_child(ns_box)
	_newsize_dlg.confirmed.connect(_on_new_pressed)
	add_child(_newsize_dlg)

	# 保存覆盖确认 → 公共层 EditorUI.confirm（见 _save_shortcut）；不再持久化对话框节点

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
	sidebar.custom_minimum_size = Vector2(230, 0)

	# —— 图层切换（互斥）：地形/线/区域/单位/触发/地点——线与地点仅大地图显示（_apply_map_type 门禁）
	sidebar.add_child(EditorUI.section_title("图层"))
	var layer_grid := GridContainer.new()
	layer_grid.columns = 3
	var lg := ButtonGroup.new()
	_layer_btns = {}
	for pair in [["地形", "terrain"], ["线", "line"], ["区域", "region"], ["单位", "unit"], ["触发", "trigger"], ["地点", "location"]]:
		var b := _layer_button(str(pair[0]), str(pair[1]), lg)
		layer_grid.add_child(b)
		_layer_btns[str(pair[1])] = b
	_layer_btns["terrain"].button_pressed = true
	sidebar.add_child(layer_grid)
	sidebar.add_child(HSeparator.new())

	# 地形笔刷区（当前层=地形时显示）
	_terrain_panel = _build_terrain_brushes()
	sidebar.add_child(_terrain_panel)
	# 线特征工具区（当前层=线时显示）
	_line_panel = _build_line_tools()
	_line_panel.visible = false
	sidebar.add_child(_line_panel)
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
	# 地点工具区（当前层=地点时显示）
	_loc_panel = _build_location_tools()
	_loc_panel.visible = false
	sidebar.add_child(_loc_panel)
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
	if _line_panel: _line_panel.visible = (id == "line")
	if _region_panel: _region_panel.visible = (id == "region")
	if _unit_panel: _unit_panel.visible = (id == "unit")
	if _trigger_panel: _trigger_panel.visible = (id == "trigger")
	if _loc_panel: _loc_panel.visible = (id == "location")
	if id == "trigger":
		_refresh_trigger_list()
		if _active_trigger_idx < 0 and not map_triggers.is_empty():
			_active_trigger_idx = 0
		_load_trigger_form()
	if id == "location":
		_refresh_loc_list()
		_load_loc_form()
	if canvas: canvas.refresh_static()
	match id:
		"line":
			set_status("线特征层：河=沿格间边画（左画右擦）/ 路=沿格拖 / 桥=点已有河边")
		"region":
			if regions.is_empty():
				set_status("区域层：点「＋ 新建区域」再左键画、右键擦")
			else:
				set_status("当前层：区域")
		"unit":
			set_status("单位层：选原型 + 阵营 → 左键落子 / 右键删除（摆这一关的单位）")
		"trigger":
			set_status("触发器层：＋新建 → 选区域 + 事件 + 配 do 动作（关卡事件）")
		"location":
			set_status("地点层：选类型 → 左键放置 / 点已放地点编辑 / 右键删除")
		_:
			set_status("当前层：地形")

# 地形笔刷竖列（原 _build_brush_sidebar 内容）
func _build_terrain_brushes() -> Control:
	var box := VBoxContainer.new()
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(EditorUI.section_title("地形笔刷"))
	var addcat := Button.new()
	addcat.text = "＋ 新建分类"
	addcat.pressed.connect(_on_new_category)
	box.add_child(addcat)
	var erase_chk := CheckButton.new()
	erase_chk.text = "🧹 擦除放置物"
	erase_chk.tooltip_text = "开启后：左键点格＝清除该格的放置物（不动地形）"
	erase_chk.toggled.connect(func(on: bool): _erase_object = on)
	box.add_child(erase_chk)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	_brush_list_box = VBoxContainer.new()
	_brush_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_brush_list_box)
	_brush_group = ButtonGroup.new()
	_rebuild_terrain_brushes()
	# 地形数据（编辑选中笔刷战斗属性）＝进阶段，默认折叠给笔刷让出空间；
	# 向上展开（expand_up）：header 钉在侧栏最底不动，展开时内容向上顶开笔刷区——开合位置一致，符合人体工学。
	box.add_child(EditorUI.make_foldable("地形数据（选中笔刷）", _build_terrain_data(), true, true))
	return box

# ==================== 笔刷分类管理 ====================
# 按分类分组重建笔刷列表。分组只是视觉：brush_buttons 仍与 PALETTE 下标对齐（裸下标消费不受影响）。
func _rebuild_terrain_brushes() -> void:
	if _brush_list_box == null:
		return
	for c in _brush_list_box.get_children():
		c.queue_free()
	brush_buttons = []
	brush_buttons.resize(PALETTE.size())
	# 分组：category -> [PALETTE 下标…]（保 PALETTE 顺序）；用户分类在前、待定垫最后
	var groups := {}
	var order := []
	for cat in TerrainDB.categories():
		var cs := str(cat)
		if not groups.has(cs):
			groups[cs] = []
			order.append(cs)
	for i in PALETTE.size():
		var cat := TerrainDB.category_of(PALETTE[i])
		if not groups.has(cat):
			groups[cat] = []
			order.append(cat)
		groups[cat].append(i)
	order.erase(TerrainDB.DEFAULT_CATEGORY)
	order.append(TerrainDB.DEFAULT_CATEGORY)   # 待定恒在最后、恒显示（即便空，供移入）
	for cat in order:
		if not groups.has(cat):
			groups[cat] = []
		_brush_list_box.add_child(_make_category_group(str(cat), groups[cat]))
	_apply_brush_filter()
	if brush_index >= 0 and brush_index < brush_buttons.size() and brush_buttons[brush_index] != null:
		brush_buttons[brush_index].button_pressed = true

# 一个分类分组：标题行(折叠开关 + ⋯) + 该类笔刷行区
func _make_category_group(cat: String, idxs: Array) -> Control:
	var wrap := VBoxContainer.new()
	wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrap.add_theme_constant_override("separation", 2)
	var section := VBoxContainer.new()
	section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in idxs:
		section.add_child(_make_brush_row(int(i)))
	var collapsed := bool(_cat_collapsed.get(cat, false))
	section.visible = not collapsed
	var hdr := HBoxContainer.new()
	hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tgl := Button.new()
	tgl.toggle_mode = true
	tgl.button_pressed = not collapsed
	tgl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tgl.alignment = HORIZONTAL_ALIGNMENT_LEFT
	tgl.focus_mode = Control.FOCUS_NONE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.18, 0.22, 0.28)
	sb.set_corner_radius_all(3)
	sb.set_content_margin_all(4)
	for st in ["normal", "hover", "pressed"]:
		tgl.add_theme_stylebox_override(st, sb)
	tgl.add_theme_color_override("font_color", Color(0.86, 0.9, 0.96))
	var cnt := idxs.size()
	var upd := func(open: bool): tgl.text = ("▾ " if open else "▸ ") + "%s (%d)" % [cat, cnt]
	upd.call(not collapsed)
	tgl.toggled.connect(func(open: bool):
		section.visible = open
		_cat_collapsed[cat] = not open
		upd.call(open))
	hdr.add_child(tgl)
	if cat != TerrainDB.DEFAULT_CATEGORY:   # 待定桶不给改名/删除
		var mb := EditorUI.make_menu("⋯")
		mb.custom_minimum_size = Vector2(30, 0)
		var pop := mb.get_popup()
		pop.add_item("上移", 2)
		pop.add_item("下移", 3)
		pop.add_separator()
		pop.add_item("分类改名", 0)
		pop.add_item("删除分类（笔刷回待定）", 1)
		pop.id_pressed.connect(func(id: int):
			if id == 0:
				_on_rename_category(cat)
			elif id == 1:
				_on_delete_category(cat)
			elif id == 2:
				_on_move_category(cat, -1)
			elif id == 3:
				_on_move_category(cat, 1))
		hdr.add_child(mb)
	wrap.add_child(hdr)
	wrap.add_child(section)
	return wrap

# 一个笔刷行：原笔刷按钮 + ⋯ 菜单（重命名 / 删除 / 移到分类）
func _make_brush_row(i: int) -> Control:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var b := _make_brush_button(PALETTE[i], _brush_group)
	b.toggled.connect(_on_brush_toggled.bind(i))
	brush_buttons[i] = b
	row.add_child(b)
	var mb := EditorUI.make_menu("⋯")
	mb.custom_minimum_size = Vector2(30, 0)
	var pop := mb.get_popup()
	pop.add_item("重命名", 0)
	pop.add_item("删除笔刷", 1)
	pop.add_item("取消放置物" if TerrainDB.is_object(PALETTE[i]) else "设为放置物", 2)
	pop.add_separator("移到分类")
	var cats := _all_category_names()
	for ci in cats.size():
		pop.add_item("→ " + str(cats[ci]), 100 + ci)
	pop.id_pressed.connect(func(id: int):
		if id == 0:
			_on_rename_brush(i)
		elif id == 1:
			_on_delete_brush(i)
		elif id == 2:
			_on_toggle_object(i)
		elif id >= 100 and (id - 100) < cats.size():
			_on_move_brush(i, str(cats[id - 100])))
	row.add_child(mb)
	return row

# 全部分类名（用户分类 + 待定），供「移到分类」子菜单
func _all_category_names() -> Array:
	var out := []
	for c in TerrainDB.categories():
		out.append(str(c))
	if not out.has(TerrainDB.DEFAULT_CATEGORY):
		out.append(TerrainDB.DEFAULT_CATEGORY)
	return out

# 通用文本输入弹窗（懒建、复用；确定回调 _prompt_cb）
func _text_prompt(title: String, initial: String, cb: Callable) -> void:
	if _prompt_dlg == null:
		_prompt_dlg = ConfirmationDialog.new()
		_prompt_dlg.ok_button_text = "确定"
		_prompt_dlg.get_cancel_button().text = "取消"
		var vb := VBoxContainer.new()
		_prompt_lbl = Label.new()
		vb.add_child(_prompt_lbl)
		_prompt_edit = LineEdit.new()
		_prompt_edit.custom_minimum_size = Vector2(320, 0)
		vb.add_child(_prompt_edit)
		_prompt_dlg.add_child(vb)
		_prompt_dlg.register_text_enter(_prompt_edit)
		_prompt_dlg.confirmed.connect(func():
			if _prompt_cb.is_valid():
				_prompt_cb.call(_prompt_edit.text.strip_edges()))
		add_child(_prompt_dlg)
	_prompt_dlg.title = title
	_prompt_lbl.text = title
	_prompt_edit.text = initial
	_prompt_cb = cb
	_prompt_dlg.popup_centered(Vector2i(380, 150))
	_prompt_edit.select_all()
	_prompt_edit.grab_focus()

func _on_new_category() -> void:
	_text_prompt("新建分类名", "", func(nm: String):
		if nm == "" or nm == TerrainDB.DEFAULT_CATEGORY:
			return
		var cats: Array = TerrainDB.categories()
		if not cats.has(nm):
			cats.append(nm)
			TerrainDB.set_categories(cats)
			TerrainDB.save()
		_cat_collapsed[nm] = false
		_rebuild_terrain_brushes())

func _on_rename_category(cat: String) -> void:
	_text_prompt("分类改名", cat, func(nm: String):
		if nm == "" or nm == cat or nm == TerrainDB.DEFAULT_CATEGORY:
			return
		var cats: Array = TerrainDB.categories()
		var idx := cats.find(cat)
		if idx >= 0:
			cats[idx] = nm
			TerrainDB.set_categories(cats)
		for e in PALETTE:
			if str(e.get("category", "")) == cat:
				e["category"] = nm
		if _cat_collapsed.has(cat):
			_cat_collapsed[nm] = _cat_collapsed[cat]
			_cat_collapsed.erase(cat)
		TerrainDB.save()
		_rebuild_terrain_brushes())

func _on_delete_category(cat: String) -> void:
	EditorUI.confirm(self, "删除分类「%s」？其中的笔刷会退回「待定」（不删笔刷本身）。" % cat,
		"删除分类", func():
			var cats: Array = TerrainDB.categories()
			cats.erase(cat)
			TerrainDB.set_categories(cats)
			for e in PALETTE:
				if str(e.get("category", "")) == cat:
					e.erase("category")
			_cat_collapsed.erase(cat)
			TerrainDB.save()
			_rebuild_terrain_brushes(),
		Callable(), "删除分类")

# 分类排序：在 categories 数组里与相邻项交换（delta=-1 上移 / +1 下移）。待定不在数组、恒最后。
func _on_move_category(cat: String, delta: int) -> void:
	var cats: Array = TerrainDB.categories()
	var idx := cats.find(cat)
	if idx < 0:
		return
	var j := idx + delta
	if j < 0 or j >= cats.size():
		return
	var tmp = cats[idx]
	cats[idx] = cats[j]
	cats[j] = tmp
	TerrainDB.set_categories(cats)
	TerrainDB.save()
	_rebuild_terrain_brushes()

func _on_rename_brush(i: int) -> void:
	if i < 0 or i >= PALETTE.size():
		return
	var e = PALETTE[i]
	_text_prompt("重命名笔刷", str(e.get("label", "")), func(nm: String):
		if nm == "":
			return
		e["label"] = nm
		TerrainDB.save()
		if i < brush_buttons.size() and brush_buttons[i] != null:
			brush_buttons[i].text = nm   # 原地改名、免全表重建
		else:
			_rebuild_terrain_brushes())

func _on_delete_brush(i: int) -> void:
	if i < 0 or i >= PALETTE.size():
		return
	var e = PALETTE[i]
	EditorUI.confirm(self, "彻底删除笔刷「%s」？\n将从 terrains.json 整条移除（写盘，不可撤销）。" % str(e.get("label", "")),
		"删除", func():
			var cur_key := ""
			if brush_index >= 0 and brush_index < PALETTE.size():
				var ce = PALETTE[brush_index]
				cur_key = "%s/%s" % [ce.get("terrain"), ce.get("variant")]
			var del_key := "%s/%s" % [e.get("terrain"), e.get("variant")]
			TerrainDB.delete_entry({"terrain": e.get("terrain"), "variant": e.get("variant")})
			TerrainDB.save()   # PALETTE 是 _palette 活引用、已同步缩短
			if cur_key == del_key or cur_key == "":
				brush_index = clampi(brush_index, 0, maxi(0, PALETTE.size() - 1))
			else:
				var ni := -1
				for j in PALETTE.size():
					if "%s/%s" % [PALETTE[j].get("terrain"), PALETTE[j].get("variant")] == cur_key:
						ni = j
						break
				brush_index = ni if ni >= 0 else clampi(brush_index, 0, maxi(0, PALETTE.size() - 1))
			_rebuild_terrain_brushes(),
		Callable(), "确认删除")

func _on_move_brush(i: int, cat: String) -> void:
	if i < 0 or i >= PALETTE.size():
		return
	var e = PALETTE[i]
	if cat == "" or cat == TerrainDB.DEFAULT_CATEGORY:
		e.erase("category")
	else:
		e["category"] = cat
	TerrainDB.save()
	_rebuild_terrain_brushes()

# 切换「放置物笔刷」标记：标了的地形，画笔时落在放置物层（盖地形上、单位之下）
func _on_toggle_object(i: int) -> void:
	if i < 0 or i >= PALETTE.size():
		return
	var e = PALETTE[i]
	TerrainDB.set_object({"terrain": e.get("terrain"), "variant": e.get("variant")}, not TerrainDB.is_object(e))
	TerrainDB.save()
	_rebuild_terrain_brushes()

# 地形数据编辑区（移动成本/通行/tag 成本 + 全局·本图范围）——被 _build_terrain_brushes 包进折叠区
func _build_terrain_data() -> Control:
	var box := VBoxContainer.new()
	# 范围：全局＝写回 terrains.json（影响所有图）；本图＝只覆盖这张图（存进地图 terrain_overrides）
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
	if canvas: canvas.refresh_static()

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

# ============ 地图类型（battle/overworld）切换 + 笔刷 scope 过滤 ============

# 类型按钮：在 战斗图 ⇄ 大地图 间来回切
func _on_map_type_toggle() -> void:
	var nt := "battle" if map_type == "overworld" else "overworld"
	_push_undo(_snapshot(), "地图类型")
	map_type = nt
	_dirty = true
	_update_file_label()
	_apply_map_type()
	set_status("地图类型：%s（笔刷已按 scope 过滤；%s）" % [
		"大地图" if nt == "overworld" else "战斗图",
		"线特征/地点层已开放" if nt == "overworld" else "线特征/地点层已隐藏（数据保留）"])

# map_type 落地（切换/载入/撤销后调）：同步顶栏类型按钮 + 笔刷 scope 过滤 + 线/地点层门禁。
# 越 scope 的已画地形不动——scope 只管笔刷栏 authoring，渲染/通行照常（旧图零破坏）。
func _apply_map_type() -> void:
	if _map_type_btn != null:
		_map_type_btn.text = "大地图" if map_type == "overworld" else "战斗图"
	_apply_brush_filter()
	var on_ow := map_type == "overworld"
	for lid in ["line", "location"]:
		if _layer_btns.has(lid):
			_layer_btns[lid].visible = on_ow
	if not on_ow and (current_layer == "line" or current_layer == "location"):
		_layer_btns["terrain"].button_pressed = true   # 触发 toggled → _set_layer("terrain")

# 笔刷按 scope 过滤：只动按钮可见性（brush_index 仍是 PALETTE 裸下标，约 10 处消费不重排）。
# 当前笔刷被隐藏 → 自动跳到首个可见笔刷。
func _apply_brush_filter() -> void:
	var first_visible := -1
	for i in PALETTE.size():
		if i >= brush_buttons.size() or brush_buttons[i] == null:
			continue
		var ok: bool = (not SCOPE_FILTER_ON) or TerrainDB.in_scope(PALETTE[i], map_type)
		brush_buttons[i].visible = ok
		var row = brush_buttons[i].get_parent()   # 连整行(含 ⋯)一起隐，别留空壳（越 scope 的格才不会剩个孤零 ⋯）
		if row is Control:
			row.visible = ok
		if ok and first_visible < 0:
			first_visible = i
	if brush_index < 0 or brush_index >= PALETTE.size():
		brush_index = clampi(brush_index, 0, maxi(0, PALETTE.size() - 1))
	if SCOPE_FILTER_ON and first_visible >= 0 and not TerrainDB.in_scope(PALETTE[brush_index], map_type):
		brush_buttons[first_visible].button_pressed = true   # 触发 toggled → select_brush

# 当前可见（scope 内）笔刷的 PALETTE 下标序列——数字键 1~9 按此映射
func _visible_brush_indices() -> Array:
	var out := []
	for i in PALETTE.size():
		if (not SCOPE_FILTER_ON) or TerrainDB.in_scope(PALETTE[i], map_type):
			out.append(i)
	return out

# ============ 线特征层（河/路/桥；大地图专属 authoring）============

func _build_line_tools() -> Control:
	var v := VBoxContainer.new()
	v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(EditorUI.section_title("线特征（左键画 / 右键擦）"))
	var mrow := HBoxContainer.new()
	mrow.add_child(_make_label("工具"))
	var mopt := OptionButton.new()
	for i in LINE_MODES.size():
		mopt.add_item(LINE_MODES[i][1], i)
	mopt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mopt.item_selected.connect(_on_line_mode_selected)
	mrow.add_child(mopt)
	v.add_child(mrow)
	var hint := _make_label("河=移动阻隔（过河须桥）；路=沿路跨边成本折为1；桥=河上通行点。语义仅大地图生效。")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", Color(0.7, 0.74, 0.82))
	v.add_child(hint)
	var clr := Button.new()
	clr.text = "清空本图线特征"
	clr.pressed.connect(_on_clear_lines)
	v.add_child(clr)
	return v

func _on_line_mode_selected(idx: int) -> void:
	_line_mode = LINE_MODES[idx][0]
	match _line_mode:
		"river": set_status("河刷：沿两格间的边拖动画河（右键擦；擦河会顺带拆桥）")
		"road": set_status("路刷：沿格拖动连路（红虚线；右键沿边擦段）")
		"bridge": set_status("桥刷：左键点已有河的边架桥 / 右键拆桥")

func _on_clear_lines() -> void:
	if map_rivers.is_empty() and map_roads.is_empty() and map_bridges.is_empty():
		return
	_push_undo(_snapshot(), "清空线特征")
	map_rivers = []
	map_roads = []
	map_bridges = []
	_dirty = true
	_update_file_label()
	set_status("已清空本图全部河/路/桥")
	if canvas: canvas.refresh_static()

# 画布线层输入入口：对边 (a,b) 施加当前工具（add=左键画 / 右键擦）。走 stroke → 一段拖动一次撤销。
func line_paint_edge(a: Vector2i, b: Vector2i, add: bool) -> void:
	match _line_mode:
		"river":
			if add:
				_river_add_edge(a, b)
			else:
				_river_remove_edge(a, b)
		"road":
			if not add:
				_road_remove_edge(a, b)
			# 路的「画」走 road_paint_cell（格轨迹连线），边入口只管擦
		"bridge":
			if add:
				_bridge_add_edge(a, b)
			else:
				_bridge_remove_edge(a, b)

# 路刷（左键拖格）：与上一格连线成段；跳格（快速拖动）用 HexGrid.line 补中间格
func road_paint_cell(col: int, row: int) -> void:
	var cur := Vector2i(col, row)
	if _road_last_cell.x < 0:
		_road_last_cell = cur
		return
	if cur == _road_last_cell:
		return
	var chain := [_road_last_cell, cur] if HexGrid.adjacent(_road_last_cell, cur) else HexGrid.line(_road_last_cell, cur)
	for i in range(chain.size() - 1):
		_road_add_edge(chain[i], chain[i + 1])
	_road_last_cell = cur

# —— 河 ——（编辑器只维护单条缺省河 river_1；多条命名河可手改 json，读写保真）
func _river_add_edge(a: Vector2i, b: Vector2i) -> void:
	if _feature_has_edge(map_rivers, a, b):
		return
	if map_rivers.is_empty():
		map_rivers.append({"id": "river_1", "label": "河流", "pairs": []})
	map_rivers[0]["pairs"].append(_pair_json(a, b))
	_line_touched()

func _river_remove_edge(a: Vector2i, b: Vector2i) -> void:
	var removed := _feature_remove_edge(map_rivers, a, b)
	# 河没了桥就悬空：擦河顺带拆该边的桥
	if _remove_pair(map_bridges, a, b):
		removed = true
	if removed:
		_line_touched()

# —— 路 ——
func _road_add_edge(a: Vector2i, b: Vector2i) -> void:
	if not HexGrid.adjacent(a, b) or _feature_has_edge(map_roads, a, b):
		return
	if map_roads.is_empty():
		map_roads.append({"id": "road_1", "label": "道路", "pairs": []})
	map_roads[0]["pairs"].append(_pair_json(a, b))
	_line_touched()

func _road_remove_edge(a: Vector2i, b: Vector2i) -> void:
	if _feature_remove_edge(map_roads, a, b):
		_line_touched()

# —— 桥 ——（须架在河边上）
func _bridge_add_edge(a: Vector2i, b: Vector2i) -> void:
	if not _feature_has_edge(map_rivers, a, b):
		set_status("桥须架在河上——先用河刷在这条边画河")
		return
	if _pair_index(map_bridges, a, b) >= 0:
		return
	map_bridges.append(_pair_json(a, b))
	_line_touched()

func _bridge_remove_edge(a: Vector2i, b: Vector2i) -> void:
	if _remove_pair(map_bridges, a, b):
		_line_touched()

func _line_touched() -> void:
	_stroke_dirty = true
	_stroke_count += 1
	_dirty = true
	if canvas: canvas.refresh_static()

# —— 格对工具（JSON 形 [[x,y],[x,y]]；无向，键归一走 HexGrid.edge_key）——

func _pair_json(a: Vector2i, b: Vector2i) -> Array:
	return [[a.x, a.y], [b.x, b.y]]

func _pair_matches(p, a: Vector2i, b: Vector2i) -> bool:
	if typeof(p) != TYPE_ARRAY or p.size() < 2:
		return false
	var pa = p[0]
	var pb = p[1]
	if typeof(pa) != TYPE_ARRAY or pa.size() < 2 or typeof(pb) != TYPE_ARRAY or pb.size() < 2:
		return false
	return HexGrid.edge_key(Vector2i(int(pa[0]), int(pa[1])), Vector2i(int(pb[0]), int(pb[1]))) == HexGrid.edge_key(a, b)

func _pair_index(pairs: Array, a: Vector2i, b: Vector2i) -> int:
	for i in pairs.size():
		if _pair_matches(pairs[i], a, b):
			return i
	return -1

func _remove_pair(pairs: Array, a: Vector2i, b: Vector2i) -> bool:
	var i := _pair_index(pairs, a, b)
	if i < 0:
		return false
	pairs.remove_at(i)
	return true

# 特征列表（[{pairs:[…]}]）是否含边 / 移除边（全列表扫；空壳特征保留，避免撤销语义复杂化）
func _feature_has_edge(features: Array, a: Vector2i, b: Vector2i) -> bool:
	for f in features:
		if typeof(f) == TYPE_DICTIONARY and _pair_index(f.get("pairs", []), a, b) >= 0:
			return true
	return false

func _feature_remove_edge(features: Array, a: Vector2i, b: Vector2i) -> bool:
	var removed := false
	for f in features:
		if typeof(f) != TYPE_DICTIONARY:
			continue
		var pairs = f.get("pairs", [])
		if typeof(pairs) == TYPE_ARRAY and _remove_pair(pairs, a, b):
			removed = true
	return removed

# 画布渲染钩子（HexCanvas has_method 可选契约；三宿主同名）
func line_features() -> Dictionary:
	return {"rivers": map_rivers, "roads": map_roads, "bridges": map_bridges}

# ============ 地点层（大地图 locations 实例 authoring）============

func _build_location_tools() -> Control:
	var v := VBoxContainer.new()
	v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(EditorUI.section_title("地点（左键放置/选中，右键删）"))
	v.add_child(_make_label("放置类型"))
	_loc_type_list = ItemList.new()
	_loc_type_list.custom_minimum_size = Vector2(0, 92)
	_loc_type_list.item_selected.connect(func(idx: int):
		_loc_type_idx = idx
		if idx >= 0 and idx < _loc_types.size():
			set_status("将放置：%s——左键点格放置" % str(_loc_types[idx].get("label", ""))))
	v.add_child(_loc_type_list)
	_loc_types = LocationDB.all_types()
	for t in _loc_types:
		_loc_type_list.add_item(str(t.get("label", t.get("id", "地点"))))
	if not _loc_types.is_empty():
		_loc_type_list.select(0)
	v.add_child(HSeparator.new())
	v.add_child(_make_label("已放置"))
	_loc_list = ItemList.new()
	_loc_list.custom_minimum_size = Vector2(0, 92)
	_loc_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_loc_list.item_selected.connect(func(idx: int):
		_active_loc_idx = idx
		_load_loc_form()
		var loc := active_location()
		if not loc.is_empty() and canvas:
			canvas.center_on_cell(int(loc.get("col", 0)), int(loc.get("row", 0))))
	v.add_child(_loc_list)
	v.add_child(HSeparator.new())
	v.add_child(_make_label("选中地点"))
	_loc_id_edit = _loc_form_line("id（改名慎重：触发器/存档肃清账/world_units.json 的 home 均按此 id 引用，改了会断）", func(t: String): _set_loc_field("id", t))
	v.add_child(_loc_id_edit)
	_loc_label_edit = _loc_form_line("名字", func(t: String):
		_set_loc_field("label", t)
		_refresh_loc_list())
	v.add_child(_loc_label_edit)
	var trow := HBoxContainer.new()
	trow.add_child(_make_label("类型"))
	_loc_type_opt = OptionButton.new()
	for t in _loc_types:
		_loc_type_opt.add_item(str(t.get("label", "")))
	_loc_type_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_loc_type_opt.item_selected.connect(_on_loc_type_changed)
	trow.add_child(_loc_type_opt)
	v.add_child(trow)
	_loc_battle_edit = _loc_form_line("battle_map（据点讨伐地图路径）", func(t: String): _set_loc_field_or_erase("battle_map", t))
	v.add_child(_loc_battle_edit)
	_loc_dialogue_edit = _loc_form_line("dialogue_id（交谈对话）", func(t: String): _set_loc_field_or_erase("dialogue_id", t))
	v.add_child(_loc_dialogue_edit)
	return v

func _loc_form_line(placeholder: String, cb: Callable) -> LineEdit:
	var le := LineEdit.new()
	le.placeholder_text = placeholder
	le.tooltip_text = placeholder
	le.text_changed.connect(cb)
	return le

func active_location() -> Dictionary:
	if _active_loc_idx >= 0 and _active_loc_idx < map_locations.size():
		var loc = map_locations[_active_loc_idx]
		if typeof(loc) == TYPE_DICTIONARY:
			return loc
	return {}

func _loc_index_at(col: int, row: int) -> int:
	for i in range(map_locations.size() - 1, -1, -1):
		var e = map_locations[i]
		if typeof(e) == TYPE_DICTIONARY and int(e.get("col", -1)) == col and int(e.get("row", -1)) == row:
			return i
	return -1

func _unique_loc_id(type_id: String) -> String:
	var used := {}
	for l in map_locations:
		used[str(l.get("id", ""))] = true
	var n := 1
	while used.has("%s_%d" % [type_id, n]):
		n += 1
	return "%s_%d" % [type_id, n]

# 地点层左键：一次拖动在首格锁定动作——首格命中地点=选中它（拖出不放子）；首格空=放置当前类型（拖动只放一个）。
func _loc_paint(col: int, row: int) -> void:
	if _loc_stroke_action == "":
		var idx0 := _loc_index_at(col, row)
		_loc_stroke_action = "select" if idx0 >= 0 else "place"
		if _loc_stroke_action == "select":
			_active_loc_idx = idx0
			_refresh_loc_list()
			_load_loc_form()
			set_status("选中地点：%s（左侧表单可编辑）" % str(map_locations[idx0].get("label", "")))
			return
	if _loc_stroke_action == "select":
		return   # 选中模式：后续拖动格不落子
	if _loc_stroke_placed:
		return
	if _loc_type_idx < 0 or _loc_type_idx >= _loc_types.size():
		set_status("先在左侧选一个地点类型")
		return
	var tdef: Dictionary = _loc_types[_loc_type_idx]
	var tid := str(tdef.get("id", ""))
	_push_undo(_snapshot(), "放置地点")
	var loc := {"id": _unique_loc_id(tid), "type": tid, "label": str(tdef.get("label", "地点")), "col": col, "row": row}
	if bool(tdef.get("site", false)):
		loc["battle_map"] = "res://maps/sandbox.json"   # 据点型默认给个可打的图，表单可改
	map_locations.append(loc)
	_active_loc_idx = map_locations.size() - 1
	_loc_stroke_placed = true
	_dirty = true
	_update_file_label()
	_refresh_loc_list()
	_load_loc_form()
	set_status("已放置：%s @(%d,%d)" % [str(loc["label"]), col, row])
	if canvas: canvas.refresh_static()

func _loc_remove(col: int, row: int) -> void:
	var idx := _loc_index_at(col, row)
	if idx < 0:
		return
	_push_undo(_snapshot(), "删除地点")
	var nm := str(map_locations[idx].get("label", ""))
	map_locations.remove_at(idx)
	if _active_loc_idx == idx:
		_active_loc_idx = -1
	elif _active_loc_idx > idx:
		_active_loc_idx -= 1
	_dirty = true
	_update_file_label()
	_refresh_loc_list()
	_load_loc_form()
	set_status("已删除地点：%s" % nm)
	if canvas: canvas.refresh_static()

func _refresh_loc_list() -> void:
	if _loc_list == null:
		return
	_loc_list.clear()
	for l in map_locations:
		if typeof(l) != TYPE_DICTIONARY:
			continue
		var tdef = LocationDB.type_def(str(l.get("type", "")))
		var tl := str(tdef.get("label", l.get("type", "?"))) if tdef != null else str(l.get("type", "?"))
		_loc_list.add_item("%s〔%s〕(%d,%d)" % [str(l.get("label", "")), tl, int(l.get("col", 0)), int(l.get("row", 0))])
	if _active_loc_idx >= 0 and _active_loc_idx < map_locations.size():
		_loc_list.select(_active_loc_idx)

func _load_loc_form() -> void:
	if _loc_id_edit == null:
		return
	_loc_loading = true
	var loc := active_location()
	var has := not loc.is_empty()
	for le in [_loc_id_edit, _loc_label_edit, _loc_battle_edit, _loc_dialogue_edit]:
		le.editable = has
	_loc_id_edit.text = str(loc.get("id", "")) if has else ""
	_loc_label_edit.text = str(loc.get("label", "")) if has else ""
	_loc_battle_edit.text = str(loc.get("battle_map", "")) if has else ""
	_loc_dialogue_edit.text = str(loc.get("dialogue_id", "")) if has else ""
	if has:
		var tid := str(loc.get("type", ""))
		for i in _loc_types.size():
			if str(_loc_types[i].get("id", "")) == tid:
				_loc_type_opt.select(i)
				break
	_loc_loading = false

# 表单回写（文本高频输入不逐击入撤销栈——与区域颜色同待遇，只标脏）
func _set_loc_field(key: String, val: String) -> void:
	if _loc_loading:
		return
	var loc := active_location()
	if loc.is_empty():
		return
	if key == "id":
		var v := val.strip_edges()
		if v == "":
			set_status("id 不能为空")
			return
		for i in map_locations.size():
			if i != _active_loc_idx and str(map_locations[i].get("id", "")) == v:
				set_status("⚠ id 与「%s」重复——触发器/存档按 id 引用，请改成唯一" % str(map_locations[i].get("label", "")))
		loc["id"] = v
	else:
		loc[key] = val
	_dirty = true
	_update_file_label()

# 可选字段：清空文本＝删键（保持 schema 干净，不落空串）
func _set_loc_field_or_erase(key: String, val: String) -> void:
	if _loc_loading:
		return
	var loc := active_location()
	if loc.is_empty():
		return
	if val.strip_edges() == "":
		loc.erase(key)
	else:
		loc[key] = val.strip_edges()
	_dirty = true
	_update_file_label()

func _on_loc_type_changed(idx: int) -> void:
	if _loc_loading or idx < 0 or idx >= _loc_types.size():
		return
	var loc := active_location()
	if loc.is_empty():
		return
	var tid := str(_loc_types[idx].get("id", ""))
	if str(loc.get("type", "")) == tid:
		return
	_push_undo(_snapshot(), "地点类型")
	loc["type"] = tid
	_dirty = true
	_update_file_label()
	_refresh_loc_list()
	if canvas: canvas.refresh_static()

# 画布地点层数据（EditorCanvas 画旗帜用；颜色走 LocationDB 类型色）
func locations_for_draw() -> Array:
	var out := []
	for l in map_locations:
		if typeof(l) != TYPE_DICTIONARY:
			continue
		var type_id := str(l.get("type", ""))
		var tdef = LocationDB.type_def(type_id)
		var col := Color.html(str(tdef.get("color", "#CCCCCC"))) if tdef != null else Color(0.8, 0.8, 0.8)
		out.append({"cell": Vector2i(int(l.get("col", 0)), int(l.get("row", 0))), "color": col, "label": str(l.get("label", "")), "active": true, "type": type_id, "icon": str(l.get("icon", ""))})
	return out

# 区域工具：列表（选当前）+ 新建/改名/删除 + 颜色
func _build_region_tools() -> Control:
	var v := VBoxContainer.new()
	v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(EditorUI.section_title("区域（左键画 / 右键擦）"))
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
	v.add_child(EditorUI.section_title("单位（左键落子 / 右键删）"))
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
# 阵营色单一源＝tags.json faction 条目 color（TagDB.color，与战斗侧同一份）；未知回退灰
func faction_color(fac: String) -> Color:
	var hex := TagDB.color(fac)
	return Color(hex) if hex != "" else Color(0.8, 0.8, 0.8)

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
	if canvas: canvas.refresh_static()

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
	if canvas: canvas.refresh_static()

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
	if canvas: canvas.refresh_static()

# 改名字/阵营 → DeployPanel 调此（战斗宿主里刷底部栏；编辑器里=序列化回关卡 + 重绘 token）
func _refresh_roster_bar() -> void:
	if _editing_unit == null:
		return
	_unit_edit_before_change()
	_serialize_editing_unit()
	if canvas: canvas.refresh_static()

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
	v.add_child(EditorUI.section_title("触发器"))
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
	var defs := EventEngine.action_defs()   # 动作菜单＝注册表驱动（新动作登记 EventEngine 即自动出现在这）
	for i in defs.size():
		pop.add_item(str(defs[i]["label"]), i)
	pop.id_pressed.connect(func(id: int): _on_add_action(str(EventEngine.action_defs()[id]["id"])))
	_trig_do_box.add_child(mb)

func _on_add_action(act: String) -> void:
	var t := active_trigger()
	if t.is_empty():
		return
	_push_undo(_snapshot(), "添加动作")
	if typeof(t.get("do")) != TYPE_ARRAY:
		t["do"] = []
	t["do"].append(EventEngine.default_action(act))
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
	var lbl := _make_label("• " + EventEngine.action_label(str(a.get("action", ""))))
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(lbl)
	var x := Button.new()
	x.text = "✕"
	x.pressed.connect(_on_remove_action.bind(idx))
	head.add_child(x)
	box.add_child(head)
	# 参数表单＝注册表 fields 数据驱动（不再每动作手写分支；新动作登记 EventEngine.ACTIONS 即自动有表单）
	for f in EventEngine.action_def(str(a.get("action", ""))).get("fields", []):
		box.add_child(_build_action_field(a, f))
	box.add_child(HSeparator.new())
	return box

# 注册表字段 → 控件（type：text/int/proto/faction/weather）。int 的 max 是宽泛上限，越界值运行时按地图 clamp。
func _build_action_field(a: Dictionary, f: Dictionary) -> Control:
	var key := str(f.get("key", ""))
	var flabel := str(f.get("label", key))
	match str(f.get("type", "text")):
		"int":
			var row := HBoxContainer.new()
			row.add_child(_make_label(flabel))
			var sp := SpinBox.new()
			sp.min_value = int(f.get("min", 0))
			sp.max_value = int(f.get("max", 999))
			sp.value = int(a.get(key, f.get("default", 0)))
			sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sp.value_changed.connect(func(val: float): _set_action_field(a, key, int(val)))
			row.add_child(sp)
			return row
		"proto":
			var protos := UnitFactory.all_prototypes()
			var po := OptionButton.new()
			for i in protos.size():
				po.add_item(str(protos[i].get("name", "")))
				if str(protos[i].get("id", "")) == str(a.get(key, "")):
					po.select(i)
			po.item_selected.connect(func(i: int): _set_action_field(a, key, str(protos[i].get("id", ""))))
			return po
		"faction":
			var fo := OptionButton.new()
			for i in UNIT_FACTIONS.size():
				fo.add_item(TagDB.cn(UNIT_FACTIONS[i]))
				if UNIT_FACTIONS[i] == str(a.get(key, f.get("default", ""))):
					fo.select(i)
			fo.item_selected.connect(func(i: int): _set_action_field(a, key, UNIT_FACTIONS[i]))
			return fo
		"weather":
			var weathers := EnvDB.all_weathers()
			var wo := OptionButton.new()
			for i in weathers.size():
				wo.add_item(str(weathers[i].get("label", weathers[i].get("id", ""))))
				if str(weathers[i].get("id", "")) == str(a.get(key, f.get("default", "clear"))):
					wo.select(i)
			wo.item_selected.connect(func(i: int): _set_action_field(a, key, str(weathers[i].get("id", ""))))
			return wo
		_:   # "text"
			var le := LineEdit.new()
			le.placeholder_text = flabel
			le.text = str(a.get(key, ""))
			le.text_changed.connect(func(t: String): _set_action_field(a, key, t))
			return le

# 右栏与左栏对称：最近操作（折叠·右上，对位左栏图层）/ 地图库（主内容撑满，对位地形笔刷）/ 环境（折叠·向上展开·右下，与左栏底部地形数据对称）
func _build_side_panel() -> Control:
	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(240, 0)

	# —— 最近操作（撤销栈）＝右上角折叠（默认收起，需要时展开看）——
	side.add_child(EditorUI.make_foldable("最近操作（顶＝下一个撤销）", _build_history_panel(), true))
	side.add_child(HSeparator.new())

	# —— 地图库（文件夹 + 其中地图列表）＝主内容，撑满中段 ——
	side.add_child(EditorUI.section_title("地图库"))
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

	# —— 当前文件 ——
	_file_label = _make_label("文件：(未保存)")
	_file_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	side.add_child(_file_label)

	# —— 环境（日夜 + 天气表；地图级 authoring）＝右下角折叠·向上展开，与左栏底部「地形数据」对称 ——
	side.add_child(EditorUI.make_foldable("环境（天气·日夜）", _build_env_section(), true, true))
	return side

# 撤销历史面板（收进右上折叠区）：一个固定高度的列表
func _build_history_panel() -> Control:
	var v := VBoxContainer.new()
	_history_list = ItemList.new()
	_history_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_history_list.custom_minimum_size = Vector2(0, 150)
	v.add_child(_history_list)
	return v

# ------------------------------------------------------------------ 环境（日夜 + 天气表）

# 环境面板：日夜下拉 + 天气表（增删行）。写进 map_environment，随图存盘、含撤销。
func _build_env_section() -> Control:
	var v := VBoxContainer.new()
	var trow := HBoxContainer.new()
	trow.add_child(_make_label("日夜"))
	_env_time_opt = OptionButton.new()
	_env_time_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 第 0 项＝跟随时钟（不写 time 键＝战役按世界时钟推导，M2 语义）；显式昼/夜从下标 1 起
	_env_time_opt.add_item("跟随时钟（战役日夜）")
	for t in EnvDB.all_times():
		_env_time_opt.add_item("锁定：%s (%s)" % [str(t.get("label", "")), str(t.get("id", ""))])
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

# 刷新整个环境面板（载入 / 撤销 / 新图后调）：同步日夜下拉 + 重建天气行。
# 无 time 键＝跟随时钟（第 0 项）；有键＝锁定态（1+i）——UI 呈现与 M2 运行时语义一致，不再「显示昼实为跟随」。
func _refresh_env_panel() -> void:
	if _env_time_opt == null:
		return
	var has_time: bool = typeof(map_environment) == TYPE_DICTIONARY and map_environment.has("time")
	if not has_time:
		_env_time_opt.select(0)
	else:
		var cur_time := str(map_environment.get("time", "day"))
		var times := EnvDB.all_times()
		for i in times.size():
			if str(times[i].get("id", "")) == cur_time:
				_env_time_opt.select(i + 1)
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
	var has_time: bool = typeof(map_environment) == TYPE_DICTIONARY and map_environment.has("time")
	if idx <= 0:   # 选「跟随时钟」＝删 time 键（战役按世界时钟推导）
		if not has_time:
			return   # 本就跟随：无变化
		_push_undo(_snapshot(), "环境·日夜")
		map_environment.erase("time")
		_dirty = true
		_update_file_label()
		return
	var times := EnvDB.all_times()
	if idx - 1 >= times.size():
		return
	var id := str(times[idx - 1].get("id", "day"))
	if has_time and str(map_environment.get("time", "")) == id:
		return   # 已锁定同值：无变化（跟随态选「昼」也会真正落键——修「显式选昼被判无变化」）
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
		var p := _join(_map_dir, n)
		_map_paths.append(p)
		_map_list.add_item(n + ("  〔大地图〕" if MapIO.peek_type(p) == "overworld" else ""))
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

# —— UI chrome 已抽到公共层：分节/折叠/菜单/面板/主题/文件对话框见 EditorUI.gd + EditorTheme.gd ——

# 文件菜单分派：新建地图…/保存/另存为…/加载…/返回主菜单
func _on_file_menu(id: int) -> void:
	match id:
		0: _newsize_dlg.popup_centered()
		1: _save_shortcut()
		2: _on_save_as_pressed()
		3: _on_load_pressed()

# 笔刷按钮＝左侧地块缩略图（完整六边形，与地图格同一份 HexTileRender 渲染）+ 右侧地形名。
# 底色改中性深底（地块颜色已由缩略图承载）；选中＝亮黄描边。
func _make_brush_button(entry: Dictionary, group: ButtonGroup) -> Button:
	var b := Button.new()
	b.text = ("⊕ " if TerrainDB.is_object(entry) else "") + str(entry.label)   # ⊕＝放置物笔刷
	b.toggle_mode = true
	b.button_group = group
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, 50)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.clip_text = true
	b.tooltip_text = "%s（terrain=%s, variant=%s）\ntags: %s" % [
		entry.label, entry.terrain, entry.variant, ", ".join(entry.tags)]

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.17, 0.20)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 52   # 给左侧缩略图让位
	sb.content_margin_right = 6
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	var sb_hover := sb.duplicate()
	sb_hover.bg_color = Color(0.22, 0.24, 0.28)
	var sb_pressed := sb.duplicate()
	sb_pressed.bg_color = Color(0.26, 0.30, 0.36)
	sb_pressed.border_color = Color(1.0, 0.9, 0.35)
	sb_pressed.set_border_width_all(2)
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", sb_hover)
	b.add_theme_stylebox_override("pressed", sb_pressed)
	b.add_theme_stylebox_override("focus", sb_pressed)
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(c, Color(0.9, 0.92, 0.96))

	# 左侧缩略图（点击穿透到按钮；固定 46×44、竖向居中于 50px 行高）
	var sw := TerrainSwatch.new()
	sw.set_tile(str(entry.terrain), str(entry.variant))
	sw.position = Vector2(3, 3)
	sw.size = Vector2(46, 44)
	b.add_child(sw)
	return b


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
	# 数字键 1~9 快速选笔刷（仅地形层；按 scope 过滤后的可见序映射；焦点在输入框时该键被其消费、不会落到这里）
	if current_layer == "terrain" and event.keycode >= KEY_1 and event.keycode <= KEY_9:
		var idx: int = event.keycode - KEY_1
		var vis := _visible_brush_indices()
		if idx < vis.size():
			brush_buttons[vis[idx]].button_pressed = true  # 触发 toggled -> select_brush
			get_viewport().set_input_as_handled()

# 有未保存改动时先确认再执行 action（新建/加载共用）
func _confirm_discard(action: Callable) -> void:
	EditorUI.confirm_discard(self, _dirty, action, _refresh_map_highlight,
		"当前地图有未保存的改动，确定要丢弃吗？")

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
	# 没文件走“另存为”（文件选择器本身即确认）；有文件＝覆盖，先弹确认显示目标路径（防手快覆盖错文件）
	if current_path == "":
		_on_save_as_pressed()
	else:
		EditorUI.confirm(self, "覆盖保存到：\n%s\n（此操作会覆盖该文件）" % current_path,
			"覆盖保存", func(): save_to_file(current_path), Callable(), "确认保存")

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
			# 越 scope 的地块（如战斗图上残留的 swamp）：其笔刷已被过滤隐藏，取色它会造成「无可见选中 + brush_index 越界」。
			# 拒绝取色、只提示——保留当前有效选中不动。
			if SCOPE_FILTER_ON and not TerrainDB.in_scope(e, map_type):
				set_status("「%s」不属于当前地图类型（%s），未取色" % [str(e.label), "大地图" if map_type == "overworld" else "战斗图"])
				return
			if i < brush_buttons.size():
				brush_buttons[i].button_pressed = true  # 触发 toggled -> select_brush
			set_status("取色：" + e.label)
			return
	set_status("该地块不在当前笔刷列表中")

# ------------------------------------------------------------------ 图层分派 + 区域

# 画布左键 → 按当前层：地形=画地形 / 区域=把格加入当前区域 / 线(路刷)=沿格连路 / 地点=放置或选中
# 线层的河/桥走边拾取入口 line_paint_edge（EditorCanvas 按 _line_mode 分流，不进这里）。
func primary_paint(col: int, row: int) -> void:
	if current_layer == "region":
		_region_paint(col, row, true)
	elif current_layer == "unit":
		_unit_paint(col, row)
	elif current_layer == "line":
		if _line_mode == "road":
			road_paint_cell(col, row)
	elif current_layer == "location":
		_loc_paint(col, row)
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

# 画布右键 → 按当前层：地形=取色 / 区域=从当前区域移除格 / 单位=删除该格单位 / 地点=删除地点
# 线层右键（擦边）走 line_paint_edge(add=false)，不进这里。
func secondary_paint(col: int, row: int) -> void:
	if current_layer == "region":
		_region_paint(col, row, false)
	elif current_layer == "unit":
		_remove_unit(col, row)
	elif current_layer == "location":
		_loc_remove(col, row)
	elif current_layer == "line":
		pass
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
		canvas.refresh_static()

func _on_region_selected(idx: int) -> void:
	_active_region_idx = idx
	if _region_color_btn and idx >= 0 and idx < regions.size():
		_region_color_btn.color = Color.html(str(regions[idx].get("color", "#FFFFFF")))
	_sync_region_kind_opt()
	if canvas:
		canvas.refresh_static()

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
		canvas.refresh_static()

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
		canvas.refresh_static()

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
		canvas.refresh_static()

# 颜色实时改（ColorPicker 拖动会高频触发 → 不入撤销栈、避免刷屏；只标脏）
func _on_region_color_changed(c: Color) -> void:
	var reg := active_region()
	if reg.is_empty():
		return
	reg["color"] = "#" + c.to_html(false)
	_dirty = true
	if canvas:
		canvas.refresh_static()

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
	map_type = "battle"          # 新图：回缺省战斗图
	map_locations = []           # 新图：清空地点
	map_rivers = []              # 新图：清空线特征
	map_roads = []
	map_bridges = []
	_active_region_idx = -1
	_active_loc_idx = -1
	current_path = ""
	_dirty = false
	if width_spin: width_spin.value = width
	if height_spin: height_spin.value = height
	if canvas: canvas.request_fit()
	_apply_map_type()
	_refresh_canvas()
	_refresh_region_list()
	_refresh_env_panel()
	_refresh_loc_list()
	_load_loc_form()
	_update_file_label()
	_refresh_map_highlight()
	set_status("新建地图 %d×%d" % [width, height])

func paint_cell(col: int, row: int) -> void:
	var tile = tiles[row][col]
	if _erase_object:
		# 橡皮·放置物：只清该格放置物，不动地形
		if not (tile is Dictionary and tile.has("object")):
			return
		tile.erase("object")
	else:
		var b = PALETTE[brush_index]
		if TerrainDB.is_object(b):
			# 放置物笔刷 → 写该格放置物层，保留底下地形
			var cur = tile.get("object")
			if typeof(cur) == TYPE_DICTIONARY and str(cur.get("terrain")) == str(b.terrain) and str(cur.get("variant")) == str(b.variant):
				return
			tile["object"] = {"terrain": b.terrain, "variant": b.variant}
		else:
			# 普通地形 → 写地形层，保留已有放置物
			if str(tile.get("terrain")) == str(b.terrain) and str(tile.get("variant")) == str(b.variant):
				return
			var keep = tile.get("object")
			var nt := {"terrain": b.terrain, "variant": b.variant}
			if keep != null:
				nt["object"] = keep
			tiles[row][col] = nt
	_stroke_dirty = true
	_stroke_count += 1
	_dirty = true
	if canvas:
		canvas.refresh_cell(col, row)   # 只重画该格所在块（+邻块过渡边），不重画整张 → 大图涂格不卡（§7 分块）

# 画布查表（未知地形 -> 品红，便于发现数据异常）；统一走 TerrainDB 的 O(1) 查表
func color_for_tile(tile) -> Color:
	return TerrainDB.color_of(tile)

func decor_for_tile(tile) -> String:
	return TerrainDB.decor_of(tile)

func accent_for_tile(tile) -> Color:
	return TerrainDB.accent_of(tile)

# 左下角悬停信息：坐标 + 地块标签/类型/外观/tags
# 左下角悬停信息：结合战斗版（地形/可通行性/特殊效果）与编辑器版（tag汉化/区域/地点/线特征）。
# 通行性·效果·tag汉化 走 TerrainDB 共用文案单一实现（与战斗侧同源）。
func hover_text(col: int, row: int) -> String:
	if row < 0 or row >= tiles.size() or col < 0 or col >= tiles[row].size():
		return ""
	var t = tiles[row][col]
	var e = TerrainDB.entry_for(t)
	var label := str(e.label) if e != null else "未知"
	var base := "地形：%s（%d, %d）" % [label, col, row]
	base += "\n可通行性：%s" % TerrainDB.passability_text(TerrainDB.effective_move(t, map_terrain_overrides))
	base += "\n特殊效果：%s" % TerrainDB.effects_text(e)
	var tcn := TerrainDB.tags_cn(e)
	if tcn != "":
		base += "\ntags：%s" % tcn
	var rtxt := _regions_at(col, row)
	if rtxt != "":
		base += "\n区域：" + rtxt
	var li := _loc_index_at(col, row)
	if li >= 0:
		base += "\n地点：%s（%s）" % [str(map_locations[li].get("label", "")), str(map_locations[li].get("id", ""))]
	var ln := _line_summary_at(col, row)
	if ln != "":
		base += "\n" + ln
	return base

# 该格六条边上的线特征概览（悬停信息）：如「河边×2 · 路×1 · 桥×1」
func _line_summary_at(col: int, row: int) -> String:
	var cell := Vector2i(col, row)
	var nr := 0
	var nd := 0
	var nb := 0
	for nbr in HexGrid.neighbors(cell):
		if _feature_has_edge(map_rivers, cell, nbr):
			nr += 1
		if _feature_has_edge(map_roads, cell, nbr):
			nd += 1
		if _pair_index(map_bridges, cell, nbr) >= 0:
			nb += 1
	var parts := []
	if nr > 0:
		parts.append("河边×%d" % nr)
	if nd > 0:
		parts.append("路×%d" % nd)
	if nb > 0:
		parts.append("桥×%d" % nb)
	return " · ".join(parts)

func _refresh_canvas() -> void:
	if canvas:
		canvas.refresh_static()

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
	return {"width": width, "height": height, "tiles": _copy_tiles(tiles), "regions": _copy_regions(regions), "map_units": _copy_map_units(map_units), "map_triggers": _copy_map_triggers(map_triggers), "map_terrain_overrides": map_terrain_overrides.duplicate(true), "map_environment": map_environment.duplicate(true), "map_type": map_type, "map_locations": map_locations.duplicate(true), "map_rivers": map_rivers.duplicate(true), "map_roads": map_roads.duplicate(true), "map_bridges": map_bridges.duplicate(true)}

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
			var nc := {"terrain": cell.terrain, "variant": cell.variant}
			var obj = cell.get("object")   # 放置物层随撤销快照一起拷——否则任一撤销会连同全图放置物一起抹掉
			if typeof(obj) == TYPE_DICTIONARY:
				nc["object"] = obj.duplicate(true)
			line.append(nc)
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
	map_type = str(snap.get("map_type", map_type))
	map_locations = snap.get("map_locations", map_locations)
	map_rivers = snap.get("map_rivers", map_rivers)
	map_roads = snap.get("map_roads", map_roads)
	map_bridges = snap.get("map_bridges", map_bridges)
	_active_region_idx = clampi(_active_region_idx, -1, regions.size() - 1)
	_active_trigger_idx = clampi(_active_trigger_idx, -1, map_triggers.size() - 1)
	_active_loc_idx = clampi(_active_loc_idx, -1, map_locations.size() - 1)
	if width_spin: width_spin.value = width
	if height_spin: height_spin.value = height
	_apply_map_type()         # map_type 可能随快照回退 → 同步顶栏下拉/笔刷过滤/层门禁
	_refresh_canvas()
	_refresh_region_list()
	_refresh_env_panel()      # 撤销/重做后同步环境面板
	_refresh_terrain_data()   # 覆盖变了 → 刷新地形数据编辑区（若在本图范围）
	if _trigger_panel != null and _trigger_panel.visible:
		_refresh_trigger_list()
		_load_trigger_form()
	if _loc_panel != null and _loc_panel.visible:
		_refresh_loc_list()
		_load_loc_form()

func begin_stroke() -> void:
	_stroke_snapshot = _snapshot()
	_stroke_dirty = false
	_stroke_count = 0
	_unit_stroke_action = ""   # 单位层：新一次拖动重置动作锁（第一格再定 编辑/落子）
	_road_last_cell = Vector2i(-1, -1)   # 路刷：新一次拖动重起连线
	_loc_stroke_placed = false           # 地点层：place 模式一次拖动只放一个
	_loc_stroke_action = ""              # 地点层：新一次拖动重置动作锁（首格再定 选中/放置）

func end_stroke() -> void:
	if _stroke_dirty and _stroke_snapshot != null:
		var lbl := ""
		match current_layer:
			"region": lbl = "区域编辑"
			"unit": lbl = "单位编辑"
			"line": lbl = "线特征编辑"
			"location": lbl = "地点编辑"
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
	return MapIO.to_dict(width, height, tiles, _map_opts())

# 存盘/试玩共用的 MapIO opts 包（字段清单唯一处）
func _map_opts() -> Dictionary:
	return {"regions": _regions_to_json(), "units": map_units, "triggers": map_triggers,
		"terrain_overrides": map_terrain_overrides, "environment": map_environment,
		"map_type": map_type, "locations": map_locations,
		"rivers": map_rivers, "roads": map_roads, "bridges": map_bridges}

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
	if not MapIO.write_map(path, width, height, tiles, _map_opts()):
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
	map_type = str(res.get("map_type", "battle"))   # 地图类型（顶栏可切换；决定笔刷过滤/层门禁）
	map_locations = res.get("locations", [])   # 地点实例（地点层可编辑）
	map_rivers = res.get("rivers", [])   # 线特征（线特征层可编辑）
	map_roads = res.get("roads", [])
	map_bridges = res.get("bridges", [])
	_active_region_idx = -1 if regions.is_empty() else 0
	_active_loc_idx = -1
	current_path = path
	_dirty = false
	if width_spin: width_spin.value = width
	if height_spin: height_spin.value = height
	if canvas: canvas.request_fit()
	_apply_map_type()         # 同步顶栏下拉/笔刷 scope 过滤/线·地点层门禁
	_refresh_canvas()
	_refresh_region_list()
	_refresh_env_panel()      # 载入后同步环境面板
	_refresh_loc_list()
	_load_loc_form()
	_update_file_label()
	_refresh_map_highlight()
	set_status("已加载：%s (%d×%d)" % [path, width, height])
