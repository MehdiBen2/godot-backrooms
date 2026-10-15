extends Node3D
## The threshold gate in the T.S.R.A. hub's launch bay: the portal frame (models/props/tsra/tsra_portal_frame.glb,
## tools/blender/build_tsra_portal_frame.py) on its base (tsra_gate.glb: platform, charge coils, orbit ring,
## tools/blender/build_tsra_gate.py), and in the frame's doorway the threshold itself, a quad drawn by
## shaders/tsra_portal.gdshader just in front of the doorway's closed back. Faces +Z; its origin is the platform's
## middle on the floor.
##
## The launch bay drives it: set_charge(k) while the lever panel charges (the hairline flickers in, the pylons'
## strips and the coils' bands brighten, the orbit ring precesses faster), open_portal() tears the threshold open.
## Once it is open, the local player walking into the doorway fires `entered`.

signal entered

const Prop := preload("res://scripts/World/props/industrial_prop.gd")
const MODEL := "res://models/props/tsra/tsra_gate.glb"
const FRAME := "res://models/props/tsra/tsra_portal_frame.glb"
const SHADER := preload("res://shaders/tsra_portal.gdshader")
const AMBER := Color("f0a838")

# the frame's doorway, as build_tsra_portal_frame.py measures it (from the frame's feet). A bare gate (set before
# it enters the tree) has no platform and no frame: whoever builds round it sizes the opening with these.
var bare := false
var PLATFORM_H := 0.1
var OPEN_W := 2.07
var OPEN_H := 3.28
var SILL := 0.46              # the doorway's floor is raised this far
var BACK_Z := -0.424          # its closed back
var FRONT_Z := 1.236          # the frame's front face
const ORBIT_TILT := deg_to_rad(9.0)
const OPEN_TIME := 2.4
const WALK_IN := 0.65         # m: this far in from the doorway's back and you are through

var portal: MeshInstance3D
var portal_mat: ShaderMaterial
var glow_mat: StandardMaterial3D
var orbit: Node3D
var light: OmniLight3D
var charge := 0.0
var open := 0.0
var is_open := false
var _spin := 0.0
var _used := false
var _tw: Tween

## A bare threshold `w` x `h` m standing on the floor, its glowing face `back` m behind the origin (negative: in)
func make_bare(w: float, h: float, back: float) -> void:
	bare = true
	PLATFORM_H = 0.0
	SILL = 0.0
	OPEN_W = w
	OPEN_H = h
	BACK_Z = back
	FRONT_Z = 0.0

func _ready() -> void:
	if not bare:
		var model := Prop._instance(MODEL)
		if model:
			add_child(model)
			orbit = model.find_child("Orbit", true, false) as Node3D
			_take_glow(model)
		var frame := Prop._instance(FRAME)
		if frame:
			frame.position.y = PLATFORM_H
			add_child(frame)

	portal_mat = ShaderMaterial.new()
	portal_mat.shader = SHADER
	portal_mat.set_shader_parameter("portal_size", Vector2(OPEN_W, OPEN_H))
	var q := QuadMesh.new()
	q.size = Vector2(OPEN_W, OPEN_H)
	portal = MeshInstance3D.new()
	portal.mesh = q
	portal.material_override = portal_mat
	portal.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	portal.position = Vector3(0.0, PLATFORM_H + SILL + OPEN_H * 0.5, BACK_Z + 0.02)
	add_child(portal)

	light = OmniLight3D.new()
	light.light_color = Color(1.0, 0.82, 0.45)
	light.omni_range = 11.0
	light.light_energy = 0.0
	light.shadow_enabled = true
	light.position = Vector3(0.0, PLATFORM_H + SILL + OPEN_H * 0.5, FRONT_Z + 0.4)
	add_child(light)
	_apply()

## The material the model calls "GateGlow" (the pylons' strips, the coils' bands), one copy for all of them
func _take_glow(model: Node) -> void:
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(i)
			if m is StandardMaterial3D and m.resource_name == "GateGlow":
				if glow_mat == null:
					glow_mat = (m as StandardMaterial3D).duplicate()
					glow_mat.emission_enabled = true
				mi.set_surface_override_material(i, glow_mat)

func set_charge(k: float) -> void:
	charge = clampf(k, 0.0, 1.0)

func open_portal() -> void:
	if is_open:
		return
	is_open = true
	_used = false
	if _tw: _tw.kill()
	_tw = create_tween()
	_tw.tween_property(self, "open", 1.0, OPEN_TIME).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN_OUT)

func close_portal() -> void:
	is_open = false
	if _tw: _tw.kill()
	_tw = create_tween()
	_tw.tween_property(self, "open", 0.0, 1.2).set_trans(Tween.TRANS_SINE)
	charge = 0.0

func _process(dt: float) -> void:
	# the ring: idle it drifts round, charging it whirls, open it settles to a steady turn
	var speed := 0.15 + 3.2 * charge * (1.0 - open) + 1.1 * open
	_spin += speed * dt
	if orbit:
		orbit.basis = Basis(Vector3.UP, _spin) * Basis(Vector3.RIGHT, ORBIT_TILT * (1.0 + 0.6 * charge))
	_apply()

func _physics_process(_dt: float) -> void:
	if not is_open or _used or open < 0.85:
		return
	var p: Node3D = Game.player
	if p == null or not is_instance_valid(p):
		return
	var local := to_local(p.global_position)
	if absf(local.x) < OPEN_W * 0.5 and local.z < BACK_Z + WALK_IN and local.y < PLATFORM_H + SILL + OPEN_H:
		_used = true
		entered.emit()

func _apply() -> void:
	portal_mat.set_shader_parameter("open", open)
	portal_mat.set_shader_parameter("charge", charge)
	portal.visible = open > 0.0 or charge > 0.0
	var pulse := 0.85 + 0.15 * sin(Time.get_ticks_msec() * 0.001 * (3.0 + 18.0 * charge))
	if glow_mat:
		glow_mat.emission_energy_multiplier = (0.6 + 5.0 * charge * pulse) * (1.0 - open) + 4.0 * open
	light.light_energy = charge * 1.2 * pulse * (1.0 - open) + 6.0 * open
