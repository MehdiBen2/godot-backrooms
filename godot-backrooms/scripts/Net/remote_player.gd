extends Node3D
## Another survivor. Wears the hazmat suit (models/player/survivor.glb) and plays its clips through
## survivor_anim.gd: look-around idle / walk / run / crouch idle / crouch walk, and the death clip which
## holds its last frame. Falls back to a box figure if the model can't load.
## Smoothed towards the last state received.

const HazmatFit := preload("res://scripts/Entities/hazmat_fit.gd")
const SurvivorAnim := preload("res://scripts/Entities/survivor_anim.gd")
const MODEL := SurvivorAnim.MODEL
const MODEL_HEIGHT := 2.0       # metres: eye / visor level matches the 1.7 m camera in the idle pose
const SMOOTH := 12.0

var color := Color("c9a44a")

var target_pos := Vector3.ZERO
var target_yaw := 0.0
var target_pitch := 0.0
var crouching := false
var torch_on := true
var dead := false
var seen := false
var peer_id := 0
var playing := true              # false while they sit in the menu: the monsters leave them alone

var body: Node3D                # box figure + torch; the torch stays when the model replaces the box
var figure: Node3D              # the box figure only
var leg_l: Node3D
var leg_r: Node3D
var head: MeshInstance3D
var light: SpotLight3D
var tag: Label3D
var model: Node3D
var anim: AnimationPlayer
var _floor: SurvivorAnim.FloorGuard
var clips := {}                 # role -> animation name found in the model
var _role := ""
var _walk := 0.0
var _speed := 0.0
var speed := 0.0                # m/s, smoothed; read by the entity's senses
var _fall := 0.0
var buf = preload("res://scripts/Net/snap_buffer.gd").new()

func _ready() -> void:
	body = Node3D.new()
	add_child(body)
	figure = Node3D.new()
	body.add_child(figure)
	var jacket := StandardMaterial3D.new()
	jacket.albedo_color = color
	var trousers := StandardMaterial3D.new()
	trousers.albedo_color = Color("262a33")
	var skin := StandardMaterial3D.new()
	skin.albedo_color = Color("c09a7c")

	_box(figure, Vector3(0.42, 0.62, 0.24), Vector3(0, 1.19, 0), jacket)
	head = _box(figure, Vector3(0.22, 0.25, 0.22), Vector3(0, 1.64, 0), skin)
	_box(figure, Vector3(0.12, 0.66, 0.13), Vector3(-0.28, 1.15, 0), jacket)
	_box(figure, Vector3(0.12, 0.66, 0.13), Vector3(0.28, 1.15, 0), jacket)
	leg_l = _leg(Vector3(-0.1, 0.88, 0), trousers)
	leg_r = _leg(Vector3(0.1, 0.88, 0), trousers)

	light = SpotLight3D.new()
	light.position = Vector3(0.28, 1.4, -0.3)
	light.spot_range = 12.0
	light.spot_angle = 32.0
	light.light_energy = 2.5
	light.light_color = Color("fff0c8")
	# Without a shadow their torch shines straight through walls: you'd see a pool of light on your floor
	# from a survivor in the next corridor. One spot shadow each is cheap; off on the Low preset.
	light.shadow_enabled = int(Gfx.s.get("shadows", 1)) > 0
	light.shadow_bias = 0.04
	light.shadow_normal_bias = 1.5
	body.add_child(light)

	tag = Label3D.new()
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.pixel_size = 0.004
	tag.font_size = 48
	tag.outline_size = 12
	tag.modulate = Color(0.94, 0.91, 0.75)
	tag.position = Vector3(0, 2.25, 0)
	tag.no_depth_test = true
	add_child(tag)
	visible = false          # until the first state arrives
	_load_model()

func set_label(text: String) -> void:
	if tag:
		tag.text = text
	else:
		ready.connect(func(): tag.text = text, CONNECT_ONE_SHOT)

