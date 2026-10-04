extends Node
## Event director (js/game/events.js + eventDefs.js). Decides WHEN something happens and WHICH
## event fits the moment: tension builds while things are quiet (faster when you stand still,
## walk in the dark or have low sanity), then a weighted pick among events that are off cooldown
## and pass their own when()/score(). Events use later() / watch() / on_clear().
##
## Dev keys: F1 random event, F6 mannequin room + bacteria, F7 power cut, F8 preacher whisper,
## F9 stop all events.

const GridNav := preload("res://scripts/World/grid_nav.gd")
const MachineVoice := preload("res://scripts/Audio/machine_voice_lines.gd")

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
var clock := 0.0                      # the events' own time: in co-op it keeps running while you sit in the pause
                                      # menu, so a scare ends here when it ends for everyone (Game.time stops)
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
	define({"name": "redAlert", "weight": 1.8, "cooldown": 420.0, "duration": 28.0, "intensity": 0.8,
		"when": func(c): return level.lit.size() > 0 and c.since_last > 45.0,
		"score": func(c): return 1.0 + 0.4 * c.tension,
		"run": _event_red_alert})
	define({"name": "emergencyPulse", "weight": 1.4, "cooldown": 360.0, "duration": 29.0, "intensity": 0.7,
		"when": func(c): return level.lit.size() > 0 and c.since_last > 45.0,
		"score": func(c): return (1.3 if c.still > 3.0 else 1.0) * (1.2 if c.sanity < 70.0 else 1.0),
		"run": _event_emergency_pulse})
	define({"name": "lightsOut", "weight": 1.5, "cooldown": 300.0, "duration": 22.0, "intensity": 0.75,
		"when": func(c): return level.lit.size() > 0,
		"score": func(c): return (1.3 if c.dark else 1.0),
		"run": _event_lights_out})
	define({"name": "oneLamp", "weight": 1.4, "cooldown": 400.0, "duration": 22.0, "intensity": 0.85,
		"when": func(c): return level.lit.size() > 6 and c.since_last > 45.0,
		"score": func(c): return (1.3 if c.dark else 1.0) * (1.2 if c.still > 3.0 else 1.0),
		"run": _event_one_lamp})
	define({"name": "deadAir", "weight": 1.3, "cooldown": 420.0, "duration": 13.0, "intensity": 0.85,
		"when": func(c): return c.since_last > 40.0,
		"score": func(c): return (1.4 if c.still > 4.0 else 1.0),
		"run": _event_dead_air})
	define({"name": "machineVoice", "weight": 1.4, "cooldown": 240.0, "duration": 12.0, "intensity": 0.5,
		"when": func(c): return c.since_last > 30.0,
		"run": _event_machine_voice})
	define({"name": "ghostRoster", "weight": 0.9, "cooldown": 600.0, "duration": 8.0, "intensity": 0.4,
		"when": func(c): return c.since_last > 40.0,
		"run": _event_ghost_roster})
	define({"name": "humRises", "weight": 1.1, "cooldown": 420.0, "duration": 24.0, "intensity": 0.6,
		"when": func(c): return level.lit.size() > 0 and c.since_last > 40.0,
		"run": _event_hum_rises})
	define({"name": "partyWall", "weight": 1.0, "cooldown": 600.0, "duration": 62.0, "intensity": 0.5,
		"when": func(c): return c.since_last > 45.0,
		"run": _event_party_wall})
	define({"name": "phoneRing", "weight": 1.1, "cooldown": 540.0, "duration": 40.0, "intensity": 0.5,
		"when": func(c): return c.since_last > 40.0,
		"run": _event_phone_ring})
	define({"name": "houndPacing", "weight": 1.1, "cooldown": 480.0, "duration": 60.0, "intensity": 0.6,
		"when": func(c): return c.since_last > 40.0,
		"run": _event_hound_pacing})
	define({"name": "run", "weight": 0.8, "cooldown": 720.0, "duration": 28.0, "intensity": 1.0,
		"when": func(c): return level.lit.size() > 10 and c.since_last > 60.0,
		"run": _event_run})

