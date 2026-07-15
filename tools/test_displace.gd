extends SceneTree
## 击退/位移解算器回归（🔒 2026-07-15 用户拍板：概率制击中附带 on_hit_displace + displace 族首铺 push）。
## 覆盖：displace_push 几何/占位/地形/出图停步 → _dir_away 推离方向 → _resolve_compute 击退判定
## （主动概率 + 被动伪 stat knockback_chance 合并单掷 / 肉体强韧数值直减 / 格挡免推 / 借机段禁入）→
## 数据接线（ws_spear_repel 击退键随 flatten_bws 透传）→ consume_cast 消耗口（EWS 轨）。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_displace.gd（退出码 0=PASS）

const BattleState := preload("res://BattleState.gd")
const Unit := preload("res://Unit.gd")
const SkillDB := preload("res://SkillDB.gd")

var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func mk(nm: String, fac: String, col: int, row: int) -> Unit:
	var u := Unit.new(nm, fac, col, row)
	u.stats["HP"] = int(u.stats.get("HP_max", 40))
	return u

# 定序循环等第一个命中样本（test_resolve_chain 同法：acc 100→hc 钳 95，seed 固定＝序列确定必出）
func first_hit(s, a, d, skill: Dictionary) -> Dictionary:
	for _i in range(64):
		var r: Dictionary = s._resolve_compute(a, d, skill)
		if r.get("hit", false):
			return r
		d.stats["HP"] = int(d.stats["HP_max"])
	return {}

