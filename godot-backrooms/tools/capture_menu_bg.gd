extends SceneTree
## Renders the title screen backdrops: textures/menu/bg_0.png .. bg_N.png (main_menu.gd cycles BG_SET).
## Run: Godot --path . --resolution 1920x1080 --script tools/capture_menu_bg.gd
##
## Staged shots rather than a dozen copies of "empty hall, eye level": halls stretching into the dark from
## the floor, eye level and a long lens, peeks round corners, a lone tube seen from the carpet, halls whose
## tubes give out part-way into black, and flashlight-only frames in a power cut. Never a creature: the
## monsters are hidden so the menu spoils nothing. Every shot is rendered at the Ultra preset at full
## resolution, with the viewmodel and HUD hidden, and cropped to 16:9.

const OUT := "res://textures/menu/bg_%d.png"
const W := 1920
const H := 1080

var main: Node
var level: Node
var player: Node3D
var cam: Camera3D
var cell := 4.5
var n := 0
var used: Array[Vector3] = []

func _initialize() -> void:
	root.get_node("Game").respawned = true
	var gfx := root.get_node("Gfx")
	gfx.set_preset("ultra")
	gfx.s["adapt"] = false
	gfx.s["scale"] = 100
	gfx.adapt_ratio = 1.0
	gfx.apply()
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	DirAccess.make_dir_recursive_absolute("res://textures/menu")
	await create_timer(4.0).timeout
	main.get_node("UI").visible = false
	level = main.get_node("Level")
	player = main.get_node("Player")
	cam = player.get_node("Camera3D")
	cell = level.CELL
	player.set_physics_process(false)
	player.set_process(false)
	for ch in cam.get_children():                       # torch / arms viewmodel, keep the lights
		if ch is Node3D and not (ch is Light3D):
			ch.visible = false
	# no creature in any frame: the menu never spoils what is waiting in there
	for nm in ["Entity", "Mannequin", "Mimic", "Killer", "Eyes", "Events"]:
		var e := main.get_node_or_null(nm)
		if e == null: continue
		e.process_mode = Node.PROCESS_MODE_DISABLED
		if e is Node3D: (e as Node3D).visible = false
		for g in e.find_children("*", "Node3D", false, false): g.visible = false

	for p in level.find_children("*", "Node3D", true, false):       # no glowing pickups in the frame
		var sc: Script = p.get_script()
		if sc and sc.resource_path.ends_with("_pickup.gd"): p.visible = false
	var halls := _halls()
	var corners := _corners()
	# 1. the hall: long, empty, the far end lost in the dark
	for i in 3:
		var h = _take(halls)
		if h == null: break
		var off: float = [0.9, -1.1, 0.0][i]
		await _shot(h.at - h.dir * cell * 1.4 + _side(h.dir) * off, h.at + h.dir * cell * 8.0, [0.35, 1.75, 1.3][i], [3.0, -2.5, 0.0][i], [84.0, 58.0, 45.0][i])
	# 2. round a corner: tight against the wall end, peering past it
	for i in 3:
		var c = _take(corners)
		if c == null: break
		await _shot(c.at, c.at + (c.dir + c.side * 0.55).normalized() * cell * 6.0, [1.45, 0.8, 1.7][i], [-5.0, 4.0, -1.5][i], [76.0, 80.0, 64.0][i])
	# 3. a lone tube from the carpet, looking up
	var h3 = _take(halls)
	if h3: await _shot(h3.at - h3.dir * cell * 0.7, h3.at + Vector3(0, 2.9, 0) + h3.dir * cell * 0.6, 0.25, 6.0, 88.0)
	# 4. the lights give out part-way down: the hall runs lit, then into black
	for i in 2:
		var h = _take(halls)
		if h == null: break
		var cut := []
		for f in level.lit:
			var rel: Vector3 = f.pos - h.at
			var along := rel.dot(h.dir)
			if along > cell * [2.5, 1.5][i] and absf(rel.dot(_side(h.dir))) < cell * 3.0:
				level.cut_fixture(f, 999.0)
				cut.append(f)
		await create_timer(1.0).timeout
		await _shot(h.at - h.dir * cell * 1.2 + _side(h.dir) * [-0.6, 0.7][i], h.at + h.dir * cell * 7.0, [1.6, 0.6][i], [2.0, -4.0][i], [66.0, 78.0][i])
		for f in cut: level.cut_fixture(f, 0.01)
	# 5. power cut: nothing but the flashlight
	level.cut_power(999.0)
	await create_timer(3.0).timeout
	for i in 3:
		var x = _take(halls) if i != 1 else _take(corners)
		if x == null: continue
		if i == 1:
			await _shot(x.at, x.at + (x.dir + x.side * 0.5).normalized() * cell * 5.0, 1.5, 3.0, 72.0)
		else:
			await _shot(x.at - x.dir * cell * 0.8, x.at + x.dir * cell * 6.0 + Vector3(0, [0.3, 0.0, -0.9][i], 0), [1.6, 0.0, 1.2][i], [1.5, 0.0, -6.0][i], [72.0, 0.0, 80.0][i])
	print("captured ", n)
	quit()

