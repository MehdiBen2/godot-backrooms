extends Node
## Blood in the level + the fallen survivor's body (js/game/grab.js bloodFeast/bloodStep, death.js ragdoll).
## Child of the Death autoload. Droplets fly and fall, stains spread across the floor, streaks run
## down nearby walls, and a hazmat survivor topples onto its back where you stood.

const CELL := 4.5
const BLOOD_SHADER := """
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, specular_schlick_ggx;
uniform sampler2D tex : source_color, filter_linear_mipmap;
uniform vec4 region = vec4(0.0, 0.0, 1.0, 1.0);
uniform float alpha = 0.9;
uniform float seed = 0.0;
uniform bool drip = false;
void fragment() {
	vec2 uv = region.xy + UV * region.zw;
	vec3 c = texture(tex, uv).rgb;
	float m = smoothstep(0.03, 0.09, c.r);
	float mask;
	if (drip) {
		m = 1.0;
			float w = 0.16 + 0.05 * sin(UV.y * 9.0 + seed);
			float cx = 0.5 + 0.04 * sin(UV.y * 5.0 + seed * 2.0);
			mask = smoothstep(w, w * 0.55, abs(UV.x - cx)) * smoothstep(0.9, 0.78, UV.y) * smoothstep(0.0, 0.03, UV.y);
			c = vec3(0.6, 0.0, 0.0);
	} else {
		vec2 d = UV - vec2(0.5);
		float a = atan(d.y, d.x);
		float r = 0.34 + 0.11 * sin(a * 3.0 + seed) + 0.05 * sin(a * 7.0 + seed * 2.0);
		mask = smoothstep(r, r - 0.06, length(d));
	}
	ALBEDO = vec3(0.17, 0.005, 0.01) + c * vec3(0.10, 0.0, 0.0);
	ALPHA = m * mask * alpha;
	ROUGHNESS = 0.1;
	SPECULAR = 0.9;
	METALLIC = 0.05;
}
"""

var tex: Texture2D = null
var floor_y := 0.0
var _shader: Shader = null
var _decals: Array = []
var _grow: Array = []
var _drops: Array = []
var _floor_col: GPUParticlesCollisionBox3D = null
var _ragdoll: Node3D = null
var _ragdoll_t := 0.0
var _clip_played := false
var _drop_mesh: SphereMesh = null
var _drop_mat: StandardMaterial3D = null

func _ready() -> void:
	if ResourceLoader.exists("res://textures/blood/PsoSI8.png"):
		tex = load("res://textures/blood/PsoSI8.png")

func _world() -> Node:
	return get_tree().current_scene

func _wall_at(x: float, z: float) -> bool:
	var lvl = Game.level
	if lvl == null:
		return false
	return lvl.walls.has(Vector2i(roundi(x / CELL), roundi(z / CELL)))

func _material(drip: bool, alpha: float) -> ShaderMaterial:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = BLOOD_SHADER
	var m := ShaderMaterial.new()
	m.shader = _shader
	m.render_priority = 2
	m.set_shader_parameter("tex", tex)
	m.set_shader_parameter("alpha", alpha)
	m.set_shader_parameter("seed", randf() * 6.0)
	m.set_shader_parameter("drip", drip)
	if drip:
		m.set_shader_parameter("region", Vector4(0.1 + (randi() % 4) * 0.2, 0.0, 0.2, 0.36))
	else:
		m.set_shader_parameter("region", Vector4(0.02 + randf() * 0.5, 0.62 + randf() * 0.12, 0.3, 0.27))
	return m

func pool(x: float, z: float, size: float, alpha := 0.9, stretch_dir := NAN, delay := 0.0) -> void:
	if tex == null or _decals.size() > 70:
		return
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	mi.mesh = q
	mi.material_override = _material(false, alpha)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_world().add_child(mi)
	mi.rotation = Vector3(-PI / 2.0, 0.0, 0.0)
	mi.rotate_y(randf() * TAU if is_nan(stretch_dir) else stretch_dir)
	mi.global_position = Vector3(x, floor_y + 0.02 + _decals.size() * 0.0006, z)
	mi.scale = Vector3(0.05, 0.05, 0.05)
	mi.visible = delay <= 0.0
	_decals.append(mi)
	_grow.append({"m": mi, "t": -delay, "dur": 1.2 + size * 0.9, "sx": 1.0 if is_nan(stretch_dir) else 1.7, "run": false})

