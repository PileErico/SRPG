extends PanelContainer
## 底部「可用单位」横栏：管理 roster（已准备单位）。
## 末尾「＋」添加（内置原型 / 已存预设）；每个单位槽：拖到地图布置、点选编辑、✕ 移出。
## 撤下（场上→待命）在地图上右键单位（Sandbox.deploy_right_click）。host = Sandbox 实例。

var host
var _row: HBoxContainer
var _add_menu: PopupMenu
var _menu_sources := []   # PopupMenu item id -> proto 字典

# 可拖拽单位槽：拖到地图 = 布置该单位（拖拽数据带单位引用）
class RosterSlot extends Button:
	var unit
	func _get_drag_data(_at):
		var data := {"kind": "roster_unit", "ref": unit}
		var prev := PanelContainer.new()
		var l := Label.new()
		l.text = str(unit.unit_name)
		prev.add_child(l)
		set_drag_preview(prev)
		return data

func _ready() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.14, 0.96)
	sb.set_content_margin_all(6)
	add_theme_stylebox_override("panel", sb)

	var outer := VBoxContainer.new()
	add_child(outer)
	var title := Label.new()
	title.text = "可用单位（拖到地图布置 · 点选编辑 · 地图右键撤下）"
	title.add_theme_color_override("font_color", Color(0.72, 0.76, 0.84))
	title.add_theme_font_size_override("font_size", 12)
	outer.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 8)
	scroll.add_child(_row)

	_add_menu = PopupMenu.new()
	_add_menu.id_pressed.connect(_on_add_chosen)
	add_child(_add_menu)

	refresh()

func refresh() -> void:
	if _row == null:
		return
	for c in _row.get_children():
		c.queue_free()
	if host != null:
		for u in host.roster_units():   # S5：经访问器读花名册，不直读 host.roster
			_row.add_child(_make_slot(u))
	# 末尾「＋」
	var add := Button.new()
	add.text = "＋"
	add.custom_minimum_size = Vector2(56, 70)
	add.tooltip_text = "添加可用单位（原型 / 预设）"
	add.pressed.connect(_open_add_menu)
	_row.add_child(add)

func _make_slot(u) -> Control:
	var card := VBoxContainer.new()
	card.custom_minimum_size = Vector2(100, 0)
	var slot := RosterSlot.new()
	slot.unit = u
	slot.custom_minimum_size = Vector2(100, 50)
	slot.clip_text = true
	slot.text = str(u.unit_name)
	slot.tooltip_text = "拖到地图布置 · 点选编辑"
	if host != null:
		slot.add_theme_color_override("font_color", host.faction_color(u.faction))
	slot.pressed.connect(_on_slot_pressed.bind(u))
	card.add_child(slot)

	var bottom := HBoxContainer.new()
	var st := Label.new()
	st.add_theme_font_size_override("font_size", 11)
	if host != null and host.is_placed(u):
		st.text = "在(%d,%d)" % [u.col, u.row]
		st.add_theme_color_override("font_color", Color(0.55, 0.85, 0.55))
	else:
		st.text = "待命"
		st.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	st.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(st)
	var del := Button.new()
	del.text = "✕"
	del.tooltip_text = "从可用单位移出"
	del.pressed.connect(_on_slot_remove.bind(u))
	bottom.add_child(del)
	card.add_child(bottom)
	return card

func _on_slot_pressed(u) -> void:
	if host:
		host.select_roster_unit(u)

func _on_slot_remove(u) -> void:
	if host:
		host.remove_roster_unit(u)

func _open_add_menu() -> void:
	if host == null:
		return
	_add_menu.clear()
	_menu_sources.clear()
	var src = host.roster_sources()
	var id := 0
	for p in src.get("protos", []):
		_add_menu.add_item("原型：%s" % str(p.get("name", "?")), id)
		_menu_sources.append(p)
		id += 1
	var presets = src.get("presets", [])
	if not presets.is_empty():
		_add_menu.add_separator("预设")
		for p in presets:
			_add_menu.add_item("预设：%s" % str(p.get("name", "?")), id)
			_menu_sources.append(p)
			id += 1
	_add_menu.add_separator()
	_add_menu.add_item("★ 默认阵容（全部加入）", 9000)
	var mp := get_viewport().get_mouse_position()
	_add_menu.popup(Rect2i(Vector2i(mp), Vector2i.ZERO))

func _on_add_chosen(id: int) -> void:
	if host == null:
		return
	if id == 9000:
		host.spawn_default_roster()
		return
	if id >= 0 and id < _menu_sources.size():
		host.add_roster_unit(_menu_sources[id])
