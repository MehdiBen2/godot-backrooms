extends RefCounted
## The T.S.R.A. outpost's bulletproof glazing: what stands in a "glazing" opening of a wall of the graph
## (wall_graph.gd OPENINGS, the level editor's "Outpost glass"). The wall is cut through both faces from the sill
## to the head (wall_openings.gd: still solid to walk into) and this fills it: a deep steel bezel round the hole
## with a casing lip on both faces, steel mullions splitting it into bays, each laminated pane held in a black
## gasket and bolted through. Style "service": the middle pane gets a speak grille and a document tray through
## the sill, the reception window of the outpost. Built by level_geometry.gd _build_openings, in the opening's
## frame (wall_openings.gd frame_of: +x across the wall, +z along it, y up from the floor).

const BulletGlass := preload("res://scripts/World/props/bullet_glass.gd")

const BEZEL := 0.07                   # metres: the bezel's face width round the hole
const MULLION := 0.06                 # ... a mullion's
const LIP := 0.05                     # how far the casing laps over each face of the wall
const PANE_T := 0.03                  # the laminate's thickness
const BAY := 1.5                      # metres a bay, when the opening doesn't say how many ("panes")

static var _mats := {}

static func _mat(key: String) -> Material:
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		match key:
			"steel":
				m.albedo_color = Color(0.06, 0.065, 0.07)
				m.metallic = 0.6
				m.roughness = 0.42
			"gasket":
				m.albedo_color = Color(0.015, 0.015, 0.015)
				m.roughness = 0.75
			"bolt":
				m.albedo_color = Color(0.6, 0.6, 0.58)
				m.metallic = 1.0
				m.roughness = 0.32
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
	var parts := {"steel": [], "gasket": [], "bolt": [], "glass": []}
	var d := depth + 0.02
	var face := depth * 0.5 + 0.006
	# the bezel lining the hole, and its lip on both faces
	parts.steel.append([Vector3(0, y1 - BEZEL * 0.5, 0), Vector3(d, BEZEL, w)])
	parts.steel.append([Vector3(0, y0 + BEZEL * 0.5, 0), Vector3(d + 0.04, BEZEL, w)])
	for s: float in [-1.0, 1.0]:
		parts.steel.append([Vector3(0, (y0 + y1) * 0.5, s * (w - BEZEL) * 0.5), Vector3(d, y1 - y0, BEZEL)])
	for side: float in [-1.0, 1.0]:
		for s: float in [-1.0, 1.0]:
			parts.steel.append([Vector3(side * face, (y0 + y1) * 0.5, s * (w + LIP) * 0.5), Vector3(0.012, y1 - y0 + LIP * 2.0, LIP)])
		parts.steel.append([Vector3(side * face, y1 + LIP * 0.5, 0), Vector3(0.012, LIP, w)])
		parts.steel.append([Vector3(side * face, y0 - LIP * 0.5, 0), Vector3(0.012, LIP, w)])
	# the bays
	var inner := w - BEZEL * 2.0
	var n := int(op.get("panes", 0))
	if n <= 0: n = maxi(1, roundi(inner / BAY))
	var pitch := inner / n
	var gy0 := y0 + BEZEL
	var gy1 := y1 - BEZEL
	var gh := gy1 - gy0
	for i in range(1, n):
		parts.steel.append([Vector3(0, (gy0 + gy1) * 0.5, -inner * 0.5 + i * pitch), Vector3(0.12, gh, MULLION)])
	for i in n:
		var z := -inner * 0.5 + (i + 0.5) * pitch
		var gw := pitch - (MULLION if n > 1 else 0.0)
		var gc := Vector3(0, (gy0 + gy1) * 0.5, z)
		parts.glass.append([gc, Vector3(PANE_T, gh, gw)])
		var g := 0.018
		parts.gasket.append([gc + Vector3(0, gh * 0.5 - g * 0.5, 0), Vector3(0.045, g, gw)])
		parts.gasket.append([gc - Vector3(0, gh * 0.5 - g * 0.5, 0), Vector3(0.045, g, gw)])
		parts.gasket.append([gc + Vector3(0, 0, gw * 0.5 - g * 0.5), Vector3(0.045, gh, g)])
		parts.gasket.append([gc - Vector3(0, 0, gw * 0.5 - g * 0.5), Vector3(0.045, gh, g)])
		for side: float in [-1.0, 1.0]:                       # the bolts through the laminate
			for by: float in [gy0 + 0.1, gy1 - 0.1]:
				for bz: float in [z - gw * 0.5 + 0.07, z + gw * 0.5 - 0.07]:
					parts.bolt.append([Vector3(side * (PANE_T * 0.5 + 0.005), by, bz), Vector3(0.01, 0.024, 0.024)])
	if str(op.get("style", "")) == "service":
		var mz := -inner * 0.5 + (n / 2 + 0.5) * pitch    # the middle bay (of an even number, the one past the middle)
		parts.gasket.append([Vector3(0, gy0 + 0.28, mz), Vector3(PANE_T + 0.02, 0.1, 0.32)])
		for k in 4:
			for side: float in [-1.0, 1.0]:
				parts.steel.append([Vector3(side * (PANE_T * 0.5 + 0.012), gy0 + 0.245 + k * 0.022, mz), Vector3(0.006, 0.008, 0.28)])
		parts.steel.append([Vector3(0, y0 + BEZEL - 0.01, mz), Vector3(d + 0.5, 0.03, 0.45)])     # the document tray
		parts.gasket.append([Vector3(0, y0 + BEZEL + 0.006, mz), Vector3(d + 0.44, 0.012, 0.39)])
	for key: String in parts:
		if (parts[key] as Array).is_empty(): continue
		var st := SurfaceTool.new()
		for b: Array in parts[key]:
			var bm := BoxMesh.new()
			bm.size = b[1]
			st.append_from(bm, 0, Transform3D(Basis.IDENTITY, b[0]))
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		mi.material_override = BulletGlass.material() if key == "glass" else _mat(key)
		if key == "glass": mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mi)
	return root
