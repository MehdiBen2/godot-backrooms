extends Node
## THE RENDER ENGINE, v2 (autoload: Render). Drives the simulated camera every frame (shaders/render/camera.gdshader):
## which camera is filming, how fast the picture slides (motion blur), how hard the sensor is pushed (noise),
## and how much VHS damage a scare puts on the tape. The lens is the original barrel fish eye for both.
## (A true fisheye and a rolling shutter were tried and taken out: both read as a warping picture, not a camera.)
##
## Three cameras, blended (cam_mode 0 .. 1 is bodycam .. camcorder; clean_mix leans the bodycam to the clean one):
##   BODYCAM    a digital camera with a touch of old tape: noisy shadows, sharpening, compression blocks in the
##              dark, light tape grain and colour bleed. The default.
##   CLEAN      a good digital camera: a fine grain, a little lens fringing and vignette, no tape, no codec. Takes
##              over from the bodycam in a Classic zone (the clean, evenly lit Level 0 look).
##   CAMCORDER  a late-90s tape camcorder: tape grain and the full VHS chain.
## Graphics setting `camera` (Gfx.camera): "bodycam" (the default; clean in a Classic zone), "camcorder" (always
## that one), or "auto" (the camcorder in a Classic zone: the old found-footage tape look).

const PROFILES := {
	"bodycam": {
		"fov_boost": 0.0,            # (the lens is the original barrel fish eye: it needs no wider render)
		"chroma_amt": 0.0032,        # colour fringing toward the edges, a little stronger than a clean lens: old-tape feel
		"shutter": 1.0 / 100.0,      # a fast shutter: turning the head blurs a little, never smears (see blur_max_px)
		"sharpen": 0.45,
		"codec": 0.55,
		"noise_luma": 0.05,
		"noise_chroma": 0.045,
		"vignette_amt": 0.55,
		"vhs": 0.2,                  # a subtle touch of tape: soft colour bleed, faint line wobble
		"tape": 0.6,                 # and its grain, under the digital noise
		# the tubes light everything warm yellow; a digital camera's white balance takes part of that back out,
		# so the halls stay yellow but not soaked in it (cooler red / blue balance than the tape grade)
		"grade": Color(0.96, 1.0, 1.1),
	},
	"clean": {
		"fov_boost": 0.0,
		"chroma_amt": 0.0024,        # a little fringing toward the edges: a real lens, not a broken one
		"shutter": 1.0 / 120.0,
		"sharpen": 0.4,              # a digital camera's in-camera sharpening: the wallpaper's grain and the tile edges read
		"codec": 0.0,
		"noise_luma": 0.03,          # a fine sensor grain over the walls
		"noise_chroma": 0.008,
		"vignette_amt": 0.72,
		"vhs": 0.0,
		"tape": 0.12,
		"grade": Color(0.98, 1.0, 1.04),   # a lighter white-balance pull: the walls keep their yellow
	},
	"camcorder": {
		"fov_boost": 0.0,
		"chroma_amt": 0.0028,
		"shutter": 1.0 / 60.0,
		"sharpen": 0.0,
		"codec": 0.0,
		"noise_luma": 0.0,
		"noise_chroma": 0.0,
		"vignette_amt": 0.62,
		"vhs": 1.0,
		"tape": 1.0,
		"grade": Color(0.96, 1.0, 1.1),     # (unused: the camcorder keeps the shader's own warm tape grade)
	},
}
const MODE_SPEED := 0.6              # 1/s: how fast one camera hands over to the other (a zone change)
const SPIN_SMOOTH := 18.0            # 1/s: the measured slide is eased, so one jittery frame doesn't smear
const SPIN_MAX := 4.0                # screens per second: anything faster is a teleport / cut, not a pan
const BASE_EXPOSURE := 0.95          # main.tscn's tonemap exposure: the sensor gain is measured against it

var mode_mix := 0.0                  # 0 bodycam .. 1 camcorder (eased)
var clean_mix := 0.0                 # 0 bodycam .. 1 clean, under the camcorder (eased)
var fov_boost := 0.0                 # player.gd adds this to the field of view (see PROFILES)
var spin := Vector2.ZERO             # how fast the picture slides right now (screen widths / heights per second)
var vfov := deg_to_rad(75.0)
var _yaw := 0.0
var _pitch := 0.0
var _have_angles := false
var _cam_id := 0

func active() -> bool:
	return Gfx.post_mat != null

