extends Control
## 内置像素画布：在 N×N 网格上画部件贴图，底下叠**洋葱皮**（角色其余部件）作对齐参照。
## 大视口 + 滚轮缩放（光标锚定）+ 中键拖动平移；NEAREST 采样＝像素硬边不溢色。
## 工具：铅笔/橡皮/填充/吸管/直线/矩形/实心矩形 + 水平镜像；选区(矩形)/魔棒 + 复制/剪切/粘贴/删除/拖动移动浮动块。
## 直线矩形拖动实时预览、松手落定；undo 快照栈。就着角色本体画→锚点天然对齐。未来完整像素编辑器的地基。

signal color_picked(c: Color)

const CHECK_A := Color(0.16, 0.17, 0.20)
const CHECK_B := Color(0.21, 0.22, 0.26)
const ZOOMS := [2, 3, 4, 6, 8, 10, 12, 16, 20, 24, 32, 40, 48, 64]

var img: Image
var onion: Texture2D
var px_size := 32
var brush := Color(0.5, 0.5, 0.5, 1.0)
var tool := "pencil"          # pencil/eraser/fill/pick/line/rect/rectf/select/wand
var mirror_x := false
var show_grid := true

var zoom := 16
var pan := Vector2.ZERO
var _fitted := false
var _tex: ImageTexture
var _drawing := false
var _panning := false
var _pan_start := Vector2.ZERO
var _last := Vector2i(-999, -999)
var _start := Vector2i(0, 0)
var _preview: Array[Vector2i] = []
var _undo: Array[Image] = []

# 选区
var _sel := {}                # {Vector2i: true}
var _sel_rect_a := Vector2i.ZERO
var _sel_rect_b := Vector2i.ZERO
var _sel_dragging := false
var _float: Array = []        # [{p:Vector2i, c:Color}] 浮动块（移动/粘贴中）
var _float_off := Vector2i.ZERO
var _moving := false
var _move_start := Vector2i.ZERO
var _move_origin := Vector2i.ZERO
var _clip: Array = []         # 剪贴板（归一化到最小角）

func setup(size: int, initial: Image, onion_tex: Texture2D) -> void:
	px_size = size
	if initial != null:
		img = initial.duplicate()
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
	else:
		img = Image.create(size, size, false, Image.FORMAT_RGBA8)
		img.fill(Color(0, 0, 0, 0))
	onion = onion_tex
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	clip_contents = true
	focus_mode = Control.FOCUS_CLICK
	custom_minimum_size = Vector2(560, 560)
	_fitted = false
	_rebuild()

func set_tool(t: String) -> void:
	if t != "select" and t != "wand":
		_commit_float()
		_clear_sel()
	tool = t

func load_image(src: Image) -> void:
	_snapshot()
	img = src.duplicate()
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	_rebuild()

func get_image() -> Image:
	_commit_float()
	return img.duplicate()

func clear_img() -> void:
	_snapshot(); img.fill(Color(0, 0, 0, 0)); _clear_sel(); _rebuild()

func undo() -> void:
	if _undo.is_empty():
		return
	img = _undo.pop_back(); _float = []; _clear_sel(); _rebuild()

func set_grid(on: bool) -> void:
	show_grid = on; queue_redraw()

func zoom_in() -> void: _zoom_to(_zi() + 1, size * 0.5)
func zoom_out() -> void: _zoom_to(_zi() - 1, size * 0.5)
func fit() -> void: _fit(); queue_redraw()

func _rebuild() -> void:
	_tex = ImageTexture.create_from_image(img)
	queue_redraw()

# —— 视口 ——
func _fit() -> void:
	if size.x < 4 or size.y < 4:
		return
	var z := int(floor(min(size.x, size.y) * 0.9 / float(px_size)))
	zoom = clampi(z, ZOOMS[0], ZOOMS[ZOOMS.size() - 1])
	pan = (size - Vector2(px_size * zoom, px_size * zoom)) * 0.5
	_fitted = true

func _zi() -> int:
	var bi := 0; var bd := 99999
	for i in ZOOMS.size():
		var d: int = absi(ZOOMS[i] - zoom)
		if d < bd:
			bd = d; bi = i
	return bi

func _zoom_to(idx: int, anchor: Vector2) -> void:
	idx = clampi(idx, 0, ZOOMS.size() - 1)
	var nz: int = ZOOMS[idx]
	if nz == zoom:
		return
	pan = anchor - (anchor - pan) * (float(nz) / float(zoom))
	zoom = nz
	queue_redraw()

