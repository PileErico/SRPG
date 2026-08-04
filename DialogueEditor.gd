extends Control
## 对话编辑器（M8 编辑侧）：data/dialogues.json 可视化编辑——对话列表 / 节点序列 / 节点表单
## （说话人/左右侧/立绘/文本/推进目标），选项分支（文本/跳转/结果动作——EventEngine 动作注册表
## 与触发器 do 同一张表：给物品/给钱/设flag/改声望/开战斗…新动作登记引擎即自动出现）。
## 双宿主：StartMenu 独立场景（返回主菜单）/ MapEditor 触发器「开对话 ✎」浮层内嵌（embedded=true，关闭发 closed）。
## 保存＝DialogueDB.save 写回（保留顶层 _note/format_version）；脏跟踪＋离开守卫（与地形数据 §19 同语义）。
## 节点 id 改名＝自动同步全对话内 next/choices.next 引用；nodes[0] 恒为首节点（上移到顶＝改开场）。

signal closed

const DialogueDB := preload("res://DialogueDB.gd")
const EventEngine := preload("res://EventEngine.gd")
const EditorUI := preload("res://EditorUI.gd")
const EditorTheme := preload("res://EditorTheme.gd")
const TextureCache := preload("res://TextureCache.gd")

var embedded := false   # 浮层模式（MapEditor 内嵌）：顶栏显「关闭」、不换场景

var _sel := -1          # 选中对话下标（DialogueDB.all_dialogues() live 列表）
var _node_sel := -1     # 选中节点下标
var _dirty := false
var _filter := ""
var _pending_select := ""   # select_dialogue 先于 _ready 被调时暂存

var _list: ItemList
var _filter_box: LineEdit
var _node_list: ItemList
var _dlg_head: VBoxContainer    # 对话级 id/label 表单（重建式）
var _node_form: VBoxContainer   # 节点表单（重建式）
var _msg: Label
var _save_btn: Button
var _file_dlg: FileDialog       # 立绘选择（懒建）

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP   # 浮层模式：吞输入，底下的编辑器不响应
	add_child(EditorUI.background())
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 6)
	add_child(root)
	root.add_child(_titlebar())
	var split := HSplitContainer.new()
	split.split_offset = 340
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(_build_left())
	split.add_child(_build_right())
	root.add_child(split)
	_refresh_list()
	if _pending_select != "":
		select_dialogue(_pending_select)
		_pending_select = ""
	elif _list.item_count > 0:
		_pick(0)

# 外部定位（触发器 ✎ 带当前对话进来）；early 调用（未进树）暂存，_ready 后生效
func select_dialogue(id: String) -> void:
	if _list == null:
		_pending_select = id
		return
	var dlgs: Array = DialogueDB.all_dialogues()
	for i in dlgs.size():
		if str(dlgs[i].get("id", "")) == id:
			_pick(i)
			return

# ============ 顶栏 / 左栏 ============

func _titlebar() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", EditorTheme.sb(Color(0.13, 0.14, 0.17), Color(0.26, 0.29, 0.35)))
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 10)
	var title := Label.new()
	title.text = "  💬 对话编辑器"
	title.add_theme_font_size_override("font_size", 22)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(title)
	_save_btn = Button.new()
	_save_btn.pressed.connect(_on_save)
	bar.add_child(_save_btn)
	_update_save_btn()
	var back := Button.new()
	back.text = "关闭" if embedded else "返回主菜单"
	back.pressed.connect(_on_close)
	bar.add_child(back)
	panel.add_child(bar)
	return panel

func _build_left() -> Control:
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(320, 0)
	box.add_theme_constant_override("separation", 4)
	_filter_box = LineEdit.new()
	_filter_box.placeholder_text = "🔍 过滤对话（名称 / id）"
	_filter_box.clear_button_enabled = true
	_filter_box.text_changed.connect(func(t: String):
		_filter = t.strip_edges().to_lower()
		_refresh_list())
	box.add_child(_filter_box)
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(func(i: int): _pick(int(_list.get_item_metadata(i))))
	box.add_child(_list)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var add := Button.new()
	add.text = "＋ 新建"
	add.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add.pressed.connect(_on_add_dialogue)
	row.add_child(add)
	var dup := Button.new()
	dup.text = "⧉ 复制"
	dup.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dup.pressed.connect(_on_dup_dialogue)
	row.add_child(dup)
	var del := Button.new()
	del.text = "🗑 删除"
	del.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	del.pressed.connect(_on_del_dialogue)
	row.add_child(del)
	box.add_child(row)
	return EditorUI.panelize(box)

