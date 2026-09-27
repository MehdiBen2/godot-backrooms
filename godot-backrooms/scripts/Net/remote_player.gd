extends Node3D
## Another survivor. Wears the hazmat suit (models/player/hazmat.glb) and plays its clips the way the
## web game does (js/game/survivorModel.js): idle / run / sprint / crouch idle / crouch walk, and the
## death clip which holds its last frame. Falls back to a box figure if the model can't load.
## Smoothed towards the last state received.

const HazmatFit := preload("res://scripts/Entities/hazmat_fit.gd")
const MODEL := "res://models/player/hazmat.glb"
const MODEL_HEIGHT := 2.0       # metres: eye / visor level matches the 1.7 m camera in the idle pose
const SMOOTH := 12.0
const MOVING_ABOVE := 0.1       # m/s
const SPRINT_ABOVE := 3.2       # the player walks 2.4 m/s and sprints about 4
const FADE := 0.22              # clip cross-fade, seconds

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
	# same lookups as the web's findClip(); a missing clip falls back to the nearest one
	clips = {
		"run": _find("^run"), "sprint": _find("sprint"), "idle": _find("^idle"),
		"crouch_idle": _find("crouch.*idle"), "crouch_walk": _find("crouch.*walk"), "death": _find("death"),
	}
	if clips["run"] == "" and clips["idle"] == "":
		root.queue_free()
		anim = null
		return
	for role in clips:
		if clips[role] != "":
			anim.get_animation(clips[role]).loop_mode = Animation.LOOP_NONE if role == "death" else Animation.LOOP_LINEAR

	# stand on the floor, centred, MODEL_HEIGHT tall. The file faces +Z, survivors face -Z.
	model = Node3D.new()
	add_child(model)
	model.add_child(root)
	root.transform = HazmatFit.fit(root, model, MODEL_HEIGHT)
	model.rotation.y = PI
	_tint(root)
	figure.visible = false
	_role = ""
	_play("idle")

func _find(pattern: String) -> String:
	var re := RegEx.new()
	re.compile("(?i)" + pattern)
	for n in anim.get_animation_list():
		if re.search(n):
			return n
	return ""

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

# Stand / crouch x still / moving, like the web's blend: each role falls back to the closest clip
func _pick_role(moving: bool, sprinting: bool) -> String:
	if dead:
		return "death" if clips.get("death", "") != "" else "idle"
	var want := ""
	if crouching:
		want = "crouch_walk" if moving else "crouch_idle"
	elif moving:
		want = "sprint" if sprinting else "run"
	else:
		want = "idle"
	var fallback := {"crouch_walk": "run", "crouch_idle": "idle", "sprint": "run", "run": "idle", "idle": "run"}
	while want != "" and clips.get(want, "") == "":
		want = fallback.get(want, "")
	return want

func _play(role: String) -> void:
	if role == "" or role == _role:
		return
	_role = role
	anim.play(clips[role], FADE)
	if role == "death":
		anim.speed_scale = 1.0

# playback speed follows the real movement speed so feet don't slide
func _anim_speed() -> float:
	match _role:
		"run": return clampf(_speed / 2.8, 0.5, 2.0)
		"sprint": return clampf(_speed / 4.0, 0.7, 1.6)
		"crouch_walk": return clampf(_speed / 1.4, 0.5, 2.0)
	return 1.0

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
		_play(_pick_role(_speed > MOVING_ABOVE, _speed > SPRINT_ABOVE))
		anim.speed_scale = _anim_speed()
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
