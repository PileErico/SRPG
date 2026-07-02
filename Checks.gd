extends RefCounted
## 属性检定原语（DB 范式：preload + static，无 class_name）——项目**唯一**的 d20 检定实现处（需求 §1.11 实现注记）。
## check(unit, attr, dc)＝1d20 + 单位属性（effective 口径，含装备/buff）vs 难度，>=DC 过。
## 首个消费者＝死门每回合检定（体力 STA vs 15+5×次数）；大地图/营地事件的 BB 式检定（M7+）直接复用。
## （既有 4 处 randf()*100<X 的百分比判定是另一形状，不并入。）

static func check(unit, attr: String, dc: int) -> Dictionary:
	var roll := randi_range(1, 20)
	var bonus := int(unit.effective_stat(attr)) if unit != null else 0
	return {"ok": roll + bonus >= dc, "roll": roll, "bonus": bonus, "total": roll + bonus, "dc": dc}
