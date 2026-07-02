extends Control
## 单位 sandbox：15×15 全草原地图 + 一个基础单位，用来逐步挂属性、看表现。
## 复用 terrains.json（与编辑器同一地形数据源）与 HexCanvas（经 SandboxCanvas 叠加单位）。
## 充当 HexCanvas 需要的“editor”宿主：提供 width/height/tiles + 地形查表 + hover_text。

const Unit := preload("res://Unit.gd")
const UnitFactory := preload("res://UnitFactory.gd")   # 造单位/序列化单一入口（与编辑器共用）
const CombatResolver := preload("res://CombatResolver.gd")   # 伤害分量化 + 减伤链（纯数学）
const HexGrid := preload("res://HexGrid.gd")               # 纯六边形几何前置（cube 互转/距离/邻居/连线/环）
const SkillDB := preload("res://SkillDB.gd")
const ItemInstances := preload("res://ItemInstances.gd")    # 物品实例门面（悬停单位卡经合成视图取武器）
const TextureCache := preload("res://TextureCache.gd")      # 立绘/图标加载 + 缓存单一入口

# element → 抗性中文标签（战斗记录用）
const ELEM_RES_CN := {"physical": "物抗", "fire": "火抗", "ice": "冰抗", "thunder": "雷抗", "holy": "神圣抗"}
const TerrainDB := preload("res://TerrainDB.gd")
const EnvDB := preload("res://EnvDB.gd")   # 环境注册表（天气/日夜 → sight 修正）
const TagDB := preload("res://TagDB.gd")   # tag 中文/颜色单一源
const WeatherVFX := preload("res://WeatherVFX.gd")   # 天气视觉叠层（屏幕空间氛围）
const SandboxCanvas := preload("res://SandboxCanvas.gd")
const UnitStatusPanel := preload("res://UnitStatusPanel.gd")
const TurnOrderBar := preload("res://TurnOrderBar.gd")
const DeployPanel := preload("res://DeployPanel.gd")
const RosterBar := preload("res://RosterBar.gd")
const SandboxConfig := preload("res://SandboxConfig.gd")
const MapIO := preload("res://MapIO.gd")   # 地图读 / 写单一入口（与 MapEditor 共用）
# 战斗地图：默认与地图编辑器共享同一张图（编辑器改 → 这里读到）。
# 实际打开哪张：优先 SandboxConfig.map_path（选地图界面传入），空则用此默认；缺失/损坏回退全草原。
const MAP_PATH := "res://maps/sandbox.json"
const DEFAULT_TERRAIN := "plain"
const DEFAULT_VARIANT := "grassland"
const AI_THINK_DELAY := 0.5            # 敌方 AI 回合开始的思考停顿
const AI_ACT_GAP := 1.0                # 每个动作之间的停顿（移动→停 1 秒→攻击），便于观看
# 语义色（判定/胜负）：成功绿 / 失败红——胜负横幅、col_html、_oc 共用，避免同一对色多处字面量
const OK_GREEN := "#6FCF6F"
const BAD_RED := "#E07A5A"

var width := 15
var height := 15
var tiles := []            # tiles[row][col] = {"terrain":..,"variant":..}；sandbox 全草原
var PALETTE := []
var units := []            # Unit 列表
# 仇恨触发区域（mode②）：{region_id: {Vector2i:true}}。关卡设计者在地图编辑器「区域层」绘制。
# 由 _load_map 从地图 regions 字段读入 _map_regions，_setup_regions 转成 aggro_regions。
var aggro_regions := {}
var _map_regions := []     # 地图文件 regions 原始数据：[{id,label,color,cells:[[x,y]…],kind?}]（schema v2，可空）
var _map_units := []       # 地图文件 units 原始数据：[{proto,col,row,faction}]（schema v3，可空）→ _spawn_map_units 落子
var _map_triggers := []    # 地图文件 triggers 原始数据：[{id,label,when,do}]（schema v3，可空）→ 运行时评估
var _map_terrain_overrides := {}   # 图级地形覆盖 { "terrain/variant": {move?,effects?} }：只改本图、不动全局 terrains.json
var _all_region_cells := {}   # 所有区域的格集合 {region_id: {Vector2i:true}}（不分 kind，供触发器引用）
var _fired_triggers := {}  # 已触发过的 trigger id（when.once 用）；每场战斗开始清空
var _deploy_cells := {}    # 部署区格集合 {Vector2i:true}：kind=="deploy" 的区域并集（玩家单位只能放这里）

# —— 感知 / 战争迷雾（玩家侧；见 docs/感知系统.md 🔒）——
# 三态＝黑(未探索)/灰(探索过·当前无观测)/常态(当前视野内)。数据模型：seen 决定黑vs非黑、visible 决定灰vs常态。
var _vis_visible := {}    # 当前可见格 {Vector2i:true}＝我方/友方全体单位视野格并集（每次移动/开战重算）
var _vis_seen := {}       # 曾看到过的格 {Vector2i:true}（只增不减）
var omniscient := false   # 调试全知：默认 false＝迷雾生效（真实体验 🔒）；按 V 切换

# —— 环境：日夜(静态) + 天气(动态)（Phase 2；见 docs/感知系统.md 🔒。近期只影响 sight）——
var _map_environment := {}   # 地图 environment 字段 {time, weather_table:[{weather,weight,min_rounds,max_rounds}]}
var _cur_time := "day"       # 当前日夜 id（战中不变）
var _cur_weather := "clear"  # 当前天气 id
var _weather_left := 0       # 当前天气剩余回合（<=0 ＝ 不自动变：表空 / 强制常驻）
var _time_sight_mult := 1.0  # 日夜的视野【最终乘子】：在所有加减之后再乘（夜=0.5 减半）；见 _effective_sight
var _weather_vfx             # 天气视觉叠层（WeatherVFX，挂在 canvas 下；随 _cur_weather 播放）
var _night_overlay: ColorRect  # 夜晚整体变暗滤镜（挂 canvas 下、在天气 VFX 之下）

# —— 简陋回合框架（round/turn 双层，出手按速度；详见 docs/单位系统设计.md）——
var round_num := 1
var turn_order := []       # 本 round 的出手序列（速度大→小；同速玩家优先）
var active_index := 0      # 当前行动单位在 turn_order 的下标
# ZOC 借机去重：本 round 内「拥有者→移动者」已触发过的集合（key=owner_id_mover_id），每 round 清空。
var zoc_triggered := {}

# —— 选中 / 移动指令状态 ——
var selected_unit = null   # 左键选中的单位（用于唤出选单 / 移动）
var move_mode := false     # 选了「移动」后进入移动指令模式：显示范围 + 路径线
var attack_mode := false   # 选了「攻击」后进入攻击模式：角色周围攻击范围、点敌即打
var skill_mode := false    # 选了某主动技能后：显示目标范围（绿）、点范围内合法目标释放
var active_skill_id := ""  # 当前待释放的技能 id（skill_mode 期间有效）
var skill_cells := {}      # 技能目标范围 {Vector2i: true}（含可自选的己格）
var reachable := {}        # 移动模式下可达格：{Vector2i(col,row): 累计移动消耗}
var attack_cells := {}     # 攻击格 {Vector2i: true}：移动模式=极限可攻击预览；攻击模式=角色周围实际可攻击
var _came_from := {}       # Dijkstra 前驱：{格: 上一格}，用于即时重建鼠标路径
var hover_path := []       # 当前鼠标悬停格的移动路径（Vector2i 序列，含起点）

# —— 范围显示（移动/攻击范围层）——
var range_overlays := []        # 画布要画的范围层：[{reach,attack,move_color,atk_color}]
var show_enemy_preview := false # 移动模式按 Tab：是否同时显示最近敌方的移动/攻击范围
var hover_range_unit = null     # 鼠标悬停在地图棋子上的单位（显示其移动/攻击范围；敌我皆可）
const RANGE_MOVE_FRIENDLY := Color(0.45, 0.70, 1.0, 0.32)  # 我方移动范围：浅蓝
const RANGE_MOVE_ENEMY := Color(1.0, 0.92, 0.35, 0.28)     # 敌方移动范围：浅黄
const RANGE_ATTACK := Color(0.95, 0.32, 0.30, 0.36)        # 攻击范围：浅红
const RANGE_SKILL := Color(0.30, 0.85, 0.42, 0.34)         # 技能（治疗）范围：浅绿

# —— 移动动画（沿路径平移，非瞬移）——
var _animating := false
var _anim_unit = null      # 正在播放滑动动画的单位（移动滑行 / 攻击撞击共用）
var _anim_pos := Vector2.ZERO  # 该单位当前的绘制世界坐标（动画期间覆盖 hex_center）
const MOVE_ANIM_STEP := 0.09   # 每格滑动秒数

# —— 起飞 / 降落过渡（纯 cosmetic，不占用 _animating 串行通道）——
var _fly_anim := {}        # 单位 → 悬空因子 0..1（仅起降动画进行中存在）
var _fly_tweens := {}      # 单位 → 当前起降 Tween（再次切换时先 kill 旧的）
const FLY_ANIM_TIME := 0.28   # 起飞/降落过渡时长

# —— 攻击动画 / 音效 ——
const ATTACK_SFX := "res://audio/attack.mp3"
const FLASH_TIME := 0.2    # 受击闪红时长
var _flash_units := {}     # 正在闪红的受击单位集合
var _sfx: AudioStreamPlayer  # 攻击音效播放器

var canvas
var _turn_panel: VBoxContainer   # 紧凑回合状态
var _log: RichTextLabel          # 战斗记录（BBCode）
var _context_menu: PopupMenu
var _skill_submenu: PopupMenu          # 「技能」子菜单（列已学主动技能）
var _skill_menu_map := {}              # 子菜单项 id -> skill_id
var _status_panel
var _turn_bar                    # 顶部行动顺序槽（TurnOrderBar）
var viewed_unit = null   # 角色状态页当前查看的单位（用于棋子圆圈高亮）
var hover_unit = null    # 鼠标扫过行动顺序槽头像时，要在地图上高亮所在格的单位

# —— 遭遇战结束（胜负）——
var battle_over := false
var _banner: Label        # 胜利 / 失败 横幅（含「按 R 重开」）

# —— 阶段：deploy=布置（调试侧栏摆单位、回合不跑）/ battle=战斗（回合+AI 正常）——
var phase := "deploy"
var _deploy_panel         # DeployPanel（右侧：选中单位编辑器 + 保存预设 + 开始游戏）
var _roster_bar           # RosterBar（底部横向栏：可用单位管理 + ＋ 添加）
var _battle_ui: VBoxContainer   # 战斗期才显示的右栏（回合状态 + 战斗记录）

# 可用单位 roster（底部栏全部已准备单位）。其中「已布置」的也在 units 里（= 上场参战的子集）。
# roster 单位的配置（四维/装备/技能…）可存成「单位预设」，与场上位置无关。
# 原型/预设的读写与「proto ↔ Unit」往返统一在 UnitFactory（含路径常量）。
var roster := []

# 六边形邻居偏移表已迁 HexGrid（odd-q，single source）；本文件几何一律走 HexGrid.*。
# stat 键→中文 统一走 StatMeta.label（单一数据源、全量键），不再在此维护副本（已删除未使用的 STAT_LABELS）。

func _ready() -> void:
	randomize()   # 战斗判定掷骰
	_load_terrains()
	_load_map()   # 读「选地图」传入或默认的战斗地图（缺失则回退全草原）
	_setup_regions()
	_build_ui()
	_spawn_map_units()   # 落地图预置单位（关卡设计的敌 / 中立 / 固定单位）；旧图无 units = 空
	_enter_deploy()   # 停在布置阶段：侧栏摆单位、回合不跑；点「开始游戏」才 _start_battle

# 仇恨触发区域（mode②）：从地图 regions 字段（_map_regions）构建 {region_id: {Vector2i:true}}。
# 敌人挂 ai_region 引用某区域 id，玩家踏入即激活（消费见 _ai_update_aggro）。旧图无 regions = 空。
func _setup_regions() -> void:
	aggro_regions = {}
	_deploy_cells = {}
	_all_region_cells = {}
	for reg in _map_regions:
		if typeof(reg) != TYPE_DICTIONARY:
			continue
		var id := str(reg.get("id", ""))
		var kind := str(reg.get("kind", "aggro"))   # 缺省＝仇恨触发区（向后兼容）
		var cells := {}
		for c in reg.get("cells", []):
			# cells 项形如 [x, y]
			if typeof(c) == TYPE_ARRAY and c.size() >= 2 and _cell_in_bounds(int(c[0]), int(c[1])):
				cells[Vector2i(int(c[0]), int(c[1]))] = true
		if id != "":
			_all_region_cells[id] = cells   # 全区域格集合（不分 kind，供触发器 when.region 引用）
		if kind == "deploy":
			# 部署区（玩家布置区）：并入 _deploy_cells（faction 暂统一按玩家）
			for cell in cells:
				_deploy_cells[cell] = true
		elif id != "":
			aggro_regions[id] = cells   # 仇恨/触发区按 id 存（敌人 ai_region 引用）

# —— 地形：经 TerrainDB 复用 terrains.json（与编辑器同一数据源、O(1) 查表）——
func _load_terrains() -> void:
	PALETTE = TerrainDB.palette()

# 读编辑器存的战斗地图（MAP_PATH）；缺失/损坏则回退到全草原，保证沙盒永远能跑
func _load_map() -> void:
	_map_regions = []   # 默认无区域（旧 v1 图 / 加载失败）
	_map_units = []     # 默认无预置单位（旧图 / 加载失败）
	_map_triggers = []  # 默认无触发器
	_map_terrain_overrides = {}   # 默认无图级地形覆盖
	_map_environment = {}   # 默认无环境设定（＝昼·晴）
	# 优先用「选地图」界面传入的路径（SandboxConfig.map_path）；空则用默认战斗图
	var path: String = SandboxConfig.map_path if SandboxConfig.map_path != "" else MAP_PATH
	var res := MapIO.read_file(path)   # 统一读 / 钳制（与 MapEditor 共用 MapIO）
	if res.get("ok", false):
		width = int(res["width"])
		height = int(res["height"])
		tiles = res["tiles"]
		_map_regions = res["regions"]   # schema v2：命名区域（向后兼容，旧图无此键=空）
		_map_units = res["units"]       # schema v3：预置单位（向后兼容，旧图无此键=空）
		_map_triggers = res["triggers"] # schema v3：触发器（向后兼容，旧图无此键=空）
		_map_terrain_overrides = res.get("terrain_overrides", {})   # 图级地形覆盖（向后兼容，旧图无此键=空）
		_map_environment = res.get("environment", {})   # 环境（日夜/天气；向后兼容，旧图无此键=空）
		return
	if FileAccess.file_exists(path):
		push_warning("战斗地图 %s 格式无效，回退全草原" % path)
	_new_grassland(width, height)

