extends Node3D
## THE MIMIC (js/game/mimicPeer.js + mimicPeek.js). The web game ties it to a chat session with an
## LLM; offline it is two behaviours:
##
##  PEER   a hazmat survivor look-alike that keeps at the edge of your sight. It walks up behind you
##         while your back is turned (approach), walks off when you face it (keepAway), sprints away
##         if you go at it (flee). During a power cut it CHARGES you in the dark, frozen while you
##         look, bolting when you catch it in your light; reaching you hurts and stuns.
##  PEEK   stand still long enough and its head slides in from the edge of the screen to study
##         your face, then snaps away and footsteps run off into the dark.
##
## The Peer is dormant until a power cut (or F5) starts a "session".
## Dev keys: F5 toggles the Mimic peer, F3 forces a peek.

const GridNav := preload("res://scripts/world/grid_nav.gd")
const MODEL := "res://models/entities/hazmat.glb"
const MODEL_HEIGHT := 2.0

# MIMIC_PEER config
const SPAWN_MIN := 12.0
const SPAWN_MAX := 20.0
const STOP_AT := 7.0
const VIEW_CONE := 0.62
const WALK_SPEED := 1.5
const JOG_SPEED := 4.0
const FLEE_SPEED := 6.2
const ACCEL := 12.0
const TURN_RATE := 4.5
const FLEE_TURN_RATE := 8.0
const KEEP_AWAY_DIST := 10.0
const FLEE_DIST := 6.0
const FLEE_DONE_DIST := 26.0
const STUCK_AFTER := 4.0
const RELOCATE_AFTER := 12.0
const CHARGE_STOP := 2.5
const CHARGE_SPEED := 5.6
const HIT_DAMAGE := 40.0
const HIT_STUN := 2.0
const HIT_COOLDOWN := 8.0
const SPOOK_CHANCE := 0.04
const OFFSETS := [0.0, 0.35, -0.35, 0.7, -0.7, 1.1, -1.1, 1.6, -1.6, 2.2, -2.2, PI]

# MIMIC_PEEK config
const PEEK_COOLDOWN := 600.0
const PEEK_FIRST_WAIT := 30.0
const PEEK_STILL := 5.0
const PEEK_CHANCE := 0.5
const PEEK_IN := 1.4
const PEEK_HOLD := 2.0
const PEEK_OUT := 0.12
const PEEK_DIST := 0.9
const PEEK_HEIGHT := 2.6
const PEEK_STEPS := 7
const PEEK_STEP_GAP := 0.17
const PEEK_VOLUME := 0.9
const PEEK_SPOOK_SPEED := 2.6

var level: Node
var player: CharacterBody3D
var scares: Node
var nav
var rng := RandomNumberGenerator.new()

# ---- peer
var session := false
var spawned := false
var wait := 0.0
var mode := "approach"
var heading := 0.0
var speed := 0.0
var stuck := 0.0
var stuck_total := 0.0
var step := 0.0
var flee_until := 0.0
var react_at := 0.0
var hit_ready := 0.0
var body: Node3D
var anim: AnimationPlayer
var body_yaw := 0.0

# ---- peek
var pk_root: Node3D
var pk_head: Node3D
var pk_phase := "idle"
var pk_t := 0.0
var pk_side := 1.0
var pk_amount := 0.0
var pk_out_from := 1.0
var pk_still := 0.0
var pk_cooldown := PEEK_FIRST_WAIT
var pk_steps_left := 0
var pk_step_timer := 0.0
var pk_step_index := 0
var pk_last_yaw := 0.0
var pk_last_pitch := 0.0
var pk_turn := 0.0

func _ready() -> void:
	rng.randomize()
	level = get_parent().get_node("Level")
	player = get_parent().get_node("Player")
	scares = get_parent().get_node("Scares")
	nav = GridNav.new(level)
	_build_body()
	_build_peek()

func now() -> float:
	return Time.get_ticks_msec() / 1000.0

# ================================================================= peer
func _build_body() -> void:
	body = Node3D.new()
	body.visible = false
	add_child(body)
	var packed := load(MODEL) as PackedScene
	if packed == null:
		return
	var root: Node3D = packed.instantiate()
	body.add_child(root)
	var box := AABB()
	var first := true
	for m in root.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var t := Transform3D.IDENTITY
		var p: Node = mi
		while p != null and p != body:
			if p is Node3D:
				t = (p as Node3D).transform * t
			p = p.get_parent()
		var b := t * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	if box.size.y > 0.0:
		var sc := MODEL_HEIGHT / box.size.y
		var c := box.get_center()
		root.transform = Transform3D(Basis.from_scale(Vector3(sc, sc, sc)), Vector3(-c.x, -box.position.y, -c.z) * sc)
	var aps := root.find_children("*", "AnimationPlayer", true, false)
	if not aps.is_empty():
		anim = aps[0]
		if anim.has_animation("run"):
			anim.get_animation("run").loop_mode = Animation.LOOP_LINEAR

