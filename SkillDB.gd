extends RefCounted
## 技能注册表：读 data/skills.json，合并成按 id 查的表。
## 用法：const SkillDB := preload("res://SkillDB.gd")，再 SkillDB.get_skill(id)。
## ⚠ 2026-07-13：seq/by_seq（旧「13 通用序列」槽位）随通用能力页一并废除——新体系＝武器技能+熟练度+树。
## 仿 ItemDB（不用 class_name：全局类要编辑器扫描注册，headless 跑会找不到；静态变量仍是全局单例）。
## 数据/代码分离：技能的数值/门槛/效果都是“数据”；代码只查表，不关心来自哪个文件。

const FILES := [
	"res://data/skills.json",
]
const JsonRegistry := preload("res://JsonRegistry.gd")
const HexGrid := preload("res://HexGrid.gd")   # 形状掩码可及距离（决策30）

static var _skills := {}     # id -> def
static var _loaded := false
static var _path_override := ""   # 测试注入缝（非空＝只读此路径）

static func _paths() -> Array:
	return [_path_override] if _path_override != "" else FILES

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	_skills = {}
	for path in _paths():
		for entry in JsonRegistry.load_indexed(path, "")["list"]:
			_skills[str(entry["id"])] = entry

static func reload_data() -> void:
	_loaded = false
	_ensure()

# 取一个技能定义（找不到返回 null）
static func get_skill(id: String):
	_ensure()
	return _skills.get(id)

static func all() -> Dictionary:
	_ensure()
	return _skills

# ============ 统一读取器（🔒 模块_技能_设计 §2.1/§2.4，阶段2）============

# AP 消耗单一读取口：costs.ap（新 schema）↔ 顶层 ap_cost（旧/BAS attack 块）双键桥。
# 全项目读技能/攻击 AP 一律走这里——否则 costs.ap 落地后未改点会静默当 AP=1（§2.1 ⚠️）。
static func skill_ap_cost(def) -> int:
	if typeof(def) != TYPE_DICTIONARY:
		return 1
	var costs = def.get("costs", {})
	if typeof(costs) == TYPE_DICTIONARY and costs.has("ap"):
		return maxi(0, int(floor(float(costs["ap"]))))
	return maxi(0, int(floor(float(def.get("ap_cost", 1)))))

# 统一数值求值器（🔒 §2.4 数值边界）：标量与公式对象 {base, per_stat:{stat:w}, per_level:[...]} 两吃。
# 求值 = base + Σ(unit.effective_stat_f(k)×w) + per_level[clamp(level-1)]；
# level==0（未学/被动载体）取第 1 档、越界取末档（clamp）；null/缺失/空对象 → default（按各字段文档默认值由调用方给）。
# 取整口径由调用方按字段语义做（浮点字段 coeff/概率/百分比不取整；整数字段 floor）；负值钳制同理在调用方（mods 允许负）。
static func resolve_num(v, unit = null, level: int = 1, default: float = 0.0) -> float:
	match typeof(v):
		TYPE_INT, TYPE_FLOAT:
			return float(v)
		TYPE_DICTIONARY:
			if not (v.has("base") or v.has("per_stat") or v.has("per_level")):
				return default   # 空对象/异形 → 默认值（§2.4 缺省条）
			var out := float(v.get("base", 0.0))
			var per = v.get("per_stat", {})
			if typeof(per) == TYPE_DICTIONARY and unit != null:
				for k in per:
					out += float(unit.effective_stat_f(str(k))) * float(per[k])
			var pl = v.get("per_level", [])
			if typeof(pl) == TYPE_ARRAY and pl.size() > 0:
				out += float(pl[clampi(maxi(level, 1) - 1, 0, pl.size() - 1)])
			return out
	return default

# 能力路径可跑块白名单（护栏#1「可编≠可跑」的判定口）：apply_skill 当前只会执行这些 kind；
# attack 块不在内（普攻走攻击路径、经能力施放＝阶段6）——BattleState 守卫 / ItemEditor 过滤 / lint 规则8 共用此口。
const RUNNABLE_KINDS := ["heal", "apply_effect"]