func _new_grassland(w: int, h: int) -> void:
	width = w
	height = h
	tiles = []
	for row in height:
		var line := []
		for col in width:
			line.append({"terrain": DEFAULT_TERRAIN, "variant": DEFAULT_VARIANT})
		tiles.append(line)

# 从内存地图字典装载战场（编辑器「一键试玩」用，免存盘）。dict = MapEditor.to_json_dict() 形。
# 重置到布置阶段：保留 roster（玩家自带军，收回待命），按新地图重新落预置单位。
func load_from_memory(map_dict: Dictionary) -> void:
	var res := MapIO.normalize(map_dict)
	if not res.get("ok", false):
		push_warning("试玩装载失败：地图数据无效")
		return
	battle_over = false
	width = int(res["width"])
	height = int(res["height"])
	tiles = res["tiles"]
	_map_regions = res["regions"]
	_map_units = res["units"]
	_map_triggers = res["triggers"]
	_map_terrain_overrides = res.get("terrain_overrides", {})
	_map_environment = res.get("environment", {})
	_setup_regions()
	# 场上清空、roster 收回待命（保留玩家自带军，跨试玩不丢）
	units = []
	for u in roster:
		u.col = -1
		u.row = -1
		_clear_effects_and_buffs(u)
		u.init_vitals()
	_spawn_map_units()   # 按新地图落预置单位（关卡的敌 / 我）
	turn_order = []
	active_index = 0
	round_num = 1
	if canvas != null:
		canvas.request_fit()
		canvas.queue_redraw()
	_enter_deploy()

# 落子地图预置单位（_map_units → units）：关卡设计者在编辑器/部署里摆好、存进地图的敌 / 中立 / 固定单位。
# 每条 = {proto, col, row, faction}；直接进 units（不过部署区限制——这是关卡数据，非玩家临时布置）。
# 出生点越界则钳进界内。make_unit 已收尾 recompute_derived + init_vitals。
func _spawn_map_units() -> void:
	for entry in _map_units:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var proto = entry.get("proto", {})
		if typeof(proto) != TYPE_DICTIONARY or proto.is_empty():
			continue
		var fac := str(entry.get("faction", proto.get("default_faction", "enemy")))
		var col := clampi(int(entry.get("col", 0)), 0, maxi(0, width - 1))
		var row := clampi(int(entry.get("row", 0)), 0, maxi(0, height - 1))
		units.append(make_unit(proto, fac, col, row))

# 把当前场上所有单位存进地图文件的 units 字段（关卡预置）。复用 _unit_to_proto + 补 AI 字段；
# 写回当前地图路径（保留 tiles/regions 不变）。返回是否成功。
func save_units_to_map() -> bool:
	var units_json := []
	for u in units:
		var proto := _unit_to_proto(u)
		proto.erase("_preset")                 # 这是关卡预置、不是用户预设
		proto["ai_threat"] = u.ai_threat        # 预置敌人的 AI 警觉配置要随地图存
		proto["ai_region"] = u.ai_region
		proto["ai_group"] = u.ai_group
		units_json.append({"proto": proto, "col": u.col, "row": u.row, "faction": u.faction})
	var path: String = SandboxConfig.map_path if SandboxConfig.map_path != "" else MAP_PATH
	if MapIO.write_map(path, width, height, tiles, _map_regions, units_json, _map_triggers, _map_terrain_overrides, _map_environment):
		_map_units = units_json   # 同步内存：R 重开 / exit_battle 从这里重建
		return true
	return false

# ============ 触发器（schema v3：when 条件 → do 动作）============
# 当前支持 when.event="enter_region"（玩家踏入某区域）；动作 show_message / spawn_unit / activate_aggro。
# 编辑器侧的「触发器层」UI 待做（先支持运行时 + 手写/沙盒摆好后写回）。

# 玩家单位 u 落位后评估所有 enter_region 触发器
func _check_enter_triggers(u) -> void:
	if _map_triggers.is_empty():
		return
	var cell := Vector2i(u.col, u.row)
	for i in _map_triggers.size():
		var trig = _map_triggers[i]
		if typeof(trig) != TYPE_DICTIONARY:
			continue
		var when = trig.get("when", {})
		if typeof(when) != TYPE_DICTIONARY or str(when.get("event", "")) != "enter_region":
			continue
		var tid := _trigger_key(trig, i)
		if bool(when.get("once", true)) and _fired_triggers.has(tid):
			continue
		var by := str(when.get("by_faction", "player"))   # 缺省＝仅玩家踏入触发
		if by != "" and by != "any" and u.faction != by:
			continue
		var cells: Dictionary = _all_region_cells.get(str(when.get("region", "")), {})
		if cells.has(cell):
			_fire_trigger(trig, tid)

# 触发器去重 key：有 id 用 id；无 id 用数组下标兜底（否则 once 对无 id 触发器失效、会重复触发）
func _trigger_key(trig: Dictionary, index: int) -> String:
	var tid := str(trig.get("id", ""))
	return tid if tid != "" else "#%d" % index

func _fire_trigger(trig: Dictionary, tid: String = "") -> void:
	if tid == "":
		tid = str(trig.get("id", ""))
	if tid != "":
		_fired_triggers[tid] = true
	var label := str(trig.get("label", tid))
	for a in trig.get("do", []):
		if typeof(a) == TYPE_DICTIONARY:
			_do_trigger_action(a, label)

func _do_trigger_action(a: Dictionary, trig_label: String) -> void:
	match str(a.get("action", "")):
		"show_message":
			_log_line("⚑ %s" % str(a.get("text", trig_label)))
		"activate_aggro":
			var grp := str(a.get("group", ""))   # 空＝激活全部敌方
			for g in units:
				if not _is_friendly(g) and (grp == "" or g.ai_group == grp) and not g.ai_aggroed:
					_ai_set_aggro(g)
		"set_weather":
			# 定点变天：设为指定天气；duration>0 ＝ 持续该回合数后回天气表随机，<=0/缺 ＝ 常驻不变
			_cur_weather = str(a.get("weather", "clear"))
			_weather_left = maxi(0, int(a.get("duration", 0)))
			_apply_env_modifiers()
			var dur_txt := ("%d 回合" % _weather_left) if _weather_left > 0 else "持续"
			_log_line("⚑ 天气转为 [b]%s[/b]（%s）" % [EnvDB.weather_label(_cur_weather), dur_txt])
		"spawn_unit":
			var proto := _find_proto(str(a.get("proto_id", "")))
			if proto.is_empty():
				return
			var col := clampi(int(a.get("col", 0)), 0, maxi(0, width - 1))
			var row := clampi(int(a.get("row", 0)), 0, maxi(0, height - 1))
			var fac := str(a.get("faction", proto.get("default_faction", "enemy")))
			var nu = make_unit(proto, fac, col, row)
			units.append(nu)
			if phase == "battle" and not (nu in turn_order):
				turn_order.append(nu)   # 战中召唤：排进本 round 末
			_log_line("⚑ %s 出现！" % _cname(nu))
			if canvas != null:
				canvas.queue_redraw()

# 按 id 查内置原型（data/unit_prototypes.json）；找不到返回 {}
func _find_proto(pid: String) -> Dictionary:
	if pid == "":
		return {}
	for p in _all_prototypes():
		if str(p.get("id", "")) == pid:
			return p
	return {}

# ============ 布置阶段（deploy）：调试侧栏生成/编辑单位，点开始游戏才开打 ============

# 进入/回到布置阶段：回合不跑，显示调试侧栏、隐藏战斗 UI 与顶部顺序槽
func _enter_deploy() -> void:
	phase = "deploy"
	battle_over = false
	_cur_weather = "clear"   # 回布置：清天气 + 日夜（叠层停），下次开战再按地图摇/读
	_weather_left = 0
	_cur_time = "day"
	_time_sight_mult = 1.0
	_update_env_overlays()   # 停天气 VFX + 隐藏夜晚变暗
	_clear_selection()
	if _deploy_panel != null:
		_deploy_panel.visible = true
		_deploy_panel.set_battle_mode(false)
		_deploy_panel.select_unit(null)   # 清掉可能指向已移除单位的编辑选中
	if _roster_bar != null:
		_roster_bar.visible = true
		_roster_bar.refresh()
	_set_battle_ui_visible(false)
	if _turn_bar != null:
		_turn_bar.visible = false
	if canvas != null:
		canvas.queue_redraw()

func _set_battle_ui_visible(on: bool) -> void:
	if _battle_ui != null:
		_battle_ui.visible = on

# 「开始游戏」：锁定布置 → 翻到战斗阶段 → 启动回合系统（复用 _start_battle）
func begin_game() -> void:
	if phase != "deploy":
		return
	if units.is_empty():
		return
	phase = "battle"
	if _deploy_panel != null:
		_deploy_panel.set_battle_mode(true)   # 隐藏编辑控件
	if _roster_bar != null:
		_roster_bar.visible = false           # 战斗期收起底部可用单位栏
	_set_battle_ui_visible(true)
	if _turn_bar != null:
		_turn_bar.visible = true
	_start_battle()

# 通用造单位工厂：按原型 proto（unit_prototypes.json 一条或 {}）+ 指定阵营，落在 (col,row)。
# 单一造单位入口——名字/立绘/图标/tag/四维/特性/装备/技能/AI 字段全从 proto 组装，供预置落子、
# 布置栏拖放、试玩重建共用。（阶段规划：抽成独立 UnitFactory 供编辑器单位深编 / 角色编辑器复用。）
func make_unit(proto: Dictionary, fac: String, col: int, row: int):
	return UnitFactory.make_unit(proto, fac, col, row)

# 编辑单位后收尾：重算四维派生 + 注满生命/护甲（编辑器改四维/特性/装备后调）
func _commit_unit(u) -> void:
	if u == null:
		return
	u.recompute_derived()
	u.init_vitals()
	if _roster_bar != null:
		_roster_bar.refresh()
	if canvas != null:
		canvas.queue_redraw()

# ============ 可用单位 roster（底部横向栏：＋添加 / 拖到地图布置 / 编辑 / 预设）============

# 从原型或预设 proto 添加一个「可用单位」到 roster（待命，未落子），并选中编辑
func add_roster_unit(proto: Dictionary):
	var fac := str(proto.get("default_faction", proto.get("faction", "player")))
	var u = make_unit(proto, fac, -1, -1)   # col=-1：待命（不在 units、地图不渲染）
	roster.append(u)
	_refresh_roster_bar()
	select_roster_unit(u)
	return u

# 选中一个 roster 单位 → 右侧编辑器；若已落子则镜头居中并高亮
func select_roster_unit(u) -> void:
	set_viewed_unit(u)
	if is_placed(u):
		focus_on_unit(u)
	if _deploy_panel != null:
		_deploy_panel.select_unit(u)

func is_placed(u) -> bool:
	return units.has(u)

# 把 roster 单位落到 (col,row)（已落子则移到新格）；越界/被占则拒绝
func place_roster_unit(u, col: int, row: int) -> void:
	if u == null or phase != "deploy" or not _cell_in_bounds(col, row):
		return
	var occ = unit_at(col, row)
	if occ != null and occ != u:
		return
	# 部署区限制：地图画了部署区时，玩家方（我方/友方）单位只能放区内；
	# 敌方/中立、以及没画部署区的图（_deploy_cells 空）= 任意放（不挡调试 / 关卡设计者摆敌）。
	if _is_friendly(u) and not _deploy_cells.is_empty() and not _deploy_cells.has(Vector2i(col, row)):
		if _deploy_panel != null:
			_deploy_panel.notify("玩家单位只能放在部署区（高亮格）内")
		return
	u.col = col
	u.row = row
	if not units.has(u):
		units.append(u)
	set_viewed_unit(u)
	_refresh_roster_bar()
	if _deploy_panel != null:
		_deploy_panel.select_unit(u)
	if canvas != null:
		canvas.queue_redraw()

# 撤下：从场上召回到待命（仍在 roster、可重新布置）
func recall_roster_unit(u) -> void:
	if u == null:
		return
	units.erase(u)
	u.col = -1
	u.row = -1
	_refresh_roster_bar()
	if canvas != null:
		canvas.queue_redraw()

# 彻底移出 roster（连带撤下场上）
func remove_roster_unit(u) -> void:
	units.erase(u)
	roster.erase(u)
	if viewed_unit == u:
		set_viewed_unit(null)
	if hover_unit == u:
		hover_unit = null
	if selected_unit == u:
		selected_unit = null
	if _deploy_panel != null and _sel_is(u):
		_deploy_panel.select_unit(null)
	_refresh_roster_bar()
	if canvas != null:
		canvas.queue_redraw()

func _sel_is(u) -> bool:
	return _deploy_panel != null and _deploy_panel.selected_unit() == u

func _refresh_roster_bar() -> void:
	if _roster_bar != null:
		_roster_bar.refresh()

# 拖放落子（SandboxCanvas._drop_data 调用）：把被拖的 roster 单位放到该格
func deploy_drop(col: int, row: int, data: Dictionary) -> void:
	if phase != "deploy" or typeof(data) != TYPE_DICTIONARY:
		return
	if data.get("kind") == "roster_unit":
		place_roster_unit(data.get("ref"), col, row)

# 布置阶段右键某格：有已布置单位 → 撤下回待命
func deploy_right_click(col: int, row: int) -> void:
	if phase != "deploy":
		return
	var u = unit_at(col, row)
	if u != null:
		recall_roster_unit(u)

# 一键把默认演示阵容（比路兹/维肯/2 敌）加入 roster（待命，不自动落子）
func spawn_default_roster() -> void:
	for proto in _all_prototypes():
		add_roster_unit(proto)

# ---- 单位预设（保存「调整好的单位配置」，与场上位置无关）----

# 把一个单位序列化成 proto 字典（可被 make_unit 复原）
func _unit_to_proto(u) -> Dictionary:
	return UnitFactory.unit_to_proto(u)

# 保存单位为预设（名 preset_name），写进 user://unit_presets.json（同名覆盖）
func save_unit_preset(u, preset_name: String) -> void:
	UnitFactory.save_preset(u, preset_name)

func load_unit_presets() -> Array:
	return UnitFactory.load_presets()

# 读 unit_prototypes.json 的内置原型
func _all_prototypes() -> Array:
	return UnitFactory.all_prototypes()

# 「＋」菜单数据：内置原型（含开头「空白单位」）+ 用户预设
func roster_sources() -> Dictionary:
	var protos := [{"name": "空白单位"}]
	protos.append_array(_all_prototypes())
	return {"protos": protos, "presets": load_unit_presets()}

