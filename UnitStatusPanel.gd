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
const TraitDB := preload("res://TraitDB.gd")
const SkillDB := preload("res://SkillDB.gd")
const ProfDB := preload("res://ProfDB.gd")               # 技艺（熟练度域）注册表——「技艺」页

const TagDB := preload("res://TagDB.gd")                 # 稀有度→颜色单一数据源
const TextureCache := preload("res://TextureCache.gd")   # 立绘/图标加载 + 缓存单一入口
const ItemTooltip := preload("res://ItemTooltip.gd")     # 物品富 tooltip 通用渲染组件（与物品编辑器共用）
const StatMeta := preload("res://StatMeta.gd")           # stat 键→中文 单一数据源（含甲抗/固减等全量键）

const ROMAN := ["", "I", "II", "III", "IV", "V"]   # 技能等级 → 罗马数字（右下角金色徽标）

# 属性键 / tag → 中文均走单一数据源：stat 用 StatMeta.label（全量、无漂移），tag 用 TagDB.cn。

const CARD_SIZE := Vector2(900, 660)   # 卡片固定尺寸（含抬头区）
const FRAME_SCALE := 3                 # 角饰放大倍数
const GUTTER := 52                     # 上下留白：≥角饰高(17×scale) 以避让角饰
const SIDE_PAD := 28                   # 左右内缩

const BAG_USABLE := 8                  # 默认可用物品格（横4竖2）
const BAG_TOTAL := 16                  # 实际画 4×4，多出的锁定
const HEADER_H := 56                   # 抬头/拖动区高度（覆盖标题行 + 上方留白）

const STAT_GREEN := Color("#6FCF6F")   # 属性被修正调高
const STAT_RED := Color("#E07A5A")     # 属性被修正调低
# 稀有度 → 槽位边框色（见 docs/标签词典.md）
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
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(card)
	_card = card

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
	# 技能三分类（见 docs/单位系统设计.md「技能三分类」）：通用＝人人；职业＝同类单位共享树（杂兵主进度）；专属＝具名独有。
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
	# 技艺（熟练度域 🔒 属性与成长系统.md §2）：三页分区 + 阶段进度 + 装载/卸载（非战斗随时；战斗中锁定只读）
	var craft_page := _build_prof_page(u)
	craft_page.name = "技艺"
	tabs.add_child(craft_page)
	# 通用技能：人人都有（即原「职业技能」页的 13 通用序列 + 进阶；命名修正——它一直是通用技能）
	var common_page := _build_common_skill_page(u)
	common_page.name = "通用技能"
	tabs.add_child(common_page)
	# 第三页二选一：具名角色（char_*）→ 专属技能；其余杂兵 → 职业技能（同类共享树）
	if _has_exclusive_skills(u):
		var exclusive_page := _build_exclusive_skill_page(u)
		exclusive_page.name = "专属技能"
		tabs.add_child(exclusive_page)
	else:
		var prof_page := _build_profession_skill_page(u)
		prof_page.name = "职业技能"
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
	for x in host.units:
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

# 初次居中；之后沿用上次拖到的位置
func _place_card() -> void:
	var vp := get_viewport_rect().size
	if _win_pos.x < 0.0:
		_card.position = ((vp - CARD_SIZE) * 0.5).floor()
	else:
		_set_card_pos(_win_pos)

# 设卡片位置并钳制：横向至少留 min_vis 可见，标题条不超出顶/底
func _set_card_pos(p: Vector2) -> void:
	var vp := get_viewport_rect().size
	var cs: Vector2 = _card.size
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

