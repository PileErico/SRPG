extends "res://ListEditorShell.gd"
## 技能编辑器（能力 Ability）：拼装/调参 data/skills.json 条目，写盘走 SkillDB.save_skill。
## 🔒 设计真值＝docs/模块_技能_设计.md（schema §2.1 / 效果块调色盘 §3 / 公式 §2.4 / 护栏 §10）。
## 本质＝用预设「效果块」模板拼装技能（非通用 DSL）；复杂专属逻辑走 scripted 逃生舱。
## v1 可编块：attack(单 hit+公式) / heal / passive_stat_mods / conditional_mod / apply_effect / scripted。
## 「可编不可跑」护栏（§10）：多 hits / riders＝阶段6 禁入库（块锁定只读）；weapon_source＝3b、
##   passive_stat_mods / conditional_mod＝阶段4 均已生效（绿条说明）；scripted 需代码注册——黄条警示；
##   未编辑高级字段保存原样保留。conditional_mod 的 when 行控件在 EditorUI（词表 §4 v1，将来技能树同词表直取）；
##   未实现 when 类型（time_of_day 等）＝行级锁定原样保留。块可折叠+↑/↓ 调序（按序结算，序有编辑权）。
## 存盘校验与 test_data_lint 规则7 对齐（编辑器先拦，别让 lint 红）：BAS 约束 / target 三旗全 false /
##   per_level 长度==max_level / costs.ap 与顶层 ap_cost 禁双写（收集时剥旧键 nature/seq 随存即迁——2026-07-13 改词/废除）。
## 效果库（EffectDB）＝独立 EffectEditor 场景，标题栏分段切换（仿工坊切换器，脏守卫接管）。

const SkillDB := preload("res://SkillDB.gd")
const EffectDB := preload("res://EffectDB.gd")
const TagDB := preload("res://TagDB.gd")
const StatMeta := preload("res://StatMeta.gd")
const EffectEditorScript := preload("res://EffectEditor.gd")   # §26 apply_effect 引用位「↗」静态传参口
const ItemDB := preload("res://ItemDB.gd")                     # §18 反向引用感知（武器 bws/ews 引用技能）
const UnitFactory := preload("res://UnitFactory.gd")           # §18 反向引用感知（原型 skills 引用技能）
const HexShapePicker := preload("res://HexShapePicker.gd")     # 🔒 决策30 图形化范围（选取形/作用形点格）
const HexGrid := preload("res://HexGrid.gd")                   # 参考盘派生预览（旋转/圆盘）
const SkillTooltip := preload("res://SkillTooltip.gd")         # 右栏即时预览（成品 tooltip 效果，2026-07-15 用户令）

const ICON_DIR := "res://icons/Skills"
# 适用武器种类的 tag 类别（🔒 决策29：词表＝TagDB wcat_*，与武器 tag/动态技能 tag 三位一体）
const WEAPON_KIND_CATS := [["wcat_melee", "近战"], ["wcat_ranged", "远程"], ["wcat_catalyst", "触媒"], ["wcat_shield", "盾"]]
const CATEGORIES := [["skill", "技巧 skill"], ["spell", "魔法 spell（魔法系统后置）"]]   # ⚠ 2026-07-13 用户改词：键 nature→category（与修正对象的 nature〔buff/debuff〕分家）
# 伤害属性（大类：物理/元素；真伤=将来位）＋伤害类型（创伤，词表同 tags.json cat damage）——两正交下拉（2026-07-13 用户拍板）
const DAMAGE_CATEGORIES := [["physical", "物理"], ["fire", "火"], ["ice", "冰"], ["thunder", "雷"], ["holy", "神圣"]]
const DAMAGE_TYPES := [["", "（未设）"], ["slashing", "斩击"], ["piercing", "穿刺"], ["bludgeoning", "打击"]]
# 握持要求（🔒 决策35 运行时可用性条件：菜单灰显+apply_skill 守卫；BWS 禁带——普攻恒可用，lint 执法）
const GRIP_PAIRS := [["", "（不限）"], ["one_handed", "需单手持"], ["two_handed", "需双手持"]]
const HAND_SLOTS := [["main_hand", "主手"], ["off_hand", "副手"]]   # when equip_state 槽位词表（requires_hands 已删 2026-07-13）
const BLOCK_KINDS := [["attack", "攻击 attack"], ["heal", "治疗 heal"],
	["passive_stat_mods", "被动修正 passive_stat_mods"],
	["conditional_mod", "条件修正 conditional_mod"],
	["apply_effect", "施加效果 apply_effect"], ["scripted", "脚本 scripted"]]
# 技能 tag 下拉预设的类别（§2.1 tags：verbal 等玩家可读/可筛词；其余手动）
# damage 类已摘（2026-07-13）：创伤定型走攻击块 damage_type 字段，不再从 tag 口进
const SKILL_TAG_CATS := ["skill_type", "target"]
const WARN_COLOR := Color(0.95, 0.8, 0.35)    # 黄＝可编不可跑警示
const LOCK_COLOR := Color(0.92, 0.5, 0.45)    # 红＝阶段6 前禁入库（块锁定）
const HINT_COLOR := Color(0.55, 0.75, 0.55)   # 绿＝纯说明（字段已生效，非警示）

# —— 状态 ——
var _current: Dictionary = {}
var _tags: Array = []
var _blocks: Array = []       # 效果块：[{data, kind, panel, ...控件}]（data＝原始块，collect 时 duplicate+更新）

# —— 控件 ——
var _form: VBoxContainer
var _file_dialog: FileDialog
var _icon_thumb: TextureRect
var _w_id: LineEdit
var _w_name: LineEdit
var _w_icon: LineEdit
var _w_desc: TextEdit
var _w_category: OptionButton
var _w_active: CheckBox
var _w_ap: SpinBox
var _w_cd: SpinBox
var _w_uses: SpinBox
var _w_maxlv: SpinBox
var _w_range: SpinBox
var _w_t_enemy: CheckBox
var _w_t_ally: CheckBox
var _w_t_self: CheckBox
var _w_passive_hint: Label   # §25 被动灰化联动的说明条（active=false 时可见）
# —— 武器技能（🔒 决策29 勾选制）+ 形状（🔒 决策30 图形化）——
var _w_wskill: CheckBox            # 武器技能勾选（勾＝可被武器选取）
var _kind_box: Control             # 适用武器种类区（勾选时显示）
var _kind_checks := {}             # wcat tag id -> CheckBox
var _w_grip: OptionButton          # 握持要求（🔒 决策35；随 _kind_box 显隐）
var _preview: VBoxContainer        # 右栏即时 tooltip 预览（SkillTooltip 共享渲染，2026-07-15）
var _form_ready := false           # 表单建全旗（半构造期闸预览 collect）
var _w_custom_pick: CheckBox       # 自定义攻击范围（勾＝选取形可点格编辑；否＝盘只作 range 可视化参考）
var _w_pick: Control               # 选取形 HexShapePicker
var _w_effect: Control             # 作用形 HexShapePicker
var _w_anchor: OptionButton        # 作用形锚点 caster/target
var _w_ff: CheckBox                # 友伤 friendly_fire
var _blocks_box: VBoxContainer
var _block_pick: OptionButton


# —— §26 跨编辑器定位口 ——
# 其他编辑器（ItemEditor BWS/EWS「↗」）先写本静态位再 change_scene_to_file；_ready 消费即清，
# 直跑本场景不受影响。同型先例＝SandboxConfig.battle_setup（静态变量跨场景切换存活）。
static var _open_with_id := ""

func _ready() -> void:
	super._ready()
	if _open_with_id != "":
		var jump_id := _open_with_id
		_open_with_id = ""
		if SkillDB.get_skill(jump_id) != null:
			_shell_load(jump_id)
		else:
			_err("跳转定位失败：技能「%s」不在库（悬空引用？）" % jump_id)


# —— 外壳钩子（ListEditorShell）——

func _shell_title() -> String:
	return "技能编辑器"

func _shell_new_label() -> String:
	return "＋ 新建能力"

func _shell_new_entry() -> void:
	_open_skill(_skeleton(), true)
	_select_row("")
	_info("新建能力——填好 id（唯一）后点保存")

func _shell_load(id: String) -> void:
	var def = SkillDB.get_skill(id)
	if def == null:
		return
	_open_skill((def as Dictionary).duplicate(true), false)
	_select_row(id)
	_info("编辑「%s」" % str(_current.get("name", id)))

func _shell_discard_text() -> String:
	return "当前能力有未保存的修改，继续将丢弃。"

