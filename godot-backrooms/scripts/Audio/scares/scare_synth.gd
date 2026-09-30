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
		"thump":       # a heavy footfall heard through walls: a dull, rounded thud, no slap and no boom
			# (the old one had a 2.4x noise slap and a 70 Hz sine: it read as a distant explosion)
			var a := _buf(0.55)
			var body := _noise_lp(a.size(), 95.0)          # the floor taking the weight, muffled by the walls
			var scuff := _noise_lp(a.size(), 420.0)        # a hint of carpet under it, nothing sharp
			var ph := 0.0
			for i in a.size():
				var t := float(i) / SR
				ph += TAU * (34.0 + 22.0 * exp(-t * 30.0)) / SR
				var atk := minf(1.0, t / 0.012)              # 12 ms attack: soft onset, never a click
				var v := sin(ph) * 0.5 * exp(-t * 15.0) + body[i] * 2.2 * exp(-t * 20.0) + scuff[i] * 0.9 * exp(-t * 40.0)
				a[i] = v * atk * clampf((0.55 - t) / 0.08, 0.0, 1.0)
			w = _wav(_normalize(a, 0.55))
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
		"static":      # entity proximity crackle: a soft, dull sputter of signal noise
			# (it was raw white noise gated ~300 times a second: a harsh, high-pitched banging)
			var a := _buf(0.3)
			var band := _band(a.size(), 250.0, 1600.0)
			var gate := 1.0
			var g := 1.0
			for i in a.size():
				var t := float(i) / SR
				if i % 900 == 0:
					gate = 1.0 if rng.randf() < 0.6 else 0.3
				g += (gate - g) * 0.01                      # eased, so the chops don't click
				a[i] = band[i] * g * minf(1.0, t / 0.02) * exp(-t * 7.0)
			w = _wav(_normalize(a, 0.22))
		"static_hit":  # a short dropout of dull signal noise: chopped, band-limited, nothing pitched
			# (no 1.8 kHz beep and no white-noise crash: that was the TV-snow gag)
			var a := _buf(0.4)
			var band := _band(a.size(), 500.0, 3200.0)
			var gate := 1.0
			for i in a.size():
				var t := float(i) / SR
				if i % 220 == 0:
					gate = 1.0 if rng.randf() < 0.6 else 0.25
				a[i] = band[i] * gate * minf(1.0, t / 0.006) * exp(-t * 7.0)
			w = _wav(_normalize(a, 0.4))
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
		"stinger":     # a startle: air drawn in sharply, a low dissonant swell under it, a soft body-felt hit
			# (the old one was a saturated falling shriek and read as a cartoon "dun-DUN"; this one is dark,
			# low-passed and unpitched enough that it feels like the room reacting, not a musical sting)
			var a := _buf(1.1)
			var air := _band(a.size(), 350.0, 2400.0)
			var ph_a := 0.0
			var ph_b := 0.0
			var ph_sub := 0.0
			for i in a.size():
				var t := float(i) / SR
				var gasp := air[i] * 2.4 * minf(1.0, t / 0.008) * exp(-t * 7.0)
				ph_a += TAU * 146.8 * (1.0 - 0.02 * t) / SR       # a minor second, sinking a hair: sour, not tuneful
				ph_b += TAU * 155.6 * (1.0 - 0.02 * t) / SR
				var swell := (sin(ph_a) + sin(ph_b)) * 0.16 * (1.0 - exp(-t * 14.0)) * exp(-t * 3.2)
				ph_sub += TAU * (44.0 + 10.0 * exp(-t * 18.0)) / SR
				var thump := sin(ph_sub) * 0.55 * minf(1.0, t / 0.01) * exp(-t * 9.0)
				a[i] = (gasp + swell + thump) * clampf((1.1 - t) / 0.15, 0.0, 1.0)
			w = _wav(_normalize(a, 0.6))
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
		"howler_step": # THE BACTERIA's footfall. arg = variant 0..3 (no two in a row alike), +10 = running.
			# A huge bare, damp foot: a fleshy slap on the carpet, a short round thud through the slab, and a
			# wet peel-and-stick as the sole settles. Short and dry-tailed: the old long sub rumble read as a
			# cartoon "whump". Every layer fades in over milliseconds, nothing clicks.
			var v_i := int(arg) % 10
			var run := 1.0 if arg >= 10.0 else 0.0
			var dur := 0.55
			var a := _buf(dur)
			var body := _noise_lp(a.size(), 170.0 + 18.0 * v_i)      # flesh meeting the floor
			var wet := _noise_lp(a.size(), 900.0 + 120.0 * v_i)      # the damp skin, uneven per take
			var flutter := _noise_lp(a.size(), 38.0)                  # irregular: the sole peeling, not a buzz
			var k_hi := 1.0 - exp(-TAU * 2200.0 / SR)
			var k_lo := 1.0 - exp(-TAU * 300.0 / SR)
			var hi := 0.0
			var lo := 0.0
			var ph := 0.0
			var atk := lerpf(0.005, 0.003, run)
			var f0 := 62.0 + 3.0 * v_i - 8.0 * run
			var stick_at := lerpf(0.05, 0.035, run) + 0.006 * v_i
			for i in a.size():
				var t := float(i) / SR
				var x := rng.randf_range(-1.0, 1.0)
				hi += (x - hi) * k_hi
				lo += (hi - lo) * k_lo
				var slap := minf(1.0, t / atk) * exp(-t * lerpf(38.0, 48.0, run))
				var thud := minf(1.0, t / 0.008) * exp(-t * lerpf(15.0, 19.0, run))
				var ts := maxf(0.0, t - stick_at)
				var stick := minf(1.0, ts / 0.01) * exp(-ts * 22.0) if t >= stick_at else 0.0
				ph += TAU * (f0 + 30.0 * exp(-t * 26.0)) / SR
				var v := (hi - lo) * 1.5 * slap * (0.8 + 0.5 * run)         # the slap of skin on pile
				v += body[i] * 3.2 * thud
				v += sin(ph) * (0.75 + 0.3 * run) * thud                      # weight, kept short so it stays a step
				v += wet[i] * (0.5 + 2.2 * absf(flutter[i]) * 6.0) * stick * 0.7   # the wet stick as it lifts
				a[i] = v * clampf((dur - t) / 0.06, 0.0, 1.0)
			w = _wav(_normalize(a, 0.9))
		"howler_far":  # the deep thud of its foot carried through the slab and the walls: bass you feel before you place it
			# arg = variant 0..3. A falling sine with a 2nd harmonic (still audible on small speakers), a
			# rounded body, and a slow low bloom as the building answers. Nothing above ~300 Hz, so walls can't muffle it away.
			var v_i := int(arg) % 4
			var dur := 0.9
			var a := _buf(dur)
			var body := _noise_lp(a.size(), 110.0 + 10.0 * v_i)
			var ph := 0.0
			for i in a.size():
				var t := float(i) / SR
				var f := 38.0 + 3.0 * v_i + 34.0 * exp(-t * 22.0)
				ph += TAU * f / SR
				var strike := minf(1.0, t / 0.012) * exp(-t * 9.0)
				var bloom := minf(1.0, t / 0.08) * exp(-t * 3.2)
				var v := (sin(ph) + 0.5 * sin(2.0 * ph)) * strike + body[i] * 2.2 * strike + sin(ph * 0.5) * 0.5 * bloom
				a[i] = v * clampf((dur - t) / 0.12, 0.0, 1.0)
			w = _wav(_normalize(a, 0.9))
		"howler_drag": # its short, limping leg: set down lighter, then dragged a beat through the pile.
			# arg 10 = running: a shorter, harder scuff
			var run := 1.0 if arg >= 10.0 else 0.0
			var dur := lerpf(0.6, 0.45, run)
			var a := _buf(dur)
			var body := _noise_lp(a.size(), 190.0)
			var press := _noise_lp(a.size(), 9.0)                     # uneven pressure as it slides
			var k_hi := 1.0 - exp(-TAU * 1500.0 / SR)
			var k_lo := 1.0 - exp(-TAU * 260.0 / SR)
			var hi := 0.0
			var lo := 0.0
			var ph := 0.0
			var drag_len := lerpf(0.36, 0.24, run)
			for i in a.size():
				var t := float(i) / SR
				var x := rng.randf_range(-1.0, 1.0)
				hi += (x - hi) * k_hi
				lo += (hi - lo) * k_lo
				var contact := minf(1.0, t / 0.006) * exp(-t * 22.0)
				var slide := clampf((t - 0.05) / 0.04, 0.0, 1.0) * clampf((0.05 + drag_len - t) / 0.08, 0.0, 1.0)
				ph += TAU * (58.0 + 22.0 * exp(-t * 24.0)) / SR
				var v := body[i] * 2.4 * contact + sin(ph) * 0.5 * contact
				# skin dragged through pile: rough band noise whose pressure wanders, never a steady wobble
				v += (hi - lo) * slide * (0.35 + 3.0 * absf(press[i])) * 0.7
				a[i] = v * clampf((dur - t) / 0.06, 0.0, 1.0)
			w = _wav(_normalize(a, 0.7))
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
		"wall_knock":  # a hand on hollow drywall; arg = kind * 10 + take (see _knock)
			w = _wav(_knock(int(arg) / 10))
		"wall_scratch": # fingernails dragged down the inside of the wall (arg: the take)
			w = _wav(_normalize(_scratch(), 0.7))
		"breath_close": # a breath right at the back of your neck (arg: the kind, see _breath)
			w = _wav(_normalize(_breath(int(arg)), 0.85))
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