# ---------------------------------------------------------------- tools for events
func later(seconds: float, fn: Callable) -> void:
	queue.append({"at": clock + seconds, "fn": fn})

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
	scares.stop_flatline()
	level.restore_power()
	level.set("tint_wb", true)
	level.set_tint(Color.WHITE)
	Game.fx_reset()

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
	# solo: a pause holds the scare where it is. Co-op: the others are still in it, so it runs on (dead too:
	# whatever it switched off still has to come back)
	if not Net.is_online() and (not Game.playing or Game.dead):
		return
	clock += dt
	for i in range(queue.size() - 1, -1, -1):
		if clock < queue[i].at:
			continue
		var q: Dictionary = queue[i]
		queue.remove_at(i)
		q.fn.call()
	for i in range(watchers.size() - 1, -1, -1):
		var w: Dictionary = watchers[i]
		w.t += dt
		if not w.fn.call(dt, w.t):
			watchers.remove_at(i)
	if not Game.playing or Game.dead:
		return                        # (the director only runs while you are actually in the run)
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
	if Net.is_online() and not Net.hosting:
		return                        # co-op: the event keys are the host's only
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
		later(dur + rng.randf_range(0.5, 1.2), func(): scares.breath_behind(_behind_neck(0.45), 1.0))
	later(1.2, func():
		haunt(0.8)
		Game.add_glitch(0.25)
		if Game.heart != null:
			Game.heart.feed("breath", 0.85))

# A spot `dist` behind your head, where something would stand to breathe on your neck
func _behind_neck(dist: float) -> Vector3:
	return player.global_position + Vector3(0.0, 1.55, 0.0) + player.global_transform.basis.z * dist

# ---------------------------------------------------------------- shared by the newer events
# The tint now reaches every light in the level, not only the tubes' faces (level_light_pool.gd multiplies its
# real lights by it). A red event turns the camera's white balance off (`tint_wb`), so the red stays red instead
# of being corrected halfway back to white.
const EMERGENCY := Color(0.62, 0.025, 0.015)      # the deep red of emergency lighting
const NEAR_BLACK := Color(0.015, 0.0, 0.0)

func _banner_red(text: String) -> void:
	banner.add_theme_color_override("font_color", Color("b3170c"))
	show_banner(text)
	on_clear(func():
		banner.modulate.a = 1.0
		banner.add_theme_color_override("font_color", Color("ffc107")))

## Recolour every light, but only when it has visibly changed (a full recolour touches every tube)
func _tint(c: Color) -> void:
	var cur: Color = level.tint
	if absf(cur.r - c.r) + absf(cur.g - c.g) + absf(cur.b - c.b) > 0.012:
		level.set_tint(c)

func _red_mode(on: bool) -> void:
	level.set("tint_wb", not on)

func _hush(seconds: float, to := 0.0) -> void:
	var amb: Node = get_parent().get_node_or_null("Audio/Ambience")
	if amb != null:
		amb.hush_for(to, seconds)

## A deep thud carried through the structure: a bulkhead, a door closing somewhere far below
func _boom(volume := 0.6, pitch := 0.4) -> void:
	scares.spawn_flat(scares.synth("thump"), volume, "Scares", pitch)

## A soft footfall from somewhere; the tubes near it shiver
func _step_at(pos: Vector3, volume: float, shiver := 0.5) -> void:
	scares.play_scare("footThump", pos, volume)
	if shiver > 0.0:
		level.disturb(pos, 5.0, shiver)

