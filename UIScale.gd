extends RefCounted
## UI 同比缩放：以 1080p 为设计基准，UI 随视口等比缩放（更大/更小分辨率同比放缩）。
## 🔒（2026-07-07）只作用于 UI —— 地图不套本缩放：玩家有独立的手动地图缩放（按喜好自适应），
##   无需自动缩；且引擎全局 stretch 会连战场瓦片一起缩、毁像素密度，故弃用（见 docs/模块_UI交互.md）。
## 仿 *DB 伪单例：preload + 静态、无 class_name。用法：
##   const UIScale := preload("res://UIScale.gd")
##   · 固定尺寸面板（卡片/对话框/覆盖层）：根节点 pivot 归零或居中 + scale = UIScale.of(self)，
##     并在自身 resized / 视口 size_changed 时重算。
##   · 边缘吸附 HUD（底边栏/角标提示）：不整体 scale（会脱离锚点），改缩字号/内边距等度量。

const REF := Vector2(1920, 1080)   # 设计基准＝1080p：此处 factor=1
const MIN := 0.55                  # 小窗兜底：再小也不至挤爆
const MAX := 1.5                   # 大屏封顶：不至于像 2× 那么猛

# 给定视口尺寸 → 缩放系数（取长短边较小者、等比、夹值）。
static func factor(vp: Vector2) -> float:
	return clampf(minf(vp.x / REF.x, vp.y / REF.y), MIN, MAX)

# 便捷：读节点当前所在视口的 factor。
static func of(node: Node) -> float:
	var vp: Vector2 = node.get_viewport().get_visible_rect().size
	return factor(vp)
