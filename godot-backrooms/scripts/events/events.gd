extends Node
## Event director (js/game/events.js + eventDefs.js). Decides WHEN something happens and WHICH
## event fits the moment: tension builds while things are quiet (faster when you stand still,
## walk in the dark or have low sanity), then a weighted pick among events that are off cooldown
## and pass their own when()/score(). Events use later() / watch() / on_clear().
##
## Dev keys: F6 random event, F7 power cut, F8 preacher whisper, F9 stop all events.

const GridNav := preload("res://scripts/world/grid_nav.gd")

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
	define({"name": "tiltDrift", "weight": 2.0, "cooldown": 180.0, "duration": 14.0, "intensity": 0.4,
		"score": func(c): return (1.5 if c.still > 4.0 else 1.0) * (1.5 if c.sanity < 50.0 else 1.0),
		"run": _event_tilt_drift})
	define({"name": "preacherWhisper", "weight": 2.0, "cooldown": 360.0, "duration": 12.0, "intensity": 0.5,
		"when": func(c): return c.since_last > 60.0,
		"score": func(c): return 1.0 + minf(1.0, c.still / 10.0),
		"run": func(): _event_preacher(-1)})

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

func show_banner(text: String) -> void:
	banner.text = text
	banner.visible = true

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
		history[name] = Game.time
		busy_until = Game.time + e.duration
		recovery = RECOVERY_BASE + RECOVERY_PER_INTENSITY * e.intensity
		tension = 0.0
		threshold = rng.randf_range(GAP_MIN, GAP_MAX)
		e.run.call()
		return true
	return false

func _unhandled_input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	match e.physical_keycode:
		KEY_F1: print("event: ", trigger_random(true))
		KEY_F6: debug_spawn_hunters()
		KEY_F7: run_event("powerCut")
		KEY_F8: run_event("preacherWhisper")
		KEY_F9: stop_all()
		KEY_F12: run_event("tiltDrift")

# DEBUG F6: warp into the mannequin room and drop the bacteria a few metres away, already screeching.
# Dev keys: F1 random event, F2 mannequin room, F3 mimic peek, F4 bacteria stalk, F5 mimic session,
# F6 mannequin + bacteria, F7 power cut, F8 preacher, F9 stop all, F10 bacteria in front, F12 tilt drift.
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

	# pre-flicker warning across ~2 s
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
		later(35.0, func(): scares.play_scare("vanish"))
		later(POWER_CUT_SECONDS, func(): scares.play_scare("restrike")))

# ---------------------------------------------------------------- tilt drift
func _event_tilt_drift() -> void:
	var secs := 14.0
	on_clear(func(): player.cam.rotation.z = 0.0)
	scares.play_scare("drone", secs)
	watch(func(_dt: float, t: float) -> bool:
		var env := minf(1.0, t / 3.0) * minf(1.0, (secs - t) / 3.0)
		player.cam.rotation.z = 0.32 * sin(t * 0.7) * maxf(0.0, env)
		if t < secs:
			return true
		player.cam.rotation.z = 0.0
		return false)

# ---------------------------------------------------------------- preacher whisper
# A Mandela Catalogue-style preacher voice from down a corridor, drifting closer
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
