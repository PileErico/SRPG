extends "res://HexCanvas.gd"
## sandbox 画布：复用编辑器的六边形渲染 + 视图变换（平移/缩放/悬停），
## 在地形之上叠画单位 token。输入沿用父类（中键平移、滚轮缩放、悬停）；
## 左右键在 sandbox 宿主里是空操作（不绘制地形）。

const TextureCache := preload("res://TextureCache.gd")   # 图标加载 + 缓存单一入口
var _fly_phase := 0.0   # 飞行漂浮相位（_process 累加，仅在场上有飞行单位时推进+重绘）

func _ready() -> void:
	super()
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # 像素图标放大不糊

# 仅当场上存在飞行单位时才连续重绘（推进漂浮相位）；否则保持事件驱动、不空转
func _process(delta: float) -> void:
	if editor == null:
		return
	for u in editor.units:
		if u.is_airborne():
			_fly_phase += delta * 2.4
			queue_redraw()
			return

# 左键＝点格指令（按下即触发、不拖拽绘制）；右键＝取消；中键/滚轮/悬停沿用父类
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_handle_left_click(event.position)
			accept_event()
			return
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if editor != null:
				if editor.phase == "deploy":
					var off := pixel_to_offset(_world_from_screen(event.position))
					if _in_bounds(off):
						editor.deploy_right_click(off.x, off.y)   # 撤下已布置单位回待命
					else:
						editor.cancel_action()
				else:
					editor.cancel_action()
			accept_event()
			return
	super(event)

func _handle_left_click(screen_pos: Vector2) -> void:
	if editor == null:
		return
	var off := pixel_to_offset(_world_from_screen(screen_pos))
	if _in_bounds(off):
		editor.left_click_cell(off.x, off.y)
	else:
		editor.cancel_action()

# 布置阶段：从底部「可用单位」栏拖来的单位（RosterBar.RosterSlot 提供数据），放到鼠标所在格子
func _can_drop_data(_at_position: Vector2, data) -> bool:
	return editor != null and editor.phase == "deploy" \
		and typeof(data) == TYPE_DICTIONARY and data.get("kind") == "roster_unit"

func _drop_data(at_position: Vector2, data) -> void:
	if editor == null:
		return
	var off := pixel_to_offset(_world_from_screen(at_position))
	if _in_bounds(off):
		editor.deploy_drop(off.x, off.y, data)

# 鼠标换格：移动模式即时重建路径线；任何时候都更新「悬停单位的范围预览」
func _update_hover(screen_pos: Vector2) -> void:
	super(screen_pos)
	if editor == null:
		return
	if editor.move_mode:
		editor.update_hover_path(hover_cell)
		queue_redraw()
	editor.update_unit_hover(hover_cell)

# 鼠标移出画布：清掉悬停范围预览
func _on_mouse_exit() -> void:
	super()
	if editor != null:
		editor.update_unit_hover(Vector2i(-1, -1))

func _draw() -> void:
	super()  # 先画地形 + 悬停高亮（HexCanvas）
	if editor == null:
		return
	# 此处 draw_set_transform 仍是父类设的视图变换，直接用世界坐标画单位即可对齐
	_draw_fog()          # 战争迷雾：黑遮未探索 / 压暗探索过（盖在地形上、其余层之下）
	_draw_regions()      # 仇恨触发区域（淡紫，最底层；调试可见）
	_draw_deploy_zone()  # 部署区（布置阶段高亮，蓝色）：玩家单位只能放这里
	# 范围层（移动/攻击）：先攻击(浅红)、后移动(我方浅蓝 / 敌方浅黄)，移动盖在攻击上
	for ov in editor.range_overlays:
		_draw_cells(ov["attack"], ov["atk_color"])
		_draw_cells(ov["reach"], ov["move_color"])
	for ov in editor.range_overlays:   # ZOC 红框画最上层，避免被范围填充盖住
		_draw_zoc(ov.get("zoc", {}))
	if editor.move_mode:
		_draw_move_path()
	_draw_hover_unit()   # 行动顺序槽悬停 → 高亮该单位所在格（在单位 token 之下）
	for u in editor.units:
		if editor._unit_hidden_by_fog(u):
			continue     # 迷雾里的敌人不渲染（看不到）
		_draw_unit(u)

