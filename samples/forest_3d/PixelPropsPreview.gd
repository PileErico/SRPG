extends "res://samples/forest_3d/PixelOutpostSample.gd"
## 同一渲染与素材规格下的近景陈列；与哨站共用模型、材质和自由环绕操作。

const DISPLAY_CELLS := {"well": Vector2i(2, 4), "barrels": Vector2i(4, 4), "signpost": Vector2i(6, 4)}
const REFERENCE_CELL := Vector2i(3, 6)

func _ready() -> void:
	super._ready()
	get_window().title = "新增物件 · 像素材质对照"

func _build_stage() -> void:
	super._build_stage()
	_reset_camera()

func _reset_camera() -> void:
	_angle = 0.20
	_camera_pitch = deg_to_rad(40.0)
	_camera_target = Vector3(0.0, 0.45, 1.4)
	_camera.size = 8.8
	_update_camera()
	_sync_pawn_pixel_scale()

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
	_rng.seed = 11
	_hover_cell = NONE
	for cell: Vector2i in [Vector2i(2, 4), Vector2i(4, 4), Vector2i(6, 4), REFERENCE_CELL]:
		cells[cell] = {"height": 0, "forest": 0.0, "road": false}
		_build_tile(cell)
	for kind: String in DISPLAY_CELLS:
		_build_prop(kind, DISPLAY_CELLS[kind])
	pawn_cell = REFERENCE_CELL
	_build_pawn()
	_hover = _mesh(_world, _hex_ring(0.95, 0.88), _marker_mat, Vector3.ZERO)
	_hover.visible = false
	_hover.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_status.text = "从左到右：水井、木桶、路牌。前方人物作为尺寸参照。"
	_detail.text = "共用石材、木材与金属 · 同一像素密度 · 同一套色板"

func _build_ui() -> void:
	super._build_ui()
	_ui_root.get_node("Eyebrow").text = "新 增 物 件   /   同 规 格 试 制"
	_ui_root.get_node("Title").text = "水井 · 木桶 · 路牌"
	_ui_root.get_node("SceneBadge").text = "正面人物 · 自由环绕\n右键 旋转  /  中键 平移"
	var help := _status.get_parent().get_child(1) as Label
	help.text = "右键拖动 环绕与俯角     中键拖动 平移     滚轮 缩放     Q/E 转向     G 格线     O 描边     C 复位     Esc 退出"
