extends RefCounted
## 派系注册表（M9；DB 范式：preload + static，无 class_name）：读 res://data/factions.json，派系定义单一源。
## 分工：定义（文案/默认声望/敌对阈值/遭伏参数）＝数据；**声望数值存 WorldState.reputation**（随档）——
## 本类是唯一读写口（rep_of 兜 start_rep 默认、add_rep 钳制 [-100,100]），WorldState 保持纯存储不识派系。
## 敌对遭伏的评估不在这里：Overworld 把敌对派系转成 enter_tile 伪触发器喂 EventEngine（冷却随档持久）。

const PATH := "res://data/factions.json"
const REP_MIN := -100
const REP_MAX := 100

static var _factions := []   # 有序派系定义（声望面板按此顺序）
static var _by_id := {}      # id -> entry
static var _loaded := false

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	_factions = []
	_by_id = {}
	if FileAccess.file_exists(PATH):
		var f = FileAccess.open(PATH, FileAccess.READ)
		var data = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(data) == TYPE_DICTIONARY:
			for e in data.get("factions", []):
				if typeof(e) == TYPE_DICTIONARY and e.has("id"):
					_factions.append(e)
					_by_id[str(e["id"])] = e

static func all_factions() -> Array:
	_ensure()
	return _factions

# 派系定义；未登记返回 null（声望字典是开放键——未登记派系仍可记数，只是无文案/阈值）
static func faction(id: String):
	_ensure()
	return _by_id.get(id)

static func label(id: String) -> String:
	var e = faction(id)
	return str(e.get("label", id)) if e != null else id

static func color(id: String) -> Color:
	var e = faction(id)
	return Color.html(str(e.get("color", "#CCCCCC"))) if e != null else Color(0.8, 0.8, 0.8)

# ============ 声望读写（唯一口；数值存 ws.reputation）============

# 当前声望：未记录＝派系默认 start_rep（读端兜底——老档/新派系免迁移）
static func rep_of(ws, id: String) -> int:
	var e = faction(id)
	var def_rep := int(e.get("start_rep", 0)) if e != null else 0
	return int(ws.reputation.get(id, def_rep)) if ws != null else def_rep

# 声望增减（对话选项/事件动作/战后结算共用写口）；钳制 [-100,100]
static func add_rep(ws, id: String, delta: int) -> void:
	if ws == null or id == "":
		return
	ws.reputation[id] = clampi(rep_of(ws, id) + delta, REP_MIN, REP_MAX)

# 是否敌对：声望低于 hostile_below（未登记派系无阈值＝永不敌对）
static func hostile(ws, id: String) -> bool:
	var e = faction(id)
	return e != null and rep_of(ws, id) < int(e.get("hostile_below", -1000000))
