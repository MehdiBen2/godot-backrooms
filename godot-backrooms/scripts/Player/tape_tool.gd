extends Node
## Reflective hazard tape in the hand. Hold T looking at a wall or the floor within REACH: the end
## is pressed down there, and the strip pulls out along that surface after your aim as you turn or
## walk, up to MAX_STRIP. Let go and it tears off the roll and stays (tape_marks.gd). It can't run
## off the edge of the surface (a doorway, the end of a wall) or through a corner; a strip shorter
## than MIN_STRIP is balled up and not used.
## The rolls are an inventory item (tape_pickup.gd): ROLL_LENGTH of tape each, the one in use is
## `roll_left`; when it runs out the next roll comes out.
## Built by hud.gd; tape_readout.gd draws the tape mode HUD off `state`, `length`, `limit`,
## `surface`, `anchor` / `tip`, `roll_left` and the result of the last pull (`result_t`, `result_len`,
## `result_ry`).
## Hold T on a strip already stuck up (anyone's) and it peels back off, end first; held to the
## end, it comes away and its length goes back on the roll (a roll comes back into the inventory
## if you had none left). Let go early and it presses back down.
## Each strip also maps the level: the grid cells it marks go to Clearance.file_survey() and pay
## Research Yield the first time (asra_clearance.gd).

const TapeMarks := preload("res://scripts/World/props/tape_marks.gd")
const TapePickup := preload("res://scripts/World/props/tape_pickup.gd")

const KEY := KEY_T
const REACH := 3.0               # m: how far away the first end can be pressed down
const MAX_STRIP := 20.0          # m in one pull
const MIN_STRIP := 0.12          # m: shorter is not a strip
const WORLD_MASK := 1            # level geometry only
const PULL_EASE := 16.0          # 1/s: how quickly the tape catches up with your aim
const SUPPORT_STEP := 0.15       # m between checks that there is still surface under the strip
const GRAIN_EVERY := 0.045       # m of tape per crackle
const PEEL_SPEED := 9.0          # m/s a strip peels back
const PEEL_MIN := 0.35           # s: even a short one takes this long
const RESULT_TIME := 1.4        # s the readout shows how the last pull went
const GRAINS := ["tape_grain_0.wav", "tape_grain_1.wav", "tape_grain_2.wav", "tape_grain_3.wav"]

var player: Node                 # player.gd (set by hud.gd)
var inventory: Node              # inventory.gd

var pulling := false
var length := 0.0                # m pulled out on the strip in hand
var roll_left := TapePickup.ROLL_LENGTH
var latched := false             # a press that found nothing to stick to: let go of T first
var peeling := false
var peel_full := 0.0             # m in the strip being peeled
var state := "idle"              # idle / pull / placed / short / no_surface / no_tape / peel / peeled
var result_t := 0.0              # s left showing placed / short / no_surface
var result_len := 0.0            # m in the strip just placed
var result_ry := 0               # Research Yield it filed for mapping new ground (0: none new)
var _open_cells := -1            # the level's open cells (the survey's 100%), counted once
var limit := ""                  # what is stopping the strip growing: "" / MAX / ROLL / CORNER / EDGE
var surface := ""                # WALL / FLOOR / CEILING the strip is on
var anchor := Vector3.ZERO       # the pressed-down end
var normal := Vector3.UP         # the surface it's on
var tip := Vector3.ZERO          # the free end, eased
var _grain_acc := 0.0
var _peel := {}                  # the strip being peeled (tape_marks.gd)
var _peel_k := 1.0               # how much of it is still stuck down
var _preview: MeshInstance3D
var _preview_mesh := ArrayMesh.new()
var _sfx: Array[AudioStreamPlayer] = []
var _streams := {}

func _ready() -> void:
	for i in 4:
		var p := AudioStreamPlayer.new()
		p.bus = "World"
		add_child(p)
		_sfx.append(p)

func _process(dt: float) -> void:
	result_t = maxf(0.0, result_t - dt)
	if not pulling and not peeling and result_t <= 0.0:
		state = "idle"
	var can: bool = player != null and inventory != null and Game.playing and not Game.dead \
		and not player.dead and not player.frozen and not Game.outdoors \
		and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	var down := can and Input.is_physical_key_pressed(KEY)
	if not down:
		latched = false
		if pulling:
			if can: _tear_off()
			else: _cancel()          # menu / terminal / death mid-pull: the strip goes back on the roll
		elif peeling:
			_stop_peel()             # let go early: it presses back down
		return
	if latched:
		return
	if peeling:
		_peel_step(dt)
		return
	if not pulling:
		_start()
		return
	_pull(dt)