func _shell_has_entry() -> bool:
	return _w_id != null and is_instance_valid(_w_id)

func _shell_titlebar_extras(titlebar: HBoxContainer) -> void:
	titlebar.add_child(EditorUI.scene_switch(self, "skill",
		[["skill", "⚔ 能力库", "res://SkillEditor.tscn"], ["effect", "✨ 效果库", "res://EffectEditor.tscn"]],
		_confirm_discard))

# 右侧＝再一道 HSplit：表单（中）+ 即时 tooltip 预览（右）——与 ItemEditor 同构（2026-07-15 用户令）
func _shell_build_right(split: HSplitContainer) -> void:
	var right_split := HSplitContainer.new()
	right_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_split.split_offset = 420
	split.add_child(right_split)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_form = VBoxContainer.new()
	_form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_form.add_theme_constant_override("separation", 8)
	scroll.add_child(_form)
	right_split.add_child(scroll)

	var prev_scroll := ScrollContainer.new()
	prev_scroll.custom_minimum_size = Vector2(230, 0)
	prev_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_preview = VBoxContainer.new()
	_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview.add_theme_constant_override("separation", 6)
	prev_scroll.add_child(_preview)
	right_split.add_child(prev_scroll)
	_refresh_preview()

# 即时预览（SkillTooltip 共享渲染）：_mark_dirty 顺带刷新（表单未建全时 _form_ready 闸住防半构造 collect 崩）
func _refresh_preview() -> void:
	if _preview == null or not is_instance_valid(_preview):
		return
	for c in _preview.get_children():
		c.free()
	var title := Label.new()
	title.text = "预览（成品效果）"
	title.add_theme_color_override("font_color", Color("#EBBC04"))
	title.add_theme_font_size_override("font_size", 14)
	_preview.add_child(title)
	if not _form_ready or _w_id == null or not is_instance_valid(_w_id):
		var h := Label.new()
		h.text = "（编辑能力时此处即时显示）"
		h.add_theme_color_override("font_color", Color(0.55, 0.6, 0.66))
		h.add_theme_font_size_override("font_size", 12)
		_preview.add_child(h)
		return
	_preview.add_child(SkillTooltip.render(_shell_collect()))

func _mark_dirty() -> void:
	_dirty = true
	if _form_ready:
		_refresh_preview()

func _shell_show_empty() -> void:
	_clear_form()
	_select_row("")
	_w_id = null   # 无表单态（外壳按 _shell_has_entry 走）
	var hint := Label.new()
	hint.text = "← 选左侧能力编辑，或点「＋ 新建能力」；效果（buff/debuff）在右上「✨ 效果库」"
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.72))
	_form.add_child(hint)
	_dirty = false

# 清单：武器普攻 BWS / 主动 / 被动 三折叠组；组内按名字排序。
func _shell_populate_list(q: String) -> void:
	var searching := q != ""
	var groups := {"bws": [], "active": [], "passive": []}
	for id in SkillDB.all():
		var s = SkillDB.all()[id]
		var nm := str(s.get("name", id))
		if searching and not (str(id).to_lower().contains(q) or nm.to_lower().contains(q)):
			continue
		if SkillDB.is_weapon_skill(s):
			groups["bws"].append(s)   # 勾选制（🔒 决策29）：勾了武器技能＝可被武器选取；BWS/EWS 之分在武器侧
		elif bool(s.get("active", true)):
			groups["active"].append(s)
		else:
			groups["passive"].append(s)
	for g in [["active", "主动能力"], ["passive", "被动能力"], ["bws", "武器技能（勾选制——可被武器选取）"]]:
		var key := str(g[0])
		var arr: Array = groups[key]
		arr.sort_custom(func(a, b): return _sort_key(a) < _sort_key(b))
		var section := VBoxContainer.new()
		section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		section.add_theme_constant_override("separation", 2)
		for s in arr:
			var id := str(s.get("id", ""))
			var row := _make_row_card(id, TextureCache.get_tex(str(s.get("icon", ""))),
				str(s.get("name", id)), null, 42, Vector2(32, 32), str(s.get("desc", "")))
			section.add_child(row)
			_rows[id] = row
		if arr.is_empty():
			var hint := Label.new()
			hint.text = "（无匹配）" if searching else "（暂无）"
			hint.add_theme_color_override("font_color", Color(0.5, 0.54, 0.6))
			hint.add_theme_font_size_override("font_size", 12)
			section.add_child(hint)
		_add_fold_group(key, "%s (%d)" % [str(g[1]), arr.size()], section, searching)

func _sort_key(s: Dictionary) -> String:
	return str(s.get("name", "")).to_lower()


# —— 新建 / 载入 / 副本 ——

# 骨架＝canonical 键序（§2.1 示例序；字节级往返靠「duplicate 原条目+按键更新」保序）
func _skeleton() -> Dictionary:
	return {"id": "", "name": "新能力", "icon": "", "category": "skill", "desc": "",
		"active": true, "tags": [],
		"costs": {"ap": 1}, "cooldown": {"base": 0}, "uses_per_battle": {"base": 0},
		"max_level": 1, "target": {"enemy": true, "ally": false, "self": false},
		"range": 1, "effects": []}

func _open_skill(def: Dictionary, is_new: bool) -> void:
	_current = def
	_is_new = is_new
	_loaded_id = "" if is_new else str(def.get("id", ""))
	_build_form()
	_update_buttons()

func _shell_open_as_new(entry: Dictionary) -> void:
	_current = entry
	_is_new = true
	_loaded_id = ""
	_build_form()


# —— 表单 ——

func _clear_form() -> void:
	_form_ready = false   # 半构造期闸住预览的 _shell_collect（控件未建全会崩）
	for c in _form.get_children():
		c.queue_free()
	_tags = []
	_blocks = []

