extends RefCounted
## THE MANNEQUIN's body: creepy_mannequin.glb taken apart into its separate meshes (torso, head, eyes,
## two arms, two legs), each with the joint it swings about, and the poses. A pose is a Dictionary of
## POSE_KEYS angles; part_transforms() turns one into a transform per part in figure space (feet on
## y = 0, HEIGHT tall). Shared by the real one (its own meshes) and the decoys (one MultiMesh per part).

const MODEL := "res://models/entities/creepy_mannequin.glb"
const HEIGHT := 1.85
const POSE_KEYS := ["legL", "legR", "armL", "armR", "splayL", "splayR", "rollL", "rollR", "headYaw", "headTilt", "headNod", "lean", "twist", "bob"]

# A second sculpt mixed into the standing crowd for variety; load_variant() picks one of these per run.
# mannequin_variant.glb is one skinned mesh with a simple rig (Hips > LegL, LegR, Spine > Head, ArmL >
# ForearmL, ArmR > ForearmR; built by tools/blender/rig_mannequin_variant.py, source art/mannequin_variant.blend),
# posed through its bones with the same pose Dictionaries as the jointed one (pose_variant), so no two of
# them stand alike. Each bone's +Y runs down its limb. mannequinvar3.glb carries its own unrelated humanoid
# rig (Pelvis/Spine01/L_Upperarm/...) from a different auto-rig tool, so it is posed through RIG_PROFILES
# below instead of the hardcoded bone names: same pose Dictionary, mapped to whichever names that rig uses.
const VARIANT_MODELS := ["res://models/entities/mannequin_variant.glb", "res://models/entities/mannequinvar3.glb"]
# role -> bone name for each entry in VARIANT_MODELS, so pose_variant() works on either rig. "spine" is the
# single bone twist/lean turns (mannequin_variant.glb only has one torso bone; mannequinvar3.glb's nearest
# equivalent is the waist, just below its two spine bones).
const RIG_PROFILES := [
	{"spine": "Spine", "head": "Head", "armL": "ArmL", "armR": "ArmR", "forearmL": "ForearmL", "forearmR": "ForearmR", "legL": "LegL", "legR": "LegR"},
	{"spine": "Waist", "head": "Head", "armL": "L_Upperarm", "armR": "R_Upperarm", "forearmL": "L_Forearm", "forearmR": "R_Forearm", "legL": "L_Thigh", "legR": "R_Thigh"},
]
# Its rest pose is a catwalk stride with a hand on the hip. A frozen mannequin reads better planted, so the
# legs are brought most of the way back under it before a pose is applied (0 = keep the stride).
const VARIANT_PLANT := 0.75
# How worn each variant is (variant_style): cracked plaster, missing parts (a hand, an arm, both arms, the
# head, or head and arms: a bare torso on legs), a painted-on
# display-shop outfit, or standing under a dust sheet. Drawn by shaders/mannequin_wear.gdshader.
const WEAR_SHADER := preload("res://shaders/mannequin_wear.gdshader")
const SHEET_CHANCE := 0.15
const CRACK_CHANCE := 0.4
const MISSING_CHANCE := 0.35
const DRESSED_CHANCE := 0.3
# what can be broken off, with how likely each is (a piece takes whatever hangs from it with it)
const MISSING_SETS := [
	[["ForearmL"], 1.0], [["ForearmR"], 1.0],            # a hand and forearm
	[["ArmL"], 1.0], [["ArmR"], 1.0],                    # one arm
	[["ArmL", "ArmR"], 1.5],                             # armless
	[["Head"], 1.5],                                     # headless
	[["Head", "ArmL", "ArmR"], 0.6],                     # just a torso on legs
]
# MISSING_SETS names the mannequin_variant.glb rig's own bones; this maps each one to its RIG_PROFILES role
# so make_variant can carry the same "missing" set over to whichever rig actually got loaded.
const MISSING_ROLE := {"ForearmL": "forearmL", "ForearmR": "forearmR", "ArmL": "armL", "ArmR": "armR", "Head": "head"}
# Display-shop outfits in faded colours: top (+ pattern), bottom, sleeves, trousers or a dress
const OUTFITS := [
	{"top": Color(0.42, 0.14, 0.13), "bottom": Color(0.16, 0.16, 0.18), "sleeves": true},
	{"top": Color(0.2, 0.28, 0.38), "bottom": Color(0.55, 0.5, 0.42), "sleeves": false},
	{"top": Color(0.62, 0.6, 0.55), "bottom": Color(0.12, 0.12, 0.14), "sleeves": true, "pants": true},
	{"top": Color(0.25, 0.33, 0.22), "bottom": Color(0.3, 0.22, 0.16), "sleeves": false, "pants": true},
	{"top": Color(0.18, 0.2, 0.3), "bottom": Color(0.14, 0.14, 0.16), "sleeves": true, "pattern": 1, "pattern_color": Color(0.8, 0.78, 0.7)},
	{"top": Color(0.5, 0.16, 0.14), "bottom": Color(0.2, 0.2, 0.24), "sleeves": true, "pattern": 2, "pattern_color": Color(0.15, 0.12, 0.1), "pants": true},
	{"top": Color(0.58, 0.46, 0.2), "sleeves": false, "dress": true},
	{"top": Color(0.14, 0.14, 0.16), "sleeves": true, "dress": true, "pattern": 3, "pattern_color": Color(0.85, 0.83, 0.76)},
	{"top": Color(0.45, 0.36, 0.42), "sleeves": false, "dress": true, "pattern": 1, "pattern_color": Color(0.75, 0.72, 0.66)},
	{"top": Color(0.7, 0.68, 0.62), "bottom": Color(0.25, 0.3, 0.42), "sleeves": false, "pattern": 3, "pattern_color": Color(0.5, 0.15, 0.14), "pants": true},
]
# What goes over the sheeted ones (mannequin_sheet.gdshader kind): linen dust sheet, moving blanket, plastic
const SHEETS := [
	{"kind": 0, "tint": Color(0.8, 0.78, 0.72), "weight": 1.0},
	{"kind": 0, "tint": Color(0.74, 0.68, 0.52), "weight": 0.6},      # yellowed with age
	{"kind": 1, "tint": Color(0.36, 0.38, 0.36), "weight": 0.6},
	{"kind": 1, "tint": Color(0.3, 0.34, 0.44), "weight": 0.4},
	{"kind": 2, "tint": Color(0.9, 0.92, 0.9), "weight": 0.7},        # plastic: the figure shows through
]
const SHEET_SHADER := preload("res://shaders/mannequin_sheet.gdshader")
var _sheet_mesh: ArrayMesh

