extends RefCounted
## Breathing model (js/audio/breathing.js): exertion, stamina debt, anxiety and terror decide when
## the player inhales and exhales, gasps on a startle, holds their breath when frozen, sighs when
## relieved. Pre-rendered breath clips are picked by length / mouth / shake and played on "Body".
## `loudness` is read back by the hum, which ducks while you are breathing hard.

const BREATH_VOLUME := 0.25          # AUDIO.breathVolume (reduced from 0.75 for less intrusive breathing)
const CALM_BREATH := 0.0             # AUDIO.calmBreathVolume
const BREATH_DURS := [0.22, 0.34, 0.5, 0.7, 0.9, 1.3, 1.6]
const BREATH_MOUTH := [0.0, 0.6, 1.0]

var audio: Node                      # the Audio node: player, vol, scales, stream(), child players

var breath_pool: Array[AudioStreamPlayer] = []
var queue: Array = []
var b_drive := 0.0
var b_debt := 0.0
var b_exertion := 0.0
var b_anxiety := 0.0
var b_terror := 0.0
var loudness := 0.0
var b_next := 0.0
var b_last := -1e9
var b_last_jitter := 1.0
var b_busy_until := 0.0
var b_voice_until := 0.0             # a recorded breath (hold_for) owns the lungs until then
var b_holding := false
var b_hold_time := 0.0
var b_hold_cd := 0.0
var b_calm_time := 10.0
var b_sigh_timer := 20.0
var b_was_exhausted := false
var b_adr_was := false

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func setup() -> void:
	for i in 8:
		var p := AudioStreamPlayer.new()
		p.bus = "Body"
		audio.add_child(p)
		breath_pool.append(p)

func clamp01(v: float) -> float:
	return clampf(v, 0.0, 1.0)

func smooth(a: float, b: float, v: float) -> float:
	var t := clamp01((v - a) / (b - a))
	return t * t * (3.0 - 2.0 * t)

func _approach(cur: float, target: float, up: float, down: float, dt: float) -> float:
	return cur + (target - cur) * minf(1.0, dt * (up if target > cur else down))

func update(dt: float) -> void:
	if Game.dead:          # the dead don't breathe: only what last_breath() queued still plays out
		loudness = 0.0
		return
	var sprinting: bool = audio.player.is_sprinting
	var exhausted: bool = audio.player.exhausted
	var moving: bool = audio.player.is_moving
	var crouching: bool = audio.player.is_crouching
	var terror: float = 0.0 if Game.dead else Game.terror     # entity proximity (entity.update_fear)
	var anxiety: float = 1.0 - audio.player.sanity / 100.0

	b_drive = _approach(b_drive, 1.0 if sprinting else 0.0, 2.5, 0.6, dt)
	var stamina_debt: float = 1.0 if exhausted else 1.0 - audio.player.stamina / 100.0
	b_debt = _approach(b_debt, stamina_debt, 1.2, 0.09, dt)
	var e := clamp01(0.3 * b_drive + 0.8 * b_debt)
	if moving: e = maxf(e, 0.05)
	# adrenaline: stamina is free but the lungs aren't - hard, fast, open-mouthed panting
	var adr: float = audio.player.adrenaline
	e = maxf(e, adr * (0.85 if moving else 0.6))
	b_exertion = e

	var raw_terror := clamp01(terror)
	b_terror = _approach(b_terror, raw_terror, 4.0, 1.2, dt)
	b_anxiety = _approach(b_anxiety, clamp01(anxiety), 0.5, 0.25, dt)

	if b_was_exhausted and not exhausted and not audio.player.adr_active: sigh()
	# the rush hits: one sharp gasp, and no holding your breath while it lasts
	var adr_on: bool = audio.player.adr_active
	if adr_on and not b_adr_was:
		b_holding = false
		gasp(1.0)
	b_adr_was = adr_on
	b_was_exhausted = exhausted

	# startle: entity first comes into range after a quiet spell
	if raw_terror <= 0.0: b_calm_time += dt
	else:
		if b_calm_time > 6.0: gasp(0.75)
		b_calm_time = 0.0
	# freeze response
	b_hold_cd = maxf(0.0, b_hold_cd - dt)
	var still := (not moving) or crouching
	if not b_holding:
		if b_terror > 0.45 and still and not sprinting and b_exertion < 0.6 and b_hold_cd == 0.0 and not adr_on:
			b_holding = true
			b_hold_time = (4.0 if crouching else 2.5) + randf() * 2.5
	else:
		b_hold_time -= dt
		if sprinting:
			b_holding = false; b_hold_cd = 5.0; gasp(0.7)
		elif b_terror < 0.25:
			b_holding = false; b_hold_cd = 5.0; sigh(0.5, 0.5)
		elif b_hold_time <= 0.0:
			b_holding = false; b_hold_cd = 7.0; gasp(0.85)
	# spontaneous sighs
	b_sigh_timer -= dt
	if b_sigh_timer <= 0.0:
		var a := _arousal()
		b_sigh_timer = (40.0 - 25.0 * a) * (0.7 + randf() * 0.6)
		if a > 0.2 and b_exertion < 0.45 and not b_holding: sigh(0.3 + 0.2 * a, a)

	var arousal := _arousal()
	var active := e > 0.08 or arousal > 0.15
	# Reduced multipliers: 0.9 -> 0.6 for exertion, 0.35 -> 0.2 for arousal
	var loud := clamp01(smooth(0.08, 1.0, e) * 0.6 + arousal * 0.2) if active else CALM_BREATH
	# Cap the loudness to prevent breathing from getting too loud during high exertion/panic
	loud = minf(loud, 0.5)
	if b_holding: loud = 0.0
	loudness = loud
	_schedule(loud)

