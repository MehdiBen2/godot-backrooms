extends Node3D
## THE WATCHER. A tall black figure that stands at the far end of a long corridor and only watches.
## It fades in slowly, faint and half-seen. It never closes in: walk at it and it fades away, stare
## at it too long or lose line of sight and it is simply gone, to turn up down another corridor later.
##
## It also leans out from behind wall corners near you, then ducks back.
##
## Debug console: `spawn watcher [peek|stand]` / `despawn watcher`.

const GridNav := preload("res://scripts/world/grid_nav.gd")
const TEXTURE := "res://textures/entities/watcher.png"
const HEIGHT := 3.8
const ASPECT := 360.0 / 1138.0

const FIRST_WAIT := 25.0
const RESPAWN_MIN := 20.0
const RESPAWN_MAX := 50.0
const MIN_CORRIDOR := 36.0        # it only appears where you can see at least this far
const MIN_DIST := 36.0
const MAX_DIST := 48.0
const MAX_ALPHA := 0.95
const FADE_IN := 3.0
const FADE_OUT := 1.2
const VIEW_CONE := 0.8
const STARE_TIME := 1.6           # seconds of being looked at before it goes
const UNSEEN_TIME := 12.0         # seconds out of your sight before it goes
const LOST_LINE_TIME := 1.5
const RUN_DIST := 32.0           # closer than this and it bolts, instantly
const RUN_SPEED := 26.0          # far faster than you can sprint
const RUN_ACCEL := 140.0
const RUN_TELL := 0.25           # it freezes dead for a beat when it notices you, then explodes away
const RUN_STEP := 0.07           # it moves in stop-motion jumps (~14 a second), not a smooth run
const OFF_SCREEN := 0.5          # view_dot below this = outside your field of view

# corner peeks: it leans out from behind a wall edge near you, then ducks back
const PEEK_CHANCE := 0.5
const PEEK_MIN := 15.0
const PEEK_MAX := 28.0
const PEEK_IN := 1.8
const PEEK_OUT := 0.15
const PEEK_STARE := 1.4           # seconds of being looked at before it ducks back
const PEEK_HIDE_DIST := 13.0
const PEEK_UNSEEN := 8.0
const PEEK_DELAY_MIN := 1.0
const PEEK_DELAY_MAX := 3.0

var level: Node
var player: CharacterBody3D
var nav
var rng := RandomNumberGenerator.new()
var quad: MeshInstance3D
var mat: StandardMaterial3D
var puff_mat: StandardMaterial3D
var ring_mat: StandardMaterial3D
var puffs: Array = []
var face_mat: StandardMaterial3D
var eye_mat: StandardMaterial3D
var eye: MeshInstance3D

# ---- co-op: the host runs the figure against the nearest survivor (and counts EVERY survivor's stare);
# guests draw the same figure from snapshots and feel it against their own position.
const _SNAP := preload("res://scripts/net/snap_buffer.gd")
var puppet := false
var net_buf = _SNAP.new()
var t_id := -1
var t_pos := Vector3.ZERO
var t_fwd := Vector3.FORWARD
var t_local := true
var vis_alpha := 0.0
var _net_t := 0.0
var _view_t := 0.0
var enabled := true              # false: it stays gone (console despawn)
var present := false
var alpha := 0.0
var fade_speed := 1.0 / FADE_IN
var fading_out := false
var wait := FIRST_WAIT
var watched_for := 0.0
var unseen_for := 0.0
var no_line_for := 0.0
var clock := 0.0
var run_speed := 0.0
var running := false
var run_heading := 0.0
var run_tell := 0.0
var run_step_t := 0.0
var run_stuck := 0.0

var peek_mode := false
var peek_hide := Vector3.ZERO
var peek_show := Vector3.ZERO
var peek_amt := 0.0
var peek_dir := Vector3.ZERO
var peek_creep := 0.0
var peek_delay := 0.0
var peek_leaving := false

func _ready() -> void:
	rng.randomize()
	level = get_parent().get_node("Level")
	player = get_parent().get_node("Player")
	nav = GridNav.new(level)
	_build_quad()

func _load_texture() -> Texture2D:
	var t := load(TEXTURE) as Texture2D
	if t != null:
		return t
	var img := Image.load_from_file(ProjectSettings.globalize_path(TEXTURE))   # not imported yet
	if img == null:
		return null
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

