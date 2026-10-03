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

