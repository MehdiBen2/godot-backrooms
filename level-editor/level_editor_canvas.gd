extends Control
## Level editor, part 1: the map canvas. Draws the grid, zones, markers and free-placed objects with their
## gizmos, turns mouse input into painting, erasing, placing, moving and rotating, snaps and aligns objects,
## and keeps the undo stack. level_editor_files.gd adds opening and saving levels, level_editor.gd the UI.

const CREAM := Color("e6e1cd")
const DIM := Color(0.9, 0.882, 0.804, 0.55)
const GOLD := Color("e6c65a")
const RED := Color("c4271f")
const SEL := Color("35e0ff")             # selection gizmo: nothing else on the map is cyan, so it reads on any floor

const WALL := "#"
const FLOOR := "."
const PIT := "O"
const THIN := "T"                    # v1 tiles, converted into objects when a level opens (_migrate_legacy)
const ARCH := "A"
const DOOR := "D"
const ZONES := {"tall": Color("5a9bff"), "low": Color("ff8a3d"), "tiles": Color("f2f2f2"), "bright": Color("fff04a"),
	"dark": Color("7a2cff"), "dim": Color("8a6a3a"), "flicker": Color("ff3f9a"), "grime": Color("8a6a30"), "classic": Color("ffe86a")}
const MARKERS := {"spawn": Color("2fd968"), "exit": Color("2fd9ee"), "entity": Color("ff3030"), "tv": Color("5c8dff")}
const BASE_COLORS := {WALL: Color("3f3a30"), FLOOR: Color("cdb86a"), PIT: Color("050505"),
	THIN: Color("7a7364"), ARCH: Color("8a7a52"), DOOR: Color("6b4a2e")}
# Free-placed objects, mirrored from the game's level_data.gd. Positions are in cells with a cell's centre
# on a whole number (the same frame as "spawn"), rotation is degrees clockwise on this map, scale is the
# width in cells. Locally an object faces +x (you walk through it along x) and spans y.
const CELL_M := 4.5                  # metres per cell in the game (level_data.gd CELL)
const SNAP_STEP := 0.5               # snap to cell centres and cell edges
var index: Array = []
var current := -1
var grid_size := 46
var grid: Array = []                 # grid[z] is an Array of one-char strings
var zones := {}                      # zone -> {Vector2i: true}
var markers := {}                    # marker -> Vector2i or null
var tool := "base:" + WALL
var brush := 1
var undo_stack: Array = []
var painting := false
var erasing := false
var panning := false
var space_down := false
var zoom := 14.0
var pan := Vector2(10, 10)
var hover := Vector2i(-1, -1)
var dirty := false
var objects: Array = []              # {type, pos_x, pos_y, rotation, scale}
var selected := -1                   # index into objects
var hover_obj := -1
var drag := ""                       # "" | "move" | "rotate" | "place"
var drag_off := Vector2.ZERO         # grab point -> object origin, in cells
var mouse_px := Vector2(-1, -1)
var place_rot := 0.0                 # new objects start at the last rotation / width used
var place_scale := 1.0
var snap := true
var rot_snap := true
var align := true                    # turn doors / arches / thin walls to fit the wall or corridor they land on
var OBJ_TYPES: Array = []            # the object types, in levels/object_types.json order
var OBJ_INFO := {}                   # type -> its object_types.json entry, plus "col" as a Color
var insp_undo := -1                  # the object the inspector already pushed an undo step for

var font: FontFile = load("res://fonts/vcr.ttf")
var canvas: Control
var title_label: Label
var status: Label
var info: Label
var insp: VBoxContainer
var insp_type: OptionButton
var insp_x: SpinBox
var insp_y: SpinBox
var insp_rot: SpinBox
var insp_scale: SpinBox
func _info(t: String) -> Dictionary:
	return OBJ_INFO.get(t, {"label": t, "key": "", "col": Color("a39c8a"), "help": ""})

## A size from object_types.json, in cells
func _cells(t: String, key: String, metres: float) -> float:
	return float(_info(t).get(key, metres)) / CELL_M

func _update_title() -> void:
	if current < 0: return
	title_label.text = "%s%s" % [str(index[current].get("name", "")), "  *" if dirty else ""]
	title_label.add_theme_color_override("font_color", RED if dirty else CREAM)
	_update_info()

