extends Node3D
## 独立视觉小样：程序化 3D 地面/树木 + 现有 2D 角色。
## 只复用 HexGrid 几何；移动/砍树是演示规则，不接战役、存档或正式战斗。

const HexGrid := preload("res://HexGrid.gd")
const TextureCache := preload("res://TextureCache.gd")
const OccludedOutline := preload("res://samples/forest_3d/occluded_outline.gdshader")
const FRIENDLY_OUTLINE := Color("59bfff")
const ENEMY_OUTLINE := Color("ff665e")
const CENTER := Vector2i(3, 3)
const START := Vector2i(2, 3)
const DEMO_TREE := Vector2i(2, 4)
const DEMO_WALL := Vector2i(4, 4)
const WALL_CELLS := [Vector2i(4, 1), Vector2i(4, 2), Vector2i(4, 4), Vector2i(4, 5)]
const NONE := Vector2i(-99, -99)
const STEP := 0.48
const SQRT3 := 1.7320508075688772

var sample_seed := 11
var cells := {}       # Vector2i -> {height, forest, road}
var trees := {}       # Vector2i -> StaticBody3D
var walls := {}       # Vector2i -> {node, breakable}；门洞格(4,3)不占地
var pawn_cell := START
var _world: Node3D
var _camera: Camera3D
var _pawn: Node3D
var _hover: MeshInstance3D
var _hover_cell := NONE
var _status: Label
var _detail: Label
var _busy := false
var _angle := 0.48
var _rng := RandomNumberGenerator.new()
var _soil := StandardMaterial3D.new()
var _bark := StandardMaterial3D.new()
var _leaf := StandardMaterial3D.new()
var _marker_mat := StandardMaterial3D.new()
var _move_tween: Tween

func _ready() -> void:
	DisplayServer.window_set_title("林缘 · 3D 小样")
	_soil = _material(Color("655744"))
	_bark = _material(Color("604937"))
	_leaf = _material(Color("557b4a"))
	_marker_mat = _material(Color("f3cf7d"))
	_marker_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_build_stage()
	_build_ui()
	regenerate()

func _material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat

func _build_stage() -> void:
	var environment := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("18252d")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("c4d6dc")
	env.ambient_light_energy = 0.65
	environment.environment = env
	add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -32, 0)
	sun.light_color = Color("ffe4b4")
	sun.light_energy = 1.15
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 45.0
	add_child(sun)
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(200, 200)
	var floor_node := _mesh(self, floor_mesh, _material(Color("26343b")), Vector3(0, -0.8, 0))
	floor_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 14.0
	_camera.far = 150.0
	add_child(_camera)
	_camera.make_current()
	_update_camera()
	get_viewport().msaa_3d = Viewport.MSAA_4X

func _update_camera() -> void:
	_camera.position = Vector3(sin(_angle) * 15.0, 15.0, cos(_angle) * 15.0)
	_camera.look_at(Vector3(0, 0.3, 0), Vector3.UP)

func _flat(cell: Vector2i) -> Vector3:
	return Vector3(1.5 * (cell.x - CENTER.x), 0,
		SQRT3 * (cell.y + 0.5 * (cell.x & 1) - 3.5))

func surface_at(cell: Vector2i) -> Vector3:
	return _flat(cell) + Vector3.UP * (float(cells[cell].height) * STEP + 0.025)

