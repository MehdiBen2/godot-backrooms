extends RefCounted
## Tape and sketches kept on disk, per level, so they are still there next launch. <level id>.json holds
## {"tape": [...], "sketch": [...]}, one key per tool, so a level's .lvl is never touched by it. From the
## Godot editor or a level-editor test launch it goes in the project's levels/marks/; an exported game
## can't write res://, so there it goes in user://marks/.
##
## Marks are kept in world metres, but the level editor can move every cell (growing the map up / left,
## TRIM): the .lvl counts how far in "mark_shift" ([x, z] cells, level_editor_canvas.gd _reframe), and each
## key of a marks file remembers the shift it was written at ("shift": {key: [x, z]}), so loading moves the
## marks by the difference (moved()). Whatever is still off a surface after that (a wall drawn on was
## removed or moved) is snapped onto the nearest wall by settle().

const CELL := 4.5                    # m: level_data.gd's cell

static var shift := Vector2i.ZERO    # the loaded level's mark_shift (use_level())

## Only level-editor test launches save marks: there they are part of the level being built, and every
## run (exported or not) loads them with the level. What a player lays in a normal run is never saved.
static func active() -> bool:
	return Game.editor_test

## Marks belong to one floor of one level: the key the static lists are filed under (Net sends it as the
## strip's "level" too, so survivors on the same floor see each other's tape)
static func key(l: int = Game.level_index, f: int = Game.level_floor) -> int:
	return l * 1000 + (f + 500)

## The file name for the level's meta id on the floor being played (floor 0 keeps the plain id)
static func file_id(level_id: String, f: int = Game.level_floor) -> String:
	if level_id == "" or f == 0:
		return level_id
	return ("%s_b%d" % [level_id, -f]) if f < 0 else ("%s_f%d" % [level_id, f])

## Take the level's mark_shift; call before reading or writing its marks
static func use_level(level: Node) -> void:
	var raw = level.get("level_raw")
	var s = raw.get("mark_shift", [0, 0]) if raw is Dictionary else [0, 0]
	shift = Vector2i(int(s[0]), int(s[1])) if s is Array and s.size() >= 2 else Vector2i.ZERO

## How far the marks under `key` of the file read as `d` have to move to sit where they were drawn
static func moved(d: Dictionary, key: String) -> Vector3:
	var all = d.get("shift", {})
	var s = all.get(key, [0, 0]) if all is Dictionary else [0, 0]
	return Vector3(shift.x - int(s[0]), 0.0, shift.y - int(s[1])) * CELL

static func _path(id: String) -> String:
	if Game.editor_test or OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://levels/marks/%s.json" % id)
	return ProjectSettings.globalize_path("user://marks/%s.json" % id)

## The marks saved with the level. An exported game reads them from inside its .pck (res://), so
## the path is left unglobalized there.
static func read(id: String) -> Dictionary:
	if id == "":
		return {}
	var p := _path(id) if active() else "res://levels/marks/%s.json" % id
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null and id.contains("_b"):
		var alt := id.replace("_b", "_f-")
		f = FileAccess.open(_path(alt) if active() else "res://levels/marks/%s.json" % alt, FileAccess.READ)
	elif f == null and id.contains("_f-"):
		var alt := id.replace("_f-", "_b")
		f = FileAccess.open(_path(alt) if active() else "res://levels/marks/%s.json" % alt, FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	return d if d is Dictionary else {}

static func write(id: String, key: String, value: Array) -> bool:
	if not active() or id == "":
		return false
	var d := read(id)
	d[key] = value
	var at = d.get("shift", {})
	if not (at is Dictionary):
		at = {}
	at[key] = [shift.x, shift.y]
	d["shift"] = at
	DirAccess.make_dir_recursive_absolute(_path(id).get_base_dir())
	var f := FileAccess.open(_path(id), FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(d))
	return true

static func v3(a) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))

static func arr(v: Vector3) -> Array:
	return [snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001)]

# ---- snapping onto walls ------------------------------------------------------------------------
const SETTLE_REACH := 3.0            # m: how far a mark may be moved to find a wall
const ON_SURFACE := 0.7              # this share of a mark's points on a surface leaves it where it is
const WORLD_MASK := 1

## Points along the line `pts` (every one up to 24, evenly picked past that) to test the surface under
static func _probe_pts(pts: Array) -> Array:
	if pts.size() <= 24:
		return pts
	var out: Array = []
	for i in 24:
		out.append(pts[int(float(i) * (pts.size() - 1) / 23.0)])
	return out