# ---- hazmat model -------------------------------------------------------------------
func _load_model() -> void:
	var packed := load(MODEL) as PackedScene
	if packed == null:
		return
	var root: Node3D = packed.instantiate()
	var aps := root.find_children("*", "AnimationPlayer", true, false)
	if aps.is_empty():
		root.queue_free()
		return
	anim = aps[0]
	clips = SurvivorAnim.find_clips(anim)       # a missing clip falls back to the nearest one
	if clips["run"] == "" and clips["idle"] == "":
		root.queue_free()
		anim = null
		return

	# stand on the floor, centred, MODEL_HEIGHT tall. The file faces +Z, survivors face -Z.
	model = Node3D.new()
	add_child(model)
	model.add_child(root)
	root.transform = HazmatFit.fit(root, model, MODEL_HEIGHT)
	model.rotation.y = PI
	_floor = SurvivorAnim.FloorGuard.new(model, anim)
	_tint(root)
	figure.visible = false
	_role = ""
	_play("idle")

# the suit takes a little of the survivor's colour so everyone is easy to tell apart
func _tint(root: Node) -> void:
	var tint := Color.WHITE.lerp(color, 0.3)
	for m in root.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		for i in mi.get_surface_override_material_count():
			var mat := mi.get_active_material(i)
			if mat is StandardMaterial3D:
				var c: StandardMaterial3D = mat.duplicate()
				c.albedo_color = c.albedo_color * tint
				mi.set_surface_override_material(i, c)

func _play(role: String) -> void:
	if role == "" or role == _role:
		return
	_role = role
	anim.play(clips[role], SurvivorAnim.FADE)

## A snapshot from the network: sender clock t (s), feet position, facing, look pitch, ground speed
func push_state(t: float, pos: Vector3, yaw: float, pitch: float, spd: float, flags: int, level: int) -> void:
	buf.push(t, {"pos": pos, "yaw": yaw, "pitch": pitch, "speed": spd, "flags": flags, "level": level})

func _process(dt: float) -> void:
	var st := buf.sample(dt)
	if st.is_empty():
		return
	var flags: int = st.flags
	crouching = flags & 1 != 0
	torch_on = flags & 2 != 0
	dead = flags & 4 != 0
	playing = flags & 8 != 0
	# a survivor still loading another level (level change, respawn) isn't in our world yet
	visible = int(st.level) == Game.level_index
	global_position = st.pos
	rotation.y = st.yaw
	target_pos = buf.latest().pos
	target_yaw = st.yaw
	target_pitch = st.pitch
	if not seen:
		seen = true
	# their own speed, as measured on their machine: animations match what they are really doing
	_speed = st.speed
	speed = _speed
	# a green name tag while they talk on voice chat
	tag.modulate = Color(0.55, 1.0, 0.6) if Voice.is_speaking(peer_id) else Color(0.94, 0.91, 0.75)
	var k := minf(1.0, dt * SMOOTH)
	light.rotation.x = target_pitch
	light.visible = torch_on and not dead and visible

	if anim != null:
		_play(SurvivorAnim.pick_role(clips, _role, _speed, _speed > SurvivorAnim.SPRINT_ABOVE, crouching, dead))
		anim.speed_scale = SurvivorAnim.speed_scale(_role, _speed)    # feet match the real movement
		_floor.on = not dead
		tag.position.y = 0.9 if dead else (1.75 if crouching else 2.25)
		return

	# ---- box figure fallback ----
	var amp := minf(1.0, _speed / 2.4)
	_walk += _speed * dt * 3.4
	var swing := sin(_walk) * amp * 0.75
	leg_l.rotation.x = swing
	leg_r.rotation.x = -swing
	# a dead survivor topples onto their back; on respawn they snap upright
	_fall = minf(1.0, _fall + dt * (0.6 + _fall * 3.0)) if dead else maxf(0.0, _fall - dt * 4.0)
	body.rotation.x = _fall * _fall * -1.5
	body.scale.y = lerpf(body.scale.y, 0.62 if crouching else 1.0, k)
	head.rotation.x = target_pitch * 0.6
	tag.position.y = (2.1 * body.scale.y) if not dead else 0.8

func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	m.mesh = b
	m.material_override = mat
	m.position = pos
	parent.add_child(m)
	return m

# a leg pivots at the hip, the mesh hangs below it
func _leg(hip: Vector3, mat: Material) -> Node3D:
	var pivot := Node3D.new()
	pivot.position = hip
	figure.add_child(pivot)
	_box(pivot, Vector3(0.16, 0.85, 0.18), Vector3(0, -0.425, 0), mat)
	return pivot