# ------------------------------------------------------------------ the wall knock
# A hand on gypsum board over studs, heard from the other side: a short contact transient, a few heavily
# damped panel modes (drywall is dead, it never rings), the stud cavity booming behind them, something
# loose buzzing in the wall, and the nearest walls throwing it back. Every take detunes the panel a
# little, so a run of knocks is never one sample repeated. kind: 0 a knuckle rap, 1 a fist pounding,
# 2 a fingernail tap
func _knock(kind: int) -> PackedFloat32Array:
	kind = clampi(kind, 0, 2)
	# contact: [band Hz, Q, decay/s, gain]; modes: [Hz, amp, decay/s]; cavity: [Hz, amp, decay/s]
	var p: Dictionary = [
		{"dur": 0.5, "contact": [1900.0, 0.8, 380.0, 1.0], "cavity": [74.0, 0.4, 11.0], "rattle": 0.05, "tail": 0.05, "drive": 1.3,
			"modes": [[118.0, 0.9, 22.0], [176.0, 0.7, 30.0], [251.0, 0.5, 42.0], [398.0, 0.3, 60.0], [615.0, 0.18, 90.0]]},
		{"dur": 0.85, "contact": [650.0, 0.7, 170.0, 0.9], "cavity": [52.0, 0.7, 7.0], "rattle": 0.16, "tail": 0.09, "drive": 1.9,
			"modes": [[66.0, 1.0, 9.0], [98.0, 0.8, 13.0], [141.0, 0.55, 18.0], [212.0, 0.3, 28.0], [334.0, 0.15, 45.0]]},
		{"dur": 0.22, "contact": [3900.0, 1.2, 900.0, 1.0], "cavity": [120.0, 0.05, 30.0], "rattle": 0.0, "tail": 0.03, "drive": 1.0,
			"modes": [[430.0, 0.22, 80.0], [1150.0, 0.15, 150.0], [1950.0, 0.12, 200.0]]},
	][kind]
	var dur: float = p.dur
	var a := _buf(dur)
	var n := a.size()
	var c: Array = p.contact
	var contact := _normalize(_bp(_white(n), c[0] * rng.randf_range(0.9, 1.1), c[1]), 1.0)
	var rattle := _normalize(_bp(_white(n), 1300.0, 3.0), 1.0)
	var room := _normalize(_noise_lp(n, 800.0), 1.0)
	var detune := rng.randf_range(0.92, 1.08)
	var modes: Array = []
	for m in p.modes:
		modes.append([m[0] * detune * rng.randf_range(0.97, 1.03), m[1] * rng.randf_range(0.8, 1.15), m[2], 0.0])
	var cav: Array = p.cavity
	var rattle_gain: float = p.rattle
	var tail_gain: float = p.tail
	var cav_ph := 0.0
	var buzz := 0.0
	for i in n:
		var t := float(i) / SR
		var v: float = contact[i] * c[3] * exp(-t * c[2])
		for m in modes:
			m[3] += TAU * m[0] * (1.0 + 0.05 * exp(-t * 70.0)) / SR     # the board is stiffest as it is struck
			v += sin(m[3]) * m[1] * exp(-t * m[2])
		cav_ph += TAU * cav[0] / SR
		v += sin(cav_ph) * cav[1] * exp(-t * cav[2]) * minf(1.0, t / 0.004)   # the cavity takes a moment to answer
		if i % 400 == 0:
			buzz = rng.randf_range(0.2, 1.0)
		v += rattle[i] * buzz * rattle_gain * exp(-t * 25.0)
		v += room[i] * tail_gain * exp(-t * 6.0) * smoothstep(0.0, 0.03, t)
		a[i] = v * minf(1.0, t / 0.0004)
	var dry := a.duplicate()
	for r in [[0.013, 0.28], [0.022, 0.2], [0.035, 0.14], [0.051, 0.09]]:
		var d := int(r[0] * SR)
		for i in range(d, n):
			a[i] += dry[i - d] * r[1]
	a = _normalize(a, 1.0)
	var drive: float = p.drive
	for i in n:
		a[i] = tanh(a[i] * drive) * clampf((dur - float(i) / SR) / 0.04, 0.0, 1.0)
	return _normalize(a, [0.85, 0.92, 0.6][kind])