var parts: Array = []                        # {mesh, xf, pivot, kind, side, ...}
var hip_pivot := Vector3(0.0, 0.818858, -0.099118)
var norm_xf := Transform3D.IDENTITY          # model space -> figure space
var ok := false
var _top_x := Vector2.ZERO                   # x extent of the last arm's shoulder slice

## One entry per VARIANT_MODELS index that loaded successfully: {scene, root_xf, xf, mesh, rigged, profile,
## vbones, arm_l_pivot}. Both currently-shipped variants are rigged, so every decoy that rolls a variant
## (mannequin_crowd.gd) picks a random loaded index and gets its own posed copy - no longer one model per run.
var _variants: Array = []
var variant_ok := false                      # true once at least one entry loaded
var variant_rigged := false                  # true if any loaded entry is rigged (gates the plain-mesh fallback)
# Back-compat aliases mirroring _variants[0], read by the offline pose/screenshot tools (tools/shot_variant_poses.gd)
var variant_mesh: Mesh
var variant_xf := Transform3D.IDENTITY
var variant_scene: PackedScene
var variant_root_xf := Transform3D.IDENTITY

func _part_kind(node: Node) -> String:
	var name := ""
	var o: Node = node
	while o != null:
		name += " " + String(o.name)
		o = o.get_parent()
	name = name.to_lower()
	if name.contains("auge") or name.contains("eye"): return "eyes"
	if name.contains("kopf") or name.contains("head"): return "head"
	if name.contains("torso") or name.contains("body"): return "torso"
	if name.contains("arm"): return "arm"
	if name.contains("bein") or name.contains("leg"): return "leg"
	return "torso"

