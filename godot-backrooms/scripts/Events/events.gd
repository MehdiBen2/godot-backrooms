extends Node
## Event director (js/game/events.js + eventDefs.js). Decides WHEN something happens and WHICH
## event fits the moment: tension builds while things are quiet (faster when you stand still,
## walk in the dark or have low sanity), then a weighted pick among events that are off cooldown
## and pass their own when()/score(). Events use later() / watch() / on_clear().
##
## Dev keys: F1 random event, F6 mannequin room + bacteria, F7 power cut, F8 preacher whisper,
## F9 stop all events.

const GridNav := preload("res://scripts/World/grid_nav.gd")

const FIRST_MIN := 40.0
const FIRST_MAX := 90.0
const GAP_MIN := 55.0
const GAP_MAX := 130.0
const RETRY := 6.0
const RECOVERY_BASE := 15.0
const RECOVERY_PER_INTENSITY := 45.0
const POWER_CUT_SECONDS := 60.0

var level: Node
var player: CharacterBody3D
var scares: Node
var nav
var mimic: Node                       # optional: charges at you during a power cut

var events: Array[Dictionary] = []
var queue: Array = []                 # {at, fn}
var watchers: Array = []              # {fn, t}
var restorers: Array = []
var history := {}
var last := ""
var last_at := -INF
var busy_until := 0.0
var recovery := 0.0
var tension := 0.0
var threshold := 0.0
var still := 0.0
var last_pos := Vector3.ZERO
var rng := RandomNumberGenerator.new()

var banner: Label
var banner_layer: CanvasLayer

func _ready() -> void:
	rng.randomize()
	level = get_parent().get_node("Level")
	player = get_parent().get_node("Player")
	scares = get_parent().get_node("Scares")
	nav = GridNav.new(level)
	_define_events()
	_build_banner()
	reset()

# ---------------------------------------------------------------- definitions
func define(def: Dictionary) -> void:
	var d := {"weight": 1.0, "cooldown": 180.0, "duration": 10.0, "intensity": 0.5,
		"when": Callable(), "score": Callable()}
	d.merge(def, true)
	events.append(d)

func _define_events() -> void:
	define({"name": "powerCut", "weight": 3.0, "cooldown": 480.0, "duration": POWER_CUT_SECONDS + 5.0, "intensity": 1.0,
		"when": func(_c): return level.lit.size() > 0,
		# hits hardest when you're relying on the tubes, not your own light
		"score": func(c): return (1.4 if c.dark else 1.0) * (1.3 if c.battery < 25.0 else 1.0),
		"run": _event_power_cut})
	define({"name": "preacherWhisper", "weight": 2.0, "cooldown": 360.0, "duration": 12.0, "intensity": 0.5,
		"when": func(c): return c.since_last > 60.0,
		"score": func(c): return 1.0 + minf(1.0, c.still / 10.0),
		"run": func(): _event_preacher(-1)})
	define({"name": "wallKnock", "weight": 1.6, "cooldown": 240.0, "duration": 9.0, "intensity": 0.45,
		"when": func(c): return c.since_last > 30.0,
		"score": func(c): return (1.4 if c.still > 3.0 else 1.0) * (1.3 if c.dark else 1.0),
		"run": _event_wall_knock})
	define({"name": "breathBehind", "weight": 1.0, "cooldown": 420.0, "duration": 6.0, "intensity": 0.6,
		"when": func(c): return c.still > 2.0 and c.dark and c.sanity < 80.0,
		"run": _event_breath_behind})
	define({"name": "redAlert", "weight": 1.8, "cooldown": 420.0, "duration": 19.0, "intensity": 0.8,
		"when": func(c): return level.lit.size() > 0 and c.since_last > 45.0,
		"score": func(c): return 1.0 + 0.4 * c.tension,
		"run": _event_red_alert})
	define({"name": "emergencyPulse", "weight": 1.4, "cooldown": 360.0, "duration": 22.0, "intensity": 0.7,
		"when": func(c): return level.lit.size() > 0 and c.since_last > 45.0,
		"score": func(c): return (1.3 if c.still > 3.0 else 1.0) * (1.2 if c.sanity < 70.0 else 1.0),
		"run": _event_emergency_pulse})
	define({"name": "lightsOut", "weight": 1.5, "cooldown": 300.0, "duration": 14.0, "intensity": 0.75,
		"when": func(c): return level.lit.size() > 0,
		"score": func(c): return (1.3 if c.dark else 1.0),
		"run": _event_lights_out})
	define({"name": "tubeChase", "weight": 1.5, "cooldown": 330.0, "duration": 16.0, "intensity": 0.7,
		"when": func(c): return level.lit.size() > 6,
		"score": func(c): return (1.3 if c.still > 3.0 else 1.0),
		"run": _event_tube_chase})
	define({"name": "wrongColor", "weight": 1.2, "cooldown": 420.0, "duration": 24.0, "intensity": 0.5,
		"when": func(c): return level.lit.size() > 0 and c.since_last > 30.0,
		"score": func(c): return 1.0 + (0.5 if c.sanity < 70.0 else 0.0),
		"run": _event_wrong_color})
	define({"name": "oneLamp", "weight": 1.4, "cooldown": 400.0, "duration": 22.0, "intensity": 0.85,
		"when": func(c): return level.lit.size() > 6 and c.since_last > 45.0,
		"score": func(c): return (1.3 if c.dark else 1.0) * (1.2 if c.still > 3.0 else 1.0),
		"run": _event_one_lamp})
	define({"name": "phantomSteps", "weight": 1.5, "cooldown": 360.0, "duration": 24.0, "intensity": 0.8,
		"when": func(c): return c.since_last > 40.0,
		"score": func(c): return (1.3 if c.dark else 1.0) * (1.2 if c.sanity < 75.0 else 1.0),
		"run": _event_phantom_steps})
	define({"name": "crawlingCeiling", "weight": 1.3, "cooldown": 420.0, "duration": 16.0, "intensity": 0.8,
		"when": func(c): return c.since_last > 40.0,
		"score": func(c): return (1.4 if c.still > 3.0 else 1.0),
		"run": _event_crawling_ceiling})
	define({"name": "tapeRot", "weight": 1.2, "cooldown": 400.0, "duration": 14.0, "intensity": 0.6,
		"when": func(c): return c.since_last > 30.0,
		"score": func(c): return 1.0 + (0.5 if c.sanity < 60.0 else 0.0),
		"run": _event_tape_rot})
	define({"name": "flatline", "weight": 1.0, "cooldown": 540.0, "duration": 16.0, "intensity": 0.9,
		"when": func(c): return c.since_last > 60.0 and c.sanity < 85.0,
		"score": func(c): return 1.0 + (100.0 - c.sanity) / 100.0,
		"run": _event_flatline})
	define({"name": "deadAir", "weight": 1.3, "cooldown": 420.0, "duration": 13.0, "intensity": 0.85,
		"when": func(c): return c.since_last > 40.0,
		"score": func(c): return (1.4 if c.still > 4.0 else 1.0),
		"run": _event_dead_air})

