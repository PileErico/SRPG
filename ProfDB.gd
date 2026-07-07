extends RefCounted
## 技艺（熟练度域）注册表（data/proficiencies.json 单一数据源）——🔒 docs/模块_属性成长_设计.md §2。
## 术语切割 🔒：技艺=熟练度域（本表）；技能=技能编辑器条目（SkillDB）；成长=个人树。
## 仿 *DB 伪单例：preload + 静态缓存；刷新叫 reload_data（DB 铁律）。
## 用法：const ProfDB := preload("res://ProfDB.gd") → ProfDB.get_prof("wp_sword")

const PATH := "res://data/proficiencies.json"

# 五阶段 🔒：生疏→娴熟→老练→专家→大师＝4 次进阶＝每技艺 4 次 perk 选择权。
# 曲线 2026-07-06 用户定 0/100/300/600/1000（大师计量满值 1500）；仍 🟡 可随数值层调参。阶段序号 1..5。
const STAGE_THRESHOLDS := [0, 100, 300, 600, 1000]
const STAGE_NAMES := ["生疏", "娴熟", "老练", "专家", "大师"]
const MASTER_XP_CAP := 1500   # 大师阶段的计量槽满值/显示上限（xp 本身不封顶）

# 前置/浮现锚 🔒（§2.1，🟡数值可调）：前置域达到本阶段＝资格达标；派生域浮现同锚。
const REQ_STAGE := 3   # 老练

static var _profs := {}      # id -> def
static var _order := []      # 保序 id 列表（页内排序=数据文件顺序）
static var _loaded := false

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	_profs = {}
	_order = []
	if not FileAccess.file_exists(PATH):
		push_warning("ProfDB：找不到 %s——技艺系统无数据" % PATH)
		return
	var f := FileAccess.open(PATH, FileAccess.READ)
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(d) != TYPE_ARRAY:
		push_warning("ProfDB：%s 解析失败（顶层须为数组）" % PATH)
		return
	for e in d:
		if typeof(e) == TYPE_DICTIONARY and str(e.get("id", "")) != "":
			var id := str(e["id"])
			_profs[id] = e
			_order.append(id)

static func reload_data() -> void:
	_loaded = false

static func get_prof(id: String) -> Dictionary:
	_ensure()
	var p = _profs.get(id, null)
	return p if typeof(p) == TYPE_DICTIONARY else {}

static func all_ids() -> Array:
	_ensure()
	return _order.duplicate()

# 按页取域 id（"style"/"weapon"/"life"；保数据文件顺序）
static func ids_by_page(page: String) -> Array:
	_ensure()
	var out := []
	for id in _order:
		if str(_profs[id].get("page", "")) == page:
			out.append(id)
	return out

# xp → 阶段（1..5）
static func stage_of(xp: int) -> int:
	var s := 1
	for i in STAGE_THRESHOLDS.size():
		if xp >= int(STAGE_THRESHOLDS[i]):
			s = i + 1
	return s

static func stage_name(stage: int) -> String:
	return STAGE_NAMES[clampi(stage, 1, 5) - 1]

# 域名（缺省回退 id）
static func prof_name(id: String) -> String:
	return str(get_prof(id).get("name", id))

# 行为匹配：武器/攻击 tags 与域 match_tags 有交集 ⇒ 本次行为喂养该域（🔒 §2.4 一次行为同喂所有匹配技艺）
static func matches_tags(id: String, tags: Array) -> bool:
	var mt = get_prof(id).get("match_tags", [])
	if typeof(mt) != TYPE_ARRAY:
		return false
	for t in mt:
		if tags.has(str(t)):
			return true
	return false
