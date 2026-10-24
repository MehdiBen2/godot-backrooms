extends SceneTree
## Renders the title screen backdrops: textures/menu/bg_0.png .. bg_N.png (main_menu.gd cycles BG_SET in order,
## from a random start). Two passes, one per level:
##   Godot --path . --resolution 1920x1080 --script tools/capture_menu_bg.gd                 (Level 0: bg_0..bg_8)
##   LEVEL=1 Godot --path . --resolution 1920x1080 --script tools/capture_menu_bg.gd         (Level 38: bg_9..bg_11)
##
## Staged tableaux, and the only thing in them is the mannequins: one at the far end of a hall where the tubes give
## out, the same hall twice with it closer the second time (bg_1 then bg_2, so the slideshow itself moves it), one
## waiting round a corner, a crowd with their backs turned except one, one caught in the torch in a power cut, one
## face down reaching for the lens with another standing behind, a dust-sheeted figure under the last working tube,
## a crowd dissolving into the dark, a headless one far too close. Never the creatures: the real hunters and the
## random decoy crowd are hidden, every figure here is placed by hand from mannequin_model.gd's sculpts. Every
## shot is rendered at the Ultra preset at full resolution, with the viewmodel and HUD hidden, and cropped to 16:9.

const MannequinModel := preload("res://scripts/Entities/mannequin/mannequin_model.gd")
const OUT := "res://textures/menu/bg_%d.png"
const W := 1920
const H := 1080
const FIRST := [0, 9]                       # by LEVEL: the first bg index the pass writes

var main: Node
var level: Node
var player: Node3D
var cam: Camera3D
var model: MannequinModel
var stage: Node3D                           # this shot's figures (cleared after every frame)
var rng := RandomNumberGenerator.new()
var cell := 4.5
var n := 0
var used: Array[Vector3] = []

func _initialize() -> void:
	var lv := int(OS.get_environment("LEVEL")) if OS.get_environment("LEVEL") != "" else 0
	var game := root.get_node("Game")
	game.level_index = lv
	game.respawned = true
	var gfx := root.get_node("Gfx")
	gfx.set_preset("ultra")
	gfx.s["scale"] = 100
	gfx.apply()
	rng.seed = 3507 + lv
	n = FIRST[lv]
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
	player.flash_on = false                             # lit by the tubes; only the power cut shot has the torch
	for ch in cam.get_children():                       # torch / arms viewmodel, keep the lights
		if ch is Node3D and not (ch is Light3D):
			ch.visible = false
	model = main.get_node("Mannequin").model            # loaded in its _ready, still usable with the node off
	# none of the game's own creatures: the hunters, the random decoy crowd, the scripted events
	for nm in ["Entity", "Mannequin", "Mimic", "Killer", "Eyes", "Events"]:
		var e := main.get_node_or_null(nm)
		if e == null: continue
		e.process_mode = Node.PROCESS_MODE_DISABLED
		if e is Node3D: (e as Node3D).visible = false
		for g in e.find_children("*", "Node3D", false, false): g.visible = false
	for p in level.find_children("*", "Node3D", true, false):       # no glowing pickups in the frame
		var sc: Script = p.get_script()
		if sc and sc.resource_path.ends_with("_pickup.gd"): p.visible = false
	stage = Node3D.new()
	main.add_child(stage)
	if lv == 0:
		await _level0()
	else:
		await _level38()
	print("captured up to bg_", n - 1)
	quit()