# ---------------------------------------------------------------- tools for events
func later(seconds: float, fn: Callable) -> void:
	queue.append({"at": Game.time + seconds, "fn": fn})

# Per-frame logic: fn(delta, t) returns false when it's done
func watch(fn: Callable) -> void:
	watchers.append({"fn": fn, "t": 0.0})

func on_clear(fn: Callable) -> void:
	restorers.append(fn)

func haunt(amount: float) -> void:
	Game.haunt(amount)

func sound_spot(dist: float, angle := -1.0, y := 1.2) -> Vector3:
	if angle < 0.0:
		angle = rng.randf() * TAU
	var p := player.global_position
	return Vector3(p.x + sin(angle) * dist, p.y + y, p.z + cos(angle) * dist)

func event_open_at(x: float, z: float) -> bool:
	return nav.open_at(x, z)

# An open corridor point min_d..max_d away, plus a nearer point for sounds that approach
func find_corridor_spot(min_d := 10.0, max_d := 24.0) -> Dictionary:
	var px := player.global_position.x
	var pz := player.global_position.z
	var py := player.global_position.y
	var angles: Array = []
	for i in 16:
		angles.append(i * PI / 8.0)
	angles.shuffle()
	for a in angles:
		var dx := sin(a)
		var dz := cos(a)
		var reach := 0.0
		var d := 1.0
		while d <= max_d:
			if not event_open_at(px + dx * d, pz + dz * d):
				break
			reach = d
			d += 0.8
		if reach < min_d:
			continue
		var dist := min_d + rng.randf() * (reach - min_d)
		var near := minf(dist, 8.5)
		return {"pos": Vector3(px + dx * dist, py + 1.2, pz + dz * dist),
			"approach": Vector3(px + dx * near, py + 1.2, pz + dz * near), "dist": dist}
	var pos := sound_spot(14.0)
	return {"pos": pos, "approach": pos.lerp(player.global_position, 0.5), "dist": 14.0}

# ---------------------------------------------------------------- banner
func _build_banner() -> void:
	banner_layer = CanvasLayer.new()
	banner_layer.layer = 6
	banner_layer.visible = not Game.hide_hud
	add_child(banner_layer)
	banner = Label.new()
	banner.add_theme_font_override("font", load("res://fonts/vcr.ttf"))
	banner.add_theme_font_size_override("font_size", 30)
	banner.add_theme_color_override("font_color", Color("ffc107"))
	banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	banner.position = Vector2(-500, 90)
	banner.size = Vector2(1000, 40)
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.visible = false
	banner_layer.add_child(banner)
	Game.hud_visibility_changed.connect(func(v: bool):
		if banner_layer: banner_layer.visible = v
	)

func show_banner(text: String) -> void:
	banner.text = text
	banner.visible = not Game.hide_hud

func hide_banner() -> void:
	banner.visible = false

# ---------------------------------------------------------------- lifecycle
func reset() -> void:
	clear_events()
	history.clear()
	last = ""
	last_at = -INF
	tension = 0.0
	recovery = 0.0
	threshold = rng.randf_range(FIRST_MIN, FIRST_MAX)

func stop_all() -> void:
	Net.send_stop_events()
	clear_events()
	tension = 0.0
	threshold = rng.randf_range(GAP_MIN, GAP_MAX)
	scares.stop_all()
	level.restore_power()

