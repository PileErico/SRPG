extends RefCounted
## 存读档单一入口（仿 MapIO 范式）：campaign 存档落 `user://saves/<slot>.json`。
## 只管「WorldState ↔ 磁盘」的搬运与槽位管理，不解释内容；版本兼容＝save_version + 读端 .get 兜底。
## 战中临时存档（suspend）🔒＝另一层、可裁剪，不在此处（见 docs/meta架构规划.md §2 B层）。
## 用法：const SaveIO := preload("res://SaveIO.gd") → SaveIO.save_campaign(ws, "slot1") / load_campaign("slot1")。

const WorldState := preload("res://WorldState.gd")

const SAVE_DIR := "user://saves"
const AUTO_SLOT := "auto"   # 自动存档槽名单一源（Overworld 写 / StartMenu「继续」读；⚠️ 测试铁律：测试不得写此槽）

static func slot_path(slot: String) -> String:
	return "%s/%s.json" % [SAVE_DIR, slot]

# slot 名净化：拒绝路径穿越/非法字符（"../evil"、盘符、分隔符），防写出 saves 目录之外。
static func _valid_slot(slot: String) -> bool:
	var s := slot.strip_edges()
	return s != "" and not s.contains("/") and not s.contains("\\") and not s.contains("..") and not s.contains(":")

# 存档（true=成功）。铁人策略（强制单槽）由调用方按 ws.ironman 决定传哪个 slot，这里不管。
static func save_campaign(ws, slot: String) -> bool:
	if ws == null or not _valid_slot(slot):
		return false
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	var f := FileAccess.open(slot_path(slot), FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(ws.to_dict(), "  "))
	f.close()
	return true

# 读档：返回 WorldState 实例；缺失/损坏/占用返回 null（调用方兜底）。
# 只构建不激活：不写 WorldState.current（且 from_dict 无全局副作用，可安全做存档预览）。
static func load_campaign(slot: String):
	if not _valid_slot(slot):
		return null
	var p := slot_path(slot)
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
	if not FileAccess.file_exists(p):
		return false
	return DirAccess.remove_absolute(p) == OK
