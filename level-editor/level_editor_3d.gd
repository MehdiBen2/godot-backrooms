extends SubViewportContainer
## The editor's 3D view: the level as simple boxes you can orbit, so you can see walls, floors, painted
## materials, zones and objects at a glance. It is rebuilt from the editor's data (grid, zones, paint,
## objects) whenever something changes while it is open; nothing here is saved.
##   right drag orbit   middle drag / Shift+right drag pan   wheel zoom   WASD pan   C toggles the ceiling
## 1 cell = 1 unit; the game's cell is 4.5 m and its wall 2.7 m, hence WALL_H.
## Objects can be placed and moved here too, where you see them (see "placing" below): with an object tool
## picked in the tool panel a ghost of it follows the mouse over the floor and the walls and a left click
## puts it there; with Select (V) a click picks an object and a drag moves it. Model props (object_types.json
## "model") are shown as their real meshes, read from the game's files, at their real size and height.
##   R turn   Shift+wheel size   Alt+wheel turn 15°   Ctrl+wheel raise / lower   Del delete   Esc let go

const WALL_H := 0.6
const TALL_H := 1.4
const GRAND_H := 2.1
const LOW_H := 0.42
const REBUILD_DELAY := 0.25
const THUMB_PX := 128                    # a prop's picture in the tool panel, square

var ed                                   # the level editor (grid, zones, paint, objects, materials, GAME)
var vp: SubViewport
var world: Node3D
var cam: Camera3D
var hud: Label
var ceiling_check: CheckBox
var target := Vector3.ZERO
var yaw := 0.6
var pitch := -0.9
var dist := 30.0
var stale := true
var _delay := 0.0
## Walk mode (E): the camera at eye height, walking the level at its real proportions (the overview squashes
## heights to half so the floor plan reads from above; walking needs the true 5.4 m walls on 4.5 m cells)
const EYE := 1.6 / 4.5                   # metres -> cells
const WALK_SPEED := 1.1                  # cells a second (about 5 m/s); Shift doubles it
var walking := false
var vscale := 2.0                        # height multiplier: 2 = true heights (walk mode, or "True height"), 1 = walls halved to see over
var true_h := true                       # the overview at true heights (H): props and rooms in their real proportions
var true_check: CheckBox
var _grab_stacked := false               # the piece being dragged stood on another prop (dragged off it, it goes back to the floor)
var _mesh_boxes := {}                    # "mesh id transform" -> the box round the triangles it really draws
var walk_pos := Vector3.ZERO
var walk_light: OmniLight3D
var _tex_cache := {}                     # pbr name -> StandardMaterial3D
var _flat_cache := {}                    # Color -> StandardMaterial3D
## Placing and moving objects in this view
const M := 1.0 / 4.5                     # metres -> cells
const SEL := Color("35e0ff")             # the editor's selection colour
var overlay: Node3D                      # what is drawn over the level: the ghost and the selection's marks
var ghost_root: Node3D
var sel_root: Node3D
var tip: Label                           # the current tool's controls, along the bottom
var obj_nodes: Array = []                # one Node3D per object of ed.objects, holding its meshes
var ghost := {}                          # the object about to be placed, where the mouse points ({}: nowhere)
var place_elev := {}                     # type -> the height off the floor its last one was given
var grab := -1                           # the object a left drag is moving
var grab_from := Vector2.ZERO            # where the mouse went down on it
var grab_off := Vector2.ZERO             # the floor under the mouse -> its origin, in cells
var grab_moved := false
var _mouse := Vector2.ZERO
var _mouse_in := false
var _aim_stale := true                   # the ghost has to be worked out again (the mouse, the camera or the tool moved)
var _shown_sel := -2                     # the selection the marks were last drawn for
var _unit: BoxMesh
var _sel_line: StandardMaterial3D
var _sel_fill: StandardMaterial3D
var _models := {}                        # object type -> {parts, mat, bounds} ({}: no model, drawn as a box)
var env: Environment
var sun: DirectionalLight3D
## The level's atmosphere (the ATMOSPHERE picker), as a hint of how it will feel in the game: the background,
## the fill light's colour and the sun. Kept bright enough to edit in; the game's real looks are in
## scripts/Render/atmospheres.gd and main.tscn (dim). [background, ambient colour, ambient energy, sun colour, sun energy]
const ATMO_PREVIEW := {
	"dim": [Color("0d0c08"), Color("8a7a52"), 0.4, Color(1.0, 0.9, 0.7), 0.5],                   # warm, dark, foggy halls
	"classic": [Color("6b5d2c"), Color("e8d27a"), 0.6, Color(1.0, 0.98, 0.9), 0.7],              # Kane Pixels: bright, flat yellow
	"liminal": [Color("4a4a3c"), Color("c8ccb8"), 0.55, Color(0.95, 0.98, 0.9), 0.6],            # pale, cool, hazy
}
## the view's light level: the atmosphere's light times this (- and = in the 3D view). Tonemapping keeps the
## highlights from clipping to white, which is what made the old preview look blown out
const LIGHT_STEP := 0.85
var light_level := 0.8
const EXPOSURE := 0.9
const ROT_FINE := 1.0                      # degrees a [ or ] press turns a piece (Shift: 15)
const ELEV_STEP := 0.05                    # metres a PageUp / PageDown press lifts a piece (Shift: 0.25)

func _init(editor) -> void:
	ed = editor
	stretch = true
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_CLICK
	visible = false
	vp = SubViewport.new()
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_4X
	add_child(vp)
	world = Node3D.new()
	vp.add_child(world)
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("0d0c08")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("8a8676")
	env.ambient_light_energy = 0.8
	env.tonemap_mode = Environment.TONE_MAPPER_ACES      # rolls the highlights off instead of clipping them to white
	env.tonemap_exposure = EXPOSURE
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	sun = DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.6, 0.0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS   # sharp near the camera, cheap far off
	sun.directional_shadow_max_distance = 120.0          # cells (1 cell = 4.5 m): the whole map's shadows
	sun.shadow_blur = 1.5                                # softer edges, less stair-stepping
	vp.add_child(sun)
	cam = Camera3D.new()
	cam.far = 500.0
	cam.fov = 55.0                                       # a little less wide than the default: less stretch at the edges
	vp.add_child(cam)
	walk_light = OmniLight3D.new()              # a lamp you carry, so rooms under the ceiling aren't black
	walk_light.omni_range = 4.0
	walk_light.light_energy = 0.6
	walk_light.visible = false
	cam.add_child(walk_light)
	hud = Label.new()
	hud.position = Vector2(10, 8)
	hud.add_theme_font_size_override("font_size", 15)
	hud.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	hud.add_theme_constant_override("shadow_offset_x", 2)
	hud.add_theme_constant_override("shadow_offset_y", 2)
	hud.add_theme_color_override("font_color", Color("cdb86a"))
	hud.text = HUD_ORBIT
	add_child(hud)
	ceiling_check = CheckBox.new()
	ceiling_check.text = "Ceiling"
	ceiling_check.position = Vector2(10, 30)
	ceiling_check.toggled.connect(func(_on): stale = true)
	add_child(ceiling_check)
	true_check = CheckBox.new()
	true_check.text = "True height"
	true_check.tooltip_text = "Rooms and props at their real heights (H). Off: walls drawn half height, to see over them"
	true_check.position = Vector2(10, 52)
	true_check.button_pressed = true_h
	true_check.toggled.connect(func(on):
		true_h = on
		vscale = 2.0 if walking or true_h else 1.0
		_aim_stale = true
		stale = true
		_delay = 0.0)
	add_child(true_check)
	_unit = BoxMesh.new()
	_unit.size = Vector3.ONE
	overlay = Node3D.new()
	vp.add_child(overlay)
	ghost_root = Node3D.new()
	overlay.add_child(ghost_root)
	sel_root = Node3D.new()
	overlay.add_child(sel_root)
	_sel_line = StandardMaterial3D.new()        # drawn over everything, so a mark behind a wall still shows
	_sel_line.albedo_color = SEL
	_sel_line.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_sel_line.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_sel_line.no_depth_test = true
	_sel_line.render_priority = 2
	_sel_fill = StandardMaterial3D.new()
	_sel_fill.albedo_color = Color(SEL, 0.18)
	_sel_fill.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_sel_fill.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_sel_fill.cull_mode = BaseMaterial3D.CULL_DISABLED
	tip = Label.new()
	tip.add_theme_font_size_override("font_size", 13)
	tip.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	tip.add_theme_constant_override("shadow_offset_x", 2)
	tip.add_theme_constant_override("shadow_offset_y", 2)
	tip.add_theme_color_override("font_color", SEL)
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(tip)
	mouse_exited.connect(func():
		_mouse_in = false
		_aim_stale = true)
	_place_camera()

const HUD_ORBIT := "3D VIEW   right drag orbit   middle drag pan   wheel zoom   ZQSD move   E walk   [ ] turn 1° (Shift 15°)   PgUp/PgDn height   - / = view light   F frame   Home reset   H true height"
const HUD_WALK := "WALKING   ZQSD walk   Shift run   right drag / arrows look   E back to overview"