func clear_events() -> void:
	queue.clear()
	watchers.clear()
	var rs := restorers.duplicate()
	restorers.clear()
	for fn in rs:
		fn.call()
	busy_until = 0.0
	if player:
		player.cam.rotation.z = 0.0
	Game.event_fear = 0.0
	Game.glitch = 0.0
	hide_banner()

# ---------------------------------------------------------------- the director
func context() -> Dictionary:
	return {
		"time": Game.time, "still": still, "moving": still < 0.5,
		"flashlight": player.flash_on, "dark": not player.flash_on,
		"battery": player.battery, "sanity": player.sanity,
		"since_last": Game.time - last_at,
		"tension": tension / threshold if threshold > 0.0 else 0.0,
	}

func tension_rate(c: Dictionary) -> float:
	var rate := 1.0
	if c.still > 8.0: rate += 0.35              # standing around invites trouble
	if c.dark: rate += 0.25
	if c.sanity < 50.0: rate += (50.0 - c.sanity) / 100.0
	return rate

func track_stillness(dt: float) -> void:
	var p := player.global_position
	if Vector2(p.x - last_pos.x, p.z - last_pos.z).length() < 0.02 * maxf(1.0, dt * 60.0):
		still += dt
	else:
		still = 0.0
	last_pos = p

func director_calm() -> bool:
	return not player.dead and Game.terror == 0.0 and Game.time >= busy_until and watchers.is_empty()

func _process(dt: float) -> void:
	if not Game.playing or Game.dead:
		return
	for i in range(queue.size() - 1, -1, -1):
		if Game.time < queue[i].at:
			continue
		var q: Dictionary = queue[i]
		queue.remove_at(i)
		q.fn.call()
	for i in range(watchers.size() - 1, -1, -1):
		var w: Dictionary = watchers[i]
		w.t += dt
		if not w.fn.call(dt, w.t):
			watchers.remove_at(i)
	track_stillness(dt)
	if Net.is_online() and not Net.hosting:
		return                        # co-op: the host decides when something happens; we only play what it sends
	if not director_calm():
		return
	if recovery > 0.0:
		recovery -= dt
		return
	var c := context()
	tension += dt * tension_rate(c)
	if tension < threshold:
		return
	if trigger_random(false, c) == "":
		# nothing fits right now; keep the tension and look again shortly
		tension = threshold - RETRY

func eligible(e: Dictionary, c: Dictionary, force: bool) -> bool:
	if force:
		return true
	if e.name == last and events.size() > 1:
		return false
	if history.has(e.name) and c.time - history[e.name] < e.cooldown:
		return false
	return not e.when.is_valid() or e.when.call(c)

func score_of(e: Dictionary, c: Dictionary) -> float:
	var fresh := 1.0
	if history.has(e.name):
		fresh = 0.5 + minf(1.0, (c.time - history[e.name]) / (e.cooldown * 3.0))
	var fit: float = maxf(0.0, e.score.call(c)) if e.score.is_valid() else 1.0
	return e.weight * fresh * fit

# Picks and runs an event; returns its name, or "" when nothing fits
func trigger_random(force := false, c := {}) -> String:
	if c.is_empty():
		c = context()
	var pool: Array = []
	var total := 0.0
	for e in events:
		if not eligible(e, c, force):
			continue
		var s := score_of(e, c)
		if s > 0.0:
			pool.append([e, s])
			total += s
	if pool.is_empty():
		return ""
	var roll := rng.randf() * total
	var pick: Dictionary = pool[0][0]
	for o in pool:
		roll -= o[1]
		if roll < 0.0:
			pick = o[0]
			break
	run_event(pick.name)
	return pick.name

func run_event(name: String) -> bool:
	for e in events:
		if e.name != name:
			continue
		last = name
		last_at = Game.time
		Net.send_event(name)          # co-op host: everyone gets it
		history[name] = Game.time
		busy_until = Game.time + e.duration
		recovery = RECOVERY_BASE + RECOVERY_PER_INTENSITY * e.intensity
		tension = 0.0
		threshold = rng.randf_range(GAP_MIN, GAP_MAX)
		e.run.call()
		return true
	return false

func _unhandled_input(e: InputEvent) -> void:
	if not Game.dev_keys or not (e is InputEventKey and e.pressed and not e.echo):
		return
	match e.physical_keycode:
		KEY_F1: if e.shift_pressed: print("event: ", trigger_random(true))
		KEY_F6: debug_spawn_hunters()
		KEY_F7: run_event("powerCut")
		KEY_F8: run_event("preacherWhisper")
		KEY_F9: stop_all()

