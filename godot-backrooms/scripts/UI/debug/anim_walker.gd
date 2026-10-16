extends Node3D
## ANIMATION TEST walker (debug console): a survivor suit that really walks, driven by the same
## survivor_anim.gd Locomotion other survivors use, so what you see is what a teammate looks like.
## It paces a short lane next to where it was summoned: goes LANE metres one way, stops, turns round on the
## spot and comes back, keeping the chosen kind of step (backwards stays backwards). It sets itself side-on
## to you so the motion crosses the screen. Head tests stand still and turn the head; "circle" walks a loop
## facing you, so the blend sweeps through every direction. snap_neck() plays THE MANNEQUIN's kill as the
## others see it (death_neck_snap), side-on, and leaves it lying where it fell until revive(); the debug
## console has the mannequin itself stage it round the walker (mannequin.gd debug_walker_kill).

const SurvivorAnim := preload("res://scripts/Entities/survivor_anim.gd")
const HazmatFit := preload("res://scripts/Entities/hazmat_fit.gd")

## move -> [label, direction in its own frame (x right, y forward)]; Vector2.ZERO stands
const MOVES := {
	"idle": ["IDLE", Vector2.ZERO],
	"forward": ["FORWARD", Vector2(0, 1)],
	"backward": ["BACKWARD", Vector2(0, -1)],
	"left": ["STRAFE LEFT", Vector2(-1, 0)],
	"right": ["STRAFE RIGHT", Vector2(1, 0)],
	"fwd_left": ["DIAG FWD-LEFT", Vector2(-1, 1)],
	"fwd_right": ["DIAG FWD-RIGHT", Vector2(1, 1)],
	"back_left": ["DIAG BACK-LEFT", Vector2(-1, -1)],
	"back_right": ["DIAG BACK-RIGHT", Vector2(1, -1)],
	"circle": ["CIRCLE (ALL DIRECTIONS)", Vector2.ZERO],
}
const GAITS := ["walk", "run", "crouch"]
## m/s, as the player moves (player.gd SPEED 2.6, SPRINT_MULT 1.75, CROUCH_MULT 0.52)
const GAIT_SPEED := {"walk": 2.6, "run": 4.55, "crouch": 1.35}
## head tests: look -> [label, yaw (deg, + left), pitch (deg, + up)]; "sweep" swings side to side
const LOOKS := {
	"ahead": ["LOOK AHEAD", 0.0, 0.0],
	"left": ["LOOK LEFT", 60.0, 0.0],
	"right": ["LOOK RIGHT", -60.0, 0.0],
	"up": ["LOOK UP", 0.0, 40.0],
	"down": ["LOOK DOWN", 0.0, -40.0],
	"sweep": ["LOOK SWEEP", 0.0, 0.0],
	"behind": ["LOOK BEHIND (TURNS)", 150.0, 0.0],
}
const LANE := 3.0              # m each way
const PAUSE := 0.45            # s stood still at each end before turning round
const CIRCLE_RADIUS := 1.6     # m
const KILL_DEAD_AT := 4.6      # s into the neck snap its own machine says dead (mannequin_snap.gd TOTAL)

var move := "forward"
var gait := "walk"
var look := "ahead"
var dead := false
var killing := false           # THE MANNEQUIN has it (snap_neck)
var time_scale := 1.0          # slow motion for this body only
var _kill_t := 0.0

var loco: SurvivorAnim.Locomotion
var _floor: SurvivorAnim.FloorGuard
var _home := Vector3.ZERO
var _face := 0.0               # where it aims (the look), radians
var _phase := "move"           # move / pause / turn
var _left := 0.0               # m left on this leg, or s left of the pause
var _t := 0.0
var _viewer_yaw := 0.0
var _caption: Label3D

