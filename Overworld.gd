extends Control
## 大地图场景（Overworld，M4）：战役层——队伍 token 在大地图上移动；**时钟可播放/暂停（空格总开关）🔒**：
## 播放即流动——沿路径伪即时行军（token 像素插值滑行，地块成本越高过格越慢）or 原地等待；抵达/模态事件自动暂停；
## 战斗仍不耗世界时间 🔒。（2026-07-08 修订旧规则「时间仅移动/扎营时流动」→ 注记见 meta层需求提炼_1.md §1.1）
## 复用底层：HexCanvas(经 OverworldCanvas)/MapIO/TerrainDB/HexGrid——与战斗地图同构（flat-top odd-q）。
## 事件：每落一格评估 EventEngine 的 enter_tile、每跨整点推 WorldClock+WorldSim（时间推进＝世界回合）+timer——
## 两路事件源并行：每图 triggers（地图 JSON）+ 全局事件池（EventDB，带地形限定 when.terrain）；📜 顶栏面板只读查看。
## 日夜：随时钟推导（WorldClock.time_of_day → 标签 + EnvDB tint 变暗叠层）；战斗侧日夜注入见 Sandbox._world_time。
## 宿主原语：event_log / event_start_battle / event_dialogue（大地图不支持战斗动作 spawn/aggro/set_weather——EventEngine 守卫警告跳过）。
## 存档：抵达目的地/扎营后自动写 AUTO_SLOT；「继续战役」从 StartMenu 读它。
## 可测性：寻路/耗时/事件评估不依赖 UI 节点（UI 刷新全走 null 守卫）——headless new() 直调 _tick_time(dh) 即可测时间步进。

const HexGrid := preload("res://HexGrid.gd")
const TerrainDB := preload("res://TerrainDB.gd")
const MapIO := preload("res://MapIO.gd")
const EnvDB := preload("res://EnvDB.gd")
const WorldState := preload("res://WorldState.gd")
const WorldClock := preload("res://WorldClock.gd")
const EventEngine := preload("res://EventEngine.gd")
const ItemDB := preload("res://ItemDB.gd")           # 背包：消耗品 tpl_id → 名/图标/on_use（give_item 授予、背包面板展示/使用）
const CampaignUI := preload("res://CampaignUI.gd")   # 战役面板 UI 工厂（弹窗脚手架/语义色/行样式，仿 EditorUI）
const EventDB := preload("res://EventDB.gd")         # 全局事件池（跨地图 when/do 事件，data/events.json）
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
const UnitStatusPanel := preload("res://UnitStatusPanel.gd")   # 👥 角色状态卡（与战斗侧同一份；宿主契约见 _open_status_panel）
const TextureCache := preload("res://TextureCache.gd")         # 队伍面板成员立绘缩略

const MAP_PATH := "res://maps/overworld/world.json"
const HOURS_PER_COST := 1    # 1 点通行成本 ＝ 1 小时（大世界成本＝terrains.json move.overworld_cost：道路 1h/格、平原 2h、山 6h）
# 大世界地块通行成本（明显档 🔒）＝数据层 terrains.json 各地形 move.overworld_cost（_move_cost_at 走 TerrainDB.move_cost(_,_,true)）；
# 道路(放置物)经 _move_cost_between 的 min(_,1)=1 恒最低；战斗地图不受影响。数值层后调。
const CAMP_HOURS := 8        # 占位：扎营一次休整 8 小时（临时据点/职务＝M6）
const DEFAULT_BATTLE_MAP := "res://maps/sandbox.json"   # 遭遇战/伏击/据点的兜底战斗图（单一源）
# 自动存档槽名单一源＝SaveIO.AUTO_SLOT（实例注入见 _save_slot）
const TIME_RATE := 2.5       # 时间流速（游戏小时/真实秒，占位可调）：cost-1 格（2h）≈0.8 真实秒
const MAX_FRAME_DELTA := 0.1 # 单帧 delta 钳制（秒）：卡帧不折成一大坨小时（_tick_time 内仍逐小时逐格结算兜底）
const WU_ANIM_SECONDS := 0.3 # 世界单位每步滑行时长（真实秒，占位）：略短于典型步间隔，滑完再走下一步
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
var _play_label: Label                  # ▶/⏸ 播放指示（顶栏极简）
var _ui_sig := ""                       # 上次渲染的时间 UI 签名（clock/gold/playing）——播放时逐帧调，变了才重建
var _log: RichTextLabel
var _night_overlay: ColorRect
var _time_playing := false              # 时间播放中（空格总开关）：播放即流动——行军 or 原地等待
var _route: Array = []                  # 行军剩余路径（Vector2i 待走格序列，[0]=当前段终点；空＝无目的地）
var _seg_progress := 0.0                # 当前段插值分数 [0,1)：token 平滑绘制 + 跨格判定
var _hour_acc := 0.0                    # 整点累加器（浮点游戏小时）：跨 1.0 才推 WorldClock——clock_hours 恒整数
var _wu_anim := {}                      # 世界单位滑行插值 {uid: {from:Vector2i, to:Vector2i, t:float}}——纯表现、不随档
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
	_log_line("抵达大地图。左键点目标格出发（自动播放时间）；空格＝播放/暂停。")
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

