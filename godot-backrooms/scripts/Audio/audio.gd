extends Node
## Port of the web game's audio engine (js/audio/*.js) to Godot.
##
## Bus layout mirrors core.js (every game bus is built here, see _setup_buses):
##   World    = worldTrim (x0.5) + lowpass 16 kHz (750 Hz while paused) + a room reverb that follows
##              the space around you  <- hum, drone, one-shots, and the buses below that send to it
##     Ambience        = high-pass + low-pass (ambience.gd darkens it)   <- the recorded beds
##     Entity          = low-pass, walls between you and THE BACTERIA    <- its voice, breath, feet
##     Scares          = plain                                           <- stingers, thumps, whispers
##     MannequinSteps  = low-pass, head shadow + walls                   <- the mannequin's footfalls
##     Preacher        = rebuilt per variant (preacher.gd)
##   Body     = x0.7, never muffled     <- your own breathing, gasps, heartbeat, jump, landing
##   Steps    = lowpass + reverb + pan  <- your footfalls, straight to master
##   Master   = compressor (-10 dB, 6:1) + the death muffle low-pass
##
## The synthesized sounds (ballast hum, breaths, clicks, pops, drone) are pre-rendered from the
## same filter chains by tools/gen_audio.py; audio/scales.json holds the level each file was
## stored at, so playback gain here = the web game's gain.

const GridNav := preload("res://scripts/World/grid_nav.gd")
const Breathing := preload("res://scripts/Audio/breathing.gd")

const HUM_VOLUME := 0.1              # AUDIO.humVolume
const HUM_HABITUATED := 0.45         # AUDIO.humHabituatedLevel
const HUM_HABIT_TIME := 14.0         # AUDIO.humHabituationTime
const DRONE_BASE := 0.2
const SLOT_GAIN := 0.3               # per-fixture hum voice gain
const ONE_SHOTS := 8

# Every bus the game owns. The scene is reloaded on each respawn but the AudioServer keeps its buses,
# so these are torn down and rebuilt on every load. ONLY these: voice chat's capture bus and its
# per-speaker buses (the Voice autoload) live across reloads, and deleting them killed the microphone
# after the first death.
const GAME_BUSES := ["World", "Body", "Steps", "Ambience", "Entity", "Scares", "MannequinSteps", "Preacher", "Voice"]

var level: Node
var player: Node
var ui: Node

var scales := {}
var streams := {}
var vol := {"master": 1.0, "footsteps": 1.0, "hum": 1.0, "breathing": 1.0, "ambient": 1.0}

# --- buses
var world_idx := 0
var body_idx := 0
var steps_idx := 0
var world_lp: AudioEffectLowPassFilter
var world_rev: AudioEffectReverb
var nav: GridNav
var room_timer := 0.0
var outdoor_mix := 0.0         # 0 = the backrooms .. 1 = the open-air hills level (Game.outdoors), eased
var room_size := 0.35          # smoothed measurements of the space around the listener
var room_target := 0.35
var echo_mix := 0.0           # 0..1, eased: standing in an Echo zone (level_data.gd `echo`)
var steps_lp: AudioEffectLowPassFilter
var steps_rev: AudioEffectReverb      # your footsteps in the room around you (follows the room measure)
var steps_pan: AudioEffectPanner      # left foot, right foot
var world_cutoff := 16000.0
var world_cutoff_target := 16000.0
var world_tc := 0.3
var muffled := false            # dead: the world stays dull until you respawn
var world_dread := 0.0          # 0..1 while held: the world slowly closes in
var world_vol := 1.0
var master_lp: AudioEffectLowPassFilter   # dead: EVERYTHING goes dull and far away, not just the world
var master_cut := 20000.0
var paused := false
var pops_enabled := true

# --- hum
var voices: Array[AudioStreamPlayer3D] = []
var voice_gain: Array[float] = []
var diffuse: AudioStreamPlayer
var drone: AudioStreamPlayer
var drone_swell := 0.0
var hum_attention := 1.0
var hum_mix := 0.0
var hum_user := 1.0
var hum_user_target := 1.0

