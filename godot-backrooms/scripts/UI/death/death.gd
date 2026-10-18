extends Node
## Death camera + blood-screen overlay (js/game/death.js + grab.js endGrab(dying=true)).
##
## Sequence:
##
##   t=0            the bite / neck snap has already been heard, at the moment it happened
##                  blood-screen image fades in and slides down (opacity 0->0.55, translateY -8%->0)
##   t=0..2.2s      the view lifts up out of the body (an arc, not a straight line) and swings round
##                  into the orbit, turning from wherever it was looking onto the falling body
##   ~2.2s          the body slams down on its back (the moment is read off the fall clip, see
##                  death_fx.contact_time): the body-fall recording's thud lands on that frame, and a
##                  jolt goes through the camera
##   t=0.5s..       a slow orbit that never stops, pushing in a little over time, with a dutch tilt and
##                  a hand-held float. It follows the body's chest (the fall clip moves it) and keeps
##                  clear of walls and low ceilings: in a tight corridor it pulls in and rises overhead.
##                  The picture drains of colour and the edges stay dark.
##
## DO NOT play the bite / snap sounds here: those happen at the moment itself (bacteria_grab.gd,
## mannequin_snap.gd), BEFORE kill_player() is called. The only sound made here is the body landing.

const DeathFx := preload("res://scripts/UI/death/death_fx.gd")
const LensBlood := preload("res://scripts/UI/death/lens_blood.gd")
const RespawnFade := preload("res://scripts/UI/death/respawn_fade.gd")
const PULL_SECONDS  := 2.2      # out of the body and round into the orbit
const ORBIT_LAP     := 28.0     # seconds per slow lap; it keeps turning until you respawn
const ORBIT_RADIUS  := 4.2
const ORBIT_RADIUS_END := 3.3   # the slow push-in while you watch
const ORBIT_HEIGHT  := 2.5
const BODY_CENTER_Y := 0.35
const CAM_MARGIN    := 0.4      # kept between the lens and any wall
const CEIL_MARGIN   := 0.35
const FALL_ONSET    := 0.24     # body_fall.mp3: the thud hits 0.24 s in (the rustle of going down comes first)
const DEATH_FOV     := 58.0     # narrower than play: a longer lens for the death shot
const CELL          := 4.5
# A faint pool of light over the body so a death in the dark never cuts to pure black
const BODY_LIGHT_ENERGY := 0.55
const BODY_LIGHT_RANGE  := 4.5
const BODY_LIGHT_HEIGHT := 1.6
const BODY_LIGHT_COLOR  := Color(1.0, 0.82, 0.62)   # dim, warm, like a dying bulb

var active     := false
var timer      := 0.0
var reason     := ""

var cam_start  := Vector3.ZERO
var death_pos  := Vector3.ZERO
var player_yaw := 0.0

var _cam: Camera3D    = null
var _player: Node3D   = null

# Blood-screen overlay
var _blood_overlay: CanvasLayer = null
var _blood_rect:    TextureRect = null
var _blood_edge:    ColorRect   = null
var _blood_tween:   Tween       = null
const BLOOD_EDGE := preload("res://shaders/blood_vignette.gdshader")
var _blood_tex:     Texture2D   = null

var _fx: Node = null
var _fade: RespawnFade
var _scares: Node = null
var _start_rot := Quaternion.IDENTITY
var _have_start_rot := false
var _fov0 := 75.0
var _focus := Vector3.ZERO      # smoothed point on the body the camera looks at
var _centre := Vector3.ZERO     # smoothed orbit centre (follows the body across the floor)
var _orbit_ang := 0.0
var _radius_now := ORBIT_RADIUS # clearance-limited orbit radius (a spring arm)
var _trauma := 0.0              # impact shake, squared on smooth noise
var _landed := false
var _land_t := -1.0            # seconds since the body hit the floor (drives the thump), -1 before
var _fall_sounded := false
var _body_light: OmniLight3D = null
var _caught := false            # something attacked you: the last breath already went out at the bite/snap
var _lens: LensBlood            # blood on the glass (THE TALL ONE's claws)
var _down := {}                 # lying(): you were already down on your back when you died (chest, head_dir)

