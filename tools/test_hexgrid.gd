extends SceneTree
## HexGrid 对拍测试（Phase 0 几何抽取回归）。
## 内嵌一份「原始几何实现」的逐字副本作 golden，全图 + 密集浮点样本断言 HexGrid.* 与之逐位相等。
## 运行：D:\godot\Godot_v4.6.2-stable_mono_win64_console.exe --headless --path "D:/1战棋" -s res://tools/test_hexgrid.gd
## 结尾必调 quit()（退出码 0=全 PASS / 1=有失配）。

const HexGrid := preload("res://HexGrid.gd")
const HexCanvas := preload("res://HexCanvas.gd")

# ===== golden 参考实现（抽取前 Sandbox.gd / HexCanvas.gd 的原始代码逐字副本）=====
const R_NB_EVEN := [Vector2i(1, 0), Vector2i(1, -1), Vector2i(0, -1), Vector2i(-1, -1), Vector2i(-1, 0), Vector2i(0, 1)]
const R_NB_ODD := [Vector2i(1, 1), Vector2i(1, 0), Vector2i(0, -1), Vector2i(-1, 0), Vector2i(-1, 1), Vector2i(0, 1)]

func ref_neighbors(col: int, row: int) -> Array:
	var out := []
	var tbl = R_NB_ODD if (col & 1) == 1 else R_NB_EVEN
	for d in tbl:
		out.append(Vector2i(col + d.x, row + d.y))
	return out

func ref_neighbor_in_dir(c: Vector2i, d: int) -> Vector2i:
	var tbl = R_NB_ODD if (c.x & 1) == 1 else R_NB_EVEN
	return Vector2i(c.x + tbl[d].x, c.y + tbl[d].y)

func ref_to_cube(c: Vector2i) -> Vector3i:
	var x := c.x
	var z := c.y - (c.x - (c.x & 1)) / 2
	return Vector3i(x, -x - z, z)

func ref_cube_to_offset(c: Vector3i) -> Vector2i:
	return Vector2i(c.x, c.z + (c.x - (c.x & 1)) / 2)

func ref_hex_dist(a: Vector2i, b: Vector2i) -> int:
	var ca := ref_to_cube(a)
	var cb := ref_to_cube(b)
	return int((abs(ca.x - cb.x) + abs(ca.y - cb.y) + abs(ca.z - cb.z)) / 2)

func ref_cube_round(xf: float, yf: float, zf: float) -> Vector3i:
	var rx := int(round(xf)); var ry := int(round(yf)); var rz := int(round(zf))
	var dx := absf(rx - xf); var dy := absf(ry - yf); var dz := absf(rz - zf)
	if dx > dy and dx > dz:
		rx = -ry - rz
	elif dy > dz:
		ry = -rx - rz
	else:
		rz = -rx - ry
	return Vector3i(rx, ry, rz)

func ref_hex_line(a: Vector2i, b: Vector2i) -> Array:
	var n := ref_hex_dist(a, b)
	if n == 0:
		return [a]
	var ca := ref_to_cube(a)
	var cb := ref_to_cube(b)
	var ax := ca.x + 1e-6; var ay := ca.y + 1e-6; var az := ca.z - 2e-6
	var bx := cb.x + 1e-6; var by := cb.y + 1e-6; var bz := cb.z - 2e-6
	var out := []
	for i in range(n + 1):
		var t := float(i) / float(n)
		out.append(ref_cube_to_offset(ref_cube_round(lerp(ax, bx, t), lerp(ay, by, t), lerp(az, bz, t))))
	return out

func ref_line_cells(from: Vector2i, target: Vector2i, length: int) -> Array:
	for d in 6:
		var cells := []
		var cur := from
		for _i in length:
			cur = ref_neighbor_in_dir(cur, d)
			cells.append(cur)
		if target in cells:
			return cells
	return []

func ref_cells_within(cells: Dictionary, radius: int, w: int, h: int) -> Dictionary:
	var out := cells.duplicate()
	for _r in radius:
		var added := {}
		for c in out:
			for nb in ref_neighbors(c.x, c.y):
				if nb.x >= 0 and nb.x < w and nb.y >= 0 and nb.y < h and not out.has(nb):
					added[nb] = true
		for k in added:
			out[k] = true
	return out

func ref_axial_round(qf: float, rf: float) -> Vector2i:
	var sf := -qf - rf
	var q := roundi(qf)
	var r := roundi(rf)
	var s := roundi(sf)
	var qd := absf(q - qf)
	var rd := absf(r - rf)
	var sd := absf(s - sf)
	if qd > rd and qd > sd:
		q = -r - s
	elif rd > sd:
		r = -q - s
	return Vector2i(q, r)

# ===== 断言基建 =====
var _fail := 0
var _checks := 0
var _shown := 0

