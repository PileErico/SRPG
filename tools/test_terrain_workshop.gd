extends SceneTree
## 地块绘制工坊回归：素材整理（add_entry/_create_entry/空分类可见）+ 拼贴预览 WYSIWYG（7 格全 live）
## + 锚行存盘规则（_save_variant 给无锚条目写死遮罩赤道行）。
## 经 TerrainDB._path_override 重定向到 user:// 合成表，绝不碰真 terrains.json；
## 测试 PNG 写进 res://icons/Tiles/zz_wtest_*/ 并在结尾清理。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_terrain_workshop.gd（退出码 0=PASS）
const TerrainDB := preload("res://TerrainDB.gd")
const TT := "user://_test_workshop_terrains.json"
var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _initialize() -> void:
	print("=== 地块绘制工坊测试开始 ===")
	var synth := {
		"format_version": 2.0,
		"categories": ["测试类"],
		"terrains": [
			{"terrain": "zz", "variant": "base", "label": "底甲", "color": "#4a7c3a", "accent": "#7bb35c", "decor": "none", "tags": ["ground"], "move": {"cost": 1.0, "passable_by": "all"}, "effects": [], "category": "测试类"},
			{"terrain": "zz", "variant": "two", "label": "底乙", "color": "#4a7c3a", "accent": "#7bb35c", "decor": "none", "tags": ["ground"], "move": {"cost": 1.0, "passable_by": "all"}, "effects": [], "category": "测试类",
				"art": ["res://icons/Tiles/zz_two/0.png", "res://icons/Tiles/zz_two/1.png"]},
			{"terrain": "zz", "variant": "big", "label": "底丙96", "color": "#4a7c3a", "accent": "#7bb35c", "decor": "none", "tags": ["ground"], "move": {"cost": 1.0, "passable_by": "all"}, "effects": [], "category": "测试类",
				"art_px": [96.0, 96.0]},
		],
	}
	var dst := FileAccess.open(TT, FileAccess.WRITE)
	dst.store_string(JSON.stringify(synth, "  "))
	dst.close()
	TerrainDB._path_override = TT
	TerrainDB.reload_data()

	# —— A) TerrainDB.add_entry 数据层 ——
	var n0: int = TerrainDB.palette().size()
	ck(not TerrainDB.add_entry({"terrain": "", "variant": "x"}), "A1 缺 terrain 拒绝")
	ck(not TerrainDB.add_entry({"terrain": "zz", "variant": "base"}), "A2 撞键拒绝")
	ck(TerrainDB.add_entry({"terrain": "zz", "variant": "new", "label": "新丁", "color": "#888888", "accent": "#aaaaaa", "decor": "none", "tags": [], "move": {"cost": 1, "passable_by": "all"}, "effects": []}), "A3 合法新建")
	ck(TerrainDB.palette().size() == n0 + 1, "A4 palette 多一条")
	ck(TerrainDB.entry_for({"terrain": "zz", "variant": "new"}) != null, "A5 _by_key 可查")
	TerrainDB.save()
	TerrainDB.reload_data()
	ck(TerrainDB.entry_for({"terrain": "zz", "variant": "new"}) != null, "A6 存读往返")

	# —— B) 工坊场景 + _create_entry 逻辑 ——
	var packed = load("res://TerrainArtWorkshop.tscn")
	var inst = (packed as PackedScene).instantiate()
	get_root().add_child(inst)
	await process_frame

	inst._create_entry("焦土", "Zz", "Scorched", "测试类", "battle", false, Color("#5a4a3a"), Color("#8a6a4a"))
	var ce = TerrainDB.entry_for({"terrain": "zz", "variant": "scorched"})   # id 强制小写
	ck(ce != null, "B1 _create_entry 落表（id 小写化）")
	if ce != null:
		ck(str(ce.get("scope", "")) == "battle", "B2 scope=battle 落字段")
		ck(str(ce.get("category", "")) == "测试类", "B3 category 落字段")
		ck(not ce.has("is_object"), "B4 非放置物不落 is_object")
		ck(str(ce.get("color", "")) == "#5a4a3a", "B5 本色落字段")
	ck(inst._sel_key == "zz_scorched", "B6 新建后选中新条目")
	var n1: int = TerrainDB.palette().size()
	inst._create_entry("重复", "zz", "scorched", "", "both", false, Color.WHITE, Color.WHITE)
	ck(TerrainDB.palette().size() == n1, "B7 撞键不落表")
	inst._create_entry("坏id", "zz!", "x y", "", "both", false, Color.WHITE, Color.WHITE)
	ck(TerrainDB.palette().size() == n1, "B8 非法 id 不落表")
	inst._create_entry("物件", "zz", "prop", "", "both", true, Color.WHITE, Color.WHITE)
	var pe = TerrainDB.entry_for({"terrain": "zz", "variant": "prop"})
	ck(pe != null and bool(pe.get("is_object", false)), "B9 放置物落 is_object")
	if pe != null:
		ck(not pe.has("scope"), "B10 通用不落 scope 字段")
	TerrainDB.reload_data()
	ck(TerrainDB.entry_for({"terrain": "zz", "variant": "scorched"}) != null, "B11 _create_entry 已写盘")

	# —— C) 拼贴预览 WYSIWYG：有 2 个既有变体的条目开新变体 → mini 只画 live ——
	inst._pick("zz_two", 0)
	inst._open_draw(inst._entry_by_key("zz_two"), -1)
	await process_frame
	var mini = _find_tilepreview(inst._ov)
	ck(mini != null, "C1 浮层里有 TilePreview")
	if mini != null:
		ck(mini._art == [inst.LIVE_ART_PATH], "C2 预览 art 池只含 live（画什么显示什么）: %s" % str(mini._art))
		ck(mini._idx == 0, "C3 预览选中 live")
		ck(mini._ground == false, "C4 无垫底（灰白 hex 轮廓参考并入 live 纹理，不铺程序地面）")
	# 编辑既有变体同律
	inst._ov.close()
	await process_frame
	inst._open_draw(inst._entry_by_key("zz_two"), 1)
	await process_frame
	mini = _find_tilepreview(inst._ov)
	ck(mini != null and mini._art == [inst.LIVE_ART_PATH], "C5 编辑现有变体同样只画 live")

	# —— D) 锚行存盘：无锚条目 _save_variant 写死遮罩赤道行 ——
	inst._ov.close()
	await process_frame
	var eb = inst._entry_by_key("zz_base")
	ck(TerrainDB.art_anchor_of(eb) < 0.0, "D0 前置：zz_base 无锚")
	inst._open_draw(eb, -1)
	await process_frame
	inst._ov.canvas.img.set_pixel(16, 14, Color(1, 0, 0, 1))   # 稀疏内容：单像素
	inst._save_variant()
	await process_frame
	eb = inst._entry_by_key("zz_base")
	var want := int(inst._hex_equator_row(Vector2i(32, 28)))
	ck(int(TerrainDB.art_anchor_of(eb)) == want, "D1 存盘写死锚行=%d（实际 %d）" % [want, int(TerrainDB.art_anchor_of(eb))])
	ck(TerrainDB.art_of(eb).size() == 1, "D2 变体已注册")
	ck(FileAccess.file_exists(str(TerrainDB.art_of(eb)[0])), "D3 PNG 落盘")
	# 96×96 条目同律（锚行按该画布遮罩算）
	var eg = inst._entry_by_key("zz_big")
	inst._open_draw(eg, -1)
	await process_frame
	inst._ov.canvas.img.set_pixel(48, 90, Color(0, 1, 0, 1))
	inst._save_variant()
	await process_frame
	eg = inst._entry_by_key("zz_big")
	var want96 := int(inst._hex_equator_row(Vector2i(96, 96)))
	ck(int(TerrainDB.art_anchor_of(eg)) == want96, "D4 96×96 锚行=%d（实际 %d）" % [want96, int(TerrainDB.art_anchor_of(eg))])

	# —— E) 空的用户分类在左栏可见（新建分类后能看见、能收条目）——
	var cats: Array = TerrainDB.categories()
	cats.append("空测试类")
	TerrainDB.set_categories(cats)
	inst._populate_left_list()
	await process_frame
	ck(_find_button_prefix(inst._left_list, "空测试类") != null, "E1 空分类占位可见")
	ck(_find_button_prefix(inst._left_list, TerrainDB.DEFAULT_CATEGORY) != null, "E2a 非空「待定」可见（zz_new/zz_prop 在桶里）")
	TerrainDB.delete_entry({"terrain": "zz", "variant": "new"})    # 清空待定桶
	TerrainDB.delete_entry({"terrain": "zz", "variant": "prop"})
	inst._populate_left_list()
	await process_frame
	ck(_find_button_prefix(inst._left_list, TerrainDB.DEFAULT_CATEGORY) == null, "E2b 空「待定」不占位")

	# —— F) 两级排序 ——
	# 条目排序（分类内相邻交换）：测试类顺序 base,two,big,scorched
	ck(not TerrainDB.move_entry({"terrain": "zz", "variant": "base"}, -1), "F1 顶端上移拒绝")
	ck(TerrainDB.move_entry({"terrain": "zz", "variant": "two"}, -1), "F2 上移成功")
	var zz_order := []
	for e4 in TerrainDB.palette():
		if str(e4.get("terrain")) == "zz":
			zz_order.append(str(e4.get("variant")))
	ck(zz_order == ["two", "base", "big", "scorched"], "F3 交换后序=%s" % str(zz_order))
	TerrainDB.save()
	TerrainDB.reload_data()
	var first_zz := ""
	for e5 in TerrainDB.palette():
		if str(e5.get("terrain")) == "zz":
			first_zz = str(e5.get("variant"))
			break
	ck(first_zz == "two", "F4 条目排序存读往返")
	# 分类排序（categories 数组交换）往返
	var cs: Array = TerrainDB.categories()
	ck(cs == ["测试类", "空测试类"], "F5 前置分类序=%s" % str(cs))
	var tmpc = cs[0]; cs[0] = cs[1]; cs[1] = tmpc
	TerrainDB.set_categories(cs)
	TerrainDB.save()
	TerrainDB.reload_data()
	ck(TerrainDB.categories() == ["空测试类", "测试类"], "F6 分类排序存读往返")

	# —— 清理：测试 PNG/目录 + 还原 override ——
	for key in ["zz_base", "zz_big"]:
		var e2 = inst._entry_by_key(key)
		if e2 != null:
			for p in TerrainDB.art_of(e2):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(str(p)))
		DirAccess.remove_absolute(ProjectSettings.globalize_path("res://icons/Tiles/" + key))
	TerrainDB._path_override = ""
	TerrainDB.reload_data()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TT))

	if _fail == 0:
		print("=== 全 PASS ===")
	else:
		print("=== %d 项 FAIL ===" % _fail)
	quit(0 if _fail == 0 else 1)

# 递归找 TilePreview 实例（浮层 side_extra）
func _find_tilepreview(node):
	if node == null:
		return null
	if node is Control and node.get_script() == load("res://TilePreview.gd"):
		return node
	for c in node.get_children():
		var r = _find_tilepreview(c)
		if r != null:
			return r
	return null

# 递归找文本含 prefix 的 Button（折叠组头文本带 ▸/▾ 箭头前缀，用 contains）
func _find_button_prefix(node, prefix: String):
	if node == null:
		return null
	if node is Button and str(node.text).contains(prefix):
		return node
	for c in node.get_children():
		var r = _find_button_prefix(c, prefix)
		if r != null:
			return r
	return null