# 右键＝中止行军：清路径并暂停（就地停在当前格；段内进度作废，已推的时钟不回退）
func cancel_action() -> void:
	if _route.is_empty():
		return
	_clear_route()
	_pause_time()
	_log_line("↩ 行军中止。")
	if canvas != null:
		canvas.queue_redraw()

# 左键点格：寻路并出发（自动播放）。行军中再点＝从当前格重新寻路（伪即时：指令可随时改）。
func left_click_cell(col: int, row: int) -> void:
	if not _cell_in_bounds(col, row) or _dialogue != null or SandboxConfig.battle_setup != null:
		return   # 模态事件（对话/战斗待切场景）中不收移动指令
	var ws = WorldState.current
	var from := Vector2i(ws.party_col, ws.party_row)
	var to := Vector2i(col, row)
	if from == to:
		_clear_route()   # 点自己脚下＝就地停下
		if _loc_by_cell.has(to):
			_open_location_panel(_loc_by_cell[to])   # 原地点自己脚下的地点＝重新进入
		return
	var path := find_path(from, to)
	if path.size() < 2:
		_log_line("那里去不了（无可通行路径）。")
		return
	_set_route(path)
	_time_playing = true   # 点目的地＝自动播放
	_refresh_time_ui()
	if canvas != null:
		canvas.queue_redraw()

# ============ 寻路 / 行程（纯逻辑，可 headless 测）============

func _cell_in_bounds(col: int, row: int) -> bool:
	return col >= 0 and col < width and row >= 0 and row < height

# 队伍在该格的通行成本（-1=不可通行）：通行性 + 大世界成本(move.overworld_cost) 都走 TerrainDB.move_cost 单一实现，
# overworld=true 令其用地形的 overworld_cost（数据层 terrains.json）。战斗侧不传该参、用 cost。
func _move_cost_at(col: int, row: int) -> int:
	if not _cell_in_bounds(col, row):
		return -1
	return TerrainDB.move_cost(TerrainDB.effective_move(tiles[row][col], _map_terrain_overrides), PARTY_TAGS, true)

# 跨边通行成本（from→to 相邻格；-1=不可跨）——线特征语义的单一实现：
#   河边无桥＝硬阻断；有桥＝可跨且享道路折扣；道路边＝成本折为 min(目的格成本, 1)（穿林翻山的大道）。
# 寻路（find_path）与行军扣时（_tick_time 段时长）都读这里，保证「路径成本＝实际耗时」不脱节；WorldSim 游荡同用。
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

# ============ 伪即时时间（🔒 修订 2026-07-08：时钟可播放/暂停，播放即流动——行军 or 原地等待）============

# 每帧步进：播放中把真实秒折成游戏小时喂 _tick_time（步进逻辑全在那，headless 直调可测）。
# delta 钳 MAX_FRAME_DELTA：卡帧的大 delta 不折成一大坨小时（_tick_time 内仍逐小时逐格结算，双保险）。
func _process(delta: float) -> void:
	var anim_moving := _advance_wu_anim(delta)   # 世界单位滑行插值（与时钟播放无关；暂停时也把上一步滑完）
	if _time_playing:
		_tick_time(minf(delta, MAX_FRAME_DELTA) * TIME_RATE)
		_refresh_time_ui()
		if canvas != null:
			canvas.queue_redraw()
	elif anim_moving and canvas != null:
		canvas.queue_redraw()

# 推进世界单位滑行插值：每步 WU_ANIM_SECONDS 真实秒 from→to；返回是否有单位仍在滑（决定是否重绘）。
func _advance_wu_anim(delta: float) -> bool:
	var moving := false
	for uid in _wu_anim:
		var a: Dictionary = _wu_anim[uid]
		if float(a["t"]) < 1.0:
			a["t"] = minf(1.0, float(a["t"]) + delta / WU_ANIM_SECONDS)
			moving = true
	return moving

# 空格＝时间总开关（播放/暂停）；只吃空格、不吞其它键。顶栏按钮已设 FOCUS_NONE，空格不会误触聚焦按钮。
func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
		_toggle_time()
		get_viewport().set_input_as_handled()

func _toggle_time() -> void:
	if not _time_playing and (_dialogue != null or SandboxConfig.battle_setup != null):
		return   # 模态事件（对话/战斗待切场景）中不允许开表
	_time_playing = not _time_playing
	_refresh_time_ui()

func _pause_time() -> void:
	_time_playing = false
	_refresh_time_ui()

# 设定行军路径（path＝find_path 产物，含起点）：只存待走格；段进度清零。
func _set_route(path: Array) -> void:
	_route = path.slice(1)
	_move_target = path.back()
	_seg_progress = 0.0

func _clear_route() -> void:
	_route = []
	_seg_progress = 0.0
	_move_target = Vector2i(-1, -1)

