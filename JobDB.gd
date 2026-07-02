extends RefCounted
## 营地职务注册表（M6；DB 范式：preload + static，无 class_name）：读 res://data/jobs.json，职务定义单一源。
## 数据/代码分离：职务及文案是「数据」；这里只做加载 + O(1) 查表。指派状态在 WorldState.camp_jobs（随档）。
## 加成承载 🔒（时间决策 §6.2）：职务＝改「每小时速率」而非一次性触发——消费端按 job 读速率系数
## （首个消费者＝WorldClock 恢复结算读医生；其余职务 effect_status=planned、效果后续接，数值待需求 §2.2）。

const JOBS_PATH := "res://data/jobs.json"

static var _jobs := []        # 有序职务定义（营地面板按此顺序）
static var _by_id := {}       # id -> entry
static var _loaded := false

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	_jobs = []
	_by_id = {}
	if FileAccess.file_exists(JOBS_PATH):
		var f = FileAccess.open(JOBS_PATH, FileAccess.READ)
		var data = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(data) == TYPE_DICTIONARY:
			for e in data.get("jobs", []):
				if typeof(e) == TYPE_DICTIONARY and e.has("id"):
					_jobs.append(e)
					_by_id[str(e["id"])] = e
	if _jobs.is_empty():   # 兜底：至少有医生（唯一已接消费端的职务）
		var m := {"id": "medic", "label": "医生", "desc": "恢复速率提升", "effect_status": "in_use"}
		_jobs = [m]
		_by_id = {"medic": m}

static func all_jobs() -> Array:
	_ensure()
	return _jobs

static func job(id: String):
	_ensure()
	return _by_id.get(id)

static func job_label(id: String) -> String:
	var e = job(id)
	return str(e.get("label", id)) if e != null else id
