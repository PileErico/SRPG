extends Control
## 角色状态页（模态覆盖层）。
## 居中卡片（不占满全屏，留出周围看大地图），顶部 Tab 切换：
##   [角色状态]  上半「横长方形」＝左 立绘+身份 / 右 属性两列；
##              下半三列 ＝ 装备 / 物品栏 / 效果·buff。
##   [职业技能]  所有角色通用的职业技能树（占位，待实现）。
##   [专属技能]  仅「具名角色」（带 char_* 标记 = 拥有独特立绘）才有的独占技能树（占位，待实现）。
## 四角叠对角装饰边框；内容整体内缩，避开角饰。
## 打开：open(unit)；关闭：ESC / 点卡片外的遮罩（不设关闭按钮）。

const DiagonalFrame := preload("res://DiagonalFrame.gd")
const ItemInstances := preload("res://ItemInstances.gd")   # 装备槽经合成视图取物品（equipment 存实例 uid）
const ItemDB := preload("res://ItemDB.gd")                 # 编辑器背包格取模板（bag_items 存模板 id）
const ItemSlot := preload("res://ItemSlot.gd")
const EquipSlots := preload("res://EquipSlots.gd")   # 穿卸交互：槽位资格判定（拖放/菜单灰显与模型同口）
const TraitDB := preload("res://TraitDB.gd")
const SkillDB := preload("res://SkillDB.gd")
const ProfDB := preload("res://ProfDB.gd")               # 技艺（熟练度域）注册表——「技艺」页

const TagDB := preload("res://TagDB.gd")                 # 稀有度→颜色单一数据源
const TextureCache := preload("res://TextureCache.gd")   # 立绘/图标加载 + 缓存单一入口
const ItemTooltip := preload("res://ItemTooltip.gd")     # 物品富 tooltip 通用渲染组件（与物品编辑器共用）
const StatMeta := preload("res://StatMeta.gd")           # stat 键→中文 单一数据源（含甲抗/固减等全量键）

# 属性键 / tag → 中文均走单一数据源：stat 用 StatMeta.label（全量、无漂移），tag 用 TagDB.cn。

const CARD_SIZE := Vector2(900, 660)   # 卡片设计尺寸（1080p 下的像素尺寸；缩放基准）
const UIScale := preload("res://UIScale.gd")   # 全 UI 同比缩放：参考/夹值单一源（1080p 基准）
const FRAME_SCALE := 3                 # 角饰放大倍数
const GUTTER := 52                     # 上下留白：≥角饰高(17×scale) 以避让角饰
const SIDE_PAD := 28                   # 左右内缩

const Unit := preload("res://Unit.gd")   # BAG_CAP 单源（背包格数＝模型容量）
const BAG_USABLE := Unit.BAG_CAP       # 可用物品格（横4竖2）＝Unit.BAG_CAP 单源
const BAG_TOTAL := 16                  # 实际画 4×4，多出的锁定
const HEADER_H := 56                   # 抬头/拖动区高度（覆盖标题行 + 上方留白）

const STAT_GREEN := Color("#6FCF6F")   # 属性被修正调高
const STAT_RED := Color("#E07A5A")     # 属性被修正调低
# 稀有度 → 槽位边框色（见 docs/表单-标签.md）
# 稀有度→颜色改从 TagDB 单一数据源读（见 _rarity_color_of），不再在此硬编码副本。

# —— 拖动状态（非模态悬浮窗）——
var _card: PanelContainer
var _dragging := false
var _drag_offset := Vector2.ZERO
var _win_pos := Vector2(-1, -1)        # 记住上次拖到的位置（x<0 = 未设 → 居中）

# —— 翻页 / 高亮 ——
var host = null                        # 宿主（Sandbox）：翻页取同阵营单位 + 棋子高亮
var _unit = null                       # 当前查看的单位
var _current_tab := 0                  # 记住当前 Tab（翻页时保持）
var _prof_subtab := 0                   # 技艺页 L2 横向 tab（技能类型：武器/战斗/其他；重建保持）
var _prof_l3 := 0                       # 技艺页 L3 纵向 tab（当前类型下具体技能；重建保持）
var _prof_slots_row: HBoxContainer      # 技能页装载格行（点格换装/等级改动即时刷新——2026-07-15 用户令）

# —— 编辑器模式（角色编辑器嵌用；默认 false → 游戏内查看行为逐字节零改动）——
# 打开＝设 editor_mode=true + 注入回调后 open(u)。可编辑：头像点选 / 姓名·等级 / 特性下拉 / 装备槽点选 / 背包。
var editor_mode := false               # true=可编辑 + docked 填充 + 无拖动/翻页/ESC 关闭
var on_portrait_pick := Callable()     # 点头像 → 宿主开文件对话框（无参）
var on_equip_slot := Callable()        # 点装备槽 → 宿主开物品选择器（参：slot_id:String）
var on_bag_slot := Callable()          # 点背包格 → 宿主开物品选择器（参：index:int）
var on_edit := Callable()              # 面板内任一编辑后 → 宿主标脏（无参）
var bag_items: Array = []              # 编辑器背包内容（item id 列表；仅编辑器态显示，不入档）
var _stats_col: VBoxContainer = null   # 右侧属性列引用（特性/种族/装备改后就地刷新，免整卡重建）
var _trait_ids: Array = []             # 编辑器特性下拉的 index→id 映射

# —— 穿卸交互模式（游戏内 Sandbox/Overworld 开启；与 editor_mode 互斥——编辑器沿用旧回调路径）——
# 点装备槽 → 卸下/换手菜单；点背包件 → 装备菜单；拖拽（槽↔背包、主手↔副手）同语义。仅 player 阵营单位生效。
var equip_interact := false            # true=装备槽/背包可交互
var on_equip_gate := Callable()        # 费用闸 Callable(u, commit:bool)->bool：false=只查资格、true=扣费提交（战斗中 1 AP）；无效=免费
var on_equipment_changed := Callable() # 动作成功后通知宿主（刷画布/信息栏）
var _equip_menu: PopupMenu = null      # 穿卸动作菜单（懒建复用）

func open(u) -> void:
	_unit = u
	_build(u)
	visible = true

func close() -> void:
	visible = false
	if host != null:
		host.set_viewed_unit(null)

func _input(event: InputEvent) -> void:
	if not visible:
		return
	# ESC 关闭（编辑器模式下面板是主界面，不关闭）
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE and not editor_mode:
		close()
		get_viewport().set_input_as_handled()
		return
	# 拖动中：跟随鼠标、松开结束（在 _input 里处理，光标移出标题条也不丢拽）
	if _dragging:
		if event is InputEventMouseMotion:
			_set_card_pos(event.global_position + _drag_offset)
			get_viewport().set_input_as_handled()
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			_dragging = false
			_win_pos = _card.position
			get_viewport().set_input_as_handled()

func _build(u) -> void:
	for c in get_children():
		c.queue_free()
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE   # 非模态：卡片以外一律穿透，照常操作战斗

	# 卡片：游戏内＝固定尺寸居中可拖动；编辑器＝仍固定 CARD_SIZE（不随窗口拉伸！），
	# 填满 self（self 由宿主 CharacterEditor 钉死为 CARD_SIZE 并套 ScrollContainer 兜溢出）。
	var card := PanelContainer.new()
	if editor_mode:
		card.set_anchors_preset(Control.PRESET_FULL_RECT)
	else:
		card.custom_minimum_size = CARD_SIZE
		card.size = CARD_SIZE
		card.pivot_offset = Vector2.ZERO          # 从左上角缩放 → position 仍是左上角，居中/拖动照旧
		card.scale = Vector2.ONE * _card_scale()
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(card)
	_card = card
	# 窗口/视口尺寸变化 → 重算缩放并复位（编辑器模式恒 1、由宿主布局，无需监听）
	if not editor_mode and not resized.is_connected(_on_resized):
		resized.connect(_on_resized)

	# 内容内缩：上下留白避让角饰
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", SIDE_PAD)
	margin.add_theme_constant_override("margin_right", SIDE_PAD)
	margin.add_theme_constant_override("margin_top", 0)
	margin.add_theme_constant_override("margin_bottom", GUTTER)
	card.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	margin.add_child(root)

	# 抬头 / 拖动区（整个顶部都能抓住拖动；含 < > 翻页 + 标题）
	root.add_child(_make_header(u))

	# 顶部 Tab：角色状态 / 通用技能 / 第三页（具名角色＝专属技能 / 杂兵＝职业技能，二选一）
	# 技能三分类（见 docs/模块_战斗_设计.md「技能三分类」）：通用＝人人；职业＝同类单位共享树（杂兵主进度）；专属＝具名独有。
	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var empty := StyleBoxEmpty.new()
	empty.content_margin_top = 10
	empty.content_margin_left = 0
	empty.content_margin_right = 0
	empty.content_margin_bottom = 0
	tabs.add_theme_stylebox_override("panel", empty)
	var status_page := _build_status_page(u)
	status_page.name = "角色状态"
	tabs.add_child(status_page)
	# 技能（熟练度域 🔒 模块_属性成长_设计.md §2；术语🔒 技能=可练的域）：三页分区 + 阶段进度 + 装载/卸载（非战斗随时；战斗中锁定只读）
	var craft_page := _build_prof_page(u)
	craft_page.name = "技能"
	tabs.add_child(craft_page)
	# （原「通用能力」页已删 2026-07-13——13 通用序列属旧技能体系，新体系＝武器技能+熟练度+树）
	# 第三页二选一：具名角色（char_*）→ 专属能力；其余杂兵 → 职业能力（同类共享树）
	if _has_exclusive_skills(u):
		var exclusive_page := _build_exclusive_skill_page(u)
		exclusive_page.name = "专属能力"
		tabs.add_child(exclusive_page)
	else:
		var prof_page := _build_profession_skill_page(u)
		prof_page.name = "职业能力"
		tabs.add_child(prof_page)
	tabs.current_tab = clampi(_current_tab, 0, tabs.get_tab_count() - 1)
	tabs.tab_changed.connect(func(idx): _current_tab = idx)
	root.add_child(tabs)

	# 对角装饰边框：铺满卡片、画在最上层、点击穿透
	var frame := DiagonalFrame.new()
	frame.corner_scale = FRAME_SCALE
	card.add_child(frame)

	if not editor_mode:
		_place_card()
	if host != null:
		host.set_viewed_unit(u)

# ============ 拖动 / 摆放 ============

# 抬头/拖动区：整块顶部都能抓住拖动；左上角 < > 翻页 + 标题；非按钮元素 IGNORE → 点哪都能拖
func _make_header(u) -> Control:
	var bar := VBoxContainer.new()
	bar.custom_minimum_size = Vector2(0, HEADER_H)
	bar.mouse_filter = Control.MOUSE_FILTER_STOP
	if not editor_mode:                    # 编辑器模式不拖动、不翻页
		bar.mouse_default_cursor_shape = Control.CURSOR_MOVE
		bar.gui_input.connect(_on_header_input)

	# 整行往下挪一点，不贴顶边
	var pad := MarginContainer.new()
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_theme_constant_override("margin_top", 10)
	bar.add_child(pad)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 空白处穿透给 bar → 可拖动
	row.add_theme_constant_override("separation", 14)
	pad.add_child(row)

	if not editor_mode:
		row.add_child(_nav_button("<", -1, "上一个同阵营单位"))
		row.add_child(_nav_button(">", 1, "下一个同阵营单位"))

	var title := Label.new()
	title.text = "%s · %s" % [TagDB.cn(u.faction), str(u.unit_name)]
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(title)

	var hint := Label.new()
	hint.text = "（可编辑：点头像/填四维/点装备槽）" if editor_mode else "（拖动此处移动 · ESC 关闭）"
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.35))
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(hint)
	return bar

