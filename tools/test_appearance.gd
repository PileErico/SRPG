extends SceneTree
## 外观模块回归：AppearanceDB 读/查/upsert/改id/删（经 _path_override 重定向到 user:// 临时文件，绝不碰真数据）
## + PaperDoll.recolor 亮度→渐变纯函数 + compose 真实部件合成（换色确实生效、透明保持、尺寸正确）。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_appearance.gd（退出码 0=PASS）

const AppearanceDB := preload("res://AppearanceDB.gd")
const PaperDoll := preload("res://PaperDoll.gd")
const PixelDrawCanvas := preload("res://PixelDrawCanvas.gd")

const P := "user://_test_appearance.json"
const P_LOOKS := "user://_test_looks.json"
var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _seed(doc: Dictionary) -> void:
	var f = FileAccess.open(P, FileAccess.WRITE)
	f.store_string(JSON.stringify(doc, "  "))
	f.close()

func _initialize() -> void:
	print("=== 外观模块测试开始 ===")

	# ---------- A) AppearanceDB 读/查/写（临时文件） ----------
	AppearanceDB._path_override = P
	_seed({
		"config": {"size": 24},
		"slots": [{"id": "body", "cn": "身体", "z": 0}, {"id": "hair", "cn": "头发", "z": 30}],
		"parts": [
			{"id": "b1", "slot": "body", "path": "res://x/b1.png", "recolorable": true, "default_palette": "p1"},
			{"id": "h1", "slot": "hair", "path": "res://x/h1.png", "recolorable": true},
		],
		"palettes": [{"id": "p1", "cn": "测试盘", "stops": ["#000000", "#ffffff"]}],
	})
	AppearanceDB.reload_data()

	ck(AppearanceDB.canvas_size() == 24, "canvas_size 读 config")
	ck(AppearanceDB.slots().size() == 2 and str(AppearanceDB.slots()[0].get("id")) == "body", "slots 按 z 序")
	ck(AppearanceDB.parts_in_slot("body").size() == 1, "parts_in_slot 过滤")
	ck(AppearanceDB.get_part("b1") != null and AppearanceDB.get_part("nope") == null, "get_part")
	ck(AppearanceDB.get_palette("p1") != null, "get_palette")

	# upsert 覆盖
	ck(AppearanceDB.save_part({"id": "b1", "slot": "body", "path": "res://x/b1b.png", "recolorable": true}), "save_part 覆盖")
	ck(str(AppearanceDB.get_part("b1").get("path")) == "res://x/b1b.png", "覆盖生效")
	ck(AppearanceDB.parts_in_slot("body").size() == 1, "覆盖不重复")

	# 新增
	ck(AppearanceDB.save_part({"id": "b2", "slot": "body", "path": "res://x/b2.png"}), "save_part 新增")
	ck(AppearanceDB.parts_in_slot("body").size() == 2, "新增计数")

	# 改 id（replace_id）：改名≠复制
	ck(AppearanceDB.save_part({"id": "b2x", "slot": "body", "path": "res://x/b2.png"}, "b2"), "改 id")
	ck(AppearanceDB.get_part("b2") == null and AppearanceDB.get_part("b2x") != null, "旧 id 消失 / 新 id 在")

	# 删除
	ck(AppearanceDB.delete_part("b2x"), "delete_part")
	ck(AppearanceDB.get_part("b2x") == null and AppearanceDB.parts_in_slot("body").size() == 1, "删除落盘")
	ck(not AppearanceDB.delete_part("no_such"), "删不存在→false")

	# 调色板 upsert
	ck(AppearanceDB.save_palette({"id": "p2", "cn": "新盘", "stops": ["#111111", "#222222"]}), "save_palette")
	ck(AppearanceDB.get_palette("p2") != null, "调色板新增")

	# 槽位 CRUD + 层序（新增部件总类 / 调 z / 删连带部件）
	ck(AppearanceDB.slots().size() == 2 and AppearanceDB.max_z() == 30, "初始 2 槽 / max_z")
	ck(AppearanceDB.save_slot({"id": "cape", "cn": "披风", "z": 40}), "save_slot 新增")
	ck(str(AppearanceDB.slots()[2].get("id")) == "cape", "新槽 z 最大→在最上")
	ck(AppearanceDB.save_slot({"id": "cape", "cn": "披风", "z": -10}), "save_slot 改 z")
	ck(str(AppearanceDB.slots()[0].get("id")) == "cape", "披风降到最底层")
	AppearanceDB.save_part({"id": "cap1", "slot": "cape", "path": "res://x/cape.png"})
	ck(AppearanceDB.parts_in_slot("cape").size() == 1, "披风槽有部件")
	ck(AppearanceDB.delete_slot("cape"), "delete_slot")
	ck(AppearanceDB.get_slot("cape") == null and AppearanceDB.parts_in_slot("cape").is_empty(), "删槽连带其部件")

	# 外观配方存储 looks（应用到单位后回读再编辑）
	AppearanceDB._looks_override = P_LOOKS
	DirAccess.remove_absolute(P_LOOKS)
	ck(AppearanceDB.all_looks().is_empty(), "looks 初始空")
	ck(AppearanceDB.save_look("hero", {"parts": {"body": "b1"}, "palettes": {"body": "p1"}}), "save_look")
	ck(typeof(AppearanceDB.get_look("hero")) == TYPE_DICTIONARY, "get_look 命中")
	ck(AppearanceDB.get_look("nope") == null, "get_look 缺失=null")
	ck(AppearanceDB.all_looks().has("hero"), "all_looks")
	DirAccess.remove_absolute(P_LOOKS)
	AppearanceDB._looks_override = ""

	# ---------- B) PaperDoll.recolor 纯函数 ----------
	var src := Image.create(4, 1, false, Image.FORMAT_RGBA8)
	src.set_pixel(0, 0, Color(0, 0, 0, 1))          # 黑 → lum 0
	src.set_pixel(1, 0, Color(0.5, 0.5, 0.5, 1))    # 灰 → lum 0.5
	src.set_pixel(2, 0, Color(1, 1, 1, 1))          # 白 → lum 1
	src.set_pixel(3, 0, Color(0, 0, 0, 0))          # 透明 → 保持透明
	var stops := PackedColorArray([Color(1, 0, 0), Color(0, 0, 1)])   # 红→蓝
	var out := PaperDoll.recolor(src, stops)
	ck(out.get_pixel(0, 0).is_equal_approx(Color(1, 0, 0, 1)), "recolor: 暗端→stop0(红)")
	ck(out.get_pixel(2, 0).is_equal_approx(Color(0, 0, 1, 1)), "recolor: 亮端→stop_n(蓝)")
	var mid := out.get_pixel(1, 0)
	ck(abs(mid.r - 0.5) < 0.02 and abs(mid.b - 0.5) < 0.02, "recolor: 中点线性插值")
	ck(out.get_pixel(3, 0).a == 0.0, "recolor: 透明像素保持透明（不泛渐变暗端）")
	ck(src.get_pixel(0, 0).is_equal_approx(Color(0, 0, 0, 1)), "recolor: 不改入参")

	# ---------- C) compose 合成（自包含：临时 PNG + override，不依赖 res:// 真素材） ----------
	# 写两张 8x8 测试图：白(可染) + 右列红(叠加验证)
	var white := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	for yy in 8:
		for xx in 8:
			white.set_pixel(xx, yy, Color(1, 1, 1, 1))
	white.save_png("user://_tp_white.png")
	var rcol := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	rcol.fill(Color(0, 0, 0, 0))
	for yy in 8:
		rcol.set_pixel(7, yy, Color(1, 0.2, 0.2, 1))
	rcol.save_png("user://_tp_red.png")
	PaperDoll.clear_cache()
	AppearanceDB._path_override = P
	_seed({
		"config": {"size": 8},
		"slots": [{"id": "body", "cn": "身体", "z": 0}, {"id": "wpn", "cn": "武器", "z": 10}],
		"parts": [
			{"id": "b", "slot": "body", "path": "user://_tp_white.png", "recolorable": true, "default_palette": "skin"},
			{"id": "w", "slot": "wpn", "path": "user://_tp_red.png", "recolorable": true},
		],
		"palettes": [{"id": "skin", "cn": "肤", "stops": ["#20140f", "#e8b48c"]}],
	})
	AppearanceDB.reload_data()
	ck(AppearanceDB.canvas_size() == 8, "override size=8")

	var empty := PaperDoll.compose({})
	ck(empty.get_width() == 8 and empty.get_pixel(4, 4).a == 0.0, "空配方全透明")

	# 换色：白(lum≈1)→亮端肤色
	var comp := PaperDoll.compose({"parts": {"body": "b"}, "palettes": {"body": "skin"}})
	var px := comp.get_pixel(4, 4)
	ck(px.a > 0.5 and px.r > px.b, "合成+换色生效（肤色 r>b）")
	# 无＝不换色：白保持白
	var comp0 := PaperDoll.compose({"parts": {"body": "b"}, "palettes": {"body": ""}})
	ck(comp0.get_pixel(4, 4).is_equal_approx(Color(1, 1, 1, 1)), "调色板『无』＝部件原色（白保持白）")
	# 叠加武器
	var comp2 := PaperDoll.compose({"parts": {"body": "b", "wpn": "w"}, "palettes": {"body": "", "wpn": ""}})
	ck(comp2.get_pixel(7, 3).r > 0.5 and comp2.get_pixel(7, 3).g < 0.5, "武器叠加到右列")

	# 导出 PNG（2x）
	var exp_path := "user://_test_appearance_export.png"
	ck(PaperDoll.export_png({"parts": {"body": "b"}, "palettes": {"body": ""}}, exp_path, 2), "export_png 成功")
	var chk := Image.new()
	ck(chk.load(exp_path) == OK and chk.get_width() == 16, "导出 PNG 可读 & 2x 放大")
	DirAccess.remove_absolute(exp_path)
	DirAccess.remove_absolute("user://_tp_white.png")
	DirAccess.remove_absolute("user://_tp_red.png")
	AppearanceDB._path_override = ""
	PaperDoll.clear_cache()

	# ---------- E) PixelDrawCanvas 选区引擎（提取/移动/复制粘贴/删除） ----------
	var pdc = PixelDrawCanvas.new()
	pdc.setup(8, null, null)
	for yy in [1, 2]:
		for xx in [1, 2]:
			pdc.img.set_pixel(xx, yy, Color(1, 1, 1, 1))   # 2x2 白块 @ (1,1)
	pdc._select_rect(Vector2i(1, 1), Vector2i(2, 2))
	ck(pdc._sel.size() == 4, "select_rect 选中 4 格")
	pdc._lift(true)   # 提成浮动块 + 从图抹掉
	ck(pdc.img.get_pixel(1, 1).a == 0.0 and pdc._float.size() == 4, "lift(cut) 抹原位+浮动4像素")
	pdc._float_off = Vector2i(3, 3)
	pdc._commit_float()
	ck(pdc.img.get_pixel(4, 4).a > 0.5 and pdc.img.get_pixel(1, 1).a == 0.0, "移动落定到新位")
	pdc._select_rect(Vector2i(4, 4), Vector2i(5, 5))
	pdc._copy()
	ck(pdc._clip.size() == 4, "复制 4 像素到剪贴板")
	pdc._paste()
	ck(pdc._float.size() == 4, "粘贴生成浮动块")
	pdc._commit_float()
	pdc._select_rect(Vector2i(4, 4), Vector2i(5, 5))
	pdc._delete_sel()
	ck(pdc.img.get_pixel(4, 4).a == 0.0, "删除选区清空像素")
	# 魔棒选同色连通块
	pdc.img.fill(Color(0, 0, 0, 0))
	for xx in range(0, 4):
		pdc.img.set_pixel(xx, 0, Color(1, 1, 1, 1))
	pdc._wand(Vector2i(0, 0))
	ck(pdc._sel.size() == 4, "魔棒选中同色连通 4 格")
	pdc.free()

	# ---------- 收尾 ----------
	DirAccess.remove_absolute(P)
	if _fail == 0:
		print("=== 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
