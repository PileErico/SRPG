extends SceneTree
## Unit.effective_stat 回归——AP_max 潜伏 bug：refresh_for_turn / AP 显示端须走 effective_stat。
## 裸读 stats["AP_max"] 时 +AP_max buff（督战 +1AP 等）会少刷 AP，且 pip 轨道格数与实心点错位。
## 见 技能与效果系统.md §10 阶段0.3 + 附录A「AP bug」。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_unit_effective.gd（退出码 0=PASS）

const UnitC := preload("res://Unit.gd")

var _fail := 0
func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _initialize() -> void:
	print("=== Unit effective_stat（AP_max）回归 ===")
	var u = UnitC.new("测试", "player", 0, 0)
	u.modifiers = []
	u.stats["AP_max"] = 2

	# 无修正：刷新到裸上限 2
	u.refresh_for_turn()
	ck(u.ap == 2, "无修正 refresh → ap=2")

	# +2 flat AP_max buff：effective=4，refresh 须刷满 4（非裸 2）
	u.modifiers.append({"stat": "AP_max", "op": "flat", "value": 2, "source": "buff:督战"})
	ck(u.effective_stat("AP_max") == 4, "effective AP_max=4（base2 + flat2）")
	u.refresh_for_turn()
	ck(u.ap == 4, "+AP_max buff：refresh → ap=4（走 effective，非裸读的 2）")

	# 摘掉 buff：effective 回落 2，下个 refresh 回 2
	u.modifiers.clear()
	u.refresh_for_turn()
	ck(u.ap == 2, "摘 buff 后 refresh → ap=2")

	if _fail == 0:
		print("=== 全部断言 PASS ===")
	else:
		print("=== 失败 %d 项 ===" % _fail)
	quit(0 if _fail == 0 else 1)