# 纯符号翻页按钮：无背景，灰白 → 悬停亮白，手型光标
func _nav_button(sym: String, dir: int, tip: String) -> Button:
	var b := Button.new()
	b.text = sym
	b.tooltip_text = tip
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(38, 32)   # 放大点击区，好按
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var e := StyleBoxEmpty.new()
	b.add_theme_stylebox_override("normal", e)
	b.add_theme_stylebox_override("hover", e)
	b.add_theme_stylebox_override("pressed", e)
	b.add_theme_stylebox_override("focus", e)
	b.add_theme_color_override("font_color", Color(0.72, 0.72, 0.72))    # 常态灰白
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1))       # 悬停亮白
	b.add_theme_color_override("font_pressed_color", Color(1, 1, 1))
	b.add_theme_font_size_override("font_size", 24)
	b.pressed.connect(_cycle.bind(dir))
	return b

func _on_header_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_dragging = true
		_drag_offset = _card.global_position - event.global_position
		accept_event()

# 翻到场上同侧的上一个/下一个单位（dir = -1/+1，循环）。同侧 = 我方+友方 / 敌方+中立。
func _cycle(dir: int) -> void:
	if host == null or _unit == null:
		return
	var side := _side(_unit.faction)
	var group := []
	for x in host.board_units():   # S5：经访问器读场上单位，不直读 host.units
		if _side(x.faction) == side:
			group.append(x)
	if group.size() <= 1:
		return
	var idx := group.find(_unit)
	if idx < 0:
		idx = 0
	idx = (idx + dir + group.size()) % group.size()
	open(group[idx])

# 阵营归边：我方/友方 同侧，敌方/中立 同侧（< > 在同侧内循环）
func _side(faction: String) -> String:
	return "friend" if faction in ["player", "ally"] else "foe"

# 卡片缩放系数：随视口等比（编辑器模式恒 1）；1080p 基准 + 夹值 → UIScale 单一源。
func _card_scale() -> float:
	if editor_mode:
		return 1.0
	return UIScale.factor(get_viewport_rect().size)

# 视口尺寸变化：重算缩放 + 复位（居中或沿用拖动位并钳制）
func _on_resized() -> void:
	if editor_mode or _card == null or not is_instance_valid(_card):
		return
	_card.scale = Vector2.ONE * _card_scale()
	_place_card()

# 初次居中；之后沿用上次拖到的位置（用缩放后的可视尺寸）
func _place_card() -> void:
	var vp := get_viewport_rect().size
	if _win_pos.x < 0.0:
		var cs := CARD_SIZE * _card.scale.x
		_card.position = ((vp - cs) * 0.5).floor()
	else:
		_set_card_pos(_win_pos)

# 设卡片位置并钳制：横向至少留 min_vis 可见，标题条不超出顶/底（用缩放后尺寸）
func _set_card_pos(p: Vector2) -> void:
	var vp := get_viewport_rect().size
	var cs: Vector2 = _card.size * _card.scale.x
	var min_vis := 140.0
	p.x = clampf(p.x, -(cs.x - min_vis), vp.x - min_vis)
	p.y = clampf(p.y, 0.0, vp.y - HEADER_H)
	_card.position = p

# ============ Tab 页 ============

# 「角色状态」页：上 横长方形（立绘+身份 / 属性），下 三列（装备 / 物品栏 / 效果）
func _build_status_page(u) -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)

	# 上半：左 立绘+身份 / 右 属性两列
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 16)
	page.add_child(top)
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.size_flags_stretch_ratio = 1.0
	top.add_child(info)
	top.add_child(VSeparator.new())
	var stats := VBoxContainer.new()
	stats.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stats.size_flags_stretch_ratio = 2.0
	top.add_child(stats)
	_build_info(info, u)
	_build_stats(stats, u)
	_stats_col = stats   # 编辑器：四维/特性改后就地刷新这列（免整卡重建、不丢 spinbox 焦点）

	page.add_child(HSeparator.new())

	# 下半：装备 / 物品栏 / 效果
	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 16)
	bottom.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(bottom)

	var equip := VBoxContainer.new()
	equip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	equip.size_flags_stretch_ratio = 1.0
	bottom.add_child(equip)
	bottom.add_child(VSeparator.new())
	var bag := VBoxContainer.new()
	bag.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bag.size_flags_stretch_ratio = 1.0
	bottom.add_child(bag)
	bottom.add_child(VSeparator.new())
	var fx := VBoxContainer.new()
	fx.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fx.size_flags_stretch_ratio = 1.2
	bottom.add_child(fx)

	_build_equip(equip, u)
	_build_bag(bag, u)
	_build_effects(fx, u)
	return page

# 「专属能力」页：具名角色（char_*）独占的天赋树输出——随等级解锁、常选 1/N 分支定走向（占位，待实现）
func _build_exclusive_skill_page(_u) -> Control:
	return _skill_placeholder("专属能力 —— 待实现")

# 「职业能力」页：同类单位共享、跨类不通的天赋树输出（杂兵主进度；按原型归类）（占位，待实现）
func _build_profession_skill_page(_u) -> Control:
	return _skill_placeholder("职业能力 —— 待实现（同类单位共享天赋树）")

# 占位空白页（居中淡灰提示）
func _skill_placeholder(text: String) -> Control:
	var c := CenterContainer.new()
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.4))
	c.add_child(l)
	return c

# 是否拥有专属技能：带任一 char_* 具名标记（= 拥有独特立绘的特殊角色）。
func _has_exclusive_skills(u) -> bool:
	for t in u.tags:
		if str(t).begins_with("char_"):
			return true
	return false

# ============ 上半 ============

# 左上：立绘 + 身份
# 布局：①顶部 左 头像(靠左) / 竖线 / 右 四维(上下居中)；②身份 姓名/特性/等级 整行铺开；③底部 完整一条经验槽。
func _build_info(info: VBoxContainer, u) -> void:
	# ① 顶部：头像 + 四维 并排
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 14)
	info.add_child(top)
	if editor_mode:
		top.add_child(_editable_portrait(u))   # 空＝大「＋」，点击开文件对话框；有图＝显示且可换
	else:
		var tex = TextureCache.get_tex(u.portrait)
		if tex != null:
			var av := TextureRect.new()
			av.texture = tex
			av.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # 像素图放大不糊
			av.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			av.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			av.custom_minimum_size = Vector2(132, 150)
			av.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN   # 靠左
			top.add_child(av)
		else:
			var ph := Label.new()
			ph.text = "[无立绘]"
			ph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			ph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			ph.custom_minimum_size = Vector2(132, 150)
			ph.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			top.add_child(ph)
	top.add_child(_attr_col(u))   # 头像右侧＝四属性列（🔒 2026-07-08 用户定布局；加点按钮整合在此）
	info.add_child(HSeparator.new())

	# ② 身份：姓名 / 特性 / 等级（整行铺开；编辑器＝可编辑）
	var ident := VBoxContainer.new()
	ident.add_theme_constant_override("separation", 6)
	info.add_child(ident)
	if editor_mode:
		ident.add_child(_edit_line_row("姓名", str(u.unit_name), _on_edit_name))
		ident.add_child(_trait_dropdown_row(u))
		ident.add_child(_edit_spin_row("等级", int(u.level), 1, 99, _on_edit_level))
	else:
		_kv(ident, "姓名", str(u.unit_name))
		ident.add_child(_trait_row(u))    # 特性：稀有度色 + 悬停富 tooltip
		_kv(ident, "等级", str(u.level))

	# ③ 底部：完整一条经验槽（独立、不与等级重叠；数值悬停可见）
	info.add_child(_exp_bar(u))

# ============ 编辑器专用小件（editor_mode；游戏内查看路径不触及）============

func _emit_edit() -> void:
	if on_edit.is_valid():
		on_edit.call()

# 右列属性就地刷新（特性/装备改后调；不整卡重建 → 保住左侧编辑件焦点）
func _refresh_stats_col(u) -> void:
	if _stats_col == null or not is_instance_valid(_stats_col):
		return
	for c in _stats_col.get_children():
		c.free()   # 纯静态标签行、无正发信号的对象（spinbox 在左列不在此），立即释放避免一帧双影
	_build_stats(_stats_col, u)

func _on_edit_name(t: String) -> void:
	if _unit == null: return
	_unit.unit_name = t
	_emit_edit()

func _on_edit_level(v: float) -> void:
	if _unit == null: return
	_unit.level = int(v)
	_refresh_prof_slots(_unit)   # 等级驱动技能槽容量（1/4/8/11/16）——即时解锁/上锁（2026-07-15 用户令）
	_emit_edit()

func _on_edit_trait(idx: int) -> void:
	if _unit == null: return
	_unit.set_trait(str(_trait_ids[idx]) if idx < _trait_ids.size() else "")
	_refresh_stats_col(_unit)   # 特性可改四维/派生
	_emit_edit()

# 可点头像：空＝132×150 大「＋」框；有图＝显示立绘；整块点击 → on_portrait_pick
func _editable_portrait(u) -> Control:
	var box := _slot_box(Vector2(132, 150))
	box.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	box.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	box.tooltip_text = "点击选择立绘图片"
	var tex = TextureCache.get_tex(u.portrait)
	if tex != null:
		var av := TextureRect.new()
		av.texture = tex
		av.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		av.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		av.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		av.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(av)
	else:
		var plus := Label.new()
		plus.text = "＋"
		plus.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		plus.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		plus.add_theme_font_size_override("font_size", 48)
		plus.add_theme_color_override("font_color", Color(1, 1, 1, 0.35))
		plus.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(plus)
	box.gui_input.connect(_on_portrait_input)
	return box

func _on_portrait_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if on_portrait_pick.is_valid():
			on_portrait_pick.call()

# 「标签 + LineEdit」一行（编辑器身份区）
func _edit_line_row(label: String, value: String, on_change: Callable) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var l := Label.new()
	l.text = "%s：" % label
	l.custom_minimum_size = Vector2(56, 0)
	row.add_child(l)
	var le := LineEdit.new()
	le.text = value
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.text_changed.connect(on_change)
	row.add_child(le)
	return row

# 「标签 + SpinBox」一行
func _edit_spin_row(label: String, value: int, mn: int, mx: int, on_change: Callable) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var l := Label.new()
	l.text = "%s：" % label
	l.custom_minimum_size = Vector2(56, 0)
	row.add_child(l)
	var sp := SpinBox.new()
	sp.min_value = mn
	sp.max_value = mx
	sp.step = 1
	sp.value = value
	sp.custom_minimum_size = Vector2(80, 0)
	sp.value_changed.connect(on_change)
	row.add_child(sp)
	return row

# 特性下拉行（编辑器；替代只读 _trait_row）
func _trait_dropdown_row(u) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var l := Label.new()
	l.text = "特性："
	l.custom_minimum_size = Vector2(56, 0)
	row.add_child(l)
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_trait_ids = [""]
	opt.add_item("（无）", 0)
	var i := 1
	for id in TraitDB.all().keys():
		var t = TraitDB.all()[id]
		opt.add_item("%s（%s）" % [str(t.get("name", id)), TagDB.cn(str(t.get("rarity", "")))], i)
		_trait_ids.append(id)
		if str(u.trait_id) == str(id):
			opt.select(i)
		i += 1
	if str(u.trait_id) == "":
		opt.select(0)
	opt.item_selected.connect(_on_edit_trait)
	row.add_child(opt)
	return row