func _build_quad() -> void:
	mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_texture = _load_texture()
	mat.albedo_color = Color(1, 1, 1, 0)
	var qm := QuadMesh.new()
	qm.size = Vector2(HEIGHT * ASPECT, HEIGHT)
	quad = MeshInstance3D.new()
	quad.mesh = qm
	quad.material_override = mat
	quad.position.y = HEIGHT / 2.0
	quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	quad.visible = false
	add_child(quad)
	_build_mist()
	_build_face()

# Black mist pooled round its feet, so it reads as something standing in the dark and not a flat cut-out
func _build_mist() -> void:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	g.colors = PackedColorArray([Color(0, 0, 0, 0.95), Color(0, 0, 0, 0.5), Color(0, 0, 0, 0.0)])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 128
	tex.height = 128
	puff_mat = StandardMaterial3D.new()
	puff_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	puff_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	puff_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	puff_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	puff_mat.albedo_texture = tex
	ring_mat = puff_mat.duplicate()
	ring_mat.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED
	var ring := MeshInstance3D.new()
	var rq := QuadMesh.new()
	rq.size = Vector2(4.2, 4.2)
	ring.mesh = rq
	ring.material_override = ring_mat
	ring.rotation.x = -PI / 2.0
	ring.position.y = 0.05 - HEIGHT / 2.0
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	quad.add_child(ring)
	for i in 8:
		var m := MeshInstance3D.new()
		var q := QuadMesh.new()
		var sz := rng.randf_range(1.5, 2.6)
		q.size = Vector2(sz, sz * 0.8)
		m.mesh = q
		m.material_override = puff_mat
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		quad.add_child(m)
		puffs.append({"n": m, "ang": rng.randf() * TAU, "rad": rng.randf_range(0.2, 0.8),
			"y": rng.randf_range(0.1, 1.1), "spd": rng.randf_range(0.15, 0.4) * (1.0 if i % 2 == 0 else -1.0),
			"ph": rng.randf() * TAU})

# How much it frightens you right now: felt before it is seen, worst when it is watching you
func _feel(level: float) -> void:
	if t_local and Game.heart != null:
		Game.heart.feed("watcher", level)

# From 40 m the face is a couple of pixels, so it gets an enlarged copy of the head laid over the
# figure (a big, wrong head) and a faint cold glint in the eye socket that pulses like it is blinking
const FACE_SCALE := 1.8
const FACE_UV := Rect2(0.26, 0.0, 0.45, 0.22)      # the head, as a fraction of the texture
const EYE_AT := Vector2(0.494, 0.097)              # the dark eye socket

func _build_face() -> void:
	face_mat = mat.duplicate()
	face_mat.uv1_scale = Vector3(FACE_UV.size.x, FACE_UV.size.y, 1.0)
	face_mat.uv1_offset = Vector3(FACE_UV.position.x, FACE_UV.position.y, 0.0)
	face_mat.render_priority = 1
	var fq := QuadMesh.new()
	fq.size = Vector2(HEIGHT * ASPECT * FACE_UV.size.x, HEIGHT * FACE_UV.size.y) * FACE_SCALE
	var face := MeshInstance3D.new()
	face.mesh = fq
	face.material_override = face_mat
	var head_y := FACE_UV.position.y + FACE_UV.size.y * 0.5
	face.position = Vector3(0.0, (0.5 - head_y) * HEIGHT, 0.0)
	face.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	quad.add_child(face)
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.35, 1.0])
	g.colors = PackedColorArray([Color(0.85, 0.92, 1.0, 1.0), Color(0.6, 0.72, 0.9, 0.35), Color(0.4, 0.5, 0.7, 0.0)])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 64
	tex.height = 64
	eye_mat = puff_mat.duplicate()
	eye_mat.albedo_texture = tex
	eye_mat.render_priority = 2
	var eq := QuadMesh.new()
	eq.size = Vector2(0.42, 0.42)
	eye = MeshInstance3D.new()
	eye.mesh = eq
	eye.material_override = eye_mat
	eye.position = Vector3(0.0, (0.5 - EYE_AT.y) * HEIGHT, 0.05)
	eye.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	quad.add_child(eye)

func _haunt(amount: float) -> void:
	if t_local:
		Game.haunt(amount)

func _set_visual(a: float) -> void:
	vis_alpha = a
	mat.albedo_color = Color(1, 1, 1, a)
	face_mat.albedo_color = Color(1.3, 1.3, 1.3, a)
	# a slow cold pulse, and now and then a blink
	var blink := 0.0 if fmod(clock, 5.3) < 0.18 else 1.0
	eye_mat.albedo_color = Color(1, 1, 1, a * blink * (0.35 + 0.25 * sin(clock * 2.2)))
	puff_mat.albedo_color = Color(1, 1, 1, minf(1.0, a * 1.1))
	ring_mat.albedo_color = Color(1, 1, 1, a)
	for p in puffs:
		var ang: float = p.ang + clock * p.spd
		var r: float = p.rad * (1.0 + 0.15 * sin(clock * 0.9 + p.ph))
		p.n.position = Vector3(cos(ang) * r, p.y + 0.1 * sin(clock * 0.7 + p.ph) - HEIGHT / 2.0, sin(ang) * r)