## No wall cell on the straight line between two points
func _clear(a: Vector3, b: Vector3) -> bool:
	var steps := ceili(a.distance_to(b) / 0.25)
	for i in range(1, steps):
		if level.walls.has(level.cell_of(a.lerp(b, float(i) / steps))): return false
	return true

func _side(d: Vector3) -> Vector3:
	return Vector3(-d.z, 0.0, d.x)

func _near_used(p: Vector3, r: float) -> bool:
	for u in used:
		if u.distance_to(p) < r: return true
	return false

func _take(list: Array):
	while not list.is_empty():
		var x = list.pop_front()
		if not _near_used(x.at, cell * 4.0):
			used.append(x.at)
			return x
	return null

## Lit fixtures with a long straight run of open cells in front of them (longest first)
func _halls() -> Array:
	var out := []
	for f in level.lit:
		var c: Vector2i = level.cell_of(f.pos)
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var open := 0
			while open < 14 and not level.walls.has(c + d * (open + 1)) and not level.pits.has(c + d * (open + 1)):
				open += 1
			if open >= 6 and not level.walls.has(c - d):
				out.append({"at": Vector3(c.x * cell, 0.0, c.y * cell), "dir": Vector3(d.x, 0, d.y), "open": open})
	out.sort_custom(func(a, b): return a.open > b.open)
	return out

## Open cells beside the end of a wall: step forward and the hall opens up round it
func _corners() -> Array:
	var out := []
	for w: Vector2i in level.walls.keys():
		for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var s := Vector2i(-d.y, d.x)
			var at: Vector2i = w - s                                 # beside the wall, facing along it
			var tip: Vector2i = w + d                                # the cell past the wall's end
			if level.walls.has(at) or level.walls.has(tip) or level.walls.has(tip + s): continue
			if level.walls.has(at - d) or level.walls.has(at + d * 2): continue
			var run := 0
			while run < 8 and not level.walls.has(tip + s * (run + 1)): run += 1
			if run < 4: continue
			var sv := Vector3(s.x, 0, s.y)
			out.append({"at": Vector3(at.x * cell, 0.0, at.y * cell) + sv * cell * 0.3, "dir": Vector3(d.x, 0, d.y), "side": sv, "run": run})
	# only corners a working tube reaches: in an unlit zone the frame is just black
	out.sort_custom(func(a, b): return level.tube_light_at(a.at) > level.tube_light_at(b.at))
	out = out.slice(0, 24)
	out.shuffle()
	return out

## Put the camera at `from` (y is taken from `h`, eye height in metres) aiming at `to`, roll/FOV as given
func _shot(from: Vector3, to: Vector3, h: float, roll: float, fov: float) -> void:
	player.global_position = Vector3(from.x, 0.1, from.z)
	var eye := Vector3(from.x, 0.1 + h, from.z)
	var v := to - eye
	player.rotation = Vector3(0.0, atan2(-v.x, -v.z), 0.0)
	cam.position = Vector3(0, h, 0)
	cam.rotation = Vector3(atan2(v.y, Vector2(v.x, v.z).length()), 0.0, deg_to_rad(roll))
	cam.fov = fov
	player._sync_flashlight_aim(1.0)                 # the player's own _process, which aims the torch, is off
	player._update_flashlight(0.5)
	# the beam from where the (hidden) torch would be: just in front of the lens, clear of the body's shadow
	var beam := cam.global_transform.translated_local(Vector3(0.18, -0.12, -0.5))
	player.flash.global_transform = beam
	if player.flash_spill: player.flash_spill.global_transform = beam
	await create_timer(2.5).timeout                  # let TAA / GI / exposure settle
	var img := root.get_texture().get_image()
	# crop to 16:9 around the centre, then scale to 1920x1080
	var iw := img.get_width()
	var ih := img.get_height()
	var ch := mini(ih, iw * H / W)
	var cw := mini(iw, ch * W / H)
	img = img.get_region(Rect2i((iw - cw) / 2, (ih - ch) / 2, cw, ch))
	img.resize(W, H, Image.INTERPOLATE_LANCZOS)
	img.save_png(OUT % n)
	print("shot ", n, " at ", from, " -> ", to)
	n += 1
