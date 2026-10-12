extends Node3D
## The T.S.R.A. field terminal in the spawn room (level_builder.gd _spawn_survey_props): a 14" Sony PVM CRT on a
## steel equipment cabinet, facing +Z. The PVM's own glass shows the terminal's screen (scripts/UI/terminal_os.gd,
## drawn into a SubViewport here under shaders/terminal_crt.gdshader), lit up by shaders/crt_screen.gdshader.
##
## [E] takes the view: a camera of the terminal's own leaves your eyes and glides in to face the glass, the tube
## blinks off and warms back up, and the terminal boots. Logging off (ESC on its main menu) powers it down and
## glides the view back to your eyes. While you are at it the HUD and your hands are put away, the mouse drives a
## cursor on the glass, and every key goes to the terminal.

const TerminalOS := preload("res://scripts/UI/terminal_os.gd")
const InteractTooltip := preload("res://scripts/World/props/interact_tooltip.gd")
const Prop := preload("res://scripts/World/props/industrial_prop.gd")
const SCREEN_SHADER := preload("res://shaders/crt_screen.gdshader")
const FONT := preload("res://fonts/vcr.ttf")
const CRT_MODEL := "res://models/props/asset_pack/sony_pvm-14l2_crt_tv.glb"

const CABINET := Vector3(0.56, 0.9, 0.5)
# The PVM in its own file (measured off the mesh): it faces +Z, feet at y = -0.006, face at z = 0.012. Its glass
# (40 triangles of the front shell, the top corners reaching out further than the sides) is 0.281 x 0.211 m
# (4:3), its middle 0.189 m up, bowed round a vertical axis (radius 0.645 m) so the sides sit 15 mm back.
const MODEL_FEET := 0.0062
const MODEL_FRONT := 0.0123
const GLASS_W := 0.2809
const GLASS_H := 0.2107
const GLASS_R := 0.645
const GLASS_AT := Vector3(0.0, 0.1887, 0.0037)
const SET_BACK := 0.03                              # the monitor's face sits this far behind the cabinet's

const VIEW_FOV := 50.0
const VIEW_FILL := 0.8          # of the view's height the glass fills once the camera is in front of it
const PAN_IN := 1.1
const PAN_OUT := 0.85
const DRAW_NEAR := 9.0          # m: the idle screen keeps drawing while a camera is this close
const GLOW_IDLE := 0.22
const GLOW_ON := 0.5
const AMBER := Color("f0a838")

const SFX_FILES := {
	"on": ["res://audio/terminal/terminal_on.wav", -12.0],
	"off": ["res://audio/terminal/terminal_off.wav", -12.0],
	"select": ["res://audio/terminal/terminal_select.wav", -17.0],
	"tab": ["res://audio/terminal/terminal_tab.wav", -15.0],
	"scan": ["res://audio/terminal/terminal_scan.wav", -15.0],
	"logged": ["res://audio/terminal/terminal_logged.wav", -14.0],
}

var viewport: SubViewport
var os: TerminalOS
var screen: Node3D              # on the glass's middle, facing out: the camera frames it, the mouse is read off it
var screen_mat: ShaderMaterial
var glow: OmniLight3D
var led: MeshInstance3D
var cam: Camera3D
var tip: Node3D
var player: Node3D = null       # while someone is at the terminal
var session := false
var busy := false               # panning or switching the tube: keys and clicks wait
var tw: Tween
var hud_was := false
var sfx := {}
var check_t := 0.0
var t := 0.0

