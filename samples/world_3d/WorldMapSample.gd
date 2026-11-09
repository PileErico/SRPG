extends Node3D
## 地域尺度的独立视觉样板；不连接战役状态、时间、寻路或存档。
## 地形、道路与聚落分别记录：选格与六邻预览仅用于观察地图表现。

const HexGrid := preload("res://HexGrid.gd")
const Materials := preload("res://samples/forest_3d/PixelMaterials.gd")
const Outline := preload("res://samples/forest_3d/ModelOutline.gd")
const ContactShadow := preload("res://samples/forest_3d/PixelContactShadow.gd")
const Faces := preload("res://samples/forest_3d/PixelPropFaces.gd")
const Kit := preload("res://samples/forest_3d/PixelOutpostKit.gd")
const WorldKit := preload("res://samples/world_3d/WorldMapKit.gd")
const Water := preload("res://samples/world_3d/WorldWater.gd")
const Relief := preload("res://samples/world_3d/WorldRelief.gd")
const ReliefMaterial := preload("res://samples/world_3d/WorldReliefMaterial.gd")
const Layout := preload("res://samples/world_3d/WorldMapLayout.gd")
const Coast := preload("res://samples/world_3d/WorldCoast.gd")
const RiverPath := preload("res://samples/world_3d/WorldRiverPath.gd")
const RiverSurface := preload("res://samples/world_3d/WorldRiverSurface.gd")
const CENTER := Layout.CENTER
const NONE := Vector2i(-99, -99)
const SQRT3 := 1.7320508075688772
const PLAIN_HEIGHT := 0.25
const WATER_LEVEL := 0.0
const RIVER_BED := Layout.RIVER_BED
const BOARD_BOTTOM := -0.80
const CHANNEL_WIDTH := 0.40
const BED_WIDTH := 0.23
const WATER_WIDTH := BED_WIDTH + (WATER_LEVEL - RIVER_BED) / (PLAIN_HEIGHT - RIVER_BED) * (CHANNEL_WIDTH - BED_WIDTH)
const NAMES := {"grass": "草原", "forest": "森林", "hills": "丘陵", "mountains": "山地", "river": "河谷", "sea": "海湾"}

var cells: Dictionary = {}
var road_edges: Array = []
var selected_cell := CENTER
var _camera: Camera3D
var _world: Node3D
var _grid: Node3D
var _context: Node3D
var _hover: MeshInstance3D
var _party: Node3D
var _status: Label
var _neighbors_label: Label
var _place_labels: Dictionary = {}
var _ui: Control
var _title_label: Label
var _subtitle_label: Label
var _badge: Label
var _party_label: Label
var _party_cell := Vector2i(4, 8)
var _road_paths: Array = []
var _river_cells: Array = []
var _river_source := NONE
var _river_outlet := NONE
var _river_profiles: Dictionary = {}
var _bridge_position := Vector2.ZERO
var _bridge_axis := Vector2.RIGHT
var _map_bounds := Rect2()
var _overview_size := 27.0
var _yaw := 0.25
var _pitch := 0.83
var _target := Vector3(0.0, 0.1, 0.0)
var _grid_visible := true
var _outlines_visible := true
var _hover_cell := NONE
var _river_line := PackedVector2Array()
var _channel_polygon := PackedVector2Array()
var _bed_polygon := PackedVector2Array()
var _water_polygon := PackedVector2Array()
var _river_banks: Dictionary = {}  # 每河格内与直接陆地邻格接壤的岸坡/岸顶区域。
var _relief := Relief.new()
var _coast := Coast.new()
var _river_surface := RiverSurface.new()

func _ready() -> void:
	get_window().title = "山谷入海 · 世界地图小样"
	_build_stage()
	_build_ui()
	_build_map()
	_reset_camera()
	get_viewport().size_changed.connect(_update_labels)
	call_deferred("_update_labels")

func _flat(cell: Vector2i) -> Vector3:
	# odd-q 必须先转换绝对坐标，再减中心的世界位置。
	return Vector3(1.5 * (cell.x - CENTER.x), 0.0,
		SQRT3 * (cell.y + 0.5 * (cell.x & 1) - CENTER.y - 0.5 * (CENTER.x & 1)))

func _solid(color_name: String) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Materials.color(color_name)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material

func _mesh(parent: Node3D, mesh: Mesh, material: Material, at := Vector3.ZERO) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = at
	parent.add_child(instance)
	return instance

func _build_stage() -> void:
	get_viewport().msaa_3d = Viewport.MSAA_DISABLED
	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("29332f")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("c8d5d9")
	env.ambient_light_energy = 0.48
	environment.environment = env
	add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-48, -40, 0)
	light.light_color = Color("ffe3b5")
	light.light_energy = 0.92
	light.shadow_enabled = true
	light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	light.directional_shadow_max_distance = 85.0
	light.shadow_bias = 0.12
	light.shadow_normal_bias = 2.5
	add_child(light)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-35, 140, 0)
	fill.light_color = Color("a1bcc8")
	fill.light_energy = 0.22
	add_child(fill)
	var backdrop := PlaneMesh.new()
	backdrop.size = Vector2(200, 200)
	var background_material := StandardMaterial3D.new()
	background_material.albedo_color = Color("38403b")
	background_material.roughness = 1.0
	_mesh(self, backdrop, background_material, Vector3(0, BOARD_BOTTOM - 0.05, 0)).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.far = 120.0
	add_child(_camera)
	_camera.make_current()
	Outline.set_color(Materials.color("outline"))
	Outline.set_pixel_width(2.0)