func _arousal() -> float:
	return maxf(b_terror, b_anxiety * 0.55)

func _schedule(loud: float) -> void:
	var t_now := _now()
	if b_next < t_now: b_next = t_now + 0.05
	if b_holding:
		b_next = maxf(t_now + 0.3, b_busy_until + 0.08)
		return
	if loud <= 0.01:
		b_next = maxf(t_now + 0.1, b_busy_until + 0.08)
		return
	var e := b_exertion
	var a := _arousal()
	var t0 := b_terror
	var bpm := 13.0 + 32.0 * e + 14.0 * a * (1.0 - e)
	var period := 60.0 / bpm
	var due := b_last + period * b_last_jitter
	b_next = maxf(t_now + 0.05, maxf(b_busy_until + 0.08, minf(b_next, due)))
	while b_next < t_now + 0.12:
		var t := b_next
		var spread := 0.06 + 0.22 * a * (1.0 - e)
		var jitter := 1.0 + (randf() * 2.0 - 1.0) * spread
		var inhale := period * (0.3 + 0.15 * e + 0.05 * a) * jitter
		var exhale := period * (0.45 + 0.07 * e - 0.05 * a) * jitter
		var mouth := smooth(0.3, 0.65, maxf(e, t0 * 0.8))
		var shake := maxf(smooth(0.3, 0.8, t0) * 0.6, smooth(0.5, 1.0, b_anxiety) * 0.25)
		var depth := (1.0 - 0.25 * a * (1.0 - e)) * (0.9 + randf() * 0.2)
		var ragged := smooth(0.8, 1.0, e)
		if randf() < ragged * 0.35:
			_phase(t, inhale * 0.45, true, loud * 0.7 * depth, mouth, shake)
			_phase(t + inhale * 0.55, inhale * 0.45, true, loud * 0.8 * depth, mouth, shake)
		else:
			_phase(t, inhale, true, loud * 0.7 * depth, mouth, shake)
		_phase(t + inhale + 0.03, exhale, false, loud * depth, mouth, shake, smooth(0.75, 1.0, e))
		b_last = t
		b_last_jitter = jitter
		b_busy_until = t + inhale + 0.03 + exhale
		b_next = t + period * jitter

func gasp(strength := 1.0) -> void:
	if _now() < b_voice_until:
		return                     # a recorded gasp is this breath already: never a second one over it
	var t := _now() + 0.01
	_phase(t, 0.34, true, strength, 1.0, 0.25)
	_phase(t + 0.4, 0.7, false, strength * 0.7, 0.8, 0.4)
	b_last = t + 0.4
	b_last_jitter = 1.0
	b_busy_until = t + 1.1
	b_next = t + 1.2

## A recorded breath (the startle gasp, scares.gd) is playing for `seconds`: drop what was queued and
## pick the rhythm up again after it, instead of breathing, or gasping again, on top of it
func hold_for(seconds: float) -> void:
	queue.clear()
	var t := _now() + seconds
	b_voice_until = maxf(b_voice_until, t)
	b_busy_until = maxf(b_busy_until, t)
	b_next = maxf(b_next, t + 0.15)
	b_last = t
	b_last_jitter = 1.0
	b_calm_time = 0.0               # the fright is heard: no second startle gasp for it

# The last breath as you go down: one long, shaking, voiced exhale, and nothing after it
func last_breath() -> void:
	queue.clear()
	var t := _now() + 0.2
	_phase(t, 1.7, false, 0.6, 0.55, 0.5, 0.8)
	b_busy_until = t + 1.7
	b_next = t + 1.8

func sigh(strength := 0.45, shake := 0.0) -> void:
	var t := maxf(_now() + 0.01, b_busy_until + 0.1)
	_phase(t, 0.8, true, strength * 0.6, 0.3, 0.1 + shake * 0.2)
	_phase(t + 0.85, 1.6, false, strength, 0.5, 0.15 + shake * 0.3)
	b_last = t + 1.3
	b_last_jitter = 1.0
	b_busy_until = t + 2.45
	b_next = t + 2.8

func _nearest(arr: Array, v: float) -> int:
	var best := 0
	for i in arr.size():
		if absf(arr[i] - v) < absf(arr[best] - v): best = i
	return best

func _phase(t: float, dur: float, inhale: bool, amp: float, mouth: float, shake: float, voiced := 0.0) -> void:
	queue.append({"t": t, "dur": dur, "inhale": inhale, "amp": amp, "mouth": mouth, "shake": shake, "voiced": voiced})

func play_queue() -> void:
	var t_now := _now()
	var i := 0
	while i < queue.size():
		var q: Dictionary = queue[i]
		if q.t > t_now:
			i += 1
			continue
		queue.remove_at(i)
		if t_now - q.t > 0.4: continue          # stale (game was paused)
		var di := _nearest(BREATH_DURS, q.dur)
		var mi := _nearest(BREATH_MOUTH, q.mouth)
		var si := 1 if q.shake > 0.2 else 0
		var file: String
		if q.inhale: file = "breath_in_%d_%d_%d.wav" % [mi, di, si]
		elif q.voiced > 0.3: file = "breath_outv_%d.wav" % di
		else: file = "breath_out_%d_%d_%d.wav" % [mi, di, si]
		var pitch := clampf(BREATH_DURS[di] / maxf(0.05, q.dur), 0.7, 1.4)
		for p in breath_pool:
			if not p.playing:
				p.stream = audio.stream(file)
				p.volume_linear = q.amp * BREATH_VOLUME * audio.vol.breathing / float(audio.scales.get(file, 1.0))
				p.pitch_scale = pitch
				p.play()
				break