func _ready() -> void:
	_blood_tex = load("res://textures/blood/PsoSI8.png") if ResourceLoader.exists("res://textures/blood/PsoSI8.png") else null
	_fx = DeathFx.new()
	add_child(_fx)
	_fade = RespawnFade.new()
	add_child(_fade)
	_lens = LensBlood.new()
	add_child(_lens)

# Autoloads only leave the tree when the game quits: drop the synth cache that outlives scene reloads
func _exit_tree() -> void:
	preload("res://scripts/Audio/scares/scare_synth.gd").clear_cache()

func bind(cam: Camera3D, player: Node3D, scares: Node) -> void:
	_cam    = cam
	_player = player
	_scares = scares

## Called by Game.kill_player().
## cam_start_global: camera world pos at death.
## p_pos: player feet world pos.
## p_yaw: player.rotation.y.
func start(killer: String, p_pos: Vector3, cam_start_global: Vector3, p_yaw: float) -> void:
	if active:
		return
	active     = true
	_have_start_rot = false
	timer      = 0.0
	reason     = killer
	death_pos  = p_pos
	cam_start  = cam_start_global
	player_yaw = p_yaw
	if is_instance_valid(_cam) and _cam.get_parent() != null and _cam.get_parent().has_method("_drop_lens"):
		_cam.get_parent()._drop_lens()           # the camcorder's zoom ends with you: start from the plain view
	_fov0 = _cam.fov if is_instance_valid(_cam) else 75.0
	_orbit_ang = 0.0
	_radius_now = ORBIT_RADIUS
	_trauma = 0.0
	_landed = false
	_land_t = -1.0
	_fall_sounded = false
	_focus = p_pos + Vector3(0.0, 1.2, 0.0)
	_centre = p_pos

	# Nothing attacked you in a psychological collapse: no blood, you just go down
	var bloody := killer != "PSYCHOLOGICAL COLLAPSE"
	_caught = bloody
	if bloody and killer != "THE TALL ONE":      # (its blood is all in the world: death_fx)
		_show_blood_screen()
	var down := _down
	_down = {}
	# The killer is right in front of the view: the bite / snap sprays from about there
	var fwd := Vector3(-sin(p_yaw), 0.0, -cos(p_yaw))
	if bloody and killer != "THE BACTERIA" and killer != "THE MANNEQUIN" and down.is_empty():   # those already bled (bite(), face_tear())
		_fx.feast(cam_start_global + fwd * 0.8, p_pos)
	_fx.spawn_ragdoll(p_pos, p_yaw)
	if not down.is_empty():
		# already on your back: the body is lying there from the first frame, and there is no fall to hear
		_fx.lay_down(down.chest, down.head_dir)
		_fall_sounded = true
		_landed = true
	_lens.wipe(1.8)                               # the view lifts off you: the blood on the glass goes with it
	# Add a dim light above the dead body so the player can see their character
	_add_body_light(p_pos)

func _add_body_light(p_pos: Vector3) -> void:
	_remove_body_light()
	_body_light = OmniLight3D.new()
	_body_light.light_color = BODY_LIGHT_COLOR
	_body_light.light_energy = 0.0
	_body_light.omni_range = BODY_LIGHT_RANGE
	_body_light.omni_attenuation = 1.4
	_body_light.shadow_enabled = false
	add_child(_body_light)
	_body_light.global_position = p_pos + Vector3(0.0, BODY_LIGHT_HEIGHT, 0.0)

func _remove_body_light() -> void:
	if _body_light != null and is_instance_valid(_body_light):
		_body_light.queue_free()
	_body_light = null

# The body hitting the floor: the camera takes the jolt (the sound was started FALL_ONSET earlier)
func _land() -> void:
	_landed = true
	_trauma = maxf(_trauma, 0.75)
	_land_t = 0.0

## The bacteria's jaws close on you: blood sprays from its mouth and pools on the floor. Called from entity.gd at the bite.
func bite(mouth: Vector3, victim: Vector3, cam_pos: Vector3) -> void:
	_fx.feast(mouth, victim)
	# most of the spray is thrown at you, the rest sprays out
	var to_victim := cam_pos - mouth
	_fx.spray(mouth, to_victim if to_victim.length() > 0.01 else Vector3.UP)