# ---------------------------------------------------------------- red alert
# No siren, no strobe. The lights stutter and die, a deep thud goes through the building, and when they come back
# every light in the level is emergency red and barely on, swelling and fading slowly, like a pulse. Nobody says
# anything. Somewhere in it something walks the halls, closer each time the red swells. Then the red goes out
# entirely for three seconds, and when it comes back for an instant something is breathing right beside you.
func _event_red_alert() -> void:
	on_clear(func():
		_red_mode(false)
		level.set_tint(Color.WHITE)
		Game.fx_reset())
	haunt(0.6)
	level.disturb(player.global_position, 40.0, 1.0)              # every tube near you stutters
	later(1.4, func():
		_red_mode(true)
		level.set_tint(NEAR_BLACK)
		_boom(0.85, 0.32)
		Game.fx_shock = 0.5
		Game.add_glitch(0.3))
	later(2.6, func():
		_banner_red("CONTAINMENT FAILURE // REMAIN WHERE YOU ARE")
		scares.spawn_flat(scares.synth("drone", 22.0), 0.4))
	later(9.0, hide_banner)
	var st := {"last": -1}
	# 2.8 .. 17: the slow red swell (3.4 s a breath), the picture losing its colour in the troughs
	watch(func(dt: float, t: float) -> bool:
		if t < 2.8:
			return true
		if t > 17.0:
			return false
		var ph := (t - 2.8) / 3.4
		var k := 0.5 - 0.5 * cos(TAU * ph)
		var rise := smoothstep(2.8, 5.0, t)
		_tint(NEAR_BLACK.lerp(EMERGENCY, rise * (0.18 + 0.82 * k * k)))
		Game.fx_contrast = 1.0 + 0.15 * rise
		banner.modulate.a = 0.25 + 0.75 * k
		var n := int(ph)
		if n != st.last:                                         # a far, muffled bulkhead at each swell
			st.last = n
			_boom(0.22, 0.38)
		return true)
	# something walking the halls, nearer each time
	for k in 4:
		later(6.5 + k * 2.7, func(): _step_at(sound_spot(17.0 - 3.5 * k), 0.35 + 0.15 * k, 0.6))
	later(9.5, func(): scares.spawn3d(scares.synth("creak"), sound_spot(14.0, rng.randf() * TAU, 3.0), 0.5, "Scares", 6.0, 0.45))
	# 17: the red goes out. Silence
	later(17.0, func():
		_tint(NEAR_BLACK)
		_hush(6.0)
		scares.spawn_flat(scares.synth("tinnitus", 4.0), 0.12))
	later(18.4, func(): scares.heartbeat(0.7))
	later(19.4, func(): scares.heartbeat(0.8))
	# 20: it slams back on for an instant, and something is right beside you
	later(20.2, func():
		level.set_tint(EMERGENCY * 1.4)
		scares.breath_behind(_behind_neck(0.5), 0.6)
		Game.fx_shock = 0.9
		haunt(1.0))
	later(20.6, func(): level.set_tint(NEAR_BLACK))
	# then back, slowly, wrong, to white
	watch(func(dt: float, t: float) -> bool:
		if t < 22.0:
			return true
		var k := smoothstep(22.0, 26.0, t)
		_tint(NEAR_BLACK.lerp(Color.WHITE, k * k))
		if t >= 26.0:
			_red_mode(false)
			level.set_tint(Color.WHITE)
			Game.fx_reset()
			return false
		return true)
	later(22.0, func(): scares.grid_on())

# ---------------------------------------------------------------- emergency pulse
# Every light in the level drops to red and beats like a heart: lub-dub, each beat lighting the halls for an
# instant. The heart speeds up. It skips, and in the dark of the skipped beat something breathes. Then it fails:
# a long dim red hold and a flatline tone, before the white comes back.
func _event_emergency_pulse() -> void:
	on_clear(func():
		_red_mode(false)
		level.set_tint(Color.WHITE)
		scares.stop_flatline()
		Game.fx_reset())
	_red_mode(true)
	haunt(0.6)
	level.disturb(player.global_position, 30.0, 0.8)
	var st := {"prev": 0.0, "skip_until": -1.0}
	for at in [11.0, 16.0]:
		later(at, func():
			st.skip_until = clock + 1.9
			scares.breath_behind(_behind_neck(0.8), 0.45))
	watch(func(dt: float, t: float) -> bool:
		if t > 21.0:
			return false
		var fade_in := smoothstep(0.0, 1.5, t)
		var period := lerpf(1.3, 0.62, clampf(t / 20.0, 0.0, 1.0))     # it quickens
		var m := fposmod(t, period)
		var d := minf(m, period - m)
		var beat := exp(-pow(d / 0.07, 2.0)) + 0.6 * exp(-pow((m - 0.26) / 0.07, 2.0))
		var live := 0.0 if clock < st.skip_until else 1.0
		var lvl := lerpf(1.0, 0.05 + 0.95 * minf(beat, 1.0) * live, fade_in)
		_tint(Color.WHITE.lerp(EMERGENCY, fade_in) * lvl)
		if m < st.prev and live > 0.0 and t > 1.5:
			scares.heartbeat(0.55)
			Game.fx_shock = 0.2
		st.prev = m
		Game.fx_sat = 1.0 - 0.35 * smoothstep(0.0, 20.0, t)
		return true)
	# it fails: a low dim hold and the flatline under it
	later(21.0, func():
		_tint(EMERGENCY * 0.12)
		scares.flatline(0.22, 0.4)
		_hush(5.0))
	later(24.5, func():
		scares.stop_flatline()
		scares.heartbeat(0.9)
		scares.grid_on())
	watch(func(dt: float, t: float) -> bool:
		if t < 24.5:
			return true
		var k := smoothstep(24.5, 27.5, t)
		_tint((EMERGENCY * 0.12).lerp(Color.WHITE, k))
		if t >= 27.5:
			_red_mode(false)
			level.set_tint(Color.WHITE)
			Game.fx_reset()
			return false
		return true)

