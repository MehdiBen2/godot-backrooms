class_name LampFixture
extends Node3D
## The lights that are not ceiling tubes (the level editor's "lamp" objects: object_types.json shape "lamp", built by
## level_geometry.gd _build_lamp). Each is a little model drawn from primitives plus one real light, in its own frame
## (object_transform: +x the arrow, y up from the floor):
##   lamp_floor       a warm standing lamp with a fabric shade, a pool of amber light round it
##   wall_sconce      a wall light, up on a wall face (mount: wall), throwing light up the wall and down
##   chandelier       a hotel chandelier hung from the ceiling on a chain: a ring of candle bulbs and crystal drops
##   emergency_strip  a red emergency strip; it glows dimly all the time and blazes when the power is cut
##   candle           a flame on a stub of wax: a small, living, flickering light
##   string_lights    festoon bulbs on a drooping wire, `scale` cells long along the arrow
##   streetlamp       a tall pole with a sodium lamp and a cone of light on the ground
##   vent_glow        a grille in the floor or a wall with something burning or humming behind it
## Params (object_types.json): tone (the colour of the light), flicker (how it behaves), energy (a multiplier on the
## type's own), elev (how high it sits: a sconce on its wall, a candle on its shelf).
##
## The real lights are rationed. Every lamp in the level registers here and a ranking, run a few times a second,
## switches on only the nearest few (and gives the nearest couple a shadow); the rest keep their glowing bulbs, which
## need no light at all. Power cuts (level_fixtures.gd cut_power / restore_power) put out everything but the
## emergency strips and candles.

const CELL := 4.5
const MAX_LIT := 10                # real lights on at once, all lamps together
const RANK_EVERY := 0.2            # seconds between rankings
const REACH := 34.0                # metres: past this a lamp is just its bulb
const SHADOWED := 2

const TONES := {
	"warm": Color(1.0, 0.72, 0.38),
	"candle": Color(1.0, 0.58, 0.22),
	"hotel": Color(1.0, 0.82, 0.55),
	"cool": Color(0.78, 0.9, 1.0),
	"sodium": Color(1.0, 0.64, 0.2),
	"red": Color(1.0, 0.1, 0.06),
	"green": Color(0.35, 1.0, 0.45),
	"party": Color(1.0, 0.4, 0.75),
}

# energy, range, glow (bulb emission) per type
const SPEC := {
	"lamp_floor": [2.4, 9.0, 3.0],
	"wall_sconce": [1.8, 7.0, 3.0],
	"chandelier": [4.2, 15.0, 3.4],
	"emergency_strip": [1.4, 10.0, 3.0],
	"candle": [0.9, 4.2, 5.0],
	"string_lights": [0.5, 3.6, 3.5],
	"streetlamp": [7.0, 17.0, 4.0],
	"vent_glow": [1.6, 6.0, 3.0],
}

static var all: Array = []
static var powered := true
static var _rank_wait := 0.0
static var _rank_frame := -1

var kind := ""
var tone := Color.WHITE
var flicker := "none"
var energy_mul := 1.0
var always_on := false             # emergency strips and candles do not need the grid
var _lights: Array = []            # [Light3D, base energy, bulb materials]
var _bulbs: Array[StandardMaterial3D] = []
var _bulb_glow := 3.0
var _seed := 0.0
var _shell := false
var _want := false                 # ranked in
var _level := 1.0                  # 0..1: power cut ease, flicker output
var _target := 1.0

## What this lamp puts out now, 0..about 1 (its flicker and the power), for the bounce light (grid_gi.gd)
func output() -> float:
	return 0.0 if _lights.is_empty() else _level * energy_mul

static func power(on: bool) -> void:
	powered = on