# —— UI：上部[画布 + 右编辑栏] + 底部[可用单位横栏] ——
func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)
	var main := HBoxContainer.new()
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(main)

	canvas = SandboxCanvas.new()
	canvas.editor = self
	canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_child(canvas)
	# 环境叠层（都挂 canvas 下 → 覆盖战场视口、不盖侧栏、点击穿透）：
	# ① 夜晚变暗滤镜（先加＝在下层，压暗地形/单位/迷雾）
	_night_overlay = ColorRect.new()
	_night_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_night_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_night_overlay.visible = false
	canvas.add_child(_night_overlay)
	# ② 天气 VFX（后加＝在上层，雨雪雾画在变暗之上）
	_weather_vfx = WeatherVFX.new()
	canvas.add_child(_weather_vfx)
	# ③ 调试快捷键提示（战场右下角，最上层、点击穿透）
	_build_shortcut_hint()

	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(320, 0)
	# 布置阶段：调试侧栏（生成/编辑单位与物品、开始游戏）
	_deploy_panel = DeployPanel.new()
	_deploy_panel.host = self
	side.add_child(_deploy_panel)
	# 战斗阶段：回合状态 + 战斗记录（布置阶段隐藏）
	_battle_ui = VBoxContainer.new()
	_battle_ui.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(_battle_ui)
	# 退出战斗 → 回到布置阶段（保留 roster、可重新布置/开打）
	var exit_btn := Button.new()
	exit_btn.text = "⏹ 退出战斗（回布置）"
	exit_btn.pressed.connect(exit_battle)
	_battle_ui.add_child(exit_btn)
	_battle_ui.add_child(HSeparator.new())
	# 回合状态（紧凑）
	_turn_panel = VBoxContainer.new()
	_battle_ui.add_child(_turn_panel)
	_battle_ui.add_child(HSeparator.new())
	# 战斗记录
	var log_title := Label.new()
	log_title.text = "战斗记录"
	_battle_ui.add_child(log_title)
	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_battle_ui.add_child(_log)
	main.add_child(side)

	# 底部「可用单位」横栏（布置阶段管理 roster；战斗阶段隐藏）
	_roster_bar = RosterBar.new()
	_roster_bar.host = self
	_roster_bar.custom_minimum_size = Vector2(0, 104)
	root.add_child(_roster_bar)

	# 左键选中单位时在鼠标处唤出的选单：项目按可用性动态构建（见 open_context_menu）
	_context_menu = PopupMenu.new()
	_context_menu.id_pressed.connect(_on_context_menu)
	add_child(_context_menu)
	# 「技能」子菜单：列已学主动技能（冷却中灰显 + 显剩余冷却数）；项目动态填，见 open_context_menu
	_skill_submenu = PopupMenu.new()
	_skill_submenu.name = "SkillSubmenu"
	_skill_submenu.id_pressed.connect(_on_skill_chosen)
	_context_menu.add_child(_skill_submenu)

	# 攻击音效播放器
	_sfx = AudioStreamPlayer.new()
	_sfx.stream = _load_audio(ATTACK_SFX)
	add_child(_sfx)

	# 顶部行动顺序槽（HUD，居中、宽=屏幕一半）
	_turn_bar = TurnOrderBar.new()
	_turn_bar.host = self
	add_child(_turn_bar)

	# 角色状态页（模态覆盖层，置于最上、默认隐藏）
	_status_panel = UnitStatusPanel.new()
	_status_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_status_panel.visible = false
	_status_panel.host = self     # 供翻页取同阵营单位 + 棋子高亮
	add_child(_status_panel)

# 行动顺序槽点头像 → 把镜头切到该单位所在格（不开角色状态）
func focus_on_unit(u) -> void:
	if u != null and canvas != null:
		canvas.center_on_cell(u.col, u.row)

# 行动顺序槽鼠标扫过头像 → 高亮该单位所在格；移开则清除
func set_hover_unit(u) -> void:
	if hover_unit == u:
		return
	hover_unit = u
	if canvas != null:
		canvas.queue_redraw()

func clear_hover_unit(u) -> void:
	if hover_unit == u:
		set_hover_unit(null)

# 设置角色状态页当前查看的单位（供棋子圆圈高亮）；变更后重绘画布
func set_viewed_unit(u) -> void:
	viewed_unit = u
	if canvas != null:
		canvas.queue_redraw()

# 右栏顶部紧凑回合状态（详细属性见角色状态页）
func _refresh_info() -> void:
	if _turn_panel == null:
		return
	for c in _turn_panel.get_children():
		c.queue_free()
	if units.is_empty():
		return
	var u = active_unit()
	if u == null:
		u = units[0]
	_add_info("回合", str(round_num))
	if _cur_time != "day" or _cur_weather != "clear":   # 非「昼·晴」才显示环境（影响视野）
		var env_txt := "%s·%s" % [EnvDB.time_label(_cur_time), EnvDB.weather_label(_cur_weather)]
		if _weather_left > 0:
			env_txt += "（余%d）" % _weather_left
		_add_info("环境", env_txt)
	_add_info("行动", "%s [%s]" % [u.unit_name, u.faction])
	_add_info("AP", "%d / %d" % [u.ap, int(u.stats.get("AP_max", 0))])
	_add_info("移动点", str(u.move_points))

func _add_info(k: String, v: String) -> void:
	var l := Label.new()
	l.text = "%s：%s" % [k, v]
	_turn_panel.add_child(l)

# 战场右下角：调试快捷键提示（半透明深底 + 浅字，点击穿透、最上层）
func _build_shortcut_hint() -> void:
	if canvas == null:
		return
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.45)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(6)
	panel.add_theme_stylebox_override("panel", sb)
	var lbl := Label.new()
	lbl.text = "[调试]  V 迷雾开关   N 昼/夜   C 切天气"
	lbl.add_theme_color_override("font_color", Color(0.85, 0.88, 0.95))
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(lbl)
	canvas.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 8)

# ============ 供 HexCanvas / SandboxCanvas 调用的“editor”接口 ============

# 阵营色单一源＝tags.json faction 条目 color（TagDB.color）；未知阵营回退玩家蓝
func faction_color(f: String) -> Color:
	var hex := TagDB.color(f)
	return Color(hex) if hex != "" else Color("#3A7BD5")

# 按 tile 的 terrain/variant 查地形定义（经 TerrainDB O(1) 查表，找不到返回 null）
func _terrain_entry(tile):
	return TerrainDB.entry_for(tile)

# 该 tile 的有效 move 块：优先本图 terrain_overrides（整块覆盖），否则全局 terrains.json。
# 图级覆盖 = 编辑器「地形数据·本图」写的，只影响这张图（通行/成本），不动全局。
func _effective_move(tile) -> Dictionary:
	if not _map_terrain_overrides.is_empty():
		var key := "%s/%s" % [str(tile.get("terrain", "")), str(tile.get("variant", ""))]
		var ov = _map_terrain_overrides.get(key)
		if typeof(ov) == TYPE_DICTIONARY and typeof(ov.get("move")) == TYPE_DICTIONARY:
			return ov["move"]
	var e = _terrain_entry(tile)
	return e.get("move", {}) if e != null else {}

func color_for_tile(tile) -> Color:
	var e = _terrain_entry(tile)
	return Color.html(e.color) if e != null else Color(1, 0, 1)

func decor_for_tile(tile) -> String:
	var e = _terrain_entry(tile)
	return e.decor if e != null else "none"

func accent_for_tile(tile) -> Color:
	var e = _terrain_entry(tile)
	return Color.html(e.accent) if e != null else Color(1, 0, 1)

func unit_at(col: int, row: int):
	for u in units:
		if u.col == col and u.row == row:
			return u
	return null

# 通行性文字：可通行 / 不可通行 / 仅<tag1/tag2>（读有效 move.passable_by，含图级覆盖）
func _passability_text(mv) -> String:
	if typeof(mv) != TYPE_DICTIONARY:
		return "未知"
	var pb = mv.get("passable_by", "all")
	if typeof(pb) == TYPE_ARRAY:
		if pb.is_empty():
			return "不可通行"
		var names := []
		for tg in pb:
			names.append(TagDB.cn(str(tg)))
		return "仅<%s>" % "/".join(names)
	if pb == "none":
		return "不可通行"
	return "可通行"

# 特殊效果文字：列出 effects 的 name（desc）；无则「无」
func _effects_text(entry) -> String:
	if entry == null:
		return "无"
	var effs = entry.get("effects", [])
	if typeof(effs) != TYPE_ARRAY or effs.is_empty():
		return "无"
	var parts := []
	for ef in effs:
		var nm = str(ef.get("name", ""))
		var d = str(ef.get("desc", ""))
		if nm != "" and d != "":
			parts.append("%s：%s" % [nm, d])
		else:
			parts.append(nm + d)
	return "；".join(parts)

# 左下角悬停信息：坐标 + 名称 + 通行性 + 特殊效果 +（该格单位）
func hover_text(col: int, row: int) -> String:
	if row < 0 or row >= tiles.size() or col < 0 or col >= tiles[row].size():
		return ""
	var entry = _terrain_entry(tiles[row][col])
	var label = entry.get("label", "未知") if entry != null else "未知"
	# 地形段（单位信息已移到 hover_extra 的单位卡里，不再走文字行）
	var s := "地形：%s（%d, %d）" % [label, col, row]
	s += "\n可通行性：%s" % _passability_text(_effective_move(tiles[row][col]))
	s += "\n特殊效果：%s" % _effects_text(entry)
	return s

# 左下信息栏的扩展段：悬停格若有可见单位 → 返回一张单位速览卡；否则 null（栏只剩地形段）。
func hover_extra(col: int, row: int):
	if not _cell_in_bounds(col, row):
		return null
	var u = unit_at(col, row)
	if u == null or _unit_hidden_by_fog(u):
		return null   # 迷雾里看不见的敌人不给卡
	return _build_unit_hover_card(u)

# 单位速览卡：左 头像 / 右竖排 名字 · 血量条 · 护甲条(有甲才画) · 图标行(主手武器 + 主动技能)。
func _build_unit_hover_card(u) -> Control:
	var root := HBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tex = TextureCache.get_tex(str(u.portrait))
	if tex != null:
		var av := TextureRect.new()
		av.texture = tex
		av.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		av.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		av.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		av.custom_minimum_size = Vector2(52, 52)
		av.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(av)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(col)
	# 名字（阵营色）+ 等级
	var namerow := HBoxContainer.new()
	namerow.add_theme_constant_override("separation", 6)
	namerow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var nm := Label.new()
	nm.text = str(u.unit_name)
	nm.add_theme_color_override("font_color", faction_color(u.faction))
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	namerow.add_child(nm)
	var lv := Label.new()
	lv.text = "Lv%d" % int(u.level)
	lv.add_theme_color_override("font_color", Color(0.80, 0.80, 0.86))
	lv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	namerow.add_child(lv)
	col.add_child(namerow)
	# 护甲条（在血条上面，有甲才画）+ 血条
	var amax := int(u.effective_stat("armor_max"))
	if amax > 0:
		col.add_child(_hover_stat_bar("护甲", int(u.stats.get("armor", 0)), amax, FLOAT_ARMOR_COLOR))
	col.add_child(_hover_stat_bar("生命", int(u.stats.get("HP", 0)), int(u.effective_stat("HP_max")), FLOAT_HP_COLOR))
	# 武器 + 技能（各一行「图标 + 名字」）
	var skills := _hover_skill_section(u)
	if skills != null:
		col.add_child(skills)
	return root

# 卡内一条状态条：底黑 + 按 cur/max 充填 color，上叠「标签 cur/max」白字（描边可读）。
func _hover_stat_bar(label: String, cur: int, maxv: int, color: Color) -> Control:
	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(150, 16)
	bar.min_value = 0
	bar.max_value = maxf(1.0, float(maxv))
	bar.value = clampf(float(cur), 0.0, bar.max_value)
	bar.show_percentage = false
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.5)
	bg.set_corner_radius_all(2)
	bar.add_theme_stylebox_override("background", bg)
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	fill.set_corner_radius_all(2)
	bar.add_theme_stylebox_override("fill", fill)
	var lbl := Label.new()
	lbl.text = "%s %d/%d" % [label, cur, maxv]
	lbl.set_anchors_preset(Control.PRESET_FULL_RECT)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	lbl.add_theme_constant_override("outline_size", 3)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(lbl)
	return bar

# 武器段：主手武器（图标+名）+ 其技能，再 副手武器（图标+名）+ 其技能。
# 每把武器的技能第一个 = attack(基础攻击 = 广义普攻)，其余 = 武器附加技能（见 _weapon_skills）。
func _hover_skill_section(u) -> Control:
	if not ("equipment" in u):
		return null
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var main_uid := int(u.equipment.get("main_hand", 0))
	_add_weapon_rows(v, main_uid)
	var off_uid := int(u.equipment.get("off_hand", 0))
	if off_uid != 0 and off_uid != main_uid:   # 双手武器占两槽、同一件（同 uid）→ 不重复列
		_add_weapon_rows(v, off_uid)
	return v if v.get_child_count() > 0 else null

# 把一件武器（图标+名，白）及其技能（图标+名，金；第一个=基础攻击）逐行加进 parent。
func _add_weapon_rows(parent: VBoxContainer, uid: int) -> void:
	if uid == 0:
		return
	var item = ItemInstances.view(uid)
	if item == null:
		return
	var wrow = _hover_named_icon(str(item.get("icon", "")), str(item.get("name", "")), Color(0.90, 0.90, 0.95))
	if wrow != null:
		parent.add_child(wrow)
	for sk in _weapon_skills(item):
		var srow = _hover_named_icon(str(sk.get("icon", "")), str(sk.get("name", "")), Color(0.95, 0.82, 0.5))
		if srow != null:
			parent.add_child(srow)

# 一件武器的技能列表：第一个 = attack(基础攻击/广义普攻)；其余 = 未来 `skills` 数组里的附加技能。
func _weapon_skills(item) -> Array:
	var out := []
	var atk = item.get("attack", null)
	if typeof(atk) == TYPE_DICTIONARY:
		out.append(atk)
	var extra = item.get("skills", null)
	if typeof(extra) == TYPE_ARRAY:
		for s in extra:
			if typeof(s) == TYPE_DICTIONARY:
				out.append(s)
	return out

# 一行「小图标 + 名字」：图标可缺（只剩名字）；图标名都空 → null。
func _hover_named_icon(icon_path: String, name: String, name_color: Color) -> Control:
	if name == "" and icon_path == "":
		return null
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 5)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ic = _hover_icon(icon_path)
	if ic != null:
		h.add_child(ic)
	var l := Label.new()
	l.text = name
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", name_color)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(l)
	return h

# 卡内一个小图标：带淡边框方框 + 纹理（缺纹理 → null）。
func _hover_icon(path: String) -> Control:
	var tex = TextureCache.get_tex(path)
	if tex == null:
		return null
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.05)
	sb.border_color = Color(1, 1, 1, 0.25)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(2)
	p.add_theme_stylebox_override("panel", sb)
	var ic := TextureRect.new()
	ic.texture = tex
	ic.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ic.custom_minimum_size = Vector2(22, 22)
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(ic)
	return p

# 画布输入接口（sandbox 不绘制地形/取色，留空兜底）
func begin_stroke() -> void: pass
func end_stroke() -> void: pass
func paint_cell(_col: int, _row: int) -> void: pass
func pick_brush_at(_col: int, _row: int) -> void: pass

