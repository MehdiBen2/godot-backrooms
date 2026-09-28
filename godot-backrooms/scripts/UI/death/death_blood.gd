extends Node
## Death effects, part 1: the blood. Flying droplets, wobbling blobs that arc under gravity and splat a
## metaball decal where their ray finds the floor (shaders/blood_blob.gdshader, blood_decal.gdshader), and
## GPU particle sprays. death_fx.gd builds on it with the fallen body, the warm-up and clearing.
##
## The splatter follows the "improved blood decals" approach (reddit r/godot 143g7cz): a blob of blood
## is a RigidBody3D carrying a wobbling-sphere MeshInstance3D and a RayCast3D; it is flung into a random
## direction, arcs under gravity, and when its ray finds the floor it lays a decal there (walls and the
## ceiling take no blood for now). The decal is a flat card with a custom metaball shader (not a Decal
## node, so every parameter is ours), shaped by how the blood hit, spread by a Tween `grow` parameter,
## and fading from wet red to a dark dried red.

const CELL := 4.5
const WARM_CULL_MARGIN := 600.0     # past the camera's draw distance: keeps the warm-up blood in the frustum
# How close to level a surface must be to take a splat at all. A puddle is a flat card oriented to the
# hit normal, so on a steep hillside face (the hills level) that normal tilts the card hard enough to
# read as a small blob standing on its edge rather than a puddle lying down; below this, the blob keeps
# rolling/falling instead of painting one there.
const FLAT_ENOUGH_Y := 0.92

# The flying blob: a sphere whose vertices bob around the surface so it wobbles like a loose mass of blood.
const BLOB_SHADER := preload("res://shaders/blood_blob.gdshader")

# The splat decal laid on a surface. Its shape is a metaball field, so it reads as liquid: a body of
# overlapping lobes that merge smoothly (stretched along the impact), tapered fingers and satellite
# droplets thrown forward, and a small domain warp so no edge is ever a clean curve. Thin blood at the
# rim is brighter, the thick centre darker, the rim lifts into a light-catching lip, and as `wet` falls
# the edge dries dark first. `grow` spreads the body the way a pool creeps outward.
const DECAL_SHADER := preload("res://shaders/blood_decal.gdshader")

var floor_y := 0.0
var _decals: Array = []
var _drops: Array = []
var _blobs: Array = []
var _decal_tweens: Array = []
var _blob_shader: Shader = null
var _decal_shader: Shader = null
var _blob_mesh: SphereMesh = null
var _floor_col: GPUParticlesCollisionBox3D = null
var _warm := false              # true while `warm()` lays its out-of-sight warm-up blood
var _bursts: Array = []         # the one-shot particle bursts, so clear() can end them (they outlive their blood)
var _drop_mesh: SphereMesh = null
var _drop_mat: StandardMaterial3D = null

# Where the blood and the body go: the running level (Game.main), which is also the current scene in a
# normal run; the fallback keeps it working when something else is current (tools, tests)
func _world() -> Node:
	if Game.main != null and is_instance_valid(Game.main):
		return Game.main
	return get_tree().current_scene if get_tree().current_scene != null else get_tree().root

func _pit_at(x: float, z: float) -> bool:
	var lvl = Game.level
	if lvl == null:
		return false
	return lvl.pits.has(Vector2i(roundi(x / CELL), roundi(z / CELL)))

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
		_blob_shader = BLOB_SHADER
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
		if ray.is_colliding() and ray.get_collider() is StaticBody3D and ray.get_collision_normal().y > FLAT_ENOUGH_Y:
			splat = true
			point = ray.get_collision_point()
			normal = ray.get_collision_normal()
		elif dir.y < 0.0 and p.y - b.size <= floor_y + 3.0:  # near the floor: confirm against the real ground, not
			# a flat plane, so a blob over a slope (the hills level) lands on the actual surface under it
			var ground := _find_floor_point(Vector3(p.x, p.y + 1.0, p.z))
			if p.y - b.size <= ground.y:
				if _pit_at(ground.x, ground.z):
					rb.queue_free()                           # it is falling through a pit: no surface, no stain
					b["dead"] = true
					continue
				splat = true
				point = ground
		elif b.t > 2.5:
			rb.queue_free()                               # wandered off somewhere unseen: just despawn
			b["dead"] = true
			continue
		if splat:
			var s: float = b.size * randf_range(9.0, 15.0) * clampf(0.5 + speed / 8.0, 0.5, 1.4)
			surface_decal(point + normal * 0.02, normal, s, 0.0, ray.get_collider() as CollisionObject3D, v)
			_splat_sound(s)
			rb.queue_free()
			b["dead"] = true
	_blobs = _blobs.filter(func(b): return not b.has("dead"))

