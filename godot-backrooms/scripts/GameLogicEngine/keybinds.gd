extends Node
## Keybinds manager and InputMap bindings for The Backrooms.
## Supports layout presets (AZERTY / QWERTY), custom rebinding, and persists to user://settings.cfg.

signal keybinds_changed

const SETTINGS_PATH := "user://settings.cfg"
const BINDS_VERSION := 2

const ACTIONS: Array[Dictionary] = [
	{
		"id": "move_forward",
		"name": "Move Forward",
		"desc": "Walk forward in the halls",
		"default_qwerty": KEY_W,
		"default_azerty": KEY_Z,
		"alt_keys": [KEY_UP]
	},
	{
		"id": "move_backward",
		"name": "Move Backward",
		"desc": "Walk backward",
		"default_qwerty": KEY_S,
		"default_azerty": KEY_S,
		"alt_keys": [KEY_DOWN]
	},
	{
		"id": "move_left",
		"name": "Move Left",
		"desc": "Strafe left",
		"default_qwerty": KEY_A,
		"default_azerty": KEY_Q,
		"alt_keys": [KEY_LEFT]
	},
	{
		"id": "move_right",
		"name": "Move Right",
		"desc": "Strafe right",
		"default_qwerty": KEY_D,
		"default_azerty": KEY_D,
		"alt_keys": [KEY_RIGHT]
	},
	{
		"id": "sprint",
		"name": "Sprint",
		"desc": "Sprint (consumes stamina)",
		"default_qwerty": KEY_SHIFT,
		"default_azerty": KEY_SHIFT,
		"alt_keys": []
	},
	{
		"id": "jump",
		"name": "Jump",
		"desc": "Jump over gaps / obstacles",
		"default_qwerty": KEY_SPACE,
		"default_azerty": KEY_SPACE,
		"alt_keys": []
	},
	{
		"id": "crouch",
		"name": "Crouch",
		"desc": "Crouch low, softer steps (Ctrl works too)",
		"default_qwerty": KEY_C,
		"default_azerty": KEY_C,
		"alt_keys": [KEY_CTRL]
	},
	{
		"id": "flashlight",
		"name": "Flashlight",
		"desc": "Toggle flashlight beam",
		"default_qwerty": KEY_F,
		"default_azerty": KEY_F,
		"alt_keys": []
	},
	{
		"id": "battery",
		"name": "Load Battery",
		"desc": "Recharge flashlight (+45%)",
		"default_qwerty": KEY_R,
		"default_azerty": KEY_R,
		"alt_keys": []
	},
	{
		"id": "flash",
		"name": "Camera Flash",
		"desc": "Blind entities (Right Click works too)",
		"default_qwerty": KEY_G,
		"default_azerty": KEY_G,
		"alt_keys": []
	},
	{
		"id": "camera",
		"name": "Camcorder Zoom",
		"desc": "Hold to raise the camcorder, mouse wheel to zoom",
		"default_qwerty": KEY_E,
		"default_azerty": KEY_E,
		"alt_keys": []
	},
	{
		"id": "tape",
		"name": "Hazard Tape",
		"desc": "Mark your path on walls or floor",
		"default_qwerty": KEY_T,
		"default_azerty": KEY_T,
		"alt_keys": []
	},
	{
		"id": "inventory",
		"name": "Inventory",
		"desc": "Open dossier, items and clearance",
		"default_qwerty": KEY_TAB,
		"default_azerty": KEY_TAB,
		"alt_keys": []
	},
	{
		"id": "voice",
		"name": "Push to Talk",
		"desc": "Hold to speak in co-op voice chat",
		"default_qwerty": KEY_V,
		"default_azerty": KEY_V,
		"alt_keys": []
	},
	{
		"id": "scanner",
		"name": "Scanner",
		"desc": "Hold to analyze entities in view",
		"default_qwerty": KEY_Q,
		"default_azerty": KEY_A,
		"alt_keys": []
	},
]

var binds: Dictionary = {}
var current_preset := "azerty"

func _ready() -> void:
	_init_defaults("azerty")
	_load()
	apply_to_input_map()

