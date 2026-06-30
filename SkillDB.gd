extends RefCounted
## 技能注册表：读 data/skills.json，合并成按 id 查的表（外加按「通用序列槽位 seq」查）。
## 用法：const SkillDB := preload("res://SkillDB.gd")，再 SkillDB.get_skill(id) / SkillDB.by_seq(n)。
## 仿 ItemDB（不用 class_name：全局类要编辑器扫描注册，headless 跑会找不到；静态变量仍是全局单例）。
## 数据/代码分离：技能的数值/门槛/效果都是“数据”；代码只查表，不关心来自哪个文件。

const FILES := [
	"res://data/skills.json",
]

static var _skills := {}     # id -> def
static var _by_seq := {}      # 通用序列槽位(1-13) -> def
static var _loaded := false

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	for path in FILES:
		if not FileAccess.file_exists(path):
			continue
		var f = FileAccess.open(path, FileAccess.READ)
		var data = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(data) == TYPE_ARRAY:
			for entry in data:
				if typeof(entry) == TYPE_DICTIONARY and entry.has("id"):
					_skills[str(entry["id"])] = entry
					if entry.has("seq"):
						_by_seq[int(entry["seq"])] = entry

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