func _build_form() -> void:
	_clear_form()
	# 1. 基础
	_form.add_child(EditorUI.section_title("基础"))
	_w_id = EditorUI.add_line(_form, "id（唯一主键）", str(_current.get("id", "")), _mark_dirty)
	_w_name = EditorUI.add_line(_form, "名字", str(_current.get("name", "")), _mark_dirty)
	_build_icon_row()
	_w_desc = TextEdit.new()
	_w_desc.text = str(_current.get("desc", ""))
	_w_desc.custom_minimum_size = Vector2(0, 64)
	_w_desc.scroll_fit_content_height = true
	_w_desc.text_changed.connect(_mark_dirty)
	_form.add_child(EditorUI.field_row("描述 desc", _w_desc))
	# 类别 category（旧键 nature 兼容读——数据已迁，残档兜底；写盘只落 category）
	_w_category = _dropdown_pairs("类别 category", CATEGORIES, str(_current.get("category", _current.get("nature", "skill"))))
	_w_active = EditorUI.add_check(_form, "主动能力 active（关＝被动，状态页圆框陈列）", bool(_current.get("active", true)), _mark_dirty)
	# 无 seq 槽位（2026-07-13 废除）：旧「13 通用序列」随通用能力页退役，陈列排序归技能树轮

	# —— 武器技能（🔒 决策29 显式勾选制，翻案决策27 形状判定）：勾＝可被武器选取（BWS/EWS 之分武器侧定）——
	_w_wskill = EditorUI.add_check(_form, "武器技能 weapon_skill（勾＝可被武器选取为 BWS/EWS；等级钉 1——无升级）",
		bool(_current.get("weapon_skill", false)), func(_v = false):
			_mark_dirty()
			if _kind_box != null:
				_kind_box.visible = _w_wskill.button_pressed
			_update_shape_gray())
	_kind_box = VBoxContainer.new()
	_kind_box.add_theme_constant_override("separation", 2)
	var kb_hint := Label.new()
	kb_hint.text = "适用武器种类（动态 tag：被剑引用时才视为拥有 skill_sword——平时只带占位 skill_weapon）"
	kb_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	kb_hint.add_theme_font_size_override("font_size", 12)
	kb_hint.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
	_kind_box.add_child(kb_hint)
	_kind_checks = {}
	var cur_kinds: Array = _current.get("weapon_kinds", [])
	for cat in WEAPON_KIND_CATS:
		var flow := HFlowContainer.new()
		flow.add_theme_constant_override("h_separation", 8)
		var cl := Label.new()
		cl.text = str(cat[1]) + "："
		cl.add_theme_font_size_override("font_size", 12)
		flow.add_child(cl)
		for t in TagDB.by_cat(str(cat[0])):
			var tid := str(t.get("id", ""))
			var cb := CheckBox.new()
			cb.text = str(t.get("cn", tid))
			cb.tooltip_text = tid
			cb.button_pressed = tid in cur_kinds
			cb.toggled.connect(func(_on): _mark_dirty())
			flow.add_child(cb)
			_kind_checks[tid] = cb
		_kind_box.add_child(flow)
	# 握持要求（🔒 决策35 运行时可用性条件——菜单灰显「需单/双手持」；解锁归熟练度 requires，握持归状态判断；
	# BWS 禁带 grip〔普攻恒可用〕——武器编辑器 BWS 下拉已过滤带 grip 技能，lint 兜底）
	_w_grip = EditorUI.add_dropdown(_kind_box, "握持要求 grip（兼用武器单/双手形态专属招式；BWS 禁带）", GRIP_PAIRS,
		str(_current.get("grip", "")), _mark_dirty)
	_kind_box.visible = bool(_current.get("weapon_skill", false))
	_form.add_child(_kind_box)

	# —— 范围与形状（🔒 决策30 图形化；2026-07-13 UX 拍板：range 领衔、选取形默认＝range 可视化参考，
	# 勾「自定义攻击范围」才可点格编辑——以当前预览为底稿，长柄空内圈＝勾上后点掉内圈即可）——
	_form.add_child(EditorUI.section_title("范围与形状（range 定攻击范围；自定义后点格微调）"))
	var shp0: Dictionary = _current.get("shape", {}) if typeof(_current.get("shape")) == TYPE_DICTIONARY else {}
	var pick0: Array = shp0.get("pick", [])
	_w_range = EditorUI.add_spin(_form, "射程 range（格；0=自身/同格）——未自定义时选取形盘按此显示攻击范围", float(_current.get("range", 1)), 0, 20, 1,
		func():
			_mark_dirty()
			_sync_pick_preview())
	_w_custom_pick = EditorUI.add_check(_form, "自定义攻击范围（勾＝手动点格编辑选取形、取代 range；如长柄空出内圈）",
		not pick0.is_empty(), func(_v = false):
			_mark_dirty()
			if _w_pick == null:
				return
			if _w_custom_pick.button_pressed:
				_w_pick.editable = true   # 以当前预览为底稿开编
				_w_pick.queue_redraw()
			else:
				_sync_pick_preview()      # 弃自定义 → 回 range 派生参考盘
			_update_shape_gray())
	var shp_row := HBoxContainer.new()
	shp_row.add_theme_constant_override("separation", 14)
	_w_pick = _shape_picker_col(shp_row, "选取形（可瞄准的格；未自定义＝蓝灰参考盘，盘显示至 3 圈）", pick0)
	_w_effect = _shape_picker_col(shp_row, "作用形（AOE 打到的格；空＝单体打所点格）", shp0.get("effect", []))
	_form.add_child(shp_row)
	_w_anchor = EditorUI.add_dropdown(_form, "作用形锚点 anchor",
		[["caster", "锚定自身（按目标方向 60° 旋转——横扫弧）"], ["target", "锚定落点（平移到所点格——火球）"]],
		str(shp0.get("anchor", "caster")), func(_i = 0):
			_mark_dirty()
			_sync_pick_preview()
			_update_shape_gray())
	_w_ff = EditorUI.add_check(_form, "友伤 friendly_fire（AOE 可空放，故不设对敌/对友、只设是否伤及友军）",
		bool(shp0.get("friendly_fire", false)), _mark_dirty)
	_sync_pick_preview()   # 初始态：无自定义 → 盘显示 range 圆盘/方向盘参考

	# 2. 标签
	_form.add_child(EditorUI.section_title("技能标签（verbal=需发声、失语时禁用）"))
	_tags = []
	for t in _current.get("tags", []):
		_tags.append(str(t))
	EditorUI.add_tag_list(_form, "tags", _tags, _tag_options(), _mark_dirty)

	# 3. 成本 / 限制
	_form.add_child(EditorUI.section_title("成本 / 限制"))
	var costs = _current.get("costs", {})
	_w_ap = EditorUI.add_spin(_form, "AP 消耗 costs.ap（运行时钳底 1——决策21）",
		float(costs.get("ap", 1) if typeof(costs) == TYPE_DICTIONARY else _current.get("ap_cost", 1)), 0, 9, 1, _mark_dirty)
	_w_cd = EditorUI.add_spin(_form, "冷却 cooldown.base（回合；0=无冷却）",
		float((_current.get("cooldown", {}) as Dictionary).get("base", 0)), 0, 9, 1, _mark_dirty)
	_w_uses = EditorUI.add_spin(_form, "每战次数 uses_per_battle.base（0=无限 ∞）",
		float((_current.get("uses_per_battle", {}) as Dictionary).get("base", 0)), 0, 9, 1, _mark_dirty)
	_w_maxlv = EditorUI.add_spin(_form, "技能等级数 max_level（各级参数=per_level 数组长度；武器技能钉 1——无升级）",
		float(_current.get("max_level", 1)), 1, 5, 1, _mark_dirty)
	_update_shape_gray()   # 初始灰化态（range 被自定义/方向盘顶掉、武器技能等级钉 1——range 本体在形状区领衔）
	# 目标三旗（🔒 §2.7 正交自由组合；全 false=永不可施放，存盘拦）
	var trow := HBoxContainer.new()
	trow.add_theme_constant_override("separation", 12)
	var tg = _current.get("target", {"enemy": false, "ally": true, "self": true})
	if typeof(tg) != TYPE_DICTIONARY:
		tg = {}
	_w_t_enemy = _flag_check(trow, "敌方 enemy", bool(tg.get("enemy", false)))
	_w_t_ally = _flag_check(trow, "友方 ally", bool(tg.get("ally", false)))
	_w_t_self = _flag_check(trow, "自身 self", bool(tg.get("self", false)))
	_form.add_child(EditorUI.field_row("目标资格 target", trow))
	# §25 被动灰化联动：被动能力不施放——AP/冷却/次数/射程/目标不适用（只灰不清：收集仍读原值，字节级保留；
	# 技能等级 max_level 仍有效——训练有素 I/II/III 属被动多级）
	_w_passive_hint = _warn("被动能力（active 关）不施放：AP/冷却/次数/射程/目标不生效——字段只灰不清、保存原样保留", HINT_COLOR)
	_form.add_child(_w_passive_hint)
	_w_active.toggled.connect(func(_v): _update_passive_gray())
	_update_passive_gray()

	# 4. 效果块 effects[]（§3 调色盘；v1 五种可编）
	# （手部门槛 requires_hands 已删 2026-07-13 用户拍板——位置语义〔决策31〕后零用例：
	#   盾击=盾种类 WS 手位自定、双手斩=双手武器自己的 WS；collect 随存清键）
	_form.add_child(EditorUI.section_title("效果块 effects（技能＝效果块拼装；按序结算）"))
	_blocks_box = VBoxContainer.new()
	_blocks_box.add_theme_constant_override("separation", 8)
	_form.add_child(_blocks_box)
	for b in _current.get("effects", []):
		if typeof(b) == TYPE_DICTIONARY:
			_add_block(b)
	var addrow := HBoxContainer.new()
	addrow.add_theme_constant_override("separation", 6)
	_block_pick = OptionButton.new()
	for p in BLOCK_KINDS:
		_block_pick.add_item(str(p[1]))
		_block_pick.set_item_metadata(_block_pick.item_count - 1, str(p[0]))
	addrow.add_child(_block_pick)
	var addb := Button.new()
	addb.text = "＋ 添加效果块"
	addb.pressed.connect(func():
		_add_block(_block_skeleton(str(_block_pick.get_selected_metadata())))
		_mark_dirty())
	addrow.add_child(addb)
	_form.add_child(addrow)

	_form_ready = true
	_refresh_preview()   # 载入完成 → 首刷预览
	_dirty = false   # 建表单期间控件信号可能置脏——载入完成＝干净基线

# §25 被动灰化联动：active 实时切换成本/限制段可编性——灰化只锁输入不动值（勿静默清数据）
func _update_passive_gray() -> void:
	if _w_active == null or not is_instance_valid(_w_active):
		return
	var passive := not _w_active.button_pressed
	_w_passive_hint.visible = passive
	for sp in [_w_ap, _w_cd, _w_uses, _w_range]:
		(sp as SpinBox).editable = not passive
	for cb in [_w_t_enemy, _w_t_ally, _w_t_self]:
		(cb as CheckBox).disabled = passive

func _flag_check(parent: Node, label: String, v: bool) -> CheckBox:
	var cb := CheckBox.new()
	cb.text = label
	cb.button_pressed = v
	cb.toggled.connect(func(_v): _mark_dirty())
	parent.add_child(cb)
	return cb