# Fingernails dragged down drywall: each nail sticks and slips across the paper facing in a stutter of
# tiny ticks over a dry hiss, the pressure wavering as the hand drags down
func _scratch() -> PackedFloat32Array:
	var dur := rng.randf_range(1.1, 1.6)
	var a := _buf(dur)
	var n := a.size()
	var hiss := _normalize(_bp(_white(n), 3400.0, 0.9), 1.0)
	var paper := _normalize(_bp(_white(n), 900.0, 1.4), 1.0)
	var press := _wobble(n, 6.0, 0.4)
	var k := exp(-1.0 / (SR * 0.0025))
	for nail in 3:
		var rate := rng.randf_range(70.0, 130.0)
		var ph := rng.randf()
		var e := 0.0
		var start := rng.randf_range(0.0, 0.08)
		for i in n:
			var t := float(i) / SR
			ph += rate * press[i] / SR
			if ph >= 1.0:
				ph -= rng.randf_range(0.7, 1.0)
				e = rng.randf_range(0.4, 1.0)
			e *= k
			var env := smoothstep(start, start + 0.08, t) * clampf((dur - t) / 0.2, 0.0, 1.0)
			a[i] += (hiss[i] * (0.15 + e) + paper[i] * e * 0.4) * env * press[i] * 0.4
	return a

