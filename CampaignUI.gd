extends RefCounted
## 战役/大地图侧公共 UI 工厂（仿 EditorUI；全 static，无 class_name——headless 扫描不建全局类）。
## 收拢顶栏面板的 PopupPanel+VBox 脚手架、语义色、行样式，令各 _open_*_panel 只填内容不搓 chrome。
## 用法：const CampaignUI := preload("res://CampaignUI.gd")

# —— 语义色（散落的内联 Color 收敛到此，单点可调/主题化）——
const MUTED := Color(0.65, 0.68, 0.75)   # 次要/说明文字
const HOSTILE := Color(0.9, 0.45, 0.4)   # 敌对
const READY := Color(0.55, 0.8, 0.55)    # 可用/在岗（绿）
const WARN := Color(0.78, 0.68, 0.5)     # 冷却/未就绪徽章（暖灰）
const DANGER := Color(0.72, 0.5, 0.5)    # 已禁用/失效

# 建空弹窗：PopupPanel + 内 VBox（定最小宽 + 行距）。返回 {popup, box}；调用方填 box 后 popup.popup_centered()。
static func popup(min_w: int, sep := 6) -> Dictionary:
	var pop := PopupPanel.new()
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(min_w, 0)
	box.add_theme_constant_override("separation", sep)
	pop.add_child(box)
	return {"popup": pop, "box": box}

# 文本标签（可选染色；缺省白＝不覆盖）
static func label(text: String, color := Color(1, 1, 1, 1)) -> Label:
	var l := Label.new()
	l.text = text
	if color != Color(1, 1, 1, 1):
		l.add_theme_color_override("font_color", color)
	return l

static func muted(text: String) -> Label:
	return label(text, MUTED)

# 「定宽名字 + 撑满次要文字」一行；返回 row 供调用方继续追加徽章/按钮。
static func kv_row(name: String, name_w: int, secondary := "", secondary_color := MUTED) -> HBoxContainer:
	var row := HBoxContainer.new()
	var n := Label.new()
	n.text = name
	n.custom_minimum_size = Vector2(name_w, 0)
	row.add_child(n)
	if secondary != "":
		var s := Label.new()
		s.text = secondary
		s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		s.add_theme_color_override("font_color", secondary_color)
		row.add_child(s)
	return row

# 不吃空格焦点的按钮（顶栏空格＝时间开关，弹窗内按钮不该抢焦点）
static func button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	return b
