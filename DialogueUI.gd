extends Control
## 通用对话模块（M8，需求 §1.8）：两侧立绘 + 中间文本 + 玩家选项。数据外置 data/dialogues.json（DialogueDB）。
## 两类对话共用一套：纯演出＝无 choices 节点、点击任意处推进；分支＝choices 按钮，选项效果
## set_flags（写 WorldState.flags）/ rep（按 {faction:delta} 累加声望）——ws=null（纯沙盒）时效果跳过。
## 宿主接入（唯一接口）：EventEngine 动作 dialogue → 宿主原语 event_dialogue(id) → new + add_child + start()；
## 结束发 finished 信号并自毁——大地图（行进暂停等它）与战场内触发（火纹式）同一份控件。
## 可测性：播放核心 start/advance/choose 纯逻辑、UI 刷新全走 null 守卫——headless new()（不进树、_ready 不跑）即可测。

signal finished

const DialogueDB := preload("res://DialogueDB.gd")
const TextureCache := preload("res://TextureCache.gd")
const FactionDB := preload("res://FactionDB.gd")   # 声望唯一写口（钳制/默认值在它那）

var _dlg = null    # 当前对话定义（null=未播放/已结束）
var _node = null   # 当前节点
var _ws = null     # 选项效果落点（WorldState；null=无战役档，效果跳过）
var _left_portrait := ""    # 两侧立绘记忆：说话方点亮，另一侧保持上次立绘变暗（VN 惯例）
var _right_portrait := ""

# UI 节点（进树 _ready 才建；headless 纯逻辑不建）
var _speaker: Label
var _text: RichTextLabel
var _choices: VBoxContainer
var _hint: Label
var _left_rect: TextureRect
var _right_rect: TextureRect

# ============ 播放核心（纯逻辑，headless 可测）============

# 开始播放：查对话 → 进首节点。返回是否成功开播（不存在/空对话＝直接 finished 自毁）。
func start(dialogue_id: String, ws = null) -> bool:
	var dlg = DialogueDB.dialogue(dialogue_id)
	if dlg == null:
		push_warning("DialogueUI：对话「%s」不存在（data/dialogues.json）" % dialogue_id)
		_finish()
		return false
	_dlg = dlg
	_ws = ws
	_enter_node(DialogueDB.first_node(dlg))
	return _node != null

func is_active() -> bool:
	return _node != null

func current_node():
	return _node

# 纯演出节点：推进到 next（有 choices 的节点必须走 choose，点击不推进）
func advance() -> void:
	if _node == null or not (_node.get("choices", []) as Array).is_empty():
		return
	_goto(str(_node.get("next", "")))

# 分支节点：选第 i 项——先落效果、再跳转
func choose(i: int) -> void:
	if _node == null:
		return
	var cs: Array = _node.get("choices", [])
	if i < 0 or i >= cs.size() or typeof(cs[i]) != TYPE_DICTIONARY:
		return
	_apply_choice_effects(cs[i])
	_goto(str(cs[i].get("next", "")))

func _goto(next_id: String) -> void:
	if next_id == "":
		_finish()
		return
	var nd = DialogueDB.node(_dlg, next_id)
	if nd == null:
		push_warning("DialogueUI：对话「%s」引用了不存在的节点「%s」——提前结束" % [str(_dlg.get("id", "?")), next_id])
		_finish()
		return
	_enter_node(nd)

func _enter_node(nd) -> void:
	if nd == null:
		_finish()
		return
	_node = nd
	var p := str(nd.get("portrait", ""))
	if p != "":
		if str(nd.get("side", "left")) == "right":
			_right_portrait = p
		else:
			_left_portrait = p
	_refresh_ui()

