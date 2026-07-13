extends SceneTree
## 像素画布/绘制浮层回归（编辑器优化提案 §11/§16/§28/§29）：
## A) redo 栈语义（undo→redo 往返、新笔画清空 redo）
## B) 笔刷粗细落点（stamp_pts 纯函数 + 实际落笔 + 遮罩不越界 + 形状扩展）
## C) image_changed 信号（§28 实时预览的地基）
## D) TextureCache.put_file 虚拟路径注入（live 预览缝）
## E) PixelDrawOverlay 两宿主注入构建（地块样/外观样 opts；save/extra_tools/色块预设载入）
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_pixeldraw.gd（退出码 0=PASS）

const PixelDrawCanvas := preload("res://PixelDrawCanvas.gd")
const PixelDrawOverlay := preload("res://PixelDrawOverlay.gd")
const TextureCache := preload("res://TextureCache.gd")

const SWATCH_TMP := "user://_test_pixeldraw_swatches.json"
var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _find_button(node: Node, text: String) -> Button:
	if node is Button and str(node.text) == text:
		return node
	for c in node.get_children():
		var r := _find_button(c, text)
		if r != null:
			return r
	return null

func _find_picker(node: Node) -> ColorPicker:
	if node is ColorPicker:
		return node
	for c in node.get_children():
		var r := _find_picker(c)
		if r != null:
			return r
	return null

