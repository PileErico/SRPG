extends Control
## 地块对照预览：画所选变体的中心格 + 周围 6 邻格（实时拼贴），供地块绘制工坊 WYSIWYG 对照。
## 仿 PiecePreview（去掉单位/阵营那半）；用与地图完全同一 HexTileRender.draw_tile。

const HexTileRender := preload("res://HexTileRender.gd")

const R := 24.0   # 与地图原始格半径一致

var _color := Color(0.36, 0.62, 0.32)
var _accent := Color(0.5, 0.7, 0.4)
var _decor := "grass"
var _art: Array = []
var _idx := 0
var _anchor := -1.0   # 赤道锚行覆盖（绘制中 live 预览钉 hex 赤道，免半成品最宽行乱窜）；-1＝按贴图自算

func _ready() -> void:
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	custom_minimum_size = Vector2(260, 260)
	clip_contents = true

func set_tile(color: Color, accent: Color, decor: String, art: Array, idx: int, anchor := -1.0) -> void:
	_color = color; _accent = accent; _decor = decor; _art = art; _idx = idx; _anchor = anchor
	queue_redraw()

func _draw() -> void:
	# 等比显示缩放：撑满控件、保地图比例（不破坏像素密度 WYSIWYG）
	var dz: float = maxf(1.0, floorf(min(size.x / (4.6 * R), size.y / (4.6 * R))))   # 整数显示缩放：像素不糊
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(dz, dz))
	var vw := size.x / dz
	var vh := size.y / dz
	var c := Vector2(vw * 0.5, vh * 0.5)
	var h := 0.866 * R
	var offs := [Vector2(0, 0), Vector2(0, -2 * h), Vector2(0, 2 * h),
		Vector2(1.5 * R, -h), Vector2(1.5 * R, h), Vector2(-1.5 * R, -h), Vector2(-1.5 * R, h)]
	for i in offs.size():
		# 中心＝所选变体（seed=_idx 使 pick_art 命中该张）；邻格散不同 seed，看拼贴混合效果
		var seed := _idx if i == 0 else (i * 911 + 7)
		HexTileRender.draw_tile(self, c + offs[i], R, _color, _accent, _decor, seed, true, _art, _anchor)