## Every distance below is in metres from the camera (`from`, on the floor) along the hall
func _level0() -> void:
	var halls := _halls()
	var corners := _corners()
	# 0. the end of the hall: it stands where the last tube gives out, long lens
	var h = _take(halls)
	if h:
		var from: Vector3 = h.at - h.dir * cell * 0.8
		var at = _at(from, h.dir, 15.0, 0.0)
		var cut := _dark_past(from, h.dir, 16.5) + _dark_outside([from, at], cell * 2.2)
		_stand(at, from, _pose({"headTilt": 0.22, "headNod": 0.08}))
		await _shot(from, at + Vector3(0, 1.0, 0), 1.6, 0.0, 30.0)
		_restore(cut)
	# 1 + 2. the same hall twice, the slideshow is what moves it: far and still, then near with its arm coming up
	h = _take(halls)
	if h:
		var from: Vector3 = h.at - h.dir * cell * 0.6 - _side(h.dir) * 0.5
		var look: Vector3 = from + h.dir * 20.0 + Vector3(0, 1.3, 0)
		var cut := _dark_past(from, h.dir, 21.0)
		_stand(_at(from, h.dir, 18.0, 0.6), from, _pose({}))
		await _shot(from, look, 1.55, -1.5, 42.0)
		_stand(_at(from, h.dir, 5.2, 0.3), from, _pose({"armR": 0.85, "splayR": 0.1, "headYaw": -0.35, "headTilt": -0.3, "lean": 0.08}))
		await _shot(from, look, 1.55, -1.5, 42.0)
		_restore(cut)
	# 3. round a corner: it has been waiting just past the wall's end
	var c = _take(corners)
	if c:
		var aim: Vector3 = (c.dir + c.side * 0.55).normalized()
		# sweep in from the wall's side: the first spot the camera can see is the one just past the wall's edge
		var wall_s := 1.0 if not _open(c.at + c.side * cell * 0.8) else -1.0
		var at: Vector3 = c.at + aim * 4.0
		for k in 13:
			var dir := aim.rotated(Vector3.UP, wall_s * (0.7 - k * 0.1))
			var p = _spot(c.at, dir, 4.6, 0.0)
			if p != null and c.at.distance_to(p) > 3.0:
				at = p
				break
		var cut := _dark_outside([c.at, at], cell * 2.0)
		_variant(at, c.at, _pose({"headYaw": 0.5, "headTilt": 0.35}), {"cracks": 0.7})
		await _shot(c.at, c.at + aim * 6.0 + Vector3(0, 1.1, 0), 1.45, -5.0, 62.0)
		_restore(cut)
	# 4. a line of them down the hall with their backs turned, except the one in the middle
	h = _take(halls)
	if h:
		var from: Vector3 = h.at - h.dir * cell * 0.5
		var away: Vector3 = from + h.dir * 200.0
		var cut := _dark_past(from, h.dir, 18.0)
		for i in 5:
			var at = _at(from, h.dir, 4.5 + i * 2.4, 0.9 if i % 2 == 0 else -0.8)
			if i == 2:
				_variant(at, from, _pose({"headTilt": 0.3}), {})
			else:
				_stand(at, at + (away - from), _pose({"headNod": 0.35, "headTilt": rng.randf_range(-0.15, 0.15)}))   # heads hung
		await _shot(from, from + h.dir * 12.0 + Vector3(0, 1.1, 0), 1.65, 1.0, 44.0)
		_restore(cut)
	# 5. from the carpet: one face down reaching for the lens, another standing well behind it
	h = _take(halls)
	if h:
		var from: Vector3 = h.at - h.dir * cell * 0.6
		var cut := _dark_past(from, h.dir, 14.0)
		_jointed(_at(from, h.dir, 2.3, 0.35), from, _pose({"mode": "prone", "armL": 2.8, "armR": 2.6, "splayL": 0.2, "splayR": 0.35, "headYaw": 0.6}))
		_stand(_at(from, h.dir, 9.0, -0.2), from, _pose({"headTilt": -0.25}))
		await _shot(from, from + h.dir * 9.0 + Vector3(0, 0.55, 0), 0.25, 4.0, 72.0)
		_restore(cut)
	# 6. under a dust sheet, beneath the only tube still working
	h = _take(halls)
	if h:
		var from: Vector3 = h.at - h.dir * cell * 0.5 + _side(h.dir) * 0.8
		var keep = _nearest_fixture(from + h.dir * 8.0)
		var at: Vector3 = _at(from, h.dir, 8.0, 0.0)
		if keep: at = _at(from, (Vector3(keep.pos.x, 0.0, keep.pos.z) - from).normalized(), Vector2(keep.pos.x - from.x, keep.pos.z - from.z).length(), 0.0)
		var cut := []
		for f in level.lit:
			if not is_same(f, keep) and f.pos.distance_to(from) < cell * 16.0:
				level.cut_fixture(f, 999.0)
				cut.append(f)
		_variant(at, from, _pose({}), {"sheet": true, "sheet_kind": 1, "seed": 4.0})
		await create_timer(1.0).timeout
		await _shot(from, at + Vector3(0, 1.0, 0), 1.5, -2.0, 40.0)
		_restore(cut)
	# 7. a crowd, all facing you, the back rows lost in the dark
	h = _take(halls)
	if h:
		var from: Vector3 = h.at - h.dir * cell * 0.5
		var cut := _dark_past(from, h.dir, 9.0) + _dark_outside([from], cell * 2.0)
		for row in 5:
			for col in 3:
				var at: Vector3 = from + h.dir * (5.0 + row * 1.8) + _side(h.dir) * ((col - 1) * 1.2 + rng.randf_range(-0.3, 0.3))
				if not _open(at): continue
				if rng.randf() < 0.35: _variant(at, from, _pose({"headTilt": rng.randf_range(-0.3, 0.3)}), MannequinModel.variant_style(rng))
				else: _stand(at, from, _pose({"headTilt": rng.randf_range(-0.3, 0.3), "headYaw": rng.randf_range(-0.2, 0.2)}))
		await _shot(from, from + h.dir * 9.0 + Vector3(0, 1.0, 0), 1.6, 0.0, 46.0)
		_restore(cut)
	# 8. power cut (last: the lamps stay out after it): the torch finds one, arms already half up
	h = _take(halls)
	if h:
		level.cut_power(999.0)
		await create_timer(3.0).timeout
		player.flash_on = true
		var from: Vector3 = h.at - h.dir * cell * 0.8
		var at = _at(from, h.dir, 3.4, 0.25)
		_stand(at, from, _pose({"armL": 0.9, "armR": 0.75, "splayL": 0.12, "splayR": 0.1, "headNod": -0.12, "lean": 0.1}))
		await _shot(from, at + Vector3(0, 1.1, 0), 1.6, 2.0, 60.0)