func _dropdown_pairs(label: String, pairs: Array, sel: String) -> OptionButton:
	var ob := OptionButton.new()
	for p in pairs:
		ob.add_item(str(p[1]))
		ob.set_item_metadata(ob.item_count - 1, str(p[0]))
	_select_meta(ob, sel)
	ob.item_selected.connect(func(_i): _mark_dirty())
	_form.add_child(EditorUI.field_row(label, ob))
	return ob

# range/等级的联动灰化（决策30 收口）：自定义选取形 或 作用形锚自身 → range 被顶掉（灰化+存盘清键；
# 火球型〔锚落点、无自定义选取形〕仍靠 range 定投掷距离）；勾武器技能 → max_level 钉 1（武器技能无升级）
func _update_shape_gray() -> void:
	if _w_range == null:
		return
	var superseded := _range_superseded()
	_w_range.editable = not superseded
	_w_range.modulate = Color(0.55, 0.55, 0.6) if superseded else Color.WHITE
	if _w_maxlv == null:
		return
	var ws: bool = _w_wskill != null and _w_wskill.button_pressed
	if ws:
		_w_maxlv.value = 1
	_w_maxlv.editable = not ws
	_w_maxlv.modulate = Color(0.55, 0.55, 0.6) if ws else Color.WHITE

func _range_superseded() -> bool:
	if _w_pick == null or _w_effect == null or _w_custom_pick == null:
		return false
	if _w_custom_pick.button_pressed and not (_w_pick.mask() as Array).is_empty():
		return true
	return not (_w_effect.mask() as Array).is_empty() and str(_w_anchor.get_selected_metadata()) == "caster"

# 选取形参考盘同步（2026-07-13 UX 拍板）：未勾自定义 → 盘只读、显示派生预览
# （作用形锚自身＝六旋转方向盘；否则＝range 圆盘）——所见即战斗侧实际可点格（_shape_pick_cells 同口径）
func _sync_pick_preview() -> void:
	if _w_pick == null or _w_custom_pick == null:
		return
	if _w_custom_pick.button_pressed:
		_w_pick.editable = true
		return
	_w_pick.editable = false
	_w_pick.set_mask(_derived_pick_mask())

func _derived_pick_mask() -> Array:
	var effm: Array = _w_effect.mask() if _w_effect != null else []
	if not effm.is_empty() and _w_anchor != null and str(_w_anchor.get_selected_metadata()) == "caster":
		var seen := {}
		var out := []
		for k in 6:
			for m in effm:
				var d := HexGrid.axial_rotate(Vector2i(int(m[0]), int(m[1])), k)
				if not seen.has(d):
					seen[d] = true
					out.append([d.x, d.y])
		return out
	var rng := int(_w_range.value) if _w_range != null else 1
	var out2 := []
	for q in range(-rng, rng + 1):
		for r in range(-rng, rng + 1):
			var dist := int((abs(q) + abs(-q - r) + abs(r)) / 2)
			if dist >= 1 and dist <= rng:
				out2.append([q, r])
	return out2

# 形状盘列（标题 + 六边形点格盘 + 清空钮）——选取形/作用形两处共用（🔒 决策30）
func _shape_picker_col(parent: Control, title: String, mask) -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	var l := Label.new()
	l.text = title
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(170, 0)
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
	col.add_child(l)
	var p := HexShapePicker.new()
	p.set_mask(mask if typeof(mask) == TYPE_ARRAY else [])
	p.changed.connect(func():
		_mark_dirty()
		_update_shape_gray())
	col.add_child(p)
	var clr := Button.new()
	clr.text = "清空"
	clr.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	clr.pressed.connect(p.clear_mask)
	col.add_child(clr)
	parent.add_child(col)
	return p

func _build_icon_row() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var lbl := Label.new()
	lbl.text = "图标 icon"
	lbl.custom_minimum_size = Vector2(200, 0)
	row.add_child(lbl)
	_icon_thumb = TextureRect.new()
	_icon_thumb.custom_minimum_size = Vector2(28, 28)
	_icon_thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon_thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon_thumb.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_icon_thumb.texture = TextureCache.get_tex(str(_current.get("icon", "")))
	row.add_child(_icon_thumb)
	_w_icon = LineEdit.new()
	_w_icon.text = str(_current.get("icon", ""))
	_w_icon.placeholder_text = ICON_DIR + "/...png"
	_w_icon.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_w_icon.text_changed.connect(func(_t):
		_icon_thumb.texture = TextureCache.get_tex(_w_icon.text.strip_edges())
		_mark_dirty())
	row.add_child(_w_icon)
	var browse := Button.new()
	browse.text = "浏览…"
	browse.pressed.connect(_open_icon_dialog)
	row.add_child(browse)
	_form.add_child(row)

func _open_icon_dialog() -> void:
	if _file_dialog == null or not is_instance_valid(_file_dialog):
		_file_dialog = EditorUI.make_file_dialog(FileDialog.FILE_MODE_OPEN_FILE, FileDialog.ACCESS_RESOURCES,
			[["*.png", "PNG"], ["*.jpg,*.jpeg", "JPG"], ["*.webp", "WebP"]], false)
		_file_dialog.file_selected.connect(func(path):
			EditorUI.remember_dir("skill_icon", path)   # 记住上次目录（跨编辑器共享缓存）
			if _w_icon != null and is_instance_valid(_w_icon):
				_w_icon.text = path
				_icon_thumb.texture = TextureCache.get_tex(path)
				_mark_dirty())
		add_child(_file_dialog)
	_file_dialog.current_dir = EditorUI.recall_dir("skill_icon", ICON_DIR)
	_file_dialog.popup_centered(Vector2i(760, 520))

# 技能 tag 下拉预设：技能行为类别 + 手动（weapon_* 种类词走 weapon_kinds〔决策29〕，不进 tags）
func _tag_options() -> Array:
	var out := []
	for c in SKILL_TAG_CATS:
		var ids := TagDB.ids_in_cat(c)
		if ids.is_empty():
			continue
		out.append(["sep", c])
		for id in ids:
			out.append([id, "%s（%s）" % [TagDB.cn(id), id]])
	return out


func _split_tags(text: String) -> Array:
	var out := []
	for p in text.split(","):
		var t := str(p).strip_edges()
		if t != "" and not out.has(t):
			out.append(t)
	return out


# —— 效果块 ——

func _block_skeleton(kind: String) -> Dictionary:
	match kind:
		"attack":
			return {"kind": "attack", "hits": [{"coeff": 1.0, "damage_category": "physical"}]}
		"heal":
			return {"kind": "heal", "heal_pct_max_hp": 0, "cleanse_tags": []}
		"passive_stat_mods":
			return {"kind": "passive_stat_mods", "mods": []}
		"conditional_mod":
			return {"kind": "conditional_mod", "when": [], "mods": []}
		"apply_effect":
			return {"kind": "apply_effect", "effect": "", "chance": 100}
		_:
			return {"kind": "scripted", "script_id": "", "params": {}}

# 一个效果块＝带边框面板：头（折叠钮 + kind 名 + ↑/↓ 调序 + ✕）+ body（kind 专属字段，可折叠）。
# data 原样持有，collect 时 duplicate+更新。折叠纯视觉不置脏；调序置脏（§24：效果块按序结算，序有编辑权）。
func _add_block(data: Dictionary) -> void:
	var kind := str(data.get("kind", ""))
	var panel := PanelContainer.new()
	var sb := EditorTheme.sb(Color(0.14, 0.15, 0.19), Color(0.3, 0.34, 0.42))
	sb.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	panel.add_child(box)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 4)
	# 折叠钮（§24）：块头带 ↑/↓/✕ 操作钮、EditorUI.make_foldable 的整条头按钮容不下——本地小三角同语义
	var fold := Button.new()
	fold.toggle_mode = true
	fold.button_pressed = true
	fold.text = "▾"
	fold.focus_mode = Control.FOCUS_NONE
	head.add_child(fold)
	var kind_cn := kind
	for p in BLOCK_KINDS:
		if str(p[0]) == kind:
			kind_cn = str(p[1])
			break
	var title := Label.new()
	title.text = "▪ " + kind_cn
	title.add_theme_color_override("font_color", Color(0.75, 0.85, 1.0))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var up := Button.new()
	up.text = "↑"
	up.tooltip_text = "上移（效果块按序结算）"
	head.add_child(up)
	var dn := Button.new()
	dn.text = "↓"
	dn.tooltip_text = "下移（效果块按序结算）"
	head.add_child(dn)
	var rm := Button.new()
	rm.text = "✕"
	head.add_child(rm)
	box.add_child(head)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 4)
	box.add_child(body)
	var entry := {"data": data, "kind": kind, "panel": panel, "locked": false}
	fold.toggled.connect(func(open: bool):
		body.visible = open
		fold.text = "▾" if open else "▸")
	up.pressed.connect(func(): _move_block(entry, -1))
	dn.pressed.connect(func(): _move_block(entry, +1))
	rm.pressed.connect(func():
		_blocks.erase(entry)
		panel.queue_free()
		_mark_dirty())
	match kind:
		"attack":
			_build_attack_block(body, entry)
		"heal":
			_build_heal_block(body, entry)
		"passive_stat_mods":
			_build_passive_block(body, entry)
		"conditional_mod":
			_build_conditional_block(body, entry)
		"apply_effect":
			_build_apply_effect_block(body, entry)
		"scripted":
			_build_scripted_block(body, entry)
		_:
			entry["locked"] = true
			body.add_child(_warn("未知块 kind「%s」——本版不编辑，保存原样保留（运行时警告跳过）" % kind, WARN_COLOR))
	_blocks_box.add_child(panel)
	_blocks.append(entry)

