extends Node3D
## THE EYES. When sanity is very low, ONE small pair of eyes opens in the dark far down a corridor you
## can see along, and watches. It never blinks and never comes closer. Its pupils follow you (it looks
## away if you look back). It cannot be made to leave, only blinked away: the player blinks (player/blink.gd,
## the lids drawn in the post shader) and when they open it is gone. That happens by itself
## when sanity climbs back over FAR_BELOW, when the torch comes on or a lit room is entered, when you
## stare at it, put the torch on it, or get within APPROACH_DIST of it. Then the player breathes out.
##
## Debug console:  eyes [count|off|auto|clear]    sanity <0-100|off>    health <0-100>

const EntityMarks := preload("res://scripts/Entities/entity_marks.gd")
const TEXTURE := "res://textures/entities/eye.png"
const ASPECT := 920.0 / 598.0
const HALO := 1.5                  # quad size / eye size (matches eye.gdshader halo_size)
const FAR_BELOW := 30.0            # they only come when sanity is under this
const MAX_WATCHERS := 1            # one pair at a time
const SIGHT_MIN := 26.0            # how far down the corridor it opens
const SIGHT_MAX := 44.0
const SIGHT_CAST := 48.0
const SPACING := 9.0               # never two pairs closer than this
const FADE_IN := 4.0
const FADE_OUT := 1.4
const APPROACH_DIST := 20.0       # walk this close and you blink and it is gone
const STARE_TIME := 3.5            # looked at head-on this long and it goes
const TORCH_COS := 0.985           # ~10 degrees: the torch's hotspot
const TORCH_RANGE := 45.0
const TORCH_KILL := 0.8            # seconds of torchlight on it before it dies
const LIFE_MIN := 22.0
const LIFE_MAX := 50.0
const LIT_ROOM := 0.45             # ambient light at which they will not come (player.gd's safe level)
const SIGH_GAP := 8.0

var level: Node
var player: CharacterBody3D
var cam: Camera3D
var mat: ShaderMaterial
var quad: QuadMesh
var rng := RandomNumberGenerator.new()
var watchers: Array = []           # one Dictionary per pair (see _add)
var debug_count := -1              # >= 0 overrides the sanity-driven count (console)
var spawn_timer := 4.0
var seen_now := 0
var was_safe := false
var prev_torch := true
var calm_until := 0.0              # Game.time before which nothing opens (just after a banish)
var last_sigh := -100.0
var blinking_away := false
var fails := {}                    # why spawn attempts were rejected (console: `eyes`)
var spawns := 0
var _mark_pending := false         # the level has an Eyes mark it has yet to open at

func _ready() -> void:
	rng.randomize()
	level = get_parent().get_node("Level")
	player = get_parent().get_node("Player")
	cam = player.get_node("Camera3D")
	_mark_pending = not EntityMarks.of_kind(level, "eyes").is_empty()
	quad = QuadMesh.new()
	quad.size = Vector2.ONE
	mat = ShaderMaterial.new()
	mat.shader = load("res://shaders/eye.gdshader")
	mat.set_shader_parameter("eye_tex", _load_tex())
	mat.set_shader_parameter("halo_size", HALO)
	mat.set_shader_parameter("brightness", 2.0)
	mat.set_shader_parameter("glint_amt", 1.6)

# Straight from the file if the editor has not imported it yet
func _load_tex() -> Texture2D:
	if ResourceLoader.exists(TEXTURE):
		return load(TEXTURE)
	var img := Image.load_from_file(ProjectSettings.globalize_path(TEXTURE))
	if img == null or img.is_empty():
		push_warning("eyes: cannot load " + TEXTURE)
		return null
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

# How mad the mind is, 0..1 (the same curve the post shader uses)
func madness() -> float:
	return clampf((player.INSANE_BELOW - player.sanity) / player.INSANE_BELOW, 0.0, 1.0)

func torch_on() -> bool:
	return player.flash_on and player.battery > 0.0

# Light of any kind: your own torch, or a properly lit room. The eyes cannot bear it.
func is_safe() -> bool:
	return debug_count < 0 and player.sanity_lock < 0.0 and (torch_on() or player.light_level >= LIT_ROOM)

func target_count() -> int:
	if debug_count >= 0:
		return mini(debug_count, MAX_WATCHERS)
	if is_safe():
		return 0
	return MAX_WATCHERS if player.sanity <= FAR_BELOW else 0     # a pair as soon as sanity reaches 30

