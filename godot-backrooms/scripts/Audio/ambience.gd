extends Node
## Ambience director: decides WHICH recorded bed plays, WHEN, how loud and how dark.
##
## Tension (0..1) is read from the game every frame: the entity's fear/presence, darkness, lost
## sanity and power cuts. Each track has a tension it suits, so a calm walk gets the quiet beds and
## a hunt-in-the-dark gets the heavy ones. Beds crossfade, never repeat back to back, start part-way
## in so the long ones stay fresh, and step out of the way while the entity is actually hunting you
## (you need to hear it). Everything goes through the "Ambience" bus (high-pass + low-pass, built by
## audio.gd) that gets darker in tight corridors, at low sanity and during a blackout.
##
## The recordings were mastered anywhere from -16 to -28 dB RMS, so each bed is first matched to the
## same loudness (clip_levels.gd), then trimmed by its `gain`.
##
## Also owns a sparse layer of far-off events (muffled thumps behind walls) so the silence between beds
## is never truly empty.
##
## Proximity: the nearest live threat (the entity, an awake mannequin, a spawned mimic, the burnt) pushes the bed
## louder, lower and more open the closer it gets, with fewer walls in between counting for more.
## On top of that every bed drifts on its own: slow random wanders in level and pitch, sudden swells
## and moments where the tape sags out of tune, so it never settles into something you stop hearing.
##
## Whichever threat is nearest also colours WHICH bed gets picked (`tag` on each TRACKS entry, matched
## against NEAR_RANGE's keys: "Entity" is the bacteria, "Mannequin", "Mimic", "Burnt"; "Statue" matches
## either of the two that only move while you aren't looking: the mannequins and the burnt): once something is close
## enough to matter, its own beds are favoured over the general untagged ones (_pick()'s entity_w).
## Nothing close by: an untagged bed on mood alone, or - as always - nothing at all.
##
## Phases (the silence is deliberate, not a bug):
##   BED      one bed up, creeping in over FADE_IN from a random point in the file and fading out at another
##            random point (anywhere from BED_MIN_PLAY in to the file's own end), so no two plays are the same stretch
##   BREATH   a short gap between two beds; the far-off thumps can still come through it
##   SILENCE  a long stretch with no bed, 1-4 minutes: the fluorescent hum, and whatever is out there (the
##            far-off thumps, the entities' feet and voices) heard all the plainer for it.
##            A silence budget keeps it near SILENCE_SHARE of the calm airtime: the less silence there has
##            been lately, the likelier the next bed is followed by one. Never while things are tense or
##            something is close; a threat closing in breaks it at once with a quick (FADE_IN_URGENT) bed.
## A run opens on a short silence, so the first thing you hear down here is the hum.

const ClipLevels := preload("res://scripts/Audio/clip_levels.gd")

