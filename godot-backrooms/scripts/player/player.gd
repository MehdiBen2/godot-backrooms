extends CharacterBody3D
## First-person controller. Values mirror PLAYER_DEFAULTS / JUMP in the web game.
## Movement reads PHYSICAL keys, so WASD works as ZQSD on AZERTY (and any other layout).

const SPEED := 2.6
const SPRINT_MULT := 1.75
const CROUCH_MULT := 0.52
const STAND_H := 1.7
const CROUCH_H := 1.0
const JUMP_SPEED := 5.0
const GRAVITY := 20.0
# Movement feel: weighty but responsive, forgiving jumps
const ACCEL_GROUND := 16.0        # x speed per second towards the wished velocity (was an instant 40 m/s^2)
const DECEL_GROUND := 22.0        # a touch snappier when letting go, so stops feel deliberate
const ACCEL_AIR := 5.0            # limited steering in the air
const COYOTE_TIME := 0.10         # can still jump this long after walking off an edge
const JUMP_BUFFER := 0.12         # a press this soon before landing still jumps
const LEAN_WALK := 0.010          # camera roll into a strafe (rad)
const LEAN_SPRINT := 0.018
var sens := 0.0022        # set from the menu's Mouse Sens slider
const SPRINT_SECONDS := 30.0
const STAMINA_REGEN := 18.0
# Adrenaline (ADRENALINE in js/config.js): hunted by the bacteria up close, you get a burst of speed
# and endless sprint to break away, then a crash
const ADR_RANGE := 22.0          # metres: it must be chasing you from at least this close
const ADR_BOOST := 0.5           # +50% movement speed
const ADR_RAMP := 0.35           # seconds to reach full strength
const ADR_MAX_TIME := 10.0       # longest a burst can last
const ADR_AFTERGLOW := 3.5       # seconds it lingers after the chase ends
const ADR_CRASH_STAMINA := 25.0  # stamina you're left with when it fades
const ADR_COOLDOWN := 22.0       # seconds before it can kick in again
const ADR_FOV := 9.0             # extra field of view at full strength (degrees)

@onready var cam: Camera3D = $Camera3D
@onready var flash: SpotLight3D = $Camera3D/Flashlight
var flash_spill: SpotLight3D
@onready var shape: CollisionShape3D = $CollisionShape3D

signal jumped
signal landed(strength: float)
signal battery_died
signal dead_click
signal contact_click(off: bool)
signal adrenaline_started
signal adrenaline_faded

var is_sprinting := false
var is_moving := false
var is_crouching := false
var was_airborne := false
var air_time := 0.0
var last_vy := 0.0
var last_step_time := 0.0
var foot := 1.0
var eye := STAND_H
var was_stepping := false
var step_triggered := false
var fov_kick := 0.0
# three.js fov is vertical; Godot's default keeps height too (KEEP_HEIGHT)
const BASE_FOV := 75.0
var health := 100.0
var sanity := 100.0
var battery := 100.0          # flashlight battery, %
var flash_on := true
var light_level := 1.0
var flash_target := Vector3.ZERO
var flash_flicker := {"timer": 6.0, "active": false, "step": 0.0, "value": 1.0}
var holder: Node3D
var dead := false
var grid_down := false       # power cut: the torch drains slowly
var spawn_grace := 0.0
var frozen := false          # grabbed / snapped: no input
const FLASH_ENERGY_HOTSPOT := 6.5
const FLASH_ENERGY_SPILL := 2.0
const BATTERY_DRAIN := 100.0 / 75.0     # % per second while on (75 s of light)
const BATTERY_LOW := 25.0
const BATTERY_CRIT := 10.0
var stamina := 100.0
var exhausted := false
var rest_timer := 0.0
var adrenaline := 0.0          # 0..1 strength of the burst, eased in and out
var adr_active := false
var adr_time := 0.0
var adr_glow := 0.0
var adr_cooldown := 0.0
var bob := 0.0
var walk_sounds: Array[AudioStream] = []
var sprint_sounds: Array[AudioStream] = []
var step_player: AudioStreamPlayer
var heel_player: AudioStreamPlayer        # the low knock under each recorded scuff
var heel_sound: AudioStream
var click_player: AudioStreamPlayer
var click_on: AudioStream = load("res://audio/on.mp3")
var click_off: AudioStream = load("res://audio/off.mp3")