## Builds the suit; false when the model is missing.
func build(viewer_yaw: float) -> bool:
	var packed := load(SurvivorAnim.MODEL) as PackedScene
	if packed == null:
		return false
	var inst: Node3D = packed.instantiate()
	var aps := inst.find_children("*", "AnimationPlayer", true, false)
	if aps.is_empty():
		inst.queue_free()
		return false
	var model := Node3D.new()
	add_child(model)
	model.add_child(inst)
	inst.transform = HazmatFit.fit(inst, model, 2.0)
	model.rotation.y = PI                       # the file faces +Z, survivors face -Z
	var anim: AnimationPlayer = aps[0]
	loco = SurvivorAnim.Locomotion.new(anim, SurvivorAnim.find_clips(anim))
	loco.tree.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL   # advanced here, for slow motion
	_floor = SurvivorAnim.FloorGuard.new(model, loco.tree)
	_viewer_yaw = viewer_yaw
	_caption = Label3D.new()                    # what it's doing, readable with the menu shut
	_caption.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_caption.no_depth_test = true
	_caption.pixel_size = 0.0035
	_caption.font_size = 40
	_caption.outline_size = 10
	_caption.modulate = Color(0.95, 0.85, 0.5)
	_caption.position = Vector3(0, 2.35, 0)
	add_child(_caption)
	return true

func _ready() -> void:
	_home = global_position
	set_move(move)

## Starts `m` from the middle of the lane, side-on to the viewer.
func set_move(m: String) -> void:
	if not MOVES.has(m):
		return
	move = m
	look = "ahead"
	revive()
	_t = 0.0
	global_position = _home
	var d: Vector2 = MOVES[m][1]
	var a := atan2(d.x, d.y) if d != Vector2.ZERO else 0.0     # its heading, from straight ahead towards its right
	# aim so it travels across your view, and of the two ways to do that, the one showing more of its front
	var toward_you := _viewer_yaw + PI
	var c1 := _viewer_yaw - PI / 2.0 + a
	var c2 := _viewer_yaw + PI / 2.0 + a
	_face = c1 if absf(wrapf(c1 - toward_you, -PI, PI)) <= absf(wrapf(c2 - toward_you, -PI, PI)) else c2
	if m == "idle" or m == "circle":
		_face = toward_you
	if m == "circle":
		global_position = _home + Vector3(CIRCLE_RADIUS, 0, 0)
	_phase = "move"
	_left = LANE / 2.0                          # from the middle: half a lane first
	if loco:
		loco.face(_face)
		rotation.y = _face

func set_gait(g: String) -> void:
	if GAITS.has(g):
		gait = g

## A head test: it stops where it is and turns its head.
func set_look(l: String) -> void:
	if not LOOKS.has(l):
		return
	look = l
	revive()
	if move != "idle":
		move = "idle"
		_phase = "move"
	_face = _viewer_yaw + PI                    # turns to face you first (on the spot), then looks
	_t = 0.0

## THE MANNEQUIN's kill, as a friend watching sees it: stood side-on to you (the head going round reads),
## frozen, the neck wrenched round, hanging, then down onto the knees and the floor. Dead from KILL_DEAD_AT,
## as the real thing is, lying there until revive(). False if the suit has no death_neck_snap clip.
func snap_neck() -> bool:
	if loco == null:
		return false
	prepare_kill()
	if not loco.play_kill():
		return false
	killing = true
	_kill_t = 0.0
	return true

## Stands still in the middle of its lane, side-on to you, for the kill (the mannequin is set behind it first)
func prepare_kill() -> void:
	revive()
	move = "idle"
	look = "ahead"
	_phase = "move"
	global_position = _home
	_face = kill_yaw()
	if loco:
		loco.face(_face)
	rotation.y = _face

## A new middle for its lane (and it stands there)
func move_home(p: Vector3) -> void:
	_home = p
	global_position = p

## Its facing for the kill (it faces -Z at rotation.y = this)
func kill_yaw() -> float:
	return _viewer_yaw + PI / 2.0