## The bacteria's bite (bacteria_grab.gd): spray, mist and clots out of its jaws toward the camera. `count` scales
## the droplets (the preset's particle share times the bite's intensity), `force` their speed.
func bite_burst(origin: Vector3, dir: Vector3, count: float, force: float) -> void:
	_fx.burst(origin, dir, count, force)

## A friend's neck goes (remote_player.gd, the mannequin's snap): blood sprays from it, thrown the way they face.
func friend_spray(neck: Vector3, dir: Vector3) -> void:
	_fx.floor_y = neck.y - 1.65
	_fx.spray(neck, dir)
	for i in 6:
		_fx.drop(neck, dir * randf_range(0.5, 2.0) + Vector3(randf_range(-0.8, 0.8), randf_range(0.5, 1.8), randf_range(-0.8, 0.8)), randf_range(0.02, 0.05))

## A friend's body hits the floor (or they simply die): the pool under them and the spatter thrown around it.
func friend_pool(body: Vector3, dir: Vector3) -> void:
	_fx.feast(body + Vector3(0.0, 0.3, 0.0) + dir * 0.4, body)

## The grab begins: clear last run's blood
func grab_begin() -> void:
	_fx.clear()
	_lens.clear()

## You die lying on your back where you already are (THE TALL ONE sat on you): call before Game.kill_player. The
## body is laid with its chest at `chest` and its head toward `head_dir` instead of standing and falling.
func lying(chest: Vector3, head_dir: Vector3) -> void:
	_down = {"chest": chest, "head_dir": head_dir}

## Claws through your face (THE TALL ONE: tall_one.gd). Blood thrown up off it along the blow, falling back round
## your head, and heavy drops that stain the floor where they land. `strength` 0..1
func face_tear(face: Vector3, floor_y: float, dir: Vector3, strength: float) -> void:
	_fx.floor_y = floor_y
	var flat := Vector3(dir.x, 0.0, dir.z)
	var up := (flat.normalized() * 0.7 + Vector3.UP).normalized() if flat.length() > 0.01 else Vector3.UP
	_fx.burst(face, up, (0.5 + 0.8 * strength) * Gfx.particle_scale(), 0.45 + 0.35 * strength)
	for i in int(3 + 5 * strength):
		_fx.drop(face, flat.normalized() * randf_range(0.3, 1.4) + Vector3(randf_range(-0.6, 0.6), randf_range(1.0, 2.8), randf_range(-0.6, 0.6)), randf_range(0.015, 0.04))

## The pool spreading under your head (the face is gone): laid on the floor at `head`
func face_pool(head: Vector3) -> void:
	_fx.feast(head + Vector3(0.0, 0.25, 0.0), head)

## Blood thrown on the lens at `uv` (0..1 of the screen) along `dir` (screen space, y down); `size` 0..~0.2
func lens_splat(uv: Vector2, dir: Vector2, size: float) -> void:
	_lens.splat(uv, dir, size)

## A single droplet (js bloodDrop): flies, falls and stains where it lands
func bite_drop(pos: Vector3, vel: Vector3, size: float) -> void:
	_fx.drop(pos, vel, size)

func bite_drip(from: Vector3) -> void:
	_fx.drop(from, Vector3(randf_range(-0.3, 0.3), 0.0, randf_range(-0.3, 0.3)), randf_range(0.02, 0.05))

func stop() -> void:
	active = false
	timer  = 0.0
	_hide_blood_screen()
	_remove_body_light()
	_fx.clear()
	_lens.clear()
	_down = {}
	_cam    = null
	_player = null
	_scares = null

