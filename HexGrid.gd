extends RefCounted
## 纯六边形几何前置（single source）：平顶六边形（flat-top）+ odd-q 偏移。
## 收敛 cube 互转 / 距离 / 取整 / 邻居 / 连线 / 环外扩——原先散写在 Sandbox（cube 逻辑侧）
## 与 HexCanvas（axial 取整）两处，现统一到这一份，杜绝坐标序/奇偶约定单边漂移。
##
## 边界：只放纯几何——不认识像素（HEX_SIZE/视图变换留 HexCanvas）、不认识游戏规则
## （LOS 的地形 blocks_sight 判定留消费方，这里只出 line()；通行性/边界经回调注入）。
## 范式：extends RefCounted + 静态方法 + 无 class_name（headless 友好，仿 EnvDB/TerrainDB）。
## 用法：const HexGrid := preload("res://HexGrid.gd") → HexGrid.方法()。

# odd-q 邻居偏移表（方向 0..5）：偶数列 / 奇数列各一套（奇数列向下错半格所致）。
const NB_EVEN := [Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1), Vector2i(-1, -1), Vector2i(-1, 0), Vector2i(0, 1)]
const NB_ODD := [Vector2i(1, 1), Vector2i(1, 0), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1)]

# ============ cube ↔ odd-q offset 互转（唯一实现，消灭 (col-(col&1))/2 三处开写）============

# odd-q offset → cube
static func offset_to_cube(cell: Vector2i) -> Vector3i:
	var x := cell.x
	var z := cell.y - (cell.x - (cell.x & 1)) / 2
	return Vector3i(x, -x - z, z)

# cube → odd-q offset（offset_to_cube 的逆）
static func cube_to_offset(c: Vector3i) -> Vector2i:
	return Vector2i(c.x, c.z + (c.x - (c.x & 1)) / 2)

# axial(q,r) → odd-q offset（q=col，r=cube.z）：供像素拾取把取整后的 axial 落回格。
static func axial_to_offset(axial: Vector2i) -> Vector2i:
	return cube_to_offset(Vector3i(axial.x, -axial.x - axial.y, axial.y))

# ============ 距离 / 取整 ============

# 六边形距离（战斗/视野/ZOC 共用）：cube 曼哈顿 / 2
static func distance(a: Vector2i, b: Vector2i) -> int:
	var ca := offset_to_cube(a)
	var cb := offset_to_cube(b)
	return int((abs(ca.x - cb.x) + abs(ca.y - cb.y) + abs(ca.z - cb.z)) / 2)

# cube 浮点坐标四舍五入到合法 cube 格（x+y+z=0）。唯一取整器——axial_round 内部转 cube 后调它。
static func cube_round(xf: float, yf: float, zf: float) -> Vector3i:
	var rx := int(round(xf)); var ry := int(round(yf)); var rz := int(round(zf))
	var dx := absf(rx - xf); var dy := absf(ry - yf); var dz := absf(rz - zf)
	if dx > dy and dx > dz:
		rx = -ry - rz
	elif dy > dz:
		ry = -rx - rz
	else:
		rz = -rx - ry
	return Vector3i(rx, ry, rz)

# ============ 形状掩码（🔒 技能图形化范围 2026-07-13）============
# 掩码＝axial 相对偏移集 [[dq,dr],…]（⚠ 不能用 offset 偏移——odd-q 下同一位移随列奇偶错半格，
# cube/axial 空间平移与 60° 旋转才恒正确）。编辑器点格产出掩码、战斗侧经 mask_cells 落地世界格。

# axial 偏移绕原点顺时针旋转 60°×k：cube (x,y,z) 顺转一步 → (-z,-x,-y)
static func axial_rotate(d: Vector2i, k: int) -> Vector2i:
	var v := Vector3i(d.x, -d.x - d.y, d.y)
	for _i in ((k % 6) + 6) % 6:
		v = Vector3i(-v.z, -v.x, -v.y)
	return Vector2i(v.x, v.z)

# 掩码落地：以 origin（offset 格）为锚，旋转 k 档后平移成世界格数组（越界格不裁，调用方判界）
static func mask_cells(origin: Vector2i, mask: Array, k := 0) -> Array:
	var oc := offset_to_cube(origin)
	var out := []
	for m in mask:
		if typeof(m) != TYPE_ARRAY or (m as Array).size() < 2:
			continue
		var d := axial_rotate(Vector2i(int(m[0]), int(m[1])), k)
		out.append(cube_to_offset(Vector3i(oc.x + d.x, oc.y - d.x - d.y, oc.z + d.y)))
	return out

