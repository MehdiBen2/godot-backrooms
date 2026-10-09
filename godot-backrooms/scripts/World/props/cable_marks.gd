extends Node3D
## Every 3D equipment cable placed on this level's floors, walls, and structures.
## Equipment cables are permanent 3D meshes (cylindrical conduits with end connectors,
## rolling waviness, and dynamic 3D stacking when drawn over each other or in coils).
## Saved per level in levels/marks/<level_id>.json under "cables" via mark_store.gd.

const MarkStore := preload("res://scripts/World/props/mark_store.gd")
const SHADER := preload("res://shaders/cable.gdshader")

const RADIAL_SEGS := 12
const STEP := 0.05                   # m between path points
const ERASE_RADIUS := 0.28           # m radius around cursor to erase a cable
const MAX_PER_LEVEL := 400
const MAX_TRASH := 1000

const TYPES := {
	"heavy_black": {
		"name": "HEAVY BLACK",
		"color": Color("1f2024"),
		"style": 0,
		"roughness": 0.50,
		"metallic": 0.02,
		"rib_freq": 0.0,
		"default_r": 0.038
	},
	"yellow_ext": {
		"name": "SITE YELLOW",
		"color": Color("e8a816"),
		"style": 0,
		"roughness": 0.42,
		"metallic": 0.02,
		"rib_freq": 0.0,
		"default_r": 0.028
	},
	"hi_volt_orange": {
		"name": "HIGH-VOLT ORANGE",
		"color": Color("e84e12"),
		"style": 0,
		"roughness": 0.44,
		"metallic": 0.02,
		"rib_freq": 0.0,
		"default_r": 0.034
	},
	"data_snake": {
		"name": "DATA SNAKE",
		"color": Color("1a355c"),
		"style": 3,
		"roughness": 0.48,
		"metallic": 0.02,
		"rib_freq": 0.0,
		"default_r": 0.042
	},
	"ribbed_conduit": {
		"name": "ARMORED CONDUIT",
		"color": Color("545860"),
		"style": 1,
		"roughness": 0.30,
		"metallic": 0.88,
		"rib_freq": 36.0,
		"default_r": 0.036
	},
	"hazard_striped": {
		"name": "HAZARD STRIPED",
		"color": Color(1.0, 1.0, 1.0),
		"style": 2,
		"roughness": 0.38,
		"metallic": 0.02,
		"rib_freq": 0.0,
		"default_r": 0.032
	}
}
const TYPE_KEYS := ["heavy_black", "yellow_ext", "hi_volt_orange", "data_snake", "ribbed_conduit", "hazard_striped"]

static var placed := {}              # MarkStore.key() -> Array of cable dictionaries
static var live = null
static var _loaded := {}
static var _materials := {}

var level_id := ""
var meshes := {}                     # id -> MeshInstance3D
var colliders := {}                  # id -> StaticBody3D
var _undo: Array = []
var _redo: Array = []

func _ready() -> void:
	live = self
	_load()

func reload_floor() -> void:
	for m in meshes.values():
		if is_instance_valid(m):
			m.queue_free()
	for c in colliders.values():
		if is_instance_valid(c):
			c.queue_free()
	meshes.clear()
	colliders.clear()
	_undo.clear()
	_redo.clear()
	_load()

func _exit_tree() -> void:
	if live == self:
		live = null

func count() -> int:
	return placed.get(MarkStore.key(), []).size()

## Read saved cables into `placed`
func _load() -> void:
	MarkStore.use_level(get_parent())
	level_id = MarkStore.file_id(str(get_parent().level_meta.get("id", "")))
	var lv := MarkStore.key()
	if not _loaded.has(lv):
		_loaded[lv] = true
		var list: Array = placed.get(lv, [])
		var file := MarkStore.read(level_id)
		var off := MarkStore.moved(file, "cables")
		list.append_array(_shifted(_unpack(file.get("cables", [])), off))
		placed[lv] = list
	_spawn_all(lv)

func _spawn_all(lv: int) -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	if not is_inside_tree():
		return
	_settle_all(lv)
	for c in placed.get(lv, []):
		if not meshes.has(c.id):
			_spawn(c)

func _settle_all(lv: int) -> void:
	var list: Array = placed.get(lv, [])
	var space := get_world_3d().direct_space_state
	var changed := false
	for c in list:
		var n: Vector3 = c.get("n", Vector3.UP)
		var pts: Array = c.get("pts", [])
		if pts.is_empty():
			continue
		var at := MarkStore.settle(space, pts, n)
		if not at.is_empty() and at.moved:
			c["pts"] = at.pts
			c["n"] = at.n
			changed = true
	if changed:
		save()

