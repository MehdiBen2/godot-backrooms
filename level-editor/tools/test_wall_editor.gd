extends SceneTree
## The level editor's wall tools driven with real input events, headless (nothing is saved):
##   godot --headless --path level-editor --script res://tools/test_wall_editor.gd
## Typed length / angle while drawing, the wall inspector, every handle of a picked wall (slide, bend, height,
## thickness) with typed exact values, a measurement typed into its label, a length lock, box picking, nudging,
## duplicating, copy / paste and undo. Prints ok / FAIL per check; exits 1 when one fails.
var ed
var out := ""
var fails := 0

func _initialize() -> void:
	out = OS.get_environment("SHOT")
	ed = (load("res://level_editor.tscn") as PackedScene).instantiate()
	root.add_child(ed)
	for i in 10: await process_frame
	var free := _find_space()
	_view(free + Vector2(3, 3), 48.0)
	var g = ed.wall_graph
	var CELL: float = ed.CELL_M
	# typed length, then length and angle, while drawing
	ed._select_tool("obj:thin_wall")
	await _click(free)
	await _move(free + Vector2(2, 0))
	await _type("3.5")
	await _key(KEY_ENTER)
	var e1: int = ed.wsel_edges[0]
	_check("typed length", g.length_of(e1) * CELL, 3.5)
	await _type("4,270")                         # 4 m, pointing down the screen (270 anticlockwise from right)
	await _key(KEY_ENTER)
	var e2: int = ed.wsel_edges[0]
	var d: Vector2 = g.pos(g.edges[e2].b) - g.pos(g.edges[e2].a)
	_check("typed length,angle: length", d.length() * CELL, 4.0)
	_check("typed length,angle: angle", ed._map_deg(d), 270.0)
	await _rclick(free)
	# Select: pick the first wall, the inspector shows it
	ed._select_tool("select")
	await _click(_mid(e1))
	_ok("picking a wall shows the wall inspector", ed.wall_insp.visible and ed.wsel_edges == [e1])
	ed._wall_set("thick", 0.6)
	_check("inspector thickness", float(g.edges[e1].tl) + float(g.edges[e1].tr), 0.6)
	await _shot("handles")
	# slide handle: drag it, then type 1 m exactly
	var a0: Vector2 = g.pos(g.edges[e1].a)
	var hs: Dictionary = ed._handles(e1)
	await _press_px(hs.slide, true)
	await _move_px(hs.slide + Vector2(0, -30), true)
	await _type("1")
	await _key(KEY_ENTER)
	await _press_px(hs.slide + Vector2(0, -30), false)
	_check("slid exactly 1 m", (g.pos(g.edges[e1].a) - a0).length() * CELL, 1.0)
	_check("the wall on its end stretched to follow", g.length_of(e2) * CELL, 5.0, 0.02)
	# bend handle: drag, then type a radius
	hs = ed._handles(e1)
	await _press_px(hs.bend, true)
	await _move_px(hs.bend + Vector2(0, -20), true)
	await _type("3")
	await _key(KEY_ENTER)
	await _press_px(hs.bend, false)
	_check("bent to a 3 m radius", float(g.curve_of(e1).get("r", 0.0)) * CELL, 3.0)
	# height handle: drag up, then type 2.4
	hs = ed._handles(e1)
	await _press_px(hs.height, true)
	await _move_px(hs.height + Vector2(0, -40), true)
	_ok("dragging a full-height wall up keeps it at the ceiling", float(g.edges[e1].h) == 0.0)
	await _move_px(hs.height + Vector2(0, 40), true)
	_ok("dragging the height handle down lowers it", float(g.edges[e1].h) > 0.0 and float(g.edges[e1].h) < 5.4)
	await _type("2.4")
	await _key(KEY_ENTER)
	await _press_px(hs.height, false)
	_check("typed height", float(g.edges[e1].h), 2.4)
	ed._wall_set("h", 16.2)
	_check("taller than the ceiling is full height (0)", float(g.edges[e1].h), 0.0)
	ed._wall_set("h", 2.4)
	# thickness handle on one face
	hs = ed._handles(e1)
	var tr0: float = g.edges[e1].tr
	await _press_px(hs.thick_l, true)
	await _move_px(hs.thick_l + (hs.thick_l - _px(ed.WallGeom.point(g.curve_of(e1), 0.25))).normalized() * 12.0, true)
	await _press_px(hs.thick_l, false)
	_ok("one face thicker, the other as it was", float(g.edges[e1].tl) > 0.3 and is_equal_approx(float(g.edges[e1].tr), tr0))
	# a measurement label: click, type, Enter
	ed.canvas.queue_redraw()
	await process_frame
	await process_frame
	var lab: Array = ed._wlabels.filter(func(l): return l[1] == "length")
	_ok("its length label is drawn", not lab.is_empty())
	if not lab.is_empty():
		await _press_px((lab[0][0] as Rect2).get_center(), true)
		await _press_px((lab[0][0] as Rect2).get_center(), false)
		_ok("clicking the label opens a box to type in", ed._wpopup != null)
		if ed._wpopup != null:
			ed._wpopup.text = "6"
			ed._wpopup.text_submitted.emit("6")
			await process_frame
			_check("typed in the label: length", g.length_of(e1) * CELL, 6.0)
	# locks: the second wall's length locked, drag its far end: it stays 5 m long
	ed._wall_set("lock_len", false)
	ed.wsel_edges = [e2]
	ed._winsp_undo = false
	ed._wall_set("lock_len", true)
	var far: int = g.edges[e2].b
	var L0: float = g.length_of(e2)
	await _drag(g.pos(far), g.pos(far) + Vector2(1.2, 0.7))
	_check("a length-locked wall keeps its length", g.length_of(e2), L0)
	# box select both, nudge them, duplicate, copy and paste
	var n_before: int = g.edges.size()
	var lo: Vector2 = free - Vector2(1.5, 1.5)
	var hi: Vector2 = free + Vector2(5, 7)
	await _move(lo)
	await _press(lo, MOUSE_BUTTON_LEFT, true)
	await _move(hi, MOUSE_BUTTON_MASK_LEFT)
	await _press(hi, MOUSE_BUTTON_LEFT, false)
	_ok("box picks both walls (%s)" % [ed.wsel_edges], ed.wsel_edges.size() == 2)
	var p_before: Vector2 = g.pos(g.edges[e1].a)
	await _key(KEY_RIGHT)
	_check("arrow nudges the picked walls", (g.pos(g.edges[e1].a) - p_before).x, ed.SNAP_STEP)
	var picked := 0.0
	for e in ed.wsel_edges: picked += g.length_of(e)
	var total0 := _total()
	ed._duplicate_selected()
	_check("duplicate adds the picked walls' length", _total() - total0, picked, 0.001)
	ed._copy()
	await _move(free + Vector2(0, 9))
	ed._paste()
	_check("copy / paste adds it again", _total() - total0, picked * 2.0, 0.001)
	await _shot("after")
	ed._undo()
	_check("undo takes the paste back", _total() - total0, picked, 0.001)
	print("WALL EDITOR %s (%d failed)" % ["ALL PASSED" if fails == 0 else "FAILED", fails])
	quit(1 if fails > 0 else 0)