## Back on its feet, whatever had it
func revive() -> void:
	dead = false
	killing = false
	if loco:
		loco.end_kill()

func _process(dt: float) -> void:
	if loco == null:
		return
	var sdt := dt * time_scale
	_t += sdt
	if killing:
		_kill_t += sdt
		dead = _kill_t >= KILL_DEAD_AT
	var speed: float = GAIT_SPEED[gait]
	var vel := Vector3.ZERO
	var aim := _face
	var pitch := 0.0
	var d: Vector2 = MOVES[move][1]
	if dead or killing:
		pass
	elif move == "circle":
		# facing fixed, the way of travel going round: every direction in turn
		var w := speed / CIRCLE_RADIUS
		var ang := _t * w
		var off := Vector3(cos(ang), 0, sin(ang)) * CIRCLE_RADIUS
		var tangent := Vector3(-sin(ang), 0, cos(ang))
		global_position = _home + off
		vel = tangent * speed
	elif d != Vector2.ZERO:
		match _phase:
			"move":
				var dir := _world_dir(d.normalized(), _face)
				vel = dir * speed
				global_position += vel * sdt
				_left -= speed * sdt
				if _left <= 0.0:
					_phase = "pause"
					_left = PAUSE
			"pause":
				_left -= sdt
				if _left <= 0.0:
					_phase = "turn"
					_face = wrapf(_face + PI, -PI, PI)         # about-face: the same step brings it back
			"turn":
				if absf(wrapf(loco.body_yaw - _face, -PI, PI)) < deg_to_rad(6.0):
					_phase = "move"
					_left = LANE
		aim = _face
	else:
		var l: Array = LOOKS[look]
		var yaw := deg_to_rad(float(l[1]))
		if look == "sweep":
			yaw = deg_to_rad(65.0) * sin(_t * 1.3)
		aim = _face + yaw
		pitch = deg_to_rad(float(l[2]))
	var moving := vel.length() > 0.01
	var sprint := gait == "run" and moving
	var crouch := gait == "crouch"
	loco.update(sdt, vel, vel.length(), sprint, crouch, dead, aim, pitch)
	loco.tree.advance(sdt)
	rotation.y = loco.body_yaw
	_floor.on = not dead and not killing           # kneeling and lying are meant to be low
	_caption.text = describe()
	_caption.position.y = 0.9 if dead or (killing and _kill_t > 4.0) else (1.75 if crouch else 2.35)

## A direction in a body's own frame (x right, y forward) facing `yaw` -> world (the body faces -Z).
static func _world_dir(d: Vector2, yaw: float) -> Vector3:
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	return (right * d.x + fwd * d.y).normalized()

## One line for the console / panel: what it's doing and the clip that is mostly playing.
func describe() -> String:
	var what: String = MOVES[move][0]
	if killing:
		what = "NECK SNAP (THE MANNEQUIN) %.1f s%s  [death_neck_snap]" % [_kill_t, " - DEAD" if dead else ""]
		return "%s%s" % [what, "  (SLOW x%.2f)" % time_scale if time_scale < 1.0 else ""]
	if dead:
		what = "DEAD"
	elif MOVES[move][1] == Vector2.ZERO and move != "circle":
		what = LOOKS[look][0]
	var clip := ""
	if not dead and MOVES[move][1] != Vector2.ZERO:
		var names: Array = SurvivorAnim.DIRS[gait]
		var d: Vector2 = MOVES[move][1]
		clip = str(names[0] if d.y > 0.0 else names[1])
		if d.y == 0.0:
			clip = str(names[2] if d.x < 0.0 else names[3])
		elif d.x != 0.0:
			clip += " + " + str(names[2] if d.x < 0.0 else names[3])
		clip = "  [" + clip + "]"
	return "%s • %s%s%s" % [what, gait.to_upper(), clip, "  (SLOW x%.2f)" % time_scale if time_scale < 1.0 else ""]
