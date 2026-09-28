extends Node3D
## THE MIMIC (js/game/mimicPeer.js). The web game ties it to a chat session with an
## LLM; offline it is the survivor look-alike:
##
##  PEER   a hazmat survivor look-alike that keeps at the edge of your sight. It walks up behind you
##         while your back is turned (approach), walks off when you face it (keepAway), sprints away
##         if you go at it (flee). During a power cut it CHARGES you in the dark, frozen while you
##         look, bolting when you catch it in your light; reaching you hurts and stuns.
## The Peer is dormant until a power cut (or F5) starts a "session".
## Dev keys: F5 toggles the Mimic peer.

const HazmatFit := preload("res://scripts/Entities/hazmat_fit.gd")
const GridNav := preload("res://scripts/World/grid_nav.gd")
const SnapBuffer := preload("res://scripts/Net/snap_buffer.gd")
const MODEL := "res://models/player/hazmat.glb"
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

# ---- co-op: the host runs the body (hunting the nearest survivor); guests follow it from snapshots.
const MODES := ["approach", "keepAway", "flee", "charge"]
var puppet := false
var net_buf = SnapBuffer.new()
var t_id := -1
var t_pos := Vector3.ZERO
var t_fwd := Vector3.FORWARD
var _net_t := 0.0
var anim: AnimationPlayer
var body_yaw := 0.0

func _ready() -> void:
	rng.randomize()
	level = get_parent().get_node("Level")
	player = get_parent().get_node("Player")
	scares = get_parent().get_node("Scares")
	nav = GridNav.new(level)
	_build_body()

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
	root.transform = HazmatFit.fit(root, body, MODEL_HEIGHT)
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
	var p := t_pos
	var fwd := t_fwd
	var dx := x - p.x
	var dz := z - p.z
	var l := maxf(sqrt(dx * dx + dz * dz), 0.001)
	return (fwd.x * dx + fwd.z * dz) / l

func watched_by(x: float, z: float, cone: float) -> bool:
	var p := t_pos
	return Vector2(x - p.x, z - p.z).length() < 45.0 and view_dot(x, z) > cone

# An open spot spawn_min..spawn_max metres away, out of your sight
func spot_around() -> Variant:
	var p := t_pos
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
	var p := t_pos
	body.global_position = Vector3(spot.x, p.y, spot.y)
	heading = atan2(p.x - spot.x, p.z - spot.y)
	speed = 0.0
	stuck = 0.0
	stuck_total = 0.0
	mode = "approach"
	spawned = true
	body.visible = true
	Archive.discover("mimic")
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
	if not session:
		return
	var tg := Net.nearest_survivor(body.global_position if spawned else player.global_position, t_id)
	if tg.is_empty():
		return                                       # nobody alive and in the game
	t_id = tg.id
	t_pos = tg.pos
	t_fwd = tg.fwd
	if not spawned:
		wait -= delta
		if wait <= 0.0:
			appear()
		return
	var pos := body.global_position
	var pp: Vector3 = t_pos
	var lp := player.global_position
	var ldist := Vector2(lp.x - pos.x, lp.z - pos.z).length()      # sound and heartbeat follow THIS player, not the target
	var dx := pp.x - pos.x
	var dz := pp.z - pos.z
	var dist := maxf(Vector2(dx, dz).length(), 0.001)
	var to_player := atan2(dx, dz)
	var watched := watched_by(pos.x, pos.z, VIEW_CONE)
	var t := now()
	if Game.heart != null:
		var near := clampf(1.0 - ldist / 12.0, 0.0, 1.0)
		Game.heart.feed("mimic", 0.9 if mode == "charge" else 0.2 + 0.5 * clampf(1.0 - ldist / 25.0, 0.0, 1.0), 3.0 * near * near)

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
		if tg.local:
			hit_player()
		else:
			Net.send_mm_hit(tg.id)               # the blow lands on their machine

	footsteps(delta, ldist)

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

# ================================================================= frame
func _physics_process(delta: float) -> void:
	var online := Net.is_online()
	puppet = online and not Net.hosting
	if not online and (not Game.playing or Game.dead):
		return
	if puppet:
		_puppet_step(delta)
	else:
		update_peer(delta)
		if online:
			_net_send(delta)

# ================================================================= co-op
func _net_send(delta: float) -> void:
	_net_t -= delta
	if _net_t > 0.0:
		return
	_net_t = 0.05
	var p := body.global_position
	Net.send_mm([p.x, p.y, p.z, body_yaw, speed, spawned, maxi(0, MODES.find(mode))])

func net_apply(t: float, m: Array) -> void:
	net_buf.send_interval = 0.05
	net_buf.push(t, {"pos": Vector3(m[0], m[1], m[2]), "yaw": float(m[3]), "speed": float(m[4]), "m": m})

# Guest: the host's Mimic, drawn smoothly, with its own footfalls and the heartbeat for THIS player
func _puppet_step(delta: float) -> void:
	var st: Dictionary = net_buf.sample(delta)
	if st.is_empty():
		return
	var m: Array = st.m
	spawned = m[5]
	body.visible = spawned
	if not spawned:
		return
	mode = MODES[clampi(int(m[6]), 0, MODES.size() - 1)]
	speed = st.speed
	body.global_position = st.pos
	body_yaw = st.yaw
	body.rotation.y = body_yaw
	var pos := body.global_position
	var lp := player.global_position
	var ldist := Vector2(lp.x - pos.x, lp.z - pos.z).length()
	if Game.heart != null and Game.playing and not player.dead:
		var near := clampf(1.0 - ldist / 12.0, 0.0, 1.0)
		Game.heart.feed("mimic", 0.9 if mode == "charge" else 0.2 + 0.5 * clampf(1.0 - ldist / 25.0, 0.0, 1.0), 3.0 * near * near)
	footsteps(delta, ldist)
	if anim and anim.has_animation("run"):
		if speed > 0.6:
			if not anim.is_playing():
				anim.play("run")
			anim.speed_scale = clampf(speed / 4.0, 0.4, 1.6)
		elif anim.is_playing():
			anim.pause()

func _unhandled_input(e: InputEvent) -> void:
	if not Game.dev_keys or not (e is InputEventKey and e.pressed and not e.echo):
		return
	if e.physical_keycode == KEY_F5:
		toggle_session()

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