## Walk mode on / off: start from the spawn marker (else the middle of the view), heights at true scale
func toggle_walk() -> void:
	walking = not walking
	vscale = 2.0 if walking or true_h else 1.0
	walk_light.visible = walking
	cam.near = 0.01 if walking else 0.05
	hud.text = HUD_WALK if walking else HUD_ORBIT
	if walking:
		var sp = ed.markers.get("spawn")
		var c: Vector2i = sp if sp != null else Vector2i(roundi(target.x), roundi(target.z))
		if _solid(Vector2(c)): c = _nearest_floor(c)
		walk_pos = Vector3(c.x, 0.0, c.y)
		pitch = 0.0
		ceiling_check.button_pressed = true
	else:
		target = walk_pos
		pitch = -0.9
		ceiling_check.button_pressed = false
	stale = true
	_delay = 0.0
	_place_camera()

## Can't walk into a wall cell or off the map
func _solid(p: Vector2) -> bool:
	var c := Vector2i(roundi(p.x), roundi(p.y))
	return c.x < 0 or c.y < 0 or c.x >= ed.grid_size or c.y >= ed.grid_size or ed.grid[c.y][c.x] == ed.WALL

func _nearest_floor(c: Vector2i) -> Vector2i:
	for r in range(1, ed.grid_size):
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var n := c + Vector2i(dx, dz)
				if not _solid(Vector2(n)): return n
	return c

func mark_stale() -> void:
	stale = true
	_delay = REBUILD_DELAY

func open() -> void:
	visible = true
	var n: int = ed.grid_size
	target = Vector3(n * 0.5, 0.0, n * 0.5)
	dist = n * 0.9
	_place_camera()
	stale = true
	_delay = 0.0
	grab_focus()

func _process(dt: float) -> void:
	if not visible: return
	if stale:
		_delay -= dt
		if _delay <= 0.0:
			stale = false
			_rebuild()
	_tick_placing()
	var move_left := Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_Q)
	var move_right := Input.is_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_D)
	var move_fwd := Input.is_key_pressed(KEY_Z) or Input.is_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_Z)
	var move_back := Input.is_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_S)

	var dir := Vector2.ZERO
	if has_focus() or get_global_rect().has_point(get_global_mouse_position()):
		dir = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
		if move_left: dir.x -= 1.0
		if move_right: dir.x += 1.0
		if move_fwd: dir.y -= 1.0
		if move_back: dir.y += 1.0
	if walking:
		if Input.is_key_pressed(KEY_LEFT): yaw += 1.8 * dt
		if Input.is_key_pressed(KEY_RIGHT): yaw -= 1.8 * dt
		var ahead := -dir.y if not (Input.is_key_pressed(KEY_UP) or Input.is_key_pressed(KEY_DOWN)) else \
			(1.0 if move_fwd else (-1.0 if move_back else 0.0))
		var side := (1.0 if move_right else 0.0) - (1.0 if move_left else 0.0)
		var f := Vector2(-sin(yaw), -cos(yaw))
		var r := Vector2(cos(yaw), -sin(yaw))
		var step := (f * ahead + r * side).limit_length(1.0) * WALK_SPEED * (2.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0) * dt
		var p := Vector2(walk_pos.x, walk_pos.z)
		const R := 0.08                          # body radius: keep this far off walls (slide along them)
		for axis in [Vector2(step.x, 0), Vector2(0, step.y)]:
			var q: Vector2 = p + axis
			var edge: Vector2 = q + axis.normalized() * R if axis != Vector2.ZERO else q
			if not _solid(edge): p = q
		walk_pos = Vector3(p.x, 0.0, p.y)
		_place_camera()
		return
	if dir != Vector2.ZERO and not Input.is_key_pressed(KEY_CTRL):
		var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
		var right := Vector3(cos(yaw), 0.0, -sin(yaw))
		target += (right * dir.x + fwd * -dir.y).limit_length(1.0) * dist * 0.8 * dt
		_place_camera()

func _place_camera() -> void:
	var was := cam.transform
	if walking:
		var eye := walk_pos + Vector3(0, EYE, 0)
		var look := Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
		cam.look_at_from_position(eye, eye + look, Vector3.UP)
	else:
		var off := Vector3(sin(yaw) * cos(pitch), -sin(pitch), cos(yaw) * cos(pitch)) * dist
		cam.look_at_from_position(target + off, target, Vector3.UP)
	if not cam.transform.is_equal_approx(was): _aim_stale = true      # the mouse now points somewhere else

func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		var m: InputEventMouseMotion = e
		_mouse = m.position
		_mouse_in = true
		_aim_stale = true
		if not (m.button_mask & MOUSE_BUTTON_MASK_LEFT): grab = -1      # the button came up somewhere else
		elif grab >= 0: _drag_grabbed()
		if m.button_mask & MOUSE_BUTTON_MASK_MIDDLE or (m.button_mask & MOUSE_BUTTON_MASK_RIGHT and m.shift_pressed):
			var right := Vector3(cos(yaw), 0.0, -sin(yaw))
			var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
			target += (-right * m.relative.x + fwd * m.relative.y) * dist * 0.0018
			_place_camera()
		elif m.button_mask & MOUSE_BUTTON_MASK_RIGHT and walking:
			yaw -= m.relative.x * 0.005
			pitch = clampf(pitch - m.relative.y * 0.005, -1.3, 1.3)
			_place_camera()
		elif m.button_mask & MOUSE_BUTTON_MASK_RIGHT:
			yaw -= m.relative.x * 0.006
			pitch = clampf(pitch - m.relative.y * 0.006, -1.55, -0.05)
			_place_camera()
	elif e is InputEventMouseButton:
		var mb: InputEventMouseButton = e
		if mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
			if not mb.pressed: return
			var up := mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_LEFT
			if mb.shift_pressed or mb.alt_pressed or mb.ctrl_pressed:        # (Shift can turn the wheel sideways: both count)
				_wheel_edit(up, mb)
			elif mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				dist = maxf(dist * 0.88, 2.0) if up else minf(dist * 1.14, 300.0)
				_place_camera()
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			_mouse = mb.position
			_mouse_in = true
			if not mb.pressed: grab = -1
			elif _placing() != "":
				_aim()
				_place()
			elif ed.tool == "select": _grab()
	elif e is InputEventKey and e.pressed and not e.echo and not e.ctrl_pressed:
		var k: InputEventKey = e
		match k.keycode:
			KEY_R:                                       # the piece in hand, else the selected one
				var deg := -90.0 if k.shift_pressed else 90.0
				if _placing() != "": ed.place_rot = fposmod(ed.place_rot + deg, 360.0)
				else: ed._rotate_selected(deg)
				_aim_stale = true
			KEY_DELETE, KEY_BACKSPACE:
				ed._delete_selected()
				_delay = 0.0
			KEY_ESCAPE:                                  # drop the piece in hand, else the selection
				if _placing() != "": ed._select_tool("select")
				else: ed._select(-1)
			KEY_BRACKETLEFT, KEY_BRACKETRIGHT:          # a fine turn of the piece in hand, else the selected one
				var turn := ROT_FINE * (15.0 if k.shift_pressed else 1.0)
				if k.keycode == KEY_BRACKETLEFT: turn = -turn
				if _placing() != "": ed.place_rot = fposmod(float(ed.place_rot) + turn, 360.0)
				else: ed._rotate_selected(turn)
				_aim_stale = true
			KEY_PAGEUP, KEY_PAGEDOWN:                   # the height of the piece in hand, else the selected one
				_step_elev((1.0 if k.keycode == KEY_PAGEUP else -1.0) * (5.0 if k.shift_pressed else 1.0))
			KEY_MINUS, KEY_EQUAL:                       # how bright the view is (lighting only, not the map)
				light_level = clampf(light_level * (LIGHT_STEP if k.keycode == KEY_MINUS else 1.0 / LIGHT_STEP), 0.15, 2.5)
				_apply_atmosphere()
				ed._status("View light %d%%" % roundi(light_level * 100.0))
			KEY_F: _frame_selected()
			KEY_HOME: _reset_view()
			KEY_V: ed._select_tool("select")
			KEY_E: toggle_walk()
			KEY_C: ceiling_check.button_pressed = not ceiling_check.button_pressed
			KEY_H: true_check.button_pressed = not true_check.button_pressed

# ---------------------------------------------------------------- materials
func _flat(col: Color) -> StandardMaterial3D:
	if not _flat_cache.has(col):
		var m := StandardMaterial3D.new()
		m.albedo_color = col
		m.roughness = 0.9
		if col.a < 1.0: m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_flat_cache[col] = m
	return _flat_cache[col]

## A surface material (a pbr name or "default:<slot>", see the editor's _surface_key) as the editor's thumbnail,
## tiled by world position; its average colour if it has no texture
func _pbr(key: String) -> StandardMaterial3D:
	if _tex_cache.has(key): return _tex_cache[key]
	var t: Dictionary = ed._thumb(key)
	var m := StandardMaterial3D.new()
	m.roughness = 0.9
	if t.tex != null:
		m.albedo_texture = t.tex
		m.uv1_triplanar = true
		m.uv1_world_triplanar = true
		m.uv1_scale = Vector3.ONE * 0.5
		if key.begins_with("Ceiling_Drop"):
			# the drop ceilings: their picture is two 0.75 m tiles, on the game's tile grid (level_geometry.gd _pbr_by_id)
			m.uv1_scale = Vector3.ONE / 1.5
			m.uv1_offset = Vector3(0.5 if key == "Ceiling_Drop_Long" else 0.25, 0.25, 0.25)
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	else:
		m.albedo_color = t.avg
	_tex_cache[key] = m
	return m