# The grid just went down: it comes for you in the dark (called by the power cut event)
func grid_down() -> void:
	if not session:
		session = true
		wait = 2.0
	elif not spawned:
		wait = minf(wait, 2.0)

func toggle_session() -> void:
	session = not session
	if session:
		wait = 1.0
	else:
		spawned = false
		body.visible = false

func view_dot(x: float, z: float) -> float:
	var p := player.global_position
	var fwd := -player.global_transform.basis.z
	var dx := x - p.x
	var dz := z - p.z
	var l := maxf(sqrt(dx * dx + dz * dz), 0.001)
	return (fwd.x * dx + fwd.z * dz) / l

func watched_by(x: float, z: float, cone: float) -> bool:
	var p := player.global_position
	return Vector2(x - p.x, z - p.z).length() < 45.0 and view_dot(x, z) > cone

# An open spot spawn_min..spawn_max metres away, out of your sight
func spot_around() -> Variant:
	var p := player.global_position
	var angles: Array = []
	for i in 16:
		angles.append(i * PI / 8.0)
	angles.shuffle()
	for a in angles:
		var dx := sin(a)
		var dz := cos(a)
		var reach := 0.0
		var d := 1.0
		while d <= SPAWN_MAX:
			if not nav.open_at(p.x + dx * d, p.z + dz * d):
				break
			reach = d
			d += 0.8
		if reach < SPAWN_MIN:
			continue
		d = SPAWN_MIN + rng.randf() * (reach - SPAWN_MIN)
		var x := p.x + dx * d
		var z := p.z + dz * d
		if not watched_by(x, z, VIEW_CONE - 0.1):
			return Vector2(x, z)
	return null

func appear() -> bool:
	var spot = spot_around()
	if spot == null:
		return false
	var p := player.global_position
	body.global_position = Vector3(spot.x, p.y, spot.y)
	heading = atan2(p.x - spot.x, p.z - spot.y)
	speed = 0.0
	stuck = 0.0
	stuck_total = 0.0
	mode = "approach"
	spawned = true
	body.visible = true
	return true

# Can a body walk from (x, z) heading `a` for `dist` metres without hitting a wall?
func clear_ahead(x: float, z: float, a: float, dist: float) -> bool:
	var sx := sin(a)
	var sz := cos(a)
	var d := 0.4
	while d <= dist:
		var px := x + sx * d
		var pz := z + sz * d
		if not nav.open_at(px, pz) or not nav.open_at(px + sz * 0.3, pz - sx * 0.3) or not nav.open_at(px - sz * 0.3, pz + sx * 0.3):
			return false
		d += 0.4
	return true

# The open heading closest to `want`, looking ahead `look` metres; NAN when boxed in
func steer_to(x: float, z: float, want: float, look: float) -> float:
	for off in OFFSETS:
		if clear_ahead(x, z, want + off, look):
			return want + off
	return NAN

func footsteps(delta: float, dist: float) -> void:
	var pos := body.global_position
	if mode == "charge" and speed <= 1.0:
		step = 0.0
	if (mode == "flee" or mode == "charge") and speed > (1.0 if mode == "charge" else 3.0) and dist < 30.0:
		step -= delta
		if step <= 0.0:
			step = 0.27 if mode == "charge" else 0.3
			scares.play_scare("footThump", Vector3(pos.x, player.global_position.y + 0.2, pos.z), maxf(0.2, 0.75 * (1.0 - dist / 30.0)))