# ---------------------------------------------------------------- lights out
# The grid fails in stages: a stutter, a dip, a longer dark each time, the tubes slow to come back. Then it goes,
# and in the black something walks toward you, step by step, and stops just in front of you. Nothing for a long
# moment. The lights come back and you are alone.
func _event_lights_out() -> void:
	on_clear(func():
		level.restore_power()
		level.set_tint(Color.WHITE)
		Game.fx_reset())
	haunt(0.5)
	var at := 0.0
	for i in rng.randi_range(4, 6):
		at += rng.randf_range(0.6, 1.4)
		var off_for := rng.randf_range(0.15, 0.4) + 0.12 * i
		later(at, func():
			level.cut_power(off_for)
			if i > 1: Game.add_glitch(0.1))
		later(at + off_for, func():
			level.restore_power()
			level.set_tint(Color(0.55, 0.5, 0.4)))                     # each time, a little weaker
		at += off_for
	later(at + 0.6, func():
		level.cut_power(9.0)
		level.set_tint(Color.WHITE)
		scares.grid_off(sound_spot(12.0, rng.randf() * TAU, 2.4))
		_hush(9.0, 0.1))
	for k in 4:
		later(at + 2.0 + k * 1.4, func(): scares.play_scare("footThump", sound_spot(9.0 - 2.0 * k), 0.4 + 0.12 * k))
	later(at + 8.0, func(): scares.heartbeat(0.8))
	later(at + 9.8, func():
		level.restore_power()
		scares.grid_on()
		Game.add_glitch(0.3))

# ---------------------------------------------------------------- one lamp
# Everything goes dark but the single tube over you, and it flickers. Something stands under the next tube along,
# breathing. It comes a little nearer at every step, stopping at the edge of your light. Then your lamp dies too.
func _event_one_lamp() -> void:
	on_clear(func():
		level.restore_power()
		level.set_tint(Color.WHITE))
	var p := player.global_position
	var near: Array = level.fixtures_near(p, 16.0)
	near.sort_custom(func(x, y): return Vector2(x.pos.x - p.x, x.pos.z - p.z).length() < Vector2(y.pos.x - p.x, y.pos.z - p.z).length())
	if near.size() < 2:
		return
	var mine: Dictionary = near[0]
	var other: Dictionary = near[1]
	for f: Dictionary in near:
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
		_hush(18.0, 0.15))
	later(4.0, func(): scares.spawn3d(scares.synth("breath_close", 0.0), other_at, 0.22, "Scares", 1.5, 0.6))
	for k in 4:
		later(6.0 + k * 2.3, func(): scares.play_scare("footThump", other_at.lerp(mine.pos - Vector3.UP * 1.5, 0.15 + 0.17 * k), 0.4 + 0.12 * k))
	later(11.0, func():
		scares.heartbeat(0.8)
		haunt(0.8))
	later(13.5, func(): scares.spawn3d(scares.synth("breath_close", 0.0), other_at.lerp(mine.pos, 0.5), 0.26, "Scares", 1.5, 0.55))
	later(16.5, func():
		level.cut_fixture(mine, 6.0)
		level.fixture_event.emit(mine, false)
		Game.add_glitch(0.3))
	later(20.0, func():
		level.restore_power()
		scares.grid_on())

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