# DEBUG F6: warp into the mannequin room and drop the bacteria a few metres away, already screeching.
# Dev keys: Shift+F1 random event, Shift+F2 mannequin room (plain F1-F3 change level, see level_builder), F4 bacteria stalk, F5 mimic session,
# F6 mannequin + bacteria, F7 power cut, F8 preacher, F9 stop all, F10 bacteria in front.
func debug_spawn_hunters() -> void:
	var root := get_parent()
	var mannequin: Node = root.get_node("Mannequin")
	var entity: Node = root.get_node("Entity")
	mannequin.warp_to_room()
	var pp := player.global_position
	for dist in [9.0, 7.0, 12.0, 5.0]:
		for i in 16:
			var a := i * TAU / 16.0
			var x: float = pp.x + sin(a) * dist
			var z: float = pp.z + cos(a) * dist
			if entity.nav.open_at(x, z) and entity.nav.clear_line(pp.x, pp.z, x, z):
				entity.summon(x, z, pp.x, pp.z)
				print("debug: mannequin room + bacteria at ", Vector2(x, z))
				return
	entity.relocate()
	print("debug: mannequin room; no open spot for the bacteria, relocated it")

# ---------------------------------------------------------------- power cut
# A grid failure: the tubes stutter, then a full minute of dark with something moving in it
func _event_power_cut() -> void:
	on_clear(func():
		level.set_tint(Color.WHITE)
		player.grid_down = false)
	show_banner("GRID FLUCTUATION // MAIN BALLAST")
	later(2.5, hide_banner)

	# pre-flicker warning across ~2 s: the tubes round you stutter and pop, the whole grid browns out
	later(0.2, func(): level.disturb(player.global_position, 28.0, 0.9))
	var dim := Color(0.25, 0.25, 0.18)
	for i in range(1, 7):
		later(i * 0.35, func(): level.set_tint(dim if i % 2 == 0 else Color.WHITE))

	later(2.1, func():
		level.set_tint(Color.WHITE)
		level.cut_power(POWER_CUT_SECONDS)
		# the torch is the only light now: drains slowly, and an empty one gets a 40% charge
		player.grid_down = true
		if mimic and mimic.has_method("grid_down"):
			mimic.grid_down()
		if player.battery <= 0.0:
			player.battery = 40.0
		later(POWER_CUT_SECONDS, func(): player.grid_down = false)
		# the grid dies somewhere far off (sound carries through the walls)
		scares.grid_off(sound_spot(18.0 + rng.randf() * 8.0, rng.randf() * TAU, 2.4))
		Game.add_glitch(0.5)
		haunt(0.7)
		# something walks around in the dark, circling in, then backing off before the lights return
		var steps := [[5, 18], [12, 13], [19, 9], [27, 6], [34, 4], [40, 8], [48, 14]]
		for s in steps:
			later(s[0] + rng.randf() * 2.0, func():
				var d: float = s[1]
				scares.play_scare("footThump", sound_spot(d), 0.5 + 0.5 * (1.0 - d / 18.0))
				haunt(0.4 + 0.4 * (1.0 - d / 18.0)))
		later(POWER_CUT_SECONDS, func(): scares.grid_on()))

# ---------------------------------------------------------------- preacher whisper
# A Mandela Catalogue-style preacher voice from far down a corridor, behind the walls (preacher.gd)
func _event_preacher(forced: int) -> Dictionary:
	var corridor := find_corridor_spot(11.0, 24.0)
	var variant := clampi(forced, 0, 5) if forced >= 0 else rng.randi() % 6
	haunt(0.4)
	Game.add_glitch(0.2)
	scares.preacher(corridor.pos, variant, corridor.approach, 5.5, 1.0)
	if variant == 2 or variant == 4:
		# radio / electrical: a tracking tear and a torch flicker
		later(1.5, func():
			Game.add_glitch(0.5)
			if player.flash_on:
				player.trigger_flicker(1.2))
	elif variant == 1:
		later(2.0, func(): haunt(0.65))
	elif variant == 5:
		# approaching stalker: your heartbeat picks up as it draws near
		later(3.0, func():
			scares.heartbeat(0.4)
			haunt(0.4))
	return {"variant": variant, "name": scares.PREACHER_NAMES[variant], "dist": corridor.dist}

# ---------------------------------------------------------------- knocking in the walls
# Something inside the walls, behind you, in one of a few patterns - always ending nearer than it began:
#   0 three raps, a pause, then three harder ones from a wall nearer to you
#   1 "shave and a haircut" from far off... and the "two bits" answered by two fists right beside you
#   2 slow single knocks walking along the wall towards you, then nails dragged down it
#   3 fingernails tapping, restless and close; a scratch; a silence; one fist
#   4 a fist pounding, fast and uneven, that stops dead
func _event_wall_knock() -> void:
	var first := _wall_face_behind(9.0, 16.0)
	if not first.is_finite():
		first = sound_spot(12.0)
	var second := _wall_face_behind(4.0, 8.0)
	if not second.is_finite():
		second = first.lerp(player.global_position + Vector3(0.0, 1.3, 0.0), 0.5)
	haunt(0.35)
	match rng.randi() % 5:
		0:
			for i in 3:
				later(i * rng.randf_range(0.38, 0.47), func(): scares.knock(first, 0.9))
			later(3.2, func(): haunt(0.55))
			for i in 3:
				later(3.2 + i * rng.randf_range(0.27, 0.33), func(): scares.knock(second, 1.4, scares.KNOCK_FIST))
		1:
			for at in [0.0, 0.34, 0.51, 0.68, 1.02]:
				later(at, func(): scares.knock(first, 0.85))
			later(4.6, func(): haunt(0.65))
			later(4.6, func(): scares.knock(second, 1.5, scares.KNOCK_FIST))
			later(5.0, func(): scares.knock(second, 1.5, scares.KNOCK_FIST))
		2:
			var at := 0.0
			for i in 5:
				var pos := first.lerp(second, i / 4.0)
				later(at, func(): scares.knock(pos, 0.7 + i * 0.18, scares.KNOCK_KNUCKLE if i < 3 else scares.KNOCK_FIST))
				at += rng.randf_range(1.0, 1.4)
			later(at - 0.6, func(): haunt(0.55))
			later(at, func(): scares.wall_scratch(second, 1.1))
		3:
			var at := 0.0
			for i in 9:
				later(at, func(): scares.knock(second, 1.0, scares.KNOCK_NAIL))
				at += rng.randf_range(0.12, 0.38)
			later(at + 0.4, func(): scares.wall_scratch(second))
			later(at + 3.4, func(): haunt(0.6))
			later(at + 3.4, func(): scares.knock(second, 1.4, scares.KNOCK_FIST))
		_:
			var at := 0.0
			later(0.0, func(): haunt(0.6))
			for i in rng.randi_range(6, 9):
				later(at, func(): scares.knock(second, rng.randf_range(1.1, 1.5), scares.KNOCK_FIST))
				at += rng.randf_range(0.16, 0.3)

