extends Node
## Scare sounds (js/audio/scares.js, scares2.js, bacteria.js). The web game builds these from
## oscillators and filtered noise at run time; here the same recipes are rendered into AudioStreamWAVs
## on first use (scare_synth.gd) and played flat or positioned through AudioStreamPlayer3D.
##
## The parts with logic of their own live beside it (their old entry points are kept here):
##   creature_voice.gd  THE BACTERIA's calls and its breathing       (entity_call, entity_breathe...)
##   creature_steps.gd  the Bacteria's and the mannequin's footfalls  (howler_step, mannequin_step)
##   preacher.gd        the preacher whisper event                    (preacher)
##
## What you hear when something gets you: one hit per beat, never two stacked.
##   seized     gasp() (a recording, loudness-matched; your breathing waits it out) + seize() + a heartbeat
##   the bite   bite_death(): the blood-scream recording once, plus its own bite recording, wet rips after it
##   neck snap  neck_snap(): its own recording (synth crack as a fallback), and the heart stops on the spot (flatline)
##   death      heart_stop() settles the flatline into a quiet hold under the death muffle,
##              body_fall() lands with your body on the death camera, and the last breath (DEATH_VOICE)
##              goes out with it - except when something caught you: the bite/snap already told that
##              story at the moment it happened
##
## death_reaction(Game.DeathType) dispatches to the reaction sound above by kind; RIPPED / EXPLODED /
## STRANGLED are reserved for future death types and have no sound of their own yet.

const ScareSynth := preload("res://scripts/Audio/scares/scare_synth.gd")
const CreatureVoice := preload("res://scripts/Audio/scares/creature_voice.gd")
const CreatureSteps := preload("res://scripts/Audio/scares/creature_steps.gd")
const Preacher := preload("res://scripts/Audio/scares/preacher.gd")
const ClipLevels := preload("res://scripts/Audio/clip_levels.gd")
const SfxPool := preload("res://scripts/Audio/sfx_pool.gd")

const PREACHER_NAMES := Preacher.NAMES

# The startle gasps. They were recorded at levels 26 dB apart, so each is matched to GASP_RMS (peak kept
# under GASP_PEAK) and then played GASP_GAIN hotter. The old flat x32 was tuned for the two quiet takes
# and drove the loud ones to +26 dBFS: the gasp you heard when caught was a clipped blast.
const GASPS := [
	"res://audio/player/gasp/gasp_2.mp3", "res://audio/player/gasp/gasp_3.mp3",
	"res://audio/player/gasp/gasp_4.mp3", "res://audio/player/gasp/gasp_5.mp3",
	"res://audio/player/gasp/gasp_6.mp3",
	"res://audio/player/gasp/gasp_short_1.mp3", "res://audio/player/gasp/gasp_short_2.mp3",
]
const GASP_RMS := -20.0
const GASP_PEAK := -6.0
const GASP_GAIN := 2.0
# Five of the takes open with a second-plus of breath-in before the actual gasp hits (measured):
# skip straight to it so the catch is heard the instant it plays, not after its wind-up.
const GASP_SKIP := {
	"res://audio/player/gasp/gasp_2.mp3": 1.14,
	"res://audio/player/gasp/gasp_3.mp3": 1.32,
	"res://audio/player/gasp/gasp_4.mp3": 1.06,
	"res://audio/player/gasp/gasp_5.mp3": 1.32,
	"res://audio/player/gasp/gasp_6.mp3": 1.26,
}
const BODY_FALL := "res://audio/player/death/body_fall.mp3"
# The last breath, only when nothing caught you (a bite/snap already had its own reaction sound)
const DEATH_VOICE := "res://audio/player/death/death.mp3"
const BLOOD_SCREAM := "res://audio/entity/blood_scream.mp3"
# The bacteria's bite: its own recording, on top of the blood-scream splat()
const BITE_DEATH := "res://audio/player/death/bite/bitedeathsound.mp3"
# The mannequin's neck snap: its own recording, replacing the synthesized crack (synth("neck_snap"),
# kept only as a fallback if this one is ever missing)
const NECK_SNAP_SOUND := "res://audio/player/death/neck_snap/floraphonic-necksnap-10-218514.mp3"
const GRID_OFF := "res://audio/events/gridoff.mp3"
const TUBE_RESTRIKE := "res://audio/tube_restrike.wav"
# A recorded single lub-dub dropped at one of these paths replaces the synthesized one
const HEART_SAMPLES := ["res://audio/player/heartbeat.ogg", "res://audio/player/heartbeat.wav", "res://audio/player/heartbeat.mp3"]

