extends RefCounted
## 存读档单一入口（仿 MapIO 范式）：campaign 存档落 `user://saves/<slot>.json`。
## 只管「WorldState ↔ 磁盘」的搬运与槽位管理，不解释内容；版本兼容＝save_version + 读端 .get 兜底。
## 战中临时存档（suspend）🔒＝另一层、可裁剪，不在此处（见 docs/meta架构规划.md §2 B层）。
## 用法：const SaveIO := preload("res://SaveIO.gd") → SaveIO.save_campaign(ws, "slot1") / load_campaign("slot1")。

const WorldState := preload("res://WorldState.gd")

const SAVE_DIR := "user://saves"
const AUTO_SLOT := "auto"   # 自动存档槽名单一源（Overworld 写 / StartMenu「继续」读；⚠️ 测试铁律：测试不得写此槽）
const MANUAL_SLOTS := ["save1", "save2", "save3"]   # 手动槽位单一源（Overworld 存档面板 / StartMenu 读档列表共用）

static func slot_path(slot: String) -> String:
	return "%s/%s.json" % [SAVE_DIR, slot]

# slot 名净化：拒绝路径穿越/非法字符（"../evil"、盘符、分隔符），防写出 saves 目录之外。
static func _valid_slot(slot: String) -> bool:
	var s := slot.strip_edges()
	return s != "" and not s.contains("/") and not s.contains("\\") and not s.contains("..") and not s.contains(":")

# 存档（true=成功）。铁人策略（强制单槽+禁手动）由调用方按 ws.ironman 决定，这里不管。
# 原子写 🔒（技改提案波B-4）：先写 .tmp → 旧档转 .bak（一级回滚）→ rename 顶正位——
# 写一半崩电/崩进程＝正档或 .bak 至少一份完好，「继续战役」永不因半截 JSON 变灰。
static func save_campaign(ws, slot: String) -> bool:
	if ws == null or not _valid_slot(slot):
		return false
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	var p := slot_path(slot)
	var tmp := p + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(ws.to_dict(), "  "))
	f.close()
	if FileAccess.file_exists(p):
		if FileAccess.file_exists(p + ".bak"):
			DirAccess.remove_absolute(p + ".bak")
		DirAccess.rename_absolute(p, p + ".bak")
	return DirAccess.rename_absolute(tmp, p) == OK

# 读档：返回 WorldState 实例；缺失/损坏/占用 → 自动回退 .bak（响亮警告），双失才 null（调用方兜底）。
# 只构建不激活：不写 WorldState.current（且 from_dict 无全局副作用，可安全做存档预览）。
static func load_campaign(slot: String):
	if not _valid_slot(slot):
		return null
	var ws = _load_file(slot_path(slot))
	if ws != null:
		return ws
	ws = _load_file(slot_path(slot) + ".bak")
	if ws != null:
		push_warning("SaveIO：槽「%s」主档缺失/损坏——已回退上一份 .bak 存档" % slot)
	return ws

static func _load_file(p: String):
	if not FileAccess.file_exists(p):
		return null
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:   # 存在但打不开（外部占用/权限/竞态删除）
		return null
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(d) != TYPE_DICTIONARY:
		return null
	return WorldState.from_dict(d)

# 槽位速览（存/读档 UI 用）：直接读 JSON 键不构建 WorldState；空槽/坏档返回 {}。
static func slot_info(slot: String) -> Dictionary:
	if not _valid_slot(slot):
		return {}
	var p := slot_path(slot)
	if not FileAccess.file_exists(p):
		return {}
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(d) != TYPE_DICTIONARY:
		return {}
	return {
		"clock_hours": int(d.get("clock_hours", 0)),
		"party": (d.get("roster", []) as Array).size() if typeof(d.get("roster", [])) == TYPE_ARRAY else 0,
		"gold": int(d.get("gold", 0)),
		"ironman": bool(d.get("ironman", false)),
		"mtime": FileAccess.get_modified_time(p),
	}

# 列出现有存档槽名（不含 .json 后缀），按文件名排序。
static func list_slots() -> Array:
	var out := []
	var dir := DirAccess.open(SAVE_DIR)
	if dir == null:
		return out
	for fn in dir.get_files():
		if fn.ends_with(".json"):
			out.append(fn.trim_suffix(".json"))
	out.sort()
	return out

static func delete_slot(slot: String) -> bool:
	if not _valid_slot(slot):
		return false
	var p := slot_path(slot)
	if FileAccess.file_exists(p + ".bak"):
		DirAccess.remove_absolute(p + ".bak")   # 删槽连 .bak 一起清
	if not FileAccess.file_exists(p):
		return false
	return DirAccess.remove_absolute(p) == OK