func _init_defaults(preset: String) -> void:
	current_preset = preset
	for act in ACTIONS:
		var k: Key = act.default_azerty if preset == "azerty" else act.default_qwerty
		binds[act.id] = k

func get_key(action_id: String) -> Key:
	if binds.has(action_id):
		return binds[action_id] as Key
	for act in ACTIONS:
		if act.id == action_id:
			return act.default_azerty as Key
	return KEY_NONE

func get_key_name(action_id: String) -> String:
	return format_key_name(get_key(action_id))

static func format_key_name(k: int) -> String:
	match k:
		KEY_NONE: return "NONE"
		KEY_ESCAPE: return "ESC"
		KEY_TAB: return "TAB"
		KEY_BACKSPACE: return "BKSP"
		KEY_ENTER: return "ENTER"
		KEY_KP_ENTER: return "ENTER"
		KEY_INSERT: return "INS"
		KEY_DELETE: return "DEL"
		KEY_HOME: return "HOME"
		KEY_END: return "END"
		KEY_LEFT: return "←"
		KEY_UP: return "↑"
		KEY_RIGHT: return "→"
		KEY_DOWN: return "↓"
		KEY_PAGEUP: return "PGUP"
		KEY_PAGEDOWN: return "PGDN"
		KEY_SHIFT: return "SHIFT"
		KEY_CTRL: return "CTRL"
		KEY_ALT: return "ALT"
		KEY_CAPSLOCK: return "CAPS"
		KEY_SPACE: return "SPACE"
		_:
			var s := OS.get_keycode_string(k)
			return s.to_upper() if s != "" else str(k)

func set_key(action_id: String, keycode: Key) -> void:
	binds[action_id] = keycode
	current_preset = "custom"
	_save()
	apply_to_input_map()
	keybinds_changed.emit()

func apply_preset(preset_name: String) -> void:
	_init_defaults(preset_name)
	_save()
	apply_to_input_map()
	keybinds_changed.emit()

func reset_defaults() -> void:
	apply_preset("azerty")

func apply_to_input_map() -> void:
	for act in ACTIONS:
		var action_name := StringName(act.id)
		if not InputMap.has_action(action_name):
			InputMap.add_action(action_name)
		else:
			InputMap.action_erase_events(action_name)
		
		var primary_key: Key = get_key(act.id)
		if primary_key != KEY_NONE:
			var ev_log := InputEventKey.new()
			ev_log.keycode = primary_key
			InputMap.action_add_event(action_name, ev_log)
		
		# Secondary/alternative inputs (arrows, ctrl, etc.)
		var alts: Array = act.get("alt_keys", [])
		for alt in alts:
			var alt_key := alt as Key
			if alt_key != primary_key and alt_key != KEY_NONE:
				var ev_alt_log := InputEventKey.new()
				ev_alt_log.keycode = alt_key
				InputMap.action_add_event(action_name, ev_alt_log)
		
		# Camera flash has right click as alternate action
		if act.id == "flash":
			var mb := InputEventMouseButton.new()
			mb.button_index = MOUSE_BUTTON_RIGHT
			InputMap.action_add_event(action_name, mb)

func _load() -> void:
	var cf := ConfigFile.new()
	if cf.load(SETTINGS_PATH) != OK:
		return
	# Binds saved before v2 stored physical key codes; drop them so AZERTY defaults apply.
	if int(cf.get_value("keybinds_meta", "version", 1)) < BINDS_VERSION:
		return
	if cf.has_section("keybinds"):
		for act in ACTIONS:
			if cf.has_section_key("keybinds", act.id):
				binds[act.id] = int(cf.get_value("keybinds", act.id, binds[act.id])) as Key
	if cf.has_section_key("keybinds_meta", "preset"):
		current_preset = str(cf.get_value("keybinds_meta", "preset", current_preset))

func _save() -> void:
	var cf := ConfigFile.new()
	cf.load(SETTINGS_PATH) # Load existing file to preserve other sections (volume, graphics, etc.)
	for act in ACTIONS:
		cf.set_value("keybinds", act.id, int(binds[act.id]))
	cf.set_value("keybinds_meta", "preset", current_preset)
	cf.set_value("keybinds_meta", "version", BINDS_VERSION)
	cf.save(SETTINGS_PATH)
