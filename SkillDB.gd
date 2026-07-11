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
