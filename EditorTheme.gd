extends RefCounted
## 编辑器统一深色主题 + StyleBox 工厂——地图/物品等编辑器共用一份观感（DRY 单一出处）。
## 用法：编辑器根 Control 里 `theme = EditorTheme.build()`；子控件全继承。
##   per-instance override 仍优先（如笔刷缩略图的选中亮描边）。
## （不用 class_name：与 *DB 同理，headless 扫描找不到全局类；静态函数经 preload const 调用。）

# 深色底 StyleBoxFlat 工厂：bg 填充 + 可选 1px 描边（border.a>0 才画）+ 圆角3 + 内边距4。
static func sb(bg: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	if border.a > 0.0:
		s.border_color = border
		s.set_border_width_all(1)
	s.set_corner_radius_all(3)
	s.set_content_margin_all(4)
	return s

# 统一深色 Theme（Button/OptionButton/MenuButton/Label/CheckBox/LineEdit/ItemList）。一处改全局。
static func build() -> Theme:
	var th := Theme.new()
	var text := Color(0.86, 0.89, 0.94)
	var b_norm := sb(Color(0.20, 0.22, 0.27), Color(0.30, 0.33, 0.40))
	var b_hover := sb(Color(0.25, 0.28, 0.34), Color(0.40, 0.44, 0.52))
	var b_press := sb(Color(0.24, 0.36, 0.52), Color(0.46, 0.62, 0.85))
	var b_flat := sb(Color(0, 0, 0, 0), Color(0, 0, 0, 0))
	for t in ["Button", "OptionButton", "MenuButton"]:
		th.set_stylebox("normal", t, b_norm)
		th.set_stylebox("hover", t, b_hover)
		th.set_stylebox("pressed", t, b_press)
		th.set_stylebox("focus", t, b_flat)
		th.set_stylebox("disabled", t, b_norm)
		th.set_color("font_color", t, text)
		th.set_color("font_hover_color", t, Color.WHITE)
		th.set_color("font_pressed_color", t, Color.WHITE)
		th.set_color("font_focus_color", t, text)
		th.set_color("font_disabled_color", t, Color(0.5, 0.52, 0.57))
	th.set_color("font_color", "Label", text)
	th.set_color("font_color", "CheckBox", text)
	th.set_color("font_pressed_color", "CheckBox", Color.WHITE)
	th.set_color("font_hover_color", "CheckBox", Color.WHITE)
	th.set_stylebox("normal", "LineEdit", sb(Color(0.15, 0.16, 0.20), Color(0.30, 0.33, 0.40)))
	th.set_stylebox("focus", "LineEdit", sb(Color(0.17, 0.19, 0.24), Color(0.42, 0.56, 0.80)))
	th.set_color("font_color", "LineEdit", text)
	th.set_color("font_placeholder_color", "LineEdit", Color(0.55, 0.58, 0.64))
	th.set_stylebox("panel", "ItemList", sb(Color(0.14, 0.15, 0.19), Color(0.26, 0.29, 0.35)))
	th.set_color("font_color", "ItemList", text)
	th.set_color("font_selected_color", "ItemList", Color.WHITE)
	return th

# 编辑器背景色（铺满垫底的 ColorRect 用；去掉引擎默认灰）。
static func bg_color() -> Color:
	return Color(0.09, 0.10, 0.12)
