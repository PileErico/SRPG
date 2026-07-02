extends RefCounted
## 单位数据（sandbox 起步版）。
## 身份字段固定；战斗属性放在 stats 字典里，方便“慢慢添加”——
## 每加一条属性，侧栏（与将来的 token）自动反映。
## 属性口径见 docs/单位系统设计.md「第一层属性」：默认值可为 0（面板 + 修正）。

const STANCE_TAGS := ["player", "ally", "enemy", "neutral"]   # 阵营立场 tag
const ItemInstances := preload("res://ItemInstances.gd")     # 物品实例门面（每件装备独立实例；消费合成视图）
const TraitDB := preload("res://TraitDB.gd")                 # 特性注册表（特性查表）
const SkillDB := preload("res://SkillDB.gd")                 # 技能注册表（技能查表）
const EquipSlots := preload("res://EquipSlots.gd")          # 槽位 / 槽位资格（tag 驱动装备资格）

var unit_name := "新兵"
var col := 0
var row := 0

# 单位 tag（移动型 / 阵营立场 / 特性 / 状态 共用一张词表，见 docs/单位系统设计.md「tag 体系」）。
# 默认地面单位（无 flying/spectral → 按地块基础 cost、不可进深水）；阵营立场 tag 由 faction 读写。
var tags := ["ground"]

# 阵营立场：真值存在 tags 里（player/ally/enemy/neutral 之一）；faction 是便捷读写口，
# 符合「tag 统一判断」——效果可直接查 tag（如「对所有 enemy +X」）。
var faction: String:
	get:
		for t in STANCE_TAGS:
			if tags.has(t):
				return t
		return "neutral"
	set(value):
		for t in STANCE_TAGS:
			tags.erase(t)
		if not tags.has(value):
			tags.append(value)

# —— 身份 / 养成（非战斗数值，显示在角色状态页左区）——
var uid := 0                 # 存档域唯一 id 🔒（WorldState.mint_uid 分配，unit/item 共用计数器；0=未分配＝临时对象，如沙盒测试单位）
var level := 1               # 等级
var exp := 0                 # 当前经验
var exp_max := 100           # 升级所需经验
var trait_id := ""           # 特性 id（空=无；具名角色固定专属、通用角色随机，见 docs）。注：trait 是 GDScript 保留字，故用 trait_id；改用 set_trait() 设定以挂上加成
var portrait := ""           # 头像图片路径（res://...，角色状态页大图），空=占位
var icon := ""               # 棋子图标路径（res://...，叠在圆形 token 上），空=不画

# 第一层属性面板（详见 docs/单位系统设计.md「第一层属性」）。
# 这些是“基础值/上限”，默认值可为 0（面板 + 修正）；当前 turn 的剩余量是运行时状态，见下。
var stats := {
	# 四维主属性（支撑技能系统：力量 STR / 灵巧 DEX / 智力 INT / 体力 STA；默认占位 5，机制待定）
	"STR": 5, "DEX": 5, "INT": 5, "STA": 5,
	# 生存
	"HP_max": 10, "HP": 10,
	"armor_max": 0, "armor": 0,   # 护甲值（承伤池，来自防具，默认 0）
	# 行动
	"AP_max": 2,                  # AP 上限：每 turn 开始刷新到此值（行动经济基础 2）
	"move": 6,                    # 移动力：一次「移动动作」（花 1 AP）获得的移动点数
	"speed": 5,                   # 速度：出手顺序（大→小；同速玩家优先）
	"sight": 5,                   # 视野半径：能看多远（六边形距离）；被 LOS 裁剪。夜/天气等环境挂修正。见 docs/感知系统.md
	# 进攻
	"atk": 5,                     # 攻击 → 武器 skill 物理伤害
	"mag": 0,                     # 理术 → 魔法 spell 伤害 + 施加异常强度
	"atk_eff": 100,              # 攻击效能(%)：最终增伤乘数层，基线 100
	"def_eff": 100,              # 防御效能(%)：最终减伤乘数层，基线 100
	"acc": 90,                    # 命中
	"eva": 10,                    # 闪避
	"crit_rate": 5,               # 暴击率(%)
	"crit_dmg": 150,              # 暴击威力(%)，未暴击=100
	"block_rate": 0,              # 格挡率(%)
	"block_power": 0,             # 格挡性能(%)
	# 抗性（物理 / 异常 + 四元素；详见 docs/单位系统设计.md「元素/魔法系统」）
	"res_phys": 0,                # 物理抗性(%)
	"res_status": 0,              # 异常抗性(%)：抵抗纯异常施加
	"res_fire": 0,                # 火焰抗性(%)
	"res_thunder": 0,             # 雷电抗性(%)
	"res_ice": 0,                 # 冰冻抗性(%)
	"res_holy": 0,                # 神圣抗性(%)
}