func _ready() -> void:
	_build_cabinet()
	var crt := Prop._instance(CRT_MODEL)
	var crt_at := Vector3(0.0, CABINET.y + MODEL_FEET, CABINET.z * 0.5 - SET_BACK - MODEL_FRONT)
	if crt:
		crt.position = crt_at
		add_child(crt)

	viewport = SubViewport.new()
	viewport.size = TerminalOS.SIZE
	viewport.disable_3d = true
	viewport.transparent_bg = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	os = TerminalOS.new()
	viewport.add_child(os)
	os.sfx.connect(play_sfx)
	os.logged_off.connect(_log_off)

	screen_mat = ShaderMaterial.new()
	screen_mat.shader = SCREEN_SHADER
	screen_mat.set_shader_parameter("screen_tex", viewport.get_texture())
	screen = Node3D.new()
	screen.position = crt_at + GLASS_AT
	add_child(screen)
	# the shader follows the view through the faceplate to the phosphor behind it, in the glass's own terms
	screen_mat.set_shader_parameter("glass_size", Vector2(GLASS_W, GLASS_H))
	screen_mat.set_shader_parameter("to_glass", screen.global_basis.inverse())
	if not (crt and _light_glass(crt)):
		var sheet := MeshInstance3D.new()      # no model, or no glass in it: a bowed sheet where the glass would be
		sheet.mesh = _glass_mesh()
		sheet.material_override = screen_mat
		sheet.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		screen.add_child(sheet)

	glow = OmniLight3D.new()
	glow.light_color = AMBER
	glow.light_energy = GLOW_IDLE
	glow.omni_range = 2.6
	glow.light_specular = 0.0          # it lights the room; it must not shine back off its own glass
	glow.position = screen.position + Vector3(0.0, 0.05, 0.5)
	add_child(glow)

	cam = Camera3D.new()
	cam.near = 0.02
	add_child(cam)

	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	var top := CABINET.y + 0.34
	box.size = Vector3(CABINET.x, top, CABINET.z)
	shape.shape = box
	shape.position.y = top * 0.5
	body.add_child(shape)
	add_child(body)

	tip = InteractTooltip.new()
	tip.name = "InteractTooltip"
	tip.height = 1.45
	add_child(tip)

	for k in SFX_FILES:
		var sp := AudioStreamPlayer.new()
		sp.stream = load(SFX_FILES[k][0])
		sp.volume_db = SFX_FILES[k][1]
		add_child(sp)
		sfx[k] = sp

	os.standby()
	_raster(Vector2(0.5, 0.5))

## A steel equipment cabinet in agency olive: plinth, body, a lipped top the monitor stands on, a recessed front
## panel with vent slats, a stencilled designation and a status lamp
func _build_cabinet() -> void:
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.2, 0.21, 0.17)
	steel.metallic = 0.55
	steel.roughness = 0.6
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.07, 0.075, 0.065)
	dark.metallic = 0.4
	dark.roughness = 0.75
	var front := CABINET.z * 0.5
	_box(Vector3(CABINET.x - 0.04, 0.06, CABINET.z - 0.04), Vector3(0, 0.03, 0), dark)
	_box(Vector3(CABINET.x, CABINET.y - 0.085, CABINET.z), Vector3(0, 0.06 + (CABINET.y - 0.085) * 0.5, 0), steel)
	_box(Vector3(CABINET.x + 0.02, 0.025, CABINET.z + 0.02), Vector3(0, CABINET.y - 0.0125, 0), steel)
	_box(Vector3(CABINET.x - 0.08, 0.5, 0.01), Vector3(0, 0.36, front + 0.002), dark)
	for i in 5:
		_box(Vector3(CABINET.x - 0.2, 0.01, 0.012), Vector3(0, 0.7 + i * 0.024, front + 0.004), dark)
	var label := Label3D.new()
	label.text = "T.S.R.A.   FT-07"
	label.font = FONT
	label.font_size = 48
	label.pixel_size = 0.0007
	label.outline_size = 0
	label.shaded = true
	label.modulate = Color(0.78, 0.62, 0.28)
	label.position = Vector3(0, 0.82, front + 0.002)
	add_child(label)
	led = MeshInstance3D.new()
	var bead := SphereMesh.new()
	bead.radius = 0.006
	bead.height = 0.012
	led.mesh = bead
	var lamp := StandardMaterial3D.new()
	lamp.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lamp.albedo_color = Color(1.6, 0.95, 0.3)
	led.material_override = lamp
	led.position = Vector3(CABINET.x * 0.5 - 0.06, 0.82, front + 0.004)
	add_child(led)

func _box(size: Vector3, at: Vector3, mat: Material) -> void:
	var m := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	m.mesh = b
	m.material_override = mat
	m.position = at
	add_child(m)

