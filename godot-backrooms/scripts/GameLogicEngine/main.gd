extends Node3D
## Wires up the player, UI and audio. Esc is native here: no browser cooldown.

@onready var level := $Level
@onready var player := $Player
@onready var ui := $UI
@onready var audio := $Audio

func _ready() -> void:
	player.global_position = level.spawn_pos
	level.player = player
	Game.bind(player, level, self)
	Game.dead = false
	Death.warmup.call_deferred()
	ui.apply_settings()
	Gfx.apply_scene(self)
	$Entity.mannequin = $Mannequin
	$Events.mimic = $Mimic
	ui.inventory.close_requested.connect(func(): set_inventory(false))
	if Game.respawned:
		# respawn (death.js finishRespawn): straight back into the game, no title screen
		Game.respawned = false
		set_paused(false)
	else:
		set_paused(true, true)      # start screen, like the web game's #start-screen

func toggle_fullscreen() -> void:
	var fs := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if fs else DisplayServer.WINDOW_MODE_FULLSCREEN)

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and (e.physical_keycode == KEY_F11 or (e.physical_keycode == KEY_ENTER and e.alt_pressed)):
		toggle_fullscreen()
		return
	if e is InputEventKey and e.pressed and not e.echo and e.physical_keycode == KEY_TAB \
			and Game.playing and not ui.menu.shown and not Game.dead:
		set_inventory(not ui.inventory.shown)
		return
	if e is InputEventKey and e.pressed and not e.echo and e.physical_keycode == KEY_ESCAPE:
		if ui.inventory.shown:
			set_inventory(false)
			return
		if ui.menu.shown and ui.menu.close_panel():
			return                  # ESC closes the Settings / Controls panel first
		set_paused(not ui.menu.shown)
	elif ui.menu.shown and e is InputEventMouseButton and e.pressed:
		set_paused(false)
		get_viewport().set_input_as_handled()   # the click that closes the menu must not also respawn you

# Alt-tab or a click on another window mid-run: pause, rather than leave you unable to move while
# it keeps hunting
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and Game.playing and not Game.dead and not ui.menu.shown:
		set_paused(true)

func set_paused(on: bool, start := false) -> void:
	Game.playing = not on
	if on: set_inventory(false)
	ui.set_paused(on, start)
	audio.set_paused(on)
	# the death screen wants the cursor (click to respawn) whether or not the menu was opened over it
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if (on or Game.dead) else Input.MOUSE_MODE_CAPTURED

func set_inventory(on: bool) -> void:
	ui.inventory.set_shown(on)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if (on or ui.menu.shown or Game.dead) else Input.MOUSE_MODE_CAPTURED