# —— 运行时回合状态（不是面板属性；每 turn 开始重置）——
var ap := 0           # 本 turn 剩余 AP
var move_points := 0  # 本 turn 剩余移动点（买移动动作时按 move 注入，可分批花、零头作废）

# —— 挂在身上的效果 / buff（修正对象的载体；将来由修正管线填充，见 docs 装备/修正管线）——
# 每条形如 {name, kind:"buff"/"debuff", permanent:bool, duration:int(按 round)}；状态页右下列表读它。
var effects := []

# —— 修正管线：装备/buff/养成/地块/元素 都把“修正对象”挂这（统一来源）——
# 每条 = {stat, op:"flat"/"pct"/"eff", value, source, nature?}；effective_stat 三层解析。
var modifiers := []

# —— 已装备：slot_id -> 实例 uid(int)（双手武器占 main_hand + off_hand 两槽、同一 uid）——
# 物品数据一律经 ItemInstances.view(uid) 取合成视图（模板 ⊕ 词条/耐久/状态）。
var equipment := {}

# —— 已学技能：skill_id -> {level:int(1..max), cd:int(剩余冷却,按本单位 turn), uses:int(本战剩余次数)} ——
# 学过 = 键存在；等级 / 冷却 / 本战次数 都存这。技能定义（数值/门槛/效果）查 SkillDB，不在此重复。
var skills := {}

# —— 敌方 AI 警觉 / 仇恨（友方单位忽略这些字段；三种触发任一满足即激活，可组合）——
# ai_threat：①视野感知——敌人进入它的「视野(sight) 且有视线(LOS)」就警觉（默认开）。见 docs/感知系统.md。
# ai_region：②区域触发——关卡设计者指定的区域 id（如要塞某房间）；敌人进入该区域即激活，与本单位移动/攻击无关。空=不用。
# ai_group：③连锁——仇恨编组 id（非空时组内任一被激活则全组一起被激活）。
# ai_aggroed：运行时——是否已进入战斗（激活后持续追击，不再回到休眠）。
var ai_threat := true
var ai_region := ""
var ai_group := ""
var ai_aggroed := false

# 四舍五入到 1 位小数（属性统一精度：算到小数点后一位，再往后四舍五入）。
static func round1(v: float) -> float:
	return round(v * 10.0) / 10.0

# 有效属性（保留 1 位小数）= 基础面板 + 修正：base + Σflat + base×Σpct%。面板显示用这个。
# 去重规则 🔒：同一 source（同名 buff/技能）对同一 (stat, op) 只算一次、**取高**（重复挂不叠加、数值不同取大）；
# 不同 source 才互相累加。无 source 标识的修正各自独立计入。
func effective_stat_f(key: String) -> float:
	var base := float(stats.get(key, 0))
	var flat := 0.0
	var pct := 0.0
	var flat_src := {}   # source → 该源对本 stat 的 flat 取高值
	var pct_src := {}
	for m in modifiers:
		if str(m.get("stat", "")) != key:
			continue
		var v := float(m.get("value", 0))
		var src := str(m.get("source", ""))
		match str(m.get("op", "flat")):
			"flat":
				if src == "": flat += v
				else: flat_src[src] = maxf(flat_src.get(src, v), v)
			"pct":
				if src == "": pct += v
				else: pct_src[src] = maxf(pct_src.get(src, v), v)
	for s in flat_src: flat += flat_src[s]
	for s in pct_src: pct += pct_src[s]
	return round1(base + flat + base * pct / 100.0)

