extends Node3D
## Another survivor. Wears the hazmat suit (models/player/survivor.glb) and moves it through
## survivor_anim.gd's Locomotion: look-around idle, walk / run / crouch walk blended forwards, backwards and
## sideways by the way they are really going, and the death clip which holds its last frame. Caught by THE
## MANNEQUIN they play its kill instead (play_kill(): frozen, the neck wrenched round, then down), so the
## others watch it happen. The body turns after their look and the head leads it. Falls back to a box
## figure if the model can't load.
## Smoothed towards the last state received.

const HazmatFit := preload("res://scripts/Entities/hazmat_fit.gd")
const SurvivorAnim := preload("res://scripts/Entities/survivor_anim.gd")
const MODEL := SurvivorAnim.MODEL
const MODEL_HEIGHT := 2.0       # metres: eye / visor level matches the 1.7 m camera in the idle pose
const SMOOTH := 12.0
const LIGHT_FADE := 34.0
const SHADOW_FADE := 18.0

var color := Color("c9a44a")

var target_pos := Vector3.ZERO
var target_yaw := 0.0
var target_pitch := 0.0
var crouching := false
var torch_on := true
var dead := false
var seen := false
var here := true                 # on our level AND floor (an invisible spectator is still `here`)
var peer_id := 0
var playing := true              # false while they sit in the menu: the monsters leave them alone
var level_i := -1                # the level and floor they are on ([F6] CREW)
var floor_i := 0
const GARBLE := "#%&@$?!/"
var _name := ""                  # their callsign as it should read; the tag breaks it up with the signal
var _tag_t := 0.0
var _tag_alpha := 1.0

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
var loco: SurvivorAnim.Locomotion
var clips := {}                 # role -> animation name found in the model
var _walk := 0.0
var _vel := Vector3.ZERO         # m/s, from how their (interpolated) position moves: the way they're going
var _last_pos := Vector3.INF
var _speed := 0.0
var speed := 0.0                # m/s, smoothed; read by the entity's senses
var _fall := 0.0
const KILL_GIVE_UP := 9.0        # s: a kill that never ended in their death (they got away?) lets them go
const KILL_SNAP_AT := 2.3        # s into it: the crack (mannequin_snap.gd SNAP_AT)
const KILL_DROP_AT := 4.75       # ...it let go, they dropped onto their knees and went over: the chest hits
var _kill_t := -1.0              # s since the mannequin's kill started (-1: not in one)
var _kill_dead := false          # ...and they have died since
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
	# from a survivor in the next corridor. Off on the Low preset. Every shadowed torch is one more shadow
	# render of the level a frame, so with a full lobby they only keep it close by: the shadow fades out
	# past SHADOW_FADE m (a torch that far off lights little but its own wall) and the light past LIGHT_FADE.
	light.shadow_enabled = int(Gfx.s.get("shadows", 1)) > 0
	light.shadow_bias = 0.04
	light.shadow_normal_bias = 1.5
	light.distance_fade_enabled = true
	light.distance_fade_begin = LIGHT_FADE
	light.distance_fade_length = 8.0
	light.distance_fade_shadow = SHADOW_FADE
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
	_name = text
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
	loco = SurvivorAnim.Locomotion.new(anim, clips)
	_floor = SurvivorAnim.FloorGuard.new(model, loco.tree)
	_tint(root)
	figure.visible = false

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

## THE MANNEQUIN has them (net.gd, from their own machine as its neck snap starts there): its kill, played on
## their suit. The death that follows holds its last frame instead of the usual fall.
func play_kill() -> void:
	if loco != null and loco.play_kill():
		_kill_t = 0.0
		_kill_dead = false

# Heard from where it happens: the crack as the head goes round, the body dropping once it lets go
# (the clip's beats: tools/blender/add_survivor_neck_snap.py).
# Near: you hear their gasp and the bone crack raw. Far: their voice echoes down the corridors,
# reverbed and repeating like a fighting-game death cry, and fades away.
func _kill_sounds(was: float) -> void:
	if not visible:
		return
	var fwd := Vector3(-sin(rotation.y), 0.0, -cos(rotation.y))
	if was < KILL_SNAP_AT and _kill_t >= KILL_SNAP_AT:
		Death.friend_spray(global_position + Vector3(0.0, 1.65, 0.0), fwd)
	if was < KILL_DROP_AT and _kill_t >= KILL_DROP_AT:
		Death.friend_pool(global_position, fwd)
	var scares: Node = Game.main.get_node_or_null("Scares") if Game.main != null and is_instance_valid(Game.main) else null
	if scares == null:
		return
	if was < KILL_SNAP_AT and _kill_t >= KILL_SNAP_AT:
		scares.neck_snap_at(global_position + Vector3(0.0, 1.65, 0.0))
		# distance-based reaction: the near friend hears the raw gasp + crack,
		# the far friend hears the voice echo through the corridors and die away
		var player_node: Node3D = scares.player if scares.player != null else null
		if player_node != null:
			var d := player_node.global_position.distance_to(global_position)
			if d < scares.FAR_THRESH:
				scares.friend_death_near(global_position)
			else:
				scares.friend_death_far(global_position)
	if was < KILL_DROP_AT and _kill_t >= KILL_DROP_AT:
		scares.body_fall_at(global_position + Vector3(0.0, 0.3, 0.0))

