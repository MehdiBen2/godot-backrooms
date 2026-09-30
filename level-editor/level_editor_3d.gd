extends SubViewportContainer
## The editor's 3D view: the level as simple boxes you can orbit, so you can see walls, floors, painted
## materials, zones and objects at a glance. It is rebuilt from the editor's data (grid, zones, paint,
## objects) whenever something changes while it is open; nothing here is saved.
##   right drag orbit   middle drag / Shift+right drag pan   wheel zoom   WASD pan   C toggles the ceiling
## 1 cell = 1 unit; the game's cell is 4.5 m and its wall 2.7 m, hence WALL_H.

const WALL_H := 0.6
const TALL_H := 1.4
const LOW_H := 0.42
const REBUILD_DELAY := 0.25

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
var vscale := 1.0                        # height multiplier: 2 in walk mode
var walk_pos := Vector3.ZERO
var walk_light: OmniLight3D
var _tex_cache := {}                     # pbr name -> StandardMaterial3D
var _flat_cache := {}                    # Color -> StandardMaterial3D

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
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("0d0c08")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("8a8676")
	env.ambient_light_energy = 0.8
	var we := WorldEnvironment.new()
	we.environment = env
	vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.6, 0.0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	vp.add_child(sun)
	cam = Camera3D.new()
	cam.far = 500.0
	vp.add_child(cam)
	walk_light = OmniLight3D.new()              # a lamp you carry, so rooms under the ceiling aren't black
	walk_light.omni_range = 4.0
	walk_light.light_energy = 1.2
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
	_place_camera()

const HUD_ORBIT := "3D VIEW   right drag orbit   middle drag pan   wheel zoom   WASD move   E walk"
const HUD_WALK := "WALKING   WASD walk   Shift run   right drag / arrows look   E back to overview"

## Walk mode on / off: start from the spawn marker (else the middle of the view), heights at true scale
func toggle_walk() -> void:
	walking = not walking
	vscale = 2.0 if walking else 1.0
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
	var dir := Vector2.ZERO
	if has_focus() or get_global_rect().has_point(get_global_mouse_position()):
		dir = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
		if Input.is_key_pressed(KEY_A): dir.x -= 1.0
		if Input.is_key_pressed(KEY_D): dir.x += 1.0
		if Input.is_key_pressed(KEY_W): dir.y -= 1.0
		if Input.is_key_pressed(KEY_S): dir.y += 1.0
	if walking:
		if Input.is_key_pressed(KEY_LEFT): yaw += 1.8 * dt
		if Input.is_key_pressed(KEY_RIGHT): yaw -= 1.8 * dt
		var ahead := -dir.y if not (Input.is_key_pressed(KEY_UP) or Input.is_key_pressed(KEY_DOWN)) else \
			(1.0 if Input.is_key_pressed(KEY_W) else (-1.0 if Input.is_key_pressed(KEY_S) else 0.0))
		var side := (1.0 if Input.is_key_pressed(KEY_D) else 0.0) - (1.0 if Input.is_key_pressed(KEY_A) else 0.0)
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
	if walking:
		var eye := walk_pos + Vector3(0, EYE, 0)
		var look := Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
		cam.look_at_from_position(eye, eye + look, Vector3.UP)
		return
	var off := Vector3(sin(yaw) * cos(pitch), -sin(pitch), cos(yaw) * cos(pitch)) * dist
	cam.look_at_from_position(target + off, target, Vector3.UP)

func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		var m: InputEventMouseMotion = e
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
	elif e is InputEventMouseButton and e.pressed:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP: dist = maxf(dist * 0.88, 2.0)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN: dist = minf(dist * 1.14, 300.0)
		else: return
		_place_camera()
	elif e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_E and not e.ctrl_pressed:
		toggle_walk()
	elif e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_C and not e.ctrl_pressed:
		ceiling_check.button_pressed = not ceiling_check.button_pressed

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
	var all_low := true
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var n := c + Vector2i(dx, dz)
			if ed.zones["tall"].has(n): return TALL_H * vscale
			if not ed.zones["low"].has(n): all_low = false
	return (LOW_H if all_low else WALL_H) * vscale

func _rebuild() -> void:
	_clear()
	var n: int = ed.grid_size
	var unit := BoxMesh.new()
	unit.size = Vector3.ONE
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
	for o: Dictionary in ed.objects:
		_object(o, unit)

func _object(o: Dictionary, unit: Mesh) -> void:
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
		"arch":
			var pillar := float(info.get("pillar", 0.75)) / 4.5
			var r := span * 0.5 - pillar
			var top := 0.42                              # crown, flattened to a lintel
			for side in [-1.0, 1.0]:
				parts.append([Vector3(0, h * 0.5, side * (r + pillar * 0.5)), Vector3(1, h, pillar), wall_mat])
			parts.append([Vector3(0, (h + top) * 0.5, 0), Vector3(1, h - top, r * 2.0), wall_mat])
		"door":
			var frame := _flat(Color("6b4a2e"))
			parts.append([Vector3(0, h * 0.42, 0), Vector3(depth, h * 0.84, span * 0.8), frame])
			parts.append([Vector3(0, h * 0.92, 0), Vector3(depth * 1.4, h * 0.16, span), wall_mat])
			for side in [-1.0, 1.0]:
				parts.append([Vector3(0, h * 0.5, side * span * 0.45), Vector3(depth * 1.4, h, span * 0.1), wall_mat])
		"stairs_up", "stairs_down":
			var rise := 0.35 * vscale * (1.0 if o.type == "stairs_up" else -1.0)       # 3 m in cell units, about
			var steps := 8
			for i in steps:
				var top := rise * (i + 1) / steps
				var base := 0.0 if rise > 0 else rise
				parts.append([Vector3(-0.5 + (i + 0.5) / steps, (top + base) * 0.5, 0), Vector3(1.0 / steps, absf(top - base) + 0.01, span), _flat(col)])
		_:
			var sh: String = ed._shape(o.type)
			var hm := float(ed._param(o, "height", 0.0))
			var ph := h if hm <= 0.0 else minf(h, hm / 9.0 * vscale)        # metres -> this view's squashed heights (5.4 m = 0.6)
			var t: float = ed._thick_cells(o)
			match sh:
				"slab", "corner", "arc":
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
				"zone":
					var zc := col
					zc.a = 0.22
					var zm := _flat(zc)
					zm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
					parts.append([Vector3(0, h * 0.4, 0), Vector3(float(ed._param(o, "depth", 2.0)), h * 0.8, span), zm])
				_:
					var s := 0.28 * span
					parts.append([Vector3(0, s * 0.5, 0), Vector3(s, s, s), _flat(col)])
	var xf := Transform3D(Basis(Vector3.UP, yaw_rad), pos)
	for p in parts:
		var mi := MeshInstance3D.new()
		mi.mesh = p[4] if p.size() > 4 else unit
		var yaw: float = p[3] if p.size() > 3 else 0.0
		mi.transform = xf * Transform3D(Basis(Vector3.UP, yaw) * Basis.from_scale(p[1]), p[0])
		mi.material_override = p[2]
		world.add_child(mi)
