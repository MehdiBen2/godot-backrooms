extends Node
## Save tapes: SLOTS numbered save files in user://saves/, picked on the lobby screen (lobby_screen.gd) that
## PLAY opens. Autoload name: Saves.
##
## A tape holds the whole run: the level, the floor and how they got onto it, where the player stands and looks,
## their vitals (health, sanity, stamina, the torch's battery and switch), the pack and the recovered files
## (inventory.gd), the archive's entries (tsra_archive.gd), the clocks (the cassette's time, the HUD counter,
## distance walked, this life's start), the terminal's credits (terminal_os.gd) and the hazard tape the player
## stuck up on every level (tape_marks.gd). The clearance XP and rank live in their own file beside the tape
## (Clearance.slot_path), switched in by begin().
##
## Loading: begin(slot) reads the tape and sets the level, floor, credits and tape strips at once, so the menu
## warms and names the right level; the rest waits in _pending / _run until the run's scene is up and main.gd
## calls apply(). A death respawns from the level start with the starting kit, as before (both are used once).
## Writing: every AUTOSAVE_EVERY s of play, on every level or floor change, on leaving the run (pause menu
## MAIN MENU) and on closing the window. Never while dead, and never on a guest: in co-op the host's tape is
## the run (a guest plays with slot -1).

signal changed                  # a tape was written or erased (the lobby redraws its slots)

const SLOTS := 3
const DIR := "user://saves/"
const VERSION := 2              # 1: position only (its pack, vitals and archive start fresh)
const AUTOSAVE_EVERY := 30.0
const TapeMarks := preload("res://scripts/World/props/tape_marks.gd")
const TerminalOS := preload("res://scripts/UI/terminal_os.gd")
const START_CREDITS := 150      # terminal_os.gd credit_balance on a blank tape

var slot := -1                  # the tape in the deck: -1 none (a guest, a level editor test launch)
var play_time := 0.0            # s played on this tape, over every session
var _pending := {}              # where the player stood, until the run's scene applies it
var _run := {}                  # the rest of the player's part of the tape (vitals, pack, archive, clocks), likewise
var _autosave_t := 0.0
var _floor_seen := Vector2i(-1, -1)    # (level, floor) last saved: a change saves at once

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().auto_accept_quit = false     # closing the window saves the tape first (_notification)

func path(i: int) -> String:
	return DIR + "tape_%d.cfg" % (i + 1)

func exists(i: int) -> bool:
	return FileAccess.file_exists(path(i))

## A tape's label for the lobby: {} if the slot is blank, {"broken": true} if unreadable, else its meta
func info(i: int) -> Dictionary:
	if not exists(i):
		return {}
	var cf := ConfigFile.new()
	if cf.load(path(i)) != OK:
		return {"broken": true}
	var out := {}
	if cf.has_section("meta"):
		for k in cf.get_section_keys("meta"):
			out[k] = cf.get_value("meta", k)
	return out

func erase(i: int) -> void:
	for p in [path(i), Clearance.slot_path(i)]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	if slot == i:
		slot = -1
		Clearance.use_slot(-1)      # or its next filing would write the erased record back
	changed.emit()

