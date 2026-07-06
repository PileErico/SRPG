extends SceneTree
## BattleState 回归：模型层脱离 Sandbox 独立跑（Phase 4 目标）+ 战中 suspend 快照 JSON 往返对拍。
## 覆盖：棋盘/区域派生/预置落子/回合序/效果桥/死门/视野迷雾/ZOC 键 → to_dict→stringify→parse→restore →
## 逐单位快照规范化对比 + effective_stat/dijkstra/cell_fog 对拍 + 复原态上继续跑收尸。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/test_battlestate.gd（退出码 0=PASS）

const BattleState := preload("res://BattleState.gd")
const UnitFactory := preload("res://UnitFactory.gd")
const WorldState := preload("res://WorldState.gd")
const TerrainDB := preload("res://TerrainDB.gd")

var _fail := 0

func ck(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		push_error("[FAIL] " + msg)

# JSON 规范化（int→float 等价折叠）：stringify→parse→stringify，两边同法后可直接比对字符串
func canon(x) -> String:
	return JSON.stringify(JSON.parse_string(JSON.stringify(x)))

func _initialize() -> void:
	print("=== BattleState 模型层/快照往返 测试开始 ===")
	WorldState.current = null   # 纯沙盒域（非铁人；不触碰玩家存档）
	var protos := UnitFactory.all_prototypes()
	ck(not protos.is_empty(), "有内置原型可用")

	# —— 1) 独立建模：棋盘 + 区域 + 单位（全程不建 Sandbox 场景）——
	var s = BattleState.new()
	s._new_grassland(9, 7)
	ck(s.width == 9 and s.height == 7 and s.tiles.size() == 7, "grassland 棋盘建立")
	s._map_regions = [
		{"id": "r1", "label": "哨区", "color": "#AA66CC", "cells": [[2, 2], [3, 2]], "kind": "aggro"},
		{"id": "d1", "label": "部署", "color": "#3A7BD5", "cells": [[0, 0], [1, 0]], "kind": "deploy"},
	]
	s._setup_regions()
	ck(s.aggro_regions.has("r1") and s.aggro_regions["r1"].size() == 2, "aggro 区域派生")
	ck(s._deploy_cells.size() == 2 and s._all_region_cells.size() == 2, "deploy/全区域派生")
	var pa = UnitFactory.make_unit(protos[0], "player", 1, 1)
	var eb = UnitFactory.make_unit(protos[0], "enemy", 5, 3)
	var ec = UnitFactory.make_unit(protos[0], "enemy", 2, 2)
	eb.unit_name = "精锐乙"
	eb.tags.append("elite")   # 死门资格（敌方 elite）
	ec.unit_name = "杂兵丙"
	ec.ai_aggroed = true
	s.roster = [pa]
	s.units = [pa, eb, ec]
	ck(s.unit_at(5, 3) == eb and s._occupied_by_other(2, 2, pa), "unit_at/占格查询")
	ck(s._is_hostile(pa, eb) and not s._is_friendly(eb), "阵营判定")

	# —— 2) 规则运转：效果桥 / 回合序 / 死门 / 视野 ——
	s._add_effect(pa, {"name": "测试减速", "kind": "debuff", "duration": 2,
		"mods": [{"stat": "speed", "op": "flat", "value": -2}, {"stat": "eva", "op": "flat", "value": -1}]})
	var has_mod := false
	for m in pa.modifiers:
		if str(m.get("source", "")) == "buff:测试减速":
			has_mod = true
	ck(has_mod and pa.effects.size() == 1, "buff↔modifier 桥挂载")
	if pa.skills.is_empty():
		pa.skills["_probe"] = {"level": 1, "cd": 2, "uses": 1}   # 无原型技能时注入探针（cd/uses 运行态往返）
	else:
		pa.skills[pa.skills.keys()[0]]["cd"] = 2
	s.phase = "battle"
	s._rebuild_turn_order()
	ck(s.turn_order.size() == 3 and s.active_unit() != null, "出手序列建立")
	s.zoc_triggered[s._zoc_key(eb, pa)] = true
	s._fired_triggers["t_once"] = true
	s._battle_context = {"location_id": "site_x"}
	s.campaign_battle = false
	s._cur_time = "night"
	s._time_sight_mult = 0.5
	s._cur_weather = "rain"
	s._weather_left = 2
	# 死门：精锐乙 HP 归零 → 转门（占格）+ 条走到 -1
	eb.stats["HP"] = 0
	var hd: Dictionary = s._handle_deaths_state()
	ck(hd["entered_door"].has(eb) and hd["dead"].is_empty(), "精锐转入死门（不离场）")
	ck(eb.tags.has("deaths_door") and s.units.size() == 3, "死门 tag + 占格")
	eb.door_gauge = -1
	s._recompute_vision_state()
	ck(not s._vis_visible.is_empty(), "视野重算非空")
	ck(s.cell_fog(Vector2i(1, 1)) == 2, "自格可见")
	ck(s._unit_hidden_by_fog(eb) == (not s._vis_visible.has(Vector2i(5, 3))), "迷雾藏敌口径")

	# —— 3) 快照 → JSON 落盘往返 → 复原 ——
	var d := s.to_dict()
	var js := JSON.stringify(d)
	var back = JSON.parse_string(js)
	ck(typeof(back) == TYPE_DICTIONARY, "快照可 JSON 往返")
	var s2 = BattleState.new()
	ck(not s2.restore({}), "坏版本拒绝复原")
	s2 = BattleState.new()
	ck(s2.restore(back), "复原成功")
	ck(s2.width == 9 and s2.height == 7 and s2.tiles.size() == 7, "棋盘复原")
	ck(s2.units.size() == 3 and s2.roster.size() == 1 and s2.turn_order.size() == 3, "单位/池/序列条数")
	ck(s2.aggro_regions.has("r1") and s2._deploy_cells.size() == 2, "区域派生重算")
	ck(s2._cur_time == "night" and s2._cur_weather == "rain" and s2._weather_left == 2, "环境字段复原")
	ck(is_equal_approx(s2._time_sight_mult, 0.5), "日夜乘子复原")
	ck(s2._fired_triggers.has("t_once") and str(s2._battle_context.get("location_id", "")) == "site_x", "触发账/上下文复原")
	ck(s2.phase == "battle" and not s2.battle_over and s2.round_num == s.round_num and s2.active_index == s.active_index, "回合面复原")
	# 逐单位快照规范化对比（int/float 折叠后逐字节相等）
	for i in s.units.size():
		var a = s.units[i]
		var b = s2.units[i]
		ck(canon(UnitFactory.unit_to_battle_snapshot(a)) == canon(UnitFactory.unit_to_battle_snapshot(b)),
			"单位[%d]%s 快照往返一致" % [i, a.unit_name])
		ck(a.effective_stat("speed") == b.effective_stat("speed") and a.effective_stat("eva") == b.effective_stat("eva"),
			"单位[%d] effective_stat 对拍" % i)
	var pa2 = s2.units[0]
	var eb2 = s2.units[1]
	ck(pa2.last_hit_by == null, "last_hit_by 空复原")
	ck(eb2.tags.has("deaths_door") and eb2.door_gauge == -1 and eb2.faction == "enemy", "死门单位复原（tag/条/阵营视图）")
	ck(s2.zoc_triggered.size() == 1 and s2.zoc_triggered.has(s2._zoc_key(eb2, pa2)), "ZOC 借机键按新对象重铸")
	# 派生重算对拍：迷雾全图逐格 + dijkstra best 图
	var fog_ok := true
	for row in s.height:
		for col in s.width:
			if s.cell_fog(Vector2i(col, row)) != s2.cell_fog(Vector2i(col, row)):
				fog_ok = false
	ck(fog_ok, "cell_fog 全图对拍")
	var b1: Dictionary = s._dijkstra(s.units[0], 6)["best"]
	var b2: Dictionary = s2._dijkstra(s2.units[0], 6)["best"]
	var dij_ok: bool = b1.size() == b2.size()
	for cell in b1:
		if not b2.has(cell) or int(b1[cell]) != int(b2[cell]):
			dij_ok = false
	ck(dij_ok, "dijkstra 可达图对拍")
	ck(s2._vis_seen.size() == s._vis_seen.size(), "seen 历史保真")

	# —— 4) 复原态上继续跑规则：死门 −3 收尸闭环 ——
	eb2.door_gauge = -3
	ck(s2._door_settle_state(eb2) == "down_injured", "非铁人 −3＝重伤离场标记")
	var hd2: Dictionary = s2._handle_deaths_state()
	ck(hd2["dead"].has(eb2) and s2.units.size() == 2 and not (eb2 in s2.turn_order), "复原态收尸闭环")
	ck(s2._battle_kills.size() == s._battle_kills.size() + 1, "击杀账在复原态继续记")

	# —— 5) 编解码小件 ——
	var cells := {Vector2i(3, 4): true, Vector2i(0, 0): true}
	ck(BattleState.cells_from_json(BattleState.cells_to_json(cells)).size() == 2, "cells 编解码往返")
	ck(BattleState.cells_from_json(null).is_empty() and BattleState.cells_from_json([[1]]).is_empty(), "编解码容错")

	# —— 6) 地块效果惰性接入（森林掩蔽→守方闪避效能，仅地面态；命中/因子对拍）——
	var atk = UnitFactory.make_unit(protos[0], "player", 0, 1)
	var tgt = UnitFactory.make_unit(protos[0], "enemy", 4, 4)
	atk.stats["acc"] = 100   # 命中基数拉高、避开 5/95 钳制以露出 ×0.85 差异
	tgt.stats["eva"] = 20
	var hc_plain := s._hit_chance(atk, tgt)   # 目标站草原（无地块效果）
	s.tiles[4][4] = {"terrain": "forest", "variant": "forest"}   # (4,4) 改森林、目标站其上
	tgt.tags = ["ground"]
	var hc_forest := s._hit_chance(atk, tgt)
	tgt.tags = ["flying"]
	var hc_fly := s._hit_chance(atk, tgt)
	ck(hc_forest < hc_plain, "森林掩蔽压低对地面目标命中率（%d<%d）" % [hc_forest, hc_plain])
	ck(hc_fly == hc_plain, "森林掩蔽对飞行态不生效（when.occupant_lacks_tags[flying]）")
	ck(is_equal_approx(s._terrain_eff_factor(tgt, "eva_eff", false), 1.0), "飞行态森林闪避效能因子=1")
	tgt.tags = ["ground"]
	ck(is_equal_approx(s._terrain_eff_factor(tgt, "eva_eff", false), 0.85), "地面态森林闪避效能因子=0.85")
	ck(is_equal_approx(s._terrain_eff_factor(atk, "eva_eff", false), 1.0), "攻方站草原无地块效能（=1）")
	ck(TerrainDB.active_grants(null, []).is_empty(), "无地块 active_grants 空")

	if _fail == 0:
		print("=== 全部断言 PASS ===")
	else:
		print("=== 失败 %d 项 ===" % _fail)
	quit(0 if _fail == 0 else 1)
