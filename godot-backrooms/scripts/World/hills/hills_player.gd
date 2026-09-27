extends CharacterBody3D
## Minimal first-person walker for the hills level: WASD, Shift sprint, Space jump, Esc frees the mouse.

const WALK := 4.2
const SPRINT := 8.0
const JUMP := 4.6
const SENS := 0.0025

var cam: Camera3D
var pitch := 0.0

func _ready() -> void:
	var shape := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.35
	cap.height = 1.8
	shape.shape = cap
	shape.position.y = 0.9
	add_child(shape)
	cam = Camera3D.new()
	cam.position.y = 1.65
	cam.fov = 75.0
	cam.far = 1000.0
	add_child(cam)
	floor_max_angle = deg_to_rad(58.0)
	floor_snap_length = 0.6
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-e.relative.x * SENS)
		pitch = clampf(pitch - e.relative.y * SENS, -1.5, 1.5)
		cam.rotation.x = pitch
	elif e is InputEventKey and e.pressed and not e.echo and e.physical_keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED
	elif e is InputEventMouseButton and e.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(dt: float) -> void:
	var dir := Vector2(
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A)),
		float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W)))
	var speed := SPRINT if Input.is_physical_key_pressed(KEY_SHIFT) else WALK
	var wish := (global_transform.basis * Vector3(dir.x, 0.0, dir.y)).normalized() * speed
	var accel := 14.0 if is_on_floor() else 3.0
	velocity.x = move_toward(velocity.x, wish.x, accel * dt * speed)
	velocity.z = move_toward(velocity.z, wish.z, accel * dt * speed)
	if is_on_floor():
		if Input.is_physical_key_pressed(KEY_SPACE):
			velocity.y = JUMP
	else:
		velocity.y -= 12.0 * dt
	move_and_slide()