# 左键点格：移动模式下＝选目标提交移动 / 取消；否则＝点中行动单位则唤出选单
func left_click_cell(col: int, row: int) -> void:
	if _animating or battle_over:
		return
	if phase == "deploy":
		# 布置阶段：点单位＝选中编辑（放置走拖拽，见 SandboxCanvas._drop_data）
		var du = unit_at(col, row)
		if du != null:
			set_viewed_unit(du)
			if _deploy_panel != null:
				_deploy_panel.select_unit(du)
		return
	var clicked := Vector2i(col, row)
	if skill_mode:
		if skill_cells.has(clicked) and _valid_skill_target(selected_unit, SkillDB.get_skill(active_skill_id), unit_at(clicked.x, clicked.y)):
			_do_skill(selected_unit, active_skill_id, clicked)
		else:
			_clear_selection()   # 点范围外/无效目标 = 取消技能
		return
	if attack_mode:
		if attack_cells.has(clicked):
			_do_attack(selected_unit, clicked)   # 传格子（直线 AoE 按方向打）
		else:
			_clear_selection()   # 点范围外 = 取消攻击
		return
	if move_mode:
		if reachable.has(clicked):
			_commit_move(col, row)
		elif attack_cells.has(clicked):
			pass   # 移动模式下红格仅为「极限可攻击范围」预览，不在此攻击
		else:
			_clear_selection()   # 点到范围外 = 取消移动
		return
	var here = unit_at(col, row)
	if here != null:
		selected_unit = here        # 点中任意单位 → 行动选单（仅列可用项；非当前/不可控单位只有「角色状态」）
		open_context_menu()
	else:
		_clear_selection()          # 点空格 → 取消当前选中
		open_ground_menu()          # 并弹出仅含「结束回合」的菜单（仅当前可控单位的回合）

# 右键 / 点空白：取消当前选中或移动模式
func cancel_action() -> void:
	if _animating:
		return
	_clear_selection()

# ============ 回合框架（简陋版：单层 round + 速度出手序列）============

func _start_battle() -> void:
	round_num = 1
	zoc_triggered = {}
	_fired_triggers = {}   # 新一场战斗：触发器「只触发一次」记录清零
	for u in units:
		u.refresh_for_turn()       # 开局所有单位面板满 AP（便于查看）
		u.reset_skill_charges()    # 技能冷却清零、本战次数按智力重置
	_rebuild_turn_order()
	active_index = 0
	_setup_environment()  # 建立日夜 + 开场天气（挂 sight 环境修正）
	_recompute_vision()   # 开战即算一次玩家视野（迷雾初态）
	_begin_active_turn()

func _rebuild_turn_order() -> void:
	turn_order = _sorted_by_speed(units)

# 按速度（effective_stat，含修正）大→小排序；同速我方/友方优先。
func _sorted_by_speed(arr: Array) -> Array:
	var out := arr.duplicate()
	out.sort_custom(_speed_cmp)
	return out

func _speed_cmp(a, b) -> bool:
	var sa: int = a.effective_stat("speed")
	var sb: int = b.effective_stat("speed")
	if sa != sb:
		return sa > sb
	var fa := _is_friendly(a)
	var fb := _is_friendly(b)
	if fa != fb:
		return fa   # 同速：友方先
	return false

# 速度中途变化（buff/装备等）：保留已行动者与当前行动者，仅对「之后未行动」的重排，
# 立刻反映到出手序列与行动顺序槽。任何改了 speed 修正的地方都应调用本函数。
func _resort_pending() -> void:
	if turn_order.is_empty() or active_index >= turn_order.size():
		return
	var acted := turn_order.slice(0, active_index)        # 本 round 已行动
	var active = turn_order[active_index]                  # 当前行动者（保持最前）
	var rest := turn_order.slice(active_index + 1)         # 之后未行动 → 重排
	rest = _sorted_by_speed(rest)
	var new_order := acted.duplicate()
	new_order.append(active)
	new_order.append_array(rest)
	turn_order = new_order
	# active_index 不变（= acted.size()）

func notify_speed_changed() -> void:
	_resort_pending()
	_refresh_turn_bar()
	_refresh_info()

# 行动顺序槽要显示的条目序列：当前回合剩余（含标记）+ 下一回合全员（按当前速度）。
func _turn_sequence() -> Array:
	var seq := []
	if turn_order.is_empty():
		return seq
	var active = active_unit()
	if active_index < turn_order.size():
		seq.append({"kind": "marker", "round": round_num})
		for i in range(active_index, turn_order.size()):
			var u = turn_order[i]
			seq.append({"kind": "unit", "round": round_num, "unit": u, "active": (u == active)})
	# 下一回合：全员按当前速度重排（尚未开始，无「当前行动者」）
	seq.append({"kind": "marker", "round": round_num + 1})
	for u in _sorted_by_speed(units):
		seq.append({"kind": "unit", "round": round_num + 1, "unit": u, "active": false})
	return seq

func _refresh_turn_bar() -> void:
	if _turn_bar != null:
		_turn_bar.refresh(_turn_sequence())

func active_unit():
	if active_index < 0 or active_index >= turn_order.size():
		return null
	return turn_order[active_index]

func _begin_active_turn() -> void:
	if battle_over or phase != "battle":
		return   # 布置阶段绝不进回合/AI（双保险——根本不调 _start_battle）
	var u = active_unit()
	if u != null:
		u.refresh_for_turn()   # AP 刷新、移动点清零
	_clear_selection()         # 清掉上一单位的选中/移动状态
	_refresh_info()
	_refresh_turn_bar()        # 行动者换人 → 更新顶部行动顺序槽（当前者下落、后续补位）
	# 敌对方（敌方/中立）由 AI 操控；友方（我方/友方）由玩家操控
	if u != null and not _is_friendly(u):
		_run_enemy_ai(u)

# ============ 敌方 AI（基础版：靠近最近敌人 → 进攻击距离就打）============

func _run_enemy_ai(unit) -> void:
	if not is_inside_tree():
		return
	await get_tree().create_timer(AI_THINK_DELAY).timeout
	# 先评估仇恨：未被激活（休眠）则按兵不动、直接过；激活后才持续行动
	# phase=="battle" 兜底：中途「退出战斗」回到布置阶段时，挂起的 AI 协程恢复后立即收手。
	if is_inside_tree() and not battle_over and phase == "battle" and active_unit() == unit and _ai_update_aggro(unit):
		while is_inside_tree() and not battle_over and phase == "battle" and active_unit() == unit:
			var acted: bool = await _ai_one_action(unit)
			if not acted:
				break
			await get_tree().create_timer(AI_ACT_GAP).timeout   # 动作间停顿（移动→停 1 秒→攻击）
	if is_inside_tree() and not battle_over and phase == "battle" and active_unit() == unit:
		end_turn()

# 评估并更新 unit 的仇恨状态；返回是否已激活（已激活才会行动）。
# ① 视野感知(ai_threat)：敌人进本单位 sight 且有 LOS 就警觉；② 区域触发；③ 连锁同组。见 docs/感知系统.md。
func _ai_update_aggro(unit) -> bool:
	if unit.ai_aggroed:
		return true
	var trig := false
	var here := Vector2i(unit.col, unit.row)
	# ① 视野感知：敌人进入本单位视野(sight)且视线(LOS)不被地形挡（六边形战棋：只有地形挡、单位不挡）
	if unit.ai_threat:
		var sight: int = _effective_sight(unit)   # 含天气加减 + 日夜最终乘子
		for h in units:
			var hp := Vector2i(h.col, h.row)
			if _is_hostile(unit, h) and _hex_dist(here, hp) <= sight and _has_los(here, hp):
				trig = true
				break
	# ② 区域触发：敌人踏进该单位挂的区域（关卡设计者指定）
	if not trig and unit.ai_region != "" and aggro_regions.has(unit.ai_region):
		var cells: Dictionary = aggro_regions[unit.ai_region]
		for h in units:
			if _is_hostile(unit, h) and cells.has(Vector2i(h.col, h.row)):
				trig = true
				break
	# ③ 连锁：同组任一已激活
	if not trig and unit.ai_group != "":
		for g in units:
			if g != unit and g.ai_group == unit.ai_group and g.ai_aggroed:
				trig = true
				break
	if trig:
		_ai_set_aggro(unit)
	return unit.ai_aggroed

# 激活仇恨：本体 + 连锁同组全部敌方；首次激活记一行日志。
func _ai_set_aggro(unit) -> void:
	if unit.ai_aggroed:
		return
	unit.ai_aggroed = true
	_log_line("%s 进入战斗！" % _cname(unit))
	if unit.ai_group != "":
		for g in units:
			if g != unit and not _is_friendly(g) and g.ai_group == unit.ai_group and not g.ai_aggroed:
				_ai_set_aggro(g)   # 连锁仇恨

# 一个 AI 动作：能打就打、否则靠近；返回是否做了事
func _ai_one_action(unit) -> bool:
	var target = _ai_nearest_hostile(unit)
	if target == null:
		return false
	var here := Vector2i(unit.col, unit.row)
	var tcell := Vector2i(target.col, target.row)
	var rng := int(unit.basic_attack().get("range", 1))
	# 1) 在攻击距离内且有 AP → 攻击
	if _hex_dist(here, tcell) <= rng and _can_attack(unit):
		_do_attack(unit, tcell)
		return true
	# 2) 否则朝目标移动一步（buy 一批移动力 / 用剩余移动点）
	if _move_budget(unit) > 0:
		return await _ai_step_toward(unit, target)
	return false

# 朝 target 走：在可达格里挑最靠近 target 的；不能更近就不动（返回 false）
func _ai_step_toward(unit, target) -> bool:
	var budget := _move_budget(unit)
	if budget <= 0:
		return false
	var data := _dijkstra(unit, budget)
	var best: Dictionary = data["best"]          # {格: 累计消耗}，含起点(0)
	var came: Dictionary = data["came_from"]
	var start := Vector2i(unit.col, unit.row)
	var tcell := Vector2i(target.col, target.row)
	var cur_dist := _hex_dist(start, tcell)
	var pick := start
	var pick_dist := cur_dist
	var pick_cost := 0
	for cell in best:
		if cell == start:
			continue
		if _occupied_by_other(cell.x, cell.y, unit):
			continue
		var dd := _hex_dist(cell, tcell)
		var cc := int(best[cell])
		if dd < pick_dist or (dd == pick_dist and cc < pick_cost):
			pick = cell
			pick_dist = dd
			pick_cost = cc
	if pick == start or pick_dist >= cur_dist:
		return false   # 没有更靠近的落点 → 收手
	var path := _path_via(came, pick)
	# 预算：移动点=0 时花 1 AP 买一批移动力，再扣路径消耗（与玩家提交移动同口径）
	if unit.move_points == 0:
		if unit.ap <= 0:
			return false
		unit.ap -= 1
		unit.move_points += unit.move_allowance()   # effective 口径（与预览范围 _dijkstra 一致）
	# ZOC 借机：离开起点前判定（敌方离开我方控制区也会被借机）；被钉住则本次没走成
	if _zoc_on_leave(unit):
		unit.move_points = 0
		_refresh_info()
		if canvas != null:
			canvas.queue_redraw()
		return false
	unit.move_points -= int(best[pick])
	unit.col = pick.x
	unit.row = pick.y
	_refresh_info()
	await _animate_path(unit, path)
	return true

# 最近的敌对单位（按六边形距离）
func _ai_nearest_hostile(unit):
	var best = null
	var bd := 1 << 30
	var here := Vector2i(unit.col, unit.row)
	for u in units:
		if not _is_hostile(unit, u):
			continue
		var d := _hex_dist(here, Vector2i(u.col, u.row))
		if d < bd:
			bd = d
			best = u
	return best

# 死亡处理：HP<=0 的单位移出战斗（不再重生）。攻击/伤害落地后调用。
func _handle_deaths() -> void:
	var dead := []
	for u in units:
		if int(u.stats.get("HP", 0)) <= 0:
			dead.append(u)
	if dead.is_empty():
		return
	var cur = active_unit()
	var active_died: bool = cur != null and cur in dead   # 当前行动者阵亡（借机可致）
	for u in dead:
		_log_line("[b]%s 倒下！[/b]" % _cname(u))
		units.erase(u)
		if viewed_unit == u:
			viewed_unit = null
		if hover_unit == u:
			hover_unit = null
		if selected_unit == u:
			selected_unit = null
	# 从出手序列剔除死者
	turn_order = turn_order.filter(func(x): return not (x in dead))
	if active_died:
		# 行动者阵亡 → 其 turn 结束；下一个已被 filter 前移到同下标（越界则进新 round）
		if active_index >= turn_order.size():
			active_index = 0
			round_num += 1
			_rebuild_turn_order()
			zoc_triggered = {}
			_tick_weather()   # 新 round：天气计时 −1，到期重摇
		_check_battle_over()
		if not battle_over:
			call_deferred("_begin_active_turn")   # 延后开始下一单位的 turn（避免在借机结算中重入）
	else:
		var idx: int = turn_order.find(cur)
		active_index = idx if idx >= 0 else clampi(active_index, 0, max(turn_order.size() - 1, 0))
		_check_battle_over()
	_refresh_info()
	_refresh_turn_bar()   # 单位变动（阵亡）→ 更新行动顺序槽
	_recompute_vision()   # 单位阵亡 → 重算视野（友方阵亡收缩视野）
	if canvas != null:
		canvas.queue_redraw()

# 胜负判定：敌全灭=胜 / 友方全灭=负
func _check_battle_over() -> void:
	if battle_over:
		return
	var friends := 0
	var foes := 0
	for u in units:
		if _is_friendly(u):
			friends += 1
		else:
			foes += 1
	if foes == 0:
		_end_battle(true)
	elif friends == 0:
		_end_battle(false)

func _end_battle(win: bool) -> void:
	battle_over = true
	_clear_selection()
	var col := OK_GREEN if win else BAD_RED
	var msg := "胜利！" if win else "失败…"
	_log_line("[b][color=%s]══ %s ══[/color][/b]" % [col, msg])
	_show_banner(msg, win)

# 居中大横幅（按 R 重开）
func _show_banner(msg: String, win: bool) -> void:
	if _banner == null:
		_banner = Label.new()
		_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_banner.add_theme_font_size_override("font_size", 44)
		_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var box := StyleBoxFlat.new()
		box.bg_color = Color(0, 0, 0, 0.62)
		box.set_content_margin_all(20)
		box.set_corner_radius_all(12)
		_banner.add_theme_stylebox_override("normal", box)
		add_child(_banner)
	_banner.add_theme_color_override("font_color", Color(col_html(win)))
	_banner.text = "%s\n（按 R 重开）" % msg
	_banner.visible = true
	_banner.reset_size()
	var vp := get_viewport_rect().size
	_banner.position = (vp - _banner.size) * 0.5