# 经验槽：整条横向进度条（fill = 经验/上限）；左叠淡「经验」标识；悬停出「经验：x / x」。
# 配色：浅紫底 + 稍深黑边框 + 明显紫填充。
func _exp_bar(u) -> Control:
	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(0, 18)
	bar.min_value = 0
	bar.max_value = maxf(1.0, float(u.exp_max))
	bar.value = clampf(float(u.exp), 0.0, bar.max_value)
	bar.show_percentage = false
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 让外层 tooltip 宿主接管 hover
	var tip := "经验：%d / %d" % [int(u.exp), int(u.exp_max)]
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color("#9B59B6")
	bg.bg_color.a = 0.14
	bg.border_color = Color(0, 0, 0, 0.85)
	bg.set_border_width_all(1)
	bg.set_corner_radius_all(3)
	bar.add_theme_stylebox_override("background", bg)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color("#9B59B6")
	fill.set_corner_radius_all(3)
	bar.add_theme_stylebox_override("fill", fill)
	# 叠淡「经验」标识（不挡 hover）
	var mc := MarginContainer.new()
	mc.set_anchors_preset(Control.PRESET_FULL_RECT)
	mc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mc.add_theme_constant_override("margin_left", 6)
	var lbl := Label.new()
	lbl.text = "经验"
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mc.add_child(lbl)
	bar.add_child(mc)
	return _tip_host(bar, tip)   # 纯黑 tooltip 宿主

# 特性行：「特性：名」——名按稀有度上色（无特性=灰「无」）；有特性则悬停出富 tooltip（加成+性质描述）。
# 用 ItemSlot 当 tooltip 宿主（去掉边框），复用其 _make_custom_tooltip → tooltip_builder 机制。
func _trait_row(u) -> Control:
	var tid := str(u.trait_id) if ("trait_id" in u) else ""
	var t = TraitDB.get_trait(tid) if tid != "" else null
	var host := ItemSlot.new()
	host.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	host.mouse_filter = Control.MOUSE_FILTER_STOP
	if t != null:
		host.item = t
		host.tooltip_builder = _build_trait_tooltip
		host.tooltip_text = str(t.get("name", ""))
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 0)
	host.add_child(h)
	var k := Label.new()
	k.text = "特性："
	k.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(k)
	var v := Label.new()
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if t != null:
		v.text = str(t.get("name", ""))
		var rc = _rarity_color_of(str(t.get("rarity", "")))
		if rc != null:
			v.add_theme_color_override("font_color", rc)
	else:
		v.text = "无"
		v.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	h.add_child(v)
	return host

# 特性富 tooltip：黑底 + 稀有度边框；名称(稀有度色) + 属性加成(绿/红行，复用 _mod_line) + 性质描述。
func _build_trait_tooltip(t) -> Control:
	var rc = _rarity_color_of(str(t.get("rarity", "")))
	if rc == null:
		rc = Color(1, 1, 1, 0.5)
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 1)
	sb.border_color = rc
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 5)
	panel.add_child(v)
	var name_l := Label.new()
	name_l.text = str(t.get("name", ""))
	name_l.add_theme_font_size_override("font_size", 18)
	name_l.add_theme_color_override("font_color", rc)
	v.add_child(name_l)
	# 具体属性加成行
	for m in t.get("mods", []):
		v.add_child(ItemTooltip.mod_line(m, 15))
	# 性质描述（含限制说明）
	var desc := str(t.get("desc", ""))
	if desc != "":
		v.add_child(HSeparator.new())
		var d := Label.new()
		d.text = desc
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		d.custom_minimum_size = Vector2(280, 0)
		d.add_theme_font_size_override("font_size", 14)
		d.add_theme_color_override("font_color", Color(0.82, 0.82, 0.86))
		v.add_child(d)
	return panel

# ============ 技能页（熟练度域 🔒 模块_属性成长_设计.md §2；视觉稿 v1 → 真数据已接）============
# 术语 🔒（表单-专用术语）：本页＝技能（熟练度域，代码旧名 prof/技艺）；「能力」各页＝SkillDB 主动招式。
# 布局：① 顶部 5 装备格＝Unit.prof_slots（竖向计量槽=档位内进度、色随档位；容量外格=未解锁）② 横线
#       ③ 三级 tab：L2 横向三 tab 名/序不改（用户令 2026-07-06）＝武器技能/战斗技能/其他技能，
#         映射 ProfDB 三页 weapon/style/life（战斗技能=风格页、其他=生活页「有些不太生活」）
#         → L3 纵向＝该页各域（阶段浮现过滤）→ 内容页（待定）
#       右侧窄列「已习得」＝Unit.prof_known（熟练度高→低）。
# 图标：装载格读该域 proficiencies.json 的 `icon` 字段（res:// 路径，🟡 技艺图标待玩家自绘/委托——
#   与物品图标逻辑不同，不复用物品图）；未填=空格（名字在格下）。要上图＝往对应域加 "icon":"res://…"。
# ⚠️ 待接回：装载/卸载交互（点格换装）+ 战斗锁 _can_swap_prof（原列表版已拆，🔒 规格仍在）。

# 熟练度档位 🔒（用户定曲线 2026-07-06：0/100/300/600/1000，大师满值 1500）：
# 档位名/阈值读 ProfDB 单一源（STAGE_THRESHOLDS/STAGE_NAMES/MASTER_XP_CAP），本处只留 UI 配色。
const PROF_STAGE_COLORS := ["#E0E0E0", "#4FAE5A", "#3A7BD5", "#9B59B6", "#EBBC04"]   # 生疏白/娴熟绿/老练蓝/专家紫/大师金
const PROF_CELL_COUNT := 5                        # 装备技能格数（=技艺槽上限）
const PROF_SLOT_LV := [1, 4, 8, 11, 16]           # 各格解锁等级 🔒（20 级表 §10.1 二次修订，与 Unit.prof_slot_capacity 同源）
const PROF_CELL_SIZE := Vector2(64, 64)           # 单格边长
const PROF_GAUGE_W := 12                          # 竖向计量槽宽度
const PROF_GAUGE_TRACK := Color(1, 1, 1, 0.10)    # 槽底（暗）
const PROF_PAGES := [["武器技能", "weapon"], ["战斗技能", "style"], ["其他技能", "life"]]   # L2 tab 显示名→ProfDB 页（名/序 🔒 用户定）
const PROF_FONT_CELL := 13                        # 装备格下方「名-档位」字号
const PROF_FONT_LIST := 15                        # 右侧「已习得」列表字号

# xp → 档位定义 {name, lo, hi, color}（阈值/名字来自 ProfDB.stage_of 单一源；hi＝下一档下界或大师满值）
# static 公开复用：档位显示口径单源——角色编辑器已学习行同吃（与 ItemTooltip 小件跨类复用同约定）。
static func _prof_tier(xp: int) -> Dictionary:
	var stage: int = ProfDB.stage_of(xp)
	var lo := int(ProfDB.STAGE_THRESHOLDS[stage - 1])
	var hi := int(ProfDB.STAGE_THRESHOLDS[stage]) if stage < ProfDB.STAGE_THRESHOLDS.size() else int(ProfDB.MASTER_XP_CAP)
	return {"name": ProfDB.stage_name(stage), "lo": lo, "hi": hi, "color": PROF_STAGE_COLORS[stage - 1]}

# xp → 当前档位内进度 0..1（gauge 填充高度）
func _prof_tier_progress(xp: int) -> float:
	var t := _prof_tier(xp)
	return clampf(float(xp - int(t["lo"])) / float(maxi(1, int(t["hi"]) - int(t["lo"]))), 0.0, 1.0)

# 档位「显示」名/色（🔒 用户 2026-07-07）：未学习→深灰；首段→白「入门」（覆盖 ProfDB 的"生疏"）；
# 其后 娴熟/老练/专家/大师 照旧。仅覆盖 UI 显示、不动数据层；gauge 填充/进度仍走 _prof_tier。
# ⚠️ 判据修订（2026-07-15 known 三态落地）：未学习＝不在 prof_known，不再拿 xp==0 顶替——
# 已学习但 xp=0（编辑器刚标 known）＝入门(白)，与「已学=可装载,生疏起步」三态对齐（Unit.gd L131）。
const PROF_UNLEARNED := {"name": "未学习", "color": "#808080"}
const PROF_TIER0_NAME := "入门"
static func _prof_disp(xp: int, known := true) -> Dictionary:
	if not known:
		return PROF_UNLEARNED
	var t := _prof_tier(xp)
	return {"name": PROF_TIER0_NAME if int(t["lo"]) == 0 else str(t["name"]), "color": str(t["color"])}

func _build_prof_page(u) -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 4)   # 收紧上部区块间距 → 让位给中轴计量条

	# ① 顶部：5 个装备技能格＝Unit.prof_slots；容量内空格=（空槽）、容量外=未解锁（Lv 节拍）。
	# editor_mode 点格换装（2026-07-15 用户令）：空槽点击→已学习选单装载、已装点击→卸载；
	# 等级编辑即时刷新容量（_on_edit_level → _refresh_prof_slots）。游戏内查看路径仍只读（战斗锁待接回）。
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	page.add_child(row)
	_prof_slots_row = row
	_refresh_prof_slots(u)

	# ② 横线
	page.add_child(HSeparator.new())

	# ③ 三级 tab：L2 横向（技能类型）→ L3 左侧纵向（该类下具体技能）→ 主内容页；右侧窄列＝已习得。
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 10)
	page.add_child(body)

	# 左区：上＝L2 横向 tab 行；中＝横线；下＝[L3 纵向 tab | 竖线 | 主内容]
	var left_area := VBoxContainer.new()
	left_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_area.add_theme_constant_override("separation", 4)   # 收紧 → 让位给计量条
	body.add_child(left_area)
	# L2 横向 tab 行——起始右移一截，避免与下方 L3 纵向 tab 同列混淆
	var tabrow := HBoxContainer.new()
	tabrow.add_theme_constant_override("separation", 6)
	var l2_indent := Control.new()
	l2_indent.custom_minimum_size = Vector2(92, 0)
	tabrow.add_child(l2_indent)
	left_area.add_child(tabrow)
	# 横线：把 L2 与下方内容分开（下方内容直接关联 L3 纵向 tab，L3 又关联 L2）
	left_area.add_child(HSeparator.new())

	var inner := HBoxContainer.new()
	inner.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inner.add_theme_constant_override("separation", 8)
	left_area.add_child(inner)
	# L3 列套滚动容器：图标放大后条目可能超高，纵向滚动兜底（不裁切）
	var l3scroll := ScrollContainer.new()
	l3scroll.custom_minimum_size = Vector2(90, 0)
	l3scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	l3scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inner.add_child(l3scroll)
	var l3col := VBoxContainer.new()          # L3：纵向具体技能 tab（随 L2 重建）
	l3col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l3col.add_theme_constant_override("separation", 4)
	l3scroll.add_child(l3col)
	inner.add_child(VSeparator.new())
	var main := VBoxContainer.new()           # 选中技能的内容页（待定）
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inner.add_child(main)

	# L2 横向 tab：切页 → 重建 L3 纵向 tab（重置到该页第一项）
	var grp2 := ButtonGroup.new()
	var l2btns := []
	for i in PROF_PAGES.size():
		var b := Button.new()
		b.text = str(PROF_PAGES[i][0])
		b.toggle_mode = true
		b.button_group = grp2
		b.custom_minimum_size = Vector2(0, 32)
		var idx := i
		b.pressed.connect(func():
			_prof_subtab = idx
			_prof_l3 = 0
			_rebuild_prof_l3(l3col, main, str(PROF_PAGES[idx][1]), u))
		l2btns.append(b)
		tabrow.add_child(b)

	body.add_child(VSeparator.new())

	# 右：窄列——全部已习得技艺（Unit.prof_known，熟练度高→低）
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(200, 0)
	right.size_flags_horizontal = Control.SIZE_SHRINK_END
	right.add_theme_constant_override("separation", 4)
	body.add_child(right)
	_section(right, "已习得")
	var rsc := ScrollContainer.new()
	rsc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	rsc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(rsc)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 3)
	rsc.add_child(list)
	_fill_learned_list(list, u)

	# 初始：按记住的 L2 选中 → 建 L3（clamp 记住的 L3）
	_prof_subtab = clampi(_prof_subtab, 0, PROF_PAGES.size() - 1)
	l2btns[_prof_subtab].button_pressed = true   # 程序化选中不触发 pressed
	_rebuild_prof_l3(l3col, main, str(PROF_PAGES[_prof_subtab][1]), u)
	return page

