extends "res://scripts/World/level/level_geometry.gd"
## THE LEVEL, layer 2b: what an office's walls wear once it has been lived in. All built once from the grid
## and the placed walls when the floor loads (_build_trim, after the walls and objects):
##   - skirting: a vinyl cove base along the foot of every wall, pillar and thin wall (the dark rubber strip
##     every commercial building has), mitred round the corners;
##   - outlets and light switches: a socket low on the odd wall, a switch beside the odd way through;
##   - wear: rubber scuffs and kick marks low on the walls, grey hand marks round the switches and on the
##     corners people round.

# ---------------------------------------------------------------- the wall faces
## One per side of an open cell that a solid wall block stands against: {c: the open cell, n: towards the wall,
## t: along the face, ends: [at -t, at +t]}, an end being how the wall carries on there: END_ON (straight on),
## END_IN (into a corner, the next wall coming at you), END_OUT (round an outside corner: the wall ends, a way
## through or a room beyond).
const END_ON := 0
const END_IN := 1
const END_OUT := 2
var _faces: Array = []

func _wall_faces() -> Array:
	var out: Array = []
	for x in range(1, size - 1):
		for z in range(1, size - 1):
			var c := Vector2i(x, z)
			if _block_at(c) or pits.has(c) or stair_cells.has(c) or arch_cells.has(c): continue
			if not crop.is_empty() and not crop.has(c): continue
			if edge_wrap and wrap_ring.has(c): continue
			for n: Vector2i in DIRS:
				if not _block_at(c + n): continue
				if edge_wrap and wrap_ring.has(c + n): continue          # (the copy beyond the seam draws that one)
				var t := Vector2i(-n.y, n.x)
				var ends := []
				for s: Vector2i in [-t, t]:
					if _block_at(c + s): ends.append(END_IN)
					elif _block_at(c + s + n): ends.append(END_ON)
					else: ends.append(END_OUT)
				out.append({"c": c, "n": n, "t": t, "ends": ends})
	return out

## Where face `f` is: the middle of it on the floor (world), its normal out into the room, and along it
func _face_frame(f: Dictionary) -> Array:
	var c: Vector2i = f.c
	var n: Vector2i = f.n
	var t: Vector2i = f.t
	var at := Vector3((c.x + n.x * 0.5) * CELL, 0.0, (c.y + n.y * 0.5) * CELL)
	return [at, Vector3(-n.x, 0.0, -n.y), Vector3(t.x, 0.0, t.y)]

## The placed walls, pillars and columns (level_data.gd `objects`) as floor-plan outlines (world): the faces
## above only know the grid, so a thin wall butting onto a grid wall is invisible to them, and a switch or a
## stain put there would sit half inside it. [outline, solid] (solid: the outline's inside is wall too; a round
## room's two rings are not, the room is inside them).
var _obstacles: Array = []

func _gather_obstacles() -> void:
	_obstacles.clear()
	for o: Dictionary in objects:
		var outlines := _object_outlines(o)
		var xf := object_transform(o)
		for outline: Array in outlines:
			var poly := PackedVector2Array()
			for p: Vector2 in outline[0]:
				var w := xf * Vector3(p.x, 0.0, p.y)
				poly.append(Vector2(w.x, w.z))
			_obstacles.append([poly, outlines.size() == 1])

## True when floor-plan point `p` (world) is at least `margin` metres clear of every placed wall, pillar and column
func _clear_of_objects(p: Vector3, margin: float) -> bool:
	var q := Vector2(p.x, p.z)
	for ob: Array in _obstacles:
		var poly: PackedVector2Array = ob[0]
		if ob[1] and Geometry2D.is_point_in_polygon(q, poly): return false
		for i in poly.size():
			if Geometry2D.get_closest_point_to_segment(q, poly[i], poly[(i + 1) % poly.size()]).distance_to(q) < margin:
				return false
	return true

## A basis standing on the wall: +Z out of it into the room, +Y up, +X along it
static func _on_wall(out: Vector3) -> Basis:
	return Basis(Vector3.UP.cross(out), Vector3.UP, out)

