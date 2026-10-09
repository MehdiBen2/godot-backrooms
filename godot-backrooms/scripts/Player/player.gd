extends CharacterBody3D
## First-person controller. Values mirror PLAYER_DEFAULTS / JUMP in the web game.
## Movement reads PHYSICAL keys, so WASD works as ZQSD on AZERTY (and any other layout).
##
## Its parts live beside it: footsteps.gd (your footfalls), torch_model.gd (the torch in your hand),
## blink.gd (your eyelids). The flashlight beam, stamina, adrenaline and sanity are here.

const Footsteps := preload("res://scripts/Player/footsteps.gd")
const TorchModel := preload("res://scripts/Player/torch_model.gd")
const Blink := preload("res://scripts/Player/blink.gd")
const PlayerShadow := preload("res://scripts/Player/player_shadow.gd")
const Handheld := preload("res://scripts/Player/handheld.gd")
const Peek := preload("res://scripts/Player/peek.gd")
const CornerGrab := preload("res://scripts/Player/corner_grab.gd")

const SPEED := 2.6
const SPRINT_MULT := 1.75
const CROUCH_MULT := 0.52
const STAND_H := 1.7
const CROUCH_H := 1.0
const JUMP_SPEED := 5.0
const GRAVITY := 20.0
const DRAIN_ZONE_RATE := 4.5      # sanity a second lost in a Drain zone: more than a lit room gives back (2.2)
const FALL_SPEED_MAX := 30.0     # m/s: a shaft can run through many floors (or have no bottom), each built as you reach it
# A long fall: past FALL_FX_FROM m/s the view widens, shudders in the rushing air and streaks along the way you
# are going (camera.gdshader fall_blur), all of it full at FALL_FX_FULL (a bottomless pit's speed, pit_fall.gd)
const FALL_FX_FROM := 9.0
const FALL_FX_FULL := 50.0
const FALL_FOV := 13.0           # degrees added at full speed
const FALL_BLUR := 0.03          # streak length at full speed, in screen heights
const FALL_WARP := 0.1           # extra barrel bend of the lens
const FALL_BUFFET := 0.007       # rad of shudder
# Movement feel: weighty but responsive, forgiving jumps
const ACCEL_GROUND := 16.0        # x speed per second towards the wished velocity (was an instant 40 m/s^2)
const DECEL_GROUND := 22.0        # a touch snappier when letting go, so stops feel deliberate
const ACCEL_AIR := 5.0            # limited steering in the air
const COYOTE_TIME := 0.10         # can still jump this long after walking off an edge
const JUMP_BUFFER := 0.12         # a press this soon before landing still jumps
const LEAN_WALK := 0.010          # camera roll into a strafe (rad)
const LEAN_SPRINT := 0.018
const SPRINT_SECONDS := 30.0
const STAMINA_REGEN := 18.0
# Adrenaline (ADRENALINE in js/config.js): hunted by the bacteria up close, you get a burst of speed
# and endless sprint to break away, then a crash
const ADR_RANGE := 22.0          # metres: it must be chasing you from at least this close
const ADR_BOOST := 0.5           # +50% movement speed
const ADR_RAMP := 0.35           # seconds to reach full strength
const ADR_MAX_TIME := 10.0       # longest a burst can last
const ADR_AFTERGLOW := 3.5       # seconds it lingers after the chase ends
const ADR_CRASH_STAMINA := 25.0  # stamina you're left with when it fades
const ADR_COOLDOWN := 22.0       # seconds before it can kick in again
const ADR_FOV := 9.0             # extra field of view at full strength (degrees)
# three.js fov is vertical; Godot's default keeps height too (KEEP_HEIGHT)
const BASE_FOV := 75.0
const INSANE_BELOW := 60.0     # the picture starts to go and the eyes open below this
const HURT_SANITY := 30.0      # health starts draining below this
const CALM_SANITY := 60.0      # health starts coming back above this
const FLASH_ENERGY_HOTSPOT := 6.5
const FLASH_ENERGY_SPILL := 2.0
const BATTERY_DRAIN := 100.0 / 75.0     # % per second while on (75 s of light)
const BATTERY_LOW := 25.0
const BATTERY_CRIT := 10.0

@onready var cam: Camera3D = $Camera3D
@onready var flash: SpotLight3D = $Camera3D/Flashlight
@onready var shape: CollisionShape3D = $CollisionShape3D
var flash_spill: SpotLight3D
static var _beam_tex: Texture2D
var footsteps: Footsteps
var torch: TorchModel
var blink: Blink
var shadow_body: PlayerShadow
var level: Node
var fullbright_light: OmniLight3D

signal jumped
signal landed(strength: float)
signal battery_died
signal battery_swap              # the cells are being changed (audio.gd: battery_swap.wav)
signal battery_swap_cut          # and the change was cut short: the sound stops
signal dead_click
signal contact_click(off: bool)
signal adrenaline_started
signal adrenaline_faded

# settings (menu.gd pushes them in through hud.apply_settings)
var sens := 0.0022
var base_fov := BASE_FOV
var head_bob := 1.0              # 0 = steady camera, 1 = full bob / lean / landing dip

var is_sprinting := false
var is_moving := false
var is_crouching := false
var was_airborne := false
var air_time := 0.0
var last_vy := 0.0
var eye := STAND_H
var was_stepping := false
var step_triggered := false
var fov_kick := 0.0
var fall_speed_max := FALL_SPEED_MAX   # pit_fall.gd raises it while you drop down a bottomless pit
var fall_fx := 0.0               # 0..1 eased: how much the fall shows on the view
var _fall_post := false          # the post shader's fall streaks were left on
var handheld := Handheld.new()   # camcorder-in-the-hands offsets: tremor, slow wander, uneven steps (handheld.gd)
var peek := Peek.new()           # facing a wall edge, the view leans out round it on its own (peek.gd)
var cam_shake := 1.0             # 0 = no handheld camcorder shake while walking / running, 1 = full
var lens_up := 0.0               # 0..1 the camcorder raised to your eye (zoom_tool.gd, hold X)
var lens_zoom := 1.0             # magnification it gives at that raise: narrows the field of view, slows the aim
var fov_flat := BASE_FOV         # the field of view before the lens zoom
var bob_amp := 1.0              # eased per-step bob height from handheld.step_amp
var health := 100.0
var sanity := 100.0
var sanity_lock := -1.0        # >= 0 pins sanity there (debug console)
var unnerved := 0.0            # s left: something holding your gaze (the mannequins) stops light calming you
var insanity := 0.0            # 0..1 how far gone: blur, double vision, the eyes
var hurt_tick := 0.0
var battery := 100.0          # flashlight battery, %
var swap_dark := false        # mid battery swap, the cap off the torch: no light
var swap_charge := 0.0        # % waiting to go in when the swap is done
var flash_on := true
var light_level := 1.0
var flash_target := Vector3.ZERO
var flash_flicker := {"timer": 6.0, "active": false, "step": 0.0, "value": 1.0}
var flicker_left := 0.0
var dead := false:
	set(v):
		dead = v
		if v: _drop_lens()
var grid_down := false       # power cut: the torch drains slowly
var spawn_grace := 0.0
var frozen := false:         # grabbed / snapped: no input
	set(v):
		frozen = v
		if v: _drop_lens()
var stamina := 100.0
var exhausted := false
var rest_timer := 0.0
var adrenaline := 0.0          # 0..1 strength of the burst, eased in and out
var adr_active := false
var adr_time := 0.0
var adr_glow := 0.0
var adr_cooldown := 0.0
var adr_idle := 0.0            # seconds since an entity last ticked the adrenaline (it stops when they despawn or hide)
var bob := 0.0
var bob_w := 0.0                 # eased 0..1: how much of a walking stride is in the view
var bob_rate := 5.3              # how fast `bob` runs right now (rad/s): one step per PI
var stair_w := 0.0               # eased 0..1: how much of a stair flight is underfoot
var stair_vy := 0.0              # smoothed climb rate on a flight (m/s, + up)
var stair_prev_y := 0.0
var breath := 0.0
var click_player: AudioStreamPlayer
var click_on: AudioStream = load("res://audio/on.mp3")
var click_off: AudioStream = load("res://audio/off.mp3")