func col_html(win: bool) -> String:
	return OK_GREEN if win else BAD_RED

# 退出战斗 / 重开：回到布置阶段（战斗期点「退出战斗」按钮，或胜负后按 R）
func exit_battle() -> void:
	battle_over = false
	if _banner != null:
		_banner.visible = false
	selected_unit = null
	viewed_unit = null
	hover_unit = null
	_exit_move_mode()
	if _status_panel != null and _status_panel.has_method("close"):
		_status_panel.close()
	if _log != null:
		_log.clear()
	# R 重开 = 回到布置阶段：场上单位收回待命（roster 保留，可重新布置），回合状态归零
	units = []
	for u in roster:
		u.col = -1
		u.row = -1
		_clear_effects_and_buffs(u)
		u.init_vitals()   # 回满生命/护甲（清掉战斗里的损耗）
	_spawn_map_units()   # 重新落地图预置单位（关卡的敌 / 我），R 重开后不消失
	turn_order = []
	active_index = 0
	round_num = 1
	_enter_deploy()
	if canvas != null:
		canvas.queue_redraw()

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if battle_over and event.keycode == KEY_R:
		exit_battle()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_TAB and move_mode:
		# 移动模式按 Tab：切换「是否同时显示最近敌方的移动/攻击范围」
		show_enemy_preview = not show_enemy_preview
		_update_overlays()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_V:
		# 调试：切换全知（关迷雾）；默认迷雾生效
		omniscient = not omniscient
		_update_overlays()   # 悬停预览受迷雾影响，跟着刷新
		if canvas != null:
			canvas.queue_redraw()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_C and phase == "battle":
		# 调试：循环切换天气（看 VFX / 视野变化）；锁为常驻直到再切
		var ws := EnvDB.all_weathers()
		if not ws.is_empty():
			var ids := []
			for w in ws:
				ids.append(str(w.get("id", "")))
			_cur_weather = ids[(ids.find(_cur_weather) + 1) % ids.size()]
			_weather_left = 0
			_apply_env_modifiers()
			_refresh_info()
			_log_line("☁ [调试]天气 → [b]%s[/b]" % EnvDB.weather_label(_cur_weather))
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_N and phase == "battle":
		# 调试：切换昼/夜（看整体变暗滤镜 + 视野最终减半）
		_cur_time = "day" if _cur_time == "night" else "night"
		_apply_env_modifiers()
		_refresh_info()
		_log_line("☾ [调试]日夜 → [b]%s[/b]" % EnvDB.time_label(_cur_time))
		get_viewport().set_input_as_handled()

func end_turn() -> void:
	if battle_over:
		return
	var cur = active_unit()
	# 该单位 turn 末：先结算个人 DoT（流血等）。若 DoT 致死，_handle_deaths 已接管推进 → 收手。
	if _tick_turn_end_effects(cur):
		_handle_deaths()
		if battle_over or not (cur in units):
			return
	active_index += 1
	if active_index >= turn_order.size():   # 全员走完一轮 → 新 round
		active_index = 0
		round_num += 1
		_rebuild_turn_order()
		zoc_triggered = {}   # 新 round：借机去重清空
		_tick_weather()      # 新 round：天气计时 −1，到期重摇
	_begin_active_turn()

# 单位自己 turn 末：结算个人 DoT（按最大生命百分比直接掉 HP，无视护甲）+ 时长递减（按 round）+ 到期移除。
# 返回是否造成了伤害（用于触发死亡检查）。
func _tick_turn_end_effects(u) -> bool:
	if u == null or not ("effects" in u) or u.effects.is_empty():
		return false
	var dmg_done := false
	var keep := []
	for e in u.effects:
		var pct := float(e.get("dot_pct_max_hp", 0))
		if pct > 0.0:
			var d := int(round(float(u.effective_stat("HP_max")) * pct / 100.0))
			if d > 0:
				u.stats["HP"] = int(u.stats.get("HP", 0)) - d
				dmg_done = true
				_log_line("%s %s：-%d（最大生命%s%%）" % [_cname(u), str(e.get("name", "流血")), d, _numf(pct)])
		if e.get("permanent", false):
			keep.append(e)
		else:
			var dur := int(e.get("duration", 0)) - 1
			if dur > 0:
				e["duration"] = dur
				keep.append(e)
			else:
				_remove_mods_by_source(u, str(e.get("source", "buff:" + str(e.get("name", "")))))   # 到期：连带摘掉其挂的修正
	u.effects = keep
	return dmg_done

func _on_context_menu(id: int) -> void:
	match id:
		0:
			_enter_move_mode()    # 移动
		1:
			end_turn()            # 回合结束
		2:
			if selected_unit != null and _status_panel != null:
				_status_panel.open(selected_unit)   # 角色状态
		3:
			_enter_attack_mode()  # 攻击
		4:
			_do_toggle_fly(selected_unit)   # 起飞 / 降落

# 起飞 / 降落（动作，耗 1 AP）：切 ground/flying（换地形通行 + 换主/副手攻击：地撕裂/空抓取）。
# 游戏状态即时切好；视觉上 token 用 _animate_fly_toggle 在贴地↔悬空之间缓动。
func _do_toggle_fly(u) -> void:
	if u == null or not u.can_fly() or u.ap <= 0 or _animating:
		return
	u.ap -= 1
	var going_up: bool = not u.is_airborne()
	u.set_airborne(going_up)
	_push_log(["%s %s" % [_cname(u), "起飞（→足爪·抓取）" if going_up else "降落（→翼爪·撕裂）"]])
	_clear_selection()
	_refresh_info()
	_animate_fly_toggle(u, going_up)

# 起降视觉过渡：把该单位的「悬空因子」从当前值缓动到 1（起飞）/ 0（降落）。
func _animate_fly_toggle(u, going_up: bool) -> void:
	if _fly_tweens.has(u) and _fly_tweens[u] != null and _fly_tweens[u].is_valid():
		_fly_tweens[u].kill()   # 旧的起降动画未完就再切 → 先停掉，从当前高度接着缓动
	var from: float = _fly_anim.get(u, 0.0 if going_up else 1.0)
	var to := 1.0 if going_up else 0.0
	_fly_anim[u] = from
	var tw := create_tween()
	tw.tween_method(_set_fly_factor.bind(u), from, to, FLY_ANIM_TIME).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT if going_up else Tween.EASE_IN)
	tw.tween_callback(_end_fly_anim.bind(u))
	_fly_tweens[u] = tw

func _set_fly_factor(v: float, u) -> void:
	_fly_anim[u] = v
	if canvas != null:
		canvas.queue_redraw()

func _end_fly_anim(u) -> void:
	_fly_anim.erase(u)
	_fly_tweens.erase(u)
	if canvas != null:
		canvas.queue_redraw()

# 单位当前「悬空因子」0..1：起降动画中取插值；否则按 flying tag 取 1/0。供 SandboxCanvas._draw_unit。
func fly_factor(u) -> float:
	if _fly_anim.has(u):
		return _fly_anim[u]
	return 1.0 if u.is_airborne() else 0.0

# —— 主动技能：菜单 / 进入目标模式 / 释放 ——

# 该单位已学、且「主动」的技能 id 列表（按通用序列槽位 seq 升序，稳定）
func _learned_active_skills(u) -> Array:
	var out := []
	if u == null:
		return out
	for id in u.skills:
		var def = SkillDB.get_skill(id)
		if def != null and def.get("active", false):
			out.append(id)
	out.sort_custom(func(a, b):
		return int(SkillDB.get_skill(a).get("seq", 99)) < int(SkillDB.get_skill(b).get("seq", 99)))
	return out

# 填「技能」子菜单：每个已学主动技能一项；冷却中/用尽 → 灰显(disabled) + 名后用阿拉伯数字标剩余冷却。
func _build_skill_submenu(u) -> void:
	_skill_submenu.clear()
	_skill_menu_map = {}
	var i := 0
	for id in _learned_active_skills(u):
		var def = SkillDB.get_skill(id)
		var ready: bool = u.skill_ready(id) and u.ap >= int(def.get("ap_cost", 1))
		var label := str(def.get("name", id))
		var cd := int(u.skills[id].get("cd", 0))
		var uses := int(u.skills[id].get("uses", 0))
		if cd > 0:
			label += "（冷却 %d）" % cd          # 冷却中：括号里用阿拉伯数字标剩余回合
		elif uses <= 0:
			label += "（本战已用尽）"
		_skill_submenu.add_item(label, i)
		_skill_submenu.set_item_disabled(i, not ready)
		_skill_menu_map[i] = id
		i += 1

# 在子菜单里选了某主动技能 → 进入该技能的目标选择模式
func _on_skill_chosen(id: int) -> void:
	var skill_id := str(_skill_menu_map.get(id, ""))
	if skill_id != "" and selected_unit != null:
		_enter_skill_mode(skill_id)

# 进入技能目标模式：标出范围（绿），点范围内合法目标释放。
func _enter_skill_mode(skill_id: String) -> void:
	var u = selected_unit
	var def = SkillDB.get_skill(skill_id)
	if u == null or def == null:
		return
	if not u.skill_ready(skill_id) or u.ap < int(def.get("ap_cost", 1)):
		return
	move_mode = false
	attack_mode = false
	reachable = {}
	_came_from = {}
	hover_path = []
	attack_cells = {}
	skill_mode = true
	active_skill_id = skill_id
	skill_cells = {}
	var rng := int(def.get("range", 1))
	for c in _cells_within({Vector2i(u.col, u.row): true}, rng):
		skill_cells[c] = true
	_update_overlays()

# 技能目标合法性：非敌方（己方/友方）；自己按 self_target 开关。
func _valid_skill_target(caster, def, target) -> bool:
	if target == null or def == null:
		return false
	if target == caster:
		return def.get("self_target", true)
	return not _is_hostile(caster, target)

# 释放技能到目标格（已确保格在范围内）。当前实现：治疗类（heal_pct_max_hp 按等级档 + cleanse_tags）。
func _do_skill(caster, skill_id: String, cell: Vector2i) -> void:
	var def = SkillDB.get_skill(skill_id)
	if def == null:
		return
	var target = unit_at(cell.x, cell.y)
	if not _valid_skill_target(caster, def, target):
		_clear_selection()
		return
	caster.ap -= int(def.get("ap_cost", 1))
	caster.consume_skill(skill_id, caster.skill_cooldown_max(def))
	var lines := ["%s 对 %s 使用 %s" % [_cname(caster), _cname(target), _hl(str(def.get("name", skill_id)))]]
	# 治疗：按目标最大生命百分比（取技能当前等级档）
	var heals = def.get("heal_pct_max_hp", [])
	var lvl: int = caster.skill_level(skill_id)
	if typeof(heals) == TYPE_ARRAY and heals.size() > 0:
		var idx := clampi(lvl - 1, 0, heals.size() - 1)
		var pct := float(heals[idx])
		var maxhp := int(target.effective_stat("HP_max"))
		var before := int(target.stats.get("HP", 0))
		var healed := mini(int(round(maxhp * pct / 100.0)), maxhp - before)
		target.stats["HP"] = before + maxi(0, healed)
		lines.append("　治疗 %s（最大生命%s%%）：%d → %d" % [_hl(maxi(0, healed)), _numf(pct), before, int(target.stats["HP"])])
	# 清除指定 tag 的效果（流血等）
	for tag in def.get("cleanse_tags", []):
		var n := _cleanse_effects_with_tag(target, str(tag))
		if n > 0:
			lines.append("　清除 %d 个「%s」效果" % [n, str(tag)])
	_push_log(lines)
	_clear_selection()
	_refresh_info()
	if canvas != null:
		canvas.queue_redraw()

# 在鼠标处唤出选单（紧贴光标）：只列「当前可用」的项、隐藏不可用项。
# 仅当点中的是「当前行动的可控单位」才有 攻击/移动/回合结束（且 攻击/移动 还要有预算）；
# 其它单位（非当前回合 / 敌方 / 中立）唯一能做的就是「角色状态」。
func open_context_menu() -> void:
	if _context_menu == null or selected_unit == null:
		return
	var u = selected_unit
	var controllable: bool = (u == active_unit() and _is_friendly(u))
	_context_menu.clear()
	if controllable:
		if _can_attack(u):
			_context_menu.add_item("攻击", 3)
		if _learned_active_skills(u).size() > 0 and u.ap > 0:   # 技能：插在攻击后、移动前
			_build_skill_submenu(u)
			_context_menu.add_submenu_item("技能", "SkillSubmenu")
		if _can_move(u):
			_context_menu.add_item("移动", 0)
		if u.can_fly() and u.ap > 0:                      # 起飞/降落＝动作，耗 1 AP
			_context_menu.add_item("降落" if u.is_airborne() else "起飞", 4)
	_context_menu.add_item("角色状态", 2)
	if controllable:
		_context_menu.add_item("回合结束", 1)
	_popup_context()

# 点空白地面：只在「当前可控单位的回合」弹一个只含「结束回合」的菜单
func open_ground_menu() -> void:
	if _context_menu == null:
		return
	var au = active_unit()
	if au == null or not _is_friendly(au):
		return
	_context_menu.clear()
	_context_menu.add_item("回合结束", 1)
	_popup_context()

# 在鼠标处弹出 _context_menu（紧贴光标）。坐标系随是否内嵌而不同。
func _popup_context() -> void:
	_context_menu.reset_size()
	var p := get_viewport().get_mouse_position()
	if not get_viewport().gui_embed_subwindows:
		p += Vector2(get_window().position)
	_context_menu.position = Vector2i(p)
	_context_menu.popup()

func _can_move(u) -> bool:
	return u != null and (u.move_points > 0 or u.ap > 0)

func _can_attack(u) -> bool:
	return u != null and u.ap >= int(u.basic_attack().get("ap_cost", 1))

func _is_friendly(u) -> bool:
	return u != null and u.faction in ["player", "ally"]

# 平顶 odd-q：从 c 沿方向 d（0–5）走一格
func _neighbor_in_dir(c: Vector2i, d: int) -> Vector2i:
	return HexGrid.neighbor_in_dir(c, d)

# 从 from 沿某方向直线走 length 格；返回“包含 target 的那条方向线”的格序列（找不到=[]）
func _line_cells(from: Vector2i, target: Vector2i, length: int) -> Array:
	return HexGrid.spoke_through(from, target, length)

# ============ 移动力 / 寻路 ============

func _cell_in_bounds(col: int, row: int) -> bool:
	return col >= 0 and col < width and row >= 0 and row < height

func _neighbors(col: int, row: int) -> Array:
	return HexGrid.neighbors(Vector2i(col, row))