static func has_runnable_block(def: Dictionary) -> bool:
	for b in def.get("effects", []):
		if typeof(b) == TYPE_DICTIONARY and RUNNABLE_KINDS.has(str(b.get("kind", ""))):
			return true
	return false

# 是否含 attack 块（不问形状合法性）：冒烟测试划「攻击型＝阶段6 能力路径时限」的口
static func has_attack_block(def: Dictionary) -> bool:
	for b in def.get("effects", []):
		if typeof(b) == TYPE_DICTIONARY and str(b.get("kind", "")) == "attack":
			return true
	return false

# ============ 武器技能（🔒 决策29 显式勾选制 2026-07-13——翻案决策27 形状判定制）============
# 勾选 weapon_skill=true ＝「是武器技能」＝ 可被武器选取（BWS/EWS 之分由**武器侧**配置时决定，
# 技能库不管引用位）；weapon_kinds=[wcat tag…]＝适用武器种类（可多选：横扫可配剑+戟）。
# 单一判定口：ItemEditor 武器技能选取过滤 / lint 规则8 / SkillEditor 左栏分组 共用。
# ⚠ 引擎事实（非门槛）：普攻路径不结算冷却/次数/等级——带这些的技能放 BWS 位时该三项不生效。
static func is_weapon_skill(def) -> bool:
	return typeof(def) == TYPE_DICTIONARY and bool(def.get("weapon_skill", false))

# 动态武器技能 tag（🔒 决策29 核心）：技能本体**不**静态携带 skill_<种类>，只在被适用种类的武器
# 持有/引用结算时「视为」拥有——weapon_sword→skill_sword、weapon_halberd→skill_halberd（去 weapon_ 前缀）；
# 占位 skill_weapon＝所有武器技能恒有。同一技能随引用武器换 tag 吃对应加成（熟练度 perk 经
# when.skill_tag 只喂对应种类）。三位一体：武器 tag ↔ 适用武器种类 ↔ 武器技能 tag。
# 返回本次结算的技能 tag 全集（本体 tags + 占位 + 动态）；非武器技能＝只回本体 tags。
static func skill_ctx_tags(def: Dictionary, weapon_tags: Array) -> Array:
	var out: Array = []
	for t in def.get("tags", []):
		out.append(str(t))
	if not is_weapon_skill(def):
		return out
	out.append("skill_weapon")
	for k in def.get("weapon_kinds", []):
		if str(k) in weapon_tags:
			out.append("skill_" + str(k).trim_prefix("weapon_"))
	return out

# 形状掩码（🔒 决策30 图形化范围）：{pick:[[dq,dr]…]=选取形（可瞄格，取代 range 标量——环形射程等），
# effect:[[dq,dr]…]=作用形（AOE；空=单体只打所点格）, anchor:"caster"（绕施放者旋转，横扫弧）|"target"
# （平移到落点，火球），friendly_fire:bool（AOE 可空放，故不设对敌/对友、只设友伤）}。
# 双读桥：无 shape/掩码为空 → 回退 range 圆盘/单体（旧数据零迁移）。掩码数学单源＝HexGrid.mask_cells。
static func shape_of(def) -> Dictionary:
	if typeof(def) != TYPE_DICTIONARY:
		return {}
	var s = def.get("shape", {})
	return s if typeof(s) == TYPE_DICTIONARY else {}

# 技能可及距离（AI/预览粗口径）：pick 有则取其最远格，否则 effect（caster 锚），否则 range
static func skill_reach(def) -> int:
	var shp := shape_of(def)
	var pick: Array = shp.get("pick", [])
	if not pick.is_empty():
		return HexGrid.mask_reach(pick)
	var eff: Array = shp.get("effect", [])
	if not eff.is_empty() and str(shp.get("anchor", "caster")) == "caster":
		return HexGrid.mask_reach(eff)
	return int(def.get("range", 1)) if typeof(def) == TYPE_DICTIONARY else 1

