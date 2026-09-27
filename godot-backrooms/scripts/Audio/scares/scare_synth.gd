extends RefCounted
## Procedural scare sounds (thumps, static, heartbeat, drone...): the web game's oscillator and
## filtered-noise recipes rendered once into AudioStreamWAVs and cached. Pure DSP, no scene access.

const SR := 22050

# Shared by every instance and kept across scene reloads (the level is reloaded on each respawn), so a
# sound is only ever rendered once per session. Guarded: Scares.prewarm_death() renders on a worker thread.
static var cache := {}
static var _lock := Mutex.new()
var rng := RandomNumberGenerator.new()

# Let go of every rendered sound (at quit, so nothing is reported as leaked)
static func clear_cache() -> void:
	_lock.lock()
	cache.clear()
	_lock.unlock()

func _init() -> void:
	rng.randomize()

## The sound if it has been rendered already (by anyone, on any thread), else null. Never renders.
static func cached(name: String, arg := 0.0) -> AudioStreamWAV:
	_lock.lock()
	var hit: AudioStreamWAV = cache.get(name + str(snappedf(arg, 0.5)))
	_lock.unlock()
	return hit

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
	_lock.lock()
	var hit: AudioStreamWAV = cache.get(key)
	_lock.unlock()
	if hit != null:
		return hit
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
		"heartbeat":   # lub-dub: two soft, round sub thumps (808-style falling sine), heavily low-passed
			var a := _buf(0.75)
			var hits := [[0.0, 1.0, 62.0, 40.0, 13.0], [0.24, 0.62, 70.0, 46.0, 18.0]]   # at, gain, f start, f end, decay
			for h in hits:
				var ph := 0.0
				var start := int(h[0] * SR)
				for i in range(start, a.size()):
					var t := float(i - start) / SR
					var f: float = h[3] + (h[2] - h[3]) * exp(-t * 28.0)
					ph += TAU * f / SR
					var env: float = (1.0 - exp(-t * 160.0)) * exp(-t * h[4])   # ~6 ms attack: no click
					if env < 0.0005 and t > 0.05:
						break
					# a touch of 2nd harmonic so it is still felt on small speakers that cannot play 45 Hz
					a[i] += (sin(ph) + 0.22 * sin(2.0 * ph)) * env * h[1]
			# two passes of a ~170 Hz low-pass: round and muffled, like hearing it from inside
			for _n in 2:
				var lp := 0.0
				var k := 1.0 - exp(-TAU * 170.0 / SR)
				for i in a.size():
					lp += (a[i] - lp) * k
					a[i] = lp
			var peak := 0.0001
			for v in a:
				peak = maxf(peak, absf(v))
			for i in a.size():
				a[i] = a[i] / peak * 0.9
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
		"knock":       # wood on wood: a mannequin foot (legacy)
			var a := _buf(0.32)
			var nz := _noise_lp(a.size(), 1400.0)
			for i in a.size():
				var t := float(i) / SR
				a[i] = (sin(TAU * 160.0 * t) * exp(-t * 30.0) * 0.6 + sin(TAU * 410.0 * t) * exp(-t * 55.0) * 0.35 + nz[i] * exp(-t * 60.0) * 1.4)
			w = _wav(a)
		"mannequin_step": # Rigorous physical simulation of a hollow composite mannequin foot striking carpet over concrete
			# arg = variant 0..3: each variation has slightly different cavity frequencies, slab damping, and rock times
			var v_i := int(arg) % 4
			var a := _buf(0.36)
			# Sub-slab impact noise and floor resonance
			var slab := _noise_lp(a.size(), 140.0 + 20.0 * v_i)
			# Hollow body bandpass: composite limb cavity resonance (380-520 Hz)
			var shell_f := 390.0 + 35.0 * v_i
			# Sharp contact tick at high frequencies (heel contact)
			var tick_nz := _noise_lp(a.size(), 4200.0)
			# Sub-bass fundamental (structure-borne floor thump into concrete slab)
			var f0 := 52.0 + 5.0 * v_i
			
			for i in a.size():
				var t := float(i) / SR
				# 1. Floor slab thump: deep sub sine + damped floor noise
				var thud := (sin(TAU * (f0 * exp(-t * 24.0) + 26.0) * t) * 0.75 + slab[i] * 2.2) * exp(-t * 18.0) * minf(1.0, t / 0.002)
				# 2. Hollow shell resonance: damped resonant body modes
				var shell := (sin(TAU * shell_f * t) * 0.45 + sin(TAU * (shell_f * 1.35) * t) * 0.25) * exp(-t * 42.0) * minf(1.0, t / 0.003)
				# 3. Initial contact transient: plastic/wood strike on carpet fibers
				var tick := (tick_nz[i] - slab[i] * 0.5) * 1.6 * exp(-t * 120.0) * minf(1.0, t / 0.001)
				# 4. Secondary micro-rock/settle: non-articulated rigid sole settles
				var t_rock := t - (0.038 + 0.004 * v_i)
				var rock := 0.0
				if t_rock > 0.0:
					rock = (sin(TAU * 240.0 * t_rock) * 0.3 + slab[i] * 0.8) * exp(-t_rock * 38.0) * minf(1.0, t_rock / 0.002)
				a[i] = (thud * 0.75 + shell * 0.55 + tick * 0.45 + rock * 0.35) * 0.85
			w = _wav(a)
		"mannequin_creak": # dry stick-slip friction of an unlubricated ball-and-socket joint
			var v_i := int(arg) % 3
			var dur := 0.18 + 0.04 * v_i
			var a := _buf(dur)
			var band_f := 950.0 + 180.0 * v_i
			var nz := _noise_lp(a.size(), 2600.0)
			var ph := 0.0
			for i in a.size():
				var t := float(i) / SR
				var env := sin(PI * clampf(t / dur, 0.0, 1.0))
				# micro-slip chatter rate
				var slip := sin(TAU * (35.0 + 15.0 * sin(t * 28.0)) * t)
				var gate := 1.0 if slip > 0.1 else 0.15
				ph += TAU * (band_f + 80.0 * sin(t * 19.0)) / SR
				a[i] = (sin(ph) * 0.3 + nz[i] * 0.7) * env * gate * 0.45
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
		"stinger":     # a sudden loud startle: a hiss of air, a falling shriek, a low punch
			# (the old one clipped hard and its pitch sweep jumped at 0.5 s: phase is accumulated now and
			# the sum is soft-saturated instead of chopped off)
			var a := _buf(0.9)
			var nz := _noise_lp(a.size(), 4500.0)
			var ph := 0.0
			for i in a.size():
				var t := float(i) / SR
				ph += TAU * (380.0 + 520.0 * exp(-t * 4.0)) / SR          # 900 Hz gliding smoothly down
				var v := nz[i] * 1.1 * exp(-t * 6.0) * minf(1.0, t / 0.003) \
					+ sin(ph) * 0.3 * exp(-t * 6.0) \
					+ sin(TAU * (55.0 + 25.0 * exp(-t * 20.0)) * t) * 0.6 * exp(-t * 4.0)
				a[i] = tanh(v * 1.3) * 0.75
			w = _wav(a)
		"seize":       # it has you: a body blow, the floor dropping out, a dissonant cluster that swells and dies
			var a := _buf(1.8)
			var thud := _noise_lp(a.size(), 380.0)
			var ph_sub := 0.0
			var notes := [233.1, 246.9, 311.1, 329.6, 466.2]            # two clashing seconds and a tritone
			var phs := [0.0, 0.0, 0.0, 0.0, 0.0]
			for i in a.size():
				var t := float(i) / SR
				ph_sub += TAU * (38.0 + 34.0 * exp(-t * 6.0)) / SR        # a boom sinking out from under you
				var v := sin(ph_sub) * 0.85 * exp(-t * 2.6) * minf(1.0, t / 0.004)
				v += thud[i] * 2.4 * exp(-t * 22.0) * minf(1.0, t / 0.002)
				var cl := 0.0
				for k in notes.size():
					phs[k] += TAU * notes[k] * (1.0 + 0.004 * sin(t * (3.0 + k))) / SR   # a slow sour wobble
					cl += sin(phs[k]) + 0.35 * sin(phs[k] * 2.0) + 0.15 * sin(phs[k] * 3.0)
				v += cl * 0.075 * minf(1.0, t / 0.015) * exp(-t * 2.2)
				a[i] = tanh(v * 1.2) * 0.8
			w = _wav(a)
		"splat":       # something wet and heavy
			var a := _buf(0.7)
			var nz := _noise_lp(a.size(), 1100.0)
			for i in a.size():
				var t := float(i) / SR
				a[i] = nz[i] * 2.4 * exp(-t * 9.0) + sin(TAU * 50.0 * t) * exp(-t * 12.0) * 0.7
			w = _wav(a)
		"tinnitus":    # dead silence: high ear ringing while the hum is gone
			var secs := maxf(1.0, arg)
			var a := _buf(secs)
			for i in a.size():
				var t := float(i) / SR
				a[i] = sin(TAU * 7400.0 * t) * 0.012 * 1.5 * minf(1.0, t * 4.0) * clampf((secs - t) * 2.0, 0.0, 1.0)
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
		"howler_step": # THE BACTERIA's footfall (arg = variant 0..3, so no two in a row are the same sound):
			# the weight coming down, the floor giving under it, the carpet crushed, claws catching the pile
			var v_i := int(arg)
			var a := _buf(0.5)
			var body := _noise_lp(a.size(), 170.0 + 25.0 * v_i)
			var f0 := 46.0 + 5.0 * v_i
			var k_hi := 1.0 - exp(-TAU * 2200.0 / SR)
			var k_lo := 1.0 - exp(-TAU * 700.0 / SR)
			var hi := 0.0
			var lo := 0.0
			var gate := 1.0
			for i in a.size():
				var t := float(i) / SR
				var x := rng.randf_range(-1.0, 1.0)
				hi += (x - hi) * k_hi
				lo += (hi - lo) * k_lo
				if i % 70 == 0:
					gate = 1.0 if rng.randf() < 0.5 else 0.35
				var v := body[i] * 3.2 * minf(1.0, t / 0.005) * exp(-t * 15.0)
				v += sin(TAU * (f0 + 22.0 * exp(-t * 28.0)) * t) * 0.55 * exp(-t * 9.0)
				var t2 := t - 0.015 - 0.004 * v_i
				if t2 > 0.0:
					v += (hi - lo) * gate * 1.9 * minf(1.0, t2 / 0.003) * exp(-t2 * 30.0)   # a 700-2200 Hz band
				a[i] = v * 0.65
			w = _wav(a)
		"howler_drag": # its short, limping leg: the foot lands light and is dragged, claws raking the carpet
			var a := _buf(0.42)
			var body := _noise_lp(a.size(), 200.0)
			var k_hi := 1.0 - exp(-TAU * 2600.0 / SR)
			var k_lo := 1.0 - exp(-TAU * 500.0 / SR)
			var hi := 0.0
			var lo := 0.0
			var gate := 1.0
			for i in a.size():
				var t := float(i) / SR
				var x := rng.randf_range(-1.0, 1.0)
				hi += (x - hi) * k_hi
				lo += (hi - lo) * k_lo
				if i % 55 == 0:
					gate = 1.0 if rng.randf() < 0.55 else 0.2
				var drag := pow(sin(PI * clampf((t - 0.04) / 0.36, 0.0, 1.0)), 1.4)
				var v := body[i] * 1.8 * minf(1.0, t / 0.005) * exp(-t * 20.0)            # a lighter landing
				v += (hi - lo) * gate * drag * 1.4
				a[i] = v * 0.8
			w = _wav(a)
		"heel":        # your heel on carpet laid over concrete: the low knock the recorded scuffs lack
			var a := _buf(0.14)
			var nz := _noise_lp(a.size(), 380.0)
			for i in a.size():
				var t := float(i) / SR
				a[i] = (nz[i] * 2.6 * exp(-t * 40.0) + sin(TAU * (92.0 + 45.0 * exp(-t * 60.0)) * t) * 0.55 * exp(-t * 32.0)) \
					* minf(1.0, t / 0.002) * 0.85
			w = _wav(a)
		"bone_crack":  # a knuckle / joint cracking under the weight
			var a := _buf(0.06)
			var k := 1.0 - exp(-TAU * 2600.0 / SR)
			var lo := 0.0
			for i in a.size():
				var t := float(i) / SR
				var x := rng.randf_range(-1.0, 1.0)
				lo += (x - lo) * k
				a[i] = (x - lo) * 0.5 * minf(1.0, t / 0.001) * exp(-t * 120.0)   # white minus its low end: a high-pass
			w = _wav(a)
		"flatline_loop": # the flatline's steady middle, looped: exactly 1000 whole cycles in one second, so no seam
			var a := _buf(1.0)
			for i in a.size():
				a[i] = sin(TAU * 1000.0 * float(i) / SR) * 0.081
			w = _wav(a, true)
		"wall_knock":  # a knuckle on the hollow drywall: a dull knock and the cavity booming behind it
			var a := _buf(0.3)
			var nz := _noise_lp(a.size(), 2200.0)
			for i in a.size():
				var t := float(i) / SR
				var knock := sin(TAU * (210.0 + 70.0 * exp(-t * 80.0)) * t) * exp(-t * 38.0) * 0.8
				var cavity := sin(TAU * 92.0 * t) * exp(-t * 16.0) * 0.55
				var click := nz[i] * exp(-t * 260.0) * 2.0
				a[i] = (knock + cavity + click) * minf(1.0, t / 0.0008)
			w = _wav(_normalize(a, 0.85))
		"neck_snap":   # the mannequin wrenches your head round: cartilage popping, one deep crunch, gristle
			w = _wav(_normalize(_neck_snap(), 0.95))
		"tile_step":   # a heel on waxed vinyl tile over concrete: a hard tick and a short knock
			var a := _buf(0.16)
			var k_lo := 1.0 - exp(-TAU * 900.0 / SR)
			var lo := 0.0
			for i in a.size():
				var t := float(i) / SR
				var x := rng.randf_range(-1.0, 1.0)
				lo += (x - lo) * k_lo
				var tick := (x - lo) * exp(-t * 320.0) * 0.9                       # the high click of the heel
				var knock := sin(TAU * (190.0 + 60.0 * exp(-t * 90.0)) * t) * exp(-t * 55.0) * 0.6
				var ring := sin(TAU * 1250.0 * t) * exp(-t * 90.0) * 0.08           # the tile itself, briefly
				a[i] = (tick + knock + ring + lo * exp(-t * 70.0) * 0.8) * minf(1.0, t / 0.0006)
			w = _wav(_normalize(a, 0.8))
		"rasp_loop":   # THE BACTERIA breathing: a wet rattling draw in, a long growling breath out, silence
			w = _wav(_normalize(_rasp(), 0.8), true)
		_:
			w = _wav(_buf(0.1))
	_lock.lock()
	cache[key] = w
	_lock.unlock()
	return w