# 掩码可及半径（AI/预览粗口径）：掩码内最远偏移的六边形距离；空掩码=0
static func mask_reach(mask: Array) -> int:
	var best := 0
	for m in mask:
		if typeof(m) != TYPE_ARRAY or (m as Array).size() < 2:
			continue
		var q := int(m[0])
		var r := int(m[1])
		best = maxi(best, int((abs(q) + abs(-q - r) + abs(r)) / 2))
	return best

# ============ 邻居 ============

# 某格的 6 个邻居（odd-q，含越界格，通行性/边界由调用方判）
static func neighbors(cell: Vector2i) -> Array:
	var tbl = NB_ODD if (cell.x & 1) == 1 else NB_EVEN
	var out := []
	for d in tbl:
		out.append(Vector2i(cell.x + d.x, cell.y + d.y))
	return out

# 从 cell 沿方向 d（0..5）走一格
static func neighbor_in_dir(cell: Vector2i, d: int) -> Vector2i:
	var tbl = NB_ODD if (cell.x & 1) == 1 else NB_EVEN
	return Vector2i(cell.x + tbl[d].x, cell.y + tbl[d].y)

# 两格是否相邻（共享一条边）
static func adjacent(a: Vector2i, b: Vector2i) -> bool:
	return distance(a, b) == 1

# ============ 边（格对共享边）============

# 相邻格对的归一化边键（无向：两端排序后拼串）。线特征（河/桥/道路）索引共用这一份，
# 防编辑器/大地图/测试各写一套键序。非相邻格对不设防——调用方保证 adjacent。
static func edge_key(a: Vector2i, b: Vector2i) -> String:
	if b.x < a.x or (b.x == a.x and b.y < a.y):
		var t := a
		a = b
		b = t
	return "%d,%d|%d,%d" % [a.x, a.y, b.x, b.y]

# ============ 连线（两种语义，刻意不合并）============

# 任意两格间的唯一连线：cube 线性插值 + round，返回含 a、b 的格序列。微 epsilon 避顶点歧义。
# 用于 LOS / 寻路（斜穿网格也有解）。地形阻挡判定不在此，由调用方走返回的格序列自行判。
static func line(a: Vector2i, b: Vector2i) -> Array:
	var n := distance(a, b)
	if n == 0:
		return [a]
	var ca := offset_to_cube(a)
	var cb := offset_to_cube(b)
	# 端点各挪极小量：避免采样点正落在两格边界上（LOS 判定更稳定）
	var ax := ca.x + 1e-6; var ay := ca.y + 1e-6; var az := ca.z - 2e-6
	var bx := cb.x + 1e-6; var by := cb.y + 1e-6; var bz := cb.z - 2e-6
	var out := []
	for i in range(n + 1):
		var t := float(i) / float(n)
		out.append(cube_to_offset(cube_round(lerp(ax, bx, t), lerp(ay, by, t), lerp(az, bz, t))))
	return out

# 方向轴直线：从 from 沿某一方向直走 length 格，返回“包含 target 的那条方向线”的格序列（找不到=[]，不含起点）。
# 与 line() 语义不同——只在 target 正落某方向轴上才非空；用于直线 AoE。切勿与 line() 合并。
static func spoke_through(from: Vector2i, target: Vector2i, length: int) -> Array:
	for d in 6:
		var cells := []
		var cur := from
		for _i in length:
			cur = neighbor_in_dir(cur, d)
			cells.append(cur)
		if target in cells:
			return cells
	return []

# ============ 环外扩 ============

# 把一组格按六边形几何外扩 radius 圈（仅几何、不管通行性）；返回含原格的集合。
# 边界由 in_bounds 回调注入（HexGrid 不认识 width/height）：in_bounds.call(Vector2i) -> bool。
static func ring_within(cells: Dictionary, radius: int, in_bounds: Callable) -> Dictionary:
	var out := cells.duplicate()
	for _r in radius:
		var added := {}
		for c in out:
			for nb in neighbors(c):
				if in_bounds.call(nb) and not out.has(nb):
					added[nb] = true
		for k in added:
			out[k] = true
	return out
