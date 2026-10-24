extends RefCounted
## The Entity marks a level carries (level editor objects of type "entity", object_types.json): one per monster
## placed by hand, each with a Kind and a Behavior (roam / lurk). Every monster that has AI reads its own kind's
## marks through here, the way the bacteria does (bacteria.gd _mark).

const CELL := 4.5

## The cells a monster kind is confined to (painted "area_<kind>" zone), {} when it has none
static func area(level: Node, kind: String) -> Dictionary:
	if level == null or not ("entity_areas" in level):
		return {}
	return level.entity_areas.get(kind, {})

## Every mark of `kind` on the floor `level` has built, in the order they were placed. A territory with no mark
## still places one: a roaming mark on the open cell in the middle of the territory
static func of_kind(level: Node, kind: String) -> Array:
	var out: Array = []
	if level == null:
		return out
	var objs = level.level_data.get("objects", [])
	if objs is Array:
		for o in objs:
			if o is Dictionary and o.get("type", "") == "entity" and str(o.get("kind", "bacteria")) == kind:
				out.append(o)
	if out.is_empty():
		var cells: Array = area(level, kind).keys().filter(func(c: Vector2i): return not level.walls.has(c) and not level.pits.has(c) and not level.safe.has(c))
		if not cells.is_empty():
			cells.sort_custom(func(a: Vector2i, b: Vector2i): return a.y < b.y or (a.y == b.y and a.x < b.x))
			var c: Vector2i = cells[cells.size() / 2]
			out.append({"type": "entity", "kind": kind, "behavior": "roam", "pos_x": float(c.x), "pos_y": float(c.y)})
	return out

static func cell(mark: Dictionary) -> Vector2i:
	return Vector2i(roundi(float(mark.get("pos_x", 0.0))), roundi(float(mark.get("pos_y", 0.0))))

## Where the mark stands in the world (y is left at 0: the monster finds its own floor)
static func world_pos(mark: Dictionary) -> Vector3:
	var c := cell(mark)
	return Vector3(c.x * CELL, 0.0, c.y * CELL)

static func lurks(mark: Dictionary) -> bool:
	return str(mark.get("behavior", "roam")) == "lurk"
