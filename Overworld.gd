extends Control
## 大地图场景（Overworld，M4）：战役层——队伍 token 在大地图上移动；**时间仅在移动/扎营时流动 🔒**。
## 复用底层：HexCanvas(经 OverworldCanvas)/MapIO/TerrainDB/HexGrid——与战斗地图同构（flat-top odd-q）。
## 事件：每落一格评估 EventEngine 的 enter_tile + timer（fired/冷却＝WorldState.event_* 世界持久层）。
## 日夜：随时钟推导（WorldClock.time_of_day → 标签 + EnvDB tint 变暗叠层）；战斗侧日夜注入见 Sandbox._world_time。
## 宿主原语：event_log / event_start_battle / event_dialogue（大地图不支持战斗动作 spawn/aggro/set_weather——EventEngine 守卫警告跳过）。
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
const BattleIO := preload("res://BattleIO.gd")
const SandboxConfig := preload("res://SandboxConfig.gd")
const JobDB := preload("res://JobDB.gd")   # 营地职务注册表（M6 框架）
const DialogueUI := preload("res://DialogueUI.gd")   # 通用对话模块（M8）
const LocationDB := preload("res://LocationDB.gd")   # 地点类型/服务注册表（M7）
const FactionDB := preload("res://FactionDB.gd")     # 派系/声望注册表（M9）
const WorldSim := preload("res://WorldSim.gd")       # 大地图动态单位模拟（🟡 v1：玩家移动=世界回合）
const WorldUnitDB := preload("res://WorldUnitDB.gd") # 动态单位类型注册表
const MinHeap := preload("res://MinHeap.gd")         # 寻路优先队列（find_path；与 BattleState._dijkstra 共用实现）

const MAP_PATH := "res://maps/overworld/world.json"
const HOURS_PER_COST := 2    # 占位：1 点地形通行成本 ＝ 2 小时行程（数值层后调）
const CAMP_HOURS := 8        # 占位：扎营一次休整 8 小时（临时据点/职务＝M6）
# 自动存档槽名单一源＝SaveIO.AUTO_SLOT（实例注入见 _save_slot）
const STEP_DELAY := 0.12     # 行进逐格停顿（秒）
const PARTY_TAGS: Array = [] # 队伍通行 tag（暂无船/坐骑——深水/墙 passable_by 列表对空 tags 关闭＝天然屏障）

var width := 15
var height := 15
var tiles := []
var _map_triggers := []
var _map_terrain_overrides := {}
var _map_locations := []      # 地图 locations 字段（M7）：地点实例 [{id,type,label,col,row,battle_map?,dialogue_id?}]
var _loc_by_cell := {}        # {Vector2i: loc} 落格索引（悬停/点击/抵达 O(1) 查）
# 线特征（schema v4）：原始数据（渲染钩子透出）+ 边索引（{HexGrid.edge_key: true}，跨边通行 O(1) 查）
var _map_rivers := []
var _map_roads := []
var _map_bridges := []
var _river_edges := {}
var _road_edges := {}
var _bridge_edges := {}
var _map_regions := []        # 地图 regions 字段：大地图按「区域外轮廓虚线」渲染（派系领地/区域解锁可视化，纯视觉）

var canvas
var _time_label: Label
var _log: RichTextLabel
var _night_overlay: ColorRect
var _moving := false                    # 行进中（忽略新指令）
var _move_target := Vector2i(-1, -1)    # 当前行进目的地（画布标记用）
var _save_slot: String = SaveIO.AUTO_SLOT   # 自动存档槽（单一源在 SaveIO；测试可注入独立槽）
var _transient := false                 # 兜底建的调试档：只活内存、绝不自动落盘（防覆盖玩家 auto 真档）
var _dialogue = null                    # 打开中的对话（DialogueUI；行进遇事件对话＝暂停等它播完）

func _ready() -> void:
	_ensure_campaign()
	_load_map()
	_ensure_party_placed()
	WorldSim.ensure_spawned(WorldState.current, self)   # 动态单位开局生成（幂等，flags 记账）
	_build_ui()
	_refresh_time_ui()
	_log_line("抵达大地图。左键点击目标格移动；移动与扎营会推进时间。")
	_autosave()   # 新开局立即落盘（否则首次移动前关窗＝战役无痕消失）；调试兜底档在 _autosave 内被拦

# 无档兜底（直接跑本场景调试/headless 冒烟）：正常入口是 StartMenu 建/读档后进来。
# 兜底档标记 transient——不自动落盘，防止调试直跑一步移动就覆盖玩家的 auto 真档。
func _ensure_campaign() -> void:
	if WorldState.current == null:
		WorldState.start_new()
		_transient = true