# --- your breathing (breathing.gd)
var breathing := Breathing.new()
var one_shots: Array[AudioStreamPlayer] = []

func _ready() -> void:
	level = get_parent().get_node("Level")
	player = get_parent().get_node("Player")
	ui = get_parent().get_node("UI")
	scales = JSON.parse_string(FileAccess.get_file_as_string("res://audio/scales.json"))
	_setup_buses()
	_setup_hum()
	breathing.audio = self
	breathing.setup()
	for i in ONE_SHOTS:
		var p := AudioStreamPlayer.new()
		add_child(p)
		one_shots.append(p)
	level.fixture_event.connect(_on_fixture_event)
	level.slot_assigned.connect(func(_i): hum_notice(0.12))   # walking under a new light draws the ear back
	player.jumped.connect(_on_jump)
	player.landed.connect(_on_land)
	player.battery_died.connect(func(): play_world("battery_dead.wav"))
	player.battery_swap.connect(func(): play_world("battery_swap.wav"))
	player.battery_swap_cut.connect(func(): stop_world("battery_swap.wav"))
	player.dead_click.connect(func(): play_world("battery_dead_click.wav"))
	player.contact_click.connect(func(off: bool): play_world("flash_click_off.wav" if off else "flash_click_on.wav"))
	var amb := Node.new()
	amb.name = "Ambience"
	amb.set_script(preload("res://scripts/Audio/ambience.gd"))
	add_child(amb)
	var out := Node.new()
	out.name = "Outdoor"
	out.set_script(preload("res://scripts/Audio/outdoor_audio.gd"))
	add_child(out)

