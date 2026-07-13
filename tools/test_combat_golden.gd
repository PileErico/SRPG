extends SceneTree
## 战斗伤害 golden 基线：对 BattleState._resolve_compute 的 out/伤害分量做数值断言。
## 目的：把「一次命中 → 分量减伤链落血」的数学锁成不回归基线——阶段3 BAS 迁移、后续
##       效能/护甲改动一旦静默改数就 FAIL（blocker 静默回归的可测护栏；见模块_技能_设计.md §10 阶段0）。
##
## 确定化手法（无 flaky）：命中率 clamp[5,95] 无法钳到 100，但
##   crit_rate=0 → roll*100<0 恒 false（暴击结果与 RNG 无关）；
##   block_rate=0 → 同理恒不格挡；
##   施放前注入 s.rng.seed=SEED（技改 §1-1 战斗骰统一过 BattleState.rng）使首个命中掷骰恒定 → 命中恒成立。
## 故每个用例结果确定、可逐分量断言。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_combat_golden.gd（退出码 0=PASS）

const BattleState := preload("res://BattleState.gd")
const UnitC := preload("res://Unit.gd")

const SEED := 20260705   # 该 seed 下首骰 < 95 → 命中恒成立（_initialize 首条断言把关）

var _fail := 0
func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

# 裸单位：清空修正/装备（effective==base），一套中性可控 stats，overrides 覆写。
func mk(overrides: Dictionary):
	var u = UnitC.new("测试", "player", 3, 3)   # 站草原（无效能层地块 grant → 地形因子=1.0）
	u.modifiers = []
	u.equipment = {}
	# 🔒 属性重做（docs/模块_属性成长_设计.md）：四维已删、抗性两轨（物理/自然）——本基线为重做后重推（旧基线作废=预期）。
	var base := {
		"HP": 100, "HP_max": 100, "armor": 0, "armor_max": 0,
		"atk": 20, "acc": 200, "eva": 0,
		"crit_rate": 0, "crit_dmg": 150,
		"block_rate": 0, "block_power": 0,
		"def_eff": 100, "atk_eff": 100,
		"res_phys": 0, "res_nature": 0,
		"armor_res_phys": 0, "armor_res_nature": 0,
		"dr_flat_human": 0, "dr_flat_armor": 0,
		"will_fort": 0, "body_fort": 0,
	}
	for k in overrides:
		base[k] = overrides[k]
	u.stats = base
	return u

# 确定化施放：每次施放前同 seed，命中/暴击/格挡结果恒定。
# 士气钉回 25（稳定档＝档位判定 0，🔒 §10.7 已接线）：命中 +2 会连击滚档改 aeff——golden 只锁伤害数学。
func hit(s, a, t, skill) -> Dictionary:
	s.rng.seed = SEED   # 注入定序（战斗骰统一过 BattleState.rng——技改 §1-1）
	a.morale = 25
	return s._resolve_compute(a, t, skill)