func _build_trim() -> void:
	_faces = _wall_faces()
	_gather_obstacles()
	_build_skirting()
	var switches := _build_fittings()
	_build_wall_wear(switches)
	_build_damp()

# ---------------------------------------------------------------- skirting
# A vinyl cove base, in cross-section from its top edge against the wall down to its toe on the carpet
# (x: out from the wall, y: up; metres): 10 cm tall, a few millimetres thick, a rounded top edge, and the cove
# that curls out at the foot so a mop can't catch it.
const SKIRT := [Vector2(0.0, 0.102), Vector2(0.0025, 0.1015), Vector2(0.0041, 0.0998), Vector2(0.0046, 0.0965),
	Vector2(0.0046, 0.019), Vector2(0.0056, 0.0115), Vector2(0.0081, 0.0052), Vector2(0.0118, 0.0014), Vector2(0.0146, 0.0)]
var _skirt_normals: Array[Vector2] = []
const MITRE := [0.0, -1.0, 1.0]     # by end (END_ON, END_IN, END_OUT): how far along the wall a vertex at depth d moves, times d

func _build_skirting() -> void:
	_skirt_normals.clear()
	for i in SKIRT.size():
		var a: Vector2 = SKIRT[maxi(i - 1, 0)]
		var b: Vector2 = SKIRT[mini(i + 1, SKIRT.size() - 1)]
		var d := (b - a).normalized()
		_skirt_normals.append(Vector2(-d.y, d.x))      # (out of the wall and up: the profile runs top to toe)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false
	# the maze's walls, a face at a time: its ends cut square where the wall runs straight on, mitred into an
	# inside corner, and mitred round an outside one (the vertex at depth d moves d along the wall)
	for f: Dictionary in _faces:
		var fr := _face_frame(f)
		var mid: Vector3 = fr[0]
		var out: Vector3 = fr[1]
		var along: Vector3 = fr[2]
		var a := mid - along * (CELL * 0.5)
		var b := mid + along * (CELL * 0.5)
		var sa: float = MITRE[f.ends[0]]
		var sb: float = MITRE[f.ends[1]]
		_skirt_run(st, [a, b], [out - along * sa, out + along * sb], [out, out], [out, out], false)
		any = true
	# placed walls, pillars and columns: round the outline of each
	for o: Dictionary in objects:
		for outline: Array in _object_outlines(o):
			_skirt_loop(st, outline[0], object_transform(o), outline[1])
			any = true
	if not any: return
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _skirt_material()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF      # (a centimetre proud of the wall)
	add_child(mi)

## One strip of skirting along `pts` (world, on the floor at the wall's face). `miter[i]`: where a vertex at
## depth d sits, as pts[i] + miter[i] * d. `face_in[i]` / `face_out[i]`: the wall's outward normal at pts[i] for
## the run arriving there / leaving it (the same on a curve, the two faces' own at a corner: no smeared shading).
func _skirt_run(st: SurfaceTool, pts: Array, miter: Array, face_in: Array, face_out: Array, closed: bool) -> void:
	var n := pts.size()
	var segs := n if closed else n - 1
	for i in segs:
		var j := (i + 1) % n
		var fi: Vector3 = face_out[i]
		var fj: Vector3 = face_in[j]
		var pi: Vector3 = pts[i]
		var pj: Vector3 = pts[j]
		var mi: Vector3 = miter[i]
		var mj: Vector3 = miter[j]
		for k in SKIRT.size() - 1:
			var p0: Vector2 = SKIRT[k]
			var p1: Vector2 = SKIRT[k + 1]
			var n0: Vector2 = _skirt_normals[k]
			var n1: Vector2 = _skirt_normals[k + 1]
			var v := [pi + mi * p0.x + Vector3(0, p0.y, 0), pj + mj * p0.x + Vector3(0, p0.y, 0),
				pj + mj * p1.x + Vector3(0, p1.y, 0), pi + mi * p1.x + Vector3(0, p1.y, 0)]
			var nm := [fi * n0.x + Vector3.UP * n0.y, fj * n0.x + Vector3.UP * n0.y,
				fj * n1.x + Vector3.UP * n1.y, fi * n1.x + Vector3.UP * n1.y]
			_quad(st, v, nm, ((nm[0] as Vector3) + (nm[2] as Vector3)).normalized())