func _top_centroid(mesh: Mesh, xf: Transform3D, b: AABB) -> Vector3:
	var limit := b.end.y - b.size.y * 0.06
	var sum := Vector3.ZERO
	var cnt := 0
	_top_x = Vector2(INF, -INF)
	for s in mesh.get_surface_count():
		var verts = mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		if verts == null:
			continue
		for v in verts:
			var w: Vector3 = xf * v
			if w.y >= limit:
				sum += w
				cnt += 1
				_top_x = Vector2(minf(_top_x.x, w.x), maxf(_top_x.y, w.x))
	if cnt == 0:
		return Vector3(b.get_center().x, b.end.y, b.get_center().z)
	return sum / cnt

# Centre of the shoulder socket: the flat disc of the arm that sits against the torso is the inner-most
# slice of the mesh, and its middle (not the top of the arm) is where the joint really is. Swinging
# the arm about the top of the disc lifts the socket off the torso peg once the arm is raised.
func _socket_centroid(mesh: Mesh, xf: Transform3D, b: AABB, inner_is_min_x: bool) -> Vector3:
	var band := maxf(0.01, b.size.x * 0.04)
	var edge := b.position.x if inner_is_min_x else b.end.x
	var sum := Vector3.ZERO
	var cnt := 0
	for s in mesh.get_surface_count():
		var verts = mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		if verts == null:
			continue
		for v in verts:
			var w: Vector3 = xf * v
			if absf(w.x - edge) <= band:
				sum += w
				cnt += 1
	if cnt == 0:
		return Vector3.INF
	var c := sum / cnt
	c.x = edge
	return c

## Load the model and work out every part's joint. `host` holds the instance while it is measured.
func load_template(host: Node) -> bool:
	var packed := load(MODEL) as PackedScene
	if packed == null:
		return false
	var root: Node3D = packed.instantiate()
	host.add_child(root)
	var box := AABB()
	var first := true
	for m in root.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var xf := Transform3D.IDENTITY
		var p: Node = mi
		while p != null and p != root:
			if p is Node3D:
				xf = (p as Node3D).transform * xf
			p = p.get_parent()
		var b := xf * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
		var kind := _part_kind(mi)
		var pivot := Vector3.ZERO
		if kind == "leg":
			pivot = Vector3(b.get_center().x, b.end.y, b.get_center().z)
		elif kind == "arm":
			# the real shoulder joint: the centroid of the top slice of the arm, not the AABB centre
			# (which is off to the side when the arm hangs at an angle)
			pivot = _top_centroid(mi.mesh, xf, b)
		elif kind == "head" or kind == "eyes":
			pivot = Vector3(b.get_center().x, b.position.y, b.get_center().z)   # base of the neck
		# torso pivot is the hips (a little above the leg tops): set below
		parts.append({"mesh": mi.mesh, "xf": xf, "pivot": pivot, "kind": kind, "cx": b.get_center().x, "b": b, "top_x": _top_x})
	root.queue_free()
	if parts.is_empty() or box.size.y <= 0.0:
		return false
	var s := HEIGHT / box.size.y
	var c := box.get_center()
	norm_xf = Transform3D(Basis.from_scale(Vector3(s, s, s)), Vector3(-c.x, -box.position.y, -c.z) * s)
	# left / right from where the part sits (the model's own labels are mirrored); L is +X
	var hip_y := -3.0
	for pt in parts:
		if pt.kind == "leg":
			hip_y = pt.b.end.y
		if pt.kind == "arm" or pt.kind == "leg":
			pt["side"] = "L" if pt.cx > c.x else "R"
			if pt.kind == "arm":
				# how far out from vertical the arm hangs in the model: raised forward, that angle would
				# spread the hands wide, so the reaching poses can cancel it (pose.align)
				var out_x: float = (pt.cx - pt.pivot.x) * (1.0 if pt.side == "L" else -1.0)
				pt["rest_ang"] = atan2(out_x, pt.pivot.y - pt.b.get_center().y)
				# swing about the inner edge of the shoulder so the joint stays closed against the torso
				var tx: Vector2 = pt.top_x
				pt.pivot.x = tx.x if pt.side == "L" else tx.y
				# and about the middle of the socket disc, so the joint stays on the torso peg
				var sock := _socket_centroid(pt.mesh, pt.xf, pt.b, pt.side == "L")
				if sock.is_finite():
					pt.pivot = sock
		elif pt.kind == "head" or pt.kind == "eyes":
			pt["side"] = ""
	# the head pivot is shared: at the base of the head (set by the head part; the eyes copy it)
	var head_pivot := Vector3.ZERO
	for pt in parts:
		if pt.kind == "head":
			head_pivot = pt.pivot
	for pt in parts:
		if pt.kind == "eyes":
			pt.pivot = head_pivot
	hip_pivot = Vector3(c.x, hip_y, c.z)
	ok = true
	return true

