extends "res://scripts/World/level/level_light_pool.gd"
## THE LEVEL, layer 3c: how its light feels (the web game's lighting.js atmosphere).
##
## Builds the whole lighting stack (fixtures from level_fixtures.gd, the real-light pool from
## level_light_pool.gd, baked GI) and runs it each frame: fog and ambient follow how much tube light reaches
## you, the eye adapts to bright halls and dark corners, and looking straight into a lit tube glares.

# Eye adaptation: exposure follows how much tube light is where you stand and where you look, so a
# shadowed corner opens up and a blazing hall calms down. Dark zones and power cuts are left dark.
const EYE_GAIN_DARK := 1.35
const EYE_GAIN_BRIGHT := 0.85
const EYE_SPEED := 0.9
const EYE_PROBE := 8.0
# Glare: looking into a lit tube / panel stops the exposure down, so the rest of the room drops toward shadow
# like a real eye or camera. Clamps down fast, opens back up slowly.
const GLARE_CONE := 0.87            # cos of the half-angle round the view centre where a light counts (~30 deg)
const GLARE_FULL := 0.99            # cos where it counts fully (~8 deg: staring straight at it)
const GLARE_DIST := 7.0             # metres: nearer lights glare more
const GLARE_DIM := 0.55             # exposure multiplier at full glare (the light itself stays clipped white: it's HDR)
const GLARE_IN := 3.5               # 1/s: stopping down (fast)
const GLARE_OUT := 0.7              # 1/s: opening back up (slow)
const FOG_DENSITY := 0.075
const FOG_LIT_SCALE := 0.5
const FOG_DARK_BOOST := 0.5
const AMBIENT_MIN := 0.3
const ADAPT := 1.6
const FOG_COLOR := Color("141108")
const FOG_COLOR_DARK := Color("020201")

## Level-wide looks. "dim" is what main.tscn's WorldEnvironment is tuned for; the others are where the
## environment blends to while you stand in them (classic_mix: the Classic zone, or "atmosphere":
## "classic" for the whole level). Tune the classic backrooms look here.
const ATMOSPHERES := {
	"classic": {
		"ambient_energy": 0.8, "ambient_color": Color(0.36, 0.31, 0.17),   # flat, even yellow fill: far walls never go dark
		"exposure": 1.05, "tonemap_white": 4.0,       # gentle highlight roll-off: panels clip white, walls don't
		"glow_threshold": 1.1,                        # the panels bloom, the brightly lit walls don't
		"glow_intensity": 1.0, "glow_bloom": 0.02, "glow_wide": 0.5,    # wide soft halo round the lights (glow level 5)
		"ssao_intensity": 2.5,                        # fluorescent light is shadowless: keep only contact AO
		"haze": Color(0.66, 0.58, 0.36),              # the far distance fades to lit-wallpaper yellow, never to murk
	},
}

var _env_base := {}        # the WorldEnvironment's own (dim) values, read once

# ---- atmosphere
var env: Environment
var bounce := 1.0
var eye := 1.0                     # eye-adaptation exposure gain
var glare := 0.0                   # 0..1 smoothed: how much light you are looking straight into
var cam_mix := 0.0                 # how far the camera settings lean to the classic look (Classic zone, or softer in Bright)
var grid_glow := 0.0
var zone_amb := 1.0
var zone_fog := 1.0
var bright_mix := 0.0              # same idea for Bright zones (a softer version of the classic look)
var open_mix := 0.0                # how far the air is cleared and the far distance filled with light
var classic_mix := 0.0             # 0..1: how much of the classic look the player is standing in

func build_lighting() -> void:
	if panel_ceiling != null:
		_place_panel_fixtures()
		_build_panel_ceiling()
	else:
		_place_fixtures()
		_build_fixture_meshes()
	_build_light_pool()
	_build_floor_reflections()
	var we := get_parent().get_node_or_null("WorldEnvironment") as WorldEnvironment
	env = we.environment if we else null
	_read_quality()
	Gfx.changed.connect(_read_quality)
	_apply_gi()
	Gfx.changed.connect(_apply_gi)

