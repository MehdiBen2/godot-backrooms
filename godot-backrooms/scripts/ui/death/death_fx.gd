extends Node
## Blood in the level + the fallen survivor's body (js/game/grab.js bloodFeast/bloodStep, death.js ragdoll).
## Child of the Death autoload. Droplets fly and fall, stains spread across the floor, streaks run
## down nearby walls, and a hazmat survivor topples onto its back where you stood.
##
## The splatter follows the "improved blood decals" approach (reddit r/godot 143g7cz): a blob of blood
## is a RigidBody3D carrying a wobbling-sphere MeshInstance3D and a RayCast3D; it is flung into a random
## direction, arcs under gravity, and when its ray finds a wall / floor / ceiling the ray's normal is
## used to lay a decal on that surface. The decal is a thin BoxMesh with a custom decal shader (not a
## Decal node, so every parameter is ours): world-space triplanar noise makes the blood pool in patches
## and keeps overlapping splats aligned (no z-fighting), a centre-fade mask plus a Tween `grow` parameter
## spreads the splat outward, and the albedo fades from bright oxygenated red to a dark dried red.

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

# The flying blob: a sphere whose vertices bob around the surface so it wobbles like a loose mass of blood.
const BLOB_SHADER := """
shader_type spatial;
render_mode specular_schlick_ggx;
uniform float seed = 0.0;
void vertex() {
	float t = TIME * 10.0 + seed * 6.0;
	float k = sin(VERTEX.x * 13.0 + t) * sin(VERTEX.y * 11.0 - t * 1.4) * sin(VERTEX.z * 12.0 + t * 0.8);
	VERTEX += NORMAL * k * 0.16;
}
void fragment() {
	ALBEDO = vec3(0.45, 0.012, 0.025);
	ROUGHNESS = 0.12;
	SPECULAR = 0.85;
	METALLIC = 0.02;
}
"""

# The splat decal laid on a surface: triplanar world-space noise (pooling, aligned across overlapping
# splats), a centre-fade mask expanded by the Tween-driven `grow`, and `wet` fading bright red to dark.
const DECAL_SHADER := """
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, specular_schlick_ggx;
uniform float grow = 1.0;
uniform float wet = 1.0;
uniform float seed = 0.0;
uniform vec3 splat_normal = vec3(0.0, 1.0, 0.0);
uniform float pool_scale = 2.6;
varying vec3 wpos;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
float h21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vno(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h21(i), h21(i + vec2(1.0, 0.0)), f.x), mix(h21(i + vec2(0.0, 1.0)), h21(i + vec2(1.0, 1.0)), f.x), f.y);
}
float fbm2(vec2 p) {
	float a = 0.5, s = 0.0;
	for (int i = 0; i < 3; i++) { s += a * vno(p); p = p * 2.17 + 13.0; a *= 0.5; }
	return s;
}
// triplanar blend weighted by the surface normal, sampled at WORLD position: two splats on the same
// wall share the pooling pattern instead of fighting over depth
float tri(vec3 p) {
	vec3 w = abs(splat_normal);
	w /= max(w.x + w.y + w.z, 0.001);
	return fbm2(p.xy + seed) * w.z + fbm2(p.zy + seed * 1.7) * w.x + fbm2(p.xz - seed * 0.6) * w.y;
}
void fragment() {
	vec2 d = UV - vec2(0.5);
	float ang = atan(d.y, d.x);
	float r = length(d) * 2.0;
	float outline = 0.60 + 0.22 * sin(ang * 3.0 + seed) + 0.12 * sin(ang * 7.0 + seed * 2.3);
	float pool = clamp(0.55 + 0.85 * tri(wpos * pool_scale), 0.25, 1.35);
	float edge = max(0.004, outline * grow * pool);   // never a zero-width smoothstep (NaN flicker)
	float m = smoothstep(edge, edge * 0.55, r);
	// fine spatter flung slightly past the body of the splat (soft-thresholded so it never crawls)
	float sp = (1.0 - smoothstep(0.70, 0.80, fbm2(wpos.xz * 6.0 + seed))) * smoothstep(edge * 1.45, edge, r);
	m = max(m * (0.75 + 0.25 * pool), sp * 0.8);
	if (m < 0.02) { discard; }
	vec3 bright = vec3(0.55, 0.015, 0.02);   // oxygenated: just landed
	vec3 dark = vec3(0.13, 0.004, 0.008);    // dried
	ALBEDO = mix(dark, bright, wet) * (0.8 + 0.35 * pool);
	ALPHA = m * 0.95;
	ROUGHNESS = mix(0.42, 0.09, wet);
	SPECULAR = mix(0.25, 0.95, wet);
	METALLIC = 0.02;
}
"""