# The monitor's flat tone of a heart that has stopped. ONE player per life: it is started once and after
# that only its level moves (the grab / snap bring it up, death settles it down to a quiet hold). Never
# a second copy: two of the same 1 kHz tone beat against each other and it sounds like it restarts.
const FLATLINE_GAIN := 1.0        # as the heart stops (grab, snap)
const FLATLINE_HOLD_GAIN := 0.5   # dead: a thin line under the muffle until the respawn, not an alarm

var rng := RandomNumberGenerator.new()
var player: Node3D
var audio: Node
var voice: CreatureVoice
var steps: CreatureSteps
var preacher_fx: Preacher

var _synth := ScareSynth.new()
var _streams := {}                # path -> AudioStream, loaded once so nothing loads on the hot path
var _last_gasp := -1
var _last_gasp_time := -10.0
var _last_scream_time := -100.0
var _clock := 0.0
var _last_beat := -1.0
var _heart_sample: AudioStream = null
var _flat_player: AudioStreamPlayer = null
var _flat_tween: Tween
var _prewarm_task := -1

func _ready() -> void:
	rng.randomize()
	player = get_parent().get_node("Player")
	audio = get_parent().get_node_or_null("Audio")
	voice = CreatureVoice.new()
	voice.name = "CreatureVoice"
	add_child(voice)
	steps = CreatureSteps.new(self)
	preacher_fx = Preacher.new(self)
	# every scare clip goes into the buffer pool now, on worker threads, so none of them hits the disk mid-scare
	SfxPool.warm(GASPS + [BODY_FALL, DEATH_VOICE, BLOOD_SCREAM, BITE_DEATH, NECK_SNAP_SOUND, GRID_OFF, TUBE_RESTRIKE] + SfxPool.scare_paths())
	for path in HEART_SAMPLES:
		if ResourceLoader.exists(path):
			_heart_sample = load(path)
			break

func _stream(path: String) -> AudioStream:
	if not _streams.has(path):
		_streams[path] = SfxPool.get_stream(path)
	return _streams[path]

func _process(dt: float) -> void:
	_clock += dt
	preacher_fx.update(dt)

# ------------------------------------------------------------------ synthesis
func synth(name: String, arg := 0.0) -> AudioStreamWAV:
	return _synth.render(name, arg)

# ------------------------------------------------------------------ playback
## A one-shot at `pos` that frees itself. `occlude`: walls between you and it muffle it (audio.gd).
func spawn3d(stream: AudioStream, pos: Vector3, linear: float, bus := "Scares", ref := 5.0, pitch := 1.0, occlude := true) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.stream = stream
	p.bus = bus
	p.unit_size = ref
	p.max_distance = 90.0
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	p.volume_db = linear_to_db(maxf(linear, 0.0001))
	p.pitch_scale = pitch
	add_child(p)
	p.global_position = pos
	if occlude and audio != null:
		audio.occlude(p, true)
	p.finished.connect(p.queue_free)
	p.play()
	return p

## A one-shot with no position (inside your head, or everywhere at once) that frees itself
func spawn_flat(stream: AudioStream, linear: float, bus := "Scares", pitch := 1.0) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.bus = bus
	p.volume_db = linear_to_db(maxf(linear, 0.0001))
	p.pitch_scale = pitch
	add_child(p)
	p.finished.connect(p.queue_free)
	p.play()
	return p