func _build_map() -> void:
	_world = Node3D.new()
	_world.name = "WorldMap"
	add_child(_world)
	_grid = Node3D.new()
	_world.add_child(_grid)
	_context = Node3D.new()
	_world.add_child(_context)
	var layout := Layout.build()
	cells = layout.cells
	_road_paths = layout.road_paths
	_river_cells = layout.river_cells
	_river_source = layout.river_source
	_river_outlet = layout.river_outlet
	_party_cell = layout.party_cell
	_title_label.text = layout.title
	_subtitle_label.text = layout.subtitle
	get_window().title = str(layout.title) + " · 世界地图小样"
	_badge.text = "%d 格 · 地域尺度\n山脉 / 河谷 / 聚落" % cells.size()
	for path: Array in _road_paths:
		for i in range(path.size() - 1):
			assert(HexGrid.adjacent(path[i], path[i + 1]), "A world road must connect neighboring regions")
			road_edges.append([path[i], path[i + 1]])
		for cell: Vector2i in path:
			cells[cell].road = true
	var centers := {}
	for cell: Vector2i in cells:
		var center := _flat(cell)
		centers[cell] = Vector2(center.x, center.z)
		_map_bounds = _map_bounds.expand(centers[cell])
	_map_bounds = _map_bounds.grow(1.0)
	_overview_size = maxf(_map_bounds.size.x, _map_bounds.size.y) * 1.05 + 3.0
	_relief.configure(cells, centers, PLAIN_HEIGHT)
	_build_river_shape()
	var river_lines: Array = [_channel_polygon, _bed_polygon, _water_polygon]
	for banks: Array in _river_banks.values():
		river_lines.append_array(banks)
	_river_surface.configure(cells, centers, _river_ground_field, river_lines, RIVER_BED, PLAIN_HEIGHT, WATER_LEVEL)
	_coast.configure(cells, centers, PLAIN_HEIGHT,
		func(cell: Vector2i, point: Vector2) -> float: return _ground_height(cell, point),
		_coast_river_breakpoints())
	for cell: Vector2i in cells:
		_build_tile(cell)
	_build_roads()
	_build_bridge()
	for cell: Vector2i in cells:
		var model: Node3D
		var origin := _flat(cell)
		var ground := _center_ground_height(cell)
		var village: bool = cells[cell].location != ""
		var turn := PI / 6.0 if village or cells[cell].road else (cell.x + cell.y) % 6 * PI / 3.0
		var ground_at := func(local_anchor: Vector3) -> float:
			var world_anchor := origin + local_anchor.rotated(Vector3.UP, turn)
			return _ground_height(cell, Vector2(world_anchor.x, world_anchor.z)) - ground
		if village:
			model = WorldKit.make_village(ground_at)
			var label := _label(_ui, cells[cell].location, 16, "plaster_light")
			_style_place_label(label)
			_place_labels[cell] = label
		elif cells[cell].terrain == "forest":
			model = WorldKit.make_forest(cell.x * 37 + cell.y, ground_at)
		if model != null:
			model.position = origin + Vector3.UP * (ground + 0.006)
			model.rotation.y = turn
			model.set_meta("world_landmark", "village" if village else cells[cell].terrain)
			_world.add_child(model)
			_fit_contact_shadows(model, cell)
			_add_landmark_picking(model, cell)
			Outline.apply_to(model)
	_build_party()
	_hover = _mesh(_world, _hex_ring(0.97, 0.948), _solid("plaster_light"))
	_hover.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_hover.visible = false
	_select(CENTER)

func _fit_contact_shadows(model: Node3D, cell: Vector2i) -> void:
	for child in model.get_children():
		if child is not MeshInstance3D or not child.has_meta("sample_contact_shadow"):
			continue
		var plane := child.mesh as PlaneMesh
		plane.subdivide_width = 4
		plane.subdivide_depth = 4
		var arrays := plane.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for i in range(vertices.size()):
			var point: Vector3 = child.to_global(vertices[i])
			point.y = _ground_height(cell, Vector2(point.x, point.z)) + 0.009
			vertices[i] = child.to_local(point)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		child.mesh = mesh

func _add_landmark_picking(model: Node3D, cell: Vector2i) -> void:
	# 点击树冠或屋顶也选中该地域，不穿过模型误选到后方地面。
	for part in model.get_children():
		if part is not MeshInstance3D or part.has_meta("sample_contact_shadow"):
			continue
		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.collision_mask = 0
		body.set_meta("cell", cell)
		part.add_child(body)
		var collision := CollisionShape3D.new()
		collision.shape = part.mesh.create_trimesh_shape()
		body.add_child(collision)

