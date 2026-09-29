extends Node
## THE MIMIC copies sounds, not just faces. Every few tens of seconds, from just round a corner (the
## next corridor over: close by walking, but out of sight), it plays back something YOU did a little
## while ago: your torch switch, a strip of tape tearing off the roll, a run of your own footsteps on
## that floor. The same sounds you make, so you can't tell them from a teammate's or your own echo.
## They come through the walls like any sound in the world (audio.gd occlude).
## Only you hear yours: it runs on each machine for that machine's player (no network), so in co-op
## you can ask "did you hear that?" and get "no". It works alone too, where there are no voices to copy.
## Child of the Mimic (mimic.gd); quiet while something is hunting you and while the Mimic itself is
## in your sight.

const START := 150.0                 # s into a level before it starts
const GAP := Vector2(30.0, 70.0)     # s between sounds
const KEEP := 180.0                  # s it remembers what you did
const NEAR_CELLS := Vector2i(2, 4)   # the spot: this many cells' walk away...
const NEAR_M := Vector2(7.0, 18.0)   # ...this far in a straight line, and out of your line of sight
const STEP_GAP := {"walk": 0.52, "sprint": 0.34, "crouch": 0.8}
# a footstep at the level of your own (footsteps.gd step(): scuff level, heel weight), heard from a
# distance: at STEP_UNIT metres a copied step is exactly as loud as yours, further off it fades
const STEP_LEVEL := {"walk": 0.05, "sprint": 0.08, "crouch": 0.015}
const HEEL_WEIGHT := {"walk": 0.32, "sprint": 0.45, "crouch": 0.15}
const STEP_UNIT := 3.0

var mimic: Node                      # mimic.gd
var clock := 0.0
var next_at := START
var events: Array = []               # {t, kind}: torch_on / torch_off / tape / steps_walk / steps_sprint / steps_crouch
var _torch_was := true
var _tape_was := ""
var _moving_for := 0.0
var _steps_at := -100.0

func _process(dt: float) -> void:
	var player: Node = mimic.player if mimic != null else null
	if player == null or not Game.playing or Game.dead or player.dead or Game.outdoors:
		return
	clock += dt
	_notice(player, dt)
	if clock < next_at:
		return
	next_at = clock + randf_range(GAP.x, GAP.y)
	if events.is_empty() or Game.hunted or Game.terror > 0.3 or player.grid_down or _mimic_in_view(player):
		return
	var spot = _spot(player)
	if spot == null:
		return
	# the more recent, the likelier: something you did in the last minute or two
	var e: Dictionary = events[clampi(events.size() - 1 - int(pow(randf(), 2.0) * events.size()), 0, events.size() - 1)]
	_play(e.kind, spot, player)

## What you have been doing that makes a sound
func _notice(player: Node, dt: float) -> void:
	var on: bool = player.flash_on
	if on != _torch_was:
		events.append({"t": clock, "kind": "torch_on" if on else "torch_off"})
	_torch_was = on
	var hud: Node = Game.main.get_node_or_null("UI") if Game.main != null and is_instance_valid(Game.main) else null
	var tape: Node = hud.get("tape") if hud != null else null
	if tape != null:
		var st: String = tape.state
		if st != _tape_was and (st == "placed" or st == "peeled"):
			events.append({"t": clock, "kind": "tape"})
		_tape_was = st
	_moving_for = _moving_for + dt if player.is_moving else 0.0
	if _moving_for > 2.0 and clock - _steps_at > 20.0:
		_steps_at = clock
		var how := "sprint" if player.is_sprinting else ("crouch" if player.is_crouching else "walk")
		events.append({"t": clock, "kind": "steps_" + how})
	while not events.is_empty() and clock - float(events[0].t) > KEEP:
		events.pop_front()

func _mimic_in_view(player: Node) -> bool:
	if not mimic.spawned or mimic.body == null:
		return false
	var p: Vector3 = mimic.body.global_position
	var pp: Vector3 = player.global_position
	return pp.distance_to(p) < 45.0 and mimic.nav.clear_line(pp.x, pp.z, p.x, p.z)

