extends Control
## ListEditorShell：数据清单编辑器的通用 CRUD 外壳（基类）。
## ItemEditor / CharacterEditor / SkillEditor 继承本类，只实现 _shell_* 钩子；表单/预览等专属内容归子类。
## 外壳承担（原两编辑器 250+ 行逐字重复的收敛处）：
##   · 布局骨架：深色主题+背景 / 标题栏+返回主菜单（带脏守卫）/ 左清单｜右内容 HSplit / 底栏（信息+另存副本+保存）
##   · 左清单：＋新建 / 🔍搜索 / 折叠分组（折叠态跨刷新保留）/ 行卡片（图标+名/id 两行）/ 金框选中+滚动定位 / 删除选中
##   · CRUD 流程：保存（id 空/字符/撞库三验 + 改名 replace_id 语义）/ 删除（确认框）/ 另存副本（id 唯一化）/ 脏守卫 / Ctrl+S
## 子类必须实现：_shell_title / _shell_new_label / _shell_build_right / _shell_populate_list /
##   _shell_new_entry / _shell_load / _shell_collect / _shell_exists / _shell_db_save / _shell_db_delete /
##   _shell_after_save / _shell_open_as_new / _shell_show_empty / _shell_has_entry / _shell_delete_confirm_text
## ⚠ 子类勿再声明本文件已有的 const/var（GDScript 成员重定义报错）；EditorTheme/EditorUI/TextureCache 由此继承。

const EditorTheme := preload("res://EditorTheme.gd")
const EditorUI := preload("res://EditorUI.gd")
const TextureCache := preload("res://TextureCache.gd")

# —— 外壳状态 ——
var _is_new := false
var _loaded_id := ""          # 载入时的 id（改名判定：保存时 id≠此值 → replace_id 换名而非复制）
var _dirty := false           # 有未保存改动（切换/新建/删除/返回前确认）
var _rows: Dictionary = {}    # id -> 行 Button（选中高亮 / 滚动定位）
var _selected_id := ""        # 当前高亮 id（"" = 无）
var _fold_collapsed: Dictionary = {}   # 分组 key -> 折叠态（跨刷新保留）

# —— 外壳控件 ——
var _list_scroll: ScrollContainer
var _list_root: VBoxContainer
var _search: LineEdit
var _msg: Label
var _save_btn: Button
var _dup_btn: Button
var _del_btn: Button


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = EditorTheme.build()
	add_child(EditorUI.background())
	_shell_init()   # 子类前置状态（建 UI 前需要的数据准备）

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 20
	root.offset_top = 14
	root.offset_right = -20
	root.offset_bottom = -14
	root.add_theme_constant_override("separation", 10)
	add_child(root)

	var titlebar := HBoxContainer.new()
	titlebar.add_theme_constant_override("separation", 12)
	var title := Label.new()
	title.text = _shell_title()
	title.add_theme_font_size_override("font_size", 26)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titlebar.add_child(title)
	var back := Button.new()
	back.text = "返回主菜单"
	back.custom_minimum_size = Vector2(120, 0)
	# 返回也走未保存守卫（否则静默丢改动）
	back.pressed.connect(func(): _confirm_discard(func(): get_tree().change_scene_to_file("res://StartMenu.tscn")))
	titlebar.add_child(back)
	root.add_child(titlebar)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.split_offset = _shell_split_offset()
	root.add_child(split)
	split.add_child(_build_left_pane())
	_shell_build_right(split)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 12)
	_msg = Label.new()
	_msg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_msg.add_theme_color_override("font_color", Color(0.72, 0.78, 0.86))
	bottom.add_child(_msg)
	_dup_btn = Button.new()
	_dup_btn.text = "另存副本"
	_dup_btn.custom_minimum_size = Vector2(110, 38)
	_dup_btn.disabled = true
	_dup_btn.tooltip_text = "以当前内容复制出一份新条目（id 自动加 _copy）"
	_dup_btn.pressed.connect(_on_duplicate)
	bottom.add_child(_dup_btn)
	_save_btn = Button.new()
	_save_btn.text = "保存 ⤓ (Ctrl+S)"
	_save_btn.custom_minimum_size = Vector2(150, 38)
	_save_btn.disabled = true
	_save_btn.pressed.connect(_on_save)
	bottom.add_child(_save_btn)
	root.add_child(bottom)

	_refresh_list()
	_shell_show_empty()


