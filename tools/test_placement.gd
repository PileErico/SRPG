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

	if _fail == 0:
		print("=== 全 PASS ===")
	else:
		print("=== %d 项 FAIL ===" % _fail)
	quit(0 if _fail == 0 else 1)
