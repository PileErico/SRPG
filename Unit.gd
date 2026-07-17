extends RefCounted
## 单位数据（sandbox 起步版）。
## 身份字段固定；战斗属性放在 stats 字典里，方便“慢慢添加”——
## 每加一条属性，侧栏（与将来的 token）自动反映。
## 属性口径 🔒 docs/模块_属性成长_设计.md：四维已删——基础值=种族底值（RaceDB 写入，缺省=人类基线），
## 装备/熟练度/perk 经修正管线叠加；等级零数值。

const STANCE_TAGS := ["player", "ally", "enemy", "neutral"]   # 阵营立场 tag
const ItemInstances := preload("res://ItemInstances.gd")     # 物品实例门面（每件装备独立实例；消费合成视图）
const StatMeta := preload("res://StatMeta.gd")               # stat 元数据单一源（派生键/序列化白名单）
const TraitDB := preload("res://TraitDB.gd")                 # 特性注册表（特性查表）
const SkillDB := preload("res://SkillDB.gd")                 # 技能注册表（技能查表）
const ProfDB := preload("res://ProfDB.gd")                   # 技艺（熟练度域）注册表（🔒 模块_属性成长_设计.md §2）
const EquipSlots := preload("res://EquipSlots.gd")          # 槽位 / 槽位资格（tag 驱动装备资格）
const RaceDB := preload("res://RaceDB.gd")                  # 种族底值/成长曲线/天生武器（🔒 §10.4/§10.6）

var unit_name := "新兵"
var col := 0
var row := 0

# 单位 tag（移动型 / 阵营立场 / 特性 / 状态 共用一张词表，见 docs/模块_战斗_设计.md「tag 体系」）。
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

# 第一层属性面板（详见 docs/模块_战斗_设计.md「第一层属性」）。
# 这些是“基础值/上限”，默认值可为 0（面板 + 修正）；当前 turn 的剩余量是运行时状态，见下。
var stats := {
	# 生存（🔒 §10.6 HP 重基：基准 40、种族成长曲线每级 +1——"变肉但没变很肉"）
	"HP_max": 40, "HP": 40,
	"armor_max": 0, "armor": 0,   # 护甲值（承伤池，来自防具，默认 0）
	# 行动
	"AP_max": 2,                  # AP 上限：每 turn 开始刷新到此值（行动经济基础 2）
	"move": 4,                    # 移动力：一次「移动动作」（花 1 AP）获得的移动点数（🔒 2026-07-08 人类基线 4；种族条件覆盖见 move_allowance）
	"speed": 0,                   # 速度面板（装备/buff 修正落点）；回合序＝speed+灵活（🔒 §10.6，读 initiative()）
	"sight": 5,                   # 视野半径：能看多远（六边形距离）；被 LOS 裁剪。夜/天气等环境挂修正。见 docs/感知系统.md
	# 进攻 / 防御（默认=人类基线，与 data/races.json human 一致；武器/熟练度/perk 经修正管线叠加）
	"atk": 0,                     # 攻击面板（🔒 §10.4 攻击全来自武器：人底 0，徒手数值在拳脚条目）
	"atk_eff": 100,              # 攻击效能(%)：最终增伤乘数层，基线 100
	"def_eff": 100,              # 防御效能(%)：最终减伤乘数层，基线 100
	"offhand_eff": 50,           # 副手攻击效能(%)（🔒 决策5 阶段3b）：weapon_source=off_hand 的 hit ×此值/100；单手精通 perk 走修正管线加至 ≤75
	"acc": 0,                     # 命中面板＝武器侧承载（武器 mods 落点）；人身命中＝技巧（🔒 §10.6 命中=武器命中+技巧−闪避−灵活）
	"eva": 0,                     # 闪避面板＝修正落点；人身闪避＝灵活（同上）
	"crit_rate": 0,               # 暴击率(%)：无人身底率 🔒——暴击＝招式/武器 + 技巧×0.5 − 对方运气
	"crit_dmg": 120,              # 暴击威力(%)＝全招式默认值（🔒 二次修订 2026-07-08：160→120），未暴击=100
	"block_rate": 0,              # 格挡率(%)：人底 0 🔒 §10.3——纯物品承载（盾天生激活/武器须格挡域）
	"block_power": 0,             # 格挡性能(%)：同上
	# 抗性四轨 🔒（docs/模块_属性成长_设计.md §5）：抗性=百分比减伤（人/甲分算）；强韧=异常豁免掷（防具永不提供＋等级自动曲线）
	"res_phys": 0,                # 物理抗性(%)：全部物理伤害
	"res_nature": 0,              # 自然抗性(%)：全部元素伤害（含神圣）
	"will_fort": 0,               # 意志强韧(%)：非物质异常豁免（眩晕/恐惧/混乱…）；每级 +2（种族 growth）
	"body_fort": 0,               # 肉体强韧(%)：物质异常豁免（寒冷/麻痹/流血…）；每级 +2（种族 growth）
	# 加点四属性 🔒（§10.6 加点轨：不随等级自动涨、c 节点四选二；人类底值＝技巧10/灵活10/运气5/决心0）
	"finesse": 10,                # 技巧：等额加进命中；暴击率 +0.5%/点（加点 +2/次）
	"agility": 10,                # 灵活：战斗速度＝灵活；闪避＝灵活（加点 +1/次；防具减灵活、防具域缓解）
	"luck": 5,                    # 运气：受击时压低对方暴击率（等额）；全 d20 检定补正（加点 +1/次）
	"resolve": 0,                 # 决心：初始士气 +2/点；每次士气损失抵消 1/点（单次损失保底 1）（加点 +1/次）
}

# —— 运行时回合状态（不是面板属性；每 turn 开始重置）——
var ap := 0           # 本 turn 剩余 AP
var move_points := 0  # 本 turn 剩余移动点（买移动动作时按 move 注入，可分批花、零头作废）

# —— 士气（战斗运行时态，随战中快照走、不入档；🔒 模块_属性成长_设计.md §10.7）——
# 0~50 五档（档界 0~9/10~19/20~29/30~39/40~50，常态 25 居稳定档正中）、无溃逃；初始 = 25 + 2×决心（init_vitals 时定）。
# v1 只有数值与事件（变化入口＝BattleState._morale_add）；档位战斗判定（±命中/伤害）延后批次；五档图标 UI＝状态面板侧。
const MORALE_MAX := 50
const MORALE_BASELINE := 25
const MORALE_BANDS := ["崩溃", "动摇", "稳定", "高昂", "狂热"]
var morale := MORALE_BASELINE

# —— 交互语境（🔒 §4.2 阶段4）：一次攻击/技能结算期内由 BattleState._resolve_compute 设置、出结算即清——
# {target: Unit, skill_tags: Array}。when 条件（target_tag/skill_tag/target_effect）惰性读此；
# 结算外恒空＝交互条件不满足。纯瞬态：不入快照白名单、不序列化。
var combat_ctx := {}

# —— 挂在身上的效果 / buff（修正对象的载体；将来由修正管线填充，见 docs 装备/修正管线）——
# 每条形如 {name, kind:"buff"/"debuff", permanent:bool, duration:int(按 round)}；状态页右下列表读它。
var effects := []

# —— 修正管线：装备/buff/养成/地块/元素 都把“修正对象”挂这（统一来源）——
# 每条 = {stat, op:"flat"/"pct"/"eff", value, source, nature?}；effective_stat 三层解析。
var modifiers := []

# —— 已装备：slot_id -> 实例 uid(int)（双手武器占 main_hand + off_hand 两槽、同一 uid）——
# 物品数据一律经 ItemInstances.view(uid) 取合成视图（模板 ⊕ 词条/耐久/状态）。
var equipment := {}

# —— 角色背包：物品实例 uid 列表（装备穿卸的缓冲区；上限 BAG_CAP＝状态页可用格数单源）——
# 序列化三层全走：proto 存模板 id / campaign 存 uid 引用 / 战斗快照整份（护栏#3 白名单）。
const BAG_CAP := 8
var bag := []

