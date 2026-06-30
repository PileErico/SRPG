extends RefCounted
## tag 注册表：读 data/tags.json（标签词典 docs/标签词典.md 的机器可读版），按 id 查。
## 单一数据源——替代各处硬编码的 TAG_CN / RARITY_COLORS（消除手动同步漂移）；tag 统一判断（项目核心理念）。
## 用法：const TagDB := preload("res://TagDB.gd")，再 TagDB.cn(id) / TagDB.color(id) / TagDB.by_cat(cat)。
## 字段：{id, cn, cat, status, color?, desc?}。其中 id/cn/cat/color 有功能性，desc/status 仅参考。

const FILE := "res://data/tags.json"

static var _tags := {}        # id -> entry（dict 保插入顺序 = json 顺序）
static var _loaded := false

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(FILE):
		return
	var f = FileAccess.open(FILE, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(data) == TYPE_ARRAY:
		for e in data:
			if typeof(e) == TYPE_DICTIONARY and e.has("id"):
				_tags[str(e["id"])] = e

# 取一条 tag 定义（找不到返回 null）
static func get_tag(id: String):
	_ensure()
	return _tags.get(id)

static func all() -> Dictionary:
	_ensure()
	return _tags

# 中文名（找不到回退 id 本身——保证不会显示空白）
static func cn(id: String) -> String:
	_ensure()
	var e = _tags.get(id)
	return str(e.get("cn", id)) if e != null else id

# 颜色（仅稀有度等带；无则返回 ""）
static func color(id: String) -> String:
	_ensure()
	var e = _tags.get(id)
	return str(e.get("color", "")) if e != null else ""

# 某类别下的全部 tag 条目（保持 json 顺序）——给下拉 / tag picker 用。
static func by_cat(cat: String) -> Array:
	_ensure()
	var out := []
	for id in _tags:
		if str(_tags[id].get("cat", "")) == cat:
			out.append(_tags[id])
	return out

# 某类别下的全部 tag id（保持 json 顺序）。
static func ids_in_cat(cat: String) -> Array:
	var out := []
	for e in by_cat(cat):
		out.append(str(e.get("id", "")))
	return out

static func reload() -> void:
	_tags.clear()
	_loaded = false
	_ensure()