func alive_count() -> int:
	var n := 0
	for w in watchers:
		if not w.dying and not w.get("fixed", false):   # a pair on a level editor mark is not sanity's to count
			n += 1
	return n

func _process(dt: float) -> void:
	var _pt := Time.get_ticks_usec()
	_process_timed(dt)
	Perf.add("Eyes", _pt)

func _process_timed(dt: float) -> void:
	if player == null:
		return
	var running: bool = Game.playing and not Game.dead
	if blinking_away and not player.blink.blinking():
		blinking_away = false
	var k := madness() if debug_count < 0 else maxf(madness(), 0.7)
	if running:
		if _mark_pending:
			_mark_pending = false
			_open_at_mark()
		_light_check()
		_spawn_logic(dt)
	elif Game.dead:
		for w in watchers:
			w.dying = true
	_update(dt, k)

# ---------------------------------------------------------------- the blink that takes it away
func _light_check() -> void:
	var torch := torch_on()
	if torch and not prev_torch:
		blink_away(6.0)                # lighting the torch is always answered (even for a forced test)
	prev_torch = torch
	var safe := is_safe()
	if safe and not was_safe:
		blink_away(3.0)
	was_safe = safe

# You blink (player/blink.gd), and by the time the lids open it is gone. Then you breathe out.
func blink_away(calm := 3.0) -> void:
	if blinking_away or alive_count() == 0 or player.blink.blinking():
		return
	blinking_away = true
	player.blink.blink()
	player.blink.closed.connect(_clear_now.bind(calm), CONNECT_ONE_SHOT)

func _clear_now(calm: float) -> void:
	blinking_away = false
	if watchers.is_empty():
		return
	for w in watchers:
		if w.get("fixed", false):
			continue                       # a pair on a mark stays where the level put it
		w.dying = true
		w.fade_out = 0.02              # gone the instant the lids meet
	calm_until = Game.time + calm
	if Game.time - last_sigh > SIGH_GAP:
		last_sigh = Game.time
		var au := get_parent().get_node_or_null("Audio")
		if au != null and au.get("breathing") != null:
			au.breathing.sigh(0.65, 0.35)

# ---------------------------------------------------------------- spawning
func _spawn_logic(dt: float) -> void:
	var want := target_count()
	var have := alive_count()
	spawn_timer -= dt
	if have < want and spawn_timer <= 0.0 and Game.time >= calm_until:
		spawn_timer = 0.3 if debug_count >= 0 else rng.randf_range(3.0, 7.0)
		if not _spawn():
			spawn_timer = 1.0              # no long sight line here: look again soon
	# too many: sanity came back over FAR_BELOW (you blink and it is gone), or the console lowered it
	if have > want and debug_count < 0:
		blink_away(3.0)
	elif have > want:
		var far = null
		var far_d := -1.0
		for w in watchers:
			if w.dying or w.get("fixed", false):
				continue
			var d: float = w.pos.distance_squared_to(cam.global_position)
			if d > far_d:
				far_d = d
				far = w
		if far != null:
			far.dying = true

