extends Node
## T.S.R.A. field scanner: the only way to log an entity in the Threshold Dossier. Hold Q while
## facing one. A reading needs the target near the middle of the view (CONE_COS), within RANGE and
## in plain line of sight for SCAN_TIME seconds; a complete one calls Archive.discover(), and the
## HUD toast (scripts/UI/hud/terminal_toast.gd) announces the new entry. Every complete reading
## also goes to Clearance.file() for its Research Yield (asra_clearance.gd): new sites and repeat
## readings of logged entities still pay, a little.
## Targets are the nodes in Archive.SCANNABLE: each carries its id in the "asra_id" meta and lists
## the points it can be read from in scan_points() (see the entity scripts). Entities read from
## anywhere in RANGE; props (survey_clipboard.gd, dead_fixture.gd) give a short scan_range(), so
## the signal meter still leads to them from afar but the reading only starts up close.
## Built by hud.gd, which also hands the player the scanner item; scan_readout.gd draws the reticle
## off `state` / `progress` / `target_id` / `target_pos` / `signal_strength` / `signal_dist`, and,
## by clearance (asra_clearance.gd), `signal_bearing` (C-3 range-finder) and `target_node` (C-4 deep scan).
## With no anomaly in the sights it also reads hazard tape (tape_marks.gd) under the crosshair:
## `tape_info` says how long ago the strip went down and who stuck it, so you can tell whether the
## corridor you're in is one you've already walked.

const TapeMarks := preload("res://scripts/World/props/tape_marks.gd")

const RANGE := 32.0
const CONE_COS := 0.9877         # cos 9 deg: the target has to be close to the crosshair
const SCAN_TIME := 2.0
const LOCK_GRACE := 0.4          # a lock survives this long out of view (a doorframe, a flicker)
const RESULT_TIME := 1.6         # the reticle shows the result this long after Q is let go
const MAX_RAYS := 4              # line-of-sight checks per frame, best-aimed candidates first
const WORLD_MASK := 1            # level geometry only: an entity's own body never blocks its reading
const SIGNAL_COS := 0.55         # the signal meter starts to pick things up within ~57 deg of the view

var player: Node                 # player.gd (set by hud.gd)
var inventory: Node              # inventory.gd: no scanner item, no scanning

var holding := false             # Q is down and scanning is possible
var state := "idle"              # idle / search / lock / logged / on_file
var target_id := ""
var target_dist := 0.0
var target_pos := Vector3.ZERO   # world point being read (the reticle's lock brackets sit on it)
var signal_strength := 0.0       # 0..1 warmer / colder: anything scannable ahead and near, walls or not
var raw_signal := 0.0
var signal_dist := 0.0           # rough range of whatever gives the signal, eased (the scale's band)
var raw_dist := 0.0
var signal_bearing := 0.0        # degrees from the view to the signal, + right (the C-3 range-finder's arrows)
var raw_bearing := 0.0
var target_node: Node            # the entity locked on (the C-4 deep scan asks it scan_behavior())
var progress := 0.0              # 0..1 through the current reading
var last_yield := 0              # RY the last completed reading filed (Clearance.file), 0 for none
var result_t := 0.0
var latched := false             # a reading finished: Q has to be let go before the next one
var lost_t := 0.0
var ping_t := 0.0
var tape_info := {}              # hazard tape under the crosshair while searching: {age, mine, by, length, dist}
var ping: AudioStreamPlayer
var denied: AudioStreamPlayer

func _ready() -> void:
	ping = _player("res://audio/terminal/terminal_scan.wav", -10.0)
	denied = _player("res://audio/terminal/terminal_select.wav", -16.0)

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
	var down := can and Input.is_action_pressed("scanner")
	if not down:
		holding = false
		latched = false
		tape_info = {}
		progress = 0.0
		signal_strength = 0.0
		signal_dist = 0.0
		if state == "search" or state == "lock" or result_t <= 0.0:
			state = "idle"
			target_id = ""
			target_node = null
		else:
			_update_target_tracking()
		return
	holding = true
	if latched:
		_update_target_tracking()
		return                       # keep showing the result until Q is let go
	var hit := _best_target()
	tape_info = _tape_under_crosshair() if hit.is_empty() and state != "lock" else {}
	signal_strength = lerpf(signal_strength, maxf(raw_signal, 0.85 if state == "lock" else 0.0), minf(1.0, dt * 6.0))
	if raw_signal > 0.02:
		signal_dist = raw_dist if signal_dist <= 0.0 else lerpf(signal_dist, raw_dist, minf(1.0, dt * 4.0))
		signal_bearing = lerpf(signal_bearing, raw_bearing, minf(1.0, dt * 6.0))
	if hit.is_empty():
		lost_t += dt
		if state != "lock" or lost_t > LOCK_GRACE:
			state = "search"
			target_id = ""
			target_node = null
			progress = 0.0
		elif state == "lock":
			_update_target_tracking()
	else:
		lost_t = 0.0
		if hit.id != target_id:
			target_id = hit.id
			progress = 0.0
		state = "lock"
		target_node = hit.node
		target_dist = hit.dist
		target_pos = hit.pos
		progress = minf(1.0, progress + dt / (SCAN_TIME * Clearance.scan_time_scale()))
		if progress >= 1.0:
			_complete()
			return
	_ping(dt)