# 把一组格按给定色填充（范围层通用）
func _draw_cells(cells: Dictionary, color: Color) -> void:
	for cell in cells:
		draw_colored_polygon(hex_corners(hex_center(cell.x, cell.y)), color)

# 战争迷雾：黑(未探索)不透明全遮 / 灰(探索过·当前无观测)半透明压暗。仅战斗阶段且非全知才画（见 Sandbox.cell_fog）。
const FOG_BLACK := Color(0.03, 0.03, 0.05, 1.0)   # 未探索：不透明，盖住地形
const FOG_GRAY := Color(0.02, 0.02, 0.05, 0.55)   # 探索过·无观测：半透明压暗，地形透出
func _draw_fog() -> void:
	if editor.phase != "battle" or editor.omniscient:
		return
	for row in editor.height:
		for col in editor.width:
			var f: int = editor.cell_fog(Vector2i(col, row))
			if f == 2:
				continue
			draw_colored_polygon(hex_corners(hex_center(col, row)), FOG_BLACK if f == 0 else FOG_GRAY)

# 仇恨触发区域：淡紫填充（调试可见；将来正式关卡可隐藏）
func _draw_regions() -> void:
	for rid in editor.aggro_regions:
		for cell in editor.aggro_regions[rid]:
			draw_colored_polygon(hex_corners(hex_center(cell.x, cell.y)), Color(0.75, 0.40, 0.95, 0.12))

# 部署区：仅布置阶段高亮（蓝填充 + 描边），提示玩家单位可放的格
func _draw_deploy_zone() -> void:
	if editor.phase != "deploy" or editor._deploy_cells.is_empty():
		return
	for cell in editor._deploy_cells:
		var pts := hex_corners(hex_center(cell.x, cell.y))
		draw_colored_polygon(pts, Color(0.30, 0.65, 1.0, 0.22))
		var outline := PackedVector2Array(pts)
		outline.append(pts[0])
		draw_polyline(outline, Color(0.45, 0.75, 1.0, 0.7), 1.5 / view_zoom)

# ZOC（控制区）：单位周围一圈地块填红（比攻击范围更深一点，叠在最上层突出）
func _draw_zoc(cells: Dictionary) -> void:
	for cell in cells:
		draw_colored_polygon(hex_corners(hex_center(cell.x, cell.y)), Color(0.85, 0.10, 0.10, 0.42))

# 行动顺序槽悬停的单位：在地图上高亮其所在格（青白填充 + 描边，区别于黄色地形悬停）
func _draw_hover_unit() -> void:
	var u = editor.hover_unit
	if u == null or editor._unit_hidden_by_fog(u):
		return   # 迷雾里的敌人不高亮位置（哪怕在行动顺序槽被扫到）
	var center := hex_center(u.col, u.row)
	var pts := hex_corners(center)
	draw_colored_polygon(pts, Color(0.55, 0.85, 1.0, 0.22))
	var outline := PackedVector2Array(pts)
	outline.append(pts[0])
	draw_polyline(outline, Color(0.65, 0.92, 1.0, 0.95), 3.0 / view_zoom, true)


# 鼠标当前路径：带宽度的箭头丝带（深蓝描边 + 更浅的半透明蓝填充，让地形透出）。
# 尺寸用世界坐标，故带宽随缩放与六边形同比例（带宽≈半条六边形边）。
const PATH_BODY_HW := 6.0       # 丝带半宽（带宽 12 ≈ 半条边，HEX_SIZE=24）
const PATH_HEAD_HW := 13.0      # 箭头外扩半宽
const PATH_HEAD_LEN := 15.0     # 箭头长度
const PATH_FILL := Color(0.55, 0.80, 1.0, 0.40)   # 更浅的蓝、半透明
const PATH_STROKE := Color(0.10, 0.35, 0.80, 0.95)  # 深蓝描边

