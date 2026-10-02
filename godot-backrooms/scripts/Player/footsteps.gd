extends Node
## Your footfalls (sfx.js footstep). A recorded carpet take drawn from a shuffle bag (every take once before
## any comes round again, never the same one twice running), with level / pitch variation, plus a synthesized
## heel knock under it for weight (the recorded scuffs are all top end), itself one of several takes.
## Underfoot is read with a ray: a stairwell's solids carry their style ("concrete" or "carpet", props/stairs.gd),
## and elsewhere the level's "tiles" zones are waxed tile. On tile the heel is a hard tick and the scuff lighter
## and brighter; on concrete a gritty knock under a dry, thin scuff; both carry further (noise() is read by the
## entity's hearing). Recorded takes dropped in audio/footsteps/tile|concrete/ replace the borrowed carpet scuffs.
## `pace` (0 walk .. 1 full sprint, from your real speed) makes faster steps louder and heavier.
## Outdoors (Game.outdoors, the hills level) the surface comes from the terrain: recorded grass steps on
## the meadow, gravel / sand on the road and steep slopes, no heel knock, and the level scales to each set.
## Crouching is quieter and darker (the Steps bus low-pass). Child of the player.

const ScareSynth := preload("res://scripts/Audio/scares/scare_synth.gd")
const MIN_GAP := 0.18                  # seconds: never two steps closer than this
const TILE_NOISE := 1.35               # a step on tile is heard this much further off
const CONCRETE_NOISE := 1.3
const HEEL_TAKES := 4
const GAIN := 0.55                     # over every step: the level of the whole set

## A shuffle bag: hands out every item once, in a random order, then reshuffles; never the same item twice
## running, not even across a reshuffle
class Bag:
	var items: Array
	var order: Array = []
	var last := -1

	func _init(list: Array) -> void:
		items = list

	func next() -> Variant:
		if order.is_empty():
			order = range(items.size())
			order.shuffle()
			if order.size() > 1 and order.back() == last:
				order[-1] = order[0]                  # pop_back takes the last: keep it off the one just played
				order[0] = last
		last = order.pop_back()
		return items[last]

var player: Node3D
var walk: Bag
var sprint: Bag
var scuff: AudioStreamPlayer
var under: AudioStreamPlayer           # a second, different take laid under the first, so no two steps share a sound
var heel: AudioStreamPlayer
var heels := {}                        # surface -> Bag of synth heel takes
var recorded := {}                     # "tile" / "concrete" -> Bag of recorded takes, when there are any
var last_time := -10.0
var foot := 1.0                        # which foot lands next (-1 left, 1 right)
var outdoor := {}                      # surface -> Bag of [AudioStream, gain]: built on the first outdoor step
var surface := "carpet"
const OUTDOOR_LEVEL := {"grass": 0.11, "dirt": 0.3}       # measured: matches the carpet steps' loudness, a touch louder in open air
const OUTDOOR_NOISE := {"grass": 0.75, "dirt": 1.0}       # a step on soft grass carries less far
const SAND_TRIM := 1.32                                   # the sand clips are 2.4 dB quieter than the gravel ones
# per indoor surface: scuff level, scuff pitch, heel weight
const SURFACE := {
	"carpet": [1.0, 1.0, 1.0],
	"tile": [0.55, 1.1, 1.8],
	"concrete": [0.45, 1.12, 1.9],
}

func _ready() -> void:
	player = get_parent()
	var w := []
	var s := []
	for i in range(1, 5):
		w.append(load("res://audio/carpet_walk_%d.wav" % i))
		s.append(load("res://audio/carpet_sprint_%d.wav" % i))
	walk = Bag.new(w)
	sprint = Bag.new(s)
	scuff = _voice()
	under = _voice()
	heel = _voice()
	var synth := ScareSynth.new()
	for kind: Array in [["carpet", "heel"], ["tile", "tile_step"], ["concrete", "concrete_step"]]:
		var takes := []
		for i in HEEL_TAKES:
			takes.append(synth.render(kind[1], i))
		heels[kind[0]] = Bag.new(takes)
	for set_name: String in ["tile", "concrete"]:
		var clips := []
		while ResourceLoader.exists("res://audio/footsteps/%s/%s_%d.ogg" % [set_name, set_name, clips.size()]):
			clips.append(load("res://audio/footsteps/%s/%s_%d.ogg" % [set_name, set_name, clips.size()]))
		if not clips.is_empty():
			recorded[set_name] = Bag.new(clips)

func _voice() -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = "Steps"
	add_child(p)
	return p

## What is underfoot here: a stairwell solid says what it is made of; otherwise tile in the level's "tiles"
## zones, carpet everywhere else
func _surface_under() -> String:
	var p := player.global_position
	var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 0.2, p + Vector3.DOWN * 0.6)
	if player is CollisionObject3D:
		q.exclude = [(player as CollisionObject3D).get_rid()]
	var hit := player.get_world_3d().direct_space_state.intersect_ray(q)
	var body = hit.get("collider")
	if body is CollisionObject3D:
		var owner_node = body.shape_owner_get_owner(body.shape_find_owner(hit["shape"]))
		if owner_node is Node and owner_node.has_meta("surface"):
			var s := str(owner_node.get_meta("surface"))
			if SURFACE.has(s):
				return s
	var lvl = Game.level
	if lvl != null and is_instance_valid(lvl) and lvl.tiles.has(Vector2i(roundi(p.x / lvl.CELL), roundi(p.z / lvl.CELL))):
		return "tile"
	return "carpet"