func _process(dt: float) -> void:
	if not active():
		fov_boost = 0.0
		return
	var mat := Gfx.post_mat
	# which camera: forced by the setting, or (auto) the camcorder in a Classic zone
	var want := 0.0
	var want_clean := 0.0
	match Gfx.camera:
		"camcorder": want = 1.0
		"bodycam": want_clean = clampf(Game.fx_classic * 1.3, 0.0, 1.0)   # a Classic zone films clean
		_: want = clampf(Game.fx_classic * 1.3, 0.0, 1.0)                 # auto: the old tape look in a Classic zone
	mode_mix = move_toward(mode_mix, want, dt * MODE_SPEED)
	clean_mix = move_toward(clean_mix, want_clean, dt * MODE_SPEED)
	var a: Dictionary = _blend(PROFILES.bodycam, PROFILES.clean, clean_mix)
	var b: Dictionary = PROFILES.camcorder
	var m := mode_mix
	fov_boost = lerpf(a.fov_boost, b.fov_boost, m)
	_measure_camera(dt)
	# a scare damages the tape whichever camera it is: glitches and terror push VHS sync trouble in
	var scare := clampf(Game.glitch * 1.2 + Game.terror * 0.45, 0.0, 0.85)
	mat.set_shader_parameter("cam_mode", m)
	mat.set_shader_parameter("cam_spin", spin)
	mat.set_shader_parameter("shutter", lerpf(a.shutter, b.shutter, m))
	mat.set_shader_parameter("sharpen", lerpf(a.sharpen, b.sharpen, m))
	mat.set_shader_parameter("codec", lerpf(a.codec, b.codec, m))
	mat.set_shader_parameter("noise_luma", lerpf(a.noise_luma, b.noise_luma, m))
	mat.set_shader_parameter("noise_chroma", lerpf(a.noise_chroma, b.noise_chroma, m))
	mat.set_shader_parameter("chroma_amt", lerpf(a.chroma_amt, b.chroma_amt, m))
	mat.set_shader_parameter("vignette_amt", lerpf(a.vignette_amt, b.vignette_amt, m))
	mat.set_shader_parameter("vhs", maxf(lerpf(a.vhs, b.vhs, m), scare))
	mat.set_shader_parameter("tape", lerpf(a.tape, b.tape, m))
	var gr: Color = a.grade
	mat.set_shader_parameter("grade_digital", Vector3(gr.r, gr.g, gr.b))
	mat.set_shader_parameter("iso", _sensor_gain())
	# fluorescent banding (Gfx `banding`, the CAMERA menu): as strong as the tube light on the player, none outdoors
	# (full strength under any ordinary lamp: the tube light on the player is rarely over a half)
	var tubes := 0.0 if Game.outdoors else clampf(Game.fx_tubes * 2.5, 0.0, 1.0)
	mat.set_shader_parameter("banding", tubes if bool(Gfx.s.get("banding", true)) else 0.0)

## Profile `a` leaned `t` of the way to `b` (numbers and colours)
func _blend(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	if t <= 0.0: return a
	var out := {}
	for k in a:
		out[k] = lerp(a[k], b[k], t) if b.has(k) else a[k]
	return out

## The camera that is drawing the frame: its field of view, and how fast its view is turning, as the speed the
## picture slides across the screen (what the rolling shutter and the motion blur need)
func _measure_camera(dt: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or not is_instance_valid(cam):
		spin = Vector2.ZERO
		_have_angles = false
		return
	vfov = deg_to_rad(clampf(cam.fov, 10.0, 150.0))
	var f := -cam.global_transform.basis.z
	var yaw := atan2(-f.x, -f.z)
	var pitch := asin(clampf(f.y, -1.0, 1.0))
	var target := Vector2.ZERO
	# a new camera (death camera, a cutscene) or a long frame (loading): no history to compare against
	if _have_angles and cam.get_instance_id() == _cam_id and dt > 0.0001 and dt < 0.1:
		var aspect := get_viewport().get_visible_rect().size.aspect()
		var hfov := 2.0 * atan(tan(vfov * 0.5) * aspect)
		# turning left (yaw up) slides the picture right; looking up (pitch up) slides it down
		target = Vector2(wrapf(yaw - _yaw, -PI, PI) / dt / hfov, (pitch - _pitch) / dt / vfov)
		if target.length() > SPIN_MAX:
			target = Vector2.ZERO              # a snap, not a pan
	spin = spin.lerp(target, minf(1.0, dt * SPIN_SMOOTH))
	_yaw = yaw
	_pitch = pitch
	_cam_id = cam.get_instance_id()
	_have_angles = true

## How hard the sensor is pushed: the scene's exposure against the base look's (the eye adaptation / auto exposure
## opening up in the dark shows here as more noise, like a real camera raising its gain)
func _sensor_gain() -> float:
	var main: Node = Game.main if Game.main != null and is_instance_valid(Game.main) else null
	var we: WorldEnvironment = null
	if main != null:
		we = main.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we == null or we.environment == null:
		return 1.0
	return clampf(we.environment.tonemap_exposure / BASE_EXPOSURE, 0.5, 3.0)
