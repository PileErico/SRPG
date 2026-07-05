extends SceneTree
## 删除「待定」里所有 fh 导入件（182 个垃圾）；保留待定里的非 fh 原生地形（swamp/farmland/tundra/coast）。
## 同步清理不再被任何存活条目引用的 icons/Tiles/fh/*.png 孤儿图。
const TerrainDB := preload("res://TerrainDB.gd")

func _initialize() -> void:
	TerrainDB.reload_data()
	var pal: Array = TerrainDB.palette()
	var to_del := []      # [{terrain,variant}]
	var del_art := []     # 被删条目的 art 路径
	for e in pal:
		if str(e.get("terrain")) == "fh" and TerrainDB.category_of(e) == TerrainDB.DEFAULT_CATEGORY:
			to_del.append({"terrain": e.get("terrain"), "variant": e.get("variant")})
			for a in (e.get("art", []) as Array):
				del_art.append(str(a))
	for t in to_del:
		TerrainDB.delete_entry(t)
	TerrainDB.save()
	# 存活条目仍引用的 art（保护，别误删）
	var keep_art := {}
	for e in TerrainDB.palette():
		for a in (e.get("art", []) as Array):
			keep_art[str(a)] = true
	var removed_png := 0
	for a in del_art:
		if keep_art.has(a):
			continue
		if not a.begins_with("res://icons/Tiles/fh/"):
			continue
		var abs := ProjectSettings.globalize_path(a)
		if FileAccess.file_exists(abs):
			DirAccess.remove_absolute(abs)
			removed_png += 1
	print("PURGED  entries=%d  orphan_png=%d  palette_now=%d" % [to_del.size(), removed_png, TerrainDB.palette().size()])
	quit()
