extends RefCounted
## 编辑器公共 UI 控件工厂——地图/物品等编辑器共用一套 chrome（DRY 单一出处）。
## 全 static；发信号的控件（add_line/check/spin）把刷新逻辑经 on_change 回调传入，
## 不耦合具体编辑器的 _refresh；确认框经 host 挂子节点。
## 用法：const EditorUI := preload("res://EditorUI.gd")，再 EditorUI.section_title(...) 等。
## （不用 class_name：与 *DB / EditorTheme 同理，headless 扫描找不到全局类。）

const EditorTheme := preload("res://EditorTheme.gd")
const TagDB := preload("res://TagDB.gd")       # 自由 tag 区 chip 中文标签（tag 单一词表）
const StatMeta := preload("res://StatMeta.gd") # 修正行 stat 中文标签
const ItemTooltip := preload("res://ItemTooltip.gd")   # 物品选择器悬停富预览（通用渲染组件复用）
const ReactionRegistry := preload("res://ReactionRegistry.gd")

# —— 基础构件 ——

# 纯文本标签（编辑器里散用；比 Label.new()+set text 省一行）。
static func label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l

# 分节标题：一条淡蓝底色条 + 亮字，给侧栏各段清晰的视觉分隔。
static func section_title(text: String) -> Control:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.22, 0.36, 0.55, 0.5)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 7
	sb.content_margin_right = 6
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	p.add_theme_stylebox_override("panel", sb)
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0))
	p.add_child(l)
	return p

# 「标签 + 控件」一行：左侧定宽标签，右侧控件撑满。
static func field_row(text: String, control: Control, label_w := 200) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(label_w, 0)
	row.add_child(l)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row

# 把侧栏 VBox 包进带深色底 + 内边距的面板（与画布视觉分开）。
static func panelize(inner: Control) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.13, 0.16)
	sb.set_content_margin_all(7)
	p.add_theme_stylebox_override("panel", sb)
	p.add_child(inner)
	return p

# 铺满垫底的深色背景 ColorRect（去掉引擎默认灰；加到编辑器根最底层）。
static func background() -> ColorRect:
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = EditorTheme.bg_color()
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return bg

# —— 折叠区 ——

# 点标题栏收起/展开 content。进阶/占空间的段默认收起，给主内容让位。
# expand_up=true：底部停靠段——content 在 header 之上（向上展开），header 钉死在底部原地不随开合上下跳。
static func make_foldable(title: String, content: Control, collapsed: bool, expand_up: bool = false, on_toggle := Callable()) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	var hdr := Button.new()
	hdr.toggle_mode = true
	hdr.button_pressed = not collapsed
	hdr.alignment = HORIZONTAL_ALIGNMENT_LEFT
	hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr.focus_mode = Control.FOCUS_NONE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.18, 0.22, 0.28)
	sb.set_corner_radius_all(3)
	sb.set_content_margin_all(4)
	hdr.add_theme_stylebox_override("normal", sb)
	hdr.add_theme_stylebox_override("hover", sb)
	hdr.add_theme_stylebox_override("pressed", sb)
	hdr.add_theme_color_override("font_color", Color(0.86, 0.9, 0.96))
	# 箭头：普通段 ▸收起/▾展开；向上展开段 ▴收起(点了向上开)/▾展开(点了向下收)
	var _upd := func(open: bool):
		var a := ("▾ " if open else "▴ ") if expand_up else ("▾ " if open else "▸ ")
		hdr.text = a + title
	_upd.call(not collapsed)
	content.visible = not collapsed
	hdr.toggled.connect(func(pressed: bool):
		content.visible = pressed
		_upd.call(pressed)
		if on_toggle.is_valid():
			on_toggle.call(pressed))
	if expand_up:
		box.add_child(content)   # content 在上、header 在下 → 展开时内容向上长，header 留在底部
		box.add_child(hdr)
	else:
		box.add_child(hdr)
		box.add_child(content)
	return box

# —— 顶栏下拉菜单（绘图软件式：文件/编辑/视图）——
# 弹出项由调用方 get_popup().add_item(...) 填、再接 id_pressed。
static func make_menu(title: String) -> MenuButton:
	var mb := MenuButton.new()
	mb.text = title
	mb.focus_mode = Control.FOCUS_NONE
	mb.get_popup().add_theme_constant_override("v_separation", 3)
	return mb

# —— 工坊切换器（角色 ⇄ 地块）——
# scene_switch 的预置参数版（技改 §3-10：原独立实现已删，迁移到参数化通用件）。
static func workshop_switch(host: Node, current: String) -> Control:
	return scene_switch(host, current, [
		["appearance", "🎭 角色", "res://AppearanceWorkshop.tscn"],
		["terrain", "🧱 地块", "res://TerrainArtWorkshop.tscn"],
	])

# —— 表单动态字段（信号经 on_change 回调，不耦合具体编辑器刷新）——

static func add_line(parent: Node, text: String, value: String, on_change := Callable()) -> LineEdit:
	var le := LineEdit.new()
	le.text = value
	if on_change.is_valid():
		le.text_changed.connect(func(_t): on_change.call())
	parent.add_child(field_row(text, le))
	return le

static func add_check(parent: Node, text: String, value: bool, on_change := Callable()) -> CheckBox:
	var cb := CheckBox.new()
	cb.button_pressed = value
	if on_change.is_valid():
		cb.toggled.connect(func(_v): on_change.call())
	parent.add_child(field_row(text, cb))
	return cb

static func add_spin(parent: Node, text: String, value: float, mn: float, mx: float, step: float, on_change := Callable()) -> SpinBox:
	var sb := SpinBox.new()
	sb.min_value = mn
	sb.max_value = mx
	sb.step = step
	sb.value = value
	if on_change.is_valid():
		sb.value_changed.connect(func(_v): on_change.call())
	parent.add_child(field_row(text, sb))
	return sb

