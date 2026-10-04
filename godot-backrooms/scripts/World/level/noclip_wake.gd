extends Node
## Coming to after a Noclip fall (pit_fall.gd): the new level has been built behind the black, and you wake up
## in it. Started by pit_fall.gd once you have hit the ground, added to the scene root so it outlives the level
## rebuild. Holds the camera itself (process_priority after the player, as burnt.gd does while it holds you):
##   black       the thud has just happened; nothing, a ringing, your heart
##   eyes        they open and fall shut again, three times, each time a little longer open; blurred, grey
##   on the floor you are lying on your side on the carpet, the room on its side, breathing hard
##   sitting up  you roll onto your back, push up to sitting, look round
##   standing    you get up, unsteady, and the view settles into your own; the controls come back

const SETTLE := 0.8            # s of black after the level is built, before the eyes first open
const LIE := 4.6               # s on the floor
const SIT := 2.4               # rolling up to sitting
const STAND := 2.2             # getting to your feet
const FLOOR_Y := 0.22          # eye height lying down
const SIT_Y := 0.95

var _pl                        # player.gd (cam, frozen, dead...)
var _level: Node
var _t := -1.0                 # -1 while waiting for the level to finish building
var _wait := 0.0
var _sounded := {}

func _ready() -> void:
	process_priority = 100
	_pl = Game.player
	_level = Game.level
	if _pl == null or not is_instance_valid(_pl):
		queue_free()
		return
	_pl.frozen = true
	_pl.velocity = Vector3.ZERO
	_black(1.0)

func _black(a: float) -> void:
	if Gfx.post_mat:
		Gfx.post_mat.set_shader_parameter("fall_fade", clampf(a, 0.0, 1.0))

func _scares() -> Node:
	return Game.main.get_node_or_null("Scares") if Game.main != null and is_instance_valid(Game.main) else null

func _once(key: String, call: Callable) -> void:
	if _sounded.has(key): return
	_sounded[key] = true
	call.call()

func _process(dt: float) -> void:
	if _pl == null or not is_instance_valid(_pl) or _pl.dead:
		_finish()
		return
	var cam: Camera3D = _pl.cam
	# the player's own view this frame, looking level: where the wake-up ends up. (Its height, sway and roll the
	# player sets fresh each frame; its pitch builds on the last frame's, which is ours, so it is left out.)
	var stand: Transform3D = _pl.global_transform * Transform3D(Basis.from_euler(Vector3(0.0, cam.rotation.y, cam.rotation.z)), cam.position)
	if _t < 0.0:
		# behind the black: the level is still being built, then a moment more
		_black(1.0)
		_pl.frozen = true
		_pl.velocity = Vector3.ZERO
		var lv: Node = Game.level
		if lv != null and lv.get("rebuilding") == true:
			_wait = 0.0
			return
		_wait += dt
		if _wait < SETTLE: return
		_t = 0.0
		var sc := _scares()
		if sc != null:
			sc.spawn_flat(sc.synth("tinnitus", 6.0), 0.18, "Body")
			sc.heartbeat(0.9)
		var amb: Node = Game.main.get_node_or_null("Audio/Ambience")
		if amb != null: amb.hush_for(0.1, 7.0)
	_t += dt
	_pl.frozen = true
	_pl.velocity = Vector3.ZERO
	var t := _t
	var sc := _scares()
	# --- the eyes: open a crack, shut, open longer, shut, then open for good (black = 1 is shut)
	var lid := 1.0
	if t < 0.6: lid = 1.0
	elif t < 1.4: lid = 1.0 - 0.45 * sin((t - 0.6) / 0.8 * PI)             # a crack of light, gone
	elif t < 2.0: lid = 1.0
	elif t < 3.4: lid = 1.0 - 0.75 * sin((t - 2.0) / 1.4 * PI)
	elif t < 3.8: lid = 1.0
	else: lid = maxf(0.0, 1.0 - (t - 3.8) / 1.2)
	_black(lid)
	var wake := clampf((t - 3.8) / (LIE + SIT + STAND - 3.8), 0.0, 1.0)
	Game.fx_blur = 0.45 * (1.0 - wake)
	Game.fx_sat = lerpf(0.35, 1.0, wake)
	# --- the body: on your side on the floor, then sitting, then up
	var base: Vector3 = _pl.global_position
	var yaw: float = _pl.rotation.y
	var h := FLOOR_Y
	var roll := 1.35                       # on your side: the room on its side
	var pitch := -0.08
	var breathe := 0.02 * sin(t * 2.6)     # your chest heaving against the floor
	if t >= LIE and t < LIE + SIT:
		var k := smoothstep(0.0, 1.0, (t - LIE) / SIT)
		h = lerpf(FLOOR_Y, SIT_Y, k)
		roll = lerpf(1.35, 0.12, smoothstep(0.0, 0.6, (t - LIE) / SIT))
		pitch = lerpf(-0.08, -0.25, k) + 0.12 * sin(k * PI)                 # head lolls forward as you come up
		if sc != null:
			_once("sit", func(): sc.spawn3d(sc.synth("creak"), base + Vector3.UP * 0.4, 0.25, "Scares", 2.0, 1.4))
	elif t >= LIE + SIT:
		var k := smoothstep(0.0, 1.0, (t - LIE - SIT) / STAND)
		h = SIT_Y
		roll = 0.12 * (1.0 - k)
		pitch = -0.25 * (1.0 - k)
		breathe = 0.035 * sin(t * 3.1) * (1.0 - k)                       # unsteady on your feet
	if t < LIE and sc != null:
		_once("gasp", func(): sc.heartbeat(1.0))
	var basis := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch) * Basis(Vector3.BACK, roll)
	var lying := Transform3D(basis, base + Vector3.UP * (h + breathe))
	var to_stand := smoothstep(LIE + SIT, LIE + SIT + STAND, t)
	var xf := lying.interpolate_with(stand, to_stand)
	cam.global_transform = xf
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