# ------------------------------------------------------------------ the breath behind you
# Breath is air rushing through a throat, mouth or nose: noise through that tract's resonances
# (formants), with the flow never quite steady. Close enough to feel, the air also hits your ear as a
# low puff under it. kind:
#   0 a slow draw through the nose, a long exhale that catches and creaks in the throat at the end
#   1 sniffing at you, three quick draws, then out through the nose onto your neck
#   2 wet: spit crackling on the draw in, a gurgle on the way out, lips parting after
#   3 a ragged, stuttering draw in, held, then a long exhale shaking all the way out
func _breath(kind: int) -> PackedFloat32Array:
	kind = clampi(kind, 0, 3)
	var a := _buf([2.45, 2.3, 2.8, 3.05][kind])
	var n := a.size()
	var w := _white(n)
	var turb := _wobble(n, 18.0, 0.35)
	var near := _normalize(_noise_lp(n, 150.0), 1.0)
	match kind:
		0:
			var nose := _normalize(_formants(w, [[950.0, 1.4, 0.5], [2700.0, 2.0, 0.35], [5200.0, 2.0, 0.18]]), 1.0)
			var mouth := _normalize(_formants(w, [[640.0, 2.2, 1.0], [1150.0, 2.6, 0.7], [2500.0, 3.0, 0.35], [3600.0, 3.0, 0.15]]), 1.0)
			var fry := _fry(n, 44.0, [[520.0, 4.0, 1.0], [1400.0, 5.0, 0.5]])
			for i in n:
				var t := float(i) / SR
				var exh := _seg(t, 0.78, 2.38, 0.07, 1.5)
				a[i] = (nose[i] * _seg(t, 0.05, 0.62, 0.35, 1.0) * 0.45 + mouth[i] * exh) * turb[i] \
					+ near[i] * exh * 0.5 + fry[i] * _seg(t, 1.5, 2.35, 0.4, 1.2) * 0.35
		1:
			var sniff := _normalize(_formants(w, [[1900.0, 1.3, 0.6], [3800.0, 1.6, 0.6], [6200.0, 1.6, 0.4]]), 1.0)
			var out := _normalize(_formants(w, [[480.0, 1.6, 0.8], [1500.0, 2.0, 0.4], [3000.0, 2.2, 0.2]]), 1.0)
			for i in n:
				var t := float(i) / SR
				var s := _seg(t, 0.05, 0.18, 0.02, 0.6) * 0.7 + _seg(t, 0.25, 0.38, 0.02, 0.6) * 0.85 \
					+ _seg(t, 0.44, 0.62, 0.02, 0.7)
				var exh := _seg(t, 0.98, 2.25, 0.05, 1.6)
				a[i] = (sniff[i] * s + out[i] * exh * 0.8) * turb[i] + near[i] * exh * 0.7
		2:
			var draw := _normalize(_formants(w, [[1100.0, 1.8, 0.7], [2400.0, 2.2, 0.5], [4200.0, 2.0, 0.3]]), 1.0)
			var out := _normalize(_formants(w, [[450.0, 2.0, 1.0], [1000.0, 2.5, 0.6], [2300.0, 3.0, 0.3]]), 1.0)
			var gurgle := 1.0
			var gv := 1.0
			for i in n:
				var t := float(i) / SR
				var exh := _seg(t, 1.2, 2.55, 0.06, 1.3)
				if i % 800 == 0:
					gurgle = rng.randf_range(0.35, 1.0)
				gv += (gurgle - gv) * 0.08
				a[i] = draw[i] * _seg(t, 0.05, 1.0, 0.45, 0.8) * 0.55 * turb[i] + out[i] * exh * gv + near[i] * exh * 0.6
			for _c in 14:                                   # spit crackling in the throat as the air turns
				a = _click(a, rng.randf_range(0.3, 1.35), rng.randf_range(2200.0, 4800.0), rng.randf_range(0.15, 0.4))
			a = _click(a, 2.62, 1400.0, 0.6)                    # and the lips coming apart
			a = _click(a, 2.665, 2100.0, 0.35)
		3:
			var draw := _normalize(_formants(w, [[1200.0, 1.8, 0.7], [2600.0, 2.2, 0.5], [4400.0, 2.0, 0.3]]), 1.0)
			var out := _normalize(_formants(w, [[700.0, 2.0, 1.0], [1250.0, 2.5, 0.6], [2700.0, 3.0, 0.3]]), 1.0)
			var fry := _fry(n, 50.0, [[600.0, 4.0, 1.0], [1500.0, 5.0, 0.4]])
			var ph := 0.0
			for i in n:
				var t := float(i) / SR
				var inh := _seg(t, 0.05, 0.25, 0.04, 0.5) * 0.6 + _seg(t, 0.32, 0.5, 0.04, 0.5) * 0.75 \
					+ _seg(t, 0.58, 1.0, 0.1, 0.9) * 0.9
				var exh := _seg(t, 1.35, 2.98, 0.08, 1.2)
				ph += TAU * (6.5 + 1.5 * sin(TAU * 0.7 * t)) / SR
				var trem := 0.6 + 0.4 * sin(ph)
				a[i] = draw[i] * inh * 0.5 * turb[i] + (out[i] + near[i] * 0.5) * exh * trem \
					+ fry[i] * _seg(t, 2.2, 2.95, 0.3, 1.0) * 0.25
	return a

