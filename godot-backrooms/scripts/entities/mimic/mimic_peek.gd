extends RefCounted
## THE MIMIC's peek (js/game/mimicPeek.js). Stand still long enough and a hazmat survivor slides in from the edge
## of your screen to study your face, then snaps away and footsteps run off into the dark. Whip the
## camera round and it bolts from wherever it has got to. Personal to each player (never networked).

const HazmatFit := preload("res://scripts/entities/hazmat_fit.gd")
const PEEK_COOLDOWN := 600.0
const PEEK_FIRST_WAIT := 30.0
const PEEK_STILL := 5.0
const PEEK_CHANCE := 0.5
const PEEK_IN := 1.4
const PEEK_HOLD := 2.0
const PEEK_OUT := 0.12
const PEEK_DIST := 0.9
const PEEK_HEIGHT := 2.6
const PEEK_STEPS := 7
const PEEK_STEP_GAP := 0.17
const PEEK_VOLUME := 0.9
const PEEK_SPOOK_SPEED := 2.6

var m: Node3D                       # mimic.gd
var root: Node3D
var head: Node3D
var anim: AnimationPlayer
var phase := "idle"
var t := 0.0
var side := 1.0
var amount := 0.0
var out_from := 1.0
var still := 0.0
var cooldown := PEEK_FIRST_WAIT
var steps_left := 0
var step_timer := 0.0
var step_index := 0
var last_yaw := 0.0
var last_pitch := 0.0
var turn := 0.0

func _init(owner: Node3D) -> void:
	m = owner

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

## The head, parented to the camera: the hazmat suit (the survivor the Mimic walks around as), dimmed,
## drawn over everything, its head at the pivot and the body falling off the edge of the screen
func build(cam: Camera3D) -> void:
	root = Node3D.new()
	root.visible = false
	cam.add_child(root)
	head = Node3D.new()
	root.add_child(head)
	var packed := load("res://models/player/hazmat.glb") as PackedScene
	if packed == null:
		return
	var model: Node3D = packed.instantiate()
	head.add_child(model)
	# the file faces +Z, which is toward the camera: no turn needed. Feet at the origin, then lowered so the head sits at the pivot
	var fit := HazmatFit.fit(model, head, PEEK_HEIGHT)
	fit.origin += Vector3(0, -PEEK_HEIGHT * 0.9, 0)
	model.transform = fit
	for n in model.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.extra_cull_margin = 16.0
		for i in mi.get_surface_override_material_count():
			var mat := mi.get_active_material(i)
			if mat is StandardMaterial3D:
				var d: StandardMaterial3D = mat.duplicate()
				d.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				d.albedo_color = d.albedo_color * Color(0.45, 0.45, 0.45)   # dim, as if seen in the dark
				d.no_depth_test = true
				d.render_priority = 100
				mi.set_surface_override_material(i, d)
	var aps := model.find_children("*", "AnimationPlayer", true, false)
	if not aps.is_empty():
		anim = aps[0]
		if anim.has_animation("idle"):
			anim.get_animation("idle").loop_mode = Animation.LOOP_LINEAR
			anim.play("idle")

# Screen edge at the head's distance: how far out is off screen, how far in is a peek
func _pose(a: float) -> Vector2:
	var cam: Camera3D = m.player.cam
	var half_h := tan(deg_to_rad(cam.fov / 2.0)) * PEEK_DIST
	var vp := m.get_viewport().get_visible_rect().size
	var half_w := half_h * (vp.x / maxf(vp.y, 1.0))
	var hidden := half_w + 0.45
	var shown := half_w - 0.4
	return Vector2(side * (hidden + (shown - hidden) * a), half_h * 0.3 - (1.0 - a) * half_h * 0.3)

# How the head is held: turned to face you, top leaning in, a slow scan, a breath, a twitch
func _pose_head(a: float) -> void:
	var now := _now()
	var s := side
	var reach := minf(1.0, a)
	var twitch := pow(maxf(0.0, sin(now * 5.3)), 24.0) * 0.07 * sin(now * 61.0)
	var z := s * (0.12 + 0.4 * reach) + sin(now * 1.3) * 0.05 * reach
	var y := -s * 0.5 + sin(now * 0.8) * 0.12 * reach
	var x := -0.08 * reach + sin(now * 2.3) * 0.025 * reach
	if phase == "out":
		var u := minf(1.0, t / PEEK_OUT)
		z += s * 0.7 * u
		y += s * 0.6 * u
	head.rotation = Vector3(x + twitch, y, z + twitch)

