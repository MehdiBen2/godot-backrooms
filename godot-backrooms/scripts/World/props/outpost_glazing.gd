extends RefCounted
## The T.S.R.A. outpost's bulletproof window: what stands in a "glazing" opening of a wall of the graph
## (wall_graph.gd OPENINGS, the level editor's "Outpost glass" and "Outpost wall + glass"). The wall is cut through
## both faces (wall_openings.gd: still solid to walk into) and this fills it as in the security offices it is
## after: one big smoked pane (or a few bays, split by black mullions, on a long run), set in a thick matte-black
## rubber surround with round corners that wraps the hole right through the wall and laps over both faces, and a
## black perforated strip along the head of the glass (the intercom / vent band). Style "service": the middle bay
## gets a speak grille and a document tray through the sill, the reception window. Built by level_geometry.gd
## _build_openings, in the opening's frame (wall_openings.gd frame_of: +x across the wall, +z along it, y up).

const BulletGlass := preload("res://scripts/World/props/bullet_glass.gd")
const Surfaces := preload("res://scripts/Render/surfaces.gd")

const FACE := 0.11                    # metres: the surround's face width round the glass
const CORNER := 0.14                  # ... the radius of its inner corners (the outer ones are this plus FACE)
const PROUD := 0.025                  # how far it stands off each face of the wall
const INSET := 0.04                   # how far its inner edge comes in over the hole, all round
const ARC_SEGS := 6                   # pieces in a corner's quarter circle
const MULLION := 0.07                 # a mullion's width, between two bays
const PANE_T := 0.03                  # the laminate's thickness
const STRIP_H := 0.12                 # the perforated strip along the head
const BAY := 4.0                      # metres a bay, when the opening doesn't say how many ("panes")

static var _mats := {}

static func _mat(key: String) -> Material:
	match key:
		"rubber": return Surfaces.pbr("Powder_Coat", Color(0.035, 0.036, 0.038), 0.6, true)   # matte black surround
		"steel": return Surfaces.pbr("Powder_Coat", Color(0.1, 0.105, 0.11), 0.6, true)
		"leaf": return Surfaces.pbr("Powder_Coat", Color(0.36, 0.38, 0.39), 0.6, true)
	if not _mats.has(key):
		var m: Material
		match key:
			"strip":
				var sm := ShaderMaterial.new()
				sm.shader = load("res://shaders/perforated.gdshader")
				m = sm
			"gasket":
				var g := StandardMaterial3D.new()
				g.albedo_color = Color(0.015, 0.015, 0.015)
				g.roughness = 0.75
				m = g
			"bolt":
				var b := StandardMaterial3D.new()
				b.albedo_color = Color(0.6, 0.6, 0.58)
				b.metallic = 1.0
				b.roughness = 0.32
				m = b
		_mats[key] = m
	return _mats[key]