func wall_streak(x: float, z: float, dx: float, dz: float, y: float) -> void:
	if tex == null:
		return
	var d := 0.3
	while d < 6.0:
		if _wall_at(x + dx * d, z + dz * d):
			var h := randf_range(1.1, 2.4)
			var mi := MeshInstance3D.new()
			var q := QuadMesh.new()
			q.size = Vector2(h * 0.9, h)
			q.center_offset = Vector3(0.0, -h / 2.0, 0.0)   # hangs from its top edge
			mi.mesh = q
			mi.material_override = _material(true, 0.92)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_world().add_child(mi)
			mi.global_position = Vector3(x + dx * (d - 0.06), y + h * 0.4, z + dz * (d - 0.06))
			mi.rotation.y = atan2(dx, dz) + PI   # faces back into the room
			mi.scale = Vector3(1.0, 0.08, 1.0)
			_decals.append(mi)
			_grow.append({"m": mi, "t": -randf() * 0.4, "dur": randf_range(4.0, 7.0), "sx": 1.0, "run": true})
			return
		d += 0.25

func drop(pos: Vector3, vel: Vector3, size: float) -> void:
	if _drop_mesh == null:
		_drop_mesh = SphereMesh.new()
		_drop_mesh.radius = 1.0
		_drop_mesh.height = 2.0
		_drop_mesh.radial_segments = 8
		_drop_mesh.rings = 6
		_drop_mat = StandardMaterial3D.new()
		_drop_mat.albedo_color = Color(0.42, 0.016, 0.03)
		_drop_mat.roughness = 0.15
	var mi := MeshInstance3D.new()
	mi.mesh = _drop_mesh
	mi.material_override = _drop_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_world().add_child(mi)
	mi.global_position = pos
	mi.scale = Vector3.ONE * size
	_drops.append({"m": mi, "v": vel, "size": size})

## The bite / snap: a spray from the head, a spreading pool under the feast and under you,
## blood thrown across the nearest walls.
func feast(head: Vector3, victim: Vector3) -> void:
	floor_y = victim.y
	# no flying droplets: the splatter lands straight on the floor as stains
	for i in 22:
		var a := randf() * TAU
		var d := randf_range(0.5, 4.5)
		pool(head.x + cos(a) * d, head.z + sin(a) * d, randf_range(0.2, 0.7), 0.9, a if randf() < 0.5 else NAN, randf_range(0.0, 0.5))
	pool(head.x, head.z, randf_range(2.8, 3.6), 0.95)
	pool(victim.x, victim.z, randf_range(2.4, 3.2), 0.95, NAN, 0.3)
	for i in 6:
		var a := randf() * TAU
		var d := randf_range(0.6, 2.8)
		pool(head.x + cos(a) * d, head.z + sin(a) * d, randf_range(0.7, 2.1), 0.9, NAN, randf_range(0.15, 0.75))

## A fast burst of blood thrown out of `origin` toward `toward` (a direction): a heavy spray of
## beads plus a finer mist. Short-lived and vanishes on the floor, so it never hangs in the air.
func spray(origin: Vector3, toward: Vector3) -> void:
	_ensure_floor_collider(origin)
	var dir := (toward.normalized() + Vector3(0, 0.35, 0)).normalized()
	_emit(origin, dir, 150, 0.9, 2.5, 8.5, 70.0, 0.022, 0.06, Color(0.17, 0.004, 0.012), 0.1)
	_emit(origin, dir, 90, 0.55, 5.0, 11.0, 55.0, 0.008, 0.02, Color(0.24, 0.01, 0.02), 0.25)

func _ensure_floor_collider(near: Vector3) -> void:
	if _floor_col == null or not is_instance_valid(_floor_col):
		_floor_col = GPUParticlesCollisionBox3D.new()
		_world().add_child(_floor_col)
	_floor_col.size = Vector3(80.0, 0.2, 80.0)
	_floor_col.global_position = Vector3(near.x, floor_y - 0.1, near.z)

func _emit(origin: Vector3, dir: Vector3, amount: int, life: float, vmin: float, vmax: float,
		spread: float, smin: float, smax: float, col: Color, rough: float) -> void:
	var p := GPUParticles3D.new()
	p.amount = amount
	p.lifetime = life
	p.one_shot = true
	p.explosiveness = 0.95
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3(-30, -10, -30), Vector3(60, 30, 60))
	var pm := ParticleProcessMaterial.new()
	pm.direction = dir
	pm.spread = spread
	pm.initial_velocity_min = vmin
	pm.initial_velocity_max = vmax
	pm.gravity = Vector3(0, -15.0, 0)
	pm.damping_min = 0.4
	pm.damping_max = 1.2
	pm.scale_min = smin / 0.03
	pm.scale_max = smax / 0.03
	pm.collision_mode = ParticleProcessMaterial.COLLISION_HIDE_ON_CONTACT
	p.process_material = pm
	# elongated droplets, stretched along their flight
	pm.particle_flag_align_y = true
	var m := CapsuleMesh.new()
	m.radius = 0.012
	m.height = 0.11
	m.radial_segments = 6
	m.rings = 2
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.roughness = rough
	m.material = mat
	p.draw_pass_1 = m
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_world().add_child(p)
	p.global_position = origin
	p.emitting = true
	get_tree().create_timer(life + 1.0).timeout.connect(p.queue_free)