## Load every VARIANT_MODELS sculpt, normalised the same way (feet on y = 0, HEIGHT tall). `rng` is accepted
## for backward compatibility (older callers used it to pick a single model) but is no longer needed: all of
## them load, and mannequin_crowd.gd rolls a random one per decoy that becomes a variant.
func load_variant(host: Node, _rng: RandomNumberGenerator = null) -> bool:
	for idx in VARIANT_MODELS.size():
		var entry := _load_one_variant(host, idx)
		if entry.is_empty():
			continue
		_variants.append(entry)
		variant_ok = true
		if entry.rigged:
			variant_rigged = true
	if not _variants.is_empty():
		var v0: Dictionary = _variants[0]
		variant_mesh = v0.mesh
		variant_xf = v0.xf
		variant_scene = v0.scene
		variant_root_xf = v0.root_xf
	return variant_ok

func _load_one_variant(host: Node, idx: int) -> Dictionary:
	var packed := load(VARIANT_MODELS[idx]) as PackedScene
	if packed == null:
		return {}
	var root: Node3D = packed.instantiate()
	host.add_child(root)
	var meshes := root.find_children("*", "MeshInstance3D", true, false)
	if meshes.is_empty():
		root.queue_free()
		return {}
	var mi := meshes[0] as MeshInstance3D
	var xf := Transform3D.IDENTITY
	var p: Node = mi
	while p != null and p != root:
		if p is Node3D:
			xf = (p as Node3D).transform * xf
		p = p.get_parent()
	var b := xf * mi.get_aabb()
	var vbones := {}
	var profile := {}
	var rigged := false
	var arm_l_pivot := Vector3.INF
	var skels := root.find_children("*", "Skeleton3D", true, false)
	if not skels.is_empty():
		var sk := skels[0] as Skeleton3D
		for i in sk.get_bone_count():
			vbones[sk.get_bone_name(i)] = i
		profile = RIG_PROFILES[idx]
		rigged = profile.values().all(func(n): return vbones.has(n))
		# The rig's left shoulder joint sits at hip height (the right one is at the shoulder), so swinging
		# ArmL about its own origin would pivot the arm from the waist. Mirror the right shoulder instead.
		if rigged:
			var r: Vector3 = sk.get_bone_global_rest(vbones[profile.armR]).origin
			var l: Vector3 = sk.get_bone_global_rest(vbones[profile.armL]).origin
			if absf(l.y - r.y) > 0.1:
				arm_l_pivot = Vector3(-r.x, r.y, r.z)
	root.queue_free()
	if b.size.y <= 0.0:
		return {}
	var s := HEIGHT / b.size.y
	var c := b.get_center()
	var norm := Transform3D(Basis.from_scale(Vector3(s, s, s)), Vector3(-c.x, -b.position.y, -c.z) * s)
	# the model's vertex colours are piece ids for mannequin_wear.gdshader, not a tint: the importer
	# would multiply the albedo by them (a dark red figure) wherever the plain material is still used
	for sf in mi.mesh.get_surface_count():
		var sm := mi.mesh.surface_get_material(sf) as StandardMaterial3D
		if sm != null:
			sm.vertex_color_use_as_albedo = false
	return {"scene": packed, "root_xf": norm, "xf": norm * xf, "mesh": mi.mesh, "rigged": rigged,
		"profile": profile, "vbones": vbones, "arm_l_pivot": arm_l_pivot}

func variant_count() -> int:
	return _variants.size()

func variant_is_rigged(idx: int) -> bool:
	return _variants[idx].rigged

func variant_root_xf_at(idx: int) -> Transform3D:
	return _variants[idx].root_xf

func variant_xf_at(idx: int) -> Transform3D:
	return _variants[idx].xf