# 重建 L3 纵向 tab（当前页各技艺域，派生/异种按阶段浮现过滤 🔒），并显示选中域的内容页。
func _rebuild_prof_l3(l3col: VBoxContainer, main: VBoxContainer, page_key: String, u) -> void:
	for c in l3col.get_children():
		l3col.remove_child(c)
		c.queue_free()
	var ids := []
	for pid in ProfDB.ids_by_page(page_key):
		if u.prof_visible(str(pid)):
			ids.append(str(pid))
	if ids.is_empty():
		_fill_prof_main(main, "", u)
		return
	var grp := ButtonGroup.new()
	var btns := []
	for i in ids.size():
		var pid := str(ids[i])
		var b := Button.new()
		b.toggle_mode = true
		b.button_group = grp
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Vector2(0, 48)               # 加高 → 小图标(16×16)放大更可读
		b.tooltip_text = ProfDB.prof_name(pid)
		var tex = _prof_l3_icon(pid, page_key)
		if tex != null:
			b.icon = tex                                     # 有图标：图标居中撑满、像素硬边
			b.expand_icon = true
			b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
			b.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		else:
			b.text = ProfDB.prof_name(pid)                   # 无图标：退回文字
		var idx := i
		b.pressed.connect(func():
			_prof_l3 = idx
			_fill_prof_main(main, str(ids[idx]), u))
		btns.append(b)
		l3col.add_child(b)
	_prof_l3 = clampi(_prof_l3, 0, btns.size() - 1)
	btns[_prof_l3].button_pressed = true
	_fill_prof_main(main, str(ids[_prof_l3]), u)

# L3 tab 图标：约定 res://icons/Skills/SkillsTree-<page>/<域id去首段前缀>.png
# （wp_sword→SkillsTree-weapon/sword.png；style_one_handed→SkillsTree-style/one_handed.png）。
# 无对应文件返回 null → 调用处退回文字，随美术补图自动点亮。
func _prof_l3_icon(pid: String, page_key: String) -> Texture2D:
	var us := pid.find("_")
	var slug := pid.substr(us + 1) if us >= 0 else pid
	return TextureCache.get_tex("res://icons/Skills/SkillsTree-%s/%s.png" % [page_key, slug])

# 装载格行重填（editor_mode 点格换装/等级改动即时刷新共用；游戏内只读同走此口）
func _refresh_prof_slots(u) -> void:
	if _prof_slots_row == null or not is_instance_valid(_prof_slots_row):
		return
	for c in _prof_slots_row.get_children():
		c.queue_free()
	var cap: int = u.prof_slot_capacity()
	for i in PROF_CELL_COUNT:
		if i < u.prof_slots.size():
			var pid := str(u.prof_slots[i])
			var cb := Callable()
			if editor_mode:
				cb = func(): editor_unslot_prof(pid)
			_prof_slots_row.add_child(_prof_slot_unit({
				"name": ProfDB.prof_name(pid), "xp": int(u.prof_xp.get(pid, 0)),
				"icon": str(ProfDB.get_prof(pid).get("icon", "")),
				"tip": "点击卸载「%s」" % ProfDB.prof_name(pid) if editor_mode else ""}, cb))
		elif i < cap:
			var cb2 := Callable()
			if editor_mode:
				cb2 = func(): _popup_prof_pick()
			_prof_slots_row.add_child(_prof_slot_unit({"tip": "点击从已学习中装载" if editor_mode else ""}, cb2))
		else:
			_prof_slots_row.add_child(_prof_slot_unit({"locked": true, "lv": int(PROF_SLOT_LV[i])}))

# 空槽点击 → 已学习（known）且未装载的技艺选单；选中即装载（editor 烘焙路径 force 🔒 §6——
# 容量由「只有容量内空槽可点」保证，不再二次校验）
func _popup_prof_pick() -> void:
	if _unit == null:
		return
	var pm := PopupMenu.new()
	var ids := []
	for pid in _unit.prof_known:
		if not _unit.prof_slots.has(str(pid)):
			ids.append(str(pid))
	if ids.is_empty():
		pm.add_item("（无已学习可装载——右栏先添加已学习）")
		pm.set_item_disabled(0, true)
	else:
		for i in ids.size():
			var pid := str(ids[i])
			var disp := _prof_disp(int(_unit.prof_xp.get(pid, 0)))   # 显示名走面板口径（xp=0→入门，非"生疏"）
			pm.add_item("%s（%s）" % [ProfDB.prof_name(pid), str(disp["name"])], i)
			pm.set_item_metadata(pm.item_count - 1, pid)
		pm.index_pressed.connect(func(idx: int):
			editor_slot_prof(str(pm.get_item_metadata(idx))))
	add_child(pm)
	pm.popup_hide.connect(func(): pm.queue_free())
	pm.popup(Rect2i(Vector2i(get_global_mouse_position()), Vector2i(0, 0)))

# editor_mode 装载/卸载单口（点格换装消费；测试可直调）：改 _unit 后刷新槽行 + 通知宿主标脏
func editor_slot_prof(pid: String) -> bool:
	if _unit == null or not _unit.slot_prof(pid, true):
		return false
	_refresh_prof_slots(_unit)
	_emit_edit()
	return true

func editor_unslot_prof(pid: String) -> void:
	if _unit == null:
		return
	_unit.unslot_prof(pid)
	_refresh_prof_slots(_unit)
	_emit_edit()

# 一个装备技能格：VBox[ HBox(格 + 竖向计量槽), 下方「名-档位」]。
# d 有 name=已装载；d 空=（空槽，容量内未用）；d.locked=容量外未解锁（画 ✕，同物品栏锁定格）。
# on_click 有效＝可点（editor_mode 点格换装：手型光标 + d.tip 悬停提示）。
func _prof_slot_unit(d: Dictionary, on_click := Callable()) -> Control:
	var has := d.has("name")
	var locked := bool(d.get("locked", false))
	var xp := int(d.get("xp", 0))
	var tier := _prof_tier(xp)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	col.size_flags_vertical = Control.SIZE_SHRINK_BEGIN

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 5)
	if locked:
		# 未解锁格＝物品栏锁定格同款（暗底 + 居中 ✕）；右侧留等宽透明占位，保列与其它格对齐。
		var lc := _locked_slot(PROF_CELL_SIZE)
		lc.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		top.add_child(lc)
		var spacer := Control.new()
		spacer.custom_minimum_size = Vector2(PROF_GAUGE_W, 0)
		top.add_child(spacer)
	else:
		var cell := Panel.new()
		cell.custom_minimum_size = PROF_CELL_SIZE
		cell.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(1, 1, 1, 0.04)
		sb.set_corner_radius_all(4)
		sb.set_border_width_all(1)
		sb.border_color = Color(1, 1, 1, 0.22)
		cell.add_theme_stylebox_override("panel", sb)
		if on_click.is_valid():   # editor_mode 点格换装（空槽=装载选单 / 已装=卸载）
			cell.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			if str(d.get("tip", "")) != "":
				cell.tooltip_text = str(d["tip"])
			cell.gui_input.connect(func(ev):
				if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
					on_click.call())
		# 技艺图标（若域填了 icon 路径）：铺满格子留 4px 边距；未填=空格（名字在下方，图标你画好丢路径即显）。
		var icon_path := str(d.get("icon", ""))
		if has and icon_path != "":
			var tex = TextureCache.get_tex(icon_path)
			if tex != null:
				var tr := TextureRect.new()
				tr.texture = tex
				tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
				tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				tr.custom_minimum_size = PROF_CELL_SIZE
				tr.size = PROF_CELL_SIZE
				tr.offset_left = 4
				tr.offset_top = 4
				tr.offset_right = -4
				tr.offset_bottom = -4
				tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
				cell.add_child(tr)
		top.add_child(cell)
		var fill_col := Color(str(tier["color"])) if has else Color(1, 1, 1, 0.12)
		top.add_child(_prof_gauge(_prof_tier_progress(xp) if has else 0.0, fill_col))
	col.add_child(top)

	col.add_child(_prof_cell_label(d))
	return col

# 格子下方标签：宽度只对齐格子（不含计量槽）→ 文字居中于格子正下方。
# 已装载=「名-档位」（档位随色）；空槽=（空槽）；未解锁=Lv.N（去「解锁」二字，✕ 已在格内表意）。
func _prof_cell_label(d: Dictionary) -> Control:
	var h := HBoxContainer.new()
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	h.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN   # 贴格子左对齐、不被拉到含计量槽的整列宽
	h.custom_minimum_size = Vector2(PROF_CELL_SIZE.x, 0)
	if not d.has("name"):
		var e := Label.new()
		e.text = ("Lv.%d" % int(d.get("lv", 0))) if d.get("locked", false) else "（空槽）"
		e.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		e.custom_minimum_size = Vector2(PROF_CELL_SIZE.x, 0)
		e.add_theme_color_override("font_color", Color(1, 1, 1, 0.3))
		e.add_theme_font_size_override("font_size", PROF_FONT_CELL)
		h.add_child(e)
		return h
	var disp := _prof_disp(int(d.get("xp", 0)))   # 装载格必已学习（slot_prof 有 known 门槛）→ 入门/娴熟/…
	var nm := Label.new()
	nm.text = str(d.get("name", "")) + "-"
	nm.add_theme_font_size_override("font_size", PROF_FONT_CELL)
	h.add_child(nm)
	var tl := Label.new()
	tl.text = str(disp["name"])
	tl.add_theme_color_override("font_color", Color(str(disp["color"])))
	tl.add_theme_font_size_override("font_size", PROF_FONT_CELL)
	h.add_child(tl)
	return h

# 竖向计量槽：暗底 Panel + 填充 ColorRect（锚定底部，高度 = ratio × 满高 → 自底向上；色随档位）。
func _prof_gauge(ratio: float, color: Color) -> Control:
	var track := Panel.new()
	track.custom_minimum_size = Vector2(PROF_GAUGE_W, PROF_CELL_SIZE.y)
	track.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var tb := StyleBoxFlat.new()
	tb.bg_color = PROF_GAUGE_TRACK
	tb.set_corner_radius_all(3)
	track.add_theme_stylebox_override("panel", tb)
	var fill := ColorRect.new()
	fill.color = color
	fill.anchor_left = 0.0
	fill.anchor_right = 1.0
	fill.anchor_top = 1.0 - clampf(ratio, 0.0, 1.0)
	fill.anchor_bottom = 1.0
	fill.offset_left = 1
	fill.offset_right = -1
	fill.offset_bottom = -1
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	track.add_child(fill)
	return track

