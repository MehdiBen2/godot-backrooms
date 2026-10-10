extends Node
## Entity level of detail (autoload: EntityLOD). Every monster registers here and asks which tier it is in, so
## the far ones stop costing what the near ones do (the AI LOD of open-world games):
##   FULL      near you, or engaged (hunting, stalking, killing): everything, every frame
##   SLOW      mid distance: thinks less often, its body is posed every other frame
##   ASLEEP    far away and only idling: body hidden and not posed, voice off, thinks once a second. It still
##             walks its route, so it is somewhere believable when you come near
##   UNSPAWNED a resident monster (placed with a mark in the level editor) that hasn't arrived yet
##
## Residents spawn when you come within their `spawn_dist` of their mark, or once `arrive_after` seconds of play
## have gone by (the director: the level must not stay empty because you never walked that way). The monsters
## that come to you by design (the Mimic, the Eyes, the Grabber) only register to show in the F12 overlay.
## In co-op every monster stays FULL and spawns at once: the host simulates for players it can't measure here.

enum { FULL, SLOW, ASLEEP, UNSPAWNED }
const NAMES := ["FULL", "SLOW", "ASLEEP", "not spawned"]

const SLOW_DIST := 35.0
const ASLEEP_DIST := 70.0
const HYSTERESIS := 8.0           # m: a tier is left this much further out than it is entered (no flicker on the edge)
const TICK := 0.2                 # s between tier updates

var entities: Array[Node3D] = []
var _tier := {}                   # entity -> tier
var _resident := {}               # entity -> {mark: Vector3, spawn_dist, arrive_after}
var _play_time := 0.0
var _t := 0.0

## `resident`: {mark: Vector3, spawn_dist: float, arrive_after: float}; empty for a monster that comes to you
func register(e: Node3D, resident := {}) -> void:
	if e in entities:
		return
	entities.append(e)
	_tier[e] = FULL
	if not resident.is_empty() and not Net.is_online():
		_resident[e] = resident
		_tier[e] = UNSPAWNED
	if e.has_signal("tree_exiting"):
		e.tree_exiting.connect(_forget.bind(e), CONNECT_ONE_SHOT)

func _forget(e: Node3D) -> void:
	entities.erase(e)
	_tier.erase(e)
	_resident.erase(e)
	if entities.is_empty():
		_play_time = 0.0

func tier(e: Node3D) -> int:
	return _tier.get(e, FULL)

func tier_name(e: Node3D) -> String:
	return NAMES[tier(e)]

func is_spawned(e: Node3D) -> bool:
	return tier(e) != UNSPAWNED

## The point the monster is measured from: its body (lod_position() when it isn't its node's origin)
func position_of(e: Node3D) -> Vector3:
	return e.lod_position() if e.has_method("lod_position") else e.global_position

func distance_of(e: Node3D) -> float:
	var p: Node3D = Game.player if Game.player != null and is_instance_valid(Game.player) else null
	if p == null:
		return INF
	var a := position_of(e)
	return Vector2(a.x - p.global_position.x, a.z - p.global_position.z).length()

func _process(dt: float) -> void:
	if Game.playing and not Game.dead:
		_play_time += dt
	_t -= dt
	if _t > 0.0:
		return
	_t = TICK
	var online := Net.is_online()
	var p: Node3D = Game.player if Game.player != null and is_instance_valid(Game.player) else null
	for e in entities.duplicate():
		if not is_instance_valid(e):
			_forget(e)
			continue
		if _resident.has(e) and tier(e) == UNSPAWNED:
			_try_spawn(e, p, online)
			continue
		if online or p == null:
			_tier[e] = FULL
			continue
		var engaged: bool = e.lod_engaged() if e.has_method("lod_engaged") else false
		var d := distance_of(e)
		var cur: int = _tier.get(e, FULL)
		# a tier is entered at its distance and only left HYSTERESIS closer in
		var asleep_at := ASLEEP_DIST - (HYSTERESIS if cur == ASLEEP else 0.0)
		var slow_at := SLOW_DIST - (HYSTERESIS if cur == SLOW or cur == ASLEEP else 0.0)
		if engaged or d <= slow_at:
			_tier[e] = FULL
		elif d > asleep_at:
			_tier[e] = ASLEEP
		else:
			_tier[e] = SLOW

func _try_spawn(e: Node3D, p: Node3D, online: bool) -> void:
	# already out (summoned by an event, a co-op host, the debug console): count it as spawned
	if e.process_mode != Node.PROCESS_MODE_DISABLED and e.has_method("lod_spawned") and e.lod_spawned():
		_tier[e] = FULL
		return
	if p == null or not Game.playing or Game.dead:
		return
	var r: Dictionary = _resident[e]
	var m: Vector3 = r.mark
	var near := Vector2(m.x - p.global_position.x, m.z - p.global_position.z).length() < float(r.get("spawn_dist", 60.0))
	if online or near or _play_time > float(r.get("arrive_after", 150.0)):
		_tier[e] = FULL
		if e.has_method("lod_spawn"):
			e.lod_spawn(near or online)
