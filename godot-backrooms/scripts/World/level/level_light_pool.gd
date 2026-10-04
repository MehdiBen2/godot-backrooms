extends "res://scripts/World/level/level_fixtures.gd"
## THE LEVEL, layer 3b: the pool of real lights (the web game's lighting.js).
##
## Only a small pool of real lights exists: POOL_SIZE slots re-targeted to the nearest working tubes and cross-
## faded so nothing pops (each slot also drives one spatial hum voice in audio.gd). How many of those are
## actually lit, and how many of the nearest cast shadows, comes from the graphics preset (Gfx `lights` /
## `light_shadows`), which is what keeps this playable on a weak PC. Past them, cheap shadowless far lights
## (Gfx `far_lights`) keep distant walls lit. The tube-light estimate that drives sanity, fog and the
## entity's sight (tube_light_at) is the same on every preset.
##
## Cost: the ranking reads only the tubes in the index squares round the player (level_fixtures.gd), sight lines
## are kept per half cell (_look_from), and a light's energy or position is written only when it changes, so a
## player standing still costs the renderer nothing here.

signal slot_assigned(slot: int)                              # a light came into range (hum "notice")

const LIGHT_RANGE := 20.0
const LIGHT_COLOR := Color(1.0, 0.93, 0.78)
const CLASSIC_BOOST := 1.6          # classic-zone tubes are this much brighter
const POOL_SIZE := 12
const SELECT_RADIUS := 26.0
const FADE_START := 18.0
# Far lights: past the main pool every tube you can see still lights the walls round it. Cheap, shadowless,
# short-ranged spots like the near ones (Forward+ clusters them) on the next nearest tubes out to FAR_RADIUS; how many
# comes from the graphics preset (Gfx `far_lights`). Same range and falloff as the near lights, so a wall
# 30 m away is lit exactly like the same wall up close (anything else reads as a flat, fake distance).
const FAR_MAX := 32
const FAR_RADIUS := 46.0
const FAR_FADE := 36.0
# Ceiling glow: the tube lights skip the ceiling (CEIL_LAYER, level_geometry.gd), so each lit slot also drives a
# soft light further down that only reaches the ceiling: the broad halo round a real troffer, never a hotspot.
# It only ever lights the CEIL_LAYER mesh (never walls), so walls can never occlude it: it has no way to
# know a corner is in the way. Its range is kept well under CELL (level_data.gd) so the halo stays inside
# the fixture's own cell instead of bleeding over a nearby wall onto a corridor the fixture isn't even in.
const CEIL_GLOW := 0.5              # of the slot's energy, tube fixtures (the ceiling round a troffer is well lit)
const CEIL_GLOW_PANEL := 0.2        # panel ceilings: the panels themselves already light up the tiles round them
# a little specular from the glow: the painted T-bars catch a glinting line of it, like a real grid under a
# troffer. Kept low: the tiles themselves are rough, but at full strength their broad sheen became a hotspot.
const CEIL_GLOW_SPECULAR := 0.35
const CEIL_GLOW_DROP := 1.6         # metres under the fixture: further down = wider, softer halo
const CEIL_GLOW_RANGE := 3.5
const BOUNCE_RADIUS := 7.0
const BOUNCE_FULL := 1.3
# Light leaks. Godot lights without a shadow go straight through walls, so a shadowless tube behind a wall
# paints the floor of the corridor you are in with no visible source. Shadowless lights (pool slots past the
# shadow budget, all far lights) are therefore only lit for tubes the player can see; a hidden tube near you
# gets one of the shadowed slots (the nearest ones) or stays dark. The test is on the grid, from where you
# stand and half a cell to each side, so a tube just round a corner still counts (its spill is real).
const HIDDEN_BOUNCE := 0.3          # tube_light_at: share of a tube behind a wall that still reaches you
const FAR_SCAN := 4                 # far lights look at up to this many times their cap to find visible tubes
# Real ceiling lights are big: a 60 cm diffuser panel or a 1.2 m tube. A 30 cm thin wall under one only
# throws a faint, very soft shadow, where a point light throws a hard black stripe. light_size is the size of
# the emitter for PCSS (contact-hardening soft shadows): sharp where things meet the floor, soft further out.
const PANEL_LIGHT_SIZE := 0.6       # metres: a lit panel
const TUBE_LIGHT_SIZE := 0.5        # metres: a troffer (Godot's emitter is a sphere, so a bit under the tube length)
# ---- panel ceilings (a ceiling material with baked light panels, see level_geometry.gd panel_ceiling)
# Every open cell is a fixture that owns its five panels (the texture repeats once per cell: one panel
# in the middle, four on the diagonals). Only every other cell each way glows and hides a real light behind
# its panels (a sparse, regular grid); the other cells' panel squares are drawn as plain ceiling tiles.
const PANEL_ENERGY := 1.9
const PANEL_RANGE := 16.0
# ---- light pool
# Spots pointing straight down, their cone like a diffuser's spread (level_fixtures.gd SPOT_ANGLE): a troffer
# lights the room under it, not the ceiling round it or the top of the wall beside it
var pool: Array[SpotLight3D] = []
var pool_b: Array[SpotLight3D] = []     # a twin for each slot: the two ends of the long tube (Godot has no area lights)
## The tubes' white for the zone the player is in (level_lighting.gd); each light takes it times its own lamp's
var tube_color := LIGHT_COLOR
const TWIN_RANGE := 15.0              # metres: beyond this only one light per tube
const TUBE_HALF := 0.65                # metres from the fixture centre to each end light
var slot_fixture: Array = []       # fixture Dictionary or null
var slot_weight: Array[float] = []
var slot_target: Array[float] = []
var slot_on: Array[float] = []     # 0..1: lit under the quality cap (eased, so a light never pops)
var slot_want: Array[bool] = []
var slot_single: Array[float] = [] # 0..1: how far a shadowed slot has pulled its two tube ends into one light
var _rank_timer := 0.0
var _candidates: Array = []
var _lit_cap := POOL_SIZE
var _shadow_cap := 4