# ====== 通用技能页 ======
# 布局（仿草图；图标待美术补、技能功能待规格，先搭结构）：
#   ① 顶部 13 个「基础技能」——两行铺满整个顶部宽度（每格均分，不挤成一条）。
#   ②③④ 三类「进阶技能」各一块彩色背景板（色=分类，作底、不画在边框上），左右成簇并排，下方留空（可增长）：
#       红=力量/双手/重武器/进攻 · 蓝=体力/盾牌/铠甲/抗性/防御 · 绿=迅捷/远程/轻武器/精密。
#   每格 = 图标 + 下方技能名（名现预留占位）。进阶每类先象征性摆 3 个。
#   数据暂用常量占位，将来接 data/skills.json（见 docs/单位系统设计.md「技能系统」）。
const COMMON_BASIC_COUNT := 13
const COMMON_BASIC_ROWS := 2          # 基础技能铺成几行（13 → 7 + 6）
const COMMON_ADVANCED := [
	{"label": "力量", "tip": "力量 · 双手 · 重武器 · 进攻", "bg": Color(0.80, 0.30, 0.25, 0.16), "fg": Color("#E8927A"), "count": 3},
	{"label": "体力", "tip": "体力 · 盾牌 · 铠甲 · 抗性 · 防御", "bg": Color(0.23, 0.48, 0.84, 0.16), "fg": Color("#6FA8EA"), "count": 3},
	{"label": "迅捷", "tip": "迅捷 · 远程 · 轻武器 · 精密动作", "bg": Color(0.31, 0.68, 0.35, 0.16), "fg": Color("#7FD98A"), "count": 3},
]

# 「通用技能」页：所有角色都能学的通用技能（基础 13 通用序列数据驱动；进阶三色树仍占位）
# 勿与「职业技能（同类共享树，class_*）」混淆——那是另一分类。
func _build_common_skill_page(u) -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 10)

	# ① 基础技能：13 个（通用序列 seq 1-13），两行；上排 7 铺满，下排 6 整体错位半格（砖墙/蜂窝式）
	_section(page, "基础技能")
	var basic := VBoxContainer.new()
	basic.add_theme_constant_override("separation", 10)
	page.add_child(basic)
	var per_row := int(ceil(float(COMMON_BASIC_COUNT) / COMMON_BASIC_ROWS))   # 7
	var made := 0
	for r in COMMON_BASIC_ROWS:
		var rowc := HBoxContainer.new()
		rowc.add_theme_constant_override("separation", 6)
		basic.add_child(rowc)
		var offset := (r % 2) == 1   # 奇数行：两端各垫半格弹性占位 → 整排右移半格、错位嵌缝
		if offset:
			rowc.add_child(_hspacer(0.5))
		for i in mini(per_row, COMMON_BASIC_COUNT - made):
			rowc.add_child(_skill_cell(SkillDB.by_seq(made + 1), u))   # seq 从 1 起；该格无配置则 null=占位
			made += 1
		if offset:
			rowc.add_child(_hspacer(0.5))

	page.add_child(HSeparator.new())

	# ②③④ 进阶技能：三类各一块彩色背景板，左右成簇并排（不竖向拉伸 → 下方留空可增长）
	_section(page, "进阶技能")
	var adv := HBoxContainer.new()
	adv.add_theme_constant_override("separation", 12)
	page.add_child(adv)
	for cat in COMMON_ADVANCED:
		adv.add_child(_advanced_block(cat, u))
	return page

# 一块进阶技能背景板：彩色底 PanelContainer + 分类标题 + 一行技能格（均分铺满本块宽度）
func _advanced_block(cat: Dictionary, u) -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN   # 内容高度、贴顶，不拉到底
	var sb := StyleBoxFlat.new()
	sb.bg_color = cat["bg"]
	sb.set_corner_radius_all(5)
	sb.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	panel.add_child(v)

	var title := Label.new()
	title.text = str(cat["label"])
	title.tooltip_text = str(cat["tip"])
	title.mouse_filter = Control.MOUSE_FILTER_STOP   # 悬停看该类涵盖范围
	title.add_theme_color_override("font_color", cat["fg"])
	v.add_child(title)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	v.add_child(row)
	for i in int(cat["count"]):
		row.add_child(_skill_cell(null, u))   # 进阶技能尚无数据 → 占位空格
	return panel

