extends "res://ListEditorShell.gd"
## 角色编辑器：创作单位预设（内置原型），写回 res://data/unit_prototypes.json。
## 入口 StartMenu →「角色编辑器」；地图编辑器落子 / 沙盒 / 事件 spawn_unit 都读同一份（UnitFactory.all_prototypes）。
## CRUD 外壳（清单/行卡/保存删除流程/脏守卫）＝ListEditorShell 基类，本类只管身份条+角色卡。
##
## 界面＝**真·角色状态页照搬**（复用 UnitStatusPanel 的 editor_mode），两列布局（编辑器优化 §31）：
##   · 左列一张**可编辑角色状态卡**——头像点选、姓名/等级/特性、装备槽点选（按槽筛物品）、背包（暂不入档）；
##     属性面板＝派生结果只读实时刷新（四维直接填已删 🔒 属性重做：底值=种族底值，差异走 proto.stats 覆盖）。
##   · 右列**编辑列**：身份/标签条（id/默认阵营/精英/种族/生物类型/派系/外观组/棋子图标/其他标签）
##     ＋ 能力区（SkillDB 技能+等级 → u.skills）＋ 技艺区（已识/装载 → u.prof_known/prof_slots；xp 不在此编、随档原样）。
##     敌方 AI 编辑已移交关卡编辑器（ai_* 按每处放置决定 🔒）；unit_to_proto 仍写 ai_threat 默认兜底。
## 编辑对象＝活的 scratch Unit（表单/卡直接改它）→ 保存时 UnitFactory.unit_to_proto(u) 落盘（复用单一序列化口）。
## 悬空引用保值：SkillDB 查无的技能 / 不在已识的槽位引用 → ⚠ 行显示、_lost_* 兜回 proto（显式 ✕ 才删，不静默丢）。

const UnitFactory := preload("res://UnitFactory.gd")
const UnitStatusPanel := preload("res://UnitStatusPanel.gd")   # 复用真·角色状态页（editor_mode 可编辑）
const TagDB := preload("res://TagDB.gd")
const ItemDB := preload("res://ItemDB.gd")
const EquipSlots := preload("res://EquipSlots.gd")             # 槽位资格（装备选择器按槽筛物品）
const FactionDB := preload("res://FactionDB.gd")              # 派系单一数据源（派系下拉）
const RaceDB := preload("res://RaceDB.gd")                    # 种族底值（种族下拉同时驱动 race_id+底值，🔒 属性重做 §3）
const Unit := preload("res://Unit.gd")                        # 换种族先重置引擎基线（防旧种族键残留）
const SkillDB := preload("res://SkillDB.gd")                  # 能力区下拉（技能注册表）
const ProfDB := preload("res://ProfDB.gd")                    # 技艺区下拉（熟练度域注册表）
# EditorTheme / EditorUI / TextureCache 由 ListEditorShell 继承

const FACTIONS := ["player", "ally", "enemy", "neutral"]
const MANAGED_CATS := ["faction", "race", "biotype", "camp"]   # 有专属下拉（阵营/种族/生物类型/派系）→ 从「其他标签」排除
const MOVEMENT_ALL := ["ground", "spectral", "flying"] # 移动型（判断单位有无移动型；ground 默认、flying 运行时）
const RUNTIME_TAGS := ["flying", "deaths_door", "injured", "dead"]   # 运行时/战斗态，绝不入预设
# 描述物品/技能/地块，永不属于单位（仿 ItemEditor.NON_ITEM_CATS）→ 自由标签选择器全排除，只留 unit 能用的
const NON_UNIT_CATS := ["terrain", "rarity", "wtype", "wcat_melee", "wcat_ranged",
	"wcat_catalyst", "wcat_shield", "handedness", "gear_type", "armor_weight",
	"weapon_attr", "skill_type", "target", "damage", "effect", "effect_dim"]
const PORTRAIT_DIR := "res://icons/Characters"
const ICON_DIR := "res://icons/Unit_Icons"

# —— 状态（外壳态 _is_new/_loaded_id/_dirty/_rows/_selected_id 等在 ListEditorShell）——
var _unit                    # 当前编辑的活 scratch Unit
var _free_tags: Array = []   # 自由标签（char_* + 自定义）
var _bag: Array = []         # 背包内容（8 格，"" = 空；仅编辑器显示，不入档）
var _race_applied := ""      # 已生效的种族 tag（换种族确认 §34：取消时下拉回退到它）
# 悬空引用保值（§7）：make_unit 组装承载不了的引用（SkillDB 查无的技能 / 不在已识的槽位）——
# 编辑器侧兜住、_collect_proto 原样带回；⚠ 行显示、显式 ✕ 才真删（_ensure_meta_option 同律）。
var _lost_skills: Dictionary = {}   # skill_id -> level（int）
var _lost_slots: Array = []         # prof_id 列表
# —— 外观组（成对绑定：一套外观 = 一张立绘 + 一个棋子；编辑器侧状态，经 proto 出入，不入 Unit）——
# 每条 = {id, name, portrait, icon}。顶层 proto.portrait/icon 镜像「默认外观」→ 现有消费方零改动。
# 引用/条件切换是后续步骤；本步只管在编辑器里增删/命名/管理多套。
var _appearances: Array = []   # [{id,name,portrait,icon}]（至少 1 条）
var _default_appear := ""      # 默认外观 id（无条件时用它；镜像到顶层 portrait/icon）
var _editing_appear := ""      # 当前在卡上预览/编辑的外观 id（UI 态，可 ≠ 默认）

# —— 控件（左清单/底栏控件在 ListEditorShell）——
var _strip: VBoxContainer
var _panel                   # UnitStatusPanel 实例
var _free_box: HBoxContainer
var _file_dialog: FileDialog

var _skill_box: VBoxContainer       # 能力 chip 行容器（§7）
var _prof_box: VBoxContainer        # 技艺行容器（§7）

var _f_id: LineEdit
var _f_faction: OptionButton        # 阵营立场（默认；关卡可改）
var _f_home_faction: OptionButton   # 派系归属（FactionDB）
var _f_race: OptionButton
var _f_biotype: OptionButton
var _f_elite: CheckBox
var _icon_thumb: TextureRect
var _icon_edit: LineEdit
var _file_target := ""              # 文件对话框回填目标："portrait" | "icon"
var _appear_row: HBoxContainer      # 外观 chip 行
var _appear_id_edit: LineEdit       # 选中外观的 id（引用条件用；焦点离开/回车提交）
var _appear_name_edit: LineEdit     # 选中外观的显示名（即时）


# —— 外壳钩子（ListEditorShell）——

func _shell_title() -> String:
	return "角色编辑器"

func _shell_new_label() -> String:
	return "＋ 新建角色"

func _shell_split_offset() -> int:
	return 260

func _shell_left_min_width() -> int:
	return 240

func _shell_new_entry() -> void:
	_do_new_unit()

func _shell_load(id: String) -> void:
	_load_proto(id)

func _shell_discard_text() -> String:
	return "当前角色有未保存的修改，继续将丢弃。"

func _shell_has_entry() -> bool:
	return _unit != null