var far_pool: Array[SpotLight3D] = []
var ceil_glow: Array[OmniLight3D] = []   # one per pool slot: lights only the ceiling layer
var far_fixture: Array = []        # fixture Dictionary or null
var far_weight: Array[float] = []
var _far_candidates: Array = []
var _far_cap := 16
func _read_quality() -> void:
	_lit_cap = clampi(int(Gfx.s.get("lights", POOL_SIZE)), 1, POOL_SIZE)
	_far_cap = clampi(int(Gfx.s.get("far_lights", 16)), 0, FAR_MAX)
	_shadow_cap = int(Gfx.s.get("light_shadows", 4)) if int(Gfx.s.get("shadows", 1)) > 0 else 0
	# High / Ultra: area-light soft shadows (PCSS). Medium keeps plain filtered shadows (cheaper) but blurs
	# them wider so the stripes behind thin walls still read as soft.
	var soft := int(Gfx.s.get("shadows", 1)) >= 2
	for l in pool:
		l.light_size = (PANEL_LIGHT_SIZE if panels_mm else TUBE_LIGHT_SIZE) if soft else 0.0
		l.shadow_blur = 1.0 if soft else 2.6
	_rank_timer = 0.0

# ---------------------------------------------------------------- light pool
## A ceiling lamp's light: a spot hung pointing straight down (its -Z), shadowless and dark until a tube takes it
func _lamp_light() -> SpotLight3D:
	var l := SpotLight3D.new()
	l.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
	l.light_color = LIGHT_COLOR
	l.spot_range = PANEL_RANGE if panels_mm else LIGHT_RANGE
	l.spot_attenuation = 1.15
	l.spot_angle = SPOT_ANGLE
	l.spot_angle_attenuation = SPOT_SOFT
	l.light_energy = 0.0
	l.shadow_enabled = false
	l.light_cull_mask &= ~(CEIL_LAYER | SHELL_LAYERS)     # the ceiling gets its glow from ceil_glow instead (no hotspot)
	l.visible = false
	l.set_meta("gfx_managed", true)      # Gfx.apply_scene leaves these to us
	return l

func _build_light_pool() -> void:
	for i in POOL_SIZE:
		var l := _lamp_light()
		l.light_size = 0.0                   # set by _read_quality (soft area-light shadows on High / Ultra)
		# A spot's shadow is one map (an omni's took six renders, and dual paraboloid bent the straight edge of
		# a thin wall into a banana-shaped shadow). Only the nearest `light_shadows` tubes cast at all (Gfx preset).
		l.shadow_bias = 0.04
		l.shadow_normal_bias = 1.2
		l.shadow_blur = 1.6
		add_child(l)
		pool.append(l)
		var lb := l.duplicate() as SpotLight3D           # the tube's other end; unshadowed (only the first casts)
		lb.set_meta("gfx_managed", true)
		add_child(lb)
		pool_b.append(lb)
		slot_fixture.append(null)
		slot_weight.append(0.0)
		slot_target.append(0.0)
		slot_on.append(0.0)
		slot_want.append(false)
		slot_single.append(0.0)
		var g := OmniLight3D.new()
		g.light_color = LIGHT_COLOR
		g.omni_range = CEIL_GLOW_RANGE
		g.omni_attenuation = 1.6
		g.light_cull_mask = CEIL_LAYER
		g.light_specular = CEIL_GLOW_SPECULAR
		g.shadow_enabled = false
		g.visible = false
		g.set_meta("gfx_managed", true)
		add_child(g)
		ceil_glow.append(g)
	for i in FAR_MAX:
		var fl := _lamp_light()
		add_child(fl)
		far_pool.append(fl)
		far_fixture.append(null)
		far_weight.append(0.0)

