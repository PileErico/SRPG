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
const SkillDB := preload("res://SkillDB.gd")   # skill_ap_cost 双键桥 + bws 引用解析 flatten_bws（阶段3a）
const EffectDB := preload("res://EffectDB.gd") # inflict 引用形 {effect,chance} 的效果名解析
const ProfDB := preload("res://ProfDB.gd")     # EWS 解锁条件显示（技艺域名，决策26）

# 修正行语义色（与 Sandbox.OK_GREEN/BAD_RED、UnitStatusPanel.STAT_GREEN/RED 同 hex——语义色全局统一待 D8 拍板）
const MOD_GREEN := Color("#6FCF6F")
const MOD_RED := Color("#E07A5A")
const VISION_STATE_CN := {"nightvision": "黑夜视觉", "blind": "无视力"}   # vision_state mod 值→中文（物品自身 tooltip 显示；角色面板不显示）

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
	var slot_cn := str(EquipSlots.SLOT_CN.get(slot, slot))
	var sub := Label.new()
	sub.text = ("%s · %s" % [ItemDB.kind_cn(ItemDB.kind_of(item)), slot_cn]) if slot_cn != "" else ItemDB.kind_cn(ItemDB.kind_of(item))
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

	# 武器固有属性（🔒 决策33 三轮校准：攻/格挡率%/格挡性能%——命中在武器技能侧；0=无不显）
	# 兼用件（🔒 决策35）：顶层三键标「双手·单持」、one_handed 子面板另起「单手持（配副手）」段
	var versat: bool = (item.get("tags", []) as Array).has("versatile")
	for p in [["atk", "攻击"], ["block_rate", "格挡率"], ["block_power", "格挡性能"]]:
		var iv := float(item.get(str(p[0]), 0))
		if iv != 0.0:
			var lbl := str(p[1]) + ("（双手·单持）" if versat else "")
			v.add_child(_kv(lbl, ("%s%%" % _num(iv)) if str(p[0]) != "atk" else str(_num(iv))))
	var oh1 = item.get("one_handed", null)
	if versat and typeof(oh1) == TYPE_DICTIONARY:
		for p in [["atk", "攻击"], ["block_rate", "格挡率"], ["block_power", "格挡性能"]]:
			var iv1 := float(oh1.get(str(p[0]), 0))
			if iv1 != 0.0:
				v.add_child(_kv("%s（单手·配副手）" % str(p[1]), ("%s%%" % _num(iv1)) if str(p[0]) != "atk" else str(_num(iv1))))

	# mods（词条/附加修正）
	for m in item.get("mods", []):
		if typeof(m) == TYPE_DICTIONARY:
			v.add_child(mod_line(m))

	# On-Hit 族（🔒 决策33：打中附带——普攻/武器技能/借机都触发；甲伤同族〔任意招式都破坏护甲〕）
	var adm := float(item.get("armor_dmg", 0))
	if adm != 0.0:
		v.add_child(_kv("甲伤", "%s%%（对护甲额外伤害·任意招式）" % _num(adm)))
	for e in item.get("on_hit_effects", []):
		if typeof(e) == TYPE_DICTIONARY and str(e.get("effect", "")) != "":
			var oedef = EffectDB.get_effect(str(e["effect"]))
			var oenm := str(oedef.get("name", e["effect"])) if oedef != null else str(e["effect"])
			v.add_child(_kv("击中施加", "%s %s%%" % [oenm, _num(float(e.get("chance", 100)))]))

	# 使用效果 on_use（消耗品；数据/渲染共用一处，编辑器预览与将来背包 tooltip 同源）
	var ou = item.get("on_use", null)
	if typeof(ou) == TYPE_DICTIONARY and not ou.is_empty():
		v.add_child(HSeparator.new())
		var ul := Label.new()
		ul.text = "使用效果"
		ul.add_theme_font_size_override("font_size", 14)
		ul.add_theme_color_override("font_color", Color("#7FD08A"))
		v.add_child(ul)
		var tgt := str(item.get("target", "ally"))
		var tgt_cn := str({"self": "自身", "ally": "友方", "enemy": "敌对"}.get(tgt, tgt))
		v.add_child(_kv("　作用对象", tgt_cn if tgt == "self" else "%s（距离 %d）" % [tgt_cn, int(item.get("range", 1))]))
		if float(ou.get("heal_pct_max_hp", 0)) > 0.0:
			v.add_child(_kv("　回复生命", "最大生命 %s%%" % _num(float(ou.get("heal_pct_max_hp", 0)))))
		if float(ou.get("heal_flat", 0)) > 0.0:
			v.add_child(_kv("　回复生命", "%s 点" % _num(float(ou.get("heal_flat", 0)))))
		if float(ou.get("restore_fatigue_pct", 0)) > 0.0:
			v.add_child(_kv("　回复疲劳", "最大疲劳 %s%%" % _num(float(ou.get("restore_fatigue_pct", 0)))))
		var cl = ou.get("cleanse_tags", [])
		if typeof(cl) == TYPE_ARRAY and not cl.is_empty():
			var cln := []
			for t in cl:
				cln.append(TagDB.cn(str(t)))
			v.add_child(_kv("　净化", "、".join(cln)))

	# 攻击 skill（阶段3a 🔒 决策26：优先 bws 引用 → SkillDB 扁平化；双读窗口回退旧内联 attack）
	var atk = item.get("attack", null)
	var bws := SkillDB.weapon_bws_id(item)   # 双读单口（§1-6）
	if bws != "":
		var bdef = SkillDB.get_skill(bws)
		if bdef != null:
			var flat := SkillDB.flatten_bws(bdef)
			if not flat.is_empty():   # flatten 空（引用无 attack 块）→ 保持内联回退，勿渲染空壳攻击段
				atk = flat
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
		v.add_child(_kv("距离", "%d" % SkillDB.skill_reach(atk)))   # 形状掩码优先、range 兜底（决策30）
		v.add_child(_kv("伤害系数", "%d%%" % int(round(float(atk.get("coeff", 1.0)) * 100.0))))
		v.add_child(_kv("AP 消耗", "%d" % SkillDB.skill_ap_cost(atk)))
		var dc := str(atk.get("damage_category", ""))
		if dc != "":
			v.add_child(_kv("伤害属性", dc))
		var dt := str(atk.get("damage_type", ""))
		if dt != "":
			v.add_child(_kv("伤害类型", TagDB.cn(dt)))
		var bspec = atk.get("bonus", null)
		if typeof(bspec) == TYPE_DICTIONARY:
			var ns := []
			for s in bspec.get("stats", []):
				ns.append(StatMeta.label(str(s)))
			v.add_child(_kv("伤害补正", "（%s）×%s（不吃效能）" % ["＋".join(ns), _num(float(bspec.get("mult", 0)))]))
		var bhit := float(atk.get("hit", 0))
		if bhit > 0.0:
			v.add_child(_kv("命中", "%s%%（技能基准，角色命中修正叠加其上）" % _num(bhit)))
		var pen := float(atk.get("armor_pen", 0))
		if pen > 0.0:
			v.add_child(_kv("穿甲", "%s%%（按比例无视护甲）" % _num(pen * 100.0)))
		var inf = atk.get("inflict", null)
		if typeof(inf) == TYPE_DICTIONARY:
			# 效果名：引用形 {effect,chance} 经 EffectDB 解析（🔒 §2.2 引用制）；旧内联 name 兜底
			var iname := str(inf.get("name", ""))
			var eid := str(inf.get("effect", ""))
			if eid != "":
				var edef = EffectDB.get_effect(eid)
				if edef != null:
					iname = str(edef.get("name", eid))
			var txt := "%s%% 施加 %s" % [_num(float(inf.get("chance", 100))), iname]
			if float(inf.get("dot_pct_max_hp", 0)) > 0.0:
				txt += "（回合末 最大生命%s%%·%d回合）" % [_num(float(inf.get("dot_pct_max_hp", 0))), int(inf.get("duration", 0))]
			v.add_child(_kv("异常", txt))
		var shp: Dictionary = SkillDB.shape_of(atk)
		if not (shp.get("effect", []) as Array).is_empty():
			var ff0 := "·友伤" if bool(shp.get("friendly_fire", false)) else ""
			var anc := "锚落点" if str(shp.get("anchor", "caster")) == "target" else "随方向"
			v.add_child(_kv("范围", "AOE %d 格（%s%s）" % [(shp["effect"] as Array).size(), anc, ff0]))
		var aoe = atk.get("aoe", null)
		if typeof(aoe) == TYPE_DICTIONARY:
			var ff := "（友伤）" if bool(aoe.get("friendly_fire", false)) else ""
			v.add_child(_kv("范围", "%s·长%d%s" % [str(aoe.get("shape", "")), int(aoe.get("length", 1)), ff]))
		var prefer := str(item.get("prefer", atk.get("prefer", "")))   # 阶段3a：prefer 上提武器级（双读旧位）
		if prefer == "ground" or prefer == "air":
			var note := Label.new()
			note.text = "地面战斗时优先使用" if prefer == "ground" else "天空战斗时优先使用"
			note.add_theme_font_size_override("font_size", 12)
			note.add_theme_color_override("font_color", Color(0.70, 0.85, 1.0))
			v.add_child(note)
	# EWS 额外技能陈列（🔒 决策26：解锁条件跟武器引用走；tooltip 只陈列定义+条件，解锁态在能力菜单表达）
	var ews = item.get("ews", [])
	if typeof(ews) == TYPE_ARRAY and not ews.is_empty():
		v.add_child(HSeparator.new())
		for e in ews:
			var sid := str(e.get("skill", "")) if typeof(e) == TYPE_DICTIONARY else str(e)
			var sdef = SkillDB.get_skill(sid)
			var ews_nm := str(sdef.get("name", sid)) if sdef != null else "%s（引用悬空）" % sid
			var req_txt := ""
			if typeof(e) == TYPE_DICTIONARY:
				var parts := []
				for r in e.get("requires", []):
					if typeof(r) == TYPE_DICTIONARY:
						parts.append("%s %d" % [ProfDB.prof_name(str(r.get("prof", ""))), int(r.get("value", 0))])
				if not parts.is_empty():
					req_txt = "（需 %s）" % " ∧ ".join(parts)
			# 握持要求（🔒 决策35 运行时条件：与解锁条件并列陈列）
			var gv := str(sdef.get("grip", "")) if sdef != null else ""
			if gv != "":
				req_txt += "（需双手持）" if gv == "two_handed" else "（需单手持）"
			v.add_child(_kv("额外技能", ews_nm + req_txt))
	# 风味文本 desc（§33 可选键，旧数据无此键＝不渲染）：置底斜体灰——RPG tooltip 惯例位
	var desc := str(item.get("desc", ""))
	if desc != "":
		v.add_child(HSeparator.new())
		v.add_child(_desc_label(desc))
	return panel

