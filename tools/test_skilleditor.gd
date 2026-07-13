extends SceneTree
## SkillEditor / EffectEditor 回归（🔒 设计 §10 阶段2 验收 + 提案 §6/§24/§25 2026-07-13）：
##  · canonical 字节级往返：载入→_collect（无改动）→save_skill → 文件字节不变；collect 结果与 DB 条目全等
##  · lint 规则7 同步校验拦截：三旗全 false / seq 撞格 / per_level 长度≠max_level → collect 拒（{}）
##    （BAS 形约束已随决策27 关系制移到引用处＝lint 规则8/ItemEditor 过滤，编辑器不再有 usable_as_bas）
##  · 坏 JSON 响亮拒存：scripted params 非法 JSON → collect 拒
##  · §6 conditional_mod 表单：when 六型+未实现类型行锁定 字节级往返 / 新建块 canonical 定点 / 必填缺失拒存
##  · §24 效果块调序：↑/↓ 与收集序同步、顶端 no-op
##  · §25 EffectEditor：未注册 tag 拒存（lint 规则6 口径）/ resist 缺 fort tag 黄条 / 灰化联动 / 二环连锁提示
##  · EffectEditor：bleeding 往返 + 新建效果入库；SkillEditor 被动灰化（成本段只灰不清）
##  · 外壳 §18 反向引用拼装（技能←武器 bws / 效果←技能块·on_expire_apply 连锁）
## 全程 SkillDB/EffectDB._path_override 注入 user:// 临时副本——绝不碰 res://data 真数据；
## 外壳状态档同理走 ListEditorShell._state_path_override 测试缝（编辑器进树、退出必写）。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_skilleditor.gd（退出码 0=PASS）

