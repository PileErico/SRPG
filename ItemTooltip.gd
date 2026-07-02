extends RefCounted
## 物品富 tooltip 的**通用渲染组件**——游戏内（UnitStatusPanel）与物品编辑器（ItemEditor）共用一份。
## 取代两处各自的 `_build_item_tooltip` / `_render_item_tooltip` + `_tag_chip`（消除重复）：
##   tag → 中文统一 `TagDB.cn`、stat → 中文统一 `StatMeta.label`、稀有度色统一 `TagDB.color`、图标统一 `TextureCache`。
## 用法：const ItemTooltip := preload("res://ItemTooltip.gd")；panel = ItemTooltip.render(item)

const TagDB := preload("res://TagDB.gd")
const StatMeta := preload("res://StatMeta.gd")
const TextureCache := preload("res://TextureCache.gd")
const EquipSlots := preload("res://EquipSlots.gd")
const ItemDB := preload("res://ItemDB.gd")

const KIND_CN := {"weapon": "武器", "armor": "防具", "accessory": "饰品"}

# 物品富 tooltip 面板：纯黑底 + 稀有度边框；名称(稀有度色)/种类·部位/标签/需求/mods/攻击 skill。
static func render(item: Dictionary) -> Control:
	var rc = _rarity_color(item)
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 1)
	sb.border_color = rc if rc != null else Color(1, 1, 1, 0.3)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 5)
	panel.add_child(v)

	# 抬头：图标 + 名称 + 种类·部位
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var itex := TextureCache.get_tex(str(item.get("icon", "")))
	if itex != null:
		head.add_child(_icon(itex, 42))
	var headv := VBoxContainer.new()
	headv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var name_l := Label.new()
	var nm := str(item.get("name", ""))
	name_l.text = nm if nm != "" else "（未命名）"
	name_l.add_theme_font_size_override("font_size", 19)
	if rc != null:
		name_l.add_theme_color_override("font_color", rc)
	headv.add_child(name_l)
	var slot := str(item.get("slot", ""))
	var kind := str(ItemDB.kind_of(item))
	var sub := Label.new()
	sub.text = "%s · %s" % [str(KIND_CN.get(kind, kind)), str(EquipSlots.SLOT_CN.get(slot, slot))]
	sub.add_theme_font_size_override("font_size", 12)
	sub.add_theme_color_override("font_color", Color(0.66, 0.7, 0.78))
	headv.add_child(sub)
	head.add_child(headv)
	v.add_child(head)

	_tags(v, item.get("tags", []))

	# 需求（requires tag → 中文）
	var req = item.get("requires", [])
	if typeof(req) == TYPE_ARRAY and not req.is_empty():
		var rn := []
		for q in req:
			rn.append(TagDB.cn(str(q)))
		var rl := Label.new()
		rl.text = "需求：" + "、".join(rn)
		rl.add_theme_font_size_override("font_size", 12)
		rl.add_theme_color_override("font_color", Color(0.95, 0.62, 0.5))
		v.add_child(rl)

	# mods
	for m in item.get("mods", []):
		if typeof(m) == TYPE_DICTIONARY:
			v.add_child(_mod_line(m))

	# 攻击 skill
	var atk = item.get("attack", null)
	if typeof(atk) == TYPE_DICTIONARY:
		v.add_child(HSeparator.new())
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 8)
		var atex := TextureCache.get_tex(str(atk.get("icon", "")))
		if atex != null:
			hb.add_child(_icon(atex, 36))
		var sn := Label.new()
		sn.text = str(atk.get("name", ""))
		sn.add_theme_font_size_override("font_size", 17)
		sn.add_theme_color_override("font_color", Color("#EBBC04"))
		sn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		hb.add_child(sn)
		v.add_child(hb)
		_tags(v, atk.get("tags", []))
		v.add_child(_kv("距离", "%d" % int(atk.get("range", 1))))
		v.add_child(_kv("伤害系数", "%d%%" % int(round(float(atk.get("coeff", 1.0)) * 100.0))))
		v.add_child(_kv("AP 消耗", "%d" % int(atk.get("ap_cost", 1))))
		var dk := str(atk.get("damage_kind", ""))
		if dk != "":
			v.add_child(_kv("伤害类型", dk))
		var bspec = atk.get("bonus", null)
		if typeof(bspec) == TYPE_DICTIONARY:
			var ns := []
			for s in bspec.get("stats", []):
				ns.append(StatMeta.label(str(s)))
			v.add_child(_kv("伤害补正", "（%s）×%s（不吃效能）" % ["＋".join(ns), _num(float(bspec.get("mult", 0)))]))
		var pen := float(atk.get("armor_pen", 0))
		if pen > 0.0:
			v.add_child(_kv("穿甲", "%s%%（按比例无视护甲）" % _num(pen * 100.0)))
		var inf = atk.get("inflict", null)
		if typeof(inf) == TYPE_DICTIONARY:
			var txt := "%s%% 施加 %s" % [_num(float(inf.get("chance", 0))), str(inf.get("name", ""))]
			if float(inf.get("dot_pct_max_hp", 0)) > 0.0:
				txt += "（回合末 最大生命%s%%·%d回合）" % [_num(float(inf.get("dot_pct_max_hp", 0))), int(inf.get("duration", 0))]
			v.add_child(_kv("异常", txt))
		var aoe = atk.get("aoe", null)
		if typeof(aoe) == TYPE_DICTIONARY:
			var ff := "（友伤）" if bool(aoe.get("friendly_fire", false)) else ""
			v.add_child(_kv("范围", "%s·长%d%s" % [str(aoe.get("shape", "")), int(aoe.get("length", 1)), ff]))
		var prefer := str(atk.get("prefer", ""))
		if prefer == "ground" or prefer == "air":
			var note := Label.new()
			note.text = "地面战斗时优先使用" if prefer == "ground" else "天空战斗时优先使用"
			note.add_theme_font_size_override("font_size", 12)
			note.add_theme_color_override("font_color", Color(0.70, 0.85, 1.0))
			v.add_child(note)
	return panel

