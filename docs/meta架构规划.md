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
- **M1 · 根基（需求 §3.0）**：uid 体系 🔒 → WorldState 骨架 + SaveIO + campaign 存档 v1（roster 续存 HP/重伤位 + 时钟 + flag）→ **物品实例化**（ItemInstances + Unit.equipment 改 uid + 合成视图 + 三个雷逐一排掉；词条生成/铁匠 UI 属内容、后置）。
- **M2 · WorldClock（§3.1）**：时钟本体 + 调度表；恢复/冷却数值用占位（重伤细则待 §2.3）。
- **M3 · EventEngine（§3.3）**：动作元数据注册表（先治编辑器/运行时分叉）→ 抽引擎、战斗侧四动作迁入 → when 扩 `timer/enter_tile` + 冷却/全局间隔 + fired 状态分层。
- **M4 · Overworld（§3.4）**：map_type + 新场景 + 移动/扎营 + enter_tile 事件 + 日夜随时钟。
- **M5 · 死门+重伤+BattleIO（§3.5）**：Checks 原语 → 死门插入 → BattleResult 契约 + 战后回写 roster（经验结算也挂这，需求 §1.9「经验未实现」在此闭环）。
- **M6 · 营地职务/人员轮替（§3.6）**：职务槽 + 加成载体（待定 §2.2，先框架）。
- **M7 · 地点**；**M8 · 对话**（独立可与 M3+ 并行）；**M9 · 派系声望**（数据层进 WorldState 很早就能放，遭遇消费依赖 M4）。
- **BattleState 完整版（战中 suspend）**：继续按解耦规划后置；M5 的 BattleIO 与 M1 的 uid 都是它的前置投资，做到那天成本已摊薄。

## 6. 架构决策（🔒 已拍板 2026-07-02）

1. **uid 生成规则 🔒**：存档域自增 int（`WorldState.next_uid`），unit/item 共用一个计数器（建议采纳，未见异议；uuid 无必要）。
2. **时间粒度 🔒（用户定）**：**按小时计数**——WorldClock ＝ 单调递增的小时计数器（本质是计数，非钟表模拟）。所有战外结算以「每小时」为节拍：伤口恢复＝每小时结算 X 点；营地职务（医生等）＝**改变每小时速率**而非一次性触发。日夜＝小时区间 → EnvDB time id 映射。
3. **存档 🔒（用户定）**：campaign 正常存档（槽位细节 M1 实做时定，铁人 flag 从 SaveIO 第一版留）；**战中存档＝「临时存档（suspend）」语义**——只为「退出游戏后随时继续」，**不是 SL 读档**（读取即失效/覆盖式，防 save-scum）；且**明确可裁剪**（用户：麻烦的话直接不提供）→ 依赖 BattleState、继续后置，与解耦规划对齐，meta 层不等它。
4. **战斗不消耗世界时间 🔒（用户定）**：战场日夜**冻结**——夜里进战斗全程是夜、退出后世界仍是夜；战中只有天气变（与现状代码一致：`_cur_time` 战中不变、天气机每 round tick）。含义：① 无需 round→世界时钟挂钩（round 推进两处重复的收敛降级为纯可选债）；② 退战环境复位（Sandbox.gd:360-364 硬编码 day/clear）改为**回读 WorldClock 当前 time**。
5. **sandbox 边界 🔒**：沙盒＝自由测试场**不挂** WorldState（临时实例、退出即弃），战役入口才建/载档（建议采纳，未见异议）——与「编辑器≠沙盒」同款边界。

## 7. 扫描顺手发现的既有 bug/债（做对应模块时一并还）

- 🐛 **Sandbox 存图丢字段**：`save_units_to_map` 调 `MapIO.write_map` 没传 `terrain_overrides/environment`，沙盒侧存回会抹掉这两字段（Sandbox.gd:275）——**与 M 无关、宜尽快修**。
- 🐛 **空 id 触发器 once 失效**：`tid==""` 不记 `_fired_triggers`、会重复触发（Sandbox.gd:305-308）。
- 触发器评估仅友方 `_commit_move` 一处钩子，`by_faction:"any"` 对敌方是死键（敌方 AI 走位不评估，Sandbox.gd:1224-1228）——EventEngine 时决定是否补钩。
- round 推进逻辑重复两处（见 §6.4）；`_apply_env_modifiers` 兼容清旧 `env:time` 可顺手删。
- spawn_unit 后不调 `_recompute_vision`（新单位迷雾态延迟一拍，Sandbox.gd:330-343）。
