extends RefCounted
## 角色外观「部件 / 槽位 / 调色板」注册表——读 data/appearance_parts.json（单文件 doc）。
## 数据/代码分离：部件贴图路径、种族 tag、调色板色标都是"数据"；代码只 AppearanceDB.get_part(id) 等，
## 不关心内容。仿 ItemDB/TerrainDB：extends RefCounted + preload + 静态伪单例，**不用 class_name**
## （全局类要编辑器扫描注册，headless 跑找不到）。
## 用法：const AppearanceDB := preload("res://AppearanceDB.gd") → AppearanceDB.parts_in_slot("body")。
##
## doc 结构：{ "config":{"size":32}, "slots":[{id,cn,z}], "parts":[{id,slot,cn,path,tags,recolorable,default_palette}],
##            "palettes":[{id,cn,stops:[#hex...]}] }
## 换色约定：部件贴图存**灰度**源，运行时按亮度映射到调色板渐变（见 PaperDoll）——免多发 PNG。

const PATH := "res://data/appearance_parts.json"
const LOOKS_PATH := "res://data/appearance_looks.json"   # 单位原型 id → 外观配方（供「应用到单位」后回读再编辑）

static var _doc := {}
static var _by_part := {}     # part_id -> part dict
static var _by_pal := {}      # palette_id -> palette dict
static var _loaded := false
static var _path_override := ""   # 测试注入缝：user:// 临时文件，绝不碰 res://data 真数据
static var _looks_override := ""

static func _looks_path() -> String:
	return _looks_override if _looks_override != "" else LOOKS_PATH

# 外观配方存储（proto_id → recipe {parts,palettes}）。
# get_look 读缓存（性能 2026-07-07）：它是棋子渲染热路径（SandboxCanvas 每帧每单位查配方），
# 原「即时读盘」＝每帧磁盘 I/O＋JSON 解析。缓存按**路径**键失效（_looks_override 测试注入裸赋值切换也安全）；
# 写口 save_look 直刷缓存（工坊即改即见不变）；外部改文件走 reload_data（DB 铁律）。all_looks 低频维持直读。
static var _look_cache := {}
static var _look_cache_path := ""

static func get_look(id: String):
	var p := _looks_path()
	if _look_cache_path != p:
		_look_cache = _read_doc(p)
		_look_cache_path = p
	return _look_cache.get(id)

static func save_look(id: String, recipe: Dictionary) -> bool:
	var p := _looks_path()
	var d := _read_doc(p)
	d[id] = recipe
	_look_cache = d
	_look_cache_path = p
	return _write_doc(p, d)

static func all_looks() -> Dictionary:
	return _read_doc(_looks_path())

static func _path() -> String:
	return _path_override if _path_override != "" else PATH

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	_doc = _read_doc(_path())
	_by_part.clear()
	_by_pal.clear()
	for p in _parts_raw():
		if typeof(p) == TYPE_DICTIONARY and p.has("id"):
			_by_part[str(p["id"])] = p
	for p in _palettes_raw():
		if typeof(p) == TYPE_DICTIONARY and p.has("id"):
			_by_pal[str(p["id"])] = p

# —— 只读查询 ——

# 画布边长（所有部件同尺寸同锚点才能叠齐）。缺省 32。
static func canvas_size() -> int:
	_ensure()
	var cfg = _doc.get("config", {})
	return int(cfg.get("size", 32)) if typeof(cfg) == TYPE_DICTIONARY else 32

# 槽位列表（按 z 升序＝从后到前的叠放顺序）。
static func slots() -> Array:
	_ensure()
	var arr := _slots_raw().duplicate()
	arr.sort_custom(func(a, b): return int(a.get("z", 0)) < int(b.get("z", 0)))
	return arr

static func get_slot(slot_id: String):
	_ensure()
	for s in _slots_raw():
		if str(s.get("id", "")) == slot_id:
			return s
	return null

# 某槽位下的所有部件（保持 doc 内顺序）。
static func parts_in_slot(slot_id: String) -> Array:
	_ensure()
	return _parts_raw().filter(func(p): return str(p.get("slot", "")) == slot_id)

static func get_part(id: String):
	_ensure()
	return _by_part.get(id)

static func all_parts() -> Array:
	_ensure()
	return _parts_raw()

static func palettes() -> Array:
	_ensure()
	return _palettes_raw()

static func get_palette(id: String):
	_ensure()
	return _by_pal.get(id)

# —— 写盘（upsert；仿 ItemDB.save_item）——

