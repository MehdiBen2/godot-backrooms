extends RefCounted
## Scary hand-drawn designs for the STAMP tool in the draw tools panel (draw_ui.gd, Y). Each design is a
## list of polylines in a -1..1 box (x right, y up); sketch_tool.gd scales it to the chosen size, lays it flat
## on the wall, floor or ceiling that was clicked and turns every polyline into an ordinary sketch stroke,
## so the wobble, colour, width and opacity of the pen apply and the eraser and undo work on them.
## "t:..." ids are scratched-in words (a stroke font); \n starts a new line.

const LIST := [
	["eye", "EYE"], ["eyes", "MANY EYES"], ["grin", "GRIN"], ["figure", "FIGURE"], ["hand", "HAND"],
	["skull", "SKULL"], ["claws", "CLAWS"], ["scribble", "SCRIBBLE"], ["tally", "TALLY"],
	["spiral", "SPIRAL"], ["drips", "DRIPS"],
	["t:RUN", "RUN"], ["t:HELP ME", "HELP ME"], ["t:BEHIND\nYOU", "BEHIND YOU"],
	["t:HE SEES\nYOU", "HE SEES YOU"], ["t:DONT\nLOOK", "DONT LOOK"], ["t:GET OUT", "GET OUT"],
	["cry", "CRYING"], ["xeyes", "STITCHED"], ["spider", "SPIDER"], ["web", "WEB"], ["tentacles", "TENTACLES"],
	["door", "DOOR"], ["arrow", "ARROW"], ["maw", "MAW"], ["demon", "DEMON"], ["smiler", "SMILER"],
	["family", "FAMILY"], ["sun", "SAD SUN"], ["crack", "CRACK"], ["occult", "OCCULT"], ["watcher", "WATCHER"],
	["fingers", "FINGERS"], ["stitch", "WOUND"], ["smileys", "SMILEYS"], ["footprints", "FOOTSTEPS"], ["iris", "STARE"],
	["t:LEAVE", "LEAVE"], ["t:IT IS\nHERE", "IT IS HERE"], ["t:DONT\nTRUST\nHIM", "DONT TRUST"], ["t:NO EXIT", "NO EXIT"],
	["t:WAKE UP", "WAKE UP"], ["t:HE IS\nWATCHING", "WATCHING"], ["t:TURN\nBACK", "TURN BACK"],
	["t:I SEE YOU", "I SEE YOU"], ["t:SMILE", "SMILE"], ["t:HELP", "HELP"],
]

## Letters on a 4 wide, 6 tall grid: strokes as flat x, y, x, y ... lists
const GLYPHS := {
	"A": [[0, 0, 2, 6, 4, 0], [0.8, 2.4, 3.2, 2.4]],
	"B": [[0, 0, 0, 6, 3, 6, 4, 5, 4, 4, 3, 3, 0, 3], [3, 3, 4, 2, 4, 1, 3, 0, 0, 0]],
	"C": [[4, 5, 3, 6, 1, 6, 0, 5, 0, 1, 1, 0, 3, 0, 4, 1]],
	"D": [[0, 0, 0, 6, 2, 6, 4, 4, 4, 2, 2, 0, 0, 0]],
	"E": [[4, 6, 0, 6, 0, 0, 4, 0], [0, 3, 3, 3]],
	"F": [[4, 6, 0, 6, 0, 0], [0, 3, 3, 3]],
	"G": [[4, 5, 3, 6, 1, 6, 0, 5, 0, 1, 1, 0, 3, 0, 4, 1, 4, 3, 2, 3]],
	"H": [[0, 0, 0, 6], [4, 0, 4, 6], [0, 3, 4, 3]],
	"I": [[1, 6, 3, 6], [2, 6, 2, 0], [1, 0, 3, 0]],
	"J": [[4, 6, 4, 1, 3, 0, 1, 0, 0, 1]],
	"K": [[0, 0, 0, 6], [4, 6, 0, 2.8], [1.2, 3.8, 4, 0]],
	"L": [[0, 6, 0, 0, 4, 0]],
	"M": [[0, 0, 0, 6, 2, 3, 4, 6, 4, 0]],
	"N": [[0, 0, 0, 6, 4, 0, 4, 6]],
	"O": [[1, 0, 0, 1, 0, 5, 1, 6, 3, 6, 4, 5, 4, 1, 3, 0, 1, 0]],
	"P": [[0, 0, 0, 6, 3, 6, 4, 5, 4, 4, 3, 3, 0, 3]],
	"Q": [[1, 0, 0, 1, 0, 5, 1, 6, 3, 6, 4, 5, 4, 1, 3, 0, 1, 0], [2.5, 1.5, 4, -0.5]],
	"R": [[0, 0, 0, 6, 3, 6, 4, 5, 4, 4, 3, 3, 0, 3], [2, 3, 4, 0]],
	"S": [[4, 5, 3, 6, 1, 6, 0, 5, 0, 4, 1, 3, 3, 3, 4, 2, 4, 1, 3, 0, 1, 0, 0, 1]],
	"T": [[0, 6, 4, 6], [2, 6, 2, 0]],
	"U": [[0, 6, 0, 1, 1, 0, 3, 0, 4, 1, 4, 6]],
	"V": [[0, 6, 2, 0, 4, 6]],
	"W": [[0, 6, 1, 0, 2, 4, 3, 0, 4, 6]],
	"X": [[0, 6, 4, 0], [4, 6, 0, 0]],
	"Y": [[0, 6, 2, 3, 4, 6], [2, 3, 2, 0]],
	"Z": [[0, 6, 4, 6, 0, 0, 4, 0]],
}

