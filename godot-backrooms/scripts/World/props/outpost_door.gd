extends Node3D
## The T.S.R.A. outpost's powered door: a pair of steel leaves with bulletproof vision panels that slide apart
## into the wall on their own when you come up to it, from either side, and slide shut behind you. A door
## opening of a wall of the graph with style "outpost" (wall_graph.gd OPENINGS "door", the level editor's
## "Outpost wall + door"), built by level_geometry.gd _build_openings in the opening's frame (wall_openings.gd
## frame_of: +x across the wall, +z along it, y up from the floor). Only the player works it: the opening is no
## way through for the monsters' paths (a door is not "walk"), and nothing else trips its sensor. Its own steel
## frame, the operator housing over it on both faces with a status lamp (red shut, green open).

const BulletGlass := preload("res://scripts/World/props/bullet_glass.gd")
const OutpostGlazing := preload("res://scripts/World/props/outpost_glazing.gd")

const LEAF_T := 0.05
const FRAME := 0.07                    # the steel lining's face width
const LIP := 0.05                      # its casing lap over each face
const SENSE := 2.4                     # metres from the door's middle (either side) that opens it
const OPEN_TIME := 0.9                 # s, shut to open (and back)
const HOLD := 1.2                      # s it stays open once you are out of range
const MOTOR := "res://audio/world/doors/door_latch.wav"

var w := 1.8                           # the clear opening between the jambs
var hh := 2.3
var depth := 0.3
var leaves: Array[AnimatableBody3D] = []
var open_t := 0.0                      # 0 shut .. 1 open
var _want := false
var _hold := 0.0
var lamps: Array[StandardMaterial3D] = []
var motor: AudioStreamPlayer3D

## `xf`: the opening's frame, `clear`: its width (metres), `h_top`: its head, `wall_d`: the wall's thickness
static func make(xf: Transform3D, clear: float, h_top: float, wall_d: float) -> Node3D:
	var d := new()
	d.transform = xf
	d.w = clear
	d.hh = h_top
	d.depth = wall_d
	d._build()
	return d

func _build() -> void:
	var steel := OutpostGlazing._mat("steel")
	var dd := depth + 0.02
	var face := depth * 0.5 + 0.006
	_box(Vector3(0, hh - FRAME * 0.5, 0), Vector3(dd, FRAME, w), steel)                   # the head
	for s: float in [-1.0, 1.0]:
		# the jambs, slotted down the middle where the leaves run into the wall
		for side: float in [-1.0, 1.0]:
			_box(Vector3(side * (dd + LEAF_T + 0.02) * 0.25, hh * 0.5, s * (w - FRAME) * 0.5), Vector3((dd - LEAF_T - 0.02) * 0.5, hh, FRAME), steel)
		for side: float in [-1.0, 1.0]:
			_box(Vector3(side * face, hh * 0.5, s * (w + LIP) * 0.5), Vector3(0.012, hh + LIP, LIP), steel)
	for side: float in [-1.0, 1.0]:
		# the operator housing over the door on this face, and its status lamp
		_box(Vector3(side * (face + 0.06), hh + LIP + 0.09, 0), Vector3(0.12, 0.18, w + LIP * 2.0 + 0.3), steel)
		var lamp := StandardMaterial3D.new()
		lamp.emission_enabled = true
		lamp.albedo_color = Color(0.1, 0.02, 0.02)
		lamps.append(lamp)
		_box(Vector3(side * (face + 0.122), hh + LIP + 0.09, 0), Vector3(0.006, 0.05, 0.12), lamp)
	# the leaves: steel, a vision panel of the outpost's glass, a kick plate
	var lw := w * 0.5 + 0.015
	for k in 2:
		var body := AnimatableBody3D.new()
		body.sync_to_physics = false
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(LEAF_T, hh - FRAME, lw)
		cs.shape = bs
		cs.position = Vector3(0, (hh - FRAME) * 0.5, 0)
		body.add_child(cs)
		var gy0 := 1.0
		var gy1 := hh - FRAME - 0.18
		var rail := 0.12
		for b: Array in [[Vector3(0, gy0 * 0.5, 0), Vector3(LEAF_T, gy0, lw)],
				[Vector3(0, (gy1 + hh - FRAME) * 0.5, 0), Vector3(LEAF_T, hh - FRAME - gy1, lw)],
				[Vector3(0, (gy0 + gy1) * 0.5, (lw - rail) * 0.5), Vector3(LEAF_T, gy1 - gy0, rail)],
				[Vector3(0, (gy0 + gy1) * 0.5, -(lw - rail) * 0.5), Vector3(LEAF_T, gy1 - gy0, rail)]]:
			_box(b[0], b[1], steel, body)
		_box(Vector3(0, (gy0 + gy1) * 0.5, 0), Vector3(0.02, gy1 - gy0, lw - rail * 2.0), BulletGlass.material(), body)
		for side: float in [-1.0, 1.0]:
			_box(Vector3(side * (LEAF_T * 0.5 + 0.002), 0.15, 0), Vector3(0.004, 0.3, lw - 0.04), OutpostGlazing._mat("bolt"), body)
		add_child(body)
		leaves.append(body)
	motor = AudioStreamPlayer3D.new()
	motor.stream = load(MOTOR)
	motor.unit_size = 3.0
	motor.max_distance = 18.0
	motor.pitch_scale = 0.55
	motor.position = Vector3(0, hh, 0)
	add_child(motor)
	_place()

func _box(c: Vector3, s: Vector3, m: Material, parent: Node3D = self) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = s
	mi.mesh = bm
	mi.material_override = m
	mi.position = c
	parent.add_child(mi)

## The leaves where open_t puts them: shut they meet in the middle, open they are in the wall either side
func _place() -> void:
	var e := open_t * open_t * (3.0 - 2.0 * open_t)
	var lw := w * 0.5 + 0.015
	for k in leaves.size():
		var s := -1.0 if k == 0 else 1.0
		leaves[k].position = Vector3(0, 0, s * (lw * 0.5 - 0.0075 + e * (lw - 0.05)))
	for l in lamps:
		var c := Color(0.15, 1.0, 0.3) if open_t > 0.5 else Color(1.0, 0.12, 0.08)
		l.emission = c
		l.emission_energy_multiplier = 2.0

func _physics_process(delta: float) -> void:
	var p := Game.player as Node3D
	var near := false
	if p != null and is_instance_valid(p):
		var local := to_local(p.global_position)
		near = Vector2(local.x, local.z).length() < SENSE and local.y > -1.0 and local.y < hh + 1.0
	if near: _hold = HOLD
	else: _hold = maxf(0.0, _hold - delta)
	var want := _hold > 0.0
	if want != _want:
		_want = want
		if motor.stream != null: motor.play()
	var t := move_toward(open_t, 1.0 if want else 0.0, delta / OPEN_TIME)
	if t != open_t:
		open_t = t
		_place()