## How this one has aged: {sheet, cracks 0..1, missing: [bone names], clothes, outfit, sleeves}
static func variant_style(rng: RandomNumberGenerator) -> Dictionary:
	var st := {"sheet": false, "cracks": 0.0, "missing": [], "clothes": false, "outfit": 0, "sheet_kind": 0,
		"seed": rng.randf() * 100.0}
	if rng.randf() < SHEET_CHANCE:
		st.sheet = true
		var total := 0.0
		for sh in SHEETS:
			total += float(sh.weight)
		var roll := rng.randf() * total
		for k in SHEETS.size():
			roll -= float(SHEETS[k].weight)
			if roll <= 0.0:
				st.sheet_kind = k
				break
		return st
	if rng.randf() < CRACK_CHANCE:
		st.cracks = rng.randf_range(0.6, 1.0)
	if rng.randf() < MISSING_CHANCE:
		var total := 0.0
		for m in MISSING_SETS:
			total += float(m[1])
		var roll := rng.randf() * total
		for m in MISSING_SETS:
			roll -= float(m[1])
			if roll <= 0.0:
				st.missing = (m[0] as Array).duplicate()
				break
	if rng.randf() < DRESSED_CHANCE:
		st.clothes = true
		st.outfit = rng.randi() % OUTFITS.size()
	return st

## A posed copy of variant sculpt `idx` (its own rigged scene), in figure space, worn per `style`
## (variant_style). Null without a rig. `idx` defaults to 0 for older callers that only knew one variant.
func make_variant(pose: Dictionary, style := {}, idx := 0) -> Node3D:
	if idx < 0 or idx >= _variants.size() or not _variants[idx].rigged:
		return null
	var v: Dictionary = _variants[idx]
	if style.get("sheet", false):
		var sheet: Dictionary = SHEETS[int(style.get("sheet_kind", 0)) % SHEETS.size()]
		var covered := Node3D.new()
		var mi_s := MeshInstance3D.new()
		mi_s.mesh = _sheet()
		mi_s.transform = v.root_xf.affine_inverse()   # the crowd places it through variant_root_xf_at(idx)
		var sm := ShaderMaterial.new()
		sm.shader = SHEET_SHADER
		sm.set_shader_parameter("kind", int(sheet.kind))
		sm.set_shader_parameter("tint", sheet.tint)
		sm.set_shader_parameter("seed", float(style.get("seed", 0.0)))
		mi_s.material_override = sm
		covered.add_child(mi_s)
		if int(sheet.kind) == 2:                         # clear plastic: the figure inside, stood at rest
			var inner := style.duplicate()
			inner.sheet = false
			var fig := make_variant(rest_pose(), inner, idx)
			if fig != null:
				covered.add_child(fig)
		return covered
	var n: Node3D = v.scene.instantiate()
	var sk := n.find_children("*", "Skeleton3D", true, false)[0] as Skeleton3D
	var missing = style.get("missing", [])
	if missing is String:
		missing = [missing] if missing != "" else []
	var vbones: Dictionary = v.vbones
	var profile: Dictionary = v.profile
	var arm_l_pivot: Vector3 = v.arm_l_pivot
	# a Skeleton3D only schedules its update while in the tree: posed before that, it keeps showing its rest.
	# vbones/profile/arm_l_pivot are captured here by value so a later make_variant() call (a different
	# decoy, maybe a different variant) can't change what this closure sees once its own sk finally readies.
	sk.ready.connect(func():
		pose_variant(sk, pose, vbones, profile, arm_l_pivot)
		for bone in missing:                              # broken off: the piece (and what hangs from it) shrinks away
			var actual: String = profile.get(MISSING_ROLE.get(bone, ""), bone)
			if vbones.has(actual):
				sk.set_bone_pose_scale(vbones[actual], Vector3.ONE * 0.001), CONNECT_ONE_SHOT)
	for m in n.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mi.material_override = _wear_material(mi, style)     # every variant: plain ones just have no wear
	return n

