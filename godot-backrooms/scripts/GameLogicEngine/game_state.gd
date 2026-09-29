extends Node
## Shared run state (the web game's `game` object): clocks, fear channels the post shader reads,
## and the death sequence. Autoload name: Game.

signal player_died(reason: String)

const DeathOverlay := preload("res://scripts/UI/death/death_overlay.gd")

# How you died: picks which reaction sound scares.gd plays at the moment it happens (bite scream,
# neck crack, ...). RIPPED / EXPLODED / STRANGLED have no reaction sound/fx yet: add one
# to scares.gd's death_reaction() and death_fx.gd when they do.
enum DeathType { NONE, NECK_SNAP, BITE, RIPPED, EXPLODED, STRANGLED }

# The death shot plays for this long before a click or key respawns you, so the button you were
# mashing when it got you doesn't skip it
const RESPAWN_READY := 1.6

var playing := false          # false on the start screen / pause menu
var time := 0.0               # seconds of play time (events, mannequin timers)
var event_fear := 0.0         # fear pulse from random events, decays on its own
var glitch := 0.0             # 0..1 visual tracking tear from events and scares
var terror := 0.0             # entity proximity only (0..1)
var fear := 0.0               # everything: terror, sanity, darkness, events
var presence := 0.0           # 0..1 how near the entity is (drives dread audio)
var hunted := false
var heart: Node               # the heartbeat engine (heart.gd): threats feed it, it keeps the beat
var pulse := 0.0              # heartbeat envelope 0..1 for the tunnel vision
var dead := false
var death_reason := ""
var death_type := DeathType.NONE
# Grab / snap screen effects, read by the post shader (web: CSS filter/transform on the canvas + #grab-fade)
var fx_blur := 0.0
var fx_contrast := 1.0
var fx_sat := 1.0
var fx_hue := 0.0
var fx_zoom := 1.0
var fx_skew := 0.0
var fx_fade := 0.0
var fx_flash := 0.0
var fx_shock := 0.0
var fx_blood := 0.0
var fx_static := 0.0
var fx_warp := 0.0
var fx_classic := 0.0         # 0..1 in a Classic zone (set by level_lighting.gd, read by the post shader)
var fx_blink := 0.0           # 0 eyes open .. 1 lids shut (player/blink.gd, drawn by the post shader)
var fx_fade_release := false  # after death the black/red edges clear over 1.8s (endGrab(dying))
var level_index := 0          # which levels/levels.json entry is loaded (survives the scene reload)
var level_count := 1
# The open-air hills level (hills_portal.gd): the tube-light / hum / horror-bed logic is swapped for the sky's.
var outdoors := false
var day_light := 1.0          # how bright the outdoors is right now, 0 = moonlit night .. 1 = full day

var respawned := false        # the level was reloaded by a respawn: skip the title screen
# The F-key shortcuts that summon monsters, fire events and switch levels. On in the editor and debug
# builds; a released build only has them when launched with --dev, so a stray F-key can't spawn the
# bacteria in a player's face.
var dev_keys := OS.is_debug_build() or OS.get_cmdline_user_args().has("--dev") or OS.get_cmdline_args().has("--dev")

# Level-editor test launch: --test-level=<id from levels.json> boots straight into that level (skipping
# the title screen) and --noclip lets you fly through walls to look around.
var test_level := _launch_arg("--test-level=")
var noclip := OS.get_cmdline_user_args().has("--noclip") or OS.get_cmdline_args().has("--noclip")

static func _launch_arg(prefix: String) -> String:
	for a in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			return a.substr(prefix.length())
	return ""

var player: Node
var level: Node
var main: Node

var _overlay: DeathOverlay = null
var _death_t := 0.0
# This life's numbers for the death screen's RECORDING ENDED sheet (death_overlay.gd)
var distance := 0.0           # metres walked, on the flat
var run_yield0 := 0           # Clearance.total when this life began
var _last_pos := Vector3.ZERO
var _have_pos := false

func fx_reset(keep_fade := false) -> void:
	fx_blur = 0.0; fx_contrast = 1.0; fx_sat = 1.0; fx_hue = 0.0; fx_zoom = 1.0; fx_skew = 0.0; fx_flash = 0.0; fx_shock = 0.0; fx_blink = 0.0
	if not keep_fade:
		fx_blood = 0.0; fx_static = 0.0; fx_warp = 0.0; fx_fade = 0.0
	fx_fade_release = false

func _process(dt: float) -> void:
	fx_flash *= exp(-dt * 18.0)
	fx_shock *= exp(-dt * 9.0)
	if fx_fade_release:
		fx_fade = maxf(0.0, fx_fade - dt / 1.8)
		fx_static = maxf(0.0, fx_static - dt * 0.12)
		fx_warp = maxf(0.0, fx_warp - dt * 0.004)
		fx_blood = maxf(0.0, fx_blood - dt * 0.12)
	if playing and not dead:
		time += dt
		_track_distance()
	event_fear = maxf(0.0, event_fear - dt * 0.22)
	glitch = maxf(0.0, glitch - dt * 0.6)
	pulse = maxf(0.0, pulse - dt * 3.0)
	if dead:
		_death_t += dt

func bind(p: Node, l: Node, m: Node) -> void:
	player = p
	level = l
	main = m
	outdoors = false          # a fresh scene always starts in the backrooms
	distance = 0.0
	run_yield0 = Clearance.total
	_have_pos = false

