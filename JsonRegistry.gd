extends RefCounted
## 注册表通用加载器（DB 范式辅助；preload + static，无 class_name、无自身状态）：
## 收拢各注册表 _ensure() 里「读盘 → 解析 → typeof 守卫 → 遍历建 有序 list + by_id」的同构样板。
## 各 DB 只声明 路径/顶层键；改校验/容错/警告口径只此一处。
## 用法：const JsonRegistry := preload("res://JsonRegistry.gd")
##   var r = JsonRegistry.load_indexed(path, "factions")   → {"list": Array, "by_id": Dictionary}
##   key 空＝顶层即数组（如 EventDB）；非空＝data.get(key, [])（多数 DB）。
## 兜底：缺文件/打不开/解析失败/顶层非数组 → push_warning + 空表；无 id/非 dict 条目 → 跳过 + 警告。

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