## Put tape `i` in: a blank one starts a new run on the first level; a written one sets the level and floor from
## it now and keeps the rest for apply()
func begin(i: int) -> void:
	slot = i
	_pending = {}
	_run = {}
	_autosave_t = 0.0
	Clearance.use_slot(i)
	var cf := ConfigFile.new()
	if not exists(i) or cf.load(path(i)) != OK:
		play_time = 0.0
		Game.level_index = 0
		Game.level_floor = 0
		Game.floor_link = {}
		TerminalOS.credit_balance = START_CREDITS
		TapeMarks.restore([])
		_floor_seen = Vector2i(0, 0)
		return
	play_time = float(cf.get_value("meta", "play_time", 0.0))
	Game.level_index = int(cf.get_value("run", "level_index", 0))
	Game.level_floor = int(cf.get_value("run", "level_floor", 0))
	Game.floor_link = cf.get_value("run", "floor_link", {})
	TerminalOS.credit_balance = int(cf.get_value("world", "credits", START_CREDITS))
	TapeMarks.restore(cf.get_value("world", "tape", []))
	for sec in ["vitals", "pack", "archive", "clock"]:
		if cf.has_section(sec):
			_run[sec] = {}
			for k in cf.get_section_keys(sec):
				_run[sec][k] = cf.get_value(sec, k)
	# the level may have been changed since the tape was written: a floor it no longer has starts at its spawn
	var LevelData := load("res://scripts/World/level/level_data.gd")
	var levels: Array = LevelData.read_index()
	if not levels.is_empty() and not LevelData.in_stack(LevelData.read_level(levels[clampi(Game.level_index, 0, levels.size() - 1)]), Game.level_floor):
		Stability.trace("saves: tape %d is on floor %d, which the level no longer has: starting on its ground floor" % [i, Game.level_floor])
		Game.level_floor = 0
		Game.floor_link = {}
		_floor_seen = Vector2i(Game.level_index, 0)
		return
	_floor_seen = Vector2i(Game.level_index, Game.level_floor)
	if cf.has_section_key("player", "pos"):
		_pending = {"pos": cf.get_value("player", "pos"), "yaw": cf.get_value("player", "yaw", 0.0),
			"pitch": cf.get_value("player", "pitch", 0.0)}

## No tape (joining someone else's lobby): the host's run is the run
func eject() -> void:
	slot = -1
	_pending = {}
	_run = {}
	Clearance.use_slot(-1)

## main.gd, once the player and level are built: put the run back the way the tape left it
func apply(main: Node) -> void:
	if not _run.is_empty():
		_apply_run(main)
		_run = {}
	if _pending.is_empty():
		return
	var p: Node3D = main.player
	if not main.level.can_stand_at(_pending.pos):
		# a wall, a pit or the void there now (the level changed since): the floor's spawn, where main.gd put them
		Stability.trace("saves: the tape's spot %s is not open on this floor any more: starting at its spawn" % [_pending.pos])
		_pending = {}
		return
	p.global_position = _pending.pos
	p.rotation.y = float(_pending.yaw)
	var cam: Camera3D = p.get_node_or_null("Camera3D")
	if cam:
		cam.rotation.x = float(_pending.pitch)
	if p is CharacterBody3D:
		(p as CharacterBody3D).velocity = Vector3.ZERO
	_pending = {}

func _apply_run(main: Node) -> void:
	var p: Node = main.player
	var v: Dictionary = _run.get("vitals", {})
	for k in ["health", "sanity", "stamina", "battery"]:
		if v.has(k):
			p.set(k, clampf(float(v[k]), 1.0 if k == "health" else 0.0, 100.0))
	if v.has("flash_on"):
		p.set("flash_on", bool(v.flash_on) and float(p.get("battery")) > 0.0)
	var pack: Dictionary = _run.get("pack", {})
	var inv: Node = main.ui.get("inventory")
	if pack.has("items") and inv != null:
		inv.restore(pack.items, pack.get("lore", []), int(pack.get("selected", 0)))
	var ar: Dictionary = _run.get("archive", {})
	if ar.has("discovered"):
		Archive.restore(ar.discovered, ar.get("unread", {}))
	var c: Dictionary = _run.get("clock", {})
	Game.time = float(c.get("time", Game.time))
	Game.distance = float(c.get("distance", Game.distance))
	Game.run_unix = int(c.get("run_unix", Game.run_unix))
	Game.run_yield = int(c.get("run_yield", Game.run_yield))
	if c.has("counter") and "t" in main.ui:
		main.ui.set("t", float(c.counter))

