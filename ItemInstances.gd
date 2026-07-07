extends RefCounted
## 物品实例的**静态门面**：每件装备一个独立实例——词条/耐久/状态修正/强化次数的载体。
## `ItemDB` 是**纯模板源**；战斗/UI 一律消费**合成视图 `view(iuid)`**＝模板深拷 ⊕ 词条并入 mods。
## 实例形：{uid:int, tpl_id:String, affixes:[{name, mods:[{stat,op,value}], nature?}], durability:int(-1=未启用),
##          condition:String(""=无状态修正), enhance_count:int}
##
## 存储归属 🔒（2026-07-02 审查后定）：**实例库数据归属 WorldState 实例**（`current.item_instances` 成员字典），
## 本门面按 `WorldState.current` 路由——current==null（沙盒等无战役模式）时路由到独立的 `_transient` 临时库
## （不落盘、与任何档的 uid 域天然隔离）。读档/新建战役＝换 current，库随之切换，无全局副作用。
## uid 走 WorldState.mint_uid（unit/item 共用存档域计数器 🔒；惰性 load 断 preload 环——
## ⚠️ 导出预设须「导出全部资源」，否则字符串 load 不被依赖扫描追踪，见 docs/架构.md）。
##
## 模板热改语义 🔒：view() 实时读当前模板（编辑器改模板→tooltip 立即变），但已装单位的修正是**装备时烘焙**的
## ——运行期不重挂、**读档/重新装备时按新模板生效**；删模板前应确认无实例引用（否则该实例 view 为 null）。
## 用法：const ItemInstances := preload("res://ItemInstances.gd") → create/view/add_affix…

const ItemDB := preload("res://ItemDB.gd")
const StatMeta := preload("res://StatMeta.gd")

static var _transient := {}   # current==null 域的临时实例库（uid->inst；不落盘）
static var _ws_script = null  # WorldState 惰性引用（避免 ItemInstances→WorldState→UnitFactory→Unit→ItemInstances 的 preload 环）

static func _ws():
	if _ws_script == null:
		_ws_script = load("res://WorldState.gd")
		if _ws_script == null:
			push_error("ItemInstances: 载入 WorldState.gd 失败（导出包未含该资源？导出预设须 export all resources）")
	return _ws_script

# 当前生效的实例库：有战役→该档的成员库；无战役→临时库。
static func _store() -> Dictionary:
	var ws = _ws().current
	return ws.item_instances if ws != null else _transient

# 从模板造一个新实例，返回 uid（模板不存在返回 0）。撞号防御：mint 单调，跳号直到空位
# （正常不会撞；兜手编档/计数器被改小的污染场景，宁跳号不静默覆盖）。
static func create(tpl_id: String) -> int:
	if ItemDB.get_item(tpl_id) == null:
		return 0
	var store := _store()
	var iuid: int = _ws().mint_uid()
	while store.has(iuid):
		iuid = _ws().mint_uid()
	store[iuid] = {
		"uid": iuid, "tpl_id": tpl_id,
		"affixes": [], "durability": -1, "condition": "", "enhance_count": 0,
	}
	return iuid

static func get_instance(iuid: int):
	return _store().get(iuid)

static func exists(iuid: int) -> bool:
	return _store().has(iuid)

static func tpl_id(iuid: int) -> String:
	var inst = _store().get(iuid)
	return str(inst.get("tpl_id", "")) if inst != null else ""

# 销毁实例（装备失败回收 / 将来词条转移消耗供体）。
# ⚠️ 调用方须保证无单位在穿它——否则该单位残留烘焙修正 + equipment 悬空引用。
static func destroy(iuid: int) -> void:
	_store().erase(iuid)

# 给实例加一条词条（词条＝修正对象组：{name, mods:[{stat,op,value}], nature?}）。生成 roll/铁匠 UI 后续接。
# 🔒 运行时护栏（模块_属性成长_设计.md §5）：data lint 只扫模板文件，实例词条走这里——
# 未知 stat 键（旧键如 res_fire 永不被消费＝静默无效）或物品禁键（强韧）→ 整条拒收+告警。
static func add_affix(iuid: int, affix: Dictionary) -> void:
	var inst = _store().get(iuid)
	if inst == null or typeof(affix) != TYPE_DICTIONARY:
		return
	if _affix_valid(affix, "add_affix"):
		inst["affixes"].append(affix.duplicate(true))