# 右侧「已习得」窄列：Unit.prof_known 全量，按熟练度高→低。
func _fill_learned_list(list: VBoxContainer, u) -> void:
	for c in list.get_children():
		list.remove_child(c)
		c.queue_free()
	var arr := []
	for pid in u.prof_known:
		arr.append({"name": ProfDB.prof_name(str(pid)), "xp": int(u.prof_xp.get(str(pid), 0))})
	arr.sort_custom(func(a, b): return int(a.get("xp", 0)) > int(b.get("xp", 0)))   # 熟练度高→低
	if arr.is_empty():
		var e := Label.new()
		e.text = "（暂无）"
		e.add_theme_color_override("font_color", Color(1, 1, 1, 0.3))
		e.add_theme_font_size_override("font_size", PROF_FONT_LIST)
		list.add_child(e)
		return
	for d in arr:
		list.add_child(_learned_row(d))

# 一行：名（常色）+ 档位（含 xp 值，色随档位）——紧挨不拉远。
func _learned_row(d: Dictionary) -> Control:
	var xp := int(d.get("xp", 0))
	var disp := _prof_disp(xp)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	var nm := Label.new()
	nm.text = str(d.get("name", ""))
	nm.add_theme_font_size_override("font_size", PROF_FONT_LIST)
	nm.custom_minimum_size = Vector2(78, 0)
	h.add_child(nm)
	var t := Label.new()
	t.text = "%s（%d）" % [str(disp["name"]), xp]
	t.add_theme_font_size_override("font_size", PROF_FONT_LIST)
	t.add_theme_color_override("font_color", Color(str(disp["color"])))
	h.add_child(t)
	return h

# 主内容区（选中 L3 技艺域）：头（域名 + 状态） + 脊柱式技能树（ProfTreeView）。
func _fill_prof_main(main: VBoxContainer, pid: String, u) -> void:
	for c in main.get_children():
		main.remove_child(c)
		c.queue_free()
	if pid == "":
		var e := Label.new()
		e.text = "（本页暂无可见技能）"
		e.add_theme_color_override("font_color", Color(1, 1, 1, 0.35))
		main.add_child(e)
		return
	var def := ProfDB.get_prof(pid)
	var known: bool = u.prof_known.has(pid)
	var xp := int(u.prof_xp.get(pid, 0))
	# 头：域名 + 状态（未学 / 档位·装载）
	var hdr := HBoxContainer.new()
	hdr.add_theme_constant_override("separation", 10)
	var title := Label.new()
	title.text = "%s%s" % [str(def.get("name", pid)), "（异种）" if def.get("exotic", false) else ""]
	title.add_theme_font_size_override("font_size", 17)
	title.add_theme_color_override("font_color", Color("#EBBC04"))
	hdr.add_child(title)
	var disp := _prof_disp(xp, known)   # 已学习→入门/娴熟/…（未学习不在标题重复：计量条底部已示）
	var st := Label.new()
	st.text = "" if not known else "%s%s" % [str(disp["name"]), "　·　已装载" if u.prof_slots.has(pid) else ""]
	st.add_theme_color_override("font_color", Color(str(disp["color"])))
	st.add_theme_font_size_override("font_size", 13)
	st.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hdr.add_child(st)
	main.add_child(hdr)
	# 脊柱式技能树（🟡 占位；读真 xp/档位，perk/奖励数据待接）
	var tree := ProfTreeView.new()
	tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_child(tree)
	tree.setup(xp, known)

# ============ 脊柱式技能树视图（🟡 占位）============
# 中轴＝熟练度计量条（自底向上填 + 每100小刻度 + 档位边界大刻度 + 底部当前档位）；
# 左＝各阶段固定奖励（1/阶，装备该技能时激活）；右＝各阶段 perk（多/阶，四选一）。均小图标格 + tooltip。
# 行按 4 次进阶等距排布（不与大刻度对齐——各阶所需熟练度不等，刻度本就不均匀）；未达阶段压暗。
# ⚠️ 奖励/perk 数据未接（proficiencies.json 后加池）；本类只搭视觉、读真 xp。
class ProfTreeView extends Control:
	# {name,lo,hi,color}；首段＝入门(白)；未学习（不在 prof_known）另显深灰——判据=known，非 xp==0。
	const TIERS := [
		{"name": "入门", "lo": 0,    "hi": 100,  "color": "#E0E0E0"},
		{"name": "娴熟", "lo": 101,  "hi": 300,  "color": "#4FAE5A"},
		{"name": "老练", "lo": 301,  "hi": 600,  "color": "#3A7BD5"},
		{"name": "专家", "lo": 601,  "hi": 1000, "color": "#9B59B6"},
		{"name": "大师", "lo": 1001, "hi": 1500, "color": "#EBBC04"},
	]
	const MAXXP := 1500
	const MAJORS := [100, 300, 600, 1000]   # 档位边界大刻度（顶端 1500 单独画）
	const BAR_W := 11                        # 计量条宽（原 16 → 约 2/3）
	const TOP_PAD := 2                        # 顶留白收窄 → 计量条更长
	const BOT_PAD := 38                       # 底部留给当前档位标签
	const BOX := 40                          # 奖励/perk 小图标格
	const GAP := 8
	const ARM := 16                          # 中轴到格子的连线臂长
	const PERKS := 3                         # 占位：每阶右侧 perk 数

	var xp := 0
	var known := false
	var reached := 1                         # 当前阶段序号 1..5（=TIERS 索引+1）

	func setup(_xp: int, _known: bool) -> void:
		xp = clampi(_xp, 0, MAXXP)
		known = _known
		reached = 1
		for i in TIERS.size():
			if xp >= int(TIERS[i]["lo"]):
				reached = i + 1
		_rebuild()

	func _ready() -> void:
		resized.connect(_relayout)

	func _rebuild() -> void:
		for c in get_children():
			c.queue_free()
		# 各进阶行的 perk 格交错分布：显示自上而下＝左·右·左·右（大师在上）；
		# 格子所在侧的对侧＝该阶段「加成」文本位（数据待接，暂空、不占格）。
		for row in 4:
			var ti := row + 1                # TIERS 索引：娴熟=1 … 大师=4
			var unlocked := xp > 0 and reached >= ti + 1
			var col := Color(str(TIERS[ti]["color"]))
			var side := "L" if row % 2 == 1 else "R"   # 大师(左)·专家(右)·老练(左)·娴熟(右)
			for k in PERKS:
				add_child(_box(side, row, k, "%s perk —— 待定" % str(TIERS[ti]["name"]), unlocked, col))
		_relayout.call_deferred()

	func _box(side: String, row: int, slot: int, tip: String, unlocked: bool, col: Color) -> Panel:
		var p := Panel.new()
		p.custom_minimum_size = Vector2(BOX, BOX)
		p.size = Vector2(BOX, BOX)
		p.tooltip_text = tip
		p.set_meta("side", side)
		p.set_meta("row", row)
		p.set_meta("slot", slot)
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.03, 0.04, 0.07, 0.72)   # 深底 → 与窗口背景对比、可见度更高
		sb.set_corner_radius_all(4)
		sb.set_border_width_all(2 if unlocked else 1)
		sb.border_color = col if unlocked else Color(1, 1, 1, 0.16)
		p.add_theme_stylebox_override("panel", sb)
		p.modulate = Color(1, 1, 1, 1.0 if unlocked else 0.45)
		return p

	func _row_cy(row: int) -> float:
		var top := float(TOP_PAD)
		var bot := size.y - BOT_PAD
		# row0=娴熟(最低阶)在下、row3=大师(最高阶)在上 —— 与「熟练度自底向上涨」一致
		return top + ((3 - row) + 0.5) / 4.0 * maxf(1.0, bot - top)

	func _relayout() -> void:
		var cx := size.x * 0.5
		for c in get_children():
			if not (c is Panel):
				continue
			var row := int(c.get_meta("row", 0))
			var side := str(c.get_meta("side", "R"))
			var slot := int(c.get_meta("slot", 0))
			var cy := _row_cy(row) - BOX * 0.5
			var x := 0.0
			if side == "L":
				x = cx - BAR_W * 0.5 - ARM - BOX * (slot + 1) - GAP * slot
			else:
				x = cx + BAR_W * 0.5 + ARM + slot * (BOX + GAP)
			c.position = Vector2(x, cy)
		queue_redraw()

	func _draw() -> void:
		var cx := size.x * 0.5
		var bar_top := float(TOP_PAD)
		var bar_bot := size.y - BOT_PAD
		var barh := maxf(1.0, bar_bot - bar_top)
		draw_rect(Rect2(cx - BAR_W * 0.5, bar_top, BAR_W, barh), Color(0.03, 0.04, 0.07, 0.82), true)   # 轨道（深底：衬托填充、对比窗口背景）
		if xp > 0:   # 填充（自底向上，当前档位色）
			var fh := barh * clampf(float(xp) / float(MAXXP), 0.0, 1.0)
			draw_rect(Rect2(cx - BAR_W * 0.5, bar_bot - fh, BAR_W, fh), Color(str(TIERS[reached - 1]["color"])), true)
		for row in 4:   # 每行中轴 → 该阶格子侧的连线（交错：左/右）
			var cy := _row_cy(row)
			var ti := row + 1
			var lc := Color(str(TIERS[ti]["color"]))
			lc.a = 0.35 if (xp > 0 and reached >= ti + 1) else 0.12
			if row % 2 == 1:   # 左
				draw_line(Vector2(cx - BAR_W * 0.5, cy), Vector2(cx - BAR_W * 0.5 - ARM, cy), lc, 2.0)
			else:              # 右
				draw_line(Vector2(cx + BAR_W * 0.5, cy), Vector2(cx + BAR_W * 0.5 + ARM, cy), lc, 2.0)
		for v in range(100, MAXXP, 100):   # 刻度：每100小刻度；档位边界大刻度（该边界之上档位色）
			var ty := bar_bot - barh * (float(v) / MAXXP)
			var is_major: bool = v in MAJORS
			var ext := (BAR_W * 0.5) if is_major else (BAR_W * 0.5 - 2.0)   # 刻度不超过条宽：大刻度=满宽、小刻度略内缩
			var tcol := Color(1, 1, 1, 0.2)
			if is_major:
				tcol = Color(1, 1, 1, 0.5)
				for t in TIERS:
					if int(t["lo"]) == v + 1:
						tcol = Color(str(t["color"]))
			draw_line(Vector2(cx - ext, ty), Vector2(cx + ext, ty), tcol, 2.0 if is_major else 1.0)
		draw_line(Vector2(cx - BAR_W * 0.5, bar_top), Vector2(cx + BAR_W * 0.5, bar_top), Color(str(TIERS[4]["color"])), 2.0)   # 顶端 1500 大师满（满宽）
		var font := get_theme_default_font()
		if font != null:   # 底部当前档位（自底往上涨 → 精通阶段写最下）
			var nm := "未学习" if not known else str(TIERS[reached - 1]["name"])
			var col := Color("#808080") if not known else Color(str(TIERS[reached - 1]["color"]))
			draw_string(font, Vector2(cx - 60, size.y - BOT_PAD + 22), nm, HORIZONTAL_ALIGNMENT_CENTER, 120, 16, col)
			if known:
				draw_string(font, Vector2(cx - 60, size.y - BOT_PAD + 35), "%d / %d" % [xp, MAXXP], HORIZONTAL_ALIGNMENT_CENTER, 120, 11, Color(1, 1, 1, 0.45))