## Bounce light. Best: the level's baked VoxelGI (tools/bake_level.gd, run by the level editor on every save).
## Only the geometry is baked, the light bouncing round it is live, so flickering tubes and power cuts bounce
## too. It is used while the .lvl is unchanged since the bake and the preset allows it (Gfx `baked_gi`: High and
## Ultra; Ultra adds a second bounce). Without a bake: SDFGI, heavy, so only on Ultra ("ssil") and only for
## levels with a Classic zone unless the .lvl forces it with "sdfgi": true / false (the editor's REAL-TIME GI).
const BAKE_VERSION := "1"          # bump when the geometry code changes in a way old bakes no longer match
var voxel_gi: VoxelGI

func gi_path() -> String:
	return "res://levels/baked/%s_gi.res" % str(level_meta.get("id", "level"))

## Changes whenever the level file (or BAKE_VERSION) does: a stale bake is never used
func bake_hash() -> String:
	return (FileAccess.get_file_as_string("res://levels/" + str(level_meta.get("file", ""))) + BAKE_VERSION).md5_text()

## The box the VoxelGI covers: the whole grid, floor to the highest ceiling, a little margin all round
func gi_bounds() -> Dictionary:
	var top := TALL_H if not tall.is_empty() else WALL_H
	var lo := Vector3(-CELL * 0.5, -0.5, -CELL * 0.5)
	var hi := Vector3((size - 0.5) * CELL, top + 0.5, (size - 0.5) * CELL)
	return {"center": (lo + hi) * 0.5, "size": hi - lo}

func _load_baked_gi() -> VoxelGIData:
	if not ResourceLoader.exists(gi_path()): return null
	var data := load(gi_path()) as VoxelGIData
	return data if data != null and str(data.get_meta("lvl_hash", "")) == bake_hash() else null

func _apply_gi() -> void:
	if env == null: return
	var data: VoxelGIData = _load_baked_gi() if (bool(Gfx.s.get("baked_gi", false)) and not Gfx.compat) else null
	if data != null:
		if voxel_gi == null:
			voxel_gi = VoxelGI.new()
			voxel_gi.position = data.get_meta("center")
			voxel_gi.size = data.get_meta("size")
			voxel_gi.subdiv = data.get_meta("subdiv")
			add_child(voxel_gi)
		data.interior = true                 # no sky: only the tubes light the place
		data.energy = 1.15
		data.propagation = 0.75              # how far bounced light travels from voxel to voxel
		data.dynamic_range = 4.0
		data.bias = 1.0
		data.normal_bias = 0.2
		data.use_two_bounces = false         # each bounce off yellow walls multiplies the colour: two turned dark corners red-brown
		voxel_gi.data = data
		voxel_gi.visible = true
	elif voxel_gi != null:
		voxel_gi.visible = false
	var want: bool = level_data.get("sdfgi", not classic.is_empty())
	env.sdfgi_enabled = data == null and want and bool(Gfx.s.get("ssil", false)) and not Gfx.compat
	if env.sdfgi_enabled:
		env.sdfgi_cascades = 3
		env.sdfgi_min_cell_size = 0.5
		# Off: SDFGI's probe occlusion approximates AO from the voxel cascades, which lag behind
		# fast-moving dynamic objects (the player) and show up as a dark halo/blob dragging along
		# beneath them. The bounce light itself still works fine without it.
		env.sdfgi_use_occlusion = false
		env.sdfgi_bounce_feedback = 0.6
		env.sdfgi_energy = 1.0

