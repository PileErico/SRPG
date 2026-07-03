extends RefCounted
## 地形注册表：读 res://terrains.json，做编辑器与战斗的「地形真值」单一来源（代码侧）。
## 用法：const TerrainDB := preload("res://TerrainDB.gd")，再 TerrainDB.palette() / TerrainDB.entry_for(tile)。
## （仿 ItemDB：preload + 静态变量 = 全局单例，不用 class_name 免编辑器扫描；headless 也能用。）
## 数据/代码分离：地形属性是「数据」(terrains.json)；这里只做加载 + 按 terrain/variant 的 O(1) 查表。
## 取代了 MapEditor / Sandbox 各自的 _load_terrains + 逐格线性扫描查表（每帧 ×格数 的开销）。

const TERRAINS_PATH := "res://terrains.json"
const TagDB := preload("res://TagDB.gd")   # 移动型/地形 tag → 中文（通行性文案本地化用）

static var _palette := []      # 有序地形定义（笔刷栏顺序 / 战斗调色都按这个）
static var _by_key := {}       # "terrain/variant" -> entry，O(1) 查表
static var _root := {}         # 原始顶层字典（含 format_version/_note）——save 时保留这些字段
static var _loaded := false

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	_palette = []
	_by_key = {}
	_root = {}
	if FileAccess.file_exists(TERRAINS_PATH):
		var f = FileAccess.open(TERRAINS_PATH, FileAccess.READ)
		var data = JSON.parse_string(f.get_as_text())
		f.close()
		if typeof(data) == TYPE_DICTIONARY and typeof(data.get("terrains")) == TYPE_ARRAY:
			_root = data
			for entry in data["terrains"]:
				if typeof(entry) == TYPE_DICTIONARY and entry.has("terrain") and entry.has("variant"):
					_palette.append(entry)
					_by_key[_key(entry["terrain"], entry["variant"])] = entry
	if _palette.is_empty():
		push_warning("terrains.json 缺失或无效，使用内置兜底地形")
		var g := {"label": "草原", "terrain": "plain", "variant": "grassland",
			"color": "#4A7C3A", "accent": "#7BB35C", "decor": "grass", "tags": ["ground", "open"],
			"move": {"cost": 1, "passable_by": "all"}, "effects": []}
		_palette = [g]
		_by_key = {_key("plain", "grassland"): g}

static func _key(terrain, variant) -> String:
	return "%s/%s" % [terrain, variant]

# 有序地形定义列表（笔刷栏 / 调色按这个顺序）
static func palette() -> Array:
	_ensure()
	return _palette

# 按 tile({terrain,variant}) 查地形定义，找不到返回 null
static func entry_for(tile):
	_ensure()
	if typeof(tile) == TYPE_DICTIONARY:
		return _by_key.get(_key(tile.get("terrain"), tile.get("variant")))
	return null

# 以下为画布常用的取值封装（找不到地形 → 品红/none/未知，便于发现数据异常）
static func color_of(tile) -> Color:
	var e = entry_for(tile)
	return Color.html(e.color) if e != null else Color(1, 0, 1)

static func accent_of(tile) -> Color:
	var e = entry_for(tile)
	return Color.html(e.accent) if e != null else Color(1, 0, 1)

static func decor_of(tile) -> String:
	var e = entry_for(tile)
	return str(e.decor) if e != null else "none"

static func label_of(tile) -> String:
	var e = entry_for(tile)
	return str(e.label) if e != null else "未知"

# —— 悬停/信息用的文案（编辑器与战斗共用单一实现，防两端文案分叉）——

# 通行性文案：读 move 块 passable_by → 可通行 / 不可通行 / 仅<地面/飞行…>（tag 走 TagDB.cn 本地化）
static func passability_text(mv) -> String:
	if typeof(mv) != TYPE_DICTIONARY:
		return "未知"
	var pb = mv.get("passable_by", "all")
	if typeof(pb) == TYPE_ARRAY:
		if pb.is_empty():
			return "不可通行"
		var names := []
		for tg in pb:
			names.append(TagDB.cn(str(tg)))
		return "仅<%s>" % "/".join(names)
	if pb == "none":
		return "不可通行"
	return "可通行"

# 特殊效果文案：列出 entry.effects 的 name：desc；无则「无」
static func effects_text(entry) -> String:
	if entry == null:
		return "无"
	var effs = entry.get("effects", [])
	if typeof(effs) != TYPE_ARRAY or effs.is_empty():
		return "无"
	var parts := []
	for ef in effs:
		var nm := str(ef.get("name", ""))
		var d := str(ef.get("desc", ""))
		parts.append("%s：%s" % [nm, d] if (nm != "" and d != "") else nm + d)
	return "；".join(parts)