func update_peer(delta: float) -> void:
	if not session or player.dead:
		return
	if not spawned:
		wait -= delta
		if wait <= 0.0:
			appear()
		return
	var pos := body.global_position
	var pp := player.global_position
	var dx := pp.x - pos.x
	var dz := pp.z - pos.z
	var dist := maxf(Vector2(dx, dz).length(), 0.001)
	var to_player := atan2(dx, dz)
	var watched := watched_by(pos.x, pos.z, VIEW_CONE)
	var t := now()

	# decide what it is doing
	var charging: bool = player.grid_down
	var home := "charge" if charging else "approach"
	if not charging and mode == "charge":
		mode = "approach"                       # the lights are back
	if mode == "flee":
		if t > flee_until and (charging or dist > FLEE_DONE_DIST or (not watched and dist > 16.0)):
			mode = home
	elif charging:
		if mode != "charge":
			mode = "charge"
			step = 0.0
		if watched and dist < 40.0:
			# caught in your light: it reacts after a beat that is never quite the same
			if react_at == 0.0:
				react_at = t + 0.15 + rng.randf() * 1.1
			if t >= react_at:
				mode = "flee"
				flee_until = t + 2.0 + rng.randf() * 2.5
				react_at = 0.0
		else:
			react_at = 0.0
			# ...and sometimes it turns tail for no reason, so the pattern never reads as a script
			if rng.randf() < SPOOK_CHANCE * delta:
				mode = "flee"
				flee_until = t + 1.2 + rng.randf() * 1.8
	elif watched and dist < FLEE_DIST:
		mode = "flee"
		flee_until = t + 2.5
	elif watched and dist < KEEP_AWAY_DIST:
		mode = "keepAway"
	elif mode != "approach" and (not watched or dist >= KEEP_AWAY_DIST + 2.0):
		mode = "approach"

	# where it wants to go, and how fast
	var want := to_player
	var goal := 0.0
	var turn := TURN_RATE
	if mode == "flee":
		want = to_player + PI
		goal = FLEE_SPEED
		turn = FLEE_TURN_RATE
	elif mode == "charge":
		# it only runs while you are not looking; look back at it and it freezes, then bolts
		goal = CHARGE_SPEED if (dist > CHARGE_STOP and not watched) else 0.0
		turn = FLEE_TURN_RATE
	elif mode == "keepAway":
		want = to_player + PI
		goal = WALK_SPEED * 1.2
	elif dist > STOP_AT:
		goal = JOG_SPEED if dist > 18.0 else WALK_SPEED
		if watched:
			goal *= 0.5

	# steer round walls, then turn and accelerate like a body would
	var steered := NAN
	if goal > 0.0:
		steered = steer_to(pos.x, pos.z, want, 0.8 + speed * 0.5)
	if not is_nan(steered):
		heading = heading + clampf(wrapf(steered - heading, -PI, PI), -turn * delta, turn * delta)
	elif goal > 0.0:
		goal = 0.0                                # boxed in: stop rather than clip through
	var misalign := 0.0 if is_nan(steered) else absf(wrapf(steered - heading, -PI, PI))
	if misalign > 0.6:
		goal *= 0.7
	var rate := ACCEL * delta
	speed += clampf(goal - speed, -rate * 1.5, rate)

	var before := pos.x + pos.z * 1.37
	if speed > 0.01:
		var nx := pos.x + sin(heading) * speed * delta
		var nz := pos.z + cos(heading) * speed * delta
		if nav.open_at(nx, nz):
			pos.x = nx
			pos.z = nz
		elif nav.open_at(nx, pos.z):
			pos.x = nx
		elif nav.open_at(pos.x, nz):
			pos.z = nz
		else:
			speed = 0.0
	pos.y = pp.y
	body.global_position = pos

	# it reaches you: a blow that stuns and hurts, then it bolts
	if mode == "charge" and dist < CHARGE_STOP + 0.5 and t >= hit_ready:
		hit_ready = t + HIT_COOLDOWN
		mode = "flee"
		flee_until = t + 3.0 + rng.randf() * 2.0
		hit_player()

	footsteps(delta, Vector2(pp.x - pos.x, pp.z - pos.z).length())

	# wedged somewhere: try another way, and if it stays stuck out of sight, start over elsewhere
	var moved := absf(pos.x + pos.z * 1.37 - before)
	if goal > 0.0 and moved < 0.002:
		stuck += delta
		stuck_total += delta
	else:
		stuck = 0.0
		if speed > 1.0:
			stuck_total = 0.0
	if stuck > STUCK_AFTER:
		heading += (rng.randf() - 0.5) * PI
		stuck = 0.0
	if stuck_total > RELOCATE_AFTER and not watched:
		stuck_total = 0.0
		appear()

	# the rig: face where it is going (or at its target when it stands)
	var standing := speed < 0.3
	var want_yaw := atan2(dx, dz) if standing else heading
	body_yaw = lerp_angle(body_yaw, want_yaw, minf(1.0, delta * 10.0))
	body.rotation.y = body_yaw
	if anim and anim.has_animation("run"):
		if speed > 0.6:
			if not anim.is_playing():
				anim.play("run")
			anim.speed_scale = clampf(speed / 4.0, 0.4, 1.6)
		elif anim.is_playing():
			anim.pause()

