extends Control
## 大地图场景（Overworld，M4）：战役层——队伍 token 在大地图上移动；**时间仅在移动/扎营时流动 🔒**。
## 复用底层：HexCanvas(经 OverworldCanvas)/MapIO/TerrainDB/HexGrid——与战斗地图同构（flat-top odd-q）。
## 事件：每落一格评估 EventEngine 的 enter_tile + timer（fired/冷却＝WorldState.event_* 世界持久层）。
## 日夜：随时钟推导（WorldClock.time_of_day → 标签 + EnvDB tint 变暗叠层）；战斗侧日夜注入见 Sandbox._world_time。
## 宿主原语：只实现 event_log（大地图不支持战斗动作 spawn/aggro/set_weather——EventEngine 守卫警告跳过）。
## 存档：移动完成/扎营后自动写 AUTO_SLOT；「继续战役」从 StartMenu 读它。
## 可测性：寻路/耗时/事件评估不依赖 UI 节点（UI 刷新全走 null 守卫）——headless new() 即可测纯逻辑。

const HexGrid := preload("res://HexGrid.gd")
const TerrainDB := preload("res://TerrainDB.gd")
const MapIO := preload("res://MapIO.gd")
const EnvDB := preload("res://EnvDB.gd")
const WorldState := preload("res://WorldState.gd")
const WorldClock := preload("res://WorldClock.gd")
const EventEngine := preload("res://EventEngine.gd")
const SaveIO := preload("res://SaveIO.gd")
const OverworldCanvas := preload("res://OverworldCanvas.gd")

const MAP_PATH := "res://maps/overworld/world.json"
const HOURS_PER_COST := 2    # 占位：1 点地形通行成本 ＝ 2 小时行程（数值层后调）
const CAMP_HOURS := 8        # 占位：扎营一次休整 8 小时（临时据点/职务＝M6）
const AUTO_SLOT := "auto"    # 自动存档槽
const STEP_DELAY := 0.12     # 行进逐格停顿（秒）
const PARTY_TAGS: Array = [] # 队伍通行 tag（暂无船/坐骑——深水/墙 passable_by 列表对空 tags 关闭＝天然屏障）

var width := 15
var height := 15
var tiles := []
var _map_triggers := []
var _map_terrain_overrides := {}

var canvas
var _time_label: Label
var _log: RichTextLabel
var _night_overlay: ColorRect
var _moving := false                    # 行进中（忽略新指令）
var _move_target := Vector2i(-1, -1)    # 当前行进目的地（画布标记用）

func _ready() -> void:
	_ensure_campaign()
	_load_map()
	_ensure_party_placed()
	_build_ui()
	_refresh_time_ui()
	_log_line("抵达大地图。左键点击目标格移动；移动与扎营会推进时间。")

# 无档兜底（直接跑本场景调试/headless 冒烟）：正常入口是 StartMenu 建/读档后进来
func _ensure_campaign() -> void:
	if WorldState.current == null:
		WorldState.start_new()

func _load_map() -> void:
	var res := MapIO.read_file(MAP_PATH)
	if res.get("ok", false):
		width = res["width"]
		height = res["height"]
		tiles = res["tiles"]
		_map_triggers = res.get("triggers", [])
		_map_terrain_overrides = res.get("terrain_overrides", {})
		if str(res.get("map_type", "battle")) != "overworld":
			push_warning("Overworld：地图 %s 的 map_type 不是 overworld（照常加载）" % MAP_PATH)
	else:
		push_warning("Overworld：读不到 %s，回退全草原 %d×%d" % [MAP_PATH, width, height])
		tiles = MapIO.grassland(width, height)

# 首进战役：party 未落位 → 从地图中心 BFS 外扩找第一个可走格
func _ensure_party_placed() -> void:
	var ws = WorldState.current
	if ws.party_col >= 0 and ws.party_row >= 0 and _cell_in_bounds(ws.party_col, ws.party_row):
		return
	@warning_ignore("integer_division")
	var center := Vector2i(width / 2, height / 2)
	var seen := {center: true}
	var queue := [center]
	while not queue.is_empty():
		var cur: Vector2i = queue.pop_front()
		if _move_cost_at(cur.x, cur.y) >= 0:
			ws.party_col = cur.x
			ws.party_row = cur.y
			return
		for nb in HexGrid.neighbors(cur):
			if not seen.has(nb) and _cell_in_bounds(nb.x, nb.y):
				seen[nb] = true
				queue.append(nb)
	ws.party_col = center.x   # 全图不可走（病态图）：硬放中心
	ws.party_row = center.y