# ---------------------------------------------------------------- building
func _clear() -> void:
	for c in world.get_children(): c.queue_free()

## One MultiMesh of `mesh` (a unit box / quad, scaled per instance) for every transform in `xfs`
func _batch(mesh: Mesh, mat: Material, xfs: Array) -> void:
	if xfs.is_empty(): return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xfs.size()
	for i in xfs.size(): mm.set_instance_transform(i, xfs[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	world.add_child(mmi)

func _box_xf(centre: Vector3, size: Vector3, yaw_rad := 0.0) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, yaw_rad) * Basis.from_scale(size), centre)

func _wall_height(c: Vector2i) -> float:
	if ed.zones["crawl"].has(c): return 1.2 * vscale
	var all_low := true
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var n := c + Vector2i(dx, dz)
			if ed.zones["grand"].has(n): return GRAND_H * vscale
			if ed.zones["tall"].has(n): return TALL_H * vscale
			if not ed.zones["low"].has(n): all_low = false
	return (LOW_H if all_low else WALL_H) * vscale

func _apply_atmosphere() -> void:
	var a := "dim"
	if ed.atmo_pick != null and ed.atmo_pick.selected >= 0:
		a = ed.ATMOS[ed.atmo_pick.selected]
	var p: Array = ATMO_PREVIEW.get(a, ATMO_PREVIEW.dim)
	env.background_color = p[0]
	env.ambient_light_color = p[1]
	env.ambient_light_energy = p[2] * light_level
	sun.light_color = p[3]
	sun.light_energy = p[4] * light_level

func _rebuild() -> void:
	_apply_atmosphere()
	_clear()
	var n: int = ed.grid_size
	var unit := _unit
	var quad := QuadMesh.new()
	quad.orientation = PlaneMesh.FACE_Y
	quad.size = Vector2.ONE
	var by_mat := {"wall": {}, "floor": {}, "ceiling": {}}       # slot -> {pbr name or "": [transforms]}
	var pits: Array = []
	for z in n:
		for x in n:
			var c := Vector2i(x, z)
			var ch: String = ed.grid[z][x]
			if ch == ed.WALL:
				var h := _wall_height(c)
				by_mat["wall"].get_or_add(ed._surface_key("wall", c), []).append(_box_xf(Vector3(x, h * 0.5, z), Vector3(1, h, 1)))
				continue
			if ch == ed.PIT:
				pits.append(_box_xf(Vector3(x, -0.05, z), Vector3(1, 0.1, 1)))
				continue
			by_mat["floor"].get_or_add(ed._surface_key("floor", c), []).append(_box_xf(Vector3(x, 0.0, z), Vector3(1, 1, 1)))
			if ceiling_check.button_pressed:
				var h := _wall_height(c)
				by_mat["ceiling"].get_or_add(ed._surface_key("ceiling", c), []).append(Transform3D(Basis(Vector3.RIGHT, PI), Vector3(x, h + 0.02, z)))
	_flat_cache.clear()
	for slot in by_mat:
		for key in by_mat[slot]:
			_batch(unit if slot == "wall" else quad, _pbr(key), by_mat[slot][key])
	_batch(unit, _flat(Color("050505")), pits)
	# zones: a translucent tint on the floor, a little above it
	for zn in ed.ZONES:
		var xfs: Array = []
		for c: Vector2i in ed.zones[zn]:
			xfs.append(_box_xf(Vector3(c.x, 0.012 + 0.002 * ed.ZONES.keys().find(zn), c.y), Vector3(0.96, 1, 0.96)))
		var col: Color = ed.ZONES[zn]
		col.a = 0.55
		var zm := _flat(col)
		zm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_batch(quad, zm, xfs)
	# hotel corridors: the side walls standing into their cells, as the game builds them (level_geometry.gd
	# _build_hotel_insets). The editor's cells are the game's; HOTEL_INSET 0.9 m is 0.2 of a 4.5 m cell
	var hotel_xfs: Array = []
	var inset := 0.9 / 4.5
	for c: Vector2i in ed.zones["hotel"]:
		for dn: Vector2i in ed.DIRS4:
			var nb := c + dn
			var solid: bool = nb.x < 0 or nb.y < 0 or nb.x >= ed.grid_size or nb.y >= ed.grid_size or ed.grid[nb.y][nb.x] == ed.WALL
			if not solid: continue
			var hh := (5.0 / 6.0) * WALL_H * vscale      # the hotel ceiling is 4.5 m of the 5.4 m wall, whatever the cell's neighbours
			var sz := Vector3(inset if dn.x != 0 else 1.0, hh, inset if dn.y != 0 else 1.0)
			var at := Vector3(c.x + dn.x * (0.5 - inset * 0.5), hh * 0.5, c.y + dn.y * (0.5 - inset * 0.5))
			hotel_xfs.append(_box_xf(at, sz))
	if not hotel_xfs.is_empty():
		_batch(unit, _pbr(ed._surface_key("wall", Vector2i(-1, -1))), hotel_xfs)
	for m in ed.MARKERS:
		var mc = ed.markers[m]
		if mc == null: continue
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.06
		mesh.bottom_radius = 0.12
		mesh.height = 0.9
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.position = Vector3(mc.x, 0.45, mc.y)
		var mm := _flat(ed.MARKERS[m])
		mm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mi.material_override = mm
		world.add_child(mi)
	obj_nodes.clear()
	for o: Dictionary in ed.objects:
		var holder := Node3D.new()
		world.add_child(holder)
		obj_nodes.append(holder)
		_object(o, unit, holder)
	_shown_sel = -2                                    # the marks and the ghost go by the walls' heights too
	_aim_stale = true