# 单位进入该地块的移动消耗（tag 驱动）：-1 = 不可进入。
# passable_by 决定能否进（"all"/"none"/[tag…]，按单位 tag 判定）；
# cost 为基础成本，tag_cost 按单位 tag 取更优（最小）。
func _move_cost_at(col: int, row: int, unit) -> int:
	if not _cell_in_bounds(col, row):
		return -1
	var mv = _effective_move(tiles[row][col])   # 图级覆盖 ?? 全局
	var utags = unit.tags if unit != null else []
	# 通行性门槛
	var pb = mv.get("passable_by", "all")
	if typeof(pb) == TYPE_ARRAY:
		var ok := false
		for tg in pb:
			if tg in utags:
				ok = true
				break
		if not ok:
			return -1
	elif pb == "none":
		return -1
	# 成本：基础 cost，被单位 tag 的 tag_cost 取更优（最小）
	var cost := int(mv.get("cost", 1))
	var tag_cost = mv.get("tag_cost", {})
	if typeof(tag_cost) == TYPE_DICTIONARY:
		for tg in utags:
			if tag_cost.has(tg):
				cost = min(cost, int(tag_cost[tg]))
	return cost

func _occupied_by_other(col: int, row: int, self_u) -> bool:
	for u in units:
		if u != self_u and u.col == col and u.row == row:
			return true
	return false

# 本次「移动」动作的可用预算（格数）：
# 移动点>0 → 用剩余移动点；移动点=0 但有 AP → 用一次移动力（提交时才扣 AP）；否则 0。
func _move_budget(u) -> int:
	if u == null:
		return 0
	if u.move_points > 0:
		return u.move_points
	if u.ap > 0:
		return u.move_allowance()   # effective 口径（与预览范围一致）
	return 0

# Dijkstra：算 unit 在 budget 内可达的格 + 前驱树。返回 {best:{格:累计消耗,含起点0}, came_from:{格:前驱}}。
# 玩家移动范围、敌方 AI 走位共用。
func _dijkstra(unit, budget: int) -> Dictionary:
	var start := Vector2i(unit.col, unit.row)
	var best := {start: 0}
	var came := {}
	var open := [start]
	while not open.is_empty():
		var bi := 0
		for i in range(1, open.size()):
			if best[open[i]] < best[open[bi]]:
				bi = i
		var cur: Vector2i = open[bi]
		open.remove_at(bi)
		# ZOC：踏入敌对控制区即停（该格可达但不能从它继续外扩）；起点格除外
		if cur != start and _in_hostile_zoc(cur, unit):
			continue
		for nb in _neighbors(cur.x, cur.y):
			if not _cell_in_bounds(nb.x, nb.y):
				continue
			if _occupied_by_other(nb.x, nb.y, unit):
				continue
			var step := _move_cost_at(nb.x, nb.y, unit)
			if step < 0:
				continue
			var nc: int = best[cur] + step
			if nc > budget:
				continue
			if not best.has(nb) or nc < best[nb]:
				best[nb] = nc
				came[nb] = cur
				open.append(nb)
	return {"best": best, "came_from": came}

# 算 selected_unit 在 _move_budget 内可达的格 + 前驱树（供路径线重建）；再据此算极限可攻击格。
func _recompute_reachable() -> void:
	reachable = {}
	attack_cells = {}
	_came_from = {}
	var u = selected_unit
	if u != null and _is_friendly(u):
		var start := Vector2i(u.col, u.row)
		var data := _dijkstra(u, _move_budget(u))
		var best: Dictionary = data["best"]
		_came_from = data["came_from"]
		best.erase(start)
		reachable = best
		# 攻击格 = 可站立格(可达 ∪ 起点) 外扩 武器攻击距离 圈，去掉可站立格本身
		var rng := int(u.basic_attack().get("range", 1))
		var standable := {start: true}
		for c in reachable:
			standable[c] = true
		for c in _cells_within(standable, rng):
			if not standable.has(c):
				attack_cells[c] = true
	_update_overlays()

# 单位的「理论最远」移动 + 攻击范围（预览用）：以一次「移动动作」(1 AP→一批移动力) 的可达格为移动范围，
# 攻击范围 = (可达 ∪ 起点) 外扩武器攻击距离的威胁圈（= 移动 1 AP 后再攻击 1 AP 能触及处）。
func _compute_ranges(unit) -> Dictionary:
	var start := Vector2i(unit.col, unit.row)
	var data := _dijkstra(unit, unit.move_allowance())
	var best: Dictionary = data["best"]
	best.erase(start)
	var reach := best
	var rng := int(unit.basic_attack().get("range", 1))
	var standable := {start: true}
	for c in reach:
		standable[c] = true
	var atk := {}
	for c in _cells_within(standable, rng):
		if not standable.has(c):
			atk[c] = true
	return {"reach": reach, "attack": atk}

# 单位的 ZOC（控制区）= 周围一圈在界内的格
func _zoc_cells(unit) -> Dictionary:
	var d := {}
	for nb in _neighbors(unit.col, unit.row):
		if _cell_in_bounds(nb.x, nb.y):
			d[nb] = true
	return d

# ============ ZOC 机制（控制区 + 借机）============

func _zoc_key(owner, mover) -> String:
	return "%d_%d" % [owner.get_instance_id(), mover.get_instance_id()]

# cell 是否落在「敌对于 mover 的某单位」的 ZOC 内（= 与某敌对单位相邻）
func _in_hostile_zoc(cell: Vector2i, mover) -> bool:
	for u in units:
		if u != mover and _is_hostile(mover, u) and _hex_dist(cell, Vector2i(u.col, u.row)) == 1:
			return true
	return false

# 取 cell 处第一个「本 round 尚未对 mover 触发过」的敌对 ZOC 拥有者（找不到=null）
func _first_zoc_owner(cell: Vector2i, mover):
	for u in units:
		if u != mover and _is_hostile(mover, u) and _hex_dist(cell, Vector2i(u.col, u.row)) == 1:
			if not zoc_triggered.has(_zoc_key(u, mover)):
				return u
	return null

# 移动者从当前格「离开/在区内移动」前的借机判定。返回 true = 被钉住（本次移动作废）。
# 因「踏入 ZOC 即终点」，一次移动里只有起点可能在 ZOC 内，故只需在离开起点时判一次。
func _zoc_on_leave(mover) -> bool:
	var start := Vector2i(mover.col, mover.row)
	if not _in_hostile_zoc(start, mover):
		return false
	var owner = _first_zoc_owner(start, mover)
	if owner == null:
		return false   # 该格的 ZOC 拥有者本 round 都已对它触发过 → 放行
	zoc_triggered[_zoc_key(owner, mover)] = true   # 触发一次（无论命中与否，本 round 不再对它触发）
	var stopped := _resolve_aoo(owner, mover)
	_handle_deaths()
	if int(mover.stats.get("HP", 0)) <= 0:
		return true   # 移动者被借机打死，自然停下
	return stopped

# 借机（AoO）：owner 用基础攻击打 mover 一次（不耗 owner AP）。命中且未被格挡 = 钉住（返回 true）。
func _resolve_aoo(owner, mover) -> bool:
	_log_line("%s [b]借机[/b] → %s" % [_cname(owner), _cname(mover)])
	var res = _resolve_one(owner, mover, owner.basic_attack(), false)
	return bool(res.get("hit", false)) and not bool(res.get("blocked", false))

# 移动范围内、属于敌方 ZOC 的格（移动模式自动标红，提示「踏进会被控制」）
func _enemy_zoc_in_range(mover, reach: Dictionary) -> Dictionary:
	var out := {}
	for u in units:
		if u == mover or not _is_hostile(mover, u):
			continue
		for nb in _neighbors(u.col, u.row):
			var c := Vector2i(nb.x, nb.y)
			if reach.has(c):
				out[c] = true
	return out

# 组一个范围层：移动色按阵营（我方浅蓝 / 敌方浅黄），攻击色统一浅红；ZOC（仅敌方）红框标出
func _overlay(unit, reach: Dictionary, attack: Dictionary) -> Dictionary:
	var mc: Color = RANGE_MOVE_FRIENDLY if _is_friendly(unit) else RANGE_MOVE_ENEMY
	var zoc: Dictionary = {} if _is_friendly(unit) else _zoc_cells(unit)
	return {"reach": reach, "attack": attack, "zoc": zoc, "move_color": mc, "atk_color": RANGE_ATTACK}

# 重建画布要画的范围层（按当前模式 / 悬停 / Tab 状态）
func _update_overlays() -> void:
	range_overlays = []
	if skill_mode:
		# 技能范围：绿填充（复用 reach 通道 + move_color；无 attack/zoc 层）
		range_overlays.append({"reach": skill_cells, "attack": {}, "zoc": {}, "move_color": RANGE_SKILL, "atk_color": RANGE_ATTACK})
	elif attack_mode:
		range_overlays.append(_overlay(selected_unit, {}, attack_cells))
	elif move_mode:
		var ov := _overlay(selected_unit, reachable, attack_cells)
		ov["zoc"] = _enemy_zoc_in_range(selected_unit, reachable)   # 自动显示移动范围内的敌方 ZOC（无需 Tab）
		range_overlays.append(ov)
		if show_enemy_preview:
			var foe = _ai_nearest_hostile(selected_unit)   # 距离最近的敌方单位
			if foe != null and not _unit_hidden_by_fog(foe):   # 迷雾里的敌人不预览
				var r := _compute_ranges(foe)
				range_overlays.append(_overlay(foe, r["reach"], r["attack"]))
	elif hover_range_unit != null and not _animating:
		var r := _compute_ranges(hover_range_unit)
		range_overlays.append(_overlay(hover_range_unit, r["reach"], r["attack"]))
	if canvas != null:
		canvas.queue_redraw()

# 行动顺序三态（火纹式，用于地图棋子）：
#   已行动（本 round 它的 turn 已结束，idx<active_index）→ 整体压灰；
#   当前可行动（active_unit）→ 绿描边；
#   尚未行动（idx>active_index）→ 无装饰。
func _has_acted(u) -> bool:
	var idx := turn_order.find(u)
	return idx >= 0 and idx < active_index

func _is_active_unit(u) -> bool:
	return u == active_unit()

# 鼠标移到地图某格：若格上有单位则预览其移动/攻击范围（敌我皆可），离开则清除
func update_unit_hover(cell: Vector2i) -> void:
	var u = unit_at(cell.x, cell.y) if _cell_in_bounds(cell.x, cell.y) else null
	if u != null and _unit_hidden_by_fog(u):
		u = null   # 迷雾里的敌人不可被悬停预览（看不到就不知其范围）
	if u == hover_range_unit:
		return
	hover_range_unit = u
	if not move_mode and not attack_mode and not skill_mode:   # 移动/攻击/技能模式有自己的范围显示，悬停预览让位
		_update_overlays()

# 把一组格按六边形几何外扩 radius 圈（仅几何、不管通行性）；返回含原格的集合
func _cells_within(cells: Dictionary, radius: int) -> Dictionary:
	return HexGrid.ring_within(cells, radius, func(v: Vector2i) -> bool: return _cell_in_bounds(v.x, v.y))

# 进入移动模式：算范围、清路径线
func _enter_move_mode() -> void:
	if not _can_move(selected_unit):
		return
	move_mode = true
	hover_path = []
	_recompute_reachable()

# 进入攻击模式：在角色当前位置按武器 attack skill 的距离标攻击范围，点范围内敌人即攻击
func _enter_attack_mode() -> void:
	var u = selected_unit
	if not _can_attack(u):
		return
	move_mode = false
	attack_mode = true
	reachable = {}
	_came_from = {}
	hover_path = []
	attack_cells = {}
	var skill = u.basic_attack()
	var rng := int(skill.get("range", 1))
	var start := Vector2i(u.col, u.row)
	var aoe = skill.get("aoe", null)
	if typeof(aoe) == TYPE_DICTIONARY and aoe.get("shape", "") == "line":
		# 直线 AoE：标 6 方向的直线格（spoke），点哪条线就打哪条
		for d in 6:
			var cur := start
			for _i in rng:
				cur = _neighbor_in_dir(cur, d)
				if _cell_in_bounds(cur.x, cur.y):
					attack_cells[cur] = true
	else:
		for c in _cells_within({start: true}, rng):
			if c != start and _has_los(start, c):   # 视线被地形挡住的格不可攻击
				attack_cells[c] = true
	_update_overlays()

# 敌友判定：玩家/友军 为一方，敌方/中立 为另一方；跨方=敌对
func _is_hostile(a, b) -> bool:
	if a == null or b == null:
		return false
	var friendly := ["player", "ally"]
	return (a.faction in friendly) != (b.faction in friendly)

# 执行攻击：取攻方基础攻击 skill → 算命中目标（直线 AoE 按方向、可友伤）→ 扣 skill AP、逐目标判定 + 记录。
func _do_attack(attacker, cell: Vector2i) -> void:
	var skill = attacker.basic_attack()
	var targets := _attack_targets(attacker, cell, skill)
	var aoe = skill.get("aoe", null)
	# 单体且点到空格/非敌 → 取消、不耗 AP
	if targets.is_empty() and typeof(aoe) != TYPE_DICTIONARY:
		_clear_selection()
		return
	attacker.ap -= int(skill.get("ap_cost", 1))
	_resolve_attack(attacker, skill, targets)
	_handle_deaths()
	_play_attack_anim(attacker, cell, targets)   # 撞击 + 受击闪红 + 音效（cosmetic）
	_clear_selection()
	_refresh_info()
	if canvas != null:
		canvas.queue_redraw()

# 点击格 → 命中单位列表：直线 AoE 取该方向直线上的单位（友伤按 friendly_fire），否则取该格的敌对单位
func _attack_targets(attacker, cell: Vector2i, skill) -> Array:
	var out := []
	var aoe = skill.get("aoe", null)
	if typeof(aoe) == TYPE_DICTIONARY and aoe.get("shape", "") == "line":
		var cells = _line_cells(Vector2i(attacker.col, attacker.row), cell, int(aoe.get("length", 1)))
		var ff = bool(aoe.get("friendly_fire", false))
		for u in units:
			var p := Vector2i(u.col, u.row)
			if p in cells and (ff or _is_hostile(attacker, u)):
				out.append(u)
	else:
		var t = unit_at(cell.x, cell.y)
		# 只能打「看得到的」：目标在当前视野内(非迷雾) + 攻方到目标有视线
		if t != null and _is_hostile(attacker, t) \
			and _can_see_cell(cell) and _has_los(Vector2i(attacker.col, attacker.row), cell):
			out.append(t)
	return out

# 命中率（%）= clamp( (命中 − 闪避) × Π命中效能, 5, 95 )，读 effective_stat。
# Π命中效能 = 攻方命中效能(增益向) × 守方闪避效能(减免向)——无效能修正时 =1.0（与旧行为一致）。
func _hit_chance(attacker, target) -> int:
	var base: int = attacker.effective_stat("acc") - target.effective_stat("eva")
	var eff: float = attacker.eff_mult("hit_eff") * target.eff_reduce("eva_eff")
	return clampi(int(round(float(base) * eff)), 5, 95)