var tex: Texture2D = null
var floor_y := 0.0
var _shader: Shader = null
var _decals: Array = []
var _grow: Array = []
var _drops: Array = []
var _blobs: Array = []
var _decal_tweens: Array = []
var _blob_shader: Shader = null
var _decal_shader: Shader = null
var _blob_mesh: SphereMesh = null
var _floor_col: GPUParticlesCollisionBox3D = null
var _ragdoll: Node3D = null
var _ragdoll_t := 0.0
var _clip_played := false
var _skel: Skeleton3D = null     # the body's skeleton, so the death camera can follow the chest
var _chest := -1
var _clip: Animation = null      # the fall clip being played
## Seconds after spawn_ragdoll() at which the body's back hits the floor (read off the fall itself)
var contact_time := 0.85
var _drop_mesh: SphereMesh = null
var _drop_mat: StandardMaterial3D = null

func _ready() -> void:
	if ResourceLoader.exists("res://textures/blood/PsoSI8.png"):
		tex = load("res://textures/blood/PsoSI8.png")

# Where the blood and the body go: the running level (Game.main), which is also the current scene in a
# normal run; the fallback keeps it working when something else is current (tools, tests)
func _world() -> Node:
	if Game.main != null and is_instance_valid(Game.main):
		return Game.main
	return get_tree().current_scene if get_tree().current_scene != null else get_tree().root

func _wall_at(x: float, z: float) -> bool:
	var lvl = Game.level
	if lvl == null:
		return false
	return lvl.walls.has(Vector2i(roundi(x / CELL), roundi(z / CELL)))

func _pit_at(x: float, z: float) -> bool:
	var lvl = Game.level
	if lvl == null:
		return false
	return lvl.pits.has(Vector2i(roundi(x / CELL), roundi(z / CELL)))

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

# ───────────────────────────────────── flying blobs ────────────────────────────
## A blob of blood flung into a random direction: RigidBody3D (it arcs realistically), a wobbling
## sphere MeshInstance3D, and a RayCast3D that watches for a splatterable surface each physics tick.
func blob(pos: Vector3, vel: Vector3, size: float) -> void:
	if _blobs.size() >= 26:
		return
	if _blob_shader == null:
		_blob_shader = Shader.new()
		_blob_shader.code = BLOB_SHADER
	if _blob_mesh == null:
		_blob_mesh = SphereMesh.new()
		_blob_mesh.radius = 1.0
		_blob_mesh.height = 2.0
		_blob_mesh.radial_segments = 10
		_blob_mesh.rings = 8
	var rb := RigidBody3D.new()
	rb.collision_layer = 0            # it never bumps anything: the body only arcs under gravity
	rb.collision_mask = 1             # the RayCast3D below is what finds the splatter surface
	rb.angular_damp = 10.0
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = size
	cs.shape = sph
	rb.add_child(cs)
	var mi := MeshInstance3D.new()
	mi.mesh = _blob_mesh
	var bm := ShaderMaterial.new()
	bm.shader = _blob_shader
	bm.set_shader_parameter("seed", randf() * 6.0)
	mi.material_override = bm
	mi.scale = Vector3.ONE * size
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	rb.add_child(mi)
	var ray := RayCast3D.new()
	ray.collision_mask = 1
	rb.add_child(ray)
	_world().add_child(rb)
	rb.global_position = pos
	rb.linear_velocity = vel
	_blobs.append({"rb": rb, "ray": ray, "size": size, "t": 0.0})