func _hex_ring(outer: float, inner: float) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(6):
		var a := Vector3(cos(i * PI / 3.0), 0, sin(i * PI / 3.0))
		var b := Vector3(cos((i + 1) * PI / 3.0), 0, sin((i + 1) * PI / 3.0))
		if inner == 0.0:
			Faces.triangle(surface, a * outer, Vector3.ZERO, b * outer, Vector3.UP)
		else:
			Faces.quad(surface, a * outer, b * outer, b * inner, a * inner, Vector3.UP)
	return surface.commit()

func _build_river_shape() -> void:
	# 有序河格决定入口与出口；河床、水面及两岸共用同一条连续曲线。
	_river_banks.clear()
	var centers := {}
	for cell: Vector2i in _river_cells + [_river_source, _river_outlet]:
		var point := _flat(cell)
		centers[cell] = Vector2(point.x, point.z)
	var river := RiverPath.build(_river_cells, centers, _river_source, _river_outlet, CENTER)
	_river_line = river.line
	_river_profiles = river.profiles
	_bridge_position = river.bridge_position
	_bridge_axis = river.bridge_axis
	_channel_polygon = Geometry2D.offset_polyline(_river_line, CHANNEL_WIDTH, Geometry2D.JOIN_ROUND, Geometry2D.END_BUTT)[0]
	_bed_polygon = Geometry2D.offset_polyline(_river_line, BED_WIDTH, Geometry2D.JOIN_ROUND, Geometry2D.END_BUTT)[0]
	_water_polygon = Geometry2D.offset_polyline(_river_line, WATER_WIDTH, Geometry2D.JOIN_ROUND, Geometry2D.END_BUTT)[0]
	# 在构面之前统一决定岸形，地面、水面、邻格侧壁与点选使用同一结果。
	for cell: Vector2i in cells:
		if cells[cell].terrain != "river":
			continue
		var retained: Array = []
		for bank: PackedVector2Array in Geometry2D.clip_polygons(_hex_polygon(cell), _bed_polygon):
			if _bank_touches_land(cell, bank):
				retained.append(bank)
		_river_banks[cell] = retained

func _bank_touches_land(cell: Vector2i, bank: PackedVector2Array) -> bool:
	var hex := _hex_polygon(cell)
	var center3 := _flat(cell)
	var center := Vector2(center3.x, center3.z)
	for i in range(6):
		var a := hex[i]
		var b := hex[(i + 1) % 6]
		var outward := ((a + b) * 0.5 - center).normalized()
		for neighbor: Vector2i in HexGrid.neighbors(cell):
			if not cells.has(neighbor) or cells[neighbor].terrain in ["river", "sea"]:
				continue
			var direction3 := (_flat(neighbor) - center3).normalized()
			if Vector2(direction3.x, direction3.z).dot(outward) > 0.99 and _shared_edge_length(bank, a, b) > 0.001:
				return true
	return false

func _coast_river_breakpoints() -> PackedVector2Array:
	# 河口实际地表与裁水网格的共边折点也进入海格，确保两侧插值一致。
	var points := PackedVector2Array()
	var river_points: PackedVector2Array = _river_surface.surface_breakpoints()
	for cell: Vector2i in cells:
		if cells[cell].terrain != "sea":
			continue
		var hex := _hex_polygon(cell)
		for neighbor: Vector2i in HexGrid.neighbors(cell):
			if not cells.has(neighbor) or cells[neighbor].terrain != "river":
				continue
			var toward := (_flat(neighbor) - _flat(cell)).normalized()
			for edge in range(6):
				var outward := Vector3(cos((edge + 0.5) * PI / 3.0), 0, sin((edge + 0.5) * PI / 3.0))
				if toward.dot(outward) < 0.99:
					continue
				var a := hex[edge]
				var b := hex[(edge + 1) % 6]
				points.append(a)
				points.append(b)
				var along := b - a
				for point in river_points:
					var t := (point - a).dot(along) / along.length_squared()
					if t >= -0.00003 and t <= 1.00003 and point.distance_to(a + along * t) < 0.00003:
						points.append(point)
	return points

func _shared_edge_length(polygon: PackedVector2Array, a: Vector2, b: Vector2) -> float:
	var length := a.distance_to(b)
	var direction := (b - a) / length
	var contact := 0.0
	for i in range(polygon.size()):
		var p := polygon[i] - a
		var q := polygon[(i + 1) % polygon.size()] - a
		if absf(p.cross(direction)) > 0.0001 or absf(q.cross(direction)) > 0.0001:
			continue
		contact += maxf(0.0, minf(length, maxf(p.dot(direction), q.dot(direction)))
			- maxf(0.0, minf(p.dot(direction), q.dot(direction))))
	return contact

func _inside_retained_bank(cell: Vector2i, point: Vector2) -> bool:
	for bank: PackedVector2Array in _river_banks.get(cell, []):
		if Geometry2D.is_point_in_polygon(point, bank):
			return true
		# 裁切顶点有微小舍入；共边查询仍按同一岸高处理，避免细碎侧壁。
		for i in range(bank.size()):
			var a := bank[i]
			var edge := bank[(i + 1) % bank.size()] - a
			if edge.length_squared() < 0.00000001:
				continue
			var t := clampf((point - a).dot(edge) / edge.length_squared(), 0.0, 1.0)
			if point.distance_squared_to(a + edge * t) < 0.00000001:
				return true
	return false