## One object's meshes, added to `parent` (its holder in the level, or the ghost)
func _object(o: Dictionary, unit: Mesh, parent: Node3D) -> void:
	var c := Vector2i(roundi(o.pos_x), roundi(o.pos_y))
	var h := _wall_height(c)
	var info: Dictionary = ed.OBJ_INFO.get(o.type, {})
	var col: Color = info.get("col", Color("a39c8a"))
	var yaw_rad := -deg_to_rad(o.rotation)             # map rotation is clockwise seen from above
	var pos := Vector3(o.pos_x, 0.0, o.pos_y)
	var depth := float(info.get("thickness", 0.3)) / 4.5      # metres -> cells
	var span: float = o.scale
	var wall_mat := _pbr(ed._surface_key("wall", Vector2i(-1, -1)))
	var parts: Array = []                              # [local centre, size, material, (yaw), (mesh)]
	match o.type:
		"entity":                                      # a spawn mark: a red post with a head, like the other markers
			var post := CylinderMesh.new()
			post.top_radius = 0.06
			post.bottom_radius = 0.12
			post.height = 0.9
			var pm := MeshInstance3D.new()
			pm.mesh = post
			pm.position = pos + Vector3(0.0, 0.45, 0.0)
			var pmat := _flat(col)
			pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			pm.material_override = pmat
			parent.add_child(pm)
			return
		"arch":
			var pillar := float(info.get("pillar", 0.75)) / 4.5
			var r := span * 0.5 - pillar
			var top := 0.42                              # crown, flattened to a lintel
			for side in [-1.0, 1.0]:
				parts.append([Vector3(0, h * 0.5, side * (r + pillar * 0.5)), Vector3(1, h, pillar), wall_mat])
			parts.append([Vector3(0, (h + top) * 0.5, 0), Vector3(1, h - top, r * 2.0), wall_mat])
		"squeeze_gap":
			var sg := float(o.get("gap", 0.55)) / 4.5
			var jamb := (span - sg) * 0.5

			for side in [-1.0, 1.0]:
				parts.append([Vector3(0, h * 0.5, side * (sg * 0.5 + jamb * 0.5)), Vector3(1, h, jamb), wall_mat])
			parts.append([Vector3(0, (h * 0.43 + h) * 0.5, 0), Vector3(1, h * 0.57, sg), wall_mat])
		"door":
			var frame := _flat(Color("6b4a2e"))
			parts.append([Vector3(0, h * 0.42, 0), Vector3(depth, h * 0.84, span * 0.8), frame])
			parts.append([Vector3(0, h * 0.92, 0), Vector3(depth * 1.4, h * 0.16, span), wall_mat])
			for side in [-1.0, 1.0]:
				parts.append([Vector3(0, h * 0.5, side * span * 0.45), Vector3(depth * 1.4, h, span * 0.1), wall_mat])
		"stairs_up", "stairs_down":
			# the stairwell's box (sizes in cells, as props/stairs.gd builds it) with a flight in each lane it has
			var skin := 0.03
			var wide: float = ed.STAIR_WIDE
			var z0 := 0.5 - wide                         # across: its own row and the one to the left
			var x1: float = ed.STAIR_CELLS - 0.5
			var zm := z0 + wide * 0.5
			var lane := 3.8 / 4.5
			var door_z := zm + (0.5 + 1.9) / 4.5
			var door_w := 2.2 / 4.5
			var door_h := h * 2.8 / 5.4
			parts.append([Vector3((x1 - 0.5) * 0.5, h * 0.5, z0 + skin), Vector3(x1 + 0.5, h, skin * 2.0), wall_mat])
			parts.append([Vector3((x1 - 0.5) * 0.5, h * 0.5, 0.5 - skin), Vector3(x1 + 0.5, h, skin * 2.0), wall_mat])
			parts.append([Vector3(x1 - skin, h * 0.5, zm), Vector3(skin * 2.0, h, wide), wall_mat])
			var left_w := door_z - door_w * 0.5 - z0
			var right_w := 0.5 - (door_z + door_w * 0.5)
			parts.append([Vector3(-0.5 + skin, h * 0.5, z0 + left_w * 0.5), Vector3(skin * 2.0, h, left_w), wall_mat])
			parts.append([Vector3(-0.5 + skin, h * 0.5, 0.5 - right_w * 0.5), Vector3(skin * 2.0, h, right_w), wall_mat])
			parts.append([Vector3(-0.5 + skin, (h + door_h) * 0.5, door_z), Vector3(skin * 2.0, h - door_h, door_w), wall_mat])
			var xa := -0.5 + 3.2 / 4.5
			var xb := x1 - 3.2 / 4.5
			parts.append([Vector3((xa + xb) * 0.5, h * 0.5, zm), Vector3(xb - xa, h, 1.0 / 4.5), wall_mat])       # the wall between the lanes
			var steps := 10
			for side: Array in [[1.0, ed._stair_linked(o, ed.floor_idx, 1)], [-1.0, ed._stair_linked(o, ed.floor_idx, -1)]]:
				var zc: float = zm + side[0] * (0.5 + 1.9) / 4.5
				if not side[1]:                           # no floor that way: the lane is walled off
					parts.append([Vector3(xa + skin, h * 0.5, zc), Vector3(skin * 2.0, h, lane), wall_mat])
					continue
				for i in steps:
					var top: float = h * 0.8 * (i + 1) / steps
					if side[0] > 0.0:
						parts.append([Vector3(xa + (xb - xa) * (i + 0.5) / steps, top * 0.5, zc), Vector3((xb - xa) / steps, top, lane), _flat(col)])
					else:                                 # going down: steps sinking away under a dark slab
						parts.append([Vector3(xa + (xb - xa) * (i + 0.5) / steps, 0.02, zc), Vector3((xb - xa) / steps, 0.04, lane), _flat(col.darkened(0.08 * (i + 1)))])
		_:
			var model := _model_of(o)
			if not model.is_empty():                       # a model prop: its real mesh
				var at := _prop_xf(o)
				for mp: Array in model.parts:
					var pm := MeshInstance3D.new()
					pm.mesh = mp[0]
					pm.transform = at * (mp[1] as Transform3D)
					if model.mat != null: pm.material_override = model.mat
					parent.add_child(pm)
				return
			var sh: String = ed._shape(o.type)
			var hm := float(ed._param(o, "height", 0.0))
			var ph := h if hm <= 0.0 else minf(h, hm / 9.0 * vscale)        # metres -> this view's squashed heights (5.4 m = 0.6)
			var t: float = ed._thick_cells(o)
			match sh:
				"slab", "corner", "arc", "spline":
					var path: PackedVector2Array = ed._shape_path(o)
					for i in path.size() - 1:
						var run := path[i + 1] - path[i]
						var mid := (path[i] + path[i + 1]) * 0.5
						parts.append([Vector3(mid.x, ph * 0.5, mid.y), Vector3(run.length() + t, ph, t), wall_mat, atan2(-run.y, run.x)])
				"pillar":
					parts.append([Vector3(0, ph * 0.5, 0), Vector3(t, ph, t), wall_mat])
				"column":
					var cyl := CylinderMesh.new()
					cyl.top_radius = 0.5
					cyl.bottom_radius = 0.5
					cyl.height = 1.0
					parts.append([Vector3(0, ph * 0.5, 0), Vector3(t, ph, t), wall_mat, 0.0, cyl])
				"platform":
					var dep := float(ed._param(o, "depth", 2.0))
					var top := _up(float(ed._param(o, "elev", 2.7)))
					var slab := maxf(_up(float(ed._param(o, "slab", 0.35))), 0.01)
					parts.append([Vector3(0, top - slab * 0.5, 0), Vector3(dep, slab, span), _flat(col)])
					if bool(ed._param(o, "posts", true)) and top - slab > 0.02:
						for cx: float in [-dep * 0.45, dep * 0.45]:
							for cz: float in [-span * 0.45, span * 0.45]:
								parts.append([Vector3(cx, (top - slab) * 0.5, cz), Vector3(0.07, top - slab, 0.07), wall_mat])
					if str(ed._param(o, "edge", "chrome")) != "none":
						var rail := _flat(Color(0.85, 0.87, 0.9))
						for cz: float in [-span * 0.5, span * 0.5]: parts.append([Vector3(0, top + _up(0.5), cz), Vector3(dep, _up(1.0), 0.01), rail])
						for cx: float in [-dep * 0.5, dep * 0.5]: parts.append([Vector3(cx, top + _up(0.5), 0), Vector3(0.01, _up(1.0), span), rail])
				"flight":
					var dep := float(ed._param(o, "depth", 1.0))
					var base := _up(float(ed._param(o, "elev", 0.0)))
					var rise := _up(float(ed._param(o, "rise", 2.7)))
					var n := clampi(roundi(float(ed._param(o, "rise", 2.7)) / 0.36), 2, 40)
					for i in n:
						var hgt := rise * (i + 1) / n
						parts.append([Vector3(-dep * 0.5 + dep * (i + 0.5) / n, base + hgt * 0.5, 0), Vector3(dep / n, hgt, span), _flat(col.darkened(0.03 * (i % 2)))])
				"spiral":
					var r := span * 0.5
					var rise := _up(float(ed._param(o, "rise", 5.4)))
					var base := _up(float(ed._param(o, "elev", 0.0)))
					var sweep := deg_to_rad(float(ed._param(o, "sweep", 360.0)))
					var turn := -1.0 if str(ed._param(o, "turn", "left")) == "right" else 1.0
					var n := clampi(roundi(float(ed._param(o, "rise", 5.4)) / 0.4), 3, 60)
					var core := float(ed._param(o, "core", 0.7)) / 4.5
					for i in n:
						var a := sweep * (i + 0.5) / n
						var at := Vector3(cos(a), 0, -sin(a) * turn) * (r + core * 0.5) * 0.5
						parts.append([at + Vector3(0, base + rise * (i + 1) / n, 0), Vector3(r - core * 0.5, 0.02, maxf(0.05, sweep / n * r * 0.7)), _flat(col), atan2(sin(a) * turn, cos(a))])
					var cyl := CylinderMesh.new()
					cyl.top_radius = 0.5
					cyl.bottom_radius = 0.5
					cyl.height = 1.0
					parts.append([Vector3(0, (base + rise + _up(2.0)) * 0.5, 0), Vector3(core, base + rise + _up(2.0), core), wall_mat, 0.0, cyl])
				"window":
					var hh := _up(float(ed._param(o, "height", 2.2)))
					var sill := _up(float(ed._param(o, "elev", 0.9)))
					var glass := _flat(Color(0.75, 0.9, 1.0))
					glass.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
					parts.append([Vector3(0.012, sill + hh * 0.5, 0), Vector3(0.02, hh, span), glass])
					parts.append([Vector3(0.02, sill - 0.01, 0), Vector3(0.05, 0.02, span + 0.04), _flat(Color(0.92, 0.92, 0.9))])
				"water":
					var lvl := maxf(_up(float(ed._param(o, "level", 0.4))), 0.005)
					parts.append([Vector3(0, lvl * 0.5, 0), Vector3(float(ed._param(o, "depth", 3.0)), lvl, span), _flat(Color(0.25, 0.72, 0.8, 0.45))])
				"pool":
					var poly: PackedVector2Array = ed._shape_path(o)
					if poly.size() >= 4:
						var pv := poly.slice(0, poly.size() - 1)
						var idx := Geometry2D.triangulate_polygon(pv)
						if not idx.is_empty():
							var st := SurfaceTool.new()
							st.begin(Mesh.PRIMITIVE_TRIANGLES)
							for k in idx:
								st.set_normal(Vector3.UP)
								st.add_vertex(Vector3(pv[k].x, 0.004, pv[k].y))
							var pm := MeshInstance3D.new()
							pm.mesh = st.commit()
							var wm := _flat(Color(0.2, 0.62, 0.75))
							wm.cull_mode = BaseMaterial3D.CULL_DISABLED
							pm.material_override = wm
							pm.transform = Transform3D(Basis(Vector3.UP, yaw_rad), pos)
							parent.add_child(pm)
						var rim := _flat(Color(0.93, 0.93, 0.9))
						for i in poly.size() - 1:
							var run2 := poly[i + 1] - poly[i]
							var mid2 := (poly[i] + poly[i + 1]) * 0.5
							parts.append([Vector3(mid2.x, 0.006, mid2.y), Vector3(run2.length() + 0.07, 0.012, 0.07), rim, atan2(-run2.y, run2.x)])
				"pipe", "riser":
					_pipe_preview(o, h, Transform3D(Basis(Vector3.UP, yaw_rad), pos), parent)
				"zone":
					var zc := col
					zc.a = 0.22
					var zm := _flat(zc)
					zm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
					parts.append([Vector3(0, h * 0.4, 0), Vector3(float(ed._param(o, "depth", 2.0)), h * 0.8, span), zm])
				_:
					var s := 0.28 * span
					parts.append([Vector3(0, s * 0.5 + _up(float(ed._param(o, "elev", 0.0))), 0), Vector3(s, s, s), _flat(col)])
	var xf := Transform3D(Basis(Vector3.UP, yaw_rad), pos)
	for p in parts:
		var mi := MeshInstance3D.new()
		mi.mesh = p[4] if p.size() > 4 else unit
		var yaw: float = p[3] if p.size() > 3 else 0.0
		mi.transform = xf * Transform3D(Basis(Vector3.UP, yaw) * Basis.from_scale(p[1]), p[0])
		mi.material_override = p[2]
		parent.add_child(mi)