# 块调序（§24）：收集序＝_blocks 数组序——数组交换 + 面板按邻居实际下标换位
# （✕ 是 queue_free 延迟摘树，按 get_index 取位不受僵尸子节点影响）
func _move_block(entry: Dictionary, delta: int) -> void:
	var i := _blocks.find(entry)
	var j := i + delta
	if i < 0 or j < 0 or j >= _blocks.size():
		return
	var other: Dictionary = _blocks[j]
	_blocks[i] = other
	_blocks[j] = entry
	_blocks_box.move_child(entry["panel"], (other["panel"] as Control).get_index())
	_mark_dirty()

func _warn(text: String, color: Color) -> Label:
	var l := Label.new()
	l.text = "⚠ " + text
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", 12)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l

# attack：v1 编单 hit 的 系数/修正/命中/伤害属性/伤害类型/破甲/必中（2026-07-13 用户定序）；多 hits/riders＝阶段6 禁入库→锁定只读。
func _build_attack_block(box: VBoxContainer, entry: Dictionary) -> void:
	var hits: Array = entry["data"].get("hits", [])
	var has_riders := false
	for h in hits:
		if typeof(h) == TYPE_DICTIONARY and h.has("riders"):
			has_riders = true
	if hits.size() > 1 or has_riders:
		entry["locked"] = true
		box.add_child(_warn("多段 hits / riders＝阶段6（lint 护栏#1 现禁入库）——本块锁定只读，保存原样保留", LOCK_COLOR))
		return
	var hit: Dictionary = hits[0] if hits.size() == 1 and typeof(hits[0]) == TYPE_DICTIONARY else {}
	if hit.has("weapon_source"):
		box.add_child(_warn("weapon_source=off_hand：结算吃副手惩罚 ×offhand_eff/100（🔒 决策5 阶段3b 已生效；盾豁免）", HINT_COLOR))
	entry["coeff"] = _add_formula(box, "伤害系数 coeff", hit.get("coeff", 1.0), false)   # 攻击块无逐级（用户裁定：武器技能无升级，per_level 在此已死）
	# 命中系数：设计层可破 100% 也可为负（用户拍板）——编辑器不设 0~100 框，引擎端最终 clamp 5~95 在对抗之后
	entry["hit"] = EditorUI.add_spin(box, "命中系数 hit（%）", float(hit.get("hit", 0)), -999.0, 999.0, 1.0, _mark_dirty)
	entry["damage_category"] = EditorUI.add_dropdown(box, "伤害属性 damage_category", DAMAGE_CATEGORIES,
		str(hit.get("damage_category", hit.get("damage_kind", "physical"))), _mark_dirty)   # 旧键 damage_kind 随存即迁
	entry["damage_type"] = EditorUI.add_dropdown(box, "伤害类型 damage_type", DAMAGE_TYPES,
		str(hit.get("damage_type", "")), _mark_dirty)
	entry["armor_pen"] = EditorUI.add_spin(box, "破甲 armor_pen（0~1：0.3=30% 直击人体，1=无视护甲）", clampf(float(hit.get("armor_pen", 0)), 0.0, 1.0), 0.0, 1.0, 0.01, _mark_dirty)
	entry["sure_hit"] = EditorUI.add_check(box, "必中 sure_hit（无视命中对抗）", bool(hit.get("sure_hit", false)), _mark_dirty)
	# On-Hit Effects（🔒 2026-07-15 键级统一，用户令：与武器侧同性质只是来源不同——原「命中施加 inflict」
	# 单条对象改为同形 on_hit_effects 数组；旧键随存即迁、lint 禁回流；效果下拉只列 on_hit_ok 白名单）
	var inf0 = hit.get("inflict", null)
	if typeof(inf0) == TYPE_DICTIONARY and not inf0.is_empty() and not inf0.has("effect"):
		entry["inflict_locked"] = true
		box.add_child(_warn("inflict 为旧内联形（无 effect 引用键）——本行锁定，保存原样保留（lint 会催迁）", LOCK_COLOR))
	else:
		box.add_child(EditorUI.label("On-Hit Effects（用这招打中时施加；与武器面板的 On-Hit 叠加合并——同 id 概率取高/同族按优先级）"))
		var ob_box := VBoxContainer.new()
		ob_box.add_theme_constant_override("separation", 4)
		box.add_child(ob_box)
		entry["onhit_box"] = ob_box
		entry["onhit_rows"] = []
		for se in hit.get("on_hit_effects", []):
			if typeof(se) == TYPE_DICTIONARY:
				_add_skill_onhit_row(entry, str(se.get("effect", "")), float(se.get("chance", 100)))
		if typeof(inf0) == TYPE_DICTIONARY and str(inf0.get("effect", "")) != "":
			_add_skill_onhit_row(entry, str(inf0.get("effect", "")), float(inf0.get("chance", 100)))   # 旧 inflict → 行（随存即迁）
		var addoh := Button.new()
		addoh.text = "＋ 添加 On-Hit 效果"
		addoh.pressed.connect(func():
			_add_skill_onhit_row(entry, "", 100.0)
			_mark_dirty())
		box.add_child(addoh)
	box.add_child(_warn("aoe / bonus / ignore_* 等高级字段本版不编辑，保存原样保留", WARN_COLOR))

# 一条技能侧 On-Hit：效果下拉（只列 on_hit_ok=true 的效果——效果库勾选白名单）+ 概率% + ✕
# （与 ItemEditor._add_onhit_row 同形；🔒 2026-07-15 键级统一）
func _add_skill_onhit_row(entry: Dictionary, effect_id: String, chance: float) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var ob := OptionButton.new()
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ob.add_item("（选效果…）")
	ob.set_item_metadata(0, "")
	for id in EffectDB.all():
		var e = EffectDB.all()[id]
		if not bool(e.get("on_hit_ok", false)):
			continue   # 白名单：效果库勾了「可作 On-Hit 引用」才列（悬空/未勾旧值经 _ensure_meta_option 保值）
		ob.add_item("%s（%s）" % [str(e.get("name", id)), str(id)])
		ob.set_item_metadata(ob.item_count - 1, str(id))
	_ensure_meta_option(ob, effect_id)
	_select_meta(ob, effect_id)
	ob.item_selected.connect(func(_i): _mark_dirty())
	row.add_child(ob)
	var chl := Label.new()
	chl.text = "概率%"
	chl.add_theme_font_size_override("font_size", 12)
	row.add_child(chl)
	var ch := SpinBox.new()
	ch.min_value = 1
	ch.max_value = 100
	ch.step = 1
	ch.value = chance
	ch.value_changed.connect(func(_v): _mark_dirty())
	row.add_child(ch)
	var rm := Button.new()
	rm.text = "✕"
	var rentry := {"row": row, "effect": ob, "chance": ch}
	rm.pressed.connect(func():
		(entry["onhit_rows"] as Array).erase(rentry)
		row.queue_free()
		_mark_dirty())
	row.add_child(rm)
	(entry["onhit_box"] as VBoxContainer).add_child(row)
	(entry["onhit_rows"] as Array).append(rentry)