# 时间步进核心（纯逻辑，headless 直调）：dh＝本次推进的游戏小时（浮点）。
# 逐边界消化：每轮至多吃到「下个整点 / 当前段走完」——大 dh 不跳步，事件/战斗逐小时逐格必查。
# 段时长＝跨边成本×HOURS_PER_COST（与寻路同源，成本越高走得越慢）；跨格＝落位＋评事件（同旧 _travel 序：
# 落位→推钟→评事件）；跨整点＝WorldClock.advance(1)＋世界回合＋timer（clock_hours 恒整数 🔒）。
# 自动暂停：模态事件（对话/战斗待切场景）→ 停给玩家读选；抵达目的地 → 停＋autosave＋地点面板。
func _tick_time(dh: float) -> void:
	var ws = WorldState.current
	if ws == null:
		return
	var remain := dh
	while _time_playing:
		# 当前段时长（游戏小时）；-1＝无路径（原地等待）。0 时长段（病态成本 0）瞬跨不耗时。
		var seg_hours := -1.0
		if not _route.is_empty():
			var to: Vector2i = _route[0]
			seg_hours = maxi(_move_cost_between(ws.party_col, ws.party_row, to.x, to.y), 0) * HOURS_PER_COST
		if remain <= 0.0 and seg_hours != 0.0:
			break   # dh 耗尽（0 时长段例外：还要落格）
		if seg_hours != 0.0:
			# 本轮步长：吃到下个整点为止；行军中再被「当前段剩余」截断
			var step := minf(remain, 1.0 - _hour_acc)
			if seg_hours > 0.0:
				step = minf(step, (1.0 - _seg_progress) * seg_hours)
			remain -= step
			_hour_acc += step
			if seg_hours > 0.0:
				_seg_progress += step / seg_hours
		# ① 跨格：先落位（事件评估放到推钟后）
		var landed := Vector2i(-1, -1)
		if seg_hours >= 0.0 and (seg_hours == 0.0 or _seg_progress >= 1.0 - 1e-6):
			landed = _route.pop_front()
			ws.party_col = landed.x
			ws.party_row = landed.y
			_seg_progress = 0.0
		# ② 跨整点：推钟＋世界回合＋timer（每整点一次；浮点累加器只驱动插值）
		if _hour_acc >= 1.0 - 1e-6:
			_hour_acc = maxf(_hour_acc - 1.0, 0.0)
			_advance_world(1)
		# ③ 落格事件（enter_tile 每图+全局池 + 遭伏 + timer）
		if landed.x >= 0:
			_check_cell_events(landed)
		# ④ 暂停判定：模态事件优先（战斗已在 _start_battle_with 落盘；对话读完按空格续行）；其次抵达
		if _dialogue != null or SandboxConfig.battle_setup != null:
			_pause_time()
		elif landed.x >= 0 and _route.is_empty():
			_arrive(landed)

# 抵达目的地：自动暂停＋落盘；地点＝自动进入（面板；途经不进——BB 式点到才停靠）
func _arrive(dest: Vector2i) -> void:
	_pause_time()
	_move_target = Vector2i(-1, -1)
	if canvas != null:
		canvas.queue_redraw()
	_autosave()
	if _loc_by_cell.has(dest):
		_open_location_panel(_loc_by_cell[dest])

# 测试助手：把整条路径一次跑完（headless 无真 _process——小步反复 _tick_time 直到自动暂停/抵达）
func simulate_travel_to_arrival(path: Array) -> void:
	_set_route(path)
	_time_playing = true
	for i in 100000:
		if not _time_playing:
			return
		_tick_time(0.5)
	push_error("simulate_travel_to_arrival：10 万步未抵达（路径/暂停逻辑有问题）")

# 时钟推进统一入口：推钟（恢复调度）→ 世界回合（动态单位随玩家活动移动 🔒）→ 事件表现。
# 战斗类事件（engage）由 _start_battle_with 收口；一次推进至多一场（WorldSim 保证）。
func _advance_world(hours: int) -> void:
	var ws = WorldState.current
	WorldClock.advance(ws, hours)
	var before := _wu_positions(ws)   # 世界回合前各单位位置（滑行插值 diff）
	for e in WorldSim.tick(ws, hours, self):
		match str(e.get("kind", "")):
			"engage_player":
				var u: Dictionary = e["unit"]
				var t = WorldUnitDB.type_def(str(u.get("type", "")))
				_log_line("⚔ [b]%s[/b] 追上了你们！" % WorldUnitDB.label(str(u.get("type", ""))))
				# 讨伐赏金（波2 收入闭环）：开战点解析、随 context 走、胜后 BattleIO.apply_result 单点入账
				_start_battle_with(str(t.get("battle_map", DEFAULT_BATTLE_MAP)) if t != null else DEFAULT_BATTLE_MAP,
					{"world_unit_uid": int(u.get("uid", 0)), "faction_id": str(u.get("faction", "")),
						"bounty": int(t.get("bounty", 0)) if t != null else 0})
			"skirmish":
				var hunter := WorldUnitDB.label(str((e["hunter"] as Dictionary).get("type", "")))
				var prey := WorldUnitDB.label(str((e["prey"] as Dictionary).get("type", "")))
				_log_line("🗡 %s%s了%s。" % [hunter, "击溃" if bool(e.get("prey_died", true)) else "反被击溃——输给", prey])
			"caravan_arrive":
				pass   # 商队到站：暂不播报（避免刷屏；交易接入后再表现）
	_sync_wu_anim(ws, before)   # 世界回合后：为移动过的单位起滑行插值
	_eval_all_timers()          # timer 随时钟推进统一评估——收口于此，各推钟入口不再各自补调

