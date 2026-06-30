extends RefCounted
## 物品注册表：读 data/ 下按类分的 JSON（武器/防具/饰品…），合并成一个按 id 查的表。
## 用法：const ItemDB := preload("res://ItemDB.gd")，再 ItemDB.get_item(id)。
## （不用 class_name：全局类要编辑器扫描注册，headless 跑会找不到；静态变量仍是全局单例。）
## 数据/代码分离：物品属性、技能都是“数据”；代码只 ItemDB.get_item(id)，不关心来自哪个文件。

const FILES := [
	"res://data/weapons.json",
	"res://data/armor.json",
	"res://data/accessories.json",
]

static var _items := {}
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
					_items[str(entry["id"])] = entry

# 取一件物品定义（找不到返回 null）
static func get_item(id: String):
	_ensure()
	return _items.get(id)

static func all() -> Dictionary:
	_ensure()
	return _items