# OptionButton 按 metadata 选中；找不到＝回退第一个有效项（跳过分隔/占位 null）。
# 单一实现（技改 §13 地基件）：ListEditorShell._select_meta 委托这里，别处勿再手抄。
static func select_meta(ob: OptionButton, key) -> void:
	for i in ob.item_count:
		var m = ob.get_item_metadata(i)
		if m != null and str(m) == str(key):
			ob.select(i)
			return
	for i in ob.item_count:
		if not ob.is_item_disabled(i) and ob.get_item_metadata(i) != null:
			ob.select(i)
			return

# 裸下拉（不带 field_row）：pairs=[[meta, 显示文本], ...]（单元素＝meta 兼作文本）；sel 按 metadata 选中。
static func dropdown(pairs: Array, sel: String, on_change := Callable()) -> OptionButton:
	var ob := OptionButton.new()
	for p in pairs:
		ob.add_item(str(p[1]) if p.size() > 1 else str(p[0]))
		ob.set_item_metadata(ob.item_count - 1, str(p[0]))
	select_meta(ob, sel)
	if on_change.is_valid():
		ob.item_selected.connect(func(_i): on_change.call())
	return ob

# 「标签 + 下拉」一行（add_line/add_spin 同族；技改 §13 地基件）
static func add_dropdown(parent: Node, text: String, pairs: Array, sel: String, on_change := Callable()) -> OptionButton:
	var ob := dropdown(pairs, sel, on_change)
	parent.add_child(field_row(text, ob))
	return ob

# —— 文件对话框工厂 ——
# filters：[[pattern, desc], ...]，如 [["*.json","地图 JSON"]]。native RES 对话框不存在→资源访问传 native=false。
static func make_file_dialog(mode: int, access: int, filters: Array, native := true) -> FileDialog:
	var dlg := FileDialog.new()
	dlg.file_mode = mode
	dlg.access = access
	dlg.use_native_dialog = native
	for f in filters:
		if typeof(f) == TYPE_ARRAY and f.size() >= 2:
			dlg.add_filter(str(f[0]), str(f[1]))
	return dlg

# —— 文件对话框「上次目录」记忆（跨编辑器共享·持久化到 user://）——
# 各浏览入口按**用途 scope** 记住上次选文件所在目录，下次弹窗默认回到那里（省得每次重选文件夹）。
# scope 分开（effect_icon / skill_icon / item_icon:<kind> / char_portrait / char_icon / …）故互不串味；
# 无记录/目录已失效 → 回退各自的默认目录。res:// 与 OS 绝对路径都支持（get_base_dir 各自成对往返）。
const _DIR_MEMORY_PATH := "user://editor_dir_memory.json"
static var _dir_memory: Dictionary = {}
static var _dir_memory_loaded := false

static func _ensure_dir_memory() -> void:
	if _dir_memory_loaded:
		return
	_dir_memory_loaded = true
	if FileAccess.file_exists(_DIR_MEMORY_PATH):
		var f := FileAccess.open(_DIR_MEMORY_PATH, FileAccess.READ)
		if f != null:
			var d = JSON.parse_string(f.get_as_text())
			if typeof(d) == TYPE_DICTIONARY:
				_dir_memory = d
			f.close()

# 选中文件后调（file_selected 里）：记住该用途上次所在目录并落盘。
static func remember_dir(scope: String, selected_path: String) -> void:
	if scope == "" or selected_path == "":
		return
	_ensure_dir_memory()
	var d := selected_path.get_base_dir()
	if d == "" or str(_dir_memory.get(scope, "")) == d:
		return
	_dir_memory[scope] = d
	var f := FileAccess.open(_DIR_MEMORY_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_dir_memory, "  "))
		f.close()

# 弹窗前调：取该用途上次目录（已记且仍存在则用之，否则回退 fallback 默认目录）。
static func recall_dir(scope: String, fallback: String) -> String:
	_ensure_dir_memory()
	var d := str(_dir_memory.get(scope, ""))
	if d != "" and DirAccess.dir_exists_absolute(d):
		return d
	return fallback

# —— 确认框 ——

# 通用确认：弹出 → 确定执行 on_ok / 取消执行 on_cancel，两路都 queue_free（一次性、不残留节点）。
static func confirm(host: Node, text: String, ok_text: String, on_ok: Callable,
		on_cancel := Callable(), title := "确认", cancel_text := "取消") -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = title
	dlg.dialog_text = text
	dlg.ok_button_text = ok_text
	dlg.get_cancel_button().text = cancel_text
	host.add_child(dlg)
	dlg.confirmed.connect(func():
		if on_ok.is_valid():
			on_ok.call()
		dlg.queue_free())
	dlg.canceled.connect(func():
		if on_cancel.is_valid():
			on_cancel.call()
		dlg.queue_free())
	dlg.popup_centered()

# 未保存改动守卫：干净 → 直接 on_ok；脏 → 弹确认（丢弃→on_ok / 留下→on_cancel）。
static func confirm_discard(host: Node, dirty: bool, on_ok: Callable, on_cancel := Callable(),
		text := "当前有未保存的改动，继续将丢弃。", ok_text := "丢弃", cancel_text := "取消") -> void:
	if not dirty:
		if on_ok.is_valid():
			on_ok.call()
		return
	confirm(host, text, ok_text, on_ok, on_cancel, "未保存的改动", cancel_text)


