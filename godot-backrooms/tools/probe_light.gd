extends SceneTree
## Ceiling light coverage of a level, headless: how many tubes, how many the dark-gap pass lit, and the open
## cells that still have no lit tube in sight within a cell (a Dark zone's aside).
##   godot --headless --path godot-backrooms --script res://tools/probe_light.gd   (env LEVEL: the index)
func _initialize() -> void:
	var game: Node = root.get_node("Game")
	game.level_index = int(OS.get_environment("LEVEL")) if OS.get_environment("LEVEL") != "" else 0
	game.respawned = true
	var main: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	for i in 240: await process_frame
	var lv: Node = main.get_node("Level")
	var lit_cells := {}
	var before := {}                     # the same without what the dark-gap pass lit
	var burnt_near := {}                 # cells a burnt tube stands in
	for f: Dictionary in lv.fx:
		var c := Vector2i(roundi(f.pos.x / lv.CELL), roundi(f.pos.z / lv.CELL))
		if not f.burnt and f.get("casts", true):
			lit_cells[c] = true
			if not f.get("gap", false): before[c] = true
		elif f.burnt and f.get("casts", true): burnt_near[c] = true
	var dark_before := 0
	for x in range(1, lv.size - 1):
		for z in range(1, lv.size - 1):
			var c := Vector2i(x, z)
			if not lv._wants_light(c): continue
			var ok := false
			for dx in range(-2, 3):
				for dz in range(-2, 3):
					if before.has(c + Vector2i(dx, dz)) and not lv.sight_blocked(Vector2(c), Vector2(c + Vector2i(dx, dz))): ok = true
			if not ok: dark_before += 1
	print("before the pass: %d dark cells" % dark_before)
	var dark: Array = []
	var narrow := 0
	for x in range(1, lv.size - 1):
		for z in range(1, lv.size - 1):
			var c := Vector2i(x, z)
			if not lv._wants_light(c): continue
			var ok := false
			for dx in range(-2, 3):
				for dz in range(-2, 3):
					var d := c + Vector2i(dx, dz)
					if lit_cells.has(d) and not lv.sight_blocked(Vector2(c), Vector2(d)): ok = true
			if not ok:
				var by_burnt := false
				for dx in range(-1, 2):
					for dz in range(-1, 2):
						if burnt_near.has(c + Vector2i(dx, dz)): by_burnt = true
				dark.append([c, "burnt tube" if by_burnt else "NONE"])
			var ew: bool = lv.sight_blocked(Vector2(c), Vector2(c) + Vector2(0.9, 0)) and lv.sight_blocked(Vector2(c), Vector2(c) - Vector2(0.9, 0))
			var ns: bool = lv.sight_blocked(Vector2(c), Vector2(c) + Vector2(0, 0.9)) and lv.sight_blocked(Vector2(c), Vector2(c) - Vector2(0, 0.9))
			if ew or ns: narrow += 1
	print("mode %s: %d fixtures, %d lit, %d lit by the gap pass; %d cells between two close walls; %d open cells with no lit tube in sight within 2 cells: %s" % [
		lv.lights_mode(), lv.fx.size(), lit_cells.size(), lv.gaps_lit, narrow, dark.size(), dark.slice(0, 12)])
	# sight lines from spots near a wall off the grid to the tubes round them: how many the grid alone let
	# through (the light shone through the wall) that the walls now stop
	var through := 0
	var total := 0
	for x in range(1, lv.size - 1):
		for z in range(1, lv.size - 1):
			var c := Vector2i(x, z)
			if not lv._wants_light(c) or lv._sight.get(c) == null: continue
			var eye := Vector3(x * lv.CELL, 1.6, z * lv.CELL)
			for d: Vector2i in lit_cells:
				if Vector2(d).distance_to(Vector2(c)) > 5.0: continue
				var at := Vector3(d.x * lv.CELL, 5.0, d.y * lv.CELL)
				if not lv._line_clear(eye, at, true): continue
				total += 1
				if lv.sight_blocked(Vector2(c), Vector2(d)): through += 1
	print("sight lines from beside walls off the grid to tubes within 5 cells: %d the grid let through, %d of them through a wall (now stopped)" % [total, through])
	quit()