# 一次攻击（可多目标）：抬头「攻方 使用 技能 → 目标…」，再逐目标跑判定序
func _resolve_attack(attacker, skill, targets: Array) -> void:
	var nm := str(skill.get("name", "攻击"))
	if targets.is_empty():
		_log_line("%s 使用 [b]%s[/b]（无命中目标）" % [_cname(attacker), nm])
		return
	var names := []
	for t in targets:
		names.append(_cname(t))
	_log_line("%s 使用 [b]%s[/b] → %s" % [_cname(attacker), nm, "、".join(names)])
	var multi := targets.size() > 1
	for t in targets:
		_resolve_one(attacker, t, skill, multi)

# 对单个目标的判定序，全程读 effective_stat + 技能伤害系数；输出 = 攻击 × 系数 × 暴击 × 效能。
# 精简记录：有什么写什么——没暴击不写暴击系数、效能 100% 不写、没减伤写「无」。
# 返回 {"hit": 是否命中(未被闪避), "blocked": 是否被格挡}，供借机判定用。
func _resolve_one(attacker, target, skill, show_target := false) -> Dictionary:
	var lines := []
	if show_target:   # 多目标(AoE)才标目标名分隔；单体时抬头已含目标 → 不重复
		lines.append("→ %s" % _cname(target))
	# 命中
	var acc := int(attacker.effective_stat("acc"))
	var eva := int(target.effective_stat("eva"))
	var hc := _hit_chance(attacker, target)   # 命中公式单一来源（见 _hit_chance）
	var roll := int(randf() * 100.0)
	var hit := roll < hc
	lines.append("命中%d-闪避%d=%d%%（骰%d）" % [acc, eva, hc, roll])
	lines.append("→ %s" % _oc(hit, "已命中", "未命中"))
	if not hit:
		_spawn_hit_feedback(target, false, false, false, 0, 0)   # 飘字：未命中/闪避（看目标阵营）
		_push_log(lines)
		return {"hit": false, "blocked": false}
	# 暴击（属性吃 1 位小数：crit_rate 等可为 X.5）
	var cr := float(attacker.effective_stat_f("crit_rate"))
	var crit := randf() * 100.0 < cr
	lines.append("暴击率%s%%" % _numf(cr))
	lines.append("→ %s" % _oc(crit, "暴击", "未暴击"))
	# 伤害 = 攻击 × 系数 [× 暴击] [× 效能≠100%]
	var coeff := float(skill.get("coeff", 1.0))
	var cmult := (float(attacker.effective_stat_f("crit_dmg")) / 100.0) if crit else 1.0
	var aeff: float = attacker.eff_mult("atk_eff")   # 攻击效能桶：面板 atk_eff/100 × Π效能修正（无修正=atk_eff/100，同旧）
	var atk := float(attacker.effective_stat_f("atk"))
	var out := atk * coeff * cmult * aeff
	var formula := "攻击%s×系数%s" % [_numf(atk), _numf(coeff)]
	if crit:
		formula += "×暴击%s" % _numf(cmult)
	if aeff != 1.0:
		formula += "×效能%s%%" % _numf(aeff * 100.0)
	# 伤害补正：额外 flat 伤害，不吃效能（如撕裂/抓取的 (力量+灵巧)×0.5）
	var bonus := _skill_bonus(attacker, skill)
	if bonus > 0.0:
		out += bonus
		formula += "＋补正%s" % _numf(bonus)
	lines.append("伤害：%s=%s" % [formula, _numf(out)])
	# 格挡
	var br := float(target.effective_stat_f("block_rate"))
	var blocked := randf() * 100.0 < br
	lines.append("格挡率%s%%" % _numf(br))
	lines.append("→ %s" % _oc(blocked, "格挡", "未格挡"))
	# 全域减伤 G = max(0, 1−格挡性能/100) × 防御效能因子（下限 clamp🔒）
	var bp := float(target.effective_stat_f("block_power")) if blocked else 0.0
	# 防御效能 def_eff：base 100=中性、越高越减伤。def_factor = max(0, 2 − def_eff/100)（100→×1.0 / 120→×0.8 / ≥200→×0免疫；下限0安全）
	var deff: float = float(target.effective_stat_f("def_eff"))
	var def_factor := maxf(0.0, 2.0 - deff / 100.0)
	var g := maxf(0.0, 1.0 - bp / 100.0) * def_factor
	# 分量：普攻单分量(先进甲)；穿甲 armor_pen 拆 人/甲 两分量。element 默认物理。
	var elem := str(skill.get("element", "physical"))
	var pen := clampf(float(skill.get("armor_pen", 0.0)), 0.0, 1.0)
	var components := []
	if pen > 0.0:
		components.append({"lane": "human", "element": elem, "ratio": pen})
		components.append({"lane": "armor_first", "element": elem, "ratio": 1.0 - pen})
	else:
		components.append({"lane": "armor_first", "element": elem, "ratio": 1.0})
	# 减伤日志：有什么写什么（格挡性能 / 减伤效能≠1 / 对应元素人抗 / 甲抗(有甲时) / 穿甲）
	var reductions := []
	if bp > 0.0: reductions.append("格挡性能%s%%" % _numf(bp))
	if def_factor != 1.0: reductions.append("防御效能×%s" % _numf(def_factor))
	var rp := float(target.effective_stat_f("res_" + CombatResolver.res_suffix(elem)))
	if rp != 0.0: reductions.append("%s%s%%" % [str(ELEM_RES_CN.get(elem, "抗")), _numf(rp)])
	var ar := float(target.effective_stat_f("armor_res_" + CombatResolver.res_suffix(elem)))
	if ar != 0.0 and int(target.stats.get("armor", 0)) > 0: reductions.append("甲抗%s%%" % _numf(ar))
	if pen > 0.0: reductions.append("穿甲%s%%" % _numf(pen * 100.0))
	lines.append("减伤：%s" % ("、".join(reductions) if reductions.size() > 0 else "无"))
	# 结算落血（分量减伤链在 CombatResolver：逐分量 甲抗/人抗/固减 + 破甲溢出保留元素）
	var dres := CombatResolver.resolve(target, out, g, components)
	var hp_loss := int(round(float(dres["hp_loss"])))
	var armor_loss := int(round(float(dres["armor_loss"])))
	if armor_loss > 0:
		target.stats["armor"] = maxi(0, int(target.stats.get("armor", 0)) - armor_loss)
	if hp_loss > 0:
		target.stats["HP"] = int(target.stats.get("HP", 0)) - hp_loss
	var tail := "%s 剩余血量：%d（-%d）" % [_cname(target), int(target.stats.get("HP", 0)), hp_loss]
	if armor_loss > 0:
		tail += "，护甲 -%d" % armor_loss
	lines.append(tail)
	_spawn_hit_feedback(target, true, crit, blocked, armor_loss, hp_loss)   # 飘字：格挡 + 护甲/生命伤（暴击加粗）
	# 施加异常（如撕裂的流血）：基础概率 × (1 − 异常抵抗)，命中即挂效果
	_try_inflict(attacker, target, skill, lines)
	_push_log(lines)
	return {"hit": true, "blocked": blocked}

# 技能伤害补正（flat、不吃效能）：bonus = Σ(指定四维/属性) × mult。无则 0。
func _skill_bonus(attacker, skill) -> float:
	var b = skill.get("bonus", null)
	if typeof(b) != TYPE_DICTIONARY:
		return 0.0
	var sum := 0.0
	for s in b.get("stats", []):
		sum += attacker.effective_stat_f(str(s))
	return Unit.round1(sum * float(b.get("mult", 0.0)))

# 命中后尝试施加异常（流血等）：概率 × (1−异常抵抗)；成功则挂进 target.effects（同名刷新时长）。
func _try_inflict(attacker, target, skill, lines: Array) -> void:
	var inf = skill.get("inflict", null)
	if typeof(inf) != TYPE_DICTIONARY:
		return
	var base_ch := float(inf.get("chance", 0))
	var resist := float(target.effective_stat_f("res_status"))
	var ch := base_ch * (1.0 - resist / 100.0)
	var iroll := randf() * 100.0
	var applied := iroll < ch
	lines.append("%s %s%%（异抗%s%%→%s%%·骰%s）→ %s" % [
		str(inf.get("name", "")), _numf(base_ch), _numf(resist), _numf(ch), _numf(iroll),
		_oc(applied, "施加", "抵抗")])
	if applied:
		_add_effect(target, inf)

# 给单位挂一个效果（同名则刷新时长/数值、不叠层）。
# **buff↔modifier 桥 🔒**：若 inf 带 mods（[{stat,op,value}]），同时往 target.modifiers 挂（source="buff:名"）——
# 让"改属性的异常"（冰减速改 speed、雷麻痹改 acc/eva…）真正走修正管线（去重取高、效能等一视同仁）。
func _add_effect(target, inf: Dictionary) -> void:
	var nm := str(inf.get("name", ""))
	var source := "buff:" + nm
	_remove_mods_by_source(target, source)   # 刷新：先摘旧的同名修正，按最新重挂
	var refreshed := false
	for e in target.effects:
		if str(e.get("name", "")) == nm:
			e["duration"] = int(inf.get("duration", e.get("duration", 0)))
			e["dot_pct_max_hp"] = float(inf.get("dot_pct_max_hp", e.get("dot_pct_max_hp", 0)))
			refreshed = true
			break
	if not refreshed:
		target.effects.append({
			"name": nm,
			"kind": str(inf.get("kind", "debuff")),
			"permanent": false,
			"duration": int(inf.get("duration", 1)),
			"dot_pct_max_hp": float(inf.get("dot_pct_max_hp", 0)),
			"tags": inf.get("tags", []),   # 效果 tag（如 bleeding）：供「按 tag 驱散/清除」用
			"source": source,              # 与其挂的修正共用，便于到期/清除时按 source 摘
		})
	var touched_four := false
	for m in inf.get("mods", []):
		if typeof(m) != TYPE_DICTIONARY:
			continue
		var st := str(m.get("stat", ""))
		target.modifiers.append({"stat": st, "op": str(m.get("op", "flat")), "value": float(m.get("value", 0)), "source": source, "nature": str(inf.get("kind", "debuff"))})
		if st in ["STR", "DEX", "INT", "STA"]:
			touched_four = true
	if touched_four:
		target.recompute_derived()   # 改了四维 → 重算派生（让减速等传导到派生属性）

# 按 source 摘掉单位的修正（buff 到期/被清除时）。若摘掉的含四维修正 → 重算派生。
func _remove_mods_by_source(u, source: String) -> void:
	if u == null or typeof(u.modifiers) != TYPE_ARRAY:
		return
	var had_four := false
	var kept := []
	for m in u.modifiers:
		if str(m.get("source", "")) == source:
			if str(m.get("stat", "")) in ["STR", "DEX", "INT", "STA"]:
				had_four = true
			continue
		kept.append(m)
	u.modifiers = kept
	if had_four:
		u.recompute_derived()

# 清空单位的效果 + 所有 buff 来源的临时修正（重开/退战/换图用）；装备/特性等常驻修正保留。
func _clear_effects_and_buffs(u) -> void:
	u.effects = []
	if typeof(u.modifiers) == TYPE_ARRAY:
		u.modifiers = u.modifiers.filter(func(m): return not str(m.get("source", "")).begins_with("buff:"))
	u.recompute_derived()

# 移除单位身上所有带某 tag 的效果（如治疗清「bleeding」流血类）+ 连带摘掉它们挂的修正；返回移除条数。
func _cleanse_effects_with_tag(u, tag: String) -> int:
	if u == null or not ("effects" in u) or typeof(u.effects) != TYPE_ARRAY:
		return 0
	var kept := []
	var removed := 0
	for e in u.effects:
		if (e.get("tags", []) as Array).has(tag):
			_remove_mods_by_source(u, str(e.get("source", "buff:" + str(e.get("name", "")))))
			removed += 1
		else:
			kept.append(e)
	u.effects = kept
	return removed

# —— 战斗记录 BBCode 小工具 ——
func _hl(x) -> String:                       # 高亮加粗数字（金）
	return "[b][color=#FFD24A]%s[/color][/b]" % str(x)

func _oc(cond: bool, yes: String, no: String) -> String:  # 判定结果（绿/红）
	var col := OK_GREEN if cond else BAD_RED
	return "[b][color=%s]%s[/color][/b]" % [col, (yes if cond else no)]

# 单位名按阵营上色（我方/友方蓝、敌方红、中立黄）
func _cname(u) -> String:
	return "[b][color=#%s]%s[/color][/b]" % [faction_color(u.faction).to_html(false), u.unit_name]

# 浮点去尾巴：整数→"5"，0.85→"0.85"，8.5→"8.5"
func _numf(x) -> String:
	var f := float(x)
	if f == float(int(f)):
		return str(int(f))
	return ("%.2f" % f).rstrip("0").rstrip(".")

func _push_log(lines: Array) -> void:        # 一段（含分隔线）
	if _log == null:
		return
	for ln in lines:
		_log.append_text(ln + "\n")
	_log.append_text("[color=#5a5a5a]────────────[/color]\n")

func _log_line(text: String) -> void:        # 单行
	if _log != null:
		_log.append_text(text + "\n")

# 退出移动 / 攻击模式（保留 selected_unit）
func _exit_move_mode() -> void:
	move_mode = false
	attack_mode = false
	skill_mode = false
	active_skill_id = ""
	skill_cells = {}
	show_enemy_preview = false
	reachable = {}
	attack_cells = {}
	_came_from = {}
	hover_path = []
	_update_overlays()

# 彻底取消：清选中 + 退出移动模式
func _clear_selection() -> void:
	selected_unit = null
	_exit_move_mode()

# 鼠标移到 cell：重建从单位到该格的路径线（供画布即时绘制）
func update_hover_path(cell: Vector2i) -> void:
	hover_path = _reconstruct_path(cell)

func _reconstruct_path(cell: Vector2i) -> Array:
	if not reachable.has(cell):
		return []
	var path := [cell]
	var cur := cell
	while _came_from.has(cur):
		cur = _came_from[cur]
		path.append(cur)
	path.reverse()   # 起点 → 目标
	return path

# 提交移动：移动点=0 时把 1 点通用 AP 转成移动点（仅此刻发生），扣路径消耗后落位 + 滑动动画
func _commit_move(col: int, row: int) -> void:
	var u = selected_unit
	if u == null:
		return
	var target := Vector2i(col, row)
	if not reachable.has(target):
		return
	var cost: int = reachable[target]
	var path := _reconstruct_path(target)   # 捕获路径（_clear_selection 前）
	# 预算：移动点=0 → 花 1 AP 买一批移动力（本次移动尝试的代价）
	if u.move_points == 0:
		if u.ap <= 0:
			return
		u.ap -= 1
		u.move_points += u.move_allowance()   # effective 口径（与预览范围 _dijkstra 一致）
	# ZOC 借机：离开起点前判定（起点在敌对控制区内才触发）；命中被钉住则本次移动作废
	if _zoc_on_leave(u):
		u.move_points = 0
		_clear_selection()
		_refresh_info()
		if canvas != null:
			canvas.queue_redraw()
		return
	u.move_points -= cost
	u.col = col
	u.row = row
	_clear_selection()
	_refresh_info()
	_recompute_vision()   # 单位落位 → 重算玩家视野（友方移动揭开/关闭迷雾）
	_animate_path(u, path)   # 沿路径平移（非瞬移）；玩家不 await（即发即忘）
	if _is_friendly(u):
		_check_enter_triggers(u)   # 玩家踏入新格 → 评估 enter_region 触发器