var space_prev := false
var jump_buffer := 0.0
var coyote := 0.0
var land_dip := 0.0
var lean := 0.0

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	for i in range(1, 5):
		walk_sounds.append(load("res://audio/carpet_walk_%d.wav" % i))
		sprint_sounds.append(load("res://audio/carpet_sprint_%d.wav" % i))
	flash.top_level = true
	flash.visible = true
	if flash.has_node("Spill"):
		flash_spill = flash.get_node("Spill") as SpotLight3D
	else:
		flash_spill = SpotLight3D.new()
		flash_spill.name = "Spill"
		flash_spill.light_color = Color(1.0, 0.94, 0.84, 1.0)
		flash_spill.light_energy = FLASH_ENERGY_SPILL
		flash_spill.spot_range = 20.0
		flash_spill.spot_angle = 58.0
		flash_spill.spot_attenuation = 1.1
		flash_spill.spot_angle_attenuation = 1.1
		flash_spill.shadow_enabled = false
		flash.add_child(flash_spill)
	_build_flashlight_view()
	_build_arms_view()
	step_player = AudioStreamPlayer.new()
	step_player.bus = "Steps"
	add_child(step_player)
	heel_player = AudioStreamPlayer.new()
	heel_player.bus = "Steps"
	add_child(heel_player)
	heel_sound = preload("res://scripts/audio/scare_synth.gd").new().render("heel")
	click_player = AudioStreamPlayer.new()
	click_player.volume_db = -4.4
	add_child(click_player)

func _key(code: Key) -> bool:
	return Input.is_physical_key_pressed(code)

func _unhandled_input(e: InputEvent) -> void:
	if dead or frozen: return
	if e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-e.relative.x * sens)
		cam.rotate_x(-e.relative.y * sens)
		cam.rotation.x = clampf(cam.rotation.x, -1.49, 1.49)
	elif e is InputEventKey and e.pressed and not e.echo and e.physical_keycode == KEY_F \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if not flash_on and battery <= 0.0:
			dead_click.emit()          # dead battery: a dry hollow click, nothing else
			return
		flash_on = not flash_on
		click_player.stream = click_on if flash_on else click_off
		click_player.play()

