# 模块：UI 交互（地图视图外壳 · 悬停信息 · 底边栏 · HUD 分层）

> 常驻·模块文档。上半=✅已实现，下半=🟡规划；开发＝把下半搬进上半。架构决策 🔒（2026-07-07）。

范围：**hex 地图视图的通用 UI 外壳**（底边栏 / 悬停信息弹窗 / 未来 tooltip）+ **UI 分层约定**（通用外壳共享、专属 HUD 分开）+ 宿主契约（`hover_text` / `hover_extra` / `hover_changed`）。边界：战斗专属 HUD（行动顺序 / AP / 战斗记录 / 部署）内容→[模块_战斗.md](模块_战斗.md)；大地图专属 HUD（时钟 / 队伍 / 地点 / 派系）→[模块_大地图.md](模块_大地图.md)；画布渲染 / 地形数据 / 天气 VFX→[模块_地图美术.md](模块_地图美术.md)；角色状态卡（缩放 / tab / 技艺树）→[模块_属性成长.md](模块_属性成长.md)；三套坐标序·画布契约护栏→[架构.md](架构.md)（不复述）。

## ✅ 已实现

### 分层架构 🔒（合通用、分专属）
- **不是「合一 vs 全分」二选一，而是分层**：`Sandbox`（战斗）与 `Overworld`（大地图）**已共享 `hover_text(col,row)` 契约**（`HexCanvas` 靠它给两边读地块）→ 通用外壳天然该合；但两者 HUD 内容**几乎零重叠** → 专属该分。
- **第 1 层 通用外壳（共享）**：任何 hex 地图视图都要的外壳，一处实现、多处复用（`HexCanvas` + `MapInfoBar` 等，不属任何单一场景）。
- **第 2 层 专属 HUD（分开）**：每宿主自 build / own——战斗＝`TurnOrderBar`/回合·AP·战斗记录/`DeployPanel`；大地图＝时钟·日期/队伍/地点面板/派系。
- **命名**：共享层 `Map*` / 通用名；专属层 `Battle*` / `Overworld*` 前缀。

### 数据流原则 🔒（数据 ⟂ 呈现）
- **UI 组件自决布局**，只暴露 `set_*` / 读契约方法；**不自己抓/算数据**。
- 数据可分散：底边栏的**地块**来自 `HexCanvas`（悬停），**提示**来自宿主——UI 只此一处排版、两处数据各自注入。
- 反例（已纠正）：曾把底边栏塞进 `HexCanvas` 并注入提示串 = 把 UI 耦合进数据源；改为**独立组件 + 信号读取**。

### UI 同比缩放 🔒（1080p 基准，2026-07-07）
- **决策**：全 UI 以 **1080p（1920×1080）为设计基准**，随视口等比缩放（更大/更小分辨率同比放缩、夹在 [0.55, 1.5]）。**地图排除**——玩家有独立的手动地图缩放（按喜好自适应），无需自动缩。
- **不用引擎全局 stretch**（`canvas_items`）：它会连六边形战场瓦片一起缩、毁像素密度（赤道对齐 / 等比 1.5× 全废）——曾试全局 stretch 被否、根因即此。故只缩 UI、地图保持原生。
- **单一源＝[UIScale.gd](../UIScale.gd)**（仿 *DB：`REF`=1080p、`MIN`/`MAX`、`factor(vp)` / `of(node)`）。
- **两种应用**：① 固定尺寸面板（卡片 / 对话框 / 覆盖层）＝根节点整体 `scale = UIScale.of(self)`（pivot 归零或居中），自身 `resized` / 视口 `size_changed` 时重算；② 边缘吸附 HUD（底边栏 / 角标）＝不整体 scale（会脱锚），改缩字号 / 内边距等度量。
- **已接入**：[UnitStatusPanel.gd](../UnitStatusPanel.gd) 角色卡（`_card_scale`）、[Settings.gd](../Settings.gd) 覆盖层（对话框整体缩）。

### 宿主 ↔ 画布契约（`HexCanvas.gd`）
- `hover_text(col,row) -> String`（宿主必实现）：坐标 + 地形 + 通行性 + 特殊效果（战斗侧 [Sandbox.gd](Sandbox.gd) / 大地图侧 [Overworld.gd](Overworld.gd) 各自实现，文案经 `TerrainDB` 共用单一源、防分叉）。
- `hover_extra(col,row) -> Control?`（可选钩子）：悬停格的扩展控件（战斗＝单位速览卡）；宿主无此方法＝只地形。
- `signal hover_changed(col,row)`：悬停格变化即发（含移出＝−1）；宿主据此更新自己的 UI（如底边栏），tile 数据仍经 `hover_text` 单一源读。
- `var terrain_in_popup := true`：默认 true（编辑器 / 大地图）＝悬停弹窗内含地形段；**战斗宿主设 false** ＝地形移交常驻底边栏、弹窗只留单位卡。
- 悬停弹窗 `_info_panel`（左下，`_make_info_label` / `_update_info_label`）：`grow_vertical=BEGIN` 底固定向上长；`_info_extra`（上，宿主填单位卡）+ `info_label`（下，地形；`terrain_in_popup=false` 时清空）。

### 底边栏 `MapInfoBar`（通用外壳组件）
> ⚠️ 现状文件名仍为 `BattleBottomBar.gd`（原型），迁移中改名 `MapInfoBar` 归共享层（见下「迁移」）。
- 独立 `PanelContainer`：`PRESET_BOTTOM_WIDE` + `grow_vertical=BEGIN`（否则底边宽锚点高度塌成 0）；`mouse_filter=IGNORE` 点击穿透。
- 布局自决：`HBox[地块 Label（撑开）· 按键提示 Label]`；API 仅 `set_terrain(text)`（多行 `hover_text`→折单行）/ `set_hint(text)`。
- 战斗接线（[Sandbox.gd](Sandbox.gd)）：`_build` 建栏挂 `canvas` 下 → `set_hint("[调试] V迷雾 N昼夜 C天气")` → `canvas.terrain_in_popup=false` → 连 `canvas.hover_changed`→`_on_hover_bar`（越界/移出显占位，否则喂 `hover_text`）；取代原散在宿主的右下角 `_build_shortcut_hint`。

## 🟡 规划 / 迁移
- 🔧 **`BattleBottomBar` → 改名 `MapInfoBar`**、归共享层（去 battle 前缀＝去场景耦合）。
- 🔧 **UI 同比缩放增量接入**：其余 UI 逐屏接 `UIScale`——`MapInfoBar` / 角标提示（边缘＝度量缩放）、战斗 / 大地图 HUD、各编辑器（可选）；别一次性大改。
- 🔧 **大地图 `Overworld` 接入底边栏**：`Overworld` 已有 `hover_text`（带行程成本 / 据点状态）→ 建 `MapInfoBar` + 各自 `set_hint`；`hover_changed` 大地图侧亦可发（`OverworldCanvas` 未覆写 `_update_info_label`＝天然继承）。
- 🟢 **tooltip / 通用输入提示层**：统一富 tooltip 渲染（`ItemTooltip` 已是物品侧雏形，可上升为通用）；通用键位提示区。
- 🟢 **底边栏扩展段**：战斗态 vs 布置态按键提示切换；大地图专属信息（行程 ETA / 据点状态）进左侧地块段；选中单位的快捷动作提示段。
- 🟢 **专属 HUD 归档**：战斗 / 大地图各自 HUD 的构建现散在 `Sandbox._build` / `Overworld._build_ui`——本文档只定分层与外壳，专属 HUD 细节留各自模块文档。
