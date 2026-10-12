extends RefCounted
## Where a model-only entity that doesn't stand on the floor goes (entity_roster.gd MOUNTS, model_entity.gd mount),
## worked out on the built floor itself, so its mark only has to be near the spot:
##   "wall": flat on the nearest wall, its back on the face, its middle at FACE_H, looking out. Along the mark's
##            arrow first, so the arrow picks the wall when two are as near. Nothing in reach: it isn't placed.
##   "prop": sat on the best free top of the nearest prop (a table, a shelf, a chair's seat, a draped sculpture),
##            found by probing the prop's real meshes from above, not its box (a chair's box reaches its back): the
##            highest flat patch wide enough for it, with headroom, clear of the heads already sat there, in the
##            middle of that patch. Then turned to look the most open way, give or take a little.

const IndustrialProp := preload("res://scripts/World/props/industrial_prop.gd")
const Door := preload("res://scripts/World/props/door.gd")

const FACE_H := 1.65           # m: a wall face's middle, over the mark's floor
const WALL_REACH := 4.5        # m from the mark (a cell) to look for a wall in
const DEBUG_REACH := 12        # m: the debug console's, from the player along their look
const PROP_REACH := 6.0        # m from the mark to a prop's edge
const FLAT := 0.025            # m: how far a patch's probes may differ in height and still be flat
const MAX_PROBES := 40         # per side of a prop's top
const LOOK := 12.0             # m: how far a head looks to find the open way

static var _tris := {}         # Mesh -> its TriangleMesh, built once

# ---------------------------------------------------------------- wall
static func on_wall(m: Node3D, at: Vector3, arrow: Vector3, reach: float) -> bool:
	var space := m.get_world_3d().direct_space_state
	var eye := at + Vector3.UP * FACE_H
	var own := _rids(m)
	var best := {}
	if arrow != Vector3.ZERO:
		best = _wall_ray(space, eye, eye + arrow * reach, own)
	if best.is_empty():
		for i in 16:
			var hit := _wall_ray(space, eye, eye + Vector3.FORWARD.rotated(Vector3.UP, TAU * i / 16.0) * reach, own)
			if not hit.is_empty() and (best.is_empty() or eye.distance_to(hit.position) < eye.distance_to(best.position)):
				best = hit
	if best.is_empty(): return false
	var n: Vector3 = best.normal
	n = Vector3(n.x, 0.0, n.z).normalized()
	var box: AABB = m.local_box()
	var basis := Basis(Vector3.UP, atan2(n.x, n.z))               # its front (+Z) out of the wall
	var pos: Vector3 = best.position - n * (box.position.z - 0.003)
	pos.y = at.y + FACE_H - (box.position.y + box.size.y * 0.5)
	m.global_transform = Transform3D(basis, pos)
	return true

## A ray to the first wall: {} if it reaches none, or a floor / slope first. Props, doors, other models and
## anyone walking about are looked through.
static func _wall_ray(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3, exclude: Array[RID]) -> Dictionary:
	var ex := exclude.duplicate()
	for _i in 8:
		var q := PhysicsRayQueryParameters3D.create(from, to)
		q.exclude = ex
		var hit := space.intersect_ray(q)
		if hit.is_empty(): return {}
		if _see_through(hit.collider):
			ex.append(hit.rid)
			continue
		return hit if absf((hit.normal as Vector3).y) < 0.3 else {}
	return {}

static func _see_through(c: Object) -> bool:
	if c is CharacterBody3D or c is RigidBody3D: return true
	var n := c as Node
	while n != null:
		var sc: Script = n.get_script()
		if sc == IndustrialProp or sc == Door or n.has_method("local_box"): return true
		n = n.get_parent()
	return false

# ---------------------------------------------------------------- prop
static func on_prop(m: Node3D, level: Node, at: Vector3) -> bool:
	if level == null: return false
	var box: AABB = m.local_box()
	if box.size == Vector3.ZERO: return false
	var r := minf(box.size.x, box.size.z) * 0.3          # what it stands on: narrower than its widest part
	var apart := maxf(box.size.x, box.size.z) + 0.04      # centre to centre from another head: never touching
	var taken: Array = []                                  # where the other heads already sit
	var cands: Array = []
	for c in level.get_children():
		if c == m or not (c is Node3D): continue
		if c.has_method("local_box"):
			if c.get("mount") == "prop":
				if c.get("settled"): taken.append((c as Node3D).global_position)
				continue
			if not c.get("present"): continue
		elif c.get_script() != IndustrialProp:
			continue
		var wb := _world_box(c)
		if wb.size == Vector3.ZERO: continue
		var gap := Vector2(wb.get_center().x - at.x, wb.get_center().z - at.z).length() - maxf(wb.size.x, wb.size.z) * 0.5
		if gap <= PROP_REACH: cands.append([gap, c, wb])
	cands.sort_custom(func(a, b): return a[0] < b[0])
	var space := m.get_world_3d().direct_space_state
	for cd: Array in cands:
		var skip := _rids(m)
		skip.append_array(_rids(cd[1]))
		var seat := _seat(cd[1], cd[2], r, apart, box.size.y, taken, space, skip)
		if seat == Vector3.INF: continue
		var way := _open_way(space, seat + Vector3.UP * box.size.y * 0.5, skip)
		var wobble := (fposmod(seat.x * 12.9898 + seat.z * 78.233, 1.0) - 0.5) * 0.4     # (the same each run)
		m.global_transform = Transform3D(Basis(Vector3.UP, atan2(way.x, way.z) + wobble), seat + Vector3.UP * 0.002)
		return true
	return false

