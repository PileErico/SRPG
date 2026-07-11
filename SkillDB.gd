extends RefCounted
## 技能注册表：读 data/skills.json，合并成按 id 查的表（外加按「通用序列槽位 seq」查）。
## 用法：const SkillDB := preload("res://SkillDB.gd")，再 SkillDB.get_skill(id) / SkillDB.by_seq(n)。
## 仿 ItemDB（不用 class_name：全局类要编辑器扫描注册，headless 跑会找不到；静态变量仍是全局单例）。
## 数据/代码分离：技能的数值/门槛/效果都是“数据”；代码只查表，不关心来自哪个文件。

const FILES := [
	"res://data/skills.json",
]
const JsonRegistry := preload("res://JsonRegistry.gd")

static var _skills := {}     # id -> def
static var _by_seq := {}      # 通用序列槽位(1-13) -> def
static var _loaded := false
static var _path_override := ""   # 测试注入缝（非空＝只读此路径）

static func _paths() -> Array:
	return [_path_override] if _path_override != "" else FILES

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	_skills = {}
	_by_seq = {}
	for path in _paths():
		for entry in JsonRegistry.load_indexed(path, "")["list"]:
			_skills[str(entry["id"])] = entry
			if entry.has("seq"):
				_by_seq[int(entry["seq"])] = entry

static func reload_data() -> void:
	_loaded = false
	_ensure()

# 取一个技能定义（找不到返回 null）
static func get_skill(id: String):
	_ensure()
	return _skills.get(id)

# 取「通用序列」第 seq 格的技能（1-13；该格未配置则 null）
static func by_seq(seq: int):
	_ensure()
	return _by_seq.get(seq)

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

# BWS 扁平化（🔒 §6.2 blocker + 决策26 阶段3a）：BWS 技能条目 → legacy attack dict——
# 保下游 _resolve_compute / Sandbox / 借机 / AI 的顶层读点零改动。
# 顶层字段从技能级取（name/icon/range/ap_cost〔经 skill_ap_cost 双键桥〕/tags）；
# attack 块 hits[0] 其余键全部透传（coeff/damage_kind/aoe/inflict/armor_pen/sure_hit…）。
# 无 attack 块/空 hits → 返回 {}（勿凭顶层字段造「幻影全额物理攻击」；basic_attack 自然兜 UNARMED）。
static func flatten_bws(def: Dictionary) -> Dictionary:
	for b in def.get("effects", []):
		if typeof(b) == TYPE_DICTIONARY and str(b.get("kind", "")) == "attack":
			var hits = b.get("hits", [])
			if not (typeof(hits) == TYPE_ARRAY and hits.size() >= 1 and typeof(hits[0]) == TYPE_DICTIONARY):
				break
			var out := (hits[0] as Dictionary).duplicate(true)
			out["name"] = str(def.get("name", ""))
			out["icon"] = str(def.get("icon", ""))
			out["range"] = int(def.get("range", 1))
			out["ap_cost"] = skill_ap_cost(def)
			var tags := []
			for t in def.get("tags", []):
				tags.append(str(t))
			out["tags"] = tags
			return out
	return {}


# ============ 写盘口（阶段2；仿 EffectDB/ItemDB 范式——SkillEditor/迁移脚本的唯一写侧）============

# 读某文件的原始数组（写路径用；读侧走 _ensure/JsonRegistry）
static func _read_array(path: String) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	return data if typeof(data) == TYPE_ARRAY else []

static func _write_array(path: String, arr: Array) -> bool:
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("SkillDB：写入失败（%s）——文件被占用/只读？" % path)
		return false
	f.store_string(JSON.stringify(_intify(arr), "  "))
	f.close()
	return true

# 递归把「值为整数的 float」还原 int（1.0→1，防 diff 噪音；同 EffectDB._intify）
static func _intify(v):
	match typeof(v):
		TYPE_FLOAT:
			return int(v) if v == floorf(v) else v
		TYPE_ARRAY:
			var out := []
			for e in v:
				out.append(_intify(e))
			return out
		TYPE_DICTIONARY:
			var out := {}
			for k in v:
				out[k] = _intify(v[k])
			return out
	return v

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