func _refresh_list() -> void:
	if _list == null:
		return
	_list.clear()
	var dlgs: Array = DialogueDB.all_dialogues()
	for i in dlgs.size():
		var d = dlgs[i]
		var nm := "%s（%s）" % [str(d.get("label", "")), str(d.get("id", ""))]
		if _filter != "" and not (nm.to_lower().contains(_filter)):
			continue
		_list.add_item(nm)
		_list.set_item_metadata(_list.item_count - 1, i)
		if i == _sel:
			_list.select(_list.item_count - 1)

# ============ 右栏（对话头 + 节点序列 + 节点表单）============

func _build_right() -> Control:
	var pair: Array = EditorUI.form_scroll(860.0)
	var form: VBoxContainer = pair[1]
	_dlg_head = VBoxContainer.new()
	_dlg_head.add_theme_constant_override("separation", 4)
	form.add_child(_dlg_head)
	form.add_child(EditorUI.section_title("节点序列（nodes[0]＝开场节点；顺序＝列表序）"))
	_node_list = ItemList.new()
	_node_list.custom_minimum_size = Vector2(0, 150)
	_node_list.item_selected.connect(func(i: int): _pick_node(i))
	form.add_child(_node_list)
	var nrow := HBoxContainer.new()
	nrow.add_theme_constant_override("separation", 4)
	for cfg in [["＋ 新增节点", _on_add_node], ["🗑 删除节点", _on_del_node], ["↑ 上移", _on_node_up], ["↓ 下移", _on_node_down]]:
		var b := Button.new()
		b.text = str(cfg[0])
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(cfg[1])
		nrow.add_child(b)
	form.add_child(nrow)
	form.add_child(EditorUI.section_title("节点内容"))
	_node_form = VBoxContainer.new()
	_node_form.add_theme_constant_override("separation", 6)
	form.add_child(_node_form)
	_msg = Label.new()
	_msg.add_theme_font_size_override("font_size", 12)
	_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	form.add_child(_msg)
	return EditorUI.panelize(pair[0])

func _cur():   # 选中对话（无＝null）
	var dlgs: Array = DialogueDB.all_dialogues()
	return dlgs[_sel] if _sel >= 0 and _sel < dlgs.size() else null

func _nodes() -> Array:
	var d = _cur()
	if d == null:
		return []
	if typeof(d.get("nodes")) != TYPE_ARRAY:
		d["nodes"] = []
	return d["nodes"]

func _cur_node():
	var ns := _nodes()
	return ns[_node_sel] if _node_sel >= 0 and _node_sel < ns.size() else null

func _pick(i: int) -> void:
	_sel = i
	_node_sel = 0 if not _nodes().is_empty() else -1
	_refresh_list()
	_rebuild_dlg_head()
	_refresh_node_list()
	_rebuild_node_form()

func _pick_node(i: int) -> void:
	_node_sel = i
	_refresh_node_list()
	_rebuild_node_form()

func _touch() -> void:
	_dirty = true
	_update_save_btn()

func _update_save_btn() -> void:
	if _save_btn == null:
		return
	_save_btn.text = "● 保存（未保存）" if _dirty else "保存"
	if _dirty:
		_save_btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	else:
		_save_btn.remove_theme_color_override("font_color")

func _set_msg(text: String, ok: bool) -> void:
	if _msg == null:
		return
	_msg.text = text
	_msg.add_theme_color_override("font_color", Color(0.55, 0.85, 0.55) if ok else Color(0.95, 0.75, 0.4))

# —— 对话头（id / 名称）——

