extends Node
## The camcorder raised to your eye. Hold E (the "camera" action) to look through it; the mouse wheel
## zooms, so you can read a far wall, a sign or what is standing at the end of a hall before you walk
## down it. Built by hud.gd; zoom_readout.gd draws the viewfinder and the lens grade off the values below.
##
## What it does, like a real camcorder:
## - a motorised zoom: the wheel sets a goal, the lens runs to it at a steady ZOOM_RATE stops a second
## - autofocus that hunts: the subject's range is measured under the crosshair and the lens chases it at a
##   limited speed, so a quick zoom or a new subject goes soft, then snaps sharp. The longer the lens the
##   shallower the focus, so the same error blurs more. `blur` (a mip level) is how soft the picture is
## - the field of view narrows (player.gd lens_zoom), the aim slows with it, the handheld shake shows more
##   (player.gd, stronger standing than it would be), and the torch hand drops out of the picture
## Nothing is spent: it is your own camcorder.

const ZoomSounds := preload("res://scripts/Player/zoom_sounds.gd")

const ZOOM_MAX := 8.0
const ZOOM_START := 2.0          # what the first raise gives
const ZOOM_STEP := 1.3           # x per wheel notch
const ZOOM_RATE := 1.6           # stops (doublings) per second the motor can run
const RAISE_TIME := 0.3          # s to bring the camcorder up to your eye
const RANGE := 80.0              # m the autofocus can measure
const AF_RATE := 1.5             # stops of focus distance per second the lens can chase
const MACRO := 0.7               # m: closer than this it cannot focus at all
const ANOMALY_RANGE := 60.0      # m an entity can still disturb the picture from
const FOCUS_MASK := 0xFFFFFFFF   # the level and whatever stands in it: the lens focuses on anything solid

var player: Node                 # player.gd (set by hud.gd)
var scanner: Node                # scanner.gd: in use, the camcorder stays down
var tape: Node                   # tape_tool.gd: same while a strip is pulled or peeled
var _ok := false                 # the player has a lens to drive (player.gd, not the outdoor body)

var holding := false             # the key is down and the camcorder can come up
var up := 0.0                    # 0..1 eased raise (player.lens_up)
var goal := ZOOM_START           # the zoom the wheel asked for
var zoom := ZOOM_START           # the zoom the motor has reached
var motor := 0.0                 # 0..1 how hard the zoom motor is running
var subject := RANGE             # m: range measured under the crosshair
var focus := RANGE               # m: where the lens is focused now
var blur := 0.0                  # mip level of softness: 0 sharp
var lock := 1.0                  # 0..1 how well in focus
var lens_pos := Vector3.ZERO     # where the crosshair ray ends (for the readout)
var anomaly := 0.0               # 0..1 eased: an entity in the lens. The picture tears and corrupts (cam_zoom.gdshader)
var _click_on: AudioStream = load("res://audio/flash_click_on.wav")
var _click_off: AudioStream = load("res://audio/flash_click_off.wav")
var _click: AudioStreamPlayer
var _whirr: AudioStreamPlayer    # the zoom motor: a looped servo, louder and higher the harder it runs
var _sfx: AudioStreamPlayer      # the one-shots: motor tick, end stop, autofocus chirp
var _dir := 0.0                  # eased +1 zooming in, -1 out: the motor's pitch follows it
var _running := false            # the zoom motor is driving the lens
var _focused := true             # the autofocus had a lock (it chirps as it loses and as it finds one)
var _t := 0.0
static var _sounds := {}         # built once: ZoomSounds streams

func _ready() -> void:
	_ok = player != null and "lens_up" in player
	if _sounds.is_empty():
		_sounds = {"motor": ZoomSounds.motor(), "tick": ZoomSounds.tick(), "clunk": ZoomSounds.clunk(), "chirp": ZoomSounds.chirp()}
	_click = AudioStreamPlayer.new()
	_click.bus = "World"
	_click.volume_db = -20.0
	add_child(_click)
	_whirr = AudioStreamPlayer.new()
	_whirr.stream = _sounds.motor
	_whirr.bus = "World"
	_whirr.volume_db = -60.0
	add_child(_whirr)
	_sfx = AudioStreamPlayer.new()
	_sfx.bus = "World"
	add_child(_sfx)