const DIR := "res://audio/ambients/"
const BASE := 0.1                      # AmbientSystem.BASE_VOLUME
const BED_RMS := -20.0                 # every bed is matched to this loudness before BASE and its trim
const FADE_IN := 8.0                   # eased in from nothing: it is already there before you notice it start
const FADE_IN_URGENT := 3.0            # a silence broken by tension or a threat closing in
const FADE_OUT := 10.0
const KILL_FADE := 3.5                 # crossfade when the mood changes mid-track
const SWITCH_GAP := 45.0               # min seconds between mood switches
const NEAR_RANGE := {"Entity": 38.0, "Mannequin": 22.0, "Mimic": 26.0, "Burnt": 24.0}
# the threats that stand still while watched and move while you look away: a "Statue" bed is theirs
const STATUES := ["Mannequin", "Burnt"]
# ...and once one of them is this close (near, 0..1), its bed is put on outright, not just favoured
const STATUE_FORCE := 0.1
const NEAR_BOOST := 1.8                # extra level at point-blank (x2.8 overall)
const NEAR_PITCH := 0.08               # how far the bed drops in pitch as it closes in
# tension = the mood each bed suits; gain = level trim between the recordings (tune by ear);
# tag = which threat this bed is favoured for when it's the nearest one ("" = fine anywhere, no pull)
# Tiers come from measuring each recording (level range over time, sudden hits per minute, brightness):
#   calm   - steady, no hits, dark: the empty-office buzz you walk through
#   uneasy - still quiet, but something moves in it now and then
#   tense  - swells, booms and hits; for when something is actually out there
const TRACKS := [
	# calm (range 3-10 dB, no hits)
	{"file": "ambient1.mp3", "tension": 0.05, "gain": 1.0, "tag": ""},                          # flattest of all, long
	{"file": "ambient-drone.wav", "tension": 0.1, "gain": 1.0, "tag": ""},                      # plain drone, short
	{"file": "creepy-ambience_C_minor.wav", "tension": 0.15, "gain": 1.0, "tag": ""},           # low, slowly shifting
	{"file": "creepy-ambience-long-hollow-loop_130bpm.wav", "tension": 0.25, "gain": 1.0, "tag": "Entity"},   # deep hollow pulse
	# uneasy (a few events, brighter)
	{"file": "mleckert82-spooky-ambience-212885.mp3", "tension": 0.35, "gain": 1.0, "tag": ""},
	{"file": "universfield-horror-background-atmosphere-026-30-352879.mp3", "tension": 0.5, "gain": 1.0, "tag": ""},
	# tense (range 15-28 dB, booms and hits)
	{"file": "haunted-ambience_A#_major.wav", "tension": 0.6, "gain": 1.0, "tag": "Mannequin"},
	{"file": "universfield-creepy-tension-background-30-352872.mp3", "tension": 0.7, "gain": 1.0, "tag": "Mimic"},
	{"file": "dragon-studio-dark-horror-ambient-05-425468.mp3", "tension": 0.75, "gain": 1.0, "tag": ""},   # sub-bass booms, widest range
	{"file": "universfield-dark-horror-soundscape-345814.mp3", "tension": 0.8, "gain": 1.0, "tag": ""},
	{"file": "universfield-horror-background-atmosphere-09-219111.mp3", "tension": 0.9, "gain": 1.0, "tag": "Statue"},
]
# While tension is under this, every bed at or under it counts as an equally good fit (the calm pool), so a
# quiet walk rotates through all of them instead of the one nearest in tension winning every time.
const CALM_POOL := 0.3
# how much a track tagged for the nearest threat is favoured over an untagged one, scaled by `near`
const ENTITY_PULL := 2.2
# A track unplayed this long gets up to this much extra weight in _pick() (scales in), so all TRACKS get
# a turn over a long session instead of the 2-3 closest in tension hogging the airtime.
const STARVED_AFTER := 90.0
const STARVED_BONUS := 2.0
# A bed plays for an atmospheric stretch (looped cleanly), then a BREATH or a SILENCE follows
const BED_MIN_PLAY := 50.0
const BED_MAX_PLAY := 85.0
const BREATH_MIN := 8.0
const BREATH_MAX := 18.0
# Liminal dead air: only the fluorescent hum. Kept to a natural length so it breathes without feeling broken
const SILENCE_MIN := 25.0
const SILENCE_MAX := 75.0
const OPENING_MIN := 10.0                 # the silence a run opens on
const OPENING_MAX := 25.0
const SILENCE_SHARE := 0.35               # the share of (bed + silence) airtime the budget aims for
const AIR_MEMORY := 600.0                 # seconds: how far back the budget remembers
const SILENCE_TENSION_MAX := 0.4          # never silent at or above this tension
const SILENCE_NEAR_MAX := 0.2             # ...or with a threat this close

enum Phase { BED, BREATH, SILENCE }

var audio: Node
var player: Node
var lp: AudioEffectLowPassFilter
var voices: Array = []                 # {p, idx, t, left, gain, dying, dying_t, drift...}
var streams := {}
var recent: Array[int] = []
var rng := RandomNumberGenerator.new()

var tension := 0.0
var duck := 1.0
var hush := 1.0                        # hush_for(): 1 = bed as normal, near 0 = faded out
var _hush_until := 0.0
var cutoff := 12000.0
var lfo := 0.0
var phase := Phase.SILENCE
var phase_left := 0.0                  # seconds left in a BREATH / SILENCE (a BED runs on its voice)
var switch_cd := 0.0
var event_timer := 30.0
var near := 0.0                        # 0..1 smoothed closeness of the nearest threat
var near_target := 0.0
var near_timer := 0.0
var near_key := ""                     # NEAR_RANGE key of whichever threat is nearest right now
var swell := 0.0                       # a sudden surge in level, decays on its own
var swell_timer := 12.0
var sag := 0.0                         # a moment where the bed drags out of tune
var sag_target := 0.0
var sag_timer := 20.0
var _threats := {}                     # NEAR_RANGE key -> node (looked up once)
var _since_played := {}                # track idx -> seconds since it last played (starved bonus in _pick())
var _bed_air := 0.0                    # recent seconds with a bed up / in silence (decay over AIR_MEMORY)
var _silence_air := 0.0

