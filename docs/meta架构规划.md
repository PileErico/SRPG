# Meta 层架构规划（🟡 草案，待讨论敲定后逐项标 🔒）

> 输入：[meta层需求提炼_1.md](meta层需求提炼_1.md)（需求真值 🔒）。本篇回答「**为实现它，代码架构怎么整理 + 要新增哪些支持**」——先架构后功能。
> 现状事实依据：2026-07-02 六面代码扫描（物品实例化冲击面 / 时间环境 / 触发器 / 技能成长 / 死门插入 / 文档矛盾），全部结论带 file:line 证据。
> 关联：[解耦规划.md](解耦规划.md)（BattleState 分期与硬前置）、[词条系统.md](词条系统.md)（词条细则）、[架构.md](架构.md)（既有一页地图）。

## 1. 目标分层（一张图）

```
┌─ Campaign 层（全部新增，纯数据 RefCounted，可序列化）─────────────┐
│ WorldState：时钟 / roster(带 uid) / 物品实例库 / 声望 / 任务·事件状态 │
│            / 据点状态 / 世界 flag                                  │
└──────────────┬────────────────────────┬──────────────────────────┘
        BattleSetup ↓            ↑ BattleResult        （= BattleIO 契约）
┌─ 场景层 ─────┴────────────────────────┴──────────────────────────┐
│ Overworld.tscn（新）：大地图移动/扎营/enter_tile 事件                │
│ Sandbox.tscn（已有）：战斗；沙盒模式继续＝自由测试场、不挂 WorldState  │
│ 营地/城镇 UI（后期）：职务指派 / 铁匠 / 招募                         │
└──────────────┬───────────────────────────────────────────────────┘
┌─ 共用前置（DB 范式：RefCounted+static，无 class_name）──────────────┐
│ 已有：HexGrid/HexCanvas/MapIO/TerrainDB/ItemDB/SkillDB/TagDB/EnvDB │
│      /UnitFactory/CombatResolver/StatMeta/TextureCache/ItemTooltip │
│ 新增：WorldClock / EventEngine / ItemInstances / Checks / SaveIO   │
│      / DialogueUI（独立）                                          │
└───────────────────────────────────────────────────────────────────┘
```

核心原则不变：数据/代码分离、tag 统一判断、修正是对象、编辑器≠沙盒。**新增一条：Campaign 数据（WorldState）不认识任何场景节点**——场景是它的消费者/编辑器，这与 BattleState 的解耦哲学同构。

## 2. 根依赖：持久化分两层 + uid 体系（需求 §3.0 的架构化）

**关键判断：campaign 存档 ≠ 战中 suspend 存档，两层分开、前者先行。**

- **A 层 · campaign 存档（M1 就做）**：战斗外世界的全部状态——WorldState 整体 `to_dict/from_dict` → `user://saves/`。单位在此层只需「**定义+养成+跨战续存**」：proto（已有 UnitFactory 往返）⊕ 当前 HP、重伤状态、装备实例 uid 引用。**不含**战斗内运行态（AP/位置/buff/迷雾），故**完全不依赖 BattleState**。
- **B 层 · battle suspend（后置，🔒 语义已定）**：**「临时存档」**——只为退出游戏后随时继续、非 SL 读档（读取即失效/覆盖式）；**可裁剪**（用户明确：麻烦就不提供）。才需要完整 BattleState（解耦规划 Phase 1+，硬前置见该文档 §3）。meta 层一切功能不等它。
- **uid 体系（写第一行存档前必须定 🔒）**：`unit_uid` + `item_uid` 一起定。扫描确认 Unit 无 id 字段（Unit.gd:13-41），turn_order/回写全靠对象引用。建议：**存档域自增 int + WorldState 持有 next_uid 计数器**（简单、可读、无碰撞；uuid 无必要）。同一套 uid 将来直接喂 BattleState，一次投资两层受益。
- **存档兼容套路沿用地图 v3 范式**：`save_version` + 读端 `.get(key,default)` 兜底。

## 3. 新增前置模块（共 6 个，均为小而专的单一源）