# audio.playScare(name, ...) from the web events
func play_scare(name: String, a = null, b = null) -> void:
	match name:
		"footThump":
			var v := float(b) if b != null else 0.8
			spawn3d(synth("thump"), a, v * 0.9, "Scares", 4.0, rng.randf_range(0.85, 1.1))
		"restrike":
			if _stream(TUBE_RESTRIKE) != null:
				spawn_flat(_stream(TUBE_RESTRIKE), 0.8)
		"drone":
			spawn_flat(synth("drone", float(a) if a != null else 14.0), 0.9)
		"staticHit":
			spawn_flat(synth("static_hit"), 0.55 * (float(a) if a != null else 1.0))
		"gridOff", "gridoff":
			grid_off(a if a is Vector3 else Vector3.INF)

## A knuckle on the drywall at `pos` (the wall knock event)
func knock(pos: Vector3, weight := 1.0) -> void:
	spawn3d(synth("wall_knock"), pos, 0.9 * weight, "Scares", 3.0, rng.randf_range(0.9, 1.08))

## One wet breath at the back of your neck, as if the bacteria were right there (the breath event).
## Its breathing loop played once through, not looped.
func breath_behind(pos: Vector3) -> void:
	var once := synth("rasp_loop").duplicate() as AudioStreamWAV
	once.loop_mode = AudioStreamWAV.LOOP_DISABLED
	var p := spawn3d(once, pos, 0.9, "Scares", 1.2, rng.randf_range(0.88, 0.96), false)
	p.max_distance = 12.0

# The grid dying somewhere far off. Like web scares.js: ref 12, volume 2, not occluded (a reverberant
# distant sound carries through the walls)
func grid_off(pos := Vector3.INF) -> void:
	if not pos.is_finite():
		pos = (player.global_position if player else Vector3.ZERO) + Vector3(18.0, 2.4, 0.0)
	if _stream(GRID_OFF) != null:
		spawn3d(_stream(GRID_OFF), pos, 2.0, "Scares", 12.0, 1.0, false)

# ------------------------------------------------------------------ the heart and the body
# One heart: two callers asking for a beat in the same instant (the grab and the entity's proximity
# beat, say) get ONE beat, never a flam that sounds like it stuttered
func heartbeat(strength := 1.0, pitch := 1.0) -> void:
	if _clock - _last_beat < 0.3:          # game time, not the wall clock
		return
	_last_beat = _clock
	spawn_flat(_heart_sample if _heart_sample != null else synth("heartbeat"), clampf(0.45 * strength, 0.05, 1.2), "Body", pitch)
	Game.beat()

# The moment something seizes you: one designed hit instead of a stinger + static burst stacked
func seize() -> void:
	spawn_flat(synth("seize"), 1.0, "Body")

func entity_static() -> void:
	spawn_flat(synth("static"), 0.5, "Scares", rng.randf_range(0.9, 1.15))

func startle(amount := 0.5) -> void:
	spawn_flat(synth("stinger"), clampf(amount * 0.8, 0.1, 0.8))

# The bite (tithuh-blood-the-screaming, from the web game). The grab calls this for the bite and each
# rip after it: the scream plays ONCE per death, the rips get the synthesized wet hit only.
func splat() -> void:
	var s := _stream(BLOOD_SCREAM)
	var now := Time.get_ticks_msec() / 1000.0
	if s != null and now - _last_scream_time > s.get_length() + 1.0:
		_last_scream_time = now
		spawn_flat(s, 0.9, "Body")
	else:
		spawn_flat(synth("splat"), 0.9, "Body")

## Your neck, wrenched round: the crack, right inside your head, and a wet give under it
func neck_snap() -> void:
	var s := _stream(NECK_SNAP_SOUND)
	if s != null:
		spawn_flat(s, 1.1, "Body", rng.randf_range(0.98, 1.02))
	else:
		spawn_flat(synth("neck_snap"), 1.1, "Body", rng.randf_range(0.94, 1.04))
	spawn_flat(synth("splat"), 0.35, "Body", 0.8)