## Can the run be written right now? (a tape in, our own run, a live player in a built scene)
func can_save() -> bool:
	if slot < 0 or Game.dead or Game.editor_test or (Net.is_online() and not Net.hosting):
		return false
	var p: Node = Game.player
	if not (p != null and is_instance_valid(p) and p.is_inside_tree() and not p.get("dead") \
		and Game.main != null and is_instance_valid(Game.main) and _pending.is_empty() and _run.is_empty()):
		return false
	# never mid-way: a floor still being built, a fall or a jump, a flight (a tape put you back there, in the air)
	if Game.freefall or Game.noclip or Game.draw_mode:
		return false
	if Game.level != null and is_instance_valid(Game.level) and Game.level.has_method("settled") and not Game.level.settled():
		return false
	return not (p is CharacterBody3D) or (p as CharacterBody3D).is_on_floor()

func save_now() -> bool:
	if not can_save():
		return false
	var cf := ConfigFile.new()
	var p: Node3D = Game.player
	cf.set_value("meta", "version", VERSION)
	cf.set_value("meta", "saved_unix", int(Time.get_unix_time_from_system()))
	cf.set_value("meta", "level_tag", load("res://scripts/World/level/level_data.gd").current_level_tag())
	cf.set_value("meta", "level_name", _level_name())
	cf.set_value("meta", "floor", Game.level_floor)
	cf.set_value("meta", "play_time", play_time)
	cf.set_value("meta", "rank", Clearance.tier_label())
	cf.set_value("run", "level_index", Game.level_index)
	cf.set_value("run", "level_floor", Game.level_floor)
	cf.set_value("run", "floor_link", Game.floor_link)
	cf.set_value("player", "pos", p.global_position)
	cf.set_value("player", "yaw", p.rotation.y)
	var cam: Camera3D = p.get_node_or_null("Camera3D")
	cf.set_value("player", "pitch", cam.rotation.x if cam else 0.0)
	for k in ["health", "sanity", "stamina", "battery", "flash_on"]:
		cf.set_value("vitals", k, p.get(k))
	var ui: Node = Game.main.get_node_or_null("UI")
	var inv: Node = ui.get("inventory") if ui else null
	if inv != null:
		cf.set_value("pack", "items", inv.items)
		cf.set_value("pack", "selected", inv.selected)
		cf.set_value("pack", "lore", inv.lore_entries)
	cf.set_value("archive", "discovered", Archive.discovered)
	cf.set_value("archive", "unread", Archive.unread)
	cf.set_value("clock", "time", Game.time)
	cf.set_value("clock", "distance", Game.distance)
	cf.set_value("clock", "run_unix", Game.run_unix)
	cf.set_value("clock", "run_yield", Game.run_yield)
	if ui != null and "t" in ui:
		cf.set_value("clock", "counter", ui.get("t"))
	cf.set_value("world", "credits", TerminalOS.credit_balance)
	cf.set_value("world", "tape", TapeMarks.pack_mine())
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	# written beside the tape, then swapped in: a crash mid-write never leaves half a tape
	var tmp := path(slot) + ".tmp"
	if cf.save(tmp) != OK:
		return false
	DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(path(slot)))
	_autosave_t = 0.0
	_floor_seen = Vector2i(Game.level_index, Game.level_floor)
	changed.emit()
	return true

func _level_name() -> String:
	var levels: Array = load("res://scripts/World/level/level_data.gd").read_index()
	if levels.is_empty():
		return "LEVEL 0"
	return str(levels[clampi(Game.level_index, 0, levels.size() - 1)].get("name", "LEVEL 0"))

func _process(dt: float) -> void:
	if slot < 0 or not Game.playing or Game.dead:
		return
	play_time += dt
	_autosave_t += dt
	var at := Vector2i(Game.level_index, Game.level_floor)
	if _autosave_t >= AUTOSAVE_EVERY or (at != _floor_seen and Game.level != null and Game.level.get("rebuilding") != true):
		if not save_now():
			_autosave_t = AUTOSAVE_EVERY * 0.5      # not now (no player yet): try again in a while

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_now()
		get_tree().quit()
