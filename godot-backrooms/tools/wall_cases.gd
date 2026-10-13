extends RefCounted
## The wall-graph test scenes (tools/test_walls.gd checks them, tools/shot_walls.gd photographs them, and
## tools/make_wall_test_level.gd lays them out as a level to walk round and edit). Each builds a WallGraph in
## cells, from (0, 0), the way the level editor would: add_wall() for every wall drawn, so T and X junctions are
## found the same way. "loops": how many closed outlines the walls' feet must make (one per joined-up run of
## walls, plus one per room they close in): a gap or an overlap anywhere breaks or adds one.

const WallGraph := preload("res://scripts/World/level/walls/wall_graph.gd")
const Geom := preload("res://scripts/World/level/walls/wall_geom.gd")
const TOL := 0.1 / 4.5

static func t(thick := 0.3, h := 0.0) -> Dictionary:
	return {"tl": thick * 0.5, "tr": thick * 0.5, "h": h}

## An arc from a to b sweeping `deg` degrees (+ anticlockwise in the maths frame)
static func arc(g, a: Vector2, b: Vector2, deg: float, props := t()) -> Array:
	return g.add_wall(a, b, Geom.sagitta_of(a, b, deg_to_rad(deg)), props, TOL)

static func line(g, a: Vector2, b: Vector2, props := t()) -> Array:
	return g.add_wall(a, b, 0.0, props, TOL)