# 右侧两列（§31）：左＝角色状态卡（CARD_SIZE 定尺寸），右＝编辑列（身份条+能力+技艺，纵向滚动）。
# 原纵排在 1080p 必滚动、~700px 横向闲置——卡片居左、编辑列右移吃掉闲置宽度。
# ⚠ 只动本编辑器的容器编排，不碰 UnitStatusPanel（UI 并行线敏感区）。
func _shell_build_right(split: HSplitContainer) -> void:
	var cols := HBoxContainer.new()
	cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 10)
	split.add_child(cols)

	# 左列：角色卡固定尺寸（CARD_SIZE），不随窗口拉伸；套 ScrollContainer 兜住窗口偏小时的溢出。
	var panel_scroll := ScrollContainer.new()
	panel_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel_scroll.size_flags_stretch_ratio = 1.3   # 卡 900px : 编辑列 ~700px
	cols.add_child(panel_scroll)
	_panel = UnitStatusPanel.new()
	_panel.editor_mode = true
	_panel.custom_minimum_size = UnitStatusPanel.CARD_SIZE   # 钉死卡片尺寸
	_panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN  # 不被 ScrollContainer 拉伸
	_panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_panel.on_portrait_pick = _on_portrait_pick
	_panel.on_equip_slot = _on_equip_slot
	_panel.on_bag_slot = _on_bag_slot
	_panel.on_edit = _on_panel_edit
	panel_scroll.add_child(_panel)

	# 右列：编辑列（身份/标签条 + 能力 + 技艺；内容超高走纵向滚动、超宽走横向滚动不裁切）
	var edit_scroll := ScrollContainer.new()
	edit_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	edit_scroll.custom_minimum_size = Vector2(430, 0)
	cols.add_child(edit_scroll)
	_strip = VBoxContainer.new()
	_strip.add_theme_constant_override("separation", 4)
	_strip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var strip_panel := EditorUI.panelize(_strip)
	strip_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit_scroll.add_child(strip_panel)


# 原型清单：按阵营分折叠组（我方/友方/敌方/中立 + 其它）+ 组内按名字排序 + 行卡片（图标+名字/id）。
func _shell_populate_list(q: String) -> void:
	var searching := q != ""
	var protos := UnitFactory.all_prototypes()
	var by_fac := {}      # faction -> [proto]
	var order := []       # 阵营出现顺序（FACTIONS 优先，其余 append）
	for f in FACTIONS:
		by_fac[f] = []
		order.append(f)
	for p in protos:
		var id := str(p.get("id", ""))
		var nm := str(p.get("name", id))
		if searching and not (id.to_lower().contains(q) or nm.to_lower().contains(q)):
			continue
		var fac := str(p.get("default_faction", "neutral"))
		if not by_fac.has(fac):
			by_fac[fac] = []
			order.append(fac)
		by_fac[fac].append(p)
	for fac in order:
		var arr: Array = by_fac[fac]
		if arr.is_empty():
			continue
		arr.sort_custom(func(a, b): return str(a.get("name", "")) < str(b.get("name", "")))
		var section := VBoxContainer.new()
		section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		section.add_theme_constant_override("separation", 2)
		for p in arr:
			var id := str(p.get("id", ""))
			# 行卡图优先立绘（大图更直观；棋子图标常抽象）→ 退棋子图标 → 淡显占位
			var tex = TextureCache.get_tex(str(p.get("portrait", "")))
			if tex == null:
				tex = TextureCache.get_tex(str(p.get("icon", "")))
			var hex := TagDB.color(fac)
			var row := _make_row_card(id, tex, str(p.get("name", id)),
				Color(hex) if hex != "" else null, 54, Vector2(42, 48))
			section.add_child(row)
			_rows[id] = row
		_add_fold_group(fac, "%s (%d)" % [TagDB.cn(fac), arr.size()], section, searching)


# —— 新建 / 载入 / 副本 ——

func _do_new_unit() -> void:
	_open_proto(_skeleton(), true)
	_select_row("")
	_info("新建角色——填好 id（唯一）后点保存")

func _skeleton() -> Dictionary:
	return {"id": "", "name": "新单位", "default_faction": "enemy",
		"tags": ["human"], "race": "human", "level": 1}

func _load_proto(id: String) -> void:
	var p := UnitFactory.get_prototype(id)
	if p.is_empty():
		return
	_open_proto(p.duplicate(true), false)
	_select_row(id)
	_info("编辑「%s」" % str(p.get("name", id)))

# 副本以「新建未保存」态打开（外壳 _on_duplicate 已做 id 唯一化/置脏/消息）
func _shell_open_as_new(entry: Dictionary) -> void:
	_open_proto(entry, true)

func _open_proto(proto: Dictionary, is_new: bool) -> void:
	_unit = UnitFactory.make_unit(proto, str(proto.get("default_faction", "enemy")), 0, 0)
	_unit.proto_id = str(proto.get("id", ""))
	_is_new = is_new
	_loaded_id = "" if is_new else str(proto.get("id", ""))
	_bag = ["", "", "", "", "", "", "", ""]   # 背包每次载入清空（不入档）
	_capture_lost_refs(proto)                 # 悬空引用保值（§7）：make_unit 承载不了的 skills/slots 引用兜进 _lost_*
	_init_appearances(proto)                  # 外观组：从 proto 载入（缺省=旧 portrait/icon 合成一条 base）
	_build_strip()
	_rebuild_panel()
	_dirty = false
	_update_buttons()


# —— 身份/标签条（角色卡不显示的编辑器元数据）——

func _shell_show_empty() -> void:
	_unit = null
	_select_row("")
	for c in _strip.get_children():
		c.queue_free()
	var hint := Label.new()
	hint.text = "← 选左侧角色编辑，或点「＋ 新建角色」"
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.72))
	_strip.add_child(hint)
	if _panel != null and is_instance_valid(_panel):   # 清掉上一个条目的角色卡内容
		for c in _panel.get_children():
			c.queue_free()
	_update_buttons()