func _build_left_pane() -> Control:
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(_shell_left_min_width(), 0)
	box.add_theme_constant_override("separation", 8)
	var newbtn := Button.new()
	newbtn.text = _shell_new_label()
	newbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	newbtn.pressed.connect(func(): _confirm_discard(_shell_new_entry))
	box.add_child(newbtn)
	_search = LineEdit.new()
	_search.placeholder_text = "🔍 搜 id / 名字"
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_t): _refresh_list())
	box.add_child(_search)
	_list_scroll = ScrollContainer.new()
	_list_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_list_root = VBoxContainer.new()
	_list_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_root.add_theme_constant_override("separation", 4)
	_list_scroll.add_child(_list_root)
	box.add_child(_list_scroll)
	_del_btn = Button.new()
	_del_btn.text = "删除选中"
	_del_btn.disabled = true
	_del_btn.pressed.connect(_on_delete)
	box.add_child(_del_btn)
	return box


# —— 清单：骨架（清空→子类填组→恢复高亮）；分组/排序/分隔逻辑归子类 _shell_populate_list ——
func _refresh_list() -> void:
	if _list_root == null or not is_instance_valid(_list_root):
		return
	for c in _list_root.get_children():
		c.queue_free()
	_rows = {}
	var q := (_search.text.strip_edges().to_lower() if _search != null else "")
	_shell_populate_list(q)
	if _selected_id != "" and _rows.has(_selected_id):
		_apply_row_selected(_rows[_selected_id], true)


# 折叠分组入清单（搜索中强制展开；折叠态按 key 跨刷新保留）
func _add_fold_group(key: String, title: String, section: Control, searching: bool) -> void:
	var collapsed := false if searching else bool(_fold_collapsed.get(key, false))
	var fold := EditorUI.make_foldable(title, section, collapsed, false,
		func(open): _fold_collapsed[key] = not open)
	_list_root.add_child(fold)


# 行卡片：图标 + 名字/id 两行；点击走守卫加载；建好后子类须自行 `_rows[id] = row`。
# name_color 传 null＝主题默认色；tex 传 null＝淡显占位。
func _make_row_card(id: String, tex, name_text: String, name_color, height: int, icon_size: Vector2, tooltip := "") -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, height)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.clip_contents = true
	if tooltip != "":
		b.tooltip_text = tooltip
	b.pressed.connect(func(): _on_row_click(id))
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 6)
	margin.add_theme_constant_override("margin_right", 6)
	var hb := HBoxContainer.new()
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_theme_constant_override("separation", 8)
	var icon := TextureRect.new()
	icon.custom_minimum_size = icon_size
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if tex != null:
		icon.texture = tex
	else:
		icon.modulate = Color(1, 1, 1, 0.2)   # 无图标：占位淡显
	hb.add_child(icon)
	var vb := VBoxContainer.new()
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	vb.add_theme_constant_override("separation", 0)
	var nm := Label.new()
	nm.text = name_text
	if name_color != null:
		nm.add_theme_color_override("font_color", name_color)
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	nm.clip_text = true
	vb.add_child(nm)
	var idl := Label.new()
	idl.text = id
	idl.add_theme_color_override("font_color", Color(0.55, 0.58, 0.64))
	idl.add_theme_font_size_override("font_size", 10)
	idl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	idl.clip_text = true
	vb.add_child(idl)
	hb.add_child(vb)
	margin.add_child(hb)
	b.add_child(margin)
	_apply_row_selected(b, id == _selected_id)
	return b


