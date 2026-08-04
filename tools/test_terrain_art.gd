extends SceneTree
## 地块美术回归：HexTileRender 几何/选变体纯函数 + TextureCache 手绘图加载 + TerrainDB art 往返
## （经 _path_override 重定向到 user:// 临时 copy，绝不碰真 terrains.json）。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_terrain_art.gd（退出码 0=PASS）

const TerrainDB := preload("res://TerrainDB.gd")
const HexTileRender := preload("res://HexTileRender.gd")
const TextureCache := preload("res://TextureCache.gd")

const TT := "user://_test_terrains.json"
const TPNG := "user://_test_tile_0.png"
var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _initialize() -> void:
	print("=== 地块美术测试开始 ===")

	# ---------- A) 瓦片几何 helpers（纯函数；工坊 mask/轮廓与烘焙同一判定）----------
	var s := HexTileRender.tile_px_size()
	ck(s == Vector2i(32, 28), "tile_px_size = 32×28")
	ck(HexTileRender.tile_hex_contains(16, 14), "hex 内：中心")
	ck(not HexTileRender.tile_hex_contains(0, 0), "hex 外：左上角")
	ck(not HexTileRender.tile_hex_contains(31, 0), "hex 外：右上角")
	ck(not HexTileRender.tile_hex_contains(0, 27), "hex 外：左下角")

	# ---------- A2) 双规格 hex 几何（2026-07-20 战斗自绘 96×96；per-entry art_px）----------
	# 旧规格 32×28：hex_contains_px 与既有居中判定逐像素等价（已画瓦片零漂移铁律）
	var mismatch := 0
	for y in 28:
		for x in 32:
			if HexTileRender.tile_hex_contains(x, y) != HexTileRender.hex_contains_px(x, y, 32, 28):
				mismatch += 1
	ck(mismatch == 0, "旧规格 32×28：新旧判定逐像素等价（不等像素 %d）" % mismatch)
	# 96×96：底对齐+顶部留白（PHBT 摆位实测：hex y≈12..95、几何中心行 54）
	ck(HexTileRender.hex_anchor_row(96, 96) == 54, "96×96 锚行＝54")
	ck(not HexTileRender.hex_contains_px(48, 0, 96, 96) and not HexTileRender.hex_contains_px(48, 11, 96, 96),
		"96×96：顶部 12px 留白在六边形外")
	ck(HexTileRender.hex_contains_px(0, 54, 96, 96) and HexTileRender.hex_contains_px(95, 54, 96, 96),
		"96×96：锚行满宽（左右顶点行）")
	ck(HexTileRender.hex_contains_px(48, 94, 96, 96), "96×96：底缘在六边形内")
	ck(not HexTileRender.hex_contains_px(0, 90, 96, 96), "96×96：左下角在六边形外")
	# art_px_of：缺省旧规格 / bt 词表 96×96 / randr 放置物 32×48
	ck(TerrainDB.art_px_of({"label": "x"}) == Vector2i(32, 28), "art_px 缺省＝32×28")
	ck(TerrainDB.art_px_of({"art_px": [96, 96]}) == Vector2i(96, 96), "art_px 显式读取")
	var bt = TerrainDB.entry_for({"terrain": "bt", "variant": "grass"})
	ck(bt != null and TerrainDB.art_px_of(bt) == Vector2i(96, 96) and int(TerrainDB.art_anchor_of(bt)) == 54 \
		and str(bt.get("scope", "")) == "battle", "战斗词表 bt_grass：96×96/锚行54/scope battle")
	var rr = TerrainDB.entry_for({"terrain": "randr", "variant": "road_0"})
	ck(rr != null and TerrainDB.art_px_of(rr) == Vector2i(32, 48), "randr 放置物画布规格 32×48（工坊可编）")

	# ---------- B) pick_art（确定性选变体 / 空→"" / 负 seed 取绝对值）----------
	ck(HexTileRender.pick_art([], 5) == "", "pick_art 空→空串")
	var arr := ["a.png", "b.png", "c.png"]
	ck(HexTileRender.pick_art(arr, 0) == "a.png", "pick_art seed0→[0]")
	ck(HexTileRender.pick_art(arr, 1) == "b.png", "pick_art seed1→[1]")
	ck(HexTileRender.pick_art(arr, 3) == "a.png", "pick_art 环绕 %N")
	ck(HexTileRender.pick_art(arr, -1) == "b.png", "pick_art 负 seed 取 absi")

	# ---------- C) TextureCache 手绘图加载/缺失（缺失→null＝回落程序烘）----------
	var im := Image.create(24, 21, false, Image.FORMAT_RGBA8)
	im.fill(Color(1, 0, 1, 1))
	im.save_png(TPNG)
	ck(TextureCache.get_tex(TPNG) != null, "get_tex 手绘 PNG 命中")
	ck(TextureCache.get_tex("user://_nope_terrain_art_xyz.png") == null, "get_tex 缺失→null")

	# ---------- D) TerrainDB art 往返（_path_override 温 copy，绝不写真 terrains.json）----------
	var real = FileAccess.open("res://terrains.json", FileAccess.READ)
	ck(real != null, "读到真 terrains.json")
	if real != null:
		var txt := real.get_as_text()
		real.close()
		var w = FileAccess.open(TT, FileAccess.WRITE)
		w.store_string(txt)
		w.close()
		TerrainDB._path_override = TT
		TerrainDB.reload_data()
		var tile := {"terrain": "road", "variant": "road"}   # 用没导入 Unciv 底图的地形，保证初始 art 空
		ck(TerrainDB.art_of(TerrainDB.entry_for(tile)).is_empty(), "初始 art 空")
		ck(TerrainDB.set_art(tile, [TPNG]), "set_art 成功")
		ck(not TerrainDB.set_art({"terrain": "no", "variant": "such"}, []), "set_art 不存在→false")
		ck(TerrainDB.save(), "save 落盘")
		TerrainDB.reload_data()
		ck(TerrainDB.art_of(TerrainDB.entry_for(tile)) == [TPNG], "art 往返持久")
		var chk = FileAccess.open(TT, FileAccess.READ)
		var doc = JSON.parse_string(chk.get_as_text())
		chk.close()
		ck(typeof(doc) == TYPE_DICTIONARY and doc.has("format_version") and doc.has("_note"), "save 保留顶层字段")
		# 恢复：读真表、清临时文件
		TerrainDB._path_override = ""
		TerrainDB.reload_data()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TT))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TPNG))

	if _fail == 0:
		print("=== 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
