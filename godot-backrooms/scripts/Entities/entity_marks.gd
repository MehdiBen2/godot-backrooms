extends RefCounted
## The Entity marks a level carries (level editor objects of type "entity", object_types.json): one per monster
## placed by hand, each with a Kind and a Behavior (roam / lurk). Every monster that has AI reads its own kind's
## marks through here, the way the bacteria does (bacteria.gd _mark).

const CELL := 4.5

## Every mark of `kind` on the floor `level` has built, in the order they were placed
static func of_kind(level: Node, kind: String) -> Array:
	var out: Array = []
	if level == null:
		return out
	var objs = level.level_data.get("objects", [])
	if objs is Array:
		for o in objs:
			if o is Dictionary and o.get("type", "") == "entity" and str(o.get("kind", "bacteria")) == kind:
				out.append(o)
	return out

static func cell(mark: Dictionary) -> Vector2i:
	return Vector2i(roundi(float(mark.get("pos_x", 0.0))), roundi(float(mark.get("pos_y", 0.0))))

## Where the mark stands in the world (y is left at 0: the monster finds its own floor)
static func world_pos(mark: Dictionary) -> Vector3:
	var c := cell(mark)
	return Vector3(c.x * CELL, 0.0, c.y * CELL)

static func lurks(mark: Dictionary) -> bool:
	return str(mark.get("behavior", "roam")) == "lurk"