func slot_level(i: int) -> float:
	var f = slot_fixture[i]
	return 0.0 if f == null else f.level * slot_weight[i]

func slot_position(i: int) -> Vector3:
	var f = slot_fixture[i]
	return Vector3.ZERO if f == null else f.light_pos + _img(f)

## Where tube `f` is seen from the player, as an offset from where it hangs: nothing, or on an endless level
## (level_data.gd edge_wrap) the way to the copy of it nearest the player, set by _rank. Its real light goes
## there, so the far side of the seam is lit just like this side.
static func _img(f: Dictionary) -> Vector3:
	return f.get("img", Vector3.ZERO)

## The tubes in reach, nearest first. Only the index squares round the player are read (level_fixtures.gd
## fixtures_near), not every tube of the level; the ones the lights hold now are re-measured too, so a tube the
## player left behind (a teleport, a fall) is let go.
func _rank(p: Vector3) -> void:
	var max_sq := SELECT_RADIUS * SELECT_RADIUS
	var far_sq := FAR_RADIUS * FAR_RADIUS
	_candidates.clear()
	for held: Array in [slot_fixture, far_fixture]:
		for f in held:
			if f == null: continue
			if edge_wrap: f.img = wrap_near(f.pos, p) - f.pos
			var hx: float = f.pos.x + _img(f).x - p.x
			var hz: float = f.pos.z + _img(f).z - p.z
			f.dsq = hx * hx + hz * hz
			f.wanted = false
			f.far_wanted = false
	# on an endless level the tubes across the seam count too: the index is read round the player's spot as
	# seen from each copy of the level that comes within reach
	var looks: Array = [p]
	var found := {}
	if edge_wrap:
		looks.clear()
		var w := wrap_size()
		var lo := 0.5 * CELL - FAR_RADIUS
		var hi := (size - 1.5) * CELL + FAR_RADIUS
		for sx in range(-1, 2):
			for sz in range(-1, 2):
				var q := p - Vector3(sx * w, 0.0, sz * w)
				if q.x > lo and q.x < hi and q.z > lo and q.z < hi: looks.append(q)
	for q: Vector3 in looks:
		var span := _fx_span(q, FAR_RADIUS)
		for x in range(span[0].x, span[1].x + 1):
			for z in range(span[0].y, span[1].y + 1):
				var sq = _fx_grid.get(Vector2i(x, z))
				if sq == null: continue
				for f: Dictionary in sq:
					if edge_wrap:
						if found.has(f.index): continue       # (a small level: two copies of one tube within reach)
						found[f.index] = true
						f.img = wrap_near(f.pos, p) - f.pos
					var dx: float = f.pos.x + _img(f).x - p.x
					var dz: float = f.pos.z + _img(f).z - p.z
					f.dsq = dx * dx + dz * dz
					f.wanted = false
					f.far_wanted = false
					if f.dsq < far_sq and f.get("casts", true): _candidates.append(f)
	_candidates.sort_custom(func(a, b): return a.dsq < b.dsq)
	_look_from(p)
	# the far lights take over where the preset's lit cap stops (so a low preset still lights distant walls);
	# they never cast shadows, so only tubes you can see (see HIDDEN_BOUNCE)
	_far_candidates = []
	var i := mini(_lit_cap, _candidates.size())
	var scan_end := mini(_candidates.size(), i + _far_cap * FAR_SCAN)
	while i < scan_end and _far_candidates.size() < _far_cap:
		var fc: Dictionary = _candidates[i]
		if _seen(fc):
			fc.far_wanted = true
			_far_candidates.append(fc)
		i += 1
	var n := 0
	while n < mini(_candidates.size(), POOL_SIZE) and _candidates[n].dsq < max_sq:
		_candidates[n].wanted = true
		_candidates[n].seen = _seen(_candidates[n])
		n += 1
	_candidates.resize(n)

