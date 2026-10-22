extends Node3D
## THE REFLECTIONS (render engine v2): what glass, steel, glazed tile and a polished floor show of the room.
##
## Screen-space reflections are out for good (graphics.gd: the per-frame compute passes behind the GPU resets), so
## the room is captured instead: a few ReflectionProbes on a lattice every LATTICE cells, the nearest ones to the
## player, each rendered ONCE when it is put down (six ordinary raster views, no compute) and left as it is. The
## ceiling lamps are a pool that follows the player (level_light_pool.gd), so a probe is only put down near the
## player, where they are lit, and a far one is let go rather than kept showing a room as it was. Box projection
## lines each capture up with the room's walls, so the reflection of a doorway is where the doorway is.
##
## How many there are is the preset's (Gfx `reflections`: 0 none, the room reflects only the ambient). New probes
## are put down one a frame at most, so a capture is never more than one probe's six views in one frame.

const LATTICE := 2                     # cells between probes
const REACH := 1.3                     # a probe's box, in lattice steps (overlap for the blend)
const BLEND := 1.5                     # metres a probe's box blends into its neighbour's
const MOVE_EVERY := 0.25               # s between looks at where the player is

var level: Node                        # the level builder (level_data.gd): walls, ceiling_height
var _probes := {}                      # Vector2i lattice point -> ReflectionProbe
var _t := 0.0
var _last := Vector2i(1 << 30, 0)      # the lattice point the player was nearest on the last look

func _process(delta: float) -> void:
	_t -= delta
	if _t > 0.0: return
	_t = MOVE_EVERY
	var p := Game.player as Node3D
	var want := clampi(int(Gfx.s.get("reflections", 0)), 0, 12)
	if p == null or level == null or want == 0:
		if not _probes.is_empty(): _clear()
		return
	var cell: float = level.CELL
	var step := cell * LATTICE
	var here := Vector2i(roundi(p.global_position.x / step), roundi(p.global_position.z / step))
	# the nearest lattice points that are in a room (not inside a wall), nearest first
	var near: Array = []
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			var k := here + Vector2i(dx, dy)
			if level.walls.has(k * LATTICE): continue
			near.append(k)
	var at := Vector2(p.global_position.x, p.global_position.z) / step
	near.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return at.distance_squared_to(Vector2(a)) < at.distance_squared_to(Vector2(b)))
	near.resize(mini(want, near.size()))
	for k: Vector2i in _probes.keys():
		if not near.has(k):
			_probes[k].queue_free()
			_probes.erase(k)
	# a new capture waits until the player has been by it a look (the lamps round it fade in as you come)
	var settled := here == _last
	_last = here
	if not settled: return
	for k: Vector2i in near:
		if not _probes.has(k):
			_probes[k] = _probe(k, step)
			return                         # one new capture a look

func _probe(k: Vector2i, step: float) -> ReflectionProbe:
	var c: Vector2i = k * LATTICE
	var h: float = level.ceiling_height(c)
	var r := ReflectionProbe.new()
	r.update_mode = ReflectionProbe.UPDATE_ONCE
	r.box_projection = true
	r.interior = true                  # no sky in here: what it doesn't see is the room's ambient
	r.size = Vector3(step * REACH, h, step * REACH)
	r.origin_offset = Vector3(0.0, 1.6 - h * 0.5, 0.0)     # captured from eye height, not the middle of a tall room
	r.blend_distance = BLEND
	r.max_distance = step * 3.0
	r.mesh_lod_threshold = 4.0          # the captures are blurred by the gloss anyway: coarse meshes do
	r.position = Vector3(k.x * step, h * 0.5, k.y * step)
	add_child(r)
	return r

func _clear() -> void:
	for r: Node in _probes.values(): r.queue_free()
	_probes.clear()