## The PVM's own glass carries the picture: the front shell's triangles lying on the tube's bow inside GLASS_W x
## GLASS_H are lifted out of its mesh into a surface of their own, UV-mapped across the glass, with the screen
## material; the rest of the shell keeps its own. False if the file has no such triangles.
func _light_glass(crt: Node3D) -> bool:
	for n in crt.find_children("*front_case*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or mi.mesh.get_surface_count() != 1:
			continue
		var xf := Prop.in_model(mi, crt)
		var arrays := mi.mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var shell := PackedInt32Array()
		var glass := PackedInt32Array()
		for i in range(0, idx.size(), 3):
			var on := true
			for k in 3:
				var p := xf * verts[idx[i + k]] - GLASS_AT
				if absf(p.x) > GLASS_W * 0.5 + 0.004 or absf(p.y) > GLASS_H * 0.5 + 0.004 or absf(p.z - _bow(p.x)) > 0.0025:
					on = false
					break
			if on:
				glass.append_array(idx.slice(i, i + 3))
			else:
				shell.append_array(idx.slice(i, i + 3))
		if glass.is_empty():
			continue
		var uv := PackedVector2Array()
		uv.resize(verts.size())
		for j in verts.size():
			var p := xf * verts[j] - GLASS_AT
			uv[j] = Vector2(p.x / GLASS_W + 0.5, 0.5 - p.y / GLASS_H)
		var shell_mat := mi.get_active_material(0)
		var mesh := ArrayMesh.new()
		var a := arrays.duplicate()
		a[Mesh.ARRAY_INDEX] = shell
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
		mesh.surface_set_material(0, shell_mat)
		var g := arrays.duplicate()
		g[Mesh.ARRAY_INDEX] = glass
		g[Mesh.ARRAY_TEX_UV] = uv
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, g)
		mesh.surface_set_material(1, screen_mat)
		mi.material_override = null
		mi.mesh = mesh
		return true
	return false

## The fallback picture surface: a strip bowed like the PVM's glass, its middle on the origin, UV (0, 0) top left
static func _glass_mesh() -> ArrayMesh:
	const SEG := 24
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in SEG:
		var u0 := float(i) / SEG
		var u1 := float(i + 1) / SEG
		var quad := [[u0, 0.0], [u1, 0.0], [u1, 1.0], [u0, 0.0], [u1, 1.0], [u0, 1.0]]
		for q in quad:
			var x: float = (q[0] - 0.5) * GLASS_W
			var z := _bow(x)
			st.set_normal(Vector3(x, 0.0, z + GLASS_R).normalized())
			st.set_uv(Vector2(q[0], q[1]))
			st.add_vertex(Vector3(x, (0.5 - q[1]) * GLASS_H, z))
	return st.commit()

## How far back the glass is at `x` from its middle
static func _bow(x: float) -> float:
	return -(GLASS_R - sqrt(GLASS_R * GLASS_R - x * x))

# ---------------------------------------------------------------- interaction
func can_interact(_from_pos: Vector3) -> bool:
	return not session

func get_interact_prompt() -> String:
	return "[E] ACCESS"

func get_interact_title() -> String:
	return "T.S.R.A. Terminal"

func interact(p: Node3D) -> bool:
	if session or busy or p == null or not ("cam" in p):
		return false
	player = p
	session = true
	busy = true
	p.frozen = true
	hud_was = Game.hide_hud
	Game.hide_hud = true
	var pc: Camera3D = p.cam
	cam.fov = pc.fov
	cam.far = pc.far
	cam.cull_mask = pc.cull_mask
	cam.environment = pc.environment
	cam.attributes = pc.attributes
	cam.global_transform = pc.global_transform
	cam.make_current()
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var from := cam.global_transform
	var to := _view_xform()
	var fov0 := pc.fov
	if tw: tw.kill()
	tw = create_tween()
	tw.tween_method(func(k: float):
		cam.global_transform = from.interpolate_with(to, k)
		cam.fov = lerpf(fov0, VIEW_FOV, k)
	, 0.0, 1.0, PAN_IN).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tw.tween_callback(_power_on)
	return true

## Square on to the glass, far enough back that it fills VIEW_FILL of the view's height
func _view_xform() -> Transform3D:
	var c := screen.global_position
	var n := screen.global_transform.basis.z.normalized()
	var d := GLASS_H / VIEW_FILL * 0.5 / tan(deg_to_rad(VIEW_FOV) * 0.5)
	return Transform3D(Basis.looking_at(-n, Vector3.UP), c + n * d)

## The standby picture collapses to a line and a dot, a beat of dark glass, then the tube warms up into the boot
func _power_on() -> void:
	play_sfx("on")
	tw = create_tween()
	tw.tween_method(_raster, Vector2(0.5, 0.5), Vector2(0.5, 0.0015), 0.1).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_method(_raster, Vector2(0.5, 0.0015), Vector2(0.0, 0.0015), 0.08)
	tw.tween_callback(os.boot)
	tw.tween_interval(0.3)
	tw.tween_method(_raster, Vector2(0.0, 0.0015), Vector2(0.5, 0.0015), 0.16).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_method(_raster, Vector2(0.5, 0.0015), Vector2(0.5, 0.5), 0.24).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(glow, "light_energy", GLOW_ON, 0.24)
	tw.tween_callback(func():
		busy = false
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	)