func _build_strip() -> void:
	for c in _strip.get_children():
		c.queue_free()
	if _unit == null:
		return
	# 第一行：id / 默认阵营 / 精英
	var r1 := HBoxContainer.new()
	r1.add_theme_constant_override("separation", 8)
	r1.add_child(_lbl("id"))
	_f_id = LineEdit.new()
	_f_id.text = _unit.proto_id
	_f_id.custom_minimum_size = Vector2(150, 0)
	_f_id.tooltip_text = "唯一主键（字母/数字/下划线）"
	_f_id.text_changed.connect(_on_id_changed)
	r1.add_child(_f_id)
	r1.add_child(_lbl("默认阵营"))
	_f_faction = _dropdown(FACTIONS, _unit.faction, _on_faction_changed)
	r1.add_child(_f_faction)
	_f_elite = CheckBox.new()
	_f_elite.text = "精英 elite"
	_f_elite.tooltip_text = "非我方单位带此 tag 才有死门资格（BattleState 已接）"
	_f_elite.button_pressed = _unit.tags.has("elite")
	_f_elite.toggled.connect(func(_v): _sync_tags())
	r1.add_child(_f_elite)
	_strip.add_child(r1)
	# 第二行：种族 / 生物类型（正交两轴） / 派系归属
	var r2 := HBoxContainer.new()
	r2.add_theme_constant_override("separation", 8)
	r2.add_child(_lbl("种族"))
	_f_race = _cat_dropdown("race", _tag_in_cat("race"), _on_race_changed)
	_race_applied = str(_f_race.get_selected_metadata())   # §34：记录已生效种族（取消换族时回退基准）
	r2.add_child(_f_race)
	r2.add_child(_lbl("生物类型"))
	_f_biotype = _cat_dropdown("biotype", _tag_in_cat("biotype"), _on_biotype_changed)
	r2.add_child(_f_biotype)
	r2.add_child(_lbl("派系"))
	_f_home_faction = _faction_dropdown(_tag_in_cat("camp"))
	_f_home_faction.tooltip_text = "单位内在派系（camp_* tag；FactionDB 影响声望/敌对）。区别于「默认阵营」立场(本关站哪边)"
	r2.add_child(_f_home_faction)
	_strip.add_child(r2)
	# 外观组：多套「立绘+棋子」成对管理（选中某套 → 卡片立绘 + 下方棋子图标都编辑它）
	_build_appear_ui()
	# 第三行：棋子图标（叠在六边形 token 上的小图；立绘在角色卡头像「＋」处点选）——编辑当前选中外观
	var r3 := HBoxContainer.new()
	r3.add_theme_constant_override("separation", 6)
	r3.add_child(_lbl("棋子图标"))
	_icon_thumb = TextureRect.new()
	_icon_thumb.custom_minimum_size = Vector2(28, 28)
	_icon_thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon_thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon_thumb.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_icon_thumb.texture = TextureCache.get_tex(_unit.icon)
	r3.add_child(_icon_thumb)
	_icon_edit = LineEdit.new()
	_icon_edit.text = _unit.icon
	_icon_edit.placeholder_text = ICON_DIR + "/...png"
	_icon_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_icon_edit.text_changed.connect(_on_icon_text)
	r3.add_child(_icon_edit)
	var icon_browse := Button.new()
	icon_browse.text = "浏览…"
	icon_browse.pressed.connect(func(): _open_file_dialog("icon", ICON_DIR))
	r3.add_child(icon_browse)
	_strip.add_child(r3)
	_build_free_tag_ui()
	_build_skill_ui()   # 能力区（§7：SkillDB 技能+等级 → u.skills）
	_build_prof_ui()    # 技艺区（§7：已识/装载 → u.prof_known/prof_slots）


func _rebuild_panel() -> void:
	if _panel == null:
		return
	_panel.bag_items = _bag
	if _unit != null:
		_panel.open(_unit)


# —— 标签同步（阵营/种族/精英/自由 → _unit.tags；保留移动型）——

func _sync_tags() -> void:
	if _unit == null:
		return
	var tags := [str(_f_faction.get_selected_metadata())]   # 阵营立场
	var race := str(_f_race.get_selected_metadata())
	if race != "" and not tags.has(race):
		tags.append(race)
	var biotype := str(_f_biotype.get_selected_metadata())
	if biotype != "" and not tags.has(biotype):
		tags.append(biotype)
	var camp := str(_f_home_faction.get_selected_metadata())   # 派系归属＝ camp_<id> tag
	if camp != "" and not tags.has(camp):
		tags.append(camp)
	if _f_elite.button_pressed and not tags.has("elite"):
		tags.append("elite")
	for t in _free_tags:                     # 自由标签里可含 spectral（移动型走这条）
		var s := str(t)
		if not tags.has(s) and not RUNTIME_TAGS.has(s):
			tags.append(s)
	# 确保有移动型：自由标签含 spectral/flying 则用它，否则补默认 ground
	var has_move := false
	for t in tags:
		if str(t) in MOVEMENT_ALL:
			has_move = true
			break
	if not has_move:
		tags.append("ground")
	_unit.tags = tags
	_mark_dirty()

func _on_faction_changed() -> void:
	_sync_tags()
	_rebuild_panel()   # 阵营显示在卡片抬头，重建反映

# 换种族＝按新种族重铺底值 → 会清空 proto.stats 差异覆盖（§34）：
# 有差异先弹确认（EditorUI.confirm 工程惯例），取消＝下拉回退、数据不动；无差异直接换。
func _on_race_changed() -> void:
	if _unit == null:
		_sync_tags()
		return
	var race := str(_f_race.get_selected_metadata())
	if race == _race_applied:
		_sync_tags()   # 种族没变（重选同项）——只同步 tags
		return
	var diff: Dictionary = UnitFactory.unit_to_proto(_unit).get("stats", {})   # 现存差异覆盖（unit_to_proto 同口径）
	if diff.is_empty():
		_apply_race_change(race)
		return
	var keys := []
	for k in diff:
		keys.append(str(k))
	EditorUI.confirm(self,
		"换种族将按新种族重铺底值，清空 %d 项属性差异覆盖：\n%s\n\n（差异覆盖=本角色对种族底值的手工修改，换族后不可恢复）" \
			% [keys.size(), ", ".join(PackedStringArray(keys))],
		"换种族并清空", func(): _apply_race_change(race),
		func(): _select_meta(_f_race, _race_applied),   # 取消＝下拉回退（程序化 select 不发信号，tags 未动无需回滚）
		"换种族确认")

# 种族 tag 同时驱动种族底值 🔒（模块_属性成长_设计.md §3）：tag id 与 races.json id 同词表。
# 换族＝先重置引擎基线、再叠新种族底值——防旧种族的键在新种族未定义时残留（对抗 review 发现）；
# 未建档种族 → 仅记 tag、面板回引擎基线（race_id 清空）。
# 底值重铺后补走成长轨（与 make_unit/unit_to_proto 的 _walk_growth 同一份 🔒 §10.6）——
# 否则 level>1 角色换族后 u.stats 缺成长，保存＝负成长值烘焙进 stats 差异。
func _apply_race_change(race: String) -> void:
	_race_applied = race
	_sync_tags()
	var fresh = Unit.new()
	for k in fresh.stats:
		_unit.stats[k] = fresh.stats[k]
	_unit.race_id = ""
	if not RaceDB.get_race(race).is_empty():
		RaceDB.apply_to(_unit, race)   # 内部写 race_id
	UnitFactory._walk_growth(_unit, maxi(1, int(_unit.level)))
	_unit.init_vitals()
	_rebuild_panel()

func _on_biotype_changed() -> void:
	_sync_tags()

func _on_id_changed(_t := "") -> void:
	if _unit == null: return
	_unit.proto_id = _f_id.text.strip_edges()
	_mark_dirty()

func _on_icon_text(t: String) -> void:
	if _unit == null: return
	_unit.icon = t.strip_edges()
	if _icon_thumb != null and is_instance_valid(_icon_thumb):
		_icon_thumb.texture = TextureCache.get_tex(_unit.icon)
	_writeback_appearance(false)   # 写回当前外观（不逐键重建 chip 行，避免抢焦点）
	_mark_dirty()


# —— 外观组（成对绑定：一套 = 立绘 + 棋子；编辑器侧管理，经 proto 出入）——