## The share of `pts` with a surface facing `n` right under them
static func on_surface(space: PhysicsDirectSpaceState3D, pts: Array, n: Vector3) -> float:
	var probe := _probe_pts(pts)
	var hits := 0
	for p: Vector3 in probe:
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(p + n * 0.1, p - n * 0.1, WORLD_MASK))
		if not hit.is_empty() and (hit.normal as Vector3).dot(n) > 0.9:
			hits += 1
	return float(hits) / maxf(1.0, probe.size())

static func _inside(space: PhysicsDirectSpaceState3D, p: Vector3) -> bool:
	var q := PhysicsPointQueryParameters3D.new()
	q.position = p
	q.collision_mask = WORLD_MASK
	return not space.intersect_point(q, 1).is_empty()

## A mark that lost its surface (`pts` on a face with normal `n`), put back on the nearest wall: first slid
## straight along `n` (the wall moved forward or back, it keeps facing the same way), else turned onto
## whatever surface is closest round it. {"pts", "n", "moved"}; `moved` false if it was fine, {} if there
## is no surface within SETTLE_REACH.
static func settle(space: PhysicsDirectSpaceState3D, pts: Array, n: Vector3) -> Dictionary:
	if pts.is_empty():
		return {}
	if on_surface(space, pts, n) >= ON_SURFACE:
		return {"pts": pts, "n": n, "moved": false}
	var c := Vector3.ZERO
	for p: Vector3 in pts:
		c += p
	c /= pts.size()
	# slid along the normal: the nearest face that faces the same way, in front or behind
	var step := 0.1
	for k in range(0, int(SETTLE_REACH / step) + 1):
		for sgn in ([1.0] if k == 0 else [1.0, -1.0]):
			var o: Vector3 = c + n * (k * step * sgn)
			var from := o + n * (step * 0.5 + 0.02)
			if _inside(space, from):
				continue
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, o - n * (step * 0.5 + 0.02), WORLD_MASK))
			if hit.is_empty() or (hit.normal as Vector3).dot(n) < 0.9:
				continue
			var move := n * n.dot((hit.position as Vector3) - c)
			var slid: Array = []
			for p: Vector3 in pts:
				slid.append(p + move)
			if on_surface(space, slid, n) >= 0.5:
				return {"pts": slid, "n": n, "moved": true}
	# turned onto the closest wall round it; a mark on a floor or ceiling looks for one of those first
	var from_c := c + n * 0.05
	if _inside(space, from_c):
		return {}
	var walls: Array = []
	for i in 16:
		walls.append(Vector3.FORWARD.rotated(Vector3.UP, TAU * i / 16.0))
	var best := {}
	if absf(n.y) > 0.5:
		best = _closest(space, from_c, [Vector3.DOWN if n.y > 0.0 else Vector3.UP], true)
	if best.is_empty():
		best = _closest(space, from_c, walls, false)
	if best.is_empty():
		return {}
	var nn := (best.normal as Vector3).normalized()
	var turn := _turn(n, nn)
	var out: Array = []
	for p: Vector3 in pts:
		out.append((best.position as Vector3) + turn * (p - c))
	if on_surface(space, out, nn) < 0.3:
		return {}
	return {"pts": out, "n": nn, "moved": true}

## The nearest hit from `from` along any of `dirs` within SETTLE_REACH, on a floor / ceiling (`flat`) or a
## wall, or {}
static func _closest(space: PhysicsDirectSpaceState3D, from: Vector3, dirs: Array, flat: bool) -> Dictionary:
	var best := {}
	var best_d := INF
	for dir: Vector3 in dirs:
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + dir * SETTLE_REACH, WORLD_MASK))
		if hit.is_empty() or (absf((hit.normal as Vector3).y) > 0.8) != flat:
			continue
		var d := from.distance_to(hit.position)
		if d < best_d:
			best_d = d
			best = hit
	return best

## The turn taking the face normal `a` onto `b`, keeping a wall line upright where it can
static func _turn(a: Vector3, b: Vector3) -> Basis:
	if a.dot(b) > 0.9999:
		return Basis.IDENTITY
	if a.dot(b) < -0.9999:
		var axis := Vector3.UP if absf(a.y) < 0.9 else Vector3.RIGHT
		return Basis(axis, PI)
	if absf(a.y) < 0.5 and absf(b.y) < 0.5:
		# wall to wall: round the vertical only, so writing stays level
		var fa := Vector2(a.x, a.z).normalized()
		var fb := Vector2(b.x, b.z).normalized()
		return Basis(Vector3.UP, -fa.angle_to(fb))
	return Basis(Quaternion(a, b))
