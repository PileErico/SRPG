extends SceneTree
## 一次性工具：把 Unciv FantasyHex 整套瓦片全导入为地形笔刷（塞进「待定」＝不写 category）。
## 用户挨个测试后再归类/删除。跳过已单独导入的 10 张。幂等：已存在的 fh/<key> 跳过。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/_import_unciv_all.gd
const TerrainDB := preload("res://TerrainDB.gd")
const SRC := "d:/tmp/Unciv-Tilesets/FantasyHex/Tiles/"
const DEST_DIR := "res://icons/Tiles/fh/"
# 已在 _import_unciv.gd 导入的源文件 → 跳过，免重复
const SKIP := ["Grassland.png", "Plains.png", "Coast.png", "Ocean.png", "Desert.png",
	"Snow.png", "Tundra.png", "Marsh.png", "GrasslandForest.png", "Mountain.png"]

func _initialize() -> void:
	TerrainDB.reload_data()
	var pal: Array = TerrainDB.palette()
	var existing := {}
	for e in pal:
		existing["%s/%s" % [str(e.get("terrain", "")), str(e.get("variant", ""))]] = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DEST_DIR))
	var files := _list_pngs(SRC)
	files.sort()
	var used := {}
	var added := 0
	var skipped := 0
	for fname in files:
		if SKIP.has(fname):
			skipped += 1
			continue
		var base: String = fname.get_basename()
		var key := _slug(base)
		var k := key
		var n := 2
		while used.has(k) or existing.has("fh/%s" % k):
			k = "%s_%d" % [key, n]
			n += 1
		used[k] = true
		var img := Image.new()
		if img.load(SRC + fname) != OK:
			print("SKIP load-fail: ", fname)
			continue
		img.save_png(DEST_DIR + k + ".png")
		var col := _avg_color(img)
		pal.append({
			"terrain": "fh", "variant": k, "id": "fh_" + k,
			"label": base,
			"color": "#" + col.to_html(false),
			"accent": "#" + col.darkened(0.25).to_html(false),
			"decor": "none", "tags": [],
			"move": {"cost": 1.0, "passable_by": "all"},
			"effects": [], "scope": "both",
			"art": [DEST_DIR + k + ".png"],
		})
		added += 1
	TerrainDB.save()
	print("DONE  added=%d  skipped=%d  palette_now=%d" % [added, skipped, pal.size()])
	quit()

func _list_pngs(path: String) -> Array:
	var out := []
	var d := DirAccess.open(path)
	if d == null:
		push_error("open-fail: " + path)
		return out
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if not d.current_is_dir() and f.to_lower().ends_with(".png"):
			out.append(f)
		f = d.get_next()
	d.list_dir_end()
	return out

func _slug(s: String) -> String:
	var low := s.to_lower()
	var out := ""
	for i in low.length():
		var code := low.unicode_at(i)
		if (code >= 97 and code <= 122) or (code >= 48 and code <= 57):
			out += low[i]
		else:
			out += "_"
	while out.contains("__"):
		out = out.replace("__", "_")
	out = out.lstrip("_").rstrip("_")
	return out if out != "" else "tile"

func _avg_color(img: Image) -> Color:
	var w := img.get_width()
	var h := img.get_height()
	var r := 0.0
	var g := 0.0
	var b := 0.0
	var cnt := 0
	var sx := maxi(1, w / 48)   # 大图抽样提速
	var sy := maxi(1, h / 48)
	var y := 0
	while y < h:
		var x := 0
		while x < w:
			var c := img.get_pixel(x, y)
			if c.a > 0.5:
				r += c.r
				g += c.g
				b += c.b
				cnt += 1
			x += sx
		y += sy
	if cnt == 0:
		return Color(0.5, 0.5, 0.5)
	return Color(r / cnt, g / cnt, b / cnt)
