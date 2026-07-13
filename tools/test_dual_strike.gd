extends SceneTree
## 决策31 执行回归（🔒 docs/模块_技能_设计.md「决策31」）：
##  · 双武器连携：attack_segments 构成（主手段全额+副手段 weapon_source=off_hand）/ _do_attack 两段各自结算
##    （副手段天然吃 offhand_eff 链）/ AP＝DUAL_STRIKE_AP 常量 / 副手为盾·空手·双手武器 → 回单段
##  · 反应系数：借机 _resolve_aoo ×REACTION_RATE（0.75）——单段 15、连携两段 15+8 自动成立（golden 普攻路径零涉）
##  · 盾＝正常武器：盾可主手（EquipSlots）、主手持盾＝盾的 bws 作普攻（纯盾战士）
##  · 格挡休眠：手持武器 block mods 须 weapon_block≥1 才计；盾/防具/buff 来源恒计；件间取高照旧（§10.3）
## 确定性手法：命中钳 95、crit/block 归零 → 伤害只可能落在有限集合；rng 注入定序（s.rng.seed 先例）
## 逐种子扫描——任意命中的伤害值恒等于预期（系数错则无种子可产出预期值 → FAIL）。
## 无 UI Sandbox 实例直测（test_battleio 先例：_log/UI 全 null 守卫）；SkillDB/ItemDB 经 override 注入临时库。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_dual_strike.gd（退出码 0=PASS）

const SandboxScript := preload("res://Sandbox.gd")
const UnitC := preload("res://Unit.gd")
const SkillDB := preload("res://SkillDB.gd")
const ItemDB := preload("res://ItemDB.gd")
const ItemInstances := preload("res://ItemInstances.gd")
const EquipSlots := preload("res://EquipSlots.gd")

var _fail := 0
func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

# 裸单位（golden mk 同法）：清修正/装备，一套中性可控 stats——
# acc 200→hc 钳 95；crit/luck/finesse 归零→恒不暴击；block 0→恒不格挡；offhand_eff 50＝基线。
func mk(nm: String, fac: String, col: int, row: int):
	var u = UnitC.new(nm, fac, col, row)
	u.modifiers = []
	u.equipment = {}
	u.stats = {
		"HP": 500, "HP_max": 500, "armor": 0, "armor_max": 0,
		"AP_max": 4, "move": 4, "speed": 0, "sight": 5,
		"atk": 20, "atk_eff": 100, "def_eff": 100, "offhand_eff": 50,
		"acc": 200, "eva": 0, "crit_rate": 0, "crit_dmg": 150,
		"block_rate": 0, "block_power": 0,
		"res_phys": 0, "res_nature": 0, "will_fort": 0, "body_fort": 0,
		"finesse": 0, "agility": 0, "luck": 0, "resolve": 0,
		"armor_res_phys": 0, "armor_res_nature": 0,
		"dr_flat_human": 0, "dr_flat_armor": 0,
	}
	u.morale = 25
	return u

