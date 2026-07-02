extends SceneTree
const UnitFactory := preload("res://UnitFactory.gd")
const ItemInstances := preload("res://ItemInstances.gd")
const WorldState := preload("res://WorldState.gd")

func _initialize() -> void:
	WorldState.current = null
	ItemInstances.clear()
	var sb = UnitFactory.make_unit({"name": "沙盒兵", "equip": ["long_sword", "breast_plate"]}, "player", 0, 0)
	var chest := int(sb.equipment.get("chest", 0))
	print("沙盒兵 chest 槽 uid=", chest, " view.name=", ItemInstances.view(chest).get("name"), " slot=", ItemInstances.view(chest).get("slot"))
	# 新建战役（无 clear），战役造 2 件物品：uid 1、2 —— uid2 撞沙盒兵胸甲
	var ws = WorldState.new(); WorldState.current = ws
	var i1 := ItemInstances.create("long_sword")
	var i2 := ItemInstances.create("long_sword")
	print("战役铸造 uid=", i1, ",", i2)
	var v = ItemInstances.view(chest)
	print("沙盒兵 chest 槽 uid=", chest, " 现在 view.name=", v.get("name"), " slot=", v.get("slot"), "  ← 胸甲槽里读出一把剑")
	print("basic_attack 也串档: ", sb.basic_attack().get("name", "徒手"), "（原=斩击，主手 uid=", int(sb.equipment.get("main_hand", 0)), " 也被撞则更糟）")
	WorldState.current = null
	ItemInstances.clear()
	quit(0)
