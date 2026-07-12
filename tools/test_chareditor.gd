extends SceneTree
## 角色编辑器回归：UnitFactory 原型库读写往返 + unit_to_proto AI 字段 + CharacterEditor 表单构建冒烟。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_chareditor.gd（退出码 0=PASS）
## ⚠️ 本测试会临时写 data/unit_prototypes.json，结尾**逐字节还原原文**——跑完文件零 diff。

const UnitFactory := preload("res://UnitFactory.gd")
const ItemDB := preload("res://ItemDB.gd")
const EquipSlots := preload("res://EquipSlots.gd")
const UnitStatusPanel := preload("res://UnitStatusPanel.gd")
const TagDB := preload("res://TagDB.gd")
const FactionDB := preload("res://FactionDB.gd")

const PROTOS_PATH := "res://data/unit_prototypes.json"
const TMP_ID := "__ce_test_tmp__"
const TMP_ID2 := "__ce_test_tmp2__"

var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

func _read_text() -> String:
	var f := FileAccess.open(PROTOS_PATH, FileAccess.READ)
	if f == null:
		return ""
	var t := f.get_as_text()
	f.close()
	return t

func _write_text(t: String) -> void:
	var f := FileAccess.open(PROTOS_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(t)
		f.close()

func _initialize() -> void:
	print("=== 角色编辑器 测试开始 ===")
	var orig := _read_text()
	ck(orig != "", "原型文件可读")

	# 1) unit_to_proto AI 字段：敌方写、玩家不写
	var enemy_proto := {"id": "e", "name": "敌兵", "default_faction": "enemy",
		"tags": ["human"], "ai_threat": true, "ai_group": "g1"}
	var eu = UnitFactory.make_unit(enemy_proto, "enemy", 0, 0)
	var ep := UnitFactory.unit_to_proto(eu)
	ck(ep.has("ai_threat"), "敌方 proto 含 ai_threat")
	ck(str(ep.get("ai_group", "")) == "g1", "敌方 proto 保留 ai_group")
	ck(not ep.has("ai_region"), "空 ai_region 不写")

	var ally_proto := {"id": "a", "name": "友军", "default_faction": "player", "tags": ["human"]}
	var au = UnitFactory.make_unit(ally_proto, "player", 0, 0)
	var ap := UnitFactory.unit_to_proto(au)
	ck(not ap.has("ai_threat"), "玩家 proto 不写 AI 字段")

	# 2) 原型库 upsert / get / 计数
	var n0: int = UnitFactory.all_prototypes().size()
	var tmp := {"id": TMP_ID, "name": "临时兵", "default_faction": "enemy",
		"tags": ["human"], "race": "human", "stats": {"HP_max": 21}, "level": 3}
	ck(UnitFactory.save_prototype(tmp), "save_prototype 成功")
	ck(UnitFactory.all_prototypes().size() == n0 + 1, "原型数 +1")
	var got := UnitFactory.get_prototype(TMP_ID)
	ck(not got.is_empty(), "get_prototype 找到")
	ck(str(got.get("name", "")) == "临时兵", "get 回名字")
	ck(int(got.get("stats", {}).get("HP_max", 0)) == 21, "get 回面板覆盖 HP_max=21（🔒 属性重做：four→race+stats）")

	# 3) 覆盖同 id（upsert 不新增）
	tmp["name"] = "临时兵改"
	ck(UnitFactory.save_prototype(tmp), "覆盖保存")
	ck(UnitFactory.all_prototypes().size() == n0 + 1, "覆盖不增数")
	ck(str(UnitFactory.get_prototype(TMP_ID).get("name", "")) == "临时兵改", "覆盖后取到新名")

	# 4) 改 id（replace_id 移除旧条目）
	var tmp2 := tmp.duplicate(true)
	tmp2["id"] = TMP_ID2
	ck(UnitFactory.save_prototype(tmp2, TMP_ID), "改 id 保存")
	ck(UnitFactory.get_prototype(TMP_ID).is_empty(), "旧 id 已移除")
	ck(not UnitFactory.get_prototype(TMP_ID2).is_empty(), "新 id 存在")
	ck(UnitFactory.all_prototypes().size() == n0 + 1, "改 id 不增数")

	# 5) 删除 + 边界
	ck(UnitFactory.delete_prototype(TMP_ID2), "删除成功")
	ck(UnitFactory.all_prototypes().size() == n0, "删除后数回原")
	ck(not UnitFactory.delete_prototype("nope_no_such"), "删不存在返回 false")
	ck(not UnitFactory.save_prototype({"name": "无id"}), "无 id 保存拒绝")

	# 5.5) 外观组数据往返（save_prototype 整字典透传 appearances/default_appearance；TMP_ID 此时已空）
	var ap_proto := {"id": TMP_ID, "name": "外观兵", "default_faction": "enemy", "tags": ["human"],
		"portrait": "res://p_base.png", "icon": "res://i_base.png", "default_appearance": "base",
		"appearances": [
			{"id": "base", "name": "常态", "portrait": "res://p_base.png", "icon": "res://i_base.png"},
			{"id": "wolf", "name": "狼形", "portrait": "res://p_wolf.png", "icon": "res://i_wolf.png"}]}
	ck(UnitFactory.save_prototype(ap_proto), "含 appearances 的原型存盘")
	var ap_got := UnitFactory.get_prototype(TMP_ID)
	ck((ap_got.get("appearances", []) as Array).size() == 2, "读回 appearances=2 套")
	ck(str((ap_got["appearances"][1] as Dictionary).get("id", "")) == "wolf", "读回第二套 id=wolf")
	ck(str((ap_got["appearances"][1] as Dictionary).get("portrait", "")) == "res://p_wolf.png", "读回第二套 portrait 保真")
	ck(str(ap_got.get("default_appearance", "")) == "base", "读回 default_appearance=base")
	ck(UnitFactory.delete_prototype(TMP_ID), "清理外观兵")

	# 5.7) level>1 原型「打开即存」零 diff（审查修复回归：diff 基线含成长轨——成长值不烘焙进 stats）
	var lv_proto := {"id": "lv_probe", "name": "高级兵", "default_faction": "enemy",
		"tags": ["human"], "race": "human", "level": 5}
	var lu = UnitFactory.make_unit(lv_proto, "enemy", 0, 0)
	var lp := UnitFactory.unit_to_proto(lu)
	ck((lp.get("stats", {}) as Dictionary).is_empty(),
		"level=5 打开即存 stats 零差异（成长值不烘焙；实得 %s）" % JSON.stringify(lp.get("stats", {})))
	ck(int(lp.get("level", 0)) == 5, "level 保真")
	# 手工差异覆盖仍应保留（只烘焙成长是错、丢差异也是错——两头都钉住）
	var lv_proto2 := {"id": "lv_probe2", "name": "高级兵改", "default_faction": "enemy",
		"tags": ["human"], "race": "human", "level": 5, "stats": {"HP_max": 99}}
	var lu2 = UnitFactory.make_unit(lv_proto2, "enemy", 0, 0)
	var lp2 := UnitFactory.unit_to_proto(lu2)
	ck(int((lp2.get("stats", {}) as Dictionary).get("HP_max", 0)) == 99, "level>1 + 手工覆盖：差异仍保留")

	# 6) 还原原文（保证零 diff），并校验确实还原
	_write_text(orig)
	ck(_read_text() == orig, "原型文件逐字节还原")

	# 7) 场景表单构建冒烟（载入真实原型 → 建全表单 → collect 回读）
	await _test_scene()

	if _fail == 0:
		print("=== 全 PASS ===")
		quit(0)
	else:
		print("=== 失败 %d 项 ===" % _fail)
		quit(1)

func _test_scene() -> void:
	var packed = load("res://CharacterEditor.tscn")
	ck(packed != null, "CharacterEditor.tscn 可加载")
	if packed == null:
		return
	var ed = packed.instantiate()
	root.add_child(ed)
	await process_frame   # 让 _ready 跑完（add_child 后 _ready 延迟）
	# 脚本挂载校验：脚本若解析失败，instantiate 出的是无脚本 Control——下方方法会不存在，须拦成显式 FAIL（防假 PASS）
	ck(ed.has_method("_load_proto"), "CharacterEditor 脚本已挂载且解析通过")
	if not ed.has_method("_load_proto"):
		ed.queue_free()
		return

	# 复用真·角色状态页 + editor_mode
	ck(ed._panel != null and ed._panel.editor_mode, "嵌入 UnitStatusPanel 且 editor_mode 开")

	# 选一个真实原型 → 卡片绑定同一 scratch unit
	var protos := UnitFactory.all_prototypes()
	ck(not protos.is_empty(), "有内置原型")
	var pid := str(protos[0].get("id", ""))
	ed._load_proto(pid)
	ck(ed._unit != null, "载入后有 scratch unit")
	ck(ed._panel._unit == ed._unit, "面板绑定的是同一 scratch unit")
	var back = ed._collect_proto()
	ck(str(back.get("id", "")) == pid, "collect 回 id 一致（%s）" % pid)
	ck(str(back.get("name", "")) == str(protos[0].get("name", "")), "collect 回名字一致")

	# 新建路径
	ed._do_new_unit()
	ck(ed._is_new, "新建进 is_new")
	ck(ed._unit != null, "新建有 unit")
	var nb = ed._collect_proto()
	ck(str(nb.get("default_faction", "")) == "enemy", "新建默认阵营 enemy")

	# 种族下拉 → race_id + 种族底值直落面板（🔒 属性重做 §3；原四维编辑已删）
	ed._select_meta(ed._f_race, "lizardmen")
	ed._on_race_changed()
	ck(ed._unit.race_id == "lizardmen", "选种族 → race_id 写入")
	ck(ed._unit.effective_stat_f("body_fort") == 5.0, "种族底值直落（蜥蜴人肉体强韧5）")

	# 精英 elite tag：勾选 → 同步 → 入 proto
	ed._f_elite.button_pressed = true
	ed._sync_tags()
	ck(ed._unit.tags.has("elite"), "勾精英 → unit 带 elite tag")
	ck(ed._collect_proto().get("tags", []).has("elite"), "elite 写进 proto")

	# 生物类型 biotype：选 monster → 入 proto（与 race 正交、独立轴）
	ed._select_meta(ed._f_biotype, "monster")
	ed._sync_tags()
	ck(ed._unit.tags.has("monster"), "选生物类型 monster → unit 带 monster tag")
	ck(ed._collect_proto().get("tags", []).has("monster"), "monster 写进 proto")

	# tag 表分类：monster/beast=生物类型(非种族)、lizardmen=种族、elite=单位状态
	ck(str(TagDB.get_tag("monster").get("cat", "")) == "biotype", "monster 归 biotype")
	ck(str(TagDB.get_tag("beast").get("cat", "")) == "biotype", "beast 归 biotype")
	ck(str(TagDB.get_tag("lizardmen").get("cat", "")) == "race", "lizardmen 归 race（新增）")
	ck(str(TagDB.get_tag("elite").get("cat", "")) == "unit_status", "elite 归 unit_status（修正 char）")

	# 自由标签选择器「优化」：只列单位能用的（char_*/spectral），排除物品/技能/地块类
	var picker := OptionButton.new()
	ed._fill_free_options(picker)
	var free_ids := []
	for i in picker.item_count:
		var m = picker.get_item_metadata(i)
		if m != null and str(m) != "":
			free_ids.append(str(m))
	ck(free_ids.has("char_veiken"), "自由选择器含 char_*（身份）")
	ck(free_ids.has("spectral"), "自由选择器含 spectral（灵体移动型）")
	ck(not free_ids.has("weapon_sword"), "自由选择器排除武器 tag")
	ck(not free_ids.has("open"), "自由选择器排除地形 tag")
	ck(not free_ids.has("human"), "自由选择器排除种族 tag（有专属下拉）")
	ck(not free_ids.has("elite"), "自由选择器排除 elite（有勾选）")
	picker.free()

	# 派系归属＝ camp_<id> tag（faction 作 tag 用）→ 选帝国 → camp_empire 入 unit.tags + proto.tags
	ed._select_meta(ed._f_home_faction, "camp_empire")
	ed._sync_tags()
	ck(ed._unit.tags.has("camp_empire"), "选派系 → unit 带 camp_empire tag")
	ck(ed._collect_proto().get("tags", []).has("camp_empire"), "camp_empire 写进 proto.tags")
	# 派系名册（factions.json）＝ player/empire/wildlife/lizardmen/bandits；world_units 的 wildlife 引用不再悬空
	for fid in ["player", "empire", "wildlife", "lizardmen", "bandits"]:
		ck(FactionDB.faction(fid) != null, "factions.json 含派系 %s" % fid)
	# camp tag 在 tags.json(cat camp) + lizardmen 双身份：种族「蜥蜴人」/ 派系「蜥蜴人部落」
	ck(str(TagDB.get_tag("camp_lizardmen").get("cat", "")) == "camp", "camp_lizardmen 归 camp 类")
	ck(str(TagDB.get_tag("camp_lizardmen").get("cn", "")) == "蜥蜴人部落", "camp_lizardmen cn=蜥蜴人部落")
	ck(str(TagDB.get_tag("lizardmen").get("cn", "")) == "蜥蜴人", "race lizardmen cn=蜥蜴人（双身份分开）")
	# 自由选择器排除 camp 派系 tag（有派系下拉）
	var picker2 := OptionButton.new()
	ed._fill_free_options(picker2)
	var has_camp := false
	for i in picker2.item_count:
		if str(picker2.get_item_metadata(i)).begins_with("camp_"):
			has_camp = true
	ck(not has_camp, "自由选择器排除 camp 派系 tag")
	picker2.free()

	# 棋子图标 icon：设 → 入 proto（用户用它给棋子叠图；立绘在卡片头像「＋」）
	ed._on_icon_text("res://icons/Unit_Icons/Test.png")
	ck(ed._unit.icon == "res://icons/Unit_Icons/Test.png", "设棋子图标 → unit.icon")
	ck(str(ed._collect_proto().get("icon", "")) == "res://icons/Unit_Icons/Test.png", "icon 写进 proto")

	# AI 默认仍入 proto（关卡编辑器接管 AI；角色编辑器不再编辑，proto 带默认供落子）
	ck(ed._collect_proto().has("ai_threat"), "敌方 proto 仍带默认 ai_threat（关卡编辑器覆盖）")

	# 外观组（编辑器逻辑，不写盘）：单套=旧格式（不写 appearances 键，零噪音）
	ck(ed._appearances.size() == 1, "载入=单套外观(base)")
	ck(not ed._collect_proto().has("appearances"), "单套不写 appearances 键（保持旧格式）")
	# 加第二套 → 选图写回该套 → 设默认 → collect 应含 2 套 + 顶层镜像默认外观
	ed._add_appearance()
	ck(ed._appearances.size() == 2, "添加后=2 套外观")
	var appid: String = str(ed._editing_appear)
	ed._file_target = "portrait"
	ed._on_file_picked("res://icons/Characters/__wolf.png")
	ed._on_icon_text("res://icons/Unit_Icons/__wolf.png")
	ck(str(ed._appear_get(appid)["portrait"]) == "res://icons/Characters/__wolf.png", "选立绘写回当前外观")
	ck(str(ed._appear_get(appid)["icon"]) == "res://icons/Unit_Icons/__wolf.png", "选棋子写回当前外观")
	ed._set_default_appearance()
	var apc: Dictionary = ed._collect_proto()
	ck((apc.get("appearances", []) as Array).size() == 2, "collect 写 2 套 appearances")
	ck(str(apc.get("default_appearance", "")) == appid, "collect 写 default_appearance=当前")
	ck(str(apc.get("portrait", "")) == "res://icons/Characters/__wolf.png", "顶层 portrait 镜像默认外观")
	ck(str(apc.get("icon", "")) == "res://icons/Unit_Icons/__wolf.png", "顶层 icon 镜像默认外观")
	# 切回另一套 → 卡/棋子跟随（编辑对象切换，默认不变）
	var other_id := str(ed._appearances[0]["id"])
	ed._select_appearance(other_id)
	ck(ed._editing_appear == other_id, "切换编辑对象")
	ck(ed._default_appear == appid, "默认外观不随编辑对象切换")

	# 槽位定向装备（数据里若有该单位可装的 off_hand 物品，装进副手）
	var slot_note := "(无可装物品，跳过)"
	for id in ItemDB.all().keys():
		var it = ItemDB.all()[id]
		if EquipSlots.accepts("off_hand", it) and ed._unit.can_equip(it):
			if ed._unit.equip(str(id), "off_hand"):
				ck(int(ed._unit.equipment.get("off_hand", 0)) > 0, "定向装备进 off_hand（%s）" % str(id))
				slot_note = "off_hand=%s" % str(id)
			break
	print("  槽位定向装备：", slot_note)

	ed.queue_free()
	await process_frame

	# 回归：非编辑器（游戏内）UnitStatusPanel 仍正常构建——editor_mode 全套改动默认关，不破坏查看路径
	var view = UnitStatusPanel.new()
	root.add_child(view)
	await process_frame
	ck(not view.editor_mode, "UnitStatusPanel 默认非编辑器模式")
	var vu = UnitFactory.make_unit(protos[0], "player", 0, 0)
	view.open(vu)
	await process_frame
	ck(view.get_child_count() > 0, "游戏内角色状态页(非编辑器)正常构建")
	view.queue_free()
	await process_frame
