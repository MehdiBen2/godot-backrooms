extends "res://scripts/UI/death/death_blood.gd"
## Blood in the level + the fallen survivor's body (js/game/grab.js bloodFeast/bloodStep, death.js ragdoll).
## Child of the Death autoload. Droplets fly and fall, stains spread across the floor, and a hazmat
## survivor topples onto its back where you stood.
## The blood itself lives in death_blood.gd.

const SurvivorAnim := preload("res://scripts/Entities/survivor_anim.gd")

var _grow: Array = []
var _ragdoll: Node3D = null
var _ragdoll_t := 0.0
var _clip_played := false
var _skel: Skeleton3D = null     # the body's skeleton, so the death camera can follow the chest
var _chest := -1
var _clip: Animation = null      # the fall clip being played
## Seconds after spawn_ragdoll() at which the body's back hits the floor (read off the fall itself)
var contact_time := 0.85
func _wall_at(x: float, z: float) -> bool:
	var lvl = Game.level
	if lvl == null:
		return false
	return lvl.walls.has(Vector2i(roundi(x / CELL), roundi(z / CELL)))

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
		# the real ground under the drop, not a flat plane: on a slope (the hills level) the actual
		# surface can sit well above or below floor_y, which used to leave the stain floating or buried
		var ground := _find_floor_point(Vector3(p.x, floor_y + 3.0, p.z)) if p.y <= floor_y + 3.0 else Vector3(p.x, floor_y, p.z)
		var hit_floor := p.y <= ground.y + 0.03
		if hit_floor or _wall_at(p.x, p.z):
			if hit_floor and randf() < 0.6:
				surface_decal(Vector3(p.x, ground.y, p.z), Vector3.UP, 0.16 + d.size * 6.0 + randf() * 0.25, 0.0, null, d.v)
			mi.queue_free()
			d["dead"] = true
	_drops = _drops.filter(func(d): return not d.has("dead"))
	# the body topples backwards, accelerating like dead weight
	if _ragdoll != null and is_instance_valid(_ragdoll) and not _clip_played:
		_ragdoll_t = minf(1.0, _ragdoll_t + delta * (0.6 + _ragdoll_t * 3.0))
		_ragdoll.rotation.x = -_ragdoll_t * _ragdoll_t * 1.5

## A hazmat survivor stands where you were and falls onto its back.
func _hazmat_scene() -> PackedScene:
	var path := SurvivorAnim.MODEL
	if ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_LOADED:
		return ResourceLoader.load_threaded_get(path) as PackedScene
	return load(path) as PackedScene

## Build the blood shaders / pipelines now so the first death does not hitch. The test blood is laid on the
## floor behind the view, where the player cannot see it, and cleared again a moment later; `_keep_drawn`
## is what makes it still render out of view, which is the only way its pipelines get built.
func warm() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var pl = Game.player
	var at := cam.global_position + cam.global_basis.z * 2.0          # behind the camera, not in front of it
	floor_y = pl.global_position.y if pl != null and is_instance_valid(pl) else cam.global_position.y - 1.7
	_warm = true
	surface_decal(Vector3(at.x, floor_y, at.z), Vector3.UP, 0.06)   # the decal shader + its pipeline
	blob(Vector3(at.x, floor_y + 0.5, at.z), Vector3(0.1, 1.0, 0.0), 0.02)  # the wobbling blob shader + rigid body
	_ensure_floor_collider(at)
	_emit(Vector3(at.x, floor_y + 0.1, at.z), Vector3.UP, 6, 0.3, 0.5, 1.0, 20.0, 0.01, 0.015, Color(0.2, 0.0, 0.01), 0.1)
	await get_tree().create_timer(0.7).timeout
	_warm = false
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
	# survivor.glb ships a 'death' clip that does the falling; play it once and hold the last frame
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
	# the chest bone (the suit's Tripo rig; Mixamo / humanoid names too, in case the import renames them)
	_skel = null
	_chest = -1
	for s in root.find_children("*", "Skeleton3D", true, false):
		for bone in ["Spine02", "Spine1", "Chest", "Spine", "Hip", "Hips"]:
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
	for b in ["Spine02", "Spine2", "UpperChest", "Spine1", "Chest", "Spine", "Hips"]:
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
