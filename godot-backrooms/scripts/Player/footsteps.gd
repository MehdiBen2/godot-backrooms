extends Node
## Your footfalls (sfx.js footstep). A recorded carpet take, never the same one twice running, with
## slight level / pitch variation, plus a synthesized heel knock under it for weight (the recorded
## scuffs are all top end). On the waxed tile rooms the heel is a hard tick instead and the scuff is
## lighter and brighter, and every step carries further (noise() is read by the entity's hearing).
## Outdoors (Game.outdoors, the hills level) the surface comes from the terrain: recorded grass steps on
## the meadow, gravel / sand on the road and steep slopes, no heel knock, and the level scales to each set.
## Crouching is quieter and darker (the Steps bus low-pass). Child of the player.

const ScareSynth := preload("res://scripts/Audio/scares/scare_synth.gd")
const MIN_GAP := 0.18                  # seconds: never two steps closer than this
const TILE_NOISE := 1.35               # a step on tile is heard this much further off

var player: Node3D
var walk: Array[AudioStream] = []
var sprint: Array[AudioStream] = []
var scuff: AudioStreamPlayer
var heel: AudioStreamPlayer
var heel_carpet: AudioStream
var heel_tile: AudioStream
var last_idx := -1
var last_time := -10.0
var foot := 1.0                        # which foot lands next (-1 left, 1 right)
var on_tile := false
var outdoor := {}                      # surface -> Array of [AudioStream, gain]: built on the first outdoor step
var surface := "carpet"
const OUTDOOR_LEVEL := {"grass": 0.11, "dirt": 0.3}       # measured: matches the carpet steps' loudness, a touch louder in open air
const OUTDOOR_NOISE := {"grass": 0.75, "dirt": 1.0}       # a step on soft grass carries less far
const SAND_TRIM := 1.32                                   # the sand clips are 2.4 dB quieter than the gravel ones

func _ready() -> void:
	player = get_parent()
	for i in range(1, 5):
		walk.append(load("res://audio/carpet_walk_%d.wav" % i))
		sprint.append(load("res://audio/carpet_sprint_%d.wav" % i))
	scuff = _voice()
	heel = _voice()
	var synth := ScareSynth.new()
	heel_carpet = synth.render("heel")
	heel_tile = synth.render("tile_step")

func _voice() -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = "Steps"
	add_child(p)
	return p

## What is underfoot here: tile in the level's "tiles" zones, carpet everywhere else
func _tile_under() -> bool:
	var lvl = Game.level
	if lvl == null or not is_instance_valid(lvl):
		return false
	var p := player.global_position
	return lvl.tiles.has(Vector2i(roundi(p.x / lvl.CELL), roundi(p.z / lvl.CELL)))

## How far your steps carry right now (x the entity's hearing radius)
func noise() -> float:
	if surface != "carpet":
		return OUTDOOR_NOISE[surface]
	return TILE_NOISE if on_tile else 1.0

func _load_outdoor() -> void:
	var grass := []
	for i in 9:
		grass.append([load("res://audio/footsteps/grass/grass_%d.ogg" % i), 1.0])
	var dirt := []
	for i in 10:
		dirt.append([load("res://audio/footsteps/dirt/gravel_%d.ogg" % i), 1.0])
	for f in ["SandL1", "SandL2", "SandL3", "SandR1", "SandR2", "SandR3"]:
		dirt.append([load("res://audio/footsteps/dirt/sand_%s.ogg" % f), SAND_TRIM])
	outdoor = {"grass": grass, "dirt": dirt}

## An outdoor footfall: one recorded take, never the same twice running, slight level / pitch wobble
func _outdoor_step(sprinting: bool, crouching: bool, intensity: float) -> void:
	if outdoor.is_empty():
		_load_outdoor()
	var hills := get_tree().get_first_node_in_group("hills")
	surface = hills.surface_at(player.global_position.x, player.global_position.z) if hills != null else "grass"
	var list: Array = outdoor[surface]
	var idx := randi() % list.size()
	while idx == last_idx and list.size() > 1:
		idx = randi() % list.size()
	last_idx = idx
	var mult := 0.4 if crouching else (1.45 if sprinting else 1.0)
	scuff.stream = list[idx][0]
	scuff.volume_linear = OUTDOOR_LEVEL[surface] * list[idx][1] * mult * randf_range(0.85, 1.1) * intensity
	scuff.pitch_scale = (0.94 if crouching else 1.0) * randf_range(0.94, 1.06) * (1.06 if sprinting else 1.0)
	foot = -foot
	var au := player.get_parent().get_node_or_null("Audio")
	if au != null:
		au.step_foot(foot)
		var want := 2500.0 if crouching else 12000.0
		if au.steps_lp and au.steps_lp.cutoff_hz != want:
			au.steps_lp.cutoff_hz = want
	scuff.play()

func step(sprinting: bool, crouching: bool, intensity: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if now - last_time < MIN_GAP:
		return
	last_time = now
	if Game.outdoors:
		_outdoor_step(sprinting, crouching, intensity)
		return
	surface = "carpet"
	on_tile = _tile_under()
	var list := sprint if sprinting else walk
	var idx := randi() % list.size()
	while idx == last_idx and list.size() > 1:
		idx = randi() % list.size()
	last_idx = idx
	var level := 0.05 if crouching else (0.2 if sprinting else 0.14)
	scuff.stream = list[idx]
	scuff.volume_linear = level * randf_range(0.85, 1.1) * intensity * (0.55 if on_tile else 1.0)
	scuff.pitch_scale = (0.92 if crouching else 1.0) * randf_range(0.96, 1.04) * (1.1 if on_tile else 1.0)
	# the knock underneath: more of it when you run, hardly any creeping; the two feet never land alike
	foot = -foot
	var weight := 0.45 if sprinting else (0.15 if crouching else 0.32)
	if on_tile:
		weight *= 1.8
	heel.stream = heel_tile if on_tile else heel_carpet
	heel.volume_linear = level * weight * randf_range(0.8, 1.1) * intensity
	heel.pitch_scale = randf_range(0.9, 1.1) * (0.96 if foot < 0.0 else 1.02) * (0.9 if sprinting else 1.0)
	var au := player.get_parent().get_node_or_null("Audio")
	if au != null:
		au.step_foot(foot)
		var want := 2500.0 if crouching else 12000.0
		if au.steps_lp and au.steps_lp.cutoff_hz != want:
			au.steps_lp.cutoff_hz = want        # only on change: re-setting it clicks
	scuff.play()
	heel.play()
