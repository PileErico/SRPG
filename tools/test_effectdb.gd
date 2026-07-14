extends SceneTree
## EffectDB 回归：读真库 bleeding / 新增 / 同 id 覆盖(upsert 不重复) / 改 id(replace_id，改名≠复制) /
## 删除 / 写盘失败传导 / reload_data。经 _path_override 重定向到 user:// 临时文件——绝不碰 res://data 真数据。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_effectdb.gd（退出码 0=PASS）

const EffectDB := preload("res://EffectDB.gd")

const P := "user://_test_effects.json"

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
	print("=== EffectDB 测试开始 ===")

	# 0) 真库：流血定义可读、字段正确（效果 id 随用户重建改：bleeding→bleeding_basic 2026-07-15）
	var bleed = EffectDB.get_effect("bleeding_basic")
	ck(bleed != null, "真库 bleeding_basic 可读")
	if bleed != null:
		ck(str(bleed.get("kind", "")) == "debuff", "bleeding_basic kind=debuff")
		ck((bleed.get("tags", []) as Array).has("bleeding"), "bleeding_basic tag 有 bleeding")
		ck(int(bleed.get("dot_pct_max_hp", 0)) == 5, "bleeding_basic dot=5%")
		ck(str(bleed.get("duration_model", "")) == "fixed", "bleeding_basic duration_model=fixed")

	# 1) 接管路径 + 空库起步
	EffectDB._path_override = P
	DirAccess.remove_absolute(P)
	EffectDB.reload_data()
	ck(EffectDB.get_effect("bleeding_basic") == null, "接管临时库后 bleeding_basic 不在（隔离真数据）")

	# 2) 新增 → 文件自动创建 + 可读
	ck(EffectDB.save_effect({"id": "poison_t", "name": "中毒", "kind": "debuff", "tags": ["poison"], "dot_pct_max_hp": 3}), "save 新增成功")
	ck(EffectDB.get_effect("poison_t") != null and _ids(P) == ["poison_t"], "写进临时库 + 可读")

	# 3) 同 id 覆盖（upsert 不重复）
	EffectDB.save_effect({"id": "poison_t", "name": "剧毒", "kind": "debuff", "tags": ["poison"], "dot_pct_max_hp": 8})
	ck(str(EffectDB.get_effect("poison_t").get("name")) == "剧毒", "同 id 覆盖生效")
	ck(_ids(P).size() == 1, "文件内不重复")

	# 4) 改 id（replace_id）：改名≠复制，旧条目移除
	ck(EffectDB.save_effect({"id": "venom_t", "name": "剧毒", "kind": "debuff", "tags": ["poison"]}, "poison_t"), "改 id 保存成功")
	ck(EffectDB.get_effect("poison_t") == null and EffectDB.get_effect("venom_t") != null, "旧 id 消失、新 id 在")
	ck(not _ids(P).has("poison_t"), "文件无旧 id 残留")

	# 5) 删除
	ck(EffectDB.delete_effect("venom_t"), "delete 成功")
	ck(EffectDB.get_effect("venom_t") == null and not _ids(P).has("venom_t"), "删除落盘")
	ck(not EffectDB.delete_effect("no_such"), "删不存在 → false")

	# 6) 无 id → 拒绝保存
	ck(not EffectDB.save_effect({"name": "无id"}), "无 id 保存被拒")

	# 7) 写盘失败传导：目录不存在 → save false
	EffectDB._path_override = "user://_no_dir_x/effects.json"
	ck(not EffectDB.save_effect({"id": "fail_t", "name": "x"}), "写盘失败 → false")

	# 收尾：还原真路径 + 清临时文件
	EffectDB._path_override = ""
	EffectDB.reload_data()
	DirAccess.remove_absolute(P)
	ck(EffectDB.get_effect("bleeding_basic") != null and EffectDB.get_effect("venom_t") == null, "还原后真库回归、测试效果不残留")

	if _fail == 0:
		print("=== 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