# A wall face (the side of a wall cell that looks into an open cell) min_d..max_d from you, behind you
# if there is one: where the knocking comes from
func _wall_face_behind(min_d: float, max_d: float) -> Vector3:
	var p := player.global_position
	var fwd := -player.global_transform.basis.z
	var cell := GridNav.CELL
	var cx := GridNav.cell(p.x)
	var cz := GridNav.cell(p.z)
	var r := ceili(max_d / cell) + 1
	var best := Vector3.INF
	var best_score := -INF
	for x in range(cx - r, cx + r + 1):
		for z in range(cz - r, cz + r + 1):
			if not nav.is_wall(x, z):
				continue
			for o in GridNav.NEIGHBOURS:
				if nav.blocked(x + o.x, z + o.y):
					continue
				var face := Vector3(x * cell + o.x * cell * 0.5, p.y + 1.3, z * cell + o.y * cell * 0.5)
				var d := Vector2(face.x - p.x, face.z - p.z).length()
				if d < min_d or d > max_d:
					continue
				var behind := -Vector2(fwd.x, fwd.z).normalized().dot(Vector2(face.x - p.x, face.z - p.z) / d)
				var score := behind + rng.randf() * 0.5
				if score > best_score:
					best_score = score
					best = face
	return best

# ---------------------------------------------------------------- something breathing behind you
# Standing still in the dark: a breath right at the back of your neck. Turn round: nothing there.
# Sometimes it breathes again a moment later - behind you still, wherever you turned, and closer.
func _event_breath_behind() -> void:
	var dur: float = scares.breath_behind(_behind_neck(0.7))
	if rng.randf() < 0.35:
		later(dur + rng.randf_range(0.5, 1.2), func(): scares.breath_behind(_behind_neck(0.45), 1.2))
	later(1.2, func():
		haunt(0.8)
		Game.add_glitch(0.25)
		if Game.heart != null:
			Game.heart.feed("breath", 0.85))

# A spot `dist` behind your head, where something would stand to breathe on your neck
func _behind_neck(dist: float) -> Vector3:
	return player.global_position + Vector3(0.0, 1.55, 0.0) + player.global_transform.basis.z * dist

# ---------------------------------------------------------------- red alert
# The grid throws a containment alarm: every tube slams red and cuts out again in time with a siren thud, an
# emergency banner over it, the picture tearing on each flash. Then it dies and the white light comes back wrong.
const ALERT_RED := Color(1.0, 0.04, 0.03)
const ALERT_OFF := Color(0.03, 0.0, 0.0)

func _banner_red(text: String) -> void:
	banner.add_theme_color_override("font_color", Color("ff2a1a"))
	show_banner(text)
	on_clear(func(): banner.add_theme_color_override("font_color", Color("ffc107")))

func _event_red_alert() -> void:
	on_clear(func(): level.set_tint(Color.WHITE))
	_banner_red("EMERGENCY // CONTAINMENT BREACH")
	later(15.0, hide_banner)
	haunt(0.6)
	later(0.0, func(): level.disturb(player.global_position, 30.0, 1.0))
	# the siren: 0.55 s on, 0.55 s off, ~14 flashes, each one a low thud through the floor and a tear in the picture
	for i in 14:
		var at := 0.8 + i * 1.1
		later(at, func():
			level.set_tint(ALERT_RED)
			scares.spawn_flat(scares.synth("thump"), 0.55, "Scares", 0.5)
			Game.add_glitch(0.12 + 0.03 * i)
			if i % 4 == 3: haunt(0.5))
		later(at + 0.55, func(): level.set_tint(ALERT_OFF))
	# in the last seconds something is moving in the dark between the flashes
	later(9.0, func(): scares.play_scare("footThump", sound_spot(9.0), 0.8))
	later(12.5, func(): scares.play_scare("footThump", sound_spot(5.0), 1.0))
	later(16.5, func():
		level.set_tint(Color.WHITE)
		scares.grid_on()
		Game.add_glitch(0.6)
		haunt(0.7))

