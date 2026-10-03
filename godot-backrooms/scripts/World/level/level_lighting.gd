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
const FOG_DENSITY := 0.055
const FOG_LIT_SCALE := 0.5
const FOG_DARK_BOOST := 0.3
const AMBIENT_MIN := 0.3
const ADAPT := 1.6
const FOG_COLOR := Color("141108")
const FOG_COLOR_DARK := Color("020201")
# Horizon fog: past HORIZON_BEGIN everything fades into the fog colour, whatever the zone's fog density.
# The clear-air looks thin the fog to almost nothing, so the level's edge and whatever the camera's far
# plane cuts off showed through as bare background (black space). A screen-wide quad over the depth buffer.
const HORIZON_BEGIN := 90.0
const HORIZON_END := 170.0
const HORIZON_SHADER := """shader_type spatial;
render_mode unshaded, fog_disabled, depth_test_disabled, depth_draw_never, cull_disabled, shadows_disabled, blend_mix;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform vec3 fog_color : source_color;
uniform float begin = 40.0;
uniform float end = 70.0;
void vertex() { POSITION = vec4(VERTEX.xy, 1.0, 1.0); }
void fragment() {
	float depth = texture(depth_tex, SCREEN_UV).x;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(SCREEN_UV, depth) * 2.0 - 1.0;
#else
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
#endif
	vec4 view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	float dist = abs(view.w) < 1e-6 ? 1e6 : length(view.xyz / view.w);
	ALBEDO = fog_color;
	ALPHA = smoothstep(begin, end, dist);
}
"""

## Level-wide looks: "dim" is main.tscn's WorldEnvironment (the base), "liminal" and "classic" are where the
## environment blends to while you stand in them. They live in the render engine: scripts/Render/atmospheres.gd.
## (The found-footage camera that meters, pumps and drifts on its own in the classic look: _update_camcorder.)
const Atmospheres := preload("res://scripts/Render/atmospheres.gd")
var ATMOSPHERES: Dictionary = Atmospheres.LOOKS
const FF_FOG := 0.05                # found footage: fog left at this share (clear air, far walls readable)
const FF_CEIL_FILL := 0.3           # found footage: ceiling bounce-light fill (see panel_ceiling.gdshader): a bright ceiling
const VFOG_EMISSION := Color(0.035, 0.03, 0.015)   # main.tscn's volumetric fog emission (the dim look)
const FF_BLACK_LIFT := 0.1          # found footage: camcorder black level (camera.gdshader black_lift): milky, never black
# Camcorder auto exposure: meters the scene late, then swings past the right exposure and settles
const AE_KEY := 0.75                # meter reading that gives a gain of 1 (a typical lit hall)
const AE_MIN := 0.55
const AE_MAX := 1.7
const AE_METER_SPEED := 2.5         # 1/s: how fast the meter itself follows
const AE_HZ := 0.45                 # spring frequency: a full swing takes about two seconds
const AE_DAMP := 0.42               # < 1: overshoots (the pumping)
# Camcorder auto white balance: a slow wander, and a late, partial correction of tinted light
const WB_DRIFT := 0.035
const WB_CORRECT := 0.5             # how much of a light's colour cast the camera takes back out
const WB_SPEED := 0.25              # 1/s

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
var liminal_mix := 0.0             # 0..1: the same for the liminal look
var shaft_mix := 0.0               # 0..1: standing by a shaft through the floors (level_data.gd hole_box)
const SHAFT_AIR_CELLS := 5         # how near
const SHAFT_FOG := 0.2             # share of the fog left there
var _lim := 0.0                    # liminal_mix while the power is on (a power cut is dark in any look)
var exposure_gain := 1.0           # what the eye / camera adds on top of the look's exposure
var _ae := 1.0
var _ae_v := 0.0
var _ae_meter := AE_KEY
var _wb_t := 0.0
var _wb_corr := Vector3.ONE
var _wb_noise := FastNoiseLite.new()
var _ceil_fill := -1.0
var _tube_col := Color(-1, -1, -1)  # the pool lights' colour as last written (forces the first write)
var _horizon: MeshInstance3D
var _horizon_mat: ShaderMaterial