func _load_map() -> void:
	var res := MapIO.read_file(MAP_PATH)
	if res.get("ok", false):
		width = res["width"]
		height = res["height"]
		tiles = res["tiles"]
		_map_triggers = res.get("triggers", [])
		_map_terrain_overrides = res.get("terrain_overrides", {})
		_setup_locations(res.get("locations", []))
		_setup_line_features(res)
		_map_regions = res.get("regions", [])   # 区域（外轮廓虚线渲染；透传原始 [[x,y]] 形，绘制时转 Vector2i）
		if str(res.get("map_type", "battle")) != "overworld":
			push_warning("Overworld：地图 %s 的 map_type 不是 overworld（照常加载）" % MAP_PATH)
		# 世界层触发器必须有 id：once/冷却/timer 状态按 id 随档持久，无 id 会退化成数组下标 key（"#N"），
		# 地图改版增删触发器后旧档状态会错位到别的触发器（战斗侧每战清零无此患）。
		for i in _map_triggers.size():
			var t = _map_triggers[i]
			if typeof(t) == TYPE_DICTIONARY and str(t.get("id", "")) == "":
				push_warning("Overworld：triggers[%d]「%s」无 id——世界层持久状态将按下标记档，地图改版会错位；请补 id" % [i, str(t.get("label", "?"))])
	else:
		push_warning("Overworld：读不到 %s，回退全草原 %d×%d" % [MAP_PATH, width, height])
		tiles = MapIO.grassland(width, height)

# 装地点实例：校验（id/类型/在界内）+ 建落格索引。状态（据点肃清时刻）在档里，这里只有静态定义。
func _setup_locations(raw: Array) -> void:
	_map_locations = []
	_loc_by_cell = {}
	for loc in raw:
		if typeof(loc) != TYPE_DICTIONARY:
			continue
		var cell := Vector2i(int(loc.get("col", -1)), int(loc.get("row", -1)))
		if str(loc.get("id", "")) == "" or LocationDB.type_def(str(loc.get("type", ""))) == null or not _cell_in_bounds(cell.x, cell.y):
			push_warning("Overworld：地点「%s」缺 id/类型未登记/越界，跳过" % str(loc.get("label", loc.get("id", "?"))))
			continue
		_map_locations.append(loc)
		_loc_by_cell[cell] = loc

# 装线特征（v4）：留原始数据（渲染）+ 建边索引（通行）。坏格对（非相邻/越界）忽略。
func _setup_line_features(res: Dictionary) -> void:
	_map_rivers = res.get("rivers", [])
	_map_roads = res.get("roads", [])
	_map_bridges = res.get("bridges", [])
	_river_edges = _edge_index(_pairs_of(_map_rivers))
	_road_edges = _edge_index(_pairs_of(_map_roads))
	_bridge_edges = _edge_index(_map_bridges)

# 特征列表（[{pairs:[…]}]）→ 扁平格对列表
func _pairs_of(features: Array) -> Array:
	var out := []
	for f in features:
		if typeof(f) == TYPE_DICTIONARY and typeof(f.get("pairs")) == TYPE_ARRAY:
			out.append_array(f["pairs"])
	return out

# 格对列表 → {边键: true}（键归一走 HexGrid.edge_key；坏形/非相邻丢弃）
func _edge_index(pairs: Array) -> Dictionary:
	var out := {}
	for p in pairs:
		if typeof(p) != TYPE_ARRAY or p.size() < 2:
			continue
		var a = p[0]
		var b = p[1]
		if typeof(a) != TYPE_ARRAY or a.size() < 2 or typeof(b) != TYPE_ARRAY or b.size() < 2:
			continue
		var va := Vector2i(int(a[0]), int(a[1]))
		var vb := Vector2i(int(b[0]), int(b[1]))
		if HexGrid.adjacent(va, vb):
			out[HexGrid.edge_key(va, vb)] = true
	return out

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

# 线特征渲染钩子（HexCanvas has_method 可选契约；与编辑器/战斗侧同名同形）
func line_features() -> Dictionary:
	return {"rivers": _map_rivers, "roads": _map_roads, "bridges": _map_bridges}