func _draw() -> void:
	if not _fitted:
		_fit()
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.09, 0.10, 0.12))
	var w := px_size * zoom
	for gy in px_size:
		for gx in px_size:
			draw_rect(Rect2(pan + Vector2(gx, gy) * zoom, Vector2(zoom, zoom)), CHECK_A if (gx + gy) % 2 == 0 else CHECK_B)
	if onion != null:
		draw_texture_rect(onion, Rect2(pan, Vector2(w, w)), false, Color(1, 1, 1, 0.30))
	if _tex != null:
		draw_texture_rect(_tex, Rect2(pan, Vector2(w, w)), false)
	# 浮动块
	if not _float.is_empty():
		for e in _float:
			var fp: Vector2i = e["p"] + _float_off
			if _in(fp):
				draw_rect(Rect2(pan + Vector2(fp) * zoom, Vector2(zoom, zoom)), e["c"])
	# 形状预览
	if _drawing and not _preview.is_empty():
		var pc := Color(brush.r, brush.g, brush.b, 0.75)
		for p in _all_pts(_preview):
			if _in(p):
				draw_rect(Rect2(pan + Vector2(p) * zoom, Vector2(zoom, zoom)), pc)
	if show_grid and zoom >= 8:
		var gc := Color(1, 1, 1, 0.08)
		for i in range(px_size + 1):
			draw_line(pan + Vector2(i * zoom, 0), pan + Vector2(i * zoom, w), gc, 1.0)
			draw_line(pan + Vector2(0, i * zoom), pan + Vector2(w, i * zoom), gc, 1.0)
	# 选区轮廓（含浮动块）
	_draw_sel_outline()
	# 矩形选取拖动框
	if _sel_dragging:
		var xa := mini(_sel_rect_a.x, _sel_rect_b.x); var xb := maxi(_sel_rect_a.x, _sel_rect_b.x)
		var ya := mini(_sel_rect_a.y, _sel_rect_b.y); var yb := maxi(_sel_rect_a.y, _sel_rect_b.y)
		draw_rect(Rect2(pan + Vector2(xa, ya) * zoom, Vector2((xb - xa + 1) * zoom, (yb - ya + 1) * zoom)), Color(1, 1, 1, 0.9), false, 1.0)
	draw_rect(Rect2(pan, Vector2(w, w)), Color(0, 0, 0, 0.6), false, 1.0)

func _draw_sel_outline() -> void:
	var cells := {}
	if not _float.is_empty():
		for e in _float:
			cells[e["p"] + _float_off] = true
	else:
		cells = _sel
	if cells.is_empty():
		return
	for k in cells:
		var p: Vector2i = k
		var o := pan + Vector2(p) * zoom
		if not cells.has(Vector2i(p.x, p.y - 1)): _edge(o, o + Vector2(zoom, 0))
		if not cells.has(Vector2i(p.x, p.y + 1)): _edge(o + Vector2(0, zoom), o + Vector2(zoom, zoom))
		if not cells.has(Vector2i(p.x - 1, p.y)): _edge(o, o + Vector2(0, zoom))
		if not cells.has(Vector2i(p.x + 1, p.y)): _edge(o + Vector2(zoom, 0), o + Vector2(zoom, zoom))

func _edge(a: Vector2, b: Vector2) -> void:
	draw_line(a, b, Color(0, 0, 0, 0.9), 2.0)
	draw_line(a, b, Color(1, 1, 1, 0.95), 1.0)

# —— 输入 ——
func _gui_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed:
		_key(e); return
	if e is InputEventMouseButton:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP and e.pressed:
			_zoom_to(_zi() + 1, e.position); return
		if e.button_index == MOUSE_BUTTON_WHEEL_DOWN and e.pressed:
			_zoom_to(_zi() - 1, e.position); return
		if e.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = e.pressed; _pan_start = e.position - pan; return
		var p := _px(e.position)
		if e.button_index == MOUSE_BUTTON_RIGHT and e.pressed:
			_pick(p); return
		if e.button_index == MOUSE_BUTTON_LEFT:
			if e.pressed:
				grab_focus()
				_press(p)
			else:
				_release(p)
	elif e is InputEventMouseMotion:
		if _panning:
			pan = e.position - _pan_start; queue_redraw()
		elif _moving:
			_float_off = _move_origin + (_px(e.position) - _move_start); queue_redraw()
		elif _sel_dragging:
			_sel_rect_b = _px(e.position); queue_redraw()
		elif _drawing:
			var p := _px(e.position)
			if tool in ["line", "rect", "rectf"]:
				_preview = _shape(_start, p); queue_redraw()
			else:
				_line(_last, p); _last = p; _rebuild()