func view_dot(x: float, z: float) -> float:
	var p := t_pos
	var fwd := t_fwd
	var dx := x - p.x
	var dz := z - p.z
	var l := maxf(sqrt(dx * dx + dz * dz), 0.001)
	var fl := maxf(sqrt(fwd.x * fwd.x + fwd.z * fwd.z), 0.001)
	return (fwd.x * dx + fwd.z * dz) / (l * fl)

# The far end of a long straight run you are looking down (or, failing that, any long run)
func find_spot() -> Variant:
	var p := t_pos
	var fwd := t_fwd
	var best := -INF
	var spot = null
	for i in 16:
		var a := i * PI / 8.0
		var dx := sin(a)
		var dz := cos(a)
		var reach := 0.0
		var d := 1.0
		while d <= MAX_DIST:
			if not nav.open_at(p.x + dx * d, p.z + dz * d):
				break
			reach = d
			d += 0.8
		if reach < MIN_CORRIDOR:
			continue
		var score := (dx * fwd.x + dz * fwd.z) + rng.randf() * 0.5
		if score > best:
			best = score
			var dist := rng.randf_range(MIN_DIST, minf(reach, MAX_DIST))
			spot = Vector2(p.x + dx * dist, p.z + dz * dist)
	return spot

func appear(kind := "") -> bool:
	if kind == "peek" or (kind == "" and rng.randf() < PEEK_CHANCE):
		if find_peek_spot():
			return true
		if kind == "peek":
			return false
	peek_mode = false
	var spot = find_spot()
	if spot == null:
		return false
	global_position = Vector3(spot.x, t_pos.y, spot.y)
	present = true
	fading_out = false
	alpha = 0.0
	fade_speed = 1.0 / FADE_IN
	watched_for = 0.0
	unseen_for = 0.0
	no_line_for = 0.0
	run_speed = 0.0
	running = false
	quad.scale = Vector3.ONE
	quad.visible = true
	return true

# A corner near you: hidden by a wall edge from where you stand, but one step out from behind it
# and you would see it. hide = tucked behind the wall, show = leaning out past the edge.
func find_peek_spot() -> bool:
	var p := t_pos
	var R := ceili(PEEK_MAX / GridNav.CELL) + 1
	var pcx := GridNav.cell(p.x)
	var pcz := GridNav.cell(p.z)
	var best := -INF
	var found := false
	for cx in range(pcx - R, pcx + R + 1):
		for cz in range(pcz - R, pcz + R + 1):
			if cx < 1 or cz < 1 or cx >= nav.n - 1 or cz >= nav.n - 1 or nav.blocked(cx, cz):
				continue
			var wx: float = cx * GridNav.CELL
			var wz: float = cz * GridNav.CELL
			var d := Vector2(wx - p.x, wz - p.z).length()
			if d < PEEK_MIN or d > PEEK_MAX or nav.clear_line(wx, wz, p.x, p.z):
				continue
			for o in GridNav.NEIGHBOURS:
				var nx: int = cx + o.x
				var nz: int = cz + o.y
				if nav.blocked(nx, nz):
					continue
				var nwx: float = nx * GridNav.CELL
				var nwz: float = nz * GridNav.CELL
				if not nav.clear_line(nwx, nwz, p.x, p.z):
					continue
				var edge := -1.0
				var s := 0.05
				while s <= 1.001:
					if nav.clear_line(wx + (nwx - wx) * s, wz + (nwz - wz) * s, p.x, p.z):
						edge = s * GridNav.CELL
						break
					s += 0.05
				if edge < 0.0:
					continue
				var score := -absf(d - 21.0) / 21.0 + rng.randf() * 0.6
				if score <= best:
					continue
				best = score
				found = true
				var dir := Vector3(o.x, 0.0, o.y)
				var base := Vector3(wx, p.y, wz)
				peek_hide = base + dir * maxf(0.0, edge - 0.9)
				peek_show = base + dir * (edge + rng.randf_range(-0.25, 0.0))
				peek_dir = dir
	if not found:
		return false
	peek_mode = true
	peek_amt = 0.0
	peek_creep = 0.0
	peek_leaving = false
	peek_delay = rng.randf_range(PEEK_DELAY_MIN, PEEK_DELAY_MAX)
	present = true
	fading_out = false
	alpha = 0.0
	watched_for = 0.0
	unseen_for = 0.0
	global_position = peek_hide
	quad.scale = Vector3.ONE
	quad.visible = true
	return true