# —— 自由 tag 清单区（🔒 技能设计 §10 阶段2.4 抽通用：Item/Skill/Effect 编辑器共用一份）——
# arr 被就地增删（调用方持有同一数组）；options=[["sep",分组标题] | [id] | [id,显示文本], ...]，
# 空/只有分隔 ⇒ 不显下拉、只留手动输入。on_change＝任何增删后回调（刷新预览/置脏）。
static func add_tag_list(parent: Node, label_text: String, arr: Array, options: Array, on_change := Callable()) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	var adder := HBoxContainer.new()
	adder.add_theme_constant_override("separation", 6)
	var pick := OptionButton.new()
	pick.custom_minimum_size = Vector2(170, 0)
	pick.add_item("（下拉添加…）")
	pick.set_item_metadata(0, "")
	for o in options:
		if typeof(o) != TYPE_ARRAY or o.is_empty():
			continue
		if str(o[0]) == "sep":
			pick.add_separator(str(o[1]) if o.size() > 1 else "")
		else:
			pick.add_item(str(o[1]) if o.size() > 1 else str(o[0]))
			pick.set_item_metadata(pick.item_count - 1, str(o[0]))
	var has_presets := false
	for i in pick.item_count:
		if not pick.is_item_disabled(i) and str(pick.get_item_metadata(i)) != "":
			has_presets = true
			break
	if has_presets:
		pick.item_selected.connect(func(idx):
			var tg = pick.get_item_metadata(idx)
			if tg != null and str(tg) != "" and not arr.has(str(tg)):
				arr.append(str(tg))
				_rebuild_tag_box(box, arr, on_change)
				if on_change.is_valid():
					on_change.call()
			pick.select(0))
		adder.add_child(pick)
	else:
		pick.queue_free()
	var manual := LineEdit.new()
	manual.placeholder_text = "手动 tag"
	manual.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	adder.add_child(manual)
	var addb := Button.new()
	addb.text = "＋"
	addb.pressed.connect(func():
		var tt := manual.text.strip_edges()
		if tt != "" and not arr.has(tt):
			arr.append(tt)
			_rebuild_tag_box(box, arr, on_change)
			if on_change.is_valid():
				on_change.call()
		manual.clear())
	adder.add_child(addb)
	parent.add_child(field_row(label_text, adder))
	parent.add_child(box)
	_rebuild_tag_box(box, arr, on_change)

static func _rebuild_tag_box(box: VBoxContainer, arr: Array, on_change: Callable) -> void:
	if box == null or not is_instance_valid(box):
		return
	for c in box.get_children():
		c.queue_free()   # ⚠ 必须 queue_free：常由行内 ✕ 的 pressed 触发，free() 会当场释放发信号中的按钮
	if arr.is_empty():
		var l := Label.new()
		l.text = "（无）"
		l.add_theme_color_override("font_color", Color(0.55, 0.6, 0.66))
		l.add_theme_font_size_override("font_size", 12)
		box.add_child(l)
		return
	for t in arr:
		var row := HBoxContainer.new()
		var l := Label.new()
		l.text = "%s（%s）" % [TagDB.cn(str(t)), str(t)]
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(l)
		var rm := Button.new()
		rm.text = "✕"
		var tag := str(t)
		rm.pressed.connect(func():
			arr.erase(tag)
			_rebuild_tag_box(box, arr, on_change)
			if on_change.is_valid():
				on_change.call())
		row.add_child(rm)
		box.add_child(row)


# —— 修正行（stat 下拉 + 固定/百分比 + 数值 + ✕）——技能被动块 / 效果 mods 共用；
# ItemEditor 的修正行含 vision_state 特型不并入。stat_keys＝可选 stat 键序（中文经 StatMeta）。
# 返回 {row, stat, op, value}；entries＝调用方的行数组（✕ 时自动 erase 本 entry）。
static func add_mod_row(parent: Node, entries: Array, stat_keys: Array, stat: String, op: String, value: float, on_change := Callable()) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var st := OptionButton.new()
	st.custom_minimum_size = Vector2(180, 0)
	for key in stat_keys:
		st.add_item("%s %s" % [key, StatMeta.label(str(key))])
		st.set_item_metadata(st.item_count - 1, str(key))
	for i in st.item_count:
		if str(st.get_item_metadata(i)) == stat:
			st.select(i)
			break
	if on_change.is_valid():
		st.item_selected.connect(func(_i): on_change.call())
	row.add_child(st)
	var opb := OptionButton.new()
	opb.custom_minimum_size = Vector2(110, 0)
	for o in [["flat", "固定"], ["pct", "百分比%"]]:
		opb.add_item(str(o[1]))
		opb.set_item_metadata(opb.item_count - 1, str(o[0]))
	for i in opb.item_count:
		if str(opb.get_item_metadata(i)) == op:
			opb.select(i)
			break
	if on_change.is_valid():
		opb.item_selected.connect(func(_i): on_change.call())
	row.add_child(opb)
	var val := SpinBox.new()
	val.min_value = -9999
	val.max_value = 9999
	val.step = 0.5
	val.value = value
	val.custom_minimum_size = Vector2(110, 0)
	if on_change.is_valid():
		val.value_changed.connect(func(_v): on_change.call())
	row.add_child(val)
	var rm := Button.new()
	rm.text = "✕"
	var entry := {"row": row, "stat": st, "op": opb, "value": val}
	rm.pressed.connect(func():
		entries.erase(entry)
		row.queue_free()
		if on_change.is_valid():
			on_change.call())
	row.add_child(rm)
	parent.add_child(row)
	entries.append(entry)
	return entry


# —— when 条件行（🔒 模块_技能_设计 §4 / Unit._when_met 词表 v1）——
# conditional_mod 表单与将来技能树（阶段5）同词表直取；词表以引擎实际支持为准，勿发明新词：
# 单位语境 stat_threshold/equip_state/self_tag ＋ 交互语境 target_tag/skill_tag/target_effect（结算内生效）；
# time_of_day/nearby_units＝光环轮未实现（引擎 fail-closed）——载入遇到＝行锁定原样保留。
const WHEN_TYPES := [
	["stat_threshold", "属性阈值 stat_threshold"],
	["equip_state", "装备状态 equip_state"],
	["self_tag", "自身标签 self_tag"],
	["target_tag", "目标标签 target_tag（结算内）"],
	["skill_tag", "技能标签 skill_tag（结算内）"],
	["target_effect", "目标效果 target_effect（结算内）"],
	["event_relation", "事件单位关系 event_relation"],
	["weapon_tag", "武器标签 weapon_tag"],
	["weapon_grip", "武器握持 weapon_grip"],
	["incapacitated", "失能状态 incapacitated"],
]