# 从 proto 载入外观组；缺省则用顶层 portrait/icon 合成单条 base（旧原型无缝）。
func _init_appearances(proto: Dictionary) -> void:
	_appearances = []
	var raw = proto.get("appearances", [])
	if raw is Array:
		for e in raw:
			if e is Dictionary:
				_appearances.append({
					"id": str(e.get("id", "")), "name": str(e.get("name", "")),
					"portrait": str(e.get("portrait", "")), "icon": str(e.get("icon", "")),
				})
	if _appearances.is_empty():
		_appearances.append({"id": "base", "name": "默认",
			"portrait": _unit.portrait, "icon": _unit.icon})
	_ensure_appear_ids()
	_default_appear = str(proto.get("default_appearance", ""))
	if not _appear_has(_default_appear):
		_default_appear = str(_appearances[0]["id"])
	_editing_appear = _default_appear
	_apply_appearance(_editing_appear)   # 让 _unit.portrait/icon = 编辑对象（卡片/棋子预览它）

# 给缺 id / 重复 id 的条目补唯一 id（防脏数据）。
func _ensure_appear_ids() -> void:
	var seen := {}
	for a in _appearances:
		var id := str(a["id"])
		if id == "" or seen.has(id):
			id = _unique_appear_id("look")
			a["id"] = id
		seen[id] = true

func _appear_index(id: String) -> int:
	for i in _appearances.size():
		if str(_appearances[i]["id"]) == id:
			return i
	return -1

func _appear_has(id: String) -> bool:
	return id != "" and _appear_index(id) >= 0

func _appear_get(id: String):
	var i := _appear_index(id)
	return _appearances[i] if i >= 0 else null

func _unique_appear_id(base: String) -> String:
	var i := 1
	var cand := "%s_%d" % [base, i]
	while _appear_has(cand):
		i += 1
		cand = "%s_%d" % [base, i]
	return cand

# 把某外观的图应用到活 _unit（供卡片/棋子预览）；不动 UI。
func _apply_appearance(id: String) -> void:
	var a = _appear_get(id)
	if a == null or _unit == null:
		return
	_unit.portrait = str(a["portrait"])
	_unit.icon = str(a["icon"])

# 把 _unit 当前 portrait/icon 写回当前编辑外观（图改了就同步进外观组）。
func _writeback_appearance(rebuild_chips: bool) -> void:
	var a = _appear_get(_editing_appear)
	if a == null:
		return
	a["portrait"] = _unit.portrait
	a["icon"] = _unit.icon
	if rebuild_chips:
		_rebuild_appear_row()

func _build_appear_ui() -> void:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	head.add_child(_lbl("外观组"))
	var addb := Button.new()
	addb.text = "＋ 添加外观"
	addb.tooltip_text = "新增一套空白外观（立绘+棋子），选它后再点选图片"
	addb.pressed.connect(_add_appearance)
	head.add_child(addb)
	var defb := Button.new()
	defb.text = "设为默认 ★"
	defb.tooltip_text = "默认外观 = 无触发条件时使用；同步到顶层 portrait/icon，落子/大地图/战斗当前即用它"
	defb.pressed.connect(_set_default_appearance)
	head.add_child(defb)
	var delb := Button.new()
	delb.text = "✕ 删除当前"
	delb.pressed.connect(_remove_appearance)
	head.add_child(delb)
	_strip.add_child(head)

	_appear_row = HBoxContainer.new()
	_appear_row.add_theme_constant_override("separation", 6)
	_strip.add_child(_appear_row)

	var meta := HBoxContainer.new()
	meta.add_theme_constant_override("separation", 6)
	meta.add_child(_lbl("外观 id"))
	_appear_id_edit = LineEdit.new()
	_appear_id_edit.custom_minimum_size = Vector2(110, 0)
	_appear_id_edit.tooltip_text = "外观 id（字母/数字/下划线，唯一）——将来「引用条件」按它指定；回车/移开焦点提交"
	_appear_id_edit.text_submitted.connect(func(_t): _commit_appear_id())
	_appear_id_edit.focus_exited.connect(_commit_appear_id)
	meta.add_child(_appear_id_edit)
	meta.add_child(_lbl("名称"))
	_appear_name_edit = LineEdit.new()
	_appear_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_appear_name_edit.placeholder_text = "显示名（如 常态 / 狼形 / 精英版）"
	_appear_name_edit.text_changed.connect(_on_appear_name_changed)
	meta.add_child(_appear_name_edit)
	_strip.add_child(meta)

	_rebuild_appear_row()
	_sync_appear_meta()

# 重建 chip 行：每套外观一个缩略按钮（立绘→退棋子→淡显占位），选中金框、默认加 ★。
func _rebuild_appear_row() -> void:
	if _appear_row == null or not is_instance_valid(_appear_row):
		return
	for c in _appear_row.get_children():
		c.queue_free()
	for a in _appearances:
		var id := str(a["id"])
		var chip := Button.new()
		chip.custom_minimum_size = Vector2(52, 60)
		chip.clip_contents = true
		chip.tooltip_text = "%s（%s）" % [str(a["name"]), id]
		var tex = TextureCache.get_tex(str(a["portrait"]))
		if tex == null:
			tex = TextureCache.get_tex(str(a["icon"]))
		var tr := TextureRect.new()
		tr.set_anchors_preset(Control.PRESET_FULL_RECT)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if tex != null:
			tr.texture = tex
		else:
			tr.modulate = Color(1, 1, 1, 0.2)
		chip.add_child(tr)
		if id == _default_appear:
			var star := Label.new()
			star.text = "★"
			star.add_theme_color_override("font_color", Color("#EBBC04"))
			star.add_theme_font_size_override("font_size", 12)
			star.mouse_filter = Control.MOUSE_FILTER_IGNORE
			chip.add_child(star)
		var cid := id
		chip.pressed.connect(func(): _select_appearance(cid))
		_apply_row_selected(chip, id == _editing_appear)
		_appear_row.add_child(chip)

# 同步「选中外观」的 id/名称输入框到 UI（程序化设 .text 不触发 text_changed）。
func _sync_appear_meta() -> void:
	var a = _appear_get(_editing_appear)
	if a == null:
		return
	if _appear_id_edit != null and is_instance_valid(_appear_id_edit):
		_appear_id_edit.text = str(a["id"])
	if _appear_name_edit != null and is_instance_valid(_appear_name_edit):
		_appear_name_edit.text = str(a["name"])

# 同步棋子图标缩略/输入框到当前 _unit.icon（切换外观后刷新）。
func _refresh_icon_field() -> void:
	if _icon_thumb != null and is_instance_valid(_icon_thumb):
		_icon_thumb.texture = TextureCache.get_tex(_unit.icon)
	if _icon_edit != null and is_instance_valid(_icon_edit):
		_icon_edit.text = _unit.icon

# 选一套外观 → 成为编辑对象：卡片立绘 + 棋子图标都切到它。
func _select_appearance(id: String) -> void:
	if not _appear_has(id):
		return
	_editing_appear = id
	_apply_appearance(id)
	_rebuild_panel()        # 立绘
	_refresh_icon_field()   # 棋子
	_sync_appear_meta()
	_rebuild_appear_row()

