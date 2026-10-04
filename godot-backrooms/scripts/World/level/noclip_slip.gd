extends Node3D
## NOCLIP through the floor (level_data.gd `noclip_floor`: the Noclip zone painted on plain floor, or the Noclip
## Floor zone): ordinary-looking floor that you clip straight through, the way the Kane Pixels film opens. Stand
## on it a moment and you start to sink into it, then drop through it; the instant your eyes pass the carpet it is
## black. No sound but your body landing somewhere else. noclip_wake.gd then has you come to in the floor's
## Noclip destination. Built by level_geometry.gd on a floor that has any. Holds the player's body itself (process
## priority after the player) while it happens; nothing is rolled (the HUD's vitals tilt with the camera's roll).

const NoclipWake := preload("res://scripts/World/level/noclip_wake.gd")
const STAND := 0.35           # s standing on it before it takes you
const SINK := 0.45            # feet sinking into the carpet, slowly
const DROP := 0.55            # then dropping through, faster and faster
const HOLD := 0.35            # black, before you land

var level: Node3D
var _on := 0.0
var _t := -1.0
var _y0 := 0.0
var _eye := 1.6               # the camera's height over your feet when it started

func setup(l: Node3D) -> void:
	level = l
	process_physics_priority = 100

func _physics_process(dt: float) -> void:
	if level == null: return
	var p = level.player
	if p == null or not is_instance_valid(p) or p.dead: return
	if _t < 0.0:
		if _t < -1.5: return                                     # (done: the level is being rebuilt)
		if Game.noclip or Game.draw_mode or Game.dead or Game.freefall or Death.respawn_busy or p.frozen: return
		if p.is_on_floor() and level.noclip_floor.has(level.cell_of(p.global_position)):
			_on += dt
			if _on >= STAND: _start(p)
		else:
			_on = 0.0
		return
	_t += dt
	p.frozen = true
	p.velocity = Vector3.ZERO
	var depth := 0.0
	if _t < SINK:
		var k: float = _t / SINK
		depth = 0.3 * k * k                                      # the floor gives under you
	elif _t < SINK + DROP:
		var k: float = (_t - SINK) / DROP
		depth = 0.3 + (_eye + 0.4) * k * k                       # and you go through it
		if k > 0.35 and randf() < dt * 8.0:
			Game.fx_corrupt = maxf(Game.fx_corrupt, 0.25)        # the picture catching on the geometry
	else:
		depth = 0.3 + _eye + 0.4
		if _t >= SINK + DROP + HOLD:
			_land()
			return
	# black the moment your eyes reach the carpet: you never see what is under the level
	if Gfx.post_mat:
		Gfx.post_mat.set_shader_parameter("fall_fade", smoothstep(_eye - 0.7, _eye - 0.1, depth))
	p.global_position.y = _y0 - depth

func _start(p) -> void:
	_t = 0.0
	_on = 0.0
	_y0 = p.global_position.y
	var cam: Camera3D = p.cam
	_eye = maxf(0.6, cam.global_position.y - _y0)
	p.frozen = true
	p.velocity = Vector3.ZERO
	Game.fx_shock = 0.35                                         # the jolt of the floor giving

## In the black: the ground, and the level you fell into, built behind it
func _land() -> void:
	_t = -2.0
	if Gfx.post_mat: Gfx.post_mat.set_shader_parameter("fall_fade", 1.0)
	var sc: Node = level.get_parent().get_node_or_null("Scares") if level.get_parent() != null else null
	if sc != null and sc.has_method("body_fall"):
		sc.body_fall(0.0, false)
	var to := str(level.get("noclip_to"))
	var idx := Game.level_index + 1
	var levels: Array = level.read_index()
	for i in levels.size():
		if str((levels[i] as Dictionary).get("id", "")) == to:
			idx = i
			break
	if Game.main != null and is_instance_valid(Game.main):
		Game.main.add_child(NoclipWake.new())
	Game.change_level(idx)                                     # (last: rebuilding the level tears this floor down, this node with it)
