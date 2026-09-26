extends Node
## THE HEART. One system that owns the player's heartbeat, so every threat in the game speaks to the
## same pulse instead of each running its own beat timer.
##
## Anything that frightens you calls `Game.heart.feed("name", level)` every frame it is doing it
## (level 0..1, "how scared should this make me right now"). The heart also feels the player's own
## body: adrenaline, sprinting, low sanity, event fear.
##
##  - stress is the smoothed result: it jumps up fast when something new appears, and only bleeds away
##    slowly once it is gone, so a scare leaves you thumping for a while
##  - bpm follows stress (62 resting .. 168 terrified); the beat is scheduled here, on a phase clock
##  - a sudden new threat gives one hard jolt beat straight away
##  - past ~55% stress the rhythm stutters now and then with an extra soft beat
##  - it stays silent unless you are really scared (stress over 50%, until it drops under 38%), and stands down while something has hold of you (the grab and the
##    mannequin's snap script their own heartbeat and flatline)
##
## Console: `heart` shows it, `heart 0.8` forces a stress level, `heart off` releases it.

const REST_BPM := 62.0
const MAX_BPM := 150.0
const AUDIBLE_ON := 0.5             # you only hear your heart once you are really scared...
const AUDIBLE_OFF := 0.38           # ...and it stays audible until you have properly calmed
const RISE := 1.6                   # how fast stress climbs toward a higher target (per second, exponential)
const FALL := 0.07                  # how fast it bleeds away once the threat is gone (per second)
const JOLT_STEP := 0.25             # a target jumping this much at once is a startle
const FLUTTER_AT := 0.55
const FLUTTER_CHANCE := 0.07
const HABITUATE := 25.0             # seconds of sustained fear before the beat has ducked all the way
const HABITUATE_DUCK := 0.55        # ...and how much quieter it is by then: a heart you stop noticing, not one that spams
const CALM_RECOVER := 10.0          # seconds of calm to hear it clearly again
const SELF_CALM_TIME := 7.0         # seconds for you to talk yourself down from a threat that is not getting worse
const MAX_CALM := 0.6               # how much of a steady threat's fear you can shake off
const ESCALATE := 0.05              # the threat getting this much worse restores the fear (it moved, it came closer)
const ESCALATE_RESTORE := 3.0       # ...by this many times the size of the jump
const NEW_THREAT_GAP := 2.0         # out of your life this long and the next sighting hits fresh
const FRESH := 0.3                  # a source not fed for this long has stopped

var player: CharacterBody3D
var scares: Node
var rng := RandomNumberGenerator.new()

var sources := {}                   # name -> {level, t}
var clock := 0.0
var stress := 0.0
var bpm := REST_BPM
var phase := 0.0
var last_target := 0.0
var audible := false
var fatigue := 0.0                  # 0..1 how used to the pounding your ears have got
var debug_stress := -1.0            # >= 0 overrides everything (console)

func _ready() -> void:
	rng.randomize()
	player = get_parent().get_node("Player")
	scares = get_parent().get_node("Scares")
	Game.heart = self

# `drain`: sanity lost per second while this source is being fed (standing close to something wrong)
func feed(source: String, level: float, drain := 0.0) -> void:
	var s: Dictionary = sources.get(source, {})
	var fresh: bool = s.is_empty() or clock - s.t > NEW_THREAT_GAP
	sources[source] = {"level": clampf(level, 0.0, 1.0), "t": clock, "drain": drain,
		"calm": 0.0 if fresh else s.calm, "peak": 0.0 if fresh else s.peak}

# You get used to a threat that just stays there: the first sight spikes your heart, then, if it is
# no worse, you steady your breathing and the fear settles to a fraction. If it gets worse (closer,
# leans out, bolts) the fear comes straight back, in proportion to how much worse.
func _settle(delta: float) -> void:
	for k in sources.keys():
		var s: Dictionary = sources[k]
		if clock - s.t > FRESH:
			continue
		if s.level > s.peak + ESCALATE:
			s.calm = maxf(0.0, s.calm - (s.level - s.peak) * ESCALATE_RESTORE)
			s.peak = s.level
		else:
			s.calm = minf(MAX_CALM, s.calm + delta * MAX_CALM / SELF_CALM_TIME)
			s.peak = minf(s.peak, s.level)      # it eased off: the new baseline

# What the body alone is doing, plus every fresh source, blended so two threats are worse than one
func _target() -> float:
	if debug_stress >= 0.0:
		return debug_stress
	var t := 0.0
	for k in sources.keys():
		var s: Dictionary = sources[k]
		if clock - s.t > FRESH:
			continue
		t = 1.0 - (1.0 - t) * (1.0 - s.level * (1.0 - s.calm))
	var body: float = player.adrenaline * 0.7
	if player.is_sprinting:
		body = maxf(body, 0.15)
	body = maxf(body, (1.0 - player.sanity / 100.0) * 0.25)
	body = maxf(body, Game.event_fear * 0.5)
	return 1.0 - (1.0 - t) * (1.0 - body)

func _process(delta: float) -> void:
	if not Game.playing or Game.dead or player.dead:
		return
	clock += delta
	if player.frozen:
		phase = 0.0                 # a scripted sequence owns the heart right now
		return
	var drain := 0.0
	for k in sources.keys():
		var s: Dictionary = sources[k]
		if clock - s.t <= FRESH:
			drain += s.drain
	if drain > 0.0:
		player.sanity = maxf(0.0, player.sanity - drain * delta)
	_settle(delta)
	var target := _target()
	if target - last_target > JOLT_STEP and target > 0.3:
		stress = maxf(stress, target * 0.8)
		if target >= AUDIBLE_ON:
			_beat(1.3)                # only a real fright makes the heart heard
		phase = 0.0
	last_target = target
	if target > stress:
		stress += (target - stress) * minf(1.0, delta * RISE)
	else:
		stress = maxf(target, stress - (FALL + (stress - target) * 0.3) * delta)   # settles toward it, not a cliff
	fatigue = clampf(fatigue + (delta / HABITUATE if stress > 0.5 else -delta / CALM_RECOVER), 0.0, 1.0)
	bpm = lerpf(bpm, lerpf(REST_BPM, MAX_BPM, pow(stress, 0.8)), minf(1.0, delta * 2.0))
	if audible and stress < AUDIBLE_OFF:
		audible = false
	elif not audible and stress >= AUDIBLE_ON:
		audible = true
	phase += delta * bpm / 60.0
	if phase >= 1.0:
		phase -= 1.0
		if audible:
			_beat(1.0 - HABITUATE_DUCK * fatigue)
			if stress > FLUTTER_AT and rng.randf() < FLUTTER_CHANCE:
				get_tree().create_timer(0.17, false).timeout.connect(_beat.bind(0.55 * (1.0 - HABITUATE_DUCK * fatigue)))

func _beat(weight: float) -> void:
	scares.heartbeat((0.3 + 0.9 * stress) * weight, 1.0 + 0.06 * stress)

func describe() -> String:
	return "stress %.2f  bpm %d  %s" % [stress, int(bpm), "(forced)" if debug_stress >= 0.0 else ""]