# The alarm held low: the tubes breathe red, slowly, in time with a heart that is not yours, and every so often
# one beat drops out and the whole hall goes black for it.
func _event_emergency_pulse() -> void:
	on_clear(func(): level.set_tint(Color.WHITE))
	_banner_red("// ALERT // ALL STAFF TO SHELTER //")
	later(5.0, hide_banner)
	haunt(0.5)
	var beat := [0.0]
	watch(func(dt: float, t: float) -> bool:
		if t > 18.0:
			level.set_tint(Color.WHITE)
			return false
		var k := 0.5 + 0.5 * sin(t * TAU / 1.6)                  # one slow breath of red every 1.6 s
		level.set_tint(ALERT_OFF.lerp(ALERT_RED, k * k))
		if k > 0.97 and Game.time - beat[0] > 1.2:
			beat[0] = Game.time
			scares.heartbeat(0.8)
			if rng.randf() < 0.25: level.disturb(player.global_position, 22.0, 0.7)
		return true)
	later(18.2, func(): scares.grid_on())

# The whole grid blinks: dark, light, dark, a long dark with a footstep in it, then everything strikes at once.
func _event_lights_out() -> void:
	on_clear(func():
		level.restore_power()
		level.set_tint(Color.WHITE))
	haunt(0.6)
	var at := 0.0
	for i in rng.randi_range(5, 8):
		at += rng.randf_range(0.25, 0.9)
		var off_for := rng.randf_range(0.12, 0.5)
		later(at, func():
			level.cut_power(off_for)
			Game.add_glitch(0.15))
		later(at + off_for, func(): level.restore_power())
		at += off_for
	later(at + 0.5, func():
		level.cut_power(4.5)
		scares.grid_off(sound_spot(10.0, rng.randf() * TAU, 2.4))
		Game.add_glitch(0.4))
	later(at + 2.0, func(): scares.play_scare("footThump", sound_spot(4.5), 1.0))
	later(at + 3.4, func(): haunt(0.8))
	later(at + 5.2, func():
		level.restore_power()
		scares.grid_on())

# ---------------------------------------------------------------- tube chase
# The tubes die one after another down the corridor, coming toward you: far end first, a pop each, the dark
# walking up the hall. It stops one tube short of you. Then everything strikes at once.
func _event_tube_chase() -> void:
	on_clear(func(): level.restore_power())
	var p := player.global_position
	var spot := find_corridor_spot(14.0, 26.0)
	var dir := Vector3(spot.pos.x - p.x, 0.0, spot.pos.z - p.z).normalized()
	var line: Array = []
	for f: Dictionary in level.fixtures_near(p, 30.0):
		var d := Vector3(f.pos.x - p.x, 0.0, f.pos.z - p.z)
		var along := d.dot(dir)
		if along > 4.5 and (d - dir * along).length() < 3.5:
			line.append([along, f])
	if line.size() < 3:                       # no straight hall: a ring closing in instead
		line.clear()
		for f: Dictionary in level.fixtures_near(p, 26.0):
			var d := Vector2(f.pos.x - p.x, f.pos.z - p.z).length()
			if d > 4.5: line.append([d, f])
	line.sort_custom(func(x, y): return x[0] > y[0])
	haunt(0.5)
	var step := clampf(7.0 / maxf(line.size(), 1.0), 0.12, 0.4)
	for i in line.size():
		var f: Dictionary = line[i][1]
		later(1.0 + i * step, func():
			if f.black <= 0.0:
				level.cut_fixture(f, 30.0)
				level.fixture_event.emit(f, false))
	var end := 1.0 + line.size() * step
	later(end, func(): scares.spawn3d(scares.synth("thump"), p + dir * 6.0 + Vector3.UP, 0.7, "Scares", 4.0, 0.6))
	later(end + 0.4, func(): haunt(0.7))
	later(end + 3.0, func():
		level.restore_power()
		scares.grid_on()
		Game.add_glitch(0.3))

# ---------------------------------------------------------------- wrong colour
# The light goes slowly sick: green, then violet, a single white flash, and back. Nothing else happens.
func _event_wrong_color() -> void:
	on_clear(func(): level.set_tint(Color.WHITE))
	haunt(0.3)
	var sick := Color(0.55, 1.0, 0.4)
	var violet := Color(0.75, 0.35, 1.0)
	later(1.0, func(): scares.spawn_flat(scares.synth("drone", 14.0), 0.35))
	watch(func(dt: float, t: float) -> bool:
		if t > 20.0:
			level.set_tint(Color.WHITE)
			return false
		var c := Color.WHITE
		if t < 6.0: c = Color.WHITE.lerp(sick, smoothstep(0.0, 6.0, t))
		elif t < 12.0: c = sick.lerp(violet, smoothstep(6.0, 12.0, t))
		elif t < 15.0: c = violet.lerp(Color(0.4, 0.15, 0.6), smoothstep(12.0, 15.0, t))
		elif t < 15.2: c = Color(1.0, 1.0, 1.0)                 # the flash
		elif t < 15.6: c = Color(0.1, 0.0, 0.12)
		else: c = Color(0.1, 0.0, 0.12).lerp(Color.WHITE, smoothstep(15.6, 20.0, t))
		level.set_tint(c)
		return true)