func hit_player() -> void:
	if player.dead or player.frozen:
		return
	player.health = maxf(0.0, player.health - HIT_DAMAGE)
	player.frozen = true
	Game.add_glitch(1.0)
	scares.gasp()
	if player.health <= 0.0:
		Game.kill_player("A SURVIVOR")    # the death plays the hit itself: don't stack a second one
		return
	scares.startle(0.9)
	scares.play_scare("staticHit", 1.0)
	get_tree().create_timer(HIT_STUN).timeout.connect(func():
		if not Game.dead:
			player.frozen = false)

# ================================================================= peek
func _build_peek() -> void:
	pk_root = Node3D.new()
	pk_root.visible = false
	player.get_node("Camera3D").add_child(pk_root)
	pk_head = Node3D.new()
	pk_root.add_child(pk_head)
	var packed := load("res://models/entities/howler.glb") as PackedScene
	if packed == null:
		return
	var root: Node3D = packed.instantiate()
	pk_head.add_child(root)
	var box := AABB()
	var first := true
	for m in root.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var t := Transform3D.IDENTITY
		var p: Node = mi
		while p != null and p != pk_head:
			if p is Node3D:
				t = (p as Node3D).transform * t
			p = p.get_parent()
		var b := t * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	if box.size.y <= 0.0:
		return
	var sc := PEEK_HEIGHT / box.size.y
	var c := box.get_center()
	var rot := Basis(Vector3.UP, -PI / 2.0) * Basis.from_scale(Vector3(sc, sc, sc))
	var norm_pos := rot * Vector3(-c.x, -box.position.y, -c.z) + Vector3(0, -PEEK_HEIGHT * 0.92, 0)
	root.transform = Transform3D(rot, norm_pos)
	# pitch black, drawn on top of everything so no wall can hide it
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.BLACK
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.render_priority = 100
	for m in root.find_children("*", "MeshInstance3D", true, false):
		(m as MeshInstance3D).material_override = mat
		(m as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		(m as MeshInstance3D).extra_cull_margin = 16.0

# Screen edge at the head's distance: how far out is off screen, how far in is a peek
func peek_pose(amount: float) -> Vector2:
	var cam: Camera3D = player.cam
	var half_h := tan(deg_to_rad(cam.fov / 2.0)) * PEEK_DIST
	var vp := get_viewport().get_visible_rect().size
	var half_w := half_h * (vp.x / maxf(vp.y, 1.0))
	var hidden := half_w + 0.45
	var shown := half_w - 0.4
	return Vector2(pk_side * (hidden + (shown - hidden) * amount), half_h * 0.3 - (1.0 - amount) * half_h * 0.3)

# How the head is held: turned to face you, top leaning in, a slow scan, a breath, a twitch
func peek_pose_head(amount: float) -> void:
	var t := now()
	var s := pk_side
	var reach := minf(1.0, amount)
	var twitch := pow(maxf(0.0, sin(t * 5.3)), 24.0) * 0.07 * sin(t * 61.0)
	var z := s * (0.12 + 0.4 * reach) + sin(t * 1.3) * 0.05 * reach
	var y := -s * 0.5 + sin(t * 0.8) * 0.12 * reach
	var x := -0.08 * reach + sin(t * 2.3) * 0.025 * reach
	if pk_phase == "out":
		var u := minf(1.0, pk_t / PEEK_OUT)
		z += s * 0.7 * u
		y += s * 0.6 * u
	pk_head.rotation = Vector3(x + twitch, y, z + twitch)

func peek_start() -> bool:
	if pk_phase != "idle" or player.dead:
		return false
	pk_side = -1.0 if rng.randf() < 0.5 else 1.0
	pk_phase = "in"
	pk_t = 0.0
	pk_out_from = 1.0
	pk_amount = 0.0
	pk_turn = 0.0
	pk_last_yaw = player.rotation.y
	pk_last_pitch = player.cam.rotation.x
	pk_root.visible = true
	# its voice: an entity call from right beside you, on its side
	var at: Vector3 = player.cam.to_global(Vector3(pk_side * 1.2, 0.0, -0.4))
	at.y = player.global_position.y + 1.4
	scares.entity_call("stalk", at, false, PEEK_VOLUME)
	return true

# footsteps carrying off behind it, quieter and further each time
func peek_step() -> void:
	var i := pk_step_index
	pk_step_index += 1
	var fade := 1.0 - float(i) / PEEK_STEPS
	var at: Vector3 = player.cam.to_global(Vector3(pk_side * (1.5 + i * 1.1), 0.0, 0.5 + i * 1.4))
	at.y = player.global_position.y + 0.2
	scares.play_scare("footThump", at, maxf(0.15, 0.85 * fade))

func peek_hide() -> void:
	if pk_root:
		pk_root.visible = false
	pk_phase = "idle"
	pk_steps_left = 0

func peek_now() -> bool:
	peek_hide()
	return peek_start()

func update_peek(delta: float) -> void:
	if pk_phase == "idle":
		if pk_cooldown > 0.0:
			pk_cooldown -= delta
			return
		# walking counts as calm: only sprinting (or being hurt) restarts the count
		if player.is_sprinting or player.dead or player.frozen:
			pk_still = 0.0
			return
		pk_still += delta
		if pk_still < PEEK_STILL:
			return
		pk_still = 0.0
		pk_cooldown = PEEK_COOLDOWN             # win or lose, the wait starts again
		if rng.randf() < PEEK_CHANCE:
			peek_start()
		return
	if player.dead:
		peek_hide()
		return
	pk_t += delta
	# whip the camera round and it bolts, from wherever it has got to
	var yaw := player.rotation.y
	var pitch: float = player.cam.rotation.x
	var d_yaw := wrapf(yaw - pk_last_yaw, -PI, PI)
	var turn := sqrt(d_yaw * d_yaw + (pitch - pk_last_pitch) * (pitch - pk_last_pitch)) / delta if delta > 0.0 else 0.0
	pk_last_yaw = yaw
	pk_last_pitch = pitch
	pk_turn += (turn - pk_turn) * minf(1.0, delta * 12.0)
	if (pk_phase == "in" or pk_phase == "hold") and pk_turn > PEEK_SPOOK_SPEED:
		_peek_begin_out()
	var amount := 1.0
	if pk_phase == "in":
		var u := minf(1.0, pk_t / PEEK_IN)
		amount = 0.5 - cos(u * PI) / 2.0
		amount = amount * amount * (3.0 - 2.0 * amount)
		if u >= 1.0:
			pk_phase = "hold"
			pk_t = 0.0
	elif pk_phase == "hold":
		amount = 1.0 + minf(1.0, pk_t / PEEK_HOLD) * 0.1
		if pk_t >= PEEK_HOLD:
			_peek_begin_out()
	elif pk_phase == "out":
		var u2 := minf(1.0, pk_t / PEEK_OUT)
		amount = pk_out_from * (1.0 - u2 * u2)
		if u2 >= 1.0:
			pk_root.visible = false
			pk_phase = "run"
	if pk_phase == "in" or pk_phase == "hold" or pk_phase == "out":
		pk_amount = amount
		var pose := peek_pose(amount)
		pk_root.position = Vector3(pose.x, pose.y, -PEEK_DIST)
		peek_pose_head(amount)
	if pk_phase == "out" and pk_steps_left == PEEK_STEPS:
		peek_step()
		pk_steps_left -= 1
		pk_step_timer = PEEK_STEP_GAP
	if pk_phase == "out" or pk_phase == "run":
		pk_step_timer -= delta
		if pk_steps_left > 0 and pk_step_timer <= 0.0:
			peek_step()
			pk_steps_left -= 1
			pk_step_timer = PEEK_STEP_GAP
		if pk_phase == "run" and pk_steps_left <= 0:
			pk_phase = "idle"

func _peek_begin_out() -> void:
	pk_phase = "out"
	pk_t = 0.0
	pk_out_from = pk_amount
	pk_step_index = 0
	pk_step_timer = 0.0
	pk_steps_left = PEEK_STEPS

# ================================================================= frame
func _physics_process(delta: float) -> void:
	if not Game.playing or Game.dead:
		return
	update_peer(delta)
	update_peek(delta)

func _unhandled_input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	if e.physical_keycode == KEY_F5:
		toggle_session()
	elif e.physical_keycode == KEY_F3:
		peek_now()

# ---------------------------------------------------------------- debug console
func debug_active() -> bool:
	return session

func debug_despawn() -> void:
	session = false
	spawned = false
	body.visible = false

func debug_spawn() -> bool:
	session = true
	if not spawned:
		wait = 0.1
	return true