func _ray(from: Vector3, to: Vector3) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [player.get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(q)

# Somewhere far down a corridor you can see along, mostly ahead of you so you actually catch it
func _fail(why: String) -> void:
	fails[why] = int(fails.get(why, 0)) + 1

func _spawn() -> bool:
	var origin := cam.global_position
	var yaw0 := cam.global_rotation.y
	for attempt in 30:
		var yaw := yaw0 + (rng.randf_range(-1.05, 1.05) if rng.randf() < 0.8 else rng.randf() * TAU)
		var dir := Vector3(-sin(yaw), 0.0, -cos(yaw))
		var hit := _ray(origin, origin + dir * SIGHT_CAST)
		var free := SIGHT_CAST if hit.is_empty() else origin.distance_to(hit.position)
		if free < SIGHT_MIN + 3.0:
			_fail("short")
			continue
		var dist := rng.randf_range(SIGHT_MIN, minf(free - 2.0, SIGHT_MAX))
		var cell := Vector2i(roundi((origin + dir * dist).x / level.CELL), roundi((origin + dir * dist).z / level.CELL))
		var ceil_h: float = level.ceiling_height(cell)
		var y: float = player.global_position.y + minf(rng.randf_range(1.7, 2.4), ceil_h - 0.6)
		var p := Vector3(origin.x + dir.x * dist, y, origin.z + dir.z * dist)
		if (p - origin).normalized().dot(-cam.global_transform.basis.z) > 0.97:
			_fail("centre")
			continue                       # never opens dead centre of the view
		var apart := true
		for w in watchers:
			if not w.dying and w.pos.distance_to(p) < SPACING:
				apart = false
		if not apart:
			_fail("crowded")
			continue
		# clear line to it, and clear space around it (no eye stuck in a wall)
		if not _ray(origin, p).is_empty():
			_fail("blocked")
			continue
		_add(p)
		spawns += 1
		return true
	return false

# ---------------------------------------------------------------- T.S.R.A. scanner
# Hold Q on it with the field scanner (scripts/Player/scanner.gd) to log it in the Threshold Dossier.
func _enter_tree() -> void:
	add_to_group(Archive.SCANNABLE)
	set_meta("asra_id", "eyes")

## Where the scanner can take a reading off it right now; empty while it is away
func scan_points() -> Array:
	var out := []
	for w in watchers:
		if not w.dying and w.lid > 0.3:
			out.append(w.pos)
	return out

## C-4 deep scan (scan_readout.gd): harmless in itself; the reading is really about your sanity
func scan_behavior(_at: Vector3) -> Dictionary:
	return {"state": "WATCHING", "detail": "HARMLESS // YOUR SANITY %d%% - LIGHT UP OR STARE IT DOWN" % int(player.sanity), "danger": 0}

## An Eyes mark in the level editor: a pair opens there from the start of the level and stays, watching. Unlike
## the ones sanity brings, it is not blinked away by light, by staring it down or by walking up to it.
func _open_at_mark() -> void:
	var marks := EntityMarks.of_kind(level, "eyes")
	if marks.is_empty():
		return
	var at := EntityMarks.world_pos(marks[0])
	var ceil_h: float = level.ceiling_height(EntityMarks.cell(marks[0]))
	_add(Vector3(at.x, player.global_position.y + minf(2.0, ceil_h - 0.6), at.z))
	var w: Dictionary = watchers[watchers.size() - 1]
	w.fixed = true
	w.life = INF
	w.delay = 0.5
	spawns += 1

func _add(p: Vector3) -> void:
	# sized by distance so it always covers the same small angle on screen (about 1 degree per eye):
	# a fixed 30 cm eye 35 m away would be seven pixels and simply not seen
	var size: float = p.distance_to(cam.global_position) * rng.randf_range(0.0145, 0.019)
	var nodes: Array = []
	for i in 2:
		var node := MeshInstance3D.new()
		node.mesh = quad
		node.material_override = mat
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(node)
		node.set_instance_shader_parameter("seed", rng.randf())
		node.set_instance_shader_parameter("alpha", 0.0)
		node.set_instance_shader_parameter("lid", 0.0)
		nodes.append(node)
	watchers.append({
		"nodes": nodes, "pos": p, "size": size,
		"tilt": [rng.randf_range(-0.12, 0.12), rng.randf_range(-0.12, 0.12)],
		"lid": 0.0, "alpha_max": rng.randf_range(0.85, 1.0), "life": rng.randf_range(LIFE_MIN, LIFE_MAX),
		"dying": false, "stare": 0.0, "torch": 0.0, "squint": 0.0,
		"look": Vector2.ZERO, "jit": Vector2.ZERO, "jit_t": rng.randf() * 2.0,
		"delay": rng.randf_range(0.5, 2.0), "fade_out": FADE_OUT,
		"shy": rng.randf() < 0.5, "shy_dir": 1.0 if rng.randf() < 0.5 else -1.0,
	})
	Game.add_glitch(0.05)

# ---------------------------------------------------------------- per-pair life
func _update(dt: float, k: float) -> void:
	var cpos := cam.global_position
	var fwd := -cam.global_transform.basis.z
	var torch: bool = torch_on() and not player.dead
	seen_now = 0
	var vanish := 0.0
	for i in range(watchers.size() - 1, -1, -1):
		var w: Dictionary = watchers[i]
		var to: Vector3 = w.pos - cpos
		var dist := to.length()
		var dir := to / maxf(dist, 0.001)
		var facing := dir.dot(fwd)
		var fixed: bool = w.get("fixed", false)
		if fixed:
			w.size = clampf(dist * 0.0165, 0.12, 0.8)    # keeps the same small angle on screen as you walk
		if not w.dying and not fixed:
			w.life -= dt
			if w.life <= 0.0 or dist > SIGHT_CAST + 6.0:
				w.dying = true
			elif dist < APPROACH_DIST:
				vanish = 4.0               # too close: you blink, and it is not there
		# open / close
		if w.dying:
			w.lid -= dt / w.fade_out
			if w.lid <= 0.0:
				for n: Node in w.nodes:
					n.queue_free()
				watchers.remove_at(i)
				continue
		else:
			w.delay -= dt
			if w.delay <= 0.0:
				w.lid = minf(1.0, w.lid + dt / FADE_IN)
		# the torch on it, or being stared at head-on
		var lit: bool = torch and facing > TORCH_COS and dist < TORCH_RANGE and w.lid > 0.3 and not w.dying
		w.squint = move_toward(w.squint, 1.0 if lit else 0.0, dt * (4.0 if lit else 1.2))
		if lit:
			w.torch += dt
			if w.torch > TORCH_KILL and not fixed:
				vanish = 6.0               # the torch on it: you flinch, blink, and it is gone
		else:
			w.torch = maxf(0.0, w.torch - dt * 0.5)
		var watched: bool = facing > 0.93 and w.lid > 0.6 and not w.dying
		if watched:
			w.stare += dt
			if w.stare > STARE_TIME and not fixed:
				vanish = 5.0               # stared too long: you blink, and it is gone
		else:
			w.stare = maxf(0.0, w.stare - dt * 0.4)
		if w.lid > 0.6 and not w.dying and facing > 0.3:
			seen_now += 1
		# face the player (turning on the spot only), the pair a little apart, gently swaying
		var flat := Vector3(cpos.x - w.pos.x, 0.0, cpos.z - w.pos.z).normalized()
		var bx := Vector3.UP.cross(flat).normalized()
		var sway := Vector3(0.0, sin(Game.time * 0.5 + w.size * 9.0) * 0.06, 0.0)
		w.jit_t -= dt
		if w.jit_t <= 0.0:
			w.jit_t = rng.randf_range(0.6, 3.0)
			w.jit = Vector2(rng.randf_range(-0.6, 0.6), rng.randf_range(-0.4, 0.4))
		var to_me := -dir
		var want := Vector2(to_me.dot(bx), to_me.dot(Vector3.UP)).limit_length(1.0)
		var speed := 3.0
		if watched and w.shy:
			want = Vector2(w.shy_dir * 0.95, -0.3)      # looks away when you look at it
			speed = 8.0
		else:
			want = (want * 0.7 + w.jit * 0.45).limit_length(1.0)
		w.look = w.look.lerp(want, minf(1.0, dt * speed))
		var ease_lid: float = w.lid * w.lid * (3.0 - 2.0 * w.lid)
		var a: float = minf(1.0, w.lid * 2.5) * w.alpha_max * (0.75 + 0.25 * k)
		var spacing: float = w.size * 1.7
		for j in 2:
			var node: MeshInstance3D = w.nodes[j]
			var side := -0.5 if j == 0 else 0.5
			var basis := Basis(bx, Vector3.UP, flat).rotated(flat, w.tilt[j])
			basis = basis.scaled_local(Vector3(w.size * HALO, w.size / ASPECT * HALO, 1.0))
			node.global_transform = Transform3D(basis, w.pos + sway + bx * side * spacing)
			node.set_instance_shader_parameter("alpha", a)
			node.set_instance_shader_parameter("lid", ease_lid)
			node.set_instance_shader_parameter("look", w.look)
			node.set_instance_shader_parameter("squint", w.squint)
			node.set_instance_shader_parameter("madness", k)
	if vanish > 0.0:
		blink_away(vanish)
	# being watched raises the heart
	if seen_now > 0 and Game.heart != null and not Game.dead:
		Game.heart.feed("eyes", minf(0.5, 0.2 + seen_now * 0.1))

# ---------------------------------------------------------------- debug console
func debug_set(n: int) -> void:
	debug_count = n

func debug_auto() -> void:
	debug_count = -1

func debug_clear() -> void:
	for w in watchers:
		w.dying = true

func describe() -> String:
	return "eyes: %d pairs alive (%d total, %d spawned), target %d, %s, %s, %d in view, sanity %d, rejected %s" % [
		alive_count(), watchers.size(), spawns, target_count(),
		"forced" if debug_count >= 0 else "from sanity (under %d)" % int(FAR_BELOW),
		"LIT: they will not come" if is_safe() else "dark",
		seen_now, int(player.sanity), str(fails)]