func _update_info() -> void:
	var open_cells := 0
	for row in grid:
		for ch in row:
			if ch == FLOOR or ch == ARCH: open_cells += 1
	var warn := []
	for m in ["spawn", "exit"]:
		if markers.get(m) == null: warn.append("no " + m)
	info.text = "%dx%d   %d open   %d objects   %s" % [grid_size, grid_size, open_cells, objects.size(), ("WARN: " + ", ".join(warn)) if not warn.is_empty() else "OK"]
	info.add_theme_color_override("font_color", RED if not warn.is_empty() else DIM)

func _mark_dirty() -> void:
	dirty = true
	_update_title()
	canvas.queue_redraw()

# ---------------------------------------------------------------- canvas
func _fit() -> void:
	if canvas == null: return
	zoom = clampf(minf(canvas.size.x, canvas.size.y) / maxf(grid_size, 1) * 0.96, 6.0, 40.0)
	pan = (canvas.size - Vector2(grid_size, grid_size) * zoom) / 2.0
	canvas.queue_redraw()

func _cell_at(p: Vector2) -> Vector2i:
	var q := (p - pan) / zoom
	return Vector2i(floori(q.x), floori(q.y))

func _draw_canvas() -> void:
	canvas.draw_rect(Rect2(Vector2.ZERO, canvas.size), Color("080704"))
	for z in grid_size:
		for x in grid_size:
			canvas.draw_rect(Rect2(pan + Vector2(x, z) * zoom, Vector2(zoom, zoom)), BASE_COLORS.get(grid[z][x], Color.BLACK))
	for zn in ZONES:
		var col: Color = ZONES[zn]
		col.a = 0.5
		for c: Vector2i in zones[zn]:
			canvas.draw_rect(Rect2(pan + Vector2(c) * zoom + Vector2.ONE, Vector2(zoom, zoom) - Vector2(2, 2)), col)
	if zoom >= 10.0:
		for i in grid_size + 1:
			canvas.draw_line(pan + Vector2(i, 0) * zoom, pan + Vector2(i, grid_size) * zoom, Color(0, 0, 0, 0.3))
			canvas.draw_line(pan + Vector2(0, i) * zoom, pan + Vector2(grid_size, i) * zoom, Color(0, 0, 0, 0.3))
	for o: Dictionary in objects:
		_draw_object(o, 1.0)
	for m in MARKERS:
		var c = markers[m]
		if c != null:
			var p: Vector2 = pan + (Vector2(c) + Vector2(0.5, 0.5)) * zoom
			canvas.draw_circle(p, zoom * 0.42, MARKERS[m])
			canvas.draw_arc(p, zoom * 0.42, 0, TAU, 20, Color.BLACK, 1.5)
			canvas.draw_string(font, p + Vector2(-zoom * 0.2, zoom * 0.2), m.substr(0, 1).to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, int(zoom * 0.6), Color.BLACK)
	if _object_tool():
		if hover_obj >= 0 and hover_obj != selected and drag == "":
			_draw_outline(objects[hover_obj], Color(SEL, 0.6), 1.5)
		elif hover.x >= 0 and hover_obj < 0 and drag == "" and tool.begins_with("obj:"):
			var p := _snap_pos(_pos_at(mouse_px))           # ghost of what a click would place
			var ghost := {"type": tool.get_slice(":", 1), "pos_x": p.x, "pos_y": p.y, "rotation": _wall_align(p, place_rot), "scale": place_scale}
			_draw_object(ghost, 0.45)
			_draw_arrow(ghost, Color(SEL, 0.5))
	elif hover.x >= 0 and not tool.begins_with("mark:"):
		var half := brush / 2
		for dz in brush:
			for dx in brush:
				var c := hover + Vector2i(dx - half, dz - half)
				canvas.draw_rect(Rect2(pan + Vector2(c) * zoom, Vector2(zoom, zoom)), Color(1, 1, 1, 0.22))
	elif hover.x >= 0:
		canvas.draw_rect(Rect2(pan + Vector2(hover) * zoom, Vector2(zoom, zoom)), Color(1, 1, 1, 0.3))
	if selected >= 0:
		_draw_gizmo(objects[selected])
	canvas.draw_rect(Rect2(pan, Vector2(grid_size, grid_size) * zoom), GOLD, false, 1.5)