func _update_peek(delta: float) -> void:
	var pos := global_position
	var pp := t_pos
	var dist := Vector2(pos.x - pp.x, pos.z - pp.z).length()
	if peek_delay > 0.0:
		peek_delay -= delta
		_feel(0.15)
	elif not peek_leaving:
		peek_amt = minf(1.0, peek_amt + delta / PEEK_IN)
		var line: bool = nav.clear_line(pos.x, pos.z, pp.x, pp.z)
		if (line and peek_amt > 0.6 and view_dot(pos.x, pos.z) > 0.6) or (peek_amt > 0.6 and Net.watch_seen_by_peers()):
			watched_for += delta
			unseen_for = 0.0
			_haunt(0.15)
			_feel(0.55 + 0.3 * peek_creep)
		elif peek_amt >= 1.0:
			unseen_for += delta
		if peek_amt >= 1.0:
			peek_creep = minf(1.0, peek_creep + delta / 3.0)      # edges out a little further while it holds
		if watched_for > PEEK_STARE or dist < PEEK_HIDE_DIST or unseen_for > PEEK_UNSEEN:
			peek_leaving = true
	if peek_leaving:
		peek_amt = maxf(0.0, peek_amt - delta / PEEK_OUT)
	var e := smoothstep(0.0, 1.0, peek_amt)
	global_position = peek_hide.lerp(peek_show, e) + peek_dir * 0.45 * peek_creep * e
	var flicker := 0.9 + 0.1 * sin(clock * 11.0)
	_set_visual(MAX_ALPHA * flicker)   # never fades: the wall hides it
	if peek_leaving and peek_amt <= 0.0:
		peek_mode = false
		_gone()
		wait = rng.randf_range(15.0, 35.0)

func _gone() -> void:
	present = false
	fading_out = false
	alpha = 0.0
	quad.scale = Vector3.ONE
	quad.visible = false
	wait = rng.randf_range(RESPAWN_MIN, RESPAWN_MAX)

func _physics_process(delta: float) -> void:
	var online := Net.is_online()
	puppet = online and not Net.hosting
	if puppet:
		_puppet_step(delta)
		return
	if not Game.playing and not online:
		return
	var tg := Net.nearest_survivor(global_position if present else player.global_position, t_id)
	if tg.is_empty():
		return                                       # nobody alive and in the game
	t_id = tg.id
	t_pos = tg.pos
	t_fwd = tg.fwd
	t_local = tg.local
	clock += delta
	if online:
		_net_send(delta)
	if not present:
		if not enabled:
			return
		wait -= delta
		if wait <= 0.0:
			if not appear():
				wait = 3.0
		return

	if peek_mode:
		_update_peek(delta)
		return

	var pos := global_position
	var pp := t_pos
	var dist := Vector2(pos.x - pp.x, pos.z - pp.z).length()
	var line: bool = nav.clear_line(pos.x, pos.z, pp.x, pp.z)
	var watched := (line and view_dot(pos.x, pos.z) > VIEW_CONE and dist < 45.0) or Net.watch_seen_by_peers()

	if not running:
		no_line_for = 0.0 if line else no_line_for + delta
		if watched:
			watched_for += delta
			unseen_for = 0.0
			_haunt(0.12)
			_feel(0.45 + 0.35 * minf(1.0, watched_for / STARE_TIME))
		else:
			unseen_for += delta
			_feel(0.2)                 # you feel it there before you see it
		if no_line_for > LOST_LINE_TIME:
			_gone()                    # round a corner, so nobody sees it go
			return
		if dist < RUN_DIST or watched_for > STARE_TIME or unseen_for > UNSEEN_TIME:
			running = true
			run_tell = RUN_TELL
			run_stuck = 0.0
			run_heading = atan2(pos.x - pp.x, pos.z - pp.z)
	if running:
		_feel(0.85)                    # it bolted: your heart lurches after it
		if run_tell > 0.0:
			# noticed you: dead still, with a tremor, before it goes
			run_tell -= delta
			quad.scale = Vector3(1.0 + rng.randf_range(-0.03, 0.03), 1.0, 1.0)
		else:
			run_speed = move_toward(run_speed, RUN_SPEED, RUN_ACCEL * delta)
			var moved := _run(delta, global_position, pp)
			run_stuck = 0.0 if moved else run_stuck + delta
			# it never blinks out where you can see it: it only leaves once it is out of your view (round a
			# corner, off to the side or behind you, or lost in the far dark); boxed in, it keeps trying
			var here := global_position
			var visible_now: bool = nav.clear_line(here.x, here.z, pp.x, pp.z) and view_dot(here.x, here.z) > OFF_SCREEN
			if not visible_now and (not line or dist > 30.0 or run_stuck > 2.0 or view_dot(here.x, here.z) < OFF_SCREEN):
				_gone()
				return
			if dist > 90.0:
				_gone()
				return

	# faint at the best of times, with a nervous flicker
	alpha = move_toward(alpha, MAX_ALPHA, fade_speed * MAX_ALPHA * delta)
	var far := clampf(1.5 - dist / 45.0, 0.75, 1.0)
	var flicker := 0.88 + 0.12 * sin(clock * 9.0) * sin(clock * 3.7)
	_set_visual(alpha * far * flicker)

