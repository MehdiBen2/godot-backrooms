extends Node
## A.S.R.A. field scanner: the only way to log an entity in the Threshold Dossier. Hold Q while
## facing one. A reading needs the target near the middle of the view (CONE_COS), within RANGE and
## in plain line of sight for SCAN_TIME seconds; a complete one calls Archive.discover(), and the
## HUD toast (scripts/UI/hud/terminal_toast.gd) announces the new entry.
## Targets are the nodes in Archive.SCANNABLE: each carries its id in the "asra_id" meta and lists
## the points it can be read from in scan_points() (see the entity scripts).
## Built by hud.gd, which also hands the player the scanner item; scan_readout.gd draws the reticle
## off `state` / `progress` / `target_id`.

const RANGE := 32.0
const CONE_COS := 0.9877         # cos 9 deg: the target has to be close to the crosshair
const SCAN_TIME := 2.0
const LOCK_GRACE := 0.4          # a lock survives this long out of view (a doorframe, a flicker)
const RESULT_TIME := 1.6         # the reticle shows the result this long after Q is let go
const MAX_RAYS := 4              # line-of-sight checks per frame, best-aimed candidates first
const WORLD_MASK := 1            # level geometry only: an entity's own body never blocks its reading

var player: Node                 # player.gd (set by hud.gd)
var inventory: Node              # inventory.gd: no scanner item, no scanning

var holding := false             # Q is down and scanning is possible
var state := "idle"              # idle / search / lock / logged / on_file
var target_id := ""
var target_dist := 0.0
var progress := 0.0              # 0..1 through the current reading
var result_t := 0.0
var latched := false             # a reading finished: Q has to be let go before the next one
var lost_t := 0.0
var ping_t := 0.0
var ping: AudioStreamPlayer
var denied: AudioStreamPlayer

func _ready() -> void:
	ping = _player("res://audio/terminal/terminal_scan.wav", -15.0)
	denied = _player("res://audio/terminal/terminal_select.wav", -8.0)

func _player(path: String, db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = load(path)
	p.volume_db = db
	add_child(p)
	return p

func _process(dt: float) -> void:
	result_t = maxf(0.0, result_t - dt)
	var can: bool = player != null and inventory != null and Game.playing and not Game.dead \
		and not player.dead and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and inventory.has_item("scanner")
	var down := can and Input.is_physical_key_pressed(KEY_Q)
	if not down:
		holding = false
		latched = false
		progress = 0.0
		if state == "search" or state == "lock" or result_t <= 0.0:
			state = "idle"
			target_id = ""
		return
	holding = true
	if latched:
		return                       # keep showing the result until Q is let go
	var hit := _best_target()
	if hit.is_empty():
		lost_t += dt
		if state != "lock" or lost_t > LOCK_GRACE:
			state = "search"
			target_id = ""
			progress = 0.0
	else:
		lost_t = 0.0
		if hit.id != target_id:
			target_id = hit.id
			progress = 0.0
		state = "lock"
		target_dist = hit.dist
		progress = minf(1.0, progress + dt / SCAN_TIME)
		if progress >= 1.0:
			_complete()
			return
	_ping(dt)

func _complete() -> void:
	latched = true
	result_t = RESULT_TIME
	if Archive.is_discovered(target_id):
		state = "on_file"
		denied.play()
	else:
		state = "logged"
		Archive.discover(target_id)  # -> entity_discovered -> the HUD toast and its chime

## Faster and higher as the reading fills; a slow ping while nothing is in the cone
func _ping(dt: float) -> void:
	ping_t -= dt
	if ping_t > 0.0:
		return
	if state == "lock":
		ping_t = lerpf(0.3, 0.07, progress)
		ping.pitch_scale = 1.0 + 0.5 * progress
	else:
		ping_t = 0.8
		ping.pitch_scale = 0.85
	ping.play()

## The scannable point closest to the crosshair that is in range and in plain sight: {id, pos, dist}
func _best_target() -> Dictionary:
	var cam: Camera3D = player.cam
	var from := cam.global_position
	var fwd := -cam.global_transform.basis.z
	var found: Array = []            # [dot, id, pos, dist] inside the cone
	for n in get_tree().get_nodes_in_group(Archive.SCANNABLE):
		if not n.has_method("scan_points"):
			continue
		var id := str(n.get_meta("asra_id", ""))
		if id == "":
			continue
		for p in n.scan_points():
			var d: Vector3 = p - from
			var dist := d.length()
			if dist < 0.5 or dist > RANGE:
				continue
			var dot := fwd.dot(d / dist)
			if dot >= CONE_COS:
				found.append([dot, id, p, dist])
	if found.is_empty():
		return {}
	found.sort_custom(func(a, b): return a[0] > b[0])
	var space: PhysicsDirectSpaceState3D = player.get_world_3d().direct_space_state
	for i in mini(found.size(), MAX_RAYS):
		var c: Array = found[i]
		var q := PhysicsRayQueryParameters3D.create(from, c[2], WORLD_MASK)
		q.exclude = [player.get_rid()]
		var hit := space.intersect_ray(q)
		# a hit right at the target is the entity's own geometry (or the wall it stands against)
		if hit.is_empty() or from.distance_to(hit.position) > c[3] - 1.0:
			return {"id": c[1], "pos": c[2], "dist": c[3]}
	return {}