func _update_atmosphere(delta: float) -> void:
	if env == null: return
	var c := cell_of(player.global_position)
	var za := 1.0
	var zf := 1.0
	var grid_down: bool = player.get("grid_down") == true
	grid_glow += ((1.0 if grid_down else 0.0) - grid_glow) * minf(1.0, delta * 0.5)
	classic_mix += ((1.0 if classic.has(c) else 0.0) - classic_mix) * minf(1.0, delta * 1.5)
	bright_mix += ((1.0 if bright.has(c) else 0.0) - bright_mix) * minf(1.0, delta * 1.5)
	# how much of the building's power is on (a power cut kills the tubes): drives the fill lights and the cleared air
	var power := 1.0
	if not lit.is_empty():
		var total := 0.0
		var n := 0
		for i in range(0, lit.size(), maxi(1, lit.size() / 24)):
			total += minf(1.0, lit[i].level) * (0.0 if lit[i].black > 0.0 else 1.0)
			n += 1
		power = total / maxf(n, 1)
	power = smoothstep(0.1, 0.7, power)
	for fl in fill_lights:
		fl.light_energy = LIGHT_ENERGY * 1.5 * (1.0 - grid_glow) * power
	open_mix = maxf(classic_mix, bright_mix * 0.85) * (1.0 - grid_glow) * power   # a power cut is dark, whatever the zone
	Game.fx_classic = classic_mix
	if reflect_mmi != null:                                              # noclip under the map would show them as huge white panels
		reflect_mmi.visible = player.global_position.y > 0.0
	for l in pool + pool_b + far_pool + ceil_glow:                                   # stark white tubes in the classic zone, so the light reads against the yellow walls
		l.light_color = LIGHT_COLOR.lerp(Color(1.0, 0.99, 0.96), classic_mix)
	cam_mix = maxf(classic_mix, bright_mix * 0.7)
	if dark.has(c):
		za = 0.12; zf = 1.35
	elif dim.has(c):
		za = 0.55; zf = 1.15
	var k := minf(1.0, delta * ADAPT)
	bounce += (tube_light_at(player.global_position) - bounce) * k
	zone_amb += (za - zone_amb) * k
	# eye adaptation: light where you stand and where you look (a lit hall ahead calms the exposure down,
	# a wall in shade in front of you opens it up); only where the zone is meant to be readable
	var cam := get_viewport().get_camera_3d()
	var ahead := player.global_position
	if cam: ahead = cam.global_position - cam.global_transform.basis.z * EYE_PROBE
	var seen := 0.5 * (tube_light_at(player.global_position) + tube_light_at(ahead))
	var gain := lerpf(1.0, lerpf(EYE_GAIN_DARK, EYE_GAIN_BRIGHT, seen), clampf(zone_amb, 0.0, 1.0) * (1.0 - grid_glow))
	eye += (gain - eye) * minf(1.0, delta * EYE_SPEED)
	if cam:
		var target := _glare_now(cam)
		glare += (target - glare) * minf(1.0, delta * (GLARE_IN if target > glare else GLARE_OUT))
	if Gfx.post_mat:
		Gfx.post_mat.set_shader_parameter("glare", glare)   # lens dirt / halation / streaks swell (post.gdshader)
	_blend_env(ATMOSPHERES.classic)
	zf = lerpf(zf, 0.2, open_mix)                                     # clear air: the far halls keep their light, only a touch of haze
	zone_fog += (zf - zone_fog) * k
	var b := AMBIENT_MIN + (1.0 - AMBIENT_MIN) * bounce
	# power cut: a faint glow so shapes barely read (ATMOSPHERE.gridDownAmbient / gridDownFog)
	var darkness := 1.0 - minf(1.0, maxf(b * zone_amb, 0.25 * grid_glow))
	env.fog_light_color = FOG_COLOR.lerp(FOG_COLOR_DARK, darkness)
	# in big lit halls the distance fades to a warm haze instead of black, so you can read the far walls and ceiling
	env.fog_light_color = env.fog_light_color.lerp(ATMOSPHERES.classic.haze, open_mix * (1.0 - darkness))
	env.background_color = env.fog_light_color
	var lit_scale := FOG_LIT_SCALE + (1.0 + FOG_DARK_BOOST - FOG_LIT_SCALE) * darkness
	# web uses exp2 fog at 0.075; Godot's exponential fog needs a lower density for the same feel
	env.fog_density = FOG_DENSITY * 0.8 * lit_scale * zone_fog * (1.0 + (0.55 - 1.0) * grid_glow)
	if env.volumetric_fog_enabled:
		env.volumetric_fog_density = 0.016 * lit_scale * zone_fog * (1.0 + (0.55 - 1.0) * grid_glow)
		env.volumetric_fog_albedo = Color(0.88, 0.82, 0.58, 1.0).lerp(Color(0.08, 0.06, 0.03, 1.0), darkness)