# 区域轮廓渲染钩子（OverworldCanvas 静态层描边用）：[{cells:[Vector2i…], color:Color, label}]。
# 界内格才收（越界数据丢弃）；color 缺省白。纯视觉——派系领地/区域解锁可视化。
func regions_for_draw() -> Array:
	var out := []
	for reg in _map_regions:
		if typeof(reg) != TYPE_DICTIONARY:
			continue
		var cells := []
		for cp in reg.get("cells", []):
			if typeof(cp) == TYPE_ARRAY and cp.size() >= 2:
				var v := Vector2i(int(cp[0]), int(cp[1]))
				if _cell_in_bounds(v.x, v.y):
					cells.append(v)
		if cells.is_empty():
			continue
		out.append({"cells": cells, "color": Color.html(str(reg.get("color", "#FFFFFF"))), "label": str(reg.get("label", ""))})
	return out

func hover_text(col: int, row: int) -> String:
	if not _cell_in_bounds(col, row):
		return ""
	var tile = tiles[row][col]
	var cost := _move_cost_at(col, row)
	# 格自身通行性（地形 base 成本，非最终耗时——过河/沿路的实际扣时按「边」算，见下方从当前位置进入的提示）
	var pass_txt := "不可通行（地形）" if cost < 0 else "地形成本 %d（约 %d 小时）" % [cost, cost * HOURS_PER_COST]
	var txt := "地形：%s（%d, %d）\n%s" % [TerrainDB.label_of(tile), col, row, pass_txt]
	# 若与队伍相邻：给出「从当前位置进入这一格」的真实边成本（吃河阻断/桥·路折扣，与寻路/行程同源）
	var ws0 = WorldState.current
	if ws0 != null and cost >= 0:
		var from := Vector2i(ws0.party_col, ws0.party_row)
		if HexGrid.distance(from, Vector2i(col, row)) == 1:
			var ec := _move_cost_between(from.x, from.y, col, row)
			if ec < 0:
				txt += "\n⚠ 从当前位置：隔河，须绕行到桥"
			else:
				txt += "\n从当前位置进入：约 %d 小时" % (ec * HOURS_PER_COST)
	var loc = _loc_by_cell.get(Vector2i(col, row))
	if loc != null:
		txt = "📍 %s（%s）%s\n%s" % [str(loc.get("label", "")), LocationDB.type_label(str(loc.get("type", ""))), _site_status_text(loc), txt]
	var ws = WorldState.current
	if ws != null:
		for u in ws.world_units:
			if int(u.get("col", -1)) == col and int(u.get("row", -1)) == row:
				txt = "🚶 %s（%s%s）\n%s" % [WorldUnitDB.label(str(u.get("type", ""))),
					FactionDB.label(str(u.get("faction", ""))),
					"·敌对" if FactionDB.hostile(ws, str(u.get("faction", ""))) else "", txt]
				break
	return txt

# 据点状态短文案（悬停/面板共用）："" ＝ 非据点；可挑战 / 刷新倒计时 / 已肃清不再刷新
func _site_status_text(loc: Dictionary) -> String:
	if not LocationDB.is_site(str(loc.get("type", ""))):
		return ""
	if LocationDB.site_ready(loc, WorldState.current):
		return "——可挑战"
	var left := LocationDB.site_respawn_in(loc, WorldState.current)
	return "——已肃清（%s）" % ("约 %d 小时后刷新" % left if left > 0 else "不再刷新")

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
		if _loc_by_cell.has(to):
			_open_location_panel(_loc_by_cell[to])   # 原地点自己脚下的地点＝重新进入
		return
	var path := find_path(from, to)
	if path.size() < 2:
		_log_line("那里去不了（无可通行路径）。")
		return
	_travel(path)

# ============ 寻路 / 行程（纯逻辑，可 headless 测）============

func _cell_in_bounds(col: int, row: int) -> bool:
	return col >= 0 and col < width and row >= 0 and row < height

# 队伍在该格的通行成本（-1=不可通行）：覆盖合并 + 成本计算都走 TerrainDB 单一实现（与战斗侧同源）
func _move_cost_at(col: int, row: int) -> int:
	if not _cell_in_bounds(col, row):
		return -1
	return TerrainDB.move_cost(TerrainDB.effective_move(tiles[row][col], _map_terrain_overrides), PARTY_TAGS)

# 跨边通行成本（from→to 相邻格；-1=不可跨）——线特征语义的单一实现：
#   河边无桥＝硬阻断；有桥＝可跨且享道路折扣；道路边＝成本折为 min(目的格成本, 1)（穿林翻山的大道）。
# 寻路（find_path）与行程扣时（_travel）都读这里，保证「路径成本＝实际耗时」不脱节；WorldSim 游荡同用。
func _move_cost_between(from_col: int, from_row: int, col: int, row: int) -> int:
	var base := _move_cost_at(col, row)
	if base < 0:
		return -1
	var key := HexGrid.edge_key(Vector2i(from_col, from_row), Vector2i(col, row))
	if _river_edges.has(key) and not _bridge_edges.has(key):
		return -1
	if _road_edges.has(key) or _bridge_edges.has(key):
		return mini(base, 1)
	return base