# ---------------------------------------------------------------- the machine voice
# An old text-to-speech voice, flat and crushed, reads out one line (tools/gen_machine_voice.py renders them into
# audio/tts/), and the words type themselves across the screen in red as it says them. Sometimes it comes out of
# your own camera; sometimes from a speaker somewhere inside the wall behind you. Everything else goes quiet for
# it. Never the same line twice in a row (the last twelve are held back).
var _voice_recent: Array = []

func _event_machine_voice() -> void:
	var pool: Array = []
	for i in MachineVoice.LINES.size():
		if not _voice_recent.has(i):
			pool.append(i)
	if pool.is_empty():
		return
	var pick: int = pool[rng.randi() % pool.size()]
	_voice_recent.append(pick)
	if _voice_recent.size() > 12:
		_voice_recent.pop_front()
	var line: Array = MachineVoice.LINES[pick]
	var stream: AudioStream = load(line[0]) if ResourceLoader.exists(line[0]) else null
	if stream == null:
		return                                   # (not imported yet: open the project in the editor once)
	var dur := stream.get_length()
	on_clear(func():
		banner.visible_ratio = 1.0
		Game.fx_static = 0.0)
	_hush(dur + 2.0, 0.1)
	haunt(0.5)
	Game.add_glitch(0.35)
	var wall := _wall_face_behind(4.0, 9.0)
	if rng.randf() < 0.4 and wall.is_finite():
		scares.spawn3d(stream, wall, 0.9, "Scares", 5.0)          # a speaker somewhere in the wall
	else:
		scares.spawn_flat(stream, 0.5)                             # out of your own camera
	_banner_red(str(line[1]))
	banner.visible_ratio = 0.0
	watch(func(dt: float, t: float) -> bool:
		if t > dur + 1.0:
			hide_banner()
			banner.visible_ratio = 1.0
			Game.fx_static = 0.0
			return false
		banner.visible_ratio = clampf((t - 0.25) / maxf(dur * 0.8, 0.1), 0.0, 1.0)
		banner.modulate.a = 0.55 if rng.randf() < 0.06 else 1.0     # the text stutters
		Game.fx_static = 0.1 + 0.06 * sin(t * 11.0)
		return true)

# ---------------------------------------------------------------- shared by the events below
## A looping player (the imported wav doesn't loop, so it restarts itself), flat or at `pos`
func _loop_player(path: String, pos := Vector3.INF) -> Node:
	if not ResourceLoader.exists(path):
		return null
	var stream: AudioStream = load(path)
	var p: Node
	if pos.is_finite():
		var p3 := AudioStreamPlayer3D.new()
		p3.stream = stream
		p3.bus = "Scares"
		p3.unit_size = 4.0
		p3.max_distance = 45.0
		p3.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p3.volume_db = -60.0
		add_child(p3)
		p3.global_position = pos
		if scares.audio != null:
			scares.audio.occlude(p3, true)                          # through the wall: muffled
		p3.finished.connect(p3.play)
		p3.play()
		p = p3
	else:
		var p2 := AudioStreamPlayer.new()
		p2.stream = stream
		p2.bus = "Scares"
		p2.volume_db = -60.0
		add_child(p2)
		p2.finished.connect(p2.play)
		p2.play()
		p = p2
	return p

func _free(n) -> void:
	if n != null and is_instance_valid(n):
		n.queue_free()

## The wall face nearest you within `max_d` (the side of a wall cell that looks into an open one)
func _wall_face_nearest(max_d: float) -> Vector3:
	var p := player.global_position
	var cell := GridNav.CELL
	var cx := GridNav.cell(p.x)
	var cz := GridNav.cell(p.z)
	var r := ceili(max_d / cell) + 1
	var best := Vector3.INF
	var best_d := INF
	for x in range(cx - r, cx + r + 1):
		for z in range(cz - r, cz + r + 1):
			if not nav.is_wall(x, z):
				continue
			for o in GridNav.NEIGHBOURS:
				if nav.blocked(x + o.x, z + o.y):
					continue
				var face := Vector3(x * cell + o.x * cell * 0.5, p.y + 0.6, z * cell + o.y * cell * 0.5)
				var d := Vector2(face.x - p.x, face.z - p.z).length()
				if d < best_d and d <= max_d:
					best_d = d
					best = face
	return best