func _hex_polygon(cell: Vector2i) -> PackedVector2Array:
	var center := _flat(cell)
	var polygon := PackedVector2Array()
	for i in range(6):
		polygon.append(Vector2(center.x + cos(i * PI / 3.0), center.z + sin(i * PI / 3.0)))
	return polygon

func _river_distance(point: Vector2) -> float:
	var distance := INF
	for i in range(_river_line.size() - 1):
		var a := _river_line[i]
		var direction := _river_line[i + 1] - a
		var t := clampf((point - a).dot(direction) / direction.length_squared(), 0.0, 1.0)
		distance = minf(distance, point.distance_to(a + direction * t))
	return distance

func _ground_height(cell: Vector2i, point: Vector2) -> float:
	if cells[cell].terrain == "river":
		return _river_surface.height_at(cell, point)
	return _coast.height_at(cell, point) if cells[cell].terrain == "sea" else _relief.height_at(cell, point)

func _river_ground_field(cell: Vector2i, point: Vector2) -> float:
	if not _inside_retained_bank(cell, point):
		return RIVER_BED
	var blend := clampf((_river_distance(point) - BED_WIDTH) / (CHANNEL_WIDTH - BED_WIDTH), 0.0, 1.0)
	return lerpf(RIVER_BED, PLAIN_HEIGHT, blend)

func _center_ground_height(cell: Vector2i) -> float:
	var at := _flat(cell)
	return _ground_height(cell, Vector2(at.x, at.z))

func _display_height(cell: Vector2i, point: Vector2) -> float:
	var ground := _ground_height(cell, point)
	return maxf(WATER_LEVEL, ground) if cells[cell].terrain in ["river", "sea"] else ground

func _terrain_surface(body: StaticBody3D, mesh: ArrayMesh, material: Material, name_text: String) -> void:
	if mesh == null or mesh.get_surface_count() == 0:
		return
	var part := _mesh(body, mesh, material)
	part.name = name_text
	# 查询面与最终可见表面一致，不用跨过河槽的整块凸碰撞。
	var collision := CollisionShape3D.new()
	collision.shape = mesh.create_trimesh_shape()
	body.add_child(collision)

func _region_ring(cell: Vector2i, outer: float, inner: float, lift: float) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var center := _flat(cell)
	# 河岸与水面有较急的折转，细分轮廓可避免长线段切入岸坡。
	var segments := 64 if cells[cell].terrain == "river" else 16
	for i in range(6):
		var a := Vector2(cos(i * PI / 3.0), sin(i * PI / 3.0))
		var b := Vector2(cos((i + 1) * PI / 3.0), sin((i + 1) * PI / 3.0))
		for step in range(segments):
			var start := a.lerp(b, float(step) / float(segments))
			var end := a.lerp(b, float(step + 1) / float(segments))
			var points: Array[Vector3] = []
			for point: Vector2 in [start * outer, end * outer, end * inner, start * inner]:
				point += Vector2(center.x, center.z)
				points.append(Vector3(point.x, _display_height(cell, point) + lift, point.y))
			Faces.quad(surface, points[0], points[1], points[2], points[3], Vector3.UP)
	return surface.commit()

