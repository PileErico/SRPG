extends RefCounted
## 物品注册表：读 data/ 下按类分的 JSON（武器/防具/饰品…），合并成一个按 id 查的表。
## 用法：const ItemDB := preload("res://ItemDB.gd")，再 ItemDB.get_item(id)。
## （不用 class_name：全局类要编辑器扫描注册，headless 跑会找不到；静态变量仍是全局单例。）
## 数据/代码分离：物品属性、技能都是“数据”；代码只 ItemDB.get_item(id)，不关心来自哪个文件。

# 类别 → 落盘文件（写回路由）与中文名（kind→中文唯一源，ItemEditor/ItemTooltip 共用）
const FILE_BY_KIND := {
	"weapon": "res://data/weapons.json",
	"armor": "res://data/armor.json",
	"accessory": "res://data/accessories.json",
}
const KIND_CN := {"weapon": "武器", "armor": "防具", "accessory": "饰品"}

static var _items := {}
static var _loaded := false
static var _paths_override := {}   # 测试注入缝：{kind: user://路径}——headless 测试重定向读写，绝不碰 res://data 真数据

static func _kind_paths() -> Dictionary:
	return _paths_override if not _paths_override.is_empty() else FILE_BY_KIND

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	for path in _kind_paths().values():
		for entry in _read_array(path):
			if typeof(entry) == TYPE_DICTIONARY and entry.has("id"):
				_items[str(entry["id"])] = entry

# 取一件物品定义（找不到返回 null）
static func get_item(id: String):
	_ensure()
	return _items.get(id)

static func all() -> Dictionary:
	_ensure()
	return _items

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

static func kind_cn(kind: String) -> String:
	return str(KIND_CN.get(kind, kind))

static func _file_for(item) -> String:
	var paths := _kind_paths()
	return str(paths.get(kind_of(item), paths.get("weapon")))

# 重新加载（清缓存再读）——保存后刷新内存表。
# ⚠️ 名字不能叫 reload：*DB 是 preload 的脚本资源，外部 XxxDB.reload() 会命中原生 Script.reload()
# （重编译+静态变量全重置）而非本函数——2026-07-02 实测踩坑，全 DB 统一 reload_data。
static func reload_data() -> void:
	_items.clear()
	_loaded = false
	_ensure()

# 读某文件的数组（不存在 / 解析失败 → []）。
static func _read_array(path: String) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	return data if typeof(data) == TYPE_ARRAY else []

# 写数组（2 空格缩进，与工程其它数据文件一致）。打不开（占用/只读/目录不存在）＝false，调用方须传导失败。
# 写前整数归一化：JSON 读回的数字全是 float，直接回写会把全文件 1 刷成 1.0（无意义 diff 噪音）。
static func _write_array(path: String, arr: Array) -> bool:
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("ItemDB：写入失败（%s）——文件被占用/只读？" % path)
		return false
	f.store_string(JSON.stringify(_intify(arr), "  "))
	f.close()
	return true

# 递归把「值为整数的 float」还原为 int（1.0→1；1.5 保留）——只影响落盘表示，不改语义
static func _intify(v):
	match typeof(v):
		TYPE_FLOAT:
			return int(v) if v == floorf(v) else v
		TYPE_ARRAY:
			var out := []
			for e in v:
				out.append(_intify(e))
			return out
		TYPE_DICTIONARY:
			var out := {}
			for k in v:
				out[k] = _intify(v[k])
			return out
	return v

# 保存一件物品（按 id 覆盖、无则新增）→ 写回其 slot 对应文件 → reload。返回是否全部写盘成功。
# replace_id：改 id 时传旧 id——旧条目从所有文件移除（否则「改名」会变成「复制」，旧 id 残留）。
# 换类别（slot 改了）时：同 id 也从其它文件清掉（避免两文件重复）。
static func save_item(item: Dictionary, replace_id := "") -> bool:
	if not item.has("id") or str(item["id"]) == "":
		return false
	var id := str(item["id"])
	var target := _file_for(item)
	var ok := true
	for path in _kind_paths().values():
		if not FileAccess.file_exists(str(path)):
			continue
		var arr := _read_array(str(path))
		var filtered := arr.filter(func(e):
			if typeof(e) != TYPE_DICTIONARY:
				return true
			var eid := str(e.get("id", ""))
			if replace_id != "" and replace_id != id and eid == replace_id:
				return false   # 改 id：旧条目移除
			if str(path) != target and eid == id:
				return false   # 换类别：其它文件的旧条目移除
			return true)
		if filtered.size() != arr.size():
			ok = _write_array(str(path), filtered) and ok
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
	ok = _write_array(target, tarr) and ok
	reload_data()
	return ok

# 删除（按 id，从其所属文件移除）→ reload。写盘失败＝false。
static func delete_item(id: String) -> bool:
	_ensure()
	var item = _items.get(id)
	if item == null:
		return false
	var path := _file_for(item)
	var arr := _read_array(path)
	var out := arr.filter(func(e): return not (typeof(e) == TYPE_DICTIONARY and str(e.get("id", "")) == id))
	if not _write_array(path, out):
		return false
	reload_data()
	return true
