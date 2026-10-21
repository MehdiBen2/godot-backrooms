extends "res://scripts/Events/events_core.gd"
## Events about the lights and the building: power cut, whispers, knocking, red alert, lamps, dead air.

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
	# (the last step is an odd one, white: an even one at 2.1 s landed in the same frame as the cut below, and the
	# queue runs newest first, so it could leave the dim tint on every real light for the whole cut and after it)
	for i in range(1, 6):
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
		later(POWER_CUT_SECONDS, func():
			player.grid_down = false
			level.set_tint(Color.WHITE))
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