# BWS 扁平化（🔒 §6.2 blocker + 决策26 阶段3a）：BWS 技能条目 → legacy attack dict——
# 保下游 _resolve_compute / Sandbox / 借机 / AI 的顶层读点零改动。
# 顶层字段从技能级取（name/icon/range/ap_cost〔经 skill_ap_cost 双键桥〕/tags）；
# attack 块 hits[0] 其余键全部透传（coeff/hit/damage_category/damage_type/aoe/inflict/armor_pen/sure_hit…）。
# 无（合法）attack 块 → 返回 {}（勿凭顶层字段造「幻影全额物理攻击」；basic_attack 自然兜 UNARMED）。
# 取「首个 hits 合法的 attack 块」，异形块跳过继续扫。shape/weapon_skill/weapon_kinds 顶层透传
# （决策29/30：攻击路径要认形状掩码、动态 tag 解析要认勾选与适用种类）。
static func flatten_bws(def: Dictionary) -> Dictionary:
	for b in def.get("effects", []):
		if typeof(b) == TYPE_DICTIONARY and str(b.get("kind", "")) == "attack":
			var hits = b.get("hits", [])
			if not (typeof(hits) == TYPE_ARRAY and hits.size() >= 1 and typeof(hits[0]) == TYPE_DICTIONARY):
				continue
			var out := (hits[0] as Dictionary).duplicate(true)
			out["name"] = str(def.get("name", ""))
			out["icon"] = str(def.get("icon", ""))
			out["range"] = int(def.get("range", 1))
			out["ap_cost"] = skill_ap_cost(def)
			var tags := []
			for t in def.get("tags", []):
				tags.append(str(t))
			out["tags"] = tags
			if typeof(def.get("shape")) == TYPE_DICTIONARY:
				out["shape"] = (def["shape"] as Dictionary).duplicate(true)
			if is_weapon_skill(def):
				out["weapon_skill"] = true
				out["weapon_kinds"] = (def.get("weapon_kinds", []) as Array).duplicate()
			return out
	return {}


# ============ 写盘口（阶段2；仿 EffectDB/ItemDB 范式——SkillEditor/迁移脚本的唯一写侧）============

# 读写盘口已上收 JsonRegistry（技改 §4-4 四胞胎收敛）；私有名保留＝本文件调用点零改动
static func _read_array(path: String) -> Array:
	return JsonRegistry.read_array(path)

static func _write_array(path: String, arr: Array) -> bool:
	return JsonRegistry.write_json(path, arr, "SkillDB")

static func _intify(v):   # 外部消费（迁移脚本/test_skilleditor 语义比较）仍走此名
	return JsonRegistry.intify(v)

# 武器 BWS 引用 id 单口（技改 §1-6：原五处手抄 bws→bas 双读链）——
# bws 正键 + bas 旧键回退（双键桥）；拆桥时只删这一处回退分支即一刀净。
static func weapon_bws_id(item: Dictionary) -> String:
	return str(item.get("bws", item.get("bas", "")))

# 按 id upsert 进主文件（FILES[0]）；replace_id=改名语义（旧条目全移除，改名≠复制）。写盘后 reload_data。
static func save_skill(skill: Dictionary, replace_id := "") -> bool:
	if not skill.has("id") or str(skill["id"]) == "":
		return false
	var id := str(skill["id"])
	var path: String = _paths()[0]
	var arr := _read_array(path)
	if replace_id != "" and replace_id != id:
		arr = arr.filter(func(e): return not (typeof(e) == TYPE_DICTIONARY and str(e.get("id", "")) == replace_id))
	var replaced := false
	for i in arr.size():
		if typeof(arr[i]) == TYPE_DICTIONARY and str(arr[i].get("id", "")) == id:
			arr[i] = skill
			replaced = true
			break
	if not replaced:
		arr.append(skill)
	var ok := _write_array(path, arr)
	reload_data()
	return ok

static func delete_skill(id: String) -> bool:
	_ensure()
	if not _skills.has(id):
		return false
	var path: String = _paths()[0]
	var out := _read_array(path).filter(func(e): return not (typeof(e) == TYPE_DICTIONARY and str(e.get("id", "")) == id))
	if not _write_array(path, out):
		return false
	reload_data()
	return true