# 单个技能格：上 图标格（主动=方框 / 被动=圆框；真图标待美术，暂用 ✦）+ 下 技能名。
# def==null → 占位空格（✦ / —）。def!=null → 数据驱动：
#   未学=整体压灰；已学=正常 +（可升级技能）右下角金色罗马数字等级；
#   悬停出技能富 tooltip；左键点击 = 学习/升级（角色等级够门槛时，见 _can_learn）。
func _skill_cell(def, u) -> Control:
	var cell := VBoxContainer.new()
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cell.add_theme_constant_override("separation", 3)

	var is_active: bool = def == null or bool(def.get("active", true))
	var box := _skill_box(Vector2(50, 50), is_active)
	box.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	cell.add_child(box)

	# 占位空格（无技能数据）：淡 ✦ + 「—」，不可交互
	if def == null:
		box.tooltip_text = ""
		_skill_glyph(box, 0.22)
		cell.add_child(_skill_name_label("—", 0.3))
		return cell

	var sid := str(def.get("id", ""))
	var lvl: int = u.skill_level(sid)
	var learned := lvl > 0

	_skill_glyph(box, 0.5 if learned else 0.22)
	# 等级罗马数字（金，右下角）——已学且可升级（max_level>1）才显示
	if learned and int(def.get("max_level", 1)) > 1:
		var num := Label.new()
		num.text = ROMAN[clampi(lvl, 0, ROMAN.size() - 1)]
		num.add_theme_color_override("font_color", Color("#EBBC04"))
		num.add_theme_font_size_override("font_size", 14)
		num.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		num.offset_left = -18
		num.offset_top = -20
		num.offset_right = -3
		num.offset_bottom = -1
		num.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		num.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		num.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(num)
	# 未学 → 整体压灰（图标 + 边框）
	if not learned:
		box.modulate = Color(0.62, 0.62, 0.66)
	# 富 tooltip + 点击学习/升级
	box.item = def
	box.tooltip_builder = _build_skill_tooltip.bind(u)
	box.tooltip_text = str(def.get("name", ""))
	box.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if _can_learn(u, def) else Control.CURSOR_ARROW
	box.gui_input.connect(_on_skill_cell_input.bind(def, u))

	cell.add_child(_skill_name_label(str(def.get("name", "")), 0.9 if learned else 0.4))
	return cell

# 图标格里居中放占位字形 ✦（真图标待美术补；alpha 区分已学/未学）
func _skill_glyph(box: Control, alpha: float) -> void:
	var g := Label.new()
	g.text = "✦"
	g.set_anchors_preset(Control.PRESET_FULL_RECT)
	g.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	g.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	g.add_theme_color_override("font_color", Color(1, 1, 1, alpha))
	g.add_theme_font_size_override("font_size", 22)
	g.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(g)

# 图标下方技能名（居中、可设淡度）
func _skill_name_label(text: String, alpha: float) -> Label:
	var nm := Label.new()
	nm.text = text
	nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	nm.custom_minimum_size = Vector2(0, 16)
	nm.add_theme_font_size_override("font_size", 12)
	nm.add_theme_color_override("font_color", Color(1, 1, 1, alpha))
	return nm

# 技能图标格：主动=方框（圆角3）/ 被动=圆框（圆角=半边长）。仿 _slot_box。
func _skill_box(sz: Vector2, active: bool) -> Control:
	var p := ItemSlot.new()
	p.custom_minimum_size = sz
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.04)
	sb.border_color = Color(1, 1, 1, 0.22)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(3 if active else int(sz.x / 2.0))
	p.add_theme_stylebox_override("panel", sb)
	return p