## Skirting right round a closed outline `pts` (object space, on the floor, wound either way): outside it, or
## inside it (`inward`: the inner face of a round room's wall)
func _skirt_loop(st: SurfaceTool, pts: Array, xf: Transform3D, inward: bool) -> void:
	var n := pts.size()
	if n < 3: return
	var area := 0.0
	for i in n:
		var p: Vector2 = pts[i]
		var q: Vector2 = pts[(i + 1) % n]
		area += p.x * q.y - q.x * p.y
	var sgn := (1.0 if area > 0.0 else -1.0) * (-1.0 if inward else 1.0)
	var side: Array[Vector2] = []                # each edge's normal, the side the skirting goes
	for i in n:
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[(i + 1) % n]
		var d := (b - a).normalized()
		side.append(Vector2(d.y, -d.x) * sgn)
	var at: Array = []
	var miter: Array = []
	var face_in: Array = []
	var face_out: Array = []
	for i in n:
		var before: Vector2 = side[(i - 1 + n) % n]
		var after: Vector2 = side[i]
		var m := (before + after).normalized()
		var off := m / maxf(m.dot(after), 0.3)
		var p: Vector2 = pts[i]
		at.append(xf * Vector3(p.x, 0.0, p.y))
		miter.append(xf.basis * Vector3(off.x, 0.0, off.y))
		var smooth := before.dot(after) > 0.85            # under ~30 degrees: part of a curve
		face_in.append(xf.basis * Vector3(m.x, 0.0, m.y) if smooth else xf.basis * Vector3(before.x, 0.0, before.y))
		face_out.append(xf.basis * Vector3(m.x, 0.0, m.y) if smooth else xf.basis * Vector3(after.x, 0.0, after.y))
	_skirt_run(st, at, miter, face_in, face_out, true)

## The plan outlines (object space, metres) a placed wall, pillar or column stands on, as [points, inward]: what
## its skirting runs round. Doors, arches and everything else: none (a door's frame meets the floor itself).
func _object_outlines(o: Dictionary) -> Array:
	if o.type == "squeeze_gap":              # the two jambs either side of the slit
		var half := CELL * 0.5
		var g := clampf(float(o.get("gap", 0.55)), 0.35, 0.9) * 0.5
		return [[[Vector2(-half, -half), Vector2(half, -half), Vector2(half, -g), Vector2(-half, -g)], false],
			[[Vector2(-half, g), Vector2(half, g), Vector2(half, half), Vector2(-half, half)], false]]
	if o.type in ["door", "arch"] or is_stairs(o.type): return []
	var info := object_info(o.type)
	if info.has("model"): return []
	match str(info.get("shape", "")):
		"pillar":
			var h := object_thick(o) * 0.5
			return [[[Vector2(-h, -h), Vector2(h, -h), Vector2(h, h), Vector2(-h, h)], false]]
		"column":
			var r := object_thick(o) * 0.5
			var ring: Array = []
			for i in 24: ring.append(Vector2.from_angle(TAU * i / 24.0) * r)
			return [[ring, false]]
		"slab", "corner", "arc":
			var path := shape_path(o)
			if path.size() < 2: return []
			var p: Array[Vector2] = []
			for v in path: p.append(v * CELL)
			var closed := p.size() > 2 and p[0].distance_to(p[-1]) < 0.01
			if closed: p.remove_at(p.size() - 1)
			var n := p.size()
			var segs := n if closed else n - 1
			var side: Array[Vector2] = []
			for i in segs:
				var d := (p[(i + 1) % n] - p[i]).normalized()
				side.append(Vector2(-d.y, d.x))
			var half := object_thick(o) * 0.5
			var left: Array = []
			var right: Array = []
			for i in n:            # (the same mitred faces as level_geometry.gd _sweep_wall)
				var before: Vector2 = side[(i - 1 + segs) % segs] if (closed or i > 0) else side[0]
				var after: Vector2 = side[i % segs] if (closed or i < n - 1) else side[segs - 1]
				var m := (before + after).normalized()
				var off := m * (half / maxf(m.dot(after), 0.3))
				left.append(p[i] + off)
				right.append(p[i] - off)
			if closed:                     # a round room: its outside, and its inside (the smaller of the two rings)
				var la := _area(left)
				var ra := _area(right)
				return [[left, la < ra], [right, ra <= la]]
			right.reverse()
			return [[left + right, false]]
	return []