# 行选中/非选中样式（选中＝金框亮底；非选中＝中性深底 + 悬停微亮）——单一源，杜绝两套数值漂移。
func _apply_row_selected(b: Button, selected: bool) -> void:
	if b == null or not is_instance_valid(b):
		return
	if selected:
		var sel := EditorTheme.sb(Color(0.26, 0.30, 0.36), Color(1.0, 0.82, 0.30))
		sel.set_border_width_all(2)
		for s in ["normal", "hover", "pressed", "focus"]:
			b.add_theme_stylebox_override(s, sel)
	else:
		b.add_theme_stylebox_override("normal", EditorTheme.sb(Color(0.16, 0.17, 0.20), Color(0, 0, 0, 0)))
		b.add_theme_stylebox_override("hover", EditorTheme.sb(Color(0.22, 0.24, 0.28), Color(0, 0, 0, 0)))
		b.add_theme_stylebox_override("pressed", EditorTheme.sb(Color(0.24, 0.27, 0.32), Color(0, 0, 0, 0)))
		b.add_theme_stylebox_override("focus", EditorTheme.sb(Color(0.16, 0.17, 0.20), Color(0, 0, 0, 0)))


# 点行：已在编辑它＝忽略；否则守卫后加载（取消丢弃＝旧高亮原地保留）。
func _on_row_click(id: String) -> void:
	if id == _selected_id:
		return
	_confirm_discard(_shell_load.bind(id))


# 移动选中高亮到某 id（""＝清空），并滚动到可见。
func _select_row(id: String) -> void:
	if _selected_id != id and _rows.has(_selected_id):
		_apply_row_selected(_rows[_selected_id], false)
	_selected_id = id
	if id != "" and _rows.has(id):
		_apply_row_selected(_rows[id], true)
		if _list_scroll != null and is_instance_valid(_list_scroll):
			_list_scroll.ensure_control_visible(_rows[id])


# —— 保存 / 删除 / 副本 ——

func _on_save() -> void:
	if not _shell_has_entry():
		return
	var entry := _shell_collect()
	var id := str(entry.get("id", ""))
	if id == "":
		_err("id 不能为空")
		return
	if not _valid_id(id):
		_err("id 只能用 字母/数字/下划线（现为「%s」）" % id)
		return
	var renaming := (not _is_new) and _loaded_id != "" and id != _loaded_id
	if (_is_new or renaming) and _shell_exists(id):
		_err("id「%s」已存在，请换一个" % id)   # 改名撞已有 id 也拦：否则会静默覆盖别的条目
		return
	if not _shell_db_save(entry, _loaded_id if renaming else ""):
		_err("保存失败（文件被占用/只读？）")
		return
	_shell_after_save(entry, id, renaming)   # 子类：成功消息 + 专属状态更新（如 _current）
	_is_new = false
	_loaded_id = id
	_dirty = false
	_refresh_list()
	_select_row(id)
	_update_buttons()


func _on_delete() -> void:
	if _is_new or _loaded_id == "":
		return
	var id := _loaded_id
	EditorUI.confirm(self, _shell_delete_confirm_text(id),
		"删除", func(): _do_delete(id), Callable(), "确认删除")

func _do_delete(id: String) -> void:
	if not _shell_db_delete(id):
		_err("删除失败（文件被占用/只读？）")
		return
	_dirty = false
	_loaded_id = ""
	_is_new = false
	_refresh_list()
	_shell_show_empty()
	_update_buttons()
	_info("✓ 已删除「%s」" % id)


# 另存副本：当前内容 → 新条目（id 自动唯一化 _copy），进「新建未保存」态
func _on_duplicate() -> void:
	if not _shell_has_entry():
		return
	var entry := _shell_collect()
	entry["id"] = _unique_copy_id(str(entry.get("id", "entry")))
	entry["name"] = str(entry.get("name", "")) + "（副本）"
	_shell_open_as_new(entry)
	_select_row("")
	_dirty = true   # 副本＝未保存的新内容（须在 _shell_open_as_new 之后置——子类建表单常清脏标记）
	_update_buttons()
	_info("已生成副本「%s」——改好后保存" % str(entry["id"]))

func _unique_copy_id(base: String) -> String:
	var cand := base + "_copy"
	var i := 2
	while _shell_exists(cand):
		cand = "%s_copy%d" % [base, i]
		i += 1
	return cand