# —— 共用小件（公开：物品/技能/特性 tooltip 与角色状态页复用同一份，字号按场合传）——
static func tag_chip(text: String, font_px := 12) -> Control:
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
	l.add_theme_font_size_override("font_size", font_px)
	l.add_theme_color_override("font_color", Color(0.86, 0.86, 0.9))
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

# 一条修正数值行（绿=加/红=减；抗性/效能/率类即便 flat 也带 % —— StatMeta.is_pct 语义）。
# 词条来源 mod（ItemInstances.view 并入时打 affix 标记）行尾注〔词条名〕——白板与带词条件在 tooltip 可分辨。
static func mod_line(m: Dictionary, font_px := 13) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", font_px)
	var key := str(m.get("stat", ""))
	var afx := str(m.get("affix", ""))
	var afx_sfx := ("〔%s〕" % afx) if afx != "" else ""
	if key == "vision_state":   # 非数值状态旗：直接显状态名（如「黑夜视觉」，蓝），不加前缀、不走 ±数值/百分比
		var vv := str(m.get("value", ""))
		l.text = str(VISION_STATE_CN.get(vv, vv)) + afx_sfx
		l.add_theme_color_override("font_color", Color("#7FB0E0"))
		return l
	var val := float(m.get("value", 0))
	var sfx := "%" if (str(m.get("op", "flat")) == "pct" or StatMeta.is_pct(key)) else ""
	var sgn := "+" if val >= 0.0 else ""
	l.text = "%s %s%s%s%s" % [StatMeta.label(key), sgn, _num(val), sfx, afx_sfx]
	l.add_theme_color_override("font_color", MOD_GREEN if val >= 0.0 else MOD_RED)
	return l

# §33 风味文本行：仿斜体（FontVariation 剪切——参数照引擎默认主题 italics_font 的 Transform2D(1,0.2,0,1,0,0)）
# + 灰字 + 自动换行。CJK 若走系统回退字体则剪切可能不生效——灰字置底仍与机制段可分辨。
static func _desc_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(220, 0)
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.64, 0.66, 0.72))
	var fv := FontVariation.new()
	fv.base_font = l.get_theme_font("font")
	fv.variation_transform = Transform2D(Vector2(1.0, 0.2), Vector2(0.0, 1.0), Vector2.ZERO)
	l.add_theme_font_override("font", fv)
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