static func _area(pts: Array) -> float:
	var a := 0.0
	for i in pts.size():
		var p: Vector2 = pts[i]
		var q: Vector2 = pts[(i + 1) % pts.size()]
		a += p.x * q.y - q.x * p.y
	return absf(a)

## Dark brown vinyl, satin: the sheen of a mopped rubber strip, a little uneven
func _skirt_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.115, 0.098, 0.082)
	m.roughness = 0.5
	m.metallic_specular = 0.5
	var noise := FastNoiseLite.new()
	noise.frequency = 0.05
	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.width = 256
	tex.height = 256
	tex.seamless = true
	m.roughness_texture = tex
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3.ONE * 0.6
	return m

# ---------------------------------------------------------------- outlets and switches
## A duplex socket and a rocker switch (light_switch_and_wall_socket.glb, "Light Switch And Wall Socket" by
## Theocritus on Sketchfab), at the heights an electrician puts them: the socket 30 cm up, the switch 1.2 m
## up and a hand's width in from the edge of a way through. Rolled per wall face with a dice of its own (so the
## tubes' dice don't move); a look-only copy of the floor gets the same ones.
const FITTINGS := "res://models/props/wall_socket/light_switch_and_wall_socket.glb"
const OUTLET_H := 0.3
const SWITCH_H := 1.2
const OUTLET_CHANCE := 0.08         # a wall face (4.5 m) with a socket on it
const SWITCH_CHANCE := 0.06         # an outside corner with a switch beside it
const FITTING_SQUARE := 4           # cells a side of a group (one MultiMesh a part a group: they cull by group)

## Places them; returns where the switches went (world, [position, out of the wall]) for the hand marks
func _build_fittings() -> Array:
	var switches: Array = []
	var outlets: Array = []
	for f: Dictionary in _faces:
		var c: Vector2i = f.c
		var r := RandomNumberGenerator.new()
		r.seed = hash(Vector4i(c.x, c.y, DIRS.find(f.n), floor_src(level_raw, floor_no) + 8117))
		var fr := _face_frame(f)
		var mid: Vector3 = fr[0]
		var out: Vector3 = fr[1]
		var along: Vector3 = fr[2]
		var taken: Array[float] = []
		# (never inside a doorway or a thin wall's cell: the switch goes on the room's wall beside the opening,
		# not in its jamb; and never where a placed wall meets this one, or it would sit half inside it)
		var in_passage := carved.has(c)
		for e in 2:
			if f.ends[e] != END_OUT or r.randf() >= SWITCH_CHANCE or in_passage: continue
			var side := -1.0 if e == 0 else 1.0
			var u := (CELL * 0.5 - 0.2) * side
			# the corner itself must be a real one: no placed wall carrying the wall on from it
			if not _clear_of_objects(mid + along * (CELL * 0.5 * side) + out * 0.05, 0.4): continue
			if not _clear_of_objects(mid + along * u + out * 0.05, 0.35): continue
			taken.append(u)
			switches.append([mid + along * u + Vector3(0.0, SWITCH_H, 0.0), out, c])
		if r.randf() < OUTLET_CHANCE and not in_passage:
			var u := r.randf_range(-1.6, 1.6)
			var clear := _clear_of_objects(mid + along * u + out * 0.05, 0.35)
			for v in taken:
				if absf(v - u) < 0.5: clear = false
			if clear: outlets.append([mid + along * u + Vector3(0.0, OUTLET_H, 0.0), out, c])
	if switches.is_empty() and outlets.is_empty(): return switches
	var parts := _fitting_parts()
	if parts.is_empty(): return switches
	for kind: String in ["socket", "switch"]:
		var spots: Array = outlets if kind == "socket" else switches
		if spots.is_empty(): continue
		var groups := {}
		for s: Array in spots:
			var c: Vector2i = s[2]
			groups.get_or_add(Vector2i(floori(float(c.x) / FITTING_SQUARE), floori(float(c.y) / FITTING_SQUARE)), []).append(s)
		for part: Array in parts[kind]:
			var mesh: Mesh = part[0]
			var local: Transform3D = part[1]
			for g in groups:
				var list: Array = groups[g]
				var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.mesh = mesh
				mm.instance_count = list.size()
				var buf := MMBuffer.alloc(mm)
				var st := MMBuffer.stride(mm)
				for i in list.size():
					var s: Array = list[i]
					MMBuffer.put(buf, i * st, Transform3D(_on_wall(s[1]), s[0] + (s[1] as Vector3) * 0.001) * local)
				mm.buffer = buf
				var mmi := MultiMeshInstance3D.new()
				mmi.multimesh = mm
				mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				mmi.visibility_range_end = 32.0                  # (7 cm across: a pixel or two beyond this)
				mmi.visibility_range_end_margin = 4.0
				mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
				add_child(mmi)
	return switches