static func cases() -> Array:
	var out: Array = []
	var g

	g = WallGraph.new()
	line(g, Vector2(0, 0), Vector2(2, 0))
	line(g, Vector2(2, 0), Vector2(2, 2))
	line(g, Vector2(0, 3), Vector2(2, 3))            # and a sharp one (30 degrees): its outside corner is bevelled
	line(g, Vector2(2, 3), Vector2(2, 3) + Vector2.from_angle(deg_to_rad(150.0)) * 2.0)
	out.append({"name": "L join", "g": g, "loops": 2, "nodes": 6, "edges": 4})

	g = WallGraph.new()
	line(g, Vector2(0, 0), Vector2(4, 0))
	line(g, Vector2(2, 2), Vector2(2, 0))            # ends on the first wall: splits it
	out.append({"name": "T join", "g": g, "loops": 1, "nodes": 4, "edges": 3})

	g = WallGraph.new()
	line(g, Vector2(0, 1), Vector2(4, 1))
	line(g, Vector2(2, -1), Vector2(2, 3))           # crosses it: both split
	line(g, Vector2(6, 0), Vector2(6, 3))            # five walls into one node, all different angles
	for deg: float in [10.0, 80.0, 200.0]:
		line(g, Vector2(6, 1.5), Vector2(6, 1.5) + Vector2.from_angle(deg_to_rad(deg)) * 1.6)
	out.append({"name": "X and 5-way join", "g": g, "loops": 2, "nodes": 11, "edges": 9})

	g = WallGraph.new()
	# a quarter circle carrying straight on out of both ends (tangent), and one wall leaving it at an angle
	arc(g, Vector2(0, 0), Vector2(2, 2), 90.0)
	line(g, Vector2(-2, 0), Vector2(0, 0))
	line(g, Vector2(2, 2), Vector2(2, 4))
	line(g, Vector2(0, 0), Vector2(-1, -1.5))
	out.append({"name": "arc into straight", "g": g, "loops": 1, "nodes": 5, "edges": 4})

	g = WallGraph.new()
	arc(g, Vector2(0, 0), Vector2(2, 0), -70.0)      # two arcs meeting at an angle
	arc(g, Vector2(2, 0), Vector2(4, 0), -70.0)
	arc(g, Vector2(0, 3), Vector2(2, 3), -60.0)      # an S: tangent, curving the other way
	arc(g, Vector2(2, 3), Vector2(4, 3), 60.0)
	arc(g, Vector2(6, 0), Vector2(8, 0), 180.0)      # a round room from two half circles
	arc(g, Vector2(8, 0), Vector2(6, 0), 180.0)
	out.append({"name": "arc into arc", "g": g, "loops": 4, "nodes": 8, "edges": 6})

	g = WallGraph.new()
	arc(g, Vector2(0, 0), Vector2(4, 0), -100.0)
	var top: Vector2 = Geom.point(Geom.curve(Vector2(0, 0), Vector2(4, 0), Geom.sagitta_of(Vector2(0, 0), Vector2(4, 0), deg_to_rad(-100.0))), 0.5)
	line(g, top + Vector2(0, 2), top)                # out of the middle of the arc (a T on a curve)
	var q: Vector2 = Geom.point(Geom.curve(Vector2(0, 0), Vector2(4, 0), Geom.sagitta_of(Vector2(0, 0), Vector2(4, 0), deg_to_rad(-100.0))), 0.25)
	line(g, q, Vector2(q.x + 0.4, -0.2))              # and into its hollow from further round
	out.append({"name": "arc T-junction", "g": g, "loops": 1, "nodes": 6, "edges": 5})

	g = WallGraph.new()
	line(g, Vector2(0, 0), Vector2(2, 0), t(0.3))
	line(g, Vector2(2, 0), Vector2(2, 2), t(0.8))    # an L, thin into thick
	line(g, Vector2(4, 0), Vector2(8, 0), t(0.8))
	line(g, Vector2(6, 2), Vector2(6, 0), t(0.15))   # a thin T into a thick wall
	line(g, Vector2(0, 4), Vector2(2, 4), t(0.3))
	line(g, Vector2(2, 4), Vector2(4, 4), t(0.8))    # straight on, stepping out
	var off := {"tl": 0.1, "tr": 0.5, "h": 0.0}      # off-centre: more to the right than the left
	line(g, Vector2(5, 4), Vector2(7, 4), off)
	arc(g, Vector2(7, 4), Vector2(8, 6), -60.0, t(0.5))
	out.append({"name": "mixed thickness", "g": g, "loops": 4, "nodes": 13, "edges": 9})

	g = WallGraph.new()
	line(g, Vector2(0, 0), Vector2(4, 0))
	line(g, Vector2(2, 2), Vector2(2, 0), t(0.3, 1.25))   # a half wall into a full one
	line(g, Vector2(6, 0), Vector2(6, 2), t(0.3, 1.25))
	line(g, Vector2(6, 2), Vector2(8, 2))                 # an L, low into tall
	line(g, Vector2(0, 4), Vector2(2, 4), t(0.3, 2.5))
	line(g, Vector2(2, 4), Vector2(4, 4), t(0.3, 1.0))    # straight on, stepping down
	line(g, Vector2(6, 4), Vector2(8, 4), t(0.3, 1.25))
	line(g, Vector2(7, 3), Vector2(7, 4))                 # a tall wall ending on a low one
	var lifted := t(0.3, 3.0)
	lifted["base"] = 2.2                                  # a bulkhead hanging off the ceiling, across a low wall
	line(g, Vector2(9, 3), Vector2(9, 5), lifted)
	line(g, Vector2(9, 4), Vector2(11, 4), t(0.3, 1.25))
	out.append({"name": "mixed height", "g": g, "loops": 5, "nodes": 18, "edges": 13})

	g = WallGraph.new()
	line(g, Vector2(0, 1), Vector2(4, 1))
	line(g, Vector2(2, -1), Vector2(2, 3))
	arc(g, Vector2(6, 1), Vector2(10, 1), -40.0)          # and a four-way node on an arc
	line(g, Vector2(8, -1), Vector2(8, 3))
	var mid: int = g.node_near(Vector2(2, 1), 0.01)
	g.move_node(mid, Vector2(2.7, 1.6))                   # moved: every wall on it follows, arcs too
	var mid2 := -1
	for n in g.nodes:
		if g.degree(n) == 4 and n != mid: mid2 = n
	g.move_node(mid2, g.pos(mid2) + Vector2(-0.5, 0.4))
	out.append({"name": "moving a 4-way node", "g": g, "loops": 2, "nodes": 10, "edges": 8, "moved": [mid, mid2]})

	g = WallGraph.new()
	line(g, Vector2(0, 0), Vector2(4, 0))
	line(g, Vector2(4, 0), Vector2(4, 3))
	arc(g, Vector2(4, 3), Vector2(0, 3), 50.0)
	line(g, Vector2(0, 3), Vector2(0, 0))
	var div := line(g, Vector2(2, 0), Vector2(2, 3.45))   # a divider from wall to wall: two rooms
	var before: int = g.edges.size()
	g.delete_edge(div[0])                                 # taken out again: one room, the walls it split joined up
	out.append({"name": "deleting a wall in a loop", "g": g, "loops": 2, "nodes": 4, "edges": 4, "before": before})
	return out