# ---------------------------------------------------------------- someone joined
# A terminal card: a field researcher has joined the expedition. Nobody joined. Sometimes it is a name nobody has,
# sometimes it is one of your teammates, who is standing next to you, and sometimes it is you. The [F6] CREW page
# lists them: alive, 0 m away, on your floor. A while later their signal is lost.
const GHOST_NAMES := ["HALVERSON", "R. OKAFOR", "DELACROIX", "M. VOSS", "J. ABERNATHY", "SURVIVOR 00", "NOBODY",
	"E. LINDQVIST", "THE OTHER ONE", "K. MARSH"]

func _event_ghost_roster() -> void:
	var callsign: String = GHOST_NAMES[rng.randi() % GHOST_NAMES.size()]
	var roll := rng.randf()
	if roll < 0.3:
		var me: String = Net.my_name()
		callsign = me if me != "" else "YOU"
	elif roll < 0.5 and not Net.remotes.is_empty():
		var ids: Array = Net.remotes.keys()
		callsign = Net.label_for(int(ids[rng.randi() % ids.size()]))
	var id := 9000 + rng.randi() % 900
	# somewhere out in the halls, wandering: a distance that drifts, so the roster reads like a real one
	Net.phantoms[id] = {"name": callsign, "dist": rng.randf_range(18.0, 150.0), "drift": rng.randf_range(-2.5, 2.5)}
	on_clear(func(): Net.phantoms.erase(id))
	Net.survivor_joined.emit(id, callsign, false)
	haunt(0.4)
	later(rng.randf_range(40.0, 70.0), func():
		if Net.phantoms.has(id):
			Net.phantoms.erase(id)
			Net.survivor_left.emit(id, callsign))

# ---------------------------------------------------------------- the hum rises
# The fluorescent buzz you stopped hearing hours ago starts to climb. (The level's own hum fades out under it, so
# there is only the one.) Louder, harsher, a little higher, until it hurts: your eyes water and won't stay open,
# blinking harder and more often, squinting, the picture swimming. Then it stops, and so does every other sound:
# nothing at all, for long enough to make you wonder whether you can still hear. Then the hum comes back.
func _event_hum_rises() -> void:
	var au: Node = get_parent().get_node_or_null("Audio")
	var hum = _loop_player("res://audio/events/hum_loop.wav")
	var lids = player.get("blink")                             # player/blink.gd: the player's own blink
	if au != null: au.hum_event_target = 0.0
	on_clear(func():
		_free(hum)
		Game.fx_reset()
		if au != null:
			au.set_muffled(false)
			au.hum_event_target = 1.0)
	haunt(0.3)
	var st := {"next": 3.0}
	watch(func(dt: float, t: float) -> bool:
		if t >= 15.0:
			return false
		var k := pow(t / 15.0, 2.2)
		if hum != null and is_instance_valid(hum):
			hum.volume_db = linear_to_db(0.015 + 0.55 * k)
			hum.pitch_scale = 1.0 + 0.06 * k
		Game.fx_blur = 0.38 * k
		Game.fx_shock = maxf(Game.fx_shock, 0.15 * k * (0.5 + 0.5 * sin(t * 37.0)))
		# the eyes: blinks coming harder and closer together, and a squint between them
		st.next -= dt
		if lids != null and t > 2.0:
			if st.next <= 0.0:
				st.next = lerpf(3.2, 0.6, k) + rng.randf() * 0.5
				lids.blink(lerpf(1.0, 1.9, k))                       # slower, heavier as it hurts
			elif not lids.blinking():
				Game.fx_blink = 0.32 * k * k                         # squinting against it
		if k > 0.45 and rng.randf() < dt * 2.0:
			level.disturb(player.global_position, 12.0, 0.6)
		return true)
	later(15.0, func():
		_free(hum)
		Game.fx_reset()
		if au != null: au.set_muffled(true)
		_hush(8.0))
	later(16.5, func(): scares.spawn_flat(scares.synth("tinnitus", 4.0), 0.06))
	later(22.0, func():
		if au != null:
			au.set_muffled(false)
			au.hum_event_target = 1.0                          # the level's hum fades back in
		scares.play_scare("restrike"))

