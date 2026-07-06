extends RefCounted
## 单位数据（sandbox 起步版）。
## 身份字段固定；战斗属性放在 stats 字典里，方便“慢慢添加”——
## 每加一条属性，侧栏（与将来的 token）自动反映。
## 属性口径 🔒 docs/属性与成长系统.md：四维已删——基础值=种族底值（RaceDB 写入，缺省=人类基线），
## 装备/熟练度/perk 经修正管线叠加；等级零数值。

const STANCE_TAGS := ["player", "ally", "enemy", "neutral"]   # 阵营立场 tag
const ItemInstances := preload("res://ItemInstances.gd")     # 物品实例门面（每件装备独立实例；消费合成视图）
const StatMeta := preload("res://StatMeta.gd")               # stat 元数据单一源（派生键/序列化白名单）
const TraitDB := preload("res://TraitDB.gd")                 # 特性注册表（特性查表）
const SkillDB := preload("res://SkillDB.gd")                 # 技能注册表（技能查表）
const ProfDB := preload("res://ProfDB.gd")                   # 技艺（熟练度域）注册表（🔒 属性与成长系统.md §2）
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
var proto_id := ""           # 来源原型 id（图鉴编号/击杀统计按它归类；空=手捏单位）
var race_id := ""            # 种族 id（data/races.json；RaceDB.apply_to 写入种族底值时一并记下。空=引擎默认基线）
# 派系归属＝ tag（`camp_<factions.json id>`，见 data/tags.json cat "camp"）——走 tags 统一判断，不设专门字段。
# 区别于 faction(阵营立场 player/ally/enemy/neutral，关卡决定)：camp 是单位内在派系（帝国/流寇…），影响声望/敌对(FactionDB)。
var level := 1               # 等级
var exp := 0                 # 当前经验
var exp_max := 100           # 升级所需经验
var injured_until := 0       # 重伤休整到期时刻（clock_hours；0/过期=健康。战后 BattleIO 写；时长细则待 §2.3）

# —— 死门（战斗运行时态，不入档；规格见需求 §1.11 🔒）——
var door_gauge := 0          # 死门条 -3~+3（-3 倒下〔非铁人重伤离场/铁人真死〕；+3 自爬回）
var door_checks := 0         # 已检定次数（每回合难度 15+5×次数）
var last_hit_by = null       # 最后命中本单位的攻击者（击杀归属用；运行时引用、不入档）
var trait_id := ""           # 特性 id（空=无；具名角色固定专属、通用角色随机，见 docs）。注：trait 是 GDScript 保留字，故用 trait_id；改用 set_trait() 设定以挂上加成
var portrait := ""           # 头像图片路径（res://...，角色状态页大图），空=占位
var icon := ""               # 棋子图标路径（res://...，叠在圆形 token 上），空=不画