func _initialize() -> void:
	print("=== 战斗伤害 golden 基线 测试开始 ===")
	var s = BattleState.new()
	s._new_grassland(9, 7)   # 草原棋盘：所有格无效能层 grant → 地形攻/防效能因子恒 1.0

	# 0) 确定化前提：命中恒成立、暴击/格挡恒 false、效能/防御因子=1
	var a0 = mk({})
	a0.col = 1
	a0.row = 1
	var r0 := hit(s, a0, mk({"HP": 1000}), {"coeff": 1.0})
	ck(r0["hit"], "命中恒成立（hc=95 + 固定 seed）")
	ck(not r0["crit"], "crit_rate=0 → 恒不暴击")
	ck(not r0["blocked"], "block_rate=0 → 恒不格挡")
	ck(is_equal_approx(float(r0["aeff"]), 1.0), "atk_eff=100 且无地块 → 攻击效能因子=1")
	ck(is_equal_approx(float(r0["def_factor"]), 1.0), "def_eff=100 → 防御因子=1")

	# 1) 物理·无甲：out=atk×coeff=20；全进人（res=0）
	var t1 = mk({"HP": 100})
	var r1 := hit(s, a0, t1, {"coeff": 1.0})
	ck(is_equal_approx(float(r1["out"]), 20.0), "out=20（atk20×coeff1）")
	ck(int(r1["hp_loss"]) == 20 and int(r1["armor_loss"]) == 0, "无甲：hp_loss=20 armor_loss=0")
	ck(int(t1.stats["HP"]) == 80, "落血后 HP=80")

	# 2) 系数：coeff=0.5 → out=10
	var r2 := hit(s, a0, mk({}), {"coeff": 0.5})
	ck(is_equal_approx(float(r2["out"]), 10.0) and int(r2["hp_loss"]) == 10, "coeff0.5：out=10 hp_loss=10")

	# 3) 甲吸收：armor=30 ≥ out20 → 全进甲、不伤血
	var r3 := hit(s, a0, mk({"armor": 30}), {"coeff": 1.0})
	ck(int(r3["armor_loss"]) == 20 and int(r3["hp_loss"]) == 0, "甲足：armor_loss=20 hp_loss=0")

	# 4) 破甲溢出：armor=5 → 5 进甲、15 溢出进人
	var r4 := hit(s, a0, mk({"armor": 5}), {"coeff": 1.0})
	ck(int(r4["armor_loss"]) == 5 and int(r4["hp_loss"]) == 15, "溢出：armor_loss=5 hp_loss=15")

	# 5) 人抗：res_phys=50 → hp_loss=out×0.5=10
	var r5 := hit(s, a0, mk({"res_phys": 50}), {"coeff": 1.0})
	ck(int(r5["hp_loss"]) == 10, "人抗50：hp_loss=10")

	# 6) 穿甲：pen=0.5、甲厚不破（armor=1000）→ 人分量 10、甲分量 10
	var r6 := hit(s, a0, mk({"armor": 1000}), {"coeff": 1.0, "armor_pen": 0.5})
	ck(int(r6["hp_loss"]) == 10 and int(r6["armor_loss"]) == 10, "穿甲0.5：人10 甲10")

	# 7) 格挡全域减伤：block_rate=100 恒格挡、block_power=50 → G=0.5 → hp_loss=10
	var r7 := hit(s, a0, mk({"block_rate": 100, "block_power": 50}), {"coeff": 1.0})
	ck(r7["blocked"] and int(r7["hp_loss"]) == 10, "格挡性能50：全域减伤×0.5 → hp_loss=10")

	# 8) 补正机制（通道保留、内容已迁走）：bonus{[atk]×0.5}=20×0.5=10（flat、不吃效能）→ out=30
	#    🔒 属性重做：四维已删，爪类 STR/DEX 补正已折进武器 mods；此条只守 _skill_bonus 通道本身
	var r8 := hit(s, a0, mk({}), {"coeff": 1.0, "bonus": {"stats": ["atk"], "mult": 0.5}})
	ck(is_equal_approx(float(r8["bonus"]), 10.0) and int(r8["hp_loss"]) == 30, "补正+10：out=30 hp_loss=30")

	# 9) 伤害属性与抗性归轨（§7.2 正字 + 🔒 属性重做 §5 两轨）：damage_category 保留细分（fire/holy…；原 damage_kind 已改词），
	#    减伤统一归轨 nature——res_nature=50 对火伤减半、物抗不参与。此条即元素归轨的判决点。
	var rf := hit(s, a0, mk({"res_nature": 50, "res_phys": 0}), {"coeff": 1.0, "damage_category": "fire"})
	ck(str(rf["damage_category"]) == "fire", "结果携带 damage_category=fire")
	ck(int(rf["hp_loss"]) == 10, "火伤取自然抗50 → hp_loss=10（元素归轨 nature）")
	#    神圣=自然伤害（🔒 §5）：holy 同轨取 res_nature
	var rh := hit(s, a0, mk({"res_nature": 50}), {"coeff": 1.0, "damage_category": "holy"})
	ck(int(rh["hp_loss"]) == 10, "神圣伤同取自然抗 → hp_loss=10")

	# 10) 规格招牌样例（docs/模块_战斗_设计.md「减伤链」验算：out=50 打进 甲20+甲抗50%+人抗20%）——
	#     到甲 50×0.5=25 → 破 20 甲、溢出 5×0.8=4 进人。锁「破甲溢出同时过甲抗+人抗」的双层减伤链
	#     （case4/5 从不交叉甲抗与人抗，此条补上；后续 eff/护甲重构漏乘/调序会在此 FAIL）。
	var t10 = mk({"HP": 100, "armor": 20, "armor_res_phys": 50, "res_phys": 20})
	var r10 := hit(s, a0, t10, {"coeff": 2.5})   # atk20×2.5 → out=50
	ck(is_equal_approx(float(r10["out"]), 50.0), "招牌样例 out=50")
	ck(int(r10["armor_loss"]) == 20 and int(r10["hp_loss"]) == 4, "双层减伤：armor_loss=20 hp_loss=4")
	ck(int(t10.stats["armor"]) == 0 and int(t10.stats["HP"]) == 96, "落甲/落血写回：armor=0 HP=96")

	# 11) 甲道归轨：fire 伤害打进厚甲目标，甲道须取 armor_res_nature（非 armor_res_phys）。
	#     armor_res_nature=50/armor_res_phys=0：归轨对→到甲 20×0.5=10；误取物理键→20。守护甲道后缀映射。
	var t11 = mk({"HP": 100, "armor": 100, "armor_res_nature": 50, "armor_res_phys": 0, "res_nature": 0})
	var r11 := hit(s, a0, t11, {"coeff": 1.0, "damage_category": "fire"})
	ck(int(r11["armor_loss"]) == 10 and int(r11["hp_loss"]) == 0, "火伤取甲自然抗50 → armor_loss=10（甲道归轨）")
	ck(int(t11.stats["armor"]) == 90, "落甲写回：armor=90")

	if _fail == 0:
		print("=== 全部断言 PASS ===")
	else:
		print("=== 失败 %d 项 ===" % _fail)
	quit(0 if _fail == 0 else 1)
