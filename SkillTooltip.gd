extends RefCounted
## 技能富 tooltip 面板（SkillTooltip.render(def)）：技能编辑器右栏即时预览首发；
## 游戏侧（能力菜单悬停/状态页技能卡）后续同吃这一份渲染。风格与 ItemTooltip 一致（黑底+边框）。
## 小件复用 ItemTooltip 共用区（tag_chip/_tags/mod_line/_kv/_icon/_desc_label——「公开：物品/技能/特性 tooltip 复用同一份」约定）。

const TagDB := preload("res://TagDB.gd")
const SkillDB := preload("res://SkillDB.gd")
const EffectDB := preload("res://EffectDB.gd")
const TextureCache := preload("res://TextureCache.gd")
const ItemTooltip := preload("res://ItemTooltip.gd")

const CAT_CN := {"skill": "技巧", "spell": "魔法"}
const DMG_CAT_CN := ItemTooltip.DMG_CAT_CN   # 伤害属性中文词表单源（ItemTooltip 共用）

static func render(def: Dictionary) -> Control:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 1)
	sb.border_color = Color(0.45, 0.6, 0.85, 0.8)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 5)
	panel.add_child(v)

	# 抬头：图标 + 名称 + 类别·主/被动
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	var itex := TextureCache.get_tex(str(def.get("icon", "")))
	if itex != null:
		head.add_child(ItemTooltip._icon(itex, 42))
	var headv := VBoxContainer.new()
	headv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var name_l := Label.new()
	var nm := str(def.get("name", ""))
	name_l.text = nm if nm != "" else "（未命名）"
	name_l.add_theme_font_size_override("font_size", 19)
	name_l.add_theme_color_override("font_color", Color("#EBBC04"))
	headv.add_child(name_l)
	var sub := Label.new()
	var parts := [str(CAT_CN.get(str(def.get("category", "skill")), def.get("category", "")))]
	parts.append("主动" if bool(def.get("active", true)) else "被动")
	if bool(def.get("weapon_skill", false)):
		parts.append("武器技能")
	sub.text = " · ".join(parts)
	sub.add_theme_font_size_override("font_size", 12)
	sub.add_theme_color_override("font_color", Color(0.66, 0.7, 0.78))
	headv.add_child(sub)
	head.add_child(headv)
	v.add_child(head)

	ItemTooltip._tags(v, def.get("tags", []))

	# 武器技能：适用种类 + 握持要求
	if bool(def.get("weapon_skill", false)):
		var kinds: Array = def.get("weapon_kinds", [])
		var kn := []
		for k in kinds:
			kn.append(TagDB.cn(str(k)))
		v.add_child(ItemTooltip._kv("适用武器", "、".join(kn) if not kn.is_empty() else "通用（不限种类）"))
		# （握持要求不在技能侧——2026-07-15 用户裁定：握持组挂武器 ews/ews_2h，武器 tooltip 标注）

	# 施放成本（主动才有意义；被动无此段）
	if bool(def.get("active", true)):
		var cost := "%d AP" % SkillDB.skill_ap_cost(def)
		var cd := int((def.get("cooldown", {}) as Dictionary).get("base", 0)) if typeof(def.get("cooldown")) == TYPE_DICTIONARY else 0
		if cd > 0:
			cost += " · 冷却 %d" % cd
		var uses := int((def.get("uses_per_battle", {}) as Dictionary).get("base", 0)) if typeof(def.get("uses_per_battle")) == TYPE_DICTIONARY else 0
		if uses > 0:
			cost += " · 每战 %d 次" % uses
		v.add_child(ItemTooltip._kv("消耗", cost))
		v.add_child(ItemTooltip._kv("距离", "%d" % SkillDB.skill_reach(def)))
		var tg = def.get("target", {})
		if typeof(tg) == TYPE_DICTIONARY and not tg.is_empty():
			var tn := []
			if bool(tg.get("enemy", false)): tn.append("敌方")
			if bool(tg.get("ally", false)): tn.append("友方")
			if bool(tg.get("self", false)): tn.append("自身")
			v.add_child(ItemTooltip._kv("目标", "、".join(tn) if not tn.is_empty() else "（无——存盘会被拦）"))

	# 效果块逐块渲染
	for block in def.get("effects", []):
		if typeof(block) != TYPE_DICTIONARY:
			continue
		match str(block.get("kind", "")):
			"attack":
				var hits: Array = block.get("hits", [])
				if hits.is_empty() or typeof(hits[0]) != TYPE_DICTIONARY:
					continue
				var hit: Dictionary = hits[0]
				v.add_child(HSeparator.new())
				v.add_child(ItemTooltip._kv("伤害系数", "%d%%" % int(round(float(hit.get("coeff", 1.0)) * 100.0))))
				var bh := float(hit.get("hit", 0))
				if bh != 0.0:
					v.add_child(ItemTooltip._kv("命中系数", "%s%%" % ItemTooltip._num(bh)))
				var dc := str(hit.get("damage_category", ""))
				if dc != "":
					v.add_child(ItemTooltip._kv("伤害属性", str(DMG_CAT_CN.get(dc, dc))))
				var dt := str(hit.get("damage_type", ""))
				if dt != "":
					v.add_child(ItemTooltip._kv("伤害类型", TagDB.cn(dt)))
				var pen := float(hit.get("armor_pen", 0))
				if pen > 0.0:
					v.add_child(ItemTooltip._kv("穿甲", "%s%%（按比例无视护甲）" % ItemTooltip._num(pen * 100.0)))
				if bool(hit.get("sure_hit", false)):
					v.add_child(ItemTooltip._kv("必中", "无视命中对抗"))
				for se in hit.get("on_hit_effects", []):
					if typeof(se) == TYPE_DICTIONARY and str(se.get("effect", "")) != "":
						var edef = EffectDB.get_effect(str(se["effect"]))
						var enm := str(edef.get("name", se["effect"])) if edef != null else "%s（引用悬空）" % str(se["effect"])
						v.add_child(ItemTooltip._kv("击中施加", "%s %s%%" % [enm, ItemTooltip._num(float(se.get("chance", 100)))]))
				var kb = hit.get("on_hit_displace", null)   # 击退（🔒 2026-07-15 概率制：判定＝概率−目标肉体强韧，格挡免推）
				if typeof(kb) == TYPE_DICTIONARY:
					v.add_child(ItemTooltip._kv("击退", "%d 格 %s%%（减目标肉体强韧；格挡免推）" % [
						maxi(1, int(kb.get("distance", 1))), ItemTooltip._num(float(kb.get("chance", 100)))]))
				var shp: Dictionary = SkillDB.shape_of(def)
				if not (shp.get("effect", []) as Array).is_empty():
					var ff0 := "·友伤" if bool(shp.get("friendly_fire", false)) else ""
					var anc := "锚落点" if str(shp.get("anchor", "caster")) == "target" else "随方向"
					v.add_child(ItemTooltip._kv("范围", "AOE %d 格（%s%s）" % [(shp["effect"] as Array).size(), anc, ff0]))
				elif typeof(hit.get("aoe")) == TYPE_DICTIONARY:
					var aoe: Dictionary = hit["aoe"]
					v.add_child(ItemTooltip._kv("范围", "%s·长%d%s" % [str(aoe.get("shape", "")), int(aoe.get("length", 1)), "（友伤）" if bool(aoe.get("friendly_fire", false)) else ""]))
			"heal":
				v.add_child(HSeparator.new())
				v.add_child(ItemTooltip._kv("治疗", "%s%% 最大生命" % _fmt_num(block.get("heal_pct_max_hp", 0))))
				var cl = block.get("cleanse_tags", [])
				if typeof(cl) == TYPE_ARRAY and not cl.is_empty():
					var cln := []
					for t in cl:
						cln.append(TagDB.cn(str(t)))
					v.add_child(ItemTooltip._kv("净化", "、".join(cln)))
			"apply_effect":
				v.add_child(HSeparator.new())
				var eid := str(block.get("effect", ""))
				var edef2 = EffectDB.get_effect(eid)
				var enm2 := str(edef2.get("name", eid)) if edef2 != null else "%s（引用悬空）" % eid
				v.add_child(ItemTooltip._kv("施加效果", "%s %s%%" % [enm2, ItemTooltip._num(float(block.get("chance", 100)))]))
			"passive_stat_mods", "conditional_mod":
				v.add_child(HSeparator.new())
				if str(block.get("kind", "")) == "conditional_mod":
					v.add_child(ItemTooltip._kv("条件修正", "%d 项条件全满足时生效" % (block.get("when", []) as Array).size()))
				for m in block.get("mods", []):
					if typeof(m) == TYPE_DICTIONARY:
						v.add_child(ItemTooltip.mod_line(m))
			"scripted":
				v.add_child(HSeparator.new())
				v.add_child(ItemTooltip._kv("脚本效果", str(block.get("script", "（专属逻辑）"))))

	# 风味文本置底（与 ItemTooltip 同惯例）
	var desc := str(def.get("desc", ""))
	if desc != "":
		v.add_child(HSeparator.new())
		v.add_child(ItemTooltip._desc_label(desc))
	return panel

# 公式化数值的展示（标量 / {base,per_level,per_stat}）：编辑器预览用粗口径
static func _fmt_num(val) -> String:
	if typeof(val) in [TYPE_INT, TYPE_FLOAT]:
		return str(ItemTooltip._num(float(val)))
	if typeof(val) == TYPE_DICTIONARY:
		var pl = val.get("per_level", null)
		if typeof(pl) == TYPE_ARRAY and not (pl as Array).is_empty():
			var parts := []
			for x in pl:
				parts.append(str(ItemTooltip._num(float(x))))
			return "/".join(parts)
		return str(ItemTooltip._num(float(val.get("base", 0))))
	return str(val)
