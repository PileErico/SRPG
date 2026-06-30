extends RefCounted
## 槽位 / 物品内在 tag 的单一数据源——授权侧（物品编辑器）用；运行时装备资格(can_equip)待模型敲定+盾/副手机制要做时再接。
## 关键区分（用户校准 2026-06-30）：
##  · 槽位 = 放置位置（main_hand/off_hand/helmet/armor/accessory_1/2），**不是物品 tag**。
##    main_hand/off_hand 都能放任意单手武器；双手武器同时占两个；off_hand 还能放盾。
##  · 物品内在 tag = 它“是什么”：武器→持握(one_handed/two_handed，天生武器无)+类型(weapon_spear…)+innate；
##    防具→helmet/armor；饰品→accessory。
##  · main_hand/off_hand **不作物品 tag**（旧设计失误）。“强化副手武器/副手削弱”等按【槽位占用】判
##    （读 equipment["off_hand"]），不靠物品 tag——内在属性用 tag、位置相关查槽位。
## 用法：const EquipSlots := preload("res://EquipSlots.gd")。纯静态、无状态。

const SLOTS := ["main_hand", "off_hand", "helmet", "armor", "accessory_1", "accessory_2"]
const SLOT_CN := {
	"main_hand": "主手", "off_hand": "副手", "helmet": "头盔", "armor": "身甲",
	"accessory_1": "饰品1", "accessory_2": "饰品2",
}
# 类别（物品编辑器按类别给槽下拉）→ 该类可选的具体槽。
# 武器的“槽”= 默认放置位置（单手实际可装主手/副手任一；双手占两个）；防具/饰品的槽即其归属。
const SLOTS_BY_KIND := {
	"weapon": ["main_hand", "off_hand"],
	"armor": ["helmet", "armor"],
	"accessory": ["accessory_1", "accessory_2"],
}
# 编辑器自动管理、不放进自由标签的 tag（由 类别/双手/天生 控件派生）。
# 含旧失误的 main_hand/off_hand：若物品 tag 里残留则剥离、不再加回。
const MANAGED_TAGS := ["one_handed", "two_handed", "helmet", "armor", "accessory", "main_hand", "off_hand"]

# 物品的「内在 tag」（编辑器按 类别/双手/天生 自动写入 tags）。
# 武器 → 持握：天生=无 / 双手=two_handed / 单手=one_handed；防具 → 槽(helmet/armor)；饰品 → accessory。
static func intrinsic_tag(kind: String, slot: String, two_handed: bool, innate: bool) -> String:
	match kind:
		"weapon":
			if innate:
				return ""   # 天生武器无单/双手词条
			return "two_handed" if two_handed else "one_handed"
		"armor":
			return slot     # "helmet" / "armor"
		"accessory":
			return "accessory"
	return ""

# 装备资格相关的内在 tag（判定物品够格进哪个槽）。
const ELIGIBILITY_TAGS := ["one_handed", "two_handed", "shield", "helmet", "armor", "accessory"]

# 物品（按内在 tag）能否进某槽——tag 驱动装备资格。
#  · innate 天生武器：豁免 tag 资格（按其 slot 字段放置、永不卸下）。
#  · 无任何资格 tag 的旧物品（未迁移）：回退比 slot 字段（双手字段也认）。
#  · 否则严格判：main_hand=单/双手；off_hand=单手/盾（双手经主手连带占，不直接放副手）；helmet/armor/accessory=对应 tag。
static func accepts(slot: String, item: Dictionary) -> bool:
	if item.get("innate", false):
		return true
	var tags: Array = item.get("tags", [])
	var has_elig := false
	for t in ELIGIBILITY_TAGS:
		if tags.has(t):
			has_elig = true
			break
	if not has_elig:
		return _slot_field_fits(item, slot)
	match slot:
		"main_hand": return tags.has("one_handed") or tags.has("two_handed")
		"off_hand": return tags.has("one_handed") or tags.has("shield")
		"helmet": return tags.has("helmet")
		"armor": return tags.has("armor")
		"accessory_1", "accessory_2": return tags.has("accessory")
	return false

# 回退：未迁移物品按 slot 字段判定（双手占主+副；饰品进任一饰品槽）。
static func _slot_field_fits(item: Dictionary, slot: String) -> bool:
	if item.get("two_handed", false):
		return slot == "main_hand" or slot == "off_hand"
	var s := str(item.get("slot", ""))
	if s == "accessory_1" or s == "accessory_2":
		return slot == "accessory_1" or slot == "accessory_2"
	return s == slot