# 0 outside t0..t1; inside it rises smoothly over `atk` seconds and dies away over the rest (`curve` > 1
# lets it go early, like breath running out)
static func _seg(t: float, t0: float, t1: float, atk: float, curve := 1.0) -> float:
	if t <= t0 or t >= t1:
		return 0.0
	var u := t - t0
	return smoothstep(0.0, atk, u) * pow(1.0 - clampf((u - atk) / (t1 - t0 - atk), 0.0, 1.0), curve)

# Vocal fry: slow, uneven glottal clicks through a throat's resonances - the creak at the end of a breath
func _fry(n: int, hz: float, fs: Array) -> PackedFloat32Array:
	var p := PackedFloat32Array()
	p.resize(n)
	var ph := 0.0
	var f := hz
	for i in n:
		ph += f / SR
		if ph >= 1.0:
			ph -= 1.0
			p[i] = rng.randf_range(0.5, 1.0)
			f = hz * rng.randf_range(0.8, 1.25)
	return _normalize(_formants(p, fs), 1.0)

# A wet click (spit, lips) mixed into `a` at `at` seconds
func _click(a: PackedFloat32Array, at: float, hz: float, gain: float) -> PackedFloat32Array:
	var start := int(at * SR)
	for j in int(0.005 * SR):
		if start + j >= a.size():
			break
		var t := float(j) / SR
		a[start + j] += (sin(TAU * hz * t) * 0.6 + rng.randf_range(-0.4, 0.4)) * exp(-t * 1400.0) * gain
	return a

