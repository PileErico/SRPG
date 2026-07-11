extends SceneTree
## _add_effect 效果桥回归（阶段1A.2）：EffectDB id 路径（同 id 刷新 / stackable 叠层 / mods 桥 / HoT /
## on_expire 两段式连锁）+ 向后兼容匿名 name 路径。经 EffectDB._path_override 注入临时效果库，绝不碰真数据。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_effect.gd（退出码 0=PASS）

const BattleState := preload("res://BattleState.gd")
const EffectDB := preload("res://EffectDB.gd")
const UnitC := preload("res://Unit.gd")

const P := "user://_test_fx.json"

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
	u.stats = {"HP": 100, "HP_max": 100, "speed": 5, "eva": 10}   # 🔒 属性重做：四维已删
	return u

func _fx_of(u, eid: String) -> Variant:
	for e in u.effects:
		if str(e.get("id", "")) == eid:
			return e
	return null

func _count(u, eid: String) -> int:
	var n := 0
	for e in u.effects:
		if str(e.get("id", "")) == eid:
			n += 1
	return n

func _initialize() -> void:
	print("=== _add_effect 效果桥 回归 ===")
	EffectDB._path_override = P
	var f = FileAccess.open(P, FileAccess.WRITE)
	f.store_string(JSON.stringify([
		{"id": "t_slow", "name": "减速", "kind": "debuff", "duration": {"base": 2, "per_stat": {}}, "mods": [{"stat": "speed", "op": "flat", "value": -2}]},
		{"id": "t_dot", "name": "灼烧", "kind": "debuff", "duration": {"base": 3}, "dot_pct_max_hp": 10},
		{"id": "t_hot", "name": "愈合", "kind": "buff", "duration": {"base": 5}, "hot_flat": 5},
		{"id": "t_stack", "name": "叠层", "kind": "debuff", "duration": {"base": 2}, "stackable": true, "max_stacks": 3},
		{"id": "t_seed", "name": "引信", "kind": "debuff", "duration": {"base": 1}, "on_expire_apply": "t_boom"},
		{"id": "t_boom", "name": "爆发", "kind": "debuff", "duration": {"base": 2}, "mods": [{"stat": "eva", "op": "flat", "value": -5}]},
		{"id": "t_ts", "name": "架势", "kind": "buff", "duration": {"base": 1}, "expire_timing": "turn_start"},
		{"id": "t_stun", "name": "眩晕", "kind": "debuff", "duration": {"base": 2}, "tags": ["incapacitated"]},
		{"id": "t_haste", "name": "鼓舞疾速", "kind": "buff", "duration": {"base": 1}, "expire_timing": "round_end",
			"mods": [{"stat": "speed", "op": "flat", "value": 50}], "on_expire_apply": "t_boom"},
	], "  "))
	f.close()
	EffectDB.reload_data()

	var s = BattleState.new()

	# 1) id 路径：挂载 → 存进 effects（带 id/source）+ mods 桥生效
	var u = mk()
	s._add_effect(u, {"id": "t_slow"})
	var e = _fx_of(u, "t_slow")
	ck(e != null, "id 路径：t_slow 已挂")
	ck(int(e.get("duration", 0)) == 2, "duration 由 {base:2} 对象求值成 scalar 2")
	ck(str(e.get("source", "")) == "buff:t_slow", "source=buff:t_slow")
	ck(u.effective_stat("speed") == 3, "mods 桥：speed 5-2=3")

	# 2) 同 id 刷新：时长复位、不重复、mods 不翻倍
	e["duration"] = 1
	s._add_effect(u, {"id": "t_slow"})
	ck(_count(u, "t_slow") == 1, "同 id 刷新不产生重复条目")
	ck(int(_fx_of(u, "t_slow").get("duration", 0)) == 2, "刷新后 duration 复位=2")
	ck(u.effective_stat("speed") == 3, "刷新后 mods 仍只一份（speed=3）")

	# 3) stackable 叠层：封顶 max_stacks
	var u2 = mk()
	for i in 4:
		s._add_effect(u2, {"id": "t_stack"})
	ck(_count(u2, "t_stack") == 1, "叠层只一个条目")
	ck(int(_fx_of(u2, "t_stack").get("stacks", 0)) == 3, "stacks 封顶 max_stacks=3")

	# 4) DoT：回合末按 HP_max% 扣血
	var u3 = mk()
	s._add_effect(u3, {"id": "t_dot"})
	s._apply_turn_end_effects(u3)
	ck(int(u3.stats["HP"]) == 90, "DoT：HP 100→90（10% HP_max）")
	ck(int(_fx_of(u3, "t_dot").get("duration", 0)) == 2, "DoT duration 3→2")

	# 5) HoT：回合末回固定血、钳 HP_max 不溢出
	var u4 = mk()
	u4.stats["HP"] = 50
	s._add_effect(u4, {"id": "t_hot"})
	s._apply_turn_end_effects(u4)
	ck(int(u4.stats["HP"]) == 55, "HoT：HP 50→55（+5）")
	u4.stats["HP"] = 98
	s._apply_turn_end_effects(u4)
	ck(int(u4.stats["HP"]) == 100, "HoT 钳 HP_max：98→100（只 +2 不溢出）")

	# 6) on_expire 两段式：t_seed 到期 → 连锁施加 t_boom
	var u5 = mk()
	s._add_effect(u5, {"id": "t_seed"})
	s._apply_turn_end_effects(u5)   # t_seed dur 1→0 到期 → 连锁 t_boom
	ck(_fx_of(u5, "t_seed") == null, "t_seed 已到期移除")
	ck(_fx_of(u5, "t_boom") != null, "on_expire 连锁：t_boom 已施加")
	ck(u5.effective_stat("eva") == 5, "第二段 mods 生效：eva 10-5=5")

	# 7) 向后兼容匿名 name 路径（死门/重伤/旧内联）：无 id → 走 name 路径
	var u6 = mk()
	s._add_effect(u6, {"name": "匿名减速", "kind": "debuff", "duration": 2, "mods": [{"stat": "eva", "op": "flat", "value": 3}]})
	var an: Variant = null
	for ee in u6.effects:
		if str(ee.get("name", "")) == "匿名减速":
			an = ee
	ck(an != null and not an.has("id"), "匿名路径：有 name 无 id")
	ck(str(an.get("source", "")) == "buff:匿名减速", "匿名 source=buff:<name>")
	ck(u6.effective_stat("eva") == 13, "匿名 mods 桥：eva 10+3=13")

	# 8) expire_timing turn_start：回合末不递减、回合开始 tick 才到期（DoT/HoT 恒 turn_end 不受影响）
	var u7 = mk()
	s._add_effect(u7, {"id": "t_ts"})
	s._apply_turn_end_effects(u7)
	ck(_fx_of(u7, "t_ts") != null and int(_fx_of(u7, "t_ts").get("duration", 0)) == 1, "turn_start 效果：回合末不递减（duration 仍 1）")
	s._apply_turn_start_effects(u7)
	ck(_fx_of(u7, "t_ts") == null, "turn_start 效果：回合开始 tick 到期移除")

	# 8b) expire_timing round_end（2026-07-11 tick 落地）：turn 两侧不递减、_wrap_round 才到期；
	#     🔒 §2.2 过渡序＝到期（摘 mods+连锁）先于 _rebuild_turn_order——速度 buff 不污染新 round 排序
	var fast = mk()
	var slow = mk()
	slow.stats["speed"] = 20   # 基础比 fast(5) 快；fast 靠 round_end buff 暂时反超
	s._add_effect(fast, {"id": "t_haste"})
	s.units = [fast, slow]
	s._rebuild_turn_order()
	ck(s.turn_order[0] == fast, "鼓舞疾速期内：fast(5+50) 排 slow(20) 前")
	s._apply_turn_end_effects(fast)
	s._apply_turn_start_effects(fast)
	ck(_fx_of(fast, "t_haste") != null and int(_fx_of(fast, "t_haste").get("duration", 0)) == 1,
		"round_end 效果：turn 两侧 tick 均不递减")
	var round_evs: Array = s._wrap_round()
	ck(_fx_of(fast, "t_haste") == null, "round_end 效果：_wrap_round tick 到期移除")
	ck(fast.effective_stat("speed") == 5, "到期连带摘 speed mods")
	ck(s.turn_order[0] == slow, "🔒 过渡序：到期先于重排 → 新 round slow 回到首位")
	ck(_fx_of(fast, "t_boom") != null, "round_end 到期的 on_expire_apply 两段连锁照常施加")
	var has_exp := false
	var has_chain := false
	for ev in round_evs:
		if str(ev.get("type", "")) == "expired" and ev.get("who") == fast:
			has_exp = true
		if str(ev.get("type", "")) == "chain":
			has_chain = true
	ck(has_exp and has_chain, "_wrap_round 返回 expired+chain 事件且带 who 归属（宿主日志用）")

	# 9) has_state：扫活跃 effects tags（失能/失语状态机查询）
	var u8 = mk()
	ck(not u8.has_state("incapacitated"), "无效果 → 无 incapacitated 状态")
	s._add_effect(u8, {"id": "t_stun"})
	ck(u8.has_state("incapacitated"), "挂眩晕 → has_state incapacitated")
	ck(not u8.has_state("silenced"), "眩晕不带 silenced")

	# 收尾
	EffectDB._path_override = ""
	EffectDB.reload_data()
	DirAccess.remove_absolute(P)

	if _fail == 0:
		print("=== 全部断言 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
