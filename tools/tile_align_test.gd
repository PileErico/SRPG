extends Node2D
## 瓦片对齐标定/回归场景（临时工具，非生产代码）。
## 左面板＝旧「等比1.14×底对齐」本地复现；右面板＝**真实 HexTileRender.draw_tile**（赤道对齐+1.5×）实跑。
## 黄线＝几何 hex（数学格/黄框/点击都用它）。看：右面板美术是否贴着黄线、山峰上冒、水/林正常。
## 截图：
##   ..._console.exe --path "D:/1战棋" -s res://tools/screenshot.gd -- \
##     --scene=res://tools/tile_align_test.tscn --out=user://shots/tile_align.png --w=1200 --h=780 --frames=6
##   放大细看陆/水边界：加 --setup=focus_mode --w=1200 --h=900

const HexTileRender := preload("res://HexTileRender.gd")

const HEX := 24.0
var hex_h := sqrt(3.0) * HEX
var col_step := 1.5 * HEX
var row_step := sqrt(3.0) * HEX

var view_scale := 1.6
var panels := [0, 9]                    # 0=旧本地(1.14底对齐)  9=新真实代码
var map := [
	"gggggggg",
	"ggmggmgg",
	"gggffggg",
	"gggggggg",
	"cccccccc",
	"oooooooo",
	"oooooooo",
	"oooooooo",
]

const ART := {
	"g": "plain_grassland", "m": "mountain_mountain", "f": "forest_forest",
	"c": "water_shallow", "o": "water_deep",
}
const TITLES := {0: "旧 1.14x 底对齐(错位)", 9: "新 HexTileRender 赤道1.5x"}
var _tex := {}

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	queue_redraw()

func focus_mode() -> void:
	view_scale = 4.5
	map = ["ggg", "ggg", "ggg", "ccc", "ooo"]
	queue_redraw()

func _map_cols() -> int:
	var m := 0
	for line in map:
		m = maxi(m, (line as String).length())
	return m

func _panel_w() -> float:
	return _map_cols() * col_step + 44.0

func _tget(dir: String) -> Texture2D:
	if not _tex.has(dir):
		var img := Image.new()
		var err := img.load("res://icons/Tiles/%s/0.png" % dir)
		_tex[dir] = ImageTexture.create_from_image(img) if err == OK else null
	return _tex[dir]

func hex_center(col: int, row: int) -> Vector2:
	return Vector2(col_step * col + HEX, row_step * (row + 0.5 * (col % 2)) + hex_h * 0.5)

func hex_corners(c: Vector2) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 6:
		var a := deg_to_rad(60.0 * i)
		pts.append(c + Vector2(cos(a), sin(a)) * HEX)
	pts.append(pts[0])
	return pts

func _cells_sorted() -> Array:
	# Diamond-Down：按屏幕 y 升序（下排后画→盖住上排底缘）
	var cells := []
	for row in map.size():
		for col in (map[row] as String).length():
			cells.append(Vector2i(col, row))
	cells.sort_custom(func(a, b): return hex_center(a.x, a.y).y < hex_center(b.x, b.y).y)
	return cells

func _draw() -> void:
	draw_rect(Rect2(0, 0, 3000, 1400), Color(0.11, 0.11, 0.13), true)
	draw_set_transform(Vector2(6, 4), 0.0, Vector2(view_scale, view_scale))
	var font := ThemeDB.fallback_font
	var pw := _panel_w()
	for i in panels.size():
		var kind: int = panels[i]
		var ox := i * pw + 12.0
		draw_string(font, Vector2(ox, 12), TITLES[kind], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.9, 0.9, 0.95))
		_draw_panel(Vector2(ox, 22), kind)

func _draw_panel(origin: Vector2, kind: int) -> void:
	var cells := _cells_sorted()
	for cell in cells:
		var code := (map[cell.y] as String)[cell.x]
		var center := hex_center(cell.x, cell.y) + origin
		var seed: int = cell.x * 73856093 ^ cell.y * 19349663
		if kind == 9:
			# 真实生产路径：走 HexTileRender.draw_tile（art 路径 → 赤道对齐 1.5×）
			if code == "f":
				HexTileRender.draw_tile(self, center, HEX, Color.WHITE, Color.WHITE, "", seed, false, ["res://icons/Tiles/%s/0.png" % ART["g"]])
			HexTileRender.draw_tile(self, center, HEX, Color.WHITE, Color.WHITE, "", seed, false, ["res://icons/Tiles/%s/0.png" % ART[code]])
		else:
			# 旧本地复现：等比 1.14×、底对齐
			if code == "f":
				_blit_old(center, _tget(ART["g"]))
			_blit_old(center, _tget(ART[code]))
	for cell in cells:
		var center := hex_center(cell.x, cell.y) + origin
		draw_polyline(hex_corners(center), Color(1.0, 0.95, 0.2, 0.5), 0.8)

# 旧法：宽 = 2·size·1.14，底缘钉几何 hex 底
func _blit_old(center: Vector2, tex: Texture2D) -> void:
	if tex == null:
		return
	var w := 2.0 * HEX * 1.14
	var dh := float(tex.get_height()) * (w / float(tex.get_width()))
	var bottom := center.y + hex_h * 0.5
	draw_texture_rect(tex, Rect2(center.x - w * 0.5, bottom - dh, w, dh), false)
