extends Node3D
## NOCLIP FLOOR (level_data.gd `noclip_floor`, painted in the level editor): ordinary-looking floor that you fall
## straight through, the way the Kane Pixels film opens. Nothing to see: stand on it a moment and it gives.
##   gives     a jolt, the picture tears, a deep thud; your feet sink into the carpet
##   through   you sink through the floor itself, the camera passing through the slab; the picture breaking up
##   void      under it there is nothing: the level seen from below, a falling body, static rising, then black
##   after     in the black you hit the ground, and wake up in the floor's Noclip destination (noclip_wake.gd)
## Built by level_geometry.gd on a floor that has any. Holds the player's body itself (process priority after
## the player) while it happens.

const NoclipWake := preload("res://scripts/World/level/noclip_wake.gd")
const STAND := 0.35           # s standing on it before it gives
const GIVE := 0.55            # the jolt and the sinking feet
const THROUGH := 1.25         # sinking through the slab
const VOID := 1.9             # falling under it, until the black
const BLACK_IN := 0.8         # the last part of the fall going black

var level: Node3D
var _on := 0.0
var _t := -1.0
var _y0 := 0.0
var _vy := 0.0
var _depth := 0.0
var _sounded := {}

func setup(l: Node3D) -> void:
	level = l
	process_physics_priority = 100

func _scares() -> Node:
	return level.get_parent().get_node_or_null("Scares") if level != null and level.get_parent() != null else null

func _once(key: String, call: Callable) -> void:
	if _sounded.has(key): return
	_sounded[key] = true
	call.call()

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
	var t := _t
	var sc := _scares()
	p.frozen = true
	p.velocity = Vector3.ZERO
	if t < GIVE:
		# the floor gives: a jolt, feet into the carpet
		var k := t / GIVE
		_depth = 0.55 * k * k
		p.rotation.z = 0.06 * sin(t * 40.0) * (1.0 - k)
		Game.fx_corrupt = maxf(Game.fx_corrupt, 0.35)
	elif t < GIVE + THROUGH:
		# through the slab: slow, then giving way
		var k := (t - GIVE) / THROUGH
		_depth = 0.55 + 2.1 * k * k
		p.rotation.z = lerpf(0.0, 0.22, k)                        # going over sideways as you drop
		Game.glitch = maxf(Game.glitch, 0.4 + 0.5 * k)
		Game.fx_warp = 0.004 + 0.02 * k
		if randf() < dt * 6.0: Game.fx_corrupt = maxf(Game.fx_corrupt, 0.3 + 0.5 * k)
		if sc != null:
			_once("through", func(): sc.play_scare("staticHit", 1.0))
	else:
		# under it: nothing but the level seen from below, falling faster
		var k := (t - GIVE - THROUGH) / VOID
		_vy += 14.0 * dt
		_depth += _vy * dt
		p.rotation.z = 0.22 + 0.15 * k
		Game.fx_static = 0.2 + 0.8 * k
		Game.glitch = maxf(Game.glitch, 0.6)
		if Gfx.post_mat:
			Gfx.post_mat.set_shader_parameter("fall_fade", smoothstep(VOID - BLACK_IN, VOID, t - GIVE - THROUGH))
		if k >= 1.0:
			_land(p)
			return
	p.global_position.y = _y0 - _depth

func _start(p) -> void:
	_t = 0.0
	_on = 0.0
	_y0 = p.global_position.y
	_vy = 1.5
	_depth = 0.0
	_sounded.clear()
	p.frozen = true
	p.velocity = Vector3.ZERO
	var sc := _scares()
	if sc != null:
		sc.spawn_flat(sc.synth("thump"), 0.9, "Scares", 0.32)
		sc.play_scare("staticHit", 0.8)
	Game.fx_shock = 0.8
	Game.add_glitch(0.6)

## In the black: the ground, and the level you fell into, built behind it
func _land(p) -> void:
	_t = -2.0
	p.rotation.z = 0.0
	Game.fx_static = 0.0
	Game.fx_warp = 0.0
	Game.glitch = 0.0
	if Gfx.post_mat: Gfx.post_mat.set_shader_parameter("fall_fade", 1.0)
	var sc := _scares()
	if sc != null and sc.has_method("body_fall"):
		sc.body_fall(0.0, false)
	Game.fx_shock = 1.0
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