# 选项效果：set_flags 写世界 flag / rep 累加声望——需求「分支影响限于个人剧情、支线走向」，flag+声望先兜住
func _apply_choice_effects(c: Dictionary) -> void:
	if _ws == null:
		if c.has("set_flags") or c.has("rep"):
			push_warning("DialogueUI：无战役档（沙盒模式），选项效果 set_flags/rep 跳过")
		return
	var sf = c.get("set_flags", {})
	if typeof(sf) == TYPE_DICTIONARY:
		for k in sf:
			_ws.set_flag(str(k), sf[k])   # 唯一写口（带 flag_changed 广播）
	var rp = c.get("rep", {})
	if typeof(rp) == TYPE_DICTIONARY:
		for f in rp:
			FactionDB.add_rep(_ws, str(f), int(rp[f]))   # 唯一写口：默认值兜底+[-100,100] 钳制

func _finish() -> void:
	_node = null
	_dlg = null
	finished.emit()
	if is_inside_tree():
		queue_free()   # headless（不在树）由测试方 free

# ============ UI（进树才建；两侧立绘 + 中间文本 + 选项，全屏模态吞输入）============

func _ready() -> void:
	# ⚠️ 必须用 and_offsets 版：_ready 时已进树，set_anchors_preset 只改锚点、offsets 会保住当前 0×0 矩形
	# ——曾致对话框零尺寸不可见+点不到，行进 await 它 finished 造成大地图假死（2026-07-02 实机复现修复）。
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP   # 模态：对话期间点击不落到底下的地图/战斗
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.35)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.custom_minimum_size = Vector2(0, 232)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 点击穿给自身（推进）；按钮自己会截
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.07, 0.07, 0.10, 0.93)
	box.set_content_margin_all(14)
	box.border_color = Color(0.55, 0.47, 0.25, 0.8)
	box.border_width_top = 2
	panel.add_theme_stylebox_override("panel", box)
	add_child(panel)

	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 16)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(h)

	_left_rect = _make_portrait_rect(false)
	h.add_child(_left_rect)

	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.add_theme_constant_override("separation", 6)
	mid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(mid)
	_speaker = Label.new()
	_speaker.add_theme_font_size_override("font_size", 18)
	_speaker.add_theme_color_override("font_color", Color(0.93, 0.80, 0.38))
	mid.add_child(_speaker)
	_text = RichTextLabel.new()
	_text.bbcode_enabled = true
	_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text.add_theme_font_size_override("normal_font_size", 16)
	mid.add_child(_text)
	_choices = VBoxContainer.new()
	_choices.add_theme_constant_override("separation", 4)
	mid.add_child(_choices)
	_hint = Label.new()
	_hint.text = "▼ 点击继续"
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hint.add_theme_color_override("font_color", Color(0.6, 0.62, 0.7))
	_hint.add_theme_font_size_override("font_size", 12)
	mid.add_child(_hint)

	_right_rect = _make_portrait_rect(true)
	h.add_child(_right_rect)
	_refresh_ui()   # start 先于进树被调过的场合（先 start 后 add_child）补一次刷新

func _make_portrait_rect(flip: bool) -> TextureRect:
	var r := TextureRect.new()
	r.custom_minimum_size = Vector2(180, 200)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.flip_h = flip   # 右侧立绘镜像（面向中间）
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r

# 点击任意处推进（分支节点由选项按钮接管，此处不动）
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		advance()
		accept_event()

func _refresh_ui() -> void:
	if _text == null or _node == null:
		return
	_speaker.text = str(_node.get("speaker", ""))
	_text.text = str(_node.get("text", ""))
	var right_active := str(_node.get("side", "left")) == "right"
	_set_portrait(_left_rect, _left_portrait, not right_active)
	_set_portrait(_right_rect, _right_portrait, right_active)
	for c in _choices.get_children():
		c.queue_free()
	var cs: Array = _node.get("choices", [])
	_hint.visible = cs.is_empty()
	for i in cs.size():
		var b := Button.new()
		b.text = str(cs[i].get("text", "…"))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		var idx := i
		b.pressed.connect(func(): choose(idx))
		_choices.add_child(b)

func _set_portrait(rect: TextureRect, path: String, active: bool) -> void:
	rect.texture = TextureCache.get_tex(path)   # 空路径→null＝无立绘（名字/文本仍在）
	rect.modulate = Color(1, 1, 1) if active else Color(0.42, 0.42, 0.5)