func _press(p: Vector2i) -> void:
	match tool:
		"select":
			if not _float.is_empty() and _sel.has(p):
				_moving = true; _move_start = p; _move_origin = _float_off
			elif _sel.has(p):
				_snapshot(); _lift(true); _moving = true; _move_start = p; _move_origin = _float_off
			else:
				_commit_float(); _sel_dragging = true; _sel_rect_a = p; _sel_rect_b = p; queue_redraw()
		"wand":
			_commit_float(); _wand(p); queue_redraw()
		"fill":
			_snapshot(); _flood(p); _rebuild()
		"pick":
			_pick(p)
		"line", "rect", "rectf":
			_snapshot(); _drawing = true; _start = p; _preview = [p]; queue_redraw()
		_:
			_snapshot(); _drawing = true; _last = p; _paint(p); _rebuild()

func _release(_p: Vector2i) -> void:
	if _sel_dragging:
		_sel_dragging = false
		_select_rect(_sel_rect_a, _sel_rect_b); queue_redraw()
	elif _moving:
		_moving = false
	elif _drawing and tool in ["line", "rect", "rectf"]:
		for q in _all_pts(_preview):
			_put(q)
		_preview = []; _rebuild()
	_drawing = false; _last = Vector2i(-999, -999)

func _key(e: InputEventKey) -> void:
	if e.ctrl_pressed or e.meta_pressed:
		match e.keycode:
			KEY_C: _copy(); accept_event()
			KEY_X: _snapshot(); _copy(); _delete_sel(); accept_event()
			KEY_V: _paste(); accept_event()
			KEY_A: _select_rect(Vector2i(0, 0), Vector2i(px_size - 1, px_size - 1)); accept_event()
			KEY_Z: undo(); accept_event()
	else:
		match e.keycode:
			KEY_DELETE, KEY_BACKSPACE: _snapshot(); _delete_sel(); accept_event()
			KEY_ESCAPE: _commit_float(); _clear_sel(); accept_event()

func _px(pos: Vector2) -> Vector2i:
	return Vector2i(int(floor((pos.x - pan.x) / zoom)), int(floor((pos.y - pan.y) / zoom)))

