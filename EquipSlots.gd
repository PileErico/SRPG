extends RefCounted
## 槽位 / 物品内在 tag 的单一数据源——授权侧（物品编辑器）+ 运行时装备资格(Unit.can_equip/equip)共用。
## 关键区分（用户校准）：
##  · 槽位/部位 = 放置位置（main_hand/off_hand/head/body/accessory_1/2），**不是物品 tag**。
##    部位用「身体部位」命名(head/body)，与 stat「armor/armor_max」(护甲值)区分开。
##  · 物品内在 tag = 它“是什么”：武器→持握(one/two_handed，天生无)+类型/种类；防具→head/body(部位)；饰品→accessory。
##  · main_hand/off_hand 等 **不作物品 tag**；位置类效果(强化副手)按【槽位占用】判，不靠物品 tag。
## 用法：const EquipSlots := preload("res://EquipSlots.gd")。纯静态、无状态。

const SLOTS := ["main_hand", "off_hand", "head", "body", "accessory_1", "accessory_2"]
const SLOT_CN := {
	"main_hand": "主手", "off_hand": "副手", "head": "头部", "body": "身体",
	"accessory_1": "饰品1", "accessory_2": "饰品2",
}
# 类别（kind，物品编辑器按类别给槽下拉）→ 该类可选的具体槽/部位。
const SLOTS_BY_KIND := {
	"weapon": ["main_hand", "off_hand"],
	"armor": ["head", "body"],
	"accessory": ["accessory_1", "accessory_2"],
}
# 编辑器自动管理、不进自由标签的 tag（含旧失误的 main_hand/off_hand）。
const MANAGED_TAGS := ["one_handed", "two_handed", "head", "body", "accessory", "main_hand", "off_hand"]

# 物品内在 tag（编辑器按 类别/双手/天生 派生）。武器→持握；防具→部位(head/body)；饰品→accessory。
static func intrinsic_tag(kind: String, slot: String, two_handed: bool, innate: bool) -> String:
	match kind:
		"weapon":
			if innate:
				return ""
			return "two_handed" if two_handed else "one_handed"
		"armor":
			return slot     # "head" / "body"
		"accessory":
			return "accessory"
	return ""

# 装备资格相关的内在 tag。
const ELIGIBILITY_TAGS := ["one_handed", "two_handed", "shield", "head", "body", "accessory"]

# 物品（按内在 tag）能否进某槽——tag 驱动装备资格。
#  · innate 天生：豁免 tag 资格（按其 slot 字段放置、永不卸下）。
#  · 无任何资格 tag 的旧物品：回退比 slot 字段。
#  · 否则严格判：main_hand=单/双手；off_hand=单手/盾；head/body/accessory=对应部位 tag。
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
		"head": return tags.has("head")
		"body": return tags.has("body")
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
