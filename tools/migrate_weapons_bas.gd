extends SceneTree
## BAS 迁移（🔒 模块_技能_设计 §10 阶段3a + 决策25/26）：weapons.json 内联 attack → skills.json BWS 条目 + 武器 "bws" 引用。
##  · 幂等：已有 bws / 无 attack 的武器跳过——可重复跑。
##  · prefer 上提：attack.prefer（比路兹地/空爪偏好）→ 武器顶层 "prefer"（_weapon_prefer 双读）。
##  · 命名（决策25）：通用招式按武器种类共用（斩击/刺击/重击/徒手），专属武器＝独立条目；
##    未列入映射表的武器回退 "bws_<武器id>"。
##  · 自校验：迁移后逐武器断言 SkillDB.flatten_bws(条目) == 原 attack（去 prefer）——语义零漂移（golden 的前置保险）。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/migrate_weapons_bas.gd（退出码 0=成功）
## ⚠ 数据迁移单独 commit（显式路径）＝git 即回滚。

const SkillDB := preload("res://SkillDB.gd")

const WEAPONS_PATH := "res://data/weapons.json"
# 武器 id → BWS 技能 id（通用招式共用一条；专属独立）。名字/参数一律取自原 attack。
const ID_MAP := {
	"long_sword": "bws_slash",                   # 斩击（剑类通用）
	"rusty_dagger": "bws_stab",                  # 刺击（匕首类通用）
	"wooden_club": "bws_bash",                   # 重击（锤/钝器类通用）
	"unarmed_fists": "bws_unarmed",              # 徒手（天生武器）
	"spear_dragon_calamity": "bws_dragon_lance", # 突刺·龙枪（维肯专属）
	"claw_wing": "bws_belooz_rend",              # 撕裂（比路兹翼爪专属）
	"claw_foot": "bws_belooz_grab",              # 抓取（比路兹足爪专属）
	"Desmond_Claw": "bws_desmond_claw",          # 狼爪（戴斯蒙专属）
}
# 从 attack 上提/挪走的键（其余全部留在 hit 透传）：顶层四件套→技能级；tags→技能级；prefer→武器顶层
const HOIST_KEYS := ["name", "icon", "ap_cost", "range", "tags", "prefer"]

func _initialize() -> void:
	quit(_run())

func _run() -> int:
	var f = FileAccess.open(WEAPONS_PATH, FileAccess.READ)
	if f == null:
		push_error("weapons.json 打不开")
		return 1
	var arr = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(arr) != TYPE_ARRAY:
		push_error("weapons.json 非数组")
		return 1

	var migrated := 0
	var fail := 0
	for w in arr:
		if typeof(w) != TYPE_DICTIONARY:
			continue
		var wid := str(w.get("id", ""))
		if str(w.get("bws", w.get("bas", ""))) != "" or typeof(w.get("attack", null)) != TYPE_DICTIONARY:
			continue   # 幂等：已迁 / 本就无攻击（盾/防具）
		var atk: Dictionary = w["attack"]
		var sid := str(ID_MAP.get(wid, "bws_" + wid))
		# hit＝attack 去上提键（coeff/damage_kind/aoe/inflict/armor_pen/sure_hit… 全透传）
		var hit: Dictionary = atk.duplicate(true)
		for k in HOIST_KEYS:
			hit.erase(k)
		var skill := {
			"id": sid,
			"name": str(atk.get("name", wid)),
			"icon": str(atk.get("icon", "")),
			"nature": "skill",
			"desc": "",
			"active": true,
			"tags": (atk.get("tags", []) as Array).duplicate(true),
			"costs": {"ap": int(atk.get("ap_cost", 1))},
			"cooldown": {"base": 0},
			"uses_per_battle": {"base": 0},
			"max_level": 1,
			"target": {"enemy": true, "ally": false, "self": false},
			"range": int(atk.get("range", 1)),
			"requires_hands": [],
			"effects": [{"kind": "attack", "hits": [hit]}],
		}
		if not SkillDB.save_skill(skill):
			push_error("%s：BWS 条目写入失败" % wid)
			fail += 1
			continue
		# 武器侧：attack 摘除、挂 bws 引用、prefer 上提
		if atk.has("prefer"):
			w["prefer"] = str(atk["prefer"])
		w.erase("attack")
		w["bws"] = sid
		migrated += 1
		# 自校验：扁平化 == 原 attack 去 prefer（语义零漂移；数值按值比较——JSON 读回 float vs intify int 不算漂移）
		var expect: Dictionary = atk.duplicate(true)
		expect.erase("prefer")
		var flat: Dictionary = SkillDB.flatten_bws(SkillDB.get_skill(sid))
		if not _deep_eq(flat, expect):
			push_error("%s：flatten_bws ≠ 原 attack（漂移！）\n  flat=%s\n  orig=%s" % [wid, JSON.stringify(flat), JSON.stringify(expect)])
			fail += 1

	if migrated > 0:
		var g = FileAccess.open(WEAPONS_PATH, FileAccess.WRITE)
		if g == null:
			push_error("weapons.json 写入失败")
			return 1
		g.store_string(JSON.stringify(SkillDB._intify(arr), "  "))
		g.close()
	print("MIGRATE: 迁移 %d 件武器（失败 %d）" % [migrated, fail])
	return 0 if fail == 0 else 1

# 深比较（键序无关、数值按值 1==1.0）：dict 键集全等+逐键递归 / array 逐元素 / 数值容差 / 其余 ==
func _deep_eq(a, b) -> bool:
	if typeof(a) in [TYPE_INT, TYPE_FLOAT] and typeof(b) in [TYPE_INT, TYPE_FLOAT]:
		return absf(float(a) - float(b)) < 0.000001
	if typeof(a) == TYPE_DICTIONARY and typeof(b) == TYPE_DICTIONARY:
		if a.size() != b.size():
			return false
		for k in a:
			if not b.has(k) or not _deep_eq(a[k], b[k]):
				return false
		return true
	if typeof(a) == TYPE_ARRAY and typeof(b) == TYPE_ARRAY:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not _deep_eq(a[i], b[i]):
				return false
		return true
	return a == b
