extends Node
## Save tapes: SLOTS numbered save files in user://saves/, picked on the lobby screen (lobby_screen.gd) that
## PLAY opens. Autoload name: Saves (listed after Archive and Clearance, whose state each tape carries).
##
## A tape holds the whole run as it stood: the level, floor and how you got onto it, where you stand and
## look, the vitals (health, sanity, stamina, torch battery and switch), the pack (every item and its count,
## the recovered papers, the roll of tape in use), the field archive and the T.S.R.A. clearance record (the
## XP: lifetime yield, tier, sites, survey, service record). While a tape is in (slot >= 0), Clearance keeps
## its record on the tape instead of its own lifetime file (tsra_clearance.gd _save), and the archive is no
## longer wiped at each level start (main.gd).
##
## Loading: begin(slot) reads the tape and sets the level, floor and records at once, so the menu warms and
## names the right level; the player, vitals and pack wait in _pending until the run's scene is up and
## main.gd calls apply(). A death respawns from the level start as before (_pending is used once).
## Writing: every AUTOSAVE_EVERY s of play, on every level or floor change, on every clearance filing, and
## on leaving the run (pause menu MAIN MENU, closing the window). Never while dead, and never on a guest:
## in co-op the host's tape is the run (a guest plays with slot -1).

signal changed                  # a tape was written or erased (the lobby redraws its slots)

const SLOTS := 3
const DIR := "user://saves/"
const VERSION := 1
const AUTOSAVE_EVERY := 60.0

var slot := -1                  # the tape in the deck: -1 none (a guest, a level editor test launch)
var play_time := 0.0            # s played on this tape, over every session
var _pending := {}              # the player's part of the tape, until the run's scene applies it
var _autosave_t := 0.0
var _floor_seen := Vector2i(-1, -1)    # (level, floor) last saved: a change saves at once

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().auto_accept_quit = false     # closing the window saves the tape first (_notification)

func path(i: int) -> String:
	return DIR + "tape_%d.cfg" % (i + 1)

func exists(i: int) -> bool:
	return FileAccess.file_exists(path(i))

## A tape's label for the lobby: {} if the slot is blank, else level, tier, play time, when it was written
func info(i: int) -> Dictionary:
	if not exists(i):
		return {}
	var cf := ConfigFile.new()
	if cf.load(path(i)) != OK:
		return {"broken": true}
	var out := {}
	for k in cf.get_section_keys("meta") if cf.has_section("meta") else []:
		out[k] = cf.get_value("meta", k)
	return out

func erase(i: int) -> void:
	if exists(i):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path(i)))
	if slot == i:
		slot = -1
		Clearance.use_lifetime()
	changed.emit()

## Put tape `i` in: a blank one starts a new run on the first level with an empty record; a written one
## sets the level, floor, archive and clearance from it now and keeps the rest for apply()
func begin(i: int) -> void:
	slot = i
	_pending = {}
	_autosave_t = 0.0
	var cf := ConfigFile.new()
	if not exists(i) or cf.load(path(i)) != OK:
		play_time = 0.0
		Game.level_index = 0
		Game.level_floor = 0
		Game.floor_link = {}
		Archive.forget_all()
		Clearance.read_from(ConfigFile.new())
		_floor_seen = Vector2i(0, 0)
		return
	play_time = float(cf.get_value("meta", "play_time", 0.0))
	Game.level_index = int(cf.get_value("run", "level_index", 0))
	Game.level_floor = int(cf.get_value("run", "level_floor", 0))
	Game.floor_link = cf.get_value("run", "floor_link", {})
	_floor_seen = Vector2i(Game.level_index, Game.level_floor)
	Archive.discovered = cf.get_value("archive", "discovered", {})
	Archive.unread = cf.get_value("archive", "unread", {})
	Clearance.read_from(cf)
	for k in ["player", "inventory", "tools"]:
		if cf.has_section(k):
			var part := {}
			for key in cf.get_section_keys(k):
				part[key] = cf.get_value(k, key)
			_pending[k] = part
	_pending["game"] = {"time": cf.get_value("run", "game_time", 0.0), "distance": cf.get_value("run", "distance", 0.0)}

## No tape (joining someone else's lobby): the clearance goes back to the lifetime file
func eject() -> void:
	slot = -1
	_pending = {}
	Clearance.use_lifetime()

