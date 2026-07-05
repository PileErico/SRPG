extends SceneTree
## 只读：报告地形分类分布 + 待定明细（查有无核心地形误留待定）。
const TerrainDB := preload("res://TerrainDB.gd")

func _initialize() -> void:
	TerrainDB.reload_data()
	var pal: Array = TerrainDB.palette()
	var by_cat := {}
	for e in pal:
		var c := TerrainDB.category_of(e)
		if not by_cat.has(c):
			by_cat[c] = []
		by_cat[c].append(e)
	print("TOTAL=%d   categories(order)=%s" % [pal.size(), str(TerrainDB.categories())])
	for c in by_cat:
		print("  [%s] = %d" % [c, (by_cat[c] as Array).size()])
	var pend: Array = by_cat.get(TerrainDB.DEFAULT_CATEGORY, [])
	print("=== 待定 %d 条 ===" % pend.size())
	var non_fh := []
	for e in pend:
		if str(e.get("terrain")) != "fh":
			non_fh.append("%s/%s「%s」" % [str(e.get("terrain")), str(e.get("variant")), str(e.get("label"))])
	print("⚠ 待定里【非 fh＝核心/原生地形】= %d 条：%s" % [non_fh.size(), str(non_fh)])
	print("待定里 fh 导入件 = %d 条" % (pend.size() - non_fh.size()))
	quit()
