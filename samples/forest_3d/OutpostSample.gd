extends "res://samples/forest_3d/ForestSample.gd"
## 林地哨站：复用小样交互，独立验证现成自然素材与六边形建筑模块的组合。

const NatureAssets := preload("res://samples/forest_3d/NatureAssets.gd")
const OutpostKit := preload("res://samples/forest_3d/OutpostKit.gd")
const BOARD_CENTER := Vector2i(4, 4)
const SPAWN := Vector2i(3, 4)
const GATE := Vector2i(4, 4)
const CRACKED := Vector2i(4, 5)
const CHOP_TREE := Vector2i(2, 5)
const HUT_CELLS := [Vector2i(6, 2), Vector2i(6, 3)]
const ROCK_CELLS := [Vector2i(1, 2), Vector2i(7, 5)]
const FORT_CELLS := [Vector2i(4, 1), Vector2i(4, 2), Vector2i(4, 3), Vector2i(4, 5), Vector2i(4, 6), Vector2i(4, 7)]

var _occupied := {}
var _grid_root: Node3D
var _grid_visible := true
var _earth_material: StandardMaterial3D
var _ground_material: StandardMaterial3D
var _grid_material: StandardMaterial3D
var _small_stone: StandardMaterial3D
var _ui_root: Control

func _ready() -> void:
	_angle = 0.48
	_earth_material = _material(Color.WHITE)
	_earth_material.vertex_color_use_as_albedo = true
	_ground_material = _material(Color.WHITE)
	_ground_material.vertex_color_use_as_albedo = true
	_grid_material = _material(Color("787b59"))
	_grid_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_small_stone = _material(Color("8c8977"))
	super._ready()
	get_window().title = "林地哨站 · 场景美术样板"

func _build_stage() -> void:
	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("29332f")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("c8d5d9")
	env.ambient_light_energy = 0.48
	world_env.environment = env
	add_child(world_env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -40, 0)
	sun.light_color = Color("ffe3b5")
	sun.light_energy = 0.92
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance = 40.0
	sun.shadow_bias = 0.12
	sun.shadow_normal_bias = 2.5
	add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-35, 140, 0)
	fill.light_color = Color("a1bcc8")
	fill.light_energy = 0.22
	add_child(fill)
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(200, 200)
	var floor_node := _mesh(self, floor_mesh, _material(Color("38403b")), Vector3(0, -0.93, 0))
	floor_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 16.7
	_camera.far = 150.0
	add_child(_camera)
	_camera.make_current()
	_update_camera()
	get_viewport().msaa_3d = Viewport.MSAA_4X

func _update_camera() -> void:
	_camera.position = Vector3(sin(_angle) * 19.0, 17.0, cos(_angle) * 19.0)
	_camera.look_at(Vector3(0.0, 0.6, 0.0), Vector3.UP)

func _flat(cell: Vector2i) -> Vector3:
	return Vector3(1.5 * (cell.x - BOARD_CENTER.x), 0,
		SQRT3 * (cell.y + 0.5 * (cell.x & 1) - 4.0))