# ---------------------------------------------------------------- pipes
## A pipe run or riser as the game's props/pipe_network.gd lays it out (without its fittings): a cylinder per leg of
## each pipe of the run, a ball at each turn, at its height (under the ceiling `roof`, on stands, or at Off floor)
func _pipe_preview(o: Dictionary, roof: float, xf: Transform3D, parent: Node3D) -> void:
	var mat := _flat(ed._pipe_col(str(ed._param(o, "material", "rust"))))
	var r := float(ed._param(o, "diameter", 0.3)) * 0.5 * M
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.5
	cyl.bottom_radius = 0.5
	cyl.height = 1.0
	cyl.radial_segments = 12
	var ball := SphereMesh.new()
	ball.radius = 0.5
	ball.height = 1.0
	var put := func(mesh: Mesh, at: Transform3D) -> void:
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = mat
		mi.transform = xf * at
		parent.add_child(mi)
	var leg := func(a: Vector3, b: Vector3) -> void:
		var d := b - a
		if d.length() < 0.001: return
		var y := d.normalized()
		var x := (Vector3.UP if absf(y.y) < 0.9 else Vector3.RIGHT).cross(y).normalized()
		put.call(cyl, Transform3D(Basis(x, y, x.cross(y)) * Basis.from_scale(Vector3(r * 2.0, d.length(), r * 2.0)), (a + b) * 0.5))
	if ed._shape(o.type) == "riser":
		var to := float(ed._param(o, "to", 0.0))
		leg.call(Vector3(0, _up(float(ed._param(o, "from", 0.0))), 0), Vector3(0, roof if to <= 0.0 else _up(to), 0))
		return
	var path: PackedVector2Array = ed._shape_path(o)
	if path.size() < 2: return
	var r_m := float(ed._param(o, "diameter", 0.3)) * 0.5
	var hang := str(ed._param(o, "hang", "ceiling"))
	var y0: float
	match hang:
		"floor": y0 = _up(r_m + 0.12)
		"elev": y0 = _up(float(ed._param(o, "elev", 1.0)) + r_m)
		_: y0 = roof - _up(maxf(float(ed._param(o, "drop", 0.45)), r_m + 0.05))
	var n := clampi(int(ed._param(o, "count", 1)), 1, 8)
	var pitch := (r_m * 2.0 + float(ed._param(o, "gap", 0.08))) * M
	var up := str(ed._param(o, "stack", "side")) == "up"
	for k in n:
		var s := (k - (n - 1) * 0.5) * pitch
		var dy := 0.0
		if up: dy = (-k if hang == "ceiling" else k) * pitch
		var pts: Array = []
		for i in path.size():
			var p := path[i]
			var side := Vector2.ZERO
			if not up:
				var d0 := (p - path[i - 1]).normalized() if i > 0 else Vector2.ZERO
				var d1 := (path[i + 1] - p).normalized() if i < path.size() - 1 else Vector2.ZERO
				side = (Vector2(-d0.y, d0.x) + Vector2(-d1.y, d1.x)).normalized() * s
			pts.append(Vector3(p.x + side.x, y0 + dy, p.y + side.y))
		for i in pts.size() - 1:
			leg.call(pts[i], pts[i + 1])
			if i > 0: put.call(ball, Transform3D(Basis.from_scale(Vector3.ONE * r * 2.5), pts[i]))

# ---------------------------------------------------------------- prop models
## Metres up -> this view's height (squashed to half in the overview, true in walk mode, like the walls)
func _up(m: float) -> float:
	return m / 9.0 * vscale

## A model prop's meshes as the game's props/industrial_prop.gd stands them (metres, in the prop's own space:
## turned by "model_yaw", the lowest point on y = 0), read straight from the game's .glb / .fbx:
## {parts: [[Mesh, Transform3D]], mat: its material (null: the file's own), bounds: AABB}.
## {} for a type with no model, or one that can't be read: it is drawn as a box.
## The model of object `o` as it is: its type's, and for a type with "variants" the piece its "variant" picks
func _model_of(o: Dictionary) -> Dictionary:
	return _model(str(o.type), int(ed._param(o, "variant", 1)))

func _model(t: String, variant := 1) -> Dictionary:
	var info: Dictionary = ed.OBJ_INFO.get(t, {})
	var variants: Array = info.get("variants", [])
	var key := t if variants.is_empty() else "%s#%d" % [t, clampi(variant, 1, variants.size())]
	if _models.has(key): return _models[key]
	_models[key] = {}
	if not info.has("model"): return {}
	var path: String = ed.GAME.path_join(str(info.model).trim_prefix("res://"))
	var fbx := path.get_extension().to_lower() == "fbx"
	if fbx and not ClassDB.class_exists("FBXDocument"): return {}
	var doc: GLTFDocument = ClassDB.instantiate("FBXDocument") if fbx else GLTFDocument.new()
	var state: GLTFState = ClassDB.instantiate("FBXState") if fbx else GLTFState.new()
	if doc.append_from_file(path, state) != OK: return {}
	var root := doc.generate_scene(state)
	if root == null: return {}
	var parts: Array = []
	var keep: Array = info.get("model_nodes", []) if variants.is_empty() else variants[clampi(variant, 1, variants.size()) - 1]
	var drop: Array = info.get("model_drop", [])
	if root is MeshInstance3D and (root as MeshInstance3D).mesh != null and keep.is_empty(): parts.append([(root as MeshInstance3D).mesh, Transform3D.IDENTITY])
	_model_parts(root, Transform3D.IDENTITY, parts, keep.is_empty(), keep, drop)
	root.free()
	if parts.is_empty(): return {}
	var raw := AABB()
	for i in parts.size():
		var b := _mesh_box(parts[i][0], parts[i][1])
		raw = b if i == 0 else raw.merge(b)
	# its size: "fit" (its real size, on the file's own axes) else "model_scale"
	var big_by := float(info.get("model_scale", 1.0))
	var fit: Array = info.get("fit", [])
	if fit.size() == 2:
		var have := raw.size.y
		match str(fit[0]):
			"x": have = raw.size.x
			"z": have = raw.size.z
			"len": have = maxf(raw.size.x, raw.size.z)
		if have > 0.0001: big_by = float(fit[1]) / have
	var r: Array = info.get("model_rot", [0.0, 0.0, 0.0])
	var rot := Basis.from_euler(Vector3(deg_to_rad(float(r[0])), deg_to_rad(float(r[1])), deg_to_rad(float(r[2]))))
	var basis := Basis(Vector3.UP, deg_to_rad(float(info.get("model_yaw", 0.0)))) * rot * Basis.from_scale(Vector3.ONE * big_by)
	var box: AABB = Transform3D(basis, Vector3.ZERO) * raw
	var off := Vector3(0.0, -box.position.y, 0.0)
	if bool(info.get("center", false)):                # a pack's piece: its middle on the object's origin
		off.x = -box.get_center().x
		off.z = -box.get_center().z
	var fix := Transform3D(basis, off)
	box.position += off
	for p: Array in parts: p[1] = fix * (p[1] as Transform3D)
	# a loose-texture pack (the game builds its material from "textures"): its colour map, small; else the file's own
	var mat: StandardMaterial3D = null
	var tex: Dictionary = info.get("textures", {})
	if not tex.is_empty():
		mat = StandardMaterial3D.new()
		mat.roughness = 0.8
		mat.albedo_color = info.get("col", Color("a39c8a"))
		var img: Image = Image.load_from_file(ed.GAME.path_join(str(tex.albedo).trim_prefix("res://"))) if tex.has("albedo") else null
		if img != null and not img.is_empty():
			var big := maxi(img.get_width(), img.get_height())
			if big > 512: img.resize(maxi(1, roundi(img.get_width() * 512.0 / big)), maxi(1, roundi(img.get_height() * 512.0 / big)), Image.INTERPOLATE_BILINEAR)
			img.generate_mipmaps()
			mat.albedo_color = Color.WHITE
			mat.albedo_texture = ImageTexture.create_from_image(img)
			mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_models[key] = {"parts": parts, "mat": mat, "bounds": box}
	return _models[key]

## A picture of a model prop for the tool panel: its real meshes from a three-quarter view, drawn once into a
## little viewport of its own on a clear background. null for a type with no model (or one that can't be read).
func prop_thumb(t: String) -> Texture2D:
	var m := _model(t)
	if m.is_empty(): return null
	var tvp := SubViewport.new()
	tvp.size = Vector2i(THUMB_PX, THUMB_PX)
	tvp.own_world_3d = true
	tvp.transparent_bg = true
	tvp.render_target_update_mode = SubViewport.UPDATE_ONCE
	ed.add_child(tvp)
	var root := Node3D.new()
	tvp.add_child(root)
	for p: Array in m.parts:
		var mi := MeshInstance3D.new()
		mi.mesh = p[0]
		mi.transform = p[1]
		mi.material_override = m.mat
		root.add_child(mi)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("8a8676")
	env.ambient_light_energy = 0.8
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = EXPOSURE
	we.environment = env
	tvp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.6, 0.0)
	sun.light_energy = 1.1
	tvp.add_child(sun)
	var b: AABB = m.bounds
	var c := b.get_center()
	var cam := Camera3D.new()
	cam.fov = 30.0
	tvp.add_child(cam)
	cam.look_at_from_position(c + Vector3(1.0, 0.55, 1.0).normalized() * maxf(b.size.length(), 0.3) * 2.0, c)
	cam.current = true
	await RenderingServer.frame_post_draw
	var img := tvp.get_texture().get_image()
	tvp.queue_free()
	return ImageTexture.create_from_image(img)