func _rebuild_dlg_head() -> void:
	if _dlg_head == null:
		return   # headless 纯逻辑（不进树 _ready 未跑）：数据路径照走、UI 全免
	for c in _dlg_head.get_children():
		c.queue_free()
	var d = _cur()
	if d == null:
		_dlg_head.add_child(EditorUI.label("（左侧选择或新建一段对话）"))
		return
	var les: Array = EditorUI.add_line_pair(_dlg_head, "id", str(d.get("id", "")), "名称", str(d.get("label", "")))
	(les[0] as LineEdit).text_changed.connect(func(t: String):
		d["id"] = t
		DialogueDB.reindex()   # id 是引用键（触发器 dialogue_id）——改名即时重铸索引
		_touch()
		_refresh_list())
	(les[1] as LineEdit).text_changed.connect(func(t: String):
		d["label"] = t
		_touch()
		_refresh_list())

# —— 节点序列 ——

func _node_row_text(i: int, n: Dictionary) -> String:
	var t := str(n.get("text", ""))
	if t.length() > 24:
		t = t.substr(0, 24) + "…"
	var mark := "⑂" if not (n.get("choices", []) as Array).is_empty() else "→" + (str(n.get("next", "")) if str(n.get("next", "")) != "" else "■")
	return "%d. [%s] %s：%s　%s" % [i, str(n.get("id", "")), str(n.get("speaker", "")), t, mark]

func _refresh_node_list() -> void:
	if _node_list == null:
		return
	_node_list.clear()
	var ns := _nodes()
	for i in ns.size():
		if typeof(ns[i]) == TYPE_DICTIONARY:
			_node_list.add_item(_node_row_text(i, ns[i]))
	if _node_sel >= 0 and _node_sel < _node_list.item_count:
		_node_list.select(_node_sel)

func _node_id_exists(id: String) -> bool:
	for other in _nodes():
		if str(other.get("id", "")) == id:
			return true
	return false

func _uniq_node_id() -> String:
	var ns := _nodes()
	var used := {}
	for n in ns:
		used[str(n.get("id", ""))] = true
	var k := ns.size() + 1
	while used.has("n%d" % k):
		k += 1
	return "n%d" % k

func _on_add_node() -> void:
	var d = _cur()
	if d == null:
		return
	var ns := _nodes()
	var nid := _uniq_node_id()
	# 便利：上一个末节点若是「结束」且非分支 → 自动接到新节点（顺撰长对话免手连）
	if not ns.is_empty():
		var last: Dictionary = ns[ns.size() - 1]
		if str(last.get("next", "")) == "" and (last.get("choices", []) as Array).is_empty():
			last["next"] = nid
	ns.append({"id": nid, "speaker": "", "text": "", "next": ""})
	_node_sel = ns.size() - 1
	_touch()
	_refresh_node_list()
	_rebuild_node_form()

func _on_del_node() -> void:
	var ns := _nodes()
	var n = _cur_node()
	if n == null:
		return
	var do_del := func():
		var nid := str(n.get("id", ""))
		ns.erase(n)
		for other in ns:
			if str(other.get("next", "")) == nid:
				other["next"] = ""
			for c in other.get("choices", []):
				if typeof(c) == TYPE_DICTIONARY and str(c.get("next", "")) == nid:
					c["next"] = ""
		_node_sel = clampi(_node_sel, -1, ns.size() - 1)
		_touch()
		_refresh_node_list()
		_rebuild_node_form()
	EditorUI.confirm(self, "删除节点「%s」？指向它的推进/选项跳转会被清空（回「结束」）。" % str(n.get("id", "")),
		"删除", do_del, Callable(), "删除节点")

func _on_node_up() -> void:
	_swap_node(_node_sel, _node_sel - 1)

func _on_node_down() -> void:
	_swap_node(_node_sel, _node_sel + 1)

func _swap_node(a: int, b: int) -> void:
	var ns := _nodes()
	if a < 0 or b < 0 or a >= ns.size() or b >= ns.size():
		return
	var t = ns[a]
	ns[a] = ns[b]
	ns[b] = t
	_node_sel = b
	_touch()
	_refresh_node_list()

# 节点 id 改名 → 自动同步全对话内引用（next / choices.next）
func _rename_node(n: Dictionary, new_id: String) -> void:
	var old := str(n.get("id", ""))
	if new_id == old or new_id == "":
		return
	n["id"] = new_id
	for other in _nodes():
		if str(other.get("next", "")) == old:
			other["next"] = new_id
		for c in other.get("choices", []):
			if typeof(c) == TYPE_DICTIONARY and str(c.get("next", "")) == old:
				c["next"] = new_id
	_touch()
	_refresh_node_list()