const TEX_RUBBER_COLOR := "res://textures/pbr/Road_Asphalt_Yellow_Lines/Road_Asphalt_Yellow_Lines_Color.jpg"
const TEX_RUBBER_NORMAL := "res://textures/pbr/Road_Asphalt_Yellow_Lines/Road_Asphalt_Yellow_Lines_NormalGL.jpg"
const TEX_RUBBER_ROUGH := "res://textures/pbr/Road_Asphalt_Yellow_Lines/Road_Asphalt_Yellow_Lines_Roughness.jpg"
const TEX_RUBBER_AO := "res://textures/pbr/Road_Asphalt_Yellow_Lines/Road_Asphalt_Yellow_Lines_AmbientOcclusion.jpg"
const TEX_METAL_COLOR := "res://textures/pbr/Metal_Dark_Plate/Metal_Dark_Plate_Color.jpg"
const TEX_METAL_NORMAL := "res://textures/pbr/Metal_Dark_Plate/Metal_Dark_Plate_NormalGL.jpg"
const TEX_METAL_ROUGH := "res://textures/pbr/Metal_Dark_Plate/Metal_Dark_Plate_Roughness.jpg"
const TEX_HAZARD := "res://textures/items/hazard_tapes/hazardous_tapes.jpg"

static var _plug_mat: StandardMaterial3D

