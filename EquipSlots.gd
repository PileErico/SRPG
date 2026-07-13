extends RefCounted
## 槽位 / 物品内在 tag 的单一数据源——授权侧（物品编辑器）+ 运行时装备资格(Unit.can_equip/equip)共用。
## 关键区分（用户校准）：
##  · 槽位/部位 = 放置位置（main_hand/off_hand/head/body/accessory_1/2），**不是物品 tag**。
##    部位用「身体部位」命名(head/body)，与 stat「armor/armor_max」(护甲值)区分开。
##  · 物品内在 tag = 它“是什么”：武器→持握(one/two_handed，天生无)+类型/种类；防具→head/body(部位)；饰品→accessory。
##  · main_hand/off_hand 等 **不作物品 tag**；位置类效果(强化副手)按【槽位占用】判，不靠物品 tag。
## 用法：const EquipSlots := preload("res://EquipSlots.gd")。纯静态、无状态。

const SLOT_CN := {
	"main_hand": "主手", "off_hand": "副手", "head": "头部", "body": "身体",
	"accessory_1": "饰品1", "accessory_2": "饰品2",
}
# （曾有 SLOTS/SLOTS_BY_KIND/MANAGED_TAGS/intrinsic_tag——全仓零调用的死码，2026-07-02 清除：
#  编辑器的管理集/内在 tag 派生实际长在 ItemEditor〔MANAGED_CATS 走 TagDB 类别、更全〕，两份只留活的那份。）

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
		"main_hand": return tags.has("one_handed") or tags.has("two_handed") or tags.has("shield")   # 盾可主手＝纯盾战士（🔒 决策31：盾＝正常武器，主手持盾＝盾击作普攻）
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