func _build_tile(cell: Vector2i) -> void:
	var body := StaticBody3D.new()
	body.name = "Region_%d_%d" % [cell.x, cell.y]
	body.set_meta("cell", cell)
	body.collision_layer = 1
	body.collision_mask = 0
	_world.add_child(body)
	var polygon := _hex_polygon(cell)
	var terrain: String = cells[cell].terrain
	if terrain == "river":
		_build_river_surfaces(body, cell)
	else:
		if terrain == "sea":
			_terrain_surface(body, _coast.mesh_for(cell), Materials.get_material("dirt"), "SeabedAndCoast")
		else:
			_terrain_surface(body, _relief.mesh_for(cell), ReliefMaterial.get_material(), "Land")
		if terrain == "sea":
			_terrain_surface(body, _coast.water_mesh_for(cell, WATER_LEVEL),
				Water.get_material(cells[cell].get("deep_water", false)), "SeaWater")
	# 高差交界只由高的一侧构面；河槽口的侧壁按真实岸/床高度下降。
	var sides := SurfaceTool.new()
	var water_sides := SurfaceTool.new()
	sides.begin(Mesh.PRIMITIVE_TRIANGLES)
	water_sides.begin(Mesh.PRIMITIVE_TRIANGLES)
	var side_count := 0
	var water_side_count := 0
	for i in range(6):
		var outward := Vector3(cos((i + 0.5) * PI / 3.0), 0, sin((i + 0.5) * PI / 3.0))
		var neighbor := NONE
		for other: Vector2i in HexGrid.neighbors(cell):
			if cells.has(other) and (_flat(other) - _flat(cell)).normalized().dot(outward) > 0.99:
				neighbor = other
		var a := polygon[i]
		var b := polygon[(i + 1) % 6]
		for step in range(16):
			var p := a.lerp(b, float(step) / 16.0)
			var q := a.lerp(b, float(step + 1) / 16.0)
			var hp := _ground_height(cell, p)
			var hq := _ground_height(cell, q)
			var lp := _ground_height(neighbor, p) if neighbor != NONE else BOARD_BOTTOM
			var lq := _ground_height(neighbor, q) if neighbor != NONE else BOARD_BOTTOM
			if maxf(hp - lp, hq - lq) > 0.001:
				Faces.quad(sides, Vector3(p.x, hp, p.y), Vector3(q.x, hq, q.y),
					Vector3(q.x, minf(lq, hq), q.y), Vector3(p.x, minf(lp, hp), p.y), outward)
				side_count += 1
			if terrain == "sea" and neighbor == NONE:
				water_side_count += _append_water_cutaway(water_sides, p, q, hp, hq, outward)
	if side_count > 0:
		_terrain_surface(body, sides.commit(), Materials.get_material("earth"), "Cliffs")
	if water_side_count > 0:
		_terrain_surface(body, water_sides.commit(), Water.get_material(true), "WaterCutaway")
	var raised := terrain in ["hills", "mountains"]
	var grid_color := "earth_dark" if raised else ("cloth" if terrain == "sea" else "ground_shadow")
	var line := _mesh(_grid, _region_ring(cell, 0.996, 0.985, 0.014 if raised or terrain == "river" else 0.008), _solid(grid_color))
	line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _build_river_surfaces(body: StaticBody3D, cell: Vector2i) -> void:
	# 材质仅拆分同一份实际三角网，不单独三角化曲岸多边形。
	var surfaces: Array[SurfaceTool] = []
	var counts := [0, 0, 0]
	for i in range(3):
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		surfaces.append(surface)
	# 直接读取无索引的原始顶点，保留岸坡小折点的精度。
	var faces: PackedVector3Array = _river_surface.mesh_for(cell).surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for i in range(0, faces.size(), 3):
		var low := minf(faces[i].y, minf(faces[i + 1].y, faces[i + 2].y))
		var high := maxf(faces[i].y, maxf(faces[i + 1].y, faces[i + 2].y))
		var kind := 0 if low >= PLAIN_HEIGHT - 0.0001 else (2 if high <= RIVER_BED + 0.0001 else 1)
		var normal := (faces[i + 2] - faces[i]).cross(faces[i + 1] - faces[i]).normalized()
		for j in range(3):
			var point := faces[i + j]
			surfaces[kind].set_normal(normal)
			surfaces[kind].set_uv(Vector2(point.x, point.z))
			surfaces[kind].add_vertex(point)
		counts[kind] += 1
	for i in range(3):
		if counts[i] > 0:
			_terrain_surface(body, surfaces[i].commit(), Materials.get_material(["grass", "dirt", "earth"][i]),
				["BanksTop", "RiverBanks", "RiverBed"][i])
	_terrain_surface(body, _river_surface.water_mesh_for(cell), Water.get_material(), "RiverWater")

func _append_water_cutaway(surface: SurfaceTool, a: Vector2, b: Vector2, ha: float, hb: float, normal: Vector3) -> int:
	if minf(ha, hb) >= WATER_LEVEL:
		return 0
	# 只给真正有水的外缘补水体侧面；岸坡露出水面的部分由土地侧面封闭。
	if ha > WATER_LEVEL:
		a = a.lerp(b, (WATER_LEVEL - ha) / (hb - ha))
		ha = WATER_LEVEL
	elif hb > WATER_LEVEL:
		b = a.lerp(b, (WATER_LEVEL - ha) / (hb - ha))
		hb = WATER_LEVEL
	Faces.quad(surface, Vector3(a.x, WATER_LEVEL, a.y), Vector3(b.x, WATER_LEVEL, b.y),
		Vector3(b.x, hb, b.y), Vector3(a.x, ha, a.y), normal)
	return 1

