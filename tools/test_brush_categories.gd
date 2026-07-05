extends SceneTree
## 笔刷分类管理数据层回归：TerrainDB 的 categories/set_category/set_label/delete_entry + save/reload 往返。
## 经 _path_override 重定向到 user:// 临时 copy，绝不碰真 terrains.json。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_brush_categories.gd（退出码 0=PASS）
const TerrainDB := preload("res://TerrainDB.gd")
const TT := "user://_test_cats_terrains.json"
var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _initialize() -> void:
	print("=== 笔刷分类管理测试开始 ===")
	# 写一份合成 terrains.json（无 categories、无分类）→ user://，重定向；不依赖真表状态（真表已被用户分类，不能假设"初始为空"）
	var synth := {
		"format_version": 2.0,
		"terrains": [
			{"terrain": "a", "variant": "1", "label": "甲", "color": "#ffffff", "accent": "#000000", "decor": "none", "tags": [], "move": {"cost": 1.0, "passable_by": "all"}, "effects": [], "scope": "both"},
			{"terrain": "b", "variant": "1", "label": "乙", "color": "#ffffff", "accent": "#000000", "decor": "none", "tags": [], "move": {"cost": 1.0, "passable_by": "all"}, "effects": [], "scope": "both"},
			{"terrain": "fh", "variant": "junk", "label": "丙", "color": "#ffffff", "accent": "#000000", "decor": "none", "tags": [], "move": {"cost": 1.0, "passable_by": "all"}, "effects": [], "scope": "both", "art": ["res://x.png"]},
		],
	}
	var dst := FileAccess.open(TT, FileAccess.WRITE)
	dst.store_string(JSON.stringify(synth, "  "))
	dst.close()
	TerrainDB._path_override = TT
	TerrainDB.reload_data()

	var pal: Array = TerrainDB.palette()
	ck(pal.size() > 0, "palette 非空 (%d)" % pal.size())
	var t0 = {"terrain": pal[0].get("terrain"), "variant": pal[0].get("variant")}

	# A) categories 往返
	ck(TerrainDB.categories().is_empty(), "初始无 categories")
	TerrainDB.set_categories(["林地", "水域"])
	TerrainDB.save()
	TerrainDB.reload_data()
	ck(TerrainDB.categories() == ["林地", "水域"], "categories 存读往返")

	# B) set_category / category_of 往返（并验待定＝无字段）
	pal = TerrainDB.palette()
	t0 = {"terrain": pal[0].get("terrain"), "variant": pal[0].get("variant")}
	ck(TerrainDB.category_of(pal[0]) == TerrainDB.DEFAULT_CATEGORY, "默认属待定")
	TerrainDB.set_category(t0, "林地")
	ck(TerrainDB.category_of(TerrainDB.entry_for(t0)) == "林地", "set_category 生效")
	TerrainDB.save()
	TerrainDB.reload_data()
	ck(TerrainDB.category_of(TerrainDB.entry_for(t0)) == "林地", "category 存读往返")
	TerrainDB.set_category(t0, TerrainDB.DEFAULT_CATEGORY)   # 移回待定＝抹字段
	ck(not TerrainDB.entry_for(t0).has("category"), "移回待定抹掉 category 字段")

	# C) set_label 往返
	TerrainDB.set_label(t0, "改名测试X")
	TerrainDB.save()
	TerrainDB.reload_data()
	ck(str(TerrainDB.entry_for(t0).get("label")) == "改名测试X", "set_label 存读往返")

	# D) delete_entry 往返（挑一个 fh 导入的删，别动核心地形）
	pal = TerrainDB.palette()
	var victim = null
	for e in pal:
		if str(e.get("terrain")) == "fh":
			victim = e
			break
	if victim != null:
		var vt = {"terrain": victim.get("terrain"), "variant": victim.get("variant")}
		var n0 := pal.size()
		ck(TerrainDB.delete_entry(vt), "delete_entry 返回 true")
		ck(TerrainDB.palette().size() == n0 - 1, "palette 少一条")
		ck(TerrainDB.entry_for(vt) == null, "_by_key 同步移除")
		TerrainDB.save()
		TerrainDB.reload_data()
		ck(TerrainDB.entry_for(vt) == null, "delete 存读往返（仍不在）")
	else:
		print("(无 fh 条目，跳过 delete 测试)")

	if _fail == 0:
		print("=== 全 PASS ===")
	else:
		print("=== %d 项 FAIL ===" % _fail)
	quit(0 if _fail == 0 else 1)