# --- Door interaction & camera animation ---
var focused_door: Node = null
var _door_anim_active := false   # in the scripted scene through a door (_door_scene): it has the body, the eyes and the left hand
var _ds: Node3D = null            # the door
var _ds_t := 0.0                  # s into the scene
var _ds_open := true
var _ds_side := 1.0               # the door's face you work it from (door.gd side_of)
var _ds_k := -1.0                 # s into the scene the hand turned the knob / started the pull (-1 not yet)
var _ds_kside := 1.0              # +1 the knob was to your right as it began
var _ds_swing := 1.0
var _ds_pushed := false
var _ds_ghost: Object = null       # the leaf you're let through while walking past it (one collision exception, taken off at the end)
var _door_cam_pos := Vector3.ZERO
var _door_cam_rot := Vector3.ZERO
var space_prev := false
var jump_buffer := 0.0
var coyote := 0.0
var land_dip := 0.0
var quake_amt := 0.0          # 0..1: something heavy walking nearby shaking the floor (and the view)
var quake_t := 0.0
var lean := 0.0
const TURN_ROLL_MAX := 0.045
# Corner peek (peek.gd): on top of the sideways lean, the view dips, edges forward, rolls and turns a little
const PEEK_DIP := 0.035           # m
const PEEK_FWD := 0.03            # m
const PEEK_ROLL := 0.13           # rad at full head bob (half of it with head bob off)
const PEEK_YAW := 0.035           # rad, towards the opening
var _peek_slow := false
var _hug_dim := 1.0               # 1 beam on .. 0 off while both hands are on a wall
# Corner swing: walking past a wall's edge, steering round it, the near hand grabs the edge and pulls you round
const SWING_MIN_SPEED := 0.9      # m/s: walking at least this fast...
const SWING_SIDE_SPEED := 0.3     # m/s: ...and already going this fast out round the edge
const SWING_KICK := 1.1           # m/s: the pull, along the way round
const SWING_BOOST := 0.22         # share of walking speed added after it, fading
const SWING_FADE := 1.3           # s the boost takes to fade
const SWING_COOLDOWN := 1.1       # s before the next grab
# Corner grab: walking along a wall that ends just ahead, the near hand takes hold of the corner and you swing round it
const CORNER_SPEED_MIN := 1.3     # m/s: walking at least this fast, on the way ahead
const CORNER_TIME := 1.0          # s the hand stays on the corner
const CORNER_COOLDOWN := 2.0      # s before the next grab
const CORNER_STEER := 0.55        # how far (0..1) your heading is pulled round towards the corner at the most
const CORNER_BOOST := 0.35        # share of walking speed added by the pull, fading
const CORNER_FADE := 1.5          # s the boost takes to fade
var corner := CornerGrab.new()
# Squeeze gap (levels' "squeeze_gap" objects): a slit in a wall you turn sideways to pass
const SQUEEZE_RADIUS := 0.15      # m: the body's width while at a slit (normal: the capsule's own)
const SQUEEZE_SPEED := 0.3        # share of walking speed through it
# Head lamp: a small, weak lamp on the forehead for tight spots (crouched, crawling, in a slit), where the
# hand torch is put away. On by itself there, off everywhere else; it doesn't use the torch's battery.
const HEAD_LAMP_ENERGY := 1.5
const HEAD_LAMP_RANGE := 7.0      # m
const HEAD_LAMP_ANGLE := 58.0     # deg
const HEAD_LAMP_AT := Vector3(0.0, 0.07, -0.04)   # m off the eye: on the forehead
var head_lamp: SpotLight3D
var _head_k := 0.0                # 0..1 eased: how far the head lamp is on
# Crawl space (the editor's CRAWL zone): a ceiling you have to get right down under
const CRAWL_EYE := 0.62           # m: eye height crawling
const CRAWL_SPEED := 0.7          # share of crouch speed
const WADE_DEEP := 1.1            # m of water at which wading is at its slowest...
const WADE_SPEED := 0.45          # ...this share of walking speed
var wade_k := 0.0                 # 0 dry .. 1 waist deep and over, eased
const SWIM_FLOAT := 0.28          # m of you over the surface when afloat: eyes and nose out
const CLIMB_OUT_TIME := 0.8       # s: the most a heave out of the water over its side can take
const CLIMB_OUT_SPEED := 3.2
var swimming := false
var _climb_out := 0.0
const CRAWL_REACH := 0.3          # m: how far ahead of you each hand goes on the floor (inside arm's reach from a crawling shoulder)
const CRAWL_LEAD_MAX := 0.42      # m: the furthest ahead a reaching hand lands, however fast you go
const CRAWL_SWING_SHARE := 0.4    # share of a hand's cycle (two footfalls) spent in the air reaching forward
const CRAWL_LIFT := 0.07          # m a hand lifts off the carpet as it reaches
const CRAWL_WIDTH := 0.22         # m each hand is out to its side
var _cr_on := false
var _cr_plant: Array = [Vector3.ZERO, Vector3.ZERO]   # world: where each hand is down (left, right)
var _cr_from: Array = [Vector3.ZERO, Vector3.ZERO]    # world: where a reaching hand set off from
var _cr_swinging: Array = [false, false]
var crawl_k := 0.0                # 0..1 eased: in a crawl space
const SQ_AHEAD: Array[float] = [0.24, 0.3]   # m ahead of you each hand (left, right) slides along its wall
const SQ_WANDER := Vector2(0.04, 0.025)      # m the hands drift fore-aft / up-down, slowly
const SQ_RAISE_EVERY := Vector2(1.6, 3.8)    # s between one hand coming off the wall and the next
const SQ_RAISE_TIME := 0.55                  # s a raise takes, off the wall and back on
const SQ_LIFT_UP := 0.06                     # m a raised hand comes up, and
const SQ_LIFT_OUT := 0.06                    # m off the wall
var _sq_clock := 0.0
var _sq_raise_in := 2.0                      # s to the next raise
var _sq_raise_t: Array[float] = [-1.0, -1.0] # s into each hand's raise (-1 none)
var _sq_raise_dy: Array[float] = [0.0, 0.0]  # m: where each hand was put back, up or down from the middle
# The way in and out of a slit, on the camera: [t (s), yaw, roll, pitch (rad), y, z (m), fov (deg)], yaw and
# roll towards _sq_side. Going in: a little pull back first, then the shoulder turns in, head ducked and low,
# settling into the squeezed hold. Coming out: a shove the other way, then you pop free, stand tall and look
# up with the view opening wide, and settle.
const SQ_ENTER := [[0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0], [0.22, -0.05, -0.03, 0.02, -0.015, 0.03, -1.0],
	[0.75, 0.36, 0.14, -0.07, -0.06, 0.0, -5.0], [1.4, 0.06, 0.05, -0.02, -0.03, 0.0, -4.0]]
const SQ_EXIT := [[0.0, 0.06, 0.05, -0.02, -0.03, 0.0, -4.0], [0.2, -0.12, -0.07, 0.0, -0.01, -0.02, -2.0],
	[0.55, -0.04, -0.02, 0.06, 0.03, 0.0, 5.0], [1.3, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]]
var _sq_cam_anim := 0                        # 0 out, 1 going in, 2 in, 3 coming out
var _sq_cam_t := 0.0
var _sq_cam_keys: Array = []                 # the clip playing (its first key: where it set out from)
var _sq_cam: Array = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]   # yaw, roll, pitch, y, z, fov right now
var tight_k := 0.0               # 0..1 eased: how far into a squeeze (the breathing and the head bob read it)
var _sq := {}                     # the squeeze gap here (level_geometry.gd squeeze_at), {} when none
var _sq_radius := 0.0             # the capsule's normal radius
var _sq_side := 1.0               # which shoulder goes in first (+1 right)
var _corner_on := false
var _corner_t := 0.0
var _corner_cd := 0.0
var _corner_boost := 0.0
var _swing_cd := 0.0
var _swing_boost := 0.0
var _swinging := false
const PEEK_HOLD_SPEED := 1.8      # m/s: slower than this a hand in reach takes hold of the edge
var look_from := -1          # msec the mouse was captured at: the jump that comes with capturing is dropped
var turn_accum := 0.0         # mouse yaw since the last physics tick (rad)
var turn_roll := 0.0
var idle_time := 0.0
var idle_amt := 0.0
var pitch_off := 0.0          # motion pitch offset currently added onto cam.rotation.x
var pitch_applied := 0.0
var dark_time := 0.0          # how long you have been in the dark with no light of your own
var beam_tilt := 0.0          # eased sprint/crouch dip: the beam drops with the hand, not just the model
var beam_pos := Vector3.ZERO  # eased light origin: the torch lens, pulled back to the eye inside walls
const BEAM_TILT_MAX := 0.30   # rad: how far the arm may drop the beam (any more and it only skims the floor)

