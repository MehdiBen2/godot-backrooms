extends RefCounted
## How a place sounds (audio.gd follows it with the World and Steps reverbs as you walk): worked out from the
## architecture round each cell of the floor, the first time anyone stands in it, and kept.
##  - how far sound runs before it meets a wall: RAYS lines out across the plan, stopped by wall blocks and by
##    every wall placed as an object (curved and spline walls, pillars, columns: level_data.gd wall_segments);
##  - how high the ceiling is (a grand hall, an open ceiling: a long way up);
##  - what it is made of: tiles, concrete, water ring; carpet and wallpaper soak it up;
##  - a round room (lines out nearly all the same length) focuses its echoes and rings on.
## A big hard space gives a long, bright, wet tail; a tight low corridor a short, dark one with the highs gone. The
## level editor's Hall reverb and Muffled zones say so outright, over whatever the shape gives (and its AUTO
## ACOUSTICS button paints them from the same reckoning).

const RAYS := 16
const STEP := 0.6                  # m along a line between looks at the plan
const REACH := 42.0                # m: a line goes no further than this
const HALL := {"size": 0.98, "damp": 0.12, "wet": 0.55, "cut": 16000.0, "pre": 60.0}
const DEAD := {"size": 0.1, "damp": 0.97, "wet": 0.03, "cut": 2400.0, "pre": 2.0}

var level: Node
var _cells := {}                   # Vector2i -> its profile
var _segs := {}                    # Vector2i -> the wall spans that pass through that cell ([a, b] in cells)
var _hard_walls := 0.3             # how hard the level's walls are (0 soft .. 1 hard)
var _hard_floor := 0.0

func _init(lv: Node) -> void:
	level = lv
	for s: Array in lv.wall_segments:
		if s[3]: continue                               # a half wall: sound goes over it
		var a: Vector2 = s[0]
		var b: Vector2 = s[1]
		var r: float = float(s[2]) / float(lv.CELL) + 0.05
		for x in range(floori(minf(a.x, b.x) - r - 0.5), ceili(maxf(a.x, b.x) + r + 0.5) + 1):
			for z in range(floori(minf(a.y, b.y) - r - 0.5), ceili(maxf(a.y, b.y) + r + 0.5) + 1):
				_segs.get_or_add(Vector2i(x, z), []).append(s)
	var mats: Dictionary = lv.level_data.get("materials", {})
	_hard_walls = _hardness(str(mats.get("wall", "")), 0.3)
	_hard_floor = _hardness(str(mats.get("floor", "")), 0.0) - 0.1

## Tiles, concrete, metal, brick: hard; anything else a little; the Level 0 wallpaper / carpet (no material): soft
static func _hardness(id: String, none: float) -> float:
	if id == "": return none
	var l := id.to_lower()
	for hard in ["tile", "concrete", "metal", "brick", "brc", "road", "ground"]:
		if l.contains(hard): return 0.8
	return 0.45

## How the place round level point `p` sounds: {size, damp, wet (0..1, AudioEffectReverb's), cut (Hz: the world's
## low-pass), pre (ms: the pre-delay)}
func profile_at(p: Vector3) -> Dictionary:
	var c := Vector2i(roundi(p.x / level.CELL), roundi(p.z / level.CELL))
	if not _cells.has(c): _cells[c] = _work_out(c)
	return _cells[c]

func _work_out(c: Vector2i) -> Dictionary:
	if level.hall_reverb.has(c): return HALL
	if level.muffled.has(c): return DEAD
	var from: Vector2 = Vector2(c) * float(level.CELL)
	var lens: Array[float] = []
	var total := 0.0
	for i in RAYS:
		var d := Vector2.from_angle(TAU * (i + 0.5) / RAYS)
		var l := _cast(from, d)
		lens.append(l)
		total += l
	var mfp := total / RAYS                              # ~3 m in a corridor, 30+ in a hall
	var spread := 0.0
	for l in lens: spread += (l - mfp) * (l - mfp)
	var even := 1.0 - sqrt(spread / RAYS) / maxf(mfp, 0.1)     # 1: every way the same distance (a round room)
	var h: float = level.ceiling_height(c)
	if level.open_above.has(c) or level.endless_ceiling.has(c): h = 20.0
	var hard := _hard_walls
	if level.tiles.has(c): hard += 0.15
	else: hard += _hard_floor * 0.5
	if not (level.water_at(Vector3(from.x, 0.0, from.y)) as Dictionary).is_empty(): hard += 0.25
	hard = clampf(hard, 0.0, 1.0)
	var size := clampf(0.12 + mfp / 34.0 + maxf(h - level.WALL_H, 0.0) / 22.0, 0.08, 0.98)
	if even > 0.75 and mfp > 5.0: size = minf(0.98, size + 0.1 * hard)
	var damp := clampf(0.88 - 0.55 * hard - 0.15 * size, 0.08, 0.95)
	# Lowered wetness overall so it sounds less muddy/weird
	var wet := clampf(0.04 + size * (0.12 + 0.2 * hard), 0.02, 0.4)
	# tight and low: short, dark and dull
	# When walls are closely surrounding the player (small rooms, corridors), kill the reverb completely
	# Nerfed significantly: requires huge open spaces (mfp > 30) for full reverb
	var tight := clampf((30.0 - mfp) / 15.0, 0.0, 1.0) * (1.0 if h <= level.WALL_H + 0.01 else 0.9)
	if h <= level.LOW_H + 0.01: tight = maxf(tight, 0.8)
	if h <= level.CRAWL_H + 0.01: tight = 1.0
	damp = lerpf(damp, 0.98, tight)
	wet = lerpf(wet, 0.0, tight) # completely mute reverb in tight spaces
	size = lerpf(size, 0.01, tight)
	return {"size": size, "damp": damp, "wet": wet, "cut": lerpf(16000.0, 3200.0, tight), "pre": clampf(mfp * 1.6, 3.0, 70.0)}

## How far (m) a line from level point `from` (on the plan, metres) runs along `d` before a wall stops it
func _cast(from: Vector2, d: Vector2) -> float:
	var cell: float = level.CELL
	var t := STEP
	var last := from
	while t < REACH:
		var at := from + d * t
		var c := Vector2i(roundi(at.x / cell), roundi(at.y / cell))
		if (level.walls.has(c) or level.crawl.has(c)) and not level.carved.has(c): return t
		var near: Array = _segs.get(c, [])
		for s: Array in near:
			if Geometry2D.segment_intersects_segment(last / cell, at / cell, s[0], s[1]) != null: return t
			# (a pillar or column is a span of no length: a circle round it)
			if (s[0] as Vector2).is_equal_approx(s[1]) and (at / cell).distance_to(s[0]) < float(s[2]) / cell: return t
		last = at
		t += STEP
	return REACH
