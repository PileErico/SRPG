extends RefCounted
## BattleState：战斗模型层（纯数据 + 规则，非 Node）——解耦规划 Phase 1~3（见 docs/解耦规划.md）。
## 持有战斗领域状态（棋盘/单位/回合/视野/环境/区域/触发器/击杀账）+ 纯查询/变更方法；
## **不认识 canvas / UI / 场景树**——日志、飘字、重绘、回合编排全留宿主（Sandbox）。
## Sandbox 经同名薄访问器属性委托到这里（画布 editor.* 契约、测试直调签名零破坏）。

const Unit := preload("res://Unit.gd")
const UnitFactory := preload("res://UnitFactory.gd")
const CombatResolver := preload("res://CombatResolver.gd")
const HexGrid := preload("res://HexGrid.gd")
const TerrainDB := preload("res://TerrainDB.gd")
const WorldState := preload("res://WorldState.gd")

const DEFAULT_TERRAIN := "plain"
const DEFAULT_VARIANT := "grassland"

# —— 棋盘（地块＝战斗权威棋盘）——
var width := 15
var height := 15
var tiles := []            # tiles[row][col] = {"terrain":..,"variant":..}

# —— 单位 ——
var units := []            # 场上单位（Unit 对象列表；元素自带运行态）
var roster := []           # 可用单位池（含未布置；units ⊆ roster ∪ 地图预置）

# —— 地图原始数据（读图落入；存图/试玩透传保真）——
var _map_regions := []             # regions 原始数据：[{id,label,color,cells:[[x,y]…],kind?}]
var _map_units := []               # units 原始数据：[{proto,col,row,faction}]
var _map_triggers := []            # triggers 原始数据：[{id,label,when,do}]
var _map_terrain_overrides := {}   # 图级地形覆盖 { "terrain/variant": {move?,effects?} }
var _map_locations := []           # locations 原始数据（大地图 M7；战斗侧只透传）
var _map_environment := {}         # environment {time, weather_table:[…]}
var _map_type := "battle"          # 地图类型（overworld/battle）

# —— 区域派生（由 _map_regions 经 _setup_regions 全量重建，不入存档）——
var aggro_regions := {}      # {region_id: {Vector2i:true}}（仇恨/触发区）
var _all_region_cells := {}  # {region_id: {Vector2i:true}}（不分 kind，供触发器引用）
var _deploy_cells := {}      # 部署区格并集 {Vector2i:true}

# —— 事件 / 击杀 / 战役 ——
var _fired_triggers := {}   # 已触发 trigger id（战斗局部 once；EventEngine 经引用回写）
var _battle_kills := []     # 本战击杀记录 [{proto_id, victim_uid, faction, by_uid}]
var campaign_battle := false
var _battle_context := {}   # BattleSetup.context 透传（location_id/world_unit_uid…）

# —— 感知 / 战争迷雾（玩家侧）——
var _vis_visible := {}    # 当前可见格 {Vector2i:true}（派生：可由单位位置重算）
var _vis_seen := {}       # 曾见格 {Vector2i:true}（只增不减——唯一不可重建的历史，必存）
var omniscient := false   # 调试全知（门控 targeting/迷雾规则，属规则输入）

# —— 环境：日夜 + 天气（战斗级状态）——
var _cur_time := "day"
var _cur_weather := "clear"
var _weather_left := 0       # 当前天气剩余回合（<=0 ＝ 不自动变）
var _time_sight_mult := 1.0  # 日夜视野最终乘子（由 _cur_time 派生，随存无害——恢复时宿主仍应重挂环境）

# —— 回合（round/turn 双层）——
var round_num := 1
var turn_order := []       # 本 round 出手序列（Unit 引用）
var active_index := 0
var zoc_triggered := {}    # 本 round「拥有者→移动者」借机去重（key=instance_id 对）

# —— 阶段 / 胜负 ——
var phase := "deploy"      # deploy=布置 / battle=战斗
var battle_over := false
