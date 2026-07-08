extends SceneTree
## ItemDB 回归：kind 路由/新增/覆盖/换类别迁移/**改 id 语义（replace_id，改名≠复制）**/删除/写盘失败传导
## + kind_cn 单一源 + StatMeta.is_pct。经 _paths_override 重定向到 user:// 临时文件——绝不碰 res://data 真数据。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_itemdb.gd（退出码 0=PASS）

const ItemDB := preload("res://ItemDB.gd")
const StatMeta := preload("res://StatMeta.gd")

const P_W := "user://_test_items_w.json"
const P_A := "user://_test_items_a.json"
const P_C := "user://_test_items_c.json"
const P_I := "user://_test_items_i.json"

var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _write(path: String, arr: Array) -> void:
	var f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(arr, "  "))
	f.close()

func _ids(path: String) -> Array:
	var out := []
	if FileAccess.file_exists(path):
		var f = FileAccess.open(path, FileAccess.READ)
		var data = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(data) == TYPE_ARRAY:
			for e in data:
				out.append(str(e.get("id", "")))
	return out

func _initialize() -> void:
	print("=== ItemDB 测试开始 ===")

	# 0) 接管路径 + 种子
	ItemDB._paths_override = {"weapon": P_W, "armor": P_A, "accessory": P_C}
	_write(P_W, [{"id": "sword_t", "name": "测试剑", "slot": "main_hand", "tags": ["common"]}])
	_write(P_A, [{"id": "cap_t", "name": "测试帽", "slot": "head", "tags": ["common"]}])
	DirAccess.remove_absolute(P_C)   # 饰品文件初始不存在（仿真实：accessories.json 未建）
	ItemDB.reload_data()
	ck(ItemDB.get_item("sword_t") != null and ItemDB.get_item("cap_t") != null, "种子可读")

	# 1) kind 路由 + kind_cn 单一源
	ck(ItemDB.kind_of({"slot": "off_hand"}) == "weapon", "kind_of: off_hand→weapon")
	ck(ItemDB.kind_of({"slot": "body"}) == "armor", "kind_of: body→armor")
	ck(ItemDB.kind_of({"slot": "accessory_2"}) == "accessory", "kind_of: accessory_2→accessory")
	ck(ItemDB.kind_cn("weapon") == "武器" and ItemDB.kind_cn("x") == "x", "kind_cn 兜底")

	# 2) 新增：饰品 → 文件自动创建
	ck(ItemDB.save_item({"id": "ring_t", "name": "戒指", "slot": "accessory_1", "tags": []}), "save 新增成功")
	ck(ItemDB.get_item("ring_t") != null and _ids(P_C) == ["ring_t"], "写进饰品文件")

	# 3) 同 id 覆盖（upsert 不重复）
	ItemDB.save_item({"id": "sword_t", "name": "精铁剑", "slot": "main_hand", "tags": []})
	ck(str(ItemDB.get_item("sword_t").get("name")) == "精铁剑", "同 id 覆盖")
	ck(_ids(P_W).size() == 1, "文件内不重复")

	# 4) 换类别（slot 改）→ 移文件、旧文件清掉
	ItemDB.save_item({"id": "sword_t", "name": "剑改胸甲", "slot": "body", "tags": []})
	ck(_ids(P_W).is_empty() and _ids(P_A).has("sword_t"), "换类别移文件")

	# 5) 改 id（replace_id）：改名≠复制，旧条目移除
	ck(ItemDB.save_item({"id": "breast_t", "name": "胸甲", "slot": "body", "tags": []}, "sword_t"), "改 id 保存成功")
	ck(ItemDB.get_item("sword_t") == null and ItemDB.get_item("breast_t") != null, "旧 id 消失、新 id 在")
	ck(not _ids(P_A).has("sword_t"), "文件无旧 id 残留")

	# 6) 删除
	ck(ItemDB.delete_item("breast_t"), "delete 成功")
	ck(ItemDB.get_item("breast_t") == null and not _ids(P_A).has("breast_t"), "删除落盘")
	ck(not ItemDB.delete_item("no_such"), "删不存在 → false")

	# 7) 写盘失败传导：目标目录不存在 → save false（原先静默当成功）
	ItemDB._paths_override = {"weapon": "user://_no_dir_x/w.json", "armor": P_A, "accessory": P_C}
	ck(not ItemDB.save_item({"id": "fail_t", "slot": "main_hand", "tags": []}), "写盘失败 → false")

	# 8) StatMeta.is_pct（原 UnitStatusPanel._is_pct_stat 迁入）
	ck(StatMeta.is_pct("res_nature") and StatMeta.is_pct("armor_res_phys") and StatMeta.is_pct("atk_eff") and StatMeta.is_pct("crit_rate") and StatMeta.is_pct("block_power") and StatMeta.is_pct("crit_dmg") and StatMeta.is_pct("will_fort"), "百分比语义真集（含甲抗/强韧）")
	ck(not StatMeta.is_pct("atk") and not StatMeta.is_pct("move") and not StatMeta.is_pct("armor_max") and not StatMeta.is_pct("dr_flat_armor"), "百分比语义假集（固减非%）")

	# 9) item kind（消耗品/物品：显式 kind 字段路由 items.json，无装备槽）——授权 B
	ItemDB._paths_override = {"weapon": P_W, "armor": P_A, "accessory": P_C, "item": P_I}
	DirAccess.remove_absolute(P_I)
	ItemDB.reload_data()
	ck(ItemDB.kind_of({"kind": "item", "tags": ["consumable"]}) == "item", "kind_of: 显式 kind=item 优先")
	ck(ItemDB.kind_of({"slot": "main_hand"}) == "weapon", "kind_of: 无 kind 仍按 slot（向后兼容）")
	ck(str(ItemDB.kind_cn("item")) == "物品", "kind_cn: item→物品")
	ck(ItemDB.save_item({"id": "potion_t", "name": "药水", "kind": "item", "tags": ["consumable", "medical"], "on_use": {"heal_pct_max_hp": 50}}), "save 消耗品成功")
	ck(ItemDB.get_item("potion_t") != null and _ids(P_I) == ["potion_t"], "写进 items 文件")
	ck(ItemDB.delete_item("potion_t") and not _ids(P_I).has("potion_t"), "消耗品删除落盘")

	# 收尾：还原真路径 + 清临时文件
	ItemDB._paths_override = {}
	ItemDB.reload_data()
	for p in [P_W, P_A, P_C, P_I]:
		DirAccess.remove_absolute(p)
	ck(ItemDB.get_item("ring_t") == null, "还原后测试物品不在真库")

	if _fail == 0:
		print("=== 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