## A real torch's beam is not a smooth disc: the reflector and lens leave a bright core, a faint ring where the lens
## edge throws light, a little grain in the glass, and a softer edge. Projected through the spot as a light cookie
## (light_projector), so it lands on walls and tape with that texture, and it is made once for every torch.
static func beam_cookie() -> Texture2D:
	if _beam_tex != null: return _beam_tex
	const N := 256
	var img := Image.create(N, N, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	# a little low-frequency mottling in the glass (value noise, 8 by 8 knots)
	var knots := PackedFloat32Array()
	for i in 81: knots.append(rng.randf_range(0.9, 1.0))
	for y in N:
		for x in N:
			var u := (x + 0.5) / N * 2.0 - 1.0
			var v := (y + 0.5) / N * 2.0 - 1.0
			var r := sqrt(u * u + v * v)
			if r >= 1.0:
				img.set_pixel(x, y, Color(0, 0, 0, 1))
				continue
			var core := pow(maxf(0.0, 1.0 - r), 1.0)                  # the bright middle, falling off to the rim
			var ring := 0.22 * exp(-pow((r - 0.62) / 0.07, 2.0))      # the lens edge: a soft bright ring
			var edge := smoothstep(1.0, 0.82, r)                       # the beam fades out at the rim
			var fx := (u * 0.5 + 0.5) * 7.0
			var fy := (v * 0.5 + 0.5) * 7.0
			var ix := int(floor(fx)); var iy := int(floor(fy))
			var tx := fx - ix; var ty := fy - iy
			var a := knots[iy * 9 + ix]; var b := knots[iy * 9 + ix + 1]
			var c := knots[(iy + 1) * 9 + ix]; var d := knots[(iy + 1) * 9 + ix + 1]
			var mottle := lerpf(lerpf(a, b, tx), lerpf(c, d, tx), ty)
			var grain := 0.96 + 0.04 * rng.randf()
			var val := minf(1.0, (core * 1.5 + ring) * edge * mottle * grain)   # (fuller than the raw falloff: the beam keeps its reach)
			img.set_pixel(x, y, Color(val, val, val, 1.0))
	_beam_tex = ImageTexture.create_from_image(img)
	return _beam_tex

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# stairs and ramps (props/vertical_pieces.gd, props/stairs.gd): as fast up a slope as on the flat, held down onto
	# it going down instead of skipping off each tread, and a slope a little past 45 degrees still a floor
	floor_constant_speed = true
	floor_snap_length = 0.45
	floor_max_angle = deg_to_rad(48.0)
	level = get_parent().get_node_or_null("Level")
	# The beam leaves from the low hand now, so it skims the floor: at that grazing angle the shadow map
	# bands across it, which a normal bias lifts. Level lamps set theirs in code too, not in the scene.
	flash.shadow_normal_bias = 2.0
	flash.shadow_blur = 1.0
	flash.spot_angle_attenuation = 1.45
	flash.spot_attenuation = 1.2
	flash.light_projector = beam_cookie()          # the lens pattern of a real torch (a texture, not a flat disc)
	# the beam is not drawn into the fog: there the lens pattern showed as a flat picture in the air
	# in front of the camera, instead of on the walls
	flash.light_volumetric_fog_energy = 0.0
	flash.top_level = true
	flash.visible = true
	flash_spill = flash.get_node_or_null("Spill") as SpotLight3D
	if flash_spill == null:
		flash_spill = SpotLight3D.new()
		flash_spill.name = "Spill"
		flash_spill.light_color = Color(1.0, 0.94, 0.84, 1.0)
		flash_spill.light_energy = FLASH_ENERGY_SPILL
		flash_spill.spot_range = 20.0
		flash_spill.spot_angle = 58.0
		flash_spill.spot_attenuation = 1.2
		flash_spill.spot_angle_attenuation = 1.3
		flash_spill.shadow_enabled = false
		flash.add_child(flash_spill)
	head_lamp = SpotLight3D.new()
	head_lamp.name = "HeadLamp"
	head_lamp.position = HEAD_LAMP_AT
	head_lamp.light_color = Color(1.0, 0.93, 0.8)
	head_lamp.spot_range = HEAD_LAMP_RANGE
	head_lamp.spot_angle = HEAD_LAMP_ANGLE
	head_lamp.spot_attenuation = 1.4
	head_lamp.spot_angle_attenuation = 1.6
	head_lamp.shadow_enabled = true
	head_lamp.shadow_normal_bias = 2.0
	head_lamp.shadow_blur = 1.5
	head_lamp.light_energy = 0.0
	head_lamp.visible = false
	cam.add_child(head_lamp)
	torch = TorchModel.new()
	cam.add_child(torch)
	if not torch.build():
		torch.queue_free()
		torch = null
	else:
		torch.swap_started.connect(func(): battery_swap.emit())
		torch.swap_cut.connect(func(): battery_swap_cut.emit())
		torch.swap_dark.connect(func(dark: bool): swap_dark = dark)
		torch.swap_done.connect(_swap_done)
	shadow_body = PlayerShadow.new()
	add_child(shadow_body)
	if not shadow_body.build():
		shadow_body.queue_free()
		shadow_body = null
	else:
		# The flashlight is mounted on this same body, so up close it clips through its own
		# shadow-only geometry (worst when looking down or mid-sprint). Only the ceiling tubes,
		# far enough away not to self-intersect, are left to light/shadow it. Both masks matter:
		# light_cull_mask alone only stops the flashlight from lighting the body, shadow_caster_mask
		# is the one that actually keeps it out of the flashlight's shadow map.
		flash.light_cull_mask &= ~PlayerShadow.SHADOW_LAYER
		flash.shadow_caster_mask &= ~PlayerShadow.SHADOW_LAYER
		flash_spill.light_cull_mask &= ~PlayerShadow.SHADOW_LAYER
		flash_spill.shadow_caster_mask &= ~PlayerShadow.SHADOW_LAYER
		head_lamp.light_cull_mask &= ~PlayerShadow.SHADOW_LAYER
		head_lamp.shadow_caster_mask &= ~PlayerShadow.SHADOW_LAYER
	footsteps = Footsteps.new()
	footsteps.name = "Footsteps"
	add_child(footsteps)
	blink = Blink.new()
	blink.name = "Blink"
	add_child(blink)
	click_player = AudioStreamPlayer.new()
	click_player.volume_db = -4.4
	add_child(click_player)
	fullbright_light = OmniLight3D.new()
	fullbright_light.name = "FullbrightLight"
	fullbright_light.omni_range = 250.0
	fullbright_light.omni_attenuation = 0.35
	fullbright_light.light_energy = 2.2
	fullbright_light.light_color = Color(1.0, 0.98, 0.94)
	fullbright_light.shadow_enabled = false
	fullbright_light.visible = Game.fullbright
	cam.add_child(fullbright_light)

func _key(code: Key) -> bool:
	return Input.is_physical_key_pressed(code)

func _unhandled_input(e: InputEvent) -> void:
	if dead or frozen or _door_anim_active: return     # the door scene has the view and the hands
	if e is InputEventMouseMotion and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		look_from = -1
	elif e is InputEventMouseMotion:
		# capturing warps the cursor to the centre and reports it as one big move, which would spin you
		# off the direction the level spawns you facing: ignore motion for a moment after capture
		if look_from < 0: look_from = Time.get_ticks_msec()
		if Time.get_ticks_msec() - look_from < 150: return
		# zoomed in, the same hand movement sweeps a smaller slice of the world: the aim slows with the lens
		var aim := sens / pow(lens_zoom, 0.8)
		rotate_y(-e.relative.x * aim)
		turn_accum += -e.relative.x * aim
		# set the Euler pitch directly: rotate_x() on a camera with lean/roll (rotation.z) mixes axes,
		# so the clamp read back a wrapped angle and let the view flip past straight down
		cam.rotation.x = clampf(cam.rotation.x - e.relative.y * aim, -1.49, 1.49)
		_sync_flashlight_aim(0.35)
	elif e.is_action_pressed("flashlight") and lens_up <= 0.0 \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if not flash_on and battery <= 0.0:
			dead_click.emit()          # dead battery: a dry hollow click, nothing else
			return
		flash_on = not flash_on
		click_player.stream = click_on if flash_on else click_off
		click_player.play()
	elif (e.is_action_pressed("interact") or (e is InputEventKey and e.pressed and not e.echo and e.physical_keycode == KEY_E)) \
			and lens_up <= 0.0 and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if focused_door != null and focused_door.has_method("interact"):
			focused_door.interact(self)
			_sync_flashlight_aim(0.35)
			get_viewport().set_input_as_handled()

func _process(delta: float) -> void:
	if not dead and not frozen:
		_update_flashlight_aim(delta)
	focused_door = _find_interactable_door() if not dead and not frozen and not _door_anim_active else null
	_update_fall_fx(delta)

func _physics_process(dt: float) -> void:
	spawn_grace = maxf(0.0, spawn_grace - dt)
	# nothing is hunting you any more (or nothing is left to say so): let the burst wind down on its own
	adr_idle += dt
	if adr_idle > 0.5 and (adr_active or adrenaline > 0.0):
		_tick_adrenaline(dt, false)
	if dead or frozen:
		if _door_anim_active: _end_door_scene()        # grabbed, or worse, with a hand on the door
		if adrenaline > 0.0 or adr_active: end_adrenaline()
		velocity.x = 0.0
		velocity.z = 0.0
		is_moving = false
		is_sprinting = false
		if not is_on_floor(): velocity.y -= GRAVITY * dt
		move_and_slide()
		peek.update(dt, self, eye, false)
		if torch:
			torch.set_hug(false, Vector3.ZERO, Vector3.ZERO, false)
			torch.set_grab(false, 1, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
			torch.set_squeeze(false, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
			torch.set_peek(peek.side, false, peek.edge, peek.normal, peek.out, peek.dist, false, is_crouching)
		if shadow_body: shadow_body.update(false, false, is_crouching, dead, 0.0)
		if dead:
			if torch:
				torch.end_swap()
				torch.update(dt, false, false, false, bob)
			flash.visible = false
			flash.light_energy = 0.0
			if flash_spill:
				flash_spill.visible = false
				flash_spill.light_energy = 0.0
		return
	if _door_anim_active:            # (it plays out even with the mouse let go: the door waits on it)
		_door_scene(dt)
		return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not Game.draw_mode:
		return
	if Game.noclip or Game.draw_mode:
		_fly(dt)
		_was_flying = true
		return
	if _was_flying:
		_was_flying = false
		shape.disabled = false         # the draw tools panel closed: solid again
	var crouch := Input.is_action_pressed("crouch")
	_update_squeeze(dt)
	var crawling: bool = Game.level != null and "crawl" in Game.level and (Game.level.crawl as Dictionary).has(Vector2i(roundi(global_position.x / Game.level.CELL), roundi(global_position.z / Game.level.CELL))) and not dead
	crawl_k = lerpf(crawl_k, 1.0 if crawling else 0.0, minf(1.0, dt * 4.0))
	if crawling:
		crouch = true                  # no standing up under a ceiling like that
	var dir := Vector2.ZERO
	if Input.is_action_pressed("move_forward"): dir.y -= 1
	if Input.is_action_pressed("move_backward"): dir.y += 1
	if Input.is_action_pressed("move_left"): dir.x -= 1
	if Input.is_action_pressed("move_right"): dir.x += 1
	var moving := dir != Vector2.ZERO
	var rush := adrenaline > 0.5 and adr_active     # sprint is free during a burst
	# wading (a Water object, level_data.gd water_depth_at): the deeper, the slower; past the waist no running
	var wade: float = Game.level.water_depth_at(global_position) if Game.level != null and Game.level.has_method("water_depth_at") else 0.0
	wade_k = lerpf(wade_k, clampf(wade / WADE_DEEP, 0.0, 1.0), minf(1.0, dt * 6.0))
	var sprint := Input.is_action_pressed("sprint") and not crouch and moving and (rush or (not exhausted and stamina > 0.0)) and tight_k < 0.25 and wade < 0.9
	is_sprinting = sprint
	is_moving = moving
	is_crouching = crouch
	_update_stamina(dt, sprint, rush)

	eye = lerpf(eye, CRAWL_EYE if crawling else (CROUCH_H if crouch else STAND_H), minf(1.0, dt * (6.0 if crawling else 10.0)))
	(shape.shape as CapsuleShape3D).height = eye + 0.1
	shape.position.y = (eye + 0.1) / 2.0

	var speed := SPEED * (SPRINT_MULT if sprint else (CROUCH_MULT if crouch else 1.0))
	speed *= 1.0 + ADR_BOOST * adrenaline
	speed *= 1.0 + SWING_BOOST * _swing_boost
	speed *= 1.0 + CORNER_BOOST * _corner_boost
	speed *= lerpf(1.0, SQUEEZE_SPEED, tight_k) * lerpf(1.0, CRAWL_SPEED, crawl_k)
	speed *= lerpf(1.0, WADE_SPEED, wade_k)
	speed *= Game.speed_mult
	var wish := (transform.basis * Vector3(dir.x, 0, dir.y)).normalized() * speed
	if _corner_on and wish.length_squared() > 0.0001:
		# the hand on the corner draws you round it
		var pull := sin(PI * clampf(_corner_t / CORNER_TIME, 0.0, 1.0)) * CORNER_STEER
		wish = wish.normalized().lerp(corner.dir, pull).normalized() * speed
	var rate := ACCEL_AIR
	if is_on_floor():
		rate = ACCEL_GROUND if moving else DECEL_GROUND
	velocity.x = move_toward(velocity.x, wish.x, rate * speed * dt)
	velocity.z = move_toward(velocity.z, wish.z, rate * speed * dt)

	var space := Input.is_action_pressed("jump")
	if space and not space_prev:
		jump_buffer = JUMP_BUFFER
	space_prev = space
	jump_buffer = maxf(0.0, jump_buffer - dt)
	coyote = COYOTE_TIME if is_on_floor() else maxf(0.0, coyote - dt)
	# Deep water (a pool, a flood over your chin): you float with your head out of it. Space swims up, crouch
	# dives, and pushing on into the pool's side heaves you up and out over it.
	# (afloat, the water stands at eye - SWIM_FLOAT: well clear of where you start and stop, so it never flickers)
	swimming = wade > eye - SWIM_FLOAT - 0.05 or (swimming and wade > eye - SWIM_FLOAT - 0.5 and not is_on_floor())
	if swimming and is_on_wall() and moving and dir.y < 0.0 and wade < eye + 0.4 and _climb_out <= 0.0:
		_climb_out = CLIMB_OUT_TIME                  # hands on the side, heave: carried on until you are over it
	if _climb_out > 0.0:
		_climb_out -= dt
		velocity.y = CLIMB_OUT_SPEED
		if not is_on_wall() and wade <= 0.05: _climb_out = 0.0      # over the rim: on you go
		jump_buffer = 0.0
		coyote = 0.0
	elif swimming:
		var want := clampf((wade - (eye - SWIM_FLOAT)) * 2.5, -1.2, 1.4)
		if crouch: want = -1.5
		elif space: want = 1.8
		velocity.y = move_toward(velocity.y, want, dt * 7.0)
		jump_buffer = 0.0
		coyote = 0.0
	elif (space or jump_buffer > 0.0) and coyote > 0.0:
		velocity.y = JUMP_SPEED * Game.jump_mult
		jump_buffer = 0.0
		coyote = 0.0
		jumped.emit()
	elif not is_on_floor():
		velocity.y = maxf(velocity.y - GRAVITY * dt, -fall_speed_max)
	last_vy = velocity.y
	move_and_slide()
	# Landing: both feet down, thud scales with the drop
	if is_on_floor():
		if was_airborne and air_time > 0.15 and last_vy < -2.0:
			var strength := minf(1.0, absf(last_vy) / 12.0)
			landed.emit(strength)
			land_dip = 0.04 + 0.10 * strength
			footsteps.step(true, false, 1.0)
		was_airborne = false
		air_time = 0.0
	else:
		was_airborne = true
		air_time += dt
	var near_door := _near_door()
	if near_door:
		peek.reset()
		_corner_on = false
		_swinging = false
		_corner_cd = maxf(_corner_cd, 1.0)
		_swing_cd = maxf(_swing_cd, 1.0)

	peek.update(dt, self, eye, is_on_floor() and not sprint and tight_k < 0.3 and not near_door)    # no peeking from inside a slit or near doors
	if not near_door:
		_update_swing(dt, crouch)
		_update_corner(dt, sprint, crouch)
	else:
		_corner_on = false
		_swinging = false

	if torch:
		var flat_speed := Vector2(velocity.x, velocity.z).length()
		_peek_slow = flat_speed < PEEK_HOLD_SPEED * (1.5 if _peek_slow else 0.8)   # hysteresis: hovering at the limit doesn't flicker the grip
		var slow := _peek_slow or _swinging      # swinging round, the hand holds on though you're moving
		_set_squeeze_hands()
		if near_door:
			torch.set_grab(false, 0, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
			torch.set_hug(false, Vector3.ZERO, Vector3.ZERO, false)
			torch.set_peek(0, false, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, 0.0, false, crouch)
		else:
			torch.set_grab(_corner_on, corner.side, corner.point, corner.normal, corner.out)
			torch.set_hug(peek.hug, peek.hug_point, peek.hug_normal, slow)
			torch.set_peek(peek.side, peek.leaning, peek.edge, peek.normal, peek.out, peek.dist, slow, crouch)
		torch.update(dt, flash_on and not dead and not _tight_spot(), is_sprinting, is_moving, bob)
		if lens_up > 0.02:
			torch.visible = false        # the camcorder is at your eye: both hands are on it
	if shadow_body:
		shadow_body.update(is_moving, is_sprinting, is_crouching, dead, Vector2(velocity.x, velocity.z).length())
	_update_flashlight(dt)
	_update_sanity(dt)
	_update_head(dt, dir, sprint, crouch, moving)

	# fell down a pit or drop hole: seamless descent to floor below, or loop to spawn (no loading screen).
	# (A pit that opens into the floor below never gets this far: level_builder.gd hands you to that floor.)
	# (A bottomless pit's fall is pit_fall.gd's, Game.freefall.)
	if global_position.y < -12.0 and not Death.respawn_busy and not Game.freefall:
		if Game.level_floor > 0:
			Game.change_floor(Game.level_floor - 1, Vector2(global_position.x / 4.5, global_position.z / 4.5), "drop_hole")
		elif global_position.y < -30.0:
			_back_to_spawn()

# Stamina: 30 s of sprint, brief rest delay, exhaustion until it recovers a bit
## Noclip (editor test launch): free flight along the camera, straight through walls and floors.
## WASD move, Space up, C/Ctrl down, Shift fast.
var _was_flying := false

func _fly(dt: float) -> void:
	shape.disabled = true
	var dir := Vector3.ZERO
	if Input.is_action_pressed("move_forward"): dir.z -= 1
	if Input.is_action_pressed("move_backward"): dir.z += 1
	if Input.is_action_pressed("move_left"): dir.x -= 1
	if Input.is_action_pressed("move_right"): dir.x += 1
	var wish := cam.global_transform.basis * dir
	if Input.is_action_pressed("jump"): wish.y += 1.0
	if Input.is_action_pressed("crouch"): wish.y -= 1.0
	velocity = Vector3.ZERO
	is_moving = false
	is_sprinting = false
	var fly_spd := (18.0 if Input.is_action_pressed("sprint") else 7.0) * Game.speed_mult
	global_position += wish.normalized() * fly_spd * dt

func _update_stamina(dt: float, sprint: bool, rush: bool) -> void:
	if Game.infinite_stamina:
		exhausted = false
		stamina = 100.0
		rest_timer = 0.0
		return
	if rush:
		exhausted = false
		stamina = maxf(stamina, 60.0)
		rest_timer = 0.6
	elif sprint:
		stamina = maxf(0.0, stamina - dt * 100.0 / SPRINT_SECONDS)
		rest_timer = 0.6
		if stamina <= 0.0: exhausted = true
	else:
		rest_timer = maxf(0.0, rest_timer - dt)
		if rest_timer == 0.0: stamina = minf(100.0, stamina + STAMINA_REGEN * dt)
		if exhausted and stamina >= 15.0: exhausted = false

# Head bob + footfalls (web updateHeadBob): a step lands at the bottom of each bob. The bob, the lean
# and the landing dip are scaled by the head-bob setting; the footfalls keep their rhythm regardless.
func _update_head(dt: float, dir: Vector2, sprint: bool, crouch: bool, moving: bool) -> void:
	var horiz := Vector2(velocity.x, velocity.z).length()
	var walking := moving and horiz > 0.3
	var y := eye
	var walk_goal := 0.0
	if not is_on_floor():
		pass                                  # no bob while airborne
	elif not walking:
		if was_stepping:
			was_stepping = false
			if not step_triggered:
				footsteps.step(false, crouch, 0.5)   # trailing foot comes down softly
				handheld.step(0.5, false)
		handheld.settle()
	else:
		was_stepping = true
		walk_goal = 1.0
		# one step per PI of `bob`: the body is lowest as each foot lands, and rises over the planted leg
		# the cadence follows how fast you are really going (speeding up into a run, an adrenaline burst, a
		# wall in the way): 5.3 at a walk, and the stride lengthens as you go faster, so 8.2 at a full sprint
		var base := SPEED * maxf(Game.speed_mult, 0.01) * (CROUCH_MULT if crouch else 1.0)
		var gait_k := horiz / base
		var before := floori(bob / PI)
		bob_rate = (4.1 if crouch else 5.3) * pow(clampf(gait_k, 0.3, 2.0), 0.78) * lerpf(1.0, 0.6, tight_k)
		bob += dt * bob_rate
		bob_amp = lerpf(bob_amp, handheld.step_amp, minf(1.0, dt * 8.0))    # no two steps the same height
		if floori(bob / PI) != before:
			footsteps.step(sprint, crouch, 1.0, clampf((gait_k - 1.0) / (SPRINT_MULT - 1.0), 0.0, 1.0))
			handheld.step(0.6 if crouch else 1.0, sprint)
			if stair_vy < -0.3:
				land_dip += 0.014 * stair_w       # stepping down a flight: each foot drops onto the tread below
		step_triggered = fposmod(bob, PI) < PI * 0.5
	bob_w = lerpf(bob_w, walk_goal, minf(1.0, dt * (9.0 if walk_goal > 0.0 else 5.0)))
	breath += dt * 1.5
	if is_on_floor():
		y += sin(breath) * 0.012 * head_bob * (1.0 - bob_w)    # standing: slow breathing
	# Walking view, like an inverted pendulum: a sharp low at each footfall and a rounded top, the body
	# swaying over the planted foot (one full side-to-side swing per two steps), a little roll with it and
	# a nod forward as the foot lands.
	var gait := head_bob * bob_w
	var rise := absf(sin(bob))                              # 0 at a footfall, 1 mid-stride
	var vert := 0.075 if sprint else (0.028 if crouch else 0.04)
	var side := sin(bob * 0.5)
	var bob_side := side * (0.035 if sprint else (0.014 if crouch else 0.022)) * gait
	var bob_roll := side * (0.012 if sprint else (0.004 if crouch else 0.006)) * gait
	# squeezed through a slit: short, slow, heavy steps, the shoulders working side to side more than the head lifts
	vert *= lerpf(1.0, 0.45, tight_k) * lerpf(1.0, 0.7, crawl_k)
	bob_side *= lerpf(1.0, 2.2, tight_k) * lerpf(1.0, 1.6, crawl_k)       # crawling the body rocks over each hand in turn
	bob_roll *= lerpf(1.0, 2.6, tight_k) * lerpf(1.0, 1.8, crawl_k)
	var bob_nod := (rise - 0.5) * (0.016 if sprint else (0.005 if crouch else 0.008)) * gait
	y += (rise - 0.64) * vert * bob_amp * gait
	# Stairs: the flight's walking surface is a smooth slope, but legs take it a tread at a time. Climbing,
	# the head goes up early in each stride as the leg pushes onto the next step, then levels; going down
	# it hangs, then drops as the foot lands. Nothing at a footfall itself, so it joins the bob seamlessly.
	var dy := global_position.y - stair_prev_y
	stair_prev_y = global_position.y
	var on_flight := walking and is_on_floor() and _on_stair_flight()
	if absf(dy) < 0.5:                                      # not a teleport or the floor swap on a far landing
		stair_vy = lerpf(stair_vy, dy / maxf(dt, 0.0001) if on_flight else 0.0, minf(1.0, dt * 10.0))
	stair_w = lerpf(stair_w, 1.0 if on_flight else 0.0, minf(1.0, dt * 6.0))
	if stair_w > 0.001:
		var stair_p := fposmod(bob, PI) / PI                # 0 at a footfall .. 1 at the next
		var stair_h := minf(absf(stair_vy) * PI / maxf(bob_rate, 0.1), 0.45)    # height won per step
		var stair_lift := (1.0 - pow(1.0 - stair_p, 2.5)) - stair_p if stair_vy > 0.0 else stair_p - pow(stair_p, 2.5)
		y += stair_lift * stair_h * stair_w * head_bob * 0.8
		if stair_vy > 0.0:
			bob_nod -= stair_lift * stair_h * stair_w * head_bob * 0.2    # leaning into the climb as you push up
	land_dip *= exp(-dt * 9.0)
	# the floor shaking under something heavy: a short low rumble, not a wobble. Squared so light steps
	# barely register and the close ones hit; scaled by the head-bob setting like the rest of the motion.
	quake_amt *= exp(-dt * 5.5)
	quake_t += dt
	var qk := quake_amt * quake_amt * head_bob
	var qx := (sin(quake_t * 31.0) + 0.6 * sin(quake_t * 53.0 + 1.7)) * 0.625
	var qy := (sin(quake_t * 37.0 + 0.4) + 0.6 * sin(quake_t * 61.0 + 2.9)) * 0.625
	cam.position = Vector3(qx * 0.025 * qk + bob_side, y- land_dip * head_bob + qy * 0.035 * qk, 0.0)
	var lean_target := -dir.x * (LEAN_SPRINT if sprint else LEAN_WALK) * head_bob if walking else 0.0
	lean = lerpf(lean, lean_target, minf(1.0, dt * 7.0))
	# turning banks the view into the turn (smoothed mouse yaw rate); rate is in rad/s
	var yaw_rate := turn_accum / maxf(dt, 0.0001)
	turn_accum = 0.0
	# the camcorder in your hands: it shakes more out of breath or with your heart pounding
	var shake := 1.0 + adrenaline * 1.5 + (1.0 if exhausted else 0.0)
	var motion := (1.8 if sprint else (0.6 if crouch else 1.0)) if walking else 0.0
	# held out at your eye the camcorder never quite stills: the shake is there standing, and the longer the
	# lens the more of it you see. Crouched you brace it against your knee.
	var steady := 0.55 if crouch else 1.0
	motion = maxf(motion, 0.55 * lens_up * steady)
	shake += lens_up * (lens_zoom - 1.0) * 0.15
	handheld.update(dt, motion, shake, cam_shake)
	if torch != null:
		torch.sway_amount = maxf(head_bob, cam_shake)    # the hands trail the view unless both are off
	_update_door_camera(dt)
	cam.position += handheld.offset
	cam.position += global_transform.basis.inverse() * peek.shift + Vector3(0.0, -PEEK_DIP * peek.amount, -PEEK_FWD * peek.amount)
	# the squeeze gap's way in / out (_update_squeeze): shoulder turn, duck, pop free
	var sq_hb := maxf(head_bob, 0.3)
	cam.position += Vector3(0.0, _sq_cam[3], _sq_cam[4]) * sq_hb
	cam.position += _door_cam_pos
	cam.rotation.y = handheld.yaw - peek.side * PEEK_YAW * peek.amount + _sq_side * _sq_cam[0] * sq_hb + _door_cam_rot.y
	turn_roll = lerpf(turn_roll, clampf(yaw_rate * 0.012, -TURN_ROLL_MAX, TURN_ROLL_MAX), minf(1.0, dt * 6.0))
	# idle: after a moment of standing still the view drifts in a slow breathing sway
	idle_time = 0.0 if (moving or not is_on_floor()) else idle_time + dt
	idle_amt = lerpf(idle_amt, clampf((idle_time - 1.0) / 1.5, 0.0, 1.0), minf(1.0, dt * 2.0))
	var sway_z := (sin(idle_time * 0.55) * 0.010 + sin(idle_time * 0.9 + 1.3) * 0.005) * idle_amt
	var sway_x := (sin(idle_time * 0.42 + 0.7) * 0.007 + sin(idle_time * 0.77) * 0.003) * idle_amt
	# the rush of air in a long fall shakes the view, more the faster you go
	var buffet := fall_fx * fall_fx * head_bob
	cam.position += Vector3(sin(quake_t * 23.0) + 0.5 * sin(quake_t * 41.0 + 1.3), sin(quake_t * 29.0 + 0.7), 0.0) * 0.012 * buffet
	cam.rotation.z = lean + (turn_roll + sway_z) * head_bob + qy * 0.01 * qk + handheld.roll + bob_roll \
			- peek.side * PEEK_ROLL * peek.amount * lerpf(0.5, 1.0, head_bob) \
			+ (sin(quake_t * 17.0) + 0.6 * sin(quake_t * 31.0 + 2.1)) * FALL_BUFFET * buffet \
			+ _sq_side * _sq_cam[1] * sq_hb \
			+ _door_cam_rot.z
	# pitch: dip into forward motion, rise on the jump, nose down while falling. Added on top of the
	# mouse pitch as an offset (previous offset removed first) so aiming and other readers stay intact.
	var fwd := -velocity.dot(global_transform.basis.z)
	var pitch_target := -clampf(fwd / SPEED, -1.0, 1.6) * 0.018
	if not is_on_floor():
		pitch_target += clampf(velocity.y * 0.008, -0.07, 0.05)
	pitch_target = (pitch_target + sway_x) * head_bob
	pitch_off = lerpf(pitch_off, pitch_target, minf(1.0, dt * 6.0))
	var pitch_total: float = pitch_off + qx * 0.006 * qk + handheld.pitch + bob_nod + float(_sq_cam[2]) * sq_hb + _door_cam_rot.x
	cam.rotation.x = clampf(cam.rotation.x - pitch_applied + pitch_total, -1.49, 1.49)
	pitch_applied = pitch_total
	# FOV: the base, +2.5 sprinting, +2 in the air (web updateFov), wider on adrenaline
	var fov_target: float = (2.5 if sprint else 0.0) + (2.0 if not is_on_floor() else 0.0) + float(_sq_cam[5])
	fov_kick += (fov_target - fov_kick) * minf(1.0, 9.0 * dt)
	# (Render.fov_boost: the bodycam's fisheye magnifies the middle of the picture; the render widens to give it back)
	fov_flat = base_fov + Render.fov_boost + fov_kick + ADR_FOV * adrenaline + FALL_FOV * fall_fx * fall_fx
	cam.fov = _zoomed_fov(fov_flat)

## The field of view through the camcorder's lens: `flat` narrowed by the magnification (a true zoom, so the
## picture is the middle of the wide one scaled up, not a bend of it)
func _zoomed_fov(flat: float) -> float:
	if lens_zoom <= 1.001:
		return flat
	return rad_to_deg(2.0 * atan(tan(deg_to_rad(flat) * 0.5) / lens_zoom))

## Grabbed, snapped or dead: the camcorder drops from your eye at once, so the sequences that take the
## view over start from the plain field of view
func _drop_lens() -> void:
	lens_up = 0.0
	lens_zoom = 1.0
	if is_instance_valid(cam):
		cam.fov = fov_flat

## The long fall on the screen: the post shader smears the picture along the way things stream past (out of
## the point you are falling towards, or into the one you are falling away from) and bends the lens a little.
## Run every frame, so the streaks go the moment you land, die or freeze.
func _update_fall_fx(dt: float) -> void:
	var want := 0.0
	if not (dead or frozen or Game.noclip or Game.draw_mode or is_on_floor()):
		want = smoothstep(FALL_FX_FROM, FALL_FX_FULL, -velocity.y)
	fall_fx += (want - fall_fx) * minf(1.0, dt * (4.0 if want > fall_fx else 9.0))
	var post := Gfx.post_mat
	if post == null: return
	if fall_fx < 0.002:
		if _fall_post:
			_fall_post = false
			post.set_shader_parameter("fall_blur", 0.0)
			post.set_shader_parameter("fall_warp", 0.0)
		return
	_fall_post = true
	# where the way you are going lands on the screen (Godot's fov is vertical); behind you, its opposite,
	# which the streaks run into instead of out of: the same lines either way
	var d := cam.global_transform.basis.inverse() * velocity.normalized()
	if d.z > 0.0: d = -d
	var t := tan(deg_to_rad(cam.fov) * 0.5)
	var vp := get_viewport().get_visible_rect().size
	var aspect := vp.x / maxf(vp.y, 1.0)
	var z := maxf(-d.z, 0.001)
	var foe := Vector2(0.5 + 0.5 * clampf(d.x / z / (t * aspect), -2000.0, 2000.0), 0.5 - 0.5 * clampf(d.y / z / t, -2000.0, 2000.0))
	post.set_shader_parameter("fall_foe", foe)
	post.set_shader_parameter("fall_blur", FALL_BLUR * fall_fx * fall_fx)
	post.set_shader_parameter("fall_warp", FALL_WARP * fall_fx)

## Walking up or down a stairwell flight (its sloped solid underfoot, props/stairs.gd tags it), not a landing
func _on_stair_flight() -> bool:
	if get_floor_normal().y > 0.97:
		return false
	for i in get_slide_collision_count():
		var c := get_slide_collision(i)
		if c.get_normal().y > 0.5:
			var sh = c.get_collider_shape()
			if sh is Node and sh.has_meta("surface"):
				return true
	return false

## How far your footsteps carry right now (the entity's hearing multiplies by this)
func step_noise() -> float:
	return footsteps.noise() if footsteps else 1.0

# Something heavy landed nearby (the bacteria's footfalls in a chase): the view dips with the floor
func jolt(amount: float) -> void:
	land_dip = maxf(land_dip, clampf(amount, 0.0, 1.0) * 0.035)

# The floor shaking under something heavy nearby: 0..1, the view rumbles and settles
func quake(amount: float) -> void:
	quake_amt = maxf(quake_amt, clampf(amount, 0.0, 1.0))

# Face to face with the bacteria up close: your torch arm jerks up in front of your face
func flinch() -> void:
	if torch != null and not dead and not frozen:
		torch.flinch()

# Adrenaline: the bacteria calls this every frame with whether it is hunting you close by
func update_adrenaline(dt: float, hunted: bool) -> void:
	adr_idle = 0.0
	_tick_adrenaline(dt, hunted)

func _tick_adrenaline(dt: float, hunted: bool) -> void:
	if dead or frozen: hunted = false
	adr_cooldown = maxf(0.0, adr_cooldown - dt)
	if not adr_active and hunted and adr_cooldown <= 0.0:
		adr_active = true
		adr_time = 0.0
		adr_glow = ADR_AFTERGLOW
		Game.fx_shock = maxf(Game.fx_shock, 0.7)     # the jolt as it hits: the picture punches in
		var sc := get_parent().get_node_or_null("Scares")
		if sc != null:
			sc.startle(0.35)
			sc.heartbeat(1.6)
		adrenaline_started.emit()
	if adr_active:
		adr_time += dt
		adr_glow = ADR_AFTERGLOW if hunted else adr_glow - dt
		if adr_time > ADR_MAX_TIME or adr_glow <= 0.0 or dead:
			adr_active = false
			adr_cooldown = ADR_COOLDOWN
			if not dead:
				stamina = minf(stamina, ADR_CRASH_STAMINA)
				rest_timer = 2.5
				adrenaline_faded.emit()
	var target := 1.0 if adr_active else 0.0
	var rate := 1.0 / ADR_RAMP if target > adrenaline else 1.0 / 1.5
	adrenaline = move_toward(adrenaline, target, rate * dt)

# Drop straight out of adrenaline (death, grab, respawn): no crash, no cooldown
func end_adrenaline() -> void:
	adr_active = false
	adr_cooldown = 0.0
	adrenaline = 0.0

func _back_to_spawn() -> void:
	end_adrenaline()
	global_position = level.spawn_pos
	velocity = Vector3.ZERO
	land_dip = 0.0
	quake_amt = 0.0
	was_airborne = false
	air_time = 0.0

## How lit the spot you stand on is: the level's tubes in the backrooms, the sky (day / night cycle) outdoors
func ambient_light() -> float:
	if Game.outdoors:
		return Game.day_light
	return level.tube_light_at(global_position) if level != null else 1.0

## Crouched, crawling or squeezed through a slit: no room to hold the torch up, the head lamp is on instead
func _tight_spot() -> bool:
	return is_crouching or crawl_k > 0.5 or tight_k > 0.4

func _update_head_lamp(dt: float) -> void:
	if head_lamp == null:
		return
	var goal := 1.0 if _tight_spot() and not dead else 0.0
	_head_k = move_toward(_head_k, goal, dt * (4.0 if goal > _head_k else 2.5))
	head_lamp.light_energy = HEAD_LAMP_ENERGY * _head_k
	head_lamp.visible = _head_k > 0.01

# ---- per-frame flashlight: battery drain, low-battery dimming/flicker, aim with slight lag ----
func _update_flashlight(dt: float) -> void:
	# both hands on a wall, or crouched / crawling / squeezed through a slit: the torch is put away, so the beam
	# fades out (and the battery rests); in a tight spot the head lamp takes over
	var hugging: bool = torch != null and torch.hugging()
	var beam_goal := 0.0 if hugging or _tight_spot() else 1.0
	_update_head_lamp(dt)
	_hug_dim = move_toward(_hug_dim, beam_goal, dt * (8.0 if beam_goal < _hug_dim else 5.0))
	if flash_on and not swap_dark and _hug_dim > 0.5:
		if Game.infinite_battery:
			battery = 100.0
		else:
			battery = maxf(0.0, battery - BATTERY_DRAIN * (0.25 if grid_down else 1.0) * dt)
		if battery <= 0.0:
			flash_on = false
			battery_died.emit()
	var k := 1.0
	if battery < BATTERY_LOW:
		var ratio := maxf(0.12, battery / BATTERY_LOW)
		k *= 0.35 + 0.65 * ratio
		if randf() < (0.32 if battery < BATTERY_CRIT else 0.10):
			k *= 0.05 + randf() * 0.45
			if torch: torch.smack()
	k *= _contact_flicker(dt)
	# Dark adaptation: in deep darkness your pupils open up and the beam reads brighter and crisper
	var lvl := ambient_light()
	var dark_boost := lerpf(1.35, 1.0, clampf(lvl, 0.0, 1.0))
	k *= _hug_dim
	var lit := flash_on and not dead and not swap_dark and _hug_dim > 0.01
	flash.light_energy = FLASH_ENERGY_HOTSPOT * k * dark_boost if lit else 0.0
	flash.visible = lit
	if flash_spill:
		flash_spill.light_energy = FLASH_ENERGY_SPILL * k * dark_boost if lit else 0.0
		flash_spill.visible = lit
	_update_flashlight_aim(dt)

## At a squeeze gap (a slit through a wall): the body goes slim in its funnel so it fits, and inside the slit
## you're squeezed: slow, breathing hard, the view glancing aside and back as you go in
func _update_squeeze(dt: float) -> void:
	_sq = Game.level.squeeze_at(global_position) if Game.level != null and Game.level.has_method("squeeze_at") and not dead else {}
	var cap := shape.shape as CapsuleShape3D
	if _sq_radius <= 0.0:
		_sq_radius = cap.radius
	cap.radius = move_toward(cap.radius, SQUEEZE_RADIUS if not _sq.is_empty() else _sq_radius, dt * (3.0 if not _sq.is_empty() else 0.8))
	var inside: bool = not _sq.is_empty() and absf((_sq.local as Vector3).x) <= Game.level.CELL * 0.5 + 0.1
	tight_k = lerpf(tight_k, 1.0 if inside else 0.0, minf(1.0, dt * 3.0))
	# the camera's way in and out (thresholds apart, so hovering at the mouth doesn't restart them)
	if tight_k >= 0.35 and (_sq_cam_anim == 0 or _sq_cam_anim == 3):
		if _sq_cam_anim == 0:
			_sq_side = 1.0 if randf() < 0.5 else -1.0
		_sq_cam_play(1, SQ_ENTER)
	elif tight_k < 0.25 and (_sq_cam_anim == 1 or _sq_cam_anim == 2):
		_sq_cam_play(3, SQ_EXIT)
	if _sq_cam_anim == 1 or _sq_cam_anim == 3:
		_sq_cam_t += dt
		_sq_cam = _sq_cam_sample(_sq_cam_keys, _sq_cam_t)
		if _sq_cam_t >= float(_sq_cam_keys[-1][0]):
			_sq_cam_anim = 2 if _sq_cam_anim == 1 else 0
	# the hands in the slit: their slow drift, and now and then one comes up off the wall and goes back
	_sq_clock += dt
	for i in 2:
		if _sq_raise_t[i] >= 0.0:
			_sq_raise_t[i] += dt
			if _sq_raise_t[i] >= SQ_RAISE_TIME * 0.5 and _sq_raise_t[i] - dt < SQ_RAISE_TIME * 0.5:
				_sq_raise_dy[i] = randf_range(-0.05, 0.05)     # put back somewhere a little different
			if _sq_raise_t[i] >= SQ_RAISE_TIME:
				_sq_raise_t[i] = -1.0
	if tight_k > 0.5:
		_sq_raise_in -= dt * (1.0 if is_moving else 0.4)
		if _sq_raise_in <= 0.0:
			_sq_raise_in = randf_range(SQ_RAISE_EVERY.x, SQ_RAISE_EVERY.y)
			var i := randi() % 2
			if _sq_raise_t[i] < 0.0:
				_sq_raise_t[i] = 0.0

## Start camera clip `keys` (SQ_ENTER / SQ_EXIT) from wherever the camera is now, so cutting one short for
## the other never jumps
func _sq_cam_play(anim: int, keys: Array) -> void:
	_sq_cam_anim = anim
	_sq_cam_t = 0.0
	_sq_cam_keys = keys.duplicate(true)
	var first: Array = [0.0]
	first.append_array(_sq_cam)
	_sq_cam_keys[0] = first

## The clip at `t`: eased (smoothstep) from key to key
func _sq_cam_sample(keys: Array, t: float) -> Array:
	for k in range(1, keys.size()):
		var b: Array = keys[k]
		if t <= float(b[0]) or k == keys.size() - 1:
			var a: Array = keys[k - 1]
			var u := smoothstep(float(a[0]), float(b[0]), t)
			var out: Array = []
			for j in range(1, 7):
				out.append(lerpf(float(a[j]), float(b[j]), u))
			return out
	return _sq_cam

# ---------------------------------------------------------------- door interaction: the scripted scene
## [E] on a door plays a short scene with the player's body, eyes and left hand (the torch stays in the
## right). Opening, from shut: step up to it, eyes down to the knob, reach and turn it; the latch gives and
## the leaf falls ajar and you look through the gap, then the push, and you follow it through the doorway.
## Shutting: turn to it, take the knob, pull it to you (backing off if it comes your way) until it knocks shut.
## The scene tells the door when the knob turns (turn_knob: the open sound starts) and when the pull starts
## (pull); door.gd times the leaf and the sounds from there. Mouse look and walking come back at the end.
const DS_STAND := 0.7                   # m out from the door, square to the middle of it: where you open it
const DS_THROUGH := 1.4                 # m past it on the far side: where the walk through ends
const DS_STEP := 1.2                    # m/s stepping up to it
const DS_WALK := 1.05                   # m/s through: slow, careful
const DS_TURN := 2.0                    # rad/s the most the body turns
const DS_PULL_AT := 0.62                # m: shutting, you keep this far from the knob
const DS_PULL_REACH := 1.05             # m: further than this from the knob, you step to it

func trigger_door_camera_animation(door: Node3D, opening: bool, swing_dir: float) -> void:
	_door_anim_active = true
	_ds = door
	_ds_t = 0.0
	_ds_open = opening
	_ds_swing = swing_dir
	_ds_pushed = false
	_ds_side = door.side_of(global_position) if door.has_method("side_of") else 1.0
	if not opening and door.has_method("face_normal"):
		# shutting, the knob on the face that looks your way (the leaf may be swung either side of you)
		_ds_side = 1.0 if door.face_normal(1.0).dot(global_position - door.knob_at(1.0)) > 0.0 else -1.0
	_ds_k = -1.0
	var knob: Vector3 = door.knob_at(_ds_side) if door.has_method("knob_at") else door.global_position
	_ds_kside = 1.0 if (cam.global_transform.basis.inverse() * (knob - cam.global_position)).x >= 0.0 else -1.0
	peek.reset()
	_corner_on = false
	_swinging = false

func _end_door_scene() -> void:
	if _ds_ghost != null and is_instance_valid(_ds_ghost):
		remove_collision_exception_with(_ds_ghost)
	_ds_ghost = null
	_door_anim_active = false
	_ds = null
	if torch != null:
		torch.set_grab(false, -1, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)

## One tick of the scene: where the body goes, where the eyes go, whether the hand is on the door, and the
## head's own motion on top (_door_cam_pos / _door_cam_rot, camera space). Stands in for the walking update.
func _door_scene(dt: float) -> void:
	var d = _ds                        # (untyped: the door script's own members)
	if d == null or not is_instance_valid(d) or not d.has_method("knob_at"):
		_end_door_scene()
		return
	_ds_t += dt
	var t := _ds_t
	var s := _ds_side
	var knob: Vector3 = d.knob_at(s)
	var goal := global_position
	var spd := DS_STEP
	var look := knob
	var look_rate := 5.0
	var hand := false
	var walk_through := false
	var walk := Vector3.ZERO
	var pos := Vector3.ZERO
	var rot := Vector3.ZERO           # pitch, yaw, roll
	var ks := _ds_kside
	var done := false
	var k := _ds_k if _ds_k >= 0.0 else 1e6      # (not yet: every later beat stays in the future)
	if _ds_open:
		var lp: Vector3 = d.to_local(global_position)
		# step up square to the middle of the door; after the push, straight through along its middle line
		goal = d.to_global(Vector3(s * DS_STAND, 0.0, 0.0))
		spd = DS_STEP
		# there and the hand on it: turn the knob (the open sound starts; the latch gives LATCH_AFTER into it)
		if _ds_k < 0.0 and ((t > 0.45 and Vector2(goal.x - global_position.x, goal.z - global_position.z).length() < 0.12) or t > 1.6):
			_ds_k = t
			k = t
			d.turn_knob()
		var r: float = k + float(d.LATCH_AFTER)       # the latch gives, the leaf falls ajar
		var p: float = k + float(d.push_after())      # the push
		if t > p + 0.15:
			walk_through = true
			var along: Vector3 = d.global_basis.x.normalized() * -s
			var across: Vector3 = d.global_basis.z.normalized()
			walk = along * DS_WALK + across * clampf(-lp.z * 4.0, -0.5, 0.5)
			if _ds_ghost == null and d.get("leaf_body") != null:
				_ds_ghost = d.leaf_body
				add_collision_exception_with(_ds_ghost)
		# a glance down to the knob (not a stare), then through the gap, then the room ahead
		if t < r:
			look = knob.lerp(d.to_global(Vector3(s * 0.2, 1.5, 0.15)), 0.45)
			look_rate = 4.0
		elif t < p + 0.25:
			look = d.to_global(Vector3(-s * 2.5, 1.55, 0.45))
			look_rate = 3.0
		else:
			look = d.to_global(Vector3(-s * 5.0, 1.6, 0.0))
			look_rate = 2.5
		hand = t > 0.25 and t < p + 0.3
		# reaching for the knob: a small dip; turning it (the rattle, the sound's first 0.15 s): a twitch of the head
		var wr := smoothstep(0.2, 0.45, t) * (1.0 - smoothstep(r, r + 0.35, t))
		pos += Vector3(0.0, -0.02, -0.02) * wr
		var wk := smoothstep(k, k + 0.06, t) * (1.0 - smoothstep(k + 0.1, k + 0.2, t))
		rot.z += ks * 0.012 * wk
		# the look through the gap: the head goes a little in toward it
		var wp := smoothstep(r, r + 0.2, t) * (1.0 - smoothstep(p + 0.05, p + 0.35, t))
		pos += Vector3(ks * 0.03, -0.01, -0.05) * wp
		rot.z += -ks * 0.02 * wp
		# the push: weight forward behind the hand
		var wu := smoothstep(p - 0.05, p + 0.2, t) * (1.0 - smoothstep(p + 0.4, p + 0.9, t))
		pos += Vector3(0.0, -0.01, -0.04) * wu
		if t >= p and not _ds_pushed:
			_ds_pushed = true
			if torch != null: torch.nudge_door(true, _ds_swing)
		done = s * lp.x < -DS_THROUGH or t > p + 4.0
	else:
		var flat := Vector3(global_position.x - knob.x, 0.0, global_position.z - knob.z)
		# keep at arm's length from the knob: step to it if it's far, back off as it comes to you
		if flat.length() > DS_PULL_REACH or t > k:
			goal = Vector3(knob.x, global_position.y, knob.z) + flat.normalized() * DS_PULL_AT
		# in reach with the hand on it: pull (the door times its knock into the frame to the close sound)
		if _ds_k < 0.0 and ((t > 0.35 and flat.length() <= DS_PULL_REACH + 0.05) or t > 1.5):
			_ds_k = t
			k = t
			d.pull()
		var shut: float = k + float(d.CLOSE_TIME)    # it meets the frame
		look = knob if t < k + 0.3 else d.to_global(Vector3(s * 0.2, 1.4, 0.0))
		look_rate = 4.0 if t < k + 0.3 else 2.0
		hand = t > 0.15 and t < shut
		var wr := smoothstep(0.1, 0.35, t) * (1.0 - smoothstep(k, k + 0.3, t))
		pos += Vector3(0.0, -0.03, -0.04) * wr
		rot.z += -ks * 0.02 * wr
		# the pull: weight back, head up a touch
		var wl := smoothstep(k - 0.05, k + 0.25, t) * (1.0 - smoothstep(shut - 0.1, shut + 0.3, t))
		pos += Vector3(0.0, 0.0, 0.04) * wl
		rot += Vector3(0.02, -ks * 0.025, -ks * 0.02) * wl
		# the knock: a small flinch of the head as it shuts
		var wh := smoothstep(shut, shut + 0.04, t) * (1.0 - smoothstep(shut + 0.06, shut + 0.25, t))
		pos += Vector3(0.0, 0.0, 0.012) * wh
		rot.x += 0.01 * wh
		done = (t > shut + 0.35 and not d.blocked) or t > 6.0
	# the body: walk to the goal
	var to := Vector3(goal.x - global_position.x, 0.0, goal.z - global_position.z)
	var wish := to.normalized() * minf(spd, to.length() * 3.5) if to.length() > 0.02 else Vector3.ZERO
	if walk_through:
		wish = walk
	velocity.x = move_toward(velocity.x, wish.x, ACCEL_GROUND * SPEED * dt)
	velocity.z = move_toward(velocity.z, wish.z, ACCEL_GROUND * SPEED * dt)
	if not is_on_floor():
		velocity.y = maxf(velocity.y - GRAVITY * dt, -fall_speed_max)
	move_and_slide()
	# the eyes: the body turns to the look, the head pitches to it
	var to_look := look - cam.global_position
	var yaw_goal := atan2(-to_look.x, -to_look.z)
	var yaw_step := clampf(wrapf(yaw_goal - rotation.y, -PI, PI) * (1.0 - exp(-dt * look_rate)), -DS_TURN * dt, DS_TURN * dt)
	rotate_y(yaw_step)
	var pitch_goal := clampf(atan2(to_look.y, Vector2(to_look.x, to_look.z).length()), -1.1, 0.6)
	var base := cam.rotation.x - pitch_applied
	cam.rotation.x += (pitch_goal - base) * (1.0 - exp(-dt * look_rate))
	_door_cam_pos = pos
	_door_cam_rot = rot
	# the rest of the body as walking would have it
	var moving := wish.length() > 0.25
	is_moving = moving
	is_sprinting = false
	is_crouching = false
	eye = lerpf(eye, STAND_H, minf(1.0, dt * 10.0))
	(shape.shape as CapsuleShape3D).height = eye + 0.1
	shape.position.y = (eye + 0.1) / 2.0
	_update_stamina(dt, false, false)
	peek.update(dt, self, eye, false)
	if torch:
		# the hand's frame is set from where you stand, not from the leaf: the leaf turns through 120 degrees as
		# it swings and a palm laid on its face would wring the wrist round with it. Palm toward the knob from
		# your side, fingers across to your right.
		var face := Vector3(cam.global_position.x - knob.x, 0.0, cam.global_position.z - knob.z)
		face = face.normalized() if face.length() > 0.05 else -global_basis.z
		var across: Vector3 = Vector3.UP.cross(face).normalized()
		torch.set_hug(false, Vector3.ZERO, Vector3.ZERO, false)
		torch.set_squeeze(false, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
		torch.set_grab(hand, -1, knob + face * 0.03, face, across)
		torch.set_peek(0, false, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, 0.0, false, false)
		torch.update(dt, flash_on and not dead, false, moving, bob)
	if shadow_body:
		shadow_body.update(moving, false, false, dead, Vector2(velocity.x, velocity.z).length())
	_update_flashlight(dt)
	_update_sanity(dt)
	_update_head(dt, Vector2(0.0, -1.0) if moving else Vector2.ZERO, false, false, moving)
	if done:
		_end_door_scene()

## Outside the scene the head's door motion eases back out
func _update_door_camera(dt: float) -> void:
	if _door_anim_active:
		return
	_door_cam_pos = _door_cam_pos.lerp(Vector3.ZERO, minf(1.0, dt * 8.0))
	_door_cam_rot = _door_cam_rot.lerp(Vector3.ZERO, minf(1.0, dt * 8.0))

func _near_door() -> bool:
	if focused_door != null:
		return true
	var cp := global_position
	var doors := get_tree().get_nodes_in_group("doors")
	for d in doors:
		if is_instance_valid(d) and d is Node3D:
			var d_pos: Vector3 = (d as Node3D).global_position
			var dist := Vector2(cp.x - d_pos.x, cp.z - d_pos.z).length()
			if dist < 3.2 and absf(cp.y - d_pos.y) < 2.5:
				return true
	return false

var _cached_doors: Array = []
var _door_cache_t := 0.0

func _find_interactable_door() -> Node:
	if dead or frozen or Game.draw_mode or Game.noclip:
		return null
	var cam_pos := cam.global_position
	var cam_fwd := -cam.global_transform.basis.z
	
	# 1. Direct raycast through reticle
	var space := get_world_3d().direct_space_state
	if space != null:
		var ray_end := cam_pos + cam_fwd * 2.8
		var query := PhysicsRayQueryParameters3D.create(cam_pos, ray_end, 1 | 2)
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			var collider: Object = hit.collider
			var d := _get_door_from_node(collider)
			if d != null and d.has_method("can_interact") and d.can_interact(cam_pos):
				return d
				
	# 2. View-cone / proximity query for nearby doors within reach (handles open doorways and side angles)
	var now := Time.get_ticks_msec() * 0.001
	if now - _door_cache_t > 1.0 or _cached_doors.is_empty():
		_door_cache_t = now
		_cached_doors = get_tree().get_nodes_in_group("doors")

	var best_door: Node = null
	var best_dot := 0.62
	for n in _cached_doors:
		if not is_instance_valid(n): continue
		var dpos: Vector3 = (n as Node3D).global_position
		if cam_pos.distance_squared_to(dpos) > 16.0: continue
		if n.has_method("can_interact") and n.can_interact(cam_pos):
			var target_pos: Vector3 = n.get_handle_global_pos() if n.has_method("get_handle_global_pos") else dpos
			var to_door := (target_pos - cam_pos).normalized()
			var dot := cam_fwd.dot(to_door)
			var dist := cam_pos.distance_to(target_pos)
			if dist < 2.6 and dot > best_dot:
				best_dot = dot
				best_door = n
	return best_door

func _get_door_from_node(node: Object) -> Node:
	if node == null:
		return null
	if node.has_method("interact"):
		return node as Node
	if node.has_meta("door"):
		return node.get_meta("door") as Node
	if node is Node:
		var p := (node as Node).get_parent()
		if p != null:
			if p.has_method("interact"): return p
			if p.has_meta("door"): return p.get_meta("door") as Node
			var pp := p.get_parent()
			if pp != null:
				if pp.has_method("interact"): return pp
				if pp.has_meta("door"): return pp.get_meta("door") as Node
	return null

## Both hands flat on the slit's walls (or, crawling, on the floor), fingers on the way through, while you're in it
func _set_squeeze_hands() -> void:
	if torch == null:
		return
	if crawl_k > 0.5 and tight_k < 0.5:
		# crawling: a hand flat on the floor each side, going forward and back in turn with the stride
		var fwd := -global_transform.basis.z
		fwd.y = 0.0
		fwd = fwd.normalized()
		var right := global_transform.basis.x
		right.y = 0.0
		right = right.normalized()
		# A crawl gait, a hand per footfall: each hand is planted on the carpet (it stays put in the world while you
		# move over it), then lifts, reaches forward on an arc and comes down exactly on a footstep (bob = k * PI),
		# the right on one, the left on the next. Where it lands leads you by how far you'll travel while it's
		# down, so it ends its stance about as far behind as it started ahead.
		var dt := get_physics_process_delta_time()
		var floor_at := global_position
		var speed := Vector3(velocity.x, 0.0, velocity.z).length()
		var cycle := TAU / maxf(bob_rate, 0.5)                  # s for both hands (two footfalls)
		var lead := minf(CRAWL_REACH + speed * cycle * (1.0 - CRAWL_SWING_SHARE) * 0.5, CRAWL_LEAD_MAX)
		var hands: Array = []
		for i in 2:                                             # 0 left, 1 right
			var side := 1.0 if i == 1 else -1.0
			var rest := floor_at + fwd * CRAWL_REACH + right * (CRAWL_WIDTH * side)
			var target := floor_at + fwd * lead + right * (CRAWL_WIDTH * side)
			if not _cr_on:
				_cr_plant[i] = rest
				_cr_from[i] = rest
			# the right lands on even footfalls, the left on odd ones
			var ph := fposmod(bob / TAU + CRAWL_SWING_SHARE - (0.0 if i == 1 else 0.5), 1.0)
			var at: Vector3
			if ph < CRAWL_SWING_SHARE:
				if not _cr_swinging[i]:
					_cr_swinging[i] = true
					_cr_from[i] = _cr_plant[i]
				var u := smoothstep(0.0, CRAWL_SWING_SHARE, ph)
				at = (_cr_from[i] as Vector3).lerp(target, u) + Vector3.UP * (CRAWL_LIFT * sin(PI * ph / CRAWL_SWING_SHARE))
				_cr_plant[i] = target
			else:
				_cr_swinging[i] = false
				# stopped (or turned on the spot): a planted hand left far off creeps back under you
				var p: Vector3 = _cr_plant[i]
				var off := p - rest
				if speed < 0.2 or off.length() > CRAWL_REACH * 1.4:
					_cr_plant[i] = p.lerp(rest, minf(1.0, dt * 2.5))
				at = _cr_plant[i]
			hands.append(at)
		_cr_on = true
		torch.set_squeeze(true, hands[1], Vector3.UP, hands[0], Vector3.UP, fwd)
		return
	_cr_on = false
	if tight_k < 0.5 or _sq.is_empty():
		torch.set_squeeze(false, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO)
		return
	var xf: Transform3D = Game.level.object_transform(_sq.o)
	var gap: float = _sq.gap
	var along := signf((-global_transform.basis.z).dot(xf.basis.x))
	if along == 0.0:
		along = 1.0
	var half: float = Game.level.CELL * 0.5 - 0.1
	var here: float = (_sq.local as Vector3).x
	# The hands ride along the walls with you, a little ahead (the right a touch further than the left), drifting
	# slowly up and down and fore and aft so they never sit dead still; every so often one comes up off the wall
	# and is put back a bit higher or lower (_sq_raise, timed in _update_squeeze).
	var ly := global_position.y - xf.origin.y + eye - 0.2
	var hands := {}
	for z: float in [-1.0, 1.0]:
		var p0: Vector3 = xf * Vector3(0.0, 0.0, z * gap * 0.5)
		var side := 1 if (p0 - global_position).dot(global_transform.basis.x) > 0.0 else 0
		var ph := _sq_clock * (0.8 if side == 1 else 0.67) + side * 2.1
		var lx := clampf(here + along * (SQ_AHEAD[side] + sin(ph) * SQ_WANDER.x), -half, half)
		var lift := sin(PI * clampf(_sq_raise_t[side] / SQ_RAISE_TIME, 0.0, 1.0)) if _sq_raise_t[side] >= 0.0 else 0.0
		var y := ly + sin(ph * 1.3 + 0.8) * SQ_WANDER.y + _sq_raise_dy[side] + SQ_LIFT_UP * lift
		var n: Vector3 = -xf.basis.z.normalized() * z
		var p: Vector3 = xf * Vector3(lx, y, z * gap * 0.5) + n * (SQ_LIFT_OUT * lift)
		hands[side] = [p, n]
	if not (hands.has(0) and hands.has(1)):
		return
	torch.set_squeeze(true, hands[1][0], hands[1][1], hands[0][0], hands[0][1], xf.basis.x.normalized() * along)

## Walking forward along a wall that ends just ahead: the hand on that side reaches out, takes hold of the
## corner, and the grip draws you round it with a burst of speed. Every corner, with a cooldown.
func _update_corner(dt: float, sprint: bool, crouch: bool) -> void:
	_corner_cd = maxf(0.0, _corner_cd - dt)
	_corner_boost = maxf(0.0, _corner_boost - dt / CORNER_FADE)
	var fwd := -global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		_corner_on = false
		return
	fwd = fwd.normalized()
	var free := is_on_floor() and not crouch and not dead and peek.side == 0 and not peek.hug
	if _corner_on:
		_corner_t += dt
		var eye_at := global_position + Vector3.UP * eye
		var passed := (corner.point - eye_at).dot(fwd) < 0.15            # the corner is beside you: let go
		if _corner_t >= CORNER_TIME or passed or not free:
			_corner_on = false
		return
	var v := Vector3(velocity.x, 0.0, velocity.z)
	if _corner_cd > 0.0 or sprint or not free or _swinging or v.length() < CORNER_SPEED_MIN or v.normalized().dot(fwd) < 0.8:
		return
	if corner.scan(self, eye, fwd):
		_corner_on = true
		_corner_t = 0.0
		_corner_cd = CORNER_COOLDOWN
		_corner_boost = 1.0
		land_dip = maxf(land_dip, 0.025)       # a little dip as the weight goes onto the hand

## Walking, an edge in reach and you're already heading out round it: the hand takes hold, and the grab
## pulls you round it with a push and a short burst of speed. Once per corner (cooldown).
func _update_swing(dt: float, crouch: bool) -> void:
	_swing_cd = maxf(0.0, _swing_cd - dt)
	_swing_boost = maxf(0.0, _swing_boost - dt / SWING_FADE)
	var v := Vector3(velocity.x, 0.0, velocity.z)
	var ok := peek.leaning and peek.side != 0 and peek.amount > 0.5 and is_on_floor() and not crouch \
		and peek.dist <= 1.15 and v.length() >= SWING_MIN_SPEED and v.dot(peek.out) >= SWING_SIDE_SPEED
	if ok and not _swinging and _swing_cd <= 0.0:
		_swinging = true
		_swing_cd = SWING_COOLDOWN
		_swing_boost = 1.0
		velocity += peek.out * SWING_KICK + v.normalized() * (SWING_KICK * 0.4)
	elif _swinging and (not ok or _swing_cd < SWING_COOLDOWN - 0.5):
		_swinging = false           # the hand keeps hold for half a second, then lets go

## Immediate partial alignment during rapid mouse motion to prevent TAA flashlight ghosting
func _sync_flashlight_aim(factor: float) -> void:
	if not is_instance_valid(flash) or not flash.visible:
		return
	var lens := cam.global_position
	if torch != null and torch.visible:
		lens = torch.lens()
	var where := _lens_clear_of_walls(cam.global_position, lens)
	beam_pos = beam_pos.lerp(where, factor)
	flash.global_position = beam_pos
	var fwd := -cam.global_transform.basis.z * 16.0
	var tilt := 0.0 if (Game.hide_hud or Game.hide_hands) else beam_tilt
	var want := beam_pos + fwd.rotated(cam.global_transform.basis.x, -tilt)
	flash_target = flash_target.lerp(want, factor)
	if flash_target.distance_to(beam_pos) > 0.01:
		flash.look_at(flash_target, Vector3.UP)

## Dynamic velocity rejection tuning for flashlight beam:
## Dynamically scales tracking rate with angular look delta. When turning rapidly, tracking ramps up
## to 85.0/s to eliminate the multi-frame lag that creates temporal ghost trails, while easing down
## to smooth organic 24.0/s during subtle breathing movement.
func _update_flashlight_aim(dt: float) -> void:
	if not is_instance_valid(flash) or not flash.visible:
		return
	var dip_target := 0.0
	if torch != null and not (Game.hide_hud or Game.hide_hands):
		dip_target = torch.lower * 0.28 + (1.0 - torch.raise) * 0.5
	var tilt_target := 0.0 if (Game.hide_hud or Game.hide_hands) else clampf(dip_target, 0.0, BEAM_TILT_MAX)
	beam_tilt = lerpf(beam_tilt, tilt_target, minf(1.0, 8.0 * dt))
	var lens := cam.global_position
	if torch != null and torch.visible:
		lens = torch.lens()
	var where := _lens_clear_of_walls(cam.global_position, lens)
	var pos_rate := lerpf(30.0, 95.0, clampf(beam_pos.distance_to(where) * 4.0, 0.0, 1.0))
	beam_pos = where if beam_pos.distance_to(where) > 2.0 else beam_pos.lerp(where, minf(1.0, pos_rate * dt))
	flash.global_position = beam_pos
	var fwd := -cam.global_transform.basis.z * 16.0
	var current_tilt := 0.0 if (Game.hide_hud or Game.hide_hands) else beam_tilt
	var want := beam_pos + fwd.rotated(cam.global_transform.basis.x, -current_tilt)
	var look_delta := (want - flash_target).length()
	var track_rate := lerpf(24.0, 85.0, clampf(look_delta * 3.0, 0.0, 1.0))
	flash_target = flash_target.lerp(want, minf(1.0, track_rate * dt))
	if flash_target.distance_to(beam_pos) > 0.01:
		flash.look_at(flash_target, Vector3.UP)

# The lens hangs ~0.4 m in front of your eye, so pressed up against a wall it sits inside the geometry
# and the beam vanishes with it. Only level walls count: a creature passing between your eye and the
# torch must not move your light.
func _lens_clear_of_walls(from: Vector3, lens: Vector3) -> Vector3:
	if from.distance_to(lens) < 0.01:
		return lens
	var space := get_world_3d().direct_space_state
	if space == null:
		return lens
	var q := PhysicsRayQueryParameters3D.create(from, lens)
	q.exclude = [get_rid()]
	for i in 3:
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			return lens
		if hit.collider is StaticBody3D:
			return from
		q.exclude.append(hit.rid)                       # a body in the way is not a wall: look past it
	return lens

## Load a battery pack worth `charge` % (hud.gd, R). The hands change the cells (torch_model.gd swap()):
## the light is out while the cap is off, and the charge goes in when it's back on. Without the arms it
## just goes in.
func swap_battery(charge: float) -> void:
	swap_charge += charge
	if torch == null or not torch.swap():
		battery_swap.emit()
		_swap_done()

func swapping() -> bool:
	return torch != null and torch.swapping()

func _swap_done() -> void:
	battery = minf(100.0, battery + swap_charge)
	swap_charge = 0.0

## The torch stutters for `secs` seconds (an event, or something big coming close)
func trigger_flicker(secs: float) -> void:
	flash_flicker.timer = 0.0
	flash_flicker.active = true
	flash_flicker.step = 0.0
	flicker_left = maxf(flicker_left, secs)
	if torch: torch.smack()

# Loose contact: long steady stretches, then a burst of dropouts
func _contact_flicker(dt: float) -> float:
	var fl := flash_flicker
	fl.timer -= dt
	if fl.timer > 0.0: return 1.0
	if not fl.active:
		fl.active = true
		fl.step = 0.0
		if torch: torch.smack()                         # a loose contact: knock it
	fl.step -= dt
	if fl.step <= 0.0:
		fl.step = 0.03 + randf() * 0.05
		var cut := randf() < 0.4
		fl.value = 0.03 if cut else 0.2 + randf() * 0.8
		var forced := flicker_left > 0.0
		if forced: flicker_left -= fl.step
		if (forced and flicker_left <= 0.0) or (not forced and randf() < 0.08):
			flicker_left = 0.0
			fl.active = false
			fl.value = 1.0
			fl.timer = 9.0 + randf() * 18.0
	return fl.value

# ---- sanity: darkness drains it, safe light restores it (web SANITY values) ----
# Light is what keeps you sane. Ambient light (the tubes) restores it as before. The torch is a light
# of your own: with it on you never lose sanity to the dark, and it slowly restores it. With NO light at
# all (dark area, torch off or dead) sanity drains, and the longer you stay in it the faster it goes.
func _update_sanity(dt: float) -> void:
	if Game.infinite_sanity:
		sanity = 100.0
		sanity_lock = 100.0
		insanity = 0.0
		dark_time = 0.0
		_update_mind(dt)
		return
	var ambient := ambient_light()
	var torch_lit := (flash_on and battery > 0.0 and not swap_dark) or _head_k > 0.5
	light_level = lerpf(light_level, ambient, minf(1.0, dt * 3.0))
	unnerved = maxf(0.0, unnerved - dt)
	if sanity_lock >= 0.0:
		sanity = sanity_lock                      # debug console: `sanity <n>` pins it
	elif unnerved > 0.0:
		pass                                      # no calming down while you stare at them (they drain it)
	elif light_level >= 0.45:
		var rec := minf(1.0, (light_level - 0.45) / 0.55)
		sanity = minf(100.0, sanity + 2.2 * (0.4 + 0.6 * rec) * dt)
		dark_time = 0.0
	elif torch_lit:
		# your own light: steadies you even in the dark, a little slower than a properly lit room
		sanity = minf(100.0, sanity + 1.4 * dt)
		dark_time = maxf(0.0, dark_time - dt * 3.0)
	elif light_level < 0.3:
		var dark_ratio := 1.0 - light_level / 0.3
		dark_time += dt
		var creep := 1.0 + minf(dark_time / 20.0, 1.0)         # doubles over the first 20 s of it
		sanity = maxf(0.0, sanity - (1.0 + dark_ratio * 4.5) * creep * (1.4 if grid_down else 1.0) * dt)
	else:
		dark_time = maxf(0.0, dark_time - dt)                  # dim but not black: neither gain nor loss
	# a Drain zone (painted in the level editor): the place itself wears you down, lit or not, torch or not
	if sanity_lock < 0.0 and level != null:
		var zone = level.get("drain")
		if zone is Dictionary and zone.has(Vector2i(roundi(global_position.x / 4.5), roundi(global_position.z / 4.5))):
			sanity = maxf(0.0, sanity - DRAIN_ZONE_RATE * dt)
	_update_mind(dt)

# A slipping mind hurts. Below HURT_SANITY the body starts to fail (faster the lower it goes), the
# picture smears and doubles (insanity, read by the post shader) and the heart runs. Recovering
# sanity stops the bleed, and health then creeps back once you are properly calm again.
func _update_mind(dt: float) -> void:
	var target := clampf((INSANE_BELOW - sanity) / INSANE_BELOW, 0.0, 1.0)
	insanity += (target - insanity) * minf(1.0, dt * 1.5)
	if Game.god_mode:
		health = 100.0
		return
	if sanity < HURT_SANITY:
		var sev := 1.0 - sanity / HURT_SANITY
		health = maxf(0.0, health - (0.6 + 3.0 * sev * sev) * dt)
		hurt_tick -= dt
		if hurt_tick <= 0.0:            # a throb of pain with the drain
			hurt_tick = 2.2 - 1.4 * sev
			Game.add_glitch(0.12 + 0.25 * sev)
			Game.beat()
		if Game.heart != null:
			Game.heart.feed("mind", 0.25 + 0.5 * sev)
		if health <= 0.0 and not dead and not frozen:
			Game.kill_player("PSYCHOLOGICAL COLLAPSE")
	elif sanity > CALM_SANITY and health < 100.0:
		health = minf(100.0, health + 0.8 * dt)

## Player gasps in fright (e.g. when seized or startled by an entity)
func gasp() -> void:
	var sc: Node = get_parent().get_node_or_null("Scares")
	if sc != null:
		sc.gasp()

func set_fullbright(on: bool) -> void:
	Game.fullbright = on
	if is_instance_valid(fullbright_light):
		fullbright_light.visible = on
	var we := get_parent().get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we and we.environment:
		var env := we.environment
		if on:
			if not env.has_meta("orig_ambient_energy"):
				env.set_meta("orig_ambient_energy", env.ambient_light_energy)
				env.set_meta("orig_ambient_color", env.ambient_light_color)
				env.set_meta("orig_fog", env.fog_enabled)
				env.set_meta("orig_vol_fog", env.volumetric_fog_enabled)
			env.ambient_light_energy = 2.2
			env.ambient_light_color = Color.WHITE
			env.fog_enabled = false
			env.volumetric_fog_enabled = false
		else:
			if env.has_meta("orig_ambient_energy"):
				env.ambient_light_energy = float(env.get_meta("orig_ambient_energy"))
				env.ambient_light_color = env.get_meta("orig_ambient_color")
				env.fog_enabled = bool(env.get_meta("orig_fog"))
				env.volumetric_fog_enabled = bool(env.get_meta("orig_vol_fog"))
