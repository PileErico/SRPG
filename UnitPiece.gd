extends RefCounted
## 「单位即棋子」渲染：把拼装好的角色精灵直接立在地块上——脚下阵营色椭圆光环 + 地面阴影，取代圆底 token。
## 仅用于有完整外观(appearance_*)的单位；无外观单位仍走 SandboxCanvas 的圆底 token。
## 纯静态无状态，仿 HexTileRender：extends RefCounted + 静态 + 无 class_name（headless 友好）。
## 谁用：SandboxCanvas._draw_unit（战场）＋ EditorCanvas._draw_units（编辑器）＋ 外观工坊预览——**三处同一出处**。
##
## 底盘对齐＝自动（不再靠手调三滑条）：从精灵内容量「站立锚点」(PaperDoll.measure_anchor)——
## 脚点对到环心、按包围盒高归一到统一基准、椭圆环宽跟随站宽贴身。look 里只留 size_mult(体型倍数) + dx/dy(可选微调)。

const AppearanceDB := preload("res://AppearanceDB.gd")
const PaperDoll := preload("res://PaperDoll.gd")

# —— 底盘/归一常量（改这里统一调观感）——
const TARGET_H := 2.7        # 角色包围盒目标高 ÷ r（高度归一基准；≈一个 hex 高，size_mult=1 时的贴图高）
const RING_ASPECT := 0.32    # 椭圆环 竖半径÷横半径（扁平俯视感）
const RING_FOOT_K := 0.60    # 环横半径 = 站宽 × K（环略宽于脚）
const RING_RX_MIN := 0.45    # 环横半径下限 ÷ r（防细脚角色环过小）
const RING_RX_MAX := 1.05    # 环横半径上限 ÷ r（防宽身角色环过大）
const SINK_RATIO := 0.35     # 脚陷入环 = 环竖半径 × SINK（"踩地"感）

static var _anchor_cache := {}   # 贴图 RID -> 归一化锚点（一次量、按贴图缓存；编辑部件后 clear_anchor_cache）

# 「该单位是否有工坊拼装外观」的单一判定：按 proto_id 查 look。有→返回 look，无→{}。
# 编辑器(proto.id)与战场(u.proto_id)都调这个，杜绝两套分叉。
static func look_for(proto_id: String) -> Dictionary:
	if proto_id == "":
		return {}
	var l = AppearanceDB.get_look(proto_id)
	return l if (typeof(l) == TYPE_DICTIONARY and l.has("parts")) else {}

# 从 look 取棋子微调（含默认值单一出处）。新配方＝{size_mult,dx,dy}；旧配方(有 scale 无 size_mult)→按全自动重置。
static func piece_opts(look: Dictionary) -> Dictionary:
	var pc = look.get("piece", {})
	if typeof(pc) == TYPE_DICTIONARY and pc.has("size_mult"):
		return {"size_mult": float(pc.get("size_mult", 1.0)), "dx": float(pc.get("dx", 0.0)), "dy": float(pc.get("dy", 0.0))}
	return {"size_mult": 1.0, "dx": 0.0, "dy": 0.0}

