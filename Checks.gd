extends RefCounted
## 属性检定原语（DB 范式：preload + static，无 class_name）——项目**唯一**的 d20 检定实现处（需求 §1.11 实现注记）。
## check(unit, attr, dc)＝1d20 + 单位属性（effective 口径，含装备/buff）vs 难度，>=DC 过。
## check_flat(bonus, dc)＝调用方自算修正值的形状——如死门检定（🔒 §10.6 改版：
## 1d20＋运气＋肉体强韧/5，DC 逐轮 5/10/15/20/25 递增，见 Sandbox._door_turn_check）。
## 大地图/营地事件的 BB 式检定（M7+）按取材复用两种形状。
## （既有 4 处 randf()*100<X 的百分比判定是另一形状，不并入。）

static func check(unit, attr: String, dc: int) -> Dictionary:
	var roll := randi_range(1, 20)
	var bonus := int(unit.effective_stat(attr)) if unit != null else 0
	return {"ok": roll + bonus >= dc, "roll": roll, "bonus": bonus, "total": roll + bonus, "dc": dc}

static func check_flat(bonus: int, dc: int) -> Dictionary:
	var roll := randi_range(1, 20)
	return {"ok": roll + bonus >= dc, "roll": roll, "bonus": bonus, "total": roll + bonus, "dc": dc}