## Every mesh under `n` with its place in the model (through every node above it)
## (`kept`: under one of the `keep` names, or no names given; nothing under a `drop` name: the type's
## "model_nodes" / "model_drop", a pack's one piece without the rest)
func _model_parts(n: Node, xf: Transform3D, out: Array, kept := true, keep: Array = [], drop: Array = []) -> void:
	for c in n.get_children():
		if drop.has(String(c.name)): continue
		var ck := kept or keep.has(String(c.name))
		var cx: Transform3D = xf * (c as Node3D).transform if c is Node3D else xf
		var mesh: Mesh = null
		if c is MeshInstance3D: mesh = (c as MeshInstance3D).mesh
		elif c is ImporterMeshInstance3D and (c as ImporterMeshInstance3D).mesh != null: mesh = (c as ImporterMeshInstance3D).mesh.get_mesh()
		if mesh != null and ck: out.append([mesh, cx])
		_model_parts(c, cx, out, ck, keep, drop)

## The box round the triangles `mesh` really draws, placed by `xf` (as the game's industrial_prop.gd mesh_box():
## measured on the triangles, as a box turned by a node grows, and collapsed triangles off the model don't count)
func _mesh_box(mesh: Mesh, xf: Transform3D) -> AABB:
	var key := "%d %s" % [mesh.get_instance_id(), xf]
	if _mesh_boxes.has(key): return _mesh_boxes[key]
	var box := xf * mesh.get_aabb()
	var faces := mesh.get_faces()
	var first := true
	var tiny := mesh.get_aabb().size.length_squared() * 1e-10
	for i in range(0, faces.size() - 2, 3):
		var a := faces[i]
		var b := faces[i + 1]
		var c := faces[i + 2]
		if (b - a).cross(c - a).length_squared() <= tiny: continue
		a = xf * a
		b = xf * b
		c = xf * c
		if first:
			box = AABB(a, Vector3.ZERO)
			first = false
		box = box.expand(a).expand(b).expand(c)
	_mesh_boxes[key] = box
	return box

## Where a model prop stands: turned its way, "elev" metres off the floor, its metres brought to cells
func _prop_xf(o: Dictionary) -> Transform3D:
	var k: float = float(o.scale) * M
	return Transform3D(Basis(Vector3.UP, -deg_to_rad(o.rotation)) * Basis.from_scale(Vector3(k, k * 0.5 * vscale, k)),
		Vector3(o.pos_x, _up(float(ed._param(o, "elev", 0.0))), o.pos_y))

# ---------------------------------------------------------------- placing
# Objects are put where the mouse points in this view. A ray from the mouse is followed to the first thing it
# reaches: a wall cell's side, a wall object's side (a thin wall, a door's partition, a pillar), else the
# floor. A "mount": "wall" prop (object_types.json) reaching a wall goes flat on it, its back on the face and
# its middle at the height pointed at; everything else stands on the floor there (at the wall's foot, if it
# was a wall). Positions snap as on the map (Snap to grid; Alt places freely).
var _tool_was := ""

## The object type the tool panel has in hand, "" for none (and for stairwells: they claim the same cells of
## two floors, which the map checks)
func _placing() -> String:
	var tool := str(ed.tool)
	if not tool.begins_with("obj:"): return ""
	var t := tool.get_slice(":", 1)
	return "" if ed._is_stairs(t) or bool(ed._info(t).get("draw_spline", false)) else t      # (drawn on the map)

## Once a frame while the view is open: the ghost, the selection's marks and the line of controls
func _tick_placing() -> void:
	if grab >= 0 and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT): grab = -1
	if str(ed.tool) != _tool_was:
		_tool_was = str(ed.tool)
		_aim_stale = true
	if _aim_stale: _aim()
	var sel: int = ed.selected if ed.selected < ed.objects.size() else -1
	if sel != _shown_sel: _show_selection(sel)
	var said := _tip_text()
	var wide := maxf(size.x - 20.0, 50.0)
	if tip.text != said or not is_equal_approx(tip.size.x, wide):
		tip.text = said
		tip.size = Vector2(wide, 0.0)                  # as tall as its lines need at this width
	tip.position = Vector2(10.0, size.y - tip.size.y - 8.0)

func _tip_text() -> String:
	var t := _placing()
	if t != "":
		var info: Dictionary = ed._info(t)
		var where := "point at a wall: it hangs there, at that height" if str(info.get("mount", "")) == "wall" else "it goes where the mouse points"
		if info.has("model") and str(info.get("mount", "")) != "wall": where = "point at the floor, or at a table / shelf top to stand it on that"
		return "PLACING %s   %s   click: place   R: turn 90°   [ ]: turn 1°   Shift+wheel: size   PgUp/PgDn: height   Alt: no snap   Esc: stop" % [str(info.label).to_upper(), where]
	if str(ed.tool).begins_with("obj:"): return "Stairwells, pipe runs and spline walls are drawn on the map (F4)"
	if str(ed.tool) == "select":
		if ed.selected >= 0: return "Drag: move it (a wall prop slides over the walls)   R: turn   Shift+wheel: size   Alt+wheel: turn 15°   Ctrl+wheel: height   Del: delete   Esc: deselect"
		return "Click an object to select it, drag to move it.   Pick a prop in the tool panel to place it here"
	return "Pick an object in the tool panel (PROPS tab) to place it here, or Select / move to pick one up"

## The ray the mouse points along: [where it starts, its direction]
func _mouse_ray() -> Array:
	var p := _mouse * Vector2(vp.size) / size
	return [cam.project_ray_origin(p), cam.project_ray_normal(p)]

## What the ray reaches first in the map itself: {t: how far, pos, normal}. A wall cell's side (normal: the
## way that face looks), its top, or the floor (normal up). {} if it leaves the level without reaching any.
func _cast(from: Vector3, dir: Vector3) -> Dictionary:
	var n: int = ed.grid_size
	var floor_hit := {}
	var reach := INF
	if dir.y < -0.0001:
		reach = -from.y / dir.y
		floor_hit = {"t": reach, "pos": from + dir * reach, "normal": Vector3.UP}
	# cell by cell along the ray (a cell's centre is a whole number, so its sides are on the halves)
	var cx := floori(from.x + 0.5)
	var cz := floori(from.z + 0.5)
	var sx := 1 if dir.x > 0.0 else -1
	var sz := 1 if dir.z > 0.0 else -1
	var step_x := absf(1.0 / dir.x) if absf(dir.x) > 0.000001 else INF
	var step_z := absf(1.0 / dir.z) if absf(dir.z) > 0.000001 else INF
	var next_x := (cx + 0.5 * sx - from.x) / dir.x if step_x != INF else INF
	var next_z := (cz + 0.5 * sz - from.z) / dir.z if step_z != INF else INF
	var t_in := 0.0
	var face := Vector3.ZERO                       # the side the ray came into this cell through
	for _i in 4 * n + 800:
		if t_in > reach: break
		var t_out := minf(next_x, next_z)
		if cx >= 0 and cz >= 0 and cx < n and cz < n and ed.grid[cz][cx] == ed.WALL:
			var h := _wall_height(Vector2i(cx, cz))
			if from.y + dir.y * t_in <= h:
				if t_in > 0.0:                         # (not the wall the camera itself is in)
					return {"t": t_in, "pos": from + dir * t_in, "normal": face}
			elif dir.y < 0.0:
				var t_top := (h - from.y) / dir.y
				if t_top <= t_out:
					return {"t": t_top, "pos": from + dir * t_top, "normal": Vector3.UP}
		if t_out == INF: break
		t_in = t_out
		if next_x < next_z:
			cx += sx
			next_x += step_x
			face = Vector3(-sx, 0, 0)
		else:
			cz += sz
			next_z += step_z
			face = Vector3(0, 0, -sz)
	return floor_hit

## Where the ray enters a box `ext` across centred on `xf` and turned with it: [how far, that side's normal].
## [] if it misses, or starts inside.
func _ray_box(from: Vector3, dir: Vector3, xf: Transform3D, ext: Vector3) -> Array:
	var inv := xf.affine_inverse()
	var o: Vector3 = inv * from
	var d: Vector3 = inv.basis * dir
	var t0 := 0.0
	var t1 := INF
	var axis := -1
	for i in 3:
		var half: float = ext[i] * 0.5
		var oi: float = o[i]
		var di: float = d[i]
		if absf(di) < 0.0000001:
			if absf(oi) > half: return []
			continue
		var a := (-half - oi) / di
		var b := (half - oi) / di
		if a > b:
			var swap := a
			a = b
			b = swap
		if a > t0:
			t0 = a
			axis = i
		t1 = minf(t1, b)
		if t0 > t1: return []
	if axis < 0: return []
	var nrm := Vector3.ZERO
	nrm[axis] = -signf(d[axis])
	return [t0, (xf.basis * nrm).normalized()]

