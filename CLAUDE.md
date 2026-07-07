# 项目：战棋（hex SRPG：火纹式战斗 + BB 式沙盒经营）

**Godot 4.6.2（mono 版引擎，纯 GDScript 工程）**；平顶六边形战场 + 角色养成。
**定位 🔒（2026-07-02）**：火焰纹章式战术战斗 + 战场兄弟式沙盒经营——大地图区域解锁 + 自由移动的长线单周目（肉鸽短局循环已放弃；保留开局身份/随机词条/随机特性池这类随机性要素）。

> **本文件＝目录与路由页**，不承载细节：状态实录/设计真值全在 docs/ 各表单，按下表跳转。**新会话先读 [docs/架构.md](docs/架构.md) 建全局。**

## 状态速览
- ✅ 已完成（逐条实录 → [docs/实现现状.md](docs/实现现状.md)）：关卡编辑器六图层 / 战斗 sandbox＋数值地基 / **属性系统重做 🔒**（种族底值＋熟练度＋抗性四轨）/ 感知 P1+P2＋程序化天气 VFX / Meta 层 M1~M9 / Sandbox 解耦 Phase 0~4 / 地块美术 P1~P3 / 角色外观模块 P0~P2。
- 🟡 待验收：WorldSim 动态单位 v1 六项待定 → [docs/大地图动态单位.md](docs/大地图动态单位.md) §4。
- 🟢 下一步候选 → [docs/路线图.md](docs/路线图.md)：技能系统执行（Phase 3＋帝国树）、任务线内容层、元素内容、suspend 存档 UI。

## 查什么去哪（文档路由）
| 要查 | 文档 |
|---|---|
| 全局架构：场景流/模块职责/DB 范式/三套坐标序/Meta 架构决策 | [docs/架构.md](docs/架构.md)（**新会话先读**）|
| **词汇🔒 / 代码符号对照 / stat·抗性键 / 战斗公式** | [docs/术语表.md](docs/术语表.md)（改词或确认代码用词→随手补）|
| tag（唯一查阅处；机器版＝data/tags.json 两处同步改） | [docs/标签词典.md](docs/标签词典.md) |
| 已实现的功能/操作/地图格式/关键决策 | [docs/实现现状.md](docs/实现现状.md) |
| 没做的 ＋ 🔧技术债 | [docs/路线图.md](docs/路线图.md) |
| 属性/成长/抗性/熟练度 真值 🔒 | [docs/属性与成长系统.md](docs/属性与成长系统.md)（§7 翻案记录 / §8 待定勿实现）|
| 战斗数学/回合结构/判定序 规格 🔒 | [docs/单位系统设计.md](docs/单位系统设计.md)（⚠️ 作废段以头部横幅为准）|
| 能力(技能条目)/效果 schema/分期执行计划 🔒 | [docs/技能与效果系统.md](docs/技能与效果系统.md) ＋ [docs/技能树_帝国士兵.md](docs/技能树_帝国士兵.md)（内容真值＋爬梯）＋ [docs/技能系统红队报告.md](docs/技能系统红队报告.md)（反例裁决）|
| Meta 层需求真值 🔒（§2 待定勿实现勿假设） | [docs/meta层需求提炼_1.md](docs/meta层需求提炼_1.md) |
| 装备词条/生成 roll/重铸/铁匠 🟡 | [docs/词条系统.md](docs/词条系统.md) |
| 敌情图鉴/烹饪 🟡 | [docs/情报与烹饪系统.md](docs/情报与烹饪系统.md) |
| 角色外观模块 🔒（P0~P2 已落地） | [docs/角色外观换装换色.md](docs/角色外观换装换色.md) |
| 大地图动态单位 🟡（六项待定） | [docs/大地图动态单位.md](docs/大地图动态单位.md) |
| 地块美术/瓦片对齐/线特征 | [docs/地块美术升级.md](docs/地块美术升级.md) |
| Sandbox 解耦战略（✅ 收官，留决策依据/护栏） | [docs/解耦规划.md](docs/解耦规划.md) |

## 工程结构
- 引擎：`D:\godot\Godot_v4.6.2-stable_mono_win64.exe`（带控制台的 `..._console.exe` 用于看日志/跑测试）。
- 场景流：**主场景＝开始菜单 `StartMenu.tscn`**（游戏正式入口）→ 沙盒（`MapSelect`→`Sandbox.tscn`）/ 地图编辑（`MapEditor.tscn`）/ 角色·物品编辑器 / 外观·地块工坊。共用底层：`HexCanvas.gd`（六边形画布基类）、`terrains.json`+`TerrainDB`（地形单一数据源）、`MapIO.gd`（地图读写单一入口）。
- 三个 `.bat` / VSCode 任务各跑各的场景，用 `--path`+指定场景**绕过**主场景设置，故主场景设置不影响它们。

## 协作约定
- **文档分工**：架构＝全局地图（约定单一源）、实现现状＝已做、路线图＝未做+技术债、术语表＝词汇/键/公式速查、标签词典＝tag。**做完一项 → 从路线图删、在实现现状补**；架构级约定（DB 范式/坐标序/编辑器≠沙盒）只在架构.md 维护、别处引用不复述。
- 设计先讨论、敲定后写进对应文档（标 🔒 表示已锁定），再动手实现。
- 核心理念：**数据/代码分离**（如 `terrains.json`）；**tag 统一判断**（单位/地块/效果共用一张词表）；**修正是对象**（保留载体 + buff/debuff 性质）。

## 运行 / 测试
- **快捷启动**：双击 `run_game.bat`（主菜单＝游戏正式入口）/ `run_sandbox.bat`（直接进单位 sandbox）/ `run_map_editor.bat`（地图编辑器）；或 VSCode `Ctrl+Shift+B`（默认任务「运行 游戏」），「运行任务…」里还有「运行 Sandbox」「运行 地图编辑器」「打开 Godot 编辑器」。
- 命令行：开 Godot IDE 用 `..._win64.exe -e --path "D:/1战棋"`；直接跑某场景用 `..._console.exe --path "D:/1战棋" res://Sandbox.tscn`。
- **测试基线**：28 套 headless（`tools/test_*.gd`），中央 runner `tools/run_tests.ps1` **须用 pwsh7 跑**（PowerShell 5 编码会崩）；通用截图 harness `tools/screenshot.gd`（窗口跑场景存 PNG，供 UI/美术目检）。
- **headless 自测（推荐）**：`..._console.exe --headless --path "D:/1战棋" res://<场景>.tscn --quit-after 8`——跑真实场景、必然自动退出、stderr 能看到报错。
- ⚠️ **不要写「不调 `quit()` 的 SceneTree 脚本」**：会空转不退出（CPU 飙、`Select-Object` 看不到输出），曾因此空转数小时。非要用 SceneTree 脚本就务必结尾 `quit()`；且 `add_child` 后 `_ready` 是**延迟**的、需显式初始化（如 `e._load_terrains()` / `e.new_map(...)`）。