func _level38() -> void:
	var halls := _halls()
	# 9. headless, far too close, off to one side of the frame
	var h = _take(halls)
	if h:
		var from: Vector3 = h.at - h.dir * cell * 0.6
		var cut := _dark_past(from, h.dir, 10.0)
		_variant(_at(from, h.dir, 2.0, 0.6), from, _pose({"armL": 0.3}), {"missing": ["Head"], "cracks": 1.0})
		await _shot(from, from + h.dir * 12.0 + Vector3(0, 0.9, 0), 1.6, -6.0, 66.0)
		_restore(cut)
	# 10. a dressed display figure side-on to the hall, only its head turned round to watch you
	h = _take(halls)
	if h:
		var from: Vector3 = h.at - h.dir * cell * 0.6
		var at = _at(from, h.dir, 6.0, 1.6)
		var cut := _dark_past(from, h.dir, 12.0)
		_variant(at, at + _side(h.dir), _pose({"headYaw": 1.0, "headTilt": 0.2, "armR": 0.25}), {"clothes": true, "outfit": 7, "cracks": 0.4})
		await _shot(from, at + Vector3(0, 1.1, 0), 1.5, 3.0, 50.0)
		_restore(cut)
	# 11. the long view: one standing at the far end, one slumped on its side nearer
	h = _take(halls)
	if h:
		var from: Vector3 = h.at - h.dir * cell * 1.0
		var at = _at(from, h.dir, 13.0, 0.0)
		var cut := _dark_past(from, h.dir, 15.0)
		_stand(at, from, _pose({"headNod": 0.15}))
		_jointed(_at(from, h.dir, 7.0, 1.5), from, _pose({"mode": "side", "legL": 0.5, "legR": 0.7, "armL": 0.6}))
		await _shot(from, at + Vector3(0, 1.0, 0), 1.2, 1.5, 34.0)
		_restore(cut)

# ================================================================= the figures
## A rest pose with these keys set ("mode" too: stand, lie_up, prone, side, sit)
func _pose(over: Dictionary) -> Dictionary:
	var p := MannequinModel.rest_pose()
	p["mode"] = "stand"
	p.merge(over, true)
	return p