# —— 节点表单 ——

func _next_pairs(exclude_id: String) -> Array:
	var pairs := [["", "——结束对话"]]
	for n in _nodes():
		var nid := str(n.get("id", ""))
		if nid != "" and nid != exclude_id:
			pairs.append([nid, "%s（%s）" % [nid, str(n.get("speaker", ""))]])
	return pairs

func _rebuild_node_form() -> void:
	if _node_form == null:
		return   # headless 纯逻辑同上
	for c in _node_form.get_children():
		c.queue_free()
	var n = _cur_node()
	if n == null:
		_node_form.add_child(EditorUI.label("（选择或新增一个节点）"))
		return
	# id / 说话人。id＝**提交制**改名（回车/失焦才落地）：逐键改名会在中途撞上既有 id、
	# 把别人的入边劫持改错（如 n2→n10 途经 "n1"）——撞车/空值一律拒绝还原。
	var nles: Array = EditorUI.add_line_pair(_node_form, "节点id", str(n.get("id", "")), "说话人", str(n.get("speaker", "")))
	var idle: LineEdit = nles[0]
	var commit_rename := func():
		var t := idle.text.strip_edges()
		var old := str(n.get("id", ""))
		if t == old:
			return
		if t == "" or _node_id_exists(t):
			idle.text = old
			_set_msg("节点 id「%s」为空/与既有节点重复——已还原" % t, false)
			return
		_rename_node(n, t)
		_set_msg("节点改名 %s→%s（全对话引用已同步）" % [old, t], true)
	idle.text_submitted.connect(func(_t: String): commit_rename.call())
	idle.focus_exited.connect(commit_rename)
	(nles[1] as LineEdit).text_changed.connect(func(t: String):
		n["speaker"] = t
		_touch()
		_refresh_node_list())
	# 立绘侧 + 立绘路径（选图 + 预览）
	var side_ob := EditorUI.dropdown([["left", "左侧"], ["right", "右侧"]], str(n.get("side", "left")))
	side_ob.item_selected.connect(func(i: int):
		n["side"] = str(side_ob.get_item_metadata(i))
		_touch())
	_node_form.add_child(EditorUI.field_row("立绘位置", side_ob))
	_node_form.add_child(_portrait_row(n))
	# 台词（多行 wrap）
	_node_form.add_child(EditorUI.label("台词"))
	var te := TextEdit.new()
	te.text = str(n.get("text", ""))
	te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	te.custom_minimum_size = Vector2(0, 92)
	te.text_changed.connect(func():
		n["text"] = te.text
		_touch())
	_node_form.add_child(te)
	# 分支：无 choices → 推进目标；有 choices → 选项列表（choices 接管推进）
	var cs = n.get("choices", [])
	if typeof(cs) != TYPE_ARRAY or cs.is_empty():
		var next_ob := EditorUI.dropdown(_next_pairs(str(n.get("id", ""))), str(n.get("next", "")))
		next_ob.item_selected.connect(func(i: int):
			n["next"] = str(next_ob.get_item_metadata(i))
			_touch()
			_refresh_node_list())
		_node_form.add_child(EditorUI.field_row("点击推进到", next_ob))
	else:
		_node_form.add_child(EditorUI.section_title("玩家选项（有选项＝点击不推进，走选项跳转）"))
		for ci in cs.size():
			if typeof(cs[ci]) == TYPE_DICTIONARY:
				_node_form.add_child(_choice_panel(n, cs[ci]))
	var add_choice := Button.new()
	add_choice.text = "＋ 添加玩家选项"
	add_choice.tooltip_text = "无选项＝纯演出节点（点击推进）；加了选项＝分支节点（选项接管跳转）"
	add_choice.pressed.connect(func():
		var arr = n.get("choices", [])
		if typeof(arr) != TYPE_ARRAY:
			arr = []
		arr.append({"text": "……", "next": ""})
		n["choices"] = arr
		_touch()
		_refresh_node_list()
		_rebuild_node_form())
	_node_form.add_child(add_choice)

