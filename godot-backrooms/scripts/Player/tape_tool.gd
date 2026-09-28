extends Node
## Reflective hazard tape in the hand. Hold T looking at a wall or the floor within REACH: the end
## is pressed down there, and the strip pulls out along that surface after your aim as you turn or
## walk, up to MAX_STRIP. Let go and it tears off the roll and stays (tape_marks.gd). It can't run
## off the edge of the surface (a doorway, the end of a wall) or through a corner; a strip shorter
## than MIN_STRIP is balled up and not used.
## The rolls are an inventory item (tape_pickup.gd): ROLL_LENGTH of tape each, the one in use is
## `roll_left`; when it runs out the next roll comes out.
## Built by hud.gd, which also draws `pulling` / `length` / `roll_left` as the readout under the
## crosshair.

const TapeMarks := preload("res://scripts/World/props/tape_marks.gd")
const TapePickup := preload("res://scripts/World/props/tape_pickup.gd")

const KEY := KEY_T
const REACH := 2.4               # m: how far away the first end can be pressed down
const MAX_STRIP := 4.0           # m in one pull
const MIN_STRIP := 0.12          # m: shorter is not a strip
const WORLD_MASK := 1            # level geometry only
const PULL_EASE := 16.0          # 1/s: how quickly the tape catches up with your aim
const SUPPORT_STEP := 0.1        # m between checks that there is still surface under the strip
const GRAIN_EVERY := 0.045       # m of tape per crackle
const GRAINS := ["tape_grain_0.wav", "tape_grain_1.wav", "tape_grain_2.wav", "tape_grain_3.wav"]

var player: Node                 # player.gd (set by hud.gd)
var inventory: Node              # inventory.gd

var pulling := false
var length := 0.0                # m pulled out on the strip in hand
var roll_left := TapePickup.ROLL_LENGTH
var latched := false             # a press that found nothing to stick to: let go of T first
var _a := Vector3.ZERO           # the pressed-down end
var _n := Vector3.UP             # the surface it's on
var _end := Vector3.ZERO         # the free end, eased
var _grain_acc := 0.0
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
	var can: bool = player != null and inventory != null and Game.playing and not Game.dead \
		and not player.dead and not player.frozen and not Game.outdoors \
		and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and inventory.has_item(TapePickup.ITEM_ID)
	var down := can and Input.is_physical_key_pressed(KEY)
	if not down:
		latched = false
		if pulling:
			if can: _tear_off()
			else: _cancel()          # menu / terminal / death mid-pull: the strip goes back on the roll
		return
	if latched:
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
		return
	pulling = true
	latched = false
	_n = (hit.normal as Vector3).normalized()
	_a = hit.position
	_end = _a
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
	var goal := _end
	var denom := _n.dot(d)
	if denom < -0.02:
		var t := _n.dot(_a - o) / denom
		if t > 0.0 and t < REACH + MAX_STRIP:
			goal = o + d * t
	goal = _supported(goal)
	var prev := length
	_end = _end.lerp(goal, minf(1.0, dt * PULL_EASE))
	length = _a.distance_to(_end)
	TapeMarks.strip_mesh(_a, _end, _n, TapeMarks.LIFT + TapeMarks.LIFT_STEP * 8.0, _preview_mesh)
	# the roll crackles as it unwinds: one grain every few cm, so it follows how fast you pull
	_grain_acc += maxf(0.0, length - prev)
	if _grain_acc >= GRAIN_EVERY:
		_grain_acc = fmod(_grain_acc, GRAIN_EVERY)
		_play(GRAINS[randi() % GRAINS.size()], -10.0, randf_range(0.85, 1.2))

## The free end, held back to what there is tape and surface for: no longer than MAX_STRIP or
## what's left on the roll, no further than the surface goes, not through anything in the way
func _supported(goal: Vector3) -> Vector3:
	var v := goal - _a
	v -= _n * _n.dot(v)                        # stay in the surface's plane
	var want := minf(v.length(), minf(MAX_STRIP, roll_left))
	if want < 0.001:
		return _a
	var dir := v.normalized()
	var space: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
	var lift := _n * 0.03
	# something standing in the way along the surface (the far wall of a corner)
	var block := PhysicsRayQueryParameters3D.create(_a + lift, _a + lift + dir * want, WORLD_MASK)
	block.exclude = [player.get_rid()]
	var hit := space.intersect_ray(block)
	if not hit.is_empty():
		want = maxf(0.0, (hit.position as Vector3).distance_to(_a + lift) - 0.02)
	# and the surface still under it every SUPPORT_STEP (the end of a wall, a doorway, a pit)
	var probe := PhysicsRayQueryParameters3D.create(Vector3.ZERO, Vector3.ZERO, WORLD_MASK)
	probe.exclude = [player.get_rid()]
	var s := SUPPORT_STEP
	var ok := 0.0
	while s <= want + SUPPORT_STEP * 0.5:
		var at := _a + dir * minf(s, want)
		probe.from = at + _n * 0.05
		probe.to = at - _n * 0.05
		var under := space.intersect_ray(probe)
		if under.is_empty() or (under.normal as Vector3).dot(_n) < 0.95:
			break
		ok = minf(s, want)
		s += SUPPORT_STEP
	return _a + dir * ok

func _tear_off() -> void:
	var a := _a
	var b := _end
	var n := _n
	var l := length
	_clear()
	if l < MIN_STRIP or TapeMarks.live == null:
		return
	TapeMarks.live.place(a, b, n)
	_play("tape_rip.wav", -5.0, randf_range(0.92, 1.08))
	roll_left -= l
	if roll_left < MIN_STRIP:                  # that roll is done: the next one comes out
		inventory.remove_item(TapePickup.ITEM_ID)
		roll_left = TapePickup.ROLL_LENGTH

func _cancel() -> void:
	_clear()

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
