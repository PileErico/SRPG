extends RefCounted
## 造单位 / 序列化 / 原型·预设读写的单一入口（仿 *DB 伪单例：preload + 静态函数，不用 class_name）。
## 供 Sandbox（战斗/布置）、MapEditor（单位层深度编辑）、将来角色编辑器共用——
## 「proto 字典 ↔ 活的 Unit」往返都收在这里，任何一方都不必自己拼装。
##
## 用法：const UnitFactory := preload("res://UnitFactory.gd")
##       var u = UnitFactory.make_unit(proto, "enemy", 10, 7)   # proto → Unit
##       var proto = UnitFactory.unit_to_proto(u)               # Unit → proto

const Unit := preload("res://Unit.gd")

const PROTOS_PATH := "res://data/unit_prototypes.json"   # 内置原型
const PRESETS_PATH := "user://unit_presets.json"         # 用户自存预设（跨次启动保留）

# proto 字典 → 配置完毕的 Unit（四维/特性/装备/技能/AI 全组装，收尾 recompute_derived + init_vitals）。
static func make_unit(proto: Dictionary, fac: String, col: int, row: int):
	var u = Unit.new(str(proto.get("name", "新兵")), fac, col, row)
	u.portrait = str(proto.get("portrait", ""))
	u.icon = str(proto.get("icon", ""))
	for t in proto.get("tags", []):
		if not u.tags.has(str(t)):
			u.tags.append(str(t))
	var four = proto.get("four", {})
	if typeof(four) == TYPE_DICTIONARY and not four.is_empty():
		set_four(u, int(four.get("STR", 5)), int(four.get("DEX", 5)), int(four.get("INT", 5)), int(four.get("STA", 5)))
	if proto.get("speed", null) != null:
		u.stats["speed"] = int(proto["speed"])
	u.level = int(proto.get("level", 1))
	u.exp = int(proto.get("exp", 0))
	u.exp_max = int(proto.get("exp_max", u.exp_max))
	var tr := str(proto.get("trait", ""))
	if tr != "":
		u.set_trait(tr)
	for it in proto.get("equip", []):
		u.equip(str(it))
	# 属性覆盖（预设里手动调过的非派生属性：move/speed/AP_max/armor_max/各抗/效能…）
	var ov = proto.get("stats", {})
	if typeof(ov) == TYPE_DICTIONARY:
		for k in ov:
			u.stats[k] = ov[k]
	# 技能：列表（各学到 1 级）或字典 {id:level}（学到该等级）
	var sk_src = proto.get("skills", [])
	if typeof(sk_src) == TYPE_DICTIONARY:
		for sid in sk_src:
			for _n in range(maxi(1, int(sk_src[sid]))):
				if u.learn_skill(str(sid)) == 0:
					break
	else:
		for sk in sk_src:
			u.learn_skill(str(sk))
	# 敌方 AI 字段（玩家/友方忽略）
	u.ai_threat = bool(proto.get("ai_threat", true))
	u.ai_region = str(proto.get("ai_region", ""))
	u.ai_group = str(proto.get("ai_group", ""))
	u.recompute_derived()
	u.init_vitals()
	return u

# 设四维主属性（力量/灵巧/智力/体力）
static func set_four(u, strv: int, dex: int, intl: int, sta: int) -> void:
	u.stats["STR"] = strv
	u.stats["DEX"] = dex
	u.stats["INT"] = intl
	u.stats["STA"] = sta

# Unit → proto 字典（可被 make_unit 复原）。阵营立场/flying 不入 tags（单独存/运行时态）。
static func unit_to_proto(u) -> Dictionary:
	var keep_tags := []
	for t in u.tags:
		if t in ["player", "ally", "enemy", "neutral", "flying"]:
			continue
		keep_tags.append(t)
	var equip_ids := []
	for slot in u.equipment:
		var id = u.equipment[slot]
		if not equip_ids.has(id):
			equip_ids.append(id)
	var skill_lv := {}
	for sid in u.skills:
		skill_lv[sid] = u.skill_level(sid)
	var stat_ov := {}
	for k in ["move", "speed", "sight", "AP_max", "armor_max", "atk_eff", "def_eff", "res_phys", "res_fire", "res_thunder", "res_ice", "res_holy"]:
		stat_ov[k] = u.stats.get(k, 0)
	return {
		"name": u.unit_name,
		"default_faction": u.faction,
		"portrait": u.portrait,
		"icon": u.icon,
		"tags": keep_tags,
		"four": {"STR": u.stats.get("STR", 5), "DEX": u.stats.get("DEX", 5), "INT": u.stats.get("INT", 5), "STA": u.stats.get("STA", 5)},
		"level": u.level,
		"exp": u.exp,
		"exp_max": u.exp_max,
		"trait": u.trait_id,
		"equip": equip_ids,
		"skills": skill_lv,
		"stats": stat_ov,
		"_preset": true,
	}

# ============ campaign 层（战役续存，供 WorldState 调用）============
# campaign 条目 = proto（定义/养成）⊕ 跨战运行态（uid / 当前 HP / 当前护甲）。
# 战斗内瞬态（AP/位置/buff/冷却）不入——那是战中临时存档（BattleState）的事。
static func unit_to_campaign(u) -> Dictionary:
	return {
		"uid": u.uid,
		"proto": unit_to_proto(u),
		"hp": int(u.stats.get("HP", 0)),
		"armor": int(u.stats.get("armor", 0)),
	}

# 读档复原：make_unit 会 init_vitals 注满 —— 之后再覆写 HP/armor（绕开注满，战损跨存档保留）。
static func unit_from_campaign(entry: Dictionary):
	var proto = entry.get("proto", {})
	if typeof(proto) != TYPE_DICTIONARY:
		proto = {}
	var u = make_unit(proto, str(proto.get("default_faction", "player")), -1, -1)   # col/row=-1＝待命（非战斗中）
	u.uid = int(entry.get("uid", 0))
	u.stats["HP"] = clampi(int(entry.get("hp", u.stats.get("HP", 0))), 0, int(u.effective_stat("HP_max")))
	u.stats["armor"] = clampi(int(entry.get("armor", u.stats.get("armor", 0))), 0, int(u.effective_stat("armor_max")))
	return u

# 读 unit_prototypes.json 的内置原型列表
static func all_prototypes() -> Array:
	var out := []
	if FileAccess.file_exists(PROTOS_PATH):
		var f := FileAccess.open(PROTOS_PATH, FileAccess.READ)
		var d = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(d) == TYPE_ARRAY:
			for e in d:
				if typeof(e) == TYPE_DICTIONARY:
					out.append(e)
	return out

static func load_presets() -> Array:
	if not FileAccess.file_exists(PRESETS_PATH):
		return []
	var f := FileAccess.open(PRESETS_PATH, FileAccess.READ)
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	return d if typeof(d) == TYPE_ARRAY else []

# 把单位存成预设（名 preset_name），写进 user://unit_presets.json（同名覆盖）
static func save_preset(u, preset_name: String) -> void:
	if u == null or preset_name.strip_edges() == "":
		return
	var proto := unit_to_proto(u)
	proto["name"] = preset_name
	var arr := load_presets()
	var replaced := false
	for i in arr.size():
		if str(arr[i].get("name", "")) == preset_name:
			arr[i] = proto
			replaced = true
			break
	if not replaced:
		arr.append(proto)
	var f := FileAccess.open(PRESETS_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(arr, "  "))
		f.close()