func _wear_material(mi: MeshInstance3D, style: Dictionary) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = WEAR_SHADER
	var base := mi.mesh.surface_get_material(0) as StandardMaterial3D
	if base != null:
		mat.set_shader_parameter("albedo_tex", base.albedo_texture)
		mat.set_shader_parameter("roughness", base.roughness)
	mat.set_shader_parameter("cracks", float(style.get("cracks", 0.0)))
	mat.set_shader_parameter("clothes", 1.0 if style.get("clothes", false) else 0.0)
	var outfit: Dictionary = OUTFITS[int(style.get("outfit", 0)) % OUTFITS.size()]
	mat.set_shader_parameter("shirt_color", outfit.top)
	mat.set_shader_parameter("bottom_color", outfit.get("bottom", outfit.top))
	mat.set_shader_parameter("sleeves", 1.0 if style.get("sleeves", outfit.get("sleeves", true)) else 0.0)
	mat.set_shader_parameter("pants", 1.0 if outfit.get("pants", false) else 0.0)
	mat.set_shader_parameter("dress", 1.0 if outfit.get("dress", false) else 0.0)
	mat.set_shader_parameter("pattern", int(outfit.get("pattern", 0)))
	mat.set_shader_parameter("pattern_color", outfit.get("pattern_color", Color.WHITE))
	return mat

## A dust sheet thrown over a standing figure (figure space: feet on y = 0, facing +Z): a round head, the
## cloth hanging off the shoulders and spreading to the floor in folds, the hem uneven. Built once.
func _sheet() -> ArrayMesh:
	if _sheet_mesh != null:
		return _sheet_mesh
	const RINGS := 30
	const SEGS := 44
	var top := HEIGHT + 0.03
	var noise := FastNoiseLite.new()
	noise.seed = 17
	noise.frequency = 1.3
	var pts: Array = []
	for r in RINGS + 1:
		var t := float(r) / RINGS                      # 0 top .. 1 hem
		var y := top * (1.0 - t)
		var rad := 0.0
		if y > 1.6:                                    # the head under the cloth
			var u := clampf((top - y) / (top - 1.6), 0.0, 1.0)
			rad = 0.14 * sqrt(1.0 - (1.0 - u) * (1.0 - u))
		elif y > 1.42:                                 # neck to shoulders
			rad = lerpf(0.27, 0.14, (y - 1.42) / 0.18)
		else:                                          # hanging to the floor, spreading as it goes
			rad = lerpf(0.4, 0.27, y / 1.42)
		var ring: Array = []
		for sgm in SEGS:
			var a := TAU * float(sgm) / SEGS
			var hang := clampf((1.42 - y) / 1.42, 0.0, 1.0)
			var fold := 1.0 + 0.09 * hang * sin(a * 7.0 + noise.get_noise_2d(a * 2.0, y) * 3.0) + 0.04 * noise.get_noise_2d(a * 3.0, y * 4.0)
			var squash := lerpf(0.62, 0.9, hang) if y < 1.6 else 1.0        # shoulders are wider than deep
			var yy := y
			if r == RINGS:                              # the hem: uneven, a few corners lifted
				yy = 0.015 + maxf(0.0, noise.get_noise_2d(a * 4.0, 5.0)) * 0.12
			ring.append(Vector3(cos(a) * rad * fold, yy, sin(a) * rad * fold * squash))
		pts.append(ring)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for r in RINGS:
		for sgm in SEGS:
			var n2 := (sgm + 1) % SEGS
			var a0: Vector3 = pts[r][sgm]
			var a1: Vector3 = pts[r][n2]
			var b0: Vector3 = pts[r + 1][sgm]
			var b1: Vector3 = pts[r + 1][n2]
			for v in [a0, b0, a1, a1, b0, b1]:
				st.add_vertex(v)
	st.generate_normals()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.7, 0.68, 0.62)
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	st.set_material(mat)
	_sheet_mesh = st.commit()
	return _sheet_mesh

## Turn one bone by `rot`, a rotation in skeleton space about `pivot` (its own joint when INF). Its parent's
## pose still applies on top, so an arm swings with a leaning torso. `vbones` is the loaded variant's own
## bone-name -> index map (mannequin_variant.glb and mannequinvar3.glb use different bone names).
func _vturn(sk: Skeleton3D, vbones: Dictionary, bone: String, rot: Basis, pivot := Vector3.INF) -> void:
	var i: int = vbones[bone]
	var g := sk.get_bone_global_rest(i)
	var rest := sk.get_bone_rest(i)
	sk.set_bone_pose_rotation(i, (rest.basis * (g.basis.inverse() * rot * g.basis)).get_rotation_quaternion())
	if pivot.is_finite():
		var parent := sk.get_bone_parent(i)
		var pg := sk.get_bone_global_rest(parent) if parent >= 0 else Transform3D.IDENTITY
		sk.set_bone_pose_position(i, pg.affine_inverse() * (pivot + rot * (g.origin - pivot)))

