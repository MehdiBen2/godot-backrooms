extends "res://level_editor_canvas.gd"
## Level editor, part 1b: the walls, as a graph (the game's scripts/World/level/walls/: wall_graph.gd holds them,
## wall_joints.gd works out where they meet, wall_snap.gd snaps). Walls meet at shared nodes, so a corner can't
## come apart: move a node and every wall on it follows, straight or curved.
##
## DRAWING (Thin wall, Half wall, Corner wall, Curved wall): click where a wall starts, click where it ends, and
## it carries on from there (double click, right click, Enter or Esc stops). A turns the next one into an arc
## (Curved wall always draws arcs): click its end, then move the mouse to bend it and click. Type a number while
## drawing for an exact length in metres (3.5), or a length and an angle (3.5,90); while bending, a radius.
## Every point snaps (Alt: not at all): onto a node, onto where two walls cross, onto a wall (it is split there),
## straight on out of the wall it starts from (along an arc's tangent), square to / in line with a wall nearby, in
## line past a wall's end, to whole angle steps, to the grid. A mark at the mouse says which.
## EDITING (Select, V): click a wall or a node to pick it (Shift: pick more, or drag a box). A picked wall has
## handles: its nodes (drag: move the node, the walls on it follow; dropped on a node or a wall it joins it), the
## square in its middle (slide it sideways, the walls on its ends stretch), the diamond (bend it: a straight
## wall becomes an arc and back), the two arrows on its faces (each face's thickness) and the bar (its height).
## While dragging any of them, type a number and Enter for an exact value. Its measurements are written beside
## it: click one (length, angle, radius, height, thickness) to type it. Dragging the wall moves it whole; arrows
## nudge the picked walls. The inspector sets thickness, height, materials and locks on all of them at once. A
## wall with its length / angle locked keeps it while you move what is round it. Del or right click deletes;
## what it leaves is tidied (a node nothing ends on goes, two walls left in line become one). F3 shows the graph.

var wall_snap_px := 14.0             # how near (screen pixels) the mouse must come for a snap to catch
var wall_angle_step := 15.0          # degrees: the angle snap's steps
var wall_debug := false              # F3: node and wall numbers, hubs
var warc := false                    # the next wall drawn is an arc
var wsel_edges: Array = []           # the picked walls
var wsel_node := -1                  # the picked node
var whover_edge := -1
var whover_node := -1
var whover_handle := {}              # the handle of the picked wall under the mouse
var wdraw := {}                      # the wall being drawn: {from, from_node, start, stage ("end" | "bend"), end}
var wdrag := {}                      # a drag: {kind: "node" | "wall" | "bend" | "slide" | "thick_l" | "thick_r" | "height", ...}
var wsnap := {}                      # the last snap (its mark is drawn at the mouse)
var wtyped := ""                     # a number being typed while drawing or dragging
var _wplan := {}                     # the walls' plan in cells, worked out once per change (_plan)
var _wlabels: Array = []             # the picked wall's measurements as drawn: [screen rect, what it is]
var _wpopup: LineEdit                # typing one of them in
var _winsp_undo := false             # the inspector already pushed an undo step for this selection