func build_lighting() -> void:
	_tube_col = Color(-1, -1, -1)       # fresh lights: their colour must be written again
	if panel_ceiling != null:
		_place_panel_fixtures()
		_build_panel_ceiling()
	else:
		_place_fixtures()
		_build_fixture_meshes()
	_build_light_pool()
	_build_floor_reflections()
	_build_floor_glow()
	var we := get_parent().get_node_or_null("WorldEnvironment") as WorldEnvironment
	env = we.environment if we else null
	_build_horizon_fog()
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

var _gi_read := {}     # gi_path() -> the bake, read once: it is megabytes, and every floor of a level asks for it

func _load_baked_gi() -> VoxelGIData:
	var path := gi_path()
	if not _gi_read.has(path):
		_gi_read[path] = (load(path) as VoxelGIData) if ResourceLoader.exists(path) else null
	var data: VoxelGIData = _gi_read[path]
	return data if data != null and str(data.get_meta("lvl_hash", "")) == bake_hash() else null

func _apply_gi() -> void:
	if env == null: return
	# The found-footage (classic) levels are big and flat-lit: a 200 m bake gets ~0.4 m voxels, only about ten
	# floor to ceiling, and their seams showed as a dark line across every wall at eye height plus uneven
	# bounce on the far ceiling. The look's even ambient fill does that job cleanly, so no GI there.
	var flat_lit := atmosphere() == "classic"
	var data: VoxelGIData = _load_baked_gi() if (bool(Gfx.s.get("baked_gi", false)) and not Gfx.compat and not flat_lit) else null
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
	var want: bool = level_data.get("sdfgi", not classic.is_empty()) and not flat_lit
	env.sdfgi_enabled = data == null and want and bool(Gfx.s.get("ssil", false)) and not Gfx.compat
	if env.sdfgi_enabled:
		env.sdfgi_cascades = 3
		env.sdfgi_min_cell_size = 0.5
		# cells half as tall as they are wide: more detail at a 3 m ceiling and less bounce light leaking
		# through the (single-quad) ceiling in the coarse far cascades, which made the far ceiling brighter
		env.sdfgi_y_scale = Environment.SDFGI_Y_SCALE_50_PERCENT
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
	liminal_mix += ((1.0 if liminal.has(c) else 0.0) - liminal_mix) * minf(1.0, delta * 1.5)
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
	_lim = liminal_mix * (1.0 - grid_glow) * power
	Game.fx_classic = classic_mix
	if reflect_mmi != null:                                              # noclip under the map would show them as huge white panels
		reflect_mmi.visible = player.global_position.y > 0.0
	# stark white tubes in the classic zone, so the light reads against the yellow walls. Written only when it
	# changes: it used to be set on all ~70 pooled lights every frame, each one a renderer update
	var tube_col := LIGHT_COLOR.lerp(ATMOSPHERES.liminal.light, _lim).lerp(Color(1.0, 0.99, 0.96), classic_mix)
	if not tube_col.is_equal_approx(_tube_col):
		_tube_col = tube_col
		for l in pool + pool_b + far_pool + ceil_glow:
			l.light_color = tube_col
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
		Gfx.post_mat.set_shader_parameter("glare", glare)   # lens dirt / halation / streaks swell (camera.gdshader)
	_update_camcorder(delta, seen)
	_blend_env(ATMOSPHERES.classic)
	zf *= lerpf(1.0, ATMOSPHERES.liminal.fog, _lim)                  # liminal: thin air, the halls fade out slowly
	# by a shaft through the floors the air is clear, whatever the look: the lit rooms of the storeys above and
	# below show a long way off, and past them the dark (the fog keeps its colour, there is only less of it)
	var by_shaft := hole_box.size != Vector2i.ZERO and hole_box.grow(SHAFT_AIR_CELLS).has_point(c)
	shaft_mix += ((1.0 if by_shaft else 0.0) - shaft_mix) * minf(1.0, delta * 1.5)
	zf = minf(zf, lerpf(zf, SHAFT_FOG, shaft_mix))
	zf = lerpf(zf, FF_FOG, open_mix)                                  # clear air: the far halls keep their light, only a touch of haze
	zone_fog += (zf - zone_fog) * k
	var b := AMBIENT_MIN + (1.0 - AMBIENT_MIN) * bounce
	# power cut: a faint glow so shapes barely read (ATMOSPHERE.gridDownAmbient / gridDownFog)
	var darkness := 1.0 - minf(1.0, maxf(b * zone_amb, 0.25 * grid_glow))
	env.fog_light_color = FOG_COLOR.lerp(FOG_COLOR_DARK, darkness)
	# in big lit halls the distance fades to a warm haze instead of black, so you can read the far walls and ceiling
	env.fog_light_color = env.fog_light_color.lerp(ATMOSPHERES.liminal.haze, _lim * (1.0 - 0.6 * darkness))   # stays pale in the shadows too
	env.fog_light_color = env.fog_light_color.lerp(ATMOSPHERES.classic.haze, open_mix * (1.0 - darkness))
	env.background_color = env.fog_light_color
	if is_instance_valid(_horizon) and _horizon_mat:
		_horizon_mat.set_shader_parameter("fog_color", env.fog_light_color)
		_horizon.visible = not Game.fullbright
	var lit_scale := FOG_LIT_SCALE + (1.0 + FOG_DARK_BOOST - FOG_LIT_SCALE) * darkness
	# web uses exp2 fog at 0.075; Godot's exponential fog needs a lower density for the same feel
	env.fog_density = FOG_DENSITY * 0.8 * lit_scale * zone_fog * (1.0 + (0.55 - 1.0) * grid_glow)
	if env.volumetric_fog_enabled:
		# lit volumetric fog scatters every tube it passes and piles up with distance (a glowing far band), so
		# in the found-footage look's clear air it is almost gone
		env.volumetric_fog_density = 0.016 * lit_scale * zone_fog * (1.0 + (0.55 - 1.0) * grid_glow) * (1.0 - 0.85 * open_mix) * (1.0 - 0.7 * _lim)
		env.volumetric_fog_albedo = Color(0.88, 0.82, 0.58, 1.0).lerp(Color(0.08, 0.06, 0.03, 1.0), darkness)
		env.volumetric_fog_emission = VFOG_EMISSION * (1.0 - 0.85 * open_mix)   # its own glow piles up with distance too

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
	if _lim > 0.001:                   # the liminal look under everything else
		b = {}
		var l: Dictionary = ATMOSPHERES.liminal
		for k in _env_base:
			b[k] = lerp(_env_base[k], l[k], _lim) if l.has(k) else _env_base[k]
	env.ambient_light_energy = lerpf(b.ambient_energy, a.ambient_energy, open_mix)
	env.ambient_light_color = (b.ambient_color as Color).lerp(a.ambient_color, open_mix)
	env.tonemap_exposure = lerpf(b.exposure, a.exposure, cam_mix) * exposure_gain
	env.tonemap_white = lerpf(b.tonemap_white, a.tonemap_white, cam_mix)
	env.glow_hdr_threshold = lerpf(b.glow_threshold, a.glow_threshold, cam_mix)
	env.glow_intensity = lerpf(b.glow_intensity, a.glow_intensity, cam_mix) * (1.0 + 0.35 * glare)   # the light you stare into blooms a bit more
	env.glow_bloom = lerpf(b.glow_bloom, a.glow_bloom, cam_mix)
	env.set_glow_level(5, _glow_level(5, lerpf(b.glow_wide, a.glow_wide, cam_mix)))
	env.ssao_intensity = lerpf(b.ssao_intensity, a.ssao_intensity, cam_mix)