func _eq(actual, expected, ctx: String) -> void:
	_checks += 1
	if actual != expected:
		_fail += 1
		if _shown < 20:
			_shown += 1
			push_error("[FAIL] %s : got %s, want %s" % [ctx, str(actual), str(expected)])

func _keys_eq(a: Dictionary, b: Dictionary, ctx: String) -> void:
	_checks += 1
	var ok := a.size() == b.size()
	if ok:
		for k in a:
			if not b.has(k):
				ok = false
				break
	if not ok:
		_fail += 1
		if _shown < 20:
			_shown += 1
			push_error("[FAIL] %s : key-set mismatch (|a|=%d |b|=%d)" % [ctx, a.size(), b.size()])

func _initialize() -> void:
	print("=== HexGrid 对拍测试开始 ===")

	# 1) offset<->cube 互转 + 邻居（宽范围含负坐标/越界，几何不关心边界）
	for col in range(-3, 18):
		for row in range(-3, 18):
			var cell := Vector2i(col, row)
			_eq(HexGrid.offset_to_cube(cell), ref_to_cube(cell), "offset_to_cube(%s)" % cell)
			var cube := ref_to_cube(cell)
			_eq(HexGrid.cube_to_offset(cube), ref_cube_to_offset(cube), "cube_to_offset(%s)" % cube)
			_eq(HexGrid.cube_to_offset(HexGrid.offset_to_cube(cell)), cell, "cube round-trip(%s)" % cell)
			_eq(HexGrid.neighbors(cell), ref_neighbors(col, row), "neighbors(%s)" % cell)
			for d in 6:
				_eq(HexGrid.neighbor_in_dir(cell, d), ref_neighbor_in_dir(cell, d), "neighbor_in_dir(%s,%d)" % [cell, d])

	# 2) 距离 + 连线（全 15x15 两两配对）
	var grid := []
	for col in range(15):
		for row in range(15):
			grid.append(Vector2i(col, row))
	for a in grid:
		for b in grid:
			_eq(HexGrid.distance(a, b), ref_hex_dist(a, b), "distance(%s,%s)" % [a, b])
			_eq(HexGrid.line(a, b), ref_hex_line(a, b), "line(%s,%s)" % [a, b])

	# 3) spoke_through vs ref_line_cells（含「命中某方向轴」与「不在轴上→[]」两种）
	for a in grid:
		for b in grid:
			for length in [3, 6, 9]:
				_eq(HexGrid.spoke_through(a, b, length), ref_line_cells(a, b, length), "spoke_through(%s,%s,%d)" % [a, b, length])

	# 4) ring_within vs ref_cells_within（单格种子，多半径，15x15 边界回调）
	var in_bounds := func(v: Vector2i) -> bool: return v.x >= 0 and v.x < 15 and v.y >= 0 and v.y < 15
	for seed_cell in grid:
		for radius in range(5):
			var got: Dictionary = HexGrid.ring_within({seed_cell: true}, radius, in_bounds)
			var want := ref_cells_within({seed_cell: true}, radius, 15, 15)
			_keys_eq(got, want, "ring_within(%s,r=%d)" % [seed_cell, radius])

	# 5) cube_round：密集浮点样本（近合法 cube 坐标 + epsilon 扰动，仿真实 line 插值输入）
	var f := -6.0
	while f <= 6.0:
		var g := -6.0
		while g <= 6.0:
			for dz in [0.0, 1e-6, -1e-6, 0.3, -0.3]:
				var zf: float = -f - g + dz
				_eq(HexGrid.cube_round(f, g, zf), ref_cube_round(f, g, zf), "cube_round(%f,%f,%f)" % [f, g, zf])
			g += 0.37
		f += 0.37

	# 6) axial_round：新实现（HexCanvas，内部转调 HexGrid.cube_round）vs golden
	var hc = HexCanvas.new()
	var q := -6.0
	while q <= 6.0:
		var r := -6.0
		while r <= 6.0:
			_eq(hc.axial_round(q, r), ref_axial_round(q, r), "axial_round(%f,%f)" % [q, r])
			r += 0.31
		q += 0.31

	# 7) 像素往返自洽：hex_center → pixel_to_offset 必回到原格（验 axial_round 改写没打歪拾取）
	for col in range(20):
		for row in range(20):
			var cell := Vector2i(col, row)
			_eq(hc.pixel_to_offset(hc.hex_center(col, row)), cell, "pixel round-trip(%s)" % cell)
	hc.free()

	# ===== 汇总 =====
	if _fail == 0:
		print("=== 全 PASS：%d 项断言、0 失配 ===" % _checks)
		quit(0)
	else:
		print("=== 失败：%d/%d 项失配（详见上方 [FAIL]）===" % [_fail, _checks])
		quit(1)