func _ready() -> void:
	rng.randomize()
	audio = get_parent()
	player = audio.player
	lp = AudioServer.get_bus_effect(AudioServer.get_bus_index("Ambience"), 1) as AudioEffectLowPassFilter
	cutoff = lp.cutoff_hz
	phase_left = rng.randf_range(OPENING_MIN, OPENING_MAX)     # open on the hum alone
	var root: Node = audio.get_parent()
	for key in NEAR_RANGE:
		_threats[key] = root.get_node_or_null(key)

## Step the bed back to `level` for `seconds` (a whisper or a gasp needs the room). Overlapping requests
## keep the quietest level and the latest end, so one ending never brings the bed back under another.
func hush_for(level: float, seconds: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	hush = minf(hush, level) if now < _hush_until else level
	_hush_until = maxf(_hush_until, now + seconds)

# ---------------------------------------------------------------- mood
func _target_tension() -> float:
	var dark := 1.0 - clampf(player.light_level / 0.5, 0.0, 1.0)
	var t := maxf(Game.fear, Game.presence * 0.8)
	t = maxf(t, dark * 0.5)
	t = maxf(t, (1.0 - player.sanity / 100.0) * 0.8)
	t = maxf(t, near * 0.95)
	if player.grid_down:
		t = maxf(t, 0.7)
	return clampf(t, 0.0, 1.0)

func _stream(i: int) -> AudioStream:
	if not streams.has(i):
		var path: String = DIR + TRACKS[i].file
		if ResourceLoader.exists(path):
			var s: AudioStream = load(path)
			if s is AudioStreamMP3:
				s.loop = true
			elif s is AudioStreamWAV:
				s = s.duplicate()
				s.loop_mode = AudioStreamWAV.LOOP_FORWARD
				s.loop_begin = 0
				s.loop_end = int(s.get_length() * s.mix_rate)
			streams[i] = s
		else:
			streams[i] = null
	return streams[i]

# Weighted pick: tracks whose mood matches now, never the one just played, never one already up
func _pick() -> int:
	var live: Array[int] = []
	for v in voices:
		live.append(v.idx)
	var best := -1
	var total := 0.0
	var weights := {}
	for i in TRACKS.size():
		if live.has(i) or _stream(i) == null:
			continue
		var d: float = (tension - TRACKS[i].tension) / 0.28
		if tension < CALM_POOL and TRACKS[i].tension <= CALM_POOL:
			d = 0.0                                # calm: any calm bed fits as well as any other
		var w := exp(-d * d) + 0.03
		var tag: String = TRACKS[i].tag
		if tag != "":
			# tagged for whatever is nearest: pulled in as it closes; tagged for something else
			# (or nothing is near): pushed out in favour of the untagged/matching beds
			var mine := tag == near_key or (tag == "Statue" and STATUES.has(near_key))
			w *= (1.0 + ENTITY_PULL * near) if mine else (1.0 - 0.7 * near)
		if recent.has(i):
			w *= 0.05
		# gone unplayed a while: nudged back in so a long session cycles through all of TRACKS instead of
		# just the 2-3 closest in tension to whatever mood keeps coming up
		var since: float = _since_played.get(i, STARVED_AFTER)
		w *= 1.0 + STARVED_BONUS * clampf((since - STARVED_AFTER) / STARVED_AFTER, 0.0, 1.0)
		weights[i] = maxf(w, 0.001)
		total += weights[i]
	if total <= 0.0:
		return best
	var r := rng.randf() * total
	for i in weights:
		r -= weights[i]
		best = i
		if r <= 0.0:
			break
	return best

func _start(i: int, fade_in := FADE_IN) -> void:
	var s := _stream(i)
	if s == null:
		return
	for v in voices:
		if not v.dying:
			v.dying = true
			v.dying_t = 0.0
	var len := s.get_length()
	# Start part-way through so the bed doesn't always start on the same transient
	var from := rng.randf() * minf(len * 0.75, 45.0) if len > 12.0 else 0.0
	var p := AudioStreamPlayer.new()
	p.stream = s
	p.bus = "Ambience"
	p.volume_linear = 0.0
	add_child(p)
	p.play(from)
	var gain: float = TRACKS[i].gain * ClipLevels.gain(DIR + TRACKS[i].file, BED_RMS, -1.0)
	# Play duration: because tracks loop cleanly, each bed plays for an atmospheric duration
	var left := rng.randf_range(BED_MIN_PLAY, BED_MAX_PLAY)
	var fin := minf(fade_in, left * 0.25)
	var fout := minf(FADE_OUT, left * 0.25)
	voices.append({"p": p, "idx": i, "t": 0.0, "left": left, "gain": gain, "dying": false, "dying_t": 0.0,
		"fade_in": fin, "fade_out": fout,
		"dv": 1.0, "dv_to": 1.0, "dp": 1.0, "dp_to": 1.0, "drift_t": 0.0})
	recent.append(i)
	if recent.size() > 2:
		recent.pop_front()
	switch_cd = SWITCH_GAP
	_since_played[i] = 0.0
	phase = Phase.BED

func _statue_track() -> int:
	for i in TRACKS.size():
		if TRACKS[i].tag == "Statue":
			return i
	return -1

# The bed that is playing on: not crossfading out, not into its closing fade (null = nothing is)
func _current():
	var current = null
	for v in voices:
		if not v.dying and v.left - v.t > v.fade_out:
			current = v
	return current

func _silence_ok() -> bool:
	return tension < SILENCE_TENSION_MAX and near < SILENCE_NEAR_MAX and not Game.hunted and audio.outdoor_mix < 0.5

func _silence_share() -> float:
	var total := _bed_air + _silence_air
	return _silence_air / total if total > 1.0 else SILENCE_SHARE

# The less silence there has been lately, the likelier the next one
func _silence_chance() -> float:
	return clampf(0.5 + 1.5 * (SILENCE_SHARE - _silence_share()), 0.15, 0.9)

func _enter_silence(seconds: float) -> void:
	phase = Phase.SILENCE
	phase_left = seconds
	audio.hum_notice(0.35)                    # with the bed gone, the buzz comes back to the ear

# A bed has just ended: a long silence, or a short breath before the next one
func _after_bed() -> void:
	if _silence_ok() and rng.randf() < _silence_chance():
		_enter_silence(rng.randf_range(SILENCE_MIN, SILENCE_MAX))
	else:
		phase = Phase.BREATH
		phase_left = rng.randf_range(BREATH_MIN, BREATH_MAX) * (1.0 - 0.6 * tension)

func _schedule(dt: float) -> void:
	for i in _since_played:
		_since_played[i] += dt
	var keep := exp(-dt / AIR_MEMORY)
	_bed_air *= keep
	_silence_air *= keep
	if audio.outdoor_mix > 0.5:               # under the open sky: let the horror beds fade out and start no new one
		for v in voices:
			v.dying = true
		return
	switch_cd = maxf(0.0, switch_cd - dt)
	var current = _current()
	# a mannequin or the burnt is close: its bed comes on now, whatever was playing or however quiet it was
	var statue_near := STATUES.has(near_key) and near > STATUE_FORCE
	if statue_near:
		var statue := _statue_track()
		if statue >= 0 and (current == null or current.idx != statue) and _stream(statue) != null:
			_start(statue, KILL_FADE if current != null else FADE_IN_URGENT)
			current = _current()
	if current != null:
		_bed_air += dt
		# the mood has moved on from what is playing: crossfade to a better fit
		if not statue_near and current.t > 20.0 and switch_cd <= 0.0 and absf(tension - TRACKS[current.idx].tension) > 0.45:
			var i := _pick()
			if i >= 0:
				_start(i, KILL_FADE)
		return
	if phase == Phase.BED:
		_after_bed()
	if phase == Phase.SILENCE:
		_silence_air += dt
	# things turned tense: cut a silence short so a hunt never plays out in dead air
	var broken := phase == Phase.SILENCE and not _silence_ok()
	if broken:
		phase_left = 0.0
	phase_left -= dt * (1.0 + 6.0 * near)
	if phase_left > 0.0:
		return
	var next := _pick()
	if next >= 0:
		_start(next, FADE_IN_URGENT if broken else FADE_IN)
	else:
		phase = Phase.BREATH                  # nothing importable yet: try again shortly
		phase_left = 20.0

# ---------------------------------------------------------------- playback
func _update_voices(dt: float) -> void:
	if hush < 1.0 and Time.get_ticks_msec() / 1000.0 >= _hush_until:
		hush = 1.0
	var duck_target := 0.8 if Game.hunted else 1.0         # a little room for the entity's feet and voice
	if player.dead:
		duck_target = 0.0                                    # dead: the beds (their wind and air) drain away
	duck_target *= hush                                      # a whisper is taking the room: the bed steps back
	duck_target *= 1.0 - audio.outdoor_mix                   # the hills have their own bed (outdoor_audio.gd)
	duck += (duck_target - duck) * (1.0 - exp(-dt / (0.6 if duck_target < duck else 3.0)))
	var mood := (0.55 + 0.9 * tension) * (1.0 + NEAR_BOOST * near * near) * (1.0 + swell)
	var pitch: float = 1.0 - 0.05 * (1.0 - player.sanity / 100.0)   # the bed sags out of tune as you lose it
	pitch *= (1.0 - NEAR_PITCH * near) * (1.0 - sag)
	var strongest := 0.0
	var i := voices.size() - 1
	while i >= 0:
		var v: Dictionary = voices[i]
		var p: AudioStreamPlayer = v.p
		v.t += dt
		# squared both ways: it creeps in from nothing, and its tail lingers as it goes
		var fin := minf(1.0, v.t / v.fade_in) if v.fade_in > 0.0 else 1.0
		var fout := clampf((v.left - v.t) / v.fade_out, 0.0, 1.0) if v.fade_out > 0.0 else (0.0 if v.t >= v.left else 1.0)
		var fade := minf(fin * fin, fout * fout)
		if v.dying:
			v.dying_t += dt
			fade = minf(fade, maxf(0.0, 1.0 - v.dying_t / KILL_FADE))
		if (fade <= 0.0001 and v.t > 0.5) or not is_instance_valid(p):
			if is_instance_valid(p):
				p.queue_free()
			voices.remove_at(i)
		else:
			_drift(v, dt)
			p.volume_linear = fade * v.gain * v.dv * BASE * mood * duck * audio.vol.ambient
			p.pitch_scale = maxf(0.5, pitch * v.dp)
			strongest = maxf(strongest, fade)
		i -= 1
	audio.hum_user_target = 1.0 - 0.7 * strongest        # the synthesized hum sinks under a recorded bed

# Each bed wanders on its own: a new level / pitch goal every few seconds, eased into slowly
func _drift(v: Dictionary, dt: float) -> void:
	v.drift_t -= dt
	if v.drift_t <= 0.0:
		v.drift_t = 3.0 + rng.randf() * 6.0
		v.dv_to = rng.randf_range(0.55, 1.3)
		v.dp_to = rng.randf_range(0.94, 1.03) if rng.randf() < 0.8 else rng.randf_range(0.86, 0.94)
	var k := 1.0 - exp(-dt / 2.5)
	v.dv += (v.dv_to - v.dv) * k
	v.dp += (v.dp_to - v.dp) * k

# Sudden swells and pitch sags; both come more often the closer something is
func _update_moods(dt: float) -> void:
	swell_timer -= dt * (1.0 + 3.0 * near)
	if swell_timer <= 0.0:
		swell_timer = 10.0 + rng.randf() * 25.0
		swell = maxf(swell, rng.randf_range(0.4, 1.0) * (1.0 + near))
	swell *= exp(-dt / 1.8)
	sag_timer -= dt * (1.0 + 2.0 * near + 1.5 * tension)
	if sag_timer <= 0.0:
		sag_timer = 15.0 + rng.randf() * 30.0
		sag_target = rng.randf_range(0.04, 0.12)
	sag += (sag_target - sag) * (1.0 - exp(-dt / (1.2 if sag_target > sag else 3.0)))
	if sag_target > 0.0 and absf(sag - sag_target) < 0.005:
		sag_target = 0.0                     # hit the bottom: drift back into tune

# Nearest live threat, 0..1, cheaper walls-between check a few times a second
func _update_near(dt: float) -> void:
	near_timer -= dt
	if near_timer <= 0.0:
		near_timer = 0.2
		near_target = 0.0
		var closest_key := ""
		if not player.dead and Game.playing:
			var pp: Vector3 = player.global_position
			for key in NEAR_RANGE:
				var at = _threat_pos(_threats[key])
				if at == null:
					continue
				var d := pp.distance_to(at)
				var n := clampf(1.0 - d / NEAR_RANGE[key], 0.0, 1.0)
				if n > 0.0:
					n *= pow(0.75, mini(audio.walls_between(pp, at), 3))
				if n > near_target:
					near_target = n
					closest_key = key
		near_key = closest_key
	near += (near_target - near) * (1.0 - exp(-dt / (0.8 if near_target > near else 3.0)))

func _threat_pos(n: Node):
	if n == null or not is_instance_valid(n) or n.process_mode == Node.PROCESS_MODE_DISABLED:
		return null
	if n.name == "Mannequin":
		return n.real_node.global_position if n.awake and n.real_node != null else null
	if n.name == "Mimic":
		return n.body.global_position if n.spawned and n.body != null else null
	if n.name == "Burnt":
		return n.global_position if n.present and n.state != "off" else null
	return n.global_position

# Darker in tight corridors, at low sanity and in a blackout; a slow swell keeps it from sitting still
func _update_filter(dt: float) -> void:
	lfo += dt
	var open := maxf(clampf((audio.room_size - 0.15) / 0.6, 0.0, 1.0), audio.outdoor_mix)
	var target := lerpf(3500.0, 15000.0, open)
	var calm: float = 1.0 - clampf(Game.presence * 1.5, 0.0, 1.0)    # a chase drains sanity fast: don't muffle it
	target *= lerpf(1.0, 0.45, (1.0 - player.sanity / 100.0) * calm)
	target *= 1.0 + 0.12 * sin(lfo * 0.35)
	target = lerpf(target, maxf(target, 9000.0), near)     # it opens up as the thing closes in
	if player.grid_down:
		target = minf(target, 1400.0)
	if Game.hunted:
		target = maxf(target, 7000.0)
	cutoff += (target - cutoff) * (1.0 - exp(-dt / 1.0))
	if absf(lp.cutoff_hz - cutoff) > 20.0:                # only when it moves: re-setting resets the filter
		lp.cutoff_hz = cutoff

# ---------------------------------------------------------------- far-off events
func _update_events(dt: float) -> void:
	event_timer -= dt
	if event_timer > 0.0 or Game.outdoors:
		return
	event_timer = (30.0 + rng.randf() * 50.0) * (1.0 - 0.5 * tension)
	if Game.hunted or audio.paused or not Game.playing or player.dead:
		return
	var level := 0.7 if _current() != null else 1.0    # under a bed: kept back so the two don't crowd
	var nav = audio.grid()
	if nav == null:
		return
	var scares: Node = audio.get_parent().get_node("Scares")
	var pp: Vector3 = player.global_position
	for tries in 12:
		var a := rng.randf() * TAU
		var d := 22.0 + rng.randf() * 23.0
		var x := pp.x + sin(a) * d
		var z := pp.z + cos(a) * d
		if not nav.open_at(x, z):
			continue
		var at := Vector3(x, pp.y + 0.2, z)
		for k in 1 + rng.randi() % 3:
			get_tree().create_timer(k * (0.4 + rng.randf() * 0.15), false).timeout.connect(func():
				scares.play_scare("footThump", at, 0.5 * level))
		return

# ---------------------------------------------------------------- debug console (`amb`)
func status() -> String:
	var cur = _current()
	var bed := "-"
	var left := phase_left
	if cur != null:
		bed = TRACKS[cur.idx].file
		left = cur.left - cur.t
	return "%s, %ds left | bed %s | tension %.2f, near %.2f | silence share %d%% (aim %d%%)" % [
		Phase.keys()[phase], int(left), bed, tension, near, int(_silence_share() * 100.0), int(SILENCE_SHARE * 100.0)]

## Fade out whatever is playing and hold a silence for `seconds` (still broken by a threat closing in)
func force_silence(seconds: float) -> void:
	for v in voices:
		if not v.dying:
			v.dying = true
			v.dying_t = 0.0
	_enter_silence(seconds)

## Bring a bed in now; returns its file, or "" when none is importable
func force_bed() -> String:
	var i := _pick()
	if i < 0:
		return ""
	_start(i, FADE_IN_URGENT)
	return TRACKS[i].file

func _process(dt: float) -> void:
	if audio.paused:
		_update_voices(dt)
		return
	_update_near(dt)
	_update_moods(dt)
	tension += (_target_tension() - tension) * (1.0 - exp(-dt / 2.5))
	_update_filter(dt)
	_schedule(dt)
	_update_voices(dt)
	_update_events(dt)
