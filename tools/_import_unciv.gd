extends SceneTree
const TerrainDB := preload("res://TerrainDB.gd")
const SRC := "d:/tmp/Unciv-Tilesets/FantasyHex/Tiles/"
func _initialize() -> void:
	TerrainDB.reload_data()
	var map := [
		["plain", "grassland", "Grassland.png"],
		["plain", "wasteland", "Plains.png"],
		["water", "shallow", "Coast.png"],
		["water", "deep", "Ocean.png"],
		["sand", "sand", "Desert.png"],
		["snow", "snow", "Snow.png"],
		["tundra", "tundra", "Tundra.png"],
		["swamp", "swamp", "Marsh.png"],
		["forest", "forest", "GrasslandForest.png"],
		["mountain", "mountain", "Mountain.png"],
	]
	for m in map:
		var terrain: String = m[0]; var variant: String = m[1]; var fname: String = m[2]
		var img := Image.new()
		if img.load(SRC + fname) != OK:
			print("SKIP load-fail: ", fname); continue
		var key := "%s_%s" % [terrain, variant]
		var dir := "res://icons/Tiles/" + key
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
		var dst := dir + "/0.png"
		img.save_png(dst)
		if TerrainDB.set_art({"terrain": terrain, "variant": variant}, [dst]):
			print("OK %-18s <- %-18s %dx%d" % [key, fname, img.get_width(), img.get_height()])
		else:
			print("NO-SUCH-TERRAIN: ", key)
	TerrainDB.save()
	print("DONE")
	quit()