# Dijkstra 最小成本路径（含起终点的格序列）；不可达返回 []。步进成本＝跨边成本（河阻断/桥豁免/道路折扣）。
func find_path(from: Vector2i, to: Vector2i) -> Array:
	if not _cell_in_bounds(to.x, to.y) or _move_cost_at(to.x, to.y) < 0:
		return []
	var best := {from: 0}
	var came := {}
	var open = MinHeap.new()   # 二叉堆优先队列（2026-07-07 规模化；懒删除无 decrease-key）
	open.push(0, from)
	while not open.is_empty():
		var e: Array = open.pop()
		var cur: Vector2i = e[1]
		if int(e[0]) > int(best.get(cur, -1)):
			continue   # 过期堆项：该格已有更优成本
		if cur == to:
			break
		for nb in HexGrid.neighbors(cur):
			var step := _move_cost_between(cur.x, cur.y, nb.x, nb.y)
			if step < 0:
				continue
			var nc: int = int(best[cur]) + step
			if not best.has(nb) or nc < int(best[nb]):
				best[nb] = nc
				came[nb] = cur
				open.push(nc, nb)
	if not came.has(to):
		return []
	var path := [to]
	var walker: Vector2i = to
	while walker != from:
		walker = came[walker]
		path.push_front(walker)
	return path

# 沿路径逐格行进：每格＝落位 → 推进时钟（跨边成本×HOURS_PER_COST，与寻路同源）→ 评估事件 → 重绘停顿
func _travel(path: Array) -> void:
	_moving = true
	_move_target = path.back()
	var ws = WorldState.current
	for i in range(1, path.size()):
		var prev: Vector2i = path[i - 1]
		var cell: Vector2i = path[i]
		ws.party_col = cell.x
		ws.party_row = cell.y
		_advance_world(maxi(_move_cost_between(prev.x, prev.y, cell.x, cell.y), 0) * HOURS_PER_COST)
		_refresh_time_ui()
		_check_cell_events(cell)
		if _dialogue != null and is_inside_tree():
			await _dialogue.finished   # 事件对话：行进暂停到播完（headless 无 UI 不等）
		if canvas != null:
			canvas.queue_redraw()
		if is_inside_tree():
			await get_tree().create_timer(STEP_DELAY).timeout
	_moving = false
	_move_target = Vector2i(-1, -1)
	if canvas != null:
		canvas.queue_redraw()
	_autosave()
	# 抵达地点＝自动进入（面板；途经不进——BB 式点到才停靠）。change_scene 已在途（事件开战）则不弹。
	var dest := Vector2i(ws.party_col, ws.party_row)
	if _loc_by_cell.has(dest):
		_open_location_panel(_loc_by_cell[dest])

# 时钟推进统一入口：推钟（恢复调度）→ 世界回合（动态单位随玩家活动移动 🔒）→ 事件表现。
# 战斗类事件（engage）由 _start_battle_with 收口；一次推进至多一场（WorldSim 保证）。
func _advance_world(hours: int) -> void:
	var ws = WorldState.current
	WorldClock.advance(ws, hours)
	for e in WorldSim.tick(ws, hours, self):
		match str(e.get("kind", "")):
			"engage_player":
				var u: Dictionary = e["unit"]
				var t = WorldUnitDB.type_def(str(u.get("type", "")))
				_log_line("⚔ [b]%s[/b] 追上了你们！" % WorldUnitDB.label(str(u.get("type", ""))))
				_start_battle_with(str(t.get("battle_map", "res://maps/sandbox.json")) if t != null else "res://maps/sandbox.json",
					{"world_unit_uid": int(u.get("uid", 0)), "faction_id": str(u.get("faction", ""))})
			"skirmish":
				var hunter := WorldUnitDB.label(str((e["hunter"] as Dictionary).get("type", "")))
				var prey := WorldUnitDB.label(str((e["prey"] as Dictionary).get("type", "")))
				_log_line("🗡 %s%s了%s。" % [hunter, "击溃" if bool(e.get("prey_died", true)) else "反被击溃——输给", prey])
			"caravan_arrive":
				pass   # 商队到站：暂不播报（避免刷屏；交易接入后再表现）