## `op`: the opening (its "panes", "style"), `h`: its hole (y0 / y1), `xf`: its frame, `w`: the clear width
## between its jambs, `depth`: the wall's thickness (metres)
static func build(op: Dictionary, h: Dictionary, xf: Transform3D, w: float, depth: float) -> Node3D:
	var root := Node3D.new()
	root.transform = xf
	var y0 := float(h.y0)
	var y1 := float(h.y1)
	if w < 0.4 or y1 - y0 < 0.4: return root
	# the glass: what the surround leaves of the hole
	var hw := w * 0.5 - INSET
	var gy0 := y0 + INSET
	var gy1 := y1 - INSET
	var cy := (gy0 + gy1) * 0.5
	var hh := (gy1 - gy0) * 0.5
	var r := minf(CORNER, minf(hw, hh) * 0.9)
	var x1 := depth * 0.5 + PROUD
	var ring := SurfaceTool.new()
	ring.begin(Mesh.PRIMITIVE_TRIANGLES)
	_ring(ring, hw, hh, cy, r, FACE, -x1, x1)
	_add(root, ring.commit(), _mat("rubber"))
	var boxes := {"rubber": [], "glass": [], "strip": [], "gasket": [], "steel": []}
	var n := int(op.get("panes", 0))
	if n <= 0: n = maxi(1, roundi(w / BAY))
	var pitch := hw * 2.0 / n
	for i in range(1, n):
		boxes.rubber.append([Vector3(0, cy, -hw + i * pitch), Vector3(0.08, hh * 2.0, MULLION)])
	# one pane a bay, its edges run into the surround and the mullions (the round corners hide its square ones)
	for i in n:
		var z0 := -hw + i * pitch - (0.05 if i == 0 else -MULLION * 0.5 + 0.01)
		var z1 := -hw + (i + 1) * pitch + (0.05 if i == n - 1 else -MULLION * 0.5 + 0.01)
		boxes.glass.append([Vector3(0, cy, (z0 + z1) * 0.5), Vector3(PANE_T, hh * 2.0 + 0.1, z1 - z0)])
	# the perforated strip along the head, on both faces of the glass (its ends run into the surround)
	for side: float in [-1.0, 1.0]:
		boxes.strip.append([Vector3(side * (PANE_T * 0.5 + 0.008), gy1 - STRIP_H * 0.5 + 0.01, 0), Vector3(0.012, STRIP_H, hw * 2.0)])
	if str(op.get("style", "")) == "service":
		var mz := -hw + (n / 2 + 0.5) * pitch    # the middle bay (of an even number, the one past the middle)
		boxes.gasket.append([Vector3(0, gy0 + 0.3, mz), Vector3(PANE_T + 0.02, 0.1, 0.32)])
		for k in 4:
			for side: float in [-1.0, 1.0]:
				boxes.steel.append([Vector3(side * (PANE_T * 0.5 + 0.012), gy0 + 0.265 + k * 0.022, mz), Vector3(0.006, 0.008, 0.28)])
		boxes.steel.append([Vector3(0, y0 + 0.012, mz), Vector3(depth + 0.5, 0.024, 0.45)])     # the document tray
		boxes.gasket.append([Vector3(0, y0 + 0.028, mz), Vector3(depth + 0.44, 0.008, 0.39)])
	for key: String in boxes:
		if (boxes[key] as Array).is_empty(): continue
		var st := SurfaceTool.new()
		for b: Array in boxes[key]:
			var bm := BoxMesh.new()
			bm.size = b[1]
			st.append_from(bm, 0, Transform3D(Basis.IDENTITY, b[0]))
		var mi := _add(root, st.commit(), BulletGlass.material() if key == "glass" else _mat(key))
		if key == "glass": mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return root

static func _add(root: Node3D, mesh: Mesh, m: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = m
	root.add_child(mi)
	return mi

## The surround: a ring in the wall's plane (z along, y up) between a rounded rectangle (half sizes hw x hh round
## (0, cy), corner radius r) and the same pushed out by `fw`, run through from x0 to x1: its two faces, the edge
## round the glass and the edge buried in the wall
static func _ring(st: SurfaceTool, hw: float, hh: float, cy: float, r: float, fw: float, x0: float, x1: float) -> void:
	var inner: Array[Vector2] = []
	var outer: Array[Vector2] = []
	var dirs: Array[Vector2] = []
	var corners := [Vector2(1, 1), Vector2(-1, 1), Vector2(-1, -1), Vector2(1, -1)]
	for c in 4:
		var s: Vector2 = corners[c]
		var mid := Vector2(s.x * (hw - r), cy + s.y * (hh - r))
		for k in ARC_SEGS + 1:
			var a := (c + float(k) / ARC_SEGS) * PI * 0.5
			var d := Vector2(cos(a), sin(a))
			inner.append(mid + d * r)
			outer.append(mid + d * (r + fw))
			dirs.append(d)
	var m := inner.size()
	for i in m:
		var j := (i + 1) % m
		for x: float in [x0, x1]:                   # the faces
			var nx := Vector3(signf(x), 0, 0)
			_quad(st, _p(x, inner[i]), _p(x, inner[j]), _p(x, outer[j]), _p(x, outer[i]), nx)
		var ni := -Vector3(0, (dirs[i].y + dirs[j].y) * 0.5, (dirs[i].x + dirs[j].x) * 0.5).normalized()
		_quad(st, _p(x0, inner[i]), _p(x0, inner[j]), _p(x1, inner[j]), _p(x1, inner[i]), ni)
		_quad(st, _p(x0, outer[i]), _p(x0, outer[j]), _p(x1, outer[j]), _p(x1, outer[i]), -ni)

static func _p(x: float, q: Vector2) -> Vector3:
	return Vector3(x, q.y, q.x)

## Two triangles a-b-c, a-c-d facing `n` (Godot's front faces wind clockwise seen from in front)
static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
	for t: Array in [[a, b, c], [a, c, d]]:
		var p: Vector3 = t[0]
		var q: Vector3 = t[1]
		var s: Vector3 = t[2]
		if (q - p).cross(s - p).dot(n) > 0.0:
			var sw := q
			q = s
			s = sw
		for v: Vector3 in [p, q, s]:
			st.set_normal(n)
			st.add_vertex(v)