# —— 已学技能：skill_id -> {level:int(1..max), cd:int(剩余冷却,按本单位 turn), uses:int(本战剩余次数)} ——
# 学过 = 键存在；等级 / 冷却 / 本战次数 都存这。技能定义（数值/门槛/效果）查 SkillDB，不在此重复。
var skills := {}

# —— 技艺（熟练度域）🔒 docs/模块_属性成长_设计.md §2 ——
# 三态：未学（prof_known 无）→ 已学（可装载，生疏起步）→ 阶段成长。熟练度永不丢失（卸下=冻结）。
# 装载=总开关：装载中＝阶段补正（prof:<id> 修正）+perk 生效+可涨；定义查 ProfDB，不在此重复。
var prof_xp := {}       # 域id -> 累计熟练度（int；卸下冻结不清零）
var prof_known := []    # 已学域 id（师承/自悟解锁「已学」；未学不可装载）
var prof_slots := []    # 已装载域 id（≤ prof_slot_capacity()；非战斗可随时换）
var prof_perks := {}    # 域id -> {阶段字符串: perk技能id}；卸载只停用，选择本身保留
var prof_perk_state := {} # 主动 perk 的战斗运行态：skill_id -> {cd,uses}
var reaction_state := {} # 决策36：provider_kind:provider_id:reaction_id -> limit 运行态（战斗快照持久）

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

const BLOCK_MAX_KEYS := ["block_rate", "block_power"]   # 装备来源取高聚合的键（🔒 §10.3：只用一件器械格挡）

# 格挡休眠来源过滤（🔒 决策31）：仅 BLOCK_MAX_KEYS 两键调用（effective_stat_f 先判 stat 名——热路径其他键零开销）。
# equip 源查该物品：tags 含 shield＝恒计（盾的格挡属性天然生效）；否则 slot 为 main_hand/off_hand（手持武器）
# ＝须 weapon_block ≥1（「格挡」技能/perk 激活）才计；防具/饰品等其他 equip 源、以及特性/buff/perk 非 equip 源恒计。
# 无递归环：weapon_block 自身非格挡键 → 其 effective_stat 读链不会再进本过滤。
func _block_source_active(src: String) -> bool:
	if not src.begins_with("equip:"):
		return true
	var item = ItemInstances.view(int(src.get_slice(":", 1)))
	if item == null:
		return true   # 实例不存在（测试合成源等）＝不拦
	if (item.get("tags", []) as Array).has("shield"):
		return true
	if str(item.get("slot", "")) in ["main_hand", "off_hand"]:
		return effective_stat("weapon_block") >= 1
	return true

# 修正对象是否生效（🔒 §10.3 条件 mod 基建）：`requires_prof` 字段＝须装载指定技艺域才计入
# （首例＝武器格挡须装载「格挡」域；triple_vs 等条件修正将来同走此口）。无字段＝无条件生效。
func _mod_active(m: Dictionary) -> bool:
	var req := str(m.get("requires_prof", ""))
	if req != "" and not prof_slots.has(req):
		return false
	var when = m.get("when", null)
	if typeof(when) == TYPE_ARRAY:
		for c in when:
			if typeof(c) != TYPE_DICTIONARY or not _when_met(c):
				return false
	return _grip_source_active(str(m.get("source", "")))

# 兼用件双固有面板门控 🔒（决策35）：equip 源里 source 段 i_<key>=双手形态、i1_<key>=单手形态——
# 按该件当前有效握持只放行一套；非固有段（词条 :<n>）与非 equip 源恒计。非兼用件 i_ 恒计（无 i1_）。
# effective_grip 只读 equipment/ItemInstances，无递归环（同 _block_source_active 的安全性论证）。
func _grip_source_active(src: String) -> bool:
	if not src.begins_with("equip:"):
		return true
	var seg := src.get_slice(":", 2)
	var is_1h := seg.begins_with("i1_")
	if not is_1h and not seg.begins_with("i_"):
		return true   # 词条/附魔等普通 mod（序号段）恒计
	var iuid := int(src.get_slice(":", 1))
	var item = ItemInstances.view(iuid)
	if item == null or not (item.get("tags", []) as Array).has("versatile"):
		return not is_1h   # 非兼用件：i_ 恒计；防御性拦截不该存在的 i1_
	var slot := ""
	for s in ["main_hand", "off_hand"]:
		if int(equipment.get(s, 0)) == iuid:
			slot = s
			break
	if slot == "":
		return not is_1h   # 不在手上（异常态）＝按双手面板兜底
	return (effective_grip(slot) == "one_handed") == is_1h

# 条件词表 v1（🔒 §4 阶段4；when 数组内 AND）。递归防护锁定（§4.3）：一律读**裸 stats**，
# 不进 effective_stat 读链（stat_threshold 在 effective_stat_f 内求值，读 effective 会成环）。
# 单位语境：stat_threshold{stat,op,value,pct_of?} / equip_state{slot,empty?|has_tag?} / self_tag{tag,has?}；
# 交互语境（combat_ctx 结算期内有效，结算外恒 false）：target_tag{tag|any[]} / skill_tag{tag} / target_effect{effect}。
# time_of_day / nearby_units＝光环轮（共用空间查询基建，§4.3 性能警示）；未知类型 fail-closed。
func _when_subject(c: Dictionary, ctx: Dictionary):
	var sid := str(c.get("subject", "owner"))
	if sid in ["", "owner", "self"]:
		return ctx.get("owner", self)
	if sid == "event.unit":
		var ev = ctx.get("event", {})
		return ev.get("unit") if typeof(ev) == TYPE_DICTIONARY else null
	if sid == "target":
		return ctx.get("target", combat_ctx.get("target"))
	return null

func _when_met(c: Dictionary, ctx: Dictionary = {}) -> bool:
	var subject = _when_subject(c, ctx)
	match str(c.get("type", "")):
		"stat_threshold":
			if subject == null:
				return false
			var v := float(subject.stats.get(str(c.get("stat", "")), 0))
			var pof := str(c.get("pct_of", ""))
			if pof != "":
				var denom := float(subject.stats.get(pof, 0))
				v = (v / denom * 100.0) if denom > 0.0 else 0.0
			var thr := float(c.get("value", 0))
			return v <= thr if str(c.get("op", ">=")) == "<=" else v >= thr
		"equip_state":
			if subject == null:
				return false
			var iuid := int(subject.equipment.get(str(c.get("slot", "main_hand")), 0))
			if bool(c.get("empty", false)):
				return iuid == 0
			var tag := str(c.get("has_tag", ""))
			if tag == "":
				return iuid != 0
			var item = ItemInstances.view(iuid)
			return item != null and (item.get("tags", []) as Array).has(tag)
		"self_tag":
			return subject != null and subject.tags.has(str(c.get("tag", ""))) == bool(c.get("has", true))
		"target_tag":
			var tgt = subject if c.has("subject") else combat_ctx.get("target")
			if tgt == null:
				return false
			if c.has("any"):
				for t in c.get("any", []):
					if (tgt.tags as Array).has(str(t)):
						return true
				return false
			return (tgt.tags as Array).has(str(c.get("tag", "")))
		"skill_tag":
			return (combat_ctx.get("skill_tags", []) as Array).has(str(c.get("tag", "")))
		"target_effect":
			var tgt2 = subject if c.has("subject") else combat_ctx.get("target")
			if tgt2 == null:
				return false
			var eid := str(c.get("effect", ""))
			for e in tgt2.effects:
				if typeof(e) == TYPE_DICTIONARY and str(e.get("id", "")) == eid:
					return true
			return false
		"event_relation":
			var other = _when_subject({"subject": str(c.get("subject", "event.unit"))}, ctx)
			var owner = ctx.get("owner", self)
			if other == null or owner == null:
				return false
			var relation := str(ctx.get("event_relation", ""))
			if relation == "":
				var hostile := str(owner.faction) != str(other.faction) and not (str(owner.faction) in ["player", "ally"] and str(other.faction) in ["player", "ally"])
				relation = "enemy" if hostile else "ally"
			return relation == str(c.get("value", "enemy"))
		"weapon_tag":
			if subject == null:
				return false
			var item2 = ItemInstances.view(int(subject.equipment.get(str(c.get("slot", "main_hand")), 0)))
			return item2 != null and (item2.get("tags", []) as Array).has(str(c.get("tag", "")))
		"weapon_grip":
			return subject != null and subject.effective_grip(str(c.get("slot", "main_hand"))) == str(c.get("value", ""))
		"incapacitated":
			return subject != null and subject.has_state("incapacitated") == bool(c.get("value", true))
	push_warning("Unit：when 条件类型「%s」未实现（time_of_day/nearby_units＝光环轮）——按不满足处理" % str(c.get("type", "")))
	return false