func regenerate() -> void:
	if _move_tween != null and _move_tween.is_valid():
		_move_tween.kill()
	_busy = false
	if is_instance_valid(_world):
		_world.free()
	_world = Node3D.new()
	add_child(_world)
	_grid_root = Node3D.new()
	_world.add_child(_grid_root)
	_grid_root.visible = _grid_visible
	cells.clear()
	trees.clear()
	walls.clear()
	_occupied.clear()
	_rng.seed = sample_seed
	pawn_cell = SPAWN
	_hover_cell = NONE
	var road: Array = HexGrid.line(Vector2i(0, 4), Vector2i(8, 4))
	# 分支通往哨所门口，主路与门洞保持贯通。
	road.append_array([Vector2i(5, 3), Vector2i(5, 2)])
	for row in range(9):
		for col in range(9):
			var cell := Vector2i(col, row)
			if HexGrid.distance(BOARD_CENTER, cell) > 4:
				continue
			var p := _flat(cell)
			var forest := clampf(0.48 - p.x * 0.085 - p.z * 0.018, 0.08, 0.95)
			var height := 0
			if col <= 3 and row <= 2:
				height = 2 if row <= 1 else 1
			if road.has(cell):
				height = 0
			cells[cell] = {"height": height, "forest": forest, "road": road.has(cell)}
	for cell: Vector2i in cells:
		_build_tile(cell)
	for cell: Vector2i in HUT_CELLS:
		_occupied[cell] = "哨所"
	for cell: Vector2i in ROCK_CELLS:
		_occupied[cell] = "岩石"
	# 固定构图与可达的高地台阶；R 只调整树形和外围林木。
	var fixed_trees := [Vector2i(1, 2), Vector2i(2, 1), Vector2i(0, 3),
		Vector2i(0, 5), Vector2i(1, 5), Vector2i(2, 6), Vector2i(3, 7),
		Vector2i(5, 1), Vector2i(7, 2), CHOP_TREE]
	for cell: Vector2i in fixed_trees:
		if cells.has(cell) and not cells[cell].road:
			_build_tree(cell)
	for cell: Vector2i in cells:
		if cell.x > 2 or cell == SPAWN or cell == Vector2i(2, 2) or _occupied.has(cell):
			continue
		if not trees.has(cell) and not cells[cell].road and _rng.randf() < 0.18:
			_build_tree(cell)
	for cell: Vector2i in FORT_CELLS:
		_build_wall(cell, cell == CRACKED)
	_build_gate()
	_build_outpost()
	for cell: Vector2i in cells:
		_dress_ground(cell)
	_build_pawn()
	_hover = _mesh(_world, _hex_ring(0.95, 0.88), _marker_mat, Vector3.ZERO)
	_hover.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_hover.visible = false
	_status.text = "沿小径进入哨站。树木与裂墙可以破坏，门洞可以通行。"
	_detail.text = "林缘 · 61 格 · 三档高度 · 样本 %02d" % sample_seed

func _build_tile(cell: Vector2i) -> void:
	var top := float(cells[cell].height) * STEP
	var body := StaticBody3D.new()
	body.position = _flat(cell)
	body.collision_layer = 1
	body.set_meta("cell", cell)
	_world.add_child(body)
	var points := PackedVector3Array()
	for y in [-0.9, top]:
		for i in range(6):
			points.append(Vector3(cos(i * PI / 3.0), y, sin(i * PI / 3.0)))
	var shape := ConvexPolygonShape3D.new()
	shape.points = points
	var collider := CollisionShape3D.new()
	collider.shape = shape
	body.add_child(collider)
	var soil := SurfaceTool.new()
	soil.begin(Mesh.PRIMITIVE_TRIANGLES)
	var levels := [-0.9, -0.42, top - 0.14, top]
	var strata := [Color("554c3c"), Color("786a50"), Color("615b3d")]
	for i in range(6):
		var a := Vector3(cos(i * PI / 3.0), 0, sin(i * PI / 3.0))
		var b := Vector3(cos((i + 1) * PI / 3.0), 0, sin((i + 1) * PI / 3.0))
		soil.set_normal((a + b).normalized())
		for band in range(3):
			soil.set_color(strata[band].lightened(_rng.randf_range(-0.045, 0.045)))
			for v in [a + Vector3.UP * levels[band], b + Vector3.UP * levels[band], b + Vector3.UP * levels[band + 1],
				a + Vector3.UP * levels[band], b + Vector3.UP * levels[band + 1], a + Vector3.UP * levels[band + 1]]:
				soil.add_vertex(v)
	_mesh(body, soil.commit(), _surface_material("earth", _earth_material), Vector3.ZERO)
	var base_color := Color("777d4d").lerp(Color("4c6544"), float(cells[cell].forest))
	if cells[cell].road:
		base_color = Color("a38c63")
	base_color = base_color.lightened(_rng.randf_range(-0.035, 0.035))
	var ground := SurfaceTool.new()
	ground.begin(Mesh.PRIMITIVE_TRIANGLES)
	ground.set_normal(Vector3.UP)
	for i in range(6):
		for j in [-1, i, i + 1]:
			ground.set_color(base_color.lightened(_rng.randf_range(-0.025, 0.025)))
			ground.add_vertex(Vector3.ZERO if j == -1 else Vector3(cos(j * PI / 3.0), 0, sin(j * PI / 3.0)))
	_mesh(body, ground.commit(), _surface_material("dirt" if cells[cell].road else "grass", _ground_material), Vector3(0, top + 0.012, 0))
	var grid := _mesh(_grid_root, _hex_ring(0.99, 0.981), _grid_material, surface_at(cell))
	grid.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if cells[cell].road:
		for i in range(4):
			var pebble := _cylinder(_rng.randf_range(0.04, 0.09), 0.025)
			var at := surface_at(cell) + Vector3(_rng.randf_range(-0.6, 0.6), 0.0, _rng.randf_range(-0.5, 0.5))
			var stone := _mesh(_world, pebble, _surface_material("stone", _small_stone), at)
			stone.scale.z = _rng.randf_range(0.6, 1.4)