func _physics_process(dt: float) -> void:
	spawn_grace = maxf(0.0, spawn_grace - dt)
	if dead or frozen:
		if adrenaline > 0.0 or adr_active: end_adrenaline()
		velocity.x = 0.0
		velocity.z = 0.0
		is_moving = false
		is_sprinting = false
		if not is_on_floor(): velocity.y -= GRAVITY * dt
		move_and_slide()
		return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	var crouch := _key(KEY_C) or _key(KEY_CTRL)
	var dir := Vector2.ZERO
	if _key(KEY_W) or _key(KEY_UP): dir.y -= 1
	if _key(KEY_S) or _key(KEY_DOWN): dir.y += 1
	if _key(KEY_A) or _key(KEY_LEFT): dir.x -= 1
	if _key(KEY_D) or _key(KEY_RIGHT): dir.x += 1
	var moving := dir != Vector2.ZERO
	var rush := adrenaline > 0.5 and adr_active     # sprint is free during a burst
	var sprint := _key(KEY_SHIFT) and not crouch and moving and (rush or (not exhausted and stamina > 0.0))
	is_sprinting = sprint
	is_moving = moving
	is_crouching = crouch

	# Stamina: 30 s of sprint, brief rest delay, exhaustion until it recovers a bit
	if rush:
		exhausted = false
		stamina = maxf(stamina, 60.0)
		rest_timer = 0.6
	elif sprint:
		stamina = maxf(0.0, stamina - dt * 100.0 / SPRINT_SECONDS)
		rest_timer = 0.6
		if stamina <= 0.0: exhausted = true
	else:
		rest_timer = maxf(0.0, rest_timer - dt)
		if rest_timer == 0.0: stamina = minf(100.0, stamina + STAMINA_REGEN * dt)
		if exhausted and stamina >= 15.0: exhausted = false

	eye = lerpf(eye, CROUCH_H if crouch else STAND_H, minf(1.0, dt * 10.0))
	(shape.shape as CapsuleShape3D).height = eye + 0.1
	shape.position.y = (eye + 0.1) / 2.0

	var speed := SPEED * (SPRINT_MULT if sprint else (CROUCH_MULT if crouch else 1.0))
	speed *= 1.0 + ADR_BOOST * adrenaline
	var wish := (transform.basis * Vector3(dir.x, 0, dir.y)).normalized() * speed
	var rate := ACCEL_AIR
	if is_on_floor():
		rate = ACCEL_GROUND if moving else DECEL_GROUND
	velocity.x = move_toward(velocity.x, wish.x, rate * speed * dt)
	velocity.z = move_toward(velocity.z, wish.z, rate * speed * dt)

	var space := _key(KEY_SPACE)
	if space and not space_prev:
		jump_buffer = JUMP_BUFFER
	space_prev = space
	jump_buffer = maxf(0.0, jump_buffer - dt)
	coyote = COYOTE_TIME if is_on_floor() else maxf(0.0, coyote - dt)
	if (space or jump_buffer > 0.0) and coyote > 0.0:
		velocity.y = JUMP_SPEED
		jump_buffer = 0.0
		coyote = 0.0
		jumped.emit()
	elif not is_on_floor():
		velocity.y -= GRAVITY * dt
	last_vy = velocity.y
	move_and_slide()
	# Landing: both feet down, thud scales with the drop
	if is_on_floor():
		if was_airborne and air_time > 0.15 and last_vy < -2.0:
			var strength := minf(1.0, absf(last_vy) / 12.0)
			landed.emit(strength)
			land_dip = 0.04 + 0.10 * strength
			_footstep(true, false, 1.0)
		was_airborne = false
		air_time = 0.0
	else:
		was_airborne = true
		air_time += dt
	_update_flashlight(dt)
	_update_sanity(dt)

	# Head bob + footfalls: web updateHeadBob. Step lands at the bottom of each bob.
	var horiz := Vector2(velocity.x, velocity.z).length()
	var walking := moving and horiz > 0.3
	var y := eye
	if not is_on_floor():
		pass                                  # no bob while airborne
	elif not walking:
		if was_stepping:
			was_stepping = false
			if not step_triggered: _footstep(false, crouch, 0.5)   # trailing foot comes down softly
		bob += dt * 1.5
		y = eye + sin(bob) * 0.012
	else:
		was_stepping = true
		var freq := 12.0 if sprint else (6.0 if crouch else 8.5)
		bob += dt * freq
		var b := sin(bob)
		y = eye + b * (0.07 if sprint else 0.035)
		if b < -0.85 and not step_triggered:
			step_triggered = true
			_footstep(sprint, crouch, 1.0)
		elif b > 0.0:
			step_triggered = false
	land_dip *= exp(-dt * 9.0)
	cam.position = Vector3(0.0, y - land_dip, 0.0)
	var lean_target := -dir.x * (LEAN_SPRINT if sprint else LEAN_WALK) if walking else 0.0
	lean = lerpf(lean, lean_target, minf(1.0, dt * 7.0))
	cam.rotation.z = lean

	# FOV: 75 base, +2.5 sprinting, +2 in the air (web updateFov)
	var fov_target := (2.5 if sprint else 0.0) + (2.0 if not is_on_floor() else 0.0)
	fov_kick += (fov_target - fov_kick) * minf(1.0, 9.0 * dt)
	cam.fov = BASE_FOV + fov_kick + ADR_FOV * adrenaline

	# fell down a pit: the picture dissolves into static and you come to at the spawn, no hard cut
	if global_position.y < -30.0 and not Death.respawn_busy:
		Death.respawn_transition(_back_to_spawn)