# 移动路径丝带（注意：函数名避开父类 HexCanvas 的 _draw_path 地形纹理，故叫 _draw_move_path）
func _draw_move_path() -> void:
	var path = editor.hover_path
	if path.size() < 2:
		return
	var center := []
	for cell in path:
		center.append(hex_center(cell.x, cell.y))
	var poly := _path_ribbon(center)
	if poly.is_empty():
		return
	# 半透明浅蓝填充 + 深蓝描边
	draw_colored_polygon(poly, PATH_FILL)
	var outline := PackedVector2Array(poly)
	outline.append(poly[0])
	draw_polyline(outline, PATH_STROKE, 2.5 / view_zoom, true)  # 抗锯齿描边

# 由中心线点列构造箭头丝带轮廓多边形（纯几何，可单测）：
# 左缘正向 → 左barb → 尖 → 右barb → 右缘反向
func _path_ribbon(center: Array) -> PackedVector2Array:
	var n := center.size()
	if n < 2:
		return PackedVector2Array()
	var last_dir: Vector2 = (center[n - 1] - center[n - 2]).normalized()
	var tip: Vector2 = center[n - 1]
	var seg_len: float = center[n - 1].distance_to(center[n - 2])
	var head_len: float = min(PATH_HEAD_LEN, seg_len * 0.8)
	var head_base: Vector2 = tip - last_dir * head_len   # 箭头根部（丝带身在此收口）
	var perp := Vector2(-last_dir.y, last_dir.x)
	var body := center.duplicate()
	body[body.size() - 1] = head_base
	body = _smooth(body, 2)   # Chaikin 切角柔化拐角（保端点）
	var poly := PackedVector2Array()
	for i in body.size():
		poly.append(_offset_point(body, i, PATH_BODY_HW, 1.0))
	poly.append(head_base + perp * PATH_HEAD_HW)
	poly.append(tip)
	poly.append(head_base - perp * PATH_HEAD_HW)
	for i in range(body.size() - 1, -1, -1):
		poly.append(_offset_point(body, i, PATH_BODY_HW, -1.0))
	return poly

# Chaikin 切角：每段取 1/4、3/4 点替换拐角，迭代后折线变圆滑；保留首尾端点
func _smooth(pts: Array, iterations: int) -> Array:
	var p := pts
	for _it in iterations:
		if p.size() < 3:
			break
		var out := [p[0]]
		for i in range(p.size() - 1):
			var a: Vector2 = p[i]
			var b: Vector2 = p[i + 1]
			out.append(a.lerp(b, 0.25))
			out.append(a.lerp(b, 0.75))
		out.append(p[p.size() - 1])
		p = out
	return p

# 折线第 i 点向 side(±1) 侧偏移 hw（内角做斜接 miter，端点用相邻段法线）
func _offset_point(pts: Array, i: int, hw: float, side: float) -> Vector2:
	var n := pts.size()
	if i == 0:
		var d: Vector2 = (pts[1] - pts[0]).normalized()
		return pts[0] + Vector2(-d.y, d.x) * hw * side
	if i == n - 1:
		var d: Vector2 = (pts[n - 1] - pts[n - 2]).normalized()
		return pts[n - 1] + Vector2(-d.y, d.x) * hw * side
	var d1: Vector2 = (pts[i] - pts[i - 1]).normalized()
	var d2: Vector2 = (pts[i + 1] - pts[i]).normalized()
	var nn1 := Vector2(-d1.y, d1.x)
	var m: Vector2 = nn1 + Vector2(-d2.y, d2.x)
	if m.length() < 0.001:
		m = nn1
	else:
		m = m.normalized()
	var cosa: float = max(m.dot(nn1), 0.35)   # 钳制 miter，避免锐角尖刺
	return pts[i] + m * (hw / cosa) * side

