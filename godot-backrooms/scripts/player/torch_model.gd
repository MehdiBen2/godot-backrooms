extends Node3D
## The torch in your hand (models/flashlight.glb), low-right in view: raised while it is on, swings
## with your stride, dips while you sprint. A child of the camera, built by the player.

const MODEL := "res://models/flashlight.glb"
const LENGTH := 0.27
const POS := Vector3(0.2, -0.2, -0.38)
const ROT := Vector3(0.16, 0.14, 0.0)

var raise := 0.0
var lower := 0.0

func _init() -> void:
	name = "TorchModel"
	position = POS
	rotation = ROT
	visible = false

## Load the model and fit it: long axis down -Z, LENGTH long, centred on the fist. False if missing.
func build() -> bool:
	var scn := load(MODEL) as PackedScene
	if scn == null:
		return false
	var wrap := Node3D.new()
	add_child(wrap)
	var inner := scn.instantiate() as Node3D
	wrap.add_child(inner)
	# merge the mesh bounds (in wrap space) to find the long axis and centre
	var box := AABB()
	var first := true
	for n in inner.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var b := wrap.global_transform.affine_inverse() * mi.global_transform * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	if first:
		return false
	var size := box.size
	var axis := 0 if (size.x >= size.y and size.x >= size.z) else (1 if size.y >= size.z else 2)
	var scale_f := LENGTH / maxf(0.0001, size[axis])
	inner.scale = Vector3.ONE * scale_f
	inner.position = -box.get_center() * scale_f
	if axis == 0: wrap.rotation.y = PI / 2.0
	elif axis == 1: wrap.rotation.x = -PI / 2.0
	return true

## `bob`: the head-bob phase (the swing follows your stride)
func update(dt: float, shown: bool, sprinting: bool, moving: bool, bob: float) -> void:
	visible = shown
	if not shown:
		raise = 0.0
		return
	raise = minf(1.0, raise + dt * 3.0)
	lower += ((1.0 if sprinting else 0.0) - lower) * minf(1.0, dt * 8.0)
	var down := (1.0 - raise) * (1.0 - raise)
	var step := sin(bob) if moving else 0.0
	var breathe := sin(Time.get_ticks_msec() * 0.0016) * 0.003
	position = Vector3(
		POS.x + step * 0.01 - lower * 0.03,
		POS.y + absf(step) * 0.008 + breathe - down * 0.3 - lower * 0.03,
		POS.z)
	rotation = Vector3(ROT.x - lower * 0.35 + step * 0.01, ROT.y + lower * 0.25, ROT.z + step * 0.02)