# 右上属性区（重排中·先放核心两条）：血量 / 护甲值 —— 图标 + 横向计量条（叠当前/上限）。
# 构件 _cell / _cell_cm / _two（读 effective_stat、按修正染色、悬停 tooltip）保留待复用。
const ICON_DIR := "res://icons/UI/stat/"

func _build_stats(right: VBoxContainer, u) -> void:
	# 右区再左右均分：左＝血量/护甲/士气计量条；中间竖线；右＝留白（待续排）。
	var split := HBoxContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_theme_constant_override("separation", 16)
	right.add_child(split)
	var col_l := VBoxContainer.new()
	col_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL   # 左半（ratio 1）
	col_l.add_theme_constant_override("separation", 8)
	split.add_child(col_l)
	split.add_child(VSeparator.new())
	var col_r := VBoxContainer.new()
	col_r.size_flags_horizontal = Control.SIZE_EXPAND_FILL   # 右半（ratio 1）＝修正属性列（🔒 2026-07-08 用户定布局）
	col_r.add_theme_constant_override("separation", 6)
	split.add_child(col_r)
	_build_derived_col(col_r, u)
	# 血量/护甲＝读 stats（有 _max 上限）；士气＝Unit.morale（0..MORALE_MAX），图标随区间取 flag1-5。
	col_l.add_child(_stat_bar_row(float(u.effective_stat("HP")), u.effective_stat_f("HP_max"),
		ICON_DIR + "HP_16x16.png", Color("#9A2E22")))            # 血量＝深红
	col_l.add_child(_stat_bar_row(float(u.effective_stat("armor")), u.effective_stat_f("armor_max"),
		ICON_DIR + "护甲值_16x16.png", Color("#66707A")))          # 护甲＝深钢灰
	col_l.add_child(_stat_bar_row(float(u.morale), float(u.MORALE_MAX),
		_morale_icon(int(u.morale)), _morale_color(int(u.morale), int(u.MORALE_MAX))))   # 士气＝红→绿线性
	# 绿区：计量条下方＝面板五行（🔒 用户定序：移动力/物理抗性/自然抗性/肉体强韧/意志强韧；百分比语义带 %）
	col_l.add_child(HSeparator.new())
	for key in ["move", "res_phys", "res_nature", "body_fort", "will_fort"]:
		var suffix := "%" if StatMeta.is_pct(key) else ""
		col_l.add_child(_stat_kv_row(StatMeta.label(key), str(u.effective_stat(key)) + suffix))

# ============ 属性三区（🔒 2026-07-08 用户定布局）============
# 蓝区（头像右侧）＝四属性 技巧/灵活/决心/运气（加点 [+] 整合在行尾，attr_picks>0 才出、战斗锁定）；
# 绿区（计量条下）＝移动力/双抗/双韧；右列＝修正属性（结算口径合成值）。图标缺失（决心待画）静默空位。
const ATTR_PICK_ICONS := {"finesse": "技巧_16x16.png", "agility": "灵活_16x16.png",
	"luck": "幸运_16x16.png", "resolve": "决心_16x16.png"}

# 小字键值行：可选 16px 像素图标 + 左名右值
func _stat_kv_row(label_text: String, value_text: String, icon_file := "") -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	if icon_file != "":
		var icon := TextureRect.new()
		icon.texture = TextureCache.get_tex(ICON_DIR + icon_file)
		icon.custom_minimum_size = Vector2(18, 18)
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(icon)
	var lab := Label.new()
	lab.text = label_text
	lab.add_theme_font_size_override("font_size", 13)
	lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lab)
	var val := Label.new()
	val.text = value_text
	val.add_theme_font_size_override("font_size", 13)
	row.add_child(val)
	return row

# 蓝区：四属性列（🔒 用户定序 技巧/灵活/决心/运气）
func _attr_col(u) -> Control:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.add_theme_constant_override("separation", 6)
	var picks := int(u.attr_picks)
	var in_battle: bool = host != null and "phase" in host and str(host.phase) == "battle"
	if picks > 0:
		var head := Label.new()
		head.text = "属性点 ×%d%s" % [picks, "（战斗中锁定）" if in_battle else ""]
		head.add_theme_font_size_override("font_size", 12)
		head.add_theme_color_override("font_color", Color("#EBBC04"))
		col.add_child(head)
	for key in ["finesse", "agility", "resolve", "luck"]:
		var row := _stat_kv_row(StatMeta.label(key), str(u.effective_stat(key)), str(ATTR_PICK_ICONS.get(key, "")))
		if picks > 0:
			var btn := Button.new()
			btn.text = "＋"
			btn.custom_minimum_size = Vector2(26, 0)
			btn.disabled = in_battle or not u.can_attr_pick(key)
			btn.tooltip_text = "战斗中锁定（一切结算战后进行）" if in_battle \
				else "花 1 点：%s +1（可双点同投）" % StatMeta.label(key)
			var k := str(key)
			btn.pressed.connect(func():
				if u.apply_attr_pick(k):
					open(u))   # 重建面板：数值/剩余点数/按钮灰显一并刷新
			row.add_child(btn)
		col.add_child(row)
	return col

# 右列：修正属性（武器/装备/修正全叠加后的结算口径；格挡两行＝武器/盾面板承载，人身底 0 🔒）
func _build_derived_col(col: VBoxContainer, u) -> void:
	var head := Label.new()
	head.text = "修正属性"
	head.add_theme_font_size_override("font_size", 12)
	head.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	col.add_child(head)
	col.add_child(_stat_kv_row("命中率", _fmt1(u.effective_stat_f("acc") + u.effective_stat_f("finesse") + u.morale_combat_mod()) + "%"))   # 含士气档位平加（🔒 §10.7）
	col.add_child(_stat_kv_row("闪避率", _fmt1(u.effective_stat_f("eva") + u.effective_stat_f("agility")) + "%"))
	col.add_child(_stat_kv_row("暴击率", _fmt1(u.effective_stat_f("crit_rate") + u.effective_stat_f("finesse") * 0.5) + "%"))
	col.add_child(_stat_kv_row("暴击伤害", _fmt1(u.effective_stat_f("crit_dmg") + u.effective_stat_f("luck") * 0.5) + "%"))
	col.add_child(_stat_kv_row("暴击防御", _fmt1(u.effective_stat_f("luck")) + "%"))   # 运气压对方暴击（−1%/点）
	col.add_child(_stat_kv_row("格挡率", _fmt1(u.effective_stat_f("block_rate")) + "%"))
	col.add_child(_stat_kv_row("格挡性能", _fmt1(u.effective_stat_f("block_power")) + "%"))

func _fmt1(v: float) -> String:
	return str(int(v)) if is_equal_approx(v, floorf(v)) else String.num(v, 1)

# 士气图标：按当前值五档 → flag1-5（<10 / 10-19 / 20-29 / 30-39 / ≥40）；与 Unit.morale_band() 一致，默认 25 落 flag3。
func _morale_icon(morale: int) -> String:
	var n := 1
	if morale >= 40: n = 5
	elif morale >= 30: n = 4
	elif morale >= 20: n = 3
	elif morale >= 10: n = 2
	return ICON_DIR + "flag%d_16x16.png" % n

# 士气条色：随值线性 红(0)→绿(满)——走 HSV 色相插值（红→黄→绿），比 RGB 直插好看。
func _morale_color(morale: int, mmax: int) -> Color:
	var t := clampf(float(morale) / float(maxi(1, mmax)), 0.0, 1.0)
	return Color.from_hsv(lerpf(0.0, 0.33, t), 0.72, 0.66)

# 一条「图标 + 横向计量条」：条内右对齐叠「当前 / 上限」；深底 + 指定色填充（同技能页深槽调性）。
func _stat_bar_row(cur: float, max_raw: float, icon_path: String, fill_color: Color) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var icon := TextureRect.new()
	icon.texture = TextureCache.get_tex(icon_path)
	icon.custom_minimum_size = Vector2(22, 22)                    # 16×16 源放大（小图标）
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST       # 像素图硬边
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon)

	var has := max_raw > 0.0                                      # 无上限（如无护甲）→ -- / --、条空
	var mx := maxf(1.0, max_raw)

	# 外框＝黑色粗边框 + 深底；内部计量条内缩。ProgressBar 自身 fill 会满高从左画、盖住背景边框，
	# 故不给条本体设边框，改套一层带边框的 PanelContainer，条内缩其中 → 填充绝不触边框。
	var frame := PanelContainer.new()
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var fb := StyleBoxFlat.new()
	fb.bg_color = Color(0.03, 0.04, 0.07, 0.82)                   # 深底
	fb.border_color = Color(0, 0, 0, 1)                          # 纯黑粗边框
	fb.set_border_width_all(2)
	fb.set_corner_radius_all(3)
	fb.set_content_margin_all(2)                                  # 内缩 → 内部条不触边框
	frame.add_theme_stylebox_override("panel", fb)
	row.add_child(frame)

	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(0, 4)                       # 条最低高；实高由数值字高撑起（见下）
	bar.size_flags_horizontal = Control.SIZE_FILL
	bar.size_flags_vertical = Control.SIZE_FILL                   # 撑满外框内容区（否则只按最低高画成细线）
	bar.min_value = 0
	bar.max_value = mx
	bar.value = clampf(cur, 0.0, mx) if has else 0.0
	bar.show_percentage = false
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0, 0, 0, 0)                            # 透明（深底由外框提供）
	bar.add_theme_stylebox_override("background", track)
	var fill := StyleBoxFlat.new()
	fill.bg_color = fill_color
	fill.set_corner_radius_all(1)
	bar.add_theme_stylebox_override("fill", fill)
	frame.add_child(bar)

	# 数值：作 frame 的第二个子节点（与条同区叠放、画在上层）；其字高撑起外框 →
	# 文字在边框内上下自然居中（不再塞进定高条里被顶到下边框）。
	var txt_color := Color(1, 1, 1, 0.96 if has else 0.4)
	var val := Label.new()
	val.text = ("%s / %s" % [_fmt(cur), _fmt(max_raw)]) if has else "-- / --"
	val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val.add_theme_font_size_override("font_size", 15)
	val.add_theme_color_override("font_color", txt_color)
	val.add_theme_constant_override("outline_size", 2)          # 伪加粗：同色描边加粗字形
	val.add_theme_color_override("font_outline_color", txt_color)
	val.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_child(val)
	return row

# ============ 下半三列 ============

# 左下：装备槽（占位——待 equipment.json + 修正管线接入）。
# 六槽 2×3：主手/头盔/饰品 ・ 副手/防具/饰品；正方形格 + 名称在格下。
# id 用 set_meta 存着，将来绑真实装备直接按 slot_id 取。
const EQUIP_SLOTS := [
	{"id": "main_hand", "label": "主手"},
	{"id": "head", "label": "头部"},
	{"id": "accessory_1", "label": "饰品"},
	{"id": "off_hand", "label": "副手"},
	{"id": "body", "label": "身体"},
	{"id": "accessory_2", "label": "饰品"},
]

func _build_equip(parent: VBoxContainer, u) -> void:
	# 抬头：「装备」金标题（左） + 右上角信息角标（悬停出「装备加成总计」tooltip）
	var header := HBoxContainer.new()
	var title := Label.new()
	title.text = "装备"
	title.add_theme_color_override("font_color", Color("#EBBC04"))
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(title)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(sp)
	header.add_child(_equip_summary_badge(u))
	parent.add_child(header)

	var grid := GridContainer.new()
	grid.columns = 3
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER   # 整组槽位在本列内居中
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 10)
	parent.add_child(grid)
	for s in EQUIP_SLOTS:
		grid.add_child(_equip_cell(u, s["label"], s["id"]))