# —— 效能层（修正三层的第三层 op:"eff"，乘算）——
# 增益向效能桶（攻击效能/命中效能…）：面板基（该键是面板效能 stat 时取 值/100，否则 1.0）× Π(1 + 各源%/100)。
# 规则 🔒：效能一律乘算；不同 source 互相乘算；同一 source 只计一次、取高（同名技能/buff 不叠加、取大）。
# **下限 clamp 🔒**：每个因子 max(0,…)——单条 −100% 即封顶为 0（攻击效能归零＝不造成伤害），**永不为负**，
# 防止负因子在减伤链里翻转伤害符号（＝治疗）。上限不封（高增伤合法）。
func eff_mult(bucket: String) -> float:
	var base := maxf(0.0, (effective_stat_f(bucket) / 100.0) if stats.has(bucket) else 1.0)
	var by_src := {}
	var prod := 1.0
	for m in modifiers:
		if str(m.get("op", "")) != "eff" or str(m.get("stat", "")) != bucket:
			continue
		var v := float(m.get("value", 0))
		var src := str(m.get("source", ""))
		if src == "": prod *= maxf(0.0, 1.0 + v / 100.0)
		else: by_src[src] = maxf(by_src.get(src, v), v)
	for s in by_src: prod *= maxf(0.0, 1.0 + by_src[s] / 100.0)
	return base * prod

# 减免向效能：Π(1 − 各源%/100)（守方闪避效能之于攻方命中、减伤效能之于伤害）。mod-only，无面板基；同源取高。
# **下限 clamp 🔒**：每个因子 max(0,…)——单条减免 ≥100% 即封顶为 0（＝对该项免疫），**永不为负**（同上防翻转）。
func eff_reduce(bucket: String) -> float:
	var by_src := {}
	var prod := 1.0
	for m in modifiers:
		if str(m.get("op", "")) != "eff" or str(m.get("stat", "")) != bucket:
			continue
		var v := float(m.get("value", 0))
		var src := str(m.get("source", ""))
		if src == "": prod *= maxf(0.0, 1.0 - v / 100.0)
		else: by_src[src] = maxf(by_src.get(src, v), v)
	for s in by_src: prod *= maxf(0.0, 1.0 - by_src[s] / 100.0)
	return prod

# 整数版（出手顺序 / AP / 可达 / 战斗判定等用）：有效值四舍五入到整数。
func effective_stat(key: String) -> int:
	return int(round(effective_stat_f(key)))

# 由四维派生的第一层属性键（这些 stats 的“基础值”＝四维公式算出，装备/buff 的修正再叠在其上）。
const DERIVED_KEYS := ["HP_max", "atk", "mag", "acc", "eva",
	"block_rate", "block_power", "crit_rate", "crit_dmg", "res_status"]