# ---------------------------------------------------------------- one lamp
# Everything goes dark but the single tube over you, and it flickers. Something stands under the next tube along,
# close enough to hear breathe. Then your lamp dies too.
func _event_one_lamp() -> void:
	on_clear(func():
		level.restore_power()
		level.set_tint(Color.WHITE))
	var p := player.global_position
	var near := level.fixtures_near(p, 16.0)
	near.sort_custom(func(x, y): return Vector2(x.pos.x - p.x, x.pos.z - p.z).length() < Vector2(y.pos.x - p.x, y.pos.z - p.z).length())
	if near.size() < 2:
		return
	var mine: Dictionary = near[0]
	var other: Dictionary = near[1]
	for f: Dictionary in near:                  # the next tube along: not under you, and not right on top of yours
		if Vector2(f.pos.x - mine.pos.x, f.pos.z - mine.pos.z).length() >= 4.0:
			other = f
			break
	var other_at: Vector3 = other.pos - Vector3.UP * 1.0
	haunt(0.7)
	later(0.5, func():
		for f in level.lit:
			if f != mine: level.cut_fixture(f, 40.0)
		level.flicker_fixtures(mine.pos, 1.0, 16.0)
		scares.grid_off(sound_spot(14.0, rng.randf() * TAU, 2.4))
		Game.add_glitch(0.3))
	later(4.0, func(): scares.spawn3d(scares.synth("breath_close", 0.0), other_at, 0.9, "Scares", 2.5, 0.6))
	later(8.0, func(): scares.spawn3d(scares.synth("creak"), other_at, 0.7, "Scares", 2.5, 0.65))
	later(11.0, func():
		scares.heartbeat(0.9)
		haunt(0.8))
	later(13.5, func(): scares.spawn3d(scares.synth("breath_close", 0.0), other_at, 1.0, "Scares", 2.0, 0.55))
	later(16.5, func():
		level.cut_fixture(mine, 6.0)
		level.fixture_event.emit(mine, false)
		scares.spawn3d(scares.synth("thump"), other_at, 0.9, "Scares", 3.0, 0.55)
		Game.add_glitch(0.5))
	later(20.0, func():
		level.restore_power()
		scares.grid_on())

# ---------------------------------------------------------------- phantom steps
# Something walks where you walked: a second set of footsteps a beat behind yours, step for step. Stop, and it
# stops. Stay stopped, and one last step lands right behind you.
func _event_phantom_steps() -> void:
	var trail: Array = []                       # [time, position] of where you have been
	var st := {"walked": 0.0, "since": 0.0, "steps": 0, "still": 0.0, "last": player.global_position}
	haunt(0.4)
	watch(func(dt: float, t: float) -> bool:
		var p := player.global_position
		trail.append([Game.time, p])
		while trail.size() > 2 and Game.time - trail[1][0] > 1.6:
			trail.pop_front()
		var moved := Vector2(p.x - st.last.x, p.z - st.last.z).length()
		st.last = p
		if moved > 0.01:
			st.still = 0.0
			st.walked += moved
			if st.walked >= 0.85 and t > 3.0:
				st.walked = 0.0
				st.steps += 1
				var at: Vector3 = trail[0][1]                       # where you were 1.5 s ago
				scares.play_scare("footThump", Vector3(at.x, p.y + 0.1, at.z), 0.45 + 0.02 * minf(st.steps, 12))
				if st.steps == 6: haunt(0.5)
		else:
			st.still += dt
			if st.steps >= 6 and st.still > 1.8:
				scares.play_scare("footThump", _behind_neck(1.1) - Vector3.UP * 1.4, 1.0)
				scares.heartbeat(1.0)
				haunt(0.9)
				Game.add_glitch(0.3)
				return false
		return t < 22.0)

# ---------------------------------------------------------------- crawling in the ceiling
# Scratching and a heavy, wrong gait in the ceiling above, crossing the room toward you. It stops right over your
# head. A long silence. Then something comes down behind you.
func _event_crawling_ceiling() -> void:
	var p := player.global_position
	var start: Vector3 = find_corridor_spot(12.0, 22.0).pos
	var at := 0.5
	haunt(0.4)
	for i in 12:
		var k := i / 11.0
		var pos := start.lerp(p + Vector3(0.6, 0.0, 0.0), k * k * 0.5 + k * 0.5)
		pos.y = p.y + 3.3
		var gap := rng.randf_range(0.55, 0.9) * lerpf(1.0, 0.6, k)
		later(at, func():
			if i % 3 == 2: scares.wall_scratch(pos, 0.6 + 0.4 * k)
			else: scares.play_scare("footThump", pos, 0.35 + 0.5 * k))
		at += gap
	later(at, func(): haunt(0.8))
	later(at + 0.2, func(): scares.heartbeat(0.9))
	# it holds over you; a long, listening silence, and one slow scrape
	later(at + 3.2, func(): scares.wall_scratch(p + Vector3(0.0, 3.2, 0.0), 1.2))
	later(at + 5.5, func():
		scares.play_scare("footThump", _behind_neck(2.2) - Vector3.UP * 1.3, 1.0)
		scares.spawn3d(scares.synth("bone_crack"), _behind_neck(2.0), 0.8, "Scares", 3.0, 0.7)
		Game.add_glitch(0.5)
		haunt(1.0))