func _start() -> void:
	var cam: Camera3D = player.cam
	var from := cam.global_position
	var q := PhysicsRayQueryParameters3D.create(from, from - cam.global_transform.basis.z * REACH, WORLD_MASK)
	q.exclude = [player.get_rid()]
	var hit: Dictionary = player.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty() or not (hit.collider is StaticBody3D) or TapeMarks.live == null:
		latched = true
		player.dead_click.emit()     # nothing in reach to stick it to
		_result("no_surface", 0.0)
		return
	var on: Dictionary = TapeMarks.live.strip_at(hit.position, hit.normal)
	if not on.is_empty():
		_begin_peel(on)
		return
	if not inventory.has_item(TapePickup.ITEM_ID):
		latched = true
		player.dead_click.emit()     # no roll left
		_result("no_tape", 0.0)
		return
	pulling = true
	state = "pull"
	limit = ""
	latched = false
	normal = (hit.normal as Vector3).normalized()
	anchor = hit.position
	tip = anchor
	surface = "WALL"
	if normal.y > 0.7: surface = "FLOOR"
	elif normal.y < -0.7: surface = "CEILING"
	length = 0.0
	_grain_acc = 0.0
	_preview_mesh.clear_surfaces()           # the last strip's shape, until the first _pull
	_preview = MeshInstance3D.new()
	_preview.mesh = _preview_mesh
	_preview.material_override = TapeMarks.material()
	_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	TapeMarks.live.add_child(_preview)
	_preview.global_transform = Transform3D.IDENTITY
	_play("tape_stick.wav", -6.0)

func _pull(dt: float) -> void:
	var cam: Camera3D = player.cam
	var o := cam.global_position
	var d := -cam.global_transform.basis.z
	# where the view meets the surface's plane; looking away from it, the tape stays where it was
	var goal := tip
	var denom := normal.dot(d)
	if denom < -0.02:
		var t := normal.dot(anchor - o) / denom
		if t > 0.0 and t < REACH + MAX_STRIP:
			goal = o + d * t
	goal = _supported(goal)
	var prev := length
	tip = tip.lerp(goal, minf(1.0, dt * PULL_EASE))
	length = anchor.distance_to(tip)
	TapeMarks.strip_mesh(anchor, tip, normal, TapeMarks.LIFT + TapeMarks.LIFT_STEP * 8.0, _preview_mesh)
	# the roll crackles as it unwinds: one grain every few cm, so it follows how fast you pull
	_grain_acc += maxf(0.0, length - prev)
	if _grain_acc >= GRAIN_EVERY:
		_grain_acc = fmod(_grain_acc, GRAIN_EVERY)
		_play(GRAINS[randi() % GRAINS.size()], -10.0, randf_range(0.85, 1.2))

## The free end, held back to what there is tape and surface for: no longer than MAX_STRIP or
## what's left on the roll, no further than the surface goes, not through anything in the way
func _supported(goal: Vector3) -> Vector3:
	var v := goal - anchor
	v -= normal * normal.dot(v)                        # stay in the surface's plane
	var want := minf(v.length(), minf(MAX_STRIP, roll_left))
	limit = ""
	if v.length() > want + 0.01:
		limit = "ROLL" if roll_left < MAX_STRIP else "MAX"
	if want < 0.001:
		return anchor
	var dir := v.normalized()
	var space: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
	var lift := normal * 0.03
	# something standing in the way along the surface (the far wall of a corner)
	var block := PhysicsRayQueryParameters3D.create(anchor + lift, anchor + lift + dir * want, WORLD_MASK)
	block.exclude = [player.get_rid()]
	var hit := space.intersect_ray(block)
	if not hit.is_empty():
		want = maxf(0.0, (hit.position as Vector3).distance_to(anchor + lift) - 0.02)
		limit = "CORNER"
	# and the surface still under it every SUPPORT_STEP, across its whole width (the end of a
	# wall, a doorway, a pit)
	var probe := PhysicsRayQueryParameters3D.create(Vector3.ZERO, Vector3.ZERO, WORLD_MASK)
	probe.exclude = [player.get_rid()]
	var side := normal.cross(dir).normalized() * TapeMarks.WIDTH * 0.45
	var step := maxf(SUPPORT_STEP, want / 60.0)   # a long pull checks a little more coarsely
	var s := step
	var ok := 0.0
	while s <= want + step * 0.5:
		var at := anchor + dir * minf(s, want)
		var held := true
		for off in [Vector3.ZERO, side, -side]:
			probe.from = at + off + normal * 0.05
			probe.to = at + off - normal * 0.05
			var under := space.intersect_ray(probe)
			if under.is_empty() or (under.normal as Vector3).dot(normal) < 0.95:
				held = false
				break
		if not held:
			limit = "EDGE"
			break
		ok = minf(s, want)
		s += step
	return anchor + dir * ok

