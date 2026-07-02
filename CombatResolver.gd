extends RefCounted
## 战斗伤害结算：把「输出伤害 → 拆 (通道,属性) 分量 → 逐分量走减伤链 → 落血」的**纯数学**收在这里。
## 无 RNG / 无日志 / 不 mutate target——命中/暴击/格挡掷骰与日志留在 Sandbox。
## 规格 🔒：docs/单位系统设计.md「减伤链 / 伤害结算」。下限 clamp 🔒：任何 lane 不为负（见各 maxf(0,…)）。
##
## 键约定 🔒：人抗 = res_<suffix>（挂人）；甲抗 = armor_res_<suffix>（挂防具、默认0、无甲=无甲抗）；
##            固减 = dr_flat_human / dr_flat_armor（默认0）。element：physical|fire|ice|thunder|holy。

const RES_SUFFIX := {"physical": "phys", "fire": "fire", "ice": "ice", "thunder": "thunder", "holy": "holy"}

# 结算一次攻击的所有分量。返回 {armor_loss, hp_loss}（float；调用方四舍五入后落到 target）。不改 target。
#   out        = 输出伤害（攻击面板×系数×暴击×攻击效能 ＋ 补正，Sandbox 已算好）
#   g          = 全域减伤 G = max(0,1−格挡性能/100) × 减伤效能（Sandbox 已算好并 clamp）
#   components = [{lane:"armor_first"|"human", element:String, ratio:float}]
#                普攻 = 单分量(armor_first, 物理)；穿甲比例p = human(p) + armor_first(1−p)；附魔 = 按比例拆多 element。
static func resolve(target, out: float, g: float, components: Array) -> Dictionary:
	var pool := float(target.stats.get("armor", 0))   # 局部模拟护甲池消耗，不改 target
	var armor_loss := 0.0
	var hp_loss := 0.0
	for c in components:
		var elem := str(c.get("element", "physical"))
		var amt := out * float(c.get("ratio", 1.0)) * g
		if str(c.get("lane", "armor_first")) == "human":
			# 穿甲人部分：直接进人，过人抗 + 人固减
			hp_loss += maxf(0.0, amt * _res_factor(target, "res_", elem) - _flat(target, "dr_flat_human"))
		else:
			# 非穿甲：先进甲（过甲抗 + 甲固减）；破甲溢出**保留原元素属性**再过人抗 + 人固减
			var to_armor := maxf(0.0, amt * _res_factor(target, "armor_res_", elem) - _flat(target, "dr_flat_armor"))
			if to_armor <= pool:
				pool -= to_armor
				armor_loss += to_armor
			else:
				var overflow := to_armor - pool
				armor_loss += pool
				pool = 0.0
				hp_loss += maxf(0.0, overflow * _res_factor(target, "res_", elem) - _flat(target, "dr_flat_human"))
	return {"armor_loss": armor_loss, "hp_loss": hp_loss}

# 抗性因子 = max(0, 1 − 抗/100)：抗>100→0(免疫)；抗<0(脆弱)→>1(放大，合法)。
static func _res_factor(target, prefix: String, element: String) -> float:
	var r := float(target.effective_stat_f(prefix + res_suffix(element)))
	return maxf(0.0, 1.0 - r / 100.0)

static func _flat(target, key: String) -> float:
	return float(target.effective_stat_f(key))

# element → 抗性键后缀（physical→phys，其余同名）。供本类与 Sandbox 日志共用。
static func res_suffix(element: String) -> String:
	return str(RES_SUFFIX.get(element, element))
