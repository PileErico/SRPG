extends "res://samples/forest_3d/OutpostSample.gd"
## 同一哨站布局上的粗像素实验；地形、建筑、植物与新道具共用材质。

const PixelMaterials := preload("res://samples/forest_3d/PixelMaterials.gd")
const PixelOutpostKit := preload("res://samples/forest_3d/PixelOutpostKit.gd")
const PixelNature := preload("res://samples/forest_3d/PixelNature.gd")
const CART_CELL := Vector2i(6, 5)
const ModelOutline := preload("res://samples/forest_3d/ModelOutline.gd")
const ContactShadow := preload("res://samples/forest_3d/PixelContactShadow.gd")
const PropLibrary := preload("res://samples/forest_3d/PixelPropLibrary.gd")
const PAWN_HEIGHT := 1.2
const PROP_CELLS := {
	"well": Vector2i(6, 6), "barrels": Vector2i(7, 4), "signpost": Vector2i(8, 5),
}
const DEFAULT_PITCH := 0.712
const DEFAULT_TARGET := Vector3(0.0, 0.6, 0.0)

var _model_outlines_enabled := true
var _pawn_source_height := 1
var _camera_pitch := DEFAULT_PITCH
var _camera_target := DEFAULT_TARGET

func _ready() -> void:
	super._ready()
	get_window().title = "林地哨站 · 粗像素样板"
	get_viewport().size_changed.connect(_sync_pawn_pixel_scale)

func _build_stage() -> void:
	super._build_stage()
	get_viewport().msaa_3d = Viewport.MSAA_DISABLED
	# 原生分辨率绘制，像素颗粒由素材的低分辨率贴图和少色色板提供。
	ModelOutline.set_pixel_width(3.0)
	ModelOutline.set_color(PixelMaterials.color("outline"))
	_grid_material.albedo_color = PixelMaterials.color("ground_shadow")

func _update_camera() -> void:
	var horizontal := cos(_camera_pitch) * 25.1
	_camera.position = _camera_target + Vector3(sin(_angle) * horizontal,
		sin(_camera_pitch) * 25.1, cos(_angle) * horizontal)
	_camera.look_at(_camera_target, Vector3.UP)

func _pan_camera(previous: Vector2, current: Vector2) -> void:
	var plane := Plane(Vector3.UP, _camera_target.y)
	var before: Variant = plane.intersects_ray(_camera.project_ray_origin(previous), _camera.project_ray_normal(previous))
	var after: Variant = plane.intersects_ray(_camera.project_ray_origin(current), _camera.project_ray_normal(current))
	if before is Vector3 and after is Vector3:
		_camera_target += before - after
		_camera_target.x = clampf(_camera_target.x, -12.0, 12.0)
		_camera_target.z = clampf(_camera_target.z, -12.0, 12.0)
		_update_camera()

func _reset_camera() -> void:
	_angle = 0.48
	_camera_pitch = DEFAULT_PITCH
	_camera_target = DEFAULT_TARGET
	_camera.size = 16.7
	_update_camera()
	_sync_pawn_pixel_scale()

func _build_tile(cell: Vector2i) -> void:
	super._build_tile(cell)
	var grid := _grid_root.get_child(_grid_root.get_child_count() - 1) as MeshInstance3D
	grid.mesh = _hex_ring(0.99, 0.965)

func _surface_material(kind: String, _fallback: Material) -> Material:
	return PixelMaterials.get_material(kind)

func _nature_model(kind: String, height: float) -> Node3D:
	var model := PixelNature.instantiate_model(kind, height)
	# 小草和低矮灌木保持安静，主要场景体块才描边。
	if kind in ["oak", "broadleaf", "pine", "rock", "rock_flat", "stump", "logs"]:
		model = _outlined(model)
	var holder := Node3D.new()
	holder.name = "PixelNature_" + kind
	holder.add_child(model)
	match kind:
		"oak", "broadleaf", "pine":
			_add_contact_shadow(holder, Vector2(0.72, 0.64))
		"rock", "rock_flat":
			_add_contact_shadow(holder, Vector2(1.05, 0.86))
		"bush":
			_add_contact_shadow(holder, Vector2(0.52, 0.40))
		"stump":
			_add_contact_shadow(holder, Vector2(0.58, 0.52))
		"logs":
			_add_contact_shadow(holder, Vector2(0.70, 1.12), true)
	return holder

func _fort_model(palisade: bool, breakable: bool) -> Node3D:
	var model := _outlined(PixelOutpostKit.make_palisade() if palisade else PixelOutpostKit.make_wall(breakable))
	_add_contact_shadow(model, Vector2(0.57 if palisade else 0.78, SQRT3), true)
	return model

func _gate_model() -> Node3D:
	var model := _outlined(PixelOutpostKit.make_gate())
	for z in [-0.74, 0.74]:
		_add_contact_shadow(model, Vector2(0.48, 0.44), false, Vector3(0, 0, z))
	return model