func _complete() -> void:
	latched = true
	result_t = RESULT_TIME
	if target_node != null and target_node.has_method("on_scanned"):
		target_node.on_scanned()
	# Research Yield first: the NEW ENTRY toast reads the report Archive.discover() then announces
	last_yield = int(Clearance.file(target_id, target_dist, player).get("total", 0))
	if Archive.is_discovered(target_id):
		state = "on_file"
		if last_yield <= 0:
			denied.play()
	else:
		state = "logged"
		Archive.discover(target_id)  # -> entity_discovered -> the HUD toast and its chime

## Keep target_pos and target_dist following the locked/scanned entity as it moves
func _update_target_tracking() -> void:
	if not is_instance_valid(target_node):
		target_node = null
		return
	if not target_node.is_inside_tree():
		return
	if target_node.has_method("scan_points"):
		var pts: Array = target_node.scan_points()
		if not pts.is_empty():
			var best_pt: Vector3 = pts[0]
			if pts.size() > 1:
				var best_d := target_pos.distance_squared_to(best_pt)
				for i in range(1, pts.size()):
					var p: Vector3 = pts[i]
					var d := target_pos.distance_squared_to(p)
					if d < best_d:
						best_d = d
						best_pt = p
			target_pos = best_pt
	elif target_node is Node3D:
		target_pos = target_node.global_position
	if player != null and player.cam != null:
		target_dist = player.cam.global_position.distance_to(target_pos)

## The hazard tape strip the crosshair is on, within RANGE and in sight: {age (s), mine, by,
## length, dist}, or {}
func _tape_under_crosshair() -> Dictionary:
	var live = TapeMarks.live
	if live == null or Game.outdoors:
		return {}
	var cam: Camera3D = player.cam
	var from := cam.global_position
	var q := PhysicsRayQueryParameters3D.create(from, from - cam.global_transform.basis.z * RANGE, WORLD_MASK)
	q.exclude = [player.get_rid()]
	var hit: Dictionary = player.get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return {}
	var s: Dictionary = live.strip_at(hit.position, hit.normal)
	if s.is_empty():
		return {}
	return {"age": maxf(0.0, Time.get_unix_time_from_system() - float(s.t)), "mine": TapeMarks.is_mine(s.id),
		"by": str(s.by), "length": (s.a as Vector3).distance_to(s.b), "dist": from.distance_to(hit.position)}

## Geiger-counter ticks at random (Poisson) gaps: about one a second of background while nothing
## is near, more as the signal rises, a rattle as a reading fills
func _ping(dt: float) -> void:
	ping_t -= dt
	if ping_t > 0.0:
		return
	var rate := 1.0 + 7.0 * signal_strength
	if state == "lock":
		rate = lerpf(8.0, 30.0, progress)
	ping_t = -log(maxf(randf(), 0.001)) / rate
	ping.pitch_scale = randf_range(0.9, 1.12)
	ping.play()

## The scannable point closest to the crosshair that is in range and in plain sight: {id, pos, dist, node}
func _best_target() -> Dictionary:
	var cam: Camera3D = player.cam
	var from := cam.global_position
	var fwd := -cam.global_transform.basis.z
	var found: Array = []            # [dot, id, pos, dist, node] inside the cone
	var flat_fwd := Vector2(fwd.x, fwd.z).normalized()
	raw_signal = 0.0
	for n in get_tree().get_nodes_in_group(Archive.SCANNABLE):
		if not n.has_method("scan_points"):
			continue
		var id := str(n.get_meta("asra_id", ""))
		if id == "":
			continue
		# entities read from anywhere in RANGE; a prop that has scan_range() only from up close
		var lock_range: float = minf(RANGE, n.scan_range()) if n.has_method("scan_range") else RANGE
		for p in n.scan_points():
			var d: Vector3 = p - from
			var dist := d.length()
			if dist < 0.5 or dist > RANGE:
				continue
			var dot := fwd.dot(d / dist)
			var s: float = smoothstep(SIGNAL_COS, CONE_COS, dot) * (1.0 - 0.6 * dist / RANGE)
			if s > raw_signal:
				raw_signal = s
				raw_dist = dist
				raw_bearing = rad_to_deg(flat_fwd.angle_to(Vector2(d.x, d.z)))
			if dot >= CONE_COS and dist <= lock_range:
				found.append([dot, id, p, dist, n])
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
			return {"id": c[1], "pos": c[2], "dist": c[3], "node": c[4]}
	return {}