func _total() -> float:
	var t := 0.0
	for e in ed.wall_graph.edges: t += ed.wall_graph.length_of(e)
	return t

func _check(what: String, got: float, want: float, tol := 0.01) -> void:
	_ok("%s: %.3f (wanted %.3f)" % [what, got, want], absf(got - want) <= tol)

func _ok(what: String, cond: bool) -> void:
	print(("  ok   " if cond else "  FAIL ") + what)
	if not cond: fails += 1

func _find_space() -> Vector2:
	var g: Array = ed.grid
	var best := INF
	var space := Vector2.ZERO
	for z in range(2, ed.grid_size - 13):
		for x in range(2, ed.grid_size - 13):
			var ok := true
			for dz in 12:
				for dx in 12:
					if g[z + dz][x + dx] == "#": ok = false
			if not ok: continue
			for o in ed.objects:
				if Rect2(x - 1, z - 1, 14, 14).has_point(Vector2(o.pos_x, o.pos_y)): ok = false
			for n in ed.wall_graph.nodes:
				if Rect2(x - 1, z - 1, 14, 14).has_point(ed.wall_graph.pos(n)): ok = false
			if not ok: continue
			var d := Vector2(x, z).distance_to(Vector2(ed.grid_size, ed.grid_size) * 0.5)
			if d < best:
				best = d
				space = Vector2(x + 2, z + 2)
	return space

func _mid(e: int) -> Vector2:
	return ed.WallGeom.point(ed.wall_graph.curve_of(e), 0.5)

func _view(c: Vector2, z: float) -> void:
	ed.zoom = z
	ed.zoom_goal = z
	ed.pan = ed.canvas.size * 0.5 - (c + Vector2(0.5, 0.5)) * z
	ed.canvas.queue_redraw()

func _px(c: Vector2) -> Vector2:
	return ed.pan + (c + Vector2(0.5, 0.5)) * ed.zoom

func _move(c: Vector2, held := 0) -> void:
	await _move_px(_px(c), held != 0)

func _move_px(p: Vector2, held := false) -> void:
	var m := InputEventMouseMotion.new()
	m.position = p
	m.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	ed._canvas_input(m)
	await process_frame

func _press(c: Vector2, button: int, down: bool) -> void:
	var b := InputEventMouseButton.new()
	b.position = _px(c)
	b.button_index = button
	b.pressed = down
	b.button_mask = (MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT) if down else 0
	ed._canvas_input(b)
	await process_frame

func _press_px(p: Vector2, down: bool) -> void:
	var b := InputEventMouseButton.new()
	b.position = p
	b.button_index = MOUSE_BUTTON_LEFT
	b.pressed = down
	b.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	if down: await _move_px(p)
	ed._canvas_input(b)
	await process_frame

func _click(c: Vector2) -> void:
	await _move(c)
	await _press(c, MOUSE_BUTTON_LEFT, true)
	await _press(c, MOUSE_BUTTON_LEFT, false)

func _rclick(c: Vector2) -> void:
	await _press(c, MOUSE_BUTTON_RIGHT, true)
	await _press(c, MOUSE_BUTTON_RIGHT, false)

func _drag(a: Vector2, b: Vector2) -> void:
	await _move(a)
	await _press(a, MOUSE_BUTTON_LEFT, true)
	for i in range(1, 9): await _move(a.lerp(b, i / 8.0), MOUSE_BUTTON_MASK_LEFT)
	await _press(b, MOUSE_BUTTON_LEFT, false)

func _key(k: Key) -> void:
	var e := InputEventKey.new()
	e.keycode = k
	e.pressed = true
	ed._input(e)
	await process_frame

func _type(s: String) -> void:
	for ch in s:
		var k: Key = KEY_COMMA if ch == "," else (KEY_PERIOD if ch == "." else (KEY_0 + int(ch)) as Key)
		await _key(k)

func _shot(name: String) -> void:
	ed.canvas.queue_redraw()
	await process_frame
	await process_frame
	await process_frame
	if out != "": root.get_texture().get_image().save_png("%s_%s.png" % [out, name])