func _end_kill() -> void:
	_kill_t = -1.0
	if loco != null:
		loco.end_kill()

## A snapshot from the network: sender clock t (s), feet position, facing, look pitch, ground speed
func push_state(t: float, pos: Vector3, yaw: float, pitch: float, spd: float, flags: int, level: int, floor_i: int) -> void:
	buf.push(t, {"pos": pos, "yaw": yaw, "pitch": pitch, "speed": spd, "flags": flags, "level": level, "floor": floor_i})

func _process(dt: float) -> void:
	var st := buf.sample(dt)
	if st.is_empty():
		return
	var flags: int = st.flags
	crouching = flags & 1 != 0
	torch_on = flags & 2 != 0
	var was_dead := dead
	dead = flags & 4 != 0
	if dead and not was_dead and _kill_t < 0.0 and visible and seen:      # any other death: a pool under them
		Death.friend_pool(global_position, Vector3(-sin(rotation.y), 0.0, -cos(rotation.y)))
	playing = flags & 8 != 0
	# a survivor still loading another level (level change, respawn), or up or down the stairs on another
	# floor of it, isn't in our world: hidden, out of earshot, and out of net.survivors() (no monster here
	# hunts them through the floor). An invisible spectator, flag 16, is hidden the same way.
	level_i = int(st.level)
	floor_i = int(st.get("floor", 0))
	here = level_i == Game.level_index and floor_i == Game.level_floor
	var was_visible := visible
	visible = here and flags & 16 == 0
	global_position = st.pos
	# velocity from the smoothed position (a jump of metres is a teleport: respawn, stairs, a portal)
	if _last_pos == Vector3.INF or _last_pos.distance_to(st.pos) > 3.0:
		_vel = Vector3.ZERO
	elif dt > 0.0:
		var v: Vector3 = (st.pos - _last_pos) / dt
		_vel = _vel.lerp(Vector3(v.x, 0.0, v.z), 1.0 - exp(-12.0 * dt))
	_last_pos = st.pos
	if loco != null:
		if not was_visible and visible:
			loco.face(st.yaw)                    # coming into view: already facing the right way
		rotation.y = loco.body_yaw             # the body lags their look; the head and torch lead it
		light.rotation.y = wrapf(st.yaw - rotation.y, -PI, PI)
	else:
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
	_tag_t -= dt
	if _tag_t <= 0.0:
		_tag_t = 0.09
		_tag_signal()
	tag.modulate.a = _tag_alpha
	var k := minf(1.0, dt * SMOOTH)
	if _kill_t >= 0.0:
		var was := _kill_t
		_kill_t += dt
		_kill_sounds(was)
		_kill_dead = _kill_dead or dead
		if (_kill_dead and not dead) or (not _kill_dead and _kill_t > KILL_GIVE_UP):
			_end_kill()                          # back on their feet (respawned), or it never killed them
	var caught := _kill_t >= 0.0
	light.rotation.x = target_pitch
	light.visible = torch_on and not dead and visible and not caught      # the torch is flung away

	if loco != null:
		loco.tree.active = visible               # nobody sees them: don't pose a skeleton every frame
		if not visible:
			loco.face(st.yaw)
			return
		# their own speed (measured on their machine) for the stride, our velocity for its direction
		var dir := _vel.normalized() if _vel.length() > 0.05 else Vector3.ZERO
		loco.update(dt, dir * _speed, _speed, _speed > SurvivorAnim.SPRINT_ABOVE, crouching, dead, st.yaw, target_pitch)
		_floor.on = not dead and not caught         # kneeling and lying are meant to be low
		tag.position.y = 0.9 if dead or _kill_t > 4.0 else (1.75 if crouching else 2.25)
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

## Far off, their name tag breaks up like the signal does: letters swapped for noise, the tag dimming and
## dropping out for a frame
func _tag_signal() -> void:
	var s: float = Net.signal_of(peer_id) if here else 1.0
	if s >= 0.75 or _name == "":
		if tag.text != _name:
			tag.text = _name
		_tag_alpha = 1.0
		return
	var bad := (0.75 - s) / 0.75
	var out := ""
	for ch in _name:
		out += GARBLE[randi() % GARBLE.length()] if randf() < bad * 0.6 else ch
	tag.text = out
	_tag_alpha = clampf(1.0 - bad * 0.7, 0.25, 1.0) * (0.3 if randf() < bad * 0.3 else 1.0)

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