func _canvas_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			var before := (mb.position - pan) / zoom
			zoom = clampf(zoom * (1.12 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.12), 4.0, 60.0)
			pan = mb.position - before * zoom
			canvas.queue_redraw()
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			panning = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_LEFT and space_down:
			panning = mb.pressed
		elif (mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT) and _object_tool():
			_object_press(mb)
		elif mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			painting = mb.pressed
			erasing = mb.button_index == MOUSE_BUTTON_RIGHT
			if mb.pressed:
				_push_undo()
				_apply(_cell_at(mb.position))
	elif ev is InputEventMouseMotion:
		var mm := ev as InputEventMouseMotion
		mouse_px = mm.position
		if panning:
			pan += mm.relative
		elif drag != "":
			_object_drag(mm.position)
		elif painting:
			_apply(_cell_at(mm.position))
		var c := _cell_at(mm.position)
		hover = c if c.x >= 0 and c.y >= 0 and c.x < grid_size and c.y < grid_size else Vector2i(-1, -1)
		hover_obj = _obj_at(mm.position) if _object_tool() and drag == "" else -1
		canvas.mouse_default_cursor_shape = Control.CURSOR_CROSS
		if _object_tool() and (_on_handle(mm.position) or drag == "rotate"):
			canvas.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		elif _object_tool() and (hover_obj >= 0 or drag == "move"):
			canvas.mouse_default_cursor_shape = Control.CURSOR_MOVE
		if drag != "" and selected >= 0:
			_status(_describe(objects[selected]))
		elif hover_obj >= 0:
			_status(_describe(objects[hover_obj]) + "   click to select, drag to move, right click deletes")
		elif hover.x >= 0:
			var tags := []
			for z in ZONES:
				if zones[z].has(hover): tags.append(z)
			var p := _pos_at(mm.position)
			_status("cell %d, %d   (%.2f, %.2f)   %s" % [hover.x, hover.y, p.x, p.y, ",".join(tags)])
		canvas.queue_redraw()

func _apply(c: Vector2i) -> void:
	var kind := tool.get_slice(":", 0)
	var what := tool.get_slice(":", 1)
	if kind == "mark":
		if c.x >= 1 and c.y >= 1 and c.x < grid_size - 1 and c.y < grid_size - 1:
			markers[what] = null if erasing else c
		_mark_dirty()
		return
	var half := brush / 2
	for dz in brush:
		for dx in brush:
			var p := c + Vector2i(dx - half, dz - half)
			if p.x < 1 or p.y < 1 or p.x >= grid_size - 1 or p.y >= grid_size - 1: continue
			if kind == "base":
				grid[p.y][p.x] = (FLOOR if what == WALL else WALL) if erasing else what
				if grid[p.y][p.x] == WALL:      # solid cells: the game drops any zone tag on load
					for z in zones: zones[z].erase(p)
			elif kind == "zone" and grid[p.y][p.x] != WALL:
				if erasing: zones[what].erase(p)
				else: zones[what][p] = true
	_mark_dirty()

func _push_undo() -> void:
	var z := {}
	for k in zones: z[k] = zones[k].duplicate()
	undo_stack.append({"grid": grid.duplicate(true), "zones": z, "markers": markers.duplicate(), "size": grid_size,
		"objects": objects.duplicate(true), "selected": selected})
	if undo_stack.size() > 80: undo_stack.pop_front()
	insp_undo = -1

func _undo() -> void:
	if undo_stack.is_empty(): return
	var s: Dictionary = undo_stack.pop_back()
	grid = s.grid
	zones = s.zones
	markers = s.markers
	grid_size = s.size
	objects = s.objects
	selected = s.selected if s.selected < objects.size() else -1
	drag = ""
	_sync_inspector()
	_mark_dirty()

# ---------------------------------------------------------------- objects
func _object_tool() -> bool:
	return tool == "select" or tool.begins_with("obj:")

## Canvas pixels -> object space (cells, a cell's centre on a whole number)
func _pos_at(p: Vector2) -> Vector2:
	return (p - pan) / zoom - Vector2(0.5, 0.5)

func _snap_pos(v: Vector2) -> Vector2:
	if snap and not Input.is_key_pressed(KEY_ALT):
		v = (v / SNAP_STEP).round() * SNAP_STEP
	return v.clamp(Vector2.ZERO, Vector2(grid_size - 1, grid_size - 1))

## 90° steps with rotation snap on, otherwise free; Shift steps 15°, Alt ignores snapping
func _snap_rot(deg: float) -> float:
	var step := 1.0
	if Input.is_key_pressed(KEY_SHIFT): step = 15.0
	elif rot_snap and not Input.is_key_pressed(KEY_ALT): step = 90.0
	return fposmod(snappedf(deg, step), 360.0)