## The terminal's ESC on its main menu: power down, come back to standby, glide back to the eyes
func _log_off() -> void:
	if busy or not session:
		return
	busy = true
	os.pointer(Vector2(-1, -1))
	play_sfx("off")
	if tw: tw.kill()
	tw = create_tween()
	tw.tween_method(_raster, Vector2(0.5, 0.5), Vector2(0.5, 0.0015), 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(glow, "light_energy", GLOW_IDLE * 0.4, 0.12)
	tw.tween_method(_raster, Vector2(0.5, 0.0015), Vector2(0.0, 0.0015), 0.1)
	tw.tween_callback(os.standby)
	tw.tween_interval(0.25)
	var pc: Camera3D = player.cam
	var from := _view_xform()
	tw.tween_method(func(k: float):
		if not is_instance_valid(pc): return
		cam.global_transform = from.interpolate_with(pc.global_transform, k)
		cam.fov = lerpf(VIEW_FOV, pc.fov, k)
	, 0.0, 1.0, PAN_OUT).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tw.parallel().tween_method(_raster, Vector2(0.0, 0.0015), Vector2(0.5, 0.5), 0.35).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(glow, "light_energy", GLOW_IDLE, 0.35)
	tw.tween_callback(_end_session)

func _end_session() -> void:
	if player and is_instance_valid(player):
		player.cam.make_current()
		if not player.dead:
			player.frozen = false
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	Game.hide_hud = hud_was
	session = false
	busy = false
	player = null

## Something took you away from the terminal (death, the level going): give the view back at once
func _abort() -> void:
	if tw: tw.kill()
	os.pointer(Vector2(-1, -1))
	os.standby()
	_raster(Vector2(0.5, 0.5))
	glow.light_energy = GLOW_IDLE
	_end_session()

func _exit_tree() -> void:
	if session:
		if tw: tw.kill()
		_end_session()

func _raster(r: Vector2) -> void:
	screen_mat.set_shader_parameter("raster", r)

func play_sfx(k: String) -> void:
	var sp: AudioStreamPlayer = sfx.get(k)
	if sp:
		sp.pitch_scale = randf_range(0.97, 1.03)
		sp.play()

# ---------------------------------------------------------------- input
func _input(e: InputEvent) -> void:
	if not session:
		return
	if e is InputEventKey:
		var k := e as InputEventKey
		if k.pressed and not k.echo and not busy:
			os.key(k.physical_keycode)
		get_viewport().set_input_as_handled()     # every key is the terminal's while you are at it
	elif e is InputEventMouse:
		get_viewport().set_input_as_handled()
		if busy:
			return
		var at := _glass_px(get_viewport().get_mouse_position())
		os.pointer(at)
		if at.x < 0.0:
			return
		var ev := e.duplicate() as InputEventMouse
		ev.position = at
		ev.global_position = at
		viewport.push_input(ev, true)

## Where on the terminal's screen (its pixels) the view's `at` falls on the glass; (-1, -1) off it
func _glass_px(at: Vector2) -> Vector2:
	var inv := screen.global_transform.affine_inverse()
	var o := inv * cam.project_ray_origin(at)
	var d := inv.basis * cam.project_ray_normal(at)
	if absf(d.z) < 0.00001:
		return Vector2(-1, -1)
	var hit := o
	var z := 0.0
	for i in 3:                      # onto the bowed glass: a plane at the depth of the last guess, refined
		hit = o + d * ((z - o.z) / d.z)
		z = _bow(clampf(hit.x, -GLASS_W * 0.5, GLASS_W * 0.5))
	var uv := Vector2(hit.x / GLASS_W + 0.5, 0.5 - hit.y / GLASS_H)
	if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
		return Vector2(-1, -1)
	return uv * Vector2(TerminalOS.SIZE)

# ---------------------------------------------------------------- upkeep
func _process(dt: float) -> void:
	t += dt
	if session:
		if player == null or not is_instance_valid(player) or player.dead:
			_abort()
			return
		# back from the pause menu (it recaptures the mouse on resume): the cursor is the terminal's again
		if not busy and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not get_tree().paused:
			Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
		glow.light_energy = GLOW_ON * (0.94 + 0.06 * sin(t * 47.0) * sin(t * 3.1)) if not busy else glow.light_energy
	if led:
		led.visible = session or fmod(t, 2.0) < 1.0
	# the idle screen only draws while someone could see it
	check_t -= dt
	if check_t <= 0.0 and not session:
		check_t = 0.5
		var c := get_viewport().get_camera_3d()
		var near := c != null and c.global_position.distance_to(screen.global_position) < DRAW_NEAR
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if near else SubViewport.UPDATE_DISABLED
