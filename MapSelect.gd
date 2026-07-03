extends Control
## 选地图（沙盒模式）：列出 maps/*.json，选一张 → 写入 SandboxConfig.map_path → 进入沙盒。
## 目录扫描照搬地图编辑器「地图库」那套（DirAccess.list_dir）。

const SandboxConfig := preload("res://SandboxConfig.gd")
const MapIO := preload("res://MapIO.gd")
const MAP_DIR := "res://maps"

var _list: ItemList
var _paths := []        # 与 _list 行一一对应的完整路径
var _info: Label

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 24
	root.offset_top = 18
	root.offset_right = -24
	root.offset_bottom = -18
	root.add_theme_constant_override("separation", 10)
	add_child(root)

	var title := Label.new()
	title.text = "选择地图　·　沙盒模式"
	title.add_theme_font_size_override("font_size", 28)
	root.add_child(title)

	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.item_activated.connect(func(_i): _confirm())   # 双击直接进
	root.add_child(_list)

	_info = Label.new()
	_info.add_theme_color_override("font_color", Color(0.72, 0.76, 0.84))
	root.add_child(_info)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 10)
	var back := Button.new()
	back.text = "返回"
	back.custom_minimum_size = Vector2(120, 40)
	back.pressed.connect(func(): get_tree().change_scene_to_file("res://StartMenu.tscn"))
	bar.add_child(back)
	var ok := Button.new()
	ok.text = "进入沙盒 ▶"
	ok.custom_minimum_size = Vector2(0, 40)
	ok.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ok.pressed.connect(_confirm)
	bar.add_child(ok)
	root.add_child(bar)

	_scan()

func _scan() -> void:
	_list.clear()
	_paths.clear()
	var dir := DirAccess.open(MAP_DIR)
	if dir == null:
		_info.text = "找不到地图文件夹：%s（可用地图编辑器创建地图）" % MAP_DIR
		return
	var names := []
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		# 大地图（map_type=overworld）不进沙盒列表——沙盒＝战斗测试场，大地图从主菜单「战役」进
		if not dir.current_is_dir() and f.to_lower().ends_with(".json") \
				and MapIO.peek_type(MAP_DIR + "/" + f) != "overworld":
			names.append(f)
		f = dir.get_next()
	dir.list_dir_end()
	names.sort()
	for n in names:
		_paths.append(MAP_DIR + "/" + n)
		_list.add_item(n)
	if names.is_empty():
		_info.text = "（该文件夹暂无地图，可用地图编辑器创建；也可直接进入用默认地图）"
	else:
		_list.select(0)
		_info.text = "共 %d 张地图　·　双击进入" % names.size()

func _confirm() -> void:
	var sel := _list.get_selected_items()
	SandboxConfig.map_path = _paths[sel[0]] if sel.size() > 0 else ""   # 空也行：沙盒回退默认图
	get_tree().change_scene_to_file("res://Sandbox.tscn")
