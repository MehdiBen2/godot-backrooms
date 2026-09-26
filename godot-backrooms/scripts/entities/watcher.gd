extends Node3D
## THE WATCHER. A tall black figure that stands at the far end of a long corridor and only watches.
## It fades in slowly, faint and half-seen. It never closes in: walk at it and it drifts back, stare
## at it too long or lose line of sight and it is simply gone, to turn up down another corridor later.
##
## Debug console: `spawn watcher` / `despawn watcher`.

const GridNav := preload("res://scripts/world/grid_nav.gd")
const TEXTURE := "res://textures/entities/watcher.png"
const HEIGHT := 2.7
const ASPECT := 360.0 / 1138.0

const FIRST_WAIT := 25.0
const RESPAWN_MIN := 20.0
const RESPAWN_MAX := 50.0
const MIN_CORRIDOR := 20.0        # it only appears where you can see at least this far
const MIN_DIST := 20.0
const MAX_DIST := 36.0
const MAX_ALPHA := 0.6
const FADE_IN := 3.0
const FADE_OUT := 1.2
const VIEW_CONE := 0.8
const STARE_TIME := 4.5           # seconds of being looked at before it goes
const UNSEEN_TIME := 7.0          # seconds out of your sight before it goes
const LOST_LINE_TIME := 1.5
const RETREAT_DIST := 13.0
const RETREAT_SPEED := 3.0
const VANISH_DIST := 8.0

var level: Node
var player: CharacterBody3D
var nav
var rng := RandomNumberGenerator.new()
var quad: MeshInstance3D
var mat: StandardMaterial3D

var enabled := true              # false: it stays gone (console despawn)
var present := false
var alpha := 0.0
var fade_speed := 1.0 / FADE_IN
var fading_out := false
var wait := FIRST_WAIT
var watched_for := 0.0
var unseen_for := 0.0
var no_line_for := 0.0
var clock := 0.0

func _ready() -> void:
	rng.randomize()
	level = get_parent().get_node("Level")
	player = get_parent().get_node("Player")
	nav = GridNav.new(level)
	_build_quad()

func _load_texture() -> Texture2D:
	var t := load(TEXTURE) as Texture2D
	if t != null:
		return t
	var img := Image.load_from_file(ProjectSettings.globalize_path(TEXTURE))   # not imported yet
	if img == null:
		return null
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

func _build_quad() -> void:
	mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_texture = _load_texture()
	mat.albedo_color = Color(1, 1, 1, 0)
	var qm := QuadMesh.new()
	qm.size = Vector2(HEIGHT * ASPECT, HEIGHT)
	quad = MeshInstance3D.new()
	quad.mesh = qm
	quad.material_override = mat
	quad.position.y = HEIGHT / 2.0
	quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	quad.visible = false
	add_child(quad)

func view_dot(x: float, z: float) -> float:
	var p := player.global_position
	var fwd := -player.global_transform.basis.z
	var dx := x - p.x
	var dz := z - p.z
	var l := maxf(sqrt(dx * dx + dz * dz), 0.001)
	var fl := maxf(sqrt(fwd.x * fwd.x + fwd.z * fwd.z), 0.001)
	return (fwd.x * dx + fwd.z * dz) / (l * fl)

# The far end of a long straight run you are looking down (or, failing that, any long run)
func find_spot() -> Variant:
	var p := player.global_position
	var fwd := -player.global_transform.basis.z
	var best := -INF
	var spot = null
	for i in 16:
		var a := i * PI / 8.0
		var dx := sin(a)
		var dz := cos(a)
		var reach := 0.0
		var d := 1.0
		while d <= MAX_DIST:
			if not nav.open_at(p.x + dx * d, p.z + dz * d):
				break
			reach = d
			d += 0.8
		if reach < MIN_CORRIDOR:
			continue
		var score := (dx * fwd.x + dz * fwd.z) + rng.randf() * 0.5
		if score > best:
			best = score
			var dist := rng.randf_range(MIN_DIST, minf(reach, MAX_DIST))
			spot = Vector2(p.x + dx * dist, p.z + dz * dist)
	return spot

func appear() -> bool:
	var spot = find_spot()
	if spot == null:
		return false
	global_position = Vector3(spot.x, player.global_position.y, spot.y)
	present = true
	fading_out = false
	alpha = 0.0
	fade_speed = 1.0 / FADE_IN
	watched_for = 0.0
	unseen_for = 0.0
	no_line_for = 0.0
	quad.visible = true
	return true

func vanish(fast := false) -> void:
	if not present:
		return
	fading_out = true
	fade_speed = 1.0 / (0.25 if fast else FADE_OUT)

func _gone() -> void:
	present = false
	fading_out = false
	alpha = 0.0
	quad.visible = false
	wait = rng.randf_range(RESPAWN_MIN, RESPAWN_MAX)

func _physics_process(delta: float) -> void:
	if not Game.playing or Game.dead or player.dead:
		return
	clock += delta
	if not present:
		if not enabled:
			return
		wait -= delta
		if wait <= 0.0:
			if not appear():
				wait = 3.0
		return

	var pos := global_position
	var pp := player.global_position
	var dist := Vector2(pos.x - pp.x, pos.z - pp.z).length()
	var line: bool = nav.clear_line(pos.x, pos.z, pp.x, pp.z)
	var watched := line and view_dot(pos.x, pos.z) > VIEW_CONE and dist < 45.0

	if not fading_out:
		no_line_for = 0.0 if line else no_line_for + delta
		if watched:
			watched_for += delta
			unseen_for = 0.0
			Game.haunt(0.12)
			if dist < RETREAT_DIST:
				_retreat(delta, pos, pp, dist)
		else:
			unseen_for += delta
		if dist < VANISH_DIST or watched_for > STARE_TIME or unseen_for > UNSEEN_TIME or no_line_for > LOST_LINE_TIME:
			vanish(dist < VANISH_DIST)

	# faint at the best of times, fainter still with distance, with a nervous flicker
	var target := 0.0 if fading_out else MAX_ALPHA
	alpha = move_toward(alpha, target, fade_speed * MAX_ALPHA * delta)
	var far := clampf(1.35 - dist / 45.0, 0.3, 1.0)
	var flicker := 0.88 + 0.12 * sin(clock * 9.0) * sin(clock * 3.7)
	mat.albedo_color = Color(1, 1, 1, alpha * far * flicker)
	if fading_out and alpha <= 0.0:
		_gone()

# Walk at it and it backs off down the corridor rather than let you close
func _retreat(delta: float, pos: Vector3, pp: Vector3, dist: float) -> void:
	var away := Vector2(pos.x - pp.x, pos.z - pp.z) / maxf(dist, 0.001)
	var nx := pos.x + away.x * RETREAT_SPEED * delta
	var nz := pos.z + away.y * RETREAT_SPEED * delta
	if nav.open_at(nx + away.x * 0.8, nz + away.y * 0.8):
		global_position = Vector3(nx, pos.y, nz)
	else:
		vanish(true)

# ---------------------------------------------------------------- debug console
func debug_active() -> bool:
	return present and not fading_out

func debug_spawn() -> bool:
	enabled = true
	if present and not fading_out:
		return true
	if present:
		_gone()
	return appear()

func debug_despawn() -> void:
	enabled = false
	if present:
		_gone()