func build(o: Dictionary, ceil_h: float, shell: bool) -> void:
	kind = str(o.type)
	name = "%s_%d" % [kind, get_index()]
	_shell = shell
	flicker = str(o.get("flicker", "none"))
	energy_mul = clampf(float(o.get("energy", 1.0)), 0.0, 6.0)
	tone = TONES.get(str(o.get("tone", "warm")), TONES.warm)
	_seed = fmod(absf(float(o.pos_x) * 12.9898 + float(o.pos_y) * 78.233), 100.0)
	var spec: Array = SPEC.get(kind, SPEC.lamp_floor)
	_bulb_glow = spec[2]
	var elev := float(o.get("elev", 0.0))
	var s := float(o.scale)
	always_on = kind in ["emergency_strip", "candle"]
	match kind:
		"lamp_floor": _floor_lamp(s)
		"wall_sconce": _sconce(elev if elev > 0.1 else 1.9)
		"chandelier": _chandelier(ceil_h, s)
		"emergency_strip": _strip(elev if elev > 0.1 else ceil_h - 0.35, s)
		"candle": _candle(elev, s)
		"string_lights": _string(elev if elev > 0.1 else minf(ceil_h - 0.6, 3.2), s)
		"streetlamp": _streetlamp(minf(ceil_h, 6.2))
		"vent_glow": _vent(elev, s)
	if shell: _drop_lights()
	else:
		all.append(self)
		set_process(true)
		tree_exiting.connect(func() -> void: all.erase(self))

func _drop_lights() -> void:
	for l: Array in _lights: (l[0] as Node).queue_free()
	_lights.clear()