# ──────────────────────────────────────── blood-screen overlay ─────────────────
# The blood image fades in and slides down once, then holds still. It is scaled past the screen all the way
# through (pivot at the top centre), so its edges are never in view, even at rest. A faint red stain
# (shaders/blood_vignette.gdshader) creeps in along the borders.
func _show_blood_screen() -> void:
	if _blood_overlay != null:
		_blood_overlay.queue_free()

	_blood_overlay = CanvasLayer.new()
	_blood_overlay.layer = 20          # above the 3D scene, below the SIGNAL LOST overlay (30)
	add_child(_blood_overlay)

	if _blood_tex != null:
		_blood_rect = TextureRect.new()
		_blood_rect.texture = _blood_tex
		_blood_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		_blood_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_blood_rect.stretch_mode = TextureRect.STRETCH_SCALE
		_blood_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_blood_rect.modulate.a = 0.0
		_blood_overlay.add_child(_blood_rect)
		var vs := get_viewport().get_visible_rect().size
		_blood_rect.pivot_offset = Vector2(vs.x * 0.5, 0.0)
		_blood_rect.scale = Vector2(1.14, 1.14)
		_blood_rect.position = Vector2(0.0, -vs.y * 0.10)

	var mat := ShaderMaterial.new()
	mat.shader = BLOOD_EDGE
	_blood_edge = ColorRect.new()
	_blood_edge.material = mat
	_blood_edge.set_anchors_preset(Control.PRESET_FULL_RECT)
	_blood_edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_blood_overlay.add_child(_blood_edge)

	if _blood_tween != null and _blood_tween.is_valid():
		_blood_tween.kill()
	_blood_tween = create_tween().set_parallel(true)
	_blood_tween.tween_method(func(v: float) -> void: mat.set_shader_parameter("amount", v), 0.0, 1.0, 4.0).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_SINE)
	if _blood_rect != null:
		# the slide ends with the image still larger than the screen (scale 1.08, nudged up): no edge shows
		_blood_tween.tween_property(_blood_rect, "modulate:a", 0.5, 0.7).set_ease(Tween.EASE_OUT)
		_blood_tween.tween_property(_blood_rect, "position:y", 0.0, 7.0).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
		_blood_tween.tween_property(_blood_rect, "scale", Vector2(1.08, 1.08), 7.0).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)

func _hide_blood_screen() -> void:
	if _blood_tween != null and _blood_tween.is_valid():
		_blood_tween.kill()
	if _blood_overlay != null and is_instance_valid(_blood_overlay):
		_blood_overlay.queue_free()
		_blood_overlay = null
		_blood_rect = null
		_blood_edge = null