## The best free spot on `prop`'s top for something `r` wide at its base, `h` tall and kept `apart` from the
## `taken` spots, INF if there is none
static func _seat(prop: Node3D, wb: AABB, r: float, apart: float, h: float, taken: Array, space: PhysicsDirectSpaceState3D, skip: Array[RID]) -> Vector3:
	var meshes: Array = []
	for n in prop.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or not mi.is_visible_in_tree() or mi.skin != null: continue
		if not _tris.has(mi.mesh): _tris[mi.mesh] = mi.mesh.generate_triangle_mesh()
		if _tris[mi.mesh] == null: continue
		meshes.append([mi.global_transform, mi.global_transform.affine_inverse(), _tris[mi.mesh]])
	if meshes.is_empty(): return Vector3.INF
	var nx := clampi(ceili(wb.size.x / 0.05), 2, MAX_PROBES)
	var nz := clampi(ceili(wb.size.z / 0.05), 2, MAX_PROBES)
	var sx := wb.size.x / nx
	var sz := wb.size.z / nz
	# straight down onto it from above, probe by probe: the first surface each meets (NAN: none, or not level)
	var tops := PackedFloat32Array()
	tops.resize(nx * nz)
	var top_y := wb.end.y + 0.5
	for iz in nz:
		for ix in nx:
			var from := Vector3(wb.position.x + (ix + 0.5) * sx, top_y, wb.position.z + (iz + 0.5) * sz)
			var y := -INF
			var level_ok := false
			for t: Array in meshes:
				var inv: Transform3D = t[1]
				var hit: Dictionary = (t[2] as TriangleMesh).intersect_ray(inv * from, inv.basis * Vector3.DOWN)
				if hit.is_empty(): continue
				var xf: Transform3D = t[0]
				var p: Vector3 = xf * (hit.position as Vector3)
				if p.y > y:
					y = p.y
					level_ok = absf((xf.basis.inverse().transposed() * (hit.normal as Vector3)).normalized().y) > 0.9
			tops[iz * nx + ix] = y if level_ok else NAN
	# a seat: a probe whose neighbours out to r all met the same level surface
	var kx := ceili(r / sx)
	var kz := ceili(r / sz)
	var seats: Array = []
	for iz in range(kz, nz - kz):
		for ix in range(kx, nx - kx):
			var y0 := tops[iz * nx + ix]
			if is_nan(y0): continue
			var flat := true
			for dz in range(-kz, kz + 1):
				for dx in range(-kx, kx + 1):
					if Vector2(dx * sx, dz * sz).length() > r: continue
					var y1 := tops[(iz + dz) * nx + ix + dx]
					if is_nan(y1) or absf(y1 - y0) > FLAT:
						flat = false
						break
				if not flat: break
			if not flat: continue
			var p := Vector3(wb.position.x + (ix + 0.5) * sx, y0, wb.position.z + (iz + 0.5) * sz)
			var free := true
			for q: Vector3 in taken:
				if Vector2(q.x - p.x, q.z - p.z).length() < apart:
					free = false
					break
			if free: seats.append(p)
	if seats.is_empty(): return Vector3.INF
	# the highest level first (a table's top over its stretchers, a shelf's top over the floor under it), and on it
	# the middle of the free patch
	var layers := {}
	for p: Vector3 in seats:
		var k := snappedf(p.y, FLAT * 2.0)
		if not layers.has(k): layers[k] = []
		layers[k].append(p)
	var keys := layers.keys()
	keys.sort()
	keys.reverse()
	for k in keys:
		var ps: Array = layers[k]
		var mid := Vector3.ZERO
		for p: Vector3 in ps: mid += p
		mid /= ps.size()
		ps.sort_custom(func(a: Vector3, b: Vector3): return Vector2(a.x - mid.x, a.z - mid.z).length() < Vector2(b.x - mid.x, b.z - mid.z).length())
		for p: Vector3 in ps.slice(0, 6):
			var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.03, p + Vector3.UP * h)
			q.exclude = skip
			if space.intersect_ray(q).is_empty(): return p
	return Vector3.INF

## The way that looks furthest before something is in it, of eight
static func _open_way(space: PhysicsDirectSpaceState3D, from: Vector3, skip: Array[RID]) -> Vector3:
	var best := Vector3.FORWARD
	var far := -1.0
	for i in 8:
		var d := Vector3.FORWARD.rotated(Vector3.UP, TAU * i / 8.0)
		var q := PhysicsRayQueryParameters3D.create(from, from + d * LOOK)
		q.exclude = skip
		var hit := space.intersect_ray(q)
		var dist := LOOK if hit.is_empty() else from.distance_to(hit.position)
		if dist > far + 0.01:
			far = dist
			best = d
	return best

## `n`'s meshes' box in the world
static func _world_box(n: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for c in n.find_children("*", "MeshInstance3D", true, false):
		var mi := c as MeshInstance3D
		if mi.mesh == null: continue
		var b := mi.global_transform * mi.get_aabb()
		out = b if first else out.merge(b)
		first = false
	return out

## The colliders under `n`, to look past
static func _rids(n: Node) -> Array[RID]:
	var out: Array[RID] = []
	for c in n.find_children("*", "CollisionObject3D", true, false):
		out.append((c as CollisionObject3D).get_rid())
	return out