func _add_appearance() -> void:
	if _unit == null:
		return
	var nid := _unique_appear_id("look")
	_appearances.append({"id": nid, "name": "外观%d" % _appearances.size(),
		"portrait": "", "icon": ""})   # 空白：立即看到占位「＋」提示去选图
	_editing_appear = nid
	_apply_appearance(nid)
	_rebuild_panel()
	_refresh_icon_field()
	_sync_appear_meta()
	_rebuild_appear_row()
	_mark_dirty()
	_info("已加外观「%s」——点卡片头像选立绘、下方选棋子；可「设为默认」" % nid)

func _set_default_appearance() -> void:
	if not _appear_has(_editing_appear):
		return
	_default_appear = _editing_appear
	_rebuild_appear_row()
	_mark_dirty()
	_info("默认外观 → 「%s」（游戏内当前用它）" % _default_appear)

func _remove_appearance() -> void:
	if _appearances.size() <= 1:
		_err("至少保留一套外观")
		return
	var idx := _appear_index(_editing_appear)
	if idx < 0:
		return
	var was_default := (_editing_appear == _default_appear)
	_appearances.remove_at(idx)
	if was_default:
		_default_appear = str(_appearances[0]["id"])
	_editing_appear = _default_appear
	_apply_appearance(_editing_appear)
	_rebuild_panel()
	_refresh_icon_field()
	_sync_appear_meta()
	_rebuild_appear_row()
	_mark_dirty()

# 提交外观 id 改名（回车/失焦）：校验字母数字下划线 + 唯一；无效则回退并报错。
func _commit_appear_id() -> void:
	var a = _appear_get(_editing_appear)
	if a == null or _appear_id_edit == null or not is_instance_valid(_appear_id_edit):
		return
	var nid := _appear_id_edit.text.strip_edges()
	var old := str(a["id"])
	if nid == old:
		return
	if not _valid_id(nid):
		_appear_id_edit.text = old
		_err("外观 id 只能用 字母/数字/下划线")
		return
	for other in _appearances:
		if other != a and str(other["id"]) == nid:
			_appear_id_edit.text = old
			_err("外观 id「%s」已重复" % nid)
			return
	a["id"] = nid
	if _default_appear == old:
		_default_appear = nid
	_editing_appear = nid
	_rebuild_appear_row()
	_mark_dirty()

func _on_appear_name_changed(t: String) -> void:
	var a = _appear_get(_editing_appear)
	if a == null:
		return
	a["name"] = t
	_mark_dirty()


# —— 自由标签（char_* / 自定义；仿 ItemEditor）——

func _build_free_tag_ui() -> void:
	_free_tags = []
	for t in _unit.tags:
		var s := str(t)
		# 排除：阵营 / 运行时态 / 默认 ground / 派系 camp_* / 专属下拉管的类（faction·race·biotype·camp）/ 单位状态（elite=勾选、余=运行时）
		if FACTIONS.has(s) or RUNTIME_TAGS.has(s) or s == "ground" or s.begins_with("camp_"):
			continue
		var c := _cat_of(s)
		if c in MANAGED_CATS or c == "unit_status":
			continue
		if not _free_tags.has(s):     # 余下＝char_* / spectral / 自定义
			_free_tags.append(s)
	var adder := HBoxContainer.new()
	adder.add_theme_constant_override("separation", 6)
	adder.add_child(_lbl("其他标签"))
	var pick := OptionButton.new()
	pick.custom_minimum_size = Vector2(160, 0)
	_fill_free_options(pick)
	pick.item_selected.connect(func(idx):
		var tg = pick.get_item_metadata(idx)
		if tg != null and str(tg) != "" and not _free_tags.has(str(tg)):
			_free_tags.append(str(tg))
			_rebuild_free_box()
			_sync_tags()
		pick.select(0))
	adder.add_child(pick)
	var manual := LineEdit.new()
	manual.placeholder_text = "手动 tag（如 char_xxx）"
	manual.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	adder.add_child(manual)
	var addb := Button.new()
	addb.text = "＋"
	addb.pressed.connect(func():
		var tt := manual.text.strip_edges()
		if tt != "" and not _free_tags.has(tt):
			_free_tags.append(tt)
			_rebuild_free_box()
			_sync_tags()
		manual.clear())
	adder.add_child(addb)
	_strip.add_child(adder)
	_free_box = HBoxContainer.new()
	_free_box.add_theme_constant_override("separation", 6)
	_strip.add_child(_free_box)
	_rebuild_free_box()

# 自由标签选择器：**只列单位能用的 tag**（仿物品编辑器排除不可能应用者）——
# 排除：专属下拉管的类(faction/race/biotype) + 单位状态类(elite勾选/余运行时) + 物品/技能/地块类(NON_UNIT_CATS) + 运行时/默认 id。
# 结果只剩 char_*（身份）与 spectral（灵体移动型）。
func _fill_free_options(ob: OptionButton) -> void:
	ob.add_item("（下拉添加…）")
	ob.set_item_metadata(0, "")
	var cats := {}
	var all := TagDB.all()
	for id in all:
		var c := str(all[id].get("cat", "其他"))
		if c in MANAGED_CATS or c == "unit_status" or c in NON_UNIT_CATS:
			continue
		if id in RUNTIME_TAGS or id == "ground" or id.begins_with("camp_"):
			continue
		if not cats.has(c):
			cats[c] = []
		cats[c].append(id)
	for c in cats:
		ob.add_separator(c)
		for id in cats[c]:
			ob.add_item("%s（%s）" % [TagDB.cn(id), id])
			ob.set_item_metadata(ob.item_count - 1, id)

func _rebuild_free_box() -> void:
	if _free_box == null or not is_instance_valid(_free_box):
		return
	for c in _free_box.get_children():
		c.queue_free()
	if _free_tags.is_empty():
		var l := Label.new()
		l.text = "（无）"
		l.add_theme_color_override("font_color", Color(0.55, 0.6, 0.66))
		_free_box.add_child(l)
		return
	for t in _free_tags:
		var chip := Button.new()
		chip.text = "%s ✕" % str(t)
		var tag := str(t)
		chip.pressed.connect(func():
			_free_tags.erase(tag)
			_rebuild_free_box()
			_sync_tags())
		_free_box.add_child(chip)


# —— 能力 / 技艺编辑（§7；序列化承载＝UnitFactory：skills{id:level} / profs{known,slots,xp}）——

# 载入时捕获 make_unit 承载不了的引用（悬空保值）：
# · skills：SkillDB 查无 → learn_skill 返 0、u.skills 不收——不兜住则「打开即存」静默丢；
# · profs.slots：id 不在 known → slot_prof 拒收——同理。known 的未登记 id 直接存活于 u.prof_known，无需兜。
func _capture_lost_refs(proto: Dictionary) -> void:
	_lost_skills = {}
	var sk = proto.get("skills", [])
	if typeof(sk) == TYPE_DICTIONARY:
		for sid in sk:
			if not _unit.skills.has(str(sid)):
				_lost_skills[str(sid)] = maxi(1, int(sk[sid]))
	elif typeof(sk) == TYPE_ARRAY:
		for sid in sk:
			if not _unit.skills.has(str(sid)):
				_lost_skills[str(sid)] = 1
	_lost_slots = []
	var pf = proto.get("profs", {})
	if typeof(pf) == TYPE_DICTIONARY:
		for pid in pf.get("slots", []):
			if not _unit.prof_slots.has(str(pid)) and not _lost_slots.has(str(pid)):
				_lost_slots.append(str(pid))

