extends Node
## Blood in the level + the fallen survivor's body (js/game/grab.js bloodFeast/bloodStep, death.js ragdoll).
## Child of the Death autoload. Droplets fly and fall, stains spread across the floor, and a hazmat
## survivor topples onto its back where you stood.
##
## The splatter follows the "improved blood decals" approach (reddit r/godot 143g7cz): a blob of blood
## is a RigidBody3D carrying a wobbling-sphere MeshInstance3D and a RayCast3D; it is flung into a random
## direction, arcs under gravity, and when its ray finds the floor it lays a decal there (walls and the
## ceiling take no blood for now). The decal is a flat card with a custom metaball shader (not a Decal
## node, so every parameter is ours), shaped by how the blood hit, spread by a Tween `grow` parameter,
## and fading from wet red to a dark dried red.

const CELL := 4.5
const WARM_CULL_MARGIN := 600.0     # past the camera's draw distance: keeps the warm-up blood in the frustum
const BLOOD_SHADER := """
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, specular_schlick_ggx;
uniform sampler2D tex : source_color, filter_linear_mipmap;
uniform vec4 region = vec4(0.0, 0.0, 1.0, 1.0);
uniform float alpha = 0.9;
uniform float seed = 0.0;
uniform bool drip = false;
// Value-noise sampled around the circle (n equally-spaced control points, wrapped so ang = -PI and
// +PI agree): an irregular, non-repeating blob edge. Plain sin(ang*k) harmonics tile perfectly and
// draw a symmetric flower/gear outline - real blood splats have no such symmetry.
float _h1(float x) { return fract(sin(x * 127.1) * 43758.5453); }
float _ang_noise(float ang, float sd, float n) {
	float a = (ang / 6.28318530718 + 0.5) * n;
	float af = floor(a);
	float f = a - af;
	float i0 = mod(af, n);
	float i1 = mod(i0 + 1.0, n);
	f = f * f * (3.0 - 2.0 * f);
	return mix(_h1(i0 * 13.7 + sd * 4.1), _h1(i1 * 13.7 + sd * 4.1), f);
}
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
			c = vec3(0.22, 0.0, 0.0);
	} else {
		vec2 d = UV - vec2(0.5);
		float a = atan(d.y, d.x);
		float r = 0.28 + 0.18 * _ang_noise(a, seed, 6.0) + 0.08 * _ang_noise(a, seed + 51.0, 13.0);
		mask = smoothstep(r, r - 0.06, length(d));
	}
	ALBEDO = vec3(0.065, 0.002, 0.004) + c * vec3(0.045, 0.0, 0.0);
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
	ALBEDO = vec3(0.17, 0.005, 0.01);
	ROUGHNESS = 0.18;
	SPECULAR = 0.85;
	METALLIC = 0.02;
}
"""