func _build_tree(cell: Vector2i) -> void:
	if trees.has(cell) or _occupied.has(cell):
		return
	var body := StaticBody3D.new()
	body.position = surface_at(cell)
	body.collision_layer = 2
	body.set_meta("cell", cell)
	body.set_meta("tree", true)
	_world.add_child(body)
	trees[cell] = body
	var kind := "pine" if cell.y <= 2 else ("broadleaf" if (cell.x + cell.y) % 3 == 0 else "oak")
	var height := _rng.randf_range(2.45, 3.05)
	var model := _nature_model(kind, height)
	model.rotation.y = _rng.randf_range(0.0, TAU)
	body.add_child(model)
	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.55
	shape.height = height
	collision.shape = shape
	collision.position.y = height * 0.5
	body.add_child(collision)

func _build_wall(cell: Vector2i, breakable: bool) -> void:
	var body := _object_body(cell, Vector3(0.62, 1.4, SQRT3))
	body.set_meta("wall", true)
	walls[cell] = {"node": body, "breakable": breakable}
	var palisade := cell.y == 1 or cell.y == 2 or cell.y == 7
	body.add_child(_fort_model(palisade, breakable))

func _build_gate() -> void:
	var gate := _gate_model()
	gate.position = surface_at(GATE)
	_world.add_child(gate)