# 一行 when 条件：类型下拉 + 按类型的参数子控件 + ✕。cond＝原始条件 dict（原样持有，
# collect_when_row 时 duplicate+按键更新——未编辑到的键字节级保留）。
# opts（调用方备料，本层不 preload 领域 DB）：
#   stat_keys: [stat键, ...] —— stat_threshold 属性键序（🔒 §4.3 when 读裸 stats，可含 HP 等运行态）
#   effect_options: [[id, 显示文本], ...] —— target_effect 效果下拉
#   slot_pairs: [[slot, 中文], ...] —— equip_state 槽位下拉（缺省主/副手）
# 返回 entry {row, data, type, pbox, params, locked}；entries＝调用方的行数组（✕ 自动 erase）。
static func add_when_row(parent: Node, entries: Array, cond: Dictionary, opts: Dictionary, on_change := Callable()) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var t := str(cond.get("type", ""))
	var known := false
	for p in WHEN_TYPES:
		if str(p[0]) == t:
			known = true
			break
	var entry := {"row": row, "data": cond, "locked": not known, "params": {}}
	if not known:
		# 未实现/未知类型：行锁定只读（收集原样返回）；✕ 仍可显式删除（显式≠静默丢失）
		var l := label("⚠ 未实现条件类型「%s」——原样保留：%s" % [t, JSON.stringify(cond)])
		l.add_theme_color_override("font_color", Color(0.95, 0.8, 0.35))
		l.add_theme_font_size_override("font_size", 12)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(l)
	else:
		var tob := dropdown(WHEN_TYPES, t)
		row.add_child(tob)
		entry["type"] = tob
		var pbox := HBoxContainer.new()
		pbox.add_theme_constant_override("separation", 6)
		pbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(pbox)
		entry["pbox"] = pbox
		_when_build_params(pbox, entry, cond, t, opts, on_change)
		tob.item_selected.connect(func(_i):
			# 换类型＝旧类型键作废、参数从骨架起；换回原类型＝回填原值（collect 按类型是否一致决定保留基底）
			var nt := str(tob.get_selected_metadata())
			var base: Dictionary = entry["data"] if str((entry["data"] as Dictionary).get("type", "")) == nt else {}
			_when_build_params(pbox, entry, base, nt, opts, on_change)
			if on_change.is_valid():
				on_change.call())
	var rm := Button.new()
	rm.text = "✕"
	rm.pressed.connect(func():
		entries.erase(entry)
		row.queue_free()
		if on_change.is_valid():
			on_change.call())
	row.add_child(rm)
	parent.add_child(row)
	entries.append(entry)
	return entry

