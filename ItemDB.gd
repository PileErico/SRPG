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

# —— 写回（物品编辑器用）：物品按 slot 路由到对应文件 ——
# 数据/代码分离仍成立：编辑器只调 save_item/delete_item/reload，不关心落到哪个文件。
const FILE_BY_KIND := {
	"weapon": "res://data/weapons.json",
	"armor": "res://data/armor.json",
	"accessory": "res://data/accessories.json",
}

# 由 slot 推断类别（weapon/armor/accessory）——决定写回哪个文件。
static func kind_of(item) -> String:
	var slot := ""
	if typeof(item) == TYPE_DICTIONARY:
		slot = str(item.get("slot", ""))
	match slot:
		"main_hand", "off_hand": return "weapon"
		"head", "body": return "armor"
		"accessory_1", "accessory_2": return "accessory"
	return "weapon"

static func _file_for(item) -> String:
	return FILE_BY_KIND.get(kind_of(item), FILE_BY_KIND["weapon"])

# 重新加载（清缓存再读）——保存后刷新内存表。
static func reload() -> void:
	_items.clear()
	_loaded = false
	_ensure()

# 读某文件的数组（不存在 / 解析失败 → []）。
static func _read_array(path: String) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var f = FileAccess.open(path, FileAccess.READ)
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	return data if typeof(data) == TYPE_ARRAY else []

# 写数组（2 空格缩进，与工程其它数据文件一致）。
static func _write_array(path: String, arr: Array) -> void:
	var f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(arr, "  "))
	f.close()

# 保存一件物品（按 id 覆盖、无则新增）→ 写回其 slot 对应文件 → reload。
# slot 改了导致换类别时：先从其它两个文件清掉同 id（避免重复），再写进目标文件。
static func save_item(item: Dictionary) -> bool:
	if not item.has("id") or str(item["id"]) == "":
		return false
	var id := str(item["id"])
	var target := _file_for(item)
	# 从非目标文件清掉同 id（换类别时的旧条目）
	for path in FILE_BY_KIND.values():
		if path == target or not FileAccess.file_exists(path):
			continue
		var arr := _read_array(path)
		var filtered := arr.filter(func(e): return not (typeof(e) == TYPE_DICTIONARY and str(e.get("id", "")) == id))
		if filtered.size() != arr.size():
			_write_array(path, filtered)
	# upsert 进目标文件
	var tarr := _read_array(target)
	var replaced := false
	for i in tarr.size():
		if typeof(tarr[i]) == TYPE_DICTIONARY and str(tarr[i].get("id", "")) == id:
			tarr[i] = item
			replaced = true
			break
	if not replaced:
		tarr.append(item)
	_write_array(target, tarr)
	reload()
	return true

# 删除（按 id，从其所属文件移除）→ reload。
static func delete_item(id: String) -> bool:
	_ensure()
	var item = _items.get(id)
	if item == null:
		return false
	var path := _file_for(item)
	var arr := _read_array(path)
	var out := arr.filter(func(e): return not (typeof(e) == TYPE_DICTIONARY and str(e.get("id", "")) == id))
	_write_array(path, out)
	reload()
	return true