# 保存/覆盖一个部件（按 id）。replace_id：改 id 时传旧 id（改名≠复制）。返回是否写盘成功。
static func save_part(part: Dictionary, replace_id := "") -> bool:
	if not part.has("id") or str(part["id"]) == "":
		return false
	_ensure()
	var id := str(part["id"])
	var arr := _parts_raw()
	var out := []
	var replaced := false
	for e in arr:
		var eid := str(e.get("id", "")) if typeof(e) == TYPE_DICTIONARY else ""
		if replace_id != "" and replace_id != id and eid == replace_id:
			continue   # 改 id：旧条目移除
		if eid == id:
			out.append(part)
			replaced = true
		else:
			out.append(e)
	if not replaced:
		out.append(part)
	_doc["parts"] = out
	if not _write_doc(_path(), _doc):
		return false
	reload_data()
	return true

# 保存/覆盖一个槽位（新增部件总类）。z＝叠放层级（升序＝从后到前）。
static func save_slot(slot: Dictionary, replace_id := "") -> bool:
	if not slot.has("id") or str(slot["id"]) == "":
		return false
	_ensure()
	var id := str(slot["id"])
	var arr := _slots_raw()
	var out := []
	var replaced := false
	for e in arr:
		var eid := str(e.get("id", "")) if typeof(e) == TYPE_DICTIONARY else ""
		if replace_id != "" and replace_id != id and eid == replace_id:
			continue
		if eid == id:
			out.append(slot)
			replaced = true
		else:
			out.append(e)
	if not replaced:
		out.append(slot)
	_doc["slots"] = out
	if not _write_doc(_path(), _doc):
		return false
	reload_data()
	return true

# 删除槽位（连同其下部件）。
static func delete_slot(id: String) -> bool:
	_ensure()
	_doc["slots"] = _slots_raw().filter(func(e): return str(e.get("id", "")) != id)
	_doc["parts"] = _parts_raw().filter(func(e): return str(e.get("slot", "")) != id)
	if not _write_doc(_path(), _doc):
		return false
	reload_data()
	return true

# 现有最大 z（新增槽默认排到最上层）。
static func max_z() -> int:
	_ensure()
	var m := 0
	for s in _slots_raw():
		m = maxi(m, int(s.get("z", 0)))
	return m

static func delete_part(id: String) -> bool:
	_ensure()
	if not _by_part.has(id):
		return false
	_doc["parts"] = _parts_raw().filter(func(e): return str(e.get("id", "")) != id)
	if not _write_doc(_path(), _doc):
		return false
	reload_data()
	return true

# 保存/覆盖一个调色板（按 id）。
static func save_palette(pal: Dictionary, replace_id := "") -> bool:
	if not pal.has("id") or str(pal["id"]) == "":
		return false
	_ensure()
	var id := str(pal["id"])
	var arr := _palettes_raw()
	var out := []
	var replaced := false
	for e in arr:
		var eid := str(e.get("id", "")) if typeof(e) == TYPE_DICTIONARY else ""
		if replace_id != "" and replace_id != id and eid == replace_id:
			continue
		if eid == id:
			out.append(pal)
			replaced = true
		else:
			out.append(e)
	if not replaced:
		out.append(pal)
	_doc["palettes"] = out
	if not _write_doc(_path(), _doc):
		return false
	reload_data()
	return true

# 重新加载（清缓存再读）。⚠️ 名字必须叫 reload_data 不能叫 reload——见 ItemDB 注释（Script.reload 陷阱）。
static func reload_data() -> void:
	_doc = {}
	_by_part.clear()
	_by_pal.clear()
	_loaded = false
	_look_cache = {}
	_look_cache_path = ""
	_ensure()

# —— 内部 ——

static func _slots_raw() -> Array:
	var a = _doc.get("slots", [])
	return a if typeof(a) == TYPE_ARRAY else []

static func _parts_raw() -> Array:
	var a = _doc.get("parts", [])
	return a if typeof(a) == TYPE_ARRAY else []

static func _palettes_raw() -> Array:
	var a = _doc.get("palettes", [])
	return a if typeof(a) == TYPE_ARRAY else []

static func _read_doc(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	return data if typeof(data) == TYPE_DICTIONARY else {}

# 写整个 doc（2 空格缩进 + 整数归一化，与工程其它数据文件一致）。
static func _write_doc(path: String, doc: Dictionary) -> bool:
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("AppearanceDB：写入失败（%s）——占用/只读/目录不存在？" % path)
		return false
	f.store_string(JSON.stringify(_intify(doc), "  "))
	f.close()
	return true

# 递归把「值为整数的 float」还原为 int（1.0→1；1.5 保留）——只影响落盘表示。
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
