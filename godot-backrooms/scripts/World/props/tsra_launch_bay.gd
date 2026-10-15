extends Node3D
## The T.S.R.A. hub's launch bay: everything that makes levels/tsra_hub.lvl more than a concrete hall, stood up
## from its "hub" block (tools/gen_tsra_hub.py) by level_builder.gd in place of an exit door and scattered pickups.
##
##   the threshold           the back-wall alcove's facade (concrete jambs and header), its steel frame, the
##                           roller shutter that slides up when the lever is pulled, and in it the gate
##                           (tsra_portal_gate.gd, bare): the glowing threshold itself
##   the office partition    the office's front: a sill wall, a wide open window with its posts, a doorway
##   linings                 wallpaper on the office's and the alcove's own walls
##   the launch console      models/props/tsra/tsra_console.glb, with on its MOUNT_ markers
##     the field terminal    terminal_machine.gd
##     the lever panel       tsra_emergency_panel.gd
##   wall signs              models/props/tsra/tsra_sign.glb
##
## The sequence: [E] on the lever panel -> the lever swings down, the shutter rolls up -> the panel charges, the
## gate charging with it -> charged: the threshold tears open -> walk into it -> the next level in the playlist
## (Game.next_level()).

const Prop := preload("res://scripts/World/props/industrial_prop.gd")
const Gate := preload("res://scripts/World/props/tsra_portal_gate.gd")
const LeverPanel := preload("res://scripts/World/props/tsra_emergency_panel.gd")
const TerminalMachine := preload("res://scripts/World/props/terminal_machine.gd")
const CONSOLE := "res://models/props/tsra/tsra_console.glb"
const SIGN := "res://models/props/tsra/tsra_sign.glb"
const CELL := 4.5
const WALL_H := 5.4
const FACADE := 0.3           # the threshold's facade and the office partition: this thick
const PORTAL_BACK := -0.9     # the glowing threshold stands this far into the alcove
const SHUTTER_TIME := 4.5
const STEEL := Color(0.2, 0.215, 0.21)
const TRIM := Color(0.62, 0.63, 0.6)

var gate: Node3D
var panel: Node3D
var console: Node3D
var terminal: Node3D
var shutter: Node3D
var _leaving := false
var _mats := {}

## `hub`: the .lvl's "hub" block
func setup(hub: Dictionary) -> void:
	var g = hub.get("gate")
	if g is Array and g.size() >= 3:
		var th: Dictionary = hub.get("threshold", {})
		gate = Gate.new()
		gate.name = "ThresholdGate"
		if not th.is_empty():
			gate.make_bare(float(th.get("w", 3.4)), float(th.get("h", 3.3)), PORTAL_BACK)
		_place(gate, g)
		add_child(gate)
		gate.entered.connect(_through)
		if not th.is_empty():
			_build_threshold(g, float(th.get("w", 3.4)), float(th.get("h", 3.3)))

	var o = hub.get("office")
	if o is Dictionary:
		_build_office(o)
	for lining in hub.get("linings", []):
		_line(str(lining.get("pbr", "")), lining.get("faces", []))

	var c = hub.get("console")
	if c is Array and c.size() >= 3:
		console = Prop._instance(CONSOLE)
		if console:
			console.name = "LaunchConsole"
			_place(console, c)
			add_child(console)
			terminal = TerminalMachine.new()
			terminal.name = "FieldTerminal"
			_mount(terminal, "MOUNT_terminal")
			panel = LeverPanel.new()
			panel.name = "LeverPanel"
			_mount(panel, "MOUNT_lever")
			panel.pulled.connect(_on_pulled)
			panel.charged.connect(_on_charged)

	for s in hub.get("signs", []):
		if not (s is Array and s.size() >= 3):
			continue
		var plate := Prop._instance(SIGN)
		if plate == null:
			continue
		_place(plate, s)
		plate.position.y = float(s[3]) if s.size() > 3 else 1.2
		plate.scale = Vector3.ONE * (float(s[4]) if s.size() > 4 else 1.0)
		add_child(plate)