## How far (0..1) to turn a limb bone from where it points at rest toward straight down
func _vplant(sk: Skeleton3D, vbones: Dictionary, bone: String, k: float) -> Basis:
	var d := sk.get_bone_global_rest(vbones[bone]).basis.y.normalized()
	if d.dot(Vector3.DOWN) > 0.9999 or k <= 0.0:
		return Basis.IDENTITY
	return Basis(Quaternion.IDENTITY.slerp(Quaternion(d, Vector3.DOWN), k))

## The variant in a pose Dictionary (POSE_KEYS), the same axes and signs as part_transforms(). `vbones` and
## `profile` are the loaded variant's own (from _variants[idx]), so this works for either rig.
func pose_variant(sk: Skeleton3D, pose: Dictionary, vbones: Dictionary, profile: Dictionary, arm_l_pivot := Vector3.INF) -> void:
	sk.reset_bone_poses()
	_vturn(sk, vbones, profile.spine, Basis(Vector3.UP, pose.twist) * Basis(Vector3.RIGHT, pose.lean))
	_vturn(sk, vbones, profile.head, Basis(Vector3.UP, pose.headYaw) * Basis(Vector3.BACK, pose.headTilt) * Basis(Vector3.RIGHT, pose.headNod))
	for side in ["L", "R"]:
		var sg := 1.0 if side == "L" else -1.0
		var swing := float(pose["arm" + side])
		var arm := Basis(Vector3.BACK, float(pose["splay" + side]) * sg) * Basis(Vector3.RIGHT, -swing)
		var arm_bone: String = profile["arm" + side]
		var forearm_bone: String = profile["forearm" + side]
		_vturn(sk, vbones, arm_bone, arm, arm_l_pivot if side == "L" else Vector3.INF)
		# a raised arm reaches straight: the elbow opens until the forearm lines up with the upper arm
		# (hanging, it keeps the sculpt's bend, the hand on the hip)
		if vbones.has(forearm_bone):
			var k := smoothstep(0.5, 1.3, swing)
			if k > 0.0:
				var up := sk.get_bone_global_rest(vbones[arm_bone]).basis.y.normalized()
				var fore := sk.get_bone_global_rest(vbones[forearm_bone]).basis.y.normalized()
				_vturn(sk, vbones, forearm_bone, Basis(Quaternion.IDENTITY.slerp(Quaternion(fore, up), k)))
		var leg_bone: String = profile["leg" + side]
		_vturn(sk, vbones, leg_bone, Basis(Vector3.RIGHT, -float(pose["leg" + side])) * _vplant(sk, vbones, leg_bone, VARIANT_PLANT))

# ================================================================= poses
static func rest_pose() -> Dictionary:
	var d := {}
	for k in POSE_KEYS:
		d[k] = 0.0
	return d

static func _rot_about(pivot: Vector3, axis: Vector3, angle: float) -> Transform3D:
	var b := Basis(axis, angle)
	return Transform3D(b, pivot - b * pivot)

## Every part's transform in figure space for a pose
func part_transforms(pose: Dictionary) -> Array:
	var out: Array = []
	var lean := _rot_about(hip_pivot, Vector3.RIGHT, pose.lean)
	var twist := _rot_about(hip_pivot, Vector3.UP, pose.twist)
	for pt in parts:
		var t: Transform3D = pt.xf
		match pt.kind:
			"torso":
				t = twist * lean * t
			"head", "eyes":
				var h := _rot_about(pt.pivot, Vector3.UP, pose.headYaw) * _rot_about(pt.pivot, Vector3.BACK, pose.headTilt) \
					* _rot_about(pt.pivot, Vector3.RIGHT, pose.headNod)
				t = twist * lean * h * t
			"arm":
				var s: String = pt.side
				var swing: float = pose["arm" + s]
				var splay: float = pose["splay" + s]
				var sg := 1.0 if s == "L" else -1.0
				# align: bring the hanging arm in to vertical BEFORE it is raised, so a forward reach
				# has the hands in front of the shoulders instead of flung out to the sides
				var align: float = pose.get("align", 0.0) * float(pt.get("rest_ang", 0.0))
				var a := _rot_about(pt.pivot, Vector3.BACK, splay * sg) * _rot_about(pt.pivot, Vector3.RIGHT, -swing) \
					* _rot_about(pt.pivot, Vector3.BACK, -align * sg)
				t = twist * lean * a * t
			"leg":
				var s2: String = pt.side
				t = _rot_about(pt.pivot, Vector3.RIGHT, -float(pose["leg" + s2])) * t
		out.append(norm_xf * t)
	return out