# 第一层属性面板（详见 docs/单位系统设计.md「第一层属性」）。
# 这些是“基础值/上限”，默认值可为 0（面板 + 修正）；当前 turn 的剩余量是运行时状态，见下。
var stats := {
	# 生存
	"HP_max": 15, "HP": 15,
	"armor_max": 0, "armor": 0,   # 护甲值（承伤池，来自防具，默认 0）
	# 行动
	"AP_max": 2,                  # AP 上限：每 turn 开始刷新到此值（行动经济基础 2）
	"move": 6,                    # 移动力：一次「移动动作」（花 1 AP）获得的移动点数
	"speed": 5,                   # 速度：出手顺序（大→小；同速玩家优先）
	"sight": 5,                   # 视野半径：能看多远（六边形距离）；被 LOS 裁剪。夜/天气等环境挂修正。见 docs/感知系统.md
	# 进攻 / 防御（默认=人类基线，与 data/races.json human 一致；武器/熟练度/perk 经修正管线叠加）
	"atk": 2.5,                   # 攻击面板（🔒 攻击来自武器：底值极低，主要由武器 mod 提供）
	"atk_eff": 100,              # 攻击效能(%)：最终增伤乘数层，基线 100
	"def_eff": 100,              # 防御效能(%)：最终减伤乘数层，基线 100
	"acc": 35,                    # 命中
	"eva": 5,                     # 闪避
	"crit_rate": 2.5,             # 暴击率(%)
	"crit_dmg": 160,              # 暴击威力(%)，未暴击=100
	"block_rate": 1,              # 格挡率(%)
	"block_power": 1,             # 格挡性能(%)
	# 抗性四轨 🔒（docs/属性与成长系统.md §5）：抗性=百分比减伤（人/甲分算）；强韧=异常豁免掷（防具永不提供）
	"res_phys": 0,                # 物理抗性(%)：全部物理伤害
	"res_nature": 0,              # 自然抗性(%)：全部元素伤害（含神圣）
	"will_fort": 0,               # 意志强韧(%)：非物质异常豁免（眩晕/恐惧/混乱…）
	"body_fort": 0,               # 肉体强韧(%)：物质异常豁免（寒冷/麻痹/流血…）
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

# —— 技艺（熟练度域）🔒 docs/属性与成长系统.md §2 ——
# 三态：未学（prof_known 无）→ 已学（可装载，生疏起步）→ 阶段成长。熟练度永不丢失（卸下=冻结）。
# 装载=总开关：装载中＝阶段补正（prof:<id> 修正）+perk 生效+可涨；定义查 ProfDB，不在此重复。
var prof_xp := {}       # 域id -> 累计熟练度（int；卸下冻结不清零）
var prof_known := []    # 已学域 id（师承/自悟解锁「已学」；未学不可装载）
var prof_slots := []    # 已装载域 id（≤ prof_slot_capacity()；非战斗可随时换）

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

# 一次「移动动作」（1 AP）获得的移动点——**唯一口径＝effective**（含装备/词条/buff 修正）。
# 预览范围(_dijkstra)与实际购点(玩家/AI/_move_budget)都必须读这里，禁止再读裸 stats["move"]。
func move_allowance() -> int:
	return int(effective_stat("move"))

# 把当前生命/护甲注满到上限（生成时调用；上限 = effective，含装备/特性）。
func init_vitals() -> void:
	stats["HP"] = effective_stat("HP_max")
	stats["armor"] = effective_stat("armor_max")

# 获得经验（战后结算/击杀归属）：升级循环。返回升了几级。
# 🔒 属性重做（docs/属性与成长系统.md §1）：等级零数值——属性点/技能点已废除；
# 升级的意义=技艺槽（1/5/9/13/17）与职业树层（3/6/9/12/15/18）的解锁节拍。
func gain_exp(n: int) -> int:
	var levels := 0
	exp += maxi(0, n)
	while exp >= exp_max and exp_max > 0:
		exp -= exp_max
		level += 1
		levels += 1
		exp_max = int(ceil(exp_max * 1.2))   # 占位曲线（数值层后调）
	return levels

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

# 装备（模板 id 便捷入口）：从模板**造新实例**再装——原型/预设/沙盒路径零改动。
# 装失败回收孤儿实例。成功 true。target_slot 非空＝指定目标槽（单手武器装进副手等，见 equip_instance）。
func equip(item_id: String, target_slot := "") -> bool:
	var iuid := ItemInstances.create(item_id)
	if iuid == 0:
		return false
	if equip_instance(iuid, target_slot):
		return true
	ItemInstances.destroy(iuid)
	return false

# 装备一件**已存在的实例**（按实例 iuid）；双手武器占 main_hand+off_hand（同一 iuid）。
# campaign 读档重挂 / 将来背包·铁匠都走这条。目标槽被天生武器占用＝装备失败（innate 永不被顶）。
# target_slot 非空＝**指定放进哪个槽**（如单手武器装进 off_hand 双持；须 EquipSlots.accepts 该槽）；空＝按物品 slot 字段（默认，旧行为零改动）。
func equip_instance(iuid: int, target_slot := "") -> bool:
	var item = ItemInstances.view(iuid)
	if item == null or not can_equip(item):
		return false
	var primary := target_slot if target_slot != "" else str(item.get("slot", ""))
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
# unarmed tag：喂养「体术」技艺（ProfDB match_tags）。
const UNARMED_ATTACK := {
	"name": "徒手", "coeff": 1.0, "range": 1, "ap_cost": 1,
	"damage_kind": "physical", "tags": ["unarmed"], "aoe": null,
}

# 飞行状态：带 flying tag = 在空中。比路兹起飞后主手换足爪（抓取）、落地换翼爪（撕裂）——见 set_airborne 换手。
func is_airborne() -> bool:
	return tags.has("flying")

# 能否自主起飞/降落（飞行切换能力）。暂以 harpy 种族门控（比路兹）；将来可扩为专门能力 tag。
func can_fly() -> bool:
	return tags.has("harpy")

# 切换地/空：互斥 ground/flying tag（flying tag 已驱动地形成本/可进深水/森林掩蔽豁免）+ 比路兹式起降换手。
func set_airborne(v: bool) -> void:
	if v:
		tags.erase("ground")
		if not tags.has("flying"):
			tags.append("flying")
	else:
		tags.erase("flying")
		if not tags.has("ground"):
			tags.append("ground")
	_sync_hands_to_state()

# 比路兹式「起降换手」🔒（§6.3）：让当前地/空状态偏好的那把武器住主手——普攻恒读主手，故起降即自动切爪、
# 且活跃爪始终在主手不吃副手惩罚。数据驱动：仅当主手武器 attack.prefer 与当前状态不符、且副手武器偏好当前状态
# 时对调 equipment 两 uid（不走 equip/unequip：innate 爪装卸会早退/泄漏烘焙修正）。无 prefer 的角色永不触发。
func _sync_hands_to_state() -> void:
	var state := "air" if is_airborne() else "ground"
	var mh_pref := _weapon_prefer(int(equipment.get("main_hand", 0)))
	if mh_pref == state:
		return   # 主手已偏好当前状态，无需换
	var oh_pref := _weapon_prefer(int(equipment.get("off_hand", 0)))
	if oh_pref == state and mh_pref != "":   # 需要一对 prefer 才置换（单侧无 prefer 不动）
		var tmp = equipment.get("main_hand", 0)
		equipment["main_hand"] = equipment.get("off_hand", 0)
		equipment["off_hand"] = tmp

# 读某槽武器的 attack.prefer（"ground"/"air"）；无武器/无 attack/无 prefer → 空串。
func _weapon_prefer(iuid: int) -> String:
	var item = ItemInstances.view(iuid)
	if item == null:
		return ""
	var atk = item.get("attack", null)
	if typeof(atk) != TYPE_DICTIONARY:
		return ""
	return str(atk.get("prefer", ""))

# 当前主手武器的 item 名（"比路兹的翼爪" 等）；无武器 → ""。日志/UI 用——区别于 attack.name（技能名，带括号）。
func current_main_weapon_name() -> String:
	var item = ItemInstances.view(int(equipment.get("main_hand", 0)))
	return str(item.get("name", "")) if item != null else ""

# 基础攻击 ＝ 恒读主手武器的 attack🔒（§6.2）：主手无武器/无 attack → 徒手 UNARMED（不退副手）。
# 比路兹起降已把活跃爪换进主手，故此处天然正确、无需 airborne 分支。
# 经合成视图取（深拷）——调用方拿到的 attack 不再是共享模板引用。
func basic_attack() -> Dictionary:
	var item = ItemInstances.view(int(equipment.get("main_hand", 0)))
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

# —— 视觉状态（非数值状态旗，经 mod stat=="vision_state" 承载；装备/特性/buff 任意来源可赋予）——
# 是否具备某视觉状态（如 "nightvision" 夜视 / "blind" 无视力）。扫全部修正。
func has_vision_state(state: String) -> bool:
	for m in modifiers:
		if str(m.get("stat", "")) == "vision_state" and str(m.get("value", "")) == state:
			return true
	return false

# 实际视野半径：面板 sight × 日夜乘子（宿主传入）叠加视觉状态——
#   无视力→0；夜视→免夜间减半（乘子提回 ≥1，白天/增益乘子保留）。下限 0。
func effective_sight(time_mult: float) -> int:
	if has_vision_state("blind"):
		return 0
	var m := time_mult
	if has_vision_state("nightvision"):
		m = maxf(m, 1.0)
	return maxi(0, int(round(effective_stat("sight") * m)))

# —— 状态机查询（§5）——是否具备某活跃状态 tag（扫活跃 effects 的 tags，不污染 permanent tags）。
# 失能（incapacitated）/失语（silenced）等状态机消费点用；effects 到期即状态自然消失。
func has_state(tag: String) -> bool:
	for e in effects:
		if (e.get("tags", []) as Array).has(tag):
			return true
	return false

# ============ 技能（已学状态 / 学习 / 冷却 / 本战次数）============
# 数值口径：冷却 = floor(base)（≥0）；本战次数 = floor(base)（≥1）。
# 🔒 属性重做：per_int 缩放随四维废除（智力已删）；将来数值缩放走公式对象（技能系统阶段2 resolve_num）。

func has_skill(id: String) -> bool:
	return skills.has(id)

# 已学等级（未学 = 0）
func skill_level(id: String) -> int:
	return int(skills.get(id, {}).get("level", 0))

# 冷却上限（回合，按本单位的 turn 计）
func skill_cooldown_max(def) -> int:
	var cd = def.get("cooldown", {})
	return maxi(0, int(floor(float(cd.get("base", 0)))))

# 本战使用次数上限（至少 1）
func skill_uses_max(def) -> int:
	var u = def.get("uses_per_battle", {})
	return maxi(1, int(floor(float(u.get("base", 0)))))

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

# 战斗开始：所有已学技能冷却清零、本战次数重置
func reset_skill_charges() -> void:
	for id in skills:
		var def = SkillDB.get_skill(id)
		if def == null:
			continue
		skills[id]["cd"] = 0
		skills[id]["uses"] = skill_uses_max(def)

# ============ 技艺（熟练度域）🔒 属性与成长系统.md §2 ============

# 技艺槽容量：等级 1/5/9/13/17 各解锁 1 格（共 5，暂定可调 🔒 §1）。等级唯一的解锁节拍职责之一。
func prof_slot_capacity() -> int:
	var c := 1
	for lv in [5, 9, 13, 17]:
		if level >= int(lv):
			c += 1
	return c

# 当前阶段（1..5 生疏..大师）；未接触过的域=1（生疏）
func prof_stage(id: String) -> int:
	return ProfDB.stage_of(int(prof_xp.get(id, 0)))

# 一次性学习资格 🔒（§2.1）：requires.all 全部域达 REQ_STAGE（老练）+ any 至少一个达标。
# 资格看 prof_xp（熟练度保留，与是否装载无关）——学会后前置可整个卸下。
func prof_requires_met(id: String) -> bool:
	var req = ProfDB.get_prof(id).get("requires", {})
	if typeof(req) != TYPE_DICTIONARY or req.is_empty():
		return true
	for rid in req.get("all", []):
		if prof_stage(str(rid)) < ProfDB.REQ_STAGE:
			return false
	var any = req.get("any", [])
	if typeof(any) == TYPE_ARRAY and not any.is_empty():
		for rid in any:
			if prof_stage(str(rid)) >= ProfDB.REQ_STAGE:
				return true
		return false
	return true

# 该域对本单位是否可见：派生域（derived/exotic）在前置达标前隐藏（🔒 §2.1 阶段浮现）；其余恒可见。
func prof_visible(id: String) -> bool:
	var def := ProfDB.get_prof(id)
	if bool(def.get("derived", false)) or bool(def.get("exotic", false)):
		return prof_requires_met(id) or prof_known.has(id)
	return true

# 学会一个技艺（进入「已学」态；派生=自悟在资格达标时调、基础=师承由学习渠道调——渠道后置，
# 本函数只做状态落账+资格校验）。返回是否成功。
func learn_prof(id: String) -> bool:
	if prof_known.has(id) or ProfDB.get_prof(id).is_empty():
		return false
	if not prof_requires_met(id):
		return false
	prof_known.append(id)
	return true

# 装载技艺（占一格；force=烘焙路径跳过容量校验——敌方预设不走玩家槽位系统 🔒 §6）。
# 装载=总开关：挂上当前阶段的数值补正（source="prof:<id>"）。
func slot_prof(id: String, force := false) -> bool:
	if prof_slots.has(id) or not prof_known.has(id):
		return false
	if not force and prof_slots.size() >= prof_slot_capacity():
		return false
	prof_slots.append(id)
	_apply_prof_mods(id)
	return true

# 卸载技艺：摘掉全部相关收益（阶段补正+将来 perk），熟练度冻结保留。
func unslot_prof(id: String) -> void:
	if not prof_slots.has(id):
		return
	prof_slots.erase(id)
	remove_modifiers_by_source("prof:" + id)

# 熟练度获取（🔒 §2.4：仅装载中的技艺可涨；行为权重与威胁缩放由调用方算好传入）。
# 返回新阶段（发生进阶时；未进阶=0）——进阶时重挂阶段补正。
func gain_prof(id: String, amount: int) -> int:
	if amount <= 0 or not prof_slots.has(id):
		return 0
	var old_stage := prof_stage(id)
	prof_xp[id] = int(prof_xp.get(id, 0)) + amount
	var new_stage := prof_stage(id)
	if new_stage > old_stage:
		_apply_prof_mods(id)   # 进阶：按新阶段重挂补正
		return new_stage
	return 0

# 挂/重挂某域当前阶段的数值补正：取 stage_mods 里 stage ≤ 当前阶段的**最高一档**（各档=该阶段的完整值，不叠加）。
func _apply_prof_mods(id: String) -> void:
	var source := "prof:" + id
	remove_modifiers_by_source(source)
	var def := ProfDB.get_prof(id)
	var stage := prof_stage(id)
	var best = null
	for sm in def.get("stage_mods", []):
		if typeof(sm) == TYPE_DICTIONARY and int(sm.get("stage", 0)) <= stage:
			if best == null or int(sm.get("stage", 0)) > int(best.get("stage", 0)):
				best = sm
	if best == null:
		return
	var label := "技艺·%s（%s）" % [str(def.get("name", id)), ProfDB.stage_name(stage)]
	for m in best.get("mods", []):
		if typeof(m) != TYPE_DICTIONARY:
			continue
		var mod: Dictionary = m.duplicate()
		mod["source"] = source
		mod["source_label"] = label
		modifiers.append(mod)

# 当前主手武器的 tags + attack tags（徒手=UNARMED 的 tags）——技艺喂养的行为匹配输入。
# 判据与 basic_attack 完全一致（item.has("attack")）：主手物品无 attack 块＝实际打徒手 → 喂体术、
# 不喂物品 tags（对抗 review 发现：两处判据不一致会喂错域）。
func current_attack_tags() -> Array:
	var out := []
	var item = ItemInstances.view(int(equipment.get("main_hand", 0)))
	if item != null and item.has("attack"):
		for t in item.get("tags", []):
			out.append(str(t))
		var atk = item.get("attack", null)
		if typeof(atk) == TYPE_DICTIONARY:
			for t in atk.get("tags", []):
				if not out.has(str(t)):
					out.append(str(t))
	else:
		for t in UNARMED_ATTACK.get("tags", []):
			out.append(str(t))
	return out

func _init(p_name := "新兵", p_faction := "player", p_col := 0, p_row := 0) -> void:
	unit_name = p_name
	faction = p_faction
	col = p_col
	row = p_row
	init_vitals()

# turn 开始：AP 刷新到上限，移动点清零（上一 turn 零头作废），技能冷却各 −1（按本单位 turn 计）。
func refresh_for_turn() -> void:
	ap = effective_stat("AP_max")   # 走 effective：+AP_max buff/装备须刷满有效上限（裸读会少给 AP）
	move_points = 0
	for id in skills:
		var c := int(skills[id].get("cd", 0))
		if c > 0:
			skills[id]["cd"] = c - 1