## main.gd, once the player, level and HUD are built: put the player back where the tape left them
func apply(main: Node) -> void:
	if _pending.is_empty():
		return
	var p: Node3D = main.player
	var pl: Dictionary = _pending.get("player", {})
	if pl.has("pos"):
		p.global_position = pl.pos
		p.rotation.y = float(pl.get("yaw", p.rotation.y))
		var cam: Camera3D = p.get_node_or_null("Camera3D")
		if cam:
			cam.rotation.x = float(pl.get("pitch", 0.0))
		if p is CharacterBody3D:
			(p as CharacterBody3D).velocity = Vector3.ZERO
	for k in ["health", "sanity", "stamina", "battery", "flash_on"]:
		if pl.has(k):
			p.set(k, pl[k])
	var inv: Node = main.ui.inventory
	var it: Dictionary = _pending.get("inventory", {})
	if it.has("items"):
		inv.items = it.items
		inv.lore_entries = it.get("lore", [])
		inv.selected = clampi(int(it.get("selected", 0)), -1, inv.items.size() - 1)
		inv._refresh_items()
		inv._refresh_page("PAPERS")
	var tape: Node = main.ui.get("tape")
	var tools: Dictionary = _pending.get("tools", {})
	if tape and tools.has("roll_left"):
		tape.roll_left = float(tools.roll_left)
	var g: Dictionary = _pending.get("game", {})
	Game.time = float(g.get("time", 0.0))
	Game.distance = float(g.get("distance", 0.0))
	_pending = {}

## Can the run be written right now? (a tape in, our own run, a live player in a built scene)
func can_save() -> bool:
	if slot < 0 or Game.dead or Game.editor_test or (Net.is_online() and not Net.hosting):
		return false
	var p: Node = Game.player
	return p != null and is_instance_valid(p) and p.is_inside_tree() and not p.get("dead") \
		and Game.main != null and is_instance_valid(Game.main) and _pending.is_empty()

func save_now() -> bool:
	if not can_save():
		return false
	var cf := ConfigFile.new()
	var p: Node3D = Game.player
	var main: Node = Game.main
	var names: GDScript = load("res://scripts/World/level/level_data.gd")
	var tier: Dictionary = Clearance.tier()
	cf.set_value("meta", "version", VERSION)
	cf.set_value("meta", "saved_unix", int(Time.get_unix_time_from_system()))
	cf.set_value("meta", "level_tag", names.current_level_tag())
	cf.set_value("meta", "level_name", _level_name())
	cf.set_value("meta", "floor", Game.level_floor)
	cf.set_value("meta", "play_time", play_time)
	cf.set_value("meta", "tier_code", str(tier.get("code", "")))
	cf.set_value("meta", "tier_title", str(tier.get("title", "")))
	cf.set_value("meta", "yield", Clearance.total)
	cf.set_value("meta", "unit", Clearance.unit)
	cf.set_value("meta", "logged", Archive.discovered.size())
	cf.set_value("meta", "health", float(p.get("health")))
	cf.set_value("run", "level_index", Game.level_index)
	cf.set_value("run", "level_floor", Game.level_floor)
	cf.set_value("run", "floor_link", Game.floor_link)
	cf.set_value("run", "game_time", Game.time)
	cf.set_value("run", "distance", Game.distance)
	cf.set_value("player", "pos", p.global_position)
	cf.set_value("player", "yaw", p.rotation.y)
	var cam: Camera3D = p.get_node_or_null("Camera3D")
	cf.set_value("player", "pitch", cam.rotation.x if cam else 0.0)
	for k in ["health", "sanity", "stamina", "battery", "flash_on"]:
		cf.set_value("player", k, p.get(k))
	var inv: Node = main.ui.inventory
	cf.set_value("inventory", "items", inv.items.duplicate(true))
	cf.set_value("inventory", "lore", inv.lore_entries.duplicate(true))
	cf.set_value("inventory", "selected", inv.selected)
	var tape: Node = main.ui.get("tape")
	if tape:
		cf.set_value("tools", "roll_left", tape.roll_left)
	cf.set_value("archive", "discovered", Archive.discovered)
	cf.set_value("archive", "unread", Archive.unread)
	Clearance.write_to(cf)
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

## Clearance filed something: written at the end of the frame (a filing can come with others in one frame)
var _soon := false
func save_soon() -> void:
	if _soon:
		return
	_soon = true
	(func() -> void:
		_soon = false
		save_now()).call_deferred()

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