# Scale a buffer so its loudest sample sits at `peak`
func _normalize(a: PackedFloat32Array, peak: float) -> PackedFloat32Array:
	var m := 0.0001
	for v in a:
		m = maxf(m, absf(v))
	var k := peak / m
	for i in a.size():
		a[i] *= k
	return a

# Noise band-passed between two one-pole corners: `lo_hz` .. `hi_hz`
func _band(n: int, lo_hz: float, hi_hz: float) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(n)
	var k_hi := 1.0 - exp(-TAU * hi_hz / SR)
	var k_lo := 1.0 - exp(-TAU * lo_hz / SR)
	var hi := 0.0
	var lo := 0.0
	for i in n:
		hi += (rng.randf_range(-1.0, 1.0) - hi) * k_hi
		lo += (hi - lo) * k_lo
		a[i] = hi - lo
	return a

func _neck_snap() -> PackedFloat32Array:
	var a := _buf(0.55)
	var crunch := _noise_lp(a.size(), 1400.0)
	var gristle := _band(a.size(), 1800.0, 5200.0)
	# a knot of sharp pops over the first ~60 ms, each quieter than the last
	var pops := [0.0, 0.011, 0.019, 0.034, 0.052]
	var k_hp := 1.0 - exp(-TAU * 2500.0 / SR)
	var lo := 0.0
	var gate := 1.0
	for i in a.size():
		var t := float(i) / SR
		var x := rng.randf_range(-1.0, 1.0)
		lo += (x - lo) * k_hp
		var pop := 0.0
		for k in pops.size():
			var tp: float = t - pops[k]
			if tp >= 0.0 and tp < 0.02:
				pop += (x - lo) * exp(-tp * 900.0) * (1.0 - 0.15 * k)
		var body := crunch[i] * 2.6 * exp(-t * 30.0) * minf(1.0, t / 0.002)
		var thud := sin(TAU * (100.0 * exp(-t * 22.0) + 42.0) * t) * exp(-t * 16.0) * 0.8
		if i % 45 == 0:
			gate = 1.0 if rng.randf() < 0.45 else 0.1
		var tail := gristle[i] * gate * 0.7 * exp(-maxf(0.0, t - 0.06) * 12.0) * smoothstep(0.03, 0.08, t)
		a[i] = tanh((pop * 1.6 + body + thud + tail) * 1.3)
	return a