# ---------------------------------------------------------------- buses
func _setup_buses() -> void:
	var steps_vol := -1.0
	var old_steps := AudioServer.get_bus_index("Steps")
	if old_steps >= 0:
		steps_vol = AudioServer.get_bus_volume_linear(old_steps)
	for i in range(AudioServer.bus_count - 1, 0, -1):
		if AudioServer.get_bus_name(i) in GAME_BUSES:
			AudioServer.remove_bus(i)
	while AudioServer.get_bus_effect_count(0) > 0:
		AudioServer.remove_bus_effect(0, 0)
	var comp := AudioEffectCompressor.new()
	comp.threshold = -10.0
	comp.ratio = 6.0
	comp.attack_us = 4000.0
	comp.release_ms = 200.0
	AudioServer.add_bus_effect(0, comp)
	master_lp = AudioEffectLowPassFilter.new()
	master_lp.cutoff_hz = 20000.0
	AudioServer.add_bus_effect(0, master_lp)

	world_idx = _add_bus("World", "Master")
	body_idx = _add_bus("Body", "Master")
	steps_idx = _add_bus("Steps", "Master")

	# World: small absorptive room (dropped ceiling + damp carpet = short dark tail), then the muffle filter
	world_rev = AudioEffectReverb.new()
	world_rev.room_size = 0.35
	world_rev.damping = 0.75
	world_rev.spread = 1.0
	world_rev.hipass = 0.0
	world_rev.dry = 1.0
	world_rev.wet = 0.14
	AudioServer.add_bus_effect(world_idx, world_rev)
	world_lp = AudioEffectLowPassFilter.new()
	world_lp.cutoff_hz = 16000.0
	AudioServer.add_bus_effect(world_idx, world_lp)
	AudioServer.set_bus_volume_linear(world_idx, 0.5)          # worldTrim
	AudioServer.set_bus_volume_linear(body_idx, 0.7)

	steps_lp = AudioEffectLowPassFilter.new()
	steps_lp.cutoff_hz = 20000.0
	AudioServer.add_bus_effect(steps_idx, steps_lp)          # effect 0: footsteps.gd sets it for the crouch muffle
	# The recorded steps are dry. Give them the same space as everything else: a tight slap in a corridor,
	# a longer tail across a big hall (kept drier than the World bus: they're right under you)
	steps_rev = AudioEffectReverb.new()
	steps_rev.room_size = 0.35
	steps_rev.damping = 0.8
	steps_rev.spread = 0.6
	steps_rev.dry = 1.0
	steps_rev.wet = 0.08
	steps_rev.predelay_msec = 12.0
	AudioServer.add_bus_effect(steps_idx, steps_rev)
	steps_pan = AudioEffectPanner.new()
	AudioServer.add_bus_effect(steps_idx, steps_pan)
	if steps_vol >= 0.0:
		AudioServer.set_bus_volume_linear(steps_idx, steps_vol)

	# Ambience (ambience.gd): effect 0 keeps MP3 rumble out of the drone's sub-bass, effect 1 darkens it
	var amb := _add_bus("Ambience", "World")
	var hp := AudioEffectHighPassFilter.new()
	hp.cutoff_hz = 70.0
	AudioServer.add_bus_effect(amb, hp)
	var amb_lp := AudioEffectLowPassFilter.new()
	amb_lp.cutoff_hz = 12000.0
	AudioServer.add_bus_effect(amb, amb_lp)
	# Entity / MannequinSteps: effect 0 is the muffle their owners drive (creature_voice.gd, creature_steps.gd)
	for bus in ["Entity", "MannequinSteps"]:
		var lp := AudioEffectLowPassFilter.new()
		lp.cutoff_hz = 20000.0
		AudioServer.add_bus_effect(_add_bus(bus, "World"), lp)
	_add_bus("Scares", "World")
	_add_bus("Preacher", "World")

	# Voice: the recorded gasps / last breath were taken on a cheap mic (hiss, thin, close). Band-limit them,
	# add a little grit to mask the noise floor, and put them in a small room so they sit in the world
	var voice := _add_bus("Voice", "Body")
	var v_hp := AudioEffectHighPassFilter.new()
	v_hp.cutoff_hz = 180.0
	AudioServer.add_bus_effect(voice, v_hp)
	var v_lp := AudioEffectLowPassFilter.new()
	v_lp.cutoff_hz = 4800.0
	AudioServer.add_bus_effect(voice, v_lp)
	var v_dist := AudioEffectDistortion.new()
	v_dist.mode = AudioEffectDistortion.MODE_LOFI
	v_dist.drive = 0.12
	v_dist.post_gain = -2.0
	AudioServer.add_bus_effect(voice, v_dist)
	var v_rev := AudioEffectReverb.new()
	v_rev.room_size = 0.45
	v_rev.damping = 0.6
	v_rev.dry = 0.85
	v_rev.wet = 0.3
	AudioServer.add_bus_effect(voice, v_rev)

func _add_bus(bus_name: String, send: String) -> int:
	AudioServer.add_bus()
	var idx := AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, bus_name)
	AudioServer.set_bus_send(idx, send)
	return idx

func stream(file: String) -> AudioStream:
	if not streams.has(file):
		streams[file] = load("res://audio/" + file)
	return streams[file]

# Looping is set in the .import files (edit/loop_mode=Forward, uncompressed). Never compute loop points
# from data.size(): with compressed imports that cut the loop mid-file and ticked.
func loop_stream(file: String) -> AudioStream:
	return stream(file)

# ---------------------------------------------------------------- hum
func _setup_hum() -> void:
	for i in level.POOL_SIZE:
		var p := AudioStreamPlayer3D.new()
		p.stream = loop_stream("hum_voice.wav")
		p.bus = "World"
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p.unit_size = 1.6
		p.max_distance = 40.0
		p.volume_db = -80.0
		add_child(p)
		p.play(randf() * 15.0)          # decorrelated, like the per-voice delay lines
		voices.append(p)
		voice_gain.append(0.0)
	diffuse = AudioStreamPlayer.new()
	diffuse.stream = loop_stream("hum_diffuse.wav")
	diffuse.bus = "World"
	diffuse.volume_db = -80.0
	add_child(diffuse)
	diffuse.play()
	drone = AudioStreamPlayer.new()
	drone.stream = loop_stream("drone.wav")
	drone.bus = "World"
	drone.volume_linear = DRONE_BASE / float(scales.get("drone.wav", 1.0))     # sub-bass dread drone (fear swells it)
	add_child(drone)
	drone.play()