# Spotted, or closed in on: it bolts away in stop-motion lunges, upright and rigid, steering round
# bends. Each lunge snaps the body a little taller/thinner, the way a puppet would jerk.
func _run(delta: float, pos: Vector3, pp: Vector3) -> bool:
	run_step_t += delta
	if run_step_t < RUN_STEP:
		return true
	var step := run_speed * run_step_t
	run_step_t = 0.0
	var want := atan2(pos.x - pp.x, pos.z - pp.z)
	for off in [0.0, 0.5, -0.5, 1.0, -1.0, 1.5, -1.5, 2.0, -2.0]:
		var a: float = want + off
		var sx := sin(a)
		var sz := cos(a)
		var reach := step + 1.0
		if nav.open_at(pos.x + sx * reach, pos.z + sz * reach) and nav.open_at(pos.x + sx * step * 0.5, pos.z + sz * step * 0.5) 				and nav.open_at(pos.x + sx * reach + sz * 0.4, pos.z + sz * reach - sx * 0.4) 				and nav.open_at(pos.x + sx * reach - sz * 0.4, pos.z + sz * reach + sx * 0.4):
			run_heading = a
			global_position = Vector3(pos.x + sx * step, pos.y, pos.z + sz * step)
			var jerk := rng.randf()
			quad.scale = Vector3(0.9 + 0.08 * jerk, 1.0 + 0.09 * (1.0 - jerk), 1.0)
			return true
	return false

# ---------------------------------------------------------------- debug console
func debug_active() -> bool:
	return present and (peek_mode or not fading_out)

func debug_spawn(kind := "") -> bool:
	enabled = true
	if present:
		peek_mode = false
		_gone()
	return appear(kind)

func debug_despawn() -> void:
	enabled = false
	peek_mode = false
	if present:
		_gone()

# ================================================================= co-op
func _net_send(delta: float) -> void:
	_net_t -= delta
	if _net_t > 0.0:
		return
	_net_t = 0.05
	var p := global_position
	Net.send_wt([p.x, p.y, p.z, present, quad.scale.x, quad.scale.y, peek_mode, vis_alpha])

func net_apply(t: float, m: Array) -> void:
	net_buf.send_interval = 0.05
	net_buf.push(t, {"pos": Vector3(m[0], m[1], m[2]), "yaw": 0.0, "speed": float(m[7]), "m": m})

# Guest: the host's figure, felt against THIS player (their heartbeat, their stare)
func _puppet_step(delta: float) -> void:
	clock += delta
	t_local = true
	t_pos = player.global_position
	t_fwd = -player.global_transform.basis.z
	var st: Dictionary = net_buf.sample(delta)
	if st.is_empty():
		return
	var m: Array = st.m
	present = m[3]
	peek_mode = m[6]
	quad.visible = present
	var looking := false
	if present:
		global_position = st.pos
		quad.scale = Vector3(m[4], m[5], 1.0)
		_set_visual(st.speed)
		if Game.playing and not player.dead:
			var pos := global_position
			var dist := Vector2(pos.x - t_pos.x, pos.z - t_pos.z).length()
			var line: bool = nav.clear_line(pos.x, pos.z, t_pos.x, t_pos.z)
			var facing := view_dot(pos.x, pos.z)
			looking = line and dist < 45.0 and facing > (0.6 if peek_mode else VIEW_CONE)
			if looking:
				_haunt(0.12)
				_feel(0.55)
			elif not peek_mode:
				_feel(0.2)
	_view_t -= delta
	if _view_t <= 0.0:
		_view_t = 0.1
		Net.send_wt_view(looking)