# Something heavy landed nearby (the bacteria's footfalls in a chase): the view dips with the floor
func jolt(amount: float) -> void:
	land_dip = maxf(land_dip, clampf(amount, 0.0, 1.0) * 0.035)

# Adrenaline: the bacteria calls this every frame with whether it is hunting you close by
func update_adrenaline(dt: float, hunted: bool) -> void:
	if dead or frozen: hunted = false
	adr_cooldown = maxf(0.0, adr_cooldown - dt)
	if not adr_active and hunted and adr_cooldown <= 0.0:
		adr_active = true
		adr_time = 0.0
		adr_glow = ADR_AFTERGLOW
		Game.fx_shock = maxf(Game.fx_shock, 0.7)     # the jolt as it hits: the picture punches in
		var sc := get_parent().get_node_or_null("Scares")
		if sc != null:
			sc.startle(0.35)
			sc.heartbeat(1.6)
		adrenaline_started.emit()
	if adr_active:
		adr_time += dt
		adr_glow = ADR_AFTERGLOW if hunted else adr_glow - dt
		if adr_time > ADR_MAX_TIME or adr_glow <= 0.0 or dead:
			adr_active = false
			adr_cooldown = ADR_COOLDOWN
			if not dead:
				stamina = minf(stamina, ADR_CRASH_STAMINA)
				rest_timer = 2.5
				adrenaline_faded.emit()
	var target := 1.0 if adr_active else 0.0
	var rate := 1.0 / ADR_RAMP if target > adrenaline else 1.0 / 1.5
	adrenaline = move_toward(adrenaline, target, rate * dt)

# Drop straight out of adrenaline (death, grab, respawn): no crash, no cooldown
func end_adrenaline() -> void:
	adr_active = false
	adr_cooldown = 0.0
	adrenaline = 0.0

func _back_to_spawn() -> void:
	end_adrenaline()
	global_position = get_parent().get_node("Level").spawn_pos
	velocity = Vector3.ZERO
	land_dip = 0.0
	was_airborne = false
	air_time = 0.0

# ---- held flashlight (models/flashlight.glb in the right hand, like the web viewmodel) ----
const FLASH_LENGTH := 0.27
const FLASH_POS := Vector3(0.2, -0.2, -0.38)
const FLASH_ROT := Vector3(0.16, 0.14, 0.0)
const FLASH_LENS := Vector3(0, 0, -0.125)

func _box(size: Vector3, pos: Vector3, color: Color, rot := Vector3.ZERO) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	m.mesh = b
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	m.material_override = mat
	m.position = pos
	m.rotation = rot
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return m