func regenerate() -> void:
	if _move_tween != null and _move_tween.is_valid():
		_move_tween.kill()
	_busy = false
	if is_instance_valid(_world):
		_world.free()
	_world = Node3D.new()
	add_child(_world)
	cells.clear()
	trees.clear()
	walls.clear()
	_rng.seed = sample_seed
	pawn_cell = START
	_hover_cell = NONE
	var road: Array = HexGrid.line(Vector2i(0, 3), Vector2i(6, 3))
	for row in range(7):
		for col in range(7):
			var cell := Vector2i(col, row)
			if HexGrid.distance(CENTER, cell) > 3:
				continue
			# 示例上下文：北/西北/西南邻格为林地，东侧邻格为空地。
			var p := _flat(cell)
			var forest := clampf(0.5 - p.x * 0.12 - p.z * 0.035, 0.05, 0.95)
			var level := 0
			if row <= 2 and col <= 3:
				level = 2 if row <= 1 else 1
			var is_road := road.has(cell)
			if is_road:
				level = 0
			cells[cell] = {"height": level, "forest": forest, "road": is_road}
	for cell: Vector2i in cells:
		_build_tile(cell)
		if cell != START and not WALL_CELLS.has(cell) and not cells[cell].road and _rng.randf() < float(cells[cell].forest) * 0.6:
			_build_tree(cell)
	if not trees.has(DEMO_TREE):
		_build_tree(DEMO_TREE)
	# 保证高地样板有一条可达的台阶路线，方便直接试走。
	for cell in [Vector2i(3, 2), Vector2i(3, 1), Vector2i(2, 2)]:
		if trees.has(cell):
			trees[cell].free()
			trees.erase(cell)
	for cell: Vector2i in WALL_CELLS:
		_build_wall(cell, cell == DEMO_WALL)
	_build_gate()
	_build_pawn()
	_hover = _mesh(_world, _hex_ring(0.94, 0.87), _marker_mat, Vector3.ZERO)
	_hover.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_hover.visible = false
	_status.text = "点地面走动。门洞可以穿过；靠近树木或裂墙，再点击破坏。"
	_detail.text = "37 格 · 高低地形 · 拼接围墙 · 样本 %d" % sample_seed

func _build_tile(cell: Vector2i) -> void:
	var top := float(cells[cell].height) * STEP
	var body := StaticBody3D.new()
	body.position = _flat(cell)
	body.collision_layer = 1
	body.set_meta("cell", cell)
	_world.add_child(body)
	var points := PackedVector3Array()
	for y in [-0.65, top]:
		for i in range(6):
			points.append(Vector3(cos(i * PI / 3.0), y, sin(i * PI / 3.0)))
	var shape := ConvexPolygonShape3D.new()
	shape.points = points
	var collider := CollisionShape3D.new()
	collider.shape = shape
	body.add_child(collider)
	var wall := SurfaceTool.new()
	wall.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(6):
		var a := Vector3(cos(i * PI / 3.0), 0, sin(i * PI / 3.0))
		var b := Vector3(cos((i + 1) * PI / 3.0), 0, sin((i + 1) * PI / 3.0))
		wall.set_normal((a + b).normalized())
		for v in [a + Vector3.UP * top, b + Vector3.UP * top, b + Vector3.DOWN * 0.65,
			a + Vector3.UP * top, b + Vector3.DOWN * 0.65, a + Vector3.DOWN * 0.65]:
			wall.add_vertex(v)
	_mesh(body, wall.commit(), _soil, Vector3.ZERO)
	var color := Color("91a568").lerp(Color("526f4a"), float(cells[cell].forest))
	if cells[cell].road:
		color = Color("c3a77a")
	color = color.lightened(_rng.randf_range(-0.035, 0.045))
	_mesh(body, _hex_ring(0.985, 0.0), _material(color), Vector3(0, top + 0.012, 0))

func _hex_ring(outer: float, inner: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)
	for i in range(6):
		var a := Vector3(cos(i * PI / 3.0), 0, sin(i * PI / 3.0))
		var b := Vector3(cos((i + 1) * PI / 3.0), 0, sin((i + 1) * PI / 3.0))
		for p in [a * outer, a * inner, b * outer, b * outer, a * inner, b * inner]:
			st.add_vertex(p)
	return st.commit()

func _mesh(parent: Node3D, geometry: Mesh, mat: Material, at: Vector3) -> MeshInstance3D:
	var n := MeshInstance3D.new()
	n.mesh = geometry
	n.material_override = mat
	n.position = at
	parent.add_child(n)
	return n

