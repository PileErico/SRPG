extends SceneTree
## 放置物层数据回归：MapIO 往返保留 cell.object；TerrainDB.is_object/set_object。
const MapIO := preload("res://MapIO.gd")
const TerrainDB := preload("res://TerrainDB.gd")
var _fail := 0

func ck(c: bool, m: String) -> void:
	if not c:
		_fail += 1
		push_error("[FAIL] " + m)

func _initialize() -> void:
	# A) MapIO 往返：带 object 的格穿过 to_dict→JSON→normalize 后仍在
	var tiles := [[
		{"terrain": "plain", "variant": "grassland", "object": {"terrain": "mountain", "variant": "mountain"}},
		{"terrain": "plain", "variant": "grassland"},
	]]
	var s := JSON.stringify(MapIO.to_dict(2, 1, tiles, {}))
	var back := MapIO.normalize(JSON.parse_string(s))
	ck(back.get("ok") == true, "normalize ok")
	var c0 = back["tiles"][0][0]
	ck(c0.has("object"), "object 往返保留")
	ck(str(c0["object"].get("terrain")) == "mountain" and str(c0["object"].get("variant")) == "mountain", "object 内容正确")
	var c1 = back["tiles"][0][1]
	ck(not c1.has("object"), "无 object 的格不凭空长出")

	# B) is_object 默认 false + 坏格安全
	ck(TerrainDB.is_object({}) == false, "空 entry is_object=false")
	ck(TerrainDB.is_object({"is_object": true}) == true, "标了 is_object=true")

	# C) 放置物撤销粒度（回归）：多笔放置，撤销只回退最后一笔——
	#    曾因 _copy_tiles 快照丢 object 字段 → 任一撤销把全图放置物集体抹掉。
	var MapEditorScript := load("res://MapEditor.gd")
	var ed = MapEditorScript.new()
	ed._load_terrains()
	ed.new_map(3, 3)
	var obj_idx := -1
	for i in ed.PALETTE.size():
		if TerrainDB.is_object(ed.PALETTE[i]):
			obj_idx = i
			break
	ck(obj_idx >= 0, "存在放置物笔刷")
	ed.brush_index = obj_idx
	ed.begin_stroke(); ed.paint_cell(0, 0); ed.end_stroke()   # 第一笔
	ck(ed.tiles[0][0].has("object"), "第一笔放置物落格")
	ed.begin_stroke(); ed.paint_cell(1, 1); ed.end_stroke()   # 第二笔
	ck(ed.tiles[1][1].has("object"), "第二笔放置物落格")
	ed.undo()                                                 # 只撤第二笔
	ck(ed.tiles[0][0].has("object"), "撤销后第一笔仍在（不被集体抹掉）")
	ck(not ed.tiles[1][1].has("object"), "撤销后第二笔已回退")
	ed.redo()                                                 # 重做找回第二笔
	ck(ed.tiles[1][1].has("object") and ed.tiles[0][0].has("object"), "重做找回第二笔、第一笔不受影响")
	ed.free()

	if _fail == 0:
		print("=== 全 PASS ===")
	else:
		print("=== %d 项 FAIL ===" % _fail)
	quit(0 if _fail == 0 else 1)