func _build_flashlight_view() -> void:
	holder = Node3D.new()
	holder.position = FLASH_POS
	holder.rotation = FLASH_ROT
	cam.add_child(holder)
	var scene: PackedScene = load("res://models/flashlight.glb")
	var inner: Node3D = scene.instantiate()
	var wrap := Node3D.new()
	wrap.add_child(inner)
	holder.add_child(wrap)
	# Long axis of the file becomes the barrel (-Z), centred on the fist
	var aabb := _combined_aabb(inner)
	var size := aabb.size
	var axis := 0 if (size.x >= size.y and size.x >= size.z) else (1 if size.y >= size.z else 2)
	var sc := FLASH_LENGTH / size[axis]
	inner.scale = Vector3.ONE * sc
	inner.position = -(aabb.position + aabb.size / 2.0) * sc
	if axis == 0: wrap.rotation.y = PI / 2.0
	elif axis == 1: wrap.rotation.x = -PI / 2.0
	for n in inner.find_children("*", "MeshInstance3D", true, false):
		(n as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		(n as MeshInstance3D).gi_mode = GeometryInstance3D.GI_MODE_DISABLED

# ---- first-person hazmat arm (models/player/fp_arms.glb): shown while the torch is put away ----
const ARMS_POS := Vector3(-0.04, -0.36, -0.07)
const ARMS_ROT := Vector3(-0.6, PI, 0.0)   # file faces +Z; camera looks down -Z. Pitch drops the elbow out of view
const ARMS_DROP := 0.35                    # how far below its rest spot the hand hides (m)
const ARMS_RAISE_TIME := 0.35              # seconds to slide fully in or out

var arms: Node3D
var arms_raise := 0.0                      # 0 = hidden below the frame, 1 = up in view

func _build_arms_view() -> void:
	var scene: PackedScene = load("res://models/player/fp_arms.glb")
	if scene == null: return
	arms = scene.instantiate()
	arms.position = ARMS_POS
	arms.rotation = ARMS_ROT
	cam.add_child(arms)
	for n in arms.find_children("*", "MeshInstance3D", true, false):
		(n as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		(n as MeshInstance3D).gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	# Right arm only: both arms share one mesh, so the left one is shrunk away into its shoulder
	var skel := arms.find_children("*", "Skeleton3D", true, false)
	if not skel.is_empty():
		var sk := skel[0] as Skeleton3D
		var l_arm := sk.find_bone("L_arm_01")
		if l_arm >= 0: sk.set_bone_pose_scale(l_arm, Vector3.ONE * 0.001)
	arms_raise = 0.0 if flash_on else 1.0
	_place_arms()

func _place_arms() -> void:
	var e := smoothstep(0.0, 1.0, arms_raise)
	arms.position = ARMS_POS + Vector3(0.0, -ARMS_DROP * (1.0 - e), 0.0)
	arms.visible = arms_raise > 0.0

func _combined_aabb(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		var box := mi.global_transform * mi.get_aabb() if mi.is_inside_tree() else _local_aabb(root, mi)
		out = box if first else out.merge(box)
		first = false
	return out

func _local_aabb(root: Node3D, mi: MeshInstance3D) -> AABB:
	var t := Transform3D.IDENTITY
	var n: Node = mi
	while n != null and n != root.get_parent():
		if n is Node3D: t = (n as Node3D).transform * t
		n = n.get_parent()
	return t * mi.get_aabb()

# ---- per-frame flashlight: battery drain, low-battery dimming/flicker, aim with slight lag ----
func _update_flashlight(dt: float) -> void:
	if flash_on:
		battery = maxf(0.0, battery - BATTERY_DRAIN * (0.25 if grid_down else 1.0) * dt)
		if battery <= 0.0:
			flash_on = false
			battery_died.emit()
	var k := 1.0
	if battery < BATTERY_LOW:
		var ratio := maxf(0.12, battery / BATTERY_LOW)
		k *= 0.35 + 0.65 * ratio
		if randf() < (0.32 if battery < BATTERY_CRIT else 0.10):
			k *= 0.05 + randf() * 0.45
	k *= _contact_flicker(dt)
	# Dynamic dark adaptation: in deep darkness / unlit zones / power outage,
	# human pupils dilate, making the flashlight beam appear brighter and crisper
	var lvl := 1.0
	var level_node := get_parent().get_node_or_null("Level")
	if level_node and level_node.has_method("tube_light_at"):
		lvl = level_node.tube_light_at(global_position)
	var dark_boost := lerpf(1.35, 1.0, clampf(lvl, 0.0, 1.0))

	flash.light_energy = FLASH_ENERGY_HOTSPOT * k * dark_boost if flash_on else 0.0
	flash.visible = flash_on
	# Torch out = torch in hand; switched off it is put away and the bare arm slides up instead
	holder.visible = flash_on
	if arms:
		arms_raise = move_toward(arms_raise, 0.0 if flash_on else 1.0, dt / ARMS_RAISE_TIME)
		_place_arms()
	if flash_spill:
		flash_spill.light_energy = FLASH_ENERGY_SPILL * k * dark_boost if flash_on else 0.0
		flash_spill.visible = flash_on

	# Beam leaves the lens of the held torch and follows the view with natural handheld lag
	var lens_world := holder.to_global(FLASH_LENS)
	flash.global_position = lens_world
	var want := cam.global_position - cam.global_transform.basis.z * 16.0
	flash_target = flash_target.lerp(want, minf(1.0, 14.0 * dt))
	if flash_target.distance_to(lens_world) > 0.01:
		flash.look_at(flash_target, Vector3.UP)

# An event makes the torch stutter for `secs` seconds
func trigger_flicker(secs: float) -> void:
	flash_flicker.timer = 0.0
	flash_flicker.active = true
	flash_flicker.step = 0.0
	flicker_left = secs

var flicker_left := 0.0

func _contact_flicker(dt: float) -> float:
	var fl := flash_flicker
	fl.timer -= dt
	if fl.timer > 0.0: return 1.0
	if not fl.active:
		fl.active = true
		fl.step = 0.0
	fl.step -= dt
	if fl.step <= 0.0:
		fl.step = 0.03 + randf() * 0.05
		var cut := randf() < 0.4
		fl.value = 0.03 if cut else 0.2 + randf() * 0.8
		var forced := flicker_left > 0.0
		if forced: flicker_left -= fl.step
		if (forced and flicker_left <= 0.0) or (not forced and randf() < 0.08):
			flicker_left = 0.0
			fl.active = false
			fl.value = 1.0
			fl.timer = 9.0 + randf() * 18.0
	return fl.value

# ---- sanity: darkness drains it, safe light restores it (web SANITY values) ----
func _update_sanity(dt: float) -> void:
	var lvl: float = get_parent().get_node("Level").tube_light_at(global_position)
	if flash_on and battery > 0.0: lvl = minf(1.0, lvl + 0.3)
	light_level = lerpf(light_level, lvl, minf(1.0, dt * 3.0))
	if light_level < 0.22:
		var dark_ratio := 1.0 - light_level / 0.22
		sanity = maxf(0.0, sanity - (0.8 + dark_ratio * (4.2 - 0.8)) * dt)
	elif light_level >= 0.45:
		var rec := minf(1.0, (light_level - 0.45) / 0.55)
		sanity = minf(100.0, sanity + 2.2 * (0.4 + 0.6 * rec) * dt)

# Recorded carpet footfall (sfx.js footstep): never the same take twice in a row, slight level /
# pitch / tone variation, quieter and darker when crouching, 180 ms minimum gap.
var last_step_idx := -1

func _footstep(sprint: bool, crouch: bool, intensity: float) -> void:
	var t := Time.get_ticks_msec() / 1000.0
	if t - last_step_time < 0.18: return
	last_step_time = t
	var list := sprint_sounds if sprint else walk_sounds
	var idx := randi() % list.size()
	while idx == last_step_idx and list.size() > 1: idx = randi() % list.size()
	last_step_idx = idx
	var level := 0.05 if crouch else (0.2 if sprint else 0.14)
	step_player.stream = list[idx]
	step_player.volume_linear = level * randf_range(0.85, 1.1) * intensity
	step_player.pitch_scale = (0.92 if crouch else 1.0) * randf_range(0.96, 1.04)
	# the recorded scuffs are all top end: a heel knock underneath gives the step its weight, more of it
	# when you run, hardly any creeping. The two feet never land quite alike.
	foot = -foot
	heel_player.stream = heel_sound
	heel_player.volume_linear = level * (0.45 if sprint else (0.15 if crouch else 0.32)) * randf_range(0.8, 1.1) * intensity
	heel_player.pitch_scale = randf_range(0.9, 1.1) * (0.96 if foot < 0.0 else 1.02) * (0.9 if sprint else 1.0)
	var au := get_parent().get_node_or_null("Audio")
	if au != null:
		au.step_foot(foot)
	var bus := AudioServer.get_bus_index("Steps")
	if bus >= 0:
		var lp := AudioServer.get_bus_effect(bus, 0) as AudioEffectLowPassFilter
		var want := 2500.0 if crouch else 12000.0
		if lp and lp.cutoff_hz != want: lp.cutoff_hz = want      # only on change: re-setting it clicks
	step_player.play()
	heel_player.play()

## Player gasps in fright (e.g. when seized or startled by an entity)
func gasp() -> void:
	var sc: Node = get_parent().get_node_or_null("Scares")
	if sc != null and sc.has_method("gasp"):
		sc.gasp()