func hum_notice(amount := 0.3) -> void:
	hum_attention = minf(1.0, hum_attention + amount)

func _update_hum(dt: float) -> void:
	# HumDirector: habituation, masking by breathing, dread, menu dimming
	hum_attention += (HUM_HABITUATED - hum_attention) * minf(1.0, dt / HUM_HABIT_TIME)
	var masking := 1.0 - 0.55 * breathing.loudness - (0.2 if player.is_sprinting else 0.0)
	var dread: float = 1.0 - 0.6 * Game.terror - 0.15 * Game.presence     # the hum shrinks away as it closes in
	var menu := 0.4 if paused else 1.0
	var target := maxf(0.0, hum_attention * masking * dread * menu)
	hum_mix += (target - hum_mix) * (1.0 - exp(-dt / 0.35))
	hum_user += (hum_user_target - hum_user) * (1.0 - exp(-dt / 1.5))
	var mix: float = hum_mix * HUM_VOLUME * hum_user * vol.hum * (1.0 - outdoor_mix)     # no fluorescent hum under the sky
	var comp := 1.0 / float(scales["hum_voice.wav"])
	for i in voices.size():
		var lvl: float = level.slot_level(i)
		var p := voices[i]
		if lvl > 0.004: p.global_position = level.slot_position(i)
		# inverse-distance falloff: Godot's model is half the web panner's at the reference distance
		var want := lvl * SLOT_GAIN * mix * comp * 2.0 * (1.0 - 0.6 * float(p.get_meta("occl", 0.0)))
		voice_gain[i] += (want - voice_gain[i]) * (1.0 - exp(-dt / 0.03))
		p.volume_linear = voice_gain[i]
	diffuse.volume_linear = mix / float(scales["hum_diffuse.wav"])
	# dread drone: swells with the entity's presence and the run's overall fear, up to 3x
	var swell := clampf(maxf(Game.presence, Game.fear * 0.7), 0.0, 1.0)
	drone_swell += (swell - drone_swell) * (1.0 - exp(-dt / 1.2))
	drone.volume_linear = DRONE_BASE * (1.0 + 2.0 * drone_swell) * (1.0 - outdoor_mix) / float(scales.get("drone.wav", 1.0))

# ---------------------------------------------------------------- tube pops
func _on_fixture_event(f: Dictionary, restrike: bool) -> void:
	if Game.outdoors or not pops_enabled or f.slot < 0 or not (restrike or randf() < 0.5): return
	var file := "tube_restrike.wav" if restrike else "tube_drop.wav"
	var p := AudioStreamPlayer3D.new()
	p.stream = stream(file)
	p.bus = "World"
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	p.unit_size = 1.6
	p.max_distance = 40.0
	p.volume_linear = hum_mix * HUM_VOLUME * hum_user * 2.0
	add_child(p)
	p.global_position = f.light_pos
	occlude(p, true)
	p.finished.connect(p.queue_free)
	p.play()
	hum_notice(0.15 if restrike else 0.25)

# ---------------------------------------------------------------- one-shots
func _play(file: String, bus: String, linear: float, pitch := 1.0) -> void:
	for p in one_shots:
		if not p.playing:
			p.stream = stream(file)
			p.bus = bus
			p.volume_linear = linear / float(scales.get(file, 1.0))
			p.pitch_scale = pitch
			p.play()
			return

## A short sound in the world with no position (clicks, the dead battery, a pickup)
func play_world(file: String) -> void:
	_play(file, "World", 1.0)

## Cut a one-shot short where it is (the battery swap, when a flinch ends it)
func stop_world(file: String) -> void:
	for p in one_shots:
		if p.playing and p.stream == stream(file):
			p.stop()

