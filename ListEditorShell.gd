extends Control
## ListEditorShell：数据清单编辑器的通用 CRUD 外壳（基类）。
## ItemEditor / CharacterEditor / SkillEditor 继承本类，只实现 _shell_* 钩子；表单/预览等专属内容归子类。
## 外壳承担（原两编辑器 250+ 行逐字重复的收敛处）：
##   · 布局骨架：深色主题+背景 / 标题栏+返回主菜单（带脏守卫）/ 左清单｜右内容 HSplit / 底栏（信息+另存副本+保存）
##   · 左清单：＋新建 / 🔍搜索 / 折叠分组（折叠态跨刷新保留）/ 行卡片（图标+名/id 两行）/ 金框选中+滚动定位 / 删除选中
##   · CRUD 流程：保存（id 空/字符/撞库三验 + 改名 replace_id 语义）/ 删除（确认框）/ 另存副本（id 唯一化）/ 脏守卫 / Ctrl+S
##   · 横切便利（编辑器优化提案 2026-07-13）：§9 会话状态持久（user://editor_state.cfg 按场景分节：
##     选中/搜索词/折叠态——_exit_tree 存、_ready 恢复；测试缝 _state_path_override 防写真档）/
##     §14 脏可见（保存钮 ● 前缀 + 底栏「↺ 还原」从库重载）/ §15 键盘导航（Ctrl+N 新建 / Ctrl+D 副本 /
##     Ctrl+F 搜索 / Ctrl+↑↓ 换条目 / Delete 删除——走 _unhandled_key_input，焦点在文本输入不抢键）/
##     §18 删除/改名反向引用感知（可选钩子 _shell_referenced_by 拼进确认文案，不硬拦）
## 子类必须实现：_shell_title / _shell_new_label / _shell_build_right / _shell_populate_list /
##   _shell_new_entry / _shell_load / _shell_collect / _shell_exists / _shell_db_save / _shell_db_delete /
##   _shell_after_save / _shell_open_as_new / _shell_show_empty / _shell_has_entry / _shell_delete_confirm_text
## ⚠ 子类勿再声明本文件已有的 const/var（GDScript 成员重定义报错）；EditorTheme/EditorUI/TextureCache 由此继承。

const EditorTheme := preload("res://EditorTheme.gd")
const EditorUI := preload("res://EditorUI.gd")
const TextureCache := preload("res://TextureCache.gd")

const STATE_PATH := "user://editor_state.cfg"   # §9 会话状态档（按场景分节：选中/搜索词/折叠态）
static var _state_path_override := ""           # 测试缝（仿 DB _path_override）：headless 测试指临时路径，绝不写真档

# —— 外壳状态 ——
var _is_new := false
var _loaded_id := ""          # 载入时的 id（改名判定：保存时 id≠此值 → replace_id 换名而非复制）
var _dirty := false:          # 有未保存改动（切换/新建/删除/返回前确认）；setter 联动 §14 脏可见 UI
	set(v):
		_dirty = v
		_update_dirty_ui()
var _rows: Dictionary = {}    # id -> 行 Button（选中高亮 / 滚动定位；插入序＝清单显示序，Ctrl+↑↓ 依赖）
var _selected_id := ""        # 当前高亮 id（"" = 无）
var _fold_collapsed: Dictionary = {}   # 分组 key -> 折叠态（跨刷新保留；§9 随会话状态持久）

# —— 外壳控件 ——
var _list_scroll: ScrollContainer
var _list_root: VBoxContainer
var _search: LineEdit
var _msg: Label
var _save_btn: Button
var _revert_btn: Button
var _dup_btn: Button
var _del_btn: Button


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = EditorTheme.build()
	add_child(EditorUI.background())
	# 关窗（X / Alt+F4）也走脏守卫（审查修复）：默认 auto_accept_quit 直接退出＝静默丢改动的唯一残留路径。
	# null 守卫：headless 测试 new() 不进树直调 _ready（本仓测试范式），get_tree() 为 null。
	if get_tree() != null:
		get_tree().auto_accept_quit = false
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
	_shell_titlebar_extras(titlebar)   # 子类可注入切换器等（返回按钮之前）
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
	_revert_btn = Button.new()
	_revert_btn.text = "↺ 还原"
	_revert_btn.custom_minimum_size = Vector2(96, 38)
	_revert_btn.disabled = true
	_revert_btn.tooltip_text = "丢弃当前条目未保存的修改，从库里重新载入（有确认）"
	_revert_btn.pressed.connect(_on_revert)
	bottom.add_child(_revert_btn)
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

	# §9 会话状态恢复：搜索词/折叠态须在清单构建前回填（程序赋值不发 text_changed，不会双刷）；
	# 选中恢复在清单构建后。headless 测试 new() 不进树直调 _ready＝不吃状态档（is_inside_tree 判、
	# 无 get_tree 噪音），持久化逻辑测试经 _state_path_override + 手调 _state_save/_state_restore_ui 覆盖。
	var restore_id := ""
	if is_inside_tree():
		restore_id = _state_restore_ui()
	_refresh_list()
	_shell_show_empty()
	if restore_id != "" and _shell_exists(restore_id):
		_shell_load(restore_id)