# 能力区：SkillDB 下拉 + 等级 + 添加 → chip 行（名字+等级 SpinBox+✕）
func _build_skill_ui() -> void:
	_strip.add_child(EditorUI.section_title("能力（技能 + 等级）"))
	var adder := HBoxContainer.new()
	adder.add_theme_constant_override("separation", 6)
	var pick := OptionButton.new()
	pick.custom_minimum_size = Vector2(220, 0)
	pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pick.add_item("（选技能…）")
	pick.set_item_metadata(0, "")
	var ids: Array = SkillDB.all().keys()
	ids.sort()
	for sid in ids:
		var def = SkillDB.get_skill(str(sid))
		var nm := str(def.get("name", sid)) if typeof(def) == TYPE_DICTIONARY else str(sid)
		pick.add_item("%s（%s）" % [nm, str(sid)])
		pick.set_item_metadata(pick.item_count - 1, str(sid))
	adder.add_child(pick)
	var lv := SpinBox.new()
	lv.min_value = 1
	lv.max_value = 9
	lv.value = 1
	lv.custom_minimum_size = Vector2(64, 0)
	lv.tooltip_text = "学到的等级（超出该技能 max_level 自动封顶）"
	adder.add_child(lv)
	var addb := Button.new()
	addb.text = "＋ 添加"
	addb.pressed.connect(func():
		var sid := str(pick.get_selected_metadata())
		if sid != "":
			_add_skill(sid, int(lv.value))
		pick.select(0))
	adder.add_child(addb)
	_strip.add_child(adder)
	_skill_box = VBoxContainer.new()
	_skill_box.add_theme_constant_override("separation", 3)
	_strip.add_child(_skill_box)
	_rebuild_skill_box()

func _rebuild_skill_box() -> void:
	if _skill_box == null or not is_instance_valid(_skill_box):
		return
	for c in _skill_box.get_children():
		c.queue_free()   # ⚠ queue_free：常由行内 ✕/SpinBox 信号中触发，free() 会当场释放发信号控件
	if _unit == null:
		return
	if _unit.skills.is_empty() and _lost_skills.is_empty():
		_skill_box.add_child(_dim_lbl("（无）"))
		return
	for sid_v in _unit.skills.keys():
		var sid := str(sid_v)
		var def = SkillDB.get_skill(sid)
		var maxl := int(def.get("max_level", 1)) if typeof(def) == TYPE_DICTIONARY else 1
		var nm := str(def.get("name", sid)) if typeof(def) == TYPE_DICTIONARY else sid
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var l := Label.new()
		l.text = "%s（%s）" % [nm, sid]
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.clip_text = true
		row.add_child(l)
		var lv := SpinBox.new()
		lv.min_value = 1
		lv.max_value = maxi(1, maxl)
		lv.value = _unit.skill_level(sid)
		lv.editable = maxl > 1
		lv.custom_minimum_size = Vector2(64, 0)
		lv.tooltip_text = "等级（max_level=%d）" % maxl
		var s2 := sid
		lv.value_changed.connect(func(v): _set_skill_level(s2, int(v)))
		row.add_child(lv)
		var rm := Button.new()
		rm.text = "✕"
		rm.pressed.connect(func(): _remove_skill(s2))
		row.add_child(rm)
		_skill_box.add_child(row)
	for sid_v in _lost_skills.keys():
		var sid := str(sid_v)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var warn := Label.new()
		warn.text = "⚠ 未登记技能「%s」（等级 %d）——原样保留" % [sid, int(_lost_skills[sid])]
		warn.add_theme_color_override("font_color", Color(0.95, 0.8, 0.35))
		warn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		warn.clip_text = true
		warn.tooltip_text = "SkillDB 查无此 id：保存时原样写回 proto，不静默丢；✕ 显式删除"
		row.add_child(warn)
		var rm := Button.new()
		rm.text = "✕"
		var s2 := sid
		rm.pressed.connect(func(): _remove_skill(s2))
		row.add_child(rm)
		_skill_box.add_child(row)

# 添加/置级共用：先摘净该技能（含被动修正），再逐级 learn_skill 到目标级——
# 与 make_unit 的 {id:level} 组装同轨（learn_skill 内部按 max_level 封顶+重挂被动+按比例缩放 vitals）。
func _set_skill_level(sid: String, lv: int) -> void:
	if _unit == null or sid == "":
		return
	if _unit.skill_level(sid) == lv and _unit.skills.has(sid):
		return
	var hp0 := float(_unit.effective_stat_f("HP_max"))
	var ar0 := float(_unit.effective_stat_f("armor_max"))
	_unit.skills.erase(sid)
	_unit.remove_modifiers_by_source("skill:" + sid)
	_unit._rescale_vitals(hp0, ar0)   # 摘净后先按比例回落（unslot 同律）；learn 再逐级挂回
	var got := 0
	for _n in range(maxi(1, lv)):
		got = int(_unit.learn_skill(sid))
		if got == 0:
			break
	if got == 0:
		_err("技能「%s」未登记（SkillDB 查无此 id）" % sid)
	elif got < lv:
		_info("技能「%s」等级封顶 %d（max_level）" % [sid, got])
	_rebuild_skill_box()
	_rebuild_panel()
	_mark_dirty()

func _add_skill(sid: String, lv: int) -> void:
	if _unit == null or sid == "":
		return
	if _lost_skills.has(sid):
		_lost_skills.erase(sid)   # 同 id 从悬空转正常（如该 id 后来登记进 SkillDB）
	_set_skill_level(sid, maxi(1, lv))

func _remove_skill(sid: String) -> void:
	if _lost_skills.has(sid):
		_lost_skills.erase(sid)
	if _unit != null and _unit.skills.has(sid):
		var hp0 := float(_unit.effective_stat_f("HP_max"))
		var ar0 := float(_unit.effective_stat_f("armor_max"))
		_unit.skills.erase(sid)
		_unit.remove_modifiers_by_source("skill:" + sid)   # 被动桥修正一并摘除（source="skill:<id>"）
		_unit._rescale_vitals(hp0, ar0)
	_rebuild_skill_box()
	_rebuild_panel()
	_mark_dirty()