func _rasp() -> PackedFloat32Array:
	var a := _buf(3.6)
	var inhale := _band(a.size(), 450.0, 1900.0)
	var exhale := _band(a.size(), 160.0, 1000.0)
	var ph := 0.0
	var buzz_lp := 0.0
	var k_buzz := 1.0 - exp(-TAU * 650.0 / SR)
	var gurgle := 1.0
	for i in a.size():
		var t := float(i) / SR
		var v := 0.0
		if t < 1.15:                                   # the draw in: wet, fluttering in the throat
			var env := pow(sin(PI * t / 1.15), 0.7)
			v = inhale[i] * env * (0.65 + 0.35 * sin(TAU * 27.0 * t)) * 1.1
		elif t > 1.45 and t < 3.05:                    # the breath out: lower, with a growl in it
			var u := (t - 1.45) / 1.6
			var env := pow(sin(PI * u), 0.6) * (1.0 - 0.3 * u)
			ph += (52.0 + 6.0 * sin(TAU * 0.8 * t)) / SR
			var saw := fmod(ph, 1.0) * 2.0 - 1.0
			buzz_lp += (saw - buzz_lp) * k_buzz
			if i % 180 == 0:
				gurgle = rng.randf_range(0.55, 1.0)
			v = (exhale[i] * 0.9 + buzz_lp * 0.45) * env * gurgle
		a[i] = v                                       # both ends are silent: the loop has no seam
	return a
