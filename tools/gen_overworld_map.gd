extends SceneTree
## 一次性生成默认大地图 res://maps/overworld/world.json（可重跑覆盖；手感不满意直接用地图编辑器改）。
## 运行：..._console.exe --headless --path "D:/1战棋" -s res://tools/gen_overworld_map.gd

const MapIO := preload("res://MapIO.gd")

const W := 24
const H := 16

func _initialize() -> void:
	var tiles := []
	for r in H:
		var line := []
		for c in W:
			line.append({"terrain": "plain", "variant": "grassland"})
		tiles.append(line)
	for r in H:   # 西侧南北山脉（col 3~4）
		for c in [3, 4]:
			tiles[r][c] = {"terrain": "mountain", "variant": "mountain"}
	tiles[8][3] = {"terrain": "hill", "variant": "hill"}   # row 8 山口（接道路）
	tiles[8][4] = {"terrain": "hill", "variant": "hill"}
	for r in range(1, 5):   # 东北湖：浅水圈
		for c in range(17, 22):
			tiles[r][c] = {"terrain": "water", "variant": "shallow"}
	for r in range(2, 4):   # 湖心深水（空 tags 队伍不可入＝天然屏障）
		for c in range(18, 21):
			tiles[r][c] = {"terrain": "water", "variant": "deep"}
	for r in range(9, 13):   # 南森林
		for c in range(7, 11):
			tiles[r][c] = {"terrain": "forest", "variant": "forest"}
	for r in range(3, 6):    # 北森林
		for c in range(10, 14):
			tiles[r][c] = {"terrain": "forest", "variant": "forest"}
	for c in range(3, W):    # 东西大道（row 8，穿山口贯东缘）
		tiles[8][c] = {"terrain": "road", "variant": "road"}
	for r in range(13, H):   # 东南沙地
		for c in range(16, W):
			tiles[r][c] = {"terrain": "sand", "variant": "sand"}
	var triggers := [
		{"id": "ow_merchant", "label": "游商", "when": {"event": "enter_tile", "once": false, "chance": 15, "cooldown_hours": 12},
			"do": [{"action": "dialogue", "dialogue_id": "dlg_merchant"}]},   # M8：大地图事件对话演示
		{"id": "ow_dawn", "label": "每日", "when": {"event": "timer", "every_hours": 24},
			"do": [{"action": "show_message", "text": "又是新的一天。"}]},
		{"id": "ow_ambush", "label": "劫道者", "when": {"event": "enter_tile", "col": 14, "row": 8, "once": false, "cooldown_hours": 24},
			"do": [{"action": "show_message", "text": "劫道者从路旁的灌木里窜了出来！"}, {"action": "start_battle", "map": "res://maps/sandbox.json"}]},
	]
	# 地点实例（M7；类型定义在 data/locations.json，运行时状态在 WorldState.location_cleared_at）。
	# 旧 ow_ruin「后续开放」占位触发器已被真遗迹地点取代。
	var locations := [
		{"id": "city_astra", "type": "city", "label": "阿斯特拉", "col": 8, "row": 8, "dialogue_id": "dlg_elder_astra"},
		{"id": "village_luowei", "type": "village", "label": "洛苇村", "col": 15, "row": 5},
		{"id": "ruin_sand", "type": "ruin", "label": "沙没之殿", "col": 20, "row": 14, "battle_map": "res://maps/sandbox.json"},
		{"id": "lair_bandit", "type": "lair", "label": "劫道者营地", "col": 11, "row": 11, "battle_map": "res://maps/sandbox.json"},
	]
	DirAccess.make_dir_recursive_absolute("res://maps/overworld")
	# environment 留空＝日夜不显式指定 → 消费端走「战役时钟推导」（M2 优先级的正确演示）
	var ok := MapIO.write_map("res://maps/overworld/world.json", W, H, tiles, [], [], triggers, {}, {}, "overworld", locations)
	print("world.json 生成：", "OK" if ok else "FAILED")
	quit(0 if ok else 1)