func _cylinder(radius: float, height: float, tip: float = -1.0) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.bottom_radius = radius
	mesh.top_radius = radius if tip < 0 else tip
	mesh.height = height
	mesh.radial_segments = 7
	return mesh

func _build_tree(cell: Vector2i) -> void:
	var tree := StaticBody3D.new()
	tree.position = surface_at(cell)
	tree.collision_layer = 2
	tree.set_meta("cell", cell)
	tree.set_meta("tree", true)
	_world.add_child(tree)
	trees[cell] = tree
	var height := _rng.randf_range(1.65, 2.15)
	_mesh(tree, _cylinder(0.12, height * 0.65, 0.07), _bark, Vector3(0, height * 0.325, 0))
	# 简单几何树冠：明确体积与光照，不依赖外部地块贴图。
	for i in range(3):
		var crown := SphereMesh.new()
		crown.radius = 0.62 if i == 0 else 0.46
		crown.height = crown.radius * 1.65
		crown.radial_segments = 7
		crown.rings = 3
		var pos := Vector3(0, height * 0.8, 0)
		if i > 0:
			pos += Vector3(0.34 if i == 1 else -0.31, -0.2, 0.13 if i == 1 else -0.1)
		_mesh(tree, crown, _leaf, pos)
	var collision := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.7
	shape.height = height + 0.45
	collision.shape = shape
	collision.position.y = shape.height * 0.5
	tree.add_child(collision)

func _build_pawn() -> void:
	_pawn = Node3D.new()
	_world.add_child(_pawn)
	_pawn.position = surface_at(pawn_cell)
	var base := _cylinder(0.36, 0.045)
	_mesh(_pawn, base, _material(Color("67c6dc")), Vector3(0, 0.025, 0))
	var sprite := Sprite3D.new()
	sprite.texture = TextureCache.get_tex("res://icons/Characters/appearance_empire_infantry.png")
	# 按实际像素内容归一高度与脚点，透明画布留白不参与人物尺寸。
	var used: Rect2i = sprite.texture.get_image().get_used_rect()
	sprite.pixel_size = 1.55 / float(maxi(1, used.size.y))
	sprite.offset = Vector2(sprite.texture.get_width() * 0.5 - used.get_center().x,
		used.end.y - sprite.texture.get_height() * 0.5)
	sprite.position.y = 0.06
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_pawn.add_child(sprite)
	_add_occluded_outline(sprite, FRIENDLY_OUTLINE)

func _add_occluded_outline(sprite: Sprite3D, color: Color) -> void:
	# 第二遍只画被场景挡住的像素边缘；复用脚点和尺寸，随镜头完整转向。
	var outline := Sprite3D.new()
	outline.texture = sprite.texture
	outline.pixel_size = sprite.pixel_size
	outline.offset = sprite.offset
	outline.position = sprite.position
	outline.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	mat.shader = OccludedOutline
	mat.set_shader_parameter("sprite_texture", sprite.texture)
	mat.set_shader_parameter("outline_color", color)
	outline.material_override = mat
	sprite.get_parent().add_child(outline)

func _box(parent: Node3D, dimensions: Vector3, at: Vector3, mat: Material) -> MeshInstance3D:
	var box := BoxMesh.new()
	box.size = dimensions
	return _mesh(parent, box, mat, at)