# when 行参数子控件按类型重建（参数形状＝Unit._when_met 实际读的键，🔒 勿加引擎不认的键）
static func _when_build_params(pbox: HBoxContainer, entry: Dictionary, cond: Dictionary, t: String, opts: Dictionary, on_change: Callable) -> void:
	for c in pbox.get_children():
		c.queue_free()   # ⚠ queue_free：类型下拉发信号中触发，free() 会当场释放发信号控件
	var w := {}
	entry["params"] = w
	var chg := func():
		if on_change.is_valid():
			on_change.call()
	match t:
		"stat_threshold":   # {stat, op(>=缺省|<=), value, pct_of?}——读裸 stats（§4.3 递归防护）
			w["subject"] = dropdown([["owner", "自身 owner"], ["event.unit", "事件单位 event.unit"]], str(cond.get("subject", "owner")), chg)
			pbox.add_child(w["subject"])
			var pairs := []
			for k in opts.get("stat_keys", []):
				pairs.append([str(k), "%s %s" % [str(k), StatMeta.label(str(k))]])
			w["stat"] = dropdown(pairs, str(cond.get("stat", "HP")), chg)
			pbox.add_child(w["stat"])
			w["op"] = dropdown([[">=", "≥"], ["<=", "≤"]], str(cond.get("op", ">=")), chg)
			pbox.add_child(w["op"])
			var vs := SpinBox.new()
			vs.min_value = -9999
			vs.max_value = 9999
			vs.step = 0.5
			vs.value = float(cond.get("value", 0))
			vs.custom_minimum_size = Vector2(90, 0)
			vs.value_changed.connect(func(_v): chg.call())
			w["value"] = vs
			pbox.add_child(vs)
			var pkeys := [["", "（绝对值）"]]
			for k in opts.get("stat_keys", []):
				pkeys.append([str(k), "% / " + str(k)])
			w["pct_of"] = dropdown(pkeys, str(cond.get("pct_of", "")), chg)   # 非空＝stat/pct_of×100 与阈值比
			pbox.add_child(w["pct_of"])
		"equip_state":   # {slot, empty?:true | has_tag?:"tag"}；两键皆无＝有装备即可
			w["subject"] = dropdown([["owner", "自身 owner"], ["event.unit", "事件单位 event.unit"]], str(cond.get("subject", "owner")), chg)
			pbox.add_child(w["subject"])
			w["slot"] = dropdown(opts.get("slot_pairs", [["main_hand", "主手"], ["off_hand", "副手"]]),
				str(cond.get("slot", "main_hand")), chg)
			pbox.add_child(w["slot"])
			var mode := "occupied"
			if bool(cond.get("empty", false)):
				mode = "empty"
			elif str(cond.get("has_tag", "")) != "":
				mode = "has_tag"
			var mob := dropdown([["occupied", "有装备即可"], ["empty", "空置"], ["has_tag", "装备带 tag"]], mode)
			w["mode"] = mob
			pbox.add_child(mob)
			var tl := LineEdit.new()
			tl.text = str(cond.get("has_tag", ""))
			tl.placeholder_text = "装备 tag（如 weapon_sword）"
			tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			tl.editable = mode == "has_tag"
			tl.text_changed.connect(func(_t2): chg.call())
			w["tag"] = tl
			pbox.add_child(tl)
			mob.item_selected.connect(func(_i):
				tl.editable = str(mob.get_selected_metadata()) == "has_tag"
				chg.call())
		"self_tag":   # {tag, has?(缺省 true)}
			w["subject"] = dropdown([["owner", "自身 owner"], ["event.unit", "事件单位 event.unit"]], str(cond.get("subject", "owner")), chg)
			pbox.add_child(w["subject"])
			var sl := LineEdit.new()
			sl.text = str(cond.get("tag", ""))
			sl.placeholder_text = "自身 tag（如 flying）"
			sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sl.text_changed.connect(func(_t2): chg.call())
			w["tag"] = sl
			pbox.add_child(sl)
			var hc := CheckBox.new()
			hc.text = "须有（关＝须无）"
			hc.button_pressed = bool(cond.get("has", true))
			hc.toggled.connect(func(_v): chg.call())
			w["has"] = hc
			pbox.add_child(hc)
		"target_tag":   # {tag:"x"} 或 {any:[...]}——逗号分隔；收集沿原键形（保字节）
			w["subject"] = dropdown([["target", "结算目标 target"], ["owner", "自身 owner"], ["event.unit", "事件单位 event.unit"]], str(cond.get("subject", "target")), chg)
			pbox.add_child(w["subject"])
			var tt := []
			if cond.has("any"):
				for x in cond.get("any", []):
					tt.append(str(x))
			elif str(cond.get("tag", "")) != "":
				tt.append(str(cond.get("tag", "")))
			var al := LineEdit.new()
			al.text = ", ".join(PackedStringArray(tt))
			al.placeholder_text = "受击目标 tag 逗号分隔（多个＝任一命中，如 dragon, beast）"
			al.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			al.text_changed.connect(func(_t2): chg.call())
			w["tags"] = al
			pbox.add_child(al)
		"skill_tag":   # {tag}——本次结算技能的 tag
			var kl := LineEdit.new()
			kl.text = str(cond.get("tag", ""))
			kl.placeholder_text = "本次技能 tag（如 skill_sword）"
			kl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			kl.text_changed.connect(func(_t2): chg.call())
			w["tag"] = kl
			pbox.add_child(kl)
		"target_effect":   # {effect}——目标身上效果 id（EffectDB 引用）
			w["subject"] = dropdown([["target", "结算目标 target"], ["owner", "自身 owner"], ["event.unit", "事件单位 event.unit"]], str(cond.get("subject", "target")), chg)
			pbox.add_child(w["subject"])
			var cur := str(cond.get("effect", ""))
			var pairs2 := [["", "（选效果…）"]]
			pairs2.append_array(opts.get("effect_options", []))
			var found := false
			for p2 in pairs2:
				if str(p2[0]) == cur:
					found = true
					break
			if cur != "" and not found:
				pairs2.append([cur, "⚠ 悬空引用：" + cur])   # 悬空引用保值（同 _ensure_meta_option 口径）
			w["effect"] = dropdown(pairs2, cur, chg)
			pbox.add_child(w["effect"])
		"event_relation":
			w["subject"] = dropdown([["event.unit", "事件单位 event.unit"]], str(cond.get("subject", "event.unit")), chg)
			pbox.add_child(w["subject"])
			w["value"] = dropdown([["enemy", "敌对 enemy"], ["ally", "友方 ally"]], str(cond.get("value", "enemy")), chg)
			pbox.add_child(w["value"])
		"weapon_tag":
			w["subject"] = dropdown([["owner", "反应拥有者 owner"], ["event.unit", "事件单位 event.unit"]], str(cond.get("subject", "owner")), chg)
			pbox.add_child(w["subject"])
			w["slot"] = dropdown(opts.get("slot_pairs", [["main_hand", "主手"], ["off_hand", "副手"]]), str(cond.get("slot", "main_hand")), chg)
			pbox.add_child(w["slot"])
			var wt := LineEdit.new()
			wt.text = str(cond.get("tag", ""))
			wt.placeholder_text = "武器 tag（如 weapon_spear）"
			wt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			wt.text_changed.connect(func(_t2): chg.call())
			w["tag"] = wt
			pbox.add_child(wt)
		"weapon_grip":
			w["subject"] = dropdown([["owner", "反应拥有者 owner"], ["event.unit", "事件单位 event.unit"]], str(cond.get("subject", "owner")), chg)
			pbox.add_child(w["subject"])
			w["slot"] = dropdown(opts.get("slot_pairs", [["main_hand", "主手"], ["off_hand", "副手"]]), str(cond.get("slot", "main_hand")), chg)
			pbox.add_child(w["slot"])
			w["value"] = dropdown([["one_handed", "单手 one_handed"], ["two_handed", "双手 two_handed"]], str(cond.get("value", "two_handed")), chg)
			pbox.add_child(w["value"])
		"incapacitated":
			w["subject"] = dropdown([["owner", "反应拥有者 owner"], ["event.unit", "事件单位 event.unit"]], str(cond.get("subject", "owner")), chg)
			pbox.add_child(w["subject"])
			var ic := CheckBox.new()
			ic.text = "须为失能（关＝须未失能）"
			ic.button_pressed = bool(cond.get("value", true))
			ic.toggled.connect(func(_v): chg.call())
			w["value"] = ic
			pbox.add_child(ic)

