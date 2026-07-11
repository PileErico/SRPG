extends RefCounted
## 对话注册表（M8；DB 范式：preload + static，无 class_name）：读 res://data/dialogues.json，对话定义单一源。
## 数据/代码分离：对话文本/分支/立绘全是「数据」；这里只做加载 + O(1) 查表。播放/效果在 DialogueUI。
## schema 见 dialogues.json _note：dialogue={id,label,nodes[]}；node 无 choices=纯演出、有 choices=分支。

const PATH := "res://data/dialogues.json"
const JsonRegistry := preload("res://JsonRegistry.gd")

static var _dialogues := []   # 有序对话定义
static var _by_id := {}       # dialogue_id -> entry
static var _loaded := false
static var _path_override := ""   # 测试注入缝

static func _path() -> String:
	return _path_override if _path_override != "" else PATH

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	var r = JsonRegistry.load_indexed(_path(), "dialogues")
	_dialogues = r["list"]
	_by_id = r["by_id"]

static func reload_data() -> void:
	_loaded = false
	_ensure()

static func all_dialogues() -> Array:
	_ensure()
	return _dialogues

# 按 id 取对话定义；不存在返回 null
static func dialogue(id: String):
	_ensure()
	return _by_id.get(id)

# 对话内按节点 id 查节点；不存在返回 null（节点量级小，线性扫够用——对话不建全局索引）
static func node(dlg: Dictionary, node_id: String):
	for n in dlg.get("nodes", []):
		if typeof(n) == TYPE_DICTIONARY and str(n.get("id", "")) == node_id:
			return n
	return null

# 首节点＝nodes[0]（对话入口约定）；空对话返回 null
static func first_node(dlg: Dictionary):
	var nodes = dlg.get("nodes", [])
	if typeof(nodes) == TYPE_ARRAY and nodes.size() > 0 and typeof(nodes[0]) == TYPE_DICTIONARY:
		return nodes[0]
	return null