## Object space -> canvas pixels. Local x = the way it faces, local y = its span, both in cells * zoom.
func _obj_xf(o: Dictionary) -> Transform2D:
	return Transform2D(deg_to_rad(o.rotation), pan + (Vector2(o.pos_x, o.pos_y) + Vector2(0.5, 0.5)) * zoom)

## Footprint depth along local x, in cells (at least a few pixels, so thin pieces stay clickable)
func _obj_depth(o: Dictionary) -> float:
	return maxf(_cells(o.type, "thickness", 0.3), 4.0 / zoom)

func _obj_at(p: Vector2) -> int:
	for i in range(objects.size() - 1, -1, -1):
		var o: Dictionary = objects[i]
		var l := (_obj_xf(o).affine_inverse() * p) / zoom
		if absf(l.x) <= maxf(_obj_depth(o) * 0.5, 6.0 / zoom) and absf(l.y) <= o.scale * 0.5 + 2.0 / zoom:
			return i
	return -1

## The rotate handle: a knob just past the facing arrow's tip
func _handle_px(o: Dictionary) -> Vector2:
	var xf := _obj_xf(o)
	return xf.origin + xf.x.normalized() * (_obj_depth(o) * 0.5 * zoom + maxf(zoom * 0.8, 26.0) + 9.0)

func _on_handle(p: Vector2) -> bool:
	return selected >= 0 and p.distance_to(_handle_px(objects[selected])) <= 9.0

## Wall-aware placement. On a cell edge a piece lines up with that edge; square on a cell it spans the
## corridor or wall run it lands in (you walk through it the way the open neighbours lie, like the game's
## old tiles did). Of the two ways to face along that axis it keeps the one nearer `cur`, so a door keeps
## its swing side. Off, with Alt held, on a cell corner or off the half-cell grid, `cur` stays.
func _wall_align(p: Vector2, cur: float) -> float:
	if not align or Input.is_key_pressed(KEY_ALT): return cur
	var whole := func(v: float) -> bool: return absf(v - roundf(v)) < 0.1
	var half := func(v: float) -> bool: return absf(absf(v - floorf(v)) - 0.5) < 0.1
	var facing := -1.0
	if half.call(p.x) and whole.call(p.y): facing = 0.0            # on a north-south edge: face across it
	elif whole.call(p.x) and half.call(p.y): facing = 90.0
	elif whole.call(p.x) and whole.call(p.y):
		var c := Vector2i(roundi(p.x), roundi(p.y))
		var ew := _open_cell(c + Vector2i(1, 0)) and _open_cell(c + Vector2i(-1, 0))
		var ns := _open_cell(c + Vector2i(0, 1)) and _open_cell(c + Vector2i(0, -1))
		if ew and not ns: facing = 0.0
		elif ns and not ew: facing = 90.0
	if facing < 0.0: return cur
	return facing if absf(angle_difference(deg_to_rad(cur), deg_to_rad(facing))) <= PI / 2.0 else facing + 180.0

func _open_cell(c: Vector2i) -> bool:
	return c.x > 0 and c.y > 0 and c.x < grid_size - 1 and c.y < grid_size - 1 and grid[c.y][c.x] != WALL

func _object_press(mb: InputEventMouseButton) -> void:
	if not mb.pressed:
		if drag != "":
			drag = ""
			_sync_inspector()
		return
	var i := _obj_at(mb.position)
	if mb.button_index == MOUSE_BUTTON_RIGHT:
		if i >= 0:
			_push_undo()
			_delete_object(i)
		return
	if _on_handle(mb.position):
		_push_undo()
		drag = "rotate"
	elif i >= 0:
		_select(i)
		_push_undo()
		var o: Dictionary = objects[i]
		drag_off = Vector2(o.pos_x, o.pos_y) - _pos_at(mb.position)
		drag = "move"
	elif tool == "select":
		_select(-1)
	else:
		_push_undo()
		var p := _snap_pos(_pos_at(mb.position))
		objects.append({"type": tool.get_slice(":", 1), "pos_x": p.x, "pos_y": p.y, "rotation": _wall_align(p, place_rot), "scale": place_scale})
		_select(objects.size() - 1)
		drag = "place"                   # keep the button down and drag away to aim it
		_mark_dirty()