## The upright boxes of an object a prop can hang on, as _object() draws them: [[Transform3D, size]].
## A thin, half, corner or curved wall, a door's partition, a pillar or a column; [] for anything else.
func _solid_boxes(o: Dictionary) -> Array:
	var out: Array = []
	var h := _wall_height(Vector2i(roundi(o.pos_x), roundi(o.pos_y)))
	var xf := Transform3D(Basis(Vector3.UP, -deg_to_rad(o.rotation)), Vector3(o.pos_x, 0.0, o.pos_y))
	var sh: String = ed._shape(o.type)
	if str(o.type) == "door":
		var depth := float(ed._info("door").get("thickness", 0.3)) * M
		out.append([xf * Transform3D(Basis.IDENTITY, Vector3(0, h * 0.5, 0)), Vector3(depth, h, float(o.scale))])
	elif sh in ["slab", "corner", "arc", "pillar", "column"]:
		var hm := float(ed._param(o, "height", 0.0))
		var ph := h if hm <= 0.0 else minf(h, _up(hm))
		var t: float = ed._thick_cells(o)
		if sh in ["pillar", "column"]:
			out.append([xf * Transform3D(Basis.IDENTITY, Vector3(0, ph * 0.5, 0)), Vector3(t, ph, t)])
		else:
			var path: PackedVector2Array = ed._shape_path(o)
			for i in path.size() - 1:
				var run := path[i + 1] - path[i]
				var mid := (path[i] + path[i + 1]) * 0.5
				out.append([xf * Transform3D(Basis(Vector3.UP, atan2(-run.y, run.x)), Vector3(mid.x, ph * 0.5, mid.y)), Vector3(run.length() + t, ph, t)])
	return out

## _cast(), and the sides of the wall objects in the way (not object `skip`: the one being moved)
func _cast_all(from: Vector3, dir: Vector3, skip := -1) -> Dictionary:
	var hit := _cast(from, dir)
	for i in ed.objects.size():
		if i == skip: continue
		for box: Array in _solid_boxes(ed.objects[i]):
			var r := _ray_box(from, dir, box[0], box[1])
			if r.is_empty() or absf((r[1] as Vector3).y) > 0.5: continue
			if hit.is_empty() or float(r[0]) < float(hit.t):
				hit = {"t": float(r[0]), "pos": from + dir * float(r[0]), "normal": r[1]}
		# the top of a prop: things are stood on it (a lamp on a table, a TV on a sideboard)
		var pb := _prop_box(ed.objects[i])
		if pb.is_empty(): continue
		var top := _ray_box(from, dir, pb[0], pb[1])
		if top.is_empty() or (top[1] as Vector3).y < 0.5: continue
		if hit.is_empty() or float(top[0]) < float(hit.t):
			hit = {"t": float(top[0]), "pos": from + dir * float(top[0]), "normal": Vector3.UP, "on": i}
	return hit

## Put object `o` where the ray landed (`hit`, from _cast_all). `off`: where its origin was from the floor
## point it was picked up by, so a piece being moved doesn't jump to the mouse.
func _put(o: Dictionary, hit: Dictionary, off := Vector2.ZERO) -> void:
	var t := str(o.type)
	var info: Dictionary = ed._info(t)
	var loose: bool = Input.is_key_pressed(KEY_ALT) or not ed.snap
	var nrm: Vector3 = hit.normal
	var at: Vector3 = hit.pos
	var p := Vector2(at.x, at.z)
	var out := Vector2(nrm.x, nrm.z).normalized()          # away from the wall, on the map
	var on_wall := absf(nrm.y) < 0.5
	var model := _model_of(o)
	if on_wall and str(info.get("mount", "")) == "wall" and model.is_empty():
		# a window: flat on the face pointed at, facing out of it, its glass centred on the height pointed at
		p = ed._snap_pos(p + out * 0.001)
		o.rotation = fposmod(rad_to_deg(out.angle()), 360.0)
		var sill := maxf(0.0, at.y * 9.0 / vscale - float(ed._param(o, "height", 2.2)) * 0.5)
		o["elev"] = sill if loose else snappedf(sill, 0.05)
		o.pos_x = clampf(p.x, 0.0, ed.grid_size - 1)
		o.pos_y = clampf(p.y, 0.0, ed.grid_size - 1)
		return
	if on_wall and str(info.get("mount", "")) == "wall" and not model.is_empty():
		# flat on the wall: its back (the model's -x side) on the face, facing out, its middle at the height pointed at
		var b: AABB = model.bounds
		var k := float(o.scale)
		if not loose:                                      # along the wall: cell middles and cell edges
			if absf(nrm.x) > 0.99: p.y = snappedf(p.y, ed.SNAP_STEP)
			elif absf(nrm.z) > 0.99: p.x = snappedf(p.x, ed.SNAP_STEP)
		p += out * (-b.position.x * k * M + 0.0005)
		o.rotation = fposmod(rad_to_deg(out.angle()), 360.0)
		var lift := maxf(0.0, at.y * 9.0 / vscale - (b.position.y + b.size.y * 0.5) * k)
		o["elev"] = lift if loose else snappedf(lift, 0.05)
	else:
		if hit.has("on") and not on_wall:                  # on another prop's top: stood on it, right where you point
			p += off
			if (info.get("params", {}) as Dictionary).has("elev"):
				o["elev"] = snappedf(maxf(0.0, at.y * 9.0 / vscale), 0.005)
		elif on_wall and not model.is_empty():               # a floor prop pointed at a wall: at its foot, clear of it
			p += out * (float(info.get("thickness", 0.3)) * float(o.scale) * M * 0.5 + 0.001)
		elif on_wall:                                      # a wall piece: on that face's cell edge
			p = ed._snap_pos(p + out * 0.001)
		else:
			p = ed._snap_pos(p + off, t)
		if model.is_empty() and is_zero_approx(fposmod(float(o.rotation), 90.0)):     # as on the map: fitted to the walls round it
			o.rotation = ed._wall_align(p, float(o.rotation), t)
	var top: float = ed.grid_size - 1
	o.pos_x = clampf(p.x, 0.0, top)
	o.pos_y = clampf(p.y, 0.0, top)

## The ghost: the piece in hand, where a click would put it now
func _aim() -> void:
	_aim_stale = false
	for c in ghost_root.get_children():
		ghost_root.remove_child(c)
		c.queue_free()
	ghost = {}
	var t := _placing()
	if t == "" or not _mouse_in or not visible: return
	var ray := _mouse_ray()
	var hit := _cast_all(ray[0], ray[1])
	if hit.is_empty(): return
	ghost = ed._new_object(t, Vector2.ZERO, ed.place_rot)
	if place_elev.has(t) and ghost.has("elev"): ghost["elev"] = place_elev[t]
	_put(ghost, hit)
	_object(ghost, _unit, ghost_root)
	_mark(ghost, ghost_root)

## A left click with a piece in hand: the ghost becomes an object of the level (one undo step)
func _place() -> void:
	if ghost.is_empty():
		ed._status("Nothing to put it on there: point at the floor or a wall")
		return
	ed._push_undo()
	var made: Dictionary = ghost.duplicate(true)
	ed.objects.append(made)
	if obj_nodes.size() == ed.objects.size() - 1:          # shown at once; the level is rebuilt a moment later
		var holder := Node3D.new()
		world.add_child(holder)
		obj_nodes.append(holder)
		_object(made, _unit, holder)
	ed._select(ed.objects.size() - 1)
	ed._mark_dirty()
	ed._status("Placed  " + ed._describe(made))

## How far along the ray object `o` is, -1 if the ray misses it
## A model prop's box in this view: [Transform3D, size], [] for an object with no model
func _prop_box(o: Dictionary) -> Array:
	var model := _model_of(o)
	if model.is_empty(): return []
	var base := Transform3D(Basis(Vector3.UP, -deg_to_rad(o.rotation)), Vector3(o.pos_x, 0.0, o.pos_y))
	var b: AABB = model.bounds
	var k: float = float(o.scale) * M
	var s := Vector3(k, k * 0.5 * vscale, k)
	var mid := b.get_center() * s + Vector3(0, _up(float(ed._param(o, "elev", 0.0))), 0)
	return [base * Transform3D(Basis.IDENTITY, mid), Vector3(maxf(b.size.x * s.x, 0.02), maxf(b.size.y * s.y, 0.004), maxf(b.size.z * s.z, 0.02))]

func _ray_object(from: Vector3, dir: Vector3, o: Dictionary) -> float:
	var base := Transform3D(Basis(Vector3.UP, -deg_to_rad(o.rotation)), Vector3(o.pos_x, 0.0, o.pos_y))
	var boxes: Array = []
	var pb := _prop_box(o)
	if not pb.is_empty():
		var sz: Vector3 = pb[1]
		boxes.append([pb[0], Vector3(maxf(sz.x, 0.08), maxf(sz.y, 0.08), maxf(sz.z, 0.08))])
	else:
		boxes = _solid_boxes(o)
		if boxes.is_empty():                               # an arch, a stairwell, a trigger (by its floor only, so what stands in it can be picked)
			var foot: Rect2 = ed._obj_bounds(o)
			var tall := 0.03 if ed._shape(o.type) == "zone" else _wall_height(Vector2i(roundi(o.pos_x), roundi(o.pos_y)))
			boxes.append([base * Transform3D(Basis.IDENTITY, Vector3(foot.get_center().x, tall * 0.5, foot.get_center().y)),
				Vector3(maxf(foot.size.x, 0.08), tall, maxf(foot.size.y, 0.08))])
	var best := -1.0
	for box: Array in boxes:
		var r := _ray_box(from, dir, box[0], box[1])
		if not r.is_empty() and (best < 0.0 or float(r[0]) < best): best = float(r[0])
	return best