## Whether the camcorder can be in your hands at all: in play, mouse captured, not typing into a field.
## Outdoors the player is another body (hills_player.gd) with no lens, so nothing happens there.
func _can() -> bool:
	return _ok and Game.playing and not Game.dead and not player.dead and not player.frozen \
		and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
		and not (get_viewport().gui_get_focus_owner() is LineEdit)

## Whether you want it up right now: the key, and nothing that needs your hands or your legs. Sprinting,
## a long fall, or the scanner / hazard tape in use lower it (they cannot be started while it is up either:
## scanner.gd, tape_tool.gd and the rest check player.lens_up).
func _wanted() -> bool:
	if not Input.is_action_pressed("camera"):
		return false
	if player.is_sprinting or player.fall_fx > 0.05 or Game.freefall:
		return false
	if scanner != null and scanner.holding:
		return false
	if tape != null and (tape.pulling or tape.peeling):
		return false
	return true

func _exit_tree() -> void:
	# the HUD goes with the level: leave the player with a plain lens, not stuck zoomed
	if _ok and is_instance_valid(player):
		player.lens_up = 0.0
		player.lens_zoom = 1.0
		if is_instance_valid(player.cam):
			player.cam.fov = player.fov_flat

## The magnification in the picture right now: the zoom the motor has reached, eased in with the raise
func magnification() -> float:
	return pow(zoom, smoothstep(0.0, 1.0, up))

func _unhandled_input(e: InputEvent) -> void:
	var mb := e as InputEventMouseButton
	if mb == null or not mb.pressed or not holding:
		return
	if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		goal = minf(ZOOM_MAX, goal * ZOOM_STEP)
	elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		goal = maxf(1.0, goal / ZOOM_STEP)
	else:
		return
	get_viewport().set_input_as_handled()

func _process(dt: float) -> void:
	if not _ok:
		return
	var can := _can()
	var was_up := up > 0.0
	holding = can and _wanted()
	if can:
		up = move_toward(up, 1.0 if holding else 0.0, dt / RAISE_TIME)
	else:
		up = 0.0                         # a grab, a death, the pause menu: it is out of your hands at once
	if holding and not was_up:
		_click.stream = _click_on
		_click.play()
	elif was_up and up <= 0.0 and can:
		_click.stream = _click_off
		_click.play()
	# the zoom motor: a steady run in stops, whatever the distance
	var from := log(zoom)
	var to := log(goal)
	zoom = exp(move_toward(from, to, ZOOM_RATE * 0.693147 * dt))
	motor = move_toward(motor, 1.0 if absf(to - from) > 0.001 and up > 0.5 else 0.0, dt * 6.0)
	_update_whirr(dt, signf(to - from))
	if up <= 0.0:
		_apply(0.0)
		blur = 0.0
		lock = 1.0
		anomaly = 0.0
		return
	_autofocus(dt)
	_update_anomaly(dt)
	_apply(up)

## Something that should not be there, seen through the lens. The nearer to the middle of the picture an
## entity is, the more magnified the view and the closer it stands, the more the tape misbehaves; a
## wide view of one far off barely registers. Only entities count (props in the scannable group give a
## scan_range()), and only ones in plain sight.
func _update_anomaly(dt: float) -> void:
	var cam: Camera3D = player.cam
	var from := cam.global_position
	var fwd := -cam.global_transform.basis.z
	var half := deg_to_rad(cam.fov) * 0.5
	var best := 0.0
	var best_pt := Vector3.ZERO
	for n in get_tree().get_nodes_in_group(Archive.SCANNABLE):
		if not n.has_method("scan_points") or n.has_method("scan_range"):
			continue
		for p in n.scan_points():
			var d: Vector3 = p - from
			var dist := d.length()
			if dist < 0.5 or dist > ANOMALY_RANGE:
				continue
			var ang := acos(clampf(fwd.dot(d / dist), -1.0, 1.0))
			var centred := 1.0 - smoothstep(0.35, 0.95, ang / half)    # on the crosshair, not the rim
			var s := centred * (1.0 - 0.55 * dist / ANOMALY_RANGE)
			if s > best:
				best = s
				best_pt = p
	var want := 0.0
	if best > 0.02:
		var q := PhysicsRayQueryParameters3D.create(from, best_pt, 1)
		q.exclude = [player.get_rid()]
		var hit: Dictionary = player.get_world_3d().direct_space_state.intersect_ray(q)
		if hit.is_empty() or from.distance_to(hit.position) > from.distance_to(best_pt) - 1.0:
			# a wide view barely shows it, a long lens shows it all
			want = best * (0.25 + 0.75 * smoothstep(1.0, 4.0, magnification()))
	anomaly = move_toward(anomaly, want, dt * (1.1 if want > anomaly else 0.6))