# when 行收集（护栏：字节级保留）：类型未变＝duplicate 原条件、只更新表单拥有的键（未知键透传）；
# 换过类型＝从 {type} 重建（旧类型键作废）；锁定行＝原样返回。缺省值不落盘（canonical 最小键：
# op 缺省 >= / has 缺省 true——原文显式写过则保留）。必填缺失（空 tag/效果）→ errs 追加信息（调用方拒存）。
static func collect_when_row(entry: Dictionary, errs: Array) -> Dictionary:
	var data: Dictionary = entry.get("data", {})
	if entry.get("locked", false):
		return data.duplicate(true)
	var t := str((entry["type"] as OptionButton).get_selected_metadata())
	var out: Dictionary = data.duplicate(true) if str(data.get("type", "")) == t else {"type": t}
	out["type"] = t
	var w: Dictionary = entry["params"]
	match t:
		"stat_threshold":
			var sts := str(w["subject"].get_selected_metadata())
			if data.has("subject") or sts != "owner": out["subject"] = sts
			else: out.erase("subject")
			out["stat"] = str(w["stat"].get_selected_metadata())
			var op := str(w["op"].get_selected_metadata())
			if op == "<=" or out.has("op"):
				out["op"] = op
			out["value"] = _numv(float(w["value"].value))
			var pof := str(w["pct_of"].get_selected_metadata())
			if pof != "":
				out["pct_of"] = pof
			else:
				out.erase("pct_of")
		"equip_state":
			var eqs := str(w["subject"].get_selected_metadata())
			if data.has("subject") or eqs != "owner": out["subject"] = eqs
			else: out.erase("subject")
			out["slot"] = str(w["slot"].get_selected_metadata())
			match str(w["mode"].get_selected_metadata()):
				"empty":
					out["empty"] = true
					out.erase("has_tag")
				"has_tag":
					var tg := str(w["tag"].text).strip_edges()
					if tg == "":
						errs.append("equip_state「装备带 tag」模式须填 tag")
					out["has_tag"] = tg
					if bool(out.get("empty", false)):
						out.erase("empty")   # 显式 empty:false 保留（字节）；true 与本模式矛盾才摘
				_:
					out.erase("has_tag")
					if bool(out.get("empty", false)):
						out.erase("empty")
		"self_tag":
			var sls := str(w["subject"].get_selected_metadata())
			if data.has("subject") or sls != "owner": out["subject"] = sls
			else: out.erase("subject")
			var tg2 := str(w["tag"].text).strip_edges()
			if tg2 == "":
				errs.append("self_tag 条件 tag 不能为空")
			out["tag"] = tg2
			var hv: bool = w["has"].button_pressed
			if not hv or out.has("has"):
				out["has"] = hv
		"target_tag":
			var tts := str(w["subject"].get_selected_metadata())
			if data.has("subject") or tts != "target": out["subject"] = tts
			else: out.erase("subject")
			var list := []
			for p in str(w["tags"].text).split(","):
				var s := str(p).strip_edges()
				if s != "" and not list.has(s):
					list.append(s)
			if list.is_empty():
				errs.append("target_tag 条件至少填一个 tag")
			if out.has("any") or list.size() > 1:
				out["any"] = list
				out.erase("tag")
			elif list.size() == 1:
				out["tag"] = str(list[0])
		"skill_tag":
			var tg3 := str(w["tag"].text).strip_edges()
			if tg3 == "":
				errs.append("skill_tag 条件 tag 不能为空")
			out["tag"] = tg3
		"target_effect":
			var tes := str(w["subject"].get_selected_metadata())
			if data.has("subject") or tes != "target": out["subject"] = tes
			else: out.erase("subject")
			var eid := str(w["effect"].get_selected_metadata())
			if eid == "":
				errs.append("target_effect 条件未选效果")
			out["effect"] = eid
		"event_relation":
			var ers := str(w["subject"].get_selected_metadata())
			if data.has("subject") or ers != "event.unit": out["subject"] = ers
			else: out.erase("subject")
			out["value"] = str(w["value"].get_selected_metadata())
		"weapon_tag":
			var wts := str(w["subject"].get_selected_metadata())
			if data.has("subject") or wts != "owner": out["subject"] = wts
			else: out.erase("subject")
			var wslot := str(w["slot"].get_selected_metadata())
			if data.has("slot") or wslot != "main_hand": out["slot"] = wslot
			else: out.erase("slot")
			var wtag := str(w["tag"].text).strip_edges()
			if wtag == "":
				errs.append("weapon_tag 条件 tag 不能为空")
			out["tag"] = wtag
		"weapon_grip":
			var wgs := str(w["subject"].get_selected_metadata())
			if data.has("subject") or wgs != "owner": out["subject"] = wgs
			else: out.erase("subject")
			var wgslot := str(w["slot"].get_selected_metadata())
			if data.has("slot") or wgslot != "main_hand": out["slot"] = wgslot
			else: out.erase("slot")
			out["value"] = str(w["value"].get_selected_metadata())
		"incapacitated":
			out["subject"] = str(w["subject"].get_selected_metadata())
			out["value"] = bool(w["value"].button_pressed)
	return out


# —— Reaction 编辑器（决策36：Effect.reactions[] 与 Skill reaction 块共用）——

static func add_reaction_editor(parent: Node, entries: Array, reaction: Dictionary, opts: Dictionary, on_change := Callable()) -> Dictionary:
	var panel := PanelContainer.new()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	panel.add_child(box)
	var entry := {"data": reaction, "panel": panel, "when_rows": [], "action_rows": []}
	var head := HBoxContainer.new()
	entry["id"] = LineEdit.new()
	entry["id"].text = str(reaction.get("id", ""))
	entry["id"].placeholder_text = "reaction id"
	entry["id"].size_flags_horizontal = Control.SIZE_EXPAND_FILL
	entry["id"].text_changed.connect(func(_t): if on_change.is_valid(): on_change.call())
	head.add_child(entry["id"])
	entry["name"] = LineEdit.new()
	entry["name"].text = str(reaction.get("name", ""))
	entry["name"].placeholder_text = "显示名（可空）"
	entry["name"].size_flags_horizontal = Control.SIZE_EXPAND_FILL
	entry["name"].text_changed.connect(func(_t): if on_change.is_valid(): on_change.call())
	head.add_child(entry["name"])
	entry["trigger"] = dropdown(ReactionRegistry.options(), str(reaction.get("trigger", "unit_entered_zoc")), on_change)
	for i in entry["trigger"].item_count:
		var tid := str(entry["trigger"].get_item_metadata(i))
		if not ReactionRegistry.implemented(tid):
			entry["trigger"].set_item_disabled(i, true)
	head.add_child(entry["trigger"])
	var rm := Button.new()
	rm.text = "✕"
	rm.pressed.connect(func():
		entries.erase(entry)
		panel.queue_free()
		if on_change.is_valid(): on_change.call())
	head.add_child(rm)
	box.add_child(head)
	var trigger_warn := label("⚠ 该触发词尚未接线：数据不可入库")
	trigger_warn.add_theme_color_override("font_color", Color(0.95, 0.8, 0.35))
	trigger_warn.visible = not ReactionRegistry.implemented(str(reaction.get("trigger", "unit_entered_zoc")))
	entry["trigger_warn"] = trigger_warn
	box.add_child(trigger_warn)
	entry["trigger"].item_selected.connect(func(_i):
		trigger_warn.visible = not ReactionRegistry.implemented(str(entry["trigger"].get_selected_metadata())))

	var when_box := VBoxContainer.new()
	box.add_child(when_box)
	for cond in reaction.get("when", []):
		if cond is Dictionary:
			add_when_row(when_box, entry["when_rows"], cond, opts, on_change)
	var add_when := Button.new()
	add_when.text = "+ 触发条件 when"
	add_when.pressed.connect(func(): add_when_row(when_box, entry["when_rows"], {"type": "event_relation", "value": "enemy"}, opts, on_change); if on_change.is_valid(): on_change.call())
	box.add_child(add_when)

	var limit: Dictionary = reaction.get("limit", {})
	var limit_row := HBoxContainer.new()
	limit_row.add_child(label("次数限制"))
	var uses := SpinBox.new()
	uses.min_value = 0
	uses.max_value = 99
	uses.value = float(limit.get("uses", 1))
	uses.value_changed.connect(func(_v): if on_change.is_valid(): on_change.call())
	entry["uses"] = uses
	limit_row.add_child(uses)
	entry["reset"] = dropdown([["round", "每大回合"], ["turn", "每小回合"], ["battle", "每场战斗"]], str(limit.get("reset", "round")), on_change)
	limit_row.add_child(entry["reset"])
	entry["scope"] = dropdown([["owner", "拥有者 owner"]], str(limit.get("scope", "owner")), on_change)
	limit_row.add_child(entry["scope"])
	box.add_child(limit_row)

	var actions_box := VBoxContainer.new()
	entry["actions_box"] = actions_box
	box.add_child(actions_box)
	for action in reaction.get("actions", []):
		if action is Dictionary:
			_add_reaction_action(actions_box, entry["action_rows"], action, opts, on_change)
	var add_action := Button.new()
	add_action.text = "+ 反应动作（攻击）"
	add_action.pressed.connect(func(): _add_reaction_action(actions_box, entry["action_rows"], {"kind": "attack", "source": "current_bws", "actor": "owner", "target": "event.unit", "overrides": []}, opts, on_change); if on_change.is_valid(): on_change.call())
	box.add_child(add_action)
	parent.add_child(panel)
	entries.append(entry)
	return entry