func _exit_tree() -> void:
	_state_save()   # §9 会话状态持久：切场景（Skill⇄Effect/返回主菜单）与关窗退出统一经此
	if get_tree() != null:
		get_tree().auto_accept_quit = true   # 还原默认（防污染主菜单/其他场景的关窗行为）

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_confirm_discard(func(): get_tree().quit())   # 净态直接放行（confirm_discard 内判 _dirty）


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
	if entry.is_empty():
		return   # 收集/校验失败——子类已 _err 报因，此处静默中止
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
	# §18 改名引用感知：改名前按旧 id 查引用者（引用数据不随本次保存变，先后皆可——取存前语义最清晰）
	var old_refs: Array[String] = _shell_referenced_by(_loaded_id) if renaming else ([] as Array[String])
	if not _shell_db_save(entry, _loaded_id if renaming else ""):
		_err("保存失败（文件被占用/只读？）")
		return
	_shell_after_save(entry, id, renaming)   # 子类：成功消息 + 专属状态更新（如 _current）
	if not old_refs.is_empty() and _msg != null and is_instance_valid(_msg):
		_msg.text += "　⚠ %d 处引用仍指旧 id（不自动改写，需手动同步）" % old_refs.size()
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
	EditorUI.confirm(self, _delete_confirm_full_text(id),
		"删除", func(): _do_delete(id), Callable(), "确认删除")

# §18 删除确认文案＝子类文案 + 反向引用警示段（非空时；只警示不硬拦——创作期防呆，lint 另做数据侧兜底）
func _delete_confirm_full_text(id: String) -> String:
	var text := _shell_delete_confirm_text(id)
	var refs := _shell_referenced_by(id)
	if refs.is_empty():
		return text
	var shown := refs.slice(0, 8)   # 上限防超长引用列表撑爆弹窗
	var lines := "\n".join(shown)
	if refs.size() > shown.size():
		lines += "\n…等 %d 处" % refs.size()
	return "%s\n\n⚠ 被 %d 处引用（删除后成悬空引用，lint 会红）：\n%s" % [text, refs.size(), lines]

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
	if entry.is_empty():
		return   # 收集/校验失败——子类已 _err 报因
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


# 按当前编辑态刷新按钮可用性（保存=有条目；副本=已保存条目；删除/还原=在库条目）
func _update_buttons() -> void:
	var has := _shell_has_entry()
	if _save_btn != null and is_instance_valid(_save_btn):
		_save_btn.disabled = not has
	if _dup_btn != null and is_instance_valid(_dup_btn):
		_dup_btn.disabled = not has or _is_new
	if _del_btn != null and is_instance_valid(_del_btn):
		_del_btn.disabled = not has or _is_new or _loaded_id == ""
	_update_dirty_ui()

# §14 脏状态可见：保存钮 ● 前缀；还原钮只在「在库条目 + 有未存改动」时可用。
# 由 _dirty setter 与 _update_buttons 双触发（前者管脏变化、后者管条目切换——两处状态源都盖到）。
func _update_dirty_ui() -> void:
	if _save_btn != null and is_instance_valid(_save_btn):
		_save_btn.text = ("● " if _dirty else "") + "保存 ⤓ (Ctrl+S)"
	if _revert_btn != null and is_instance_valid(_revert_btn):
		_revert_btn.disabled = not _dirty or _is_new or _loaded_id == ""

# §14 还原：确认后丢弃未存改动、从库重载当前条目（_shell_load 重建表单自会清回干净基线）
func _on_revert() -> void:
	if _is_new or _loaded_id == "" or not _dirty:
		return
	var id := _loaded_id
	EditorUI.confirm(self, "确认还原「%s」？将丢弃未保存的修改，从库里重新载入。" % id,
		"还原", func():
			_shell_load(id)
			_info("↺ 已还原「%s」（库里最后保存的版本）" % id), Callable(), "确认还原")


# —— 守卫 / 快捷键 / 校验 / 消息 ——

# 未保存改动守卫：干净直接执行；脏则弹确认（丢弃→on_ok / 留下→on_cancel）
func _confirm_discard(on_ok: Callable, on_cancel := Callable()) -> void:
	EditorUI.confirm_discard(self, _dirty, on_ok, on_cancel,
		_shell_discard_text(), "丢弃修改", "留下")

# Ctrl+S 保存（表单激活时；走 _input＝焦点在文本框也存——既有行为勿破）
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_S and event.ctrl_pressed:
		if _save_btn != null and is_instance_valid(_save_btn) and not _save_btn.disabled:
			_on_save()
		get_viewport().set_input_as_handled()