# ---------------------------------------------------------------- the built pieces
## The back-wall alcove's front: concrete jambs and header round a `w` x `h` opening, a steel frame proud of the
## wall, and the roller shutter just behind the facade (it rises into the alcove's ceiling)
func _build_threshold(at: Array, w: float, h: float) -> void:
	var root := Node3D.new()
	root.name = "Threshold"
	_place(root, at)
	add_child(root)
	var con := _mat("Concrete_Panels")
	var steel := _plain(STEEL, 0.55, 0.45)
	var jamb := CELL * 0.5 - w * 0.5
	var zc := -FACADE * 0.5
	for sx in [-1.0, 1.0]:
		_box(root, Vector3(jamb, WALL_H, FACADE), Vector3(sx * (w * 0.5 + jamb * 0.5), WALL_H * 0.5, zc), con, true)
	_box(root, Vector3(w, WALL_H - h, FACADE), Vector3(0.0, (WALL_H + h) * 0.5, zc), con, true)
	# the frame: posts and a head proud of the wall, steel reveals lining the opening, a sill plate
	var fw := 0.24
	var fd := 0.16
	for sx in [-1.0, 1.0]:
		_box(root, Vector3(fw, h + fw, fd), Vector3(sx * (w * 0.5 + fw * 0.5), (h + fw) * 0.5, fd * 0.5), steel, true)
		_box(root, Vector3(0.04, h, FACADE), Vector3(sx * (w * 0.5 - 0.02), h * 0.5, zc), steel, false)
	_box(root, Vector3(w + 2.0 * fw, fw, fd), Vector3(0.0, h + fw * 0.5, fd * 0.5), steel, false)
	_box(root, Vector3(w, 0.04, FACADE), Vector3(0.0, h - 0.02, zc), steel, false)
	_box(root, Vector3(w + 2.0 * fw, 0.012, FACADE + fd), Vector3(0.0, 0.006, (fd - FACADE) * 0.5), _plain(TRIM, 0.7, 0.35), false)
	# the shutter: ribbed slats and a heavy bottom bar, its own collision riding up with it
	shutter = Node3D.new()
	shutter.name = "Shutter"
	shutter.position = Vector3(0.0, 0.0, -FACADE - 0.05)
	root.add_child(shutter)
	var slat := _plain(Color(0.46, 0.47, 0.46), 0.6, 0.5)
	var rib := _plain(Color(0.34, 0.35, 0.34), 0.6, 0.55)
	var y := 0.12
	while y < h + 0.3:
		_box(shutter, Vector3(w + 0.1, 0.085, 0.04), Vector3(0.0, y + 0.0425, 0.0), slat, false)
		_box(shutter, Vector3(w + 0.1, 0.015, 0.025), Vector3(0.0, y + 0.0925, 0.012), rib, false)
		y += 0.1
	_box(shutter, Vector3(w + 0.1, 0.12, 0.07), Vector3(0.0, 0.06, 0.0), steel, false)
	_box(shutter, Vector3(w, h, 0.1), Vector3(0.0, h * 0.5, 0.0), null, true)

func _raise_shutter() -> void:
	if shutter == null or shutter.position.y > 0.01:
		return
	var tw := create_tween()
	tw.tween_property(shutter, "position:y", WALL_H + 0.3, SHUTTER_TIME).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

## The office's front along z (cells): a sill wall under a wide window cut in it, a header over it, a doorway near
## its east end, all in the hall's concrete; aluminium trim and posts round the window; a warm lamp inside
func _build_office(o: Dictionary) -> void:
	var root := Node3D.new()
	root.name = "OfficePartition"
	add_child(root)
	var con := _mat("Concrete_Panels")
	var trim := _plain(TRIM, 0.4, 0.4)
	var xs: Array = o.get("x", [0.5, 2.5])
	var x0 := float(xs[0]) * CELL
	var x1 := float(xs[1]) * CELL
	var z := float(o.get("z", 1.5)) * CELL - FACADE * 0.5     # flush with the back wall's face, the office side
	var win: Array = o.get("window", [])
	var door: Array = o.get("door", [])
	var sill := float(o.get("sill", 1.0))
	var head := float(o.get("head", 2.45))
	var door_h := 2.2
	var wx0 := float(win[0]) * CELL if win.size() == 2 else x1
	var wx1 := float(win[1]) * CELL if win.size() == 2 else x1
	var dx0 := float(door[0]) * CELL if door.size() == 2 else x1
	var dx1 := float(door[1]) * CELL if door.size() == 2 else x1
	for p in [[x0, wx0, 0.0, WALL_H], [wx0, wx1, 0.0, sill], [wx0, wx1, head, WALL_H], [wx1, dx0, 0.0, WALL_H],
			[dx0, dx1, door_h, WALL_H], [dx1, x1, 0.0, WALL_H]]:
		var a: float = p[0]
		var b: float = p[1]
		if b - a > 0.001:
			_box(root, Vector3(b - a, p[3] - p[2], FACADE), Vector3((a + b) * 0.5, (p[2] + p[3]) * 0.5, z), con, true)
	if wx1 > wx0:
		var ww := wx1 - wx0
		var mid := (wx0 + wx1) * 0.5
		_box(root, Vector3(ww + 0.1, 0.04, FACADE + 0.1), Vector3(mid, sill + 0.02, z), trim, false)    # the sill ledge
		_box(root, Vector3(ww, 0.05, FACADE + 0.02), Vector3(mid, head - 0.025, z), trim, false)
		for sx in [wx0 + 0.025, wx1 - 0.025]:
			_box(root, Vector3(0.05, head - sill, FACADE + 0.02), Vector3(sx, (sill + head) * 0.5, z), trim, false)
		var posts := maxi(1, roundi(ww / 2.1)) - 1
		for i in posts:
			var px := wx0 + ww * float(i + 1) / float(posts + 1)
			_box(root, Vector3(0.08, head - sill, 0.12), Vector3(px, (sill + head) * 0.5, z), trim, true)
		# the window is open but not a way through: an unseen pane keeps the player on their side
		_box(root, Vector3(ww, head - sill, 0.05), Vector3(mid, (sill + head) * 0.5, z), null, true)
	if dx1 > dx0:
		for sx in [dx0 + 0.03, dx1 - 0.03]:
			_box(root, Vector3(0.06, door_h, FACADE + 0.04), Vector3(sx, door_h * 0.5, z), trim, false)
		_box(root, Vector3(dx1 - dx0, 0.06, FACADE + 0.04), Vector3((dx0 + dx1) * 0.5, door_h - 0.03, z), trim, false)
	var lp = o.get("light")
	if lp is Array and lp.size() >= 2:
		var lamp := OmniLight3D.new()
		lamp.name = "OfficeLamp"
		lamp.light_color = Color(1.0, 0.8, 0.46)
		lamp.light_energy = 2.2
		lamp.omni_range = 8.0
		lamp.omni_attenuation = 0.8
		lamp.shadow_enabled = true
		lamp.position = Vector3(float(lp[0]) * CELL, WALL_H - 1.1, float(lp[1]) * CELL)
		root.add_child(lamp)

