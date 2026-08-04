extends Control
## 地块对照预览：画所选变体的中心格 + 周围 6 邻格（实时拼贴），供地块绘制工坊 WYSIWYG 对照。
## 仿 PiecePreview（去掉单位/阵营那半）；用与地图完全同一 HexTileRender.draw_tile。

const HexTileRender := preload("res://HexTileRender.gd")

const R := 24.0   # 与地图原始格半径一致

var _color := Color(0.36, 0.62, 0.32)
var _accent := Color(0.5, 0.7, 0.4)
var _decor := "grass"
var _art: Array = []
var _idx := 0
var _anchor := -1.0   # 赤道锚行覆盖（放置物 art_anchor / 绘制中 live 预览钉 hex 赤道）；-1＝按贴图自算
var _ground := false  # 放置物条目：先铺程序兜底地面、再叠 art（仿地图「地形→放置物」两遍绘制）
# 交互缩放/平移（2026-07-20 用户令：预览太小看不清接缝细节）
var _zoom_step := 0        # 滚轮增减的显示级（0＝自动适配控件大小）
var _pan := Vector2.ZERO   # 拖拽平移（缩放前坐标系）
var _drag := false
var _last_dz := 1.0

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	custom_minimum_size = Vector2(260, 260)
	clip_contents = true
	tooltip_text = "滚轮缩放 · 左键拖拽平移 · 右键复位"

func set_tile(color: Color, accent: Color, decor: String, art: Array, idx: int, anchor := -1.0, ground := false) -> void:
	_color = color; _accent = accent; _decor = decor; _art = art; _idx = idx; _anchor = anchor; _ground = ground
	queue_redraw()

func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		if e.pressed and e.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_step = mini(_zoom_step + 1, 24)
			queue_redraw(); accept_event()
		elif e.pressed and e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_step = maxi(_zoom_step - 1, -8)
			queue_redraw(); accept_event()
		elif e.pressed and e.button_index == MOUSE_BUTTON_RIGHT:
			_zoom_step = 0; _pan = Vector2.ZERO
			queue_redraw(); accept_event()
		elif e.button_index == MOUSE_BUTTON_LEFT:
			_drag = e.pressed
			accept_event()
	elif e is InputEventMouseMotion and _drag:
		_pan += e.relative / _last_dz
		queue_redraw()

func _draw() -> void:
	# 等比显示缩放：撑满控件、保地图比例（不破坏像素密度 WYSIWYG）＋滚轮整数级缩放（像素不糊）
	var auto: float = maxf(1.0, floorf(min(size.x / (4.6 * R), size.y / (4.6 * R))))
	var dz: float = maxf(1.0, auto + float(_zoom_step))
	_last_dz = dz
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(dz, dz))
	var vw := size.x / dz
	var vh := size.y / dz
	var c := Vector2(vw * 0.5, vh * 0.5) + _pan
	var h := 0.866 * R
	var offs := [Vector2(0, 0), Vector2(0, -2 * h), Vector2(0, 2 * h),
		Vector2(1.5 * R, -h), Vector2(1.5 * R, h), Vector2(-1.5 * R, -h), Vector2(-1.5 * R, h)]
	# 中心＝所选变体（seed=_idx 使 pick_art 命中该张）；邻格散不同 seed，看拼贴混合效果
	var cells := []
	for i in offs.size():
		cells.append({"off": offs[i], "seed": (_idx if i == 0 else i * 911 + 7)})
	# Diamond-Down：按 y 升序画（与 HexCanvas._paint_chunk 同口径）——下方格后画、盖住上方格的崖裙/侧壁
	cells.sort_custom(func(a, b): return a.off.y < b.off.y)
	if _ground:
		# 放置物：先整层铺程序兜底地面（entry 本色），再整层叠 art——仿地图「地形→放置物」两遍绘制
		for cl in cells:
			HexTileRender.draw_tile(self, c + cl.off, R, _color, _accent, "none", cl.seed, false, [])
	for cl in cells:
		HexTileRender.draw_tile(self, c + cl.off, R, _color, _accent, _decor, cl.seed, true, _art, _anchor)
