extends Control
## 「棋子效果」预览：画几块草地六边形 + 中心立一个拼装角色棋子（脚下阵营环+阴影+精灵）。
## 供外观工坊实时预览 + 手动调 缩放/偏移；用的是与战场同一套 UnitPiece 渲染（WYSIWYG）。

const HexTileRender := preload("res://HexTileRender.gd")
const UnitPiece := preload("res://UnitPiece.gd")

const R := 24.0   # 用地图原始格半径感

var tex: Texture2D
var fac := Color(0.36, 0.62, 0.32)
var pscale := 0.0     # 0＝自动
var dx := 0.0
var dy := 0.0

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	custom_minimum_size = Vector2(260, 280)
	clip_contents = true

func set_piece(t: Texture2D, s: float, ddx: float, ddy: float, f: Color) -> void:
	tex = t; pscale = s; dx = ddx; dy = ddy; fac = f
	queue_redraw()

func _draw() -> void:
	# 等比显示缩放：撑满控件、同时保持与战场同比例（不破坏 slider WYSIWYG）
	var dz: float = clampf(min(size.x / (4.4 * R), size.y / (7.2 * R)), 1.0, 6.0)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(dz, dz))
	var vw := size.x / dz
	var vh := size.y / dz
	var c := Vector2(vw * 0.5, vh * 0.62)   # 下偏，给站立精灵上方留空
	var grass := Color(0.42, 0.56, 0.30)
	var accent := Color(0.30, 0.42, 0.22)
	var h := 0.866 * R
	var offs := [Vector2(0, 0), Vector2(0, -2 * h), Vector2(0, 2 * h),
		Vector2(1.5 * R, -h), Vector2(1.5 * R, h), Vector2(-1.5 * R, -h), Vector2(-1.5 * R, h)]
	for off in offs:
		HexTileRender.draw_tile(self, c + off, R, grass, accent, "grass", 0)
	UnitPiece.draw_piece(self, c, R * 0.62, tex, fac, {"scale": pscale, "dx": dx, "dy": dy})