## A glow level is either off or clearly on, never faint. A level with a tiny share of the glow (under about
## 1 %: measured, 0.03 next to the other levels' 3.4 broke and 0.05 did not) still gets added to the picture
## but its buffer is not redrawn, and after the 3D render size changes (adaptive resolution, graphics.gd) that
## buffer is whatever was left in video memory: big blurred blocks of pink, blue and orange over a green
## picture. The wide halo fades in from 0 with the look (liminal_mix / cam_mix), so it sat in that range
## every time a look was blending in or out.
const GLOW_LEVEL_MIN := 0.02       # of the other levels' sum: twice the share that breaks
func _glow_level(idx: int, v: float) -> float:
	var others := 0.0
	for i in 7:
		if i != idx: others += env.get_glow_level(i)
	return v if v >= GLOW_LEVEL_MIN * (others if env.glow_normalized else 1.0) else 0.0

## The found-footage camera (weighted by cam_mix: the classic look). Elsewhere the eye adaptation and the
## glare stop-down stay as they were.
func _update_camcorder(delta: float, seen: float) -> void:
	var ff := cam_mix
	# auto exposure: the meter reads tube light round you and ahead plus whatever bright thing is in the
	# middle of the frame; the iris follows late and overshoots, so turning into a lit hall blows the picture
	# out for a moment, then it dims past the mark and creeps back
	var meter := 0.15 + seen * 0.75 + glare * 0.9
	_ae_meter += (meter - _ae_meter) * minf(1.0, delta * AE_METER_SPEED)
	var goal := clampf(AE_KEY / maxf(_ae_meter, 0.05), AE_MIN, AE_MAX)
	var w := TAU * AE_HZ
	_ae_v += ((goal - _ae) * w * w - _ae_v * 2.0 * AE_DAMP * w) * delta
	_ae = clampf(_ae + _ae_v * delta, AE_MIN * 0.8, AE_MAX * 1.2)
	exposure_gain = lerpf(eye * lerpf(1.0, GLARE_DIM, glare), _ae, ff)
	# white balance: a slow wander between warmer / cooler and greener / pinker, and the tubes' own tint
	# (events recolour them) taken halfway back out, late, the way a camcorder's auto white balance does
	_wb_t += delta
	var temp := _wb_noise.get_noise_1d(_wb_t * 3.5) * WB_DRIFT
	var green := _wb_noise.get_noise_1d(_wb_t * 5.0 + 500.0) * WB_DRIFT * 0.3   # a green cast reads as sickly, keep it small
	var lum := (tint.r + tint.g + tint.b) / 3.0
	var corr := Vector3.ONE
	if lum > 0.02:
		corr = Vector3(clampf(lum / maxf(tint.r, 0.05), 0.6, 1.6), clampf(lum / maxf(tint.g, 0.05), 0.6, 1.6),
			clampf(lum / maxf(tint.b, 0.05), 0.6, 1.6))
	_wb_corr = _wb_corr.lerp(Vector3.ONE.lerp(corr, WB_CORRECT), minf(1.0, delta * WB_SPEED))
	var wbv := Vector3(1.0 + temp, 1.0 + green, 1.0 - temp * 1.4) * _wb_corr
	if Gfx.post_mat:
		Gfx.post_mat.set_shader_parameter("wb", Vector3.ONE.lerp(wbv, ff))
		Gfx.post_mat.set_shader_parameter("black_lift", FF_BLACK_LIFT * ff)
	# the ceiling: bright with bounced light while the power is on (open_mix already drops in a power cut).
	# Only in the found-footage (classic) levels, lit evenly everywhere: the fill is one value on the shared
	# ceiling material, so in a dim level a bright zone would light every ceiling, over dead tubes too.
	var fill := FF_CEIL_FILL * open_mix if atmosphere() == "classic" else 0.0
	if absf(fill - _ceil_fill) > 0.002:
		_ceil_fill = fill
		for m in ceil_mats:
			if m is ShaderMaterial:
				(m as ShaderMaterial).set_shader_parameter("ceiling_fill", fill)
			elif m is StandardMaterial3D:
				(m as StandardMaterial3D).emission_energy_multiplier = fill

## The horizon fog quad (HORIZON_SHADER): its vertex shader pins it over the whole screen, so it is never
## culled and draws last, over every other transparent thing.
func _build_horizon_fog() -> void:
	var sh := Shader.new()
	sh.code = HORIZON_SHADER
	_horizon_mat = ShaderMaterial.new()
	_horizon_mat.shader = sh
	_horizon_mat.render_priority = Material.RENDER_PRIORITY_MAX
	_horizon_mat.set_shader_parameter("begin", HORIZON_BEGIN)
	_horizon_mat.set_shader_parameter("end", HORIZON_END)
	var q := QuadMesh.new()
	q.size = Vector2(2.0, 2.0)
	_horizon = MeshInstance3D.new()
	_horizon.mesh = q
	_horizon.material_override = _horizon_mat
	_horizon.extra_cull_margin = 16384.0
	_horizon.ignore_occlusion_culling = true
	_horizon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_horizon.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(_horizon)

func update_lighting(delta: float) -> void:
	if player == null or pool.is_empty(): return
	_update_fixtures(delta)
	_update_pool(delta)
	_update_atmosphere(delta)