# Sight lines, cached. Each one is a walk across the grid, from up to five eyes, for up to 140 tubes, ten times
# a second: most of what the pool cost. They are worked out from the middle of the half cell the player is in
# (always inside the player's own cell) and kept until the player crosses into another half cell, so standing
# or walking within one asks nothing again. (The eyes already reach half a cell to each side, so the middle of
# the half cell sees what the player sees.)
const SEEN_NONE := Vector2i(-(1 << 30), 0)
var _seen_key := SEEN_NONE
var _seen_of := {}                  # lit index -> bool, for the eyes at _seen_key
var _look_eyes: Array = []

func _look_from(p: Vector3) -> void:
	var h := CELL * 0.5
	var key := Vector2i(floori(p.x / h), floori(p.z / h))
	if key == _seen_key: return
	_seen_key = key
	_seen_of.clear()
	_look_eyes = _eyes(Vector3((key.x + 0.5) * h, p.y, (key.y + 0.5) * h))

func _seen(f: Dictionary) -> bool:
	var i: int = f.index
	var v = _seen_of.get(i)
	if v == null:
		v = _seen_from(_look_eyes, f)
		_seen_of[i] = v
	return v

## Where the player can see from: their spot and half a cell to each open side (slack round corners)
func _eyes(p: Vector3) -> Array:
	# inside a stairwell: its walls shut every tube out, and a shadowless one would shine straight through them
	if stair_cells.has(cell_of(p)): return []
	var out: Array = [p]
	for o in [Vector3(CELL * 0.5, 0.0, 0.0), Vector3(-CELL * 0.5, 0.0, 0.0), Vector3(0.0, 0.0, CELL * 0.5), Vector3(0.0, 0.0, -CELL * 0.5)]:
		var q: Vector3 = p + o
		if not _solid(cell_of(q)): out.append(q)
	return out

func _seen_from(eyes: Array, f: Dictionary) -> bool:
	var at: Vector3 = f.pos + _img(f)
	for e in eyes:
		if _line_clear(e, at, true): return true
	return false

# Which slots are lit (the nearest `_lit_cap`) and which of those cast shadows (the nearest `_shadow_cap`)
func _rank_slots() -> void:
	var order: Array[int] = []
	for i in POOL_SIZE:
		slot_want[i] = false
		if slot_fixture[i] != null:
			order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool: return slot_fixture[a].dsq < slot_fixture[b].dsq)
	for r in order.size():
		var i := order[r]
		var shadow := r < _shadow_cap
		# a shadowless light on a tube you can't see would only shine through the wall at you
		slot_want[i] = r < _lit_cap and (shadow or slot_fixture[i].get("seen", true))
		if pool[i].shadow_enabled != shadow:
			pool[i].shadow_enabled = shadow

## Eases toward `target` and lands on it exactly once close: an exponential ease never quite arrives, and
## a light whose position creeps by a hair every frame has its whole cube shadow re-rendered every frame.
static func _ease_to(v: float, target: float, k: float) -> float:
	v += (target - v) * k
	return target if absf(target - v) < 0.002 else v

## Move a light only when it really moved: an unchanged light keeps its cached shadow map
static func _move(l: Node3D, p: Vector3) -> void:
	if not l.global_position.is_equal_approx(p):
		l.global_position = p

## Set a light's energy only when it really changed: every write is a renderer update, and the pool has up to
## 68 lights whose energy, once faded in, sits still
static func _energy(l: Light3D, e: float) -> void:
	if absf(l.light_energy - e) > 0.0005:
		l.light_energy = e