## THE BACTERIA's jaws closing: the blood-scream splat plus its own bite recording, on top of it
func bite_death() -> void:
	splat()
	var s := _stream(BITE_DEATH)
	if s != null:
		spawn_flat(s, 1.0, "Body")

## The reaction sound for how you died (Game.DeathType), played once at the moment itself.
func death_reaction(kind: int) -> void:
	match kind:
		Game.DeathType.NECK_SNAP:
			neck_snap()
		Game.DeathType.BITE:
			bite_death()
		Game.DeathType.RIPPED, Game.DeathType.EXPLODED, Game.DeathType.STRANGLED:
			pass # TODO: no dedicated sound/reaction yet - falls back to whatever the caller already played

func flatline(gain := FLATLINE_GAIN, fade := 0.9) -> void:
	if not flatlining():
		_flat_player = spawn_flat(synth("flatline_loop"), 1.0, "Body")
		_flat_player.volume_db = -60.0
	if _flat_tween != null and _flat_tween.is_valid():
		_flat_tween.kill()
	# a tween in dB is an exponential ramp in level: the tone swells in the way the old one did
	_flat_tween = create_tween()
	_flat_tween.tween_property(_flat_player, "volume_db", linear_to_db(gain), fade)

func flatline_hold(fade := 1.5) -> void:
	flatline(FLATLINE_HOLD_GAIN, fade)

func stop_flatline() -> void:
	if _flat_player == null or not is_instance_valid(_flat_player):
		_flat_player = null
		return
	if _flat_tween != null and _flat_tween.is_valid():
		_flat_tween.kill()
	var p := _flat_player
	_flat_player = null
	var tw := create_tween()
	tw.tween_property(p, "volume_db", -80.0, 0.25)
	tw.tween_callback(p.queue_free)

func flatlining() -> bool:
	return _flat_player != null and is_instance_valid(_flat_player) and _flat_player.playing

# Dead silence: high ear ringing
func tinnitus(seconds: float) -> void:
	spawn_flat(synth("tinnitus", seconds), 1.0, "Body")

# Your body hitting the floor under the death camera (thekids15 body-fall recording). `from` skips
# into the file, so the death camera can line its thud up with the frame the body lands on.
func body_fall(from := 0.0, voice := true) -> void:
	var s := _stream(BODY_FALL)
	if s == null:
		return
	var p := spawn_flat(s, 1.0, "Body")
	if from > 0.0:
		p.play(from)
	# the last breath leaving you as you hit the floor - never when something caught you: the bite/
	# snap already told that story at the moment it happened
	if voice and _stream(DEATH_VOICE) != null:
		spawn_flat(_stream(DEATH_VOICE), 1.0, "Voice")

# At death: a grab or snap already stopped the heart, so its flatline (the same player) just settles
# down to the quiet hold. A death nothing built up to gets a few weak, uneven beats first, then the line.
func heart_stop() -> void:
	if flatlining():
		flatline_hold(2.0)
		return
	for b in [[0.3, 1.2], [1.15, 0.8], [2.35, 0.45]]:
		get_tree().create_timer(b[0], false).timeout.connect(heartbeat.bind(b[1]))
	get_tree().create_timer(3.1, false).timeout.connect(flatline_hold.bind(0.9))

