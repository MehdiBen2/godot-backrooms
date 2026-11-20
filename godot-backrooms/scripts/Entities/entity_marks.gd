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

## Every hand-placed mark of this kind on the current floor, in placement order.
static func placed(level: Node, kind: String) -> Array:
	var out: Array = []
	if level == null:
		return out
	var objs = level.level_data.get("objects", [])
	if objs is Array:
		for o in objs:
			if o is Dictionary and o.get("type", "") == "entity" and str(o.get("kind", "bacteria")) == kind:
				out.append(o)
	return out

## The marks a monster starts from. Only a placed mark spawns it: a painted "area_<kind>" territory without one
## only says where it may go, it brings nothing in.
static func of_kind(level: Node, kind: String) -> Array:
	return placed(level, kind)

static func cell(mark: Dictionary) -> Vector2i:
	return Vector2i(roundi(float(mark.get("pos_x", 0.0))), roundi(float(mark.get("pos_y", 0.0))))

## Where the mark stands in the world (y is left at 0: the monster finds its own floor)
static func world_pos(mark: Dictionary) -> Vector3:
	var c := cell(mark)
	return Vector3(c.x * CELL, 0.0, c.y * CELL)

static func lurks(mark: Dictionary) -> bool:
	return str(mark.get("behavior", "roam")) == "lurk"