func _track_distance() -> void:
	if player == null or not is_instance_valid(player):
		return
	var p: Vector3 = player.global_position
	if _have_pos:
		var step := Vector2(p.x - _last_pos.x, p.z - _last_pos.z).length()
		if step < 3.0:            # a teleport (spawn, portal) is not walking
			distance += step
	_last_pos = p
	_have_pos = true

## What the death screen lists: this life's time on tape, distance, entries logged and yield filed
func run_stats() -> Dictionary:
	return {
		"time": time,
		"distance": distance,
		"logged": Archive.discovered.size(),
		"yield": maxi(0, Clearance.total - run_yield0),
		"unit": Clearance.unit,
		"level": load("res://scripts/World/level/level_data.gd").current_level_tag(),
	}

func haunt(amount: float) -> void:
	event_fear = maxf(event_fear, amount)

func add_glitch(amount: float) -> void:
	glitch = maxf(glitch, amount)

func beat() -> void:
	pulse = 1.0

# The entity, the mannequin or the dark got you. `type` is which death this was (DeathType) - its
# own reaction sound already played at the moment itself (see scares.gd death_reaction()); this just
# records it so the death sequence can tell them apart later if it needs to.
func kill_player(reason: String, type := DeathType.NONE) -> void:
	if dead:
		return
	dead = true
	death_type = type
	# a grab or snap has already closed the edges in; anything else kills you out of nowhere
	var sudden := fx_fade < 0.5
	fx_reset(true)
	fx_fade_release = true
	if sudden:
		# it lands as a blow: a shock burst, and the edges slam shut, then open on the body
		fx_shock = 1.0
		fx_fade = 0.75
	death_reason = reason if reason != "" else "THE BACKROOMS"
	_death_t = 0.0
	glitch = 1.0
	var scene: Node = main if main != null and is_instance_valid(main) else get_tree().current_scene
	var sc: Node = scene.get_node_or_null("Scares") if scene else null
	if sc != null:
		# a grab / snap already had its scream and stinger at the bite: don't hit a second time into the black
		if sudden:
			sc.gasp()
			sc.play_scare("staticHit", 1.2)
			sc.startle(0.9)
		sc.heart_stop()          # ends in a quiet flatline that holds until the respawn
		sc.entity_breathe(0.0)
	# every death, not only the grab: the world settles into a dull, distant muffle until the respawn,
	# and you stop breathing (a broken neck doesn't even get the last breath out)
	var au: Node = scene.get_node_or_null("Audio") if scene else null
	if au != null:
		au.set_dread(0.0)
		au.set_muffled(true)
		if sudden:                 # eaten or neck snapped: there is no last breath to let out
			au.breathing.last_breath()
	if player:
		player.set("dead", true)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# Start the death camera sequence (death.gd autoload)
	if player:
		var cam: Camera3D = player.get_node_or_null("Camera3D")
		var cam_world: Vector3 = cam.global_position if cam else player.global_position + Vector3(0, 1.7, 0)
		if cam:
			var xf := cam.global_transform
			cam.top_level = true   # detach from player transform so orbit works in world space
			cam.global_transform = xf
		Death.bind(cam, player, sc)
		Death.start(reason, player.global_position, cam_world, player.rotation.y)
	_clear_overlay()
	_overlay = DeathOverlay.new(death_reason, RESPAWN_READY, run_stats())
	add_child(_overlay)
	player_died.emit(reason)

func _clear_overlay() -> void:
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.queue_free()
	_overlay = null

func _unhandled_input(e: InputEvent) -> void:
	if not dead or not playing:     # the pause menu is open over the death screen: it has the input
		return
	if _death_t < RESPAWN_READY:
		return
	var press := (e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT) \
		or (e is InputEventKey and e.pressed and not e.echo \
			and (e.keycode == KEY_SPACE or e.keycode == KEY_ENTER or e.keycode == KEY_KP_ENTER))
	if not press:
		return
	get_viewport().set_input_as_handled()
	# the first press only brings the RECORDING ENDED sheet in at once; the next one respawns
	if _overlay != null and is_instance_valid(_overlay) and not _overlay.finished():
		_overlay.skip()
		return
	_respawn()

# Respawn dissolves through TV static (death.js): the level is only reloaded once the screen is covered
func _respawn() -> void:
	if Death.respawn_busy:
		return
	Death.respawn_transition(restart)

# Switch level (wraps around the playlist) through the TV-static dissolve, like a respawn
func change_level(idx: int) -> void:
	if Death.respawn_busy:
		return
	level_index = posmod(idx, maxi(level_count, 1))
	Net.broadcast_level(level_index)      # co-op: the host takes everyone along
	Death.respawn_transition(restart)

func next_level() -> void:
	change_level(level_index + 1)

## Back to the title screen mid-run (the pause menu's MAIN MENU), dead or alive: drop the death
## screen, the death camera and its blood, and every screen effect and clock, so none of it follows
## you into the title or the next run
func end_run() -> void:
	playing = false
	dead = false
	respawned = false
	death_type = DeathType.NONE
	fx_reset()
	time = 0.0
	event_fear = 0.0
	glitch = 0.0
	terror = 0.0
	fear = 0.0
	presence = 0.0
	hunted = false
	_clear_overlay()
	Death.stop()

func restart() -> void:
	respawned = true
	dead = false
	death_type = DeathType.NONE
	fx_reset()
	time = 0.0
	event_fear = 0.0
	glitch = 0.0
	terror = 0.0
	fear = 0.0
	presence = 0.0
	hunted = false
	playing = true
	_clear_overlay()
	Death.stop()
	get_tree().reload_current_scene()