# 立绘行：路径 + 选图（res:// PNG）+ 预览
func _portrait_row(n: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.add_child(EditorUI.label("立绘"))
	var le := LineEdit.new()
	le.text = str(n.get("portrait", ""))
	le.placeholder_text = "res://icons/…（空＝无立绘）"
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var pv := TextureRect.new()
	pv.custom_minimum_size = Vector2(48, 48)
	pv.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pv.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pv.texture = TextureCache.get_tex(str(n.get("portrait", "")))
	le.text_changed.connect(func(t: String):
		if t == "":
			n.erase("portrait")
		else:
			n["portrait"] = t
		pv.texture = TextureCache.get_tex(t)
		_touch())
	row.add_child(le)
	var pick := Button.new()
	pick.text = "选图…"
	pick.pressed.connect(func(): _pick_portrait(le))
	row.add_child(pick)
	row.add_child(pv)
	return row

func _pick_portrait(le: LineEdit) -> void:
	if _file_dlg == null or not is_instance_valid(_file_dlg):
		_file_dlg = EditorUI.make_file_dialog(FileDialog.FILE_MODE_OPEN_FILE, FileDialog.ACCESS_RESOURCES,
			[["*.png", "PNG 图像"]], false)
		add_child(_file_dlg)
	_file_dlg.current_dir = EditorUI.recall_dir("dialogue_portrait", "res://icons")
	for conn in _file_dlg.file_selected.get_connections():
		_file_dlg.file_selected.disconnect(conn["callable"])
	_file_dlg.file_selected.connect(func(path: String):
		EditorUI.remember_dir("dialogue_portrait", path)
		le.text = path
		le.text_changed.emit(path))
	_file_dlg.popup_centered_ratio(0.7)

# 单条选项面板：文本 / 跳转 / 结果动作（EventEngine 注册表——与触发器 do 同表）/ 删除
func _choice_panel(n: Dictionary, c: Dictionary) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", EditorTheme.sb(Color(0.10, 0.12, 0.16), Color(0.24, 0.27, 0.33)))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	panel.add_child(box)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	var te := LineEdit.new()
	te.text = str(c.get("text", ""))
	te.placeholder_text = "选项文本"
	te.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	te.text_changed.connect(func(t: String):
		c["text"] = t
		_touch())
	head.add_child(te)
	var next_ob := EditorUI.dropdown(_next_pairs(str(n.get("id", ""))), str(c.get("next", "")))
	next_ob.item_selected.connect(func(i: int):
		c["next"] = str(next_ob.get_item_metadata(i))
		_touch())
	head.add_child(next_ob)
	var del := Button.new()
	del.text = "✕"
	del.tooltip_text = "删除该选项"
	del.pressed.connect(func():
		(n.get("choices", []) as Array).erase(c)
		if (n.get("choices", []) as Array).is_empty():
			n.erase("choices")   # 最后一个选项删掉＝回归纯演出节点
		_touch()
		_refresh_node_list()
		_rebuild_node_form())
	head.add_child(del)
	box.add_child(head)
	# 结果动作（可空＝纯跳转选项）
	var acts = c.get("actions", [])
	if typeof(acts) == TYPE_ARRAY:
		for a in acts:
			if typeof(a) == TYPE_DICTIONARY:
				box.add_child(_choice_action_row(c, a))
	box.add_child(EditorUI.event_action_menu("＋ 结果动作（给物品/给钱/设flag…）", func(act_id: String):
		var arr = c.get("actions", [])
		if typeof(arr) != TYPE_ARRAY:
			arr = []
		arr.append(EventEngine.default_action(act_id))
		c["actions"] = arr
		_touch()
		_rebuild_node_form()))
	return panel

func _choice_action_row(c: Dictionary, a: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var head := HBoxContainer.new()
	var lbl := EditorUI.label("　↳ " + EventEngine.action_label(str(a.get("action", ""))))
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(lbl)
	var x := Button.new()
	x.text = "✕"
	x.pressed.connect(func():
		(c.get("actions", []) as Array).erase(a)
		if (c.get("actions", []) as Array).is_empty():
			c.erase("actions")
		_touch()
		_rebuild_node_form())
	head.add_child(x)
	box.add_child(head)
	for f in EventEngine.action_def(str(a.get("action", ""))).get("fields", []):
		box.add_child(EditorUI.event_action_field(a, f, func(): _touch()))
	return box

# ============ 对话增删复 / 保存 / 关闭 ============

func _uniq_dialogue_id(base: String) -> String:
	var id := base
	var k := 2
	while DialogueDB.dialogue(id) != null:
		id = "%s_%d" % [base, k]
		k += 1
	return id

# 新建/复制前清过滤——否则新项被过滤隐藏、表单却在编辑「看不见」的对话（连点还会产生幽灵副本）
func _clear_filter() -> void:
	_filter = ""
	if _filter_box != null and is_instance_valid(_filter_box):
		_filter_box.text = ""

func _on_add_dialogue() -> void:
	var dlgs: Array = DialogueDB.all_dialogues()
	var id := _uniq_dialogue_id("dlg_new")
	dlgs.append({"id": id, "label": "新对话", "nodes": [{"id": "n1", "speaker": "", "text": "", "next": ""}]})
	DialogueDB.reindex()
	_touch()
	_clear_filter()
	_pick(dlgs.size() - 1)

func _on_dup_dialogue() -> void:
	var d = _cur()
	if d == null:
		return
	var dlgs: Array = DialogueDB.all_dialogues()
	var cp: Dictionary = (d as Dictionary).duplicate(true)
	cp["id"] = _uniq_dialogue_id(str(d.get("id", "dlg")) + "_copy")
	cp["label"] = str(d.get("label", "")) + "（副本）"
	dlgs.append(cp)
	DialogueDB.reindex()
	_touch()
	_clear_filter()
	_pick(dlgs.size() - 1)

func _on_del_dialogue() -> void:
	var d = _cur()
	if d == null:
		return
	var do_del := func():
		DialogueDB.all_dialogues().erase(d)
		DialogueDB.reindex()
		_sel = -1
		_node_sel = -1
		_touch()
		_refresh_list()
		_rebuild_dlg_head()
		_refresh_node_list()
		_rebuild_node_form()
	EditorUI.confirm(self, "删除对话「%s（%s）」？引用它的触发器会开播失败（仅警告不崩）。" % [str(d.get("label", "")), str(d.get("id", ""))],
		"删除", do_del, Callable(), "删除对话")

# 保存前轻校验（authoring 宽松：只警告不拦存）：节点 id 重复 / 悬空跳转
func _lint() -> Array:
	var warns := []
	for d in DialogueDB.all_dialogues():
		var ids := {}
		for n in d.get("nodes", []):
			var nid := str(n.get("id", ""))
			if ids.has(nid):
				warns.append("「%s」节点 id 重复：%s" % [str(d.get("id", "")), nid])
			ids[nid] = true
		for n in d.get("nodes", []):
			var nx := str(n.get("next", ""))
			if nx != "" and not ids.has(nx):
				warns.append("「%s」节点 %s 推进到不存在的 %s" % [str(d.get("id", "")), str(n.get("id", "")), nx])
			for c in n.get("choices", []):
				if typeof(c) == TYPE_DICTIONARY:
					var cx := str(c.get("next", ""))
					if cx != "" and not ids.has(cx):
						warns.append("「%s」节点 %s 选项跳转到不存在的 %s" % [str(d.get("id", "")), str(n.get("id", "")), cx])
	return warns

func _on_save() -> void:
	DialogueDB.reindex()
	var warns := _lint()
	if DialogueDB.save():
		_dirty = false
		_update_save_btn()
		if warns.is_empty():
			_set_msg("已保存 → data/dialogues.json", true)
		else:
			_set_msg("已保存（⚠ %d 条校验警告）：%s" % [warns.size(), "；".join(warns)], false)
	else:
		_set_msg("保存失败（写盘错误）", false)

func _on_close() -> void:
	var leave := func():
		if embedded:
			DialogueDB.reload_data()   # 未保存改动回滚（live 表脏了——重读磁盘，触发器下拉不见幽灵对话）
			closed.emit()
			queue_free()
		else:
			DialogueDB.reload_data()
			get_tree().change_scene_to_file("res://StartMenu.tscn")
	if _dirty:
		EditorUI.confirm(self, "对话有未保存改动——不保存离开将丢弃（重读磁盘）。仍要离开吗？",
			"不保存离开", leave, Callable(), "未保存改动")
	else:
		leave.call()