# 重算「四维 → 第一层属性」基础值（写回 stats，作为该属性的 base；effective_stat 再叠修正）。
# 用 effective 四维（含特性/装备对四维的修正）→ 特性加成能传导到派生属性。四维或其修正变化后须调用。
func recompute_derived() -> void:
	var strv := effective_stat_f("STR")
	var dex := effective_stat_f("DEX")
	var intl := effective_stat_f("INT")
	var sta := effective_stat_f("STA")
	stats["HP_max"] = round1(sta * 3.0)                          # 生命 = 体力 × 3
	stats["atk"] = round1(strv * 0.5)                            # 攻击 = 力量 × 0.5
	stats["mag"] = round1(intl * 0.5)                            # 理术 = 智力 × 0.5
	stats["acc"] = round1(dex + 30.0)                            # 命中 = 灵巧 + 30
	stats["eva"] = round1(dex)                                   # 闪避 = 灵巧
	stats["block_rate"] = round1((dex + strv) * 0.1)             # 格挡率 = (灵巧+力量) × 0.1
	stats["block_power"] = round1(strv * 0.2)                    # 格挡性能 = 力量 × 0.2
	stats["crit_rate"] = round1(dex * 0.5)                       # 暴击率 = 灵巧 × 0.5
	stats["crit_dmg"] = round1(150.0 + (strv + dex))            # 暴伤% = 150 + (力量+灵巧)（即 1.5+(力量+敏捷)×0.01）
	stats["res_status"] = round1((sta + intl) * 0.1)            # 异常抵抗 = (体力+智力) × 0.1

# 把当前生命/护甲注满到上限（生成时调用；上限 = effective，含装备/特性）。
func init_vitals() -> void:
	stats["HP"] = effective_stat("HP_max")
	stats["armor"] = effective_stat("armor_max")

# 能否装备：①特性限制（如「天性武者」no_weapon → 不能装带 attack 的武器；**天生武器 innate 豁免**）②物品 requires 的 tag 须全有。
func can_equip(item: Dictionary) -> bool:
	var t = TraitDB.get_trait(trait_id)
	if t != null and t.get("no_weapon", false) and item.has("attack") and not item.get("innate", false):
		return false
	for req in item.get("requires", []):
		if not tags.has(req):
			return false
	return true

# 物品能否装进指定槽（完整资格 = 特性/requires + tag 驱动的槽位资格）。供装备 UI 校验「拖到该槽是否合法」。
func can_equip_in(item: Dictionary, slot: String) -> bool:
	return can_equip(item) and EquipSlots.accepts(slot, item)

# 设定特性（按 id）：换特性先清旧特性的修正，再把新特性的属性加成挂进修正管线（source="trait"）。
func set_trait(id: String) -> void:
	remove_modifiers_by_source("trait")
	trait_id = id
	var t = TraitDB.get_trait(id)
	if t == null:
		return
	for m in t.get("mods", []):
		var mod: Dictionary = m.duplicate()
		mod["source"] = "trait"
		mod["source_label"] = str(t.get("name", id))
		modifiers.append(mod)
	recompute_derived()   # 特性可能改四维（如天性武者 +体力）→ 重算派生属性

# 装备（模板 id 便捷入口）：从模板**造新实例**再装——原型/预设/沙盒路径零改动。
# 装失败回收孤儿实例。成功 true。
func equip(item_id: String) -> bool:
	var iuid := ItemInstances.create(item_id)
	if iuid == 0:
		return false
	if equip_instance(iuid):
		return true
	ItemInstances.destroy(iuid)
	return false

# 装备一件**已存在的实例**（按实例 iuid）；双手武器占 main_hand+off_hand（同一 iuid）。
# campaign 读档重挂 / 将来背包·铁匠都走这条。目标槽被天生武器占用＝装备失败（innate 永不被顶）。
func equip_instance(iuid: int) -> bool:
	var item = ItemInstances.view(iuid)
	if item == null or not can_equip(item):
		return false
	var primary := str(item.get("slot", ""))
	if primary == "":
		return false
	if not EquipSlots.accepts(primary, item):   # tag 驱动槽位资格（innate 豁免、旧物品回退 slot 字段）
		return false
	var slots := ["main_hand", "off_hand"] if item.get("two_handed", false) else [primary]
	for s in slots:
		if equipment.has(s):
			var occ = ItemInstances.view(int(equipment[s]))
			if occ != null and occ.get("innate", false):
				return false   # innate 占槽不可顶（unequip 对 innate 早退，硬写会泄漏其烘焙修正）
	for s in slots:
		if equipment.has(s):
			unequip(s)
	for s in slots:
		equipment[s] = iuid
	_apply_item_mods(item, iuid)
	recompute_derived()   # 装备/词条可改四维 → 派生属性即时传导（与 set_trait 对齐）
	return true

