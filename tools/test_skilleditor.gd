extends SceneTree
## SkillEditor / EffectEditor 回归（🔒 设计 §10 阶段2 验收）：
##  · canonical 字节级往返：载入→_collect（无改动）→save_skill → 文件字节不变；collect 结果与 DB 条目全等
##  · lint 规则7 同步校验拦截：三旗全 false / seq 撞格 / per_level 长度≠max_level → collect 拒（{}）
##    （BAS 形约束已随决策27 关系制移到引用处＝lint 规则8/ItemEditor 过滤，编辑器不再有 usable_as_bas）
##  · 坏 JSON 响亮拒存：scripted params 非法 JSON → collect 拒
##  · EffectEditor：bleeding 往返 + 新建效果入库
## 全程 SkillDB/EffectDB._path_override 注入 user:// 临时副本——绝不碰 res://data 真数据。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_skilleditor.gd（退出码 0=PASS）

const SkillDB := preload("res://SkillDB.gd")
const EffectDB := preload("res://EffectDB.gd")
const SkillScene := preload("res://SkillEditor.tscn")
const EffectScene := preload("res://EffectEditor.tscn")

var _fail := 0
func ck(c: bool, m: String) -> void:
	if not c:
		_fail += 1
		push_error("[FAIL] " + m)

func _copy(src: String, dst: String) -> void:
	var f = FileAccess.open(src, FileAccess.READ)
	var g = FileAccess.open(dst, FileAccess.WRITE)
	g.store_string(f.get_as_text())
	f.close()
	g.close()