func _object_drag(p: Vector2) -> void:
	if selected < 0:
		drag = ""
		return
	var o: Dictionary = objects[selected]
	if drag == "move":
		var q := _snap_pos(_pos_at(p) + drag_off)
		o.pos_x = q.x
		o.pos_y = q.y
		if is_zero_approx(fposmod(o.rotation, 90.0)):      # a piece hand-turned off the grid axes keeps its angle
			o.rotation = _wall_align(q, o.rotation)
	else:
		var v := p - _obj_xf(o).origin
		if drag == "place" and v.length() < maxf(zoom * 0.5, 12.0): return    # a plain click keeps place_rot
		o.rotation = _snap_rot(rad_to_deg(v.angle()))
		place_rot = o.rotation
	_sync_inspector()
	_mark_dirty()

func _select(i: int) -> void:
	selected = i
	insp_undo = -1
	_sync_inspector()
	canvas.queue_redraw()

func _delete_object(i: int) -> void:
	objects.remove_at(i)
	if selected == i: selected = -1
	elif selected > i: selected -= 1
	hover_obj = -1
	_sync_inspector()
	_mark_dirty()

func _delete_selected() -> void:
	if selected < 0: return
	_push_undo()
	_delete_object(selected)

func _duplicate_selected() -> void:
	if selected < 0: return
	_push_undo()
	var o: Dictionary = objects[selected].duplicate()
	var off := SNAP_STEP if snap else 0.25
	o.pos_x = minf(o.pos_x + off, grid_size - 1)
	o.pos_y = minf(o.pos_y + off, grid_size - 1)
	objects.append(o)
	_select(objects.size() - 1)
	_mark_dirty()

## R / Shift+R and the inspector's buttons: turn the selection, or the next placement when nothing is selected
func _rotate_selected(deg: float) -> void:
	if selected < 0:
		place_rot = fposmod(place_rot + deg, 360.0)
		_status("placing at %s°" % _deg(place_rot))
		canvas.queue_redraw()
		return
	_push_undo()
	var o: Dictionary = objects[selected]
	o.rotation = fposmod(o.rotation + deg, 360.0)
	place_rot = o.rotation
	_sync_inspector()
	_mark_dirty()

## An inspector field changed. One undo step per object per round of edits, not one per keystroke.
func _set_prop(key: String, v) -> void:
	if selected < 0: return
	if insp_undo != selected:
		_push_undo()
		insp_undo = selected
	var o: Dictionary = objects[selected]
	o[key] = v
	match key:
		"rotation":
			o.rotation = fposmod(v, 360.0)
			place_rot = o.rotation
			insp_rot.set_value_no_signal(o.rotation)
		"scale":
			place_scale = v
	_mark_dirty()

func _sync_inspector() -> void:
	if insp == null: return
	insp.get_parent().visible = selected >= 0
	if selected < 0: return
	var o: Dictionary = objects[selected]
	insp_type.select(OBJ_TYPES.find(o.type))
	for sb: SpinBox in [insp_x, insp_y]: sb.max_value = grid_size - 1
	insp_x.set_value_no_signal(o.pos_x)
	insp_y.set_value_no_signal(o.pos_y)
	insp_rot.set_value_no_signal(o.rotation)
	insp_scale.set_value_no_signal(o.scale)

func _deg(d: float) -> String:
	return str(snappedf(d, 0.1)).trim_suffix(".0")

func _describe(o: Dictionary) -> String:
	return "%s   x %.2f   y %.2f   rotation %s°   width %.2f" % [_info(o.type).label, o.pos_x, o.pos_y, _deg(o.rotation), o.scale]

## A rectangle in the object's local space (cells), as canvas points
func _local_rect(xf: Transform2D, x0: float, y0: float, x1: float, y1: float) -> PackedVector2Array:
	return PackedVector2Array([xf * (Vector2(x0, y0) * zoom), xf * (Vector2(x1, y0) * zoom), xf * (Vector2(x1, y1) * zoom), xf * (Vector2(x0, y1) * zoom)])

func _fill(pts: PackedVector2Array, col: Color) -> void:
	canvas.draw_colored_polygon(pts, col)
	canvas.draw_polyline(pts + PackedVector2Array([pts[0]]), Color(0, 0, 0, col.a * 0.8), 1.0)