func _build_heal_block(box: VBoxContainer, entry: Dictionary) -> void:
	entry["heal_pct"] = _add_formula(box, "治疗量 heal_pct_max_hp（%最大生命）", entry["data"].get("heal_pct_max_hp", 0))
	var ct := []
	for t in entry["data"].get("cleanse_tags", []):
		ct.append(str(t))
	entry["cleanse"] = ct
	var opts := []
	for c in ["effect", "effect_dim"]:
		for id in TagDB.ids_in_cat(c):
			opts.append([id, "%s（%s）" % [TagDB.cn(id), id]])
	EditorUI.add_tag_list(box, "清除效果 tag cleanse_tags", ct, opts, _mark_dirty)

func _build_passive_block(box: VBoxContainer, entry: Dictionary) -> void:
	box.add_child(_warn("被动桥已生效（🔒 阶段4 2026-07-11）：学得即挂修正 source=skill:<id>，升级重挂、数值可用公式随级", HINT_COLOR))
	# 公式值护栏（审查修复，同多 hits 先例）：mod value 为公式对象时本版表单只有标量 Spin——
	# 强行建表单＝float() 转换错 + 保存把公式扁平化毁数据 → 整块锁定只读、保存原样保留
	for m0 in entry["data"].get("mods", []):
		if typeof(m0) == TYPE_DICTIONARY and not typeof(m0.get("value", 0)) in [TYPE_INT, TYPE_FLOAT]:
			entry["locked"] = true
			box.add_child(_warn("含公式值修正（{base/per_stat/per_level}）——本版表单仅编标量，本块锁定只读，保存原样保留（conditional_mod 表单轮补公式控件）", LOCK_COLOR))
			return
	var rows := []
	entry["mods"] = rows
	var mods_box := VBoxContainer.new()
	mods_box.add_theme_constant_override("separation", 4)
	box.add_child(mods_box)
	for m in entry["data"].get("mods", []):
		if typeof(m) == TYPE_DICTIONARY:
			EditorUI.add_mod_row(mods_box, rows, StatMeta.EDITOR_STATS,
				str(m.get("stat", "atk")), str(m.get("op", "flat")), float(m.get("value", 0)), _mark_dirty)
	var addm := Button.new()
	addm.text = "＋ 添加修正"
	addm.pressed.connect(func():
		EditorUI.add_mod_row(mods_box, rows, StatMeta.EDITOR_STATS, "atk", "flat", 0.0, _mark_dirty)
		_mark_dirty())
	box.add_child(addm)

# conditional_mod（🔒 §3/§4）：when[] 激活条件（行控件在 EditorUI，词表 v1 与将来技能树共用）+ mods。
# 引擎阶段4 已生效：学得挂修正、_mod_active 按 when 惰性判（🔒 §4.3 when 读裸 stats——故 stat 下拉含 HP）。
func _build_conditional_block(box: VBoxContainer, entry: Dictionary) -> void:
	box.add_child(_warn("条件被动已生效（🔒 阶段4）：学得即挂修正，when 全满足才计入（数组内 AND；when 读裸 stats §4.3）", HINT_COLOR))
	# 公式值护栏（同被动块先例）：mod value 为公式对象时本版表单只有标量 Spin——整块锁定只读
	for m0 in entry["data"].get("mods", []):
		if typeof(m0) == TYPE_DICTIONARY and not typeof(m0.get("value", 0)) in [TYPE_INT, TYPE_FLOAT]:
			entry["locked"] = true
			box.add_child(_warn("含公式值修正（{base/per_stat/per_level}）——本版表单仅编标量，本块锁定只读，保存原样保留", LOCK_COLOR))
			return
	var wopts := _when_opts()
	box.add_child(EditorUI.label("激活条件 when（全部满足才生效；空＝无条件恒生效）"))
	var when_rows := []
	entry["when_rows"] = when_rows
	var when_box := VBoxContainer.new()
	when_box.add_theme_constant_override("separation", 4)
	box.add_child(when_box)
	entry["when_box"] = when_box
	for c in entry["data"].get("when", []):
		if typeof(c) == TYPE_DICTIONARY:
			EditorUI.add_when_row(when_box, when_rows, c, wopts, _mark_dirty)
	var addw := Button.new()
	addw.text = "＋ 添加条件"
	addw.pressed.connect(func():
		EditorUI.add_when_row(when_box, when_rows, {"type": "stat_threshold"}, wopts, _mark_dirty)
		_mark_dirty())
	box.add_child(addw)
	box.add_child(EditorUI.label("修正 mods（条件满足时计入）"))
	var rows := []
	entry["mods"] = rows
	var mods_box := VBoxContainer.new()
	mods_box.add_theme_constant_override("separation", 4)
	box.add_child(mods_box)
	entry["mods_box"] = mods_box
	for m in entry["data"].get("mods", []):
		if typeof(m) == TYPE_DICTIONARY:
			EditorUI.add_mod_row(mods_box, rows, StatMeta.EDITOR_STATS,
				str(m.get("stat", "atk")), str(m.get("op", "flat")), float(m.get("value", 0)), _mark_dirty)
	var addm := Button.new()
	addm.text = "＋ 添加修正"
	addm.pressed.connect(func():
		EditorUI.add_mod_row(mods_box, rows, StatMeta.EDITOR_STATS, "atk", "flat", 0.0, _mark_dirty)
		_mark_dirty())
	box.add_child(addm)

# when 行备料（词表控件在 EditorUI、领域数据在这备）：stat 键序＝裸 stats 可阈值键
# （🔒 §4.3 when 读裸 stats——运行态 HP 也可作阈值，训练有素 HP%≤50 即此形）
func _when_opts() -> Dictionary:
	var eo := []
	for id in EffectDB.all():
		var e = EffectDB.all()[id]
		eo.append([str(id), "%s（%s）" % [str(e.get("name", id)), str(id)]])
	return {"stat_keys": ["HP"] + StatMeta.EDITOR_STATS, "effect_options": eo, "slot_pairs": HAND_SLOTS}

func _build_apply_effect_block(box: VBoxContainer, entry: Dictionary) -> void:
	# 公式值护栏（同上）：chance 为公式对象（引擎 resolve_num 支持）时锁定只读，防 float() 报错+扁平化
	if not typeof(entry["data"].get("chance", 100)) in [TYPE_INT, TYPE_FLOAT]:
		entry["locked"] = true
		box.add_child(_warn("chance 为公式值——本版表单仅编标量，本块锁定只读，保存原样保留", LOCK_COLOR))
		return
	var ob := OptionButton.new()
	ob.add_item("（选效果…）")
	ob.set_item_metadata(0, "")
	for id in EffectDB.all():
		var e = EffectDB.all()[id]
		ob.add_item("%s（%s）" % [str(e.get("name", id)), str(id)])
		ob.set_item_metadata(ob.item_count - 1, str(id))
	_ensure_meta_option(ob, str(entry["data"].get("effect", "")))   # 悬空引用保值（§3-1 守卫上提后补挂）
	_select_meta(ob, str(entry["data"].get("effect", "")))
	ob.item_selected.connect(func(_i): _mark_dirty())
	var erow := HBoxContainer.new()   # §26：下拉 + ↗ 跳效果库定位（与 ItemEditor BWS/EWS 同款机制）
	erow.add_theme_constant_override("separation", 6)
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	erow.add_child(ob)
	var jump := Button.new()
	jump.text = "↗"
	jump.tooltip_text = "在效果库中打开该效果（有未保存修改会先确认）"
	jump.focus_mode = Control.FOCUS_NONE
	jump.pressed.connect(func():
		var eid := str(ob.get_selected_metadata())
		if eid == "":
			_info("未选效果——无处可跳")
			return
		_confirm_discard(func():
			EffectEditorScript._open_with_id = eid
			get_tree().change_scene_to_file("res://EffectEditor.tscn")))
	erow.add_child(jump)
	box.add_child(EditorUI.field_row("效果 effect（EffectDB 引用；🔒 对象形禁裸串）", erow))
	entry["effect"] = ob
	entry["chance"] = EditorUI.add_spin(box, "施加概率 chance（%；resist 效果另有强韧豁免）",
		float(entry["data"].get("chance", 100)), 1, 100, 1, _mark_dirty)
	if EffectDB.all().is_empty():
		box.add_child(_warn("效果库为空——先去「✨ 效果库」建效果", WARN_COLOR))