# 一格落位后的事件评估：地图触发器 enter_tile + 敌对派系遭伏（M9 伪触发器）+ timer（时钟刚被推进）
func _check_cell_events(cell: Vector2i) -> void:
	var ws = WorldState.current
	EventEngine.check_enter_tile(_map_triggers, cell, "player", ws.event_fired, self, ws)
	EventEngine.check_enter_tile(_hostile_ambush_triggers(), cell, "player", ws.event_fired, self, ws)
	EventEngine.check_timer(_map_triggers, ws, self)

# 敌对派系遭伏（M9）：把当前敌对的派系转成 enter_tile 伪触发器喂 EventEngine——
# 复用同一套 chance/冷却闸门（tid 稳定＝"faction_ambush_<id>"，冷却随档持久）；参数全在 factions.json。
func _hostile_ambush_triggers() -> Array:
	var out := []
	var ws = WorldState.current
	for f in FactionDB.all_factions():
		var fid := str(f["id"])
		if not FactionDB.hostile(ws, fid):
			continue
		var amb = f.get("ambush", {})
		if typeof(amb) != TYPE_DICTIONARY or amb.is_empty():
			continue
		out.append({"id": "faction_ambush_%s" % fid, "label": "%s遭伏" % FactionDB.label(fid),
			"when": {"event": "enter_tile", "once": false,
				"chance": float(amb.get("chance", 10)), "cooldown_hours": int(amb.get("cooldown_hours", 24))},
			"do": [{"action": "show_message", "text": str(amb.get("text", "遭到伏击！"))},
				{"action": "start_battle", "map": str(amb.get("battle_map", "res://maps/sandbox.json"))}]})
	return out

# 扎营：原地休整推进时钟（恢复结算走 WorldClock 调度表；临时据点/职务＝M6）
func _on_camp() -> void:
	if _moving:
		return
	var ws = WorldState.current
	_advance_world(CAMP_HOURS)
	_log_line("⛺ 扎营休整 %d 小时。" % CAMP_HOURS)
	_refresh_time_ui()
	EventEngine.check_timer(_map_triggers, ws, self)
	if canvas != null:
		canvas.queue_redraw()
	_autosave()

# ============ EventEngine 宿主原语 ============

func event_log(text: String) -> void:
	_log_line("⚑ %s" % text)

# 改声望（do: add_rep，M9）：写口在 FactionDB（默认值兜底+钳制）
func event_add_rep(faction_id: String, delta: int) -> void:
	var ws = WorldState.current
	if ws == null:
		return
	FactionDB.add_rep(ws, faction_id, delta)
	_log_line("🚩 %s 声望 %+d → %d%s" % [FactionDB.label(faction_id), delta,
		FactionDB.rep_of(ws, faction_id), "（敌对！）" if FactionDB.hostile(ws, faction_id) else ""])

# 设世界 flag（do: set_flag，M9）：任务/事件状态的通用兜底存储
func event_set_flag(key: String, value) -> void:
	var ws = WorldState.current
	if ws == null:
		return
	ws.flags[key] = value

# 开对话（do: dialogue）：模态覆盖大地图；行进中触发＝_travel 暂停等 finished（M8）
func event_dialogue(dialogue_id: String) -> void:
	if _dialogue != null and is_instance_valid(_dialogue):
		push_warning("Overworld：已有对话进行中，跳过「%s」" % dialogue_id)
		return
	var ui = DialogueUI.new()
	_dialogue = ui
	add_child(ui)
	ui.finished.connect(func(): _dialogue = null)   # 先连再 start：start 失败同步 finished 也能清引用
	ui.start(dialogue_id, WorldState.current)

# 进入战斗（do: start_battle）：事件遭遇战，无来由上下文
func event_start_battle(map_path: String) -> void:
	_start_battle_with(map_path, {})

# 进战斗单一实现：健康 roster 全员自动出战（战前选人 UI/预设队伍后置——长在 BattleSetup 上）。
# context=战斗来由（{location_id}＝据点讨伐，胜后 BattleIO.apply_result 落肃清账）。
# 快照进/结果出契约见 BattleIO；胜负后 Sandbox 回写并送回本场景。
func _start_battle_with(map_path: String, context: Dictionary) -> void:
	var ws = WorldState.current
	if ws == null:
		return
	if SandboxConfig.battle_setup != null:
		return   # 已有战斗待切场景（同一步连环触发：遭伏+动态单位等）：先到先得，后来的不打
	var uids := []
	for u in ws.roster:
		if int(u.injured_until) > ws.clock_hours:
			continue   # 重伤休整中不可出战（需求 §1.11「战后持续一段时间无法参与任何活动」）
		uids.append(u.uid)
	if uids.is_empty():
		_log_line("⚔ 全员重伤休整中，无人可战——遭遇不了了之。")
		return
	SandboxConfig.battle_setup = BattleIO.make_setup(map_path, uids, [], context)
	_autosave()   # 进战斗前落盘（战斗不耗世界时间 🔒，回来时钟原样）
	if is_inside_tree():
		get_tree().change_scene_to_file("res://Sandbox.tscn")