# ──────────────────────────────────────── camera orbit ─────────────────────────
func _process(delta: float) -> void:
	if not active:
		return
	if not is_instance_valid(_cam):
		active = false
		return
	timer += delta
	var t := timer
	var dp := death_pos
	if not _have_start_rot:
		_start_rot = _cam.global_transform.basis.get_rotation_quaternion()
		_have_start_rot = true

	# The body: its chest follows the fall clip. The camera glides after it rather than locking on.
	var chest: Vector3 = _fx.body_point(dp + Vector3(0.0, BODY_CENTER_Y, 0.0))
	_focus = _focus.lerp(chest + Vector3(0.0, 0.1, 0.0), 1.0 - exp(-delta / 0.22))
	_centre = _centre.lerp(Vector3(chest.x, dp.y, chest.z), 1.0 - exp(-delta / 0.6))

	# The light over the body: comes up as the camera lifts out, follows the chest, and never holds quite still
	if _body_light != null and is_instance_valid(_body_light):
		var flick := 1.0 + 0.06 * _noise(11.0, t * 3.0) + (-0.35 if randf() < delta * 0.6 else 0.0)
		_body_light.light_energy = BODY_LIGHT_ENERGY * _smoothstep((t - 0.2) / 1.6) * flick
		_body_light.global_position = Vector3(_focus.x, dp.y + BODY_LIGHT_HEIGHT, _focus.z)

	# The body-fall recording, timed off the fall clip itself (_fx.contact_time: the instant its back
	# meets the floor). It starts FALL_ONSET early so its thud lands on that exact frame; any frame of
	# lateness is skipped into the file rather than heard late.
	var fall_at: float = _fx.contact_time - FALL_ONSET
	if not _fall_sounded and t >= fall_at:
		_fall_sounded = true
		if is_instance_valid(_scares):
			_scares.body_fall(t - fall_at, not _caught)
	if not _landed and t >= _fx.contact_time:
		_land()
	_trauma = maxf(0.0, _trauma - delta * 1.3)
	var tr2 := _trauma * _trauma

	# The orbit: eases into a slow turn that never stops, and pushes in a little while you watch
	var push := _smoothstep(t / 30.0)
	_orbit_ang += TAU / ORBIT_LAP * _smoothstep((t - 0.5) / 2.5) * delta
	var ang := player_yaw + _orbit_ang
	var dir := Vector3(sin(ang), 0.0, cos(ang))
	var want_r := lerpf(ORBIT_RADIUS, ORBIT_RADIUS_END, push)
	# A spring arm: pull in fast when a wall is in the way, ease back out slowly once it clears
	var room := _clearance(_centre + Vector3(0.0, 1.2, 0.0), dir, want_r)
	_radius_now += (room - _radius_now) * (1.0 - exp(-delta * (10.0 if room < _radius_now else 1.2)))
	# boxed in: rise and look down on the body instead of pressing against the wall
	var cramped := clampf(1.0 - _radius_now / want_r, 0.0, 1.0)
	var orbit_pos := _centre + dir * _radius_now + Vector3(0.0, ORBIT_HEIGHT + 0.9 * cramped + 0.12 * sin(t * 0.23), 0.0)
	orbit_pos.y = minf(orbit_pos.y, _ceiling_y(orbit_pos) - CEIL_MARGIN)

	# The lift: an arc that rises up out of the body first, then swings out into the orbit
	var u := clampf(t / PULL_SECONDS, 0.0, 1.0)
	var s := lerpf(_smootherstep(u), 1.0 - pow(1.0 - u, 3.0), 0.5)
	var ctrl := cam_start + Vector3(0.0, 1.0, 0.0)
	ctrl.y = minf(ctrl.y, maxf(cam_start.y, _ceiling_y(cam_start) - CEIL_MARGIN))
	var pos := _bezier(cam_start, ctrl, orbit_pos, s)

	# A hand-held float once it settles, and the jolt of the body landing
	var float_w := _smoothstep((t - 0.8) / 2.0)
	pos += Vector3(_noise(1.0, t * 0.45), _noise(2.0, t * 0.35) * 0.6, _noise(3.0, t * 0.45)) * 0.05 * float_w
	pos += Vector3(_noise(4.0, t * 9.0), _noise(5.0, t * 9.0), _noise(6.0, t * 9.0)) * 0.06 * tr2
	# the thump: one quick damped bounce down and back, under the noise
	if _land_t >= 0.0:
		_land_t += delta
		pos.y += sin(_land_t * 26.0) * exp(-_land_t * 7.0) * -0.035
	# the ray above only sees walls in front of the lens: also keep it off one running alongside
	if t > 0.3:
		pos = _push_off_walls(pos)
	_cam.global_position = pos

	# Ease the view from wherever it was (the snapped-head stare, the jaws) round onto the body
	var to := _focus - pos
	if to.length_squared() > 0.0001 and absf(to.normalized().y) < 0.995:
		var target := Basis.looking_at(to.normalized(), Vector3.UP).get_rotation_quaternion()
		var b := Basis(_start_rot.slerp(target, _smoothstep(t / 1.1)))
		# a slow dutch tilt, a little sway, and the landing's shake
		var roll := (0.06 + 0.025 * sin(t * 0.31)) * _smoothstep((t - 0.4) / 2.5) \
			+ _noise(7.0, t * 0.5) * 0.012 * float_w + _noise(8.0, t * 11.0) * 0.05 * tr2
		var nod := _noise(9.0, t * 0.4) * 0.01 * float_w + _noise(10.0, t * 10.0) * 0.035 * tr2
		b = b.rotated(b.x.normalized(), nod)
		b = b.rotated(b.z.normalized(), roll)
		_cam.global_transform.basis = b

	# A longer lens for the death shot, closing in slowly; a kick when the body lands
	_cam.fov = lerpf(_fov0, DEATH_FOV - 4.0 * push, _smoothstep(t / PULL_SECONDS)) + 5.0 * tr2

	# The picture drains of colour and the edges stay dark while you look at what is left of you
	var drain := _smoothstep((t - 0.3) / 4.0)
	Game.fx_sat = lerpf(1.0, 0.45, drain)
	Game.fx_contrast = lerpf(1.0, 1.1, drain)
	Game.fx_fade = maxf(Game.fx_fade, 0.25 * drain)

