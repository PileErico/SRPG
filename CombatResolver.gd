extends RefCounted
## 战斗伤害结算：把「输出伤害 → 拆 (通道,属性) 分量 → 逐分量走减伤链 → 落血」的**纯数学**收在这里。
## 无 RNG / 无日志 / 不 mutate target——命中/暴击/格挡掷骰与日志留在 Sandbox。
## 规格 🔒：docs/单位系统设计.md「减伤链 / 伤害结算」。下限 clamp 🔒：任何 lane 不为负（见各 maxf(0,…)）。
##
## 键约定 🔒（属性重做 docs/属性与成长系统.md §5）：抗性两轨——物理(phys)/自然(nature)；
##   人抗 = res_<suffix>（挂人）；甲抗 = armor_res_<suffix>（挂防具、默认0、无甲=无甲抗）；
##   固减 = dr_flat_human / dr_flat_armor（默认0）。
## damage_kind 保留细分：physical|fire|ice|thunder|holy（element 已废弃 §7.2）——伤害种别喂异常/内容层，
## 减伤归轨：physical→phys，全部元素（含神圣）→nature。元素特异性弱点不走抗性轨（走异常侧/专项逻辑）。

const RES_SUFFIX := {"physical": "phys", "fire": "nature", "ice": "nature", "thunder": "nature", "holy": "nature"}

# 结算一次攻击的所有分量。返回 {armor_loss, hp_loss}（float；调用方四舍五入后落到 target）。不改 target。
#   out        = 输出伤害（攻击面板×系数×暴击×攻击效能 ＋ 补正，Sandbox 已算好）
#   g          = 全域减伤 G = max(0,1−格挡性能/100) × 减伤效能（Sandbox 已算好并 clamp）
#   components = [{lane:"armor_first"|"human", damage_kind:String, ratio:float}]
#                普攻 = 单分量(armor_first, 物理)；穿甲比例p = human(p) + armor_first(1−p)；附魔 = 按比例拆多 damage_kind。
static func resolve(target, out: float, g: float, components: Array) -> Dictionary:
	var pool := float(target.stats.get("armor", 0))   # 局部模拟护甲池消耗，不改 target
	var armor_loss := 0.0
	var hp_loss := 0.0
	for c in components:
		var dkind := str(c.get("damage_kind", "physical"))
		var amt := out * float(c.get("ratio", 1.0)) * g
		if str(c.get("lane", "armor_first")) == "human":
			# 穿甲人部分：直接进人，过人抗 + 人固减
			hp_loss += maxf(0.0, amt * _res_factor(target, "res_", dkind) - _flat(target, "dr_flat_human"))
		else:
			# 非穿甲：先进甲（过甲抗 + 甲固减）；破甲溢出**保留原伤害类型**再过人抗 + 人固减
			var to_armor := maxf(0.0, amt * _res_factor(target, "armor_res_", dkind) - _flat(target, "dr_flat_armor"))
			if to_armor <= pool:
				pool -= to_armor
				armor_loss += to_armor
			else:
				var overflow := to_armor - pool
				armor_loss += pool
				pool = 0.0
				hp_loss += maxf(0.0, overflow * _res_factor(target, "res_", dkind) - _flat(target, "dr_flat_human"))
	return {"armor_loss": armor_loss, "hp_loss": hp_loss}

# 抗性因子 = max(0, 1 − 抗/100)：抗>100→0(免疫)；抗<0(脆弱)→>1(放大，合法)。
static func _res_factor(target, prefix: String, damage_kind: String) -> float:
	var r := float(target.effective_stat_f(prefix + res_suffix(damage_kind)))
	return maxf(0.0, 1.0 - r / 100.0)

static func _flat(target, key: String) -> float:
	return float(target.effective_stat_f(key))

# damage_kind → 抗性键后缀。供本类与 Sandbox 日志共用。
# 未知种别响亮告警 + 回退物理轨（原「同名后缀」会静默读缺省 0 键 → 双轨抗性全旁路，对抗 review 发现）；
# 种别白名单同时由 test_data_lint 在数据侧机械执法。
static func res_suffix(damage_kind: String) -> String:
	if not RES_SUFFIX.has(damage_kind):
		push_warning("CombatResolver：未知 damage_kind=%s——回退按物理取抗（白名单=%s）" % [damage_kind, str(RES_SUFFIX.keys())])
		return "phys"
	return str(RES_SUFFIX[damage_kind])