static func _add_reaction_action(parent: Node, rows: Array, action: Dictionary, opts: Dictionary, on_change: Callable) -> void:
	var box := VBoxContainer.new()
	var row := HBoxContainer.new()
	var entry := {"data": action, "box": box, "override_rows": []}
	entry["kind"] = dropdown([["attack", "攻击 attack"]], str(action.get("kind", "attack")), on_change)
	entry["source"] = dropdown([["current_bws", "当前 BWS"]], str(action.get("source", "current_bws")), on_change)
	entry["actor"] = dropdown([["owner", "拥有者 owner"]], str(action.get("actor", "owner")), on_change)
	entry["target"] = dropdown([["event.unit", "事件单位 event.unit"]], str(action.get("target", "event.unit")), on_change)
	for key in ["kind", "source", "actor", "target"]:
		row.add_child(entry[key])
	var rm := Button.new()
	rm.text = "✕"
	rm.pressed.connect(func(): rows.erase(entry); box.queue_free(); if on_change.is_valid(): on_change.call())
	row.add_child(rm)
	box.add_child(row)
	var overrides_box := VBoxContainer.new()
	box.add_child(overrides_box)
	for override in action.get("overrides", []):
		if override is Dictionary:
			_add_reaction_override(overrides_box, entry["override_rows"], override, opts, on_change)
	var add_override := Button.new()
	add_override.text = "+ 条件覆盖 override"
	add_override.pressed.connect(func(): _add_reaction_override(overrides_box, entry["override_rows"], {"when": [], "set": {"final_damage_factor": 1.0}}, opts, on_change); if on_change.is_valid(): on_change.call())
	box.add_child(add_override)
	parent.add_child(box)
	rows.append(entry)

static func _add_reaction_override(parent: Node, rows: Array, override: Dictionary, opts: Dictionary, on_change: Callable) -> void:
	var box := VBoxContainer.new()
	var entry := {"data": override, "box": box, "when_rows": []}
	for cond in override.get("when", []):
		if cond is Dictionary:
			add_when_row(box, entry["when_rows"], cond, opts, on_change)
	var row := HBoxContainer.new()
	var add_when := Button.new()
	add_when.text = "+ 覆盖条件"
	add_when.pressed.connect(func(): add_when_row(box, entry["when_rows"], {"type": "weapon_grip", "subject": "owner", "value": "two_handed"}, opts, on_change); if on_change.is_valid(): on_change.call())
	row.add_child(add_when)
	row.add_child(label("设置 final_damage_factor"))
	var factor := SpinBox.new()
	factor.min_value = 0
	factor.max_value = 10
	factor.step = 0.05
	factor.value = float(override.get("set", {}).get("final_damage_factor", 1.0))
	factor.value_changed.connect(func(_v): if on_change.is_valid(): on_change.call())
	entry["factor"] = factor
	row.add_child(factor)
	var rm := Button.new()
	rm.text = "✕"
	rm.pressed.connect(func(): rows.erase(entry); box.queue_free(); if on_change.is_valid(): on_change.call())
	row.add_child(rm)
	box.add_child(row)
	parent.add_child(box)
	rows.append(entry)

static func collect_reaction_editor(entry: Dictionary, errs: Array) -> Dictionary:
	var out: Dictionary = (entry["data"] as Dictionary).duplicate(true)
	var rid := str(entry["id"].text).strip_edges()
	if rid == "": errs.append("reaction id 不能为空")
	out["id"] = rid
	var name := str(entry["name"].text).strip_edges()
	if name == "": out.erase("name")
	else: out["name"] = name
	var trigger := str(entry["trigger"].get_selected_metadata())
	if not ReactionRegistry.exists(trigger): errs.append("未知 reaction trigger：" + trigger)
	elif not ReactionRegistry.implemented(trigger): errs.append("reaction trigger 尚未接线：" + trigger)
	out["trigger"] = trigger
	var conds := []
	for wr in entry["when_rows"]: conds.append(collect_when_row(wr, errs))
	out["when"] = conds
	out["limit"] = {"uses": int(entry["uses"].value), "reset": str(entry["reset"].get_selected_metadata()), "scope": str(entry["scope"].get_selected_metadata())}
	var actions := []
	for ar in entry["action_rows"]:
		var action: Dictionary = (ar["data"] as Dictionary).duplicate(true)
		for key in ["kind", "source", "actor", "target"]: action[key] = str(ar[key].get_selected_metadata())
		var overrides := []
		for ore in ar["override_rows"]:
			var override: Dictionary = (ore["data"] as Dictionary).duplicate(true)
			var owhen := []
			for wr in ore["when_rows"]: owhen.append(collect_when_row(wr, errs))
			override["when"] = owhen
			override["set"] = {"final_damage_factor": _numv(float(ore["factor"].value))}
			overrides.append(override)
		action["overrides"] = overrides
		actions.append(action)
	if actions.is_empty(): errs.append("reaction 至少需要一个动作")
	out["actions"] = actions
	return out

