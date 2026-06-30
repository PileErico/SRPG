extends Control
## 对角装饰边框（覆盖层）。
## 用一张 180° 点对称的角饰图（右上 + 左下），只取右上角那一块，
## 右上原样贴、左下翻转 180° 贴；角饰本身**永不拉伸**（整数倍 + NEAREST），
## 面板任意尺寸都能套。把本节点铺满目标面板（锚点全屏 + 内缩）即可。
##
## 用法：
##   var f := DiagonalFrame.new()
##   f.set_anchors_preset(Control.PRESET_FULL_RECT)   # 再按需设 offset 内缩到面板内
##   parent.add_child(f)                              # 加在面板之后 → 画在最上层

const BORDER_PATH := "res://icons/UI/UI边框_32x32.png"
# 右上角饰在 32×32 原图里的像素范围：cols 7..31 × rows 0..16，
# 恰好框住整个右上角饰、且不含左下角饰（左下最高只到 row15、且只在 col0）。
const CORNER_REGION := Rect2i(7, 0, 25, 17)

@export var corner_scale: int = 5   # 角饰整数放大倍数（保持像素清晰）

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE   # 纯装饰，点击穿透
	_build()

func _build() -> void:
	for c in get_children():
		c.queue_free()
	var src: Image = _load_image(BORDER_PATH)
	if src == null:
		push_warning("DiagonalFrame：边框图加载失败 %s" % BORDER_PATH)
		return
	var corner: Image = src.get_region(CORNER_REGION)  # 右上角饰
	var tr_tex := ImageTexture.create_from_image(corner)
	var bl_img: Image = corner.duplicate()             # 左下 = 右上翻 180°
	bl_img.flip_x()
	bl_img.flip_y()
	var bl_tex := ImageTexture.create_from_image(bl_img)

	var w := CORNER_REGION.size.x * corner_scale
	var h := CORNER_REGION.size.y * corner_scale

	# 右上角：锚定父节点右上角，向左下展开 w×h
	var tr := _mk_corner(tr_tex)
	tr.anchor_left = 1.0; tr.anchor_right = 1.0
	tr.anchor_top = 0.0;  tr.anchor_bottom = 0.0
	tr.offset_left = -w;  tr.offset_right = 0
	tr.offset_top = 0;    tr.offset_bottom = h
	add_child(tr)

	# 左下角：锚定父节点左下角，向右上展开 w×h
	var bl := _mk_corner(bl_tex)
	bl.anchor_left = 0.0; bl.anchor_right = 0.0
	bl.anchor_top = 1.0;  bl.anchor_bottom = 1.0
	bl.offset_left = 0;   bl.offset_right = w
	bl.offset_top = -h;   bl.offset_bottom = 0
	add_child(bl)

func _mk_corner(tex: Texture2D) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex
	r.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # 像素图放大不糊
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_SCALE             # 缩到 rect（整数倍 → 清晰）
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r

# 加载为 Image：优先已导入资源（取其 image），否则直读原图（免依赖编辑器导入流程）
func _load_image(path: String) -> Image:
	if ResourceLoader.exists(path):
		var t = load(path)
		if t is Texture2D:
			return t.get_image()
	var img := Image.new()
	if img.load(path) == OK:
		return img
	return null
