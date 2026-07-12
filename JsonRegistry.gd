extends RefCounted
## 注册表通用加载器（DB 范式辅助；preload + static，无 class_name、无自身状态）：
## 收拢各注册表 _ensure() 里「读盘 → 解析 → typeof 守卫 → 遍历建 有序 list + by_id」的同构样板。
## 各 DB 只声明 路径/顶层键；改校验/容错/警告口径只此一处。
## 用法：const JsonRegistry := preload("res://JsonRegistry.gd")
##   var r = JsonRegistry.load_indexed(path, "factions")   → {"list": Array, "by_id": Dictionary}
##   key 空＝顶层即数组（如 EventDB）；非空＝data.get(key, [])（多数 DB）。
## 兜底：缺文件/打不开/解析失败/顶层非数组 → push_warning + 空表；无 id/非 dict 条目 → 跳过 + 警告。

# ============ 读/写盘口（技改 §4-4：EffectDB/ItemDB/SkillDB/AppearanceDB 四份逐字重复上收；
# TerrainDB.save 同接 intify——§4-5 治 terrains.json 的 1.0 噪音）============

# 读文件数组（不存在 / 解析失败 → []）
static func read_array(path: String) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	return data if typeof(data) == TYPE_ARRAY else []

# 读文件字典（不存在 / 解析失败 → {}）
static func read_dict(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	return data if typeof(data) == TYPE_DICTIONARY else {}

# 写 JSON（2 空格缩进 + 整数归一化——JSON 读回数字全 float，直写会把 1 刷成 1.0 的 diff 噪音）。
# 打不开（占用/只读/目录不存在）＝false，调用方须传导失败。who＝警告归属（各 DB 名）。
static func write_json(path: String, data, who := "JsonRegistry") -> bool:
	var f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("%s：写入失败（%s）——文件被占用/只读/目录不存在？" % [who, path])
		return false
	f.store_string(JSON.stringify(intify(data), "  "))
	f.close()
	return true

# 递归把「值为整数的 float」还原为 int（1.0→1；1.5 保留）——只影响落盘表示，不改语义
static func intify(v):
	match typeof(v):
		TYPE_FLOAT:
			return int(v) if v == floorf(v) else v
		TYPE_ARRAY:
			var out := []
			for e in v:
				out.append(intify(e))
			return out
		TYPE_DICTIONARY:
			var out := {}
			for k in v:
				out[k] = intify(v[k])
			return out
	return v

static func load_indexed(path: String, key := "") -> Dictionary:
	var out := {"list": [], "by_id": {}}
	if not FileAccess.file_exists(path):
		push_warning("JsonRegistry：%s 缺失——注册表为空" % path)
		return out
	var f = FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("JsonRegistry：%s 打不开——注册表为空" % path)
		return out
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	var arr = data if key == "" else (data.get(key, []) if typeof(data) == TYPE_DICTIONARY else null)
	if typeof(arr) != TYPE_ARRAY:
		push_warning("JsonRegistry：%s 解析失败/顶层非预期形态——注册表为空" % path)
		return out
	for e in arr:
		if typeof(e) == TYPE_DICTIONARY and str(e.get("id", "")) != "":
			out["list"].append(e)
			out["by_id"][str(e["id"])] = e
		else:
			push_warning("JsonRegistry：%s 跳过无 id/非法条目" % path)
	return out
