extends Control
## 行动顺序槽（屏幕顶部、宽=屏幕一半、居中）。
## 显示一条「条目序列」：回合标记（第N回合，竖排）+ 单位槽（头像 + 名字 + 速度）。
## 当前行动单位永远排在最左（紧跟当前回合标记），金色边框高亮。
## 结束回合→该槽向下渐变移除，其余左滑补位；速度变化→整条重排（滑动到新位置）。
## 同时最多显示「当前回合剩余 + 下一回合全员」；塞不下时底部横向滑条查看后面。
##
## 纯视图：由宿主（Sandbox）算好序列后调 refresh(seq)。
## seq = Array[Dictionary]：
##   { "kind":"marker", "round":int }
##   { "kind":"unit",   "round":int, "unit":Unit, "active":bool }

var host                      # 宿主（提供 faction_color / focus_on_unit / set_hover_unit / clear_hover_unit）

# —— 尺寸常量 ——
const TOP_MARGIN := 6.0
const PAD := 8.0
const AVATAR := 50.0          # 头像方框边长
const SLOT_W := 60.0          # 单位槽宽（头像 + 两行文字居中）
const SLOT_H := 88.0          # 单位槽高（头像50 + 名字18 + 速度16 + 间距）
const MARKER_W := 24.0        # 回合标记宽（竖排汉字）
const GAP := 6.0              # 条目间距
const SCROLLBAR_H := 7.0      # 横向滑条厚度（细）
const BAR_H := PAD * 2.0 + SLOT_H + 2.0 + SCROLLBAR_H
const DROP := 30.0           # 退场下落距离

# —— 节点 ——
var _bg: Panel               # 半透明深色背景，吞掉点击（不误点地图）
var _viewport: Control       # 裁剪窗口（横向裁掉塞不下的部分）
var _track: Control          # 承载所有条目节点（绝对定位）；x 偏移 = -滚动值
var _scrollbar: HScrollBar   # 底部横向滑条

# —— 状态 ——
var _slots := {}             # key(String) -> 条目节点
var _last_seq := []          # 上次 refresh 的序列
var _content_w := 0.0        # 全部条目总宽
var _prev_active_key := ""   # 上次的当前行动条目 key（用于「下落」退场判定）
var _tex_cache := {}         # 头像纹理缓存

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg = Panel.new()
	_bg.mouse_filter = Control.MOUSE_FILTER_STOP   # 点击空白条不落到地图
	_bg.add_theme_stylebox_override("panel", _bar_stylebox())
	add_child(_bg)
	_viewport = Control.new()
	_viewport.clip_contents = true
	_viewport.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_viewport)
	_track = Control.new()
	_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_viewport.add_child(_track)
	_scrollbar = HScrollBar.new()
	_scrollbar.mouse_filter = Control.MOUSE_FILTER_STOP
	_scrollbar.custom_minimum_size = Vector2(0, SCROLLBAR_H)
	_slim_scrollbar()
	_scrollbar.value_changed.connect(func(_v): _apply_scroll())
	add_child(_scrollbar)
	if is_inside_tree() and get_viewport() != null:
		get_viewport().size_changed.connect(_relayout)
	_relayout()

# 横向滑条做细：轨道 + 滑块都用 0 边距薄圆角 stylebox（默认主题会显粗）
func _slim_scrollbar() -> void:
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.20, 0.20, 0.24, 0.55)
	track.set_corner_radius_all(3)
	track.set_content_margin_all(0)
	var grab := StyleBoxFlat.new()
	grab.bg_color = Color(0.62, 0.62, 0.68, 0.85)
	grab.set_corner_radius_all(3)
	grab.set_content_margin_all(0)
	var grab_hi := grab.duplicate()
	grab_hi.bg_color = Color(0.82, 0.82, 0.88, 0.95)
	_scrollbar.add_theme_stylebox_override("scroll", track)
	_scrollbar.add_theme_stylebox_override("scroll_focus", track)
	_scrollbar.add_theme_stylebox_override("grabber", grab)
	_scrollbar.add_theme_stylebox_override("grabber_highlight", grab_hi)
	_scrollbar.add_theme_stylebox_override("grabber_pressed", grab_hi)

func _bar_stylebox() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.06, 0.09, 0.82)
	sb.set_corner_radius_all(8)
	sb.set_border_width_all(1)
	sb.border_color = Color(0.5, 0.45, 0.25, 0.5)
	sb.set_content_margin_all(0)
	return sb

# ============ 布局 / 缩放 ============

func _relayout() -> void:
	if not is_inside_tree():
		return
	var vp := get_viewport_rect().size
	var bw := maxf(vp.x * 0.5, 200.0)
	custom_minimum_size = Vector2(bw, BAR_H)
	size = Vector2(bw, BAR_H)
	position = Vector2((vp.x - bw) * 0.5, TOP_MARGIN)
	if _bg != null:
		_bg.size = Vector2(bw, BAR_H)
	if _viewport != null:
		_viewport.position = Vector2(PAD, PAD)
		_viewport.size = Vector2(bw - PAD * 2.0, SLOT_H)
	if _scrollbar != null:
		_scrollbar.position = Vector2(PAD, PAD + SLOT_H + 2.0)
		_scrollbar.size = Vector2(bw - PAD * 2.0, SCROLLBAR_H)
	if not _last_seq.is_empty():
		_snap_layout()

