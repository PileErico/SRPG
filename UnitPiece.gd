extends RefCounted
## 「单位即棋子」渲染：把拼装好的角色精灵直接立在地块上——脚下阵营色椭圆光环 + 地面阴影，取代圆底 token。
## 仅用于有完整外观(appearance_*)的单位；无外观单位仍走 SandboxCanvas 的圆底 token。
## 纯静态无状态，仿 HexTileRender：extends RefCounted + 静态 + 无 class_name（headless 友好）。
## 谁用：SandboxCanvas._draw_unit（战场）＋ EditorCanvas._draw_units（编辑器）＋ 外观工坊预览——**三处同一出处**。

const AppearanceDB := preload("res://AppearanceDB.gd")

# 「该单位是否有工坊拼装外观」的单一判定：按 proto_id 查 look。有→返回 look，无→{}。
# 编辑器(proto.id)与战场(u.proto_id)都调这个，杜绝两套分叉。
static func look_for(proto_id: String) -> Dictionary:
	if proto_id == "":
		return {}
	var l = AppearanceDB.get_look(proto_id)
	return l if (typeof(l) == TYPE_DICTIONARY and l.has("parts")) else {}

# 从 look 取棋子放置微调（含默认值单一出处）。
static func piece_opts(look: Dictionary) -> Dictionary:
	var pc = look.get("piece", {})
	if typeof(pc) != TYPE_DICTIONARY:
		pc = {}
	return {"scale": float(pc.get("scale", 2.0)), "dx": float(pc.get("dx", 0.0)), "dy": float(pc.get("dy", 24.0))}

# 把一个单位棋子画到 ci 上。
#   ground   格心（世界坐标；动画/飞行由调用方算好传 ground/lift）
#   r        棋子基准半径（＝HEX_SIZE*0.62，用于脚垫/环尺寸）
#   tex      合成好的角色精灵（方形，脚在底部附近）
#   fac      阵营色
#   o        可选：{acted, flashing, deaths, active, viewed, lift,
#                    scale(每画布像素→世界像素，0/缺省=自动), dx, dy(精灵相对脚线的手动微调)}
static func draw_piece(ci: CanvasItem, ground: Vector2, r: float, tex: Texture2D, fac: Color, o: Dictionary = {}) -> void:
	var acted := bool(o.get("acted", false))
	var flashing := bool(o.get("flashing", false))
	var lift := float(o.get("lift", 0.0))
	var dx := float(o.get("dx", 0.0))
	var dy := float(o.get("dy", 0.0))
	var gt: Color = o.get("tint", Color.WHITE)   # 整体色调（编辑器非单位层压淡：alpha<1）
	var ga := gt.a
	var feet := ground + Vector2(0.0, r * 0.42)   # 脚底线＝格心稍下（阴影/光环固定在此，标记格位）

	# 地面阴影（贴地，不随漂浮上下动）
	ci.draw_colored_polygon(_ell(feet, r * 0.95, r * 0.34), Color(0, 0, 0, 0.40 * ga))
	# 脚下阵营色椭圆光环（填充淡色 + 亮描边）
	ci.draw_colored_polygon(_ell(feet, r * 0.82, r * 0.26), Color(fac.r, fac.g, fac.b, 0.50 * ga))
	_ring(ci, feet, r * 0.82, r * 0.26, Color(fac.r, fac.g, fac.b, 0.95 * ga), 1.5)
	# 状态环（脚下椭圆，替代原圆环）
	if bool(o.get("deaths", false)):
		_ring(ci, feet, r * 0.99, r * 0.35, Color(0.78, 0.42, 0.84, 0.95 * ga), 2.5)
	if bool(o.get("active", false)):
		_ring(ci, feet, r * 0.90, r * 0.30, Color(0.55, 0.95, 0.55, 0.95 * ga), 2.5)
	if bool(o.get("viewed", false)):
		_ring(ci, feet, r * 1.10, r * 0.42, Color(1.0, 0.9, 0.3, 0.95 * ga), 2.5)

	# 精灵：底边中点对齐 (脚线+dx,dy)、向上立起；飞行整体抬升 lift。scale 缺省＝让精灵约 3.9r 高。
	if tex != null:
		var sz := float(maxi(1, tex.get_width()))
		var scale := float(o.get("scale", 0.0))
		if scale <= 0.0:
			scale = r * 3.9 / sz
		var h := sz * scale
		var w := float(tex.get_height()) * scale if tex.get_height() > 0 else h
		var bx := feet.x + dx
		var by := feet.y + dy - lift
		var tint := Color(1.0, 0.35, 0.35, ga) if flashing else (Color(0.55, 0.55, 0.55, ga) if acted else Color(gt.r, gt.g, gt.b, ga))
		ci.draw_texture_rect(tex, Rect2(Vector2(bx - w * 0.5, by - h), Vector2(w, h)), false, tint)

# 自动缩放的默认 scale（供 UI 滑条初值）。
static func auto_scale(tex: Texture2D, r: float) -> float:
	if tex == null or tex.get_width() <= 0:
		return 1.0
	return r * 3.9 / float(tex.get_width())

static func _ell(center: Vector2, rx: float, ry: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 24:
		var a := TAU * float(i) / 24.0
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	return pts

static func _ring(ci: CanvasItem, center: Vector2, rx: float, ry: float, color: Color, width: float) -> void:
	var pts := _ell(center, rx, ry)
	pts.append(pts[0])
	ci.draw_polyline(pts, color, width)