# 把一个单位棋子画到 ci 上。底盘/精灵尺寸全自动，opts 只留可选微调。
#   ground   格心（世界坐标；动画/飞行由调用方算好传 ground/lift）
#   r        棋子基准半径（＝HEX_SIZE*0.62，用于脚垫/环尺寸的度量基准）
#   tex      合成好的角色精灵（方形，透明留白任意；脚点由内容自动量出）
#   fac      阵营色
#   o        可选：{acted, flashing, deaths, active, viewed, lift, tint,
#                    size_mult(体型倍数,默认1), dx, dy(精灵相对脚线的手动微调,世界px),
#                    anchor(归一化锚点;缺省则从 tex 内容量并缓存)}
static func draw_piece(ci: CanvasItem, ground: Vector2, r: float, tex: Texture2D, fac: Color, o: Dictionary = {}) -> void:
	var acted := bool(o.get("acted", false))
	var flashing := bool(o.get("flashing", false))
	var lift := float(o.get("lift", 0.0))
	var dx := float(o.get("dx", 0.0))
	var dy := float(o.get("dy", 0.0))
	var size_mult := float(o.get("size_mult", 1.0))
	if size_mult <= 0.0:
		size_mult = 1.0
	var gt: Color = o.get("tint", Color.WHITE)   # 整体色调（编辑器非单位层压淡：alpha<1）
	var ga := gt.a
	var feet := ground + Vector2(0.0, r * 0.42)   # 脚底线＝格心稍下（底盘固定在此，标记格位）

	# 锚点：opts 带则用，否则从贴图内容量（按 RID 缓存）
	var anchor: Dictionary = o.get("anchor", {})
	if anchor.is_empty():
		anchor = _anchor_for(tex)

	# 由锚点推 scale（高度归一）、站宽（环宽贴身）
	var wt := float(maxi(1, tex.get_width())) if tex != null else 1.0
	var ht := float(maxi(1, tex.get_height())) if tex != null else 1.0
	var bh_px := maxf(1.0, float(anchor.get("bh", 1.0)) * ht)
	var scale := (TARGET_H * r * size_mult) / bh_px
	var foot_w_world := float(anchor.get("fw", 0.5)) * wt * scale
	var ring_rx := clampf(foot_w_world * RING_FOOT_K, r * RING_RX_MIN, r * RING_RX_MAX)
	var ring_ry := ring_rx * RING_ASPECT

	# 接地软阴影（多层椭圆叠出柔边 AO，把单位"吸"在地上）+ 脚下阵营色椭圆光环（填充淡色 + 亮描边）——尺寸随站宽
	ci.draw_colored_polygon(_ell(feet, ring_rx * 1.35, ring_ry * 1.45), Color(0, 0, 0, 0.13 * ga))
	ci.draw_colored_polygon(_ell(feet, ring_rx * 1.12, ring_ry * 1.18), Color(0, 0, 0, 0.19 * ga))
	ci.draw_colored_polygon(_ell(feet, ring_rx * 0.85, ring_ry * 0.90), Color(0, 0, 0, 0.25 * ga))
	ci.draw_colored_polygon(_ell(feet, ring_rx, ring_ry), Color(fac.r, fac.g, fac.b, 0.50 * ga))
	_ring(ci, feet, ring_rx, ring_ry, Color(fac.r, fac.g, fac.b, 0.95 * ga), 1.5)
	# 状态环（脚下椭圆，随底盘尺寸）
	if bool(o.get("deaths", false)):
		_ring(ci, feet, ring_rx * 1.20, ring_ry * 1.35, Color(0.78, 0.42, 0.84, 0.95 * ga), 2.5)
	if bool(o.get("active", false)):
		_ring(ci, feet, ring_rx * 1.08, ring_ry * 1.15, Color(0.55, 0.95, 0.55, 0.95 * ga), 2.5)
	if bool(o.get("viewed", false)):
		_ring(ci, feet, ring_rx * 1.34, ring_ry * 1.60, Color(1.0, 0.9, 0.3, 0.95 * ga), 2.5)

	# 精灵：把锚点脚点对到脚线(下陷 + 手动微调)，按 scale 立起；飞行整体抬升 lift
	if tex != null:
		var sink := ring_ry * SINK_RATIO
		var target := Vector2(feet.x + dx, feet.y - lift + dy + sink)
		var foot_tex := Vector2(float(anchor.get("fx", 0.5)) * wt, float(anchor.get("fy", 1.0)) * ht)
		var tl := target - foot_tex * scale
		var tint := Color(1.0, 0.35, 0.35, ga) if flashing else (Color(0.55, 0.55, 0.55, ga) if acted else Color(gt.r, gt.g, gt.b, ga))
		ci.draw_texture_rect(tex, Rect2(tl, Vector2(wt * scale, ht * scale)), false, tint)

# 贴图 → 归一化锚点（按 RID 缓存；量一次）。取不到 image 时返回空（draw_piece 兜底居中）。
static func _anchor_for(tex: Texture2D) -> Dictionary:
	if tex == null:
		return {}
	var key := tex.get_rid().get_id()
	if _anchor_cache.has(key):
		return _anchor_cache[key]
	var img := tex.get_image()
	var a := PaperDoll.measure_anchor(img) if img != null else {}
	_anchor_cache[key] = a
	return a

# 编辑部件/重烘后调（贴图内容变了，旧锚点作废）。
static func clear_anchor_cache() -> void:
	_anchor_cache.clear()

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