func _initialize() -> void:
	print("=== 像素画布/绘制浮层测试开始 ===")

	# ---------- A) redo 栈语义 ----------
	var c = PixelDrawCanvas.new()
	c.setup(8, null, null)
	c.brush = Color(1, 0, 0, 1)
	c._press(Vector2i(1, 1)); c._release(Vector2i(1, 1))
	ck(c.img.get_pixel(1, 1).a > 0.5, "落笔生效")
	c.undo()
	ck(c.img.get_pixel(1, 1).a == 0.0, "undo 撤掉")
	ck(not c._redo.is_empty(), "undo 后 redo 栈非空")
	c.redo()
	ck(c.img.get_pixel(1, 1).a > 0.5, "redo 恢复")
	c.undo()
	c._press(Vector2i(2, 2)); c._release(Vector2i(2, 2))   # 新笔画
	ck(c._redo.is_empty(), "新笔画清空 redo（标准语义）")
	var before: Image = c.img.duplicate()
	c.redo()   # 栈空＝无操作
	ck(c.img.get_pixel(1, 1).a == before.get_pixel(1, 1).a, "redo 栈空＝无操作")

	# ---------- B) 笔刷粗细落点 ----------
	var s1 := c.stamp_pts(Vector2i(4, 4))
	ck(c.brush_px == 1 and s1.size() == 1 and s1[0] == Vector2i(4, 4), "stamp 1px＝单点")
	c.brush_px = 2
	var s2 := c.stamp_pts(Vector2i(4, 4))
	ck(s2.size() == 4 and Vector2i(4, 4) in s2 and Vector2i(5, 5) in s2 and Vector2i(3, 3) not in s2, "stamp 2px＝锚点起 2×2")
	c.brush_px = 3
	var s3 := c.stamp_pts(Vector2i(4, 4))
	ck(s3.size() == 9 and Vector2i(3, 3) in s3 and Vector2i(5, 5) in s3 and Vector2i(2, 2) not in s3, "stamp 3px＝居中 3×3")
	# 实际落笔：3px 铅笔一点 → 3×3 着色、圈外不染
	c.clear_img()
	c._press(Vector2i(4, 4)); c._release(Vector2i(4, 4))
	ck(c.img.get_pixel(3, 3).a > 0.5 and c.img.get_pixel(5, 5).a > 0.5, "3px 落笔覆盖 3×3")
	ck(c.img.get_pixel(2, 2).a == 0.0 and c.img.get_pixel(6, 6).a == 0.0, "3px 落笔不越足迹")
	# 遮罩：粗笔刷也不越 paint_mask
	c.clear_img()
	c.paint_mask = {Vector2i(4, 4): true}
	c._press(Vector2i(4, 4)); c._release(Vector2i(4, 4))
	ck(c.img.get_pixel(4, 4).a > 0.5 and c.img.get_pixel(5, 5).a == 0.0 and c.img.get_pixel(3, 3).a == 0.0, "粗笔刷不越遮罩")
	c.paint_mask = {}
	# 形状扩展：2px 直线 (1,1)→(3,1) 落成 2 行厚
	c.clear_img()
	c.brush_px = 2
	c.set_tool("line")
	c._press(Vector2i(1, 1))
	c._preview = c._shape(Vector2i(1, 1), Vector2i(3, 1))
	c._release(Vector2i(3, 1))
	ck(c.img.get_pixel(1, 1).a > 0.5 and c.img.get_pixel(4, 2).a > 0.5, "2px 直线落成 2px 厚（含端点扩展）")
	ck(c.img.get_pixel(1, 3).a == 0.0, "直线扩展不外溢")
	c.brush_px = 1
	c.set_tool("pencil")

	# ---------- C) image_changed 信号 ----------
	var got := [0]
	var last: Array = [null]
	c.image_changed.connect(func(im): got[0] += 1; last[0] = im)
	c._press(Vector2i(0, 0)); c._release(Vector2i(0, 0))
	ck(got[0] > 0, "落笔发 image_changed")
	ck(last[0] is Image and (last[0] as Image).get_width() == 8, "信号携带当前 Image")
	var n0: int = got[0]
	c.undo()
	ck(got[0] > n0, "undo 也发 image_changed")
	c.free()

	# ---------- D) TextureCache.put_file 注入 ----------
	var im4 := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	im4.fill(Color(1, 0, 1, 1))
	var tex4 := ImageTexture.create_from_image(im4)
	TextureCache.put_file("live://_test", tex4)
	ck(TextureCache.get_tex_file("live://_test") == tex4, "put_file 注入命中 get_tex_file 同键")
	TextureCache.clear()
	ck(TextureCache.get_tex_file("live://_test") == null, "clear 后虚拟路径回落 null")

	# ---------- E) PixelDrawOverlay 两宿主注入构建 ----------
	# E1 地块样：非方形画布 + 遮罩 + alpha 取色 + 无 id 行
	var ov1 = PixelDrawOverlay.new()
	ov1.setup({
		"title": "t", "canvas_w": 32, "canvas_h": 28,
		"paint_mask": {Vector2i(16, 14): true},
		"brush": Color(1, 0, 0, 1), "edit_alpha": true,
		"ramp_label": "快捷色", "ramp_colors": [Color.RED, Color.BLACK],
		"save_text": "💾 保存变体",
	})
	ck(ov1.canvas != null and ov1.canvas.px_size == 32 and ov1.canvas.px_h == 28, "地块宿主：画布尺寸注入")
	ck(not ov1.canvas.paint_mask.is_empty(), "地块宿主：遮罩注入")
	ck(ov1.canvas.brush == Color(1, 0, 0, 1), "地块宿主：初始笔色注入")
	ck(ov1.id_edit == null and ov1.id_text() == "", "地块宿主：无 id 行")
	ck(_find_button(ov1, "💾 保存变体") != null, "地块宿主：保存钮文案注入")
	ck(_find_button(ov1, "↷ 重做") != null, "浮层工具栏有重做钮（§11）")
	var saved := [false]
	ov1.save_pressed.connect(func(): saved[0] = true)
	_find_button(ov1, "💾 保存变体").pressed.emit()
	ck(saved[0], "保存钮 → save_pressed 信号")
	ov1.free()
	# E2 外观样：方形画布 + id 行 + 附加工具 + 色块预设载入
	var f = FileAccess.open(SWATCH_TMP, FileAccess.WRITE)
	f.store_string(JSON.stringify(["#ff0000"]))
	f.close()
	var hit := [false]
	var ov2 = PixelDrawOverlay.new()
	ov2.setup({
		"canvas_w": 32, "canvas_h": 32,
		"id_label": "部件 id", "id_value": "abc",
		"extra_tools": [["载入所选部件", "tip", func(): hit[0] = true]],
		"save_text": "💾 保存为部件",
		"swatches_path": SWATCH_TMP,
	})
	ck(ov2.canvas.px_size == 32 and ov2.canvas.px_h == 32, "外观宿主：方形画布")
	ck(ov2.id_edit != null and ov2.id_text() == "abc", "外观宿主：id 行注入")
	var eb := _find_button(ov2, "载入所选部件")
	ck(eb != null, "外观宿主：附加工具注入")
	if eb != null:
		eb.pressed.emit()
	ck(hit[0], "附加工具回调触发")
	var cp := _find_picker(ov2)
	var has_red := false
	if cp != null:
		for pc in cp.get_presets():
			if pc.is_equal_approx(Color(1, 0, 0)):
				has_red = true
	ck(cp != null and has_red, "色块预设从 swatches_path 载入（漂移收敛：两宿主都有）")
	ov2.free()
	DirAccess.remove_absolute(SWATCH_TMP)

	if _fail == 0:
		print("=== 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