## The model's meshes, by fitting: {"socket": [[mesh, transform], ...], "switch": [...]}, each transform
## putting the part where it sits on its plate, the plate centred on the origin with its back on z = 0 and its
## face to +Z. The file has both side by side (the socket on the left), so they are told apart by where they are.
static var _fitting_cache := {}
func _fitting_parts() -> Dictionary:
	if not _fitting_cache.is_empty(): return _fitting_cache
	var root := IndustrialProp._instance(FITTINGS)
	if root == null: return {}
	var found := {"socket": [], "switch": []}
	var box := {}
	var plate := {}                     # kind -> the plate's box (its biggest part, face on): what sits on the wall
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null: continue
		var xf := Transform3D.IDENTITY
		var p: Node = mi
		while p != null and p != root:
			if p is Node3D: xf = (p as Node3D).transform * xf
			p = p.get_parent()
		var aabb := xf * mi.mesh.get_aabb()
		var kind := "socket" if aabb.get_center().x < 0.0 else "switch"
		found[kind].append([mi.mesh, xf])
		if box.has(kind):
			var was: AABB = box[kind]
			box[kind] = was.merge(aabb)
		else:
			box[kind] = aabb
		if not plate.has(kind) or aabb.size.x * aabb.size.y > (plate[kind] as AABB).size.x * (plate[kind] as AABB).size.y:
			plate[kind] = aabb
	root.free()
	for kind: String in found:
		if not box.has(kind): continue
		var b: AABB = box[kind]
		# its back flat on the wall: the plate's back, not the deepest part (the toggle's pivot reaches in behind
		# the plate, into the wall box, and measured from that the plate stood a couple of centimetres off)
		var pb: AABB = plate[kind]
		var shift := Vector3(-b.get_center().x, -b.get_center().y, -pb.position.z)
		for part: Array in found[kind]:
			var at: Transform3D = part[1]
			part[1] = Transform3D(Basis(), shift) * at
	_fitting_cache = found
	return found