# ---------------------------------------------------------------- tape rot
# The recording itself is failing: blocks tear out of the picture, the colours slide, static crawls up from the
# edges. Nothing is in the room. It heals, mostly.
func _event_tape_rot() -> void:
	on_clear(func(): Game.fx_reset())
	haunt(0.5)
	var next_hit := [0.0]
	watch(func(dt: float, t: float) -> bool:
		if t > 11.0:
			Game.fx_reset()
			return false
		var k := sin(clampf(t / 11.0, 0.0, 1.0) * PI)               # builds, peaks mid-way, heals
		Game.fx_static = maxf(Game.fx_static, 0.1 + 0.4 * k)
		Game.fx_warp = maxf(Game.fx_warp, 0.002 + 0.012 * k)
		Game.fx_hue = sin(t * 0.9) * 0.18 * k
		if rng.randf() < dt * (0.6 + 2.5 * k):
			Game.fx_corrupt = maxf(Game.fx_corrupt, 0.2 + 0.5 * k)
		if Game.time > next_hit[0] and k > 0.4:
			next_hit[0] = Game.time + rng.randf_range(0.8, 2.2)
			scares.play_scare("staticHit", 0.4 + 0.6 * k)
			Game.add_glitch(0.2)
		return true)

# ---------------------------------------------------------------- flatline
# Your own heart speeds up, faster and faster, and stops. The colour drains out of the picture and the one clean
# tone of a flatline holds in the silence. Then one beat. Then you're still here.
func _event_flatline() -> void:
	on_clear(func():
		Game.fx_reset()
		scares.stop_flatline())
	var at := 0.5
	var gap := 0.95
	for i in 12:
		later(at, func():
			scares.heartbeat(0.6 + 0.05 * i)
			Game.fear = maxf(Game.fear, 0.4 + 0.04 * i)
			Game.fx_sat = 1.0 - 0.025 * i)
		at += gap
		gap = maxf(0.36, gap * 0.88)
	later(at + 0.3, func():
		var amb: Node = get_parent().get_node_or_null("Audio/Ambience")
		if amb != null: amb.hush_for(0.0, 6.0)
		Game.fx_sat = 0.15
		Game.fx_contrast = 1.25
		scares.flatline(0.45, 0.2)
		haunt(1.0))
	later(at + 5.2, func():
		scares.stop_flatline()
		Game.fx_sat = 1.0
		Game.fx_contrast = 1.0
		scares.heartbeat(1.0)
		Game.add_glitch(0.4))

# ---------------------------------------------------------------- dead air
# Every sound drops out at once, even your own steps: you are deafened. Just ringing, swelling, and a pressure in
# the picture (it softens, drains and breathes in and out). A single fist on the wall right behind you. Nothing.
# Another, nearer, and the ringing spikes. Then the sound comes back, too loud.
func _event_dead_air() -> void:
	var au: Node = get_parent().get_node_or_null("Audio")
	on_clear(func():
		Game.fx_reset()
		if au != null: au.set_muffled(false))
	var amb: Node = get_parent().get_node_or_null("Audio/Ambience")
	haunt(0.6)
	if au != null: au.set_muffled(true)
	if amb != null: amb.hush_for(0.0, 10.0)
	scares.spawn_flat(scares.synth("tinnitus", 6.0), 0.18)
	later(5.0, func(): scares.spawn_flat(scares.synth("tinnitus", 6.0), 0.25, "Scares", 1.12))      # the ringing climbs
	watch(func(dt: float, t: float) -> bool:
		if t > 10.8:
			Game.fx_reset()
			return false
		var k := smoothstep(0.0, 2.0, t) * (1.0 - smoothstep(9.0, 10.8, t))
		Game.fx_blur = 0.25 * k
		Game.fx_sat = 1.0 - 0.45 * k
		Game.fx_zoom = 1.0 + 0.025 * k * sin(t * 1.3)                     # the room breathing in and out
		Game.fx_warp = maxf(Game.fx_warp, 0.003 * k)
		Game.fx_skew = 0.01 * k * sin(t * 0.7 + 1.0)
		return true)
	later(6.0, func():
		scares.knock(_behind_neck(1.2) - Vector3.UP * 0.3, 1.7, scares.KNOCK_FIST)
		Game.fx_shock = 0.6)
	later(8.6, func():
		scares.knock(_behind_neck(0.6) - Vector3.UP * 0.3, 2.0, scares.KNOCK_FIST)
		scares.spawn_flat(scares.synth("tinnitus", 3.0), 0.45, "Scares", 1.3)
		Game.fx_shock = 1.0
		Game.fx_flash = 0.5
		haunt(1.0)
		Game.add_glitch(0.4))
	later(10.5, func():
		if au != null: au.set_muffled(false)
		scares.heartbeat(1.0))