# 计算每个条目的目标 x + 总宽
func _layout_targets(seq: Array) -> Dictionary:
	var xs := {}
	var x := 0.0
	for e in seq:
		var w: float = MARKER_W if e.get("kind") == "marker" else SLOT_W
		xs[_entry_key(e)] = x
		x += w + GAP
	return {"xs": xs, "content_w": maxf(0.0, x - GAP)}

# 重新布局（不带动画，用于窗口缩放）
func _snap_layout() -> void:
	var lay := _layout_targets(_last_seq)
	_content_w = float(lay["content_w"])
	var xs: Dictionary = lay["xs"]
	for e in _last_seq:
		var k := _entry_key(e)
		if _slots.has(k):
			var node = _slots[k]
			_kill_tw(node)
			node.position = Vector2(float(xs[k]), 0.0)
			node.modulate.a = 1.0
	_update_scroll(false)

func _entry_key(e: Dictionary) -> String:
	if e.get("kind") == "marker":
		return "m%d" % int(e.get("round", 0))
	return "u%d_r%d" % [e["unit"].get_instance_id(), int(e.get("round", 0))]

# ============ 刷新（核心：旧/新条目对账 + 动画）============

func refresh(seq: Array) -> void:
	_last_seq = seq
	var lay := _layout_targets(seq)
	_content_w = float(lay["content_w"])
	var xs: Dictionary = lay["xs"]
	# 新序列里有哪些 key、当前行动 key
	var new_keys := {}
	var active_key := ""
	for e in seq:
		var k := _entry_key(e)
		new_keys[k] = e
		if e.get("kind") == "unit" and e.get("active", false):
			active_key = k
	var active_changed := active_key != _prev_active_key
	# 退场：旧有、新无 → 当前行动者下落淡出，其余直接淡出
	for k in _slots.keys():
		if not new_keys.has(k):
			var node = _slots[k]
			_slots.erase(k)
			_animate_exit(node, k == _prev_active_key)
	# 进场 / 移动
	for e in seq:
		var k := _entry_key(e)
		var tx := float(xs[k])
		if _slots.has(k):
			var node = _slots[k]
			_update_entry(node, e)
			_tween_to(node, tx)
		else:
			var node := _create_entry(e)
			_track.add_child(node)
			node.position = Vector2(tx, 0.0)
			node.modulate.a = 0.0
			_slots[k] = node
			_fade_in(node)
	_prev_active_key = active_key
	_update_scroll(active_changed)

func _update_scroll(active_changed: bool) -> void:
	if _scrollbar == null or _viewport == null:
		return
	var view_w := _viewport.size.x
	var max_scroll := maxf(0.0, _content_w - view_w)
	_scrollbar.min_value = 0.0
	_scrollbar.max_value = maxf(_content_w, view_w)
	_scrollbar.page = view_w
	if active_changed:
		_scrollbar.value = 0.0   # 行动者换人 → 滚回最左，保证当前行动者可见
	_scrollbar.value = clampf(_scrollbar.value, 0.0, max_scroll)
	_apply_scroll()

func _apply_scroll() -> void:
	if _track != null and _scrollbar != null:
		_track.position.x = -_scrollbar.value

# ============ 动画 ============

func _tween_to(node: Control, tx: float) -> void:
	_kill_tw(node)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(node, "position:x", tx, 0.22).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(node, "position:y", 0.0, 0.22)
	tw.tween_property(node, "modulate:a", 1.0, 0.18)
	node.set_meta("tw", tw)

func _fade_in(node: Control) -> void:
	_kill_tw(node)
	var tw := create_tween()
	tw.tween_property(node, "modulate:a", 1.0, 0.20)
	node.set_meta("tw", tw)

func _animate_exit(node: Control, drop: bool) -> void:
	_kill_tw(node)
	var tw := create_tween()
	tw.set_parallel(true)
	if drop:
		tw.tween_property(node, "position:y", DROP, 0.28).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		tw.tween_property(node, "modulate:a", 0.0, 0.28)
	else:
		tw.tween_property(node, "modulate:a", 0.0, 0.16)
	tw.chain().tween_callback(node.queue_free)
	node.set_meta("tw", tw)

func _kill_tw(node: Control) -> void:
	if node.has_meta("tw"):
		var t = node.get_meta("tw")
		if t is Tween and t.is_valid():
			t.kill()

# ============ 条目构建 ============

func _create_entry(e: Dictionary) -> Control:
	if e.get("kind") == "marker":
		return _make_marker(int(e.get("round", 0)))
	return _make_slot(e)

func _update_entry(node: Control, e: Dictionary) -> void:
	if e.get("kind") == "unit":
		_style_slot(node, e)