# 是否可学习/升级：未满级 + 还有下一档门槛 + 角色等级达标。
func _can_learn(u, def) -> bool:
	if def == null:
		return false
	var cur: int = u.skill_level(str(def.get("id", "")))
	var maxl := int(def.get("max_level", 1))
	if cur >= maxl:
		return false
	var gates = def.get("learn_level", [])
	if typeof(gates) != TYPE_ARRAY or cur >= gates.size():
		return false
	return int(u.level) >= int(gates[cur])

# 点技能格：左键 → 够等级则学习/升一级，重建面板反映新等级（保持当前 tab）。
func _on_skill_cell_input(event: InputEvent, def, u) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _can_learn(u, def):
			u.learn_skill(str(def.get("id", "")))
			_build(u)

# 技能富 tooltip：黑底 + 边框（已学=金/未学=灰）；名称 + 类型chip + 距离/AP/治疗/冷却/次数 + 描述 + 学习门槛/状态。
func _build_skill_tooltip(def, u) -> Control:
	var sid := str(def.get("id", ""))
	var lvl := int(u.skill_level(sid))
	var learned := lvl > 0
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 1)
	sb.border_color = Color("#EBBC04") if learned else Color(1, 1, 1, 0.3)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 5)
	panel.add_child(v)

	var name_l := Label.new()
	name_l.text = str(def.get("name", ""))
	name_l.add_theme_font_size_override("font_size", 19)
	name_l.add_theme_color_override("font_color", Color("#EBBC04"))
	v.add_child(name_l)

	# 类型 chip：主动/被动 + 目标
	var chips := ["主动" if bool(def.get("active", true)) else "被动"]
	if str(def.get("target", "")) == "non_enemy":
		chips.append("非敌方")
	if bool(def.get("self_target", false)):
		chips.append("可自身")
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 4)
	flow.add_theme_constant_override("v_separation", 4)
	for c in chips:
		flow.add_child(ItemTooltip.tag_chip(str(c), 13))
	v.add_child(flow)

	v.add_child(_tip_line("距离", "%d" % int(def.get("range", 1))))
	v.add_child(_tip_line("AP 消耗", "%d" % int(def.get("ap_cost", 1))))
	# 各级治疗档（已学则标出当前级实际值）
	var heals = def.get("heal_pct_max_hp", [])
	if typeof(heals) == TYPE_ARRAY and heals.size() > 0:
		var parts := []
		for i in heals.size():
			parts.append("%d%%" % int(heals[i]))
		var t := " / ".join(parts)
		if learned:
			t += "　→ 当前 %s：%d%%" % [ROMAN[clampi(lvl, 0, ROMAN.size() - 1)], int(heals[clampi(lvl - 1, 0, heals.size() - 1)])]
		v.add_child(_tip_line("治疗(最大生命)", t))
	v.add_child(_tip_line("冷却", "%d 回合" % int(u.skill_cooldown_max(def))))
	v.add_child(_tip_line("本战次数", "%d 次" % int(u.skill_uses_max(def))))
	var ct = def.get("cleanse_tags", [])
	if typeof(ct) == TYPE_ARRAY and ct.size() > 0:
		v.add_child(_tip_line("附带", "立即清除目标的流血类效果"))

	var desc := str(def.get("desc", ""))
	if desc != "":
		v.add_child(HSeparator.new())
		var d := Label.new()
		d.text = desc
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		d.custom_minimum_size = Vector2(300, 0)
		d.add_theme_font_size_override("font_size", 14)
		d.add_theme_color_override("font_color", Color(0.82, 0.82, 0.86))
		v.add_child(d)

	# 学习门槛 + 当前状态
	v.add_child(HSeparator.new())
	var gates = def.get("learn_level", [])
	if typeof(gates) == TYPE_ARRAY and gates.size() > 0:
		var gparts := []
		for i in gates.size():
			gparts.append("%s=角色Lv%d" % [ROMAN[clampi(i + 1, 0, ROMAN.size() - 1)], int(gates[i])])
		v.add_child(_tip_line("学习门槛", " · ".join(gparts)))
	var st := Label.new()
	st.text = _skill_status_line(u, def)
	st.add_theme_font_size_override("font_size", 14)
	var can := _can_learn(u, def)
	st.add_theme_color_override("font_color", Color("#6FCF6F") if can else (Color(0.72, 0.72, 0.76) if learned else Color("#E07A5A")))
	v.add_child(st)
	return panel