func _update_pool(delta: float) -> void:
	var p := player.global_position
	_rank_timer -= delta
	if _rank_timer <= 0.0:
		_rank_timer = 0.1
		_rank(p)
		for i in POOL_SIZE:
			var f = slot_fixture[i]
			if f == null: continue
			slot_target[i] = 1.0 if f.wanted else 0.0
			if slot_target[i] == 0.0 and slot_weight[i] < 0.02:
				_glow_real(f, "rw_slot", 0.0)
				f.slot = -1
				slot_fixture[i] = null
		for f in _candidates:
			if f.slot != -1: continue
			var free := slot_fixture.find(null)
			if free == -1: break
			slot_fixture[free] = f
			slot_target[free] = 1.0
			slot_weight[free] = 0.0
			f.slot = free
			slot_assigned.emit(free)
		_rank_slots()
		_assign_far()
	var k := minf(1.0, delta * 5.0)
	var k_on := minf(1.0, delta * 4.0)
	var fade_range := SELECT_RADIUS - FADE_START
	for i in POOL_SIZE:
		var l := pool[i]
		var f = slot_fixture[i]
		# (the eases land on their target: a weight creeping by a hair forever rewrote every light every frame)
		slot_on[i] = _ease_to(slot_on[i], 1.0 if (f != null and slot_want[i]) else 0.0, k_on)
		var lb := pool_b[i]
		if f == null:
			_energy(l, 0.0)
			l.visible = false
			lb.visible = false
			ceil_glow[i].visible = false
			continue
		slot_weight[i] = _ease_to(slot_weight[i], slot_target[i], k)
		var lp: Vector3 = f.light_pos + _img(f)         # (the copy nearest the player on an endless level)
		var d := sqrt(f.dsq)
		var t := clampf((d - FADE_START) / fade_range, 0.0, 1.0)
		var dist_fade := 1.0 - t * t * (3.0 - 2.0 * t)
		var cast := lamp_out(f)          # (a dead tube keeps a faint ember but lights nothing)
		var energy: float = (PANEL_ENERGY if panels_mm else LIGHT_ENERGY) * SPOT_GAIN * (CLASSIC_BOOST if f.classic else 1.0) * cast * slot_weight[i] * dist_fade * slot_on[i]
		l.visible = energy > 0.002
		# its own lamp's white (written only when it changes: a slot taking a new tube, the zone's white moving)
		var col: Color = tube_color * (f.get("warm", Color.WHITE) as Color)
		if not l.light_color.is_equal_approx(col):
			l.light_color = col
			lb.light_color = col
			ceil_glow[i].light_color = col
		_glow_real(f, "rw_slot", slot_weight[i] * dist_fade * slot_on[i])     # the fake floor light gives way to this one
		var g := ceil_glow[i]
		# the halo only reads as "coming from this fixture" while its real ceiling is close enough
		# to reach (a hanging fixture under a tall atrium ceiling is metres short of that: skip it
		# rather than paint a faint, disconnected glow patch on a ceiling far above the housing)
		var ceil_h: float = f.get("ceil_h", f.light_pos.y)
		var ceil_gap: float = ceil_h - f.light_pos.y
		var ceil_reach := clampf(1.0 - (ceil_gap - CEIL_GLOW_DROP) / (CEIL_GLOW_RANGE - CEIL_GLOW_DROP), 0.0, 1.0)
		g.visible = l.visible and ceil_reach > 0.0
		_move(g, Vector3(lp.x, ceil_h - CEIL_GLOW_DROP, lp.z))
		_energy(g, energy / SPOT_GAIN * (CEIL_GLOW_PANEL if panels_mm else CEIL_GLOW) * ceil_reach)
		if panels_mm:                        # square panels: one point light, no tube ends
			lb.visible = false
			_move(l, lp)
			_energy(l, energy)
			continue
		# One light at each end of the tube, so the floor is lit along its whole length, not from a point. Only
		# the first end can cast a shadow, and a shadowless twin next to it leaks through every wall round it,
		# so a shadowed slot eases both ends into one centred light instead. Far away the tube reads as a
		# point anyway: no twin, and the single light carries all of the energy (it used to keep only half,
		# so every tube doubled in brightness as you came within TWIN_RANGE).
		slot_single[i] = _ease_to(slot_single[i], 1.0 if l.shadow_enabled else 0.0, k)
		var twin := (1.0 - slot_single[i]) if f.dsq < TWIN_RANGE * TWIN_RANGE else 0.0
		lb.visible = l.visible and twin > 0.01
		var axis := Vector3(cos(f.rot), 0.0, -sin(f.rot)) * TUBE_HALF * twin
		_move(l, lp + axis)
		_move(lb, lp - axis)
		var share := 0.5 * twin if lb.visible else 0.0
		_energy(l, energy * (1.0 - share))
		_energy(lb, energy * share)
	_update_far(k)

## Every light the pool would fade in over the next half second, lit now: a floor that takes over under a
## player who is already looking at it (level_builder.gd, falling through a hole) must not start dark
func prime_pool() -> void:
	if player == null or pool.is_empty(): return
	_rank_timer = 0.0
	_update_pool(0.0)
	for i in POOL_SIZE:
		if slot_fixture[i] == null: continue
		slot_weight[i] = slot_target[i]
		slot_on[i] = 1.0 if slot_want[i] else 0.0
	for i in FAR_MAX:
		var f = far_fixture[i]
		if f != null: far_weight[i] = 1.0 if f.far_wanted else 0.0
	_update_pool(0.0)