## Returns a shared StandardMaterial3D configured for a cable type with full PBR textures
static func get_material(type_key: String) -> Material:
	if not TYPES.has(type_key):
		type_key = "heavy_black"
	if _materials.has(type_key):
		return _materials[type_key]
	var info: Dictionary = TYPES[type_key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = info.color
	mat.roughness = info.roughness
	mat.metallic = info.metallic
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	mat.diffuse_mode = BaseMaterial3D.DIFFUSE_BURLEY
	mat.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX

	if type_key == "hazard_striped" and ResourceLoader.exists(TEX_HAZARD):
		mat.albedo_texture = load(TEX_HAZARD)
		mat.uv1_scale = Vector3(1.0, 4.0, 1.0)
		if ResourceLoader.exists(TEX_RUBBER_NORMAL):
			mat.normal_enabled = true
			mat.normal_texture = load(TEX_RUBBER_NORMAL)
			mat.normal_scale = 0.8
		if ResourceLoader.exists(TEX_RUBBER_ROUGH):
			mat.roughness_texture = load(TEX_RUBBER_ROUGH)
		mat.rim_enabled = true
		mat.rim = 0.3
	elif type_key == "ribbed_conduit":
		if ResourceLoader.exists(TEX_METAL_COLOR):
			mat.albedo_texture = load(TEX_METAL_COLOR)
		if ResourceLoader.exists(TEX_METAL_NORMAL):
			mat.normal_enabled = true
			mat.normal_texture = load(TEX_METAL_NORMAL)
			mat.normal_scale = 1.4
		if ResourceLoader.exists(TEX_METAL_ROUGH):
			mat.roughness_texture = load(TEX_METAL_ROUGH)
		mat.uv1_scale = Vector3(1.0, 12.0, 1.0)
	else:
		# Industrial vulcanized rubber cables (heavy black, site yellow, hi-volt orange, data snake)
		if ResourceLoader.exists(TEX_RUBBER_COLOR):
			mat.albedo_texture = load(TEX_RUBBER_COLOR)
		if ResourceLoader.exists(TEX_RUBBER_NORMAL):
			mat.normal_enabled = true
			mat.normal_texture = load(TEX_RUBBER_NORMAL)
			mat.normal_scale = 1.15
		if ResourceLoader.exists(TEX_RUBBER_ROUGH):
			mat.roughness_texture = load(TEX_RUBBER_ROUGH)
		if ResourceLoader.exists(TEX_RUBBER_AO):
			mat.ao_enabled = true
			mat.ao_texture = load(TEX_RUBBER_AO)
			mat.ao_light_affect = 0.55
		mat.rim_enabled = true
		mat.rim = 0.28
		mat.rim_tint = 0.15
		mat.uv1_scale = Vector3(1.0, 5.0, 1.0)

	_materials[type_key] = mat
	return mat

static func get_plug_material() -> StandardMaterial3D:
	if _plug_mat == null:
		_plug_mat = StandardMaterial3D.new()
		_plug_mat.albedo_color = Color("c2c6cc")
		_plug_mat.metallic = 0.95
		_plug_mat.roughness = 0.22
		if ResourceLoader.exists(TEX_METAL_NORMAL):
			_plug_mat.normal_enabled = true
			_plug_mat.normal_texture = load(TEX_METAL_NORMAL)
			_plug_mat.normal_scale = 0.65
		if ResourceLoader.exists(TEX_METAL_ROUGH):
			_plug_mat.roughness_texture = load(TEX_METAL_ROUGH)
	return _plug_mat

## Find height elevation if pos passes over any existing cables (or loop back)
static func get_stack_elevation(pos: Vector3, norm: Vector3, my_r: float, ignore_id := "") -> float:
	if live == null:
		return 0.0
	var key := MarkStore.key()
	var list: Array = placed.get(key, [])
	var max_elev := 0.0
	for c in list:
		if c.id == ignore_id:
			continue
		var other_r: float = float(c.get("r", 0.035))
		var pts: Array = c.get("pts", [])
		var p_count := pts.size()
		if p_count < 2:
			continue
		for i in range(p_count - 1):
			var a: Vector3 = pts[i]
			var b: Vector3 = pts[i + 1]
			var seg := b - a
			var l2 := seg.length_squared()
			if l2 < 0.00001:
				continue
			var t := clampf((pos - a).dot(seg) / l2, 0.0, 1.0)
			var proj := a + seg * t

			# Project into surface plane perpendicular to normal
			var diff := proj - pos
			var diff_along_n := diff.dot(norm)
			var perp_vec := diff - norm * diff_along_n
			var perp_dist := perp_vec.length()

			# Bridge geometry:
			# R_crest is the full contact overlap region where 100% elevation clearance is required.
			# R_bridge is the outer catenary ramp where the cable smoothly lifts off and lands.
			var r_crest := (my_r + other_r) * 1.15
			var r_bridge := r_crest + 0.20
			if perp_dist < r_bridge:
				var other_top := diff_along_n + other_r
				var req_center := other_top + my_r + 0.006
				var needed_elev := maxf(0.0, req_center - (my_r * 1.12))
				var elev := 0.0
				if perp_dist <= r_crest:
					elev = needed_elev
				else:
					var ramp_t := (perp_dist - r_crest) / (r_bridge - r_crest)
					var factor := cos(ramp_t * (PI * 0.5))
					factor *= factor
					elev = needed_elev * factor
				if elev > max_elev:
					max_elev = elev
	return max_elev

## Add a new cable path to the current floor
func add(pts: Array, n: Vector3, st: Dictionary) -> void:
	if pts.size() < 2:
		return
	var type_key: String = st.get("type", "heavy_black")
	if type_key == "random" or not TYPES.has(type_key):
		type_key = TYPE_KEYS[randi() % TYPE_KEYS.size()]
	var r: float = float(st.get("r", TYPES[type_key].default_r))
	var roll: float = float(st.get("roll", 0.5))
	var stack: int = int(st.get("stack", 0))
	var id: String = "%08x%08x" % [randi(), randi()]
	var c := {
		"id": id,
		"pts": pts,
		"n": n,
		"r": r,
		"type": type_key,
		"roll": roll,
		"stack": stack,
		"t": Time.get_unix_time_from_system()
	}
	var key := MarkStore.key()
	if not placed.has(key):
		placed[key] = []
	placed[key].append(c)
	_spawn(c)
	if placed[key].size() > MAX_PER_LEVEL:
		_drop_mesh(placed[key].pop_front().id)
	_done({"op": "add", "c": c})
	save()

func _spawn(c: Dictionary) -> void:
	var mi := MeshInstance3D.new()
	var mesh := ArrayMesh.new()
	build_cable_mesh(c.pts, c.n, float(c.r), str(c.type), float(c.roll), Vector3.ZERO, mesh)
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	add_child(mi)
	meshes[c.id] = mi

	# Segment capsule/box colliders for eraser and physics interaction
	var body := StaticBody3D.new()
	body.set_meta("cable_id", c.id)
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	colliders[c.id] = body
	_build_collision_shapes(body, c.pts, float(c.r))

func _build_collision_shapes(body: StaticBody3D, pts: Array, r: float) -> void:
	var count := pts.size()
	if count < 2:
		return
	var step := maxi(1, count / 24)
	for i in range(0, count - 1, step):
		var next_i := mini(i + step, count - 1)
		var a: Vector3 = pts[i]
		var b: Vector3 = pts[next_i]
		var seg_len := a.distance_to(b)
		if seg_len < 0.001:
			continue
		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(r * 2.2, r * 2.2, seg_len + r)
		col.shape = box
		body.add_child(col)
		col.global_position = (a + b) * 0.5
		var dir := (b - a).normalized()
		var up_axis := Vector3.UP if absf(dir.y) < 0.88 else Vector3.FORWARD
		col.look_at(col.global_position + dir, up_axis)

func _drop_mesh(id: String) -> void:
	if meshes.has(id) and is_instance_valid(meshes[id]):
		meshes[id].queue_free()
		meshes.erase(id)
	if colliders.has(id) and is_instance_valid(colliders[id]):
		colliders[id].queue_free()
		colliders.erase(id)

## Remove cable closest to point `p` within reach
func remove_near(p: Vector3, max_dist := ERASE_RADIUS) -> bool:
	var list: Array = placed.get(MarkStore.key(), [])
	var best_idx := -1
	var best_dist := max_dist
	for i in range(list.size() - 1, -1, -1):
		var c: Dictionary = list[i]
		var pts: Array = c.get("pts", [])
		for pt in pts:
			var d := (pt as Vector3).distance_to(p)
			if d < best_dist:
				best_dist = d
				best_idx = i
	if best_idx >= 0:
		var c: Dictionary = list[best_idx]
		list.remove_at(best_idx)
		_drop_mesh(c.id)
		_done({"op": "del", "c": c, "i": best_idx})
		save()
		return true
	return false

func undo() -> bool:
	if _undo.is_empty():
		return false
	var act: Dictionary = _undo.pop_back()
	_redo.append(act)
	var key := MarkStore.key()
	var list: Array = placed.get(key, [])
	match act.op:
		"add":
			var c: Dictionary = act.c
			for i in list.size():
				if list[i].id == c.id:
					list.remove_at(i)
					_drop_mesh(c.id)
					break
		"del":
			var c: Dictionary = act.c
			list.insert(mini(int(act.i), list.size()), c)
			_spawn(c)
		"clear":
			for c in act.list:
				list.append(c)
				_spawn(c)
	save()
	return true

func redo() -> bool:
	if _redo.is_empty():
		return false
	var act: Dictionary = _redo.pop_back()
	_undo.append(act)
	var key := MarkStore.key()
	var list: Array = placed.get(key, [])
	match act.op:
		"add":
			var c: Dictionary = act.c
			list.append(c)
			_spawn(c)
		"del":
			var c: Dictionary = act.c
			for i in list.size():
				if list[i].id == c.id:
					list.remove_at(i)
					_drop_mesh(c.id)
					break
		"clear":
			for c in act.list:
				_drop_mesh(c.id)
			list.clear()
	save()
	return true

func clear_all() -> void:
	var key := MarkStore.key()
	var list: Array = placed.get(key, [])
	if list.is_empty():
		return
	var backup := list.duplicate()
	for c in list:
		_drop_mesh(c.id)
	list.clear()
	_done({"op": "clear", "list": backup})
	save()

func _done(act: Dictionary) -> void:
	_undo.append(act)
	_redo.clear()

## Save all cables on this floor to disk
func save() -> bool:
	level_id = MarkStore.file_id(str(get_parent().level_meta.get("id", "")))
	return MarkStore.write(level_id, "cables", _pack(placed.get(MarkStore.key(), [])))

func _pack(list: Array) -> Array:
	var out: Array = []
	for c in list:
		var pts: Array = []
		for p in c.pts:
			pts.append(MarkStore.arr(p))
		out.append({
			"id": c.id,
			"pts": pts,
			"n": MarkStore.arr(c.get("n", Vector3.UP)),
			"r": snappedf(float(c.get("r", 0.035)), 0.001),
			"type": str(c.get("type", "heavy_black")),
			"roll": snappedf(float(c.get("roll", 0.5)), 0.01),
			"stack": int(c.get("stack", 0)),
			"t": float(c.get("t", 0.0))
		})
	return out

func _unpack(data: Array) -> Array:
	var out: Array = []
	for d in data:
		var pts: Array = []
		for p in d.get("pts", []):
			pts.append(MarkStore.v3(p))
		out.append({
			"id": str(d.get("id", "")),
			"pts": pts,
			"n": MarkStore.v3(d.get("n", [0, 1, 0])),
			"r": float(d.get("r", 0.035)),
			"type": str(d.get("type", "heavy_black")),
			"roll": float(d.get("roll", 0.5)),
			"stack": int(d.get("stack", 0)),
			"t": float(d.get("t", 0.0))
		})
	return out

func _shifted(list: Array, off: Vector3) -> Array:
	if off != Vector3.ZERO:
		for c in list:
			for i in c.pts.size():
				c.pts[i] += off
	return list

# ---------------------------------------------------------------- 3D Mesh Generation
## Builds a 3D cylindrical tube along `pts` with Bishop rotation-minimizing frame,
## physical rolling twist, and molded connector boots at both ends.
## Uses Surface 0 for the PBR cable jacket and Surface 1 for polished metal plug connectors.
static func build_cable_mesh(pts: Array, n: Vector3, r: float, type_key: String, roll: float, origin := Vector3.ZERO, mesh: ArrayMesh = null) -> ArrayMesh:
	if mesh == null:
		mesh = ArrayMesh.new()
	mesh.clear_surfaces()
	if pts.size() < 2:
		return mesh

	var smoothed := _smooth(pts, n, r)
	var count := smoothed.size()

	# Compute cumulative arc-length distances
	var dist: Array[float] = [0.0]
	for i in range(1, count):
		dist.append(dist[i - 1] + (smoothed[i] as Vector3).distance_to(smoothed[i - 1]))
	var total_len: float = dist[-1]

	# Tangents
	var tangents: Array[Vector3] = []
	for i in count:
		var t := Vector3.ZERO
		if i == 0:
			t = (smoothed[1] - smoothed[0]).normalized()
		elif i == count - 1:
			t = (smoothed[count - 1] - smoothed[count - 2]).normalized()
		else:
			t = ((smoothed[i + 1] - smoothed[i]) + (smoothed[i] - smoothed[i - 1])).normalized()
		if t.length_squared() < 0.001:
			t = Vector3.FORWARD
		tangents.append(t)

	# Parallel Transport (Bishop Frames)
	var normals: Array[Vector3] = []
	var binormals: Array[Vector3] = []
	var initial_n := n - tangents[0] * n.dot(tangents[0])
	if initial_n.length_squared() < 0.01:
		initial_n = Vector3.UP.cross(tangents[0])
		if initial_n.length_squared() < 0.01:
			initial_n = Vector3.RIGHT.cross(tangents[0])
	initial_n = initial_n.normalized()
	normals.append(initial_n)
	binormals.append(tangents[0].cross(initial_n).normalized())

	for i in range(1, count):
		var t_prev: Vector3 = tangents[i - 1]
		var t_curr: Vector3 = tangents[i]
		var axis := t_prev.cross(t_curr)
		var prev_n: Vector3 = normals[i - 1]
		if axis.length_squared() > 0.0001:
			var angle := t_prev.angle_to(t_curr)
			var cur_n := prev_n.rotated(axis.normalized(), angle)
			cur_n = (cur_n - t_curr * cur_n.dot(t_curr)).normalized()
			normals.append(cur_n)
		else:
			normals.append(prev_n)
		binormals.append(tangents[i].cross(normals[i]).normalized())

	# ---------------- Surface 0: Cable Jacket Cylinder
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var v_idx := 0

	var ring_verts: Array = []
	var connector_len := minf(0.12, total_len * 0.25)

	# Generate cylinder rings
	for i in count:
		var p: Vector3 = smoothed[i] - origin
		var t_dist: float = dist[i]
		var cur_n: Vector3 = normals[i]
		var cur_b: Vector3 = binormals[i]

		# Natural rolling twist rotation
		var twist_angle: float = roll * t_dist * 4.0
		var cos_tw := cos(twist_angle)
		var sin_tw := sin(twist_angle)
		var rn := cur_n * cos_tw + cur_b * sin_tw
		var rb := -cur_n * sin_tw + cur_b * cos_tw

		# Molded rubber strain-relief boot flare at ends
		var end_mask := 0.0
		var r_mult := 1.0
		if t_dist < connector_len:
			end_mask = 1.0 - (t_dist / connector_len)
			r_mult = 1.0 + end_mask * 0.35
		elif (total_len - t_dist) < connector_len:
			end_mask = 1.0 - ((total_len - t_dist) / connector_len)
			r_mult = 1.0 + end_mask * 0.35

		var cur_r := r * r_mult
		var ring: Array[int] = []

		for j in range(RADIAL_SEGS + 1):
			var phi := (float(j) / float(RADIAL_SEGS)) * TAU
			var rad_dir := (rn * cos(phi) + rb * sin(phi)).normalized()
			var vpos := p + rad_dir * cur_r
			var uv := Vector2(float(j) / float(RADIAL_SEGS), t_dist)

			tool.set_normal(rad_dir)
			tool.set_uv(uv)
			tool.set_color(Color(end_mask, 0.0, 0.0, 1.0))
			tool.add_vertex(vpos)
			ring.append(v_idx)
			v_idx += 1

		ring_verts.append(ring)

	# Build cylinder tube triangles
	for i in range(count - 1):
		var r0: Array = ring_verts[i]
		var r1: Array = ring_verts[i + 1]
		for j in range(RADIAL_SEGS):
			var a: int = r0[j]
			var b: int = r0[j + 1]
			var c: int = r1[j + 1]
			var d: int = r1[j]
			tool.add_index(a)
			tool.add_index(b)
			tool.add_index(c)
			tool.add_index(a)
			tool.add_index(c)
			tool.add_index(d)

	tool.generate_tangents()
	tool.commit(mesh)

	# ---------------- Surface 1: Molded Industrial Metal End Plugs
	var plug_tool := SurfaceTool.new()
	plug_tool.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Start cap (flat metal plug end)
	var p_start: Vector3 = smoothed[0] - origin
	var t_start: Vector3 = -tangents[0]
	var r_start_val := r * 1.35
	plug_tool.set_normal(t_start)
	plug_tool.set_uv(Vector2(0.5, 0.5))
	plug_tool.add_vertex(p_start) # index 0

	var rn0: Vector3 = normals[0]
	var rb0: Vector3 = binormals[0]
	for j in range(RADIAL_SEGS + 1):
		var phi := (float(j) / float(RADIAL_SEGS)) * TAU
		var rad_dir := (rn0 * cos(phi) + rb0 * sin(phi)).normalized()
		plug_tool.set_normal(t_start)
		plug_tool.set_uv(Vector2(cos(phi) * 0.5 + 0.5, sin(phi) * 0.5 + 0.5))
		plug_tool.add_vertex(p_start + rad_dir * r_start_val)

	for j in range(RADIAL_SEGS):
		plug_tool.add_index(0)
		plug_tool.add_index(j + 2)
		plug_tool.add_index(j + 1)

	# End cap (flat metal plug end)
	var p_end: Vector3 = smoothed[-1] - origin
	var t_end: Vector3 = tangents[-1]
	var r_end_val := r * 1.35
	var base_end_idx := RADIAL_SEGS + 2
	plug_tool.set_normal(t_end)
	plug_tool.set_uv(Vector2(0.5, 0.5))
	plug_tool.add_vertex(p_end) # index base_end_idx

	var rn1: Vector3 = normals[-1]
	var rb1: Vector3 = binormals[-1]
	for j in range(RADIAL_SEGS + 1):
		var phi := (float(j) / float(RADIAL_SEGS)) * TAU
		var rad_dir := (rn1 * cos(phi) + rb1 * sin(phi)).normalized()
		plug_tool.set_normal(t_end)
		plug_tool.set_uv(Vector2(cos(phi) * 0.5 + 0.5, sin(phi) * 0.5 + 0.5))
		plug_tool.add_vertex(p_end + rad_dir * r_end_val)

	for j in range(RADIAL_SEGS):
		plug_tool.add_index(base_end_idx)
		plug_tool.add_index(base_end_idx + 1 + j)
		plug_tool.add_index(base_end_idx + 2 + j)

	plug_tool.generate_tangents()
	plug_tool.commit(mesh)

	mesh.surface_set_material(0, get_material(type_key))
	mesh.surface_set_material(1, get_plug_material())
	return mesh

## Smooth path points horizontally while strictly preserving clearance height over floors and obstacles
static func _smooth(pts: Array, n: Vector3, r: float) -> Array:
	var out := pts.duplicate()
	if out.size() < 4:
		return out

	# Record original height offsets along surface normal
	var orig_heights: Array[float] = []
	for p in pts:
		orig_heights.append((p as Vector3).dot(n))

	for pass_ in 2:
		var prev := out.duplicate()
		for i in range(1, out.size() - 1):
			var smoothed_pt: Vector3 = (prev[i - 1] as Vector3) * 0.25 + (prev[i] as Vector3) * 0.5 + (prev[i + 1] as Vector3) * 0.25
			# Ensure height along normal never drops below original clearance
			var cur_h := smoothed_pt.dot(n)
			var target_h := orig_heights[i]
			if cur_h < target_h:
				smoothed_pt += n * (target_h - cur_h)
			out[i] = smoothed_pt
	return out