func _tear_off() -> void:
	var a := anchor
	var b := tip
	var n := normal
	var l := length
	_clear()
	if l < MIN_STRIP or TapeMarks.live == null:
		_result("short", l)
		return
	TapeMarks.live.place(a, b, n)
	_play("tape_rip.wav", -5.0, randf_range(0.92, 1.08))
	roll_left -= l
	_result("placed", l)
	result_ry = int(Clearance.file_survey(_cells_marked(a, b, n), _count_open()).get("total", 0))
	if roll_left < MIN_STRIP:                  # that roll is done: the next one comes out
		inventory.remove_item(TapePickup.ITEM_ID)
		roll_left = TapePickup.ROLL_LENGTH

# ---- peeling a strip back off ---------------------------------------------------------------
func _begin_peel(s: Dictionary) -> void:
	peeling = true
	state = "peel"
	limit = "PEEL"
	_peel = s
	_peel_k = 1.0
	anchor = s.a
	normal = s.n
	tip = s.b
	peel_full = anchor.distance_to(tip)
	length = peel_full
	_grain_acc = 0.0
	surface = "WALL"
	if normal.y > 0.7: surface = "FLOOR"
	elif normal.y < -0.7: surface = "CEILING"
	_play(GRAINS[randi() % GRAINS.size()], -6.0, 0.8)

func _peel_step(dt: float) -> void:
	var live = TapeMarks.live
	if live == null or not live.has_strip(_peel.id):
		peeling = false                          # someone else took it first
		state = "idle"
		length = 0.0
		return
	var prev := length
	_peel_k -= dt / maxf(PEEL_MIN, peel_full / PEEL_SPEED)
	if _peel_k <= 0.0:
		_finish_peel()
		return
	live.set_extent(_peel.id, _peel_k)
	tip = anchor.lerp(_peel.b, _peel_k)
	length = peel_full * _peel_k
	_grain_acc += maxf(0.0, prev - length)
	if _grain_acc >= GRAIN_EVERY * 3.0:      # peeling crackles coarser than unrolling
		_grain_acc = fmod(_grain_acc, GRAIN_EVERY * 3.0)
		_play(GRAINS[randi() % GRAINS.size()], -8.0, randf_range(0.7, 0.95))

func _finish_peel() -> void:
	TapeMarks.live.remove(_peel.id)
	peeling = false
	latched = true                               # T is still down: don't start a new strip at once
	length = 0.0
	if inventory.has_item(TapePickup.ITEM_ID):
		roll_left = minf(TapePickup.ROLL_LENGTH, roll_left + peel_full)
	else:
		inventory.add_item(TapePickup.ITEM_ID, TapePickup.ITEM_NAME, TapePickup.ITEM_DESC, 1,
			TapePickup.ITEM_CODE, TapePickup.STACK, TapePickup.MODEL_PATH)
		roll_left = maxf(peel_full, MIN_STRIP)
	_play("tape_rip.wav", -6.0, randf_range(0.75, 0.9))
	_result("peeled", peel_full)

func _stop_peel() -> void:
	var live = TapeMarks.live
	if live != null and live.has_strip(_peel.id):
		live.set_extent(_peel.id, 1.0)
	peeling = false
	length = 0.0
	state = "idle"
	result_t = 0.0

func _cancel() -> void:
	_clear()
	state = "idle"
	result_t = 0.0

func _result(what: String, l: float) -> void:
	state = what
	result_len = l
	result_ry = 0
	result_t = RESULT_TIME

## The level's grid cells a strip a -> b marks: the ones it runs through on a floor or ceiling, the
## corridor in front of the wall for a strip on a wall
func _cells_marked(a: Vector3, b: Vector3, n: Vector3) -> Array:
	var lvl: Node = Game.level
	var out: Array = []
	if lvl == null:
		return out
	var off := n * 0.5 if absf(n.y) < 0.7 else Vector3.ZERO
	var steps := maxi(1, ceili(a.distance_to(b) / 1.5))
	for i in steps + 1:
		var c: Vector2i = lvl.cell_of(a.lerp(b, float(i) / steps) + off)
		if not (c in out) and not lvl.walls.has(c) and not lvl.pits.has(c):
			out.append(c)
	return out

func _count_open() -> int:
	var lvl: Node = Game.level
	if lvl == null:
		return 0
	if _open_cells < 0:
		_open_cells = 0
		for z in lvl.size:
			for x in lvl.size:
				var c := Vector2i(x, z)
				if not lvl.walls.has(c) and not lvl.pits.has(c):
					_open_cells += 1
	return _open_cells

func _clear() -> void:
	pulling = false
	length = 0.0
	if _preview != null and is_instance_valid(_preview):
		_preview.queue_free()
	_preview = null

func _play(file: String, db: float, pitch := 1.0) -> void:
	if not _streams.has(file):
		_streams[file] = load("res://audio/" + file)
	for p in _sfx:
		if not p.playing:
			p.stream = _streams[file]
			p.volume_db = db
			p.pitch_scale = pitch
			p.play()
			return
