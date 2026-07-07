extends RefCounted
## stat 键 → 中文标签 单一数据源（仿 *DB：preload + 静态常量，不用 class_name）。
## 供 DeployPanel（单位编辑器，宿主可为 Sandbox 或 MapEditor）等 UI 查标签，
## 不再靠 host.STAT_LABELS 跨对象取（解耦：单位编辑器不该依赖具体宿主的常量）。
## 用法：const StatMeta := preload("res://StatMeta.gd") → StatMeta.label("atk")
##
## 🔒 属性重做（docs/模块_属性成长_设计.md）：四维主属性/派生公式已删——全部面板值均为**基础 stat**
## （基础值=种族底值 RaceDB，装备/熟练度/perk 经修正管线叠加）；抗性四轨=物理/自然抗性+意志/肉体强韧。

const LABELS := {
	"HP": "生命", "HP_max": "生命上限", "armor": "护甲", "armor_max": "护甲上限",
	"AP_max": "AP上限", "move": "移动力", "speed": "速度", "sight": "视野",
	"atk": "攻击", "atk_eff": "攻击效能", "def_eff": "防御效能",
	"acc": "命中", "eva": "闪避", "crit_rate": "暴击率", "crit_dmg": "暴击威力",
	"block_rate": "格挡率", "block_power": "格挡性能",
	"res_phys": "物理抗性", "res_nature": "自然抗性",
	"will_fort": "意志强韧", "body_fort": "肉体强韧",
	"armor_res_phys": "物理甲抗", "armor_res_nature": "自然甲抗",
	"dr_flat_armor": "甲固减", "dr_flat_human": "人固减",
}

# ============ stat 分组元数据（单一源；序列化/编辑器 两个白名单同处维护）============

# 序列化白名单：proto/preset/campaign 往返要带的基础面板 stat（非运行时 HP/armor/ap/move_points）。
# 加新基础 stat → 只补这里（UnitFactory 按「stats 里实际存在的键」序列化，缺省键不写、旧档零影响）。
# 原派生键（HP_max/atk/acc/eva/格挡/暴击）已降级为基础 stat → 一并入列（属性重做 §4）。
const SERIALIZABLE_BASE_STATS := ["HP_max", "atk", "acc", "eva",
	"crit_rate", "crit_dmg", "block_rate", "block_power",
	"move", "speed", "sight", "AP_max", "armor_max",
	"atk_eff", "def_eff",
	"res_phys", "res_nature", "will_fort", "body_fort",
	"armor_res_phys", "armor_res_nature",
	"dr_flat_human", "dr_flat_armor"]

# 单位编辑器（DeployPanel）可编辑的基础 stat 子集（甲抗/固减属物品侧数据，暂不开单位级编辑）。
const EDITOR_STATS := ["HP_max", "atk", "acc", "eva",
	"crit_rate", "crit_dmg", "block_rate", "block_power",
	"move", "speed", "sight", "AP_max", "armor_max",
	"atk_eff", "def_eff",
	"res_phys", "res_nature", "will_fort", "body_fort"]

# 非数值「状态旗」mod 键白名单（不在 LABELS、但属合法修正对象 stat）
const FLAG_MOD_STATS := ["vision_state"]

# 物品/词条永不可携带的 stat 🔒（模块_属性成长_设计.md §5：强韧来源＝种族+perk，防具/词条只有抗性）。
# data lint 规则4 与 ItemInstances 运行时护栏共用此清单（stat 键清单从单一源取、严禁各处硬编码）。
const ITEM_FORBIDDEN_STATS := ["will_fort", "body_fort"]

# 中文标签（缺则回退键本身）
static func label(key: String) -> String:
	return str(LABELS.get(key, key))

# 修正对象 stat 键是否合法（∈LABELS 或状态旗白名单）——词条/运行时 mod 入库前校验用
static func is_valid_mod_stat(key: String) -> bool:
	return LABELS.has(key) or key in FLAG_MOD_STATS

# 该 stat 是否百分比语义（显示加 %）——抗性/甲抗/强韧/效能/率类即便 op=flat 也按 % 读
# （强韧=豁免率，百分比语义；键约定「甲抗均为百分比」🔒）
static func is_pct(key: String) -> bool:
	return key.begins_with("res_") or key.begins_with("armor_res_") \
		or key.ends_with("_eff") or key.ends_with("_rate") or key.ends_with("_fort") \
		or key in ["block_power", "crit_dmg"]