# Render the death sounds on a worker thread now, so the moment you die never hitches on the synthesis.
# The synth cache is static: this only does real work once per session.
func prewarm_death() -> void:
	if _prewarm_task >= 0:
		return
	var s := ScareSynth.new()          # its own rng: not shared with the main thread
	var jobs := [["rasp_loop", 0.0], ["flatline_loop", 0.0], ["neck_snap", 0.0],
		["static_hit", 0.0], ["stinger", 0.0], ["seize", 0.0], ["heartbeat", 0.0], ["splat", 0.0],
		["howler_step", 0.0], ["howler_step", 1.0], ["howler_step", 2.0], ["howler_step", 3.0],
		["howler_step", 10.0], ["howler_step", 11.0], ["howler_step", 12.0], ["howler_step", 13.0],
		["howler_far", 0.0], ["howler_far", 1.0], ["howler_far", 2.0], ["howler_far", 3.0], ["howler_drag", 0.0], ["howler_drag", 10.0], ["bone_crack", 0.0], ["heel", 0.0], ["tile_step", 0.0], ["thump", 0.0], ["wall_knock", 0.0],
		["mannequin_step", 0.0], ["mannequin_step", 1.0], ["mannequin_step", 2.0], ["mannequin_step", 3.0],
		["mannequin_creak", 0.0], ["mannequin_creak", 1.0], ["mannequin_creak", 2.0]]
	_prewarm_task = WorkerThreadPool.add_task(func():
		for j in jobs:
			s.render(j[0], j[1]))

func _exit_tree() -> void:
	if _prewarm_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_prewarm_task)
		_prewarm_task = -1

## A gasp of fright (seized, snapped, struck). Never the same take twice running, all at one loudness.
## The recording IS that breath: the breathing model waits it out rather than gasping over it.
func gasp(volume_mult := 1.0) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_gasp_time < 0.35:
		return
	_last_gasp_time = now
	var breath = audio.breathing if audio != null else null
	var i := rng.randi() % GASPS.size()
	if GASPS.size() > 1 and i == _last_gasp:
		i = (i + 1) % GASPS.size()
	var s := _stream(GASPS[i])
	if s == null:
		if breath != null:
			breath.gasp(1.0)                # no recordings imported: the breathing model does it
		return
	_last_gasp = i
	var g := ClipLevels.gain(GASPS[i], GASP_RMS, GASP_PEAK) * GASP_GAIN * volume_mult
	var p := spawn_flat(s, g, "Voice", rng.randf_range(0.96, 1.04))
	var skip: float = GASP_SKIP.get(GASPS[i], 0.0)
	if skip > 0.0:
		p.play(skip)
	if breath != null:
		breath.hold_for(s.get_length() - skip + 0.2)
	# and the music steps aside for a moment so the gasp is not buried under it
	var amb: Node = audio.get_node_or_null("Ambience") if audio != null else null
	if amb != null and volume_mult >= 0.5:
		amb.hush_for(0.25, 1.8)

func stop_all() -> void:
	for c in get_children():
		if c is AudioStreamPlayer or c is AudioStreamPlayer3D:
			c.queue_free()
	_flat_player = null
	preacher_fx.clear()

# ------------------------------------------------------------------ THE BACTERIA (creature_voice.gd)
func voice_busy() -> bool:
	return voice.busy()

## A call of `kind` from `pos`; `interrupt` cuts off the current one. Returns false if busy.
func entity_call(kind: String, pos: Vector3, interrupt := false, volume := 1.0, pitch := -1.0) -> bool:
	return voice.call_out(kind, pos, interrupt, volume, pitch)

func entity_move(pos: Vector3) -> void:
	voice.move(pos)

func entity_whisper(pos: Vector3, ear_pos: Vector3) -> bool:
	return voice.whisper(pos, ear_pos)

func set_entity_occlusion(blocked: bool) -> void:
	voice.set_occlusion(blocked)

func entity_breathe(level: float, pitch := 1.0) -> void:
	voice.breathe(level, pitch)

# ------------------------------------------------------------------ footfalls (creature_steps.gd)
func howler_step(pos: Vector3, weight: float, dragging := false, run := 0.0) -> void:
	steps.howler_step(pos, weight, dragging, run)

func mannequin_step(pos: Vector3, weight := 1.0) -> void:
	steps.mannequin_step(pos, weight)

func mannequin_settle(pos: Vector3, weight := 1.0) -> void:
	steps.mannequin_settle(pos, weight)

# ------------------------------------------------------------------ the preacher (preacher.gd)
func preacher(pos: Vector3, variant: int, end_pos: Vector3, glide: float, volume := 1.0) -> void:
	preacher_fx.play(pos, variant, end_pos, glide, volume)