## The object under the mouse's ray that isn't behind a wall or under the floor, -1 for none
func _pick(from: Vector3, dir: Vector3) -> int:
	var wall := _cast(from, dir)
	var best_t: float = float(wall.t) + 0.05 if not wall.is_empty() else INF
	var best := -1
	for i in ed.objects.size():
		var t := _ray_object(from, dir, ed.objects[i])
		if t >= 0.0 and t < best_t:
			best_t = t
			best = i
	return best

## A left press with Select: pick what is under the mouse; keeping the button down then moves it
func _grab() -> void:
	var ray := _mouse_ray()
	var i := _pick(ray[0], ray[1])
	ed._select(i)
	grab = -1
	if i < 0: return
	var o: Dictionary = ed.objects[i]
	if ed._is_stairs(str(o.type)):
		ed._status("A stairwell is moved on the map (F4): it stands on the same cells of two floors")
		return
	ed._status(ed._describe(o))
	grab = i
	grab_from = _mouse
	grab_moved = false
	grab_off = Vector2.ZERO
	var hit := _cast_all(ray[0], ray[1], i)
	if not hit.is_empty() and (hit.normal as Vector3).y > 0.5:
		grab_off = Vector2(o.pos_x, o.pos_y) - Vector2(hit.pos.x, hit.pos.z)
	# standing on another prop? (straight down from just over its foot)
	var lift := _up(float(ed._param(o, "elev", 0.0)))
	var under := _cast_all(Vector3(o.pos_x, lift + 0.01, o.pos_y), Vector3.DOWN, i)
	_grab_stacked = lift > 0.001 and under.has("on") and absf(float(under.pos.y) - lift) < 0.02

## The grabbed object follows the mouse (one undo step, pushed when it first moves)
func _drag_grabbed() -> void:
	if grab >= ed.objects.size():
		grab = -1
		return
	if not grab_moved:
		if _mouse.distance_to(grab_from) < 5.0: return
		ed._push_undo()
		grab_moved = true
	var ray := _mouse_ray()
	var hit := _cast_all(ray[0], ray[1], grab)
	if hit.is_empty(): return
	var o: Dictionary = ed.objects[grab]
	_put(o, hit, grab_off)
	if hit.has("on"):
		_grab_stacked = true
	elif _grab_stacked and (hit.normal as Vector3).y > 0.5:   # taken off the table onto the floor: back down to the floor
		var dp: Dictionary = ed._info(o.type).get("params", {})
		if dp.has("elev"): o["elev"] = float(dp.elev)
	_refresh(grab)
	ed._sync_inspector()
	ed._mark_dirty()
	ed._status(ed._describe(o))

## Object `i` drawn again where it is now, without rebuilding the level round it
func _refresh(i: int) -> void:
	_shown_sel = -2
	if i < 0 or i >= obj_nodes.size() or obj_nodes.size() != ed.objects.size() or not is_instance_valid(obj_nodes[i]): return
	var holder: Node3D = obj_nodes[i]
	for c in holder.get_children():
		holder.remove_child(c)
		c.queue_free()
	_object(ed.objects[i], _unit, holder)

## Shift + wheel sizes, Alt + wheel turns 15 degrees, Ctrl + wheel raises / lowers 10 cm: the piece in hand,
## else the selected object
func _wheel_edit(up: bool, mb: InputEventMouseButton) -> void:
	var s := 1.0 if up else -1.0
	var t := _placing()
	if t != "":
		var info: Dictionary = ed._info(t)
		if mb.alt_pressed:
			ed.place_rot = fposmod(float(ed.place_rot) + s * 15.0, 360.0)
		elif mb.ctrl_pressed:
			var params: Dictionary = info.get("params", {})
			if not params.has("elev"): return
			place_elev[t] = clampf(snappedf(float(place_elev.get(t, params.elev)) + s * 0.1, 0.05), 0.0, 10.8)
		else:
			var step: float = 0.1 if info.has("model") else float(ed.SNAP_STEP)
			ed.place_scales[t] = clampf(snappedf(float(ed._place_scale(t)) + s * step, 0.05), 0.5, float(ed._max_scale(t)))
		_aim_stale = true
		return
	var i: int = ed.selected
	if i < 0 or i >= ed.objects.size() or ed.multi.size() > 1: return
	var o: Dictionary = ed.objects[i]
	if ed._is_stairs(str(o.type)): return
	if mb.ctrl_pressed:
		if not (ed._info(o.type).get("params", {}) as Dictionary).has("elev"): return
		ed._set_prop("elev", clampf(snappedf(float(ed._param(o, "elev", 0.0)) + s * 0.1, 0.05), 0.0, 10.8))
	elif ed._info(o.type).has("model") and not mb.alt_pressed:
		ed._set_prop("scale", clampf(snappedf(float(o.scale) + s * 0.1, 0.05), 0.5, float(ed._max_scale(o.type))))
	else:
		ed._wheel_edit(up, mb.alt_pressed)                 # as on the map
		_refresh(i)
		return
	_refresh(i)
	ed._sync_inspector()
	ed._status(ed._describe(o))

## The cyan marks of an object in hand or selected: its origin and the way it faces on the floor, a stem up
## to it when it is off the floor, and a see-through box round it (a model) or over its footprint
## Lift the piece in hand (or the selected one, if it has a height) by `s` steps of ELEV_STEP metres
func _step_elev(s: float) -> void:
	var step := ELEV_STEP * s
	var t := _placing()
	if t != "":
		var params: Dictionary = ed._info(t).get("params", {})
		if not params.has("elev"): return
		place_elev[t] = clampf(snappedf(float(place_elev.get(t, params.elev)) + step, 0.05), 0.0, 10.8)
		_aim_stale = true
		ed._status("Height %.2f m" % float(place_elev[t]))
		return
	var i: int = ed.selected
	if i < 0 or i >= ed.objects.size() or ed.multi.size() > 1: return
	var o: Dictionary = ed.objects[i]
	if ed._is_stairs(str(o.type)) or not (ed._info(o.type).get("params", {}) as Dictionary).has("elev"): return
	ed._set_prop("elev", clampf(snappedf(float(ed._param(o, "elev", 0.0)) + step, 0.05), 0.0, 10.8))
	_refresh(i)
	ed._sync_inspector()
	ed._status(ed._describe(o))

## F: move the view onto the selected object, close enough to see its placement
func _frame_selected() -> void:
	var i: int = ed.selected
	if i < 0 or i >= ed.objects.size(): return
	var o: Dictionary = ed.objects[i]
	target = Vector3(float(o.pos_x), 0.0, float(o.pos_y))
	dist = 8.0
	_place_camera()

## Home: back to the whole map from the same side as before
func _reset_view() -> void:
	var n: int = ed.grid_size
	target = Vector3(n * 0.5, 0.0, n * 0.5)
	dist = n * 0.9
	yaw = 0.6
	pitch = -0.9
	_place_camera()

func _mark(o: Dictionary, parent: Node3D) -> void:
	var base := Transform3D(Basis(Vector3.UP, -deg_to_rad(o.rotation)), Vector3(o.pos_x, 0.0, o.pos_y))
	var up := _up(float(ed._param(o, "elev", 0.0)))
	var parts: Array = [[Vector3(0.2, 0.012, 0), Vector3(0.4, 0.012, 0.024), _sel_line],
		[Vector3(0, 0.012, 0), Vector3(0.07, 0.016, 0.07), _sel_line]]
	if up > 0.02: parts.append([Vector3(0, up * 0.5, 0), Vector3(0.012, up, 0.012), _sel_line])
	var model := _model_of(o)
	if model.is_empty():
		var foot: Rect2 = ed._obj_bounds(o)
		parts.append([Vector3(foot.get_center().x, 0.01, foot.get_center().y), Vector3(foot.size.x, 0.008, foot.size.y), _sel_fill])
	for p: Array in parts:
		var mi := MeshInstance3D.new()
		mi.mesh = _unit
		mi.transform = base * Transform3D(Basis.from_scale(p[1]), p[0])
		mi.material_override = p[2]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mi)
	if model.is_empty(): return
	var b: AABB = model.bounds
	var cage := MeshInstance3D.new()
	cage.mesh = _unit
	cage.transform = _prop_xf(o) * Transform3D(Basis.from_scale(Vector3(maxf(b.size.x, 0.02), maxf(b.size.y, 0.02), maxf(b.size.z, 0.02)) * 1.06), b.get_center())
	cage.material_override = _sel_fill
	cage.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(cage)

func _show_selection(sel: int) -> void:
	_shown_sel = sel
	for c in sel_root.get_children():
		sel_root.remove_child(c)
		c.queue_free()
	if sel < 0: return
	for k: int in ed._group():
		if k >= 0 and k < ed.objects.size(): _mark(ed.objects[k], sel_root)