# 数值归一：整数值落 int（JSON 往返 5 与 5.0 字节不同——与 SkillEditor._num / JsonRegistry.intify 同口径）
static func _numv(v: float):
	return int(v) if v == floorf(v) else v


# —— 物品选择器弹窗（编辑器优化 §23：搜索过滤 + 行图标 + 悬停富预览）——
# 现用：CharacterEditor 装备/背包选物；DeployPanel（布置期单位编辑）将来可共用同款（宿主备料 entries 即接）。
# entries=[{id, label, icon(Texture2D|null), color(Color|null), item(Dictionary|null)}, ...]；
# item 非空 → 悬停该行时右栏 ItemTooltip.render 富预览（接不上传 null 即纯列表）。
# allow_clear → 顶部「✕ 清空该槽」（on_pick 回传 ""）；点行回传 id 并关闭。返回 PopupPanel（测试/宿主可查）。
static func item_picker(host: Node, title: String, entries: Array, allow_clear: bool, on_pick: Callable) -> PopupPanel:
	var pop := PopupPanel.new()
	host.add_child(pop)
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(700, 480)
	v.add_theme_constant_override("separation", 6)
	pop.add_child(v)
	var t := Label.new()
	t.text = title
	t.add_theme_color_override("font_color", Color("#EBBC04"))
	v.add_child(t)
	var search := LineEdit.new()
	search.placeholder_text = "🔍 过滤 名字 / id"
	search.clear_button_enabled = true
	v.add_child(search)
	if allow_clear:
		var cb := Button.new()
		cb.text = "✕ 清空该槽"
		cb.pressed.connect(func():
			on_pick.call("")
			pop.queue_free())
		v.add_child(cb)
	var hb := HBoxContainer.new()
	hb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hb.add_theme_constant_override("separation", 8)
	v.add_child(hb)
	var list := ItemList.new()
	list.custom_minimum_size = Vector2(340, 0)
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.fixed_icon_size = Vector2i(24, 24)
	hb.add_child(list)
	var preview := VBoxContainer.new()   # 悬停行的富预览容器（ItemTooltip.render 挂这里）
	preview.custom_minimum_size = Vector2(320, 0)
	preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hb.add_child(preview)
	var ph := Label.new()
	ph.text = "（悬停物品行看详情）"
	ph.add_theme_color_override("font_color", Color(0.55, 0.6, 0.66))
	preview.add_child(ph)
	var shown: Array = []   # 过滤后可见 entries（与 list 行号一一对应）
	var refill := func():
		list.clear()
		shown.clear()
		var q := search.text.strip_edges().to_lower()
		for e in entries:
			var eid := str(e.get("id", ""))
			var lbl := str(e.get("label", eid))
			if q != "" and not (lbl.to_lower().contains(q) or eid.to_lower().contains(q)):
				continue
			var icon = e.get("icon")
			list.add_item(lbl, icon if icon is Texture2D else null)
			var col = e.get("color")
			if col is Color:
				list.set_item_custom_fg_color(list.item_count - 1, col)
			shown.append(e)
		if shown.is_empty():
			list.add_item("（无匹配物品——先在物品编辑器造 / 换关键词）")
			list.set_item_disabled(0, true)
	refill.call()
	search.text_changed.connect(func(_t2): refill.call())
	var hovered := [-1]   # 悬停行号（数组包一层供闭包改写）
	list.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseMotion:
			var idx := list.get_item_at_position(ev.position, true)
			if idx == hovered[0]:
				return
			hovered[0] = idx
			for c in preview.get_children():
				c.queue_free()
			if idx >= 0 and idx < shown.size():
				var it = (shown[idx] as Dictionary).get("item")
				if it is Dictionary:
					preview.add_child(ItemTooltip.render(it)))
	list.item_selected.connect(func(i: int):
		if i >= 0 and i < shown.size():
			on_pick.call(str((shown[i] as Dictionary).get("id", "")))
		pop.queue_free())
	var cancel := Button.new()
	cancel.text = "取消"
	cancel.pressed.connect(func(): pop.queue_free())
	v.add_child(cancel)
	pop.popup_centered(Vector2i(720, 520))
	return pop


# —— 通用分段场景切换（workshop_switch 的参数化版）——
# pairs=[[id, 按钮文字, 场景路径], ...]；current＝高亮禁点；guard 有效则切换前先过守卫
# （编辑器传脏守卫 _confirm_discard，防切场景静默丢未保存改动）。
static func scene_switch(host: Node, current: String, pairs: Array, guard := Callable()) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	for d in pairs:
		var id := str(d[0])
		var scene := str(d[2])
		var b := Button.new()
		b.text = str(d[1])
		b.focus_mode = Control.FOCUS_NONE
		if id == current:
			var hl := EditorTheme.sb(Color(0.24, 0.36, 0.52), Color(0.46, 0.62, 0.85))
			b.add_theme_stylebox_override("normal", hl)
			b.add_theme_stylebox_override("disabled", hl)
			b.disabled = true
		else:
			var go := func(): host.get_tree().change_scene_to_file(scene)
			b.pressed.connect(func():
				if guard.is_valid():
					guard.call(go)
				else:
					go.call())
		row.add_child(b)
	return row
