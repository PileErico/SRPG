extends RefCounted
## stat 键 → 中文标签 单一数据源（仿 *DB：preload + 静态常量，不用 class_name）。
## 供 DeployPanel（单位编辑器，宿主可为 Sandbox 或 MapEditor）等 UI 查标签，
## 不再靠 host.STAT_LABELS 跨对象取（解耦：单位编辑器不该依赖具体宿主的常量）。
## 用法：const StatMeta := preload("res://StatMeta.gd") → StatMeta.label("atk")
##
## 现状：UnitStatusPanel.STAT_CN、Sandbox.STAT_LABELS 已删并迁来这里；
## 仅剩 ItemEditor.STAT_GROUPS——那是带分组/排序的「下拉选项」结构（非纯 键→中文 映射），职责不同、保留。

const LABELS := {
	"HP": "生命", "HP_max": "生命上限", "armor": "护甲", "armor_max": "护甲上限",
	"AP_max": "AP上限", "move": "移动力", "speed": "速度", "sight": "视野",
	"atk": "攻击", "mag": "理术", "atk_eff": "攻击效能", "def_eff": "防御效能",
	"acc": "命中", "eva": "闪避", "crit_rate": "暴击率", "crit_dmg": "暴击威力",
	"block_rate": "格挡率", "block_power": "格挡性能",
	"res_phys": "物理抗性", "res_status": "异常抗性",
	"res_fire": "火焰抗性", "res_thunder": "雷电抗性", "res_ice": "冰冻抗性", "res_holy": "神圣抗性",
	"armor_res_phys": "物理甲抗", "armor_res_fire": "火焰甲抗", "armor_res_thunder": "雷电甲抗",
	"armor_res_ice": "冰冻甲抗", "armor_res_holy": "神圣甲抗",
	"dr_flat_armor": "甲固减", "dr_flat_human": "人固减",
	"STR": "力量", "DEX": "灵巧", "INT": "智力", "STA": "体力",
}

# ============ stat 分组元数据（单一源；序列化/编辑器/派生 三个白名单同处维护）============
# 派生 stat：recompute_derived 从四维重算写回 base——**不序列化**（存了也会被重算覆盖）、不可编辑。
const DERIVED_STATS := ["HP_max", "atk", "mag", "acc", "eva",
	"block_rate", "block_power", "crit_rate", "crit_dmg", "res_status"]

# 序列化白名单：proto/preset/campaign 往返要带的基础面板 stat（非派生、非运行时 HP/armor/ap/move_points）。
# 加新基础 stat → 只补这里（UnitFactory 按「stats 里实际存在的键」序列化，缺省键不写、旧档零影响）。
const SERIALIZABLE_BASE_STATS := ["move", "speed", "sight", "AP_max", "armor_max",
	"atk_eff", "def_eff",
	"res_phys", "res_fire", "res_thunder", "res_ice", "res_holy",
	"armor_res_phys", "armor_res_fire", "armor_res_thunder", "armor_res_ice", "armor_res_holy",
	"dr_flat_human", "dr_flat_armor"]

# 单位编辑器（DeployPanel）可编辑的基础 stat 子集（甲抗/固减属物品侧数据，暂不开单位级编辑）。
const EDITOR_STATS := ["move", "speed", "sight", "AP_max", "armor_max",
	"atk_eff", "def_eff",
	"res_phys", "res_fire", "res_thunder", "res_ice", "res_holy"]

# 中文标签（缺则回退键本身）
static func label(key: String) -> String:
	return str(LABELS.get(key, key))