func _initialize() -> void:
	print("=== 击退/位移解算器 测试开始 ===")

	# —— 1) displace_push 纯几何：空场直推 / 占位停步 / 地形不可通行 / 出图 ——
	var s = BattleState.new()
	s._new_grassland(9, 7)
	s.rng.seed = 20260715
	var a = mk("攻手", "player", 3, 3)
	var d = mk("靶子", "enemy", 4, 3)
	s.units = [a, d]
	var dir: int = s._dir_away(Vector2i(3, 3), Vector2i(4, 3))
	ck(dir >= 0, "相邻推离方向可解（%d）" % dir)
	var res: Dictionary = s.displace_push(d, dir, 2)
	ck(int(res["steps"]) == 2 and not bool(res["blocked"]), "空场直推 2 格")
	ck(Vector2i(d.col, d.row) == res["to"], "位置落账＝to")
	ck(s._hex_dist(Vector2i(3, 3), Vector2i(d.col, d.row)) == 3, "推离方向背向攻方（距离 1+2）")
	# 目的格被占 → 寸步难行
	d.col = 4
	d.row = 3
	var dest: Vector2i = s._neighbor_in_dir(Vector2i(4, 3), dir)
	var blocker = mk("路障", "enemy", dest.x, dest.y)
	s.units = [a, d, blocker]
	res = s.displace_push(d, dir, 2)
	ck(int(res["steps"]) == 0 and bool(res["blocked"]) and Vector2i(d.col, d.row) == Vector2i(4, 3), "占位停步（0 步原地）")
	# 地形不可通行（深水 passable_by flying/aquatic——旱鸭不会被推进深水）
	s.units = [a, d]
	s.tiles[dest.y][dest.x] = {"terrain": "water", "variant": "deep"}
	res = s.displace_push(d, dir, 1)
	ck(int(res["steps"]) == 0 and bool(res["blocked"]), "地形不可通行停步（旱鸭×深水）")
	s.tiles[dest.y][dest.x] = {"terrain": "plain", "variant": "grassland"}
	# 出图停步
	var pusher = mk("边攻", "player", 1, 3)
	var edge = mk("边靶", "enemy", 0, 3)
	s.units = [pusher, edge]
	res = s.displace_push(edge, s._dir_away(Vector2i(1, 3), Vector2i(0, 3)), 1)
	ck(int(res["steps"]) == 0 and bool(res["blocked"]), "出图停步")

	# —— 2) 击退判定链（_resolve_compute；门槛=命中且未被格挡）——
	s.units = [a, d]
	d.col = 4
	d.row = 3
	a.stats["atk"] = 20.0
	a.stats["acc"] = 100.0
	# 主动块概率破百 − 强韧 0 ≥100 → 命中必推（block_rate 0 必不格挡；coeff 0 零伤防收尸干扰）
	var r := first_hit(s, a, d, {"coeff": 0.0, "on_hit_displace": {"mode": "push", "distance": 1, "chance": 200}})
	ck(not r.is_empty(), "64 次内必出命中")
	ck(r.has("displace") and int(r["displace"]["steps"]) == 1, "主动击退：概率 200−强韧 0 必推 1 格")
	ck(s._hex_dist(Vector2i(a.col, a.row), Vector2i(d.col, d.row)) == 2, "被推远离攻方")
	# 距离参数
	d.col = 4
	d.row = 3
	r = first_hit(s, a, d, {"coeff": 0.0, "on_hit_displace": {"mode": "push", "distance": 2, "chance": 200}})
	ck(r.has("displace") and int(r["displace"]["steps"]) == 2, "distance=2 推 2 格")
	# 肉体强韧数值直减（非效果族的豁免二掷）：80−80=0 → 必不推
	d.col = 4
	d.row = 3
	d.stats["body_fort"] = 80.0
	r = first_hit(s, a, d, {"coeff": 0.0, "on_hit_displace": {"mode": "push", "distance": 1, "chance": 80}})
	ck(not r.is_empty() and not r.has("displace"), "概率 80−强韧 80＝0：必不推")
	# 被动合并（perk 挂载口＝伪 stat knockback_chance）：主动 80＋被动 40−强韧 20＝100 → 必推（相加单掷）
	d.stats["body_fort"] = 20.0
	s._add_effect(a, {"name": "压制姿态", "kind": "buff", "duration": 99,
		"mods": [{"stat": "knockback_chance", "op": "flat", "value": 40}]})
	r = first_hit(s, a, d, {"coeff": 0.0, "on_hit_displace": {"mode": "push", "distance": 1, "chance": 80}})
	ck(r.has("displace") and int(r["displace"]["steps"]) == 1, "主动80＋被动40−强韧20＝100：必推（概率合并单掷）")
	# 纯被动：普攻（无击退键）也触发，距离 1
	s._clear_effects_and_buffs(a)
	s._add_effect(a, {"name": "压制精通", "kind": "buff", "duration": 99,
		"mods": [{"stat": "knockback_chance", "op": "flat", "value": 200}]})
	d.col = 4
	d.row = 3
	r = first_hit(s, a, d, {"coeff": 0.0})
	ck(r.has("displace") and int(r["displace"]["steps"]) == 1, "纯被动：普攻无击退键也触发（距离 1）")
	# 格挡免推：block_rate 100 必格挡 → 不进击退判定
	var d2 = mk("盾手", "enemy", 5, 3)
	d2.stats["block_rate"] = 100.0
	s.units = [a, d2]
	r = first_hit(s, a, d2, {"coeff": 0.0, "on_hit_displace": {"mode": "push", "distance": 1, "chance": 200}})
	ck(not r.is_empty() and bool(r["blocked"]) and not r.has("displace"), "被格挡＝免推（门槛：命中且未被格挡）")
	# 借机/反击段（atk_rate 注入键）禁击退——移动编排中途位移会撕裂路径推进（v1 安全阀）
	s._clear_effects_and_buffs(a)
	s.units = [a, d]
	d.col = 4
	d.row = 3
	d.stats["body_fort"] = 0.0
	r = first_hit(s, a, d, {"coeff": 0.0, "atk_rate": 1.0, "on_hit_displace": {"mode": "push", "distance": 1, "chance": 200}})
	ck(not r.is_empty() and not r.has("displace"), "借机段（atk_rate 键）禁击退（v1 安全阀）")

	# —— 3) 数据接线 + 消耗口 ——
	var repel = SkillDB.get_skill("ws_spear_repel")
	ck(repel != null, "ws_spear_repel 在库")
	var flat: Dictionary = SkillDB.flatten_bws(repel) if repel != null else {}
	ck(typeof(flat.get("on_hit_displace")) == TYPE_DICTIONARY and int(flat["on_hit_displace"].get("distance", 0)) == 1,
		"击退键随 flatten_bws 透传（翼矛 EWS 数据接线）")
	var caster = mk("矛兵", "player", 2, 2)
	caster.ap = 3
	s.consume_cast(caster, "ws_spear_repel", repel)
	ck(caster.ap == 3 - SkillDB.skill_ap_cost(repel), "consume_cast 扣 AP")
	ck(caster.ews_state.has("ws_spear_repel"), "consume_cast 非已学走 EWS 轨（ews_state 记账）")

	if _fail == 0:
		print("=== 全部断言 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