# 技能学习/升级状态的一句话（tooltip 底部）
func _skill_status_line(u, def) -> String:
	var sid := str(def.get("id", ""))
	var cur := int(u.skill_level(sid))
	var maxl := int(def.get("max_level", 1))
	var gates = def.get("learn_level", [])
	if cur >= maxl:
		return "已精通（满级 %s）" % ROMAN[clampi(maxl, 0, ROMAN.size() - 1)]
	var has_gate: bool = typeof(gates) == TYPE_ARRAY and cur < gates.size()
	var need := int(gates[cur]) if has_gate else 999
	var nextlv: String = ROMAN[clampi(cur + 1, 0, ROMAN.size() - 1)]
	if int(u.level) >= need:
		return ("可学习 %s（点击图标）" % nextlv) if cur == 0 else ("可升级到 %s（点击图标）" % nextlv)
	return ("需角色等级 %d 学习 %s" % [need, nextlv]) if cur == 0 else ("升级到 %s 需角色等级 %d" % [nextlv, need])

# 弹性占位（按 ratio 占宽度）：垫在一行两端可让该行整体错位/居中
func _hspacer(ratio: float) -> Control:
	var s := Control.new()
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_stretch_ratio = ratio
	s.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return s

# 「专属技能」页：具名角色（char_*）独占的技能树——随等级解锁、常选 1/N 分支定走向（占位，待实现）
func _build_exclusive_skill_page(_u) -> Control:
	return _skill_placeholder("专属技能 —— 待实现")

# 「职业技能」页：同类单位共享、跨类不通的技能树（杂兵主进度；按 class_* 类别）（占位，待实现）
func _build_profession_skill_page(_u) -> Control:
	return _skill_placeholder("职业技能 —— 待实现（同类单位共享技能树）")

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

# ============ 技艺页 ============
# ⚠️ 原「熟练度域」列表 UI 已清空重做；ProfDB / Unit.prof_* 字段 / data/proficiencies.json 未动。
# 布局：① 顶部 5 个装备技能格（右侧竖向计量槽 + 下方「名-档位」）② 横线
#       ③ 左侧纵向 3 tab（武器/战斗/其他技能）+ 竖线 + 右侧「已习得技能」列表（熟练度高→低、习得优先）。
# ⚠️ 数据源（技能真值 / 熟练度字段）待定 → 现用占位数据（_PH_*）演示结构与配色。

# 熟练度档位 🔒（用户规格 2026-07-06）：区间[lo,hi] + 颜色；计量槽显示「当前档位内进度」，色随档位。
const PROF_TIERS := [
	{"name": "生疏", "lo": 0,    "hi": 100,  "color": "#E0E0E0"},
	{"name": "娴熟", "lo": 101,  "hi": 300,  "color": "#4FAE5A"},
	{"name": "老练", "lo": 301,  "hi": 600,  "color": "#3A7BD5"},
	{"name": "专家", "lo": 601,  "hi": 1000, "color": "#9B59B6"},
	{"name": "大师", "lo": 1001, "hi": 1500, "color": "#EBBC04"},
]
const PROF_CELL_COUNT := 5                        # 装备技能格数
const PROF_CELL_SIZE := Vector2(64, 64)           # 单格边长
const PROF_GAUGE_W := 12                          # 竖向计量槽宽度
const PROF_GAUGE_TRACK := Color(1, 1, 1, 0.10)    # 槽底（暗）
const PROF_SKILL_TABS := ["武器技能", "战斗技能", "其他技能"]   # 左侧纵向子 tab

