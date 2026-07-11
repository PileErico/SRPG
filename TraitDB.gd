extends RefCounted
## 特性注册表：读 data/traits.json，合并成按 id 查的表。用法同 ItemDB：
##   const TraitDB := preload("res://TraitDB.gd")，再 TraitDB.get_trait(id)。
## 数据/代码分离：特性的稀有度 / 属性加成(mods) / 描述 / 限制(如 no_weapon) 都是“数据”。
## 每条：{ id, name, rarity, mods:[{stat,op,value}], desc, no_weapon? }
## 稀有度取物品那套 tag（special/common/uncommon/rare/epic/legendary），颜色等同。

const FILES := ["res://data/traits.json"]
const JsonRegistry := preload("res://JsonRegistry.gd")

static var _traits := {}
static var _loaded := false
static var _path_override := ""   # 测试注入缝（非空＝只读此路径）

static func _paths() -> Array:
	return [_path_override] if _path_override != "" else FILES

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	_traits = {}
	for path in _paths():
		for entry in JsonRegistry.load_indexed(path, "")["list"]:
			_traits[str(entry["id"])] = entry

static func reload_data() -> void:
	_loaded = false
	_ensure()

# 取一条特性定义（找不到返回 null）
static func get_trait(id: String):
	_ensure()
	return _traits.get(id)

static func all() -> Dictionary:
	_ensure()
	return _traits