# 沿 path（含起点的格序列）滑动单位 token；动画期间 _draw_unit 用 _anim_pos 绘制。
# 可被 await（敌方 AI 串行走位用）；玩家提交移动则不 await。
func _animate_path(u, path: Array) -> void:
	if canvas == null or path.size() < 2:
		return
	_animating = true
	_anim_unit = u
	_anim_pos = canvas.hex_center(path[0].x, path[0].y)
	var tw := create_tween()
	tw.set_trans(Tween.TRANS_LINEAR)
	for i in range(1, path.size()):
		var a: Vector2 = canvas.hex_center(path[i - 1].x, path[i - 1].y)
		var b: Vector2 = canvas.hex_center(path[i].x, path[i].y)
		tw.tween_method(_set_anim_pos, a, b, MOVE_ANIM_STEP)
	await tw.finished
	_animating = false
	_anim_unit = null
	if canvas != null:
		canvas.queue_redraw()

func _set_anim_pos(p: Vector2) -> void:
	_anim_pos = p
	if canvas != null:
		canvas.queue_redraw()

# 攻击动画：攻方棋子朝目标方向冲撞一下再退回；撞击瞬间受击方闪红 + 播放音效。
func _play_attack_anim(attacker, cell: Vector2i, targets: Array) -> void:
	if canvas == null:
		_flash_targets(targets)
		_play_sfx()
		return
	var from: Vector2 = canvas.hex_center(attacker.col, attacker.row)
	var to: Vector2 = canvas.hex_center(cell.x, cell.y)
	var dir: Vector2 = to - from
	if dir.length() < 0.001:
		_flash_targets(targets)
		_play_sfx()
		return
	var bump: Vector2 = from + dir.normalized() * 14.0
	_animating = true
	_anim_unit = attacker
	_anim_pos = from
	var tw := create_tween()
	tw.tween_method(_set_anim_pos, from, bump, 0.09).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_callback(_on_attack_impact.bind(targets))   # 撞击点：受击闪红 + 音效
	tw.tween_method(_set_anim_pos, bump, from, 0.13).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_callback(_end_attack_anim)

func _on_attack_impact(targets: Array) -> void:
	_flash_targets(targets)
	_play_sfx()

func _end_attack_anim() -> void:
	_animating = false
	_anim_unit = null
	if canvas != null:
		canvas.queue_redraw()

# 受击单位闪红：标记 + 定时清除（_draw_unit 期间把 token 画红）
func _flash_targets(targets: Array) -> void:
	if targets.is_empty():
		return
	for t in targets:
		_flash_units[t] = true
	if canvas != null:
		canvas.queue_redraw()
	if is_inside_tree():
		get_tree().create_timer(FLASH_TIME).timeout.connect(_clear_flash.bind(targets))

func _clear_flash(targets: Array) -> void:
	for t in targets:
		_flash_units.erase(t)
	if canvas != null:
		canvas.queue_redraw()

# —— 战斗飘字（浮动文字反馈）——
# 颜色对齐 token 状态条：生命=血条绿 / 护甲=护甲条银（见 SandboxCanvas._draw_hp_bar/_draw_armor_bar）。
const FLOAT_HP_COLOR := Color(0.30, 0.80, 0.30)     # 生命伤（同血条绿）
const FLOAT_ARMOR_COLOR := Color(0.82, 0.83, 0.86)  # 护甲伤（同护甲条银）
const FLOAT_MISS_COLOR := Color(0.88, 0.88, 0.92)   # 未命中 / 闪避（灰白）
const FLOAT_BLOCK_COLOR := Color(0.72, 0.85, 1.0)   # 格挡（浅蓝）

# 在目标 token 上方生成一串飘字。玩家视角措辞🔒：目标是敌方→「未命中」；目标是我方→「闪避」。
# 命中：先「格挡」（若格挡），再 护甲伤(银)、生命伤(绿)；暴击 → 该数字加粗放大。全程上浮淡出。
func _spawn_hit_feedback(target, hit: bool, crit: bool, blocked: bool, armor_loss: int, hp_loss: int) -> void:
	if canvas == null or target == null:
		return
	var entries := []   # [text, color, bold]
	if not hit:
		var friendly: bool = str(target.faction) in ["player", "ally"]
		entries.append(["闪避" if friendly else "未命中", FLOAT_MISS_COLOR, false])
	else:
		if blocked:
			entries.append(["格挡", FLOAT_BLOCK_COLOR, false])
		if armor_loss > 0:
			entries.append(["-%d" % armor_loss, FLOAT_ARMOR_COLOR, crit])
		if hp_loss > 0:
			entries.append(["-%d" % hp_loss, FLOAT_HP_COLOR, crit])
		if entries.is_empty():   # 命中但全免（0 伤、未格挡）→ 至少给个「0」反馈
			entries.append(["0", FLOAT_MISS_COLOR, false])
	# token 上方基准点：格心（世界坐标）经视图变换 → 画布屏幕坐标
	var base: Vector2 = canvas.hex_center(int(target.col), int(target.row)) * canvas.view_zoom + canvas.view_offset
	base += Vector2(0, -30)
	for i in entries.size():
		var e = entries[i]
		_float_text(base + Vector2(0, 20.0 * i), str(e[0]), e[1], bool(e[2]))

# 单条飘字：加为画布子节点（渲染在地块/token 之上），上浮 + 淡出后自毁。暴击 → 加粗放大。
func _float_text(pos: Vector2, text: String, color: Color, bold: bool) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.custom_minimum_size = Vector2(140, 0)
	lbl.size = Vector2(140, 0)
	lbl.position = pos - Vector2(70, 0)   # 140 宽居中对齐 → 视觉中心落在 pos.x
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.z_index = 200
	lbl.add_theme_font_size_override("font_size", 26 if bold else 18)
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))   # 深描边：战场上可读
	lbl.add_theme_constant_override("outline_size", 7 if bold else 5)
	if bold:   # 暴击：合成加粗（FontVariation.embolden，兼容任意底层字体）
		var basef := get_theme_font("font", "Label")
		if basef != null:
			var fv := FontVariation.new()
			fv.base_font = basef
			fv.variation_embolden = 0.7
			lbl.add_theme_font_override("font", fv)
	canvas.add_child(lbl)
	var tw := create_tween()
	tw.tween_property(lbl, "position:y", lbl.position.y - 36.0, 0.9).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(lbl, "modulate:a", 0.0, 0.9).set_delay(0.35)
	tw.tween_callback(lbl.queue_free)

func _play_sfx() -> void:
	if _sfx != null and _sfx.stream != null:
		_sfx.play()

# 加载音频：优先已导入资源，否则直读 mp3 字节（免依赖编辑器导入）
func _load_audio(path: String):
	if ResourceLoader.exists(path):
		var s = load(path)
		if s is AudioStream:
			return s
	if FileAccess.file_exists(path):
		var mp3 := AudioStreamMP3.new()
		mp3.data = FileAccess.get_file_as_bytes(path)
		return mp3
	return null

# 由前驱树 came 重建到 cell 的路径（起点 → cell，含两端）
func _path_via(came: Dictionary, cell: Vector2i) -> Array:
	var path := [cell]
	var cur := cell
	while came.has(cur):
		cur = came[cur]
		path.append(cur)
	path.reverse()
	return path

# ============ 六边形距离 / 连线（纯几何一律委托 HexGrid，见 HexGrid.gd）============
func _hex_dist(a: Vector2i, b: Vector2i) -> int:
	return HexGrid.distance(a, b)

# 两格间的连线采样（cube 插值，含端点）：LOS/寻路用。地形阻挡判定见 _has_los。
func _hex_line(a: Vector2i, b: Vector2i) -> Array:
	return HexGrid.line(a, b)

# 该格地形是否阻挡视线（读地形 blocks_sight tag；越界＝挡）
func _tile_blocks_sight(col: int, row: int) -> bool:
	if not _cell_in_bounds(col, row):
		return true
	var e = _terrain_entry(tiles[row][col])
	return e != null and ("blocks_sight" in e.get("tags", []))

# a 能否看到 b：连线上「中间格」任一 blocks_sight 即挡。终点 b 自身的 blocks_sight 不挡（看得到森林边缘的人）。
func _has_los(a: Vector2i, b: Vector2i) -> bool:
	if a == b:
		return true
	var line := _hex_line(a, b)
	for i in range(1, line.size() - 1):   # 掐头去尾：只查中间格
		var c: Vector2i = line[i]
		if _tile_blocks_sight(c.x, c.y):
			return false
	return true

# 单个单位的可见格：以己为心、半径 sight（六边形距离）、逐格被 LOS 裁剪。
func _unit_visible_cells(u) -> Dictionary:
	var out := {}
	var here := Vector2i(u.col, u.row)
	out[here] = true
	var sight: int = _effective_sight(u)   # 含天气加减 + 日夜最终乘子（夜×0.5）
	if sight <= 0:
		return out
	for cell in _cells_within({here: true}, sight):
		if _has_los(here, cell):
			out[cell] = true
	return out

# 重算玩家侧团队视野（我方/友方全体单位可见格并集）→ 更新 visible，并入 seen。位置/单位集变化后调用。
func _recompute_vision() -> void:
	_vis_visible = {}
	for u in units:
		if _is_friendly(u):
			for cell in _unit_visible_cells(u):
				_vis_visible[cell] = true
	for cell in _vis_visible:
		_vis_seen[cell] = true
	if canvas != null:
		canvas.queue_redraw()

# 某格对玩家的迷雾态：0=黑(未探索) / 1=灰(探索过·无观测) / 2=常态(可见)。全知或非战斗阶段一律常态。
func cell_fog(cell: Vector2i) -> int:
	if omniscient or phase != "battle":
		return 2
	if _vis_visible.has(cell):
		return 2
	if _vis_seen.has(cell):
		return 1
	return 0

# 玩家当前能否「看到」某格（用于 targeting：只能打可见格上的目标）
func _can_see_cell(cell: Vector2i) -> bool:
	return omniscient or phase != "battle" or _vis_visible.has(cell)

# 该单位是否被迷雾藏起（不该渲染）：战斗中、非全知、敌对且其所在格不在当前视野内。我方/友方永远可见。
func _unit_hidden_by_fog(u) -> bool:
	if omniscient or phase != "battle":
		return false
	if _is_friendly(u):
		return false
	return not _vis_visible.has(Vector2i(u.col, u.row))

# ============ 环境：日夜 + 天气（Phase 2；见 docs/感知系统.md 🔒）============
# 开战建立环境：读地图 environment 的日夜（战中不变）+ 从 weather_table 摇开场天气，挂 sight 修正。
func _setup_environment() -> void:
	_cur_time = str(_map_environment.get("time", "day"))
	_roll_weather_from_table(_map_environment.get("weather_table", []), true)
	_apply_env_modifiers()

# 从 weather_table 按 weight 摇一个天气 + 在 [min,max] 摇持续回合。表空/无效 → 晴、不自动变(_weather_left=0)。
func _roll_weather_from_table(table, announce: bool) -> void:
	if typeof(table) != TYPE_ARRAY or table.is_empty():
		_cur_weather = "clear"
		_weather_left = 0
		return
	var total := 0.0
	for row in table:
		if typeof(row) == TYPE_DICTIONARY:
			total += maxf(0.0, float(row.get("weight", 1)))
	if total <= 0.0:
		_cur_weather = "clear"
		_weather_left = 0
		return
	var pick := randf() * total
	var chosen: Dictionary = table[0]
	for row in table:
		if typeof(row) != TYPE_DICTIONARY:
			continue
		pick -= maxf(0.0, float(row.get("weight", 1)))
		if pick <= 0.0:
			chosen = row
			break
	_cur_weather = str(chosen.get("weather", "clear"))
	var lo := int(chosen.get("min_rounds", 1))
	var hi := int(chosen.get("max_rounds", lo))
	_weather_left = maxi(1, randi_range(mini(lo, hi), maxi(lo, hi)))
	if announce:
		_log_line("☁ 天气：[b]%s[/b]（%d 回合）" % [EnvDB.weather_label(_cur_weather), _weather_left])

# 进入新 round：当前天气剩余回合 −1，到期则从表摇下一个（表空→晴）。_weather_left<=0 ＝ 常驻不变（强制/无表）。
func _tick_weather() -> void:
	if _weather_left <= 0:
		return
	_weather_left -= 1
	if _weather_left <= 0:
		_roll_weather_from_table(_map_environment.get("weather_table", []), true)
		_apply_env_modifiers()   # 天气变 → 重挂 sight 修正 + 重算视野

# 应用环境到视野：天气＝flat 加减（挂修正管线 source=env:weather）；日夜＝【最终乘子】_time_sight_mult（不走 flat，见 _effective_sight）。
# 先清旧天气修正再挂新的；再刷新叠层（夜变暗 + 天气 VFX）+ 重算视野。
func _apply_env_modifiers() -> void:
	var w_mod := EnvDB.weather_sight(_cur_weather)
	for u in units:
		u.remove_modifiers_by_source("env:time")     # 清理旧版可能留下的日夜 flat（现日夜=乘子、不再挂 flat）
		u.remove_modifiers_by_source("env:weather")
		if w_mod != 0:
			u.modifiers.append({"stat": "sight", "op": "flat", "value": w_mod,
				"source": "env:weather", "source_label": "环境·" + EnvDB.weather_label(_cur_weather)})
	_time_sight_mult = EnvDB.time_sight_mult(_cur_time)   # 日夜＝所有加减之后的最终乘子（夜×0.5）
	_update_env_overlays()
	if phase == "battle":
		_recompute_vision()

# 刷新环境视觉叠层：夜晚全屏变暗滤镜（读日夜 tint）+ 天气 VFX（读 _cur_weather）。
func _update_env_overlays() -> void:
	if _night_overlay != null:
		var tint := EnvDB.time_tint(_cur_time)
		if tint != "":
			_night_overlay.color = Color.html(tint)
			_night_overlay.visible = true
		else:
			_night_overlay.visible = false
	if _weather_vfx != null:
		_weather_vfx.set_weather(_cur_weather)

# 单位当前【实际】视野半径 ＝ round( 面板 sight〔含天气/装备/技能等所有加减〕 × 日夜最终乘子 )，下限 0。
# 日夜（夜×0.5）是最后一步乘算，符合「其余都是加减、夜晚最终减半」的口径。
func _effective_sight(u) -> int:
	return maxi(0, int(round(u.effective_stat("sight") * _time_sight_mult)))