## The motor's sound follows `motor` (it spins up and winds down over about a sixth of a second). The servo
## runs higher going in than out, climbs with its speed and wavers a little, like a small motor under load.
## It catches with a tick as it starts and runs home with a clunk as it stops, a heavier one at either end
## of the lens.
func _update_whirr(dt: float, dir: float) -> void:
	_t += dt
	if dir != 0.0:
		_dir = move_toward(_dir, dir, dt * 8.0)
	var running := motor > 0.5 and dir != 0.0
	if running and not _running:
		_blip("tick", -30.0, 1.0)
	elif _running and not running and motor > 0.2:
		var end := zoom <= 1.001 or zoom >= ZOOM_MAX - 0.001
		_blip("clunk", -21.0 if end else -32.0, 1.0 if end else 1.25)
	_running = running
	if motor > 0.01:
		if not _whirr.playing:
			_whirr.play()
		var wobble := 1.0 + 0.010 * sin(_t * 31.0) + 0.006 * sin(_t * 53.0 + 1.0)
		_whirr.volume_db = lerpf(-58.0, -32.0, sqrt(motor))
		_whirr.pitch_scale = (0.78 + 0.24 * motor) * (1.0 + 0.10 * _dir) * wobble
	elif _whirr.playing:
		_whirr.stop()

func _blip(sound: String, db: float, pitch: float) -> void:
	_sfx.stream = _sounds[sound]
	_sfx.volume_db = db
	_sfx.pitch_scale = pitch * randf_range(0.97, 1.03)
	_sfx.play()

func _apply(raise: float) -> void:
	player.lens_up = smoothstep(0.0, 1.0, raise)
	player.lens_zoom = magnification() if raise > 0.0 else 1.0

## Range the subject under the crosshair and run the lens after it. Focus is chased in stops of distance, at
## a limited rate: a sudden change goes soft first. The defocus is the error in 1/distance (what a lens
## really cares about), and a longer lens has less depth of field.
func _autofocus(dt: float) -> void:
	var cam: Camera3D = player.cam
	var from := cam.global_position
	var q := PhysicsRayQueryParameters3D.create(from, from - cam.global_transform.basis.z * RANGE, FOCUS_MASK)
	q.exclude = [player.get_rid()]
	var hit: Dictionary = player.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		subject = RANGE
		lens_pos = from - cam.global_transform.basis.z * RANGE
	else:
		subject = maxf(from.distance_to(hit.position), MACRO)
		lens_pos = hit.position
	focus = exp(move_toward(log(focus), log(subject), AF_RATE * 0.693147 * dt))
	var err := absf(1.0 / focus - 1.0 / subject)
	var depth := 0.5 + 0.35 * magnification()           # shallower the longer the lens
	var want := clampf(err * depth * 4.0, 0.0, 3.5) + motor * 0.9
	if not hit.is_empty() and from.distance_to(hit.position) < MACRO:
		want = 3.0                                       # too close to focus on
	blur = lerpf(blur, want, minf(1.0, dt * 14.0))
	lock = 1.0 - clampf(blur / 1.2, 0.0, 1.0)
	# the focus motor buzzes as it goes to work and once more as it finds the subject
	if _focused and lock < 0.45 and motor < 0.05:
		_focused = false
		_blip("chirp", -36.0, 0.95)
	elif not _focused and lock > 0.85:
		_focused = true
		_blip("chirp", -40.0, 1.15)