# ============ HexCanvas 宿主接口 ============

func color_for_tile(tile) -> Color:
	return TerrainDB.color_of(tile)

func decor_for_tile(tile) -> String:
	return TerrainDB.decor_of(tile)

func accent_for_tile(tile) -> Color:
	return TerrainDB.accent_of(tile)

func begin_stroke() -> void: pass
func end_stroke() -> void: pass
func paint_cell(_col: int, _row: int) -> void: pass
func pick_brush_at(_col: int, _row: int) -> void: pass

func hover_text(col: int, row: int) -> String:
	if not _cell_in_bounds(col, row):
		return ""
	var tile = tiles[row][col]
	var cost := _move_cost_at(col, row)
	var pass_txt := "不可通行" if cost < 0 else "行程 %d 小时/格" % (cost * HOURS_PER_COST)
	return "地形：%s（%d, %d）\n%s" % [TerrainDB.label_of(tile), col, row, pass_txt]

func cancel_action() -> void:
	pass   # 行进不可中断（每格结算已落账）；预留给将来的选目标模式

# 左键点格：寻路并出发（行进中忽略）
func left_click_cell(col: int, row: int) -> void:
	if _moving or not _cell_in_bounds(col, row):
		return
	var ws = WorldState.current
	var from := Vector2i(ws.party_col, ws.party_row)
	var to := Vector2i(col, row)
	if from == to:
		return
	var path := find_path(from, to)
	if path.size() < 2:
		_log_line("那里去不了（无可通行路径）。")
		return
	_travel(path)

# ============ 寻路 / 行程（纯逻辑，可 headless 测）============

func _cell_in_bounds(col: int, row: int) -> bool:
	return col >= 0 and col < width and row >= 0 and row < height

# 队伍在该格的通行成本（-1=不可通行）：图级覆盖 ?? 全局 terrains.json，经 TerrainDB.move_cost 单一实现
func _move_cost_at(col: int, row: int) -> int:
	if not _cell_in_bounds(col, row):
		return -1
	var tile = tiles[row][col]
	var mv = null
	if not _map_terrain_overrides.is_empty():
		var key := "%s/%s" % [str(tile.get("terrain", "")), str(tile.get("variant", ""))]
		var ov = _map_terrain_overrides.get(key)
		if typeof(ov) == TYPE_DICTIONARY and typeof(ov.get("move")) == TYPE_DICTIONARY:
			mv = ov["move"]
	if mv == null:
		var e = TerrainDB.entry_for(tile)
		mv = e.get("move", {}) if e != null else {}
	return TerrainDB.move_cost(mv, PARTY_TAGS)

# Dijkstra 最小成本路径（含起终点的格序列）；不可达返回 []
func find_path(from: Vector2i, to: Vector2i) -> Array:
	if not _cell_in_bounds(to.x, to.y) or _move_cost_at(to.x, to.y) < 0:
		return []
	var best := {from: 0}
	var came := {}
	var open := [from]
	while not open.is_empty():
		var idx := 0   # 简版优先队列：线性取最小（大地图尺寸下开销可忽略）
		for i in open.size():
			if best[open[i]] < best[open[idx]]:
				idx = i
		var cur: Vector2i = open[idx]
		open.remove_at(idx)
		if cur == to:
			break
		for nb in HexGrid.neighbors(cur):
			var step := _move_cost_at(nb.x, nb.y)
			if step < 0:
				continue
			var nc: int = best[cur] + step
			if not best.has(nb) or nc < best[nb]:
				best[nb] = nc
				came[nb] = cur
				open.append(nb)
	if not came.has(to):
		return []
	var path := [to]
	var walker: Vector2i = to
	while walker != from:
		walker = came[walker]
		path.push_front(walker)
	return path