# 回合标记：竖排汉字「第N回合」，垂直居中
func _make_marker(rnd: int) -> Control:
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(MARKER_W, SLOT_H)
	box.size = Vector2(MARKER_W, SLOT_H)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 0)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for ch in ("第" + _cn_num(rnd) + "回合"):
		var l := Label.new()
		l.text = ch
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.add_theme_font_size_override("font_size", 13)
		l.add_theme_color_override("font_color", Color(0.88, 0.84, 0.58))
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(l)
	return box

# 单位槽：头像方框 + 名字 + 速度（两行居中）
func _make_slot(e: Dictionary) -> Control:
	var u = e["unit"]
	var slot := Control.new()
	slot.custom_minimum_size = Vector2(SLOT_W, SLOT_H)
	slot.size = Vector2(SLOT_W, SLOT_H)
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	slot.set_meta("unit", u)
	slot.gui_input.connect(_on_slot_input.bind(u))
	slot.mouse_entered.connect(_on_slot_hover.bind(u, true))
	slot.mouse_exited.connect(_on_slot_hover.bind(u, false))
	# 头像方框
	var frame := Panel.new()
	frame.position = Vector2((SLOT_W - AVATAR) * 0.5, 0.0)
	frame.custom_minimum_size = Vector2(AVATAR, AVATAR)
	frame.size = Vector2(AVATAR, AVATAR)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(frame)
	slot.set_meta("frame", frame)
	# 头像图（无则用名字首字兜底）
	var tex = _load_tex(u.portrait if u.portrait != "" else u.icon)
	if tex != null:
		var tr := TextureRect.new()
		tr.texture = tex
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		tr.position = Vector2(3, 3)
		tr.size = Vector2(AVATAR - 6, AVATAR - 6)
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(tr)
	else:
		var ph := Label.new()
		ph.text = u.unit_name.substr(0, 1)
		ph.size = Vector2(AVATAR, AVATAR)
		ph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		ph.add_theme_font_size_override("font_size", 24)
		ph.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(ph)
	# 名字
	var name_lbl := Label.new()
	name_lbl.text = u.unit_name
	name_lbl.position = Vector2(0, AVATAR + 2)
	name_lbl.size = Vector2(SLOT_W, 18)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 12)
	name_lbl.add_theme_color_override("font_color", host.faction_color(u.faction))
	name_lbl.clip_text = true
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(name_lbl)
	# 速度
	var spd_lbl := Label.new()
	spd_lbl.position = Vector2(0, AVATAR + 20)
	spd_lbl.size = Vector2(SLOT_W, 16)
	spd_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	spd_lbl.add_theme_font_size_override("font_size", 11)
	spd_lbl.add_theme_color_override("font_color", Color(0.70, 0.76, 0.82))
	spd_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(spd_lbl)
	slot.set_meta("speed_lbl", spd_lbl)
	_style_slot(slot, e)
	return slot

# 槽样式：当前行动者=金框+辉光，否则按阵营色描边；刷新速度文字
func _style_slot(slot: Control, e: Dictionary) -> void:
	var u = e["unit"]
	var active: bool = e.get("active", false)
	var frame: Panel = slot.get_meta("frame")
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.10, 0.13, 0.92)
	var bw := 3 if active else 2
	sb.set_border_width_all(bw)
	sb.border_color = Color(1.0, 0.84, 0.30) if active else host.faction_color(u.faction)
	sb.set_corner_radius_all(5)
	if active:
		sb.shadow_color = Color(1.0, 0.84, 0.30, 0.55)
		sb.shadow_size = 6
	frame.add_theme_stylebox_override("panel", sb)
	var spd: Label = slot.get_meta("speed_lbl")
	spd.text = "速 %d" % u.effective_stat("speed")

# 点头像 = 把镜头切到该单位所在格（不再开角色状态）
func _on_slot_input(event: InputEvent, u) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if host != null and host.has_method("focus_on_unit"):
			host.focus_on_unit(u)

# 鼠标扫到 / 离开头像 = 在地图上高亮 / 取消高亮该单位所在格
func _on_slot_hover(u, entered: bool) -> void:
	if host == null:
		return
	if entered:
		if host.has_method("set_hover_unit"):
			host.set_hover_unit(u)
	elif host.has_method("clear_hover_unit"):
		host.clear_hover_unit(u)

# ============ 工具 ============

# 路径取纹理并缓存（优先已导入资源，否则直读原图，免依赖编辑器导入）
func _load_tex(path: String):
	if path == "":
		return null
	if _tex_cache.has(path):
		return _tex_cache[path]
	var tex = null
	if ResourceLoader.exists(path):
		var t = load(path)
		if t is Texture2D:
			tex = t
	if tex == null:
		var img := Image.new()
		if img.load(path) == OK:
			tex = ImageTexture.create_from_image(img)
	_tex_cache[path] = tex
	return tex

# 阿拉伯数字 → 中文数字（0–99，超出回退阿拉伯）
func _cn_num(n: int) -> String:
	var d := ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
	if n <= 0:
		return str(n)
	if n < 10:
		return d[n]
	if n < 20:
		return "十" if n == 10 else "十" + d[n - 10]
	if n < 100:
		var t := n / 10
		var o := n % 10
		return d[t] + "十" + ("" if o == 0 else d[o])
	return str(n)
