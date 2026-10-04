extends Node
## Coming to after a Noclip fall (pit_fall.gd, noclip_slip.gd): the new level has been built behind the black, and
## you wake up in it. Started at the landing, added to the scene root so it outlives the level rebuild. Holds the
## camera itself (process_priority after the player, as burnt.gd does while it holds you). No sound but your own
## breathing, soft:
##   eyes        they open a crack and fall shut, three times, each time a little longer open; blurred, grey
##   on your back you are lying on the carpet looking up at the ceiling tiles and the tubes, chest rising and falling
##   sitting up  you push up to sitting, head heavy, and look along the floor
##   standing    you get up, unsteady, and the view settles into your own; the controls come back
## Hardly any roll: the HUD's vitals tilt with the camera's roll (vitals_panel.gd).

const SETTLE := 0.8            # s of black after the level is built, before the eyes first open
const LIE := 5.0               # s on your back
const SIT := 2.6               # sitting up
const STAND := 2.2             # getting to your feet
const FLOOR_Y := 0.2           # eye height lying down
const SIT_Y := 0.95
const LOOK_UP := 1.3           # radians of pitch: looking straight up from the floor (just short of it)

var _pl                        # player.gd (cam, frozen, dead...)
var _t := -1.0                 # -1 while waiting for the level to finish building
var _wait := 0.0
var _breaths: Array = [1.4, 3.6, 5.8, 8.2]      # s: when you breathe out, softly
var _side := 1.0                                # which way your head lolls / you look as you sit up

func _ready() -> void:
	process_priority = 100
	_pl = Game.player
	if _pl == null or not is_instance_valid(_pl):
		queue_free()
		return
	_side = 1.0 if randf() < 0.5 else -1.0
	_pl.frozen = true
	_pl.velocity = Vector3.ZERO
	_black(1.0)

func _black(a: float) -> void:
	if Gfx.post_mat:
		Gfx.post_mat.set_shader_parameter("fall_fade", clampf(a, 0.0, 1.0))

## A soft breath out, through the player's own breathing (Audio/breathing.gd)
func _breathe(strength: float) -> void:
	var au: Node = Game.main.get_node_or_null("Audio") if Game.main != null and is_instance_valid(Game.main) else null
	var br = au.get("breathing") if au != null else null
	if br != null and br.has_method("sigh"):
		br.sigh(strength)

func _process(dt: float) -> void:
	if _pl == null or not is_instance_valid(_pl) or _pl.dead:
		_finish()
		return
	var cam: Camera3D = _pl.cam
	# the player's own view this frame, looking level: where the wake-up ends up. (Its height, sway and roll the
	# player sets fresh each frame; its pitch builds on the last frame's, which is ours, so it is left out.)
	var stand: Transform3D = _pl.global_transform * Transform3D(Basis.from_euler(Vector3(0.0, cam.rotation.y, cam.rotation.z)), cam.position)
	_pl.frozen = true
	_pl.velocity = Vector3.ZERO
	if _t < 0.0:
		# behind the black: the level is still being built, then a moment more
		_black(1.0)
		var lv: Node = Game.level
		if lv != null and lv.get("rebuilding") == true:
			_wait = 0.0
			return
		_wait += dt
		if _wait < SETTLE: return
		_t = 0.0
	_t += dt
	var t := _t
	# --- the eyes: open a crack, shut, open longer, shut, then open for good (black = 1 is shut)
	var lid := 1.0
	if t < 0.6: lid = 1.0
	elif t < 1.5: lid = 1.0 - 0.4 * sin((t - 0.6) / 0.9 * PI)
	elif t < 2.1: lid = 1.0
	elif t < 3.6: lid = 1.0 - 0.75 * sin((t - 2.1) / 1.5 * PI)
	elif t < 4.0: lid = 1.0
	else: lid = maxf(0.0, 1.0 - (t - 4.0) / 1.3)
	_black(lid)
	var wake := clampf((t - 4.0) / (LIE + SIT + STAND - 4.0), 0.0, 1.0)
	Game.fx_blur = 0.5 * (1.0 - wake)
	Game.fx_sat = lerpf(0.4, 1.0, wake)
	while not _breaths.is_empty() and t >= float(_breaths[0]):
		_breaths.pop_front()
		_breathe(0.28)
	# --- the body: on your back looking up, then sitting, then up
	var base: Vector3 = _pl.global_position
	var yaw: float = _pl.rotation.y
	var h := FLOOR_Y
	var pitch := LOOK_UP + 0.025 * sin(t * 1.6)                  # chest rising and falling under you
	var turn := 0.12 * _side * smoothstep(1.5, 4.0, t)           # your head rolled a little to one side
	var roll := 0.0
	if t >= LIE and t < LIE + SIT:
		var k := smoothstep(0.0, 1.0, (t - LIE) / SIT)
		h = lerpf(FLOOR_Y, SIT_Y, k)
		pitch = lerpf(LOOK_UP, -0.35, k)                         # up off the floor, head hanging forward
		turn = lerpf(0.12 * _side, 0.35 * _side, k)              # looking along the floor, to one side
		roll = 0.06 * _side * sin(k * PI)
	elif t >= LIE + SIT:
		var k := smoothstep(0.0, 1.0, (t - LIE - SIT) / STAND)
		h = SIT_Y
		pitch = -0.35 * (1.0 - k)
		turn = 0.35 * _side * (1.0 - k)
		roll = 0.03 * sin(t * 2.4) * (1.0 - k)                   # unsteady on your feet
	var basis := Basis(Vector3.UP, yaw + turn) * Basis(Vector3.RIGHT, pitch) * Basis(Vector3.BACK, roll)
	var lying := Transform3D(basis, base + Vector3.UP * h)
	var to_stand := smoothstep(LIE + SIT, LIE + SIT + STAND, t)
	cam.global_transform = lying.interpolate_with(stand, to_stand)
	if t >= LIE + SIT + STAND:
		_finish()

func _finish() -> void:
	if _pl != null and is_instance_valid(_pl):
		_pl.frozen = false
		(_pl.cam as Camera3D).rotation.x = 0.0          # level, as the wake-up left it
	_black(0.0)
	Game.fx_blur = 0.0
	Game.fx_sat = 1.0
	queue_free()