# ---------------------------------------------------------------- wear
## The marks living leaves on walls, drawn over them (a multiply, so the wallpaper shows through): a band of
## kick marks and grime along the foot of every wall, grey hand marks round each switch, and hands and carts on
## the outside corners people round. Cards a few millimetres off the wall, the marks worked out in the shader
## from where they are; they fade out further off than they could be told apart.
const WEAR_FOOT := Vector2(0.105, 0.72)          # the kick band: from the top of the skirting up to here
func _build_wall_wear(switches: Array) -> void:
	var cards: Array = []                       # [transform, mode, seed, corner side, centre height]
	for f: Dictionary in _faces:
		var fr := _face_frame(f)
		var mid: Vector3 = fr[0]
		var out: Vector3 = fr[1]
		var along: Vector3 = fr[2]
		var b := _on_wall(out)
		var c: Vector2i = f.c
		var sd := fposmod(float(hash(Vector3i(c.x, c.y, DIRS.find(f.n)))) * 0.000123, 1.0)
		var h := WEAR_FOOT.y - WEAR_FOOT.x
		var cy := (WEAR_FOOT.x + WEAR_FOOT.y) * 0.5
		cards.append([Transform3D(b * Basis.from_scale(Vector3(CELL, h, 1.0)), mid + out * 0.004 + Vector3(0, cy, 0)), 0.0, sd, 0.0, cy])
		for e in 2:
			# (only some corners are rounded often enough to mark: one in three)
			if f.ends[e] != END_OUT or fposmod(sd * 7.31 + e * 0.53, 1.0) > 0.33: continue
			var side := -1.0 if e == 0 else 1.0
			if not _clear_of_objects(mid + along * (CELL * 0.5 * side) + out * 0.05, 0.4): continue    # (a placed wall carries on from it: no corner)
			var w := 0.7
			var at := mid + along * side * (CELL * 0.5 - w * 0.5) + out * 0.005 + Vector3(0, 0.9, 0)
			cards.append([Transform3D(b * Basis.from_scale(Vector3(w, 1.6, 1.0)), at), 2.0, sd, side * w * 0.5, 0.9])
	for s: Array in switches:
		var b := _on_wall(s[1])
		cards.append([Transform3D(b * Basis.from_scale(Vector3(0.36, 0.44, 1.0)), (s[0] as Vector3) + (s[1] as Vector3) * 0.005), 1.0, 0.5, 0.0, SWITCH_H])
	if cards.is_empty(): return
	var mat := ShaderMaterial.new()
	mat.shader = _coded_wear()
	mat.render_priority = 1
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = QuadMesh.new()
	mm.instance_count = cards.size()
	var buf := MMBuffer.alloc(mm)
	var st := MMBuffer.stride(mm)
	for i in cards.size():
		var cd: Array = cards[i]
		MMBuffer.put(buf, i * st, cd[0])
		buf[i * st + 12] = cd[1]
		buf[i * st + 13] = cd[2]
		buf[i * st + 14] = cd[3]
		buf[i * st + 15] = cd[4]
	mm.buffer = buf
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(mmi)

# ---------------------------------------------------------------- damp
## Water come down the wall from a leak in the ceiling: mould and wet staining in streaks from the top, fading
## out lower down. From photos of damp plaster (textures/damp_atlas.jpg, three of them stacked, made a multiply
## map: the clean plaster white, so the wallpaper shows through and only the stain darkens it). A card on the
## odd wall face, its top at the ceiling, showing a random stretch of a random photo (mirrored or not) at true
## size (the photos are 5.4 m of wall high), fading out raggedly at the face's ends.
const DAMP_ATLAS := "res://textures/damp_atlas.jpg"
const DAMP_CHANCE := 0.035          # a wall face with water down it (rare: a stain you see twice reads as a pattern)
const DAMP_PHOTO_H := 5.4           # metres of wall a photo's height covers
const DAMP_STRIP := 1365.0 / 4096.0 # one photo's share of the atlas's height
const DAMP_ASPECT := 2048.0 / 1365.0

## A texture by its res:// path. One Godot hasn't imported yet (added while the editor was shut, or a run
## started without it) is read straight from its file, so it still shows.
static var _raw_tex := {}
static func _texture(path: String) -> Texture2D:
	if ResourceLoader.exists(path): return load(path)
	if not _raw_tex.has(path):
		var img := Image.load_from_file(ProjectSettings.globalize_path(path))
		if img != null and not img.is_empty():
			img.generate_mipmaps()
			_raw_tex[path] = ImageTexture.create_from_image(img)
		else:
			push_warning("texture not found: " + path)
			_raw_tex[path] = null
	return _raw_tex[path]

