extends RefCounted
## WALLS, layer 4: the openings in the walls (wall_graph.gd "ops": doors, doorways, arches, windows) as holes for
## wall_mesh.gd to cut, and where the things that stand in them go. Pure, like the layers under it: the game, the
## level editor's 3D view and tools/test_walls.gd all use it.
##
## A hole runs along its wall's centre line from t0 to t1 (parameters) and up from y0 to y1 (metres off the floor),
## its sides square across the wall (on an arc: along the radius, so the jambs of an opening in a curved wall
## point at its centre, as a builder would cut them). `round`: its head is a half ellipse spanning its width,
## springing from its sides (an arch, an arched window), crowned at y1. A window onto the sky is cut through the
## room's face only, back to the other face (a deep recess the glass closes; from the other side there is no
## window), so `cut_l` / `cut_r` say which faces are cut. `solid`: the wall stays solid to walk into there (glass).

const Geom := preload("wall_geom.gd")

const LINTEL := 0.08                  # metres of wall kept over the head of an opening at least
const MIN_H := 0.25                   # metres: an opening lower than this isn't cut

## The holes of graph `g`'s walls: wall id -> [hole, ...]. `spans`: wall id -> Vector2(base, top) (metres), as
## wall_mesh.gd builds them.
static func holes_of(g, spans: Dictionary) -> Dictionary:
	var out := {}
	for e in g.edges:
		var ops: Array = g.ops_of(e)
		if ops.is_empty() or not spans.has(e): continue
		var sp: Vector2 = spans[e]
		var list: Array = []
		for i in ops.size():
			var op: Dictionary = ops[i]
			var kind := str(op.get("kind", ""))
			var s: Vector2 = g.op_span(e, op)
			var y0 := clampf(float(op.get("sill", 0.0)), sp.x, sp.y)
			var y1 := minf(y0 + float(op.get("h", 2.0)), sp.y - LINTEL)
			if y1 - y0 < MIN_H: continue
			var style := str(op.get("style", ""))
			var disc := kind == "window" and style == "porthole"
			if kind == "window" and style == "panorama":     # a wall of glass from near the floor to near the ceiling
				y0 = clampf(minf(y0, 0.6), sp.x, sp.y)
				y1 = maxf(y1, sp.y - 0.3)
			if disc:                                          # a porthole: as tall as it is wide
				var dia := minf(float(op.get("w", 1.0)), y1 - y0)
				var mid := (s.x + s.y) * 0.5
				var half := (s.y - s.x) * 0.5 * dia / maxf(float(op.get("w", 1.0)), 1e-6)
				s = Vector2(mid - half, mid + half)
				y1 = y0 + dia
			var sky := kind == "window" and str(op.get("glass", "sky")) == "sky"
			var side := str(op.get("side", "l"))
			list.append({"t0": s.x, "t1": s.y, "y0": y0, "y1": y1, "i": i, "op": op, "kind": kind, "w_m": float(op.get("w", 1.0)),
				"round": kind == "arch" or (kind == "window" and style == "arched") or disc, "disc": disc,
				"cut_l": not sky or side == "l", "cut_r": not sky or side == "r", "solid": kind == "window" or kind == "glazing"})
		if not list.is_empty(): out[e] = list
	return out

## The top of hole `h` at parameter t: y1 square across, or on its round head
static func top_at(h: Dictionary, t: float) -> float:
	if not h["round"]: return h.y1
	var half := (float(h.t1) - float(h.t0)) * 0.5
	var x := clampf((t - (float(h.t0) + float(h.t1)) * 0.5) / maxf(half, 1e-9), -1.0, 1.0)
	return spring_of(h) + (float(h.y1) - spring_of(h)) * sqrt(maxf(1.0 - x * x, 0.0))

## The bottom of hole `h` at parameter t: y0, or round under a porthole
static func bottom_at(h: Dictionary, t: float) -> float:
	if not h.get("disc", false): return h.y0
	var half := (float(h.t1) - float(h.t0)) * 0.5
	var x := clampf((t - (float(h.t0) + float(h.t1)) * 0.5) / maxf(half, 1e-9), -1.0, 1.0)
	return spring_of(h) - (spring_of(h) - float(h.y0)) * sqrt(maxf(1.0 - x * x, 0.0))

## Where a round head springs from its sides: half its width under its crown (no lower than its sill; a
## porthole's middle)
static func spring_of(h: Dictionary) -> float:
	if not h["round"]: return h.y1
	if h.get("disc", false): return (float(h.y0) + float(h.y1)) * 0.5
	return maxf(float(h.y0), float(h.y1) - float(h.w_m) * 0.5)

## Where the thing that stands in hole `h` of a wall with curve `cv` (metres) goes: its frame, origin on the centre
## line half way between its jambs (on an arc: on the chord between them) at the floor, +z along the wall from a
## to b, y up, +x across the wall to its right face (plan (x, y) is world (x, z), so the plan's left of a -> b,
## (-d.y, d.x), is the frame's -x)
static func frame_of(h: Dictionary, cv: Dictionary) -> Transform3D:
	var pa := Geom.point(cv, h.t0)
	var pb := Geom.point(cv, h.t1)
	var along := (pb - pa).normalized()
	var mid := (pa + pb) * 0.5
	var z := Vector3(along.x, 0.0, along.y)
	return Transform3D(Basis(Vector3.UP.cross(z), Vector3.UP, z), Vector3(mid.x, 0.0, mid.y))