# 行动顺序三态配色（火纹式）
const ACTED_FILL := Color(0.40, 0.40, 0.43)          # 已行动：棋子整体压灰
const ACTED_ICON := Color(0.55, 0.55, 0.55)          # 已行动：图标也压灰
const CAN_ACT_RING := Color(0.55, 0.95, 0.55, 0.95)  # 当前可行动：绿描边

func _draw_unit(u) -> void:
	# 动画期间该单位用滑动坐标，其余用格心
	var ground: Vector2 = editor._anim_pos if (editor._animating and editor._anim_unit == u) else hex_center(u.col, u.row)
	var r := HEX_SIZE * 0.62
	# 飞行：token 抬离地面 + 地面投影 + 轻微上下漂浮（每单位错相，不齐步）
	# 抬升 > 棋子半径，否则浮起的圆会盖住自己的影子（投影固定贴地、不随漂浮上下动）
	# air_t = 悬空因子（0 贴地 / 1 全悬空 / 起降过程间值）→ 起飞落地有抬升过渡，非瞬切
	var c := ground
	var air_t: float = editor.fly_factor(u)
	if air_t > 0.001:
		var bob := sin(_fly_phase + (u.col * 1.7 + u.row * 0.9)) * (HEX_SIZE * 0.07) * air_t
		var lift := HEX_SIZE * 0.72 * air_t + bob
		_draw_ground_shadow(ground, r, lift)
		c = ground - Vector2(0, lift)
	var acted: bool = editor._has_acted(u)
	var flashing: bool = editor._flash_units.has(u)
	var fill: Color = ACTED_FILL if acted else editor.faction_color(u.faction)   # 已行动→灰
	if flashing:   # 受击瞬间闪红（盖过阵营色/灰）
		fill = Color(0.95, 0.20, 0.20)
	draw_circle(c, r, fill)
	draw_arc(c, r, 0.0, TAU, 28, Color(0, 0, 0, 0.7), 2.0)
	# 死门中：紫红外环（占格垂死；条数看左下单位卡的「死门」效果与战斗记录）
	if u.tags.has("deaths_door"):
		draw_arc(c, r + 2.0, 0.0, TAU, 36, Color(0.78, 0.42, 0.84, 0.95), 3.0)
	# 当前可行动的单位：圆外浅绿描边（尚未行动者无装饰、已行动者已整体变灰）
	if editor._is_active_unit(u):
		draw_arc(c, r + 2.0, 0.0, TAU, 36, CAN_ACT_RING, 2.5)
	# 角色状态页正在查看的单位：再外一圈金色高亮
	if editor.viewed_unit == u:
		draw_arc(c, r + 4.5, 0.0, TAU, 40, Color(1.0, 0.9, 0.3, 0.95), 3.0)
	_draw_icon(u, c, r, Color(1.0, 0.35, 0.35) if flashing else (ACTED_ICON if acted else Color.WHITE))
	if flashing:   # 在图标之上再盖一层红，确保整颗棋子都红（含图标，不止露出的圆边）
		draw_circle(c, r, Color(0.95, 0.12, 0.12, 0.55))
	# 头顶血条/护甲条已移除——单位血量/护甲改在左下「光标信息栏」悬停单位卡里看（见 Sandbox.hover_extra）。
	# _draw_hp_bar/_draw_armor_bar 函数保留（将来若想「受伤才显示」再按需调用）。
	_draw_ap_pips(u, c, r)

# 飞行单位的地面投影：固定贴在原格（不随漂浮上下动），抬得越高→略小略淡（透视感，但有下限保证看得见）
func _draw_ground_shadow(ground: Vector2, r: float, lift: float) -> void:
	var k := clampf(1.0 - lift / (HEX_SIZE * 2.6), 0.6, 1.0)   # 高度衰减系数（带下限）
	var center := ground + Vector2(0.0, r * 0.30)             # 落在格心稍下、浮起 token 的正下方
	var pts := _ellipse_pts(center, r * 1.10 * k, r * 0.40 * k)
	draw_colored_polygon(pts, Color(0.0, 0.0, 0.0, 0.42 * k))