# The splat decal laid on a surface. Its shape is a metaball field, so it reads as liquid: a body of
# overlapping lobes that merge smoothly (stretched along the impact), tapered fingers and satellite
# droplets thrown forward, and a small domain warp so no edge is ever a clean curve. Thin blood at the
# rim is brighter, the thick centre darker, the rim lifts into a light-catching lip, and as `wet` falls
# the edge dries dark first. `grow` spreads the body the way a pool creeps outward.
const DECAL_SHADER := """
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, specular_schlick_ggx;
uniform float grow = 1.0;
uniform float wet = 1.0;
uniform float seed = 0.0;
uniform vec3 splat_normal = vec3(0.0, 1.0, 0.0);
uniform vec2 impact_dir = vec2(0.0);   // in the card's plane; its length is how hard it hit (0 = a pool)
varying vec3 wpos;
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
float hs(float n) { return fract(sin(n * 12.9898 + seed * 78.233) * 43758.5453); }
float h21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
// compact metaball kernel: 1 at the centre, 0 at radius r, smooth everywhere
float ball(vec2 p, vec2 c, float r) {
	vec2 q = p - c;
	float x = clamp(1.0 - dot(q, q) / (r * r), 0.0, 1.0);
	return x * x * x;
}
// the same kernel around a segment whose radius tapers from ra to rb: a finger of thrown blood
float seg(vec2 p, vec2 a, vec2 b, float ra, float rb) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-5), 0.0, 1.0);
	float r = mix(ra, rb, h);
	vec2 q = pa - ba * h;
	float x = clamp(1.0 - dot(q, q) / (r * r), 0.0, 1.0);
	return x * x * x;
}
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
float field(vec2 p) {
	float hit = clamp(length(impact_dir), 0.0, 1.0);
	vec2 dir = hit > 0.001 ? impact_dir / length(impact_dir) : vec2(1.0, 0.0);
	vec2 side = vec2(-dir.y, dir.x);
	// organic edge: a two-octave domain warp, so no outline is ever a clean circle
	p += (vec2(vno(p * 3.0 + seed * 3.1), vno(p * 3.0 - seed * 1.7)) - 0.5) * 0.14;
	p += (vec2(vno(p * 9.0 + seed * 5.3), vno(p * 9.0 - seed * 2.9)) - 0.5) * 0.04;
	// local frame: x runs along the direction the blood was travelling
	vec2 lp = vec2(dot(p, dir), dot(p, side));
	vec2 bp = vec2(lp.x / (1.0 + 0.55 * hit), lp.y) / max(grow, 0.02);
	float f = 0.0;
	// the body: lobes clustered about the centre, merging into one pool
	for (int i = 0; i < 8; i++) {
		float fi = float(i);
		float a = hs(fi * 3.7) * 6.2832;
		float d = sqrt(hs(fi * 5.3 + 1.0)) * 0.42;
		f += ball(bp, vec2(cos(a), sin(a)) * d, 0.24 + 0.18 * hs(fi * 7.1 + 2.0));
	}
	// fingers and droplets land on impact, before the pool has spread
	float appear = smoothstep(0.0, 0.25, grow);
	for (int i = 0; i < 5; i++) {
		float fi = float(i);
		float a = (hs(fi * 2.3 + 9.0) - 0.5) * 1.7;
		vec2 fd = vec2(cos(a), sin(a));
		float len = (0.3 + 0.45 * hs(fi * 4.1 + 3.0)) * appear;
		f += hit * 0.9 * seg(lp, fd * 0.2, fd * (0.2 + len), 0.11, 0.03);
	}
	for (int i = 0; i < 9; i++) {
		float fi = float(i);
		if (hs(fi * 11.0 + 7.0) > mix(0.3, 1.0, hit)) { continue; }
		float a = (hs(fi * 6.7 + 4.0) - 0.5) * mix(6.2832, 2.2, hit);
		float d = 0.6 + 0.32 * hs(fi * 1.9 + 5.0);
		f += appear * ball(lp, vec2(cos(a), sin(a)) * d, 0.04 + 0.05 * hs(fi * 8.3 + 6.0));
	}
	return f;
}
void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	const float TH = 0.3;
	float f = field(p);
	float aa = max(fwidth(f), 1e-4);
	float m = smoothstep(TH - aa, TH + aa, f);
	if (m < 0.01) { discard; }
	float thick = clamp((f - TH) / 0.9, 0.0, 1.0);
	float lip = 1.0 - smoothstep(0.0, 0.35, thick);
	// the rim of a puddle bulges up (surface tension): tilt the normal there so it catches the light
	float e = 0.01;
	vec2 gr = vec2(field(p + vec2(e, 0.0)) - f, field(p + vec2(0.0, e)) - f) / e;
	NORMAL_MAP = normalize(vec3(clamp(-gr * 0.05 * lip, vec2(-0.7), vec2(0.7)), 1.0)) * 0.5 + 0.5;
	float n = tri(wpos * 3.0);   // world-aligned mottling: clotting, shared by overlapping splats
	vec3 thin_col = vec3(0.19, 0.007, 0.009);
	vec3 thick_col = vec3(0.1, 0.003, 0.005);
	vec3 dried = vec3(0.04, 0.002, 0.003);
	vec3 col = mix(thin_col, thick_col, smoothstep(0.0, 0.2, thick));
	float dry = 1.0 - wet;
	col = mix(col, dried, clamp(dry * (1.0 + lip), 0.0, 1.0));   // the rim dries dark first
	ALBEDO = col * (0.85 + 0.3 * n);
	ALPHA = m * mix(0.85, 0.97, smoothstep(0.0, 0.3, thick));
	// wet blood is glossy; dried blood is matte (any leftover sheen reads as grey plastic)
	ROUGHNESS = mix(0.9, mix(0.25, 0.08, thick), wet);
	SPECULAR = mix(0.05, 0.6, wet);
	METALLIC = 0.0;
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
var _warm := false              # true while `warm()` lays its out-of-sight warm-up blood
var _bursts: Array = []         # the one-shot particle bursts, so clear() can end them (they outlive their blood)
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
	if _warm:
		_keep_drawn(mi)
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
		_drop_mat.albedo_color = Color(0.16, 0.006, 0.011)
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
	if _warm:
		_keep_drawn(mi)
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
		# only the level's floor takes blood: never the player's or an entity's hitbox (a splat floating in
		# mid-air), and not walls or the ceiling for now. A blob that meets a wall drops down it to the floor.
		if ray.is_colliding() and ray.get_collider() is StaticBody3D and ray.get_collision_normal().y > 0.7:
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
			surface_decal(point + normal * 0.005, normal, s, 0.0, ray.get_collider() as CollisionObject3D, v)
			_splat_sound(s)
			rb.queue_free()
			b["dead"] = true
	_blobs = _blobs.filter(func(b): return not b.has("dead"))

## Lay a decal flat on a surface, oriented by its normal: a mesh card with the decal shader on it
## (not a Decal node — full control over the shader), centred exactly at the hit point and trimmed to
## the surface that is actually there: the card never hangs over a wall's top edge or corner into open air.
func surface_decal(point: Vector3, normal: Vector3, size: float, delay := 0.0, on: CollisionObject3D = null, impact := Vector3.ZERO) -> void:
	if _decals.size() > 90:
		return
	if _decal_shader == null:
		_decal_shader = Shader.new()
		_decal_shader.code = DECAL_SHADER
	var n := normal.normalized()
	# local +Z along the surface normal; a random spin about it varies the blob outline
	var t := n.cross(Vector3.UP)
	if t.length_squared() < 0.0001:
		t = Vector3.RIGHT
	t = t.normalized()
	var b := n.cross(t).normalized()
	var sx := 1.0
	var sy := 1.0
	var w := _world()
	if w is Node3D:
		var space: PhysicsDirectSpaceState3D = (w as Node3D).get_world_3d().direct_space_state
		var reach := size * 0.5 + 0.05
		var xt := _side_reach(space, point, n, t, reach, on) + _side_reach(space, point, n, -t, reach, on)
		var yb := _side_reach(space, point, n, b, reach, on) + _side_reach(space, point, n, -b, reach, on)
		if xt < 0.12 or yb < 0.12:
			return                                  # a corner or lip: not enough surface under the splat
		sx = clampf(xt * 1.9 / size, 0.25, 1.0)
		sy = clampf(yb * 1.9 / size, 0.25, 1.0)
	var m := ShaderMaterial.new()
	m.shader = _decal_shader
	m.render_priority = 2
	m.set_shader_parameter("seed", randf() * 6.0)
	m.set_shader_parameter("splat_normal", n)
	m.set_shader_parameter("grow", 0.06)
	# the part of the blood's velocity along the surface, in the card's UV plane (UV.y runs down -Y):
	# a glancing, fast hit stretches the splat and throws fingers; a straight drop leaves a round pool
	var along := Vector2(impact.dot(t), -impact.dot(b))
	m.set_shader_parameter("impact_dir", along.normalized() * clampf(along.length() / 5.0, 0.0, 1.0) if along.length() > 0.01 else Vector2.ZERO)
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()               # a single flush card: a box's back face and side banding show through
	q.size = Vector2(size * sx, size * sy)
	mi.mesh = q
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_world().add_child(mi)
	mi.transform = Transform3D(Basis(t, b, n), point + n * (0.012 + _decals.size() * 0.0004))
	if _warm:
		_keep_drawn(mi)
	_decals.append(mi)
	_grow_decal(m, delay)

# How far the SAME surface keeps going from the hit point along one in-plane direction: a ray skimmed
# into the plane; it dies out where the surface ends (over an edge it flies off into empty air, or
# turns into a differently-facing surface like the floor).
func _side_reach(space: PhysicsDirectSpaceState3D, point: Vector3, n: Vector3, axis: Vector3, reach: float, on: CollisionObject3D) -> float:
	var origin := point + n * 0.03
	var best := 0.0
	for f in [0.4, 0.75, 1.0]:
		var d: float = reach * f
		var q := PhysicsRayQueryParameters3D.create(origin, origin + axis * d - n * 0.05)
		q.collision_mask = 1
		var hit := space.intersect_ray(q)
		if hit.is_empty() or Vector3(hit.normal).dot(n) < 0.9:
			break
		if on != null and hit.collider != on:
			break
		best = d * 0.6                                # the skim touches down about 60% along its length
	return best

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
	tw.tween_method(set_wet, 1.0, 0.25, randf_range(9.0, 16.0)).set_delay(delay + 1.2)
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
## flung as physics blobs in random directions — each one arcs, its ray finds the floor, and it
## splatters there as an expanding decal.
func feast(head: Vector3, victim: Vector3) -> void:
	floor_y = victim.y
	# the pools under the kill and under you: laid straight on the floor, spreading as they land
	surface_decal(Vector3(head.x, floor_y, head.z), Vector3.UP, randf_range(2.8, 3.6))
	surface_decal(Vector3(victim.x, floor_y, victim.z), Vector3.UP, randf_range(2.4, 3.2), 0.3)
	# the spatter thrown out around the kill: each splat points away from it, fingers flung outward
	for i in 14:
		var a := randf() * TAU
		var sp := randf_range(0.5, 4.5)
		var out := Vector3(cos(a), 0.0, sin(a))
		surface_decal(Vector3(head.x + out.x * sp * 1.4, floor_y, head.z + out.z * sp * 1.4),
				Vector3.UP, randf_range(0.3, 0.8), randf_range(0.0, 0.8), null, out * randf_range(2.0, 6.0))
	# flung blobs: fast ones fan out across the floor, heavy clots fall close
	for i in 12:
		var a := randf() * TAU
		var sp := randf_range(2.0, 5.5)
		blob(head + Vector3(0.0, 0.05, 0.0), Vector3(cos(a) * sp, randf_range(1.0, 3.0), sin(a) * sp), randf_range(0.025, 0.05))
	for i in 6:
		var a := randf() * TAU
		var sp := randf_range(0.4, 1.8)
		blob(head, Vector3(cos(a) * sp, randf_range(0.6, 2.0), sin(a) * sp), randf_range(0.05, 0.09))

## A fast burst of blood thrown out of `origin` toward `toward` (a direction): a heavy spray of
## beads plus a finer mist. Short-lived and vanishes on the floor, so it never hangs in the air.
func spray(origin: Vector3, toward: Vector3) -> void:
	_ensure_floor_collider(origin)
	var dir := (toward.normalized() + Vector3(0, 0.35, 0)).normalized()
	_emit(origin, dir, 150, 0.9, 2.5, 8.5, 70.0, 0.022, 0.06, Color(0.07, 0.002, 0.005), 0.16)
	_emit(origin, dir, 90, 0.55, 5.0, 11.0, 55.0, 0.008, 0.02, Color(0.1, 0.004, 0.008), 0.32)

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
	if _warm:
		_keep_drawn(p)
	_bursts.append(p)
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
				surface_decal(Vector3(p.x, floor_y, p.z), Vector3.UP, 0.16 + d.size * 6.0 + randf() * 0.25, 0.0, null, d.v)
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

## Build the blood shaders / pipelines now so the first death does not hitch. The test blood is laid on the
## floor behind the view, where the player cannot see it, and cleared again a moment later; `_keep_drawn`
## is what makes it still render out of view, which is the only way its pipelines get built.
func warm() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or tex == null:
		return
	var pl = Game.player
	var at := cam.global_position + cam.global_basis.z * 2.0          # behind the camera, not in front of it
	floor_y = pl.global_position.y if pl != null and is_instance_valid(pl) else cam.global_position.y - 1.7
	_warm = true
	pool(at.x, at.z, 0.1, 0.02)
	surface_decal(Vector3(at.x, floor_y, at.z), Vector3.UP, 0.06)   # the decal shader + its cube pipeline
	blob(Vector3(at.x, floor_y + 0.5, at.z), Vector3(0.1, 1.0, 0.0), 0.02)  # the wobbling blob shader + rigid body
	_ensure_floor_collider(at)
	_emit(Vector3(at.x, floor_y + 0.1, at.z), Vector3.UP, 6, 0.3, 0.5, 1.0, 20.0, 0.01, 0.015, Color(0.2, 0.0, 0.01), 0.1)
	await get_tree().create_timer(0.7).timeout
	_warm = false
	if get_parent().active:      # died inside the warm-up window: the blood and the body are real now
		return
	clear()
	floor_y = 0.0

## Keep a warm-up instance being drawn although nothing is looking at it: a wide cull margin so the
## frustum test always passes, and no occlusion culling so a wall between it and the camera never drops it.
func _keep_drawn(g: GeometryInstance3D) -> void:
	g.extra_cull_margin = WARM_CULL_MARGIN
	g.set_ignore_occlusion_culling(true)

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
	for p in _bursts:
		if is_instance_valid(p):
			p.queue_free()
	for tw in _decal_tweens:
		if tw.is_valid():
			tw.kill()
	_decals.clear()
	_drops.clear()
	_grow.clear()
	_blobs.clear()
	_bursts.clear()
	_decal_tweens.clear()
	if _ragdoll != null and is_instance_valid(_ragdoll):
		_ragdoll.queue_free()
	_ragdoll = null
	_skel = null
	_chest = -1
	if _floor_col != null and is_instance_valid(_floor_col):
		_floor_col.queue_free()
	_floor_col = null