# ============ 地点（M7）：城市/村落服务面板 + 遗迹/据点讨伐（定义 LocationDB / 状态 ws.location_cleared_at）============

var _loc_popup: PopupPanel

# 休整（rest 服务，首个已接入的城市功能）：扣钱 → 推进时钟（走 WorldClock 调度）→ 全员回满 HP（占位数值在
# locations.json services.rest；重伤 injured_until 照旧按时计，不被旅店治好）。返回是否成交（钱不够=false）。
func _do_rest(loc: Dictionary) -> bool:
	var ws = WorldState.current
	var svc = LocationDB.service("rest")
	if ws == null or svc == null:
		return false
	var cost := int(svc.get("gold", 0))
	if ws.gold < cost:
		_log_line("💰 盘缠不够（需 %d，有 %d）——住不起店。" % [cost, ws.gold])
		return false
	ws.gold -= cost
	_advance_world(int(svc.get("hours", 8)))
	for u in ws.roster:
		if float(u.stats.get("HP", 0)) > 0.0:
			u.stats["HP"] = u.effective_stat("HP_max")
	_log_line("🛏 在「%s」休整 %d 小时（-%d💰）：全员生命回满。" % [str(loc.get("label", "")), int(svc.get("hours", 8)), cost])
	_refresh_time_ui()
	EventEngine.check_timer(_map_triggers, ws, self)
	if canvas != null:
		canvas.queue_redraw()
	_autosave()
	return true

# 讨伐据点：可挑战才开打（带 location_id 上下文——胜后 BattleIO 落肃清账、按类型 respawn_hours 刷新）
func _challenge_site(loc: Dictionary) -> void:
	if not LocationDB.site_ready(loc, WorldState.current):
		_log_line("此处已被肃清，暂无敌踪。")
		return
	_start_battle_with(str(loc.get("battle_map", "res://maps/sandbox.json")), {"location_id": str(loc.get("id", ""))})

# 地点面板：城市/村落＝服务列表（rest 已接入；planned 灰显 ⏳）+ 可选交谈；遗迹/据点＝状态 + 进攻。
func _open_location_panel(loc: Dictionary) -> void:
	if not is_inside_tree():
		return   # headless：面板纯 UI，逻辑走 _do_rest/_challenge_site 直测
	if _loc_popup != null:
		_loc_popup.queue_free()
	_loc_popup = PopupPanel.new()
	add_child(_loc_popup)
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(380, 0)
	v.add_theme_constant_override("separation", 6)
	_loc_popup.add_child(v)
	var type_id := str(loc.get("type", ""))
	var title := Label.new()
	title.text = "📍 %s（%s）" % [str(loc.get("label", "")), LocationDB.type_label(type_id)]
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", LocationDB.type_color(type_id))
	v.add_child(title)
	var desc := Label.new()
	desc.text = str(LocationDB.type_def(type_id).get("desc", ""))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_color_override("font_color", Color(0.65, 0.68, 0.75))
	v.add_child(desc)
	if LocationDB.is_site(type_id):
		_build_site_rows(v, loc)
	else:
		_build_service_rows(v, loc)
	_loc_popup.popup_centered()

# 据点区：状态行 + 进攻按钮
func _build_site_rows(v: VBoxContainer, loc: Dictionary) -> void:
	var st := Label.new()
	st.text = "状态：%s" % _site_status_text(loc).trim_prefix("——")
	v.add_child(st)
	var b := Button.new()
	b.text = "⚔ 进攻"
	b.disabled = not LocationDB.site_ready(loc, WorldState.current)
	b.pressed.connect(func():
		_loc_popup.hide()
		_challenge_site(loc))
	v.add_child(b)