const SkillDB := preload("res://SkillDB.gd")
const EffectDB := preload("res://EffectDB.gd")
const EditorUI := preload("res://EditorUI.gd")
const SkillScene := preload("res://SkillEditor.tscn")
const EffectScene := preload("res://EffectEditor.tscn")
const SkillEd := preload("res://SkillEditor.gd")     # §26 静态定位口（_open_with_id）回归
const EffectEd := preload("res://EffectEditor.gd")
const ItemDB := preload("res://ItemDB.gd")           # §18 反向引用试料（真 weapons 只读）
const Shell := preload("res://ListEditorShell.gd")   # §9 状态档测试缝
const STATE_TMP := "user://test_editor_state.cfg"

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
	# §9 测试缝：状态档指临时路径（编辑器进树、退出必写）——绝不碰 user://editor_state.cfg 真档；清残留保确定性
	Shell._state_path_override = STATE_TMP
	if FileAccess.file_exists(STATE_TMP):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(STATE_TMP))
	# —— 数据注入：临时副本 + canonical 归一（先过一遍写盘口，往返比较才有字节基线）——
	_copy("res://data/skills.json", "user://test_skills.json")
	SkillDB._path_override = "user://test_skills.json"
	# 注入 conditional_mod 试料（§6 表单往返；只进临时副本不碰真数据）：
	# when 六型各一 + 一条未实现类型（time_of_day＝光环轮，行级锁定原样保留）
	var arr0 := SkillDB._read_array("user://test_skills.json")
	arr0.append({"id": "t_cond", "name": "条件被动试料", "icon": "", "nature": "skill", "desc": "",
		"active": false, "tags": [],
		"costs": {"ap": 1}, "cooldown": {"base": 0}, "uses_per_battle": {"base": 0},
		"max_level": 1, "target": {"enemy": false, "ally": false, "self": true},
		"range": 0, "requires_hands": [],
		"effects": [{"kind": "conditional_mod",
			"when": [
				{"type": "stat_threshold", "stat": "HP", "op": "<=", "value": 50, "pct_of": "HP_max"},
				{"type": "equip_state", "slot": "off_hand", "empty": true},
				{"type": "self_tag", "tag": "flying", "has": false},
				{"type": "target_tag", "any": ["dragon", "beast"]},
				{"type": "skill_tag", "tag": "skill_sword"},
				{"type": "target_effect", "effect": "bleeding"},
				{"type": "time_of_day", "at": "night"}],
			"mods": [{"stat": "acc", "op": "flat", "value": 10}]}]})
	SkillDB._write_array("user://test_skills.json", arr0)
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

	# —— §6 conditional_mod：字节级往返（when 六型 + 未实现类型行锁定）——
	var cond_before := _bytes("user://test_skills.json")
	ed._shell_load("t_cond")
	ck(ed._blocks.size() == 1 and str(ed._blocks[0]["kind"]) == "conditional_mod", "conditional_mod 块已建")
	var ce = ed._blocks[0]
	ck((ce["when_rows"] as Array).size() == 7, "when 七行全建（六型 + 1 行未实现类型）")
	var locked_n := 0
	for wr in ce["when_rows"]:
		if wr.get("locked", false):
			locked_n += 1
	ck(locked_n == 1, "未实现 when 类型（time_of_day）行级锁定原样保留")
	# §25 被动灰化：t_cond active=false → 成本段只灰不清
	ck(not ed._w_ap.editable and ed._w_passive_hint.visible, "被动载入：成本段灰化+提示可见")
	ed._w_active.button_pressed = true   # 程序置位发 toggled → 联动刷新
	ck(ed._w_ap.editable and not ed._w_passive_hint.visible, "切主动：成本段恢复可编")
	ed._w_active.button_pressed = false
	var ccol = ed._shell_collect()
	ck(not ccol.is_empty(), "conditional_mod 无改动 collect 成功")
	ck(_same(ccol, SkillDB.get_skill("t_cond")), "conditional_mod collect 与 DB 条目全等（含锁定行/缺省键形）")
	ck(SkillDB.save_skill(ccol), "conditional_mod 无改动回存成功")
	ck(_bytes("user://test_skills.json") == cond_before, "★ conditional_mod 字节级往返：无改动回存文件逐字节不变")

	# —— §6 conditional_mod：新建块→收集→canonical 定点 ——
	ed._shell_new_entry()
	ed._w_id.text = "t_cond_new"
	ed._add_block(ed._block_skeleton("conditional_mod"))
	var nb = ed._blocks[ed._blocks.size() - 1]
	var wr1 = EditorUI.add_when_row(nb["when_box"], nb["when_rows"], {"type": "stat_threshold"}, ed._when_opts(), Callable())
	ed._select_meta(wr1["params"]["stat"], "HP")
	ed._select_meta(wr1["params"]["op"], "<=")
	wr1["params"]["value"].value = 50
	ed._select_meta(wr1["params"]["pct_of"], "HP_max")
	EditorUI.add_mod_row(nb["mods_box"], nb["mods"], ["atk", "acc"], "acc", "flat", 10.0, Callable())
	var ncol2 = ed._shell_collect()
	ck(not ncol2.is_empty(), "新建 conditional_mod collect 成功")
	ck(_same(ncol2["effects"][0], {"kind": "conditional_mod",
		"when": [{"type": "stat_threshold", "stat": "HP", "op": "<=", "value": 50, "pct_of": "HP_max"}],
		"mods": [{"stat": "acc", "op": "flat", "value": 10}]}),
		"新建块收集＝canonical 形（op/pct_of 落键，缺省键不落）")
	ck(SkillDB.save_skill(ncol2), "新建 conditional_mod 入库")
	var cond_fix := _bytes("user://test_skills.json")
	ed._shell_load("t_cond_new")
	ck(SkillDB.save_skill(ed._shell_collect()), "重载回存成功")
	ck(_bytes("user://test_skills.json") == cond_fix, "★ 新建块 canonical 定点：存→载→存 字节不变")

	# —— §6 when 必填缺失＝响亮拒存 ——
	var wr2 = EditorUI.add_when_row(ed._blocks[0]["when_box"], ed._blocks[0]["when_rows"],
		{"type": "skill_tag"}, ed._when_opts(), Callable())
	ck(ed._shell_collect().is_empty(), "skill_tag 空 tag → collect 拒")
	wr2["params"]["tag"].text = "skill_sword"
	ck(not ed._shell_collect().is_empty(), "补上 tag → collect 通过")

	# —— §24 效果块调序：↑/↓ 与收集序同步 ——
	ed._shell_load("first_aid")
	ed._add_block(ed._block_skeleton("scripted"))
	ed._blocks[1]["script_id"].text = "test_order"
	ed._move_block(ed._blocks[1], -1)
	var ocol = ed._shell_collect()
	ck(str(ocol["effects"][0].get("kind")) == "scripted" and str(ocol["effects"][1].get("kind")) == "heal",
		"上移后收集序＝scripted, heal（按序结算，序有编辑权）")
	ed._move_block(ed._blocks[0], -1)   # 顶端上移＝no-op
	ck(str(ed._shell_collect()["effects"][0].get("kind")) == "scripted", "顶端上移 no-op（不越界）")

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

	# —— §25 收集校验：未注册 tag 响亮拒存（lint 规则6 编辑器先拦）——
	fe._shell_load("bleeding")
	fe._tags.append("no_such_tag")
	ck(fe._shell_collect().is_empty(), "未注册 tag → collect 拒（lint 规则6 口径）")
	fe._tags.erase("no_such_tag")
	ck(not fe._shell_collect().is_empty(), "移除未注册 tag → collect 恢复")

	# —— §25 矛盾组合联动：resist 缺 fort tag 黄条 + 不适用位灰化 ——
	fe._shell_new_entry()
	fe._w_id.text = "t_resist_probe"
	fe._select_meta(fe._w_dmodel, "resist")   # 程序 select 不发信号，手动刷联动
	fe._update_links()
	ck(fe._w_model_warn.visible, "resist 无 fort_* tag → 黄条（豁免按 tag 归轨，缺 tag 静默按 fixed 走）")
	fe._tags.append("fort_will")
	fe._update_links()
	ck(not fe._w_model_warn.visible, "补 fort_will → 黄条消失")
	ck(not fe._w_maxstacks.editable, "stackable 关 → max_stacks 灰化")
	fe._w_stackable.button_pressed = true   # 程序置位发 toggled → 联动刷新
	ck(fe._w_maxstacks.editable, "stackable 开 → max_stacks 恢复")
	fe._w_perm.button_pressed = true
	ck(not fe._w_duration.editable and fe._w_timing.disabled, "permanent → 时长/到期时点灰化")

	# —— §25 on_expire_apply 二环连锁提示（A→B→A 成环）——
	fe._shell_new_entry()
	fe._w_id.text = "t_chain_a"
	fe._w_name.text = "链A"
	ck(EffectDB.save_effect(fe._shell_collect()), "链A 入库")
	fe._shell_new_entry()
	fe._w_id.text = "t_chain_b"
	fe._w_name.text = "链B"
	fe._select_meta(fe._w_expire_apply, "t_chain_a")
	ck(EffectDB.save_effect(fe._shell_collect()), "链B（→A）入库")
	fe._shell_load("t_chain_a")
	fe._select_meta(fe._w_expire_apply, "t_chain_b")
	fe._update_links()
	ck(fe._w_chain_hint.visible and fe._w_chain_hint.text.contains("成环"), "二环连锁 A→B→A → 成环黄条提示")

	# —— 外壳 §18 反向引用拼装（技能侧：武器 bws；效果侧：技能块 + on_expire_apply 连锁）——
	var bws_skill := ""
	var bws_weapon := ""
	for iid in ItemDB.all():
		var it = ItemDB.all()[iid]
		if typeof(it) == TYPE_DICTIONARY and str(it.get("bws", it.get("bas", ""))) != "":
			bws_skill = str(it.get("bws", it.get("bas", "")))
			bws_weapon = str(it.get("name", iid))
			break
	if bws_skill != "":
		var srefs = ed._shell_referenced_by(bws_skill)
		ck(not srefs.is_empty(), "技能 referenced_by：BWS 引用被察觉（%s）" % bws_skill)
		var has_w := false
		for r in srefs:
			if str(r).contains(bws_weapon) and str(r).contains("BWS"):
				has_w = true
		ck(has_w, "引用行含武器名+BWS 位（%s）" % bws_weapon)
		ck(ed._delete_confirm_full_text(bws_skill).contains("⚠ 被"), "技能删除确认文案拼进引用警示段")
	else:
		print("（跳过：weapons 无 bws 引用试料）")
	ck((ed._shell_referenced_by("__no_such_skill__") as Array).is_empty(), "无引用技能 → referenced_by 空")
	var erefs = fe._shell_referenced_by("bleeding")
	var has_sk := false
	for r in erefs:
		if str(r).contains("技能"):
			has_sk = true
	ck(has_sk, "效果 referenced_by：技能效果块引用被察觉（bleeding）")
	var arefs = fe._shell_referenced_by("t_chain_a")
	var has_chain := false
	for r in arefs:
		if str(r).contains("t_chain_b") and str(r).contains("on_expire_apply"):
			has_chain = true
	ck(has_chain, "on_expire_apply 连锁引用被察觉（t_chain_b→t_chain_a）")
	ck((fe._shell_referenced_by("__no_such_effect__") as Array).is_empty(), "无引用效果 → referenced_by 空")

	# —— §26 跨编辑器定位静态口：_open_with_id 写→_ready 消费载入→即清 ——
	SkillEd._open_with_id = "first_aid"
	var ed2 = SkillScene.instantiate()
	root.add_child(ed2)
	if ed2._form == null:
		ed2._ready()
	ck(ed2._w_id != null and str(ed2._w_id.text) == "first_aid", "SkillEditor 静态定位口：_ready 消费 _open_with_id 载入条目")
	ck(SkillEd._open_with_id == "", "SkillEditor 静态口消费即清")
	SkillEd._open_with_id = "no_such_skill_zzz"
	var ed3 = SkillScene.instantiate()
	root.add_child(ed3)
	if ed3._form == null:
		ed3._ready()
	ck(ed3._w_id == null, "SkillEditor 悬空定位 id：不载入（空态+报错消息）")
	ck(SkillEd._open_with_id == "", "SkillEditor 悬空定位仍消费即清")
	EffectEd._open_with_id = "bleeding"
	var fe2 = EffectScene.instantiate()
	root.add_child(fe2)
	if fe2._form == null:
		fe2._ready()
	ck(fe2._w_id != null and str(fe2._w_id.text) == "bleeding", "EffectEditor 静态定位口：载入条目")
	ck(EffectEd._open_with_id == "", "EffectEditor 静态口消费即清")

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
