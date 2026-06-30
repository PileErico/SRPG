extends RefCounted
## 特性注册表：读 data/traits.json，合并成按 id 查的表。用法同 ItemDB：
##   const TraitDB := preload("res://TraitDB.gd")，再 TraitDB.get_trait(id)。
## 数据/代码分离：特性的稀有度 / 属性加成(mods) / 描述 / 限制(如 no_weapon) 都是“数据”。
## 每条：{ id, name, rarity, mods:[{stat,op,value}], desc, no_weapon? }
## 稀有度取物品那套 tag（special/common/uncommon/rare/epic/legendary），颜色等同。

const FILES := ["res://data/traits.json"]

static var _traits := {}
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
					_traits[str(entry["id"])] = entry

# 取一条特性定义（找不到返回 null）
static func get_trait(id: String):
	_ensure()
	return _traits.get(id)

static func all() -> Dictionary:
	_ensure()
	return _traits