func _build_roads() -> void:
	# 路线仍按相邻格连接；格内缓弯，穿越共边时保持边中点与垂直切线。
	var outline := PackedVector2Array()
	var degrees := {}
	for edge: Array in road_edges:
		for cell: Vector2i in edge:
			degrees[cell] = int(degrees.get(cell, 0)) + 1
	for path: Array in _road_paths:
		var ribbons := Geometry2D.offset_polyline(_road_centerline(path, degrees), 0.145,
			Geometry2D.JOIN_ROUND, Geometry2D.END_BUTT)
		assert(ribbons.size() == 1, "A world road must form one ribbon")
		var segment: PackedVector2Array = ribbons[0]
		if outline.is_empty():
			outline = segment
		else:
			var merged := Geometry2D.merge_polygons(outline, segment)
			assert(merged.size() == 1, "World sample roads must form one connected contour")
			outline = merged[0]
	outline = _round_junctions(outline, degrees)
	# 桥接河槽处留空，陆路不铺在水面上。
	var land_roads := Geometry2D.clip_polygons(outline, _channel_polygon)
	var road := _mesh(_world, _road_surface_mesh(land_roads), Materials.get_material("dirt"))
	road.name = "CurvedRoads"
	road.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _road_surface_mesh(polygons: Array) -> ArrayMesh:
	# 将路面裁到实际地表三角形上，缓坡中段也保持相同离地量。
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for cell: Vector2i in cells:
		if cells[cell].terrain == "sea":
			continue
		var patches: Array = []
		for polygon: PackedVector2Array in polygons:
			patches.append_array(Geometry2D.intersect_polygons(polygon, _hex_polygon(cell)))
		if patches.is_empty():
			continue
		if cells[cell].terrain == "river":
			for patch: PackedVector2Array in patches:
				_append_road_patch(surface, patch, func(_point: Vector2) -> float: return PLAIN_HEIGHT)
			continue
		var faces := _relief.mesh_for(cell).get_faces()
		for i in range(0, faces.size(), 3):
			var a := faces[i]
			var b := faces[i + 1]
			var c := faces[i + 2]
			var pa := Vector2(a.x, a.z)
			var u := Vector2(b.x - a.x, b.z - a.z)
			var v := Vector2(c.x - a.x, c.z - a.z)
			var triangle := PackedVector2Array([pa, pa + u, pa + v])
			var height_at := func(point: Vector2) -> float:
				var p := point - pa
				return a.y + ((b.y - a.y) * p.cross(v) + (c.y - a.y) * u.cross(p)) / u.cross(v)
			for patch: PackedVector2Array in patches:
				for clipped: PackedVector2Array in Geometry2D.intersect_polygons(patch, triangle):
					_append_road_patch(surface, clipped, height_at)
	return surface.commit()

func _append_road_patch(surface: SurfaceTool, polygon: PackedVector2Array, height_at: Callable) -> void:
	var indices := Geometry2D.triangulate_polygon(polygon)
	for i in range(0, indices.size(), 3):
		var vertices: Array[Vector3] = []
		for index in range(3):
			var point := polygon[indices[i + index]]
			vertices.append(Vector3(point.x, float(height_at.call(point)) + 0.018, point.y))
		Faces.triangle(surface, vertices[0], vertices[1], vertices[2], Vector3.UP)

func _road_centerline(path: Array, degrees: Dictionary) -> PackedVector2Array:
	var centers := PackedVector2Array()
	for cell: Vector2i in path:
		var point := _flat(cell)
		centers.append(Vector2(point.x, point.z))
	var anchors := PackedVector2Array()
	var forced_tangents := {}
	if degrees[path[0]] == 1:
		anchors.append(centers[0] + (centers[0] - centers[1]).normalized() * SQRT3 * 0.5)
	for i in range(centers.size()):
		if path[i] == CENTER and i > 0 and i + 1 < centers.size():
			# 进入桥口后沿桥轴走直线，出桥后再弯向共边，避免路接到护栏侧面。
			var direction := _bridge_axis
			if direction.dot(centers[i + 1] - centers[i - 1]) < 0.0:
				direction = -direction
			for bridge_point: Vector2 in [_bridge_position - direction * 0.775, _bridge_position, _bridge_position + direction * 0.775]:
				anchors.append(bridge_point)
				forced_tangents[bridge_point] = direction
		else:
			anchors.append(centers[i])
		if i + 1 < centers.size():
			var port := (centers[i] + centers[i + 1]) * 0.5
			anchors.append(port)
			forced_tangents[port] = (centers[i + 1] - centers[i]).normalized()
	if degrees[path[-1]] == 1:
		anchors.append(centers[-1] + (centers[-1] - centers[-2]).normalized() * SQRT3 * 0.5)
	var tangents := PackedVector2Array()
	for i in range(anchors.size()):
		tangents.append(forced_tangents.get(anchors[i],
			(anchors[mini(i + 1, anchors.size() - 1)] - anchors[maxi(0, i - 1)]).normalized()))
	var sampled := PackedVector2Array([anchors[0]])
	for i in range(anchors.size() - 1):
		var a := anchors[i]
		var b := anchors[i + 1]
		var handle := a.distance_to(b) / 3.0
		# 控制点留在本格内；中心也作为锚点，岔路不会与主路脱开。
		for step in range(1, 13):
			sampled.append(a.bezier_interpolate(a + tangents[i] * handle,
				b - tangents[i + 1] * handle, b, float(step) / 12.0))
	return sampled

func _round_junctions(polygon: PackedVector2Array, degrees: Dictionary) -> PackedVector2Array:
	var junctions := PackedVector2Array()
	for cell: Vector2i in degrees:
		if degrees[cell] > 2:
			var point := _flat(cell)
			junctions.append(Vector2(point.x, point.z))
	var result := PackedVector2Array()
	for i in range(polygon.size()):
		var at := polygon[i]
		var previous := polygon[(i - 1 + polygon.size()) % polygon.size()]
		var next := polygon[(i + 1) % polygon.size()]
		var near_junction := false
		for junction in junctions:
			if at.distance_to(junction) < 0.45:
				near_junction = true
		if not near_junction or absf((at - previous).angle_to(next - at)) < 0.35:
			result.append(at)
			continue
		var radius := minf(0.10, minf(at.distance_to(previous), at.distance_to(next)) * 0.45)
		var entry := at.move_toward(previous, radius)
		var leave := at.move_toward(next, radius)
		for step in range(7):
			var t := float(step) / 6.0
			result.append(entry.lerp(at, t).lerp(at.lerp(leave, t), t))
	return result