func _build_wall(cell: Vector2i, breakable: bool) -> void:
	var wall := StaticBody3D.new()
	wall.position = surface_at(cell)
	wall.collision_layer = 2
	wall.set_meta("cell", cell)
	wall.set_meta("wall", true)
	_world.add_child(wall)
	walls[cell] = {"node": wall, "breakable": breakable}
	var stone := _material(Color("a4a38a") if breakable else Color("818b86"))
	_box(wall, Vector3(0.66, 1.25, SQRT3), Vector3(0, 0.625, 0), stone)
	_box(wall, Vector3(0.77, 0.15, SQRT3), Vector3(0, 1.27, 0), stone)
	var mortar := _material(Color("525a55"))
	for side in [-1.0, 1.0]:
		for y in [0.42, 0.84]:
			_box(wall, Vector3(0.012, 0.025, SQRT3), Vector3(side * 0.335, y, 0), mortar)
		for p in [Vector2(0.22, -0.3), Vector2(0.63, 0.3), Vector2(1.04, -0.3)]:
			_box(wall, Vector3(0.012, 0.40, 0.025), Vector3(side * 0.335, p.x, p.y), mortar)
		if breakable:
			var points := [Vector2(1.35, -0.28), Vector2(1.04, 0.02), Vector2(0.8, -0.14), Vector2(0.49, 0.2), Vector2(0.16, 0.08)]
			for i in range(points.size() - 1):
				var a := Vector3(side * 0.35, points[i].x, points[i].y)
				var b := Vector3(side * 0.35, points[i + 1].x, points[i + 1].y)
				var mark := _mesh(wall, _cylinder(0.045, a.distance_to(b)), _material(Color("322a25")), (a + b) * 0.5)
				mark.quaternion = Quaternion(Vector3.UP, (b - a).normalized())
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.77, 1.35, SQRT3)
	collision.shape = shape
	collision.position.y = 0.675
	wall.add_child(collision)
	if breakable:
		var label := Label3D.new()
		label.text = "裂墙"
		label.font_size = 38
		label.pixel_size = 0.007
		label.modulate = Color("ffe0a1")
		label.position.y = 1.65
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		wall.add_child(label)

func _build_gate() -> void:
	# 门框跨越一个可通行格；横梁只负责表现，绝不能给整个门洞加实心阻挡。
	var gate := Node3D.new()
	gate.position = surface_at(Vector2i(4, 3))
	_world.add_child(gate)
	for z in [-0.72, 0.72]:
		_box(gate, Vector3(0.43, 2.0, 0.24), Vector3(0, 1.0, z), _bark)
	_box(gate, Vector3(0.55, 0.24, 2.0), Vector3(0, 2.0, 0), _bark)
	_box(gate, Vector3(0.69, 0.12, 2.12), Vector3(0, 2.16, 0), _material(Color("8e674d")))

func blocked(cell: Vector2i) -> bool:
	return trees.has(cell) or walls.has(cell)

func pick_at(screen: Vector2) -> Dictionary:
	var origin := _camera.project_ray_origin(screen)
	var ray := PhysicsRayQueryParameters3D.create(origin, origin + _camera.project_ray_normal(screen) * 100.0, 3)
	var hit := get_world_3d().direct_space_state.intersect_ray(ray)
	if hit.is_empty():
		return {}
	var body: Object = hit.collider
	return {"cell": body.get_meta("cell"), "tree": body.has_meta("tree"), "wall": body.has_meta("wall")}

func path_to(target: Vector2i) -> Array:
	if not cells.has(target) or blocked(target):
		return []
	var queue: Array = [pawn_cell]
	var came := {pawn_cell: pawn_cell}
	var index := 0
	while index < queue.size():
		var c: Vector2i = queue[index]
		index += 1
		if c == target:
			var path: Array = [c]
			while c != pawn_cell:
				c = came[c]
				path.push_front(c)
			return path
		for nb: Vector2i in HexGrid.neighbors(c):
			if not cells.has(nb) or blocked(nb) or came.has(nb):
				continue
			if absi(int(cells[c].height) - int(cells[nb].height)) > 1:
				continue
			came[nb] = c
			queue.append(nb)
	return []