# 沿路径逐格行进：每格＝落位 → 推进时钟（成本×HOURS_PER_COST，经 WorldClock 走恢复调度）→ 评估事件 → 重绘停顿
func _travel(path: Array) -> void:
	_moving = true
	_move_target = path.back()
	var ws = WorldState.current
	for i in range(1, path.size()):
		var cell: Vector2i = path[i]
		ws.party_col = cell.x
		ws.party_row = cell.y
		WorldClock.advance(ws, _move_cost_at(cell.x, cell.y) * HOURS_PER_COST)
		_refresh_time_ui()
		_check_cell_events(cell)
		if canvas != null:
			canvas.queue_redraw()
		if is_inside_tree():
			await get_tree().create_timer(STEP_DELAY).timeout
	_moving = false
	_move_target = Vector2i(-1, -1)
	if canvas != null:
		canvas.queue_redraw()
	SaveIO.save_campaign(ws, AUTO_SLOT)

# 一格落位后的事件评估：enter_tile（含概率/冷却/全局间隔）+ timer（时钟刚被推进）
func _check_cell_events(cell: Vector2i) -> void:
	var ws = WorldState.current
	EventEngine.check_enter_tile(_map_triggers, cell, "player", ws.event_fired, self, ws)
	EventEngine.check_timer(_map_triggers, ws, self)

# 扎营：原地休整推进时钟（恢复结算走 WorldClock 调度表；临时据点/职务＝M6）
func _on_camp() -> void:
	if _moving:
		return
	var ws = WorldState.current
	WorldClock.advance(ws, CAMP_HOURS)
	_log_line("⛺ 扎营休整 %d 小时。" % CAMP_HOURS)
	_refresh_time_ui()
	EventEngine.check_timer(_map_triggers, ws, self)
	if canvas != null:
		canvas.queue_redraw()
	SaveIO.save_campaign(ws, AUTO_SLOT)

# ============ EventEngine 宿主原语 ============

func event_log(text: String) -> void:
	_log_line("⚑ %s" % text)

# ============ 画布数据源 ============

func party_cell() -> Vector2i:
	var ws = WorldState.current
	return Vector2i(ws.party_col, ws.party_row) if ws != null else Vector2i(-1, -1)

func move_target() -> Vector2i:
	return _move_target

# ============ UI（纯代码建，仿工程惯例；headless new() 不建 UI 也能跑逻辑）============

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	var top := HBoxContainer.new()
	top.custom_minimum_size = Vector2(0, 40)
	top.add_theme_constant_override("separation", 12)
	root.add_child(top)
	_time_label = Label.new()
	_time_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_time_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top.add_child(_time_label)
	var camp_b := Button.new()
	camp_b.text = "⛺ 扎营（+%d 小时）" % CAMP_HOURS
	camp_b.pressed.connect(_on_camp)
	top.add_child(camp_b)
	var menu_b := Button.new()
	menu_b.text = "返回菜单"
	menu_b.pressed.connect(_on_back_to_menu)
	top.add_child(menu_b)

	canvas = OverworldCanvas.new()
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas.editor = self
	root.add_child(canvas)
	canvas.request_fit()
	# 夜晚变暗滤镜：盖画布（不吃输入）；随时钟 tint 显隐
	_night_overlay = ColorRect.new()
	_night_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_night_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_night_overlay.visible = false
	canvas.add_child(_night_overlay)

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.custom_minimum_size = Vector2(0, 110)
	root.add_child(_log)

func _refresh_time_ui() -> void:
	var ws = WorldState.current
	if ws == null:
		return
	if _time_label != null:
		_time_label.text = "  🕐 %s" % WorldClock.describe(ws.clock_hours)
	if _night_overlay != null:
		var tint := EnvDB.time_tint(WorldClock.time_of_day(ws.clock_hours))
		if tint != "":
			_night_overlay.color = Color.html(tint)
			_night_overlay.visible = true
		else:
			_night_overlay.visible = false

func _log_line(text: String) -> void:
	if _log != null:
		_log.append_text(text + "\n")

# 返回菜单：先自动存档（current 保留——菜单「继续」可无缝回来）
func _on_back_to_menu() -> void:
	SaveIO.save_campaign(WorldState.current, AUTO_SLOT)
	get_tree().change_scene_to_file("res://StartMenu.tscn")