# —— 占位数据（待接真实数据）——
const _PH_EQUIPPED := [
	{"name": "双手武器", "xp": 450},   # 老练·蓝
	{"name": "单手武器", "xp": 60},    # 生疏·白
	{"name": "远程",     "xp": 250},   # 娴熟·绿
	{"name": "盾",       "xp": 820},   # 专家·紫
	{"name": "体术",     "xp": 1300},  # 大师·金
]
# L3：每个技能类型下的具体技能（纵向 tab 列表）
const _PH_SKILLS := {
	"武器技能": ["剑", "匕首", "斧", "锤", "连枷", "矛", "弓", "弩", "戟"],
	"战斗技能": ["格挡", "冲锋", "闪避", "重击", "防御姿态"],
	"其他技能": ["烹饪", "医疗", "潜行", "追踪", "谈判"],
}
const _PH_LEARNED := {
	"武器技能": [
		{"name": "双手武器", "xp": 450, "known": true},
		{"name": "单手武器", "xp": 60,  "known": true},
		{"name": "剑",       "xp": 250, "known": true},
		{"name": "斧",       "xp": 0,   "known": false},
	],
	"战斗技能": [
		{"name": "格挡",     "xp": 820, "known": true},
		{"name": "冲锋",     "xp": 120, "known": true},
		{"name": "闪避",     "xp": 0,   "known": false},
	],
	"其他技能": [
		{"name": "烹饪",     "xp": 1300, "known": true},
		{"name": "医疗",     "xp": 300,  "known": true},
		{"name": "潜行",     "xp": 0,    "known": false},
	],
}

# xp → 档位定义（Dictionary）
func _prof_tier(xp: int) -> Dictionary:
	var t: Dictionary = PROF_TIERS[0]
	for e in PROF_TIERS:
		if xp >= int(e["lo"]):
			t = e
	return t

# xp → 当前档位内进度 0..1（gauge 填充高度）
func _prof_tier_progress(xp: int) -> float:
	var t := _prof_tier(xp)
	return clampf(float(xp - int(t["lo"])) / float(maxi(1, int(t["hi"]) - int(t["lo"]))), 0.0, 1.0)

func _build_prof_page(_u) -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 10)

	# ① 顶部：5 个装备技能格
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	page.add_child(row)
	for i in PROF_CELL_COUNT:
		row.add_child(_prof_slot_unit(_PH_EQUIPPED[i] if i < _PH_EQUIPPED.size() else {}))

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
	left_area.add_theme_constant_override("separation", 8)
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
	var l3col := VBoxContainer.new()          # L3：纵向具体技能 tab（随 L2 重建）
	l3col.custom_minimum_size = Vector2(84, 0)
	l3col.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	l3col.add_theme_constant_override("separation", 4)
	inner.add_child(l3col)
	inner.add_child(VSeparator.new())
	var main := VBoxContainer.new()           # 选中技能的内容页（待定）
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inner.add_child(main)

	# L2 横向 tab：切类型 → 重建 L3 纵向 tab（重置到该类第一项）
	var grp2 := ButtonGroup.new()
	var l2btns := []
	for i in PROF_SKILL_TABS.size():
		var b := Button.new()
		b.text = str(PROF_SKILL_TABS[i])
		b.toggle_mode = true
		b.button_group = grp2
		b.custom_minimum_size = Vector2(0, 32)
		var idx := i
		b.pressed.connect(func():
			_prof_subtab = idx
			_prof_l3 = 0
			_rebuild_prof_l3(l3col, main, str(PROF_SKILL_TABS[idx])))
		l2btns.append(b)
		tabrow.add_child(b)

	body.add_child(VSeparator.new())

	# 右：窄列——所有已习得技能（习得优先、熟练度高→低）
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(172, 0)
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
	_fill_learned_list(list)

	# 初始：按记住的 L2 选中 → 建 L3（clamp 记住的 L3）
	_prof_subtab = clampi(_prof_subtab, 0, PROF_SKILL_TABS.size() - 1)
	l2btns[_prof_subtab].button_pressed = true   # 程序化选中不触发 pressed
	_rebuild_prof_l3(l3col, main, str(PROF_SKILL_TABS[_prof_subtab]))
	return page

