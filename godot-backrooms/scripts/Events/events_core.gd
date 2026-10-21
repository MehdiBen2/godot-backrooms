extends Node
## Event director core: the clock, the queue, tension, picking and running events, the banner and the
## tools every event uses (later / watch / on_clear ...). The events themselves live in events_fx.gd
## (lights, power, knocking) and events_audio.gd (voices and sounds); events.gd defines and registers them.

const GridNav := preload("res://scripts/World/grid_nav.gd")
const MachineVoice := preload("res://scripts/Audio/machine_voice_lines.gd")

const FIRST_MIN := 150.0
const FIRST_MAX := 240.0
const GAP_MIN := 55.0
const GAP_MAX := 130.0
const DISABLED := false               # set true to switch off every director/trigger event (crash hunting)
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
var _share_voice := true         # false while a zone's own event runs: its voice line is for the walker only

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
	banner.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	banner.add_theme_constant_override("shadow_offset_x", 2)
	banner.add_theme_constant_override("shadow_offset_y", 2)
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
	var _pt := Time.get_ticks_usec()
	_process_timed(dt)
	Perf.add("Events", _pt)

func _process_timed(dt: float) -> void:
	# solo: a pause holds the scare where it is. Co-op: the others are still in it, so it runs on (dead too:
	# whatever it switched off still has to come back)
	if DISABLED or (not Net.is_online() and (not Game.playing or Game.dead)):
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
	if Game.level != null and Game.level.has_method("is_hub") and Game.level.is_hub():
		return                        # a T.S.R.A. hub (tsra_launch_bay.gd) is a safe place: nothing is sent at you there
	if not director_calm():
		return
	if recovery > 0.0:
		recovery -= dt
		return
	var c := context()
	tension += dt * tension_rate(c)
	if tension < threshold:
		return
	# the only event that ever starts by itself is the grid failure; every other one comes from the host's
	# debug panel or a level editor trigger zone
	var grid: Dictionary = {}
	for e in events:
		if e.name == "powerCut":
			grid = e
	if grid.is_empty() or not eligible(grid, c, false) or score_of(grid, c) <= 0.0:
		tension = threshold - RETRY
	else:
		run_event("powerCut")

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
		if not e.random or not eligible(e, c, force):      # (random: false = only a trigger zone / debug call runs it)
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

func run_event(name: String, share := true) -> bool:
	if DISABLED:
		return false
	for e in events:
		if e.name != name:
			continue
		last = name
		last_at = Game.time
		_share_voice = share
		if share:
			Net.send_event(name)      # co-op host: everyone gets it
		history[name] = Game.time
		busy_until = Game.time + e.duration
		recovery = RECOVERY_BASE + RECOVERY_PER_INTENSITY * e.intensity
		tension = 0.0
		threshold = rng.randf_range(GAP_MIN, GAP_MAX)
		e.run.call()
		_share_voice = true
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