## Lay a decal flat on a surface, oriented by its normal: a mesh card with the decal shader on it
## (not a Decal node — full control over the shader), centred exactly at the hit point and trimmed to
## the surface that is actually there: the card never hangs over a wall's top edge or corner into open air.
func surface_decal(point: Vector3, normal: Vector3, size: float, delay := 0.0, on: CollisionObject3D = null, impact := Vector3.ZERO, link_world := Vector3.ZERO) -> void:
	if _decals.size() > 90:
		return
	if _decal_shader == null:
		_decal_shader = DECAL_SHADER
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
	if link_world != Vector3.ZERO:
		var rel := link_world - point
		var half_w := size * sx * 0.5
		var half_h := size * sy * 0.5
		m.set_shader_parameter("link_to", Vector2(rel.dot(t) / half_w, -rel.dot(b) / half_h))
	var mi := MeshInstance3D.new()
	var q := QuadMesh.new()               # a single flush card: a box's back face and side banding show through
	q.size = Vector2(size * sx, size * sy)
	mi.mesh = q
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_world().add_child(mi)
	# a fixed nudge off the surface (not growing with decal count): render_priority already orders
	# overlapping splats correctly, and a height that kept climbing with every decal ever laid made
	# older splats visibly float above newer ones at a grazing view - another reason they read as
	# stacked cards instead of stains on the same surface
	mi.transform = Transform3D(Basis(t, b, n), point + n * 0.025)
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
	# the pool under the kill and the one under you: one linked decal, not two stacked ones - two
	# separately-shaded pools touching would show a seam exactly where they meet
	var hp := _find_floor_point(Vector3(head.x, head.y + 1.0, head.z))
	var vp := _find_floor_point(Vector3(victim.x, victim.y + 1.0, victim.z))
	var span := Vector2(hp.x - vp.x, hp.z - vp.z).length()
	surface_decal(hp, Vector3.UP, span * 1.2 + randf_range(1.4, 1.8), 0.0, null, Vector3.ZERO, vp)
	# the spatter thrown out around the kill: each splat points away from it, fingers flung outward
	for i in 10:
		var a := randf() * TAU
		var sp := randf_range(0.3, 2.5)
		var out := Vector3(cos(a), 0.0, sin(a))
		var splat_pos := _find_floor_point(Vector3(head.x + out.x * sp * 0.9, head.y + 1.0, head.z + out.z * sp * 0.9))
		surface_decal(splat_pos, Vector3.UP, randf_range(0.2, 0.5), randf_range(0.0, 0.8), null, out * randf_range(1.5, 4.0))
	# flung blobs: fast ones fan out across the floor, heavy clots fall close
	for i in 12:
		var a := randf() * TAU
		var sp := randf_range(2.0, 5.5)
		blob(head + Vector3(0.0, 0.05, 0.0), Vector3(cos(a) * sp, randf_range(1.0, 3.0), sin(a) * sp), randf_range(0.025, 0.05))
	for i in 6:
		var a := randf() * TAU
		var sp := randf_range(0.4, 1.8)
		blob(head, Vector3(cos(a) * sp, randf_range(0.6, 2.0), sin(a) * sp), randf_range(0.05, 0.09))

## Find the actual floor surface point by raycasting downward
func _find_floor_point(from: Vector3) -> Vector3:
	var w := _world()
	if w is Node3D:
		var space: PhysicsDirectSpaceState3D = (w as Node3D).get_world_3d().direct_space_state
		var q := PhysicsRayQueryParameters3D.create(from, from + Vector3(0, -5.0, 0))
		q.collision_mask = 1
		var hit := space.intersect_ray(q)
		# these callers always paint with an UP normal (a flat pool), so a steep hit here (a hillside
		# face) is skipped too - otherwise the flat card would clip straight into the slope
		if not hit.is_empty() and hit.collider is StaticBody3D and Vector3(hit.normal).y > FLAT_ENOUGH_Y:
			return hit.position
	# Fallback to floor_y if raycast fails
	return Vector3(from.x, floor_y, from.z)

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

## Keep a warm-up instance being drawn although nothing is looking at it: a wide cull margin so the
## frustum test always passes, and no occlusion culling so a wall between it and the camera never drops it.
func _keep_drawn(g: GeometryInstance3D) -> void:
	g.extra_cull_margin = WARM_CULL_MARGIN
	g.set_ignore_occlusion_culling(true)