# 卸下某槽的物品（双手武器从任一槽卸都连带清两槽 + 去掉它的修正，按实例 iuid 配对）。
# 天生武器（innate）永不卸下/缴械——直接忽略。卸下不销毁实例（将来进背包）。
func unequip(slot: String) -> void:
	if not equipment.has(slot):
		return
	var iuid: int = int(equipment[slot])
	var item = ItemInstances.view(iuid)
	if item != null and item.get("innate", false):
		return
	remove_modifiers_by_source_prefix("equip:%d:" % iuid)
	var to_clear := []
	for s in equipment:
		if int(equipment[s]) == iuid:
			to_clear.append(s)
	for s in to_clear:
		equipment.erase(s)
	recompute_derived()   # 对称：卸下也即时传导四维派生

# 收编迁移用（WorldState._adopt_equipment）：装备实例换 uid——equipment 槽值 + 修正 source 前缀同步重写。
func remap_equip_uid(old_uid: int, new_uid: int) -> void:
	for s in equipment:
		if int(equipment[s]) == old_uid:
			equipment[s] = new_uid
	var oldp := "equip:%d:" % old_uid
	var newp := "equip:%d:" % new_uid
	for m in modifiers:
		var src := str(m.get("source", ""))
		if src.begins_with(oldp):
			m["source"] = newp + src.substr(oldp.length())

# 无武器时的基础攻击（徒手）；装了武器则用其 attack skill（兑现“换武器=换攻击”）。
const UNARMED_ATTACK := {
	"name": "徒手", "coeff": 1.0, "range": 1, "ap_cost": 1,
	"damage_kind": "physical", "tags": [], "aoe": null,
}

# 飞行状态：带 flying tag = 在空中。比路兹起飞后用副手（足爪/抓取），落地用主手（翼爪/撕裂）。
func is_airborne() -> bool:
	return tags.has("flying")

# 能否自主起飞/降落（飞行切换能力）。暂以 harpy 种族门控（比路兹）；将来可扩为专门能力 tag。
func can_fly() -> bool:
	return tags.has("harpy")

# 切换地/空：互斥 ground/flying tag（flying tag 已驱动地形成本/可进深水/森林掩蔽豁免）。
func set_airborne(v: bool) -> void:
	if v:
		tags.erase("ground")
		if not tags.has("flying"):
			tags.append("flying")
	else:
		tags.erase("flying")
		if not tags.has("ground"):
			tags.append("ground")

# 基础攻击：空中优先副手（足爪/抓取）、地面优先主手（翼爪/撕裂）；该手无武器则退另一手 / 徒手。
# 经合成视图取（深拷）——调用方拿到的 attack 不再是共享模板引用。
func basic_attack() -> Dictionary:
	var primary := "off_hand" if is_airborne() else "main_hand"
	for slot in [primary, "main_hand", "off_hand"]:
		var item = ItemInstances.view(int(equipment.get(slot, 0)))
		if item != null and item.has("attack"):
			return item["attack"]
	return UNARMED_ATTACK

# 挂装备修正：每条 mod 唯一 source（"equip:<实例iuid>:<序号>"）——同件装备的模板 mod 与词条 mod
# 即使同 stat 同 op 也各自生效（effective_stat 的「同 source 去重取高」只该压重复 buff，不该吃词条）。
func _apply_item_mods(item: Dictionary, iuid: int) -> void:
	var label := str(item.get("name", ""))
	var idx := 0
	for m in item.get("mods", []):
		var mod: Dictionary = m.duplicate()
		mod["source"] = "equip:%d:%d" % [iuid, idx]
		mod["source_label"] = label   # 人类可读来源名（tooltip 用）
		modifiers.append(mod)
		idx += 1

