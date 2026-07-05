extends Control
## 地块缩略图控件：画一个与地图完全一致的六边形地块（底色 + accent 线稿 decor），供编辑器笔刷栏用。
## 渲染走 HexTileRender 单一实现 → 「笔刷格 == 地图格」逐笔一致（DRY）。
## 用法：TerrainSwatch.new()，set_tile(terrain, variant)；控件尺寸 ≈ 46×44 时半径 21 的地块居中铺满。

const HexTileRender := preload("res://HexTileRender.gd")
const TerrainDB := preload("res://TerrainDB.gd")

const RADIUS := 21.0   # 略小于地图半径 24：留 2~3px 边距，decor（原生偏移 ±11）仍在格内

var _tile := {"terrain": "plain", "variant": "grassland"}

func _init() -> void:
	custom_minimum_size = Vector2(46, 44)
	mouse_filter = Control.MOUSE_FILTER_IGNORE   # 点击穿透到父按钮（选笔刷）
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # 像素瓦片放大不糊（Control 不继承）

func set_tile(terrain: String, variant: String) -> void:
	_tile = {"terrain": String(terrain), "variant": String(variant)}
	queue_redraw()

func _draw() -> void:
	var e = TerrainDB.entry_for(_tile)
	if e == null:
		return
	# seed=0：笔刷缩略图不做坐标扰动（要规整、可代表该地形），与地图格的「同一份绘制」只差扰动种子
	var art: Array = e.get("art", [])   # 有手绘变体则笔刷也显手绘（art[0] 代表版）
	var anchor: float = TerrainDB.art_anchor_of(e)   # 放置物（道路/河流）固定锚行，笔刷缩略图与地图格一致
	HexTileRender.draw_tile(self, size * 0.5, RADIUS, Color.html(e.color), Color.html(e.accent), str(e.get("decor", "none")), 0, true, art, anchor)
