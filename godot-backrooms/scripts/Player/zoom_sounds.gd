extends RefCounted
## The camcorder lens's sounds (zoom_tool.gd), built once at start from a few lines of synthesis so no
## recordings ship with them.
##   motor()   a 1 s seamless loop of a small geared zoom servo: the tone of the motor and its gear train,
##             a surge from the commutator, friction hiss and a low hum. zoom_tool.gd bends its pitch and
##             level with how hard the motor runs
##   tick()    the motor catching as it starts
##   clunk()   the barrel running home when it stops (the lens end stops are heavier)
##   chirp()   the autofocus motor's short buzz as it moves the focus group

const RATE := 22050

static func _wav(s: PackedFloat32Array, looped: bool) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(s.size() * 2)
	for i in s.size():
		data.encode_s16(i * 2, int(clampf(s[i], -1.0, 1.0) * 30000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	if looped:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = s.size()
	return w

## A one-pole low-pass, `cut` in Hz
static func _lp(x: PackedFloat32Array, cut: float) -> PackedFloat32Array:
	var a := 1.0 - exp(-TAU * cut / RATE)
	var out := PackedFloat32Array()
	out.resize(x.size())
	var y := 0.0
	for i in x.size():
		y += (x[i] - y) * a
		out[i] = y
	return out

static func _noise(n: int, rng: RandomNumberGenerator) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = rng.randf() * 2.0 - 1.0
	return out

static func motor() -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7141
	var fade := 2400
	var n := RATE
	# friction hiss: noise band-passed (low-pass minus a lower low-pass), looped by crossfading its tail
	# into its head
	var raw := _noise(n + fade, rng)
	var hi := _lp(raw, 4200.0)
	var lo := _lp(raw, 900.0)
	var hiss := PackedFloat32Array()
	hiss.resize(n)
	for i in n:
		var v := hi[i] - lo[i]
		if i < fade:
			var w := float(i) / fade
			v = v * sqrt(w) + (hi[n + i] - lo[n + i]) * sqrt(1.0 - w)
		hiss[i] = v
	var out := PackedFloat32Array()
	out.resize(n)
	var peak := 0.001
	for i in n:
		var t := float(i) / RATE
		# the servo: 330 Hz and its harmonics, the 2nd and 3rd strongest (a stepped drive is not a sine)
		var tone := 0.0
		for h in 8:
			var amp := 1.0 / pow(h + 1.0, 1.15) * (1.5 if h == 1 or h == 2 else 1.0)
			tone += sin(TAU * 330.0 * (h + 1) * t + h * 0.7) * amp
		tone *= 0.17
		# the gear train: a hard narrow whine with the motor's commutator surging through it
		var gear := sin(TAU * 1650.0 * t) * 0.07 * (0.75 + 0.25 * sin(TAU * 55.0 * t))
		var hum := sin(TAU * 77.0 * t) * 0.09 + sin(TAU * 154.0 * t + 1.1) * 0.04
		var v := (tone + gear + hum) * (0.84 + 0.16 * sin(TAU * 11.0 * t + 0.6)) + hiss[i] * 1.5
		out[i] = v
		peak = maxf(peak, absf(v))
	for i in n:
		out[i] = out[i] / peak * 0.8
	return _wav(out, true)

static func tick() -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var n := int(RATE * 0.06)
	var out := PackedFloat32Array()
	out.resize(n)
	var nz := _lp(_noise(n, rng), 5000.0)
	for i in n:
		var t := float(i) / RATE
		out[i] = (nz[i] * exp(-t / 0.006) * 0.9 + sin(TAU * 1500.0 * t) * exp(-t / 0.012) * 0.4) * 0.8
	return _wav(out, false)

static func clunk() -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = 23
	var n := int(RATE * 0.22)
	var out := PackedFloat32Array()
	out.resize(n)
	var nz := _lp(_noise(n, rng), 1100.0)
	for i in n:
		var t := float(i) / RATE
		var thump := sin(TAU * (118.0 - 40.0 * minf(t / 0.12, 1.0)) * t) * exp(-t / 0.045)
		var rattle := nz[i] * exp(-t / 0.03)
		var ring := sin(TAU * 740.0 * t) * exp(-t / 0.05) * 0.12         # the barrel's little ring
		out[i] = (thump * 0.7 + rattle * 1.4 + ring) * 0.85
	return _wav(out, false)

static func chirp() -> AudioStreamWAV:
	var n := int(RATE * 0.11)
	var out := PackedFloat32Array()
	out.resize(n)
	var ph := 0.0
	for i in n:
		var t := float(i) / RATE
		var f := lerpf(1900.0, 2700.0, t / 0.11)
		ph += TAU * f / RATE
		var env := smoothstep(0.0, 0.012, t) * (1.0 - smoothstep(0.06, 0.11, t))
		out[i] = (sin(ph) + 0.35 * sin(ph * 2.0 + 0.4)) * env * 0.45
	return _wav(out, false)