# ---------------------------------------------------------------- materials and bits
func _mat(c: Color, rough := 0.7, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m

func _glow_mat(c: Color, mul := 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c * 0.6
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = _bulb_glow * mul
	m.set_meta("glow_mul", mul)
	_bulbs.append(m)
	return m

func _mesh(m: Mesh, mat: Material, at: Vector3, rot := Vector3.ZERO, shadows := false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = mat
	mi.position = at
	mi.rotation = rot
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi

func _cyl(r_top: float, r_bot: float, h: float, segs := 16) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = r_top
	c.bottom_radius = r_bot
	c.height = h
	c.radial_segments = segs
	c.rings = 1
	return c

func _sphere(r: float, segs := 12) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	s.radial_segments = segs
	s.rings = segs / 2
	return s

func _box(x: float, y: float, z: float) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = Vector3(x, y, z)
	return b

## one real light for this lamp (kept off until it is ranked in)
func _light(at: Vector3, kind_: String = "omni", mul := 1.0, spot_angle := 70.0, down := true) -> Light3D:
	var spec: Array = SPEC.get(kind, SPEC.lamp_floor)
	var base: float = spec[0] * energy_mul * mul
	var l: Light3D
	if kind_ == "spot":
		var sp := SpotLight3D.new()
		sp.spot_range = spec[1]
		sp.spot_angle = spot_angle
		sp.spot_angle_attenuation = 1.4
		sp.rotation = Vector3(-PI * 0.5 if down else PI * 0.5, 0, 0)
		l = sp
	else:
		var om := OmniLight3D.new()
		om.omni_range = spec[1]
		om.omni_attenuation = 1.3
		l = om
	l.position = at
	l.light_color = tone
	l.light_energy = base
	l.light_specular = 0.4
	l.shadow_enabled = false
	l.shadow_bias = 0.05
	l.shadow_normal_bias = 1.0
	l.light_size = 0.05
	l.visible = false
	l.light_bake_mode = Light3D.BAKE_DISABLED
	l.set_meta("gfx_managed", true)
	l.light_cull_mask &= ~((1 << 18) | (1 << 10) | (1 << 11))     # not the ceiling glow layer, nor a shell copy
	add_child(l)
	_lights.append([l, base])
	return l

# ---------------------------------------------------------------- the models
func _floor_lamp(s: float) -> void:
	var metal := _mat(Color(0.16, 0.12, 0.09), 0.4, 0.6)
	_mesh(_cyl(0.18, 0.22, 0.04), metal, Vector3(0, 0.02, 0))
	_mesh(_cyl(0.018, 0.018, 1.42, 8), metal, Vector3(0, 0.74, 0))
	var shade := _glow_mat(tone * Color(1.0, 0.92, 0.82), 0.55)
	shade.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mesh(_cyl(0.17, 0.3, 0.34, 20), shade, Vector3(0, 1.58, 0))
	_mesh(_sphere(0.07, 8), _glow_mat(Color(1, 0.9, 0.7), 1.8), Vector3(0, 1.5, 0))
	scale = Vector3.ONE * clampf(s, 0.6, 1.8)
	_light(Vector3(0, 1.5, 0) * scale.y)

func _sconce(h: float) -> void:
	var brass := _mat(Color(0.55, 0.4, 0.18), 0.35, 0.85)
	_mesh(_box(0.04, 0.3, 0.14), brass, Vector3(0.02, h, 0))                       # back plate on the wall
	_mesh(_cyl(0.015, 0.015, 0.14, 8), brass, Vector3(0.1, h - 0.06, 0), Vector3(0, 0, PI * 0.5))   # arm
	var shade := _glow_mat(tone * Color(1.0, 0.9, 0.78), 0.5)
	shade.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mesh(_cyl(0.1, 0.05, 0.18, 14), shade, Vector3(0.17, h + 0.04, 0))
	_mesh(_sphere(0.04, 8), _glow_mat(Color(1, 0.92, 0.75), 2.0), Vector3(0.17, h, 0))
	_light(Vector3(0.28, h, 0))

func _chandelier(ceil_h: float, s: float) -> void:
	var drop := clampf(ceil_h * 0.28, 1.0, 3.2) if ceil_h > 4.0 else 0.55
	var y := ceil_h - drop
	var brass := _mat(Color(0.6, 0.45, 0.2), 0.3, 0.9)
	_mesh(_cyl(0.012, 0.012, drop, 6), brass, Vector3(0, ceil_h - drop * 0.5, 0))   # the chain
	_mesh(_cyl(0.11, 0.11, 0.05, 14), brass, Vector3(0, ceil_h - 0.025, 0))         # ceiling rose
	_mesh(_cyl(0.16, 0.16, 0.12, 16), brass, Vector3(0, y, 0))                       # hub
	var tier_r := 0.5 * clampf(s, 0.8, 2.4)
	var crystal := StandardMaterial3D.new()
	crystal.albedo_color = Color(0.85, 0.9, 1.0, 0.55)
	crystal.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	crystal.metallic = 0.3
	crystal.roughness = 0.05
	crystal.emission_enabled = true
	crystal.emission = tone * 0.5
	crystal.emission_energy_multiplier = 0.8
	for ring in 2:
		var r := tier_r * (1.0 if ring == 0 else 0.55)
		var yy := y - ring * 0.26
		var n := 8 if ring == 0 else 5
		var rim := TorusMesh.new()
		rim.inner_radius = r - 0.02
		rim.outer_radius = r + 0.02
		rim.rings = 20
		rim.ring_segments = 6
		_mesh(rim, brass, Vector3(0, yy, 0))
		for i in n:
			var a := TAU * i / n
			var p := Vector3(cos(a) * r, yy, sin(a) * r)
			_mesh(_cyl(0.02, 0.02, 0.17, 6), brass, p + Vector3(0, 0.09, 0))
			_mesh(_cyl(0.0, 0.032, 0.11, 8), _glow_mat(Color(1, 0.9, 0.65), 1.6), p + Vector3(0, 0.22, 0))   # candle bulb
			_mesh(_cyl(0.0, 0.016, 0.16, 6), crystal, p - Vector3(0, 0.1, 0))                                   # drop
	_mesh(_cyl(0.0, 0.07, 0.3, 8), crystal, Vector3(0, y - 0.5, 0))                                              # the long centre drop
	_light(Vector3(0, y + 0.1, 0), "omni", clampf(s, 0.8, 2.0))
	if not _shell: _light(Vector3(0, y - 0.6, 0), "omni", 0.35)

func _strip(h: float, s: float) -> void:
	var span := clampf(s, 0.5, 6.0) * 0.9
	var housing := _mat(Color(0.12, 0.12, 0.13), 0.6, 0.2)
	_mesh(_box(span, 0.06, 0.12), housing, Vector3(0, h, 0))
	var lens := _glow_mat(Color(1.0, 0.1, 0.06), 1.0)
	_mesh(_box(span * 0.96, 0.025, 0.07), lens, Vector3(0, h - 0.035, 0))
	_light(Vector3(0, h - 0.4, 0), "spot", 1.0, 82.0)

func _candle(h: float, s: float) -> void:
	var wax := _mat(Color(0.93, 0.88, 0.76), 0.9)
	var sc := clampf(s, 0.7, 2.0)
	_mesh(_cyl(0.022 * sc, 0.026 * sc, 0.16 * sc, 10), wax, Vector3(0, h + 0.08 * sc, 0))
	var flame := _glow_mat(Color(1.0, 0.7, 0.25), 1.4)
	var f := _sphere(0.017 * sc, 8)
	f.height = 0.06 * sc
	_mesh(f, flame, Vector3(0, h + 0.19 * sc, 0))
	_light(Vector3(0, h + 0.3 * sc, 0))
	if flicker == "none": flicker = "candle"

func _string(h: float, s: float) -> void:
	var span := clampf(s, 1.0, 12.0) * CELL
	var wire := _mat(Color(0.05, 0.05, 0.05), 0.8)
	var n := maxi(6, int(span / 0.45))
	var sag := clampf(span * 0.07, 0.25, 0.9)
	var prev := Vector3(-span * 0.5, h, 0)
	var palette := [Color(1.0, 0.82, 0.5), Color(1.0, 0.55, 0.3), Color(1.0, 0.9, 0.7)] if tone == TONES.warm else [tone, tone * 0.9, tone * 1.1]
	for i in n + 1:
		var u := float(i) / n
		var p := Vector3(-span * 0.5 + span * u, h - sag * 4.0 * u * (1.0 - u), 0)
		if i > 0:
			var seg := p - prev
			var mi := _mesh(_cyl(0.006, 0.006, seg.length(), 4), wire, (p + prev) * 0.5)
			mi.look_at_from_position(mi.position, p, Vector3.UP)
			mi.rotate_object_local(Vector3.RIGHT, PI * 0.5)
		if i % 2 == 1 or i == 0:
			_mesh(_sphere(0.035, 8), _glow_mat(palette[i % palette.size()], 1.0), p - Vector3(0, 0.05, 0))
		prev = p
	for k in clampi(int(span / 5.0) + 1, 1, 4):
		var u := (k + 0.5) / clampi(int(span / 5.0) + 1, 1, 4)
		_light(Vector3(-span * 0.5 + span * u, h - sag * 4.0 * u * (1.0 - u) - 0.2, 0), "omni", 1.0)

func _streetlamp(top: float) -> void:
	var iron := _mat(Color(0.1, 0.11, 0.12), 0.55, 0.7)
	_mesh(_cyl(0.16, 0.2, 0.35), iron, Vector3(0, 0.175, 0))
	_mesh(_cyl(0.05, 0.08, top - 0.9, 10), iron, Vector3(0, (top - 0.9) * 0.5 + 0.3, 0))
	_mesh(_box(0.9, 0.06, 0.06), iron, Vector3(0.38, top - 0.55, 0))                   # the arm, reaching out along the arrow
	var housing := _mat(Color(0.18, 0.18, 0.18), 0.5, 0.5)
	_mesh(_box(0.55, 0.08, 0.26), housing, Vector3(0.75, top - 0.5, 0))
	_mesh(_box(0.48, 0.03, 0.2), _glow_mat(Color(1, 0.82, 0.55), 1.2), Vector3(0.75, top - 0.56, 0))
	_light(Vector3(0.75, top - 0.6, 0), "spot", 1.0, 62.0)
	_light(Vector3(0.75, top - 1.0, 0), "omni", 0.3)

func _vent(h: float, s: float) -> void:
	var sc := clampf(s, 0.5, 4.0)
	var frame := _mat(Color(0.14, 0.14, 0.15), 0.5, 0.6)
	var w := 0.9 * sc
	_mesh(_box(w, 0.03, 0.55 * sc), frame, Vector3(0, h + 0.015, 0))
	var glow := _glow_mat(tone, 0.9)
	_mesh(_box(w - 0.1, 0.012, 0.45 * sc), glow, Vector3(0, h + 0.03, 0))
	var slats := int(w / 0.09)
	for i in slats:
		_mesh(_box(0.014, 0.025, 0.5 * sc), frame, Vector3(-w * 0.5 + 0.07 + i * (w - 0.14) / maxi(1, slats - 1), h + 0.04, 0))
	_light(Vector3(0, h + 0.35, 0), "omni", 0.9)
	if flicker == "none": flicker = "buzz"

# ---------------------------------------------------------------- running
func _process(delta: float) -> void:
	if _shell: return
	# one lamp does the ranking for all of them, a few times a second
	var f := Engine.get_process_frames()
	if _rank_frame != f:
		_rank_frame = f
		_rank_wait -= delta
		if _rank_wait <= 0.0:
			_rank_wait = RANK_EVERY
			_rank()
	var on := powered or always_on
	var t := Time.get_ticks_msec() * 0.001
	var out := _flicker(t) if on else (0.18 if kind == "emergency_strip" else 0.0)
	if kind == "emergency_strip" and not powered: out = 1.0 + 0.25 * sin(t * 3.0 + _seed)    # the strip comes into its own
	elif kind == "emergency_strip": out = 0.2
	_target = out
	_level = lerpf(_level, _target, clampf(delta * (14.0 if kind != "emergency_strip" else 5.0), 0.0, 1.0))
	for m in _bulbs:
		m.emission_energy_multiplier = _bulb_glow * float(m.get_meta("glow_mul", 1.0)) * _level
	for l: Array in _lights:
		var li: Light3D = l[0]
		if _want and _level > 0.01:
			li.visible = true
			li.light_energy = l[1] * _level
		else:
			li.visible = false

func _flicker(t: float) -> float:
	match flicker:
		"candle":
			return clampf(0.82 + 0.1 * sin(t * 9.3 + _seed) + 0.08 * sin(t * 23.1 + _seed * 2.0) + 0.05 * sin(t * 51.0 + _seed), 0.4, 1.2)
		"faulty":
			var slot := floorf(t * 3.0 + _seed)
			var r := fposmod(sin(slot * 91.7 + _seed * 13.0) * 43758.5453, 1.0)
			if r > 0.8: return 0.0 if fposmod(t * 20.0, 1.0) > 0.4 else 0.9
			if r > 0.62: return 0.55 + 0.4 * sin(t * 40.0)
			return 1.0
		"buzz":
			return 0.9 + 0.08 * sin(t * 6.0 + _seed) + 0.04 * sin(t * 90.0 + _seed)
		"pulse":
			return 0.55 + 0.45 * (0.5 + 0.5 * sin(t * 2.2 + _seed))
		"sway":
			return 0.92 + 0.08 * sin(t * 1.3 + _seed)
	return 1.0

static func _rank() -> void:
	var cam := Engine.get_main_loop() as SceneTree
	if cam == null: return
	var vp := cam.root.get_viewport().get_camera_3d()
	if vp == null: return
	var p := vp.global_position
	var scored: Array = []
	for l: LampFixture in all:
		if not is_instance_valid(l) or not l.is_inside_tree():
			continue
		var d: float = l.global_position.distance_to(p)
		if d < REACH: scored.append([d, l])
		l._want = false
	scored.sort_custom(func(a, b) -> bool: return a[0] < b[0])
	var cap := clampi(int(Gfx.s.get("lights", 8)), 2, MAX_LIT) if Gfx.s.has("lights") else MAX_LIT
	var shadow_cap := SHADOWED if int(Gfx.s.get("shadows", 1)) > 0 else 0
	var used := 0
	var shadows := 0
	for e in scored:
		var l: LampFixture = e[1]
		var n: int = l._lights.size()
		if used + n > cap and used > 0: continue
		l._want = true
		used += n
		var allow: bool = shadows < shadow_cap and e[0] < 14.0 and l.kind in ["chandelier", "streetlamp", "lamp_floor", "wall_sconce"]
		for li: Array in l._lights:
			(li[0] as Light3D).shadow_enabled = allow
		if allow: shadows += 1
		if used >= cap: break
