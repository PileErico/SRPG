extends RefCounted
## 效果注册表：读 data/effects.json，按 id 查。仿 ItemDB（静态缓存 + 写盘口 + reload_data）。
## 效果 = 有 id 的 buff/debuff（技能 inflict / apply_effect 引用其 id，不再内联匿名 dict）。
## 见 docs/模块_技能_设计.md §2.2。DRY：一份定义多技能引用（协同攻击目标/中毒/流血）。
## （不用 class_name：全局类需编辑器扫描注册，headless 跑找不到；静态变量仍是全局单例。）
## ⚠️ 刷新函数必须叫 reload_data 不能叫 reload——外部 EffectDB.reload() 会命中原生 Script.reload()
## （重编译 + 静态变量全重置）而非本函数（2026-07-02 全 DB 统一约定）。

const FILE := "res://data/effects.json"

static var _effects := {}
static var _loaded := false
static var _path_override := ""   # 测试注入缝：user:// 路径重定向读写，绝不碰 res://data 真数据

static func _path() -> String:
	return _path_override if _path_override != "" else FILE

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	for entry in _read_array(_path()):
		if typeof(entry) == TYPE_DICTIONARY and entry.has("id"):
			_effects[str(entry["id"])] = entry

# 取一个效果定义（找不到返回 null）
static func get_effect(id: String):
	_ensure()
	return _effects.get(id)

static func all() -> Dictionary:
	_ensure()
	return _effects

# 重新加载（清缓存再读）——保存后刷新内存表。（命名铁律见文件头）
static func reload_data() -> void:
	_effects.clear()
	_loaded = false
	_ensure()

# 读文件数组（不存在 / 解析失败 → []）。
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
# 写前整数归一化：JSON 读回的数字全是 float，直接回写会把 1 刷成 1.0（无意义 diff 噪音）。
static func _write_array(path: String, arr: Array) -> bool:
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("EffectDB：写入失败（%s）——文件被占用/只读？" % path)
		return false
	f.store_string(JSON.stringify(_intify(arr), "  "))
	f.close()
	return true

# 递归把「值为整数的 float」还原为 int（1.0→1；1.5 保留）——只影响落盘表示，不改语义。
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

# 保存一个效果（按 id 覆盖、无则新增）→ 写回 → reload。返回是否写盘成功。
# replace_id：改 id 时传旧 id——旧条目移除（否则「改名」变「复制」，旧 id 残留）。
static func save_effect(effect: Dictionary, replace_id := "") -> bool:
	if not effect.has("id") or str(effect["id"]) == "":
		return false
	var id := str(effect["id"])
	var arr := _read_array(_path())
	if replace_id != "" and replace_id != id:
		arr = arr.filter(func(e): return not (typeof(e) == TYPE_DICTIONARY and str(e.get("id", "")) == replace_id))
	var replaced := false
	for i in arr.size():
		if typeof(arr[i]) == TYPE_DICTIONARY and str(arr[i].get("id", "")) == id:
			arr[i] = effect
			replaced = true
			break
	if not replaced:
		arr.append(effect)
	var ok := _write_array(_path(), arr)
	reload_data()
	return ok

# 删除（按 id）→ reload。写盘失败＝false。
static func delete_effect(id: String) -> bool:
	_ensure()
	if not _effects.has(id):
		return false
	var arr := _read_array(_path())
	var out := arr.filter(func(e): return not (typeof(e) == TYPE_DICTIONARY and str(e.get("id", "")) == id))
	if not _write_array(_path(), out):
		return false
	reload_data()
	return true