func _white(n: int) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(n)
	for i in n:
		a[i] = rng.randf_range(-1.0, 1.0)
	return a

# A slow random flutter around 1.0 (+-depth), changing about `rate` times a second
func _wobble(n: int, rate: float, depth: float) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(n)
	var step := maxi(1, int(SR / rate))
	var k := 1.0 - exp(-TAU * rate / SR)
	var target := 1.0
	var v := 1.0
	for i in n:
		if i % step == 0:
			target = 1.0 + rng.randf_range(-depth, depth)
		v += (target - v) * k
		a[i] = v
	return a

# RBJ band-pass (0 dB at the peak) at `hz`, quality `q`
func _bp(x: PackedFloat32Array, hz: float, q: float) -> PackedFloat32Array:
	var w0 := TAU * minf(hz, SR * 0.45) / SR
	var al := sin(w0) / (2.0 * q)
	var a0 := 1.0 + al
	var b0 := al / a0
	var a1 := -2.0 * cos(w0) / a0
	var a2 := (1.0 - al) / a0
	var y := PackedFloat32Array()
	y.resize(x.size())
	var x1 := 0.0
	var x2 := 0.0
	var y1 := 0.0
	var y2 := 0.0
	for i in x.size():
		var v := b0 * (x[i] - x2) - a1 * y1 - a2 * y2
		x2 = x1
		x1 = x[i]
		y2 = y1
		y1 = v
		y[i] = v
	return y

# `x` through a set of resonances [[Hz, Q, gain], ...], summed
func _formants(x: PackedFloat32Array, fs: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(x.size())
	for f in fs:
		var b := _bp(x, f[0], f[1])
		var g: float = f[2]
		for i in out.size():
			out[i] += b[i] * g
	return out