# 装备区右上角信息角标：金色「数据统计ⓘ」文本，悬停出「装备加成总计」富 tooltip（复用 ItemSlot 自定义 tooltip 机制）。
func _equip_summary_badge(u) -> Control:
	var host := ItemSlot.new()
	host.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	host.mouse_filter = Control.MOUSE_FILTER_STOP    # 默认箭头光标，不作可点击提示
	host.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	host.item = u                                   # tooltip_builder 收到的即当前单位
	host.tooltip_builder = _build_equip_summary_tooltip
	host.tooltip_text = "装备加成总计"                # 非空才会触发 tooltip
	var icon := Label.new()
	icon.text = "数据统计ⓘ"
	icon.add_theme_color_override("font_color", Color("#EBBC04"))   # 与左侧「装备」同色同字号（均用主题默认字号）
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host.add_child(icon)
	return host

# 聚合当前所有装备提供的修正：取 source 前缀 "equip:" 的修正，按 (stat, op) 合并求和；保持首次出现顺序。
func _aggregate_equip_mods(u) -> Array:
	var order := []
	var sums := {}
	for m in u.modifiers:
		if not str(m.get("source", "")).begins_with("equip:"):
			continue
		if str(m.get("stat", "")) == "vision_state":
			continue   # 视觉状态＝非数值状态旗，不进「装备加成总计」（角色面板不显示）
		var stat := str(m.get("stat", ""))
		var op := str(m.get("op", "flat"))
		var k := stat + "|" + op
		if not sums.has(k):
			sums[k] = {"stat": stat, "op": op, "value": 0.0}
			order.append(k)
		sums[k]["value"] += float(m.get("value", 0))
	var out := []
	for k in order:
		out.append(sums[k])
	return out

# 「装备加成总计」富 tooltip：黑底 + 金边；标题 + 各装备加成合并后的绿/红数值行（无则提示）。
func _build_equip_summary_tooltip(u) -> Control:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 1)
	sb.border_color = Color("#EBBC04")
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 5)
	panel.add_child(v)
	var title := Label.new()
	title.text = "装备加成总计"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color("#EBBC04"))
	v.add_child(title)
	v.add_child(HSeparator.new())
	var agg := _aggregate_equip_mods(u)
	if agg.is_empty():
		var none := Label.new()
		none.text = "（当前无装备加成）"
		none.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
		v.add_child(none)
	else:
		for m in agg:
			v.add_child(ItemTooltip.mod_line(m, 15))
	return panel

# 单个装备槽：正方形空格（已装备则放物品图标）+ 下方名称（居中）
func _equip_cell(u, slot_label: String, slot_id: String) -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	var box := _slot_box(Vector2(56, 56))
	box.set_meta("slot_id", slot_id)
	box.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_fill_equip_slot(box, u, slot_id)
	if editor_mode:                       # 点槽 → 宿主开物品选择器（按 slot 筛选）
		box.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		box.gui_input.connect(_on_equip_slot_input.bind(slot_id))
	elif _can_interact(u):                # 穿卸交互：点出菜单 / 拖出 / 接拖放
		box.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		box.gui_input.connect(_on_equip_cell_click.bind(u, slot_id))
		var iuid := int(u.equipment.get(slot_id, 0))
		var it = ItemInstances.view(iuid)
		if it != null and not it.get("innate", false):
			box.drag_payload = {"kind": "equip", "slot": slot_id}
		box.can_drop = func(p): return _equip_drop_ok(u, slot_id, p)
		box.on_drop = func(p): _do_equip_drop(u, slot_id, p)
	v.add_child(box)
	var l := Label.new()
	l.text = slot_label
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(l)
	return v

# ============ 穿卸交互（游戏内；费用闸在宿主——战斗中 1 AP）============

func _can_interact(u) -> bool:
	return equip_interact and not editor_mode and u != null and u.faction == "player"

# 动作三段式：①资格（宿主闸 commit=false，战斗中＝当前行动者且 AP≥1）②执行（模型 API，失败零扣费）③扣费+刷新
func _try_equip_action(u, act: Callable) -> void:
	if not _can_interact(u):
		return
	if on_equip_gate.is_valid() and not bool(on_equip_gate.call(u, false)):
		return
	if not bool(act.call()):
		return
	if on_equip_gate.is_valid():
		on_equip_gate.call(u, true)
	open(_unit)   # 整卡重建（tab/页态保持）
	if on_equipment_changed.is_valid():
		on_equipment_changed.call()

func _gate_ok(u) -> bool:
	return not on_equip_gate.is_valid() or bool(on_equip_gate.call(u, false))

# 战斗中资格不满足（非本单位回合/AP 不足）→ 单条灰显提示菜单（拖放路径静默拒即可，点击要有反馈）
func _popup_gate_denied() -> void:
	var menu := _get_equip_menu()
	menu.clear()
	menu.add_item("整备不可（需本单位行动回合且 AP≥1）", 99)
	menu.set_item_disabled(0, true)
	_popup_equip_menu(menu, func(_id): pass)

# 右键装备槽 → 动作菜单：卸下（背包满灰显）/ 单手武器换手
# 🔒 交互分工（用户 2026-07-12）：左键＝拖拽/选中（菜单若挂左键会抢输入、拖拽启动不了），右键＝上下文菜单。
func _on_equip_cell_click(event: InputEvent, u, slot_id: String) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT):
		return
	if get_viewport().gui_is_dragging():
		return
	var iuid := int(u.equipment.get(slot_id, 0))
	var it = ItemInstances.view(iuid)
	if it == null or it.get("innate", false):
		return
	if not _gate_ok(u):
		_popup_gate_denied()
		return
	var menu := _get_equip_menu()
	menu.clear()
	menu.add_item("卸下（放入背包）", 0)
	if u.bag.size() >= u.BAG_CAP:
		menu.set_item_disabled(0, true)
		menu.set_item_text(0, "卸下（背包已满）")
	if slot_id in ["main_hand", "off_hand"] and not it.get("two_handed", false):
		var to := "off_hand" if slot_id == "main_hand" else "main_hand"
		menu.add_item("转移到" + ("副手" if to == "off_hand" else "主手"), 1)
		if not EquipSlots.accepts(to, it):
			menu.set_item_disabled(menu.item_count - 1, true)
	var cb := func(id: int) -> void:
		match id:
			0: _try_equip_action(u, func(): return u.unequip_to_bag(slot_id))
			1:
				var to2 := "off_hand" if slot_id == "main_hand" else "main_hand"
				_try_equip_action(u, func(): return u.transfer_hand(slot_id, to2))
	_popup_equip_menu(menu, cb)

# 右键背包件 → 装备菜单：默认槽装备 / 单手武器可选副手（左键拖拽右键菜单，同上）
func _on_bag_item_click(event: InputEvent, u, iuid: int) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT):
		return
	if get_viewport().gui_is_dragging():
		return
	var it = ItemInstances.view(iuid)
	if it == null:
		return
	if not _gate_ok(u):
		_popup_gate_denied()
		return
	var menu := _get_equip_menu()
	menu.clear()
	menu.add_item("装备", 0)
	if str(it.get("slot", "")) == "main_hand" and not it.get("two_handed", false) and EquipSlots.accepts("off_hand", it):
		menu.add_item("装备到副手", 1)
	var cb := func(id: int) -> void:
		match id:
			0: _try_equip_action(u, func(): return u.equip_from_bag(iuid))
			1: _try_equip_action(u, func(): return u.equip_from_bag(iuid, "off_hand"))
	_popup_equip_menu(menu, cb)

func _get_equip_menu() -> PopupMenu:
	if _equip_menu == null or not is_instance_valid(_equip_menu):
		_equip_menu = PopupMenu.new()
		add_child(_equip_menu)
	# 旧连接清干净（懒建复用，回调随点击换）
	for c in _equip_menu.id_pressed.get_connections():
		_equip_menu.id_pressed.disconnect(c["callable"])
	return _equip_menu

func _popup_equip_menu(menu: PopupMenu, cb: Callable) -> void:
	menu.id_pressed.connect(cb, CONNECT_ONE_SHOT)
	menu.position = Vector2i(get_global_mouse_position())
	menu.popup()

# —— 拖放判定/执行（策略层；ItemSlot 只做管道）——
# 装备槽收：bag 件（装备到本槽）/ equip 件（主↔副换手）
func _equip_drop_ok(u, slot_id: String, p) -> bool:
	if typeof(p) != TYPE_DICTIONARY or not _can_interact(u):
		return false
	if on_equip_gate.is_valid() and not bool(on_equip_gate.call(u, false)):
		return false
	match str(p.get("kind", "")):
		"bag":
			var it = ItemInstances.view(int(p.get("iuid", 0)))
			return it != null and EquipSlots.accepts(slot_id, it) \
				and not (it.get("two_handed", false) and slot_id == "off_hand")
		"equip":
			var from := str(p.get("slot", ""))
			return from != slot_id and from in ["main_hand", "off_hand"] and slot_id in ["main_hand", "off_hand"]
	return false

func _do_equip_drop(u, slot_id: String, p) -> void:
	match str(p.get("kind", "")):
		"bag":
			_try_equip_action(u, func(): return u.equip_from_bag(int(p.get("iuid", 0)), slot_id))
		"equip":
			_try_equip_action(u, func(): return u.transfer_hand(str(p.get("slot", "")), slot_id))

# 背包格收：equip 件（卸下入包）
func _bag_drop_ok(u, p) -> bool:
	if typeof(p) != TYPE_DICTIONARY or str(p.get("kind", "")) != "equip" or not _can_interact(u):
		return false
	if u.bag.size() >= u.BAG_CAP:
		return false
	if on_equip_gate.is_valid() and not bool(on_equip_gate.call(u, false)):
		return false
	var it = ItemInstances.view(int(u.equipment.get(str(p.get("slot", "")), 0)))
	return it != null and not it.get("innate", false)

func _do_bag_drop(u, p) -> void:
	_try_equip_action(u, func(): return u.unequip_to_bag(str(p.get("slot", ""))))

# 编辑器：点装备槽 → 回调宿主开选择器（左键）
func _on_equip_slot_input(event: InputEvent, slot_id: String) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if on_equip_slot.is_valid():
			on_equip_slot.call(slot_id)

# 槽内已装备 → 按稀有度上色边框 + 叠物品图标；双手武器占用的副手槽（非主槽）→ 灰色滤镜
func _fill_equip_slot(box: Control, u, slot_id: String) -> void:
	var iuid := int(u.equipment.get(slot_id, 0))
	if iuid == 0:
		if editor_mode:                   # 空槽在编辑器里显示淡「＋」，示意可点选
			var plus := Label.new()
			plus.text = "＋"
			plus.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			plus.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			plus.add_theme_color_override("font_color", Color(1, 1, 1, 0.30))
			plus.add_theme_font_size_override("font_size", 22)
			plus.mouse_filter = Control.MOUSE_FILTER_IGNORE
			box.add_child(plus)
		return
	var item = ItemInstances.view(iuid)
	if item == null:
		return
	# 富 tooltip（名称/标签/数值/技能…）
	box.item = item
	box.tooltip_builder = _build_item_tooltip
	box.tooltip_text = str(item.get("name", ""))   # 非空才会触发 tooltip
	# 稀有度 → 槽位边框色（专属/特殊=红）
	var rc = _rarity_color(item)
	if rc != null:
		var sb = box.get_theme_stylebox("panel")
		if sb is StyleBoxFlat:
			sb.border_color = rc
			sb.set_border_width_all(2)
	var tex = TextureCache.get_tex(str(item.get("icon", "")))   # 复用通用纹理加载
	if tex == null:
		return
	var ic := TextureRect.new()
	ic.texture = tex
	ic.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if item.get("two_handed", false) and slot_id != str(item.get("slot", "")):
		ic.modulate = Color(0.45, 0.45, 0.45)   # 双手武器的副手：灰
	box.add_child(ic)