static func make(id: String) -> Array:
	if id.begins_with("t:"):
		return _text(id.substr(2))
	match id:
		"eye": return _eye(Vector2.ZERO, 1.0)
		"eyes": return _eyes()
		"grin": return _grin()
		"figure": return _figure()
		"hand": return _hand()
		"skull": return _skull()
		"claws": return _claws()
		"scribble": return _scribble()
		"tally": return _tally()
		"spiral": return _spiral()
		"drips": return _drips()
		"cry": return _cry()
		"xeyes": return _xeyes()
		"spider": return _spider()
		"web": return _web()
		"tentacles": return _tentacles()
		"door": return _door()
		"arrow": return _arrow()
		"maw": return _maw()
		"demon": return _demon()
		"smiler": return _smiler()
		"family": return _family()
		"sun": return _sun()
		"crack": return _crack()
		"occult": return _occult()
		"watcher": return _watcher()
		"fingers": return _fingers()
		"stitch": return _stitch()
		"smileys": return _smileys()
		"footprints": return _footprints()
		"iris": return _iris()
	return []

# ---------------------------------------------------------------- helpers
static func _poly(flat: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in range(0, flat.size() - 1, 2):
		out.append(Vector2(flat[i], flat[i + 1]))
	return out

static func _arc(c: Vector2, rx: float, ry: float, a0: float, a1: float, n := 20) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n + 1:
		var a := lerpf(a0, a1, float(i) / n)
		out.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	return out

## `lines` moved to `c` and scaled by `s`
static func _xf(lines: Array, c: Vector2, s: float) -> Array:
	var out: Array = []
	for l in lines:
		var q := PackedVector2Array()
		for p in l:
			q.append(c + p * s)
		out.append(q)
	return out

# ---------------------------------------------------------------- designs
## An almond eye, a ringed pupil, bloodshot veins, lashes and a tear
static func _eye(c: Vector2, s: float) -> Array:
	var top := PackedVector2Array()
	var bot := PackedVector2Array()
	for i in 17:
		var x := lerpf(-1.0, 1.0, i / 16.0)
		var h := 0.5 * cos(x * PI * 0.5)
		top.append(Vector2(x, h))
		bot.append(Vector2(x, -h * 0.8))
	var out: Array = [top, bot,
		_arc(Vector2(0.05, 0.0), 0.34, 0.34, 0.0, TAU, 24),
		_arc(Vector2(0.05, 0.0), 0.13, 0.13, 0.0, TAU, 12),
		_arc(Vector2(0.05, 0.0), 0.06, 0.06, 0.0, TAU, 8),
		_poly([-1.0, 0.0, -0.75, 0.06, -0.55, -0.03, -0.3, 0.04]),
		_poly([1.0, 0.0, 0.8, -0.05, 0.6, 0.04, 0.4, -0.02]),
		_poly([0.4, -0.3, 0.42, -0.6, 0.4, -0.95])]
	for k in 6:
		var lx := lerpf(-0.7, 0.7, k / 5.0)
		var ly := 0.5 * cos(lx * PI * 0.5)
		out.append(_poly([lx, ly, lx * 1.12, ly + 0.28]))
	return _xf(out, c, s)

## Eyes everywhere, all looking at you
static func _eyes() -> Array:
	var out: Array = []
	for e in [[-0.55, 0.55, 0.38], [0.5, 0.6, 0.32], [0.0, 0.1, 0.5], [-0.6, -0.35, 0.3],
			[0.55, -0.3, 0.4], [0.05, -0.75, 0.28], [-0.05, 0.88, 0.2]]:
		out.append_array(_eye(Vector2(e[0], e[1]), e[2]))
	return out

## A round face with huge dead eyes and a grin that is too wide, full of teeth
static func _grin() -> Array:
	var out: Array = [_arc(Vector2.ZERO, 0.95, 0.95, 0.0, TAU, 40)]
	for sx in [-1.0, 1.0]:
		out.append(_arc(Vector2(sx * 0.35, 0.32), 0.13, 0.2, 0.0, TAU, 14))
		out.append(_arc(Vector2(sx * 0.35, 0.32), 0.04, 0.06, 0.0, TAU, 8))
	var mouth := PackedVector2Array()
	for i in 21:
		var x := lerpf(-0.7, 0.7, i / 20.0)
		mouth.append(Vector2(x, _grin_y(x, 0.4)))
	for i in range(20, -1, -1):
		var x := lerpf(-0.7, 0.7, i / 20.0)
		mouth.append(Vector2(x, _grin_y(x, 0.75)))
	mouth.append(mouth[0])
	out.append(mouth)
	for k in 9:
		var x := lerpf(-0.6, 0.6, k / 8.0)
		out.append(PackedVector2Array([Vector2(x, _grin_y(x, 0.4)), Vector2(x, _grin_y(x, 0.75))]))
	return out

static func _grin_y(x: float, depth: float) -> float:
	var u := x / 0.7
	return -0.05 - depth * (1.0 - u * u)

## A tall faceless figure, arms down past its knees, long fingers
static func _figure() -> Array:
	var out: Array = [
		_arc(Vector2(0, 0.82), 0.09, 0.14, 0.0, TAU, 14),
		_poly([0, 0.68, 0, -0.2]),
		_poly([0, 0.55, -0.22, 0.1, -0.3, -0.5, -0.28, -0.85]),
		_poly([0, 0.55, 0.2, 0.05, 0.34, -0.45, 0.4, -0.95]),
		_poly([0, -0.2, -0.1, -0.6, -0.13, -1.0]),
		_poly([0, -0.2, 0.1, -0.6, 0.14, -1.0])]
	for f in [[-0.28, -0.85], [0.4, -0.95]]:
		for d in [-0.05, 0.0, 0.05]:
			out.append(_poly([f[0], f[1], f[0] + d * 2.0, f[1] - 0.12]))
	return out

## A handprint with one finger too many
static func _hand() -> Array:
	var out: Array = [
		_arc(Vector2(0, -0.4), 0.45, 0.5, PI, TAU, 16),
		_poly([-0.45, -0.4, -0.42, -0.1]),
		_poly([0.45, -0.4, 0.45, -0.1])]
	for f in [[-0.28, -0.05, 12.0, 0.7], [-0.1, -0.02, 4.0, 0.95], [0.08, -0.02, -3.0, 1.0],
			[0.26, -0.05, -12.0, 0.8], [0.4, -0.3, 70.0, 0.55], [-0.4, -0.25, -60.0, 0.5]]:
		out.append(_finger(Vector2(f[0], f[1]), f[2], f[3], 0.075))
	return out

## A thin finger from `base`, `deg` off vertical (positive leans right)
static func _finger(base: Vector2, deg: float, length: float, w: float) -> PackedVector2Array:
	var ang := deg_to_rad(90.0 - deg)
	var dir := Vector2.from_angle(ang)
	var perp := Vector2(dir.y, -dir.x)
	var out := PackedVector2Array([base + perp * w])
	out.append_array(_arc(base + dir * (length - w), w, w, ang - PI * 0.5, ang + PI * 0.5, 8))
	out.append(base - perp * w)
	return out

static func _skull() -> Array:
	var cranium := _arc(Vector2(0, 0.25), 0.75, 0.7, PI * 1.12, -PI * 0.12, 24)
	cranium.append_array(_poly([0.45, -0.35, 0.45, -0.8, -0.45, -0.8, -0.45, -0.35, -0.7, -0.01]))
	var out: Array = [cranium,
		_poly([0, -0.1, -0.1, -0.35, 0.1, -0.35, 0, -0.1]),
		_poly([-0.45, -0.6, 0.45, -0.6]),
		_poly([0.1, 0.9, 0.05, 0.7, 0.15, 0.55, 0.08, 0.4])]
	for sx in [-1.0, 1.0]:
		out.append(_arc(Vector2(sx * 0.3, 0.15), 0.2, 0.22, 0.0, TAU, 14))
		out.append(_arc(Vector2(sx * 0.3, 0.15), 0.08, 0.09, 0.0, TAU, 8))
	for k in 7:
		var x := -0.45 + 0.15 * k
		out.append(_poly([x, -0.8, x, -0.6]))
	return out

## Four deep scratches
static func _claws() -> Array:
	var out: Array = []
	var tops := [0.9, 0.8, 0.95, 0.85]
	var bottoms := [-0.85, -0.95, -0.8, -0.9]
	for i in 4:
		var q := PackedVector2Array()
		for j in 13:
			var t := j / 12.0
			q.append(Vector2(-0.45 + i * 0.3 + 0.18 * sin(t * PI * 0.9), lerpf(tops[i], bottoms[i], t)))
		out.append(q)
	return out

## Angry scribbling, different every time
static func _scribble() -> Array:
	var out: Array = []
	for s in 3:
		var q := PackedVector2Array()
		for i in 26:
			q.append(Vector2.from_angle(randf() * TAU) * sqrt(randf()) * 0.9)
		out.append(q)
	return out

## Days counted on the wall
static func _tally() -> Array:
	var out: Array = []
	for r in 3:
		for g in 3:
			var marks := 5
			if r == 2 and g == 1:
				marks = 3
			elif r == 2 and g == 2:
				marks = 0
			var gx := -0.9 + g * 0.6
			var gy := 0.6 - r * 0.6
			for k in mini(marks, 4):
				out.append(_poly([gx + k * 0.12, gy, gx + k * 0.12 + 0.01, gy + 0.5]))
			if marks == 5:
				out.append(_poly([gx - 0.06, gy + 0.1, gx + 0.42, gy + 0.4]))
	return out

static func _spiral() -> Array:
	var q := PackedVector2Array()
	for i in 91:
		var t := i / 90.0
		q.append(Vector2.from_angle(t * TAU * 4.0) * (0.95 * t))
	return [q]

## Something wet dripping down the wall
static func _drips() -> Array:
	var smear := PackedVector2Array()
	for i in 21:
		var x := lerpf(-1.0, 1.0, i / 20.0)
		smear.append(Vector2(x, 0.7 + 0.04 * sin(x * 9.0)))
	var out: Array = [smear]
	var xs := [-0.85, -0.6, -0.3, -0.1, 0.2, 0.45, 0.7, 0.9]
	var lens := [0.9, 0.4, 1.3, 0.6, 1.0, 0.5, 1.5, 0.7]
	for i in xs.size():
		out.append(_poly([xs[i], 0.7, xs[i] + 0.01, 0.7 - lens[i]]))
		out.append(_arc(Vector2(xs[i] + 0.01, 0.7 - lens[i] - 0.04), 0.04, 0.04, 0.0, TAU, 8))
	return out

static func _ring(c: Vector2, r: float, n := 20) -> PackedVector2Array:
	return _arc(c, r, r, 0.0, TAU, n)

## A face that cries, tears running past its chin
static func _cry() -> Array:
	var out: Array = [_ring(Vector2.ZERO, 0.95, 40)]
	for sx in [-1.0, 1.0]:
		out.append(_ring(Vector2(sx * 0.35, 0.25), 0.13, 12))
		out.append(_poly([sx * 0.35, 0.12, sx * 0.37, -0.3, sx * 0.33, -0.7, sx * 0.36, -1.0]))
	var mouth := PackedVector2Array()
	for i in 13:
		var x := lerpf(-0.4, 0.4, i / 12.0)
		var u := x / 0.4
		mouth.append(Vector2(x, -0.65 + 0.25 * (1.0 - u * u)))
	out.append(mouth)
	return out

## Crossed-out eyes and a mouth sewn shut
static func _xeyes() -> Array:
	var out: Array = [_ring(Vector2.ZERO, 0.95, 40), _poly([-0.5, -0.4, 0.5, -0.4])]
	for sx in [-1.0, 1.0]:
		out.append(_poly([sx * 0.35 - 0.12, 0.4, sx * 0.35 + 0.12, 0.1]))
		out.append(_poly([sx * 0.35 + 0.12, 0.4, sx * 0.35 - 0.12, 0.1]))
	for k in 7:
		var x := -0.5 + k / 6.0
		out.append(_poly([x, -0.52, x + 0.02, -0.28]))
	return out

static func _spider() -> Array:
	var out: Array = [_arc(Vector2.ZERO, 0.2, 0.25, 0.0, TAU, 14), _ring(Vector2(0, 0.38), 0.1, 10)]
	var knees := [0.7, 0.35, 0.0, -0.4]
	var feet := [0.3, -0.2, -0.6, -0.95]
	for side in [-1.0, 1.0]:
		for i in 4:
			out.append(_poly([side * 0.15, 0.1 - i * 0.08, side * 0.6, knees[i], side * 0.95, feet[i]]))
	return out

static func _web() -> Array:
	var out: Array = []
	for k in 8:
		out.append(_poly([0, 0, cos(k * PI * 0.25) * 0.95, sin(k * PI * 0.25) * 0.95]))
	for r in [0.25, 0.5, 0.75]:
		var q := PackedVector2Array()
		for k in 17:
			var rr: float = r if k % 2 == 0 else r * 0.88
			q.append(Vector2.from_angle(k * PI * 0.125) * rr)
		out.append(q)
	return out

## Thin tentacles reaching up from below
static func _tentacles() -> Array:
	var out: Array = []
	var xs := [-0.6, 0.0, 0.6]
	var hs := [1.5, 1.9, 1.3]
	for i in 3:
		var left := PackedVector2Array()
		var right := PackedVector2Array()
		for j in 25:
			var t := j / 24.0
			var cx: float = xs[i] + 0.25 * sin(t * 8.0 + i * 2.0) * (0.4 + t * 0.6)
			var y: float = -1.0 + t * hs[i]
			var w := 0.07 * (1.0 - t) + 0.01
			left.append(Vector2(cx - w, y))
			right.append(Vector2(cx + w, y))
		right.reverse()
		left.append_array(right)
		out.append(left)
	return out

## A closed door with a peephole eye and a hand-worn knob
static func _door() -> Array:
	var out: Array = [
		_poly([-0.5, -1, -0.5, 0.9, 0.5, 0.9, 0.5, -1]),
		_poly([-0.35, 0.7, 0.35, 0.7, 0.35, 0.1, -0.35, 0.1, -0.35, 0.7]),
		_poly([-0.35, -0.1, 0.35, -0.1, 0.35, -0.8, -0.35, -0.8, -0.35, -0.1]),
		_ring(Vector2(0.35, -0.25), 0.05, 8)]
	out.append_array(_eye(Vector2(0, 0.4), 0.2))
	return out

## A fat arrow pointing down at the floor
static func _arrow() -> Array:
	return [_poly([-0.08, 0.9, -0.08, -0.15, -0.4, -0.15, 0, -0.9, 0.4, -0.15, 0.08, -0.15, 0.08, 0.9, -0.08, 0.9])]

## A huge open mouth, teeth top and bottom
static func _maw() -> Array:
	var out: Array = [_arc(Vector2.ZERO, 0.95, 0.7, 0.0, TAU, 40)]
	for side in [1.0, -1.0]:
		for k in 8:
			var a: float = side * lerpf(0.12 * PI, 0.88 * PI, k / 7.0)
			var tip := Vector2(cos(a) * 0.95, sin(a) * 0.7) * 0.55
			var b0 := Vector2(cos(a - 0.1), sin(a - 0.1) * 0.74) * Vector2(0.95, 0.7)
			var b1 := Vector2(cos(a + 0.1), sin(a + 0.1) * 0.74) * Vector2(0.95, 0.7)
			out.append(PackedVector2Array([b0, tip, b1]))
	return out

## A horned head with slit eyes and a jagged mouth
static func _demon() -> Array:
	var out: Array = [_arc(Vector2(0, -0.1), 0.6, 0.7, 0.0, TAU, 28)]
	var mouth := PackedVector2Array()
	for k in 9:
		mouth.append(Vector2(-0.4 + k * 0.1, -0.45 - (k % 2) * 0.12))
	out.append(mouth)
	for sx in [-1.0, 1.0]:
		out.append(_poly([sx * 0.4, 0.5, sx * 0.65, 0.65, sx * 0.85, 0.95, sx * 0.5, 0.8]))
		out.append(_poly([sx * 0.12, 0.0, sx * 0.4, 0.2, sx * 0.38, 0.05, sx * 0.12, 0.0]))
		out.append(_poly([sx * 0.2, -0.45, sx * 0.15, -0.75, sx * 0.1, -0.45]))
	return out

## Just two slanted eyes and a smile that goes from edge to edge
static func _smiler() -> Array:
	var out: Array = []
	for sx in [-1.0, 1.0]:
		out.append(_arc(Vector2(sx * 0.45, 0.45), 0.1, 0.15, 0.0, TAU, 12))
		out.append(_arc(Vector2(sx * 0.45, 0.45), 0.03, 0.05, 0.0, TAU, 6))
	var top := PackedVector2Array()
	var bot := PackedVector2Array()
	for i in 25:
		var x := lerpf(-0.95, 0.95, i / 24.0)
		var u := x / 0.95
		top.append(Vector2(x, -0.1 - 0.35 * (1.0 - u * u)))
		bot.append(Vector2(x, -0.1 - 0.75 * (1.0 - u * u)))
	out.append(top)
	out.append(bot)
	for k in 12:
		var i := 1 + k * 2
		out.append(PackedVector2Array([top[i], bot[i]]))
	return out

static func _stick(x: float, base: float, h: float) -> Array:
	return [_ring(Vector2(x, base + h * 0.88), h * 0.09, 10),
		_poly([x, base + h * 0.79, x, base + h * 0.4]),
		_poly([x - h * 0.2, base + h * 0.55, x, base + h * 0.7, x + h * 0.2, base + h * 0.55]),
		_poly([x - h * 0.15, base, x, base + h * 0.4, x + h * 0.15, base])]

## A child's drawing of the family. One of them is scribbled out, and there is one too many
static func _family() -> Array:
	var out: Array = []
	out.append_array(_stick(-0.7, -0.95, 1.5))
	out.append_array(_stick(-0.2, -0.95, 1.4))
	out.append_array(_stick(0.3, -0.95, 0.8))
	out.append_array(_stick(0.8, -0.95, 1.9))
	out.append(_poly([0.1, -0.9, 0.5, -0.7, 0.1, -0.5, 0.5, -0.3, 0.1, -0.1, 0.5, 0.0, 0.1, -0.85]))
	return out

## A child's sun, frowning
static func _sun() -> Array:
	var out: Array = [_ring(Vector2.ZERO, 0.4, 24)]
	for k in 12:
		var a := k * TAU / 12.0
		var l := 0.75 + 0.2 * (k % 2)
		out.append(_poly([cos(a) * 0.5, sin(a) * 0.5, cos(a) * l, sin(a) * l]))
	for sx in [-1.0, 1.0]:
		out.append(_ring(Vector2(sx * 0.15, 0.1), 0.04, 8))
	out.append(_arc(Vector2(0, -0.28), 0.15, 0.1, PI * 0.1, PI * 0.9, 8))
	return out

static func _crack() -> Array:
	return [_poly([0, 0.95, -0.1, 0.7, 0.05, 0.45, -0.12, 0.15, 0.08, -0.15, -0.05, -0.45, 0.1, -0.7, 0, -0.95]),
		_poly([-0.1, 0.7, -0.4, 0.6, -0.55, 0.35]), _poly([0.05, 0.45, 0.4, 0.35, 0.6, 0.5]),
		_poly([-0.12, 0.15, -0.45, 0.05, -0.7, -0.15]), _poly([0.08, -0.15, 0.45, -0.25, 0.7, -0.2]),
		_poly([-0.05, -0.45, -0.35, -0.55, -0.5, -0.8]), _poly([0.1, -0.7, 0.3, -0.8, 0.5, -0.95])]

## A pentagram in a double circle
static func _occult() -> Array:
	var star := PackedVector2Array()
	for k in [0, 2, 4, 1, 3, 0]:
		star.append(Vector2.from_angle(PI * 0.5 + k * TAU / 5.0) * 0.85)
	return [_ring(Vector2.ZERO, 0.95, 40), _ring(Vector2.ZERO, 0.88, 40), star]

## An eye in a triangle
static func _watcher() -> Array:
	var out: Array = [_poly([-0.95, -0.8, 0, 0.85, 0.95, -0.8, -0.95, -0.8])]
	out.append_array(_eye(Vector2(0, -0.2), 0.45))
	return out

## Long fingers gripping up from below
static func _fingers() -> Array:
	var out: Array = []
	var xs := [-0.7, -0.35, 0.0, 0.35, 0.7]
	var degs := [-15.0, -6.0, 0.0, 7.0, 16.0]
	var lens := [1.2, 1.6, 1.9, 1.7, 1.3]
	for i in 5:
		out.append(_finger(Vector2(xs[i], -1.0), degs[i], lens[i], 0.07))
	return out

## A stitched-up wound
static func _stitch() -> Array:
	var a := PackedVector2Array()
	var b := PackedVector2Array()
	for i in 25:
		var x := lerpf(-0.95, 0.95, i / 24.0)
		a.append(Vector2(x, 0.06 + 0.02 * sin(x * 10.0)))
		b.append(Vector2(x, -0.06 + 0.02 * sin(x * 10.0 + 1.0)))
	var out: Array = [a, b]
	for k in 12:
		var x := -0.88 + k * 0.16
		out.append(_poly([x, 0.16, x + 0.04, -0.16]))
	return out

## Two rows of happy faces, and the last one is wrong
static func _smileys() -> Array:
	var out: Array = []
	for r in 2:
		var cy := 0.5 - r * 1.0
		for k in 5:
			var c := Vector2(-0.76 + k * 0.38, cy)
			out.append(_ring(c, 0.15, 14))
			if r == 1 and k == 4:
				out.append(_ring(c + Vector2(-0.06, 0.04), 0.045, 8))
				out.append(_ring(c + Vector2(0.06, 0.04), 0.012, 6))
				out.append(_poly([c.x - 0.11, c.y - 0.03, c.x - 0.05, c.y - 0.1, c.x, c.y - 0.03,
					c.x + 0.05, c.y - 0.11, c.x + 0.11, c.y - 0.03]))
			else:
				for sx in [-1.0, 1.0]:
					out.append(_ring(c + Vector2(sx * 0.05, 0.04), 0.018, 6))
				out.append(_arc(c + Vector2(0, -0.01), 0.08, 0.06, PI * 1.1, PI * 1.9, 8))
	return out

## Bare footprints coming this way
static func _footprints() -> Array:
	var out: Array = []
	for i in 8:
		var x := -0.25 if i % 2 == 0 else 0.25
		var y := -0.85 + i * 0.25
		out.append(_arc(Vector2(x, y), 0.08, 0.12, 0.0, TAU, 10))
		for t in [-0.05, 0.0, 0.05]:
			out.append(_ring(Vector2(x + t, y + 0.16), 0.025, 6))
	return out

## One huge unblinking eye
static func _iris() -> Array:
	var out: Array = []
	for r in [0.95, 0.8, 0.62, 0.45, 0.28, 0.12]:
		out.append(_ring(Vector2.ZERO, r, 36))
	for k in 16:
		var a := k * TAU / 16.0
		out.append(_poly([cos(a) * 0.12, sin(a) * 0.12, cos(a) * 0.62, sin(a) * 0.62]))
	return out

## Scratched-in words, a little shaky
static func _text(s: String) -> Array:
	var rows := s.split("\n")
	var width := 0.0
	for r in rows:
		width = maxf(width, r.length() * 5.0 - 1.0)
	var height := 6.0 + (rows.size() - 1) * 9.0
	var k := 2.0 / maxf(width, height)
	var out: Array = []
	for ri in rows.size():
		var row: String = rows[ri]
		var x0 := (width - (row.length() * 5.0 - 1.0)) * 0.5
		var y0 := height - 6.0 - ri * 9.0
		for ci in row.length():
			var g: Array = GLYPHS.get(row[ci], [])
			for st in g:
				var q := PackedVector2Array()
				for i in range(0, st.size() - 1, 2):
					var jit := Vector2(randf_range(-0.12, 0.12), randf_range(-0.12, 0.12))
					q.append((Vector2(x0 + ci * 5.0 + st[i], y0 + st[i + 1]) + jit - Vector2(width, height) * 0.5) * k)
				out.append(q)
	return out