## Step every flying blob: aim its ray along its travel, and splatter on the first surface found.
func _physics_process(delta: float) -> void:
	for b in _blobs:
		var rb: RigidBody3D = b.rb
		if not is_instance_valid(rb):
			b["dead"] = true
			continue
		b.t += delta
		var p := rb.global_position
		var v := rb.linear_velocity
		var speed := v.length()
		var dir := v / speed if speed > 0.2 else Vector3.DOWN
		var ray: RayCast3D = b.ray
		ray.target_position = ray.to_local(p + dir * (b.size * 1.8 + speed * delta * 2.0 + 0.05))
		ray.force_raycast_update()
		var point := Vector3.ZERO
		var normal := Vector3.UP
		var splat := false
		# only the level's own surfaces take blood: never the player's or an entity's hitbox, which would
		# leave a splat floating in mid-air where a body happened to stand
		if ray.is_colliding() and ray.get_collider() is StaticBody3D:
			splat = true
			point = ray.get_collision_point()
			normal = ray.get_collision_normal()
		elif dir.y < 0.0 and p.y - b.size <= floor_y:      # landed on the floor plane (no collider of its own)
			if _pit_at(p.x, p.z):
				rb.queue_free()                           # it is falling through a pit: no surface, no stain
				b["dead"] = true
				continue
			splat = true
			point = Vector3(p.x, floor_y, p.z)
		elif b.t > 2.5:
			rb.queue_free()                               # wandered off somewhere unseen: just despawn
			b["dead"] = true
			continue
		if splat:
			var s: float = b.size * randf_range(9.0, 15.0) * clampf(0.5 + speed / 8.0, 0.5, 1.4)
			surface_decal(point + normal * 0.005, normal, s)
			_splat_sound(s)
			rb.queue_free()
			b["dead"] = true
	_blobs = _blobs.filter(func(b): return not b.has("dead"))

## Lay a decal flat on a surface, oriented by its normal: a mesh card with the decal shader on it
## (not a Decal node — full control over the shader), centred exactly at the hit point.
func surface_decal(point: Vector3, normal: Vector3, size: float, delay := 0.0) -> void:
	if _decals.size() > 90:
		return
	if _decal_shader == null:
		_decal_shader = Shader.new()
		_decal_shader.code = DECAL_SHADER
	var n := normal.normalized()
	var m := ShaderMaterial.new()
	m.shader = _decal_shader
	m.render_priority = 2
	m.set_shader_parameter("seed", randf() * 6.0)
	m.set_shader_parameter("splat_normal", n)
	m.set_shader_parameter("grow", 0.06)
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()               # a single flush card: a box's back face and side banding show through
	q.size = Vector2(size, size)
	mi.mesh = q
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_world().add_child(mi)
	# local +Z along the surface normal; a random spin about it varies the blob outline
	var t := n.cross(Vector3.UP)
	if t.length_squared() < 0.0001:
		t = Vector3.RIGHT
	t = t.normalized()
	mi.transform = Transform3D(Basis(t, n.cross(t).normalized(), n), point + n * (0.012 + _decals.size() * 0.0004))
	_decals.append(mi)
	_grow_decal(m, delay)

## The Tween that sells it: the centre-fade mask spreads outward, then the red darkens as it dries.
func _grow_decal(m: ShaderMaterial, delay: float) -> void:
	var set_grow := func(v: float) -> void:
		if is_instance_valid(m):
			m.set_shader_parameter("grow", v)
	var set_wet := func(v: float) -> void:
		if is_instance_valid(m):
			m.set_shader_parameter("wet", v)
	var tw := create_tween().set_parallel(true)
	tw.tween_method(set_grow, 0.06, 1.0, randf_range(0.5, 1.0)).set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_method(set_wet, 1.0, 0.15, randf_range(4.0, 7.0)).set_delay(delay + 0.8)
	_decal_tweens = _decal_tweens.filter(func(t: Tween) -> bool: return t.is_valid())
	_decal_tweens.append(tw)

## The wet hit of a blob landing: the synthesized splat, quieter and lower-pitched for bigger clots.
func _splat_sound(size: float) -> void:
	if not get_parent().active:      # the warm-up at level start must stay silent
		return
	var sc: Node = get_parent().get("_scares")
	if sc == null or not is_instance_valid(sc):
		return
	var vol := clampf(size * 0.28, 0.08, 0.5)
	if randf() > vol * 2.2:          # never all of them at once
		return
	sc.spawn_flat(sc.synth("splat"), vol, "Body", randf_range(1.0, 1.6 - minf(0.5, size * 0.3)))