# 中下：物品栏。实画 4×4，前 BAG_USABLE 个可用（＝Unit.BAG_CAP 单源），其余锁定画 ✕。
# 编辑器模式：可用格显示 bag_items 模板（点击开选择器、不入档——编辑器旧路不动）；
# 游戏内：显示 u.bag 实例（真背包，入档）；穿卸交互开启时可点菜单/拖拽（装备↔背包）。
func _build_bag(parent: VBoxContainer, u) -> void:
	_section(parent, "物品栏（编辑器：可放任意物品，暂不入档）" if editor_mode else "物品栏")
	var grid := GridContainer.new()
	grid.columns = 4
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER   # 整组槽位在本列内居中
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	parent.add_child(grid)
	var interact := _can_interact(u)
	for i in BAG_TOTAL:
		if i < BAG_USABLE:
			var box := _slot_box(Vector2(44, 44))
			if editor_mode:
				_fill_bag_slot(box, i)
				box.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
				box.gui_input.connect(_on_bag_slot_input.bind(i))
			else:
				var iuid: int = int(u.bag[i]) if u != null and i < u.bag.size() else 0
				if iuid != 0:
					_fill_bag_instance(box, iuid)
				if interact:
					box.can_drop = func(p): return _bag_drop_ok(u, p)
					box.on_drop = func(p): _do_bag_drop(u, p)
					if iuid != 0:
						box.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
						box.gui_input.connect(_on_bag_item_click.bind(u, iuid))
						box.drag_payload = {"kind": "bag", "iuid": iuid}
			grid.add_child(box)
		else:
			grid.add_child(_locked_slot(Vector2(44, 44)))

# 游戏内背包格：装备实例合成视图（模板⊕词条）→ 图标 + 稀有度边框 + 富 tooltip（与装备槽同款）
func _fill_bag_instance(box: Control, iuid: int) -> void:
	var item = ItemInstances.view(iuid)
	if item == null:
		return
	box.item = item
	box.tooltip_builder = _build_item_tooltip
	box.tooltip_text = str(item.get("name", ""))
	var rc = _rarity_color(item)
	if rc != null:
		var sb = box.get_theme_stylebox("panel")
		if sb is StyleBoxFlat:
			sb.border_color = rc
			sb.set_border_width_all(2)
	var tex = TextureCache.get_tex(str(item.get("icon", "")))
	if tex != null:
		var ic := TextureRect.new()
		ic.texture = tex
		ic.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(ic)

# 编辑器背包格：有物品叠图标（无图标叠首字），点击 → 回调宿主
func _fill_bag_slot(box: Control, idx: int) -> void:
	if idx >= bag_items.size():
		return
	var item = ItemDB.get_item(str(bag_items[idx]))
	if item == null:
		return
	box.item = item
	box.tooltip_builder = _build_item_tooltip
	box.tooltip_text = str(item.get("name", ""))
	var tex = TextureCache.get_tex(str(item.get("icon", "")))
	if tex != null:
		var ic := TextureRect.new()
		ic.texture = tex
		ic.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(ic)
	else:
		var lb := Label.new()
		lb.text = str(item.get("name", "?")).substr(0, 1)
		lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(lb)

func _on_bag_slot_input(event: InputEvent, idx: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if on_bag_slot.is_valid():
			on_bag_slot.call(idx)

# 右下：效果 / buff 列表（带滚动条）。排序：常驻在前、限时在后；同组内 增益在 debuff 前。
func _build_effects(parent: VBoxContainer, u) -> void:
	_section(parent, "效果")
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 160)
	parent.add_child(scroll)
	# 右内边距：给滚动条让位，避免压住时长文字
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_right", 14)
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(pad)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 6)
	pad.add_child(list)

	var effs := _sort_effects(_collect_effects(u))
	if effs.is_empty():
		var hint := Label.new()
		hint.text = "（暂无）"
		hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.4))
		list.add_child(hint)
		return
	for e in effs:
		list.add_child(_effect_row(e))

# 读单位身上的效果（无则空）
func _collect_effects(u) -> Array:
	if "effects" in u and typeof(u.effects) == TYPE_ARRAY:
		return u.effects
	return []

# 排序：①常驻优先于限时 ②同组内 增益(buff) 优先于减益(debuff)
func _sort_effects(effs: Array) -> Array:
	var out := effs.duplicate()
	out.sort_custom(func(a, b):
		var pa := 1 if a.get("permanent", false) else 0
		var pb := 1 if b.get("permanent", false) else 0
		if pa != pb:
			return pa > pb
		var ka := 0 if a.get("kind", "buff") == "buff" else 1
		var kb := 0 if b.get("kind", "buff") == "buff" else 1
		return ka < kb)
	return out

# 一条效果：色点(增益绿/减益红) + 名称 + 时长(常驻/N回合)
func _effect_row(e: Dictionary) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	var is_buff: bool = e.get("kind", "buff") == "buff"
	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(10, 10)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.color = Color("#6FCF6F") if is_buff else Color("#E07A5A")
	h.add_child(dot)
	var nm := Label.new()
	nm.text = str(e.get("name", ""))
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(nm)
	var dur := Label.new()
	dur.text = "常驻" if e.get("permanent", false) else ("%d回合" % int(e.get("duration", 0)))
	dur.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	h.add_child(dur)
	return h

# ============ 小工具 ============

func _kv(parent: Node, k: String, v: String) -> void:
	var l := Label.new()
	l.text = "%s：%s" % [k, v]
	parent.add_child(l)

# 一行放两个属性格
func _two(parent: Node, a: Control, b: Control) -> void:
	var h := HBoxContainer.new()
	a.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(a)
	h.add_child(b)
	parent.add_child(h)

func _diff_color(eff: float, base: float):
	if eff > base:
		return STAT_GREEN
	if eff < base:
		return STAT_RED
	return null

# 数值显示：保留 1 位小数，整数则去掉小数尾巴（4.0→「4」、1.8→「1.8」）。
func _fmt(v: float) -> String:
	if is_equal_approx(v, round(v)):
		return str(int(round(v)))
	return "%.1f" % v

# 单值属性格：键 + 着色数值（1 位小数）+ tooltip（基础值 + 各来源加成）
func _cell(u, cn: String, key: String, pct := false) -> Control:
	var base := float(u.stats.get(key, 0))
	var eff := float(u.effective_stat_f(key))
	var sfx := "%" if pct else ""
	return _make_cell(cn, "%s%s" % [_fmt(eff), sfx], _diff_color(eff, base), _stat_tooltip(u, cn, key, pct))

# 当前/上限 双值格：着色看上限是否被修正
func _cell_cm(u, cn: String, cur, max_key: String) -> Control:
	var base := float(u.stats.get(max_key, 0))
	var eff := float(u.effective_stat_f(max_key))
	return _make_cell(cn, "%s / %s" % [_fmt(float(cur)), _fmt(eff)], _diff_color(eff, base), _stat_tooltip(u, cn + "上限", max_key, false))

func _make_cell(cn: String, value_text: String, color, tooltip: String) -> Control:
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_theme_constant_override("separation", 0)
	var k := Label.new()
	k.text = "%s：" % cn
	k.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(k)
	var v := Label.new()
	v.text = value_text
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if color != null:
		v.add_theme_color_override("font_color", color)
	h.add_child(v)
	return _tip_host(h, tooltip)   # 包纯黑 tooltip 宿主（避免默认半透明 tooltip 与文字重叠）

# 纯黑 tooltip 宿主：把任意内容包一层，悬停出「纯黑不透明」小面板（复用 ItemSlot 的自定义 tooltip 机制）。
func _tip_host(content: Control, tip: String) -> Control:
	var host := ItemSlot.new()
	host.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	host.mouse_filter = Control.MOUSE_FILTER_STOP
	if tip != "":
		host.item = tip
		host.tooltip_builder = _build_text_tooltip
		host.tooltip_text = tip   # 非空才触发
	host.add_child(content)
	return host

# 纯文字 tooltip 面板：纯黑不透明 + 浅边框（与物品/特性富 tooltip 同调）。
func _build_text_tooltip(text) -> Control:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 1)
	sb.border_color = Color(1, 1, 1, 0.22)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	sb.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", sb)
	var l := Label.new()
	l.text = str(text)
	l.add_theme_color_override("font_color", Color(0.92, 0.92, 0.95))
	panel.add_child(l)
	return panel

# tooltip 文本：基础X：N + 每条修正「来源：±值」。
# 🔒 属性重做：四维派生公式已删——基础值=种族底值（RaceDB），修正=装备/特性/buff/熟练度。
func _stat_tooltip(u, cn: String, key: String, pct: bool) -> String:
	var sfx := "%" if pct else ""
	var lines := ["基础%s：%s%s" % [cn, _fmt(float(u.stats.get(key, 0))), sfx]]
	for m in u.modifiers:
		if m.get("stat", "") != key:
			continue
		var vnum := float(m.get("value", 0))
		var vstr := str(int(vnum)) if vnum == float(int(vnum)) else str(vnum)   # 去掉浮点尾巴
		var sgn := "+" if vnum >= 0.0 else ""
		var msfx := "%" if (str(m.get("op", "flat")) == "pct" or pct) else ""
		lines.append("%s：%s%s%s" % [str(m.get("source_label", m.get("source", ""))), sgn, vstr, msfx])
	return "\n".join(lines)

# 区块小标题（金色加粗）
func _section(parent: Node, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", Color("#EBBC04"))
	parent.add_child(l)

# 稀有度 id → 颜色（读 TagDB 单一数据源；非稀有度 / 无 color 的 tag 返回 null）
func _rarity_color_of(rarity_id: String):
	var hex := TagDB.color(rarity_id)
	return Color(hex) if hex != "" else null

# 物品稀有度 → 颜色（取 tags 里的稀有度 tag）；无则 null
func _rarity_color(item):
	for t in item.get("tags", []):
		var c = _rarity_color_of(str(t))
		if c != null:
			return c
	return null

# 物品富 tooltip → 通用组件 ItemTooltip.render（与物品编辑器共用一份渲染）
func _build_item_tooltip(item) -> Control:
	return ItemTooltip.render(item)

# tag_chip / mod_line / _is_pct_stat：D6 双活小件已合并进 ItemTooltip（tag_chip/mod_line，字号按场合传）
# 与 StatMeta.is_pct（百分比语义属 stat 元数据）——本类调用点直用共享件。

# 空槽格：描边方块（ItemSlot，装上物品后可出富 tooltip）
func _slot_box(sz: Vector2) -> Control:
	var p := ItemSlot.new()
	p.custom_minimum_size = sz
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.04)
	sb.border_color = Color(1, 1, 1, 0.22)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	p.add_theme_stylebox_override("panel", sb)
	return p

# 锁定格：更暗、画浅灰 ✕、不可交互（待技能解锁）
func _locked_slot(sz: Vector2) -> Control:
	var p := PanelContainer.new()
	p.custom_minimum_size = sz
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.18)
	sb.border_color = Color(1, 1, 1, 0.10)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3)
	p.add_theme_stylebox_override("panel", sb)
	var x := Label.new()
	x.text = "✕"
	x.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	x.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	x.add_theme_color_override("font_color", Color(1, 1, 1, 0.18))
	x.add_theme_font_size_override("font_size", 24)
	x.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(x)
	return p
