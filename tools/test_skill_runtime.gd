extends SceneTree
## 技能运行态回归（审查补测②③）：SkillDB/TraitDB 契约（_path_override 注入缝 + reload_data + 坏数据兜底）
## + Unit 技能生命周期全链：learn→ready→consume→cd 递减→uses 耗尽→reset 充能，
## 以及 🔒 决策18 的 -1 无限哨兵（uses_per_battle 缺省=无限、不扣次数——阶段3 BAS 并入的硬前置）。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_skill_runtime.gd（退出码 0=PASS）

const SkillDB := preload("res://SkillDB.gd")
const TraitDB := preload("res://TraitDB.gd")
const UnitScript := preload("res://Unit.gd")

const P_S := "user://_test_skills.json"
const P_T := "user://_test_traits.json"

var _fail := 0
func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _write(path: String, text: String) -> void:
	var f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()

func _initialize() -> void:
	print("=== 技能运行态测试开始 ===")

	# 1) SkillDB 契约：注入缝 + reload_data + by_seq + 未知 id/坏条目兜底
	SkillDB._path_override = P_S
	_write(P_S, JSON.stringify([
		{"id": "t_strike", "name": "打击", "seq": 1, "max_level": 2,
			"cooldown": {"base": 2}, "uses_per_battle": {"base": 2}},
		{"id": "t_shout", "name": "呐喊", "tags": ["verbal"]},
		{"no_id": true},
	]))
	SkillDB.reload_data()
	ck(SkillDB.get_skill("t_strike") != null, "注入 + get_skill 命中")
	ck(SkillDB.by_seq(1) != null and str(SkillDB.by_seq(1).get("id")) == "t_strike", "by_seq 副索引")
	ck(SkillDB.get_skill("no_such") == null, "未知 id → null")
	ck(SkillDB.all().size() == 2, "无 id 条目被跳过（2/3 收录）")

	# 2) Unit 技能生命周期：learn→ready→consume→cd 递减→uses 耗尽→reset
	var u = UnitScript.new()
	ck(u.learn_skill("t_strike") == 1, "首学 → 等级 1")
	ck(int(u.skills["t_strike"]["uses"]) == 2 and int(u.skills["t_strike"]["cd"]) == 0, "首学初始化 uses=2 cd=0")
	ck(u.skill_ready("t_strike"), "初始就绪")
	u.consume_skill("t_strike", 2)
	ck(int(u.skills["t_strike"]["cd"]) == 2 and int(u.skills["t_strike"]["uses"]) == 1, "施放后 cd=2 uses=1")
	ck(not u.skill_ready("t_strike"), "冷却中不就绪")
	u.refresh_for_turn()
	u.refresh_for_turn()
	ck(int(u.skills["t_strike"]["cd"]) == 0 and u.skill_ready("t_strike"), "两回合 refresh → cd 归零就绪")
	u.consume_skill("t_strike", 0)
	ck(int(u.skills["t_strike"]["uses"]) == 0 and not u.skill_ready("t_strike"), "次数耗尽 → 不就绪")
	u.reset_skill_charges()
	ck(int(u.skills["t_strike"]["uses"]) == 2 and u.skill_ready("t_strike"), "开战 reset → 充能回满")
	ck(u.learn_skill("t_strike") == 2 and u.learn_skill("t_strike") == 2, "升级封顶 max_level=2")

	# 3) 🔒 决策18：uses_per_battle 缺省 → -1 无限（不扣、恒就绪）
	ck(u.skill_uses_max({}) == -1, "缺省 uses_per_battle → -1 无限")
	u.learn_skill("t_shout")
	ck(int(u.skills["t_shout"]["uses"]) == -1, "无限技能首学 uses=-1")
	u.consume_skill("t_shout", 0)
	u.consume_skill("t_shout", 0)
	ck(int(u.skills["t_shout"]["uses"]) == -1 and u.skill_ready("t_shout"), "无限技能连放不扣、恒就绪")
	u.reset_skill_charges()
	ck(int(u.skills["t_shout"]["uses"]) == -1, "reset 后仍 -1")

	# 4) TraitDB 契约：注入缝 + reload_data + 未知 id 兜底
	TraitDB._path_override = P_T
	_write(P_T, JSON.stringify([{"id": "t_tr", "name": "测试特性", "mods": [{"stat": "HP_max", "op": "flat", "value": 5}]}]))
	TraitDB.reload_data()
	ck(TraitDB.get_trait("t_tr") != null and TraitDB.all().size() == 1, "TraitDB 注入 + get_trait 命中")
	ck(TraitDB.get_trait("no_such") == null, "TraitDB 未知 id → null")

	# 还原真数据（防污染同进程后续查询；逐进程 runner 下双保险）
	DirAccess.remove_absolute(P_S)
	DirAccess.remove_absolute(P_T)
	SkillDB._path_override = ""
	SkillDB.reload_data()
	TraitDB._path_override = ""
	TraitDB.reload_data()

	if _fail == 0:
		print("=== 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)