func _hut_model() -> Node3D:
	var model := _outlined(PixelOutpostKit.make_hut())
	_add_contact_shadow(model, Vector2(2.30, 2.68), true)
	return model

func _rubble_model() -> Node3D:
	var model := _outlined(PixelOutpostKit.make_rubble())
	_add_contact_shadow(model, Vector2(0.95, 1.52))
	return model

func _build_outpost() -> void:
	super._build_outpost()
	_occupied[CART_CELL] = "木车"
	var cart := _object_body(CART_CELL, Vector3(1.24, 1.1, 1.5))
	cart.add_child(_outlined(PixelOutpostKit.make_cart()))
	_add_contact_shadow(cart, Vector2(1.25, 1.25), true, Vector3(0, 0, -0.10))
	for kind: String in PROP_CELLS:
		_build_prop(kind, PROP_CELLS[kind])

func _build_prop(kind: String, cell: Vector2i) -> Node3D:
	var spec: Dictionary = PropLibrary.SPECS[kind]
	_occupied[cell] = spec.label
	var body := _object_body(cell, spec.bounds)
	body.name = "Prop_" + kind
	body.set_meta("pixel_prop", kind)
	body.add_child(_outlined(PropLibrary.make_model(kind)))
	_add_contact_shadow(body, spec.shadow)
	return body

func _add_contact_shadow(parent: Node3D, size: Vector2, rectangular: bool = false, offset := Vector3.ZERO) -> void:
	var shadow := ContactShadow.make(size, rectangular)
	shadow.position += offset
	parent.add_child(shadow)

func _outlined(model: Node3D) -> Node3D:
	ModelOutline.apply_to(model)
	ModelOutline.set_visible(model, _model_outlines_enabled)
	return model

func _build_pawn() -> void:
	super._build_pawn()
	for child in _pawn.get_children():
		if child is MeshInstance3D and child.mesh is CylinderMesh:
			child.free()
		elif child is Sprite3D:
			_pawn_source_height = maxi(1, child.texture.get_image().get_used_rect().size.y)
			child.position.y = 0.01
	_add_contact_shadow(_pawn, Vector2(0.50, 0.28))
	_sync_pawn_pixel_scale()

func _sync_pawn_pixel_scale() -> void:
	if not is_instance_valid(_pawn) or not is_instance_valid(_camera):
		return
	# 原图以整数屏幕像素倍率显示，保留小尺寸人物的像素细节。
	var foot := _camera.unproject_position(_pawn.global_position)
	var above := _camera.unproject_position(_pawn.global_position + _camera.global_basis.y)
	var pixels_per_unit := maxf(0.001, foot.distance_to(above))
	var screen_scale := maxf(1.0, roundf(PAWN_HEIGHT * pixels_per_unit / float(_pawn_source_height)))
	ModelOutline.set_pixel_width(screen_scale)
	for child in _pawn.get_children():
		if child is Sprite3D:
			child.pixel_size = screen_scale / pixels_per_unit

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if event.button_mask & MOUSE_BUTTON_MASK_RIGHT:
			_angle -= event.relative.x * 0.006
			_camera_pitch = clampf(_camera_pitch + event.relative.y * 0.006, deg_to_rad(15.0), deg_to_rad(80.0))
			_update_camera()
			_sync_pawn_pixel_scale()
			_hover.visible = false
			return
		if event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			_pan_camera(event.position - event.relative, event.position)
			_sync_pawn_pixel_scale()
			_hover.visible = false
			return
	if event is InputEventMouseButton:
		if event.button_index in [MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			_hover.visible = false
			return
		if event.button_index == MOUSE_BUTTON_LEFT and (event.button_mask & (MOUSE_BUTTON_MASK_RIGHT | MOUSE_BUTTON_MASK_MIDDLE)):
			return
		if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_camera.size = clampf(_camera.size + (-0.7 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 0.7), 7.0, 24.0)
			_sync_pawn_pixel_scale()
			_hover.visible = false
			return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_C:
		_reset_camera()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_O:
		_model_outlines_enabled = not _model_outlines_enabled
		ModelOutline.set_visible(_world, _model_outlines_enabled)
		return
	super._unhandled_input(event)
	if event is InputEventKey or event is InputEventMouseButton:
		_sync_pawn_pixel_scale()

func _build_ui() -> void:
	super._build_ui()
	(_ui_root.get_parent() as CanvasLayer).layer = 2
	_ui_root.get_node("Eyebrow").text = "场 景 美 术 样 板   /   02"
	_ui_root.get_node("Title").text = "林地哨站 · 像素"
	_ui_root.get_node("SceneBadge").text = "新增：水井 · 木桶 · 路牌\n共享色板 · 自由环绕镜头"
	var help := _status.get_parent().get_child(1) as Label
	help.text = "左键 移动 / 破坏   右键拖动 环绕   中键拖动 平移   滚轮 缩放   Q/E 转向   G 格线   O 描边   C 复位   R 重建"