## Blend the WorldEnvironment from its own (dim) values toward an ATMOSPHERES look: the camera settings
## follow classic_mix (where you stand), the light itself open_mix (which a power cut takes away).
## How much lit fixture sits near the centre of the view right now (0..1), lights behind walls left out
func _glare_now(cam: Camera3D) -> float:
	var fwd := -cam.global_transform.basis.z
	var cp := cam.global_position
	var sum := 0.0
	for i in POOL_SIZE:
		var f = slot_fixture[i]
		if f == null or f.black > 0.0: continue
		var to: Vector3 = (f.pos as Vector3) - cp
		var d := to.length()
		if d < 0.2: continue
		var facing := fwd.dot(to / d)
		if facing < GLARE_CONE: continue
		var w := smoothstep(GLARE_CONE, GLARE_FULL, facing) * slot_level(i) / (1.0 + d * d / (GLARE_DIST * GLARE_DIST))
		if w > 0.01 and _line_clear(cp, f.pos): sum += w
	return clampf(sum, 0.0, 1.0)

func _blend_env(a: Dictionary) -> void:
	if _env_base.is_empty():
		# kept on the resource: main.tscn's Environment can outlive a level reload with the last blend in it
		if not env.has_meta("atmo_base"):
			env.set_meta("atmo_base", {"ambient_energy": env.ambient_light_energy, "ambient_color": env.ambient_light_color,
				"exposure": env.tonemap_exposure, "tonemap_white": env.tonemap_white,
				"glow_threshold": env.glow_hdr_threshold, "glow_intensity": env.glow_intensity,
				"glow_bloom": env.glow_bloom, "glow_wide": env.get_glow_level(5), "ssao_intensity": env.ssao_intensity})
		_env_base = env.get_meta("atmo_base")
	var b := _env_base
	env.ambient_light_energy = lerpf(b.ambient_energy, a.ambient_energy, open_mix)
	env.ambient_light_color = (b.ambient_color as Color).lerp(a.ambient_color, open_mix)
	env.tonemap_exposure = lerpf(b.exposure, a.exposure, cam_mix) * eye * lerpf(1.0, GLARE_DIM, glare)
	env.tonemap_white = lerpf(b.tonemap_white, a.tonemap_white, cam_mix)
	env.glow_hdr_threshold = lerpf(b.glow_threshold, a.glow_threshold, cam_mix)
	env.glow_intensity = lerpf(b.glow_intensity, a.glow_intensity, cam_mix) * (1.0 + 0.35 * glare)   # the light you stare into blooms a bit more
	env.glow_bloom = lerpf(b.glow_bloom, a.glow_bloom, cam_mix)
	env.set_glow_level(5, lerpf(b.glow_wide, a.glow_wide, cam_mix))
	env.ssao_intensity = lerpf(b.ssao_intensity, a.ssao_intensity, cam_mix)

func update_lighting(delta: float) -> void:
	if player == null or pool.is_empty(): return
	_update_fixtures(delta)
	_update_pool(delta)
	_update_atmosphere(delta)