## How far your steps carry right now (x the entity's hearing radius)
func noise() -> float:
	match surface:
		"carpet": return 1.0
		"tile": return TILE_NOISE
		"concrete": return CONCRETE_NOISE
	return OUTDOOR_NOISE[surface]

func _load_outdoor() -> void:
	var grass := []
	for i in 9:
		grass.append([load("res://audio/footsteps/grass/grass_%d.ogg" % i), 1.0])
	var dirt := []
	for i in 10:
		dirt.append([load("res://audio/footsteps/dirt/gravel_%d.ogg" % i), 1.0])
	for f in ["SandL1", "SandL2", "SandL3", "SandR1", "SandR2", "SandR3"]:
		dirt.append([load("res://audio/footsteps/dirt/sand_%s.ogg" % f), SAND_TRIM])
	outdoor = {"grass": Bag.new(grass), "dirt": Bag.new(dirt)}

## An outdoor footfall: one recorded take from the surface's bag, slight level / pitch wobble
func _outdoor_step(crouching: bool, intensity: float, pace: float) -> void:
	if outdoor.is_empty():
		_load_outdoor()
	var hills := get_tree().get_first_node_in_group("hills")
	surface = hills.surface_at(player.global_position.x, player.global_position.z) if hills != null else "grass"
	var take: Array = outdoor[surface].next()
	var mult := 0.15 if crouching else lerpf(0.4, 0.65, pace)
	foot = -foot
	var side := 0.97 if foot < 0.0 else 1.03
	scuff.stream = take[0]
	scuff.volume_linear = OUTDOOR_LEVEL[surface] * take[1] * mult * randf_range(0.75, 1.1) * intensity * GAIN
	scuff.pitch_scale = (0.94 if crouching else 1.0) * randf_range(0.9, 1.1) * side * lerpf(1.0, 1.06, pace)
	var other: Array = outdoor[surface].next()
	_layer(other[0], scuff.volume_linear * other[1] / take[1], scuff.pitch_scale)
	_bus(crouching)
	scuff.play()

## The take under the main one: quieter by a different amount each step, at its own pitch, a moment late
func _layer(stream: AudioStream, level: float, pitch: float) -> void:
	under.stream = stream
	under.volume_linear = level * randf_range(0.25, 0.6)
	under.pitch_scale = pitch * randf_range(0.86, 1.16)
	var late := randf_range(0.0, 0.035)
	if late < 0.006:
		under.play()
	else:
		get_tree().create_timer(late).timeout.connect(under.play)

## The other side of the step: which foot, for the panning, and the crouch muffle
func _bus(crouching: bool) -> void:
	var au := player.get_parent().get_node_or_null("Audio")
	if au != null:
		au.step_foot(foot)
		var want := 2500.0 if crouching else 12000.0
		if au.steps_lp and au.steps_lp.cutoff_hz != want:
			au.steps_lp.cutoff_hz = want        # only on change: re-setting it clicks

## `pace`: 0 walking .. 1 full sprint, from your real speed (-1: just from `sprinting`)
func step(sprinting: bool, crouching: bool, intensity: float, pace := -1.0) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if now - last_time < MIN_GAP:
		return
	last_time = now
	if pace < 0.0:
		pace = 1.0 if sprinting else 0.0
	if crouching:
		pace = 0.0
	if Game.outdoors:
		_outdoor_step(crouching, intensity, pace)
		return
	surface = _surface_under()
	var feel: Array = SURFACE[surface]
	var level := 0.015 if crouching else lerpf(0.05, 0.09, pace)
	foot = -foot
	var side := 0.97 if foot < 0.0 else 1.03               # the two feet never land alike
	var pitch: float = (0.92 if crouching else 1.0) * randf_range(0.9, 1.1) * side * lerpf(1.0, 0.97, pace)
	var loud: float = level * randf_range(0.75, 1.1) * intensity * GAIN
	if recorded.has(surface):
		scuff.stream = recorded[surface].next()
		scuff.volume_linear = loud
		scuff.pitch_scale = pitch
		_layer(recorded[surface].next(), loud, pitch)
	else:
		# the other set's take goes underneath: a walking take under a running one and the other way round
		scuff.stream = (sprint if sprinting else walk).next()
		scuff.volume_linear = loud * feel[0]
		scuff.pitch_scale = pitch * feel[1]
		_layer((walk if sprinting else sprint).next(), loud * feel[0], pitch * feel[1])
	# the knock underneath: deeper and heavier the faster you go, hardly any creeping, and never the same share of the step
	var weight: float = (0.15 if crouching else lerpf(0.32, 0.6, pace)) * feel[2] * randf_range(0.6, 1.25)
	heel.stream = heels[surface].next()
	heel.volume_linear = level * weight * randf_range(0.8, 1.1) * intensity * GAIN
	heel.pitch_scale = randf_range(0.9, 1.1) * (0.96 if foot < 0.0 else 1.02) * lerpf(1.0, 0.86, pace)
	_bus(crouching)
	scuff.play()
	heel.play()