func _build_bridge() -> void:
	var bridge := WorldKit.make_bridge()
	bridge.name = "RiverBridge"
	bridge.position = Vector3(_bridge_position.x, PLAIN_HEIGHT, _bridge_position.y)
	bridge.rotation.y = atan2(-_bridge_axis.y, _bridge_axis.x)
	_world.add_child(bridge)
	# 短坡连接稍抬高的桥面与土路。
	var ramps := SurfaceTool.new()
	ramps.begin(Mesh.PRIMITIVE_TRIANGLES)
	for side in [-1.0, 1.0]:
		Faces.quad(ramps, Vector3(side * 0.575, 0.10, -0.20), Vector3(side * 0.775, 0.018, -0.20),
			Vector3(side * 0.775, 0.018, 0.20), Vector3(side * 0.575, 0.10, 0.20), Vector3.UP)
	Kit._mesh(bridge, ramps.commit(), Kit._mat("wood"), Vector3.ZERO)
	_add_landmark_picking(bridge, CENTER)
	Outline.apply_to(bridge)

func _build_party() -> void:
	_party = Node3D.new()
	_party.name = "PartyBanner"
	_party.position = _flat(_party_cell) + Vector3.UP * (_center_ground_height(_party_cell) + 0.026)
	_world.add_child(_party)
	Kit._box(_party, Vector3(0.0625, 0.85, 0.0625), Vector3(0, 0.425, 0), Kit._mat("wood"))
	Faces.extrude(_party, PackedVector2Array([Vector2(0.04, 0.76), Vector2(0.48, 0.76),
		Vector2(0.48, 0.40), Vector2(0.29, 0.47), Vector2(0.04, 0.40)]), 0.0625, 0.0, Kit._mat("cloth"))
	Outline.apply_to(_party)
	var shadow := ContactShadow.make(Vector2(0.32, 0.25))
	shadow.position = _flat(_party_cell) + Vector3.UP * (_center_ground_height(_party_cell) + 0.024)
	_world.add_child(shadow)

func _select(cell: Vector2i) -> void:
	if not cells.has(cell):
		return
	selected_cell = cell
	for child in _context.get_children():
		child.free()
	var counts := {}
	for kind: String in NAMES:
		counts[kind] = 0
	for neighbor: Vector2i in HexGrid.neighbors(cell):
		if not cells.has(neighbor):
			continue
		counts[cells[neighbor].terrain] += 1
		var neighbor_ring := _mesh(_context, _region_ring(neighbor, 0.935, 0.925, 0.030), _solid("sand"))
		neighbor_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var selected_ring := _mesh(_context, _region_ring(cell, 0.97, 0.942, 0.032), _solid("ochre"))
	selected_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var data: Dictionary = cells[cell]
	var location_text := "  ·  " + str(data.location) if data.location != "" else ""
	var relief_text := "低缓陆地"
	match data.terrain:
		"hills": relief_text = "连绵丘陵 · 坡地相接"
		"mountains": relief_text = "山脚渐升 · 岩石山脊"
		"river": relief_text = "水面平齐 · 河床低于两岸"
		"sea": relief_text = "同一海平面 · 海床下沉"
	if data.terrain in ["hills", "mountains"]:
		var profile: Dictionary = _relief.relief_profile(cell)
		var relative_level := float(profile.mean_level) - float(profile.level)
		if relative_level > 0.001:
			relief_text = "接向高地 · 丘陵抬升"
		elif relative_level < -0.001:
			relief_text = "接向低地 · " + ("丘陵放缓" if data.terrain == "hills" else "山势渐低")
		else:
			relief_text = "同级相连 · " + ("连绵缓丘" if data.terrain == "hills" else "高耸山地")
	elif data.terrain not in ["river", "sea"]:
		var profile: Dictionary = _relief.relief_profile(cell)
		relief_text = "靠近高地 · 地面微升" if float(profile.target_rise) > 0.001 else "低缓陆地"
	if data.terrain == "river" and _river_banks[cell].size() < 2:
		relief_text = "单侧接岸 · 河口向水域展开" if _river_banks[cell].size() == 1 else "开阔水面 · 无相接陆岸"
	elif data.terrain == "river" and _river_profiles.has(cell):
		var river_kind: String = _river_profiles[cell].kind
		relief_text = {"straight": "直河段", "bend": "缓弯河段", "sharp": "急弯河段"}.get(river_kind, "河谷") + " · 两岸随河道衔接"
	_status.text = "%s%s  %s  ·  %s" % [NAMES[data.terrain], location_text, "·  古道经过" if data.road else "", relief_text]
	var parts := PackedStringArray()
	for kind: String in NAMES:
		if counts[kind] > 0:
			parts.append("%s %d" % [NAMES[kind], counts[kind]])
	_neighbors_label.text = "周边地块：" + " / ".join(parts)

func pick_at(screen: Vector2) -> Vector2i:
	var origin := _camera.project_ray_origin(screen)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + _camera.project_ray_normal(screen) * 100.0, 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return NONE
	return hit.collider.get_meta("cell", NONE)

