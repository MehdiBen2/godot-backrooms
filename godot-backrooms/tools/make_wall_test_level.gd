extends SceneTree
## Writes levels/wall_tests.lvl: every wall-graph test scene (tools/wall_cases.gd) laid out on one open floor, to
## open in the level editor and walk round in the game.
##   godot --headless --path godot-backrooms --script res://tools/make_wall_test_level.gd
## Env LIST=1 also puts it at the end of levels/levels.json (so the editor and the game can open it), LIST=0
## takes it out again. The game goes on to the next level in that list at an exit: take it out before publishing.

const Cases := preload("res://tools/wall_cases.gd")
const WallGraph := preload("res://scripts/World/level/walls/wall_graph.gd")
const FILE := "wall_tests.lvl"
const SIZE := 80
const COLS := 2
const STEP := Vector2(22, 9)          # cells between scenes
const ORIGIN := Vector2(5, 5)
const OPENINGS := Vector2(5, 54)      # where the rooms with doors and windows in them start
const Geom := preload("res://scripts/World/level/walls/wall_geom.gd")

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
	_openings(all, OPENINGS)
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

## Rooms with every kind of opening in their walls: doors (wood, office, glass, a pair), a doorway and an arch,
## windows onto the sky (panes, arched, a porthole, a panorama), glass between two rooms, and a round room with
## a door, an arched window and portholes in its curved wall
func _openings(g, o: Vector2) -> void:
	var t := {"tl": 0.15, "tr": 0.15, "h": 0.0}
	var put := func(at: Vector2, room: Vector2, kind: String, settings := {}) -> void:
		var hit: Dictionary = g.edge_near(at, 0.05)
		if hit.is_empty():
			print("  no wall at ", at)
			return
		var e: int = hit.e
		var cv: Dictionary = g.curve_of(e)
		var side := "l" if Geom.normal(cv, float(hit.t)).dot(room - (hit.p as Vector2)) > 0.0 else "r"
		var st: Dictionary = settings.duplicate()
		st["side"] = side
		var u: float = g.fit_opening(e, float(hit.t), float(st.get("w", WallGraph.OPENINGS[kind].w)))
		if is_nan(u):
			print("  no room for a ", kind, " at ", at)
			return
		g.edges[e].ops.append(WallGraph.new_opening(kind, u, st))
	var rect := func(a: Vector2, b: Vector2) -> void:
		for w: Array in [[a, Vector2(b.x, a.y)], [Vector2(b.x, a.y), b], [b, Vector2(a.x, b.y)], [Vector2(a.x, b.y), a]]:
			g.add_wall(o + w[0], o + w[1], 0.0, t, 0.02)
	# room A and room B, side by side, sharing a wall
	rect.call(Vector2(0, 0), Vector2(4, 3))
	rect.call(Vector2(4, 0), Vector2(8, 3))
	var ca := o + Vector2(2, 1.5)
	var cb := o + Vector2(6, 1.5)
	put.call(o + Vector2(2, 3), ca, "door", {"style": "wood"})
	put.call(o + Vector2(1, 0), ca, "window", {"style": "pane", "panes": 3, "w": 2.0, "h": 1.8, "sill": 0.9})
	put.call(o + Vector2(3, 0), ca, "window", {"style": "arched", "panes": 2, "w": 1.4, "h": 2.4, "sill": 0.9, "sky": "golden", "sun_angle": 22.0})
	put.call(o + Vector2(0, 1.5), ca, "window", {"style": "porthole", "w": 1.0, "h": 1.0, "sill": 1.4, "sky": "overcast"})
	put.call(o + Vector2(4, 0.8), ca, "door", {"style": "office"})
	put.call(o + Vector2(4, 2.0), ca, "window", {"glass": "clear", "style": "pane", "panes": 2, "w": 2.4, "h": 1.3, "sill": 1.0})
	put.call(o + Vector2(6, 0), cb, "window", {"style": "panorama", "panes": 5, "w": 6.0, "sky": "noon", "sun_angle": 40.0})
	put.call(o + Vector2(8, 1.5), cb, "door", {"style": "wood", "leaves": 2, "w": 1.9})
	put.call(o + Vector2(5, 3), cb, "door", {"style": "glass"})
	put.call(o + Vector2(7, 3), cb, "doorway", {})
	# a corridor with an arch across it
	g.add_wall(o + Vector2(0, 4.5), o + Vector2(8, 4.5), 0.0, t, 0.02)
	g.add_wall(o + Vector2(0, 6), o + Vector2(8, 6), 0.0, t, 0.02)
	g.add_wall(o + Vector2(4, 4.5), o + Vector2(4, 6), 0.0, t, 0.02)
	put.call(o + Vector2(4, 5.25), o + Vector2(3, 5.25), "arch", {"w": 2.4, "h": 3.4})
	# a round room: a door, an arched window and two portholes in its curved wall
	var c := o + Vector2(12, 3)
	var r := 2.0
	for k in 4:
		var a0 := k * PI * 0.5
		var p0 := c + Vector2.from_angle(a0) * r
		var p1 := c + Vector2.from_angle(a0 + PI * 0.5) * r
		g.add_wall(p0, p1, Geom.sagitta_of(p0, p1, PI * 0.5), t, 0.02)
	put.call(c + Vector2.from_angle(PI * 0.25) * r, c, "door", {"style": "old_wood"})
	put.call(c + Vector2.from_angle(PI * 1.25) * r, c, "window", {"style": "arched", "panes": 2, "w": 1.4, "h": 2.6, "sill": 0.8})
	put.call(c + Vector2.from_angle(PI * 0.75) * r, c, "window", {"style": "porthole", "w": 1.1, "h": 1.1, "sill": 1.3, "sky": "golden"})
	put.call(c + Vector2.from_angle(PI * 1.75) * r, c, "window", {"style": "pane", "panes": 2, "w": 1.8, "h": 1.6, "sill": 1.0})
	print("openings rooms at %s" % o)