# 世界单位当前位置快照 {uid: Vector2i}（世界回合前后 diff，判定谁移动了）
func _wu_positions(ws) -> Dictionary:
	var out := {}
	for u in ws.world_units:
		out[int(u.get("uid", 0))] = Vector2i(int(u.get("col", 0)), int(u.get("row", 0)))
	return out

# 为世界回合中移动过的单位起滑行插值：相邻步=滑行(t:0)、传送/重生成=直接落位(t:1)、消失单位清表。
func _sync_wu_anim(ws, before: Dictionary) -> void:
	var live := {}
	for u in ws.world_units:
		var uid := int(u.get("uid", 0))
		live[uid] = true
		var cur := Vector2i(int(u.get("col", 0)), int(u.get("row", 0)))
		if not before.has(uid):
			_wu_anim[uid] = {"from": cur, "to": cur, "t": 1.0}
		elif before[uid] != cur:
			if HexGrid.distance(before[uid], cur) == 1:
				_wu_anim[uid] = {"from": before[uid], "to": cur, "t": 0.0}
			else:
				_wu_anim[uid] = {"from": cur, "to": cur, "t": 1.0}
	for uid in _wu_anim.keys():
		if not live.has(uid):
			_wu_anim.erase(uid)

# 一格落位后的事件评估：地图触发器 enter_tile + 全局事件池（带有效地形 id）+ 敌对派系遭伏（M9 伪触发器）。timer 不在此评（随推钟走 _advance_world）
func _check_cell_events(cell: Vector2i) -> void:
	var ws = WorldState.current
	EventEngine.check_enter_tile(_map_triggers, cell, "player", ws.event_fired, self, ws)
	EventEngine.check_enter_tile(EventDB.all_events(), cell, "player", ws.event_fired, self, ws, _terrain_id_at(cell.x, cell.y))
	EventEngine.check_enter_tile(_hostile_ambush_triggers(), cell, "player", ws.event_fired, self, ws)

# 该格有效地形 id（全局事件池 when.terrain 匹配用）：图级覆盖（_map_terrain_overrides）只换 move/effects 块、
# 不换地形身份（键＝terrain/variant，见 MapIO schema）——故 id 恒取地形表 entry.id，与 _move_cost_at 同源读 tiles。
func _terrain_id_at(col: int, row: int) -> String:
	if not _cell_in_bounds(col, row):
		return ""
	var e = TerrainDB.entry_for(tiles[row][col])
	return str(e.get("id", "")) if e != null else ""

# timer 事件统一评估口：每图触发器 + 全局事件池——由 _advance_world 收口调用（推钟＝唯一时间推进点），各入口不再各自补调
func _eval_all_timers() -> void:
	var ws = WorldState.current
	if ws == null:
		return
	EventEngine.check_timer(_map_triggers, ws, self)
	EventEngine.check_timer(EventDB.all_events(), ws, self)

# 敌对派系遭伏（M9）：把当前敌对的派系转成 enter_tile 伪触发器喂 EventEngine——
# 复用同一套 chance/冷却闸门（tid 稳定＝"faction_ambush_<id>"，冷却随档持久）；参数全在 factions.json。
func _hostile_ambush_triggers() -> Array:
	var out := []
	var ws = WorldState.current
	if ws == null or ws.overworld_combat_off:
		return out   # 遭遇战总开关（关）：无派系伏击
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
				{"action": "start_battle", "map": str(amb.get("battle_map", DEFAULT_BATTLE_MAP))}]})
	return out

# 扎营：原地休整推进时钟（维持离散 +8h；恢复结算走 WorldClock 调度表；临时据点/职务＝M6）
func _on_camp() -> void:
	if not _route.is_empty():
		return   # 行军中不可扎营（先右键中止/点脚下停车）
	_advance_world(CAMP_HOURS)
	_log_line("⛺ 扎营休整 %d 小时。" % CAMP_HOURS)
	_refresh_time_ui()
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

# 给予物品（do: give_item，M3 挂点）：入队伍背包（可堆叠 tpl_id→count）；事件「装水得道具」/烹饪食材获取共用。
func event_give_item(item_id: String, count: int) -> void:
	var ws = WorldState.current
	if ws == null:
		return
	ws.inv_add(item_id, maxi(1, count))
	var it = ItemDB.get_item(item_id)
	_log_line("🎒 获得 %s ×%d" % [str(it.get("name", item_id)) if it != null else item_id, maxi(1, count)])