# ---------------------------------------------------------------- the party
# Through the drywall beside you: music, a thumping bass, a crowd talking and laughing, someone shrieking with
# laughter. A party, somewhere in here. Follow it and it stays just the other side of the wall. Put your ear to
# it and it stops dead, all of it at once, the way a room goes quiet when someone walks in. Then a single knock.
func _event_party_wall() -> void:
	var wall := _wall_face_behind(5.0, 13.0)
	if not wall.is_finite():
		wall = _wall_face_nearest(12.0)
	if not wall.is_finite():
		return
	var party = _loop_player("res://audio/events/party_muffled.wav", wall)
	if party == null:
		return
	on_clear(func(): _free(party))
	haunt(0.3)
	var life := rng.randf_range(30.0, 60.0)                      # how long the party goes on, if you leave it be
	const FADE := 5.0
	watch(func(dt: float, t: float) -> bool:
		if party == null or not is_instance_valid(party):
			return false
		var p := player.global_position
		if Vector2(wall.x - p.x, wall.z - p.z).length() < 3.0 and t > 2.0:
			_free(party)                                         # it heard you
			_hush(5.0)
			later(2.6, func(): scares.knock(wall, 1.1, scares.KNOCK_KNUCKLE))
			later(3.0, func(): haunt(0.9))
			return false
		# in over 4 s, on for `life`, then winding down over FADE s, as if the party were drifting off elsewhere
		var level_k := smoothstep(0.0, 4.0, t) * (1.0 - smoothstep(life - FADE, life, t))
		party.volume_db = linear_to_db(maxf(0.75 * level_k, 0.0001))
		if t >= life:
			_free(party)
			return false
		return true)

# ---------------------------------------------------------------- the phone
# Somewhere down the halls an old desk phone is ringing. It keeps ringing. Go to it and it stops mid-ring before
# you get there. A moment of quiet. Then it rings once more, very close, behind you, and is cut off.
func _event_phone_ring() -> void:
	var spot: Vector3 = find_corridor_spot(14.0, 26.0).pos
	if not ResourceLoader.exists("res://audio/events/phone_ring.wav"):
		return
	var ring: AudioStream = load("res://audio/events/phone_ring.wav")
	var st := {"next": 0.6, "count": 0, "now": null}
	on_clear(func(): _free(st.now))
	watch(func(dt: float, t: float) -> bool:
		var p := player.global_position
		if Vector2(spot.x - p.x, spot.z - p.z).length() < 5.0:
			_free(st.now)                                        # it stops before you reach it
			_hush(5.0, 0.2)
			later(3.4, func():
				var close: AudioStreamPlayer3D = scares.spawn3d(ring, _behind_neck(1.6), 0.45, "Scares", 1.5, 1.0, false)
				get_tree().create_timer(0.55).timeout.connect(func(): _free(close))
				haunt(1.0))
			return false
		st.next -= dt
		if st.next <= 0.0:
			if st.count >= 9:
				return false
			st.count += 1
			st.next = 6.0
			st.now = scares.spawn3d(ring, spot, 0.8, "Scares", 7.0, 1.0)
		return true)

# ---------------------------------------------------------------- the pacer
# Footsteps, real ones, on carpet, somewhere off to one side of you: far, muffled through the walls, keeping pace.
# Walk and they walk, a beat behind your own; stop and they stop. Over the minute it goes on they come a little
# nearer, from the next corridor over to the one beside yours. Stand still long enough and they stop too, and
# then there is one more step. Closer.
var _carpet_steps: Array = []

func _carpet_step(pos: Vector3, volume: float) -> void:
	if _carpet_steps.is_empty():
		for i in range(1, 5):
			var path := "res://audio/carpet_walk_%d.wav" % i
			if ResourceLoader.exists(path):
				_carpet_steps.append(load(path))
	if _carpet_steps.is_empty():
		return
	var s: AudioStream = _carpet_steps[rng.randi() % _carpet_steps.size()]
	scares.spawn3d(s, pos, volume, "Scares", 4.0, rng.randf_range(0.84, 0.94))     # (walls between muffle it)

