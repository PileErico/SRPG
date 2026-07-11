extends SceneTree
## bleed 迁引用端到端（阶段1A.2b）+ 强韧豁免（🔒 模块_属性成长_设计.md §5）：
## 验 _try_inflict_state 解析引用 → EffectDB 取定义施加 → DoT/cleanse；强韧=施加时+每回合豁免掷、ignore_fort 穿透。
## 确定化：施加用 chance=100 副本（数据侧 chance=30 单独验）；豁免用 body_fort=0/100 两极。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_bleed_inflict.gd（退出码 0=PASS）

const BattleState := preload("res://BattleState.gd")
const ItemDB := preload("res://ItemDB.gd")
const UnitC := preload("res://Unit.gd")
const SkillDB := preload("res://SkillDB.gd")   # 阶段3a：attack 经 bws 引用解析（flatten_bws）

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
	u.stats = {"HP": 100, "HP_max": 100}   # body_fort 缺省 0 → 无豁免掷；施加确定性靠 chance=100 副本
	return u

func _bleed(u):
	for e in u.effects:
		if str(e.get("id", "")) == "bleeding":
			return e
	return null

func _initialize() -> void:
	print("=== bleed 迁引用 端到端 回归 ===")
	var s = BattleState.new()

	# 数据侧：claw_wing 的 inflict 已是引用形态。
	# ⚠ 阶段3a（决策26）：attack 已迁 BWS 条目（武器 bws 引用）——经 SkillDB.flatten_bws 取扁平 attack（与运行时同路径）。
	var claw = ItemDB.get_item("claw_wing")
	ck(claw != null, "claw_wing 存在")
	var bws_def = SkillDB.get_skill(str(claw.get("bws", ""))) if claw != null else null
	ck(bws_def != null, "claw_wing 的 bws 引用可解析")
	var atk: Dictionary = SkillDB.flatten_bws(bws_def) if bws_def != null else {}
	var inf = atk.get("inflict", {})
	ck(str(inf.get("effect", "")) == "bleeding", "inflict 引用 effect=bleeding")
	ck(int(inf.get("chance", 0)) == 30, "inflict 保留 chance=30（rider 侧）")
	ck(not inf.has("name") and not inf.has("dot_pct_max_hp"), "内联定义字段已迁走（inflict 只剩引用+chance）")

	# 施加：解析引用 → 从 EffectDB 取定义挂上（chance→100 副本确定化）
	var atk100 = atk.duplicate(true)
	atk100["inflict"] = {"effect": "bleeding", "chance": 100}
	var t = mk()
	var r = s._try_inflict_state(t, atk100)
	ck(bool(r.get("applied", false)), "chance=100 + 强韧0 → 必施加")
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

	# cleanse by tag 仍生效（清流血类技能靠 tag）
	var removed := s._cleanse_effects_with_tag(t, "bleeding")
	ck(removed == 1 and _bleed(t) == null, "按 bleeding tag 清除 → 移除 1 条、effect 消失")

	# —— 强韧豁免 🔒（§5）：bleeding=肉体系（fort_body tag）——
	# 施加瞬间豁免：肉体强韧 100 → 必挣脱、完全不受影响
	var t2 = mk()
	t2.stats["body_fort"] = 100
	var r2 = s._try_inflict_state(t2, atk100)
	ck(bool(r2.get("shrugged", false)) and not bool(r2.get("applied", false)), "肉体强韧100 → 施加瞬间豁免")
	ck(_bleed(t2) == null, "豁免=完全不受影响")
	# ignore_fort：无视强韧（施加豁免+每回合豁免一并跳过）
	var atk_ig = atk.duplicate(true)
	atk_ig["inflict"] = {"effect": "bleeding", "chance": 100, "ignore_fort": true}
	var r3 = s._try_inflict_state(t2, atk_ig)
	ck(bool(r3.get("applied", false)) and _bleed(t2) != null, "ignore_fort 穿透强韧施加")
	var shrug := false
	for ev in s._apply_turn_start_effects(t2):
		if str(ev.get("type", "")) == "fort_shrug":
			shrug = true
	ck(not shrug and _bleed(t2) != null, "ignore_fort 效果不可挣脱（每回合豁免跳过）")
	# 常规施加后的每回合豁免：肉体强韧 100 → 回合开始必挣脱（连带摘修正、事件上报）
	var t3 = mk()
	s._add_effect(t3, {"id": "bleeding"})
	t3.stats["body_fort"] = 100
	var shrug3 := false
	for ev in s._apply_turn_start_effects(t3):
		if str(ev.get("type", "")) == "fort_shrug":
			shrug3 = true
	ck(shrug3 and _bleed(t3) == null, "每回合豁免：肉体强韧100 → 回合开始挣脱")

	if _fail == 0:
		print("=== 全部断言 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
