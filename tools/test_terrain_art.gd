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
