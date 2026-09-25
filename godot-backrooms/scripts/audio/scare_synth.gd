extends RefCounted
## Procedural scare sounds (thumps, static, heartbeat, drone...): the web game's oscillator and
## filtered-noise recipes rendered once into AudioStreamWAVs and cached. Pure DSP, no scene access.

const SR := 22050

var cache := {}
var rng := RandomNumberGenerator.new()

func _init() -> void:
	rng.randomize()

func _wav(samples: PackedFloat32Array, loop := false) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = SR
	w.stereo = false
	w.data = bytes
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_end = samples.size()
	return w

func _buf(seconds: float) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(int(seconds * SR))
	return a

# one-pole low-pass over noise, for the thuds
func _noise_lp(n: int, cutoff: float) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(n)
	var k := 1.0 - exp(-TAU * cutoff / SR)
	var y := 0.0
	for i in n:
		y += (rng.randf_range(-1.0, 1.0) - y) * k
		a[i] = y
	return a

func render(name: String, arg := 0.0) -> AudioStreamWAV:
	var key := name + str(snappedf(arg, 0.5))
	if cache.has(key):
		return cache[key]
	var w: AudioStreamWAV
	match name:
		"thump":       # a heavy footfall: sub sine and a dull noise slap
			var a := _buf(0.7)
			var nz := _noise_lp(a.size(), 220.0)
			for i in a.size():
				var t := float(i) / SR
				var f := 70.0 * exp(-t * 4.0) + 26.0
				a[i] = (sin(TAU * f * t) * exp(-t * 6.5) * 0.9 + nz[i] * exp(-t * 14.0) * 2.4)
			w = _wav(a)
		"vanish":      # everything sucked out of the room: a falling sweep and a rush of air
			var a := _buf(1.8)
			var nz := _noise_lp(a.size(), 900.0)
			var ph := 0.0
			for i in a.size():
				var t := float(i) / SR
				ph += TAU * (520.0 * exp(-t * 2.2) + 45.0) / SR
				a[i] = (sin(ph) * 0.4 + nz[i] * 1.1) * pow(1.0 - t / 1.8, 1.5) * minf(1.0, t * 30.0)
			w = _wav(a)
		"heartbeat":   # lub-dub
			var a := _buf(0.9)
			for i in a.size():
				var t := float(i) / SR
				var v := sin(TAU * (60.0 - 20.0 * minf(t, 0.2)) * t) * exp(-t * 22.0)
				var t2 := t - 0.27
				if t2 > 0.0:
					v += 0.75 * sin(TAU * (52.0 - 15.0 * minf(t2, 0.2)) * t2) * exp(-t2 * 26.0)
				a[i] = v * 0.9
			w = _wav(a)
		"static":      # entity proximity crackle
			var a := _buf(0.3)
			var gate := 1.0
			for i in a.size():
				if i % 160 == 0:
					gate = 1.0 if rng.randf() < 0.55 else 0.15
				a[i] = rng.randf_range(-1.0, 1.0) * gate * exp(-float(i) / SR * 7.0) * 0.35
			w = _wav(a)
		"static_hit":  # a burst of TV snow that cuts off
			var a := _buf(0.55)
			for i in a.size():
				var t := float(i) / SR
				a[i] = rng.randf_range(-1.0, 1.0) * 0.6 * exp(-t * 6.0) + sin(TAU * 1800.0 * t) * 0.15 * exp(-t * 18.0)
			w = _wav(a)
		"knock":       # wood on wood: a mannequin foot
			var a := _buf(0.32)
			var nz := _noise_lp(a.size(), 1400.0)
			for i in a.size():
				var t := float(i) / SR
				a[i] = (sin(TAU * 160.0 * t) * exp(-t * 30.0) * 0.6 + sin(TAU * 410.0 * t) * exp(-t * 55.0) * 0.35 + nz[i] * exp(-t * 60.0) * 1.4)
			w = _wav(a)
		"creak":       # a joint under strain
			var a := _buf(0.9)
			var nz := _noise_lp(a.size(), 700.0)
			var ph := 0.0
			for i in a.size():
				var t := float(i) / SR
				ph += TAU * (300.0 + 220.0 * sin(t * 9.0) + 90.0 * t) / SR
				a[i] = (sin(ph) * 0.15 + nz[i] * 0.8) * sin(PI * t / 0.9) * (0.6 + 0.4 * sin(t * 47.0))
			w = _wav(a)
		"stinger":     # a sudden loud startle
			var a := _buf(0.9)
			var nz := _noise_lp(a.size(), 4500.0)
			for i in a.size():
				var t := float(i) / SR
				a[i] = (nz[i] * 1.6 * exp(-t * 5.0) + sin(TAU * (900.0 - 500.0 * minf(t, 0.5)) * t) * 0.3 * exp(-t * 7.0)
					+ sin(TAU * 55.0 * t) * 0.6 * exp(-t * 4.0))
			w = _wav(a)
		"splat":       # something wet and heavy
			var a := _buf(0.7)
			var nz := _noise_lp(a.size(), 1100.0)
			for i in a.size():
				var t := float(i) / SR
				a[i] = nz[i] * 2.4 * exp(-t * 9.0) + sin(TAU * 50.0 * t) * exp(-t * 12.0) * 0.7
			w = _wav(a)
		"flatline":    # the long monitor tone of a heart that has stopped (rises, holds, fades)
			var secs := maxf(1.0, arg)
			var a := _buf(secs)
			for i in a.size():
				var t := float(i) / SR
				var g := 0.045
				if t < 0.9:
					g = 0.0001 * pow(0.045 / 0.0001, t / 0.9)              # exponential ramp up
				elif t > maxf(1.0, secs - 1.5):
					g = 0.045 * pow(0.0001 / 0.045, (t - maxf(1.0, secs - 1.5)) / (secs - maxf(1.0, secs - 1.5)))
				a[i] = sin(TAU * 1000.0 * t) * g * 3.0   # quiet: a tone you feel, not one that hurts
			w = _wav(a)
		"tinnitus":    # dead silence: high ear ringing while the hum is gone
			var secs := maxf(1.0, arg)
			var a := _buf(secs)
			for i in a.size():
				var t := float(i) / SR
				a[i] = sin(TAU * 7400.0 * t) * 0.012 * 3.0 * minf(1.0, t * 4.0) * clampf((secs - t) * 2.0, 0.0, 1.0)
			w = _wav(a)
		"drone":       # heavy, slow, wrong: a low pulse with a wobble you feel in your chest
			var secs := maxf(2.0, arg)
			var a := _buf(secs)
			for i in a.size():
				var t := float(i) / SR
				var env := clampf(t / (secs * 0.3), 0.0, 1.0) * clampf((secs - t) / (secs * 0.7), 0.0, 1.0)
				var wob := 1.0 + 0.4 * sin(TAU * 0.6 * t)
				a[i] = (sin(TAU * 46.0 * t) + sin(TAU * 48.6 * t)) * 0.28 * env * wob
			w = _wav(a)
		_:
			w = _wav(_buf(0.1))
	cache[key] = w
	return w