# 重建 L3 纵向 tab（当前技能类型下的具体技能），并显示选中技能的内容页。
func _rebuild_prof_l3(l3col: VBoxContainer, main: VBoxContainer, type_name: String) -> void:
	for c in l3col.get_children():
		l3col.remove_child(c)
		c.queue_free()
	var skills: Array = _PH_SKILLS.get(type_name, [])
	if skills.is_empty():
		_fill_prof_main(main, "")
		return
	var grp := ButtonGroup.new()
	var btns := []
	for i in skills.size():
		var b := Button.new()
		b.text = str(skills[i])
		b.toggle_mode = true
		b.button_group = grp
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Vector2(0, 28)
		var idx := i
		b.pressed.connect(func():
			_prof_l3 = idx
			_fill_prof_main(main, str(skills[idx])))
		btns.append(b)
		l3col.add_child(b)
	_prof_l3 = clampi(_prof_l3, 0, btns.size() - 1)
	btns[_prof_l3].button_pressed = true
	_fill_prof_main(main, str(skills[_prof_l3]))

# 一个装备技能格：VBox[ HBox(格 + 竖向计量槽), 下方「名-档位」]。
func _prof_slot_unit(d: Dictionary) -> Control:
	var has := not d.is_empty()
	var xp := int(d.get("xp", 0))
	var tier := _prof_tier(xp)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	col.size_flags_vertical = Control.SIZE_SHRINK_BEGIN

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 5)
	var cell := Panel.new()
	cell.custom_minimum_size = PROF_CELL_SIZE
	cell.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.04)
	sb.set_corner_radius_all(4)
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.22)
	cell.add_theme_stylebox_override("panel", sb)
	top.add_child(cell)
	var fill_col := Color(str(tier["color"])) if has else Color(1, 1, 1, 0.12)
	top.add_child(_prof_gauge(_prof_tier_progress(xp) if has else 0.0, fill_col))
	col.add_child(top)

	col.add_child(_prof_cell_label(d))
	return col

# 格子下方「名-档位」：技能名常色，档位名随档位变色（居中，宽度对齐 格+槽）。
func _prof_cell_label(d: Dictionary) -> Control:
	var h := HBoxContainer.new()
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	h.custom_minimum_size = Vector2(PROF_CELL_SIZE.x + PROF_GAUGE_W + 5, 0)
	if d.is_empty():
		var e := Label.new()
		e.text = "（空槽）"
		e.add_theme_color_override("font_color", Color(1, 1, 1, 0.3))
		e.add_theme_font_size_override("font_size", 11)
		h.add_child(e)
		return h
	var tier := _prof_tier(int(d.get("xp", 0)))
	var nm := Label.new()
	nm.text = str(d.get("name", "")) + "-"
	nm.add_theme_font_size_override("font_size", 11)
	h.add_child(nm)
	var tl := Label.new()
	tl.text = str(tier["name"])
	tl.add_theme_color_override("font_color", Color(str(tier["color"])))
	tl.add_theme_font_size_override("font_size", 11)
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

# 右侧「已习得技能」窄列：合并所有类型、只列已习得，按熟练度高→低。
func _fill_learned_list(list: VBoxContainer) -> void:
	for c in list.get_children():
		list.remove_child(c)
		c.queue_free()
	var arr := []
	for cat in PROF_SKILL_TABS:
		for d in (_PH_LEARNED.get(cat, []) as Array):
			if bool(d.get("known", false)):     # 只列已习得
				arr.append(d)
	arr.sort_custom(func(a, b): return int(a.get("xp", 0)) > int(b.get("xp", 0)))   # 熟练度高→低
	for d in arr:
		list.add_child(_learned_row(d))

