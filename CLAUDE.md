# 项目：战棋（hex SRPG：火纹式战斗 + BB 式沙盒经营）

一个用 **Godot 4.6.2 (mono 版引擎，纯 GDScript 工程)** 做的战棋游戏：
平顶六边形战场 + 角色养成。**定位 🔒（2026-07-02）：火焰纹章式战术战斗 + 战场兄弟式沙盒经营**——大地图区域解锁 + 自由移动的长线单周目（肉鸽短局循环已放弃；保留开局身份/随机词条/随机特性池这类随机性要素）。

## 现在做到哪
- **地图编辑器**：已成型可用（地形层绘制 / 存读 / 撤销 / 平移缩放 / **区域层**〔部署区·触发区〕/ 地图库 / 地形配置外置）。
- **战斗 sandbox**：已相当完整——四维派生第一层属性、装备 + 修正管线、命中/格挡/暴击判定、ZOC+借机、敌方 AI（警觉/仇恨）、行动顺序槽、攻击动画+音效、胜负+重开、主动技能首条（战场救治）。剩各动作 AP 消耗、各兵种基础值、元素系统等待接。战斗数学（回合结构、单 AP+移动力、命中/伤害/护甲/抗性）均已敲定 🔒。详见实现现状 / 单位系统设计。
- **🟢 当前主线 ＝ 编辑器关卡创作能力**（见 [docs/编辑器合并规划.md](docs/编辑器合并规划.md)）。**定位校正 🔒：编辑器＝创作可玩关卡(authoring) / 沙盒＝自由测试场，共用底层、不并成一个。** 已落地：`MapIO` 统一读写 + 地图 v3 `units` + `Game.tscn` 双模式内存试玩 + **编辑器四图层齐**（地形 / 区域 / 单位 / 触发器，均可编辑+存盘+试玩）。**🟢 编辑器关卡创作已大致完成**（四图层〔地形/区域/单位含深编/触发器〕+ 全局/图级地形数据 + 试玩）。**✅ 战斗数值地基管线已通**（2026-07-01：eff 效能桶 + `CombatResolver` 伤害分量化减伤链 + buff↔modifier 桥；对上 spec 验算，键约定 `res_*`/`armor_res_*`/`dr_flat_*`）。**✅ 感知系统已落地**（2026-07-01）：**Phase 1**＝视野 `sight` + 视线 LOS + 三态战争迷雾 + AI 视野驱动 + 重塑 targeting/悬停；**Phase 2 环境**＝日夜 + 天气（运行时天气机 + `set_weather` 触发器 + 编辑器「环境」面板）+ **天气 VFX 视觉叠层**（`WeatherVFX`，Alenia Studios 素材·CC BY 4.0 见 [CREDITS.md](CREDITS.md)）；headless 全 PASS；见 [docs/感知系统.md](docs/感知系统.md)。**当前主线 🟢＝Meta 层**（需求 → [docs/meta层需求提炼_1.md](docs/meta层需求提炼_1.md)，架构 → [docs/meta架构规划.md](docs/meta架构规划.md)）。**✅ M1 根基已完成**（2026-07-02）：`WorldState`(campaign 聚合根+uid 计数器)/`SaveIO`(user://saves)/`ItemInstances`(物品实例化：词条/耐久载体，合成视图 `view(uid)`，`Unit.equipment` 存实例 uid)——headless 测试全 PASS。**✅ M2 WorldClock 已完成**（2026-07-02）：`WorldClock.gd` 战外时间单一源（`advance(ws,hours)` 逐小时调度表+恢复占位结算）+ 日夜映射外置（environment.json `from_hour`→`EnvDB.time_for_hour`）+ Sandbox 日夜接线（地图显式>战役时钟>昼，退战回读时钟 🔒）——headless 全 PASS。**✅ M3 EventEngine 已完成**（2026-07-02）：`EventEngine.gd` when/do 事件单一源（动作元数据注册表〔编辑器/运行时同源〕+ 宿主原语转发 + `enter_region/enter_tile/timer` 评估 + once/chance/冷却/全局间隔闸门 + fired 两层分离〔战斗局部 vs `WorldState.event_*` 持久〕）——headless 全 PASS。**✅ M4 Overworld 已完成**（2026-07-02）：`Overworld.tscn` 大地图（移动=Dijkstra+推时钟 🔒/扎营/enter_tile·timer 事件/日夜 tint/自动存档 auto 槽）+ StartMenu 战役入口（新开局/继续）+ `map_type` schema + `TerrainDB.move_cost` 单一实现——headless 全 PASS。**下一步＝M5 死门+重伤+BattleIO**；技术债见 [docs/路线图.md](docs/路线图.md)；其余候选（元素内容/子地图/感知余项）排后。

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
- [docs/标签词典.md](docs/标签词典.md) —— **tag 唯一查阅处**（阵营 / 移动型 / 地形 / 武器 / 技能 / 稀有度 / 角色身份…）。
- [docs/编辑器合并规划.md](docs/编辑器合并规划.md) —— 编辑器创作路线：已完成里程碑 + **活跃余项**（placed 单位深编 / 图级 terrain_overrides）+ 决策状态 + schema 草案。
- [docs/meta层需求提炼_1.md](docs/meta层需求提炼_1.md) —— **Meta 层需求真值 🔒**：大地图/事件/营地/人员/装备实例化/派系/对话/技能成长/魔法/死门（§1 已确认 / §2 待定勿实现 / §3 实现顺序 / §4 文档冲突清单）。
- [docs/meta架构规划.md](docs/meta架构规划.md) —— 🟡草案：为实现 meta 层的**架构整理 + 新增支持**规划（分层/持久化/前置模块/分期）。
- [docs/解耦规划.md](docs/解耦规划.md) —— Sandbox 解耦战略：✅Phase 0 HexGrid 已完成；BattleState 分期 + 硬前置清单。

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