func _initialize() -> void:
	print("=== 决策31 双武器连携/反应系数/格挡休眠 测试开始 ===")
	# —— 临时技能库（bws 用；costs.ap 区分单段费与连携常量费）——
	var skills := [
		{"id": "d31_main", "name": "重斩", "active": true, "weapon_skill": true, "tags": [],
			"costs": {"ap": 2}, "cooldown": {"base": 0}, "max_level": 1,
			"target": {"enemy": true, "ally": false, "self": false}, "range": 1,
			"effects": [{"kind": "attack", "hits": [{"coeff": 1.0}]}]},
		{"id": "d31_off", "name": "快刺", "active": true, "weapon_skill": true, "tags": [],
			"costs": {"ap": 1}, "cooldown": {"base": 0}, "max_level": 1,
			"target": {"enemy": true, "ally": false, "self": false}, "range": 1,
			"effects": [{"kind": "attack", "hits": [{"coeff": 1.0}]}]},
		{"id": "d31_bash", "name": "盾击", "active": true, "weapon_skill": true, "tags": [],
			"costs": {"ap": 1}, "cooldown": {"base": 0}, "max_level": 1,
			"target": {"enemy": true, "ally": false, "self": false}, "range": 1,
			"effects": [{"kind": "attack", "hits": [{"coeff": 0.8}]}]},
	]
	var sf = FileAccess.open("user://test_d31_skills.json", FileAccess.WRITE)
	sf.store_string(JSON.stringify(skills, "  "))
	sf.close()
	SkillDB._path_override = "user://test_d31_skills.json"
	SkillDB.reload_data()
	# —— 临时物品库（武器+防具两路；不碰真数据）——
	var weapons := [
		{"id": "d31_sword", "name": "长剑", "slot": "main_hand", "tags": ["one_handed"], "bws": "d31_main"},
		{"id": "d31_dagger", "name": "短刀", "slot": "main_hand", "tags": ["one_handed"], "bws": "d31_off"},
		{"id": "d31_shield", "name": "圆盾", "slot": "off_hand", "tags": ["shield"], "bws": "d31_bash",
			"mods": [{"stat": "block_rate", "op": "flat", "value": 15},
				{"stat": "block_power", "op": "flat", "value": 35}]},
		{"id": "d31_parry", "name": "格挡剑", "slot": "main_hand", "tags": ["one_handed"], "bws": "d31_off",
			"mods": [{"stat": "block_rate", "op": "flat", "value": 10}]},
	]
	var wf = FileAccess.open("user://test_d31_weapons.json", FileAccess.WRITE)
	wf.store_string(JSON.stringify(weapons, "  "))
	wf.close()
	var armors := [
		{"id": "d31_plate", "name": "胸甲", "slot": "body", "tags": ["body"],
			"mods": [{"stat": "block_rate", "op": "flat", "value": 5}]},
	]
	var af = FileAccess.open("user://test_d31_armor.json", FileAccess.WRITE)
	af.store_string(JSON.stringify(armors, "  "))
	af.close()
	ItemDB._paths_override = {"weapon": "user://test_d31_weapons.json", "armor": "user://test_d31_armor.json"}
	ItemDB.reload_data()
	ItemInstances.clear()

	# —— 1) 普攻构成段 + AP 成本单口 ——
	var sb = SandboxScript.new()
	sb._new_grassland(7, 7)
	var a = mk("双持手", "player", 3, 3)
	a.equipment["main_hand"] = ItemInstances.create("d31_sword")
	a.equipment["off_hand"] = ItemInstances.create("d31_dagger")
	var d = mk("靶子", "enemy", 4, 3)
	sb.units = [a, d]
	ck(sb._state.attack_segments(a).size() == 1, "无 dual_strike 能力 → 单段构成")
	ck(sb._state.attack_ap_cost(a) == 2, "单段 AP＝主手技能费（costs.ap 2）")
	a.modifiers.append({"stat": "dual_strike", "op": "flat", "value": 1, "source": "skill:双武连携"})
	var segs: Array = sb._state.attack_segments(a)
	ck(segs.size() == 2 and str((segs[1] as Dictionary).get("weapon_source", "")) == "off_hand",
		"dual_strike=1 → 两段构成、副手段带 weapon_source=off_hand")
	ck(sb._state.DUAL_STRIKE_AP == 1 and sb._state.attack_ap_cost(a) == 1,
		"连携 AP＝DUAL_STRIKE_AP 常量 1（占位·数值轮调）")

	# —— 2) _do_attack 连携执行：两段各自独立结算、副手段吃 offhand_eff、AP 扣 1 ——
	# 伤害集合∈{0,10,20,30}：主手段全额 20、副手段 20×offhand_eff50%＝10；出现 30＝两段全中
	var both := false
	for seedv in range(1, 41):
		d.stats["HP"] = 500
		a.ap = 3
		a.morale = 25
		sb._state.rng.seed = seedv
		sb._do_attack(a, Vector2i(4, 3))
		ck(a.ap == 2, "连携攻击扣 DUAL_STRIKE_AP=1（seed %d 实剩 %d）" % [seedv, a.ap])
		var loss: int = 500 - int(d.stats["HP"])
		ck(loss in [0, 10, 20, 30], "连携伤害∈{0,10,20,30}（主20全额/副10＝×offhand_eff；实得 %d）" % loss)
		if loss == 30:
			both = true
			break
	ck(both, "样本内两段全中＝20+10=30（两段独立结算且副手段吃 offhand_eff 链）")

	# —— 3) 副手为盾/空手/双手武器 → 连携不激活回单段（AP 回技能费）——
	a.equipment["off_hand"] = ItemInstances.create("d31_shield")
	ck(sb._state.attack_segments(a).size() == 1, "副手为盾 → 回单段（决策31 非盾条件）")
	ck(sb._state.attack_ap_cost(a) == 2, "回单段 AP＝主手技能费 2")
	d.stats["HP"] = 500
	a.ap = 3
	a.morale = 25
	sb._state.rng.seed = 7
	sb._do_attack(a, Vector2i(4, 3))
	ck(a.ap == 1, "单段攻击扣技能费 2")
	ck((500 - int(d.stats["HP"])) in [0, 20], "单段只可能主手一击（0/20）")
	a.equipment.erase("off_hand")
	ck(sb._state.attack_segments(a).size() == 1, "副手空手 → 回单段")
	a.equipment["off_hand"] = int(a.equipment["main_hand"])   # 模拟双手武器占双槽（同 iuid）
	ck(sb._state.attack_segments(a).size() == 1, "双手武器占双槽 → 无独立副手回单段")
	a.equipment.erase("off_hand")

	# —— 4) 盾＝正常武器：盾进主手＝盾击作普攻（纯盾战士）——
	var pure = mk("纯盾", "player", 1, 1)
	ck(pure.equip("d31_shield", "main_hand"), "盾可装进主手（EquipSlots 资格放开）")
	ck(str(pure.basic_attack().get("name", "")) == "盾击", "主手持盾 → 盾的 bws（盾击）直接作普攻")
	ck(pure.effective_stat_f("block_rate") == 15.0, "主手盾格挡属性恒计（盾天然生效，与所在槽无关）")

	# —— 5) 反应系数（借机 ×REACTION_RATE=0.75）——
	# 任意命中伤害恒＝20×0.75＝15（若系数未生效会出现 20 → 集合断言 FAIL）
	var owner = mk("哨兵", "enemy", 3, 4)
	owner.equipment["main_hand"] = ItemInstances.create("d31_sword")
	var mover = mk("路过", "player", 3, 3)
	sb.units = [owner, mover]
	var hit15 := false
	for seedv in range(1, 41):
		mover.stats["HP"] = 500
		owner.morale = 25
		sb._state.rng.seed = seedv
		sb._resolve_aoo(owner, mover)
		var l2: int = 500 - int(mover.stats["HP"])
		ck(l2 in [0, 15], "借机伤害＝20×0.75=15（非 20＝反应系数生效；实得 %d）" % l2)
		if l2 == 15:
			hit15 = true
	ck(hit15, "样本内出现借机命中（15）")
	# 连携借机＝0.75×两段自动成立：主 15 + 副 round(20×0.5×0.75=7.5)=8 → 全中 23
	owner.equipment["off_hand"] = ItemInstances.create("d31_dagger")
	owner.modifiers.append({"stat": "dual_strike", "op": "flat", "value": 1, "source": "skill:双武连携"})
	var full := false
	for seedv in range(1, 41):
		mover.stats["HP"] = 500
		owner.morale = 25
		sb._state.rng.seed = seedv
		sb._resolve_aoo(owner, mover)
		var l3: int = 500 - int(mover.stats["HP"])
		ck(l3 in [0, 8, 15, 23], "连携借机∈{0,8,15,23}（0.75×两段；实得 %d）" % l3)
		if l3 == 23:
			full = true
			break
	ck(full, "连携借机两段全中＝15+8（0.75 对两段自动成立、勿特判验证）")

	# —— 6) 格挡休眠（🔒 决策31：手持武器 block 属性须 weapon_block 激活；盾/防具/buff 恒计）——
	var g = mk("格挡手", "player", 5, 5)
	ck(g.equip("d31_parry"), "装格挡剑（主手，带 block_rate 10）")
	ck(g.effective_stat_f("block_rate") == 0.0, "武器格挡默认休眠：无 weapon_block 不计（10→0）")
	g.modifiers.append({"stat": "weapon_block", "op": "flat", "value": 1, "source": "skill:格挡"})
	ck(g.effective_stat_f("block_rate") == 10.0, "weapon_block≥1 → 武器格挡激活（=10）")
	g.remove_modifiers_by_source("skill:格挡")
	ck(g.effective_stat_f("block_rate") == 0.0, "摘除能力键 → 回休眠（门控反向）")
	ck(g.equip("d31_shield"), "副手装盾（block_rate 15）")
	ck(g.effective_stat_f("block_rate") == 15.0, "盾恒计（无需激活）；休眠武器件不参与取高")
	g.modifiers.append({"stat": "weapon_block", "op": "flat", "value": 1, "source": "skill:格挡"})
	ck(g.effective_stat_f("block_rate") == 15.0, "激活后件间取高 max(10,15)=15（🔒 §10.3 只用一件器械格挡）")
	var t = mk("甲士", "player", 6, 5)
	ck(t.equip("d31_plate"), "装胸甲（防具带 block_rate 5）")
	ck(t.effective_stat_f("block_rate") == 5.0, "防具来源格挡恒计（不受 weapon_block 影响）")
	t.modifiers.append({"stat": "block_rate", "op": "flat", "value": 5, "source": "buff:架势"})
	ck(t.effective_stat_f("block_rate") == 10.0, "buff 非装备源恒计并叠加其上（5+5）")

	# —— 清场：撤 override、清实例 ——
	SkillDB._path_override = ""
	SkillDB.reload_data()
	ItemDB._paths_override = {}
	ItemDB.reload_data()
	ItemInstances.clear()
	sb.free()

	if _fail == 0:
		print("=== 全部断言 PASS ===")
	else:
		print("=== 失败 %d 项 ===" % _fail)
	quit(0 if _fail == 0 else 1)