func when_all(conds, ctx: Dictionary = {}) -> bool:
	if typeof(conds) != TYPE_ARRAY:
		return true
	for c in conds:
		if typeof(c) != TYPE_DICTIONARY or not _when_met(c, ctx):
			return false
	return true

func reaction_key(provider_kind: String, provider_id: String, reaction_id: String) -> String:
	return "%s:%s:%s" % [provider_kind, provider_id, reaction_id]

func reaction_limit_ready(key: String, limit: Dictionary, reset_token) -> bool:
	var max_uses := maxi(0, int(limit.get("uses", 0)))
	if max_uses == 0:
		return true
	var reset := str(limit.get("reset", "battle"))
	var st: Dictionary = reaction_state.get(key, {})
	if st.is_empty() or (reset != "battle" and st.get("reset_token") != reset_token):
		st = {"uses": max_uses, "reset_token": reset_token}
		reaction_state[key] = st
	return int(st.get("uses", max_uses)) > 0

func consume_reaction_limit(key: String, limit: Dictionary, reset_token) -> void:
	var max_uses := maxi(0, int(limit.get("uses", 0)))
	if max_uses == 0:
		return
	if not reaction_limit_ready(key, limit, reset_token):
		return
	var st: Dictionary = reaction_state[key]
	st["uses"] = maxi(0, int(st.get("uses", max_uses)) - 1)
	reaction_state[key] = st

func clear_reaction_provider(provider_kind: String, provider_id: String) -> void:
	var prefix := "%s:%s:" % [provider_kind, provider_id]
	for key in reaction_state.keys():
		if str(key).begins_with(prefix):
			reaction_state.erase(key)

# 有效属性（保留 1 位小数）= 基础面板 + 修正：base + Σflat + base×Σpct%。面板显示用这个。
# 去重规则 🔒：同一 source（同名 buff/技能）对同一 (stat, op) 只算一次、**取高**（重复挂不叠加、数值不同取大）；
# 不同 source 才互相累加。无 source 标识的修正各自独立计入。
# 格挡两键特例 🔒（§10.3）：装备来源（equip:*）按**件**聚合——件内累加、件间取高（"只用一件器械格挡"，
# 双持不翻倍、单手+盾时盾生效）；buff/perk/阶段奖励等非装备来源照常叠加其上。
func effective_stat_f(key: String) -> float:
	var base := float(stats.get(key, 0))
	var flat := 0.0
	var pct := 0.0
	var flat_src := {}   # source → 该源对本 stat 的 flat 取高值
	var pct_src := {}
	var block_max := key in BLOCK_MAX_KEYS
	var equip_item := {}   # 格挡键：iuid → 该件装备 flat 合计
	for m in modifiers:
		if str(m.get("stat", "")) != key or not _mod_active(m):
			continue
		var v := float(m.get("value", 0))
		var src := str(m.get("source", ""))
		if block_max and not _block_source_active(src):
			continue   # 格挡休眠（🔒 决策31）：手持武器的格挡属性须 weapon_block 激活；盾/防具/非装备源恒计
		match str(m.get("op", "flat")):
			"flat":
				if block_max and src.begins_with("equip:"):
					var iuid := src.get_slice(":", 1)
					equip_item[iuid] = float(equip_item.get(iuid, 0.0)) + v
				elif src == "": flat += v
				else: flat_src[src] = maxf(flat_src.get(src, v), v)
			"pct":
				if src == "": pct += v
				else: pct_src[src] = maxf(pct_src.get(src, v), v)
	for s in flat_src: flat += flat_src[s]
	for s in pct_src: pct += pct_src[s]
	if not equip_item.is_empty():
		var best := 0.0
		for k2 in equip_item: best = maxf(best, float(equip_item[k2]))
		flat += best
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
		if str(m.get("op", "")) != "eff" or str(m.get("stat", "")) != bucket or not _mod_active(m):
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
		if str(m.get("op", "")) != "eff" or str(m.get("stat", "")) != bucket or not _mod_active(m):
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
# 🔒 2026-07-08 种族条件移动力（races.json move_overrides）：条件命中＝**替换种族基础值**、修正差量照叠——
#   when_self_tag 查自身 tag（鸟妖 flying→6）；when_tile_tag 查脚下地块 tag（蜥蜴人 water→4），
#   地块 tags 由战斗侧调用方传入（BattleState._tile_tags_at；无战场上下文缺省 []＝只按自身 tag 判）。
func move_allowance(tile_tags: Array = []) -> int:
	var base := int(stats.get("move", 0))
	var eff := int(effective_stat("move"))
	for o in RaceDB.get_race(race_id).get("move_overrides", []):
		if typeof(o) != TYPE_DICTIONARY:
			continue
		var st := str(o.get("when_self_tag", ""))
		var tt := str(o.get("when_tile_tag", ""))
		if (st != "" and tags.has(st)) or (tt != "" and tile_tags.has(tt)):
			return maxi(0, int(o.get("move", base)) + (eff - base))   # 覆盖基础值＋保留修正差量
	return eff

# 把当前生命/护甲注满到上限（生成时调用；上限 = effective，含装备/特性）。士气一并归初始值。
func init_vitals() -> void:
	stats["HP"] = effective_stat("HP_max")
	stats["armor"] = effective_stat("armor_max")
	morale = clampi(MORALE_BASELINE + effective_stat("resolve"), 0, MORALE_MAX)   # 🔒 §10.7（二次修订：+1/点）

# 当前士气档位 0~4（崩溃/动摇/稳定/高昂/狂热；档界 🔒 每 10 一档、50 归狂热）与档位名。
func morale_band() -> int:
	return clampi(morale / 10, 0, 4)

func morale_band_name() -> String:
	return MORALE_BANDS[morale_band()]

# 档位战斗判定 🔒（§10.7 档位效果表，2026-07-08 接线）：崩溃/动摇/稳定/高昂/狂热 → −10/−5/0/+5/+10。
# 同一个数两用：命中＝acc 平加（_hit_chance/面板命中率行）、伤害＝atk_eff 因子（_resolve_compute ×(1+n/100)）。
const MORALE_BAND_COMBAT := [-10, -5, 0, 5, 10]
func morale_combat_mod() -> int:
	return MORALE_BAND_COMBAT[morale_band()]

# —— 等级三轨 🔒（模块_属性成长_设计.md §10.1；2026-07-08 二次修订＝20 级整齐表）——
# 天赋 Lv 1(默认)/3/6/9/12/14/18（7 个，18 满）· 技能槽 Lv 1/4/8/11/16（5 格，16 满）·
# 属性点 Lv 2/5/7/10/13/15/17/19/20（9 节点 ×2＝18 点，**允许双点同投一属性**——配对约束已废除）
const LEVEL_CAP := 20
const ATTR_PICK_LEVELS := [2, 5, 7, 10, 13, 15, 17, 19, 20]
const ATTR_PICK_INC := {"finesse": 1, "agility": 1, "luck": 1, "resolve": 1}   # 增量统一 +1（强弱在每点效果，不在增量）🔒
var attr_picks := 0                            # 待分配加点次数（战后结算）

# 获得经验（🔒 战后结算：战中静默记录、BattleIO 回写主档后才走到这里）：升级循环。返回升了几级。
# 每级＝种族自动轨成长（growth 块，种族分化 🔒 2026-07-08）；属性点节点另得 2 点；20 级封顶。
func gain_exp(n: int) -> int:
	var levels := 0
	exp += maxi(0, n)
	while exp >= exp_max and exp_max > 0 and level < LEVEL_CAP:
		exp -= exp_max
		level += 1
		levels += 1
		exp_max = int(ceil(exp_max * 1.2))   # 占位曲线（数值层后调）
		_apply_level_growth()
		if level in ATTR_PICK_LEVELS:
			attr_picks += 2
	if level >= LEVEL_CAP:
		exp = mini(exp, exp_max)   # 毕业：经验冻结在条内，不再滚级
	return levels