static func random_pose(rng: RandomNumberGenerator) -> Dictionary:
	var p := rest_pose()
	p.legL = rng.randf_range(-0.12, 0.12); p.legR = rng.randf_range(-0.12, 0.12)
	p.armL = rng.randf_range(0.0, 0.35); p.armR = rng.randf_range(0.0, 0.35)
	p.splayL = rng.randf_range(0.0, 0.08); p.splayR = rng.randf_range(0.0, 0.08)
	p.headYaw = rng.randf_range(-0.6, 0.6); p.headTilt = rng.randf_range(-0.2, 0.2); p.headNod = rng.randf_range(-0.1, 0.2)
	p.lean = rng.randf_range(0.0, 0.06); p.twist = rng.randf_range(-0.1, 0.1)
	return p

## Decoys are frozen mid-something: some with an arm reaching, some with the head snapped far round,
## some lying on the floor
static func decoy_pose(rng: RandomNumberGenerator) -> Dictionary:
	var p := random_pose(rng)
	var roll := rng.randf()
	p["mode"] = "stand"
	if roll < 0.12:
		p.armL = rng.randf_range(1.3, 1.6)
	elif roll < 0.24:
		p.armR = rng.randf_range(1.3, 1.6)
	elif roll < 0.32:
		p.armL = rng.randf_range(1.3, 1.6); p.armR = rng.randf_range(1.3, 1.6)
	elif roll < 0.4:
		p.headYaw = rng.randf_range(-1.1, 1.1); p.headTilt = rng.randf_range(-0.4, 0.4)
	elif roll < 0.5:
		p["mode"] = "lie_up"       # on its back, arms to the ceiling or flopped out
		var up := rng.randf() < 0.5
		p.armL = 1.5 if up else 0.3; p.armR = 1.5 if up else 0.3
		p.splayL = rng.randf_range(0.2, 0.8); p.splayR = rng.randf_range(0.2, 0.8)
		p.legL = rng.randf_range(-0.1, 0.2); p.legR = rng.randf_range(-0.1, 0.2)
		p.lean = 0.0; p.twist = 0.0
	elif roll < 0.58:
		p["mode"] = "prone"        # face down, one or both arms reaching ahead
		p.armL = 2.8; p.armR = 2.8 if rng.randf() < 0.6 else 0.3
		p.splayL = rng.randf_range(0.1, 0.5); p.splayR = rng.randf_range(0.1, 0.5)
		p.headYaw = rng.randf_range(-1.0, 1.0)
		p.lean = 0.0; p.twist = 0.0
	elif roll < 0.66:
		p["mode"] = "side"         # curled up on its side
		p.armL = rng.randf_range(0.4, 1.0); p.armR = rng.randf_range(0.2, 0.6)
		p.legL = rng.randf_range(0.2, 0.7); p.legR = rng.randf_range(0.4, 0.9)
		p.lean = 0.0; p.twist = 0.0
	return p

## Whole-figure transform (in figure space) for a decoy's mode: lying ones are laid on the floor
static func mode_base(mode: String, rng: RandomNumberGenerator) -> Transform3D:
	match mode:
		"lie_up":
			return Transform3D(Basis(Vector3.RIGHT, -PI / 2.0), Vector3(0, 0.13, HEIGHT * 0.5))
		"prone":
			return Transform3D(Basis(Vector3.RIGHT, PI / 2.0), Vector3(0, 0.13, -HEIGHT * 0.5))
		"side":
			var roll := Basis(Vector3.BACK, PI / 2.0 * (1.0 if rng.randf() < 0.5 else -1.0))
			return Transform3D(roll * Basis(Vector3.RIGHT, -PI / 2.0), Vector3(0, 0.2, HEIGHT * 0.5))
		"sit":
			return Transform3D(Basis.IDENTITY, Vector3(0, -0.74, 0))
	return Transform3D.IDENTITY