# 按当前编辑态刷新三按钮可用性（保存=有条目；副本=已保存条目；删除=在库条目）
func _update_buttons() -> void:
	var has := _shell_has_entry()
	if _save_btn != null and is_instance_valid(_save_btn):
		_save_btn.disabled = not has
	if _dup_btn != null and is_instance_valid(_dup_btn):
		_dup_btn.disabled = not has or _is_new
	if _del_btn != null and is_instance_valid(_del_btn):
		_del_btn.disabled = not has or _is_new or _loaded_id == ""


# —— 守卫 / 快捷键 / 校验 / 消息 ——

# 未保存改动守卫：干净直接执行；脏则弹确认（丢弃→on_ok / 留下→on_cancel）
func _confirm_discard(on_ok: Callable, on_cancel := Callable()) -> void:
	EditorUI.confirm_discard(self, _dirty, on_ok, on_cancel,
		_shell_discard_text(), "丢弃修改", "留下")

# Ctrl+S 保存（表单激活时）
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_S and event.ctrl_pressed:
		if _save_btn != null and is_instance_valid(_save_btn) and not _save_btn.disabled:
			_on_save()
		get_viewport().set_input_as_handled()

func _valid_id(id: String) -> bool:
	if id == "":
		return false
	for i in id.length():
		var c := id.unicode_at(i)
		if not ((c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95):
			return false
	return true

func _mark_dirty() -> void:
	_dirty = true

func _info(text: String) -> void:
	if _msg == null or not is_instance_valid(_msg):
		return
	_msg.add_theme_color_override("font_color", Color(0.72, 0.78, 0.86))
	_msg.text = text

func _err(text: String) -> void:
	if _msg == null or not is_instance_valid(_msg):
		return
	_msg.add_theme_color_override("font_color", Color(0.92, 0.5, 0.45))
	_msg.text = "✗ " + text


# OptionButton 按 metadata 选中；找不到＝回退第一个有效项（跳过分隔/占位 null）
func _select_meta(ob: OptionButton, key) -> void:
	for i in ob.item_count:
		var m = ob.get_item_metadata(i)
		if m != null and str(m) == str(key):
			ob.select(i)
			return
	for i in ob.item_count:
		if not ob.is_item_disabled(i) and ob.get_item_metadata(i) != null:
			ob.select(i)
			return


# —— 子类钩子（override）——

func _shell_init() -> void:                                   # 建 UI 前的数据准备
	pass

func _shell_title() -> String:                                # 标题栏文字
	return "编辑器"

func _shell_new_label() -> String:                            # ＋新建按钮文字
	return "＋ 新建"

func _shell_split_offset() -> int:                            # 左右分割位置
	return 300

func _shell_left_min_width() -> int:                          # 左清单最小宽
	return 300

func _shell_discard_text() -> String:                         # 脏守卫提示语
	return "当前条目有未保存的修改，继续将丢弃。"

func _shell_build_right(_split: HSplitContainer) -> void:     # 右侧内容（表单/预览/卡片）
	push_error("ListEditorShell 子类须实现 _shell_build_right")

func _shell_populate_list(_query: String) -> void:            # 填清单（分组/排序/行卡入 _rows）
	push_error("ListEditorShell 子类须实现 _shell_populate_list")

func _shell_show_empty() -> void:                             # 空态（未选任何条目）
	pass

func _shell_new_entry() -> void:                              # ＋新建（守卫已过）
	pass

func _shell_load(_id: String) -> void:                        # 载入条目（守卫已过）
	pass

func _shell_has_entry() -> bool:                              # 当前是否有编辑对象
	return false

func _shell_collect() -> Dictionary:                          # 表单 → 条目 dict
	return {}

func _shell_exists(_id: String) -> bool:                      # 库里是否已有该 id
	return false

func _shell_db_save(_entry: Dictionary, _replace_id: String) -> bool:   # 写库（replace_id≠""＝改名）
	return false

func _shell_db_delete(_id: String) -> bool:                   # 删库
	return false

func _shell_after_save(_entry: Dictionary, _id: String, _renaming: bool) -> void:   # 成功消息+专属状态
	pass

func _shell_open_as_new(_entry: Dictionary) -> void:          # 副本以「新建未保存」态打开
	pass

func _shell_delete_confirm_text(id: String) -> String:        # 删除确认语
	return "确认删除「%s」？此操作直接写盘。" % id