# 种族自动轨成长 🔒（§10.6 二次修订：成长节奏分化）：growth 值＝数字（每级固定）或**数组**（按
# 新等级 % 数组长 取节奏——人 HP [1,0]＝逢双升、鸟妖 [1,0,0]＝逢三升、蜥蜴人 [1,2]＝1/2 交替）。
# HP 上限涨多少、当前 HP 顺势补多少（升级回气）。⚠️ 依赖 self.level＝刚升到的等级（调用方先置 level）。
func _apply_level_growth() -> void:
	var g = RaceDB.get_race(race_id).get("growth", {})
	if typeof(g) != TYPE_DICTIONARY:
		return
	for k in g:
		var amt := _growth_amount(g[k])
		if amt != 0.0:
			stats[str(k)] = round1(float(stats.get(str(k), 0)) + amt)
	if g.has("HP_max") and stats.has("HP"):
		var hp_amt := _growth_amount(g["HP_max"])
		if hp_amt != 0.0:
			stats["HP"] = round1(float(stats.get("HP", 0)) + hp_amt)

func _growth_amount(v) -> float:
	if typeof(v) == TYPE_ARRAY:
		var arr := v as Array
		return float(arr[level % arr.size()]) if not arr.is_empty() else 0.0
	return float(v)

# 该属性现在可否加点（UI 灰显判据）：有余点 + 合法键。双点可同投一属性（🔒 二次修订，配对约束废除）。
func can_attr_pick(key: String) -> bool:
	return attr_picks > 0 and ATTR_PICK_INC.has(key)

# 花 1 次待分配加点、给指定属性固定增量（战后 UI 消费）。成功 true。
func apply_attr_pick(key: String) -> bool:
	if not can_attr_pick(key):
		return false
	stats[key] = round1(float(stats.get(key, 0)) + float(ATTR_PICK_INC[key]))
	attr_picks -= 1
	return true

# 回合序战斗速度 🔒（§10.6；2026-07-08 修订＝灵活收益减半）：＝速度面板（装备/buff 修正落点，人底 0）
# ＋ 灵活/2 **向下取整**——闪避仍吃满灵活、先攻只吃一半：压双重叠加、给 speed 装备词条留权重；
# 向下取整＝加点 +1 灵活隔次才涨先攻（种族底值配偶数：鸟妖 14）。出手排序/UI 显示都读这里。
func initiative() -> int:
	return int(round(effective_stat_f("speed"))) + int(floorf(effective_stat_f("agility") * 0.5))

# 能否装备：①特性限制（如「天性武者」no_weapon → 不能装「提供攻击」的武器；**天生武器 innate 豁免**）②物品 requires 的 tag 须全有。
# 「提供攻击」判据＝bws/bas 引用或旧内联 attack（阶段3a 双读窗口，与 _main_weapon_attack 同口径）。
func can_equip(item: Dictionary) -> bool:
	var t = TraitDB.get_trait(trait_id)
	var provides_attack: bool = item.has("attack") or SkillDB.weapon_bws_id(item) != ""   # 双读单口（§1-6）
	if t != null and t.get("no_weapon", false) and provides_attack and not item.get("innate", false):
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
	remove_modifiers_by_source_prefix("trait")   # 前缀摘：连带 trait_triple（三倍条件条）
	trait_id = id
	var t = TraitDB.get_trait(id)
	if t == null:
		return
	var tv = t.get("triple_vs", [])
	for m in t.get("mods", []):
		var mod: Dictionary = m.duplicate(true)
		mod["source"] = "trait"
		mod["source_label"] = str(t.get("name", id))
		modifiers.append(mod)
		# triple_vs 兑现（🔒 §4.2 阶段4，屠龙者族）：对带指定 tag 的敌人加成三倍
		# ＝再挂一条 ×2 的条件条（5+10=15），when=target_tag 惰性判（结算外恒不生效）。
		# 独立 source：同 source 同 (stat,op) 会去重取高，拆源才能 5+10 相加。
		if typeof(tv) == TYPE_ARRAY and not tv.is_empty() and typeof(m.get("value", 0)) != TYPE_STRING:
			var extra: Dictionary = m.duplicate(true)
			extra["value"] = float(m.get("value", 0)) * 2.0
			extra["source"] = "trait_triple"
			extra["source_label"] = str(t.get("name", id)) + "（三倍）"
			extra["when"] = [{"type": "target_tag", "any": (tv as Array).duplicate()}]
			modifiers.append(extra)

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
			if occ != null and occ.get("innate", false) and not occ.get("natural", false):
				return false   # 锁定型天生武器（比路兹爪）占槽不可顶；默认型（natural 拳脚）可被顶替 🔒 §10.4
	for s in slots:
		if equipment.has(s):
			_displace_slot(s)
	for s in slots:
		equipment[s] = iuid
	_apply_item_mods(item, iuid)
	return true

# 顶替占槽者（equip_instance 内部用）：默认型天生武器＝收回肉身（摘修正+清槽+销毁实例，空位时再造）；
# 普通装备＝卸下**进背包**（不销毁；bag 无上限硬拒——UI 侧动作前查容量，这里保证不丢件）——
# 但**不**触发拳脚自动回位（新武器马上落座）。
func _displace_slot(slot: String) -> void:
	var iuid: int = int(equipment.get(slot, 0))
	var item = ItemInstances.view(iuid)
	if item != null and item.get("natural", false):
		remove_modifiers_by_source_prefix("equip:%d:" % iuid)
		var to_clear := []
		for s in equipment:
			if int(equipment[s]) == iuid:
				to_clear.append(s)
		for s in to_clear:
			equipment.erase(s)
		ItemInstances.destroy(iuid)
	else:
		unequip(slot, false)
		if iuid != 0 and item != null and not bag.has(iuid):
			bag.append(iuid)   # 被顶掉的旧件落包（曾为孤儿实例——「将来进背包」兑现）

# 卸下某槽的物品（双手武器从任一槽卸都连带清两槽 + 去掉它的修正，按实例 iuid 配对）。
# 天生武器（innate，含拳脚）不可手动卸下/缴械——直接忽略。卸下不销毁实例（将来进背包）。
# auto_natural：卸空主手后拳脚自动回位（🔒 §10.4）；equip_instance 顶替路径传 false（新武器马上落座）。
func unequip(slot: String, auto_natural := true) -> void:
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
	if auto_natural and to_clear.has("main_hand"):
		ensure_natural_weapon()

# ============ 穿卸/换手交互（背包缓冲；战斗内 1 AP 由宿主闸，模型不管费用）============

# 卸下到背包：innate（含拳脚 natural）不可卸；背包满拒绝。卸空主手拳脚自动回位（unequip 内建）。
func unequip_to_bag(slot: String) -> bool:
	var iuid := int(equipment.get(slot, 0))
	if iuid == 0:
		return false
	var item = ItemInstances.view(iuid)
	if item == null or item.get("innate", false):
		return false
	if bag.size() >= BAG_CAP:
		return false
	unequip(slot)
	bag.append(iuid)
	return true

# 从背包装备（target_slot 空＝物品默认槽）：经 equip_instance 全套资格闸；被顶掉的旧件自动落包（_displace_slot）。
# 预检：目标被非 natural 件占用且背包已满（含本件腾出的格）→ 拒绝（防顶替把包挤爆）。
func equip_from_bag(iuid: int, target_slot := "") -> bool:
	if not bag.has(iuid):
		return false
	var item = ItemInstances.view(iuid)
	if item == null:
		bag.erase(iuid)   # 悬空引用顺手清
		return false
	var primary := target_slot if target_slot != "" else str(item.get("slot", ""))
	var slots := ["main_hand", "off_hand"] if item.get("two_handed", false) else [primary]
	var displaced_uids := {}   # 按 uid 去重：双手武器占两槽＝一件
	for s in slots:
		var ouid := int(equipment.get(s, 0))
		var occ = ItemInstances.view(ouid)
		if occ != null and not occ.get("natural", false):
			displaced_uids[ouid] = true
	if bag.size() - 1 + displaced_uids.size() > BAG_CAP:
		return false
	if equip_instance(iuid, target_slot):
		bag.erase(iuid)
		return true
	return false