# 技艺区：已识（known）行内带「装载」勾选（slots ⊆ known 天然成立）+ ✕；悬空槽位引用 ⚠ 行
func _build_prof_ui() -> void:
	_strip.add_child(EditorUI.section_title("技艺（熟练度域：已识 + 装载）"))
	var adder := HBoxContainer.new()
	adder.add_theme_constant_override("separation", 6)
	var pick := OptionButton.new()
	pick.custom_minimum_size = Vector2(220, 0)
	pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pick.add_item("（选技艺域…）")
	pick.set_item_metadata(0, "")
	var seen := {}
	for pp in UnitStatusPanel.PROF_PAGES:   # 页名/序与技艺页 UI 同源 🔒（[显示名, page id]）
		var page := str(pp[1])
		var pids: Array = ProfDB.ids_by_page(page)
		if pids.is_empty():
			continue
		pick.add_separator(str(pp[0]))
		for pid in pids:
			pick.add_item("%s（%s）" % [ProfDB.prof_name(str(pid)), str(pid)])
			pick.set_item_metadata(pick.item_count - 1, str(pid))
			seen[str(pid)] = true
	var rest := []
	for pid in ProfDB.all_ids():   # 数据新加页兜底（不落在三页词表外静默消失）
		if not seen.has(str(pid)):
			rest.append(str(pid))
	if not rest.is_empty():
		pick.add_separator("其他")
		for pid in rest:
			pick.add_item("%s（%s）" % [ProfDB.prof_name(str(pid)), str(pid)])
			pick.set_item_metadata(pick.item_count - 1, str(pid))
	adder.add_child(pick)
	var addb := Button.new()
	addb.text = "＋ 已识"
	addb.tooltip_text = "加入已识列表（known）；「装载」勾选＝占槽挂阶段补正（烘焙 force，不做玩家槽位容量校验 🔒 §6）。\nxp（熟练度值）不在此编辑——随存档/战斗喂养，原样往返。"
	addb.pressed.connect(func():
		var pid := str(pick.get_selected_metadata())
		if pid != "":
			_add_prof_known(pid)
		pick.select(0))
	adder.add_child(addb)
	_strip.add_child(adder)
	_prof_box = VBoxContainer.new()
	_prof_box.add_theme_constant_override("separation", 3)
	_strip.add_child(_prof_box)
	_rebuild_prof_box()

func _rebuild_prof_box() -> void:
	if _prof_box == null or not is_instance_valid(_prof_box):
		return
	for c in _prof_box.get_children():
		c.queue_free()   # ⚠ queue_free：常由行内 ✕/勾选信号中触发
	if _unit == null:
		return
	if _unit.prof_known.is_empty() and _lost_slots.is_empty():
		_prof_box.add_child(_dim_lbl("（无）"))
		return
	for pid_v in _unit.prof_known:
		var pid := str(pid_v)
		var registered: bool = not ProfDB.get_prof(pid).is_empty()
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var l := Label.new()
		if registered:
			l.text = "%s（%s）" % [ProfDB.prof_name(pid), pid]
		else:
			l.text = "⚠ 未登记技艺「%s」——原样保留" % pid
			l.add_theme_color_override("font_color", Color(0.95, 0.8, 0.35))
			l.tooltip_text = "ProfDB 查无此 id：保存时原样写回；✕ 显式删除"
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.clip_text = true
		row.add_child(l)
		var slot_cb := CheckBox.new()
		slot_cb.text = "装载"
		slot_cb.button_pressed = _unit.prof_slots.has(pid)
		slot_cb.tooltip_text = "占槽挂阶段补正（slots；烘焙 force 装载）"
		var p2 := pid
		slot_cb.toggled.connect(func(v: bool): _toggle_prof_slot(p2, v))
		row.add_child(slot_cb)
		var rm := Button.new()
		rm.text = "✕"
		rm.pressed.connect(func(): _remove_prof_known(p2))
		row.add_child(rm)
		_prof_box.add_child(row)
	for pid_v in _lost_slots:
		var pid := str(pid_v)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var warn := Label.new()
		warn.text = "⚠ 槽位引用「%s」不在已识列表——原样保留" % pid
		warn.add_theme_color_override("font_color", Color(0.95, 0.8, 0.35))
		warn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		warn.clip_text = true
		warn.tooltip_text = "profs.slots 引用了 known 没有的 id（数据不一致）：保存时原样写回；✕ 显式删除"
		row.add_child(warn)
		var rm := Button.new()
		rm.text = "✕"
		var p2 := pid
		rm.pressed.connect(func(): _remove_lost_slot(p2))
		row.add_child(rm)
		_prof_box.add_child(row)

func _add_prof_known(pid: String) -> void:
	if _unit == null or pid == "" or _unit.prof_known.has(pid):
		return
	_unit.prof_known.append(pid)   # 直灌（与 make_unit profs.known 同轨；资格校验属游戏内学习渠道，编辑器不设门）
	if _lost_slots.has(pid):       # 悬空槽位引用因 known 补齐而转正 → 真装载
		_lost_slots.erase(pid)
		_unit.slot_prof(pid, true)
	_rebuild_prof_box()
	_rebuild_panel()
	_mark_dirty()

func _remove_prof_known(pid: String) -> void:
	if _unit == null:
		return
	_unit.unslot_prof(pid)          # 先卸载（摘 prof:<id> 阶段补正）
	_unit.prof_known.erase(pid)
	_rebuild_prof_box()
	_rebuild_panel()
	_mark_dirty()

func _toggle_prof_slot(pid: String, on: bool) -> void:
	if _unit == null:
		return
	if on:
		_unit.slot_prof(pid, true)   # force＝烘焙路径 🔒 §6（敌方/预设不走玩家槽位容量校验）
	else:
		_unit.unslot_prof(pid)
	_rebuild_panel()
	_mark_dirty()

func _remove_lost_slot(pid: String) -> void:
	_lost_slots.erase(pid)
	_rebuild_prof_box()
	_mark_dirty()