func _event_hound_pacing() -> void:
	var side_sign := 1.0 if rng.randf() < 0.5 else -1.0
	var st := {"last": player.global_position, "moved": 0.0, "still": 0.0, "n": 0}
	haunt(0.4)
	watch(func(dt: float, t: float) -> bool:
		var p := player.global_position
		var b := player.global_transform.basis
		var fwd := Vector3(-b.z.x, 0.0, -b.z.z).normalized()
		var side := Vector3(-fwd.z, 0.0, fwd.x) * side_sign
		var away := lerpf(17.0, 8.0, clampf(t / 45.0, 0.0, 1.0))          # the next corridor over, then nearer
		var at := p + side * away - fwd * 1.5 + Vector3.UP * 0.1
		var mv := Vector2(p.x - st.last.x, p.z - st.last.z).length()
		st.last = p
		if mv > 0.01:
			st.still = 0.0
			st.moved += mv
			if st.moved >= 0.85:                                      # one of theirs for each of yours
				st.moved = 0.0
				st.n += 1
				later(rng.randf_range(0.12, 0.3), func(): _carpet_step(at, 0.75))
		else:
			st.still += dt
			if st.n >= 6 and st.still > 3.0:
				# they wait with you. Then one more step, nearer
				later(1.6, func(): _carpet_step(p + side * 4.5 - fwd * 1.0, 0.85))
				later(2.2, func(): haunt(0.8))
				return false
		return t < 60.0)

# ---------------------------------------------------------------- run
# Every light dies. Two seconds of black and your own heartbeat. Then, far down the hall, the lights come back on
# in red, one after another, coming toward you, fast, with something heavy running under them. It does not stop.
# It goes straight through where you are standing, and on past you, and the red keeps lighting up behind you.
func _event_run() -> void:
	var p0 := player.global_position
	var spot := find_corridor_spot(16.0, 30.0)
	var dir := Vector3(spot.pos.x - p0.x, 0.0, spot.pos.z - p0.z).normalized()
	var line: Array = []
	for f: Dictionary in level.fixtures_near(p0, 46.0):
		var d := Vector3(f.pos.x - p0.x, 0.0, f.pos.z - p0.z)
		var along := d.dot(dir)
		if along > -26.0 and (d - dir * along).length() < 3.5:
			line.append([along, f])
	if line.size() < 4:
		return
	line.sort_custom(func(x, y): return x[0] > y[0])
	var start: float = line[0][0] + 2.0
	on_clear(func():
		_red_mode(false)
		level.set_tint(Color.WHITE)
		level.restore_power()
		Game.fx_reset())
	_red_mode(true)
	level.cut_power(40.0)
	level.set_tint(EMERGENCY * 1.7)
	scares.grid_off(sound_spot(10.0, rng.randf() * TAU, 2.4))
	_hush(30.0, 0.1)
	haunt(0.6)
	later(0.9, func(): scares.heartbeat(0.9))
	later(1.8, func(): scares.heartbeat(1.0))
	const SPEED := 8.5
	var st := {"idx": 0, "step": 0.0, "passed": false, "done": -1.0}
	watch(func(dt: float, t: float) -> bool:
		if t < 2.4:
			return true
		var front := start - SPEED * (t - 2.4)
		while st.idx < line.size() and line[st.idx][0] >= front:
			var f: Dictionary = line[st.idx][1]
			level.cut_fixture(f, 0.02)                            # strikes back on, red
			st.idx += 1
		var mine := (player.global_position - p0).dot(dir)
		st.step -= dt
		if st.step <= 0.0 and st.done < 0.0:
			st.step = 0.26
			var near := 1.0 - clampf(absf(front - mine) / 30.0, 0.0, 1.0)
			scares.spawn3d(scares.synth("thump"), p0 + dir * front + Vector3.UP * 0.2, 0.35 + 0.65 * near, "Scares", 6.0, 0.55)
		if not st.passed and front < mine + 0.5:
			st.passed = true                                      # through you
			Game.fx_shock = 1.0
			Game.fx_flash = 0.35
			Game.add_glitch(0.7)
			scares.spawn_flat(scares.synth("thump"), 0.9, "Scares", 0.38)
			haunt(1.0)
		if st.idx >= line.size() and st.done < 0.0:
			st.done = t
		if (st.done >= 0.0 and t - st.done > 2.5) or t > 26.0:
			level.set_tint(Color.WHITE)
			level.restore_power()
			_red_mode(false)
			scares.grid_on()
			Game.fx_reset()
			return false
		return true)
