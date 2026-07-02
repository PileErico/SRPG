# 项目：战棋（hex SRPG：火纹式战斗 + BB 式沙盒经营）

一个用 **Godot 4.6.2 (mono 版引擎，纯 GDScript 工程)** 做的战棋游戏：
平顶六边形战场 + 角色养成。**定位 🔒（2026-07-02）：火焰纹章式战术战斗 + 战场兄弟式沙盒经营**——大地图区域解锁 + 自由移动的长线单周目（肉鸽短局循环已放弃；保留开局身份/随机词条/随机特性池这类随机性要素）。

## 现在做到哪
> 逐条实录在 [docs/实现现状.md](docs/实现现状.md)、未做项与技术债在 [docs/路线图.md](docs/路线图.md)。本段只给里程碑总览，别在此展开细节。

**✅ 已完成（截至 2026-07-02）**
- **地图编辑器**：四图层齐（地形 / 区域〔部署·触发〕/ 单位〔含深编〕/ 触发器，均可编辑+存盘+试玩）+ 全局/图级地形数据 + 地图库 + 物品编辑器。**编辑器关卡创作大致完成**。
- **战斗 sandbox**：四维派生属性、装备+修正管线、命中/格挡/暴击判定、ZOC+借机、敌方 AI（警觉/仇恨）、行动顺序槽、攻击动画+音效、胜负+重开、主动技能首条。战斗数学（回合结构·单 AP+移动力·命中/伤害/护甲/抗性）已敲定 🔒。
- **战斗数值地基**（管线已通）：eff 效能桶 + `CombatResolver` 伤害分量化减伤链 + buff↔modifier 桥。剩元素系统**内容**待填（管线就绪）。
- **感知系统 P1+P2**：视野 `sight` + LOS + 三态战争迷雾 + AI 视野驱动；日夜 + 天气 + 天气 VFX 叠层。⚠️ VFX 用 Alenia Studios 素材（CC BY 4.0），**上线前须游戏内署名** → [CREDITS.md](CREDITS.md)。
- **Meta 层 M1~M9 全部完成**：M1 持久化+物品实例化 / M2 WorldClock / M3 EventEngine / M4 Overworld 大地图 / M5 死门+BattleIO+战役战斗闭环 / M6 营地职务 / M7 地点系统 / M8 对话 / M9 派系声望。需求真值 🔒 → [docs/meta层需求提炼_1.md](docs/meta层需求提炼_1.md)。
- **Sandbox 解耦 Phase 0~4**：`HexGrid` 纯几何 + `BattleState` 战斗模型层（RefCounted，30 字段+53 规则方法+战中 suspend 快照 `to_dict/restore`）；Sandbox=视图/输入/编排宿主。战略与决策 → [docs/解耦规划.md](docs/解耦规划.md)。
- **测试基线**：14 套 headless 全 PASS（`tools/test_*.gd`）。

**🟡 待拍板 / 验收**
- **WorldSim 动态单位 v1**（框架已落地）：六项待定等验收 → [docs/大地图动态单位.md](docs/大地图动态单位.md) §4。
- **地块美术升级**（设计草案）→ [docs/地块美术升级.md](docs/地块美术升级.md)。

**🟢 下一步候选**：WorldSim/美术待定项验收、任务线内容层（主线+支线）、元素系统内容、suspend 存档 UI 接线。

## 工程结构
- 引擎：`D:\godot\Godot_v4.6.2-stable_mono_win64.exe`（带控制台的 `..._console.exe` 用于看日志/跑测试）。
- 场景流：**主场景 ＝ 开始菜单 `StartMenu.tscn`**（游戏正式入口）→「沙盒模式」`MapSelect`→`Sandbox.tscn`（`Sandbox.gd`+`SandboxCanvas.gd`+`Unit.gd`）/「地图编辑」`MapEditor.tscn`（`MapEditor.gd` 编辑器+数据）。共用：`HexCanvas.gd`（六边形画布基类）、`terrains.json`+`TerrainDB`（地形单一数据源）、`MapIO.gd`（地图读写单一入口）。
- 三个 `.bat` / VSCode 任务各跑各的场景（游戏 / Sandbox / 地图编辑器），用 `--path`+指定场景**绕过**主场景设置，故主场景设置不影响它们。