# §15 键盘导航（Ctrl+S 除外，见上）：走 _unhandled_key_input——焦点控件先消费，文本输入天然不被抢键
# （MapEditor 数字键/AppearanceWorkshop 绘制键同判定法）；Delete/Ctrl+↑↓ 另加焦点显式守卫双保险
# （空 LineEdit 的 Delete、TextEdit 的 Ctrl+↑↓ 滚动是否吞键因控件态而异，不赌）。
func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var e := event as InputEventKey
	if e.ctrl_pressed:
		match e.keycode:
			KEY_N:   # 新建（同＋新建钮：走脏守卫）
				_confirm_discard(_shell_new_entry)
				accept_event()
			KEY_D:   # 另存副本（绑既有另存动作；未保存新条目时禁用同按钮）
				if _dup_btn != null and is_instance_valid(_dup_btn) and not _dup_btn.disabled:
					_on_duplicate()
				accept_event()
			KEY_F:   # 聚焦搜索框
				if _search != null and is_instance_valid(_search) and _search.is_inside_tree():
					_search.grab_focus()
					_search.select_all()
				accept_event()
			KEY_UP:
				if not _text_input_focused():
					_nav_row(-1)
					accept_event()
			KEY_DOWN:
				if not _text_input_focused():
					_nav_row(1)
					accept_event()
	elif e.keycode == KEY_DELETE and not _text_input_focused():
		if _del_btn != null and is_instance_valid(_del_btn) and not _del_btn.disabled:
			_on_delete()   # 走既有删除确认（§18 引用警示一并生效）
		accept_event()

func _text_input_focused() -> bool:
	if not is_inside_tree():
		return false
	var f := get_viewport().gui_get_focus_owner()
	return f is LineEdit or f is TextEdit   # SpinBox 内嵌 LineEdit 聚焦时也命中

# §15 Ctrl+↑/↓：按清单显示序上下移选（_rows 插入序＝显示序；折叠组内隐藏行跳过）；
# 经 _on_row_click 换条目＝复用脏守卫，取消丢弃则原地不动。
func _nav_row(delta: int) -> void:
	var ids: Array[String] = []
	for id in _rows:
		var b = _rows[id]
		if b != null and is_instance_valid(b) and (not b.is_inside_tree() or b.is_visible_in_tree()):
			ids.append(str(id))
	if ids.is_empty():
		return
	var i := ids.find(_selected_id)
	var j := (0 if delta > 0 else ids.size() - 1) if i < 0 else clampi(i + delta, 0, ids.size() - 1)
	if ids[j] != _selected_id:
		_on_row_click(ids[j])


# —— §9 会话状态持久（user://editor_state.cfg，ConfigFile 按场景分节）——

func _state_path() -> String:
	return _state_path_override if _state_path_override != "" else STATE_PATH

func _state_section() -> String:   # 分节键＝子类脚本文件名（ItemEditor/SkillEditor/…；场景互切各回各的状态）
	var sp := str(get_script().resource_path)
	return sp.get_file().get_basename() if sp != "" else "editor"

func _state_save() -> void:
	var cf := ConfigFile.new()
	cf.load(_state_path())   # 加载失败＝首份/损坏：从空档开始（别的场景节丢了也只是回默认，无害）
	var sec := _state_section()
	cf.set_value(sec, "selected_id", _selected_id)
	cf.set_value(sec, "search", _search.text if (_search != null and is_instance_valid(_search)) else "")
	cf.set_value(sec, "folds", _fold_collapsed)
	cf.save(_state_path())

# 回填搜索词/折叠态（须在 _refresh_list 前调），返回待恢复的选中 id（""＝无；调用方在清单构建后 _shell_load）
func _state_restore_ui() -> String:
	var cf := ConfigFile.new()
	if cf.load(_state_path()) != OK:
		return ""
	var sec := _state_section()
	var folds = cf.get_value(sec, "folds", {})
	if typeof(folds) == TYPE_DICTIONARY:
		_fold_collapsed = folds
	if _search != null and is_instance_valid(_search):
		_search.text = str(cf.get_value(sec, "search", ""))
	return str(cf.get_value(sec, "selected_id", ""))

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


# 载入引用不在下拉（条目被删/被新过滤规则挡）→ 补「⚠ 悬空引用」项保值（技改 §3-1 上提外壳）：
# 否则 _select_meta 静默回退首项，随手保存＝剥掉数据里的引用（唯一「无声数据损坏」路径）。
# 用法：凡「下拉存引用 id」的位，_select_meta 前先调本函数。lint 会另行标红悬空数据。
func _ensure_meta_option(ob: OptionButton, key: String) -> void:
	if key == "":
		return
	for i in ob.item_count:
		var m = ob.get_item_metadata(i)
		if m != null and str(m) == key:
			return
	ob.add_item("⚠ 悬空引用：%s" % key)
	ob.set_item_metadata(ob.item_count - 1, key)

# OptionButton 按 metadata 选中；实现上收 EditorUI.select_meta（单一实现，when 行/裸下拉同用）
func _select_meta(ob: OptionButton, key) -> void:
	EditorUI.select_meta(ob, key)


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

func _shell_titlebar_extras(_titlebar: HBoxContainer) -> void: # 标题栏附加控件（切换器等）
	pass

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

# §18 可选钩子：谁在引用该 id（每行一个引用者描述，如「原型「强盗」(bandit)：装备 equip」）。
# 删除确认与改名保存时消费；返回空＝不感知（CharacterEditor：地图 units 内嵌 proto 是快照非 id 引用，不算）。
func _shell_referenced_by(_id: String) -> Array[String]:
	return []