func _object_body(cell: Vector2i, dimensions: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = surface_at(cell)
	body.collision_layer = 2
	body.set_meta("cell", cell)
	_world.add_child(body)
	var shape := BoxShape3D.new()
	shape.size = dimensions
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position.y = dimensions.y * 0.5
	body.add_child(collider)
	return body

func _build_outpost() -> void:
	var hut := _hut_model()
	hut.position = (surface_at(HUT_CELLS[0]) + surface_at(HUT_CELLS[1])) * 0.5
	_world.add_child(hut)
	for cell: Vector2i in HUT_CELLS:
		_object_body(cell, Vector3(2.05, 2.65, SQRT3))
	for cell: Vector2i in ROCK_CELLS:
		var rock := _object_body(cell, Vector3(1.05, 0.7, 1.05))
		rock.add_child(_nature_model("rock", 0.7))
	# 哨所旁的补给箱都位于建筑已占用的格子内。
	var timber := _surface_material("wood", _material(Color("796249")))
	var band := _surface_material("iron", _material(Color("4c493c")))
	var supply := Node3D.new()
	supply.position = surface_at(HUT_CELLS[1]) + Vector3(0.65, 0.0, 0.63)
	_world.add_child(supply)
	_box(supply, Vector3(0.5, 0.45, 0.5), Vector3(0, 0.225, 0), timber)
	for y in [0.05, 0.40]:
		_box(supply, Vector3(0.515, 0.055, 0.515), Vector3(0, y, 0), band)

func _dress_ground(cell: Vector2i) -> void:
	if _occupied.has(cell) or walls.has(cell) or cell == GATE:
		return
	var road: bool = cells[cell].road
	var count := 2 if road else 4
	for i in range(count):
		var angle := _rng.randf_range(0.0, TAU)
		var radius := _rng.randf_range(0.64, 0.80)
		var kind := "grass"
		var height := _rng.randf_range(0.14, 0.23)
		if not road and i == 0 and _rng.randf() < 0.5:
			kind = "bush"
			height = _rng.randf_range(0.28, 0.42)
		var prop := _nature_model(kind, height)
		prop.position = surface_at(cell) + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		prop.rotation.y = angle
		_world.add_child(prop)

func blocked(cell: Vector2i) -> bool:
	return super.blocked(cell) or _occupied.has(cell)

func activate_cell(cell: Vector2i) -> void:
	if _occupied.has(cell):
		_status.text = "%s占据了这一格，请从旁边绕行。" % _occupied[cell]
		return
	super.activate_cell(cell)

func cut_tree(cell: Vector2i) -> void:
	if not trees.has(cell):
		return
	trees[cell].free()
	trees.erase(cell)
	var stump := _nature_model("stump", 0.22)
	stump.position = surface_at(cell)
	_world.add_child(stump)
	_status.text = "树木已砍倒，树桩保留；这一格现在可以通行。"
	_hover_cell = NONE

func break_wall(cell: Vector2i) -> void:
	if not walls.has(cell) or not walls[cell].breakable:
		return
	walls[cell].node.free()
	walls.erase(cell)
	var rubble := _rubble_model()
	rubble.position = surface_at(cell)
	_world.add_child(rubble)
	_status.text = "裂墙已破坏，碎石间出现通路；两边的墙段依然保留。"
	_hover_cell = NONE

# 小样的视觉入口：不同美术版本共用同一布局、碰撞和交互。
func _surface_material(_kind: String, fallback: Material) -> Material:
	return fallback

func _nature_model(kind: String, height: float) -> Node3D:
	return NatureAssets.instantiate_model(kind, height)

func _fort_model(palisade: bool, breakable: bool) -> Node3D:
	return OutpostKit.make_palisade() if palisade else OutpostKit.make_wall(breakable)

func _gate_model() -> Node3D:
	return OutpostKit.make_gate()

func _hut_model() -> Node3D:
	return OutpostKit.make_hut()

func _rubble_model() -> Node3D:
	return OutpostKit.make_rubble()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_G:
			_grid_visible = not _grid_visible
			_grid_root.visible = _grid_visible
			return
		if event.keycode == KEY_C:
			_angle = 0.48
			_camera.size = 16.7
			_update_camera()
			return
	super._unhandled_input(event)

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_ui_root = Control.new()
	_ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_ui_root)
	var eyebrow := Label.new()
	eyebrow.name = "Eyebrow"
	eyebrow.text = "场 景 美 术 样 板   /   01"
	eyebrow.position = Vector2(32, 24)
	eyebrow.add_theme_font_size_override("font_size", 13)
	eyebrow.modulate = Color("c4b17e")
	_ui_root.add_child(eyebrow)
	var title := Label.new()
	title.name = "Title"
	title.text = "林地哨站"
	title.position = Vector2(29, 45)
	title.add_theme_font_size_override("font_size", 32)
	title.modulate = Color("efe6cf")
	_ui_root.add_child(title)
	_detail = Label.new()
	_detail.position = Vector2(32, 90)
	_detail.add_theme_font_size_override("font_size", 14)
	_detail.modulate = Color("a5b3a1")
	_ui_root.add_child(_detail)
	var badge := Label.new()
	badge.name = "SceneBadge"
	badge.text = "森林 → 林缘 → 哨站\n正面人物 · 自由观察"
	badge.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	badge.offset_left = -225
	badge.offset_right = -32
	badge.offset_top = 30
	badge.add_theme_font_size_override("font_size", 14)
	badge.modulate = Color("bac6b6")
	_ui_root.add_child(badge)
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	panel.offset_left = 28
	panel.offset_right = -28
	panel.offset_top = -88
	panel.offset_bottom = -22
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.105, 0.09, 0.94)
	style.border_color = Color("4d5747")
	style.border_width_top = 1
	style.set_corner_radius_all(6)
	style.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", style)
	_ui_root.add_child(panel)
	var stack := VBoxContainer.new()
	panel.add_child(stack)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 16)
	_status.modulate = Color("e1e6d5")
	stack.add_child(_status)
	var help := Label.new()
	help.text = "左键 移动 / 破坏相邻树木与裂墙     Q / E 旋转     滚轮 缩放     G 格线     C 复位视角     R 换林木     Esc 退出"
	help.add_theme_font_size_override("font_size", 13)
	help.modulate = Color("9ba991")
	stack.add_child(help)