| 模块 | 职责 | 关键设计点（来自扫描事实） |
|---|---|---|
| **WorldState** | campaign 数据聚合根：clock/roster/物品实例/声望/事件状态/flag + to_dict/from_dict | 纯 RefCounted；SandboxConfig 静态模式是跨场景通道先例（SandboxConfig.gd:4），WorldState 照此挂静态引用 |
| **SaveIO** | 存读档单一入口（仿 MapIO）：槽位管理/版本兜底/原子写 | UnitFactory 的 user:// JSON 落盘手法已验证可用 |
| **ItemInstances** | 物品实例库：`uid → {tpl_id, affixes[], durability, condition, enhance_count}` + **合成视图 `view(uid)` = 模板 ⊕ 词条 ⊕ 状态**（喂 tooltip/攻击/资格判定） | ItemDB 降为纯模板源。⚠️ 三个雷（扫描确认）：① `ItemDB.get_item` 返回共享引用（ItemDB.gd:32-38），合成视图必须 duplicate；② `Unit.equipment` 现存 id 字符串、双手靠**字符串相等**找连带槽（Unit.gd:248-264）——改存 uid 后按 uid 配对；③ 修正 source 现为 `equip:<槽>`（Unit.gd:243），同 source 同 (stat,op) 会**去重取高**（Unit.gd:112-132）吃掉多词条——source 改 `equip:<uid>`、词条各带序号 |
| **WorldClock** | 战斗外时间 🔒＝**单调小时计数器**：推进规则/小时→日夜映射/**调度表**（恢复·事件冷却·据点刷新按「每小时」节拍结算，职务加成＝改每小时速率） | 战外时间概念现为零（全仓 grep 确认）；日夜复用 EnvDB times（有序数组、加时段免改消费端）；战斗侧注入点＝`_setup_environment`（Sandbox.gd:2537，time 现从地图静态读，需定优先级：地图指定 > 时钟推导）；**战斗不耗世界时间 🔒**（战场日夜冻结、仅天气变——与现状一致）；退战复位 day/clear 硬编码（Sandbox.gd:360-364）改回读时钟 |
| **EventEngine** | 统一 when/do 事件引擎：战斗触发器与大地图事件共用一套评估/执行，宿主能力（日志/造单位/变天/开对话）经**注入接口** | 现状契约：when 仅 `enter_region`+once+by_faction+region；do 四动作内联在 Sandbox（Sandbox.gd:314-343，耦合 _log/units/turn_order/canvas）。⚠️ 编辑器动作表与运行时已分叉（set_weather 只有运行时）——动作**元数据注册表**单一源化，编辑器表单据此生成。fired/冷却状态分两层：战斗局部（每战清零，现状）vs 世界持久（进 WorldState） |
| **Checks** | 属性检定原语 `check(attr, dc)`（1d20+属性 vs 难度） | 全仓无检定函数、4 处判定各写 `randf()*100<X`（Sandbox.gd:2027/2037/2059/2123）——死门首用，大地图/营地事件复用；顺势可把 4 处内联掷骰收敛（可选） |
| **DialogueUI** | 通用对话模块（立绘+文本+选项），数据外置 json | 独立性强可并行；战场内触发＝EventEngine 加 `do: dialogue` 动作即接上（唯一接口成本，需求 §1.8 已识别） |

## 4. 既有系统的改造点（按模块，全部有 file:line 锚点）

- **Unit / UnitFactory**：加 `uid`；加 `skill_points/attr_points` 资源字段与 `gain_exp/level_up`（Unit.gd:36-38 现为裸变量、level 不影响任何数值）；**学习门槛分层**——`learn_skill` 现零校验且被 UnitFactory 反序列化+DeployPanel 直灌复用（Unit.gd:335-344, UnitFactory.gd:41-49），引入技能点时须拆「结算式学习（校验+扣点）」vs「直灌（存档/编辑器）」两条 API，别把门槛塞进 learn_skill 破坏灌装路径；proto 往返补 `exp_max`（现有序列化缺口，UnitFactory.gd:90-91）。
- **SkillDB**：加 `by_tree` 索引；⚠️ `_by_seq` 是**全局命名空间**（SkillDB.gd:25-30），多树 seq 会互相覆盖——改 `(tree,seq)` 复合键或限定 common。skills.json 加 `tier/prereq/cost` 字段（tree 字段已预埋零消费）。
- **死门（战斗层唯一新增）**：裁决点＝`_handle_deaths` 的 HP<=0 收集循环（Sandbox.gd:1246-1250，三个伤害源汇于此）+ 唯一旁路 `_zoc_on_leave`（Sandbox.gd:1837 直读 HP<=0）。死门态载体＝**tag（铁律：tag 统一判断）+ permanent effect 挂 eva/def_eff 的 pct −50**（修正管线现成，Sandbox.gd:2134-2164；唯 `_add_effect` 写死 `permanent:false` 需透传）。跳过 turn 仿「AI 未激活即 end_turn」样式（Sandbox.gd:1108-1121）；**`_check_battle_over` 的死门计数口径需定**（死门友方算不算存活——否则全员死门战斗不结束，Sandbox.gd:1288）；HP 现可为负无 clamp（Sandbox.gd:2092-2094），死门需定负血语义。
- **BattleIO（战斗进出契约，= BattleState 的先导缝）**：`BattleSetup`（出战名单+装备实例注入——roster 单位现按**引用**直接参战，Sandbox.gd:439-459）；`BattleResult` 收集点＝`_end_battle`（Sandbox.gd:1303，此刻幸存者/round/roster 全可得），**必须赶在 `exit_battle` 的 `init_vitals` 回满之前**（Sandbox.gd:1353——现状等于「时间倒流」，战损即刻蒸发）；击杀归属/经验需在 `_resolve_one/_handle_deaths` 加记录点（现死者 erase 即丢）。
- **MapIO / 地图 schema**：加 `map_type`（overworld/battle，缺省 battle 兼容旧图）；沿用「加字段+读端兜底」。
- **Overworld.tscn（新场景）**：复用 HexGrid/HexCanvas（画布基类不动）+ MapIO；移动=时钟推进；enter_tile 钩子挂 EventEngine。建议独立场景而非塞进 Game 双模式（编辑↔试玩已两模式，再塞第三种职责就混了）。

## 5. 分期路线（依赖驱动，对齐需求 §3；每期可停、headless 回归）

- **✅ M0 · 文档同步**（2026-07-02）：§4 四项 + 扫描发现的第 3 处陈旧（实现现状 412/414、路线图 91）全部改写。
- **✅ M1 · 根基（需求 §3.0，2026-07-02 完成）**：uid 体系 🔒 → WorldState 骨架 + SaveIO + campaign 存档 v1（roster 续存 HP + 时钟 + flag/声望/ironman）→ **物品实例化**（ItemInstances + Unit.equipment 改 uid + 合成视图 + **三个雷全部排掉**；`equip(模板id)` 保留为造新实例的兼容入口→原型/预设/沙盒零改动）。headless：`test_worldstate` + `test_iteminstances`（含 campaign 带词条全链往返）全 PASS。**剩**：词条生成 roll/铁匠 UI（内容层）、耐久消耗钩子（M2/M5）、重伤位字段（M5 定细则时加，schema 兼容免改档）。
- **✅ M2 · WorldClock（§3.1，2026-07-02 完成）**：`WorldClock.gd`（`advance(ws,hours)` 逐小时调度、显式收档不碰 current + 计数换算）+ 调度表首项＝恢复结算（占位速率，重伤细则待 §2.3；HP≤0 不回待 M5）+ 日夜映射数据外置（environment.json times 加 `from_hour` + `EnvDB.time_for_hour`，消费端零改动）+ Sandbox 两注入点接线（`_setup_environment` 优先级＝地图显式>战役时钟>昼；`_enter_deploy` 退战回读时钟——§6.4 的硬编码复位已清）。headless `test_worldclock` 全 PASS。推进入口（大地图移动/扎营）＝M4。
- **✅ M3 · EventEngine（§3.3，2026-07-02 完成）**：`EventEngine.gd`＝①动作元数据注册表（运行时/编辑器同源，set_weather 分叉已治，MapEditor 表单改数据驱动控件工厂）②执行（参数解析→宿主原语 `event_*` 鸭子转发+守卫）③评估（enter_region 迁入 + enter_tile〔任意/定点格+chance〕+ timer〔every_hours 节拍〕）+ 闸门（once 缺省按事件类型/chance/cooldown_hours/global_gap 占位 24h）。fired 分层落地：战斗局部 `_fired_triggers`（ws=null 无冷却）vs 世界持久 `WorldState.event_*` 四字段（随档落盘）。顺手还债：AI 走位补评估钩（by_faction:any 死键）+ spawn 补 `_recompute_vision`。headless `test_eventengine` 全 PASS。
- **✅ M4 · Overworld（§3.4，2026-07-02 完成）**：`map_type` schema（缺省 battle 兼容，MapEditor/Sandbox 透传保真）+ `Overworld.tscn` 新场景（独立场景、未塞 Game 双模式——按本规划建议）+ 移动=Dijkstra+逐格推时钟（`TerrainDB.move_cost` 单一实现，Sandbox 同用）+ 扎营 + enter_tile/timer 事件（世界持久层）+ 日夜随时钟（tint 叠层）+ StartMenu 战役入口（start_new/续 auto 档）+ `WorldState.party_*`。默认大地图 `maps/overworld/world.json`（生成器 `tools/gen_overworld_map.gd`）。headless `test_overworld` 全 PASS。**剩**：区域解锁、进出战斗（=M5 BattleIO）、编辑器 overworld 支持。
- **✅ M5 · 死门+重伤+BattleIO（§3.5，2026-07-02 完成）**：`Checks.gd` d20 原语 → 死门插入（`_handle_deaths` 收集循环三分支：门内挺着/转门/收尸；`_zoc_on_leave` 旁路天然兼容；`_begin_active_turn` 检定跳过 call_deferred 断递归；`_resolve_one` 命中 −1；`_check_battle_over` 口径＝死门算存活；`_add_effect` permanent 已透传）→ `BattleIO.gd` 快照进/结果出（M1 记的双所有权账已清：exit_battle 回满只影响副本）+ 战后回写（HP/经验/`injured_until` 占位 48h/铁人真死/`ws.kill_stats`）→ 战役战斗闭环（start_battle 动作→全员出战→结算→回大地图）。**三处远期铺垫全落地**（[情报与烹饪系统.md](情报与烹饪系统.md) §3.1）：①击杀统计共用记录点 ②permanent 透传 ③BattleSetup 可序列化+provisions。M1 记的读档技能 uses 账：战斗走快照副本+开战 reset_skill_charges 重算，实际无恙。headless `test_battleio` 全 PASS。⚠️ M1 审查记下的两笔账在此清：① **双所有权**——同一 Unit 可同时在 Sandbox.roster 与 WorldState.roster，沙盒 `exit_battle` 的 `init_vitals` 回满会抹 campaign 战损，战役战斗接入时必须定「谁拥有单位、何时回写」（BattleIO 正是这个契约）；② campaign 读档路径技能 uses 按无装备 INT 初始化（战斗开局 `reset_skill_charges` 会重算，仅战前面板显示可能偏差）。
- **✅ M6 · 营地职务框架（§3.6，2026-07-02 完成）**：`jobs.json`+`JobDB`（职务单一源）+ `WorldState.camp_jobs`/`job_holder`（在岗校验含重伤排除）+ Overworld 指派面板（一人一职）。加成载体按 §6.2 🔒＝改每小时速率——医生首个接入（`WorldClock._settle_recovery` ×2 占位）；其余职务 planned 待各自系统（厨师=烹饪/工匠=耐久/警卫=遭遇/情报官=图鉴）。headless `test_campjobs` 全 PASS。**人员轮替语义**（重伤驱动）已天然成立：重伤者自动不在岗。
- **✅ M7 · 地点（§3.7，2026-07-02 完成）**：定义/实例/状态三层分开——`data/locations.json`+`LocationDB`（类型：城/村=服务集合、遗迹/据点=`site`+`respawn_hours`；服务注册表 rest=in_use、trade/recruit/smith=planned）/ 地图 `locations` 字段（MapIO 新键，MapEditor/Sandbox 透传保真同 map_type 待遇）/ `WorldState.location_cleared_at`+`gold`（开局 200 占位）。据点刷新＝**惰性判定**（`site_ready` 读时算，不占 WorldClock 调度）。讨伐闭环长在 M5 契约上：`BattleSetup.context{location_id}` → Sandbox 透传 → `apply_result` 战胜落肃清账。Overworld：旗帜标记（肃清灰显）+ 抵达/原地点击进地点面板（休整=扣钱推钟回满 HP；planned 服务灰显；据点=进攻）。headless `test_locations` 全 PASS。**剩**：交易/招募/铁匠内容（待经济/招募池/词条轮）、据点专属战斗地图、编辑器地点层。
- **✅ M8 · 对话（§3.8，2026-07-02 完成）**：`data/dialogues.json`+`DialogueDB`（node 图：无 choices=纯演出/choices=分支，效果 set_flags+rep）+ `DialogueUI`（播放核心与 UI 分离——start/advance/choose 纯逻辑 headless 可测；UI=全屏模态+两侧立绘〔说话方亮/另侧记忆变暗〕+文本+选项；无档效果跳过）。接入=EventEngine 注册表 `dialogue` 动作 → 宿主原语 `event_dialogue`——**三触发场景齐**：大地图事件（`_travel` 暂停 await 播完）/ 地点面板「交谈」/ **战场内**（Sandbox，需求预判的唯一接口成本＝一个原语）。rep 效果即 M9 声望的现成写口。headless `test_dialogue` 全 PASS。**剩**：选项条件门（按 flag/声望显隐）、对话内发起战斗/给物品动作、立绘排版打磨。
- **✅ M9 · 派系声望（§3.9，2026-07-02 完成）**：`data/factions.json`+`FactionDB`＝声望唯一读写口（`rep_of` start_rep 读端兜底 / `add_rep` ±100 钳制 / `hostile` 阈值判定；数值存 `ws.reputation`、WorldState 纯存储不识派系）。敌对遭伏＝敌对派系转 enter_tile 伪触发器喂 EventEngine（tid 稳定、冷却随档——零新评估机制）。动作 `add_rep`/`set_flag` 进注册表（§1.2 do 清单闭合），Overworld+Sandbox 双宿主。声望面板只读。headless `test_factions` 全 PASS。**meta 主线 M0~M9 全部完成**；剩＝任务线结构（内容层）/战胜遭伏声望后果/派系间关系矩阵（后者见 [大地图动态单位.md](大地图动态单位.md) §4）。
- **➕ WorldSim 动态单位（🟡 v1 框架，2026-07-02，用户想法即日落地）**：商队/巡逻/兽群/游团随「玩家移动=世界回合」活动，敌对追击→BattleSetup.context 闭环——设计与六项待定见 [大地图动态单位.md](大地图动态单位.md)。
- **BattleState 完整版（战中 suspend）**：继续按解耦规划后置；M5 的 BattleIO 与 M1 的 uid 都是它的前置投资，做到那天成本已摊薄。

## 6. 架构决策（🔒 已拍板 2026-07-02）

1. **uid 生成规则 🔒**：存档域自增 int（`WorldState.next_uid`），unit/item 共用一个计数器（建议采纳，未见异议；uuid 无必要）。
2. **时间粒度 🔒（用户定）**：**按小时计数**——WorldClock ＝ 单调递增的小时计数器（本质是计数，非钟表模拟）。所有战外结算以「每小时」为节拍：伤口恢复＝每小时结算 X 点；营地职务（医生等）＝**改变每小时速率**而非一次性触发。日夜＝小时区间 → EnvDB time id 映射。
3. **存档 🔒（用户定）**：campaign 正常存档（槽位细节 M1 实做时定，铁人 flag 从 SaveIO 第一版留）；**战中存档＝「临时存档（suspend）」语义**——只为「退出游戏后随时继续」，**不是 SL 读档**（读取即失效/覆盖式，防 save-scum）；且**明确可裁剪**（用户：麻烦的话直接不提供）→ 依赖 BattleState、继续后置，与解耦规划对齐，meta 层不等它。
4. **战斗不消耗世界时间 🔒（用户定）**：战场日夜**冻结**——夜里进战斗全程是夜、退出后世界仍是夜；战中只有天气变（与现状代码一致：`_cur_time` 战中不变、天气机每 round tick）。含义：① 无需 round→世界时钟挂钩（round 推进两处重复的收敛降级为纯可选债）；② 退战环境复位（Sandbox.gd:360-364 硬编码 day/clear）改为**回读 WorldClock 当前 time**。
5. **sandbox 边界 🔒**：沙盒＝自由测试场**不挂** WorldState（临时实例、退出即弃），战役入口才建/载档（建议采纳，未见异议）——与「编辑器≠沙盒」同款边界。

## 7. 扫描顺手发现的既有 bug/债（做对应模块时一并还）

- ✅ ~~Sandbox 存图丢字段~~ / ✅ ~~空 id 触发器 once 失效~~（均已修，2026-07-02 提交 `7941bec`——外部复审曾误报前者仍在，实为本条记录未更新）。
- ✅ ~~触发器评估仅友方 `_commit_move` 一处钩子，`by_faction:"any"` 对敌方是死键~~（M3 已修：AI 走位落位后补评估钩）。
- round 推进逻辑重复两处（见 §6.4）；`_apply_env_modifiers` 兼容清旧 `env:time` 可顺手删。
- ✅ ~~spawn_unit 后不调 `_recompute_vision`（新单位迷雾态延迟一拍）~~（M3 已修：`event_spawn_unit` 战中即时重算）。