func remove_modifiers_by_source(source: String) -> void:
	modifiers = modifiers.filter(func(m): return m.get("source", "") != source)

# 按前缀摘修正（装备实例的多条 mod 共享 "equip:<uid>:" 前缀）
func remove_modifiers_by_source_prefix(prefix: String) -> void:
	modifiers = modifiers.filter(func(m): return not str(m.get("source", "")).begins_with(prefix))

# ============ 技能（已学状态 / 学习 / 冷却 / 本战次数）============
# 数值口径：冷却 = floor(base + 智力×per_int)（≥0）；本战次数 = floor(base + 智力×per_int)（≥1）。
# 智力取 effective（含装备/特性修正）。

func has_skill(id: String) -> bool:
	return skills.has(id)

# 已学等级（未学 = 0）
func skill_level(id: String) -> int:
	return int(skills.get(id, {}).get("level", 0))

# 冷却上限（回合，按本单位的 turn 计）
func skill_cooldown_max(def) -> int:
	var cd = def.get("cooldown", {})
	var v := float(cd.get("base", 0)) + effective_stat_f("INT") * float(cd.get("per_int", 0))
	return maxi(0, int(floor(v)))

# 本战使用次数上限（至少 1）
func skill_uses_max(def) -> int:
	var u = def.get("uses_per_battle", {})
	var v := float(u.get("base", 0)) + effective_stat_f("INT") * float(u.get("per_int", 0))
	return maxi(1, int(floor(v)))

# 学习 / 升级一个技能（按 def.max_level 封顶）；首学初始化冷却=0、本战次数=满。返回新等级（0=失败）。
func learn_skill(id: String) -> int:
	var def = SkillDB.get_skill(id)
	if def == null:
		return 0
	var maxl := int(def.get("max_level", 1))
	if skills.has(id):
		skills[id]["level"] = mini(int(skills[id]["level"]) + 1, maxl)
	else:
		skills[id] = {"level": 1, "cd": 0, "uses": skill_uses_max(def)}
	return int(skills[id]["level"])

# 是否可立即施放：已学 + 冷却就绪 + 本战还有次数（不含 AP，AP 由调用方另查）
func skill_ready(id: String) -> bool:
	if not skills.has(id):
		return false
	return int(skills[id].get("cd", 0)) <= 0 and int(skills[id].get("uses", 0)) > 0

# 施放后：进入冷却 + 扣本战次数
func consume_skill(id: String, cd: int) -> void:
	if not skills.has(id):
		return
	skills[id]["cd"] = maxi(0, cd)
	skills[id]["uses"] = maxi(0, int(skills[id].get("uses", 0)) - 1)

# 战斗开始：所有已学技能冷却清零、本战次数按当前智力重置
func reset_skill_charges() -> void:
	for id in skills:
		var def = SkillDB.get_skill(id)
		if def == null:
			continue
		skills[id]["cd"] = 0
		skills[id]["uses"] = skill_uses_max(def)

func _init(p_name := "新兵", p_faction := "player", p_col := 0, p_row := 0) -> void:
	unit_name = p_name
	faction = p_faction
	col = p_col
	row = p_row
	recompute_derived()   # 由默认四维(5/5/5/5)算出一套派生基础；设四维/特性后会再重算
	init_vitals()

# turn 开始：AP 刷新到上限，移动点清零（上一 turn 零头作废），技能冷却各 −1（按本单位 turn 计）。
func refresh_for_turn() -> void:
	ap = int(stats.get("AP_max", 0))
	move_points = 0
	for id in skills:
		var c := int(skills[id].get("cd", 0))
		if c > 0:
			skills[id]["cd"] = c - 1
