extends CharacterBody3D
## Player state: the constants, signals and fields shared by every part of the controller. Behaviour is
## layered on top, each file extending the one before: player_view.gd (head, stamina, flashlight, sanity),
## player_doors.gd (the door scene), player_squeeze.gd (slits, crawling, wall hands), player.gd (input and movement).

const Footsteps := preload("res://scripts/Player/footsteps.gd")
const TorchModel := preload("res://scripts/Player/torch_model.gd")
const Blink := preload("res://scripts/Player/blink.gd")
const PlayerShadow := preload("res://scripts/Player/player_shadow.gd")
const Handheld := preload("res://scripts/Player/handheld.gd")
const Peek := preload("res://scripts/Player/peek.gd")
const CameraGait := preload("res://scripts/Player/camera_gait.gd")
const CornerGrab := preload("res://scripts/Player/corner_grab.gd")
const WallHand := preload("res://scripts/Player/wall_hand.gd")

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
var cam_variation := true        # on = the bob's carry style and each step vary (camera_gait.gd); off = the same bob every step

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
var gait_cam := CameraGait.new() # the walking bob's carry style and per-step variation (camera_gait.gd)
## Roll / pitch with strafing, turning, speed and jumps, the landing nod, idle sway and trauma shake, each
## with its own multiplier to tune here (camera_feel.gd)
@export var camera_feel := CameraFeel.new()
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
var held_by_event := false    # frozen by an event, not an entity (events.gd look-together): you flinch, the hands stay
var _event_flinched := false
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
var stair_tread := 0.0           # m: the riser of the flight underfoot (0 = none that says), and where its first tread sits
var stair_tread_base := 0.0
var stair_snap := 0.0            # eased m: the view's catch-up to the tread underfoot, so each step lands as a distinct step
var step_ease := 0.0             # m the view still trails the body by after stepping up or down a real step (_step_up)
var stair_hold := 0.0            # s left of counting as on a flight after the last frame the slope was felt (the contact flickers)
var breath := 0.0
var click_player: AudioStreamPlayer
var click_on: AudioStream = load("res://audio/items/torch/on.mp3")
var click_off: AudioStream = load("res://audio/items/torch/off.mp3")

# --- Door interaction & camera animation ---
var focused_door: Node = null
var hidden := false              # climbed into a hiding place (props/hide_spot.gd): THE TALL ONE cannot see you (tall_one.gd _player_hidden)
var hiding_in: Node3D = null     # ...which one (its hide_spot.gd), so it can come to the door if it saw you get in
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
var _ds_way: Dictionary = {}      # how this one is opened (one of DS_WAYS)
var _ds_grip := 0                 # the handle (WallHand.Grip)
var _ds_latched := true           # shut on its latch: the handle has to be turned (else a push is enough)
var _ds_look := Vector3.ZERO      # world: the point the eyes are on, gliding after each beat's
var _ds_look_ok := false
var _ds_z := 0.0                  # door-local z you stand at to open it: the handle a little to your left
var _door_cam_pos := Vector3.ZERO
var _door_cam_rot := Vector3.ZERO
var space_prev := false
var jump_buffer := 0.0
var coyote := 0.0
var land_dip := 0.0
var quake_amt := 0.0          # 0..1: something heavy walking nearby shaking the floor (and the view)
var quake_t := 0.0
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
var pitch_accum := 0.0        # mouse pitch since the last physics tick (rad)
# How far the view tips down (rad, ~66°): your own legs (player_shadow.gd) fill the bottom of the
# view, and past this you'd stare down into the cut where the body ends. Up stays the old 1.49.
const LOOK_DOWN_MAX := 1.4
const LOOK_UP_MAX := 1.49
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
