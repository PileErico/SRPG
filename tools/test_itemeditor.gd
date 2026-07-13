extends SceneTree
## ItemEditor 回归：物品授权路径（物品大类下拉换 kind + 可使用勾选门控 on_use + 动态使用效果行 + 使用距离 + collect 往返）
## + 提案 §22 tags 搜索（英文 id/中文名双向）+ §33 desc 风味文本往返（空不落键）+ §26 BWS「↗」跳转钮。
## headless 实例化 ItemEditor 场景、驱动 _do_new_item/_on_kind_changed/_add_ou_row/_collect()——纯内存、不写真数据。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_itemeditor.gd（退出码 0=PASS）
const Scene := preload("res://ItemEditor.tscn")
const TagDB := preload("res://TagDB.gd")
var _fail := 0
func ck(c: bool, m: String) -> void:
	if not c:
		_fail += 1
		push_error("[FAIL] " + m)

func _initialize() -> void:
	print("=== ItemEditor 物品授权测试开始 ===")
	var ed = Scene.instantiate()
	root.add_child(ed)
	if ed._form == null:
		ed._ready()   # headless SceneTree 下 _ready 可能未跑，显式初始化

	# 新建 → 默认武器；大类下拉存在
	ed._do_new_item("weapon")
	ck(ed._w_kind != null, "物品大类下拉已建")
	ck(ed._current_kind == "weapon", "默认新建=武器")

	# 大类切到「物品」→ 物品表单，默认可使用、on_use 段可见、无初始效果行
	ed._on_kind_changed("item")
	ck(ed._current_kind == "item", "大类切物品")
	ck(ed._w_usable != null and ed._w_usable.button_pressed, "物品默认可使用")
	ck(ed._ou_box != null and ed._ou_box.visible, "可使用→on_use 段可见")
	ck(ed._ou_rows.size() == 0, "新物品初始无使用效果行")

	# 使用距离默认 1，友方→距离行可见
	ck(ed._w_use_range != null and int(ed._w_use_range.value) == 1, "使用距离默认 1")
	ck(ed._range_row != null and ed._range_row.visible, "作用对象=友方→距离行可见")

	# 加两条使用效果（回血 + 回疲劳，仿武器 mods 加行）
	ed._w_id.text = "potion_x"
	ed._w_name.text = "药水X"
	ed._add_ou_row("heal_pct_max_hp", 40)
	ed._add_ou_row("restore_fatigue_pct", 30)
	ck(ed._ou_rows.size() == 2, "两条使用效果行")
	var d = ed._collect()
	ck(str(d.get("kind")) == "item", "collect kind=item")
	ck(not d.has("slot") and not d.has("mods") and not d.has("use_scope"), "物品无装备槽/mods/use_scope")
	ck((d.get("tags", []) as Array).has("usable"), "collect 含 usable tag")
	ck(int((d.get("on_use", {})).get("heal_pct_max_hp", 0)) == 40, "使用效果=回血40")
	ck(int((d.get("on_use", {})).get("restore_fatigue_pct", 0)) == 30, "使用效果=回疲劳30")
	ck(str(d.get("target", "")) == "ally" and int(d.get("range", -1)) == 1, "作用对象 ally / 距离 1")

	# 作用对象=敌对 → 距离行仍可见（投掷类）；切自身 → 隐藏
	ed._select_meta(ed._w_use_target, "enemy")
	ed._update_range_visible()
	ck(ed._range_row.visible, "作用对象=敌对→距离行可见")
	ck(str(ed._collect().get("target", "")) == "enemy", "collect target=enemy")
	ed._select_meta(ed._w_use_target, "self")
	ed._update_range_visible()
	ck(not ed._range_row.visible, "作用对象=自身→距离行隐藏")

	# 取消可使用 → on_use/target/range 移除、usable tag 不残留、段隐藏
	ed._w_usable.button_pressed = false
	ed._on_usable_toggled()
	var d2 = ed._collect()
	ck(not d2.has("on_use") and not d2.has("target") and not d2.has("range"), "取消可使用→无 on_use/target/range")
	ck(not (d2.get("tags", []) as Array).has("usable"), "取消可使用→usable tag 不残留")
	ck(not ed._ou_box.visible, "取消可使用→on_use 段隐藏")

	# 任务物品勾选 → quest_item tag
	ed._w_quest.button_pressed = true
	ck((ed._collect().get("tags", []) as Array).has("quest_item"), "任务物品→quest_item tag")

	# 大类切回武器：保留 id
	ed._on_kind_changed("weapon")
	ck(ed._current_kind == "weapon" and str(ed._w_id.text) == "potion_x", "切回武器·保留 id")

	# —— §22 清单搜索扩 tags（id/名/tag 英文 id/tag 中文名 四路皆可中）——
	var probe := {"name": "试剑", "tags": ["melee", "weapon_sword"]}
	ck(ed._search_match("blade_x", probe, "blade"), "搜索：id 子串命中")
	ck(ed._search_match("blade_x", probe, "试剑"), "搜索：名字命中")
	ck(ed._search_match("blade_x", probe, "melee"), "搜索：tag 英文 id 命中")
	ck(ed._search_match("blade_x", probe, TagDB.cn("melee").to_lower()), "搜索：tag 中文名（%s）命中" % TagDB.cn("melee"))
	ck(not ed._search_match("blade_x", probe, "ranged"), "搜索：无关词不命中")
	# 清单集成：搜中文 tag「近战」应滤出至少一件真数据近战武器
	ed._search.text = TagDB.cn("melee")
	ed._refresh_list()
	ck(not ed._rows.is_empty(), "清单搜索中文 tag（近战）：有行命中")
	ed._search.text = ""
	ed._refresh_list()

	# —— §33 desc 风味文本：空不落键 / 有值往返 / 载入回填 / 清空抹键 ——
	ed._do_new_item("weapon")
	ck(ed._w_desc != null and ed._w_desc.text == "", "新建武器 desc 空")
	ck(not ed._collect().has("desc"), "desc 空 → collect 不落键（schema 干净）")
	ed._w_desc.text = "「传说中的一击」"
	ck(str(ed._collect().get("desc", "")) == "「传说中的一击」", "desc 填写 → collect 落键")
	ed._current["desc"] = "旧描述"
	ed._build_form()
	ck(ed._w_desc.text == "旧描述", "载入带 desc 条目 → 表单回填")
	ed._w_desc.text = ""
	ck(not ed._collect().has("desc"), "desc 清空 → collect 抹键")

	# —— §26 BWS 引用位「↗」跳转钮存在（跳转本体＝场景切换；静态口消费回归在 test_skilleditor）——
	var has_jump := false
	for c in ed._w_bws.get_parent().get_children():
		if c is Button and str(c.text) == "↗":
			has_jump = true
	ck(has_jump, "BWS 行带「↗」跳转钮")

	if _fail == 0:
		print("=== 全 PASS ===")
	else:
		print("=== 失败 %d 项 ===" % _fail)
	quit(_fail)
