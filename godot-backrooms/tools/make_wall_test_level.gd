extends SceneTree
## Writes levels/wall_tests.lvl: every wall-graph test scene (tools/wall_cases.gd) laid out on one open floor, to
## open in the level editor and walk round in the game.
##   godot --headless --path godot-backrooms --script res://tools/make_wall_test_level.gd
## Env LIST=1 also puts it at the end of levels/levels.json (so the editor and the game can open it), LIST=0
## takes it out again. The game goes on to the next level in that list at an exit: take it out before publishing.

const Cases := preload("res://tools/wall_cases.gd")
const WallGraph := preload("res://scripts/World/level/walls/wall_graph.gd")
const FILE := "wall_tests.lvl"
const SIZE := 52
const COLS := 2
const STEP := Vector2(22, 9)          # cells between scenes
const ORIGIN := Vector2(5, 5)

func _initialize() -> void:
	var all = WallGraph.new()
	var cases := Cases.cases()
	for i in cases.size():
		var g = cases[i].g
		var off := ORIGIN + Vector2(i % COLS, i / COLS) * STEP
		var ids := {}
		for n in g.nodes: ids[n] = all.add_node(g.pos(n) + off)
		for e in g.edges:
			var ed: Dictionary = g.edges[e]
			all.add_edge(ids[ed.a], ids[ed.b], ed.bulge, ed)
		print("%-26s at %s" % [cases[i].name, off])
	var grid: Array = []
	for z in SIZE:
		var row := ""
		for x in SIZE: row += "#" if x == 0 or z == 0 or x == SIZE - 1 or z == SIZE - 1 else "."
		grid.append(row)
	var lvl := {"format": "backrooms_level", "version": 2, "name": "Test: wall joins", "size": SIZE, "spawn": [2, 2],
		"spawn_rot": 45.0, "exit": null, "entity": null, "tv": null, "grid": grid, "zones": {}, "objects": [],
		"walls": all.to_dict(), "atmosphere": "classic"}
	var f := FileAccess.open("res://levels/" + FILE, FileAccess.WRITE)
	f.store_string(JSON.stringify(lvl, "  ") + "\n")
	f.close()
	print("wrote levels/%s: %d walls on %d nodes" % [FILE, all.edges.size(), all.nodes.size()])
	var list := OS.get_environment("LIST")
	if list != "":
		var index: Array = JSON.parse_string(FileAccess.get_file_as_string("res://levels/levels.json"))
		index = index.filter(func(e): return str(e.get("file", "")) != FILE)
		if list == "1": index.append({"id": "wall_tests", "name": "Test: wall joins", "file": FILE})
		var fi := FileAccess.open("res://levels/levels.json", FileAccess.WRITE)
		fi.store_string(JSON.stringify(index, "  ") + "\n")      # (as the level editor writes it)
		fi.close()
		print("levels.json: wall_tests %s" % ("listed (last)" if list == "1" else "not listed"))
	quit()
