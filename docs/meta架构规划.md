# Meta 层架构规划（✅ M0~M9 已实现，留架构决策依据）

> 输入：[meta层需求提炼_1.md](meta层需求提炼_1.md)（需求真值 🔒）。本篇原为「为实现需求，代码架构怎么整理」的规划——**M0~M9 已全部落地**（实录见 [实现现状.md](实现现状.md)「Meta 层」）。现保留 **§1 分层图 + §6 🔒 架构决策**作为长期依据；分期路线（§5）已收敛为一行指针。
> 关联：[解耦规划.md](解耦规划.md)、[词条系统.md](词条系统.md)、[架构.md](架构.md)。

## 1. 目标分层（一张图，✅ 已实现）

```
┌─ Campaign 层（纯数据 RefCounted，可序列化）───────────────────────┐
│ WorldState：时钟 / roster(带 uid) / 物品实例库 / 声望 / 事件状态    │
│            / 据点状态 / 世界 flag                                  │
└──────────────┬────────────────────────┬──────────────────────────┘
        BattleSetup ↓            ↑ BattleResult        （= BattleIO 契约）
┌─ 场景层 ─────┴────────────────────────┴──────────────────────────┐
│ Overworld.tscn：大地图移动/扎营/enter_tile 事件                    │
│ Sandbox.tscn：战斗；沙盒模式=自由测试场、不挂 WorldState            │
│ 营地/城镇 UI：职务指派 / 地点服务                                  │
└──────────────┬───────────────────────────────────────────────────┘
┌─ 共用前置（DB 范式：RefCounted+static，无 class_name）──────────────┐
│ HexGrid/HexCanvas/MapIO/TerrainDB/ItemDB/SkillDB/TagDB/EnvDB       │
│ /UnitFactory/CombatResolver/BattleState/StatMeta/TextureCache      │
│ /WorldClock/EventEngine/ItemInstances/Checks/SaveIO/DialogueUI     │
│ /JobDB/LocationDB/DialogueDB/FactionDB/WorldUnitDB+WorldSim         │
└───────────────────────────────────────────────────────────────────┘
```

核心原则：数据/代码分离、tag 统一判断、修正是对象、编辑器≠沙盒。**加一条：Campaign 数据（WorldState）不认识任何场景节点**——场景是它的消费者，与 BattleState 的解耦哲学同构。各模块职责详情见 [架构.md](架构.md)「Campaign 层」。

## 5. 分期路线（✅ M0~M9 + WorldSim v1 全部完成）

M0 文档同步 → M1 持久化+物品实例化 → M2 WorldClock → M3 EventEngine → M4 Overworld → M5 死门+BattleIO → M6 营地职务 → M7 地点 → M8 对话 → M9 派系声望 → ➕ WorldSim 动态单位 v1。**逐里程碑实录（含每步 headless 回归）见 [实现现状.md](实现现状.md)「Meta 层」**；剩余内容层与待定项见 [路线图.md](路线图.md)「Meta 层内容层」。**BattleState 完整版（战中 suspend）**：M1 的 uid + M5 的 BattleIO 是其前置投资，✅ 解耦 Phase 0~4 已完成（[解耦规划.md](解耦规划.md)）。

## 6. 架构决策（🔒 已拍板 2026-07-02）

1. **uid 生成规则 🔒**：存档域自增 int（`WorldState.next_uid`），unit/item 共用一个计数器（uuid 无必要）。
2. **时间粒度 🔒**：**按小时计数**——WorldClock ＝单调递增的小时计数器（本质是计数，非钟表模拟）。战外结算以「每小时」为节拍：伤口恢复＝每小时结算 X 点；营地职务（医生等）＝**改变每小时速率**而非一次性触发。日夜＝小时区间 → EnvDB time id 映射。
3. **存档 🔒**：campaign 正常存档（铁人 flag 从 SaveIO 第一版留）；**战中存档＝「临时存档（suspend）」语义**——只为「退出后随时继续」，**不是 SL 读档**（读取即失效/覆盖式，防 save-scum）；**明确可裁剪**（麻烦就不提供）→ 依赖 BattleState、meta 层不等它。
4. **战斗不消耗世界时间 🔒**：战场日夜**冻结**——夜里进战斗全程是夜、退出后世界仍是夜；战中只有天气变。含义：① 无需 round→世界时钟挂钩；② 退战环境复位改为**回读 WorldClock 当前 time**。
5. **sandbox 边界 🔒**：沙盒＝自由测试场**不挂** WorldState（临时实例、退出即弃），战役入口才建/载档——与「编辑器≠沙盒」同款边界。

> §2 持久化分两层、§3 六个新增前置模块的设计点、§4 既有系统改造点（均带 file:line 锚点）、§7 扫描发现的 bug——都是「实现前的分析」，已随 M1~M9 落地固化到代码与 [实现现状.md](实现现状.md)，此处不再展开。