## The next corridor over: a few cells' walk away but out of your line of sight. null when there's none.
func _spot(player: Node) -> Variant:
	var nav = mimic.nav
	var pp: Vector3 = player.global_position
	var n: int = nav.n
	var field := PackedInt32Array()
	field.resize(n * n)
	if not nav.bfs(nav.cell(pp.x), nav.cell(pp.z), field):
		return null
	var picks: Array = []
	for x in n:
		for z in n:
			var d := field[x * n + z]
			if d < NEAR_CELLS.x or d > NEAR_CELLS.y:
				continue
			var p := Vector3(x * nav.CELL, pp.y, z * nav.CELL)
			var straight := Vector2(p.x - pp.x, p.z - pp.z).length()
			if straight >= NEAR_M.x and straight <= NEAR_M.y and not nav.clear_line(pp.x, pp.z, p.x, p.z):
				picks.append(Vector2i(x, z))
	if picks.is_empty():
		return null
	return picks.pick_random()

func _play(kind: String, c: Vector2i, player: Node) -> void:
	var nav = mimic.nav
	var at := Vector3(c.x * nav.CELL, player.global_position.y, c.y * nav.CELL)
	match kind:
		"torch_on", "torch_off":
			_one(player.click_on if kind == "torch_on" else player.click_off, at + Vector3(0, 1.4, 0), -6.0, 1.0)
		"tape":
			_one(load("res://audio/tape_rip.wav"), at + Vector3(0, 1.2, 0), -3.0, randf_range(0.92, 1.08))
		_:
			_steps(kind.trim_prefix("steps_"), c, player)

func _source(pos: Vector3) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.bus = "World"
	p.unit_size = 4.0
	p.max_distance = 35.0
	Game.main.add_child(p)
	p.global_position = pos
	var au: Node = Game.main.get_node_or_null("Audio")
	if au != null and au.has_method("occlude"):
		au.occlude(p)                           # through the walls, like any sound in the world
	p.finished.connect(p.queue_free)
	return p

func _one(stream: AudioStream, pos: Vector3, db: float, pitch: float) -> void:
	var p := _source(pos)
	p.stream = stream
	p.volume_db = db
	p.pitch_scale = pitch
	p.play()

## A few of your own footsteps (your takes, on that floor), walking along the corridor it is in
func _steps(how: String, c: Vector2i, player: Node) -> void:
	var nav = mimic.nav
	var dir := Vector2i.ZERO
	for o in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		if nav.can_step(c.x, c.y, c.x + o.x, c.y + o.y):
			dir = o
			break
	var from := Vector3(c.x * nav.CELL, player.global_position.y + 0.1, c.y * nav.CELL)
	var along := Vector3(dir.x, 0, dir.y)
	var gap: float = STEP_GAP[how]
	var pace: float = 4.5 if how == "sprint" else (1.35 if how == "crouch" else 2.6)
	for i in randi_range(5, 9):
		var pos := from + along * (i * gap * pace)
		get_tree().create_timer(i * gap * randf_range(0.93, 1.07)).timeout.connect(func():
			if is_instance_valid(self) and not Game.dead:
				step_at(pos, how))

## One footstep at `pos`, a survivor's on that floor, as loud as your own would be from STEP_UNIT
## metres (the Mimic's own feet use this too, mimic.gd footsteps)
func step_at(pos: Vector3, how: String) -> void:
	var player: Node = mimic.player if mimic != null else null
	var fs: Node = player.get("footsteps") if player != null else null
	if fs == null or Game.level == null:
		return
	var tile: bool = Game.level.tiles.has(Vector2i(roundi(pos.x / mimic.nav.CELL), roundi(pos.z / mimic.nav.CELL)))
	var level: float = STEP_LEVEL[how]
	var list: Array = fs.sprint if how == "sprint" else fs.walk
	var scuff := _source(pos)
	scuff.unit_size = STEP_UNIT
	scuff.stream = list.pick_random()
	scuff.volume_linear = level * randf_range(0.85, 1.1) * (0.55 if tile else 1.0)
	scuff.pitch_scale = (0.92 if how == "crouch" else 1.0) * randf_range(0.96, 1.04) * (1.1 if tile else 1.0)
	scuff.play()
	var heel := _source(pos)
	heel.unit_size = STEP_UNIT
	heel.stream = fs.heel_tile if tile else fs.heel_carpet
	heel.volume_linear = level * float(HEEL_WEIGHT[how]) * (1.8 if tile else 1.0) * randf_range(0.8, 1.1)
	heel.pitch_scale = randf_range(0.9, 1.1)
	heel.play()