func _on_jump() -> void:
	_play("jump.wav", "Body", 1.0)

func _on_land(strength: float) -> void:
	_play("land_thud.wav", "Body", minf(1.0, 0.4 + strength * 0.6))

# ---------------------------------------------------------------- pause / muffle
# While something has hold of you (0..1): the world slowly closes in, dulling and ducking a little at
# a time. It never goes silent, you still hear everything, just as if from underwater.
func set_dread(v: float) -> void:
	world_dread = clampf(v, 0.0, 1.0)

# Dead: the world settles into a dull, distant muffle and stays there until the respawn
func set_muffled(on: bool) -> void:
	muffled = on
	world_tc = 0.5 if on else 0.28

func set_paused(on: bool) -> void:
	paused = on
	if not on: hum_notice(0.4)

# Where the world filter should sit right now
func _world_cutoff_goal() -> float:
	var open_hz := 750.0 if paused else 16000.0
	if muffled:
		# the master bus muffles everything once you're dead (see _process); the world filter just holds
		# where it is, so it can't open back up for a moment while the master one is still closing
		return minf(open_hz, world_cutoff)
	# an exponential glide from open down to a dull 2.2 kHz as the dread builds
	return open_hz * pow(2200.0 / 16000.0, world_dread)

# ---------------------------------------------------------------- frame
func _process(dt: float) -> void:
	outdoor_mix += ((1.0 if Game.outdoors else 0.0) - outdoor_mix) * (1.0 - exp(-dt / 1.0))
	world_cutoff_target = _world_cutoff_goal()
	world_cutoff += (world_cutoff_target - world_cutoff) * (1.0 - exp(-dt / world_tc))
	# the duck: a little quieter while held, a little more once dead (never below 60%)
	var vol_goal := 0.6 if muffled else 1.0 - 0.3 * world_dread
	world_vol += (vol_goal - world_vol) * (1.0 - exp(-dt / 0.4))
	AudioServer.set_bus_volume_linear(world_idx, 0.5 * world_vol)
	# Only touch the filter when the cutoff actually moves: re-setting it every frame resets
	# the filter state and clicks
	if absf(world_lp.cutoff_hz - world_cutoff) > 5.0:
		world_lp.cutoff_hz = world_cutoff
	# dead: every bus (world, entity, your body, the scares) through one dull muffle, as if underwater.
	# 1.1 kHz leaves the 1 kHz flatline tone just through it
	master_cut += ((1100.0 if muffled else 20000.0) - master_cut) * (1.0 - exp(-dt / world_tc))
	if absf(master_lp.cutoff_hz - master_cut) > 5.0:
		master_lp.cutoff_hz = master_cut
	if not paused:
		breathing.update(dt)
	_update_hum(dt)
	_update_room(dt)
	breathing.play_queue()

# ---------------------------------------------------------------- wall occlusion
# Godot has no geometry occlusion, so count the wall cells between a source and the listener on the
# level grid (the same map the entity's muffle uses). Each wall thickens the muffle: the per-player
# attenuation filter drops from open air (~20 kHz) toward a dull thud, and the level falls a little.
func grid() -> GridNav:
	if nav == null and level.size > 0:
		nav = GridNav.new(level)
	return nav

func walls_between(a: Vector3, b: Vector3) -> int:
	var g := grid()
	if g == null or Game.outdoors: return 0        # open air: nothing between you and the sound
	var dx := b.x - a.x
	var dz := b.z - a.z
	var steps := ceili(sqrt(dx * dx + dz * dz) / 0.75)
	var count := 0
	var last := Vector2i(1 << 30, 1 << 30)
	for i in range(1, steps):
		var t := float(i) / steps
		var c := Vector2i(GridNav.cell(a.x + dx * t), GridNav.cell(a.z + dz * t))
		if c != last and level.walls.has(c):
			count += 1
		last = c
	return count