# 给予/扣除金钱（do: give_gold；讨伐奖励同走此口）：余额钳 0、顶栏 💰 随 _ui_sig 自动刷新
func event_give_gold(amount: int) -> void:
	var ws = WorldState.current
	if ws == null or amount == 0:
		return
	ws.gold = maxi(0, int(ws.gold) + amount)
	_log_line(("💰 获得 %d 金币" % amount) if amount > 0 else "[color=#E07A5A]💰 失去 %d 金币[/color]" % -amount)

# 开对话（do: dialogue）：模态覆盖大地图；行军中触发＝_tick_time 自动暂停（读完按空格续行）（M8）
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
	if canvas != null:
		canvas.queue_redraw()
	_autosave()
	return true

# 讨伐据点：可挑战才开打（带 location_id 上下文——胜后 BattleIO 落肃清账、按类型 respawn_hours 刷新；
# 赏金按地点类型解析进 context，胜后 apply_result 单点入账）
func _challenge_site(loc: Dictionary) -> void:
	if not LocationDB.site_ready(loc, WorldState.current):
		_log_line("此处已被肃清，暂无敌踪。")
		return
	var tdef = LocationDB.type_def(str(loc.get("type", "")))
	_start_battle_with(str(loc.get("battle_map", DEFAULT_BATTLE_MAP)),
		{"location_id": str(loc.get("id", "")),
			"bounty": int(tdef.get("bounty", 0)) if tdef != null else 0})

# 地点面板：城市/村落＝服务列表（rest 已接入；planned 灰显 ⏳）+ 可选交谈；遗迹/据点＝状态 + 进攻。
func _open_location_panel(loc: Dictionary) -> void:
	if not is_inside_tree():
		return   # headless：面板纯 UI，逻辑走 _do_rest/_challenge_site 直测
	if _loc_popup != null:
		_loc_popup.queue_free()
	var ui = CampaignUI.popup(380)
	_loc_popup = ui["popup"]
	add_child(_loc_popup)
	var v: VBoxContainer = ui["box"]
	var type_id := str(loc.get("type", ""))
	var title := Label.new()
	title.text = "📍 %s（%s）" % [str(loc.get("label", "")), LocationDB.type_label(type_id)]
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", LocationDB.type_color(type_id))
	v.add_child(title)
	var desc := Label.new()
	desc.text = str(LocationDB.type_def(type_id).get("desc", ""))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_color_override("font_color", CampaignUI.MUTED)
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