func _bytes(path: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(path)

# 语义全等（int/float 同值视为等）：走 _intify+stringify 归一
func _same(a, b) -> bool:
	return JSON.stringify(SkillDB._intify(a)) == JSON.stringify(SkillDB._intify(b))

func _initialize() -> void:
	print("=== SkillEditor/EffectEditor 测试开始 ===")
	# —— 数据注入：临时副本 + canonical 归一（先过一遍写盘口，往返比较才有字节基线）——
	_copy("res://data/skills.json", "user://test_skills.json")
	SkillDB._path_override = "user://test_skills.json"
	SkillDB._write_array("user://test_skills.json", SkillDB._read_array("user://test_skills.json"))
	SkillDB.reload_data()
	_copy("res://data/effects.json", "user://test_effects.json")
	EffectDB._path_override = "user://test_effects.json"
	EffectDB._write_array("user://test_effects.json", EffectDB._read_array("user://test_effects.json"))
	EffectDB.reload_data()

	# —— SkillEditor：字节级往返 ——
	var ed = SkillScene.instantiate()
	root.add_child(ed)
	if ed._form == null:
		ed._ready()   # headless SceneTree 下 _ready 可能未跑
	ck(ed.has_method("_shell_collect"), "SkillEditor 脚本挂载且解析通过")
	var before := _bytes("user://test_skills.json")
	ck(before.size() > 0, "临时 skills 副本非空")
	ed._shell_load("first_aid")
	ck(ed._w_id != null and str(ed._w_id.text) == "first_aid", "载入 first_aid 表单")
	ck(ed._blocks.size() == 1 and str(ed._blocks[0]["kind"]) == "heal", "heal 块已建")
	var col = ed._shell_collect()
	ck(not col.is_empty(), "无改动 collect 成功")
	ck(_same(col, SkillDB.get_skill("first_aid")), "collect 结果与 DB 条目全等（含公式对象/键序语义）")
	ck(SkillDB.save_skill(col), "无改动回存成功")
	ck(_bytes("user://test_skills.json") == before, "★ canonical 字节级往返：无改动回存文件逐字节不变")

	# —— lint 规则7 同步校验拦截 ——
	ed._w_t_enemy.button_pressed = false
	ed._w_t_ally.button_pressed = false
	ed._w_t_self.button_pressed = false
	ck(ed._shell_collect().is_empty(), "三旗全 false → collect 拒")
	ed._w_t_ally.button_pressed = true
	ed._w_t_self.button_pressed = true
	ck(not ed._shell_collect().is_empty(), "校验复原后 collect 恢复")

	# seq 撞格：新建技能占 first_aid 的 seq 1
	ed._shell_new_entry()
	ed._w_id.text = "test_two"
	ed._w_seq.value = 1
	ck(ed._shell_collect().is_empty(), "seq 撞格 → collect 拒")
	ed._w_seq.value = 2
	ck(not ed._shell_collect().is_empty(), "换空槽 seq → collect 通过")

	# per_level 长度 ≠ max_level：max_level=1 配两档
	ed._add_block(ed._block_skeleton("heal"))
	var hb = ed._blocks[ed._blocks.size() - 1]
	hb["heal_pct"]["levels"].text = "10, 20"
	ck(ed._shell_collect().is_empty(), "per_level 长度≠max_level → collect 拒")
	ed._w_maxlv.value = 2
	var col2 = ed._shell_collect()
	ck(not col2.is_empty(), "max_level 对齐后 collect 通过")
	ck(_same(col2["effects"][0].get("heal_pct_max_hp"), {"per_level": [10, 20]}), "公式收集＝canonical 最小键（只 per_level）")

	# 坏 JSON 响亮拒存：scripted params 非法
	ed._add_block(ed._block_skeleton("scripted"))
	var sb = ed._blocks[ed._blocks.size() - 1]
	sb["script_id"].text = "wolf_form"
	sb["params"].text = "{bad json"
	ck(ed._shell_collect().is_empty(), "scripted 坏 JSON params → collect 拒")
	sb["params"].text = "{\"radius\": 2}"
	var col3 = ed._shell_collect()
	ck(not col3.is_empty() and _same(col3["effects"][1].get("params"), {"radius": 2}), "params 合法 JSON → 解析入库")

	# 编辑存盘：改名落盘 + 双键剥离
	ed._shell_load("first_aid")
	ed._w_name.text = "救护改"
	var col4 = ed._shell_collect()
	col4["ap_cost"] = 1   # 人为塞旧键——collect 后不该出现；此处验证 save 前的数据侧净化由 collect 承担
	ck(not ed._shell_collect().has("ap_cost"), "collect 剥离顶层 ap_cost（双键禁写）")
	ck(SkillDB.save_skill(ed._shell_collect()), "改名存盘成功")
	ck(str(SkillDB.get_skill("first_aid").get("name")) == "救护改", "存盘后 DB 读回新名")

	# —— EffectEditor：bleeding 往返 + 新建 ——
	var fe = EffectScene.instantiate()
	root.add_child(fe)
	if fe._form == null:
		fe._ready()
	var fx_before := _bytes("user://test_effects.json")
	fe._shell_load("bleeding")
	ck(fe._w_id != null and str(fe._w_id.text) == "bleeding", "载入 bleeding 表单")
	var fcol = fe._shell_collect()
	ck(_same(fcol, EffectDB.get_effect("bleeding")), "效果 collect 与 DB 条目全等")
	ck(EffectDB.save_effect(fcol), "效果无改动回存成功")
	ck(_bytes("user://test_effects.json") == fx_before, "★ 效果 canonical 字节级往返不变")
	fe._shell_new_entry()
	fe._w_id.text = "test_chill"
	fe._w_name.text = "深寒"
	fe._w_dot.value = 3
	var ncol = fe._shell_collect()
	ck(EffectDB.save_effect(ncol), "新建效果入库")
	ck(EffectDB.get_effect("test_chill") != null and int(EffectDB.get_effect("test_chill").get("dot_pct_max_hp", 0)) == 3, "新效果读回字段正确")

	# —— 复原（同进程后续脚本防污染）——
	SkillDB._path_override = ""
	SkillDB.reload_data()
	EffectDB._path_override = ""
	EffectDB.reload_data()

	if _fail == 0:
		print("=== 全 PASS ===")
	else:
		print("=== 失败 %d 项 ===" % _fail)
	quit(_fail)