## Wallpaper `pbr` hung on each [cell x, cell z, dx, dz] face: the side of that open cell toward (dx, dz)
func _line(pbr: String, faces: Array) -> void:
	var m := _mat(pbr)
	if m == null:
		return
	for f in faces:
		if not (f is Array and f.size() >= 4):
			continue
		var d := Vector3(float(f[2]), 0.0, float(f[3]))
		var c := Vector3(float(f[0]) * CELL, WALL_H * 0.5, float(f[1]) * CELL) + d * (CELL * 0.5 - 0.012)
		var size := Vector3(0.02, WALL_H, CELL) if d.x != 0.0 else Vector3(CELL, WALL_H, 0.02)
		_box(self, size, c, m, false)

## A textures/pbr material as the level lays it (world triplanar, the walls' scale), so seams meet the walls'
func _mat(id: String) -> Material:
	if _mats.has(id):
		return _mats[id]
	var m: Material = null
	var lvl := get_parent()
	if lvl and lvl.has_method("_pbr_by_id") and ResourceLoader.exists("res://textures/pbr/%s/%s.tres" % [id, id]):
		m = lvl.call("_pbr_by_id", id)
	_mats[id] = m
	return m

func _plain(c: Color, metal: float, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = metal
	m.roughness = rough
	return m

## A box `size` at `pos` under `parent`; a null `mat` draws nothing. `solid`: a static body with its shape
func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material, solid: bool) -> void:
	if mat:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = size
		mi.mesh = bm
		mi.material_override = mat
		mi.position = pos
		parent.add_child(mi)
	if solid:
		var body := StaticBody3D.new()
		var shape := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = size
		shape.shape = bs
		body.position = pos
		body.add_child(shape)
		parent.add_child(body)

## [x, z, yaw]: cells and degrees (0 faces +Z)
func _place(n: Node3D, at: Array) -> void:
	n.position = Vector3(float(at[0]) * CELL, 0.0, float(at[1]) * CELL)
	n.rotation.y = deg_to_rad(float(at[2]))

## Stand `n` where the console's marker `marker` is, turned the way it is
func _mount(n: Node3D, marker: String) -> void:
	var m := console.find_child(marker, true, false) as Node3D
	add_child(n)
	if m:
		n.global_transform = Transform3D(console.global_basis.orthonormalized(), m.global_position)
	else:
		n.global_transform = console.global_transform
		push_warning("tsra_launch_bay: %s has no %s" % [CONSOLE, marker])

func _process(_dt: float) -> void:
	if gate and panel and panel.get("state") == LeverPanel.Screen.CHARGING:
		gate.set_charge(float(panel.get("charge")))

func _on_pulled() -> void:
	if gate: gate.set_charge(0.0)
	_raise_shutter()

func _on_charged() -> void:
	_raise_shutter()
	if gate:
		gate.set_charge(1.0)
		gate.open_portal()

func _through() -> void:
	if _leaving:
		return
	_leaving = true
	Game.next_level.call_deferred()      # (not from inside the gate's own signal: the level change frees it)
