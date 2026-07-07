extends PanelContainer
## 战斗常驻底边栏：**UI 自决布局**（左＝地块信息 · 右＝按键提示），横跨底边、点击穿透。
## 信息源可分散（地块＝HexCanvas.hover_text、提示＝宿主），但**只此一处 UI**、统一排版——
## 宿主经 set_terrain / set_hint 把两处数据喂进来即可，栏本身不关心数据从哪来。
## 以后要放更多段（如选中单位快捷动作提示），在此加区即可，数据源照旧各自注入。

var _terrain: Label
var _hint: Label

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	grow_vertical = Control.GROW_DIRECTION_BEGIN   # 内容高度向上撑（否则底边宽锚点高度塌成 0）
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0, 0, 0, 0.55)
	box.content_margin_left = 12
	box.content_margin_right = 12
	box.content_margin_top = 5
	box.content_margin_bottom = 5
	add_theme_stylebox_override("panel", box)

	var hb := HBoxContainer.new()
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_theme_constant_override("separation", 24)
	add_child(hb)

	_terrain = Label.new()                 # 左：地块信息（撑开）
	_terrain.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_terrain.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_terrain.add_theme_color_override("font_color", Color(0.92, 0.94, 0.98))
	hb.add_child(_terrain)

	_hint = Label.new()                    # 右：按键提示
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	_hint.add_theme_font_size_override("font_size", 12)
	hb.add_child(_hint)

# 地块信息（多行 hover_text → 折成单行）
func set_terrain(text: String) -> void:
	if _terrain != null:
		_terrain.text = text.replace("\n", "　·　")

func set_hint(text: String) -> void:
	if _hint != null:
		_hint.text = text