# Far lights keep their tube while it stays wanted (no jumping about), fade out when it isn't, and a
# freed light fades in on the next tube out, so moving through the level never pops.
func _assign_far() -> void:
	for i in FAR_MAX:
		var f = far_fixture[i]
		if f != null and not f.far_wanted and far_weight[i] < 0.02:
			_glow_real(f, "rw_far", 0.0)
			f.far = -1
			far_fixture[i] = null
	for f in _far_candidates:
		if f.get("far", -1) != -1: continue
		var free := far_fixture.find(null)
		if free == -1: break
		far_fixture[free] = f
		far_weight[free] = 0.0
		f.far = free

func _update_far(k: float) -> void:
	var fade_range := FAR_RADIUS - FAR_FADE
	var base := (PANEL_ENERGY if panels_mm else LIGHT_ENERGY) * SPOT_GAIN
	for i in FAR_MAX:
		var fl := far_pool[i]
		var f = far_fixture[i]
		if f == null:
			fl.visible = false
			continue
		far_weight[i] = _ease_to(far_weight[i], 1.0 if f.far_wanted else 0.0, k)
		var t := clampf((sqrt(f.dsq) - FAR_FADE) / fade_range, 0.0, 1.0)
		var far_fade := 1.0 - t * t * (3.0 - 2.0 * t)
		var energy: float = base * (CLASSIC_BOOST if f.classic else 1.0) * lamp_out(f) * far_weight[i] * far_fade
		_glow_real(f, "rw_far", far_weight[i] * far_fade)
		fl.visible = energy > 0.002
		var col: Color = tube_color * (f.get("warm", Color.WHITE) as Color)
		if not fl.light_color.is_equal_approx(col): fl.light_color = col
		_move(fl, f.light_pos + _img(f))
		_energy(fl, energy)

# ------------------------------------------------------- atmosphere (lighting.js)
# How much working tube light reaches a point (0..1): the web game's bounce estimate
func tube_light_at(p: Vector3) -> float:
	if stair_cells.has(cell_of(p)):          # a stairwell is lit by its own lamps
		for s in stairwells:
			if s.holds(p): return s.light_at(p)
	# asked several times a frame for the same spot (the eye, the fog, the player's own light level): worked out once
	var frame := Engine.get_process_frames()
	if frame != _tla_frame:
		_tla_frame = frame
		_tla_memo.clear()
	var hit = _tla_memo.get(p)
	if hit != null: return hit
	var sum := 0.0
	for i in POOL_SIZE:
		var f = slot_fixture[i]
		if f == null: continue
		var w: float = lamp_out(f) * slot_weight[i]
		if w < 0.001: continue               # (a dark slot adds nothing: no sight line to walk)
		var at: Vector3 = wrap_near(f.pos, p)       # (across the seam of an endless level: its nearest copy)
		var dsq := at.distance_squared_to(p)
		# a tube behind a wall only reaches you by bouncing round (it used to count in full, so standing in a
		# dark corridor beside a lit one read as lit: the eye adaptation, fog and sanity all got it wrong)
		var seen := 1.0 if _line_clear(p, at, true) else HIDDEN_BOUNCE
		sum += w * seen / (1.0 + dsq / (BOUNCE_RADIUS * BOUNCE_RADIUS))
	var out := minf(1.0, sum / BOUNCE_FULL)
	if _tla_memo.size() < 64: _tla_memo[p] = out
	return out

var _tla_frame := -1
var _tla_memo := {}                 # this frame's tube_light_at answers, by spot

## True when no wall cell lies between two points (half-cell steps across the grid). `see_carved`: door and
## thin-wall cells count as open (most of the cell is air; light gets past them)
func _line_clear(a: Vector3, b: Vector3, see_carved := false) -> bool:
	var steps := maxi(1, ceili(Vector2(b.x - a.x, b.z - a.z).length() / (CELL * 0.5)))
	for k in range(1, steps):
		var c := wrap_cell(cell_of(a.lerp(b, float(k) / steps)))    # (an endless level: across the seam)
		if walls.has(c) and not (see_carved and carved.has(c)): return false
	return true

func _solid(c: Vector2i) -> bool:
	c = wrap_cell(c)
	return walls.has(c) and not carved.has(c)