func _build_damp() -> void:
	var atlas := _texture(DAMP_ATLAS)
	if atlas == null: return
	var span := CELL / (DAMP_PHOTO_H * DAMP_ASPECT)          # a face's width as a share of a photo's
	var cards: Array = []
	for f: Dictionary in _faces:
		var c: Vector2i = f.c
		if liminal.has(c) or bright.has(c): continue        # (the kept, clean places)
		var r := RandomNumberGenerator.new()
		r.seed = hash(Vector4i(c.x, c.y, DIRS.find(f.n), floor_src(level_raw, floor_no) + 4441))
		if r.randf() >= DAMP_CHANCE: continue
		var fr := _face_frame(f)
		# (not on a wall a placed wall butts onto: the stain would run straight through the thin wall's end)
		var clear := true
		for k in 5:
			var at: Vector3 = (fr[0] as Vector3) + (fr[2] as Vector3) * (CELL * (k / 4.0 - 0.5)) + (fr[1] as Vector3) * 0.05
			if not _clear_of_objects(at, 0.2): clear = false
		if not clear: continue
		var top := ceiling_height(c)
		var h := minf(top, DAMP_PHOTO_H)
		var xf := Transform3D(_on_wall(fr[1]) * Basis.from_scale(Vector3(CELL, h, 1.0)),
			(fr[0] as Vector3) + (fr[1] as Vector3) * 0.006 + Vector3(0.0, top - h * 0.5, 0.0))
		var custom := Color(float(r.randi() % 3), r.randf() * (1.0 - span), -1.0 if r.randf() < 0.5 else 1.0, h / DAMP_PHOTO_H)
		cards.append([xf, custom, r.randf_range(0.55, 0.95)])
	if cards.is_empty(): return
	var mat := ShaderMaterial.new()
	mat.shader = _coded_damp()
	mat.render_priority = 1
	mat.set_shader_parameter("damp", atlas)
	mat.set_shader_parameter("strip_h", DAMP_STRIP)
	mat.set_shader_parameter("span", span)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = QuadMesh.new()
	mm.instance_count = cards.size()
	for i in cards.size():
		mm.set_instance_transform(i, cards[i][0])
		mm.set_instance_custom_data(i, cards[i][1])
		mm.set_instance_color(i, Color(1, 1, 1, cards[i][2]))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(mmi)

static var _damp_shader: Shader
static func _coded_damp() -> Shader:
	if _damp_shader != null: return _damp_shader
	_damp_shader = Shader.new()
	_damp_shader.code = """shader_type spatial;
render_mode unshaded, blend_mul, depth_draw_never, cull_back, shadows_disabled, fog_disabled;
uniform sampler2D damp : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform float strip_h = 0.3333;         // one photo's share of the atlas's height
uniform float span = 0.5556;            // a face's width as a share of a photo's
varying vec2 lp;          // metres on the card: x along the wall, y up from its middle
varying vec2 sz;
varying vec4 info;        // x: which photo, y: where along it this face starts, z: mirrored (-1), w: share of its height shown
varying float strength;
void vertex() {
	sz = vec2(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz));
	lp = VERTEX.xy * sz;
	info = INSTANCE_CUSTOM;
	strength = COLOR.a;
}
float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), f.x), mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), f.x), f.y);
}
void fragment() {
	float fx = lp.x / sz.x + 0.5;
	if (info.z < 0.0) fx = 1.0 - fx;
	float v = clamp((0.5 - lp.y / sz.y) * info.w, 0.002, 0.995);      // 0 at the ceiling
	vec3 t = texture(damp, vec2(info.y + fx * span, (info.x + v) * strip_h)).rgb;
	// the water ran down from above: it fades out at the face's ends, raggedly, not at a straight edge
	float e = sz.x * 0.5 - abs(lp.x);
	float ragged = (vnoise(vec2(lp.y * 1.3, info.x * 7.0 + info.y * 11.0)) - 0.5) * 0.7;
	float keep = smoothstep(0.0, 1.0, e - 0.1 + ragged);
	ALBEDO = mix(vec3(1.0), t, strength * keep);
}
"""
	return _damp_shader