# 队伍 token 绘制段（画布插值钩子）：{from,to,t}——行军中＝当前格→下一格按段进度插值；静止＝from==to、t=0。
func party_seg() -> Dictionary:
	var cell := party_cell()
	if _route.is_empty():
		return {"from": cell, "to": cell, "t": 0.0}
	return {"from": cell, "to": _route[0], "t": _seg_progress}

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
		var uid := int(u.get("uid", 0))
		var cur := Vector2i(int(u.get("col", 0)), int(u.get("row", 0)))
		var a = _wu_anim.get(uid)
		out.append({
			"from": (a["from"] if a != null else cur),
			"to": (a["to"] if a != null else cur),
			"t": (float(a["t"]) if a != null else 1.0),
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
	_play_label = Label.new()
	_play_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_play_label.tooltip_text = "空格＝播放/暂停时间"
	top.add_child(_play_label)
	_time_label = Label.new()
	_time_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_time_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top.add_child(_time_label)
	var party_b := Button.new()
	party_b.text = "👥 队伍"
	party_b.pressed.connect(_open_party_panel)
	top.add_child(party_b)
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
	var events_b := Button.new()
	events_b.text = "📜 事件"
	events_b.pressed.connect(_open_events_panel)
	top.add_child(events_b)
	var bag_b := Button.new()
	bag_b.text = "🎒 背包"
	bag_b.pressed.connect(_open_inventory_panel)
	top.add_child(bag_b)
	var menu_b := Button.new()
	menu_b.text = "返回菜单"
	menu_b.pressed.connect(_on_back_to_menu)
	top.add_child(menu_b)
	for b in top.get_children():
		if b is Button:
			b.focus_mode = Control.FOCUS_NONE   # 空格留给时间开关（聚焦按钮会吃空格误触发）

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
	var sig := "%d|%d|%d" % [ws.clock_hours, ws.gold, int(_time_playing)]
	if sig == _ui_sig:
		return   # 时钟/金钱/播放态未变：跳过 describe/tint 重算（播放时省逐帧开销）
	_ui_sig = sig
	if _play_label != null:
		_play_label.text = "  ▶" if _time_playing else "  ⏸"
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
	var ui = CampaignUI.popup(360)
	_jobs_popup = ui["popup"]
	add_child(_jobs_popup)
	var v: VBoxContainer = ui["box"]
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
	hint.add_theme_color_override("font_color", CampaignUI.MUTED)
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
	var ui = CampaignUI.popup(300)
	_rep_popup = ui["popup"]
	add_child(_rep_popup)
	var v: VBoxContainer = ui["box"]
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
			host_l.add_theme_color_override("font_color", CampaignUI.HOSTILE)
			row.add_child(host_l)
		v.add_child(row)
	_rep_popup.popup_centered()

# ============ 📜 全局事件池（EventDB）面板：判定/文案全消费 EventEngine ④ schema 描述层（单一源，本场景不复述）============

var _events_popup: PopupPanel

# 📜 事件面板（仿 _open_rep_panel，纯只读）：上段＝当前可用（硬闸全开，条件满足即触发）；下段＝完整池+活状态徽章。
func _open_events_panel() -> void:
	if not is_inside_tree():
		return   # headless：面板纯 UI，判定/文案走 EventEngine.event_status/when_text 直测
	if _events_popup != null:
		_events_popup.queue_free()
	var ui = CampaignUI.popup(480)
	_events_popup = ui["popup"]
	add_child(_events_popup)
	var v: VBoxContainer = ui["box"]
	var ws = WorldState.current
	var pool := EventDB.all_events()
	var title := Label.new()
	title.text = "📜 全局事件池（移动/扎营/休整时自动评估；勾选=启用）"
	v.add_child(title)
	if ws != null:
		var combat_b := Button.new()
		combat_b.focus_mode = Control.FOCUS_NONE
		combat_b.text = "⚔ 大地图遭遇战：%s" % ("已关闭（安全模式）" if ws.overworld_combat_off else "开启")
		combat_b.tooltip_text = "关闭＝无派系伏击、世界单位不主动追上开战（世界单位之间的摩擦战仍照常）"
		combat_b.pressed.connect(func():
			ws.overworld_combat_off = not ws.overworld_combat_off
			_log_line("⚔ 大地图遭遇战已%s。" % ("关闭（安全模式）" if ws.overworld_combat_off else "开启"))
			_autosave()
			_open_events_panel())
		v.add_child(combat_b)
	var sec1 := Label.new()
	sec1.text = "—— 当前可用（条件满足即触发）——"
	sec1.add_theme_color_override("font_color", Color(0.55, 0.75, 0.55))
	v.add_child(sec1)
	var any_ready := false
	for ev in pool:
		if typeof(ev) == TYPE_DICTIONARY and bool(EventEngine.event_status(ev, ws).get("ready", false)):
			_add_event_row(v, ev, "")
			any_ready = true
	if not any_ready:
		var none := Label.new()
		none.text = "（无——都在冷却/已触发/未到节拍）"
		none.add_theme_color_override("font_color", CampaignUI.MUTED)
		v.add_child(none)
	var sec2 := Label.new()
	sec2.text = "—— 完整事件池（共 %d 条）——" % pool.size()
	sec2.add_theme_color_override("font_color", CampaignUI.MUTED)
	v.add_child(sec2)
	for ev in pool:
		if typeof(ev) == TYPE_DICTIONARY:
			_add_event_row(v, ev, str(EventEngine.event_status(ev, ws).get("text", "")), true)
	_events_popup.popup_centered()

# 事件一行：名称（悬停出 desc）+ 条件/概率/CD 灰字；badge 非空＝完整池段（可用绿、其余暖灰）
func _add_event_row(v: VBoxContainer, ev: Dictionary, badge: String, allow_toggle := false) -> void:
	var when: Dictionary = ev.get("when", {}) if typeof(ev.get("when")) == TYPE_DICTIONARY else {}
	var ws = WorldState.current
	var tid := str(ev.get("id", ""))
	var row := HBoxContainer.new()
	# 启用勾选（仅完整池段）：取消＝禁用此事件（写 ws.event_disabled，引擎硬闸跳过，随档保存）
	if allow_toggle and ws != null and tid != "":
		var chk := CheckBox.new()
		chk.focus_mode = Control.FOCUS_NONE
		chk.button_pressed = not ws.event_disabled.has(tid)   # 先设值再连信号：程序化置位不触发 toggled
		chk.tooltip_text = "取消勾选＝禁用此事件（随档保存）"
		chk.toggled.connect(func(on: bool):
			if on:
				ws.event_disabled.erase(tid)
			else:
				ws.event_disabled[tid] = true
			_autosave()
			_open_events_panel())
		row.add_child(chk)
	var name_l := Label.new()
	name_l.text = str(ev.get("label", ev.get("id", "?")))
	name_l.tooltip_text = str(ev.get("desc", ""))
	name_l.custom_minimum_size = Vector2(120, 0)
	row.add_child(name_l)
	var cond_l := Label.new()
	cond_l.text = "%s｜%s" % [EventEngine.when_text(when), EventEngine.gate_text(when)]
	cond_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cond_l.add_theme_color_override("font_color", CampaignUI.MUTED)
	row.add_child(cond_l)
	if badge != "":
		var b_l := Label.new()
		b_l.text = badge
		var bc := CampaignUI.WARN
		if badge == "可用":
			bc = CampaignUI.READY
		elif badge == "已禁用":
			bc = CampaignUI.DANGER
		b_l.add_theme_color_override("font_color", bc)
		row.add_child(b_l)
	v.add_child(row)

# ============ 🎒 队伍背包（WorldState.inventory：可堆叠消耗品/素材）：查看 + 战外使用（回血类，施于花名册成员）============
# 战斗内使用（回合动作 / 目标选取 / 敌对投掷 / AOE）＝后续切片，需战斗 UI 设计；本面板只做战外回血。

var _bag_popup: PopupPanel

# 背包面板：每条＝名×数量 + 效果摘要；战外可用回血消耗品给「使用」按钮。
func _open_inventory_panel() -> void:
	if not is_inside_tree():
		return
	if _bag_popup != null:
		_bag_popup.queue_free()
	var ui = CampaignUI.popup(440)
	_bag_popup = ui["popup"]
	add_child(_bag_popup)
	var v: VBoxContainer = ui["box"]
	var ws = WorldState.current
	var title := Label.new()
	title.text = "🎒 队伍背包"
	v.add_child(title)
	if ws == null or ws.inventory.is_empty():
		var none := Label.new()
		none.text = "（空——事件/烹饪/交易获得的消耗品会进这里）"
		none.add_theme_color_override("font_color", CampaignUI.MUTED)
		v.add_child(none)
	else:
		for tpl_id in ws.inventory:
			_add_inventory_row(v, str(tpl_id), ws.inv_count(str(tpl_id)))
	_bag_popup.popup_centered()

# 背包一行：名×数量 + 效果摘要（灰）；战外可用回血消耗品出「使用」按钮。
func _add_inventory_row(v: VBoxContainer, tpl_id: String, count: int) -> void:
	var it = ItemDB.get_item(tpl_id)
	var row := HBoxContainer.new()
	var name_l := Label.new()
	name_l.text = "%s ×%d" % [(str(it.get("name", tpl_id)) if it != null else tpl_id), count]
	name_l.custom_minimum_size = Vector2(160, 0)
	row.add_child(name_l)
	var eff_l := Label.new()
	eff_l.text = _consumable_effect_text(it)
	eff_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	eff_l.add_theme_color_override("font_color", CampaignUI.MUTED)
	row.add_child(eff_l)
	if it != null and _usable_out_of_battle(it):
		var use_b := Button.new()
		use_b.text = "使用"
		use_b.focus_mode = Control.FOCUS_NONE
		use_b.pressed.connect(func(): _open_use_target_picker(tpl_id))
		row.add_child(use_b)
	v.add_child(row)

# 战外可用＝usable ∧ 非敌对目标 ∧ on_use 含回血（回疲劳待系统、敌对投掷=战斗内，均不在战外用）
func _usable_out_of_battle(it: Dictionary) -> bool:
	if not (it.get("tags", []) as Array).has("usable"):
		return false
	if str(it.get("target", "ally")) == "enemy":
		return false
	var ou = it.get("on_use", {})
	return typeof(ou) == TYPE_DICTIONARY and (ou.has("heal_flat") or ou.has("heal_pct_max_hp"))

# 消耗品效果摘要（回疲劳标注未实装）
func _consumable_effect_text(it) -> String:
	if it == null:
		return ""
	var ou = it.get("on_use", {})
	if typeof(ou) != TYPE_DICTIONARY or ou.is_empty():
		return "（无使用效果）" if (it.get("tags", []) as Array).has("usable") else ""
	var parts := []
	if ou.has("heal_flat"):
		parts.append("回血 %d" % int(ou["heal_flat"]))
	if ou.has("heal_pct_max_hp"):
		parts.append("回血 %d%% 上限" % int(ou["heal_pct_max_hp"]))
	if ou.has("restore_fatigue_pct"):
		parts.append("回疲劳 %d%%（待疲劳系统）" % int(ou["restore_fatigue_pct"]))
	return "｜".join(parts)

# 使用目标选择：列花名册（名 + HP/HP_max）→ 选中即施用；阵亡不可选（战外无复活）。
func _open_use_target_picker(tpl_id: String) -> void:
	var ws = WorldState.current
	if ws == null or ws.inv_count(tpl_id) <= 0:
		return
	var ui = CampaignUI.popup(280, 4)
	var pick: PopupPanel = ui["popup"]
	add_child(pick)
	pick.popup_hide.connect(func(): pick.queue_free())
	var v: VBoxContainer = ui["box"]
	var it = ItemDB.get_item(tpl_id)
	var head := Label.new()
	head.text = "对谁使用「%s」？" % (str(it.get("name", tpl_id)) if it != null else tpl_id)
	v.add_child(head)
	for u in ws.roster:
		var hp := int(u.stats.get("HP", 0))
		var hpmax := int(u.effective_stat("HP_max"))
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text = "%s　%d/%d" % [str(u.unit_name), hp, hpmax]
		b.disabled = hp <= 0
		var target_u = u
		b.pressed.connect(func():
			pick.hide()
			_use_consumable_on(tpl_id, target_u))
		v.add_child(b)
	pick.popup_centered()

# 战外施用回血消耗品：扣一件 → 应用 on_use 回血（回疲劳待系统，暂跳过）→ 重建背包面板。
func _use_consumable_on(tpl_id: String, unit) -> void:
	var ws = WorldState.current
	if ws == null or unit == null or not ws.inv_remove(tpl_id, 1):
		return
	var it = ItemDB.get_item(tpl_id)
	var ou = (it.get("on_use", {}) if it != null else {})
	var hpmax := int(unit.effective_stat("HP_max"))
	var cur := int(unit.stats.get("HP", 0))
	var heal := 0
	if typeof(ou) == TYPE_DICTIONARY:
		heal += int(ou.get("heal_flat", 0))
		heal += int(round(hpmax * float(ou.get("heal_pct_max_hp", 0)) / 100.0))
	var newhp := mini(hpmax, cur + heal)
	unit.stats["HP"] = newhp
	_log_line("🎒 %s 使用 %s：+%d 生命（%d/%d）" % [str(unit.unit_name), (str(it.get("name", tpl_id)) if it != null else tpl_id), newhp - cur, newhp, hpmax])
	_autosave()
	_open_inventory_panel()

# ============ 👥 队伍（波2 垂直切片首环：大地图看得见自己的人）============

var _party_popup: PopupPanel
var _status_panel        # UnitStatusPanel 实例（懒建；非模态浮卡，ESC 关）

# 队伍面板：花名册逐人一行（立绘缩略 + 名/等级 + HP + 重伤徽章），点行 → 角色状态卡。
func _open_party_panel() -> void:
	var ws = WorldState.current
	if ws == null:
		return
	if _party_popup != null and is_instance_valid(_party_popup):
		_party_popup.queue_free()
	var ui = CampaignUI.popup(400)
	_party_popup = ui["popup"]
	add_child(_party_popup)
	var v: VBoxContainer = ui["box"]
	var title := Label.new()
	title.text = "👥 队伍（%d 人）——点成员看角色状态页" % ws.roster.size()
	v.add_child(title)
	if ws.roster.is_empty():
		var none := Label.new()
		none.text = "（花名册为空）"
		none.add_theme_color_override("font_color", CampaignUI.MUTED)
		v.add_child(none)
	for u in ws.roster:
		v.add_child(_party_row(u))
	_party_popup.popup_centered()

func _party_row(u) -> Control:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 52)
	b.focus_mode = Control.FOCUS_NONE
	b.clip_contents = true
	var member = u
	b.pressed.connect(func():
		if _party_popup != null and is_instance_valid(_party_popup):
			_party_popup.hide()
		_open_status_panel(member))
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 6)
	margin.add_theme_constant_override("margin_right", 6)
	b.add_child(margin)
	var hb := HBoxContainer.new()
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_theme_constant_override("separation", 10)
	margin.add_child(hb)
	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(40, 46)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tex = TextureCache.get_tex(str(u.portrait))
	if tex == null:
		tex = TextureCache.get_tex(str(u.icon))
	if tex != null:
		icon.texture = tex
	else:
		icon.modulate = Color(1, 1, 1, 0.2)
	hb.add_child(icon)
	var name_l := Label.new()
	name_l.text = "%s　Lv%d" % [str(u.unit_name), int(u.level)]
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(name_l)
	var ws = WorldState.current
	if ws != null and int(u.injured_until) > ws.clock_hours:
		var inj := Label.new()
		inj.text = "🤕 重伤休整"
		inj.add_theme_color_override("font_color", CampaignUI.WARN)
		inj.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hb.add_child(inj)
	var hp := int(u.stats.get("HP", 0))
	var hpmax := int(u.effective_stat("HP_max"))
	var hp_l := Label.new()
	hp_l.text = "❤ %d/%d" % [hp, hpmax]
	hp_l.add_theme_color_override("font_color",
		CampaignUI.DANGER if hp * 2 < hpmax else Color(0.72, 0.82, 0.72))
	hp_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(hp_l)
	return b

# 打开角色状态卡（战斗侧同一份 UnitStatusPanel，非模态浮卡/ESC 关/<> 翻页）。
# 宿主契约（面板 host 只要这两口）：board_units()＝翻页集合（大地图＝花名册）；set_viewed_unit＝棋子高亮（大地图无＝空转）。
func _open_status_panel(u) -> void:
	if _status_panel == null or not is_instance_valid(_status_panel):
		_status_panel = UnitStatusPanel.new()
		_status_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
		_status_panel.host = self
		_status_panel.equip_interact = true   # 大地图穿卸免费（不设费用闸；战斗 1 AP 闸只在沙盒宿主）
		add_child(_status_panel)
	_status_panel.open(u)

func board_units() -> Array:
	var ws = WorldState.current
	return ws.roster if ws != null else []

func set_viewed_unit(_u) -> void:
	pass   # 大地图无棋子查看高亮（面板 close/open 回调口）


# 返回菜单：先自动存档（current 由 StartMenu._ready 统一清——「继续」从磁盘重读，保留只会泄漏进沙盒）
func _on_back_to_menu() -> void:
	_autosave()
	get_tree().change_scene_to_file("res://StartMenu.tscn")