## 文档（细节都在各自文档里，别在本文件展开）
- [docs/架构.md](docs/架构.md) —— **一页地图**：场景流 / 模块职责 / 数据流 / DB 约定 / **三套坐标序** / 核心理念。**新会话先读这篇建立全局。**
- [docs/实现现状.md](docs/实现现状.md) —— **已实现**的功能、地图格式、地形表、操作、关键决策。
- [docs/路线图.md](docs/路线图.md) —— **只列没做的** + **🔧 技术债 / 重构待办**（战斗数值地基 / 巨石拆分 / 一致性）。
- [docs/单位系统设计.md](docs/单位系统设计.md) —— 单位 **属性 / tag / 回合结构 / 战斗数学** 的设计规格（已定 🔒 + 待定）。
- [docs/感知系统.md](docs/感知系统.md) —— 🟡草案：**视野 / 视线(LOS) / 三态战争迷雾 / 环境(日夜·天气)** 设计（做那轮再敲定标 🔒）。
- [docs/词条系统.md](docs/词条系统.md) —— 🟡草案：**装备词条 / 生成 roll / 重铸 / 铁匠（稀有度＝正面词条 · 状态＝负面·无·正面）** 设计（远期锻造/肉鸽那轮做；关键前置＝物品实例化）。
- [docs/情报与烹饪系统.md](docs/情报与烹饪系统.md) —— 🟡设计记录（2026-07-02）：**敌方信息解锁/图鉴 + 烹饪食物 buff**（远期实现；⚠️ 其 §3.1 三处铺垫须埋进 M5：BattleResult 击杀统计 / permanent 透传 / BattleSetup 可序列化+provisions 挂点）。
- [docs/标签词典.md](docs/标签词典.md) —— **tag 唯一查阅处**（阵营 / 移动型 / 地形 / 武器 / 技能 / 稀有度 / 角色身份…）。
- [docs/编辑器合并规划.md](docs/编辑器合并规划.md) —— 编辑器创作路线（✅ 主体完成）：定位 🔒 + 决策状态 + **前瞻 schema 草案**（effect_templates/cell_tags）。
- [docs/meta层需求提炼_1.md](docs/meta层需求提炼_1.md) —— **Meta 层需求真值 🔒**：大地图/事件/营地/人员/装备实例化/派系/对话/技能成长/魔法/死门（§1 已确认 / §2 待定勿实现 / §3 实现顺序 / §4 文档冲突〔已同步〕）。
- [docs/meta架构规划.md](docs/meta架构规划.md) —— Meta 层架构（✅ M0~M9 已实现）：留 **§1 分层图 + §6 🔒 架构决策**（uid/时间粒度/存档/战斗不耗时/沙盒边界）。
- [docs/解耦规划.md](docs/解耦规划.md) —— Sandbox 解耦战略：**✅ Phase 0~4 全部完成**（HexGrid + BattleState 模型层 + suspend 快照层）；留决策依据/护栏/后续排期。

> 旧的 `地图编辑器规划.md` 已过时、不再维护，忽略它。

## 协作约定
- **文档分工**：架构＝全局地图（约定单一源）、实现现状＝已做、路线图＝未做+技术债、单位系统设计＝设计规格、标签词典＝tag。**做完一项 → 从路线图删、在实现现状补**；架构级约定（DB 范式/坐标序/编辑器≠沙盒）只在架构.md 维护、别处引用不复述。
- 设计先讨论、敲定后写进对应文档（标 🔒 表示已锁定），再动手实现。
- 核心理念：**数据/代码分离**（如 `terrains.json`）；**tag 统一判断**（单位/地块/效果共用一张词表）；**修正是对象**（保留载体 + buff/debuff 性质）。

## 运行 / 测试
- **快捷启动**：双击 `run_game.bat`（主菜单＝游戏正式入口）/ `run_sandbox.bat`（直接进单位 sandbox）/ `run_map_editor.bat`（地图编辑器）；或 VSCode `Ctrl+Shift+B`（默认任务「运行 游戏」），「运行任务…」里还有「运行 Sandbox」「运行 地图编辑器」「打开 Godot 编辑器」。
- 命令行：开 Godot IDE 用 `..._win64.exe -e --path "D:/1战棋"`；直接跑某场景用 `..._console.exe --path "D:/1战棋" res://Sandbox.tscn`。
- **headless 自测（推荐）**：`..._console.exe --headless --path "D:/1战棋" res://<场景>.tscn --quit-after 8`——跑真实场景、必然自动退出、stderr 能看到报错。
- ⚠️ **不要写「不调 `quit()` 的 SceneTree 脚本」**：会空转不退出（CPU 飙、`Select-Object` 看不到输出），曾因此空转数小时。非要用 SceneTree 脚本就务必结尾 `quit()`；且 `add_child` 后 `_ready` 是**延迟**的、需显式初始化（如 `e._load_terrains()` / `e.new_map(...)`）。