# —— 共用小件（tag_chip 公开，供技能/特性 tooltip 等复用）——
static func tag_chip(text: String) -> Control:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.14)
	sb.set_corner_radius_all(3)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 1
	sb.content_margin_bottom = 1
	p.add_theme_stylebox_override("panel", sb)
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	p.add_child(l)
	return p

static func _tags(parent: Node, tags) -> void:
	if typeof(tags) != TYPE_ARRAY or tags.is_empty():
		return
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 4)
	flow.add_theme_constant_override("v_separation", 4)
	flow.custom_minimum_size = Vector2(150, 0)
	for t in tags:
		flow.add_child(tag_chip(TagDB.cn(str(t))))
	parent.add_child(flow)

static func _mod_line(m: Dictionary) -> Label:
	var l := Label.new()
	var val := float(m.get("value", 0))
	var sfx := "%" if str(m.get("op", "flat")) == "pct" else ""
	var sign := "+" if val >= 0.0 else ""
	l.text = "%s %s%s%s" % [StatMeta.label(str(m.get("stat", ""))), sign, _num(val), sfx]
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color(0.45, 0.85, 0.5) if val >= 0.0 else Color(0.92, 0.5, 0.5))
	return l

static func _kv(k: String, val: String) -> Label:
	var l := Label.new()
	l.text = "%s：%s" % [k, val]
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color(0.82, 0.85, 0.9))
	return l

static func _icon(tex: Texture2D, size: int) -> TextureRect:
	var ic := TextureRect.new()
	ic.texture = tex
	ic.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ic.custom_minimum_size = Vector2(size, size)
	return ic

# item 稀有度色：tags 里带 color 的（＝稀有度）tag → TagDB.color；无则 null
static func _rarity_color(item):
	for t in item.get("tags", []):
		var hex := TagDB.color(str(t))
		if hex != "":
			return Color(hex)
	return null

static func _num(v: float):
	return int(v) if v == floor(v) else v