const WALL_FILL := Color(0.25, 0.23, 0.19)
const WALL_LOW := Color(0.5, 0.44, 0.32)
## The ceiling over wall `e`, metres: as the game works it out (level_geometry.gd _object_wall_h, from the cell
## its middle is on and the four round it): a Grand zone 16.2, Tall 10.8, all Low 2.3, else 5.4. A wall is never
## built taller than that (it would come up through the ceiling): its height is capped there, and "full" is it.
func _room_h(e: int) -> float:
	var m := _bend_point(e)
	var c := Vector2i(roundi(m.x), roundi(m.y))
	var top := 0.0
	var all_low := true
	for d: Vector2i in [Vector2i.ZERO, Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var n := c + d
		if zones.get("grand", {}).has(n): top = 16.2
		elif zones.get("tall", {}).has(n): top = maxf(top, 10.8)
		if not zones.get("low", {}).has(n): all_low = false
	if top > 0.0: return top
	return 2.3 if all_low else 5.4

## A height for wall `e` as the game builds it: 0 (up to the ceiling) for anything at or over its room's ceiling
func _fit_h(e: int, h: float) -> float:
	var room := _room_h(e)
	if h > room + 0.01:
		_status("A wall can't be taller than the ceiling over it (%.1f m here): it goes up to the ceiling. Paint a Tall or Grand zone to raise the ceiling" % room)
	return 0.0 if h >= room - 0.025 or h <= 0.0 else h

## "h full (5.4 m)" / "h 2.40 m"
func _h_text(e: int) -> String:
	var h := float(wall_graph.edges[e].h)
	var room := _room_h(e)
	return "h full (%.1f m)" % room if h <= 0.0 or h >= room - 0.025 else "h %.2f m" % h
const SNAP_COL := {"node": Color("ffd84a"), "cross": Color("ff7a3d"), "edge": Color("35e0ff"), "tangent": Color("b388ff"),
	"perp": Color("39d98a"), "parallel": Color("39d98a"), "extend": Color("ff9f1c"), "angle": Color("e6e1cd"), "grid": Color("a39c8a")}
const SNAP_NAME := {"node": "on the node", "cross": "where they cross", "edge": "on the wall", "tangent": "straight on",
	"perp": "square to the wall", "parallel": "in line with the wall", "extend": "in line past the end", "angle": "angle", "grid": "grid"}
const HANDLE_TIP := {"slide": "slide it sideways (the walls on its ends stretch)", "bend": "bend it (straight again in the middle)",
	"thick_l": "this face's thickness", "thick_r": "this face's thickness", "height": "its height (drag up / down)"}

# ---------------------------------------------------------------- map <-> numbers
## A direction on the map as the editor shows angles: degrees, 0 = right, anticlockwise as seen on screen
static func _map_deg(v: Vector2) -> float:
	return fposmod(-rad_to_deg(v.angle()), 360.0)

static func _map_dir(deg: float) -> Vector2:
	return Vector2.from_angle(-deg_to_rad(deg))

# ---------------------------------------------------------------- the plan
func _walls_changed() -> void:
	_wplan = {}
	for e in wsel_edges.duplicate():
		if not wall_graph.edges.has(e): wsel_edges.erase(e)
	if wsel_node >= 0 and not wall_graph.nodes.has(wsel_node): wsel_node = -1
	_wall_insp_sync()
	if canvas != null: canvas.queue_redraw()

## The plan of every wall and hub in cells: {e: [outline, tags, box, drawable]}, hubs the same
func _plan() -> Dictionary:
	if not _wplan.is_empty(): return _wplan
	var sol: Dictionary = WallJoints.solve(wall_graph, CELL_M)
	var out := {"edges": {}, "hubs": {}}
	for e in sol.edges:
		out.edges[e] = _in_cells(sol.edges[e].poly, sol.edges[e].tags)
	for n in sol.hubs:
		if not sol.hubs[n].flat: out.hubs[n] = _in_cells(sol.hubs[n].poly, sol.hubs[n].tags)
	_wplan = out
	return out

func _in_cells(poly: PackedVector2Array, tags: Array) -> Array:
	var p := PackedVector2Array()
	var box := Rect2()
	for v in poly:
		var c := v / CELL_M
		p.append(c)
		box = Rect2(c, Vector2.ZERO) if p.size() == 1 else box.expand(c)
	return [p, tags, box, not Geometry2D.triangulate_polygon(p).is_empty()]

func _cells_px(c: Vector2) -> Vector2:
	return pan + (c + Vector2(0.5, 0.5)) * zoom

# ---------------------------------------------------------------- drawing
func _walls_draw() -> void:
	if wall_graph.edges.is_empty(): return
	var plan := _plan()
	var view := Rect2(_pos_at(Vector2.ZERO), canvas.size / zoom).grow(1.0)
	for e in plan.edges:
		var ed: Dictionary = wall_graph.edges[e]
		var low := float(ed.h) > 0.0 and float(ed.h) < 1.8
		_draw_plan(plan.edges[e], view, WALL_LOW if low else WALL_FILL, float(ed.base) > 0.0)
	for n in plan.hubs:
		_draw_plan(plan.hubs[n], view, WALL_FILL, false)
	# the picked and hovered walls
	for e in wsel_edges:
		if plan.edges.has(e): _draw_outline_px(plan.edges[e], Color(0, 0, 0, 0.8), 4.0, SEL, 2.0)
	if whover_edge >= 0 and plan.edges.has(whover_edge) and not whover_edge in wsel_edges and wdrag.is_empty():
		_draw_outline_px(plan.edges[whover_edge], Color(0, 0, 0, 0), 0.0, Color(SEL, 0.55), 1.5)
	# locked walls: what is locked, along them
	if zoom >= 8.0:
		for e in wall_graph.edges:
			var ed: Dictionary = wall_graph.edges[e]
			var ll := bool(ed.get("lock_len", false))
			var la := bool(ed.get("lock_ang", false))
			if ll or la:
				var p := _cells_px(_bend_point(e))
				if view.has_point(_pos_at(p)): _tag(p + Vector2(-14, -6), "LOCK " + ("L+A" if ll and la else ("L" if ll else "A")), Color("ff9f1c"), 9)
	# nodes, where they can be picked or snapped to
	if (tool == "select" or _walls_tool()) and zoom >= 6.0:
		for n in wall_graph.nodes:
			var p := _cells_px(wall_graph.pos(n))
			if not Rect2(Vector2.ZERO, canvas.size).grow(8.0).has_point(p): continue
			var r := 3.0 if n != whover_node else 4.5
			var col := SEL if n == wsel_node else (CREAM if n == whover_node else Color(CREAM, 0.6))
			canvas.draw_rect(Rect2(p - Vector2(r, r), Vector2(r, r) * 2.0), Color(0, 0, 0, 0.75))
			canvas.draw_rect(Rect2(p - Vector2(r - 1.0, r - 1.0), Vector2(r - 1.0, r - 1.0) * 2.0), col)
	if wall_debug: _draw_wall_debug(plan)

func _draw_plan(pl: Array, view: Rect2, fill: Color, lifted: bool) -> void:
	var box: Rect2 = pl[2]
	if not view.intersects(box): return
	var pts := PackedVector2Array()
	for c: Vector2 in pl[0]: pts.append(_cells_px(c))
	if pl[3]: canvas.draw_colored_polygon(pts, Color(fill, 0.55) if lifted else fill)
	# the outside of the walls (not where one meets the next or a hub)
	var tags: Array = pl[1]
	for i in pts.size():
		if str(tags[i].k) == "chord": continue
		var a := pts[i]
		var b := pts[(i + 1) % pts.size()]
		if lifted: canvas.draw_dashed_line(a, b, Color(CREAM, 0.7), 1.0, 4.0)
		else: canvas.draw_line(a, b, Color(CREAM, 0.75), 1.0)

func _draw_outline_px(pl: Array, under: Color, uw: float, col: Color, w: float) -> void:
	var pts := PackedVector2Array()
	for c: Vector2 in pl[0]: pts.append(_cells_px(c))
	pts.append(pts[0])
	if uw > 0.0: canvas.draw_polyline(pts, under, uw)
	canvas.draw_polyline(pts, col, w)

func _draw_wall_debug(plan: Dictionary) -> void:
	for n in plan.hubs:
		_draw_outline_px(plan.hubs[n], Color(0, 0, 0, 0), 0.0, Color("ff7a3d"), 1.5)
	for e in wall_graph.edges:
		var cv: Dictionary = wall_graph.curve_of(e)
		var line := PackedVector2Array()
		for c: Vector2 in WallGeom.polyline(cv, 16): line.append(_cells_px(c))
		canvas.draw_polyline(line, Color("35e0ff", 0.8), 1.0)
		_tag(_cells_px(WallGeom.point(cv, 0.5)) + Vector2(4, -4), "w%d" % e, Color("35e0ff"), 10)
	for n in wall_graph.nodes:
		_tag(_cells_px(wall_graph.pos(n)) + Vector2(5, 12), "n%d·%d" % [n, wall_graph.degree(n)], Color("ffd84a"), 10)
	_tag(Vector2(10, canvas.size.y - 60), "GRAPH  %d nodes  %d walls  %d hubs   (F3 hides)" % [wall_graph.nodes.size(), wall_graph.edges.size(), plan.hubs.size()], Color("ffd84a"), 12)

## The wall being drawn, the snap mark, the picked wall's handles and measurements, a number being typed
func _walls_overlay() -> void:
	_wlabels.clear()
	if not wdraw.is_empty(): _draw_rubber()
	var one := _one_wall()
	if tool == "select" and one >= 0:
		_draw_handles(one)
		if wdrag.is_empty() or wdrag.kind != "node": _draw_labels(one)
	if not wsnap.is_empty() and (not wdraw.is_empty() or _walls_tool() or wdrag.get("kind", "") == "node"):
		_draw_snap(wsnap)
	if wtyped != "":
		var what := _typed_what()
		_tag(mouse_px + Vector2(14, 22), "= %s   %s   (Enter)" % [wtyped, what], GOLD, 13)
	elif not wdrag.is_empty() and str(wdrag.kind) in ["slide", "thick_l", "thick_r", "height", "bend"]:
		_tag(mouse_px + Vector2(14, 22), _drag_readout(), CREAM, 12)

## The one wall picked (-1: none or several)
func _one_wall() -> int:
	return wsel_edges[0] if wsel_edges.size() == 1 and wall_graph.edges.has(wsel_edges[0]) else -1

func _draw_rubber() -> void:
	var t := _wall_type()
	var a: Vector2 = wdraw.from
	var b: Vector2 = wdraw.end if wdraw.stage == "bend" else (wsnap.p if not wsnap.is_empty() else a)
	var bulge := _rubber_bulge() if wdraw.stage == "bend" else 0.0
	var cv: Dictionary = WallGeom.curve(a, b, bulge)
	var line := PackedVector2Array()
	for c: Vector2 in WallGeom.polyline(cv, 32): line.append(_cells_px(c))
	if line.size() < 2: return
	var w := maxf(_wall_thick(t) / CELL_M * zoom, 3.0)
	canvas.draw_polyline(line, Color(0, 0, 0, 0.6), w + 2.0)
	canvas.draw_polyline(line, Color(SEL, 0.55), w)
	canvas.draw_polyline(line, SEL, 1.0)
	var txt := "%.2f m   %s°" % [WallGeom.length(cv) * CELL_M, _deg(_map_deg(b - a))]
	if cv.kind == WallGeom.ARC: txt += "   r %.2f m   %s°" % [float(cv.r) * CELL_M, _deg(absf(rad_to_deg(cv.sw)))]
	_tag(line[line.size() / 2] + Vector2(10, 14), txt, CREAM, 12)
	if _arc_mode() and wdraw.stage == "end": _tag(_cells_px(b) + Vector2(10, 26), "ARC: click the end, then bend it", Color("b388ff"), 11)

func _draw_snap(s: Dictionary) -> void:
	var kind := str(s.kind)
	if kind == "free": return
	var col: Color = SNAP_COL.get(kind, CREAM)
	var p := _cells_px(s.p)
	for gl: Array in s.get("guides", []):
		for i in gl.size() - 1:
			canvas.draw_dashed_line(_cells_px(gl[i]), _cells_px(gl[i + 1]), Color(col, 0.75), 1.0, 5.0)
	match kind:
		"node":
			canvas.draw_rect(Rect2(p - Vector2(6, 6), Vector2(12, 12)), col, false, 2.0)
		"cross":
			canvas.draw_line(p + Vector2(-6, -6), p + Vector2(6, 6), col, 2.0)
			canvas.draw_line(p + Vector2(-6, 6), p + Vector2(6, -6), col, 2.0)
		"edge":
			var dia := PackedVector2Array([p + Vector2(0, -6), p + Vector2(6, 0), p + Vector2(0, 6), p + Vector2(-6, 0), p + Vector2(0, -6)])
			canvas.draw_polyline(dia, col, 2.0)
		"perp":
			canvas.draw_polyline(PackedVector2Array([p + Vector2(-6, -2), p + Vector2(-6, 6), p + Vector2(2, 6)]), col, 2.0)
		"grid":
			canvas.draw_circle(p, 2.5, col)
		_:
			canvas.draw_arc(p, 5.0, 0.0, TAU, 16, col, 2.0)
	if kind != "grid": _tag(p + Vector2(10, -10), str(SNAP_NAME.get(kind, kind)) + ("" if str(s.label).count("+") == 0 else "  +"), col, 11)

func _wall_text(e: int) -> String:
	var ed: Dictionary = wall_graph.edges[e]
	var cv: Dictionary = wall_graph.curve_of(e)
	var txt := "%.2f m long   %.2f m thick" % [WallGeom.length(cv) * CELL_M, float(ed.tl) + float(ed.tr)]
	if cv.kind == WallGeom.ARC: txt += "   r %.2f m" % (float(cv.r) * CELL_M)
	txt += "   " + _h_text(e).trim_prefix("h ").replace("full", "full height")
	return txt

# ---------------------------------------------------------------- handles of the picked wall
## {kind: screen point}: slide (straight walls), bend, thick_l / thick_r (on each face a quarter of the way
## along), height (three quarters of the way along)
func _handles(e: int) -> Dictionary:
	var ed: Dictionary = wall_graph.edges[e]
	var cv: Dictionary = wall_graph.curve_of(e)
	var out := {}
	var mid: Vector2 = WallGeom.point(cv, 0.5)
	var n: Vector2 = WallGeom.normal(cv, 0.5)
	if cv.kind == WallGeom.LINE:
		out["slide"] = _cells_px(mid)
		out["bend"] = _cells_px(mid) + n * (float(ed.tl) / CELL_M * zoom + 18.0)
	else:
		out["bend"] = _cells_px(mid)
	var q: Vector2 = WallGeom.point(cv, 0.25)
	var nq: Vector2 = WallGeom.normal(cv, 0.25)
	out["thick_l"] = _cells_px(q + nq * float(ed.tl) / CELL_M) + nq * 7.0
	out["thick_r"] = _cells_px(q - nq * float(ed.tr) / CELL_M) - nq * 7.0
	out["height"] = _cells_px(WallGeom.point(cv, 0.75))
	return out

func _handle_at(px: Vector2) -> String:
	var one := _one_wall()
	if one < 0: return ""
	var hs := _handles(one)
	var best := ""
	var bd := 9.0
	for k in hs:
		var d: float = (hs[k] as Vector2).distance_to(px)
		if d <= bd:
			bd = d
			best = k
	return best

func _draw_handles(e: int) -> void:
	var hs := _handles(e)
	var cv: Dictionary = wall_graph.curve_of(e)
	for k: String in hs:
		var p: Vector2 = hs[k]
		var hot: bool = whover_handle.get("kind", "") == k or wdrag.get("kind", "") == k
		var col := Color.WHITE if hot else GOLD
		match k:
			"slide":
				canvas.draw_rect(Rect2(p - Vector2(5, 5), Vector2(10, 10)), Color(0, 0, 0, 0.85))
				canvas.draw_rect(Rect2(p - Vector2(3.5, 3.5), Vector2(7, 7)), col)
			"bend":
				var d := 6.0
				var dia := PackedVector2Array([p + Vector2(0, -d), p + Vector2(d, 0), p + Vector2(0, d), p + Vector2(-d, 0)])
				canvas.draw_colored_polygon(dia, Color(0, 0, 0, 0.85))
				canvas.draw_colored_polygon(PackedVector2Array(Array(dia).map(func(v): return p + (v - p) * 0.65)), col)
			"thick_l", "thick_r":
				var nq: Vector2 = WallGeom.normal(cv, 0.25) * (1.0 if k == "thick_l" else -1.0)
				var side := Vector2(-nq.y, nq.x)
				var tri := PackedVector2Array([p + nq * 6.0, p - nq * 2.0 + side * 5.0, p - nq * 2.0 - side * 5.0])
				canvas.draw_colored_polygon(tri, Color(0, 0, 0, 0.85))
				canvas.draw_colored_polygon(PackedVector2Array(Array(tri).map(func(v): return p + (v - p) * 0.65)), col)
			"height":
				canvas.draw_rect(Rect2(p - Vector2(3, 8), Vector2(6, 16)), Color(0, 0, 0, 0.85))
				canvas.draw_rect(Rect2(p - Vector2(1.5, 6.5), Vector2(3, 13)), col)
				canvas.draw_line(p + Vector2(-5, -9), p + Vector2(5, -9), col, 1.5)

## The picked wall's measurements beside it, each a box you can click to type it
func _draw_labels(e: int) -> void:
	var ed: Dictionary = wall_graph.edges[e]
	var cv: Dictionary = wall_graph.curve_of(e)
	var mid: Vector2 = WallGeom.point(cv, 0.5)
	var n: Vector2 = WallGeom.normal(cv, 0.5)
	var at := _cells_px(mid) - n * (float(ed.tr) / CELL_M * zoom + 30.0)
	var items: Array = [["length", "%.2f m" % (WallGeom.length(cv) * CELL_M)]]
	if cv.kind == WallGeom.LINE:
		items.append(["angle", "%s°" % _deg(_map_deg(wall_graph.pos(ed.b) - wall_graph.pos(ed.a)))])
	else:
		items.append(["radius", "r %.2f m" % (float(cv.r) * CELL_M)])
	items.append(["thick", "t %.2f m" % (float(ed.tl) + float(ed.tr))])
	items.append(["height", _h_text(e)])
	var x := at.x - 120.0
	for it: Array in items:
		var txt: String = it[1]
		var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 10.0
		var r := Rect2(Vector2(x, at.y - 10.0), Vector2(w, 18.0))
		var hot := r.has_point(mouse_px)
		canvas.draw_rect(r, Color(0.08, 0.08, 0.07, 0.9))
		canvas.draw_rect(r, GOLD if hot else Color(CREAM, 0.5), false, 1.0)
		canvas.draw_string(font, r.position + Vector2(5, 13), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, GOLD if hot else CREAM)
		_wlabels.append([r, it[0]])
		x += w + 6.0

# ---------------------------------------------------------------- the tools
## The wall type the current tool draws ("" when it doesn't): the straight pieces drawn as a line (Thin / Half
## wall), and the Corner and Curved wall pieces (drawn the same way: the curve as arcs)
func _wall_type() -> String:
	if not tool.begins_with("obj:"): return ""
	var t := tool.get_slice(":", 1)
	var sh := _shape(t)
	if sh == "slab" and bool(_info(t).get("draw_line", false)): return t
	return t if sh in ["corner", "arc"] else ""

func _walls_tool() -> bool:
	return _wall_type() != ""

func _arc_mode() -> bool:
	return warc or _shape(_wall_type()) == "arc"

func _wall_thick(t: String) -> float:
	return float(_info(t).get("params", {}).get("thick", _info(t).get("thickness", 0.3)))

func _wall_props(t: String) -> Dictionary:
	var th := _wall_thick(t)
	return {"tl": th * 0.5, "tr": th * 0.5, "h": float(_info(t).get("params", {}).get("height", 0.0))}

func _snap_opts(extra := {}) -> Dictionary:
	var o := {"radius": wall_snap_px / zoom, "grid": SNAP_STEP if snap else 0.0, "angle_step": wall_angle_step,
		"off": Input.is_key_pressed(KEY_ALT)}
	o.merge(extra, true)
	return o

## Where a click of the wall tool lands: snapped against what is drawn from
func _draw_snap_at(px: Vector2) -> Dictionary:
	var extra := {}
	if not wdraw.is_empty():
		extra = {"from": [wdraw.from], "from_node": wdraw.from_node}
	return WallSnap.snap(wall_graph, _pos_at(px), _snap_opts(extra))

func _node_at(px: Vector2) -> int:
	return wall_graph.node_near(_pos_at(px), 8.0 / zoom)

## The wall under the mouse: the nearest centre line within its half thickness (or a few pixels)
func _wall_at(px: Vector2) -> int:
	var cur := _pos_at(px)
	var best := -1
	var bd := INF
	for e in wall_graph.edges:
		var ed: Dictionary = wall_graph.edges[e]
		var reach := maxf(maxf(float(ed.tl), float(ed.tr)) / CELL_M, 6.0 / zoom)
		if not wall_graph.box_of(e, reach).has_point(cur): continue
		var c: Dictionary = WallGeom.closest(wall_graph.curve_of(e), cur)
		if c.d <= reach and c.d < bd:
			bd = c.d
			best = e
	return best

## The middle of a wall's curve
func _bend_point(e: int) -> Vector2:
	return WallGeom.point(wall_graph.curve_of(e), 0.5)

func _object_press(mb: InputEventMouseButton) -> void:
	if _wall_press(mb): return
	super(mb)

## A click the walls take (true), else it goes on to the objects
func _wall_press(mb: InputEventMouseButton) -> bool:
	if mb.pressed: _close_popup()         # (a click elsewhere; the button coming up off a label leaves its box open)
	if not mb.pressed:
		if not wdrag.is_empty() and mb.button_index == MOUSE_BUTTON_LEFT:
			_wall_drag_end()
			return true
		return _walls_tool()
	if _walls_tool():
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			if not wdraw.is_empty():
				_wall_stop()
				return true
			var e := _wall_at(mb.position)
			if e >= 0: _wall_delete([e], -1)
			return true
		if mb.button_index == MOUSE_BUTTON_LEFT: _wall_click(mb)
		return mb.button_index == MOUSE_BUTTON_LEFT
	if mb.button_index == MOUSE_BUTTON_RIGHT:
		if _obj_at(mb.position) >= 0: return false
		var e := _wall_at(mb.position)
		if e < 0: return false
		_wall_delete([e], -1)
		return true
	if tool != "select" or mb.button_index != MOUSE_BUTTON_LEFT: return false
	# the picked wall's measurements and handles, then a node, then the objects' own grips and bodies, then a wall
	for lb: Array in _wlabels:
		if (lb[0] as Rect2).has_point(mb.position):
			_open_popup(lb[1], lb[0])
			return true
	var h := _handle_at(mb.position)
	if h != "":
		_push_undo()
		var e := _one_wall()
		wdrag = {"kind": h, "edge": e, "from": _pos_at(mb.position), "from_px": mb.position, "orig": _node_positions(),
			"h0": minf(float(wall_graph.edges[e].h), _room_h(e)) if float(wall_graph.edges[e].h) > 0.0 else _room_h(e)}
		wtyped = ""
		return true
	var n := _node_at(mb.position)
	if n >= 0:
		_select(-1)
		wsel_node = n
		wsel_edges = []
		_push_undo()
		wdrag = {"kind": "node", "node": n, "orig": _node_positions()}
		wtyped = ""
		_walls_changed()
		return true
	if selected >= 0 and (_grip_at(mb.position) >= 0 or _on_handle(mb.position)): return false
	if _obj_at(mb.position) >= 0: return false
	var e := _wall_at(mb.position)
	if e < 0:
		if not mb.shift_pressed:
			wsel_edges = []
			wsel_node = -1
			_walls_changed()
		return false
	_select(-1)
	wsel_node = -1
	if mb.shift_pressed:
		if e in wsel_edges: wsel_edges.erase(e)
		else: wsel_edges.append(e)
	elif not e in wsel_edges:
		wsel_edges = [e]
	_winsp_undo = false
	_push_undo()
	wdrag = {"kind": "wall", "from": _pos_at(mb.position), "nodes": _sel_nodes(), "orig": _node_positions(), "moved": false}
	_walls_changed()
	return true

func _node_positions() -> Dictionary:
	var out := {}
	for n in wall_graph.nodes: out[n] = wall_graph.pos(n)
	return out

func _restore_positions(orig: Dictionary) -> void:
	for n in orig:
		if wall_graph.nodes.has(n): wall_graph.nodes[n].p = orig[n]

## The nodes the picked walls run between
func _sel_nodes() -> Array:
	var out: Array = []
	for e in wsel_edges:
		if not wall_graph.edges.has(e): continue
		for n in [wall_graph.edges[e].a, wall_graph.edges[e].b]:
			if not out.has(n): out.append(n)
	return out

func _wall_click(mb: InputEventMouseButton) -> void:
	var s := _draw_snap_at(mb.position)
	var p: Vector2 = s.p
	if wdraw.is_empty():
		wdraw = {"from": p, "from_node": s.node, "start": p, "stage": "end"}
		wsnap = s
		wtyped = ""
		canvas.queue_redraw()
		return
	if mb.double_click:                        # (its first click already put the wall down)
		_wall_stop()
		return
	if wdraw.stage == "end":
		_wall_end_at(p)
	else:
		_wall_lay(wdraw.from, wdraw.end, _rubber_bulge())

## The wall being drawn ends at p: put it down, or (an arc) go on to bending it
func _wall_end_at(p: Vector2) -> void:
	if p.distance_to(wdraw.from) < 1e-3: return
	if _arc_mode():
		wdraw.stage = "bend"
		wdraw.end = p
		wtyped = ""
		canvas.queue_redraw()
		return
	_wall_lay(wdraw.from, p, 0.0)

## Put a wall down from a to b and carry on drawing from b (a loop closed on where this run started ends it)
func _wall_lay(a: Vector2, b: Vector2, bulge: float) -> void:
	_push_undo()
	var made: Array = wall_graph.add_wall(a, b, bulge, _wall_props(_wall_type()), WALL_TOL)
	wtyped = ""
	_walls_changed()
	_mark_dirty()
	var closed := b.distance_to(wdraw.start) <= WALL_TOL
	var nb: int = wall_graph.node_near(b, WALL_TOL)
	wsel_edges = made
	if closed:
		_wall_stop()
		_status("Closed the loop: %d walls" % made.size())
		return
	wdraw = {"from": b, "from_node": nb, "start": wdraw.start, "stage": "end"}

func _wall_stop() -> void:
	wdraw = {}
	wtyped = ""
	canvas.queue_redraw()

## The bulge the mouse is pulling the arc being drawn to: straight near the chord, a half circle near that,
## and tangent to the wall it starts from near that
func _rubber_bulge() -> float:
	return _bulge_snap(wdraw.from, wdraw.end, _pos_at(mouse_px), int(wdraw.from_node))

func _bulge_snap(a: Vector2, b: Vector2, cur: Vector2, from_node: int, skip_edge := -1) -> float:
	var c := a.distance_to(b)
	if c < 1e-4: return 0.0
	var d := (b - a) / c
	var n := Vector2(-d.y, d.x)
	var s := (cur - (a + b) * 0.5).dot(n)
	if Input.is_key_pressed(KEY_ALT): return s
	var r := wall_snap_px / zoom
	var picks: Array = [0.0, c * 0.5, -c * 0.5]
	if from_node >= 0 and wall_graph.nodes.has(from_node):
		for e in wall_graph.edges_at(from_node):
			if e == skip_edge: continue
			var cv: Dictionary = wall_graph.curve_of(e) if wall_graph.edges[e].a == from_node else WallGeom.reversed(wall_graph.curve_of(e))
			var on: Vector2 = -WallGeom.tangent(cv, 0.0)                 # straight on out of that wall
			var sw := -2.0 * d.angle_to(on)
			if absf(sw) < TAU - 0.1: picks.append(WallGeom.sagitta_of(a, b, sw))
	for v: float in picks:
		if absf(s - v) <= r: return v
	return s

# ---------------------------------------------------------------- dragging
func _walls_motion(p: Vector2) -> bool:
	if not wdrag.is_empty():
		_wall_drag_to(p)
		return true
	whover_edge = -1
	whover_node = -1
	whover_handle = {}
	if _walls_tool():
		wsnap = {} if wdraw.get("stage", "") == "bend" else _draw_snap_at(p)
	elif tool == "select":
		wsnap = {}
		var h := _handle_at(p)
		if h != "": whover_handle = {"kind": h}
		else:
			whover_node = _node_at(p)
			if whover_node < 0 and _obj_at(p) < 0: whover_edge = _wall_at(p)
	else:
		wsnap = {}
	return false

func _wall_drag_to(p: Vector2) -> void:
	var cur := _pos_at(p)
	var free := Input.is_key_pressed(KEY_ALT)
	match str(wdrag.kind):
		"node":
			var n: int = wdrag.node
			var from: Array = []
			for e in wall_graph.edges_at(n): from.append(wdrag.orig[wall_graph.other(e, n)])
			_restore_positions(wdrag.orig)
			wsnap = WallSnap.snap(wall_graph, cur, _snap_opts({"from": from, "skip_node": n}))
			wall_graph.move_nodes(wall_graph.drag_targets(n, wsnap.p))
		"wall":
			var d: Vector2 = cur - wdrag.from
			if snap and not free: d = (d / SNAP_STEP).round() * SNAP_STEP
			_restore_positions(wdrag.orig)
			wall_graph.translate(wdrag.nodes, d)
			wdrag.moved = d != Vector2.ZERO
		"bend":
			var e: int = wdrag.edge
			var ed: Dictionary = wall_graph.edges[e]
			ed.bulge = _bulge_snap(wall_graph.pos(ed.a), wall_graph.pos(ed.b), cur, ed.a, e)
		"slide":
			var e: int = wdrag.edge
			var dist := _slide_dist(cur)
			_restore_positions(wdrag.orig)
			wall_graph.slide(e, dist)
			wdrag.value = dist
		"thick_l", "thick_r":
			var e: int = wdrag.edge
			var cv: Dictionary = WallGeom.curve(wdrag.orig[wall_graph.edges[e].a], wdrag.orig[wall_graph.edges[e].b], wall_graph.edges[e].bulge)
			var c: Dictionary = WallGeom.closest(cv, cur)
			var side := 1.0 if wdrag.kind == "thick_l" else -1.0
			var m := maxf((cur - (c.p as Vector2)).dot(WallGeom.normal(cv, c.t)) * side * CELL_M, 0.01)
			if not free: m = snappedf(m, 0.01 if not snap else 0.025)
			wall_graph.edges[e]["tl" if side > 0.0 else "tr"] = maxf(m, 0.01)
		"height":
			var e: int = wdrag.edge
			var room := _room_h(e)
			var h := clampf(float(wdrag.h0) + (float(wdrag.from_px.y) - p.y) * 0.02, 0.1, room)
			if not free: h = snappedf(h, 0.05)
			wall_graph.edges[e].h = 0.0 if h >= room - 0.025 else h
	_walls_changed()

## How far sideways the slide drag has pulled its wall (cells, + to the wall's left), on 0.1 m steps
func _slide_dist(cur: Vector2) -> float:
	var e: int = wdrag.edge
	var a: Vector2 = wdrag.orig[wall_graph.edges[e].a]
	var b: Vector2 = wdrag.orig[wall_graph.edges[e].b]
	var d := (b - a).normalized()
	var dist := (cur - (wdrag.from as Vector2)).dot(Vector2(-d.y, d.x))
	if not Input.is_key_pressed(KEY_ALT): dist = snappedf(dist * CELL_M, 0.1) / CELL_M
	return dist

func _drag_readout() -> String:
	var e: int = wdrag.get("edge", -1)
	if e < 0 or not wall_graph.edges.has(e): return ""
	var ed: Dictionary = wall_graph.edges[e]
	match str(wdrag.kind):
		"slide": return "moved %.2f m   (type a number: exact)" % (float(wdrag.get("value", 0.0)) * CELL_M)
		"thick_l": return "this side %.2f m   (%.2f m in all)" % [float(ed.tl), float(ed.tl) + float(ed.tr)]
		"thick_r": return "this side %.2f m   (%.2f m in all)" % [float(ed.tr), float(ed.tl) + float(ed.tr)]
		"height": return _h_text(e).trim_prefix("h ") + ("   (the ceiling: drag down to lower it)" if _h_text(e).begins_with("h full") else "")
		"bend":
			var cv: Dictionary = wall_graph.curve_of(e)
			return "straight" if cv.kind == WallGeom.LINE else "r %.2f m   %s°" % [float(cv.r) * CELL_M, _deg(absf(rad_to_deg(cv.sw)))]
	return ""

func _wall_drag_end() -> void:
	match str(wdrag.kind):
		"node":
			wsel_node = wall_graph.settle_node(wdrag.node, WALL_TOL)
		"wall":
			if wdrag.moved:
				for n in wdrag.nodes:
					if wall_graph.nodes.has(n): wall_graph.settle_node(n, WALL_TOL)
		"bend", "slide":
			if wall_graph.edges.has(wdrag.edge):
				wall_graph.planarize([wdrag.edge] + wall_graph.edges_at(wall_graph.edges[wdrag.edge].a) + wall_graph.edges_at(wall_graph.edges[wdrag.edge].b), WALL_TOL)
	wdrag = {}
	wsnap = {}
	wtyped = ""
	_walls_changed()
	_mark_dirty()

# ---------------------------------------------------------------- typed numbers
## What a typed number will set, for the readout
func _typed_what() -> String:
	if not wdraw.is_empty():
		return "radius m" if wdraw.stage == "bend" else "length m  (or length,angle°)"
	match str(wdrag.get("kind", "")):
		"slide": return "move m"
		"bend": return "radius m  (0: straight)"
		"thick_l", "thick_r": return "this side m"
		"height": return "height m  (0: full)"
		"node": return "length m of the wall it pulls"
	return ""

## A key while drawing or dragging: digits, a point, a minus and a comma make the number, Backspace takes one
## back, Enter uses it. True when it was taken.
func _typed_key(k: InputEventKey) -> bool:
	if wdraw.is_empty() and wdrag.is_empty(): return false
	var ch := ""
	match k.keycode:
		KEY_0, KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9: ch = str(k.keycode - KEY_0)
		KEY_KP_0, KEY_KP_1, KEY_KP_2, KEY_KP_3, KEY_KP_4, KEY_KP_5, KEY_KP_6, KEY_KP_7, KEY_KP_8, KEY_KP_9: ch = str(k.keycode - KEY_KP_0)
		KEY_PERIOD, KEY_KP_PERIOD: ch = "."
		KEY_MINUS, KEY_KP_SUBTRACT: ch = "-"
		KEY_COMMA: ch = ","
		KEY_BACKSPACE:
			if wtyped == "": return not wdraw.is_empty()
			wtyped = wtyped.left(-1)
			canvas.queue_redraw()
			return true
		KEY_ENTER, KEY_KP_ENTER:
			if wtyped == "": return false
			_typed_apply()
			return true
	if ch == "": return false
	wtyped += ch
	canvas.queue_redraw()
	return true

func _typed_apply() -> void:
	var parts := wtyped.split(",")
	wtyped = ""
	if parts.is_empty() or not parts[0].is_valid_float():
		canvas.queue_redraw()
		return
	var v := float(parts[0])
	if not wdraw.is_empty():
		var a: Vector2 = wdraw.from
		if wdraw.stage == "bend":
			var b: Vector2 = wdraw.end
			var side := signf(_rubber_bulge()) if absf(_rubber_bulge()) > 1e-6 else 1.0
			var c := a.distance_to(b)
			var r := maxf(v / CELL_M, c * 0.5)
			_wall_lay(a, b, side * (r - sqrt(maxf(r * r - c * c * 0.25, 0.0))) if v > 0.0 else 0.0)
			return
		var dir: Vector2 = (wsnap.p - a).normalized() if not wsnap.is_empty() and (wsnap.p as Vector2).distance_to(a) > 1e-4 else Vector2.RIGHT
		if parts.size() > 1 and parts[1].is_valid_float(): dir = _map_dir(float(parts[1]))
		if v > 0.0: _wall_end_at(a + dir * v / CELL_M)
		return
	var e: int = wdrag.get("edge", -1)
	match str(wdrag.kind):
		"slide":
			_restore_positions(wdrag.orig)
			var d0 := _slide_dist(_pos_at(mouse_px))
			wall_graph.slide(e, (v / CELL_M) * (signf(d0) if absf(d0) > 1e-6 else 1.0))
		"bend": wall_graph.set_radius(e, v / CELL_M)
		"thick_l": wall_graph.edges[e].tl = maxf(v, 0.01)
		"thick_r": wall_graph.edges[e].tr = maxf(v, 0.01)
		"height": wall_graph.edges[e].h = _fit_h(e, v)
		"node":
			var n: int = wdrag.node
			var at: Array = wall_graph.edges_at(n)
			if not at.is_empty() and v > 0.0:
				_restore_positions(wdrag.orig)
				wall_graph.set_length(at[0], v / CELL_M, wall_graph.other(at[0], n))
	_wall_drag_end()

# ---------------------------------------------------------------- typing a measurement in
func _open_popup(kind: String, r: Rect2) -> void:
	_close_popup()
	var e := _one_wall()
	if e < 0: return
	var ed: Dictionary = wall_graph.edges[e]
	var cv: Dictionary = wall_graph.curve_of(e)
	var val := 0.0
	match kind:
		"length": val = WallGeom.length(cv) * CELL_M
		"angle": val = _map_deg(wall_graph.pos(ed.b) - wall_graph.pos(ed.a))
		"radius": val = float(cv.get("r", 0.0)) * CELL_M
		"thick": val = float(ed.tl) + float(ed.tr)
		"height": val = float(ed.h) if float(ed.h) > 0.0 and float(ed.h) < _room_h(e) - 0.025 else _room_h(e)
	_wpopup = LineEdit.new()
	_wpopup.text = str(snappedf(val, 0.01))
	_wpopup.position = r.position - Vector2(0, 4)
	_wpopup.custom_minimum_size = Vector2(maxf(r.size.x, 70.0), 24)
	_wpopup.tooltip_text = {"length": "metres", "angle": "degrees (0 = right, anticlockwise)", "radius": "metres (0: straight)",
		"thick": "metres, both faces", "height": "metres (0: up to the ceiling)"}[kind]
	canvas.add_child(_wpopup)
	_wpopup.grab_focus()
	_wpopup.select_all()
	_wpopup.text_submitted.connect(func(t: String) -> void:
		if t.is_valid_float(): _wall_measure(e, kind, float(t))
		_close_popup())
	_wpopup.focus_exited.connect(_close_popup)

func _close_popup() -> void:
	if _wpopup != null and is_instance_valid(_wpopup):
		_wpopup.queue_free()
	_wpopup = null

## Wall `e` given an exact measurement (metres / degrees): its a end stays where it is
func _wall_measure(e: int, kind: String, v: float) -> void:
	if not wall_graph.edges.has(e): return
	_push_undo()
	var ed: Dictionary = wall_graph.edges[e]
	match kind:
		"length": if v > 0.0: wall_graph.set_length(e, v / CELL_M, ed.a)
		"angle": wall_graph.set_angle(e, _map_dir(v).angle(), ed.a)
		"radius": wall_graph.set_radius(e, v / CELL_M)
		"thick":
			ed.tl = maxf(v, 0.02) * 0.5
			ed.tr = maxf(v, 0.02) * 0.5
		"height": ed.h = _fit_h(e, v)
	if kind in ["length", "angle"] and wall_graph.edges.has(e): wall_graph.settle_node(wall_graph.edges[e].b, WALL_TOL)
	_walls_changed()
	_mark_dirty()

# ---------------------------------------------------------------- the inspector (level_editor.gd builds it)
## Overridden by level_editor.gd: the wall inspector follows the picked walls
func _wall_insp_sync() -> void:
	pass

## Set `key` on every picked wall (one undo step for a run of changes to the same selection): tl, tr, thick (both
## faces), h, base, segs, mat_l, mat_r, lock_len, lock_ang; length, angle, radius (the one picked wall)
func _wall_set(key: String, v) -> void:
	var es: Array = wsel_edges.filter(func(e): return wall_graph.edges.has(e))
	if es.is_empty(): return
	if not _winsp_undo:
		_push_undo()
		_winsp_undo = true
	for e in es:
		var ed: Dictionary = wall_graph.edges[e]
		match key:
			"thick":
				ed.tl = maxf(float(v), 0.02) * 0.5
				ed.tr = maxf(float(v), 0.02) * 0.5
			"tl", "tr": ed[key] = maxf(float(v), 0.01)
			"h": ed.h = _fit_h(e, float(v))
			"base": ed.base = maxf(float(v), 0.0)
			"segs": ed.segs = int(v)
			"mat_l", "mat_r": ed[key] = str(v)
			"lock_len", "lock_ang": ed[key] = bool(v)
			"length", "angle", "radius":
				if es.size() == 1:
					_winsp_undo = true
					var keep: int = ed.a
					if key == "length" and float(v) > 0.0: wall_graph.set_length(e, float(v) / CELL_M, keep)
					elif key == "angle": wall_graph.set_angle(e, _map_dir(float(v)).angle(), keep)
					elif key == "radius": wall_graph.set_radius(e, float(v) / CELL_M)
	_walls_changed()
	_mark_dirty()

## The inspector's buttons: "straighten", "flip" (swap the faces: thickness and material), "duplicate", "delete"
func _wall_action(what: String) -> void:
	var es: Array = wsel_edges.filter(func(e): return wall_graph.edges.has(e))
	if es.is_empty(): return
	match what:
		"delete":
			_wall_delete(es, -1)
			return
		"duplicate":
			_duplicate_selected()
			return
	_push_undo()
	for e in es:
		var ed: Dictionary = wall_graph.edges[e]
		if what == "straighten": ed.bulge = 0.0
		elif what == "flip":
			var t: float = ed.tl
			ed.tl = ed.tr
			ed.tr = t
			var m: String = ed.mat_l
			ed.mat_l = ed.mat_r
			ed.mat_r = m
	if what == "straighten": wall_graph.planarize(es, WALL_TOL)
	_walls_changed()
	_mark_dirty()

# ---------------------------------------------------------------- deleting, the selection
func _wall_delete(es: Array, n: int) -> void:
	_push_undo()
	if n >= 0: wall_graph.delete_node(n)
	for e in es: wall_graph.delete_edge(e)
	wsel_edges = []
	wsel_node = -1
	whover_edge = -1
	_walls_changed()
	_mark_dirty()

func _delete_selected() -> void:
	if not wsel_edges.is_empty() or wsel_node >= 0:
		_wall_delete(wsel_edges.duplicate(), wsel_node)
		if _group().is_empty(): return
	super()

func _select(i: int) -> void:
	if i >= 0 or wdrag.is_empty():
		wsel_edges = []
		wsel_node = -1
		_winsp_undo = false
	super(i)
	_wall_insp_sync()

func _cancel_all() -> void:
	super()
	_close_popup()
	if not wdraw.is_empty(): _wall_stop()
	if not wdrag.is_empty():
		_restore_positions(wdrag.get("orig", {}))
		wdrag = {}
		wsnap = {}
		wtyped = ""
		_undo()                              # (the drag pushed one: nothing happened)
		redo_stack.clear()

## A box dragged out with Select takes the walls whose middle is in it too
func _end_box(to: Vector2) -> void:
	var r := Rect2(box_from, Vector2.ZERO).expand(to)
	super(to)
	if r.size.length() < 4.0: return
	wsel_edges = wall_graph.edges.keys().filter(func(e): return r.has_point(_cells_px(_bend_point(e))))
	wsel_node = -1
	_winsp_undo = false
	_walls_changed()
	if not wsel_edges.is_empty():
		_status("%d walls%s picked: drag one to move them, arrows nudge, the inspector sets them all, Del deletes" % [
			wsel_edges.size(), (" and %d objects" % _group().size()) if not _group().is_empty() else ""])

## The arrow keys: the picked walls move a snap step that way too (a whole cell with Shift)
func _nudge(d: Vector2, undo: bool) -> void:
	if not wsel_edges.is_empty():
		if undo: _push_undo()
		var step := 1.0 if Input.is_key_pressed(KEY_SHIFT) or not snap else SNAP_STEP
		wall_graph.translate(_sel_nodes(), d * step)
		_walls_changed()
		_mark_dirty()
		if _group().is_empty(): return
		undo = false
	super(d, undo)

func _duplicate_selected() -> void:
	if wsel_edges.is_empty():
		super()
		return
	_push_undo()
	var off := Vector2.ONE * (SNAP_STEP if snap else 0.25)
	var made: Array = []
	for w: Array in wall_graph.walls_of(wsel_edges, Vector2.ZERO):
		var props: Dictionary = (w[3] as Dictionary).duplicate(true)
		props["cells"] = []
		props["lock_len"] = false
		props["lock_ang"] = false
		made.append_array(wall_graph.add_wall((w[0] as Vector2) + off, (w[1] as Vector2) + off, w[2], props, WALL_TOL))
	wsel_edges = made
	_walls_changed()
	_mark_dirty()

## Ctrl+C without an area: the picked walls (and objects) go on the clipboard, Ctrl+V puts them at the mouse
func _copy() -> bool:
	if tool == "area" or wsel_edges.is_empty(): return super()
	var lo := Vector2(INF, INF)
	for n in _sel_nodes(): lo = lo.min(wall_graph.pos(n))
	for k in _group(): lo = lo.min(Vector2(objects[k].pos_x, objects[k].pos_y))
	lo = lo.floor()
	clip = {"size": Vector2i.ONE, "at": Vector2i(lo), "grid": null, "zones": {}, "paint": {}, "objects": [],
		"walls": wall_graph.walls_of(wsel_edges, lo)}
	for k in _group():
		if _is_stairs(str(objects[k].type)): continue
		var d: Dictionary = objects[k].duplicate(true)
		d.pos_x -= lo.x
		d.pos_y -= lo.y
		clip.objects.append(d)
	_status("Copied %d walls and %d objects. Ctrl+V pastes them at the mouse" % [clip.walls.size(), clip.objects.size()])
	return true

## Keys the walls take: F3 (show the graph) any time; a number typed while drawing or dragging; A (an arc next)
## and Enter (stop) while drawing
func _wall_key(k: InputEventKey) -> bool:
	if k.keycode == KEY_F3:
		wall_debug = not wall_debug
		canvas.queue_redraw()
		return true
	if _typed_key(k): return true
	if not _walls_tool(): return false
	match k.keycode:
		KEY_A:
			warc = not warc
			if not _arc_mode() and not wdraw.is_empty() and wdraw.stage == "bend": wdraw.stage = "end"
			_status("Next wall: " + ("an ARC (click its end, then bend it and click)" if _arc_mode() else "straight"))
			canvas.queue_redraw()
			return true
		KEY_ENTER, KEY_KP_ENTER:
			_wall_stop()
			return true
	return false

## Wall objects (a generated area's, a pasted or an old level's) become walls of the graph, joined to whatever
## they touch
func _walls_absorb() -> void:
	var before: Array = wall_graph.edges.keys()
	var kept: Array = wall_graph.absorb(objects, OBJ_INFO, grid_size, WALL_TOL)
	if kept.size() == objects.size(): return
	objects.clear()
	objects.append_array(kept)
	selected = -1
	multi = []
	hover_obj = -1
	wsel_edges = wall_graph.edges.keys().filter(func(e): return not before.has(e))
	_walls_changed()
	_sync_inspector()

func _object_release(at: Vector2, shift := false) -> void:
	super(at, shift)
	if drag == "": _walls_absorb()

func _end_spline() -> void:
	super()
	_walls_absorb()

# ---------------------------------------------------------------- the status line
func _walls_status() -> bool:
	if _walls_tool():
		var s := "WALL: " + ("drawing from %.1f, %.1f" % [wdraw.from.x, wdraw.from.y] if not wdraw.is_empty() else "click where it starts")
		if not wsnap.is_empty() and str(wsnap.kind) != "free": s += "   snap: " + str(SNAP_NAME.get(str(wsnap.kind), wsnap.kind))
		_status(s + ("   (next: ARC)" if _arc_mode() else ""))
		return true
	if tool != "select": return false
	if not whover_handle.is_empty() or (not wdrag.is_empty() and HANDLE_TIP.has(str(wdrag.kind))):
		var k := str(whover_handle.get("kind", wdrag.get("kind", "")))
		_status("Handle: drag to %s   type a number while dragging for an exact one" % HANDLE_TIP.get(k, k))
		return true
	if wdrag.get("kind", "") == "node" or whover_node >= 0:
		var n: int = wdrag.get("node", whover_node)
		if wall_graph.nodes.has(n):
			_status("Node %d: %d walls meet here   drag: move it (they follow; locked walls hold)   Del: delete it and its walls" % [n, wall_graph.degree(n)])
			return true
	var e: int = wdrag.get("edge", whover_edge)
	if e >= 0 and wall_graph.edges.has(e):
		_status("Wall %d: %s   click: pick   drag: move it   Del / right click: delete" % [e, _wall_text(e)])
		return true
	return false

func _hint_text() -> String:
	var always := "     Space / middle drag: move the map     wheel: zoom     Esc: cancel"
	if _walls_tool():
		if not wdraw.is_empty() and wdraw.stage == "bend": return "Move: bend the arc (it snaps straight, to a half circle, and tangent to the wall before)     type a radius + Enter     click: put it down     Alt: no snapping"
		if not wdraw.is_empty(): return "Click: end this wall and draw on     type 3.5 or 3.5,90 + Enter: exact length (m), angle     A: arc     double / right click, Enter: stop     Alt: no snapping"
		return "Click: start a wall     A: next one an arc     right click a wall: delete it     Alt: no snapping     F3: graph" + always
	if tool == "select" and (not wsel_edges.is_empty() or wsel_node >= 0):
		return "Handles: node, square (slide), diamond (bend), arrows (thickness), bar (height)     click a measurement to type it     arrows: nudge     Del: delete"
	return super()
