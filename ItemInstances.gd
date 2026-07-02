extends RefCounted
## 物品实例库（single source）：每件装备一个独立实例——词条/耐久/状态修正/强化次数的载体。
## `ItemDB` 降为**纯模板源**；战斗/UI 一律消费**合成视图 `view(uid)`**＝模板 ⊕ 实例（词条并进 mods）。
## 实例形：{uid:int, tpl_id:String, affixes:[{name, mods:[{stat,op,value}], nature?}], durability:int(-1=未启用),
##          condition:String(""=无状态修正), enhance_count:int}
## uid 走 WorldState.mint_uid（unit/item 共用存档域计数器 🔒；惰性 load 断 preload 环）。
## 生命周期：静态库（战斗层不必认识 campaign）；campaign 存读档由 WorldState 序列化/整库替换；
##          沙盒模式的临时实例同库存放、不落盘（新建/读档 load_json 会先 clear）。
## 用法：const ItemInstances := preload("res://ItemInstances.gd") → create/view/add_affix…

const ItemDB := preload("res://ItemDB.gd")

static var _instances := {}   # uid(int) -> instance dict
static var _ws_script = null  # WorldState 惰性引用（避免 ItemInstances→WorldState→UnitFactory→Unit→ItemInstances 的 preload 环）

static func _mint_uid() -> int:
	if _ws_script == null:
		_ws_script = load("res://WorldState.gd")
	return _ws_script.mint_uid()

# 从模板造一个新实例，返回 uid（模板不存在返回 0）。
static func create(tpl_id: String) -> int:
	if ItemDB.get_item(tpl_id) == null:
		return 0
	var uid := _mint_uid()
	_instances[uid] = {
		"uid": uid, "tpl_id": tpl_id,
		"affixes": [], "durability": -1, "condition": "", "enhance_count": 0,
	}
	return uid

static func get_instance(uid: int):
	return _instances.get(uid)

static func exists(uid: int) -> bool:
	return _instances.has(uid)

static func tpl_id(uid: int) -> String:
	var inst = _instances.get(uid)
	return str(inst.get("tpl_id", "")) if inst != null else ""

# 销毁实例（装备失败回收 / 将来词条转移消耗供体）。
static func destroy(uid: int) -> void:
	_instances.erase(uid)

# 给实例加一条词条（词条＝修正对象组：{name, mods:[{stat,op,value}], nature?}）。生成 roll/铁匠 UI 后续接。
static func add_affix(uid: int, affix: Dictionary) -> void:
	var inst = _instances.get(uid)
	if inst != null and typeof(affix) == TYPE_DICTIONARY:
		inst["affixes"].append(affix.duplicate(true))

# ============ 合成视图（战斗/UI 的唯一消费口） ============
# 模板深拷（ItemDB.get_item 返回共享引用——深拷防污染全局模板）⊕ 实例字段；
# mods = 模板 mods + 各词条 mods（顺序保留；修正 source 粒度由 Unit._apply_item_mods 按条编号）。
static func view(uid: int):
	var inst = _instances.get(uid)
	if inst == null:
		return null
	var tpl = ItemDB.get_item(str(inst.get("tpl_id", "")))
	if tpl == null:
		return null
	var v: Dictionary = tpl.duplicate(true)
	v["uid"] = uid
	v["tpl_id"] = inst["tpl_id"]
	var mods: Array = v.get("mods", [])
	if typeof(mods) != TYPE_ARRAY:
		mods = []
	for affix in inst.get("affixes", []):
		if typeof(affix) != TYPE_DICTIONARY:
			continue
		for m in affix.get("mods", []):
			if typeof(m) == TYPE_DICTIONARY:
				var mod: Dictionary = m.duplicate(true)
				mod["affix"] = str(affix.get("name", ""))   # 标记来自哪条词条（tooltip 用）
				mods.append(mod)
	v["mods"] = mods
	v["affixes"] = (inst.get("affixes", []) as Array).duplicate(true)
	v["durability"] = int(inst.get("durability", -1))
	v["condition"] = str(inst.get("condition", ""))
	v["enhance_count"] = int(inst.get("enhance_count", 0))
	return v

# ============ 序列化（WorldState 调用）============

static func to_json() -> Array:
	var out := []
	for uid in _instances:
		out.append((_instances[uid] as Dictionary).duplicate(true))
	return out

# 整库替换（读档/新战役）；JSON 数字回来是 float，逐字段转 int。
static func load_json(arr) -> void:
	_instances.clear()
	if typeof(arr) != TYPE_ARRAY:
		return
	for e in arr:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var uid := int(e.get("uid", 0))
		if uid <= 0:
			continue
		_instances[uid] = {
			"uid": uid,
			"tpl_id": str(e.get("tpl_id", "")),
			"affixes": (e.get("affixes", []) as Array).duplicate(true) if typeof(e.get("affixes", [])) == TYPE_ARRAY else [],
			"durability": int(e.get("durability", -1)),
			"condition": str(e.get("condition", "")),
			"enhance_count": int(e.get("enhance_count", 0)),
		}

static func clear() -> void:
	_instances.clear()