func _in(p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < px_size and p.y < px_size

func _mir(p: Vector2i) -> Vector2i:
	return Vector2i(px_size - 1 - p.x, p.y)

func _all_pts(list: Array) -> Array:
	if not mirror_x:
		return list
	var out := []
	for p in list:
		out.append(p); out.append(_mir(p))
	return out

func _put(p: Vector2i) -> void:
	if not _in(p):
		return
	img.set_pixelv(p, Color(0, 0, 0, 0) if tool == "eraser" else brush)

func _paint(p: Vector2i) -> void:
	_put(p)
	if mirror_x:
		_put(_mir(p))

func _line(a: Vector2i, b: Vector2i) -> void:
	for q in _bresenham(a, b):
		_paint(q)

func _shape(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	match tool:
		"line": return _bresenham(a, b)
		"rect": return _rect_pts(a, b, false)
		"rectf": return _rect_pts(a, b, true)
	return [] as Array[Vector2i]

func _bresenham(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var dx := absi(b.x - a.x); var dy := absi(b.y - a.y)
	var sx := 1 if a.x < b.x else -1; var sy := 1 if a.y < b.y else -1
	var err := dx - dy; var x := a.x; var y := a.y
	while true:
		out.append(Vector2i(x, y))
		if x == b.x and y == b.y:
			break
		var e2 := 2 * err
		if e2 > -dy: err -= dy; x += sx
		if e2 < dx: err += dx; y += sy
	return out

func _rect_pts(a: Vector2i, b: Vector2i, filled: bool) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var xa := mini(a.x, b.x); var xb := maxi(a.x, b.x)
	var ya := mini(a.y, b.y); var yb := maxi(a.y, b.y)
	for y in range(ya, yb + 1):
		for x in range(xa, xb + 1):
			if filled or x == xa or x == xb or y == ya or y == yb:
				out.append(Vector2i(x, y))
	return out

func _pick(p: Vector2i) -> void:
	if not _in(p):
		return
	var c := img.get_pixelv(p)
	if c.a <= 0.0:
		return
	brush = c
	color_picked.emit(c)

func _flood(p: Vector2i) -> void:
	if not _in(p):
		return
	var target := img.get_pixelv(p)
	if target.is_equal_approx(brush):
		return
	var stack: Array[Vector2i] = [p]
	while not stack.is_empty():
		var q: Vector2i = stack.pop_back()
		if not _in(q) or not img.get_pixelv(q).is_equal_approx(target):
			continue
		img.set_pixelv(q, brush)
		stack.append(Vector2i(q.x + 1, q.y)); stack.append(Vector2i(q.x - 1, q.y))
		stack.append(Vector2i(q.x, q.y + 1)); stack.append(Vector2i(q.x, q.y - 1))

# —— 选区 ——
func _select_rect(a: Vector2i, b: Vector2i) -> void:
	_sel = {}
	var xa := clampi(mini(a.x, b.x), 0, px_size - 1); var xb := clampi(maxi(a.x, b.x), 0, px_size - 1)
	var ya := clampi(mini(a.y, b.y), 0, px_size - 1); var yb := clampi(maxi(a.y, b.y), 0, px_size - 1)
	for y in range(ya, yb + 1):
		for x in range(xa, xb + 1):
			_sel[Vector2i(x, y)] = true

func _wand(p: Vector2i) -> void:
	if not _in(p):
		return
	_sel = {}
	var target := img.get_pixelv(p)
	var seen := {}
	var stack: Array[Vector2i] = [p]
	while not stack.is_empty():
		var q: Vector2i = stack.pop_back()
		if not _in(q) or seen.has(q):
			continue
		seen[q] = true
		if not img.get_pixelv(q).is_equal_approx(target):
			continue
		_sel[q] = true
		stack.append(Vector2i(q.x + 1, q.y)); stack.append(Vector2i(q.x - 1, q.y))
		stack.append(Vector2i(q.x, q.y + 1)); stack.append(Vector2i(q.x, q.y - 1))

func _clear_sel() -> void:
	_sel = {}; _sel_dragging = false; queue_redraw()

func _lift(cut: bool) -> void:
	# 把选区提成浮动块（cut=从图上抹掉）
	_float = []; _float_off = Vector2i.ZERO
	for k in _sel:
		var p: Vector2i = k
		_float.append({"p": p, "c": img.get_pixelv(p)})
		if cut:
			img.set_pixelv(p, Color(0, 0, 0, 0))
	if cut:
		_rebuild()

func _commit_float() -> void:
	if _float.is_empty():
		return
	var ns := {}
	for e in _float:
		var fp: Vector2i = e["p"] + _float_off
		if _in(fp) and e["c"].a > 0.0:
			img.set_pixelv(fp, e["c"])
			ns[fp] = true
	_float = []; _float_off = Vector2i.ZERO
	_sel = ns
	_rebuild()

func _copy() -> void:
	var use_float := not _float.is_empty()
	_clip = []
	if use_float:
		var src := _float
		var minx := 99999; var miny := 99999
		for e in src:
			var fp: Vector2i = e["p"] + _float_off
			minx = mini(minx, fp.x); miny = mini(miny, fp.y)
		for e in src:
			var fp: Vector2i = e["p"] + _float_off
			_clip.append({"p": fp - Vector2i(minx, miny), "c": e["c"]})
	elif not _sel.is_empty():
		var minx := 99999; var miny := 99999
		for k in _sel:
			minx = mini(minx, (k as Vector2i).x); miny = mini(miny, (k as Vector2i).y)
		for k in _sel:
			var p: Vector2i = k
			_clip.append({"p": p - Vector2i(minx, miny), "c": img.get_pixelv(p)})

func _paste() -> void:
	if _clip.is_empty():
		return
	_snapshot()
	_commit_float()
	tool = "select"
	_float = []
	for e in _clip:
		_float.append({"p": e["p"], "c": e["c"]})
	_float_off = Vector2i(2, 2)
	_sel = {}
	for e in _float:
		_sel[e["p"] + _float_off] = true
	queue_redraw()

func _delete_sel() -> void:
	if not _float.is_empty():
		_float = []; _clear_sel(); _rebuild(); return
	if _sel.is_empty():
		return
	for k in _sel:
		img.set_pixelv(k, Color(0, 0, 0, 0))
	_clear_sel(); _rebuild()

# 工具栏调用
func copy_sel() -> void: _copy()
func cut_sel() -> void: _snapshot(); _copy(); _delete_sel()
func paste() -> void: _paste()
func delete_sel() -> void: _snapshot(); _delete_sel()

func _snapshot() -> void:
	_undo.append(img.duplicate())
	if _undo.size() > 40:
		_undo.pop_front()