func _dim_lbl(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_color_override("font_color", Color(0.55, 0.6, 0.66))
	return l


# —— 角色卡编辑回调（UnitStatusPanel editor_mode）——

func _on_panel_edit() -> void:
	_mark_dirty()   # 卡内改姓名/等级/特性（四维直接填已删 🔒 属性重做）

# 立绘选择（角色卡头像「＋」回调）→ 走通用文件对话框
func _on_portrait_pick() -> void:
	_open_file_dialog("portrait", PORTRAIT_DIR)

# 通用图片文件对话框（portrait=立绘 / icon=棋子图标共用一份）
func _open_file_dialog(target: String, dir: String) -> void:
	_file_target = target
	if _file_dialog == null or not is_instance_valid(_file_dialog):
		_file_dialog = EditorUI.make_file_dialog(FileDialog.FILE_MODE_OPEN_FILE, FileDialog.ACCESS_RESOURCES,
			[["*.png", "PNG"], ["*.jpg,*.jpeg", "JPG"], ["*.webp", "WebP"]], false)
		_file_dialog.file_selected.connect(_on_file_picked)
		add_child(_file_dialog)
	_file_dialog.current_dir = dir
	_file_dialog.popup_centered(Vector2i(760, 520))

func _on_file_picked(path: String) -> void:
	if _unit == null: return
	if _file_target == "icon":
		_unit.icon = path
		if _icon_edit != null and is_instance_valid(_icon_edit):
			_icon_edit.text = path
		if _icon_thumb != null and is_instance_valid(_icon_thumb):
			_icon_thumb.texture = TextureCache.get_tex(path)
	else:
		_unit.portrait = path
		_rebuild_panel()   # 立绘显示在角色卡头像，重建反映
	_writeback_appearance(true)   # 写回当前外观 + 刷新 chip 缩略（离散事件，重建无妨）
	_mark_dirty()

func _on_equip_slot(slot_id: String) -> void:
	if _unit == null: return
	var ids := []
	for id in ItemDB.all().keys():
		var it = ItemDB.all()[id]
		if EquipSlots.accepts(slot_id, it) and _unit.can_equip(it):
			ids.append(id)
	var occupied: bool = _unit.equipment.has(slot_id)
	_open_item_picker("装备到「%s」" % EquipSlots.SLOT_CN.get(slot_id, slot_id), ids, occupied,
		func(picked: String):
			if picked == "":
				_unit.unequip(slot_id)
			elif not _unit.equip(picked, slot_id):
				_err("装不上（requires 未满足 / 天性武者禁外来武器 / 天生武器占槽）")
				return
			_mark_dirty()
			_rebuild_panel())

func _on_bag_slot(idx: int) -> void:
	if _unit == null or idx < 0 or idx >= _bag.size(): return
	var ids := ItemDB.all().keys()   # 背包＝任意物品
	var occupied := str(_bag[idx]) != ""
	_open_item_picker("放入背包（暂不入档）", ids, occupied,
		func(picked: String):
			_bag[idx] = picked   # picked=="" 即清空
			_rebuild_panel())    # 背包不入档 → 不标脏


# —— 物品选择器（§23 升级：搜索过滤+行图标+悬停富预览；实现上收 EditorUI.item_picker——
# DeployPanel（布置期单位编辑）将来可共用同款；本层只备料 entries。allow_clear=显示「清空该槽」）——

func _open_item_picker(title: String, ids: Array, allow_clear: bool, on_pick: Callable) -> void:
	var entries: Array = []
	for id in ids:
		var it = ItemDB.get_item(str(id))
		if it == null:
			continue
		var hex := _rarity_hex(it)
		entries.append({
			"id": str(id),
			"label": "%s（%s）" % [str(it.get("name", id)), str(id)],
			"icon": TextureCache.get_tex(str(it.get("icon", ""))),
			"color": Color(hex) if hex != "" else null,
			"item": it,   # 悬停富预览（ItemTooltip.render）
		})
	EditorUI.item_picker(self, title, entries, allow_clear, on_pick)


# —— 保存 / 删除 ——

func _collect_proto() -> Dictionary:
	var proto := UnitFactory.unit_to_proto(_unit)   # _unit 已持全部编辑态（含 tags/skills/profs；AI 字段＝默认兜底，编辑权在关卡编辑器）
	# 悬空引用保值（§7）：显式 ✕ 删除前，_lost_* 原样带回 proto——「打开即存」不丢未登记引用。
	if not _lost_skills.is_empty():
		var sk: Dictionary = proto.get("skills", {})
		for sid in _lost_skills:
			if not sk.has(sid):
				sk[sid] = int(_lost_skills[sid])
		proto["skills"] = sk
	if not _lost_slots.is_empty():
		var pf: Dictionary = proto.get("profs", {})
		var sl: Array = pf.get("slots", [])
		for pid in _lost_slots:
			if not sl.has(pid):
				sl.append(pid)
		pf["slots"] = sl
		proto["profs"] = pf
	# 外观组：编辑器侧状态挂回 proto（Unit/Factory 不参与）。
	# 只在 >1 套时写 appearances/default_appearance——单套即旧格式（顶层 portrait/icon 已由 _unit 携带），零 diff 噪音。
	if _appearances.size() > 1:
		var d = _appear_get(_default_appear)
		if d == null:
			d = _appearances[0]
		proto["portrait"] = str(d["portrait"])   # 顶层镜像默认外观 → 落子/大地图/战斗渲染即用它
		proto["icon"] = str(d["icon"])
		proto["default_appearance"] = str(d["id"])
		var out := []
		for a in _appearances:
			out.append({"id": str(a["id"]), "name": str(a["name"]),
				"portrait": str(a["portrait"]), "icon": str(a["icon"])})
		proto["appearances"] = out
	return proto

# 保存/删除流程在外壳（ListEditorShell），这里只挂库口与消息：

func _shell_collect() -> Dictionary:
	return _collect_proto()

func _shell_exists(id: String) -> bool:
	return not UnitFactory.get_prototype(id).is_empty()

func _shell_db_save(entry: Dictionary, replace_id: String) -> bool:
	return UnitFactory.save_prototype(entry, replace_id)

func _shell_db_delete(id: String) -> bool:
	return UnitFactory.delete_prototype(id)

func _shell_after_save(entry: Dictionary, id: String, renaming: bool) -> void:
	if renaming:
		_info("✓ 已保存并改 id：%s → %s（引用旧 id 的地图/事件需同步）" % [_loaded_id, id])
	else:
		_info("✓ 已保存原型「%s」→ data/unit_prototypes.json" % str(entry.get("name", id)))

func _shell_delete_confirm_text(id: String) -> String:
	return "确认删除原型「%s」(%s)？此操作直接写盘。" % [_unit.unit_name, id]


# —— 小工具 ——

func _lbl(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l

func _dropdown(values: Array, cur: String, on_change: Callable) -> OptionButton:
	var ob := OptionButton.new()
	for i in values.size():
		ob.add_item(TagDB.cn(str(values[i])))
		ob.set_item_metadata(i, str(values[i]))
		if str(values[i]) == cur:
			ob.select(i)
	ob.item_selected.connect(func(_i): on_change.call())
	return ob

func _cat_dropdown(cat: String, cur: String, on_change: Callable) -> OptionButton:
	var ob := OptionButton.new()
	ob.add_item("（无）")
	ob.set_item_metadata(0, "")
	for e in TagDB.by_cat(cat):
		var id := str(e.get("id", ""))
		ob.add_item("%s（%s）" % [str(e.get("cn", id)), id])
		ob.set_item_metadata(ob.item_count - 1, id)
	_select_meta(ob, cur)
	ob.item_selected.connect(func(_i): on_change.call())
	return ob

# 派系下拉（读 FactionDB 单一数据源的派系名册 + 无）→ 设 `camp_<id>` tag（派系归属＝ tag）。
# metadata 存 camp tag id（camp_<factionid>），与 tags.json cat "camp" 对应；_sync_tags 并入 _unit.tags。
func _faction_dropdown(cur_tag: String) -> OptionButton:
	var ob := OptionButton.new()
	ob.add_item("（无归属）")
	ob.set_item_metadata(0, "")
	for e in FactionDB.all_factions():
		var id := str(e.get("id", ""))
		ob.add_item(str(e.get("label", id)))
		ob.set_item_metadata(ob.item_count - 1, "camp_" + id)
	_select_meta(ob, cur_tag)
	ob.item_selected.connect(func(_i): _sync_tags())
	return ob

# _select_meta / _valid_id / _update_buttons / _mark_dirty / _info / _err 在 ListEditorShell

func _tag_in_cat(cat: String) -> String:
	var ids := TagDB.ids_in_cat(cat)
	for t in _unit.tags:
		if ids.has(str(t)):
			return str(t)
	return ""

func _cat_of(tag: String) -> String:
	var e = TagDB.get_tag(tag)
	return str(e.get("cat", "")) if e != null else ""

func _rarity_hex(item: Dictionary) -> String:
	for t in item.get("tags", []):
		var hex := TagDB.color(str(t))
		if hex != "":
			return hex
	return ""