# 单手武器换手（主↔副）：目标被占＝互换（双方各过对侧槽位资格）；innate/双手不换；
# 目标是拳脚＝顶掉（销毁、单向移入）。直接对调 equipment 字典（比路兹起降同族手法，决策3——修正不重挂）。
func transfer_hand(from_slot: String, to_slot: String) -> bool:
	if not (from_slot in ["main_hand", "off_hand"] and to_slot in ["main_hand", "off_hand"]) or from_slot == to_slot:
		return false
	var a := int(equipment.get(from_slot, 0))
	if a == 0:
		return false
	var ia = ItemInstances.view(a)
	if ia == null or ia.get("two_handed", false) or ia.get("innate", false):
		return false
	if not EquipSlots.accepts(to_slot, ia):
		return false
	var b := int(equipment.get(to_slot, 0))
	var ib = ItemInstances.view(b) if b != 0 else null
	if ib != null:
		if ib.get("natural", false):
			_displace_slot(to_slot)   # 拳脚收回肉身
			b = 0
			ib = null
		elif ib.get("innate", false) or ib.get("two_handed", false) or not EquipSlots.accepts(from_slot, ib):
			return false
	equipment.erase(from_slot)
	equipment[to_slot] = a
	if b != 0:
		equipment[from_slot] = b
	elif from_slot == "main_hand":
		ensure_natural_weapon()   # 主手腾空 → 拳脚回位（🔒 §10.4）
	return true

# 天生武器入位 🔒（§10.4 实装·可替换）：主手空且种族配有 natural_weapon → 造实例装上。
# 生成时（UnitFactory.make_unit）与卸下主手武器后（unequip）两处调用；race 空/未配＝no-op
# （无种族的裸单位退回 UNARMED_ATTACK 常量兜底）。
func ensure_natural_weapon() -> void:
	if equipment.has("main_hand"):
		return
	var nid := str(RaceDB.get_race(race_id).get("natural_weapon", ""))
	if nid != "":
		equip(nid)

# 收编迁移用（WorldState._adopt_equipment）：装备实例换 uid——equipment 槽值 + 背包条目 + 修正 source 前缀同步重写。
func remap_equip_uid(old_uid: int, new_uid: int) -> void:
	for s in equipment:
		if int(equipment[s]) == old_uid:
			equipment[s] = new_uid
	for i in bag.size():
		if int(bag[i]) == old_uid:
			bag[i] = new_uid
	var oldp := "equip:%d:" % old_uid
	var newp := "equip:%d:" % new_uid
	for m in modifiers:
		var src := str(m.get("source", ""))
		if src.begins_with(oldp):
			m["source"] = newp + src.substr(oldp.length())