func activate_cell(cell: Vector2i) -> void:
	if _busy or not cells.has(cell):
		return
	if blocked(cell):
		if walls.has(cell) and not walls[cell].breakable:
			_status.text = "这是完整墙体：占格、挡路，不可破坏。寻找门洞或带裂缝的墙。"
			return
		if HexGrid.distance(pawn_cell, cell) != 1 or absi(int(cells[pawn_cell].height) - int(cells[cell].height)) > 1:
			_status.text = "先走到目标旁边，再点击砍树或破坏裂墙。"
			return
		if trees.has(cell):
			cut_tree(cell)
		else:
			break_wall(cell)
		return
	var path := path_to(cell)
	if path.is_empty():
		_status.text = "暂时走不过去：树木/墙体挡路，或高差超过一层。"
		return
	_busy = true
	_status.text = "沿六边形格子移动……"
	_move_tween = create_tween()
	for i in range(1, path.size()):
		_move_tween.tween_property(_pawn, "position", surface_at(path[i]), 0.18)
		_move_tween.tween_callback(func(): pawn_cell = path[i])
	_move_tween.tween_callback(func():
		_busy = false
		_status.text = "已到达。相邻树木、裂墙可破坏；普通墙体不可破坏。")

func break_wall(cell: Vector2i) -> void:
	if not walls.has(cell) or not walls[cell].breakable:
		return
	walls[cell].node.free()
	walls.erase(cell)
	var rubble := _material(Color("a4a38a"))
	for i in range(4):
		var stone := _box(_world, Vector3(0.22, 0.13, 0.25), surface_at(cell) + Vector3((i % 2) * 0.45 - 0.22, 0.065, (i / 2) * 0.6 - 0.3), rubble)
		stone.rotation.y = float(i) * 0.7
	_status.text = "裂墙已破坏，出现缺口；两侧墙段仍然保留。可以从这里穿过。"
	_hover_cell = NONE

func cut_tree(cell: Vector2i) -> void:
	if not trees.has(cell):
		return
	trees[cell].free()
	trees.erase(cell)
	_mesh(_world, _cylinder(0.17, 0.16), _bark, surface_at(cell) + Vector3.UP * 0.08)
	_status.text = "树木已砍倒，留下树桩。现在可以走进这一格。"
	_hover_cell = NONE

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var hit := pick_at(event.position)
		_hover.visible = not hit.is_empty()
		if not hit.is_empty():
			_hover_cell = hit.cell
			_hover.position = surface_at(hit.cell) + Vector3.UP * 0.02
			_marker_mat.albedo_color = Color("f3cf7d") if hit.tree or hit.wall else Color("84d6e4")
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			var hit := pick_at(event.position)
			if not hit.is_empty():
				activate_cell(hit.cell)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_camera.size = maxf(9.0, _camera.size - 0.7)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_camera.size = minf(19.0, _camera.size + 0.7)
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_R:
				sample_seed += 1
				regenerate()
			KEY_Q, KEY_E:
				_angle += -PI / 3.0 if event.keycode == KEY_Q else PI / 3.0
				_update_camera()
			KEY_ESCAPE:
				get_tree().quit()

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	var title := Label.new()
	title.text = "林缘 / 3D 小样"
	title.position = Vector2(28, 22)
	title.add_theme_font_size_override("font_size", 28)
	title.modulate = Color("efe7ce")
	root.add_child(title)
	_detail = Label.new()
	_detail.position = Vector2(30, 64)
	_detail.modulate = Color("a1b8bd")
	root.add_child(_detail)
	var context := Label.new()
	context.text = "示例世界环境\n当前格：森林\n西侧三邻：森林 · 东侧三邻：空地\n道路横穿林缘"
	context.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	context.offset_left = -310
	context.offset_right = -24
	context.offset_top = 26
	context.offset_bottom = 134
	context.modulate = Color("c1cfbf")
	root.add_child(context)
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	panel.offset_left = 24
	panel.offset_right = -24
	panel.offset_top = -94
	panel.offset_bottom = -20
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.055, 0.09, 0.115, 0.93)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(14)
	panel.add_theme_stylebox_override("panel", style)
	root.add_child(panel)
	var stack := VBoxContainer.new()
	panel.add_child(stack)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 17)
	stack.add_child(_status)
	var help := Label.new()
	help.text = "左键：移动 / 破坏相邻树木与裂墙   Q / E：转动视角   滚轮：缩放   R：重新生成   Esc：退出"
	help.modulate = Color("9ab1b8")
	help.add_theme_font_size_override("font_size", 14)
	stack.add_child(help)