# 服务区：注册表驱动（LocationDB.services_of）——rest 已接入、planned 灰显；有 dialogue_id 加「交谈」
func _build_service_rows(v: VBoxContainer, loc: Dictionary) -> void:
	var ws = WorldState.current
	for svc in LocationDB.services_of(str(loc.get("type", ""))):
		var sid := str(svc.get("id", ""))
		var b := Button.new()
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.tooltip_text = str(svc.get("desc", ""))
		if sid == "rest" and str(svc.get("status", "")) == "in_use":
			b.text = "🛏 %s　-%d💰 / +%d 小时" % [str(svc.get("label", sid)), int(svc.get("gold", 0)), int(svc.get("hours", 8))]
			b.disabled = ws == null or ws.gold < int(svc.get("gold", 0))
			b.pressed.connect(func():
				if _do_rest(loc):
					_open_location_panel(loc))   # 重建面板：金钱/时间变了
		else:
			b.text = "%s ⏳" % str(svc.get("label", sid))
			b.disabled = true   # planned：效果待各自系统（经济/招募池/词条铁匠）
		v.add_child(b)
	if str(loc.get("dialogue_id", "")) != "":
		var t := Button.new()
		t.alignment = HORIZONTAL_ALIGNMENT_LEFT
		t.text = "💬 交谈"
		t.pressed.connect(func():
			_loc_popup.hide()
			event_dialogue(str(loc.get("dialogue_id", ""))))
		v.add_child(t)

# ============ 画布数据源 ============

func party_cell() -> Vector2i:
	var ws = WorldState.current
	return Vector2i(ws.party_col, ws.party_row) if ws != null else Vector2i(-1, -1)

func move_target() -> Vector2i:
	return _move_target

# 动态单位标记数据（画布逐帧调；量级＝个位数）：敌对（对玩家）标红圈
func world_units_for_draw() -> Array:
	var out := []
	var ws = WorldState.current
	if ws == null:
		return out
	for u in ws.world_units:
		var t = WorldUnitDB.type_def(str(u.get("type", "")))
		if t == null:
			continue
		out.append({
			"cell": Vector2i(int(u.get("col", 0)), int(u.get("row", 0))),
			"color": FactionDB.color(str(u.get("faction", ""))),
			"glyph": str(t.get("glyph", "?")),
			"hostile": FactionDB.hostile(ws, str(u.get("faction", ""))),
		})
	return out

# 地点标记数据（画布逐帧调；量级＝个位数地点，无需缓存）：active＝据点可挑战/服务型恒真（灰显已肃清据点）
func locations_for_draw() -> Array:
	var out := []
	for loc in _map_locations:
		var type_id := str(loc.get("type", ""))
		out.append({
			"cell": Vector2i(int(loc.get("col", -1)), int(loc.get("row", -1))),
			"color": LocationDB.type_color(type_id),
			"label": str(loc.get("label", "")),
			"active": not LocationDB.is_site(type_id) or LocationDB.site_ready(loc, WorldState.current),
			"type": type_id,
			"icon": str(loc.get("icon", "")),
		})
	return out

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
	var jobs_b := Button.new()
	jobs_b.text = "🏕 职务"
	jobs_b.pressed.connect(_open_jobs_panel)
	top.add_child(jobs_b)
	var rep_b := Button.new()
	rep_b.text = "🚩 声望"
	rep_b.pressed.connect(_open_rep_panel)
	top.add_child(rep_b)
	var menu_b := Button.new()
	menu_b.text = "返回菜单"
	menu_b.pressed.connect(_on_back_to_menu)
	top.add_child(menu_b)

	canvas = OverworldCanvas.new()
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas.editor = self
	root.add_child(canvas)
	canvas.request_fit()
	# 夜晚变暗滤镜：盖画布（不吃输入）；构造/刷新单一实现在 EnvDB（战斗侧同用）
	_night_overlay = EnvDB.make_time_overlay()
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
		_time_label.text = "  🕐 %s　💰 %d" % [WorldClock.describe(ws.clock_hours), ws.gold]
	EnvDB.apply_time_tint(_night_overlay, WorldClock.time_of_day(ws.clock_hours))

func _log_line(text: String) -> void:
	if _log != null:
		_log.append_text(text + "\n")

# 自动存档统一入口：调试兜底档（_transient）不落盘；写失败红字提示（否则玩家以为一直在存、退出才发现丢档）
func _autosave() -> void:
	if _transient:
		return
	if not SaveIO.save_campaign(WorldState.current, _save_slot):
		_log_line("[color=#E07A5A]⚠ 自动存档失败（磁盘/占用/权限？）——本段进度未写入「%s」槽[/color]" % _save_slot)
		push_warning("Overworld：自动存档失败（槽=%s）" % _save_slot)

# ============ 营地职务（M6 框架：槽位+指派；加成载体待 §2.2——除医生〔恢复速率×2 占位〕外效果后续接）============

var _jobs_popup: PopupPanel