func _update_camera() -> void:
	_camera.position = _target + Vector3(sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch)) * 55.0
	_camera.look_at(_target, Vector3.UP)
	if is_instance_valid(_party):
		_party.rotation.y = _yaw
	_update_labels()

func _reset_camera() -> void:
	_yaw = 0.25
	_pitch = deg_to_rad(48.0)
	var center := _map_bounds.get_center()
	_target = Vector3(center.x, 0.15, center.y - 0.4)
	_camera.size = _overview_size
	_update_camera()

func _pan_camera(previous: Vector2, current: Vector2) -> void:
	var plane := Plane(Vector3.UP, 0.0)
	var a: Variant = plane.intersects_ray(_camera.project_ray_origin(previous), _camera.project_ray_normal(previous))
	var b: Variant = plane.intersects_ray(_camera.project_ray_origin(current), _camera.project_ray_normal(current))
	if a is Vector3 and b is Vector3:
		_target += a - b
		_target.x = clampf(_target.x, _map_bounds.position.x, _map_bounds.end.x)
		_target.z = clampf(_target.z, _map_bounds.position.y, _map_bounds.end.y)
		_update_camera()

func _update_labels() -> void:
	if not is_instance_valid(_party_label):
		return
	var entries: Array = [[_party_label, _party_cell, 1.02]]
	for cell: Vector2i in _place_labels:
		entries.append([_place_labels[cell], cell, 0.95])
	for entry: Array in entries:
		var label: Label = entry[0]
		var point := _camera.unproject_position(_flat(entry[1]) + Vector3.UP * (_center_ground_height(entry[1]) + float(entry[2])))
		label.position = point - Vector2(label.size.x * 0.5, label.size.y)
		label.visible = point.y > 135 and point.y < get_viewport().get_visible_rect().size.y - 125

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if event.button_mask & MOUSE_BUTTON_MASK_RIGHT:
			_yaw -= event.relative.x * 0.006
			_pitch = clampf(_pitch + event.relative.y * 0.006, deg_to_rad(25.0), deg_to_rad(80.0))
			_update_camera()
			_hover.visible = false
		elif event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			_pan_camera(event.position - event.relative, event.position)
			_hover.visible = false
		else:
			var cell := pick_at(event.position)
			if cell != _hover_cell:
				_hover_cell = cell
				if cells.has(cell):
					_hover.mesh = _region_ring(cell, 0.97, 0.948, 0.036)
			_hover.visible = cells.has(cell)
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT and not (event.button_mask & (MOUSE_BUTTON_MASK_RIGHT | MOUSE_BUTTON_MASK_MIDDLE)):
			_select(pick_at(event.position))
		elif event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_camera.size = clampf(_camera.size * (0.92 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.08), 7.0, _overview_size * 1.5)
			_hover.visible = false
			_update_labels()
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE: get_tree().quit()
			KEY_C: _reset_camera()
			KEY_Q, KEY_E:
				_yaw += PI / 3.0 * (-1.0 if event.keycode == KEY_Q else 1.0)
				_update_camera()
				_hover.visible = false
			KEY_G:
				_grid_visible = not _grid_visible
				_grid.visible = _grid_visible
			KEY_O:
				_outlines_visible = not _outlines_visible
				Outline.set_visible(_world, _outlines_visible)

func _label(parent: Control, text: String, size: int, color_name: String) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", Materials.color(color_name))
	parent.add_child(label)
	return label

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var ui := Control.new()
	_ui = ui
	layer.add_child(ui)
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label(ui, "世 界 地 图   /   风 格 小 样", 13, "ochre").position = Vector2(32, 25)
	_title_label = _label(ui, "", 32, "plaster_light")
	_title_label.position = Vector2(29, 47)
	_subtitle_label = _label(ui, "", 14, "stone_light")
	_subtitle_label.position = Vector2(32, 92)
	_badge = _label(ui, "", 14, "stone_light")
	_badge.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_badge.offset_left = -220
	_badge.offset_right = -32
	_badge.offset_top = 32
	_party_label = _label(ui, "旅团", 14, "cloth_light")
	_style_place_label(_party_label)
	var panel := PanelContainer.new()
	ui.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	panel.offset_left = 28
	panel.offset_right = -28
	panel.offset_top = -112
	panel.offset_bottom = -22
	var style := StyleBoxFlat.new()
	style.bg_color = Materials.color("outline")
	style.set_corner_radius_all(5)
	style.set_content_margin_all(13)
	panel.add_theme_stylebox_override("panel", style)
	var stack := VBoxContainer.new()
	panel.add_child(stack)
	_status = _label(stack, "", 16, "plaster_light")
	_neighbors_label = _label(stack, "", 13, "sand_light")
	_label(stack, "左键 选格与周边六格    右键拖动 环绕    中键拖动 平移    滚轮 缩放    Q/E 转向    G 格线    O 描边    C 复位    Esc 退出", 13, "stone_light")

func _style_place_label(label: Label) -> void:
	label.add_theme_color_override("font_outline_color", Materials.color("outline"))
	label.add_theme_constant_override("outline_size", 5)