# 占据者视角「当前生效」的地块效果 grant 列表：逐条评估 when 条件、只回条件通过者的 grant。
# **惰性读取用**（战斗命中/伤害结算即时调用，不材质化成持久 buff——见 docs/单位系统设计.md「森林掩蔽」🔒）。
# when 目前支持 occupant_lacks_tags（缺这些 tag 才生效，如森林对飞行态不生效）/ occupant_has_tags（须全有）。
# grant 语义／战斗桶映射＝战斗域知识，留在 BattleState._terrain_eff_factor；本函数只做「数据×条件」过滤，保持地形层纯粹。
static func active_grants(entry, occupant_tags: Array) -> Array:
	var out := []
	if entry == null:
		return out
	var effs = entry.get("effects", [])
	if typeof(effs) != TYPE_ARRAY:
		return out
	for ef in effs:
		if typeof(ef) != TYPE_DICTIONARY:
			continue
		if not _when_passes(ef.get("when", {}), occupant_tags):
			continue
		var g = ef.get("grant", null)
		if typeof(g) == TYPE_DICTIONARY:
			out.append(g)
	return out

# 地块效果 when 条件判定（tag 驱动，统一判断）：occupant_lacks_tags 缺其一才过 / occupant_has_tags 须全有。缺省=无条件通过。
static func _when_passes(when, occupant_tags: Array) -> bool:
	if typeof(when) != TYPE_DICTIONARY:
		return true
	for t in when.get("occupant_lacks_tags", []):
		if t in occupant_tags:
			return false
	for t in when.get("occupant_has_tags", []):
		if t not in occupant_tags:
			return false
	return true

# 地形 tags → 中文串（悬停信息用）；无则空串
static func tags_cn(entry) -> String:
	if entry == null or typeof(entry.get("tags")) != TYPE_ARRAY:
		return ""
	var names := []
	for tg in entry["tags"]:
		names.append(TagDB.cn(str(tg)))
	return "、".join(names)

# 地形条目是否适用于某图类型（map_type: "battle"|"overworld"）。
# scope: "battle"=仅战场 / "overworld"=仅大地图 / "both"（缺省，旧数据零迁移）。
# 编辑器笔刷栏过滤的单一判定——只影响 authoring，渲染/通行照常认 tile（旧图越 scope 地形不受影响）。
static func in_scope(entry, map_type: String) -> bool:
	if typeof(entry) != TYPE_DICTIONARY:
		return false
	var s := str(entry.get("scope", "both"))
	return s == "both" or s == map_type

# tile 的有效 move 块：图级覆盖（overrides["terrain/variant"].move 整块替换）?? 全局表兜底。
# 覆盖键格式/合并规则的单一实现——战斗（Sandbox._effective_move）与大地图（Overworld）共用，防两端解释分叉。
static func effective_move(tile, overrides: Dictionary = {}) -> Dictionary:
	if typeof(tile) == TYPE_DICTIONARY and not overrides.is_empty():
		var key := "%s/%s" % [str(tile.get("terrain", "")), str(tile.get("variant", ""))]
		var ov = overrides.get(key)
		if typeof(ov) == TYPE_DICTIONARY and typeof(ov.get("move")) == TYPE_DICTIONARY:
			return ov["move"]
	var e = entry_for(tile)
	return e.get("move", {}) if e != null else {}

# move 块 → 对带 tags 单位的通行成本；-1＝不可通行（战斗寻路与大地图移动共用的单一实现）。
# passable_by："all"＝任意 / "none"＝禁行 / [tag…]＝含其一可进；cost＝基础成本；tag_cost 按单位 tag 取更优（最小）。
static func move_cost(mv, tags: Array) -> int:
	if typeof(mv) != TYPE_DICTIONARY:
		return -1
	var pb = mv.get("passable_by", "all")
	if typeof(pb) == TYPE_ARRAY:
		var ok := false
		for tg in pb:
			if tg in tags:
				ok = true
				break
		if not ok:
			return -1
	elif pb == "none":
		return -1
	var cost := int(mv.get("cost", 1))
	var tag_cost = mv.get("tag_cost", {})
	if typeof(tag_cost) == TYPE_DICTIONARY:
		for tg in tags:
			if tag_cost.has(tg):
				cost = mini(cost, int(tag_cost[tg]))
	return cost

# —— 写回 / 热重载（编辑器「地形数据」编辑用；仿 ItemDB 的 reload/save 范式）——
# palette() 返回的是 _palette 的 live 引用：编辑器原地改 entry.move 即改这里，沙盒同进程立即可见；
# save() 把整张表写回 terrains.json（持久化，影响所有地图）。
static func save() -> bool:
	_ensure()
	var out := _root if typeof(_root) == TYPE_DICTIONARY and not _root.is_empty() else {}
	out["terrains"] = _palette   # 保留 format_version/_note 等顶层字段，只更新 terrains
	var f = FileAccess.open(TERRAINS_PATH, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(out, "  "))
	f.close()
	return true

# 丢弃内存表、下次查询重新从磁盘读（terrains.json 被外部改过时用）
# ⚠️ 不能叫 reload：外部 TerrainDB.reload() 会命中原生 Script.reload()（重编译+静态全重置），见 ItemDB 同注。
static func reload_data() -> void:
	_loaded = false
	_ensure()