func _build_scripted_block(box: VBoxContainer, entry: Dictionary) -> void:
	box.add_child(_warn("scripted＝逃生舱：script_id 需代码侧注册，未注册＝运行时警告跳过", WARN_COLOR))
	entry["script_id"] = EditorUI.add_line(box, "脚本 id script_id", str(entry["data"].get("script_id", "")), _mark_dirty)
	var pt := TextEdit.new()
	var params = entry["data"].get("params", {})
	pt.text = JSON.stringify(params, "  ") if typeof(params) == TYPE_DICTIONARY and not params.is_empty() else ""
	pt.custom_minimum_size = Vector2(0, 56)
	pt.scroll_fit_content_height = true
	pt.placeholder_text = "{ \"key\": value } 参数字典 JSON（空=无参数；存盘时解析校验）"
	pt.text_changed.connect(_mark_dirty)
	box.add_child(EditorUI.field_row("参数 params", pt))
	entry["params"] = pt


# —— 公式三段控件（🔒 §2.4：基础值 + 缩放属性×系数 + 逐级数组；无表达式解析器）——
# 收集规则（canonical 最小键）：无 per_stat 且无 per_level → 落标量；否则对象 {base?, per_stat?, per_level?}
# （base=0 省略、空段省略——{"per_level":[...]} 最小键形，保字节级往返）。
func _add_formula(box: VBoxContainer, label: String, v, show_levels := true) -> Dictionary:
	var base := 0.0
	var stat := ""
	var weight := 0.0
	var levels := ""
	match typeof(v):
		TYPE_INT, TYPE_FLOAT:
			base = float(v)
		TYPE_DICTIONARY:
			base = float(v.get("base", 0.0))
			var per = v.get("per_stat", {})
			if typeof(per) == TYPE_DICTIONARY and per.size() > 0:
				stat = str(per.keys()[0])
				weight = float(per[per.keys()[0]])
			var pl = v.get("per_level", [])
			if typeof(pl) == TYPE_ARRAY and pl.size() > 0:
				levels = ", ".join(pl.map(func(x): return str(x)))
	var bs := SpinBox.new()
	bs.min_value = 0
	bs.max_value = 999
	bs.step = 0.05
	bs.value = base
	bs.custom_minimum_size = Vector2(90, 0)
	bs.value_changed.connect(func(_v): _mark_dirty())
	box.add_child(EditorUI.field_row(label, bs))
	# 属性修正独立行（2026-07-13 用户令：不与基础值同行）——可选 per_stat：值＝基础＋属性×系数
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 6)
	var st := OptionButton.new()
	st.add_item("（无）")
	st.set_item_metadata(0, "")
	for key in StatMeta.EDITOR_STATS:
		st.add_item("%s %s" % [key, StatMeta.label(str(key))])
		st.set_item_metadata(st.item_count - 1, str(key))
	_select_meta(st, stat)
	st.item_selected.connect(func(_i): _mark_dirty())
	row2.add_child(st)
	row2.add_child(EditorUI.label("×"))
	var ws := SpinBox.new()
	ws.min_value = -99
	ws.max_value = 99
	ws.step = 0.01
	ws.value = weight
	ws.custom_minimum_size = Vector2(90, 0)
	ws.value_changed.connect(func(_v): _mark_dirty())
	row2.add_child(ws)
	box.add_child(EditorUI.field_row("　　＋属性修正 per_stat（可选：随属性成长）", row2))
	var lv: LineEdit = null
	if show_levels:
		lv = LineEdit.new()
		lv.text = levels
		lv.placeholder_text = "逐级数组 per_level 逗号分隔（长度须==max_level；填了则替代基础值档）"
		lv.text_changed.connect(func(_t): _mark_dirty())
		box.add_child(EditorUI.field_row("　　逐级 per_level", lv))
	var multi_per := typeof(v) == TYPE_DICTIONARY and typeof(v.get("per_stat", {})) == TYPE_DICTIONARY and (v.get("per_stat", {}) as Dictionary).size() > 1
	if multi_per:
		box.add_child(_warn("per_stat 多键——控件只编首键，其余保存原样保留", WARN_COLOR))
	return {"base": bs, "stat": st, "weight": ws, "levels": lv, "orig": v, "multi_per": multi_per}

# 公式收集：解析失败（per_level 非数字）→ 置 _collect_err
var _collect_err := ""

func _collect_formula(w: Dictionary):
	var base := float(w["base"].value)
	var stat := str(w["stat"].get_selected_metadata())
	var weight := float(w["weight"].value)
	var lv_text := str(w["levels"].text).strip_edges() if w["levels"] != null else ""   # 无逐级控件（攻击块）＝恒空，存盘自然清 per_level
	var per_level := []
	if lv_text != "":
		for p in lv_text.split(","):
			var s := str(p).strip_edges()
			if s == "" or not s.is_valid_float():
				_collect_err = "per_level「%s」不是数字（逗号分隔的数值列表）" % s
				return null
			per_level.append(_num(s.to_float()))
	var per_stat := {}
	if w.get("multi_per", false):   # 多键：以原对象为底，只更新首键
		per_stat = (w["orig"].get("per_stat", {}) as Dictionary).duplicate(true)
		if stat != "":
			per_stat[stat] = _num(weight)
	elif stat != "" and weight != 0.0:
		per_stat[stat] = _num(weight)
	if per_stat.is_empty() and per_level.is_empty():
		return _num(base)
	var out := {}
	if base != 0.0:
		out["base"] = _num(base)
	if not per_stat.is_empty():
		out["per_stat"] = per_stat
	if not per_level.is_empty():
		out["per_level"] = per_level
	return out

func _num(v: float):
	return int(v) if v == floorf(v) else v


# —— 收集 / 校验（与 test_data_lint 规则7 对齐）——

func _shell_collect() -> Dictionary:
	_collect_err = ""
	var out: Dictionary = _current.duplicate(true)   # duplicate+按键更新＝保留键序与未编辑字段（字节级往返）
	out["id"] = _w_id.text.strip_edges()
	out["name"] = _w_name.text.strip_edges()
	out["icon"] = _w_icon.text.strip_edges()
	out["category"] = str(_w_category.get_selected_metadata())
	out.erase("nature")   # 旧键随存即迁（2026-07-13 改词 nature→category）
	out["desc"] = _w_desc.text
	out["active"] = _w_active.button_pressed
	out["tags"] = _tags.duplicate()
	var costs: Dictionary = out.get("costs", {}) if typeof(out.get("costs")) == TYPE_DICTIONARY else {}
	costs["ap"] = int(_w_ap.value)
	out["costs"] = costs
	out.erase("ap_cost")   # 双键禁写（lint 规则7）：数据侧只留 costs.ap，旧顶层键剥掉
	var cd: Dictionary = out.get("cooldown", {}) if typeof(out.get("cooldown")) == TYPE_DICTIONARY else {}
	cd["base"] = int(_w_cd.value)
	out["cooldown"] = cd
	var uses: Dictionary = out.get("uses_per_battle", {}) if typeof(out.get("uses_per_battle")) == TYPE_DICTIONARY else {}
	uses["base"] = int(_w_uses.value)
	out["uses_per_battle"] = uses
	out["max_level"] = int(_w_maxlv.value)
	out["target"] = {"enemy": _w_t_enemy.button_pressed, "ally": _w_t_ally.button_pressed, "self": _w_t_self.button_pressed}
	out["range"] = int(_w_range.value)
	out.erase("seq")   # 旧键随存即清（2026-07-13 通用序列废除）
	# 武器技能（🔒 决策29）：勾了才落键；适用种类按 wcat 词表序收集（确定序，字节往返友好）
	if _w_wskill != null and _w_wskill.button_pressed:
		out["weapon_skill"] = true
		var kinds := []
		for tid in _kind_checks:
			if (_kind_checks[tid] as CheckBox).button_pressed:
				kinds.append(tid)
		out["weapon_kinds"] = kinds
		# 握持要求（🔒 决策35）：（不限）＝不落键
		var gv := str(_w_grip.get_selected_metadata()) if _w_grip != null and is_instance_valid(_w_grip) else ""
		if gv != "":
			out["grip"] = gv
		else:
			out.erase("grip")
	else:
		out.erase("weapon_skill")
		out.erase("weapon_kinds")
		out.erase("grip")   # 握持条件只属武器技能（决策35）
	# 形状（🔒 决策30）：选取形只在勾了「自定义攻击范围」时收集（未勾＝盘是 range 参考、不落键）；
	# 两盘全空＝删键（回退 range 圆盘/单体）；anchor/friendly_fire 只随作用形落键
	var pickm: Array = _w_pick.mask() if _w_custom_pick.button_pressed else []
	var effm: Array = _w_effect.mask()
	if pickm.is_empty() and effm.is_empty():
		out.erase("shape")
	else:
		var shp := {}
		if not pickm.is_empty():
			shp["pick"] = pickm
		if not effm.is_empty():
			shp["effect"] = effm
			shp["anchor"] = str(_w_anchor.get_selected_metadata())
			shp["friendly_fire"] = _w_ff.button_pressed
		out["shape"] = shp
	if _range_superseded():
		out.erase("range")   # 被形状顶掉＝随存清键（火球型〔锚落点无选取形〕仍留 range 定投掷距离）
	out.erase("requires_hands")   # 手部门槛已删（2026-07-13 用户拍板）——旧键随存即清
	# effects[]
	var effects := []
	for b in _blocks:
		effects.append(_collect_block(b))
		if _collect_err != "":
			_err(_collect_err)
			return {}
	out["effects"] = effects
	# —— lint 规则7 同步校验（编辑器先拦；WS 形约束已随决策27 移到引用处＝lint 规则8/ItemEditor 过滤）——
	if not (bool(out["target"]["enemy"]) or bool(out["target"]["ally"]) or bool(out["target"]["self"])):
		_err("目标三旗不得全 false（永不可施放，lint 规则7）")
		return {}
	var pls := []
	_collect_per_levels(out, pls)
	for pl in pls:
		if (pl as Array).size() != int(out["max_level"]):
			_err("per_level 长度(%d)须==max_level(%d)（lint 规则7）" % [(pl as Array).size(), int(out["max_level"])])
			return {}
	return out