# 徒手兜底常量：🔒 §10.4 后拳脚＝weapons.json 数据条目（实装占主手），正常单位打不到这里；
# 仅无种族/无天生武器配置的裸单位（编辑器草稿、测试）与快照缺实例时兜底。unarmed tag：喂养徒手系技艺。
const UNARMED_ATTACK := {
	"name": "徒手", "coeff": 1.0, "range": 1, "ap_cost": 1,
	"damage_category": "physical", "tags": ["unarmed"], "aoe": null,
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

# 读某槽武器的地/空偏好（"ground"/"air"）；无武器/无偏好 → 空串。
# 键位：武器顶层 "prefer"（BAS 迁移后归宿）双读旧 attack.prefer（窗口期兼容）。
func _weapon_prefer(iuid: int) -> String:
	var item = ItemInstances.view(iuid)
	if item == null:
		return ""
	if item.has("prefer"):
		return str(item.get("prefer", ""))
	var atk = item.get("attack", null)
	if typeof(atk) != TYPE_DICTIONARY:
		return ""
	return str(atk.get("prefer", ""))

# 当前主手武器的 item 名（"比路兹的翼爪" 等）；无武器 → ""。日志/UI 用——区别于 attack.name（技能名，带括号）。
func current_main_weapon_name() -> String:
	var item = ItemInstances.view(int(equipment.get("main_hand", 0)))
	return str(item.get("name", "")) if item != null else ""

# 某槽武器的攻击定义单一取处（🔒 §6.2 + 决策26 阶段3a；决策31 副手段复用同链）：
#   ① 武器 "bws"（旧键 "bas" 双键桥）→ SkillDB 条目 → flatten_bws 扁平 legacy attack dict；
#   ② 双读窗口：无 bws 键 → 回退旧内联 attack（迁移后正式数据不应走到；lint 收口后删此分支）；
#   ③ 无武器攻击 = {}（调用方兜 UNARMED）。悬空 bws 引用 / flatten 空（引用了无 attack 块技能，lint 另拦）＝警告后走回退链。
func _weapon_attack_of(slot: String) -> Dictionary:
	var item = ItemInstances.view(int(equipment.get(slot, 0)))
	if item == null:
		return {}
	var bws := SkillDB.weapon_bws_id(item)   # 双读单口（§1-6）；兼用件＝单手槽/共用缺省
	# 兼用件双 BWS 槽（🔒 决策35 修订 2026-07-15：握持是武器的属性——bws=单手槽、bws_2h=双手槽；
	# 只配一个＝两形态共用（省内容成本），都空＝退徒手）
	if (item.get("tags", []) as Array).has("versatile"):
		var b2 := str(item.get("bws_2h", ""))
		if effective_grip(slot) == "two_handed":
			bws = b2 if b2 != "" else bws
		elif bws == "":
			bws = b2
	if bws != "":
		var def = SkillDB.get_skill(bws)
		var flat: Dictionary = SkillDB.flatten_bws(def) if def != null else {}
		if not flat.is_empty():
			return flat
		push_warning("Unit：武器「%s」bws 引用无效（%s：悬空或无 attack 块）——回退内联/徒手" % [str(item.get("name", "")), bws])
	var atk = item.get("attack", null)
	if typeof(atk) == TYPE_DICTIONARY:
		return atk
	return {}

func _main_weapon_attack() -> Dictionary:
	return _weapon_attack_of("main_hand")

# ZOC 底值（🔒 2026-07-17 用户整理：ZOC 存在性＝半径算术——近战武器 1 / 远程武器 0 / 徒手＝天生近战 1；
# 一切扩张走 zoc_radius 修正〔立矛+1、将来远程 ZOC perk+1〕，半径 0＝无 ZOC）。
# 判据＝主手持械件 tag（恒读主手 🔒）：melee 或 unarmed（天生武器拳脚）→ 1，其余（远程/盾主手）→ 0；主手空＝徒手 1。
func zoc_base() -> int:
	var item = ItemInstances.view(int(equipment.get("main_hand", 0)))
	if item == null:
		return 1
	var t: Array = item.get("tags", [])
	return 1 if (t.has("melee") or t.has("unarmed")) else 0

# 基础攻击 ＝ 恒读主手武器 🔒（§6.2）：主手无武器攻击 → 徒手 UNARMED（不退副手）。
# 比路兹起降已把活跃爪换进主手，故此处天然正确、无需 airborne 分支。
func basic_attack() -> Dictionary:
	var atk := _main_weapon_attack()
	return atk if not atk.is_empty() else UNARMED_ATTACK

# 副手武器的攻击定义（🔒 决策31 双武器连携的副手段）：空手/双手武器占双槽/持盾（副手须持武器非盾）→ {}；
# 否则取副手 bws 扁平并烙 weapon_source=off_hand——结算天然走 offhand_eff 链（🔒 决策5 阶段3b），不硬编码系数。
func offhand_weapon_attack() -> Dictionary:
	var oh := int(equipment.get("off_hand", 0))
	if oh == 0 or oh == int(equipment.get("main_hand", 0)):
		return {}   # 空副手 / 双手武器同 iuid 占双槽＝没有独立副手武器
	var item = ItemInstances.view(oh)
	if item == null or (item.get("tags", []) as Array).has("shield"):
		return {}
	var atk := _weapon_attack_of("off_hand")
	if atk.is_empty():
		return {}
	atk = atk.duplicate()
	atk["weapon_source"] = "off_hand"
	return atk

# 副手武器技能解锁（🔒 决策31 能力键 offhand_ws ≥1；perk 经被动桥授予、走修正管线）
func can_use_offhand_ws() -> bool:
	return effective_stat("offhand_ws") >= 1

# 双武器连携激活（🔒 决策31 能力键 dual_strike ≥1 ＋ 副手持非盾武器且其攻击定义非空）——
# 激活＝普攻两段连携（主手全额 + 副手 offhand_eff 链），攻击执行点（Sandbox/BattleState）消费。
func dual_strike_active() -> bool:
	if effective_stat("dual_strike") < 1:
		return false
	return not offhand_weapon_attack().is_empty()

# 有效握持 🔒（决策35 单一读口）：该槽物品当前算单手还是双手。
#  · 单手/双手件＝静态 tag（旧数据无 tag 回退 two_handed 字段）；盾/天生/徒手＝""（无握持）。
#  · 兼用 versatile＝动态：**另一只手空置（或只有拳脚 natural——拳脚不是装备）→ 双手**，有物→单手；
#    与装在哪个槽无关（副手单持一把兼用武器同样算双手——「事实层面只装备了这一把」，用户拍板 2026-07-14）。
#  只读 equipment/ItemInstances，不进 effective_stat 读链（供 _mod_active 门控调用，无递归环）。
func effective_grip(slot: String) -> String:
	var item = ItemInstances.view(int(equipment.get(slot, 0)))
	if item == null or item.get("innate", false):
		return ""
	var itags: Array = item.get("tags", [])
	if itags.has("two_handed") or (not itags.has("one_handed") and not itags.has("versatile") and item.get("two_handed", false)):
		return "two_handed"
	if itags.has("one_handed"):
		return "one_handed"
	if itags.has("versatile"):
		var other := "off_hand" if slot == "main_hand" else "main_hand"
		var oitem = ItemInstances.view(int(equipment.get(other, 0)))
		if oitem == null or oitem.get("natural", false):
			return "two_handed"
		return "one_handed"
	return ""

# EWS 握持组是否可用 🔒（决策35 修订 2026-07-15：握持是武器的属性——组挂武器侧 ews/ews_2h，
# 技能侧 grip 键已废）：该技能的任一 EWS 条目握持组匹配当前有效握持 → 可施放；
# 非 EWS（已学技能）无握持概念恒 true。战斗菜单灰显与 apply_skill 守卫同吃此口。
func ews_grip_ok(id: String) -> bool:
	var found := false
	for e in ews_entries():
		if str(e["id"]) != id:
			continue
		found = true
		var req := str(e.get("grip_req", ""))
		if req == "" or effective_grip(str(e.get("slot", "main_hand"))) == req:
			return true
	return not found

# 武器固有属性键（🔒 决策33；⚠ 三轮校准 2026-07-13：**命中 acc 移出**——命中的固有归属＝武器技能 hit
# 〔决策32 命中系数〕，物品侧命中只能是普通 mod）：攻/格挡率%/格挡性能%＝物品顶层必填字段（0=无），
# 非 mods——mods 留给词条/附魔等**额外**修正。装备时折成 equip 源修正进同一管线（格挡休眠/
# 按件取高/tooltip 汇总零改动）。armor_dmg 甲伤不在此列：按段读持械件（BattleState._seg_armor_dmg_factor）。
const INTRINSIC_EQUIP_STATS := ["atk", "block_rate", "block_power"]

# 挂装备修正：每条 mod 唯一 source（"equip:<实例iuid>:<序号>"）——同件装备的模板 mod 与词条 mod
# 即使同 stat 同 op 也各自生效（effective_stat 的「同 source 去重取高」只该压重复 buff，不该吃词条）。
# 兼用件 🔒（决策35 双固有面板）：顶层三键=双手形态（source i_）+ one_handed 子面板=单手形态（source i1_）
# 两套都烘、_grip_source_active 按有效握持只放行一套——零重挂零状态残留（格挡休眠同族的 source 门控先例）。
func _apply_item_mods(item: Dictionary, iuid: int) -> void:
	var label := str(item.get("name", ""))
	for k in INTRINSIC_EQUIP_STATS:
		var iv := float(item.get(k, 0))
		if iv != 0.0:
			modifiers.append({"stat": k, "op": "flat", "value": iv,
				"source": "equip:%d:i_%s" % [iuid, k], "source_label": label})
	var oh1 = item.get("one_handed", null)
	if (item.get("tags", []) as Array).has("versatile") and typeof(oh1) == TYPE_DICTIONARY:
		for k in INTRINSIC_EQUIP_STATS:
			var iv1 := float(oh1.get(k, 0))
			if iv1 != 0.0:
				modifiers.append({"stat": k, "op": "flat", "value": iv1,
					"source": "equip:%d:i1_%s" % [iuid, k], "source_label": label + "（单手持）"})
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
# 本战次数上限：**-1＝无限**（🔒 决策18——BAS/无次数限制技能；uses_per_battle 缺省或 base≤0 即无限）
func skill_uses_max(def) -> int:
	var u = def.get("uses_per_battle", {})
	var base := int(floor(float(u.get("base", 0)))) if typeof(u) == TYPE_DICTIONARY else 0
	return base if base > 0 else -1

# 学习 / 升级一个技能（按 def.max_level 封顶）；首学初始化冷却=0、本战次数=满。返回新等级（0=失败）。
# 被动桥挂载在本体 🔒（§10 阶段4）＝一切获取路径（原型直灌/升级授予/编辑器）都生效；
# 获取门槛（技能点/等级）绝不塞进来——「结算式学习＝校验+扣点」vs「直灌」两条 API 拆分（既有决议）。
func learn_skill(id: String) -> int:
	var def = SkillDB.get_skill(id)
	if def == null:
		return 0
	var maxl := int(def.get("max_level", 1))
	if skills.has(id):
		skills[id]["level"] = mini(int(skills[id]["level"]) + 1, maxl)
	else:
		skills[id] = {"level": 1, "cd": 0, "uses": skill_uses_max(def)}
	_hang_skill_passives(id, def, int(skills[id]["level"]))
	return int(skills[id]["level"])

# 被动桥（🔒 §10 阶段4）：passive_stat_mods / conditional_mod 块 → modifiers（source="skill:<id>"）。
# 升级＝按源重挂（数值经 resolve_num 随 level 取档，替换不叠加）；遗忘侧（阶段5 树重置）同摘此源。
# conditional_mod 的 when 原样带上，_mod_active 惰性判（§4.3 读裸 stats 锁定）。
func _hang_skill_passives(id: String, def: Dictionary, level: int) -> void:
	var hp0 := effective_stat_f("HP_max")
	var ar0 := effective_stat_f("armor_max")
	remove_modifiers_by_source("skill:" + id)
	for b in def.get("effects", []):
		if typeof(b) != TYPE_DICTIONARY:
			continue
		var kind := str(b.get("kind", ""))
		if kind != "passive_stat_mods" and kind != "conditional_mod":
			continue
		for m in b.get("mods", []):
			if typeof(m) != TYPE_DICTIONARY:
				continue
			var mod: Dictionary = m.duplicate(true)
			mod["value"] = SkillDB.resolve_num(m.get("value", 0), self, level, 0.0)
			mod["source"] = "skill:" + id
			mod["source_label"] = str(def.get("name", id))
			if kind == "conditional_mod" and typeof(b.get("when", null)) == TYPE_ARRAY:
				mod["when"] = (b.get("when") as Array).duplicate(true)
			modifiers.append(mod)
	_rescale_vitals(hp0, ar0)

# §7.4 scale 🔒：HP_max/armor_max 上限变化 → 当前值按比例缩放（保百分比——杜绝穿脱刷血/残血自杀）。
# refill（变身回满）＝scripted 侧另走，非此默认路径。
func _rescale_vitals(hp0: float, ar0: float) -> void:
	var hp1 := effective_stat_f("HP_max")
	if not is_equal_approx(hp1, hp0) and hp0 > 0.0:
		stats["HP"] = maxi(0, int(round(float(stats.get("HP", 0)) * hp1 / hp0)))
	var ar1 := effective_stat_f("armor_max")
	if not is_equal_approx(ar1, ar0) and ar0 > 0.0:
		stats["armor"] = maxi(0, int(round(float(stats.get("armor", 0)) * ar1 / ar0)))

# 是否可立即施放：已学 + 冷却就绪 + 本战还有次数（-1=无限恒有；不含 AP，AP 由调用方另查）
func skill_ready(id: String) -> bool:
	if not skills.has(id):
		return false
	return int(skills[id].get("cd", 0)) <= 0 and int(skills[id].get("uses", 0)) != 0

# 施放后：进入冷却 + 扣本战次数（-1=无限不扣）
func consume_skill(id: String, cd: int) -> void:
	if not skills.has(id):
		return
	skills[id]["cd"] = maxi(0, cd)
	var us := int(skills[id].get("uses", 0))
	if us > 0:
		skills[id]["uses"] = us - 1

# 战斗开始：所有已学技能冷却清零、本战次数重置；EWS 运行态整表清空（懒初始化，清即全就绪）
func reset_skill_charges() -> void:
	for id in skills:
		var def = SkillDB.get_skill(id)
		if def == null:
			continue
		skills[id]["cd"] = 0
		skills[id]["uses"] = skill_uses_max(def)
	ews_state = {}
	prof_perk_state = {}

# ============ EWS 武器额外技能（🔒 决策26：装备授予、熟练度解锁、以能力形式使用）============
# EWS 非「已学」（不入 skills/不随 campaign 档）；cd/uses 运行态＝ews_state（战斗开始重置、
# 进战斗快照白名单——护栏#3，见 UnitFactory.unit_to_battle_snapshot）。

var ews_state := {}   # skill_id -> {cd, uses}（战斗运行态；懒初始化——无表项=就绪满次数）

# 武器 EWS 条目表：[{id, requires, slot, unlocked}]。主手武器的 ews 恒供给（🔒 决策28 恒读主手）；
# ⚠ 决策28「副手不供给能力表」前半句已被 🔒 决策31 翻案：**副手位武器技能一律按 EWS 论**——
# 副手武器的 ews 全量 + 其 bws 也作一条 EWS（位置语义：bws/ews 键照旧，变的是读取语义）；
# 条目自身 requires（武器域熟练度）照常判 unlocked。
# 副手门控 🔒（2026-07-13 用户裁定）：副手**武器**＝本域熟练度（条目 requires）+ offhand_ws 能力（双武器 perk）；
# 副手**盾**＝只看条目 requires（盾域熟练度，如盾击配 requires 盾域阈值）——剑盾非双持，不吃双武器门槛。
# 键形（🔒 决策26）：对象 {skill, requires:[{prof,value},…]}；决策22 兼容裸字符串＝无条件 EWS。跨槽同 id 首见去重（主手优先）。
# 兼用件 EWS 两桶（🔒 决策35 修订 2026-07-15：握持是武器的属性）：ews=单手组、ews_2h=双手组——
# 组＝激活前置（当前握持匹配 ∧ 条目 requires 解锁）；非兼用件 ews 单桶无握持门（其握持本就静态）。
func ews_entries() -> Array:
	var out := []
	var seen := {}
	var item = ItemInstances.view(int(equipment.get("main_hand", 0)))
	if item != null:
		var versat: bool = (item.get("tags", []) as Array).has("versatile")
		for e in item.get("ews", []):
			_append_ews_entry(out, seen, e, "main_hand", "one_handed" if versat else "")
		if versat:
			for e in item.get("ews_2h", []):
				_append_ews_entry(out, seen, e, "main_hand", "two_handed")
	var oh := int(equipment.get("off_hand", 0))
	if oh != 0 and oh != int(equipment.get("main_hand", 0)):   # 双手武器占双槽＝无独立副手
		var oitem = ItemInstances.view(oh)
		if oitem != null:
			var oh_shield: bool = (oitem.get("tags", []) as Array).has("shield")
			if oh_shield or can_use_offhand_ws():   # 盾豁免双武器门槛（用户裁定）；武器须 offhand_ws
				var oversat: bool = (oitem.get("tags", []) as Array).has("versatile")
				var obws := SkillDB.weapon_bws_id(oitem)
				if obws != "":
					_append_ews_entry(out, seen, {"skill": obws}, "off_hand")   # 副手 bws＝EWS（排序最高故置本槽首）
				for e in oitem.get("ews", []):
					_append_ews_entry(out, seen, e, "off_hand", "one_handed" if oversat else "")
				if oversat:
					for e in oitem.get("ews_2h", []):
						_append_ews_entry(out, seen, e, "off_hand", "two_handed")
	return out

# ews 条目解析共用（ews_entries 内部）：解键形（对象/裸字符串）→ 去重 → 附 slot/握持组 与解锁判定。
# 去重键含握持组：同技能可同时入单手组+双手组（两态都可用的写法）——各成一条、各自按握持亮灭。
func _append_ews_entry(out: Array, seen: Dictionary, e, slot: String, grip_req := "") -> void:
	var sid := ""
	var req := []
	if typeof(e) == TYPE_DICTIONARY:
		sid = str(e.get("skill", ""))
		var r = e.get("requires", [])
		if typeof(r) == TYPE_ARRAY:
			req = r
	else:
		sid = str(e)
	var dkey := sid + "|" + grip_req
	if sid == "" or seen.has(dkey):
		return
	seen[dkey] = true
	out.append({"id": sid, "requires": req, "slot": slot, "grip_req": grip_req, "unlocked": ews_requires_met(req)})

# EWS 解锁判定（🔒 决策26）：requires 复数 AND——每条〔技艺域 prof + 裸数值阈值 value〕都须 prof_xp 达标。
# 空/缺省 requires＝装备即用（决策22 旧语义子集）。资格看 prof_xp、与技艺是否装载无关（同资格闸门先例）。
func ews_requires_met(requires: Array) -> bool:
	for r in requires:
		if typeof(r) != TYPE_DICTIONARY:
			continue
		if int(prof_xp.get(str(r.get("prof", "")), 0)) < int(r.get("value", 0)):
			return false
	return true

# 某 EWS 当前是否已解锁（装备中的武器提供且条件满足）
func ews_unlocked(id: String) -> bool:
	for e in ews_entries():
		if str(e["id"]) == id:
			return bool(e["unlocked"])
	return false

# EWS 可否立即施放（对应 skill_ready；不含 AP/解锁，调用方另查）：冷却就绪 + 次数未尽。
func ews_ready(id: String) -> bool:
	var st = ews_state.get(id, null)
	if st == null:
		return true   # 未入表＝本战未用过＝就绪
	return int(st.get("cd", 0)) <= 0 and int(st.get("uses", -1)) != 0

# EWS 施放后（对应 consume_skill）：进冷却 + 扣次数（-1=无限不扣）。首用按 def 初始化次数。
func consume_ews(id: String, cd: int) -> void:
	if not ews_state.has(id):
		var def = SkillDB.get_skill(id)
		ews_state[id] = {"cd": 0, "uses": skill_uses_max(def) if def != null else -1}
	ews_state[id]["cd"] = maxi(0, cd)
	var us := int(ews_state[id].get("uses", -1))
	if us > 0:
		ews_state[id]["uses"] = us - 1

# ============ 技艺（熟练度域）🔒 模块_属性成长_设计.md §2 ============

# 技艺槽容量：等级 1/4/7/10/13 各解锁 1 格（共 5；🔒 §10.1 十五级三轨轮转 2026-07-07 定案）。
func prof_slot_capacity() -> int:
	var c := 1
	for lv in [4, 8, 11, 16]:   # 🔒 §10.1 二次修订（20 级表）：槽 1/4/8/11/16，16 满
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
	_apply_prof_perks(id)
	return true

# 卸载技艺：摘掉全部相关收益（阶段补正+将来 perk），熟练度冻结保留。
func unslot_prof(id: String) -> void:
	if not prof_slots.has(id):
		return
	prof_slots.erase(id)
	remove_modifiers_by_source("prof:" + id)
	remove_modifiers_by_source_prefix("perk:%s:" % id)

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

# 直设熟练度（编辑器烘焙口 2026-07-15；不走喂养限制/装载门槛）：装载中则按新阶段重挂补正。
# 0＝删键（prof_xp 缺省即 0，序列化不留零值行）。
func set_prof_xp(id: String, v: int) -> void:
	if v <= 0:
		prof_xp.erase(id)
	else:
		prof_xp[id] = v
	if prof_slots.has(id):
		_apply_prof_mods(id)
		_apply_prof_perks(id)

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
	var label := "技能·%s（%s）" % [str(def.get("name", id)), ProfDB.stage_name(stage)]
	for m in best.get("mods", []):
		if typeof(m) != TYPE_DICTIONARY:
			continue
		var mod: Dictionary = m.duplicate()
		mod["source"] = source
		mod["source_label"] = label
		modifiers.append(mod)

# 到阶 perk 行：同阶段候选互斥；空 id＝取消。选择可保留，但只有对应技艺装载时才挂被动/授予主动。
func select_prof_perk(id: String, stage: int, perk_id: String) -> bool:
	if not prof_known.has(id) or stage < 2 or stage > prof_stage(id):
		return false
	var candidates := ProfDB.perks_at_stage(id, stage)
	if perk_id != "" and not candidates.has(perk_id):
		return false
	if not prof_perks.has(id) or typeof(prof_perks[id]) != TYPE_DICTIONARY:
		prof_perks[id] = {}
	if perk_id == "":
		prof_perks[id].erase(str(stage))
	else:
		prof_perks[id][str(stage)] = perk_id
	if (prof_perks[id] as Dictionary).is_empty():
		prof_perks.erase(id)
	if prof_slots.has(id):
		_apply_prof_perks(id)
	return true

func selected_prof_perk(id: String, stage: int) -> String:
	var rows = prof_perks.get(id, {})
	return str(rows.get(str(stage), "")) if typeof(rows) == TYPE_DICTIONARY else ""

func has_active_prof_perk(perk_id: String) -> bool:
	for pid in prof_slots:
		var rows = prof_perks.get(str(pid), {})
		if typeof(rows) == TYPE_DICTIONARY:
			for stage_key in rows:
				if int(stage_key) <= prof_stage(str(pid)) and str(rows[stage_key]) == perk_id:
					return true
	return false

func active_prof_perk_ids() -> Array:
	var out := []
	for pid in prof_slots:
		var rows = prof_perks.get(str(pid), {})
		if typeof(rows) != TYPE_DICTIONARY:
			continue
		for stage_key in rows:
			if int(stage_key) > prof_stage(str(pid)):
				continue
			var id := str(rows[stage_key])
			var def = SkillDB.get_skill(id)
			if def != null and bool(def.get("active", false)) and not out.has(id):
				out.append(id)
	return out

# 已装载且熟练度阶段达标的全部 perk（含被动）；能力菜单仍用 active_prof_perk_ids 只列主动项。
func enabled_prof_perk_ids() -> Array:
	var out := []
	for pid in prof_slots:
		var rows = prof_perks.get(str(pid), {})
		if typeof(rows) != TYPE_DICTIONARY:
			continue
		for stage_key in rows:
			if int(stage_key) <= prof_stage(str(pid)):
				var id := str(rows[stage_key])
				if SkillDB.get_skill(id) != null and not out.has(id):
					out.append(id)
	return out

func prof_perk_weapon_ok(perk_id: String) -> bool:
	var def = SkillDB.get_skill(perk_id)
	if def == null:
		return false
	var req := str(def.get("requires_weapon_tag", ""))
	if req == "":
		return true
	var item = ItemInstances.view(int(equipment.get("main_hand", 0)))
	return item != null and (item.get("tags", []) as Array).has(req)

func prof_perk_ready(perk_id: String) -> bool:
	if not has_active_prof_perk(perk_id) or not prof_perk_weapon_ok(perk_id):
		return false
	var st = prof_perk_state.get(perk_id, {})
	return int(st.get("cd", 0)) <= 0 and int(st.get("uses", -1)) != 0

func consume_prof_perk(perk_id: String, cd: int) -> void:
	if not has_active_prof_perk(perk_id):
		return
	var def = SkillDB.get_skill(perk_id)
	var st: Dictionary = prof_perk_state.get(perk_id, {"cd": 0, "uses": skill_uses_max(def)})
	st["cd"] = maxi(0, cd)
	var uses := int(st.get("uses", -1))
	if uses > 0:
		st["uses"] = uses - 1
	prof_perk_state[perk_id] = st

func _apply_prof_perks(id: String) -> void:
	var hp0 := effective_stat_f("HP_max")
	var ar0 := effective_stat_f("armor_max")
	remove_modifiers_by_source_prefix("perk:%s:" % id)
	if not prof_slots.has(id):
		_rescale_vitals(hp0, ar0)
		return
	var rows = prof_perks.get(id, {})
	if typeof(rows) != TYPE_DICTIONARY:
		_rescale_vitals(hp0, ar0)
		return
	for stage_key in rows:
		if int(stage_key) > prof_stage(id):
			continue
		var sid := str(rows[stage_key])
		var def = SkillDB.get_skill(sid)
		if def == null:
			continue
		var source := "perk:%s:%s" % [id, str(stage_key)]
		for block in def.get("effects", []):
			if typeof(block) != TYPE_DICTIONARY or str(block.get("kind", "")) not in ["passive_stat_mods", "conditional_mod"]:
				continue
			for raw in block.get("mods", []):
				if typeof(raw) != TYPE_DICTIONARY:
					continue
				var mod: Dictionary = raw.duplicate(true)
				mod["value"] = SkillDB.resolve_num(raw.get("value", 0), self, 1, 0.0)
				mod["source"] = source
				mod["source_label"] = str(def.get("name", sid))
				if str(block.get("kind", "")) == "conditional_mod" and typeof(block.get("when", null)) == TYPE_ARRAY:
					mod["when"] = (block.get("when") as Array).duplicate(true)
				modifiers.append(mod)
	_rescale_vitals(hp0, ar0)

# 当前主手武器的 tags + attack tags（徒手=UNARMED 的 tags）——技艺喂养的行为匹配输入。
# 判据与 basic_attack 完全一致（同读 _main_weapon_attack）：主手无武器攻击＝实际打徒手 → 喂体术、
# 不喂物品 tags（对抗 review 发现：两处判据不一致会喂错域）。
func current_attack_tags() -> Array:
	var out := []
	var atk := _main_weapon_attack()
	if atk.is_empty():
		for t in UNARMED_ATTACK.get("tags", []):
			out.append(str(t))
		return out
	var item = ItemInstances.view(int(equipment.get("main_hand", 0)))
	if item != null:
		for t in item.get("tags", []):
			out.append(str(t))
		# 兼用件 🔒（决策35 喂养动态跟随）：注入有效握持 tag——单持喂「双手」style、配副手喂「单手」style
		if (item.get("tags", []) as Array).has("versatile"):
			var g := effective_grip("main_hand")
			if g != "" and not out.has(g):
				out.append(g)
	for t in atk.get("tags", []):
		if not out.has(str(t)):
			out.append(str(t))
	return out

func _init(p_name := "新兵", p_faction := "player", p_col := 0, p_row := 0) -> void:
	unit_name = p_name
	faction = p_faction
	col = p_col
	row = p_row
	init_vitals()

# turn 开始：AP 刷新到上限，移动点清零（上一 turn 零头作废），技能/EWS 冷却各 −1（按本单位 turn 计）。
func refresh_for_turn() -> void:
	ap = effective_stat("AP_max")   # 走 effective：+AP_max buff/装备须刷满有效上限（裸读会少给 AP）
	move_points = 0
	for id in skills:
		var c := int(skills[id].get("cd", 0))
		if c > 0:
			skills[id]["cd"] = c - 1
	for id in ews_state:
		var c2 := int(ews_state[id].get("cd", 0))
		if c2 > 0:
			ews_state[id]["cd"] = c2 - 1
	for id in prof_perk_state:
		var c3 := int(prof_perk_state[id].get("cd", 0))
		if c3 > 0:
			prof_perk_state[id]["cd"] = c3 - 1