## Plan view of an object, the way an architect's floor plan draws it
func _draw_object(o: Dictionary, alpha: float) -> void:
	var xf := _obj_xf(o)
	var col: Color = _info(o.type).col
	col.a = alpha
	var half: float = o.scale * 0.5
	var t := maxf(_cells(o.type, "thickness", 0.3), 5.0 / zoom)
	match o.type:
		"door":
			# the partition either side of the doorway, the leaf (closed) and its swing either way
			var door_c := _cells("door", "opening", 1.12)
			var dw := door_c * 0.5
			var wall_col := Color(_info("thin_wall").col, alpha)
			_fill(_local_rect(xf, -t * 0.5, -half, t * 0.5, -dw), wall_col)
			_fill(_local_rect(xf, -t * 0.5, dw, t * 0.5, half), wall_col)
			var hinge := xf * (Vector2(0, -dw) * zoom)
			canvas.draw_line(hinge, xf * (Vector2(0, dw) * zoom), col, maxf(2.0, zoom * 0.04))
			var a := deg_to_rad(o.rotation)
			canvas.draw_arc(hinge, door_c * zoom, a, a + PI, 24, Color(col, alpha * 0.8), 1.5)
		"arch":
			# two pillars and the passage between them, dashed where the crown spans it
			var p := _cells("arch", "pillar", 0.75)
			var d := t * 0.5
			_fill(_local_rect(xf, -d, -half, d, -half + p), col)
			_fill(_local_rect(xf, -d, half - p, d, half), col)
			for s: float in [-d, d]:
				canvas.draw_dashed_line(xf * (Vector2(s, -half + p) * zoom), xf * (Vector2(s, half - p) * zoom),
					Color(col, alpha * 0.8), 1.5, maxf(zoom * 0.12, 3.0))
		_:
			# thin walls, and any type the editor has no plan drawing for: a slab its thickness by its width
			_fill(_local_rect(xf, -t * 0.5, -half, t * 0.5, half), col)

func _draw_outline(o: Dictionary, col: Color, width: float) -> void:
	var pad := 3.0 / zoom
	var hx := _obj_depth(o) * 0.5 + pad
	var hy: float = o.scale * 0.5 + pad
	var pts := _local_rect(_obj_xf(o), -hx, -hy, hx, hy)
	canvas.draw_polyline(pts + PackedVector2Array([pts[0]]), col, width)

## The facing arrow, out of the front along local +x (the way you walk through it)
func _draw_arrow(o: Dictionary, col: Color) -> void:
	var xf := _obj_xf(o)
	var dir := xf.x.normalized()
	var tip := xf.origin + dir * (_obj_depth(o) * 0.5 * zoom + maxf(zoom * 0.8, 26.0))
	var side := dir.orthogonal() * 5.0
	var head := PackedVector2Array([tip, tip - dir * 10.0 + side, tip - dir * 10.0 - side])
	canvas.draw_line(xf.origin, tip - dir * 6.0, Color(0, 0, 0, col.a * 0.7), 4.0)     # dark underlay for contrast
	canvas.draw_polyline(head + PackedVector2Array([head[0]]), Color(0, 0, 0, col.a * 0.7), 3.0)
	canvas.draw_line(xf.origin, tip - dir * 6.0, col, 2.0)
	canvas.draw_colored_polygon(head, col)

## Selection gizmo: bounding box, facing arrow, rotate handle with its angle, pivot, and a door's hinge
func _draw_gizmo(o: Dictionary) -> void:
	_draw_outline(o, Color(0, 0, 0, 0.7), 4.0)
	_draw_outline(o, SEL, 2.0)
	_draw_arrow(o, SEL)
	var h := _handle_px(o)
	var hot := drag == "rotate" or _on_handle(mouse_px)
	canvas.draw_circle(h, 6.0, Color.WHITE if hot else SEL)
	canvas.draw_arc(h, 6.0, 0, TAU, 16, Color.BLACK, 1.5)
	var label := "%s°" % _deg(o.rotation)
	var lp := h + Vector2(10, -8)
	canvas.draw_rect(Rect2(lp + Vector2(-3, -13), font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13) + Vector2(6, 4)), Color(0, 0, 0, 0.75))
	canvas.draw_string(font, lp, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, SEL)
	var xf := _obj_xf(o)
	if o.type == "door":
		canvas.draw_circle(xf * (Vector2(0, -_cells("door", "opening", 1.12) * 0.5) * zoom), 3.0, Color.WHITE)
	canvas.draw_circle(xf.origin, 2.5, SEL)

func _status(t: String) -> void:
	if status: status.text = t