# 0 = clear line, 1 = fully boxed in. Stored on the player so update_hum can scale its gain.
func occlude(p: AudioStreamPlayer3D, instant := false) -> void:
	var o := clampf(walls_between(player.global_position, p.global_position) / 3.0, 0.0, 1.0)
	if Game.hunted: o = minf(o, 0.3)          # it is coming for you: never lose it behind a corner
	p.set_meta("occl", o)
	p.attenuation_filter_cutoff_hz = lerpf(20000.0, 650.0, sqrt(o))
	p.attenuation_filter_db = -24.0
	if instant: p.volume_linear *= 1.0 - 0.6 * o

# ---------------------------------------------------------------- per-area reverb
# Fire eight rays across the grid to measure the space around the listener. Tight corridors give a
# short, dry, dark tail; big open halls and tall ceilings give a longer, wetter, more open one.
func _measure_room() -> float:
	var g := grid()
	if g == null: return 0.35
	var p: Vector3 = player.global_position
	var total := 0.0
	for i in 8:
		var a := i * TAU / 8.0
		var d := 1.0
		# (walls only: a pit is open air, and a Safe zone is closed to entities, not to sound)
		while d < 36.0 and not g.is_wall(GridNav.cell(p.x + sin(a) * d), GridNav.cell(p.z + cos(a) * d)):
			d += 1.5
		total += d
	var mean := total / 8.0                                   # ~4 in a corridor, 30+ in a hall
	var ceil_h: float = level.ceiling_height(Vector2i(GridNav.cell(p.x), GridNav.cell(p.z)))
	return clampf(0.15 + mean / 45.0 + (ceil_h - level.WALL_H) / 40.0, 0.15, 0.95)

func _update_room(dt: float) -> void:
	room_timer -= dt
	if room_timer <= 0.0:
		room_timer = 0.25
		room_target = 0.15 if Game.outdoors else _measure_room()    # the grid measure means nothing under the open sky
	room_size += (room_target - room_size) * (1.0 - exp(-dt / 1.5))
	# Outdoors is not an enclosed space: almost no tail at all (short, dark, barely wet), just enough that a
	# sound is not bone dry. It blends with the indoor measure so crossing over never jumps.
	var o := outdoor_mix
	var rs := lerpf(room_size, 0.1, o)
	var world_wet := lerpf(0.08 + 0.22 * room_size, 0.015, o)
	var world_damp := lerpf(0.85 - 0.25 * room_size, 0.95, o)
	var steps_wet := lerpf(0.05 + 0.16 * room_size, 0.01, o)
	var steps_damp := lerpf(0.88 - 0.25 * room_size, 0.95, o)
	# an Echo zone (painted in the level editor): a huge, hard, wet space whatever the room measures
	var pp: Vector3 = player.global_position
	var zone = level.get("echo")
	var in_echo: bool = not Game.outdoors and zone is Dictionary and zone.has(Vector2i(GridNav.cell(pp.x), GridNav.cell(pp.z)))
	echo_mix += ((1.0 if in_echo else 0.0) - echo_mix) * (1.0 - exp(-dt / 0.7))
	rs = lerpf(rs, 0.97, echo_mix)
	world_wet = lerpf(world_wet, 0.5, echo_mix)
	world_damp = lerpf(world_damp, 0.3, echo_mix)
	steps_wet = lerpf(steps_wet, 0.42, echo_mix)
	steps_damp = lerpf(steps_damp, 0.3, echo_mix)
	# only write when it has moved: re-setting reverb parameters every frame can zipper
	if absf(world_rev.room_size - rs) > 0.01 or absf(world_rev.wet - world_wet) > 0.004:
		world_rev.room_size = rs
		world_rev.wet = world_wet
		world_rev.damping = world_damp
		steps_rev.room_size = rs
		steps_rev.wet = steps_wet
		steps_rev.damping = steps_damp

# Which foot came down (-1 left, 1 right): a slight pan, like the web game's +-0.06
func step_foot(side: float) -> void:
	if steps_pan != null:
		steps_pan.pan = side * 0.07