func start() -> bool:
	var player: Node3D = m.player
	if phase != "idle" or player.dead:
		return false
	side = -1.0 if m.rng.randf() < 0.5 else 1.0
	phase = "in"
	t = 0.0
	out_from = 1.0
	amount = 0.0
	turn = 0.0
	last_yaw = player.rotation.y
	last_pitch = player.cam.rotation.x
	root.visible = true
	if anim != null and anim.has_animation("idle"):
		anim.play("idle")   # every visit starts from the first frame
		anim.seek(0.0, true)
	# its voice: an entity call from right beside you, on its side
	var at: Vector3 = player.cam.to_global(Vector3(side * 1.2, 0.0, -0.4))
	at.y = player.global_position.y + 1.4
	m.scares.entity_call("stalk", at, false, PEEK_VOLUME)
	return true

# footsteps carrying off behind it, quieter and further each time
func _step() -> void:
	var player: Node3D = m.player
	var i := step_index
	step_index += 1
	var fade := 1.0 - float(i) / PEEK_STEPS
	var at: Vector3 = player.cam.to_global(Vector3(side * (1.5 + i * 1.1), 0.0, 0.5 + i * 1.4))
	at.y = player.global_position.y + 0.2
	m.scares.play_scare("footThump", at, maxf(0.15, 0.85 * fade))

func hide() -> void:
	if root:
		root.visible = false
	phase = "idle"
	steps_left = 0

func update(delta: float) -> void:
	var player: Node3D = m.player
	if phase == "idle":
		if cooldown > 0.0:
			cooldown -= delta
			return
		# walking counts as calm: only sprinting (or being hurt) restarts the count
		if player.is_sprinting or player.dead or player.frozen:
			still = 0.0
			return
		still += delta
		if still < PEEK_STILL:
			return
		still = 0.0
		cooldown = PEEK_COOLDOWN             # win or lose, the wait starts again
		if m.rng.randf() < PEEK_CHANCE:
			start()
		return
	if player.dead:
		hide()
		return
	t += delta
	# whip the camera round and it bolts, from wherever it has got to
	var yaw: float = player.rotation.y
	var pitch: float = player.cam.rotation.x
	var d_yaw := wrapf(yaw - last_yaw, -PI, PI)
	var rate := sqrt(d_yaw * d_yaw + (pitch - last_pitch) * (pitch - last_pitch)) / delta if delta > 0.0 else 0.0
	last_yaw = yaw
	last_pitch = pitch
	turn += (rate - turn) * minf(1.0, delta * 12.0)
	if (phase == "in" or phase == "hold") and turn > PEEK_SPOOK_SPEED:
		_begin_out()
	var a := 1.0
	if phase == "in":
		var u := minf(1.0, t / PEEK_IN)
		a = 0.5 - cos(u * PI) / 2.0
		a = a * a * (3.0 - 2.0 * a)
		if u >= 1.0:
			phase = "hold"
			t = 0.0
	elif phase == "hold":
		a = 1.0 + minf(1.0, t / PEEK_HOLD) * 0.1
		if t >= PEEK_HOLD:
			_begin_out()
	elif phase == "out":
		var u2 := minf(1.0, t / PEEK_OUT)
		a = out_from * (1.0 - u2 * u2)
		if u2 >= 1.0:
			root.visible = false
			phase = "run"
	if phase == "in" or phase == "hold" or phase == "out":
		amount = a
		var pose := _pose(a)
		root.position = Vector3(pose.x, pose.y, -PEEK_DIST)
		_pose_head(a)
	if phase == "out" and steps_left == PEEK_STEPS:
		_step()
		steps_left -= 1
		step_timer = PEEK_STEP_GAP
	if phase == "out" or phase == "run":
		step_timer -= delta
		if steps_left > 0 and step_timer <= 0.0:
			_step()
			steps_left -= 1
			step_timer = PEEK_STEP_GAP
		if phase == "run" and steps_left <= 0:
			phase = "idle"

func _begin_out() -> void:
	phase = "out"
	t = 0.0
	out_from = amount
	step_index = 0
	step_timer = 0.0
	steps_left = PEEK_STEPS