# 椭圆轮廓多边形（24 段；用于地面投影）
func _ellipse_pts(center: Vector2, rx: float, ry: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 24:
		var a := TAU * float(i) / 24.0
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	return pts

# 棋子上居中叠一个单位图标（保留圆形与阵营色，留一圈色边）；modulate 可压灰（已行动）
func _draw_icon(u, c: Vector2, r: float, modulate: Color = Color.WHITE) -> void:
	if u.icon == "":
		return
	var tex = TextureCache.get_tex(u.icon)
	if tex == null:
		return
	var s := r * 1.6
	draw_texture_rect(tex, Rect2(c - Vector2(s, s) * 0.5, Vector2(s, s)), false, modulate)

# 血条/护甲条共用尺寸：底黑窄条（同长同宽，护甲条叠在血条正上方）
const BAR_W_MUL := 1.8       # 条宽 = r·该系数
const BAR_H := 2.5           # 条高（窄）
const BAR_HP_DY := -10.0     # 血条上沿相对格心（往上挪一点、给护甲条腾位）
const BAR_ARMOR_DY := -14.0  # 护甲条上沿（血条之上、同长宽、留 1.5px 缝）

# token 上方一条血条：底黑 + 绿色按 HP/HP_max 充填。上限读 effective（含装备/buff 对 HP_max 的加成）。
func _draw_hp_bar(u, c: Vector2, r: float) -> void:
	if not u.stats.has("HP"):
		return
	var maxhp := float(u.effective_stat("HP_max"))
	if maxhp <= 0.0:
		return
	var frac := clampf(float(u.stats["HP"]) / maxhp, 0.0, 1.0)
	_draw_stat_bar(c, r, BAR_HP_DY, frac, Color(0.30, 0.80, 0.30))

# 血条之上一条护甲条：底黑 + 银色按 armor/armor_max 充填。上限读 effective——
# **护甲多来自装备 mod（如板胸甲 armor_max+75），裸 stats["armor_max"] 仍是0**，必须读 effective_stat 才画得出。
func _draw_armor_bar(u, c: Vector2, r: float) -> void:
	var maxv := float(u.effective_stat("armor_max"))
	if maxv <= 0.0:
		return   # 无护甲上限则不画
	var frac := clampf(float(u.stats.get("armor", 0)) / maxv, 0.0, 1.0)
	_draw_stat_bar(c, r, BAR_ARMOR_DY, frac, Color(0.82, 0.83, 0.86))   # 银色（中性偏冷的金属灰）

# 一条「底黑 + 按 frac 充填 fill_color」的窄状态条，上沿在格心上方 dy 处、水平居中
func _draw_stat_bar(c: Vector2, r: float, dy: float, frac: float, fill_color: Color) -> void:
	var w := r * BAR_W_MUL
	var top_left := c + Vector2(-w * 0.5, dy)
	draw_rect(Rect2(top_left, Vector2(w, BAR_H)), Color(0, 0, 0, 0.65))
	draw_rect(Rect2(top_left, Vector2(w * frac, BAR_H)), fill_color)

# token 下方一排 AP 点：实心=剩余可用 / 空心=已花（共 AP_max 个）
func _draw_ap_pips(u, c: Vector2, r: float) -> void:
	var ap_max := int(u.stats.get("AP_max", 0))
	if ap_max <= 0:
		return
	var cur := int(u.ap)
	var dot_r := 2.6
	var gap := 7.5
	var start_x := c.x - gap * (ap_max - 1) * 0.5
	var y := c.y + r + 7.0
	var col := Color(1.0, 0.85, 0.2)
	for i in ap_max:
		var p := Vector2(start_x + gap * i, y)
		if i < cur:
			draw_circle(p, dot_r, col)
		else:
			draw_arc(p, dot_r, 0.0, TAU, 12, Color(col.r, col.g, col.b, 0.7), 1.2)