## The bite / snap: the wet central pools land straight on the floor, and the rest of the blood is
## flung as physics blobs in random directions — each one arcs, its ray finds a wall / floor / ceiling,
## and it splatters there as an expanding decal.
func feast(head: Vector3, victim: Vector3) -> void:
	floor_y = victim.y
	# the pools under the kill and under you: laid straight on the floor, spreading as they land
	surface_decal(Vector3(head.x, floor_y, head.z), Vector3.UP, randf_range(2.8, 3.6))
	surface_decal(Vector3(victim.x, floor_y, victim.z), Vector3.UP, randf_range(2.4, 3.2), 0.3)
	for i in 14:
		var a := randf() * TAU
		var sp := randf_range(0.5, 4.5)
		surface_decal(Vector3(head.x + cos(a) * sp * 1.4, floor_y, head.z + sin(a) * sp * 1.4),
				Vector3.UP, randf_range(0.2, 0.7), randf_range(0.0, 0.8))
	# flung blobs: fast ones reach the walls and the ceiling, heavy clots fall close and stain the floor
	for i in 12:
		var a := randf() * TAU
		var sp := randf_range(2.2, 6.0)
		blob(head + Vector3(0.0, 0.05, 0.0), Vector3(cos(a) * sp, randf_range(1.2, 3.8), sin(a) * sp), randf_range(0.025, 0.05))
	for i in 6:
		var a := randf() * TAU
		var sp := randf_range(0.4, 1.8)
		blob(head, Vector3(cos(a) * sp, randf_range(0.6, 2.0), sin(a) * sp), randf_range(0.05, 0.09))

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
				surface_decal(Vector3(p.x, floor_y, p.z), Vector3.UP, 0.16 + d.size * 6.0 + randf() * 0.25)
			mi.queue_free()
			d["dead"] = true
	_drops = _drops.filter(func(d): return not d.has("dead"))
	# the body topples backwards, accelerating like dead weight
	if _ragdoll != null and is_instance_valid(_ragdoll) and not _clip_played:
		_ragdoll_t = minf(1.0, _ragdoll_t + delta * (0.6 + _ragdoll_t * 3.0))
		_ragdoll.rotation.x = -_ragdoll_t * _ragdoll_t * 1.5

## A hazmat survivor stands where you were and falls onto its back.
func _hazmat_scene() -> PackedScene:
	var path := "res://models/player/hazmat.glb"
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
	surface_decal(Vector3(at.x, floor_y, at.z), Vector3.UP, 0.06)   # the decal shader + its cube pipeline
	blob(at + Vector3(0.0, 0.5, 0.0), Vector3(0.1, 1.0, 0.0), 0.02) # the wobbling blob shader + rigid body
	_ensure_floor_collider(at)
	_emit(at, Vector3.UP, 6, 0.3, 0.5, 1.0, 20.0, 0.01, 0.015, Color(0.2, 0.0, 0.01), 0.1)
	await get_tree().create_timer(0.7).timeout
	if get_parent().active:      # died inside the warm-up window: the blood and the body are real now
		return
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
	_clip = null
	for ap in root.find_children("*", "AnimationPlayer", true, false):
		var player := ap as AnimationPlayer
		player.stop()
		for a in player.get_animation_list():
			if String(a).to_lower().contains("death"):
				_clip = player.get_animation(a)
				_clip.loop_mode = Animation.LOOP_NONE
				player.play(a)
				_clip_played = true
				break
		if _clip_played:
			break
	_ragdoll.global_position = pos
	_ragdoll.rotation.y = yaw
	_ragdoll_t = 0.0
	# the chest bone (Mixamo rig; humanoid names too, in case the import retargets it)
	_skel = null
	_chest = -1
	for s in root.find_children("*", "Skeleton3D", true, false):
		for bone in ["Spine1", "Chest", "Spine", "Hips"]:
			var i := (s as Skeleton3D).find_bone(bone)
			if i >= 0:
				_skel = s
				_chest = i
				break
		if _skel != null:
			break
	contact_time = _find_contact()

