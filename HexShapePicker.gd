extends Control
## 六边形形状掩码选择器（🔒 决策30 图形化范围，2026-07-13）：画 radius 圈平顶六边形盘
## （中心格＝施放者，画 ✦ 不可选），左键点格切换选中——产出 axial 相对偏移掩码 [[dq,dr],…]
## （⚠ 掩码必须存 axial：odd-q offset 偏移随列奇偶错半格不可平移；数学单源＝HexGrid.mask_cells）。
## 通用控件：SkillEditor 选取形/作用形两处实例化；set_mask 回填 / mask() 收集（确定序）/ changed 信号。

const HexGrid := preload("res://HexGrid.gd")

signal changed

var radius := 3          # 盘半径（圈数）；3 圈=37 格，够武器/技能常用范围
var cell_px := 15.0      # 单格外接圆半径（像素）
var editable := true     # false＝只读参考盘（显示派生预览：range 圆盘/方向盘；蓝灰色区分）
var _sel := {}           # Vector2i(dq,dr) -> true

func _init() -> void:
	var w := cell_px * (3.0 * radius + 2.0)
	var h := sqrt(3.0) * cell_px * (2.0 * radius + 1.5)
	custom_minimum_size = Vector2(w, h)
	mouse_filter = Control.MOUSE_FILTER_STOP

# 回填掩码（载入表单）；坏项忽略
func set_mask(mask) -> void:
	_sel = {}
	if typeof(mask) == TYPE_ARRAY:
		for m in mask:
			if typeof(m) == TYPE_ARRAY and (m as Array).size() >= 2:
				_sel[Vector2i(int(m[0]), int(m[1]))] = true
	queue_redraw()

# 收集掩码（存盘）：按 (dr,dq) 排序＝确定序（canonical 字节级往返友好）
func mask() -> Array:
	var keys := _sel.keys()
	keys.sort_custom(func(a, b): return a.y < b.y if a.y != b.y else a.x < b.x)
	var out := []
	for k in keys:
		out.append([k.x, k.y])
	return out

func clear_mask() -> void:
	_sel = {}
	queue_redraw()
	changed.emit()

# axial(dq,dr) → 本控件像素（平顶：x=1.5s·q，y=√3s·(r+q/2)）
func _axial_to_px(a: Vector2i) -> Vector2:
	return size * 0.5 + Vector2(1.5 * cell_px * a.x, sqrt(3.0) * cell_px * (a.y + a.x * 0.5))

func _px_to_axial(p: Vector2) -> Vector2i:
	var rel := p - size * 0.5
	var qf := rel.x / (1.5 * cell_px)
	var rf := rel.y / (sqrt(3.0) * cell_px) - qf * 0.5
	var c := HexGrid.cube_round(qf, -qf - rf, rf)
	return Vector2i(c.x, c.z)

func _axial_dist(a: Vector2i) -> int:
	return int((abs(a.x) + abs(-a.x - a.y) + abs(a.y)) / 2)

func _corners(c: Vector2) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 6:
		var ang := deg_to_rad(60.0 * i)
		pts.append(c + Vector2(cos(ang), sin(ang)) * (cell_px - 1.0))
	return pts

func _gui_input(event: InputEvent) -> void:
	if not editable:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var a := _px_to_axial(event.position)
		if a == Vector2i.ZERO or _axial_dist(a) > radius:
			return
		if _sel.has(a):
			_sel.erase(a)
		else:
			_sel[a] = true
		queue_redraw()
		changed.emit()
		accept_event()

func _draw() -> void:
	var font := get_theme_default_font()
	for q in range(-radius, radius + 1):
		for r in range(-radius, radius + 1):
			var a := Vector2i(q, r)
			if _axial_dist(a) > radius:
				continue
			var c := _axial_to_px(a)
			var pts := _corners(c)
			if a == Vector2i.ZERO:
				draw_colored_polygon(pts, Color(1, 1, 1, 0.10))
				var tw := font.get_string_size("✦", HORIZONTAL_ALIGNMENT_CENTER, -1, 13).x
				draw_string(font, c + Vector2(-tw * 0.5, 4.5), "✦", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.95, 0.9, 0.7))
			elif _sel.has(a):
				# 可编＝金色；只读参考（派生自 range/作用形方向盘）＝蓝灰
				draw_colored_polygon(pts, Color(0.92, 0.74, 0.2, 0.55) if editable else Color(0.35, 0.55, 0.85, 0.38))
			else:
				draw_colored_polygon(pts, Color(1, 1, 1, 0.035))
			var line := pts.duplicate()
			line.append(line[0])
			draw_polyline(line, Color(1, 1, 1, 0.22), 1.0)