static var _wear_shader: Shader
static func _coded_wear() -> Shader:
	if _wear_shader != null: return _wear_shader
	_wear_shader = Shader.new()
	_wear_shader.code = """shader_type spatial;
render_mode unshaded, blend_mul, depth_draw_never, cull_back, shadows_disabled, fog_disabled;
uniform vec3 mark : source_color = vec3(0.3, 0.28, 0.25);   // what full-strength grime leaves of the wall's colour
uniform float strength = 1.0;
varying vec2 lp;          // metres on the card: x along the wall, y up from its middle
varying vec2 sz;          // the card's size, metres
varying vec4 info;        // x: 0 the foot of a wall, 1 round a switch, 2 an outside corner; y: its dice; z: where the corner is (x); w: the card's middle, metres up
void vertex() {
	sz = vec2(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz));
	lp = VERTEX.xy * sz;
	info = INSTANCE_CUSTOM;
}
float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), f.x), mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), f.x), f.y);
}
void fragment() {
	float y = lp.y + info.w;                    // metres up the wall
	float u = lp.x + info.y * 37.0;             // metres along it (each wall its own marks)
	float aa = max(length(fwidth(lp)), 0.0005);
	float m = 0.0;
	if (info.x < 0.5) {
		// Walls differ: most are fairly clean, some grimy, a few well kicked (the same marks on every wall
		// read as a pattern). How grimy and how scuffed this wall is, each rolled on its own.
		float grimy = smoothstep(0.6, 0.9, hash12(vec2(info.y * 91.0, 3.7)));
		float scuffed = 0.06 + 0.32 * pow(hash12(vec2(info.y * 53.0, 8.1)), 2.0);
		// grime settled along the foot: mop splash and dust, uneven, gone by knee height
		float band = (1.0 - smoothstep(0.11, 0.5, y)) * smoothstep(0.104, 0.118, y);
		m = band * grimy * (0.1 + 0.25 * vnoise(vec2(u * 1.6, y * 3.0)) * vnoise(vec2(u * 0.35, 1.7)));
		// kick and cart marks: short dark rubber strokes, most of them low, each fading along its drag
		float cs = 0.3;
		float id0 = floor(u / cs);
		for (int k = -1; k <= 1; k++) {
			vec2 hs = vec2(id0 + float(k), info.y * 97.0);
			if (hash12(hs) > scuffed) continue;
			vec2 ctr = vec2((hs.x + hash12(hs + 1.3)) * cs, 0.13 + 0.36 * pow(hash12(hs + 2.7), 1.8));
			float len = 0.03 + 0.18 * hash12(hs + 4.1);
			float ang = (hash12(hs + 5.9) - 0.5) * 0.5;
			vec2 dir = vec2(cos(ang), sin(ang));
			vec2 a = ctr - dir * len * 0.5;
			vec2 ba = dir * len;
			vec2 pa = vec2(u, y) - a;
			float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
			float wdt = 0.0012 + 0.0035 * hash12(hs + 7.7);
			float line = 1.0 - smoothstep(wdt - aa, wdt + aa, length(pa - ba * h));
			float fade = hash12(hs + 8.1) > 0.5 ? h : 1.0 - h;
			m = max(m, line * (0.25 + 0.6 * fade) * (0.5 + 0.5 * hash12(hs + 9.3)));
		}
	} else if (info.x < 1.5) {
		// round a switch: the grey of a thousand hands, heaviest just beside and under the plate
		vec2 q = (lp - vec2(0.0, -0.02)) / vec2(0.1, 0.15);
		float r = length(q) + (vnoise(lp * 22.0 + info.y * 40.0) - 0.5) * 0.45;
		m = (1.0 - smoothstep(0.3, 1.0, r)) * 0.32;
	} else {
		// an outside corner: hands and shoulders at waist to chest height, carts and feet at the bottom
		float e = abs(lp.x - info.z);
		float hand = (1.0 - smoothstep(0.0, 0.3, e)) * smoothstep(0.75, 1.0, y) * (1.0 - smoothstep(1.3, 1.65, y));
		float foot = (1.0 - smoothstep(0.0, 0.22, e)) * smoothstep(0.104, 0.118, y) * (1.0 - smoothstep(0.15, 0.55, y));
		m = (hand * 0.2 + foot * 0.25) * (0.45 + 0.9 * vnoise(vec2(e * 10.0, y * 7.0) + info.y * 30.0));
	}
	// fade out at the card's own edge and in the distance (the marks are under a pixel there: they'd crawl)
	vec2 edge = sz * 0.5 - abs(lp);
	m *= smoothstep(0.0, 0.03, min(edge.x, edge.y)) * (1.0 - smoothstep(14.0, 26.0, length(VERTEX)));
	ALBEDO = mix(vec3(1.0), mark, clamp(m * strength, 0.0, 0.9));
}
"""
	return _wear_shader