func _collect_block(entry: Dictionary) -> Dictionary:
	var out: Dictionary = (entry["data"] as Dictionary).duplicate(true)
	if entry.get("locked", false):
		return out   # 锁定块（多 hits/riders/未知 kind）原样保留
	match str(entry["kind"]):
		"attack":
			var hits: Array = out.get("hits", [])
			var hit: Dictionary = (hits[0] as Dictionary).duplicate(true) if hits.size() == 1 and typeof(hits[0]) == TYPE_DICTIONARY else {}
			var coeff = _collect_formula(entry["coeff"])
			if _collect_err != "":
				return out
			hit["coeff"] = coeff
			hit["damage_category"] = str(entry["damage_category"].get_selected_metadata())
			hit.erase("damage_kind")   # 旧键随存即迁（→damage_category，2026-07-13 改词）
			var dt := str(entry["damage_type"].get_selected_metadata())
			if dt != "":
				hit["damage_type"] = dt
			else:
				hit.erase("damage_type")
			var bh := float(entry["hit"].value)   # 可负/可破 100（设计层语义）；0=中性不落键
			if bh != 0.0:
				hit["hit"] = _num(bh)
			else:
				hit.erase("hit")
			var pen := clampf(float(entry["armor_pen"].value), 0.0, 1.0)
			if pen > 0.0:
				hit["armor_pen"] = _num(pen)
			else:
				hit.erase("armor_pen")
			if not entry.get("inflict_locked", false) and entry.has("onhit_rows"):
				# On-Hit Effects（🔒 2026-07-15 键级统一）：空行跳过、全空不落键；旧键 inflict 随存即迁
				var ohs := []
				for oe in entry["onhit_rows"]:
					var oeid := str((oe["effect"] as OptionButton).get_selected_metadata())
					if oeid != "":
						ohs.append({"effect": oeid, "chance": _num(float((oe["chance"] as SpinBox).value))})
				if ohs.is_empty():
					hit.erase("on_hit_effects")
				else:
					hit["on_hit_effects"] = ohs
				hit.erase("inflict")
			if entry["sure_hit"].button_pressed:
				hit["sure_hit"] = true
			else:
				hit.erase("sure_hit")
			out["hits"] = [hit]
		"heal":
			var v = _collect_formula(entry["heal_pct"])
			if _collect_err != "":
				return out
			out["heal_pct_max_hp"] = v
			out["cleanse_tags"] = (entry["cleanse"] as Array).duplicate()
		"passive_stat_mods":
			var mods := []
			for m in entry["mods"]:
				mods.append({"stat": str(m["stat"].get_selected_metadata()),
					"op": str(m["op"].get_selected_metadata()), "value": _num(float(m["value"].value))})
			out["mods"] = mods
		"conditional_mod":
			# when 行收集在 EditorUI（字节级保留：类型未变 duplicate 原条件、锁定行原样）；必填缺失＝响亮拒存
			var werrs := []
			var conds := []
			for wr in entry["when_rows"]:
				conds.append(EditorUI.collect_when_row(wr, werrs))
			if not werrs.is_empty():
				_collect_err = "conditional_mod：" + str(werrs[0])
				return out
			out["when"] = conds
			var cmods := []
			for m in entry["mods"]:
				cmods.append({"stat": str(m["stat"].get_selected_metadata()),
					"op": str(m["op"].get_selected_metadata()), "value": _num(float(m["value"].value))})
			out["mods"] = cmods
		"apply_effect":
			var eid := str(entry["effect"].get_selected_metadata())
			if eid == "":
				_collect_err = "apply_effect 块未选效果（🔒 对象形 {effect,chance}，禁空引用）"
				return out
			out["effect"] = eid
			if int(entry["chance"].value) != 100:
				out["chance"] = int(entry["chance"].value)
			else:
				out.erase("chance")   # 缺省 100 不落盘（canonical 最小键）
		"scripted":
			out["script_id"] = str(entry["script_id"].text).strip_edges()
			var ptext := str(entry["params"].text).strip_edges()
			if ptext == "":
				out.erase("params")
			else:
				var parsed = JSON.parse_string(ptext)
				if typeof(parsed) != TYPE_DICTIONARY:
					_collect_err = "scripted params 不是合法 JSON 字典——保存被拒（坏 JSON 响亮报错）"
					return out
				out["params"] = parsed
	return out

# 递归收集 per_level 数组（校验长度；同 lint _collect_key_arrays 口径）
func _collect_per_levels(v, acc: Array) -> void:
	match typeof(v):
		TYPE_DICTIONARY:
			for k in v:
				if str(k) == "per_level" and typeof(v[k]) == TYPE_ARRAY:
					acc.append(v[k])
				else:
					_collect_per_levels(v[k], acc)
		TYPE_ARRAY:
			for e in v:
				_collect_per_levels(e, acc)


# —— 保存 / 删除（流程在外壳）——

func _shell_exists(id: String) -> bool:
	return SkillDB.get_skill(id) != null

func _shell_db_save(entry: Dictionary, replace_id: String) -> bool:
	return SkillDB.save_skill(entry, replace_id)

func _shell_db_delete(id: String) -> bool:
	return SkillDB.delete_skill(id)

func _shell_after_save(entry: Dictionary, id: String, renaming: bool) -> void:
	if renaming:
		_info("✓ 已保存并改 id：%s → %s　⚠ 单位已学技能/树引用旧 id 不随迁" % [_loaded_id, id])
		push_warning("SkillEditor：技能 id %s → %s——unit.skills/树引用不随迁" % [_loaded_id, id])
	else:
		_info("✓ 已保存「%s」→ data/skills.json" % str(entry.get("name", id)))
	_current = entry

func _shell_delete_confirm_text(id: String) -> String:
	return "确认删除能力「%s」(%s)？此操作直接写盘（已学单位/引用不随删）。" % [str(_current.get("name", id)), id]

# §18 反向引用：武器 bws/bas（双读单口 weapon_bws_id）与 ews[].skill（含决策22 裸 id 兼容形）＝lint 规则8
# 口径；原型 skills（dict {id:level} / 旧 array 双形）＝lint 规则9 口径。effects.json 无技能引用位——不查。
func _shell_referenced_by(id: String) -> Array[String]:
	var out: Array[String] = []
	var items = ItemDB.all()
	for iid in items:
		var it = items[iid]
		if typeof(it) != TYPE_DICTIONARY:
			continue
		var hits := PackedStringArray()
		if SkillDB.weapon_bws_id(it) == id:
			hits.append("BWS 普攻位")
		for e in it.get("ews", []):
			var sid := str(e.get("skill", "")) if typeof(e) == TYPE_DICTIONARY else str(e)
			if sid == id:
				hits.append("EWS 额外技能位")
				break
		if not hits.is_empty():
			out.append("武器「%s」(%s)：%s" % [str(it.get("name", iid)), str(iid), "、".join(hits)])
	for p in UnitFactory.all_prototypes():
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var psk = p.get("skills", [])
		var sids: Array = psk.keys() if typeof(psk) == TYPE_DICTIONARY else (psk if typeof(psk) == TYPE_ARRAY else [])
		for s in sids:
			if str(s) == id:
				out.append("原型「%s」(%s)：已学 skills" % [str(p.get("name", p.get("id", "?"))), str(p.get("id", "?"))])
				break
	return out