## Feet at `at`, facing `toward` (a point it looks at)
func _place(at: Vector3, toward: Vector3) -> Transform3D:
	var d := toward - at
	return Transform3D(Basis(Vector3.UP, atan2(d.x, d.z)), Vector3(at.x, 0.0, at.z))

## The jointed sculpt (creepy_mannequin.glb) in `pose`; the only one that can lie down or sit
func _jointed(at: Vector3, toward: Vector3, pose: Dictionary) -> void:
	var fig := Node3D.new()
	fig.transform = _place(at, toward) * MannequinModel.mode_base(pose.get("mode", "stand"), rng)
	var xfs := model.part_transforms(pose)
	for j in model.parts.size():
		var mi := MeshInstance3D.new()
		mi.mesh = model.parts[j].mesh
		mi.transform = xfs[j]
		fig.add_child(mi)
	stage.add_child(fig)

## A variant sculpt (rigged, worn per `style`: see MannequinModel.variant_style), standing; falls back to the jointed one
func _variant(at: Vector3, toward: Vector3, pose: Dictionary, style: Dictionary) -> void:
	if model.variant_count() == 0:
		_jointed(at, toward, pose)
		return
	var idx := rng.randi() % model.variant_count()
	var vn := model.make_variant(pose, style, idx)
	if vn == null:
		_jointed(at, toward, pose)
		return
	vn.transform = _place(at, toward) * model.variant_root_xf_at(idx)
	stage.add_child(vn)

## Standing figures: mostly the jointed sculpt, now and then a plain variant
func _stand(at: Vector3, toward: Vector3, pose: Dictionary) -> void:
	if rng.randf() < 0.3: _variant(at, toward, pose, {})
	else: _jointed(at, toward, pose)

# ================================================================= the level
func _open(p: Vector3) -> bool:
	var c: Vector2i = level.cell_of(p)
	return not level.walls.has(c) and not level.pits.has(c)

## A floor point `dist` m from `from` along `dir` (nudged `lateral` m sideways), in the open and in view; shorter if it has to be
func _spot(from: Vector3, dir: Vector3, dist: float, lateral: float):
	var d := dist
	while d > 1.5:
		var p := from + dir * d + _side(dir) * lateral
		if _open(p) and _clear(from, p): return p
		d -= 0.4
	return null

## _spot, or the plain point when nothing along the line is free (a figure in a pillar beats a missing shot)
func _at(from: Vector3, dir: Vector3, dist: float, lateral: float) -> Vector3:
	var p = _spot(from, dir, dist, lateral)
	if p == null:
		print("  no free spot ", dist, " m along ", dir)
		return from + dir * dist + _side(dir) * lateral
	return p

func _cut_if(pred: Callable) -> Array:
	var cut := []
	for f in level.lit:
		if pred.call(f):
			level.cut_fixture(f, 999.0)
			cut.append(f)
	return cut

## Every tube more than `dist` m ahead of `from` goes dark: the hall runs lit, then into black
func _dark_past(from: Vector3, dir: Vector3, dist: float) -> Array:
	return _cut_if(func(f): return (f.pos - from).dot(dir) > dist)

## Every tube further than `r` m from all of `points` goes dark: a pocket of light in the black
func _dark_outside(points: Array, r: float) -> Array:
	return _cut_if(func(f):
		for p in points:
			if Vector2(f.pos.x - p.x, f.pos.z - p.z).length() < r: return false
		return true)

func _restore(cut: Array) -> void:
	for f in cut: level.cut_fixture(f, 0.01)

func _nearest_fixture(p: Vector3):
	var best = null
	var bd := INF
	for f in level.lit:
		var d: float = Vector2(f.pos.x - p.x, f.pos.z - p.z).length()
		if d < bd:
			bd = d
			best = f
	return best

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

## Put the camera at `from` (y is taken from `h`, eye height in metres) aiming at `to`, roll/FOV as given,
## save the frame, then clear the stage for the next shot
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
	print("shot ", n, " at ", from, " -> ", to, " (", stage.get_child_count(), " figures)")
	n += 1
	for f in stage.get_children(): f.queue_free()