# 职务面板：每职务一行（名称 + 人选下拉）。指派即写档；一人一职（兼任自动撤原职）。
func _open_jobs_panel() -> void:
	if _jobs_popup != null:
		_jobs_popup.queue_free()
	_jobs_popup = PopupPanel.new()
	add_child(_jobs_popup)
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(360, 0)
	v.add_theme_constant_override("separation", 6)
	_jobs_popup.add_child(v)
	var title := Label.new()
	title.text = "营地职务（一人一职；重伤休整者视为不在岗）"
	v.add_child(title)
	var ws = WorldState.current
	for jdef in JobDB.all_jobs():
		var jid := str(jdef["id"])
		var row := HBoxContainer.new()
		var lbl := Label.new()
		lbl.text = str(jdef.get("label", jid)) + ("" if str(jdef.get("effect_status", "")) == "in_use" else " ⏳")
		lbl.tooltip_text = str(jdef.get("desc", ""))
		lbl.custom_minimum_size = Vector2(110, 0)
		row.add_child(lbl)
		var opt := OptionButton.new()
		opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		opt.add_item("— 空缺 —")
		opt.set_item_metadata(0, 0)
		var cur_uid := int(ws.camp_jobs.get(jid, 0))
		var idx := 1
		for u in ws.roster:
			var uname := str(u.unit_name)
			if int(u.injured_until) > ws.clock_hours:
				uname += "（重伤休整中）"
			opt.add_item(uname)
			opt.set_item_metadata(idx, u.uid)
			if int(u.uid) == cur_uid:
				opt.select(idx)
			idx += 1
		opt.item_selected.connect(func(i: int): _assign_job(jid, int(opt.get_item_metadata(i))))
		row.add_child(opt)
		v.add_child(row)
	var hint := Label.new()
	hint.text = "⏳＝效果待接入（加成数值待定）；医生已生效：全队恢复速率提升"
	hint.add_theme_color_override("font_color", Color(0.65, 0.68, 0.75))
	v.add_child(hint)
	_jobs_popup.popup_centered()

# 指派职务：一人一职（兼任自动从原职撤下）；写档。面板重建保证各行下拉同步。
func _assign_job(jid: String, uid: int) -> void:
	var ws = WorldState.current
	if uid > 0:
		for k in ws.camp_jobs.keys():
			if str(k) != jid and int(ws.camp_jobs[k]) == uid:
				ws.camp_jobs[k] = 0
	ws.camp_jobs[jid] = uid
	var holder = ws.roster_by_uid(uid) if uid > 0 else null
	_log_line("🏕 %s ← %s" % [JobDB.job_label(jid), (holder.unit_name if holder != null else "空缺")])
	_autosave()
	_open_jobs_panel()   # 重建面板（兼任撤职后其它行下拉同步）

# ============ 派系声望（M9）：数值存 ws.reputation、读写口在 FactionDB；敌对＝大地图遭伏 ============

var _rep_popup: PopupPanel

# 声望面板：每派系一行（名称·派系色 + 数值 + 敌对标记）。改动入口＝对话选项/事件动作，面板只读。
func _open_rep_panel() -> void:
	if _rep_popup != null:
		_rep_popup.queue_free()
	_rep_popup = PopupPanel.new()
	add_child(_rep_popup)
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(300, 0)
	v.add_theme_constant_override("separation", 6)
	_rep_popup.add_child(v)
	var title := Label.new()
	title.text = "派系声望（低于阈值＝敌对，大地图会遭袭击）"
	v.add_child(title)
	var ws = WorldState.current
	for f in FactionDB.all_factions():
		var fid := str(f["id"])
		var row := HBoxContainer.new()
		var name_l := Label.new()
		name_l.text = FactionDB.label(fid)
		name_l.add_theme_color_override("font_color", FactionDB.color(fid))
		name_l.custom_minimum_size = Vector2(110, 0)
		row.add_child(name_l)
		var val_l := Label.new()
		val_l.text = str(FactionDB.rep_of(ws, fid))
		val_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(val_l)
		if FactionDB.hostile(ws, fid):
			var host_l := Label.new()
			host_l.text = "⚔ 敌对"
			host_l.add_theme_color_override("font_color", Color(0.9, 0.45, 0.4))
			row.add_child(host_l)
		v.add_child(row)
	_rep_popup.popup_centered()

# 返回菜单：先自动存档（current 由 StartMenu._ready 统一清——「继续」从磁盘重读，保留只会泄漏进沙盒）
func _on_back_to_menu() -> void:
	_autosave()
	get_tree().change_scene_to_file("res://StartMenu.tscn")