# 一行：名（常色）+ 档位（含 xp 值，色随档位）——紧挨不拉远。
func _learned_row(d: Dictionary) -> Control:
	var xp := int(d.get("xp", 0))
	var tier := _prof_tier(xp)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	var nm := Label.new()
	nm.text = str(d.get("name", ""))
	nm.add_theme_font_size_override("font_size", 12)
	nm.custom_minimum_size = Vector2(60, 0)
	h.add_child(nm)
	var t := Label.new()
	t.text = "%s（%d）" % [str(tier["name"]), xp]
	t.add_theme_font_size_override("font_size", 12)
	t.add_theme_color_override("font_color", Color(str(tier["color"])))
	h.add_child(t)
	return h

# 主内容区（显示选中的 L3 具体技能）——技能页内容待定，先占位。
func _fill_prof_main(main: VBoxContainer, skill_name: String) -> void:
	for c in main.get_children():
		main.remove_child(c)
		c.queue_free()
	var l := Label.new()
	l.text = ("「%s」技能页 —— 内容待定" % skill_name) if skill_name != "" else "（无技能）"
	l.add_theme_color_override("font_color", Color(1, 1, 1, 0.35))
	main.add_child(l)

# 右上：属性两列
# 属性两列：值读 effective_stat；受修正变高=绿/变低=红；鼠标悬停看基础值 + 各来源加成。
func _build_stats(right: VBoxContainer, u) -> void:
	right.add_child(_cell_cm(u, "生命值", u.effective_stat("HP"), "HP_max"))
	right.add_child(_cell_cm(u, "护甲值", u.effective_stat("armor"), "armor_max"))
	_two(right, _cell_cm(u, "行动点", int(u.ap), "AP_max"), _cell(u, "行动力", "move"))
	_two(right, _cell(u, "攻击", "atk"), _cell(u, "速度", "speed"))
	_two(right, _cell(u, "攻击效能", "atk_eff", true), _cell(u, "防御效能", "def_eff", true))
	_two(right, _cell(u, "命中", "acc"), _cell(u, "闪避", "eva"))
	_two(right, _cell(u, "格挡率", "block_rate", true), _cell(u, "格挡性能", "block_power", true))
	_two(right, _cell(u, "暴击率", "crit_rate", true), _cell(u, "暴击威力", "crit_dmg", true))
	_two(right, _cell(u, "物理抗性", "res_phys", true), _cell(u, "自然抗性", "res_nature", true))
	_two(right, _cell(u, "意志强韧", "will_fort", true), _cell(u, "肉体强韧", "body_fort", true))

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
	v.add_child(box)
	var l := Label.new()
	l.text = slot_label
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(l)
	return v

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

# 中下：物品栏（占位）。实画 4×4，前 BAG_USABLE 个可用，其余锁定画 ✕。
# 编辑器模式：可用格显示 bag_items 内容、点击开选择器（任意物品）；⚠ 背包暂不入档（先占位）。
func _build_bag(parent: VBoxContainer, _u) -> void:
	_section(parent, "物品栏（编辑器：可放任意物品，暂不入档）" if editor_mode else "物品栏")
	var grid := GridContainer.new()
	grid.columns = 4
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER   # 整组槽位在本列内居中
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	parent.add_child(grid)
	for i in BAG_TOTAL:
		if i < BAG_USABLE:
			var box := _slot_box(Vector2(44, 44))
			if editor_mode:
				_fill_bag_slot(box, i)
				box.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
				box.gui_input.connect(_on_bag_slot_input.bind(i))
			grid.add_child(box)
		else:
			grid.add_child(_locked_slot(Vector2(44, 44)))

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

# tooltip 里的一条「键：值」
func _tip_line(k: String, val: String) -> Label:
	var l := Label.new()
	l.text = "%s：%s" % [k, val]
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", Color(0.88, 0.88, 0.92))
	return l

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
