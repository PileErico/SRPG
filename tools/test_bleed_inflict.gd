extends SceneTree
## bleed 迁引用端到端（阶段1A.2b）：claw_wing 内联 inflict 已迁成 {effect:"bleeding",chance:30}——
## 验 _try_inflict_state 解析引用 → 从 EffectDB 取定义施加 → DoT 每回合末扣血、带 bleeding tag（可被 cleanse）。
## 用真数据（真 EffectDB + 真 claw_wing）；res_status 压极低使 ch>100 → 确定必施加、无 RNG 依赖。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_bleed_inflict.gd（退出码 0=PASS）

const BattleState := preload("res://BattleState.gd")
const ItemDB := preload("res://ItemDB.gd")
const UnitC := preload("res://Unit.gd")

var _fail := 0
func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func mk():
	var u = UnitC.new("靶", "enemy", 0, 0)
	u.modifiers = []
	u.equipment = {}
	u.effects = []
	u.stats = {"HP": 100, "HP_max": 100, "res_status": -300}   # res_status 极低 → ch = 30×(1+3)=120 >100 恒施加
	return u

func _bleed(u):
	for e in u.effects:
		if str(e.get("id", "")) == "bleeding":
			return e
	return null

func _initialize() -> void:
	print("=== bleed 迁引用 端到端 回归 ===")
	var s = BattleState.new()

	# 数据侧：claw_wing 的 inflict 已是引用形态
	var claw = ItemDB.get_item("claw_wing")
	ck(claw != null, "claw_wing 存在")
	var atk = claw.get("attack", {}) if claw != null else {}
	var inf = atk.get("inflict", {})
	ck(str(inf.get("effect", "")) == "bleeding", "inflict 引用 effect=bleeding")
	ck(int(inf.get("chance", 0)) == 30, "inflict 保留 chance=30（rider 侧）")
	ck(not inf.has("name") and not inf.has("dot_pct_max_hp"), "内联定义字段已迁走（inflict 只剩引用+chance）")

	# 施加：解析引用 → 从 EffectDB 取定义挂上
	var t = mk()
	var r = s._try_inflict_state(t, atk)
	ck(bool(r.get("applied", false)), "res_status 极低 → 必施加")
	ck(str(r.get("name", "")) == "流血", "事件名取自 EffectDB 定义=流血")
	var e = _bleed(t)
	ck(e != null, "target 挂上 bleeding 效果")
	if e != null:
		ck(int(e.get("dot_pct_max_hp", 0)) == 5, "dot=5%（来自 effects.json，非武器内联）")
		ck(int(e.get("duration", 0)) == 2, "duration=2（{base:2} 求值）")
		ck((e.get("tags", []) as Array).has("bleeding"), "带 bleeding tag（cleanse 可整批清）")

	# DoT：回合末扣 5% HP_max
	s._apply_turn_end_effects(t)
	ck(int(t.stats["HP"]) == 95, "DoT：HP 100→95（5%）")

	# cleanse by tag 仍生效（battlefield_heal 清流血靠 tag）
	var removed := s._cleanse_effects_with_tag(t, "bleeding")
	ck(removed == 1 and _bleed(t) == null, "按 bleeding tag 清除 → 移除 1 条、effect 消失")

	if _fail == 0:
		print("=== 全部断言 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