# How far the camera can back away from `from` along `dir` before a wall (only level geometry counts:
# the fleeing entity or a survivor walking past must not shove the camera around)
func _clearance(from: Vector3, dir: Vector3, want: float) -> float:
	var space := _cam.get_world_3d().direct_space_state
	if space == null:
		return want
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * (want + CAM_MARGIN))
	var skip: Array[RID] = []
	if _player is CollisionObject3D:
		skip.append((_player as CollisionObject3D).get_rid())
	for i in 4:
		q.exclude = skip
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			return want
		if hit.collider is StaticBody3D:
			return clampf(from.distance_to(hit.position) - CAM_MARGIN, 0.9, want)
		skip.append(hit.rid)
	return want

# Walls are whole grid cells: push the point out of any neighbouring cell it is within CAM_MARGIN of
func _push_off_walls(p: Vector3) -> Vector3:
	var lvl = Game.level
	if lvl == null or not is_instance_valid(lvl):
		return p
	var c := Vector2i(roundi(p.x / CELL), roundi(p.z / CELL))
	var h := CELL * 0.5
	for dx in range(-1, 2):
		for dz in range(-1, 2):
			var n := c + Vector2i(dx, dz)
			if not lvl.walls.has(n):
				continue
			var near := Vector2(clampf(p.x, n.x * CELL - h, n.x * CELL + h), clampf(p.z, n.y * CELL - h, n.y * CELL + h))
			var away := Vector2(p.x, p.z) - near
			var gap := away.length()
			if gap > 0.0001 and gap < CAM_MARGIN:
				away = away / gap * (CAM_MARGIN - gap)
				p.x += away.x
				p.z += away.y
	return p

# World-space ceiling height over a point (low rooms are only 2.3 m)
func _ceiling_y(p: Vector3) -> float:
	var lvl = Game.level
	if lvl == null or not is_instance_valid(lvl) or not lvl.has_method("ceiling_height"):
		return INF
	return lvl.ceiling_height(Vector2i(roundi(p.x / CELL), roundi(p.z / CELL)))

# Smooth pseudo-noise in about -1..1 (a sum of unrelated sines)
func _noise(seed_v: float, t: float) -> float:
	return sin(t * 1.7 + seed_v * 4.7) * 0.5 + sin(t * 2.9 + seed_v * 8.1) * 0.3 + sin(t * 4.3 + seed_v * 2.9) * 0.2

func _bezier(a: Vector3, b: Vector3, c: Vector3, s: float) -> Vector3:
	var r := 1.0 - s
	return a * (r * r) + b * (2.0 * r * s) + c * (s * s)

func _smoothstep(t: float) -> float:
	var c := clampf(t, 0.0, 1.0)
	return c * c * (3.0 - 2.0 * c)

func _smootherstep(t: float) -> float:
	var c := clampf(t, 0.0, 1.0)
	return c * c * c * (c * (c * 6.0 - 15.0) + 10.0)


# ──────────────────────────────────────────────────────── respawn (respawn_fade.gd) ───
var respawn_busy: bool:
	get: return _fade.busy

## Called once the level is up: compile shaders / pipelines and start loading assets now, so the first
## death does not hitch.
func warmup() -> void:
	if _fade.busy:        # the level was just reloaded behind the fade: leave it alone
		return
	ResourceLoader.load_threaded_request(preload("res://scripts/Entities/survivor_anim.gd").MODEL)
	var sc: Node = Game.main.get_node_or_null("Scares") if Game.main != null and is_instance_valid(Game.main) else null
	if sc != null:
		sc.prewarm_death()
	_fade.warm()
	_fx.warm()

## Fade the screen to black, run `swap` (reload / reset) behind it, then fade back in.
func respawn_transition(swap: Callable) -> void:
	_fade.run(swap)