func _process(delta: float) -> void:
	for gr in _grow:
		gr.t += delta
		if gr.t < 0.0:
			continue
		var mi: MeshInstance3D = gr.m
		if not is_instance_valid(mi):
			gr["done"] = true
			continue
		mi.visible = true
		var k := minf(1.0, gr.t / gr.dur)
		var e := 1.0 - pow(1.0 - k, 1.6 if gr.run else 3.0)
		if gr.run:
			mi.scale = Vector3(1.0, 0.08 + 0.92 * e, 1.0)
		else:
			mi.scale = Vector3(0.05 + 0.95 * e * gr.sx, 0.05 + 0.95 * e, 1.0)
		if k >= 1.0:
			gr["done"] = true
	_grow = _grow.filter(func(g): return not g.has("done"))
	for d in _drops:
		var mi: MeshInstance3D = d.m
		if not is_instance_valid(mi):
			d["dead"] = true
			continue
		d.v.y -= 9.8 * delta
		mi.global_position += d.v * delta
		mi.scale = Vector3(d.size, d.size * (1.0 + minf(2.2, absf(d.v.y) * 0.16)), d.size)
		var p := mi.global_position
		var hit_floor := p.y <= floor_y + 0.03
		if hit_floor or _wall_at(p.x, p.z):
			if hit_floor and randf() < 0.6:
				var speed := Vector2(d.v.x, d.v.z).length()
				pool(p.x, p.z, 0.16 + d.size * 6.0 + randf() * 0.25, 0.9, atan2(d.v.z, d.v.x) if speed > 2.0 else NAN)
			mi.queue_free()
			d["dead"] = true
	_drops = _drops.filter(func(d): return not d.has("dead"))
	# the body topples backwards, accelerating like dead weight
	if _ragdoll != null and is_instance_valid(_ragdoll) and not _clip_played:
		_ragdoll_t = minf(1.0, _ragdoll_t + delta * (0.6 + _ragdoll_t * 3.0))
		_ragdoll.rotation.x = -_ragdoll_t * _ragdoll_t * 1.5

## A hazmat survivor stands where you were and falls onto its back.
func _hazmat_scene() -> PackedScene:
	var path := "res://models/entities/hazmat.glb"
	if ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_LOADED:
		return ResourceLoader.load_threaded_get(path) as PackedScene
	return load(path) as PackedScene

## Draw one tiny decal and one tiny burst in front of the camera so their shaders / pipelines are built now.
func warm() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or tex == null:
		return
	var at := cam.global_position + (-cam.global_basis.z) * 2.0
	floor_y = at.y - 0.3
	pool(at.x, at.z, 0.1, 0.02)
	_ensure_floor_collider(at)
	_emit(at, Vector3.UP, 6, 0.3, 0.5, 1.0, 20.0, 0.01, 0.015, Color(0.2, 0.0, 0.01), 0.1)
	await get_tree().create_timer(0.7).timeout
	clear()
	floor_y = 0.0

func spawn_ragdoll(pos: Vector3, yaw: float) -> void:
	var packed := _hazmat_scene()
	if packed == null:
		return
	var root: Node3D = packed.instantiate()
	_ragdoll = Node3D.new()
	_world().add_child(_ragdoll)
	_ragdoll.add_child(root)
	var box := AABB()
	var first := true
	for m in root.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var t := Transform3D.IDENTITY
		var n: Node = mi
		while n != null and n != _ragdoll:
			if n is Node3D:
				t = (n as Node3D).transform * t
			n = n.get_parent()
		var b := t * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	if box.size.y > 0.0:
		var sc := 1.8 / box.size.y
		var c := box.get_center()
		var flip := Basis(Vector3.UP, PI)
		root.transform = Transform3D(flip * Basis.from_scale(Vector3(sc, sc, sc)), flip * (Vector3(-c.x, -box.position.y, -c.z) * sc))
	# hazmat.glb ships a 'death' clip that does the falling; play it once and hold the last frame
	_clip_played = false
	for ap in root.find_children("*", "AnimationPlayer", true, false):
		var player := ap as AnimationPlayer
		player.stop()
		for a in player.get_animation_list():
			if String(a).to_lower().contains("death"):
				player.get_animation(a).loop_mode = Animation.LOOP_NONE
				player.play(a)
				_clip_played = true
				break
		if _clip_played:
			break
	_ragdoll.global_position = pos
	_ragdoll.rotation.y = yaw
	_ragdoll_t = 0.0

func clear() -> void:
	for mi in _decals:
		if is_instance_valid(mi):
			mi.queue_free()
	for d in _drops:
		if is_instance_valid(d.m):
			d.m.queue_free()
	_decals.clear()
	_drops.clear()
	_grow.clear()
	if _ragdoll != null and is_instance_valid(_ragdoll):
		_ragdoll.queue_free()
	_ragdoll = null
	if _floor_col != null and is_instance_valid(_floor_col):
		_floor_col.queue_free()
	_floor_col = null