# 词条 mods 校验（与 lint 规则4 共用 StatMeta 单一源）；ctx 标注调用路径供告警定位。
static func _affix_valid(affix: Dictionary, ctx: String) -> bool:
	var mods = affix.get("mods", [])
	if typeof(mods) != TYPE_ARRAY:
		return false
	for m in mods:
		if typeof(m) != TYPE_DICTIONARY:
			continue
		var key := str(m.get("stat", ""))
		if StatMeta.ITEM_FORBIDDEN_STATS.has(key):
			push_warning("ItemInstances.%s: 词条「%s」含物品禁键 %s（🔒 强韧不入物品），整条拒收" % [ctx, str(affix.get("name", "")), key])
			return false
		if not StatMeta.is_valid_mod_stat(key):
			push_warning("ItemInstances.%s: 词条「%s」含未知 stat 键 %s（不在 StatMeta 白名单，修正管线不会消费它），整条拒收" % [ctx, str(affix.get("name", "")), key])
			return false
	return true

# 从临时库取走一个实例（收编迁移用：WorldState.add_to_roster 把沙盒装备迁进档内库）。无则 null。
static func take_transient(iuid: int):
	if _transient.has(iuid):
		var inst = _transient[iuid]
		_transient.erase(iuid)
		return inst
	return null

# ============ 合成视图（战斗/UI 的唯一消费口） ============
# 模板深拷（ItemDB.get_item 返回共享引用——深拷防污染全局模板）⊕ 实例字段；
# mods = 模板 mods + 各词条 mods（顺序保留；修正 source 粒度由 Unit._apply_item_mods 按条编号）。
static func view(iuid: int):
	var inst = _store().get(iuid)
	if inst == null:
		return null
	var tpl = ItemDB.get_item(str(inst.get("tpl_id", "")))
	if tpl == null:
		return null
	var v: Dictionary = tpl.duplicate(true)
	v["uid"] = iuid
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
				mod["affix"] = str(affix.get("name", ""))   # 标记来自哪条词条（ItemTooltip.mod_line 行尾注〔词条名〕）
				mods.append(mod)
	v["mods"] = mods
	v["affixes"] = (inst.get("affixes", []) as Array).duplicate(true)
	v["durability"] = int(inst.get("durability", -1))
	v["condition"] = str(inst.get("condition", ""))
	v["enhance_count"] = int(inst.get("enhance_count", 0))
	return v

# ============ 序列化助手（WorldState 调用；纯函数、不碰任何库）============

# JSON 数组 → 实例字典（uid->inst；JSON 数字回来是 float，逐字段转 int）。
static func parse_json(arr) -> Dictionary:
	var out := {}
	if typeof(arr) != TYPE_ARRAY:
		return out
	for e in arr:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var iuid := int(e.get("uid", 0))
		if iuid <= 0:
			continue
		out[iuid] = {
			"uid": iuid,
			"tpl_id": str(e.get("tpl_id", "")),
			"affixes": _sanitize_affixes(e.get("affixes", [])),
			"durability": int(e.get("durability", -1)),
			"condition": str(e.get("condition", "")),
			"enhance_count": int(e.get("enhance_count", 0)),
		}
	return out

# 读档词条自愈：手编档/旧档可夹带违规词条（禁键/旧 stat 键），读入时逐条过滤——lint 挡模板、这里挡实例。
static func _sanitize_affixes(arr) -> Array:
	var out := []
	if typeof(arr) != TYPE_ARRAY:
		return out
	for a in arr:
		if typeof(a) == TYPE_DICTIONARY and _affix_valid(a, "parse_json"):
			out.append((a as Dictionary).duplicate(true))
	return out

# 清空**当前生效**的库（测试/退出临时模式用）。
static func clear() -> void:
	_store().clear()
