extends RefCounted
## The preacher whisper (js/audio/scares2.js): one recording, six ways of hearing it, each its own
## effect chain on the "Preacher" bus. Owned by scares.gd; update() drives the glitch variant.

const PATH := "res://audio/events/preacher.mp3"
const NAMES := [
	"Distant Corridor Echo", "Deep Sub-Bass Alternate", "Corrupted Radio / EVP",
	"Cavernous Hallway Delay", "Glitch Tremolo & Flickering Apparatus", "Approaching Corridor Stalker",
]

var scares: Node
var rng := RandomNumberGenerator.new()
var glitchers: Array = []                    # [player, next_toggle, base_db]

func _init(owner: Node) -> void:
	scares = owner
	rng.randomize()

func _bus(variant: int) -> void:
	var idx := AudioServer.get_bus_index("Preacher")
	while AudioServer.get_bus_effect_count(idx) > 0:
		AudioServer.remove_bus_effect(idx, 0)
	var lp := AudioEffectLowPassFilter.new()
	var hp := AudioEffectHighPassFilter.new()
	var rev := AudioEffectReverb.new()
	var chain: Array = []
	match variant:
		0:
			lp.cutoff_hz = 3500.0
			rev.room_size = 0.8; rev.wet = 0.5
			chain = [lp, rev]
		1:
			lp.cutoff_hz = 900.0
			rev.room_size = 0.6; rev.wet = 0.3
			chain = [lp, rev]
		2:
			hp.cutoff_hz = 600.0; lp.cutoff_hz = 3200.0
			var dist := AudioEffectDistortion.new()
			dist.mode = AudioEffectDistortion.MODE_CLIP
			dist.drive = 0.35
			chain = [hp, lp, dist]
		3:
			var delay := AudioEffectDelay.new()
			delay.tap1_active = true; delay.tap1_delay_ms = 380.0; delay.tap1_level_db = -6.0
			delay.tap2_active = true; delay.tap2_delay_ms = 760.0; delay.tap2_level_db = -12.0
			rev.room_size = 1.0; rev.wet = 0.6
			chain = [delay, rev]
		4:
			hp.cutoff_hz = 300.0; lp.cutoff_hz = 4500.0
			chain = [hp, lp]
		_:
			lp.cutoff_hz = 6000.0
			rev.room_size = 0.3; rev.wet = 0.15
			chain = [lp, rev]
	for fx in chain:
		AudioServer.add_bus_effect(idx, fx)

func play(pos: Vector3, variant: int, end_pos: Vector3, glide: float, volume := 1.0) -> void:
	_bus(variant)
	var gain := 1.5 * volume * (1.6 if variant == 1 else 1.0)
	var p: AudioStreamPlayer3D = scares.spawn3d(preload("res://scripts/Audio/sfx_pool.gd").get_stream(PATH), pos, gain, "Preacher", 7.0)
	if end_pos != pos and glide > 0.0:
		p.create_tween().tween_property(p, "global_position", end_pos, glide)
	if variant == 4:
		glitchers.append([p, 0.1, p.volume_db])

# The glitch variant: the level stutters like a failing circuit
func update(dt: float) -> void:
	for i in range(glitchers.size() - 1, -1, -1):
		var g: Array = glitchers[i]
		if not is_instance_valid(g[0]):
			glitchers.remove_at(i)
			continue
		var p: AudioStreamPlayer3D = g[0]
		if not p.playing:
			glitchers.remove_at(i)
			continue
		g[1] -= dt
		if g[1] <= 0.0:
			g[1] = 0.05 + rng.randf() * 0.2
			p.volume_db = g[2] + (-40.0 if rng.randf() < 0.45 else 0.0)

func clear() -> void:
	glitchers.clear()
