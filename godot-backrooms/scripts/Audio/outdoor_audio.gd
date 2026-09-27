extends Node
## The open-air sound bed for the hills level (Game.outdoors). Everything here follows audio.outdoor_mix
## (0 in the backrooms .. 1 in the hills, eased over ~1 s) and the sky's Game.day_light:
##   forest  - a bird-filled forest bed by day
##   crickets - a loop of crickets once it is dark
##   wind    - a synthesized seamless wind (tools/make_wind.py) whose level gusts on its own
## They sit on the "Ambience" bus, which audio.gd / ambience.gd hold open outdoors (no corridor muffle).
## The clips were mastered at very different loudnesses, so each has a gain measured to land the beds
## around -36 .. -40 dBFS RMS, under the footsteps.

const DIR := "res://audio/ambients/outdoor/"
const FOREST_GAIN := 7.0              # raw -53 dB RMS
const CRICKET_GAIN := 0.9             # raw -36.5 dB
const WIND_GAIN := 0.08               # raw -18 dB

var audio: Node
var forest: AudioStreamPlayer
var crickets: AudioStreamPlayer
var wind: AudioStreamPlayer
var gust := 0.5
var gust_target := 0.5
var gust_timer := 4.0

func _ready() -> void:
	audio = get_parent()
	forest = _voice("forest_day.mp3")
	crickets = _voice("crickets_night.mp3")
	wind = _voice("wind_loop.wav")

func _voice(file: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.bus = "Ambience"
	p.volume_linear = 0.0
	var s := load(DIR + file) as AudioStream
	if s is AudioStreamMP3:
		s.loop = true
	elif s is AudioStreamWAV:
		s = s.duplicate()
		s.loop_mode = AudioStreamWAV.LOOP_FORWARD
		s.loop_begin = 0
		s.loop_end = s.data.size() / (4 if s.stereo else 2)      # 16-bit frames
	p.stream = s
	add_child(p)
	return p

func _process(dt: float) -> void:
	var o: float = audio.outdoor_mix
	if o < 0.01:
		if forest.playing:                     # back in the backrooms: stop the streams altogether
			forest.stop()
			crickets.stop()
			wind.stop()
		return
	if not forest.playing:
		forest.play(randf() * 30.0)
		crickets.play(randf() * 8.0)
		wind.play(randf() * 20.0)
	var day := smoothstep(0.35, 0.9, Game.day_light)
	var night := 1.0 - smoothstep(0.15, 0.6, Game.day_light)
	gust_timer -= dt
	if gust_timer <= 0.0:
		gust_timer = randf_range(4.0, 10.0)
		gust_target = randf_range(0.15, 1.0)
	gust += (gust_target - gust) * (1.0 - exp(-dt / 2.5))
	var user: float = audio.vol.ambient
	forest.volume_linear = FOREST_GAIN * day * o * user
	crickets.volume_linear = CRICKET_GAIN * night * o * user
	wind.volume_linear = WIND_GAIN * (0.35 + 0.65 * gust) * lerpf(1.0, 1.3, night) * o * user
	wind.pitch_scale = 0.95 + 0.1 * gust