# When does the body hit the floor? The clip first drops it to its knees, then it slams down flat on its
# back: that slam is the moment. Read the upper back's height straight off the clip's bone tracks, find
# where it comes down within 5% of where it finally rests, then the instant that drop stops dead (no
# guessing a fixed time, so it stays right if the clip changes). Without the clip, time the procedural topple the same way.
func _find_contact() -> float:
	if _clip == null or _skel == null:
		var k := 0.0
		var t := 0.0
		while k < 1.0 and t < 5.0:
			k = minf(1.0, k + (1.0 / 120.0) * (0.6 + k * 3.0))   # the same curve as _process's topple
			t += 1.0 / 120.0
		return t
	var back := -1
	for b in ["Spine2", "UpperChest", "Spine1", "Chest", "Spine", "Hips"]:
		back = _skel.find_bone(b)
		if back >= 0:
			break
	if back < 0:
		return 0.85
	var tracks := {}
	for i in _clip.get_track_count():
		var bone := _skel.find_bone(String(_clip.track_get_path(i)).get_slice(":", 1))
		if bone < 0:
			continue
		if not tracks.has(bone):
			tracks[bone] = {}
		match _clip.track_get_type(i):
			Animation.TYPE_POSITION_3D: tracks[bone]["pos"] = i
			Animation.TYPE_ROTATION_3D: tracks[bone]["rot"] = i
			Animation.TYPE_SCALE_3D: tracks[bone]["scl"] = i
	var h0 := _clip_height(back, tracks, 0.0)
	var h_end := _clip_height(back, tracks, _clip.length)
	if h0 - h_end < 0.05:
		return 0.85
	var dt := 1.0 / 120.0
	var t := 0.0
	while t < _clip.length and _clip_height(back, tracks, t) > h_end + 0.05 * (h0 - h_end):
		t += dt
	# ...and the impact itself is where that last drop stops dead (still falling faster than 0.3 m/s: not yet)
	while t < _clip.length and (_clip_height(back, tracks, t) - _clip_height(back, tracks, t + dt)) / dt > 0.3:
		t += dt
	return minf(t, _clip.length)

# World height of a bone at time t of the clip, chaining the parents' track poses
func _clip_height(bone: int, tracks: Dictionary, t: float) -> float:
	var x := Transform3D.IDENTITY
	var b := bone
	while b >= 0:
		var rest := _skel.get_bone_rest(b)
		var p := rest.origin
		var q := rest.basis.get_rotation_quaternion()
		var sc := rest.basis.get_scale()
		var tr: Dictionary = tracks.get(b, {})
		if tr.has("pos"): p = _clip.position_track_interpolate(tr.pos, t)
		if tr.has("rot"): q = _clip.rotation_track_interpolate(tr.rot, t)
		if tr.has("scl"): sc = _clip.scale_track_interpolate(tr.scl, t)
		x = Transform3D(Basis(q).scaled(sc), p) * x
		b = _skel.get_bone_parent(b)
	return (_skel.global_transform * x).origin.y      # world up, whatever the import's armature rotation

## Where the body's chest is right now (it moves as the fall clip plays), for the death camera to
## look at. Falls back to the tipping body's position, then to `fallback`.
func body_point(fallback: Vector3) -> Vector3:
	if _skel != null and is_instance_valid(_skel) and _chest >= 0:
		return _skel.global_transform * _skel.get_bone_global_pose(_chest).origin
	if _ragdoll != null and is_instance_valid(_ragdoll):
		return _ragdoll.global_position + _ragdoll.global_basis.y * 0.9 + Vector3(0.0, 0.25, 0.0)
	return fallback

func clear() -> void:
	for mi in _decals:
		if is_instance_valid(mi):
			mi.queue_free()
	for d in _drops:
		if is_instance_valid(d.m):
			d.m.queue_free()
	for b in _blobs:
		if is_instance_valid(b.rb):
			b.rb.queue_free()
	for tw in _decal_tweens:
		if tw.is_valid():
			tw.kill()
	_decals.clear()
	_drops.clear()
	_grow.clear()
	_blobs.clear()
	_decal_tweens.clear()
	if _ragdoll != null and is_instance_valid(_ragdoll):
		_ragdoll.queue_free()
	_ragdoll = null
	_skel = null
	_chest = -1
	if _floor_col != null and is_instance_valid(_floor_col):
		_floor_col.queue_free()
	_floor_col = null
