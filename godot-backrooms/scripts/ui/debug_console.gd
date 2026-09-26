extends CanvasLayer
## DEBUG CONSOLE. Press 1 to open, Esc or 1 to close. The game keeps running behind it.
##
##   help                       list the commands
##   list                       every entity and whether it is active
##   spawn <name|all>           bring one in (or all of them)
##   despawn <name|all>         send one away (alias: kill)
##   tp mannequin               warp to the mannequin room
##   eyes [n|off|auto|clear]    pairs of eyes far down the corridor: force n pairs, none, back to sanity-driven, or wipe them
##   sanity <0-100|off>         pin sanity (blur, eyes, health drain all follow); off releases it
##   health <0-100>             set health
##   clear                      wipe this log
##
## Names: bacteria, mannequin, mimic, peek, watcher.

const ENTITIES := {
	"bacteria": "Entity",
	"mannequin": "Mannequin",
	"mimic": "Mimic",
	"watcher": "Watcher",
}
const ORDER := ["bacteria", "mannequin", "mimic", "peek", "watcher"]

var root: Node
var panel: PanelContainer
var log_label: RichTextLabel
var input: LineEdit
var history: Array = []
var history_at := 0

func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	root = get_parent()
	_build()
	panel.visible = false

func _build() -> void:
	panel = PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	panel.custom_minimum_size = Vector2(0, 260)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.82)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)
	log_label = RichTextLabel.new()
	log_label.bbcode_enabled = true
	log_label.scroll_following = true
	log_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_label.add_theme_font_size_override("normal_font_size", 14)
	box.add_child(log_label)
	input = LineEdit.new()
	input.placeholder_text = "type a command (help)"
	input.text_submitted.connect(_submit)
	box.add_child(input)
	_print("[color=gray]debug console. type [b]help[/b].[/color]")

func _print(text: String) -> void:
	log_label.append_text(text + "\n")

func _input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed and not e.echo):
		return
	if e.physical_keycode == KEY_1:
		_toggle(not panel.visible)
		get_viewport().set_input_as_handled()
	elif panel.visible and e.physical_keycode == KEY_ESCAPE:
		_toggle(false)
		get_viewport().set_input_as_handled()
	elif panel.visible and e.physical_keycode == KEY_UP:
		_recall(-1)
		get_viewport().set_input_as_handled()
	elif panel.visible and e.physical_keycode == KEY_DOWN:
		_recall(1)
		get_viewport().set_input_as_handled()

func _toggle(on: bool) -> void:
	if on and (Game.dead or root.ui.menu.shown):
		return
	panel.visible = on
	if on:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		input.clear()
		input.grab_focus()
	else:
		input.release_focus()
		if not Game.dead and not root.ui.menu.shown:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _recall(dir: int) -> void:
	if history.is_empty():
		return
	history_at = clampi(history_at + dir, 0, history.size())
	input.text = "" if history_at >= history.size() else history[history_at]
	input.caret_column = input.text.length()

func _submit(line: String) -> void:
	input.clear()
	line = line.strip_edges()
	if line == "":
		return
	history.append(line)
	history_at = history.size()
	_print("[color=cyan]> " + line + "[/color]")
	var parts := line.to_lower().split(" ", false)
	var cmd := parts[0]
	var arg := parts[1] if parts.size() > 1 else ""
	match cmd:
		"help", "?":
			_print("spawn <name|all> [peek|stand]   despawn <name|all>   heart [0-1|off]   eyes [n|off|auto|clear]   sanity <0-100|off>   health <0-100>   list   tp mannequin   clear")
			_print("names: " + ", ".join(ORDER))
		"list":
			for n in ORDER:
				var on := _active(n)
				_print("  %-10s %s" % [n, "[color=lime]active[/color]" if on else "[color=gray]off[/color]"])
		"spawn":
			_each(arg, true, parts[2] if parts.size() > 2 else "")
		"despawn", "kill":
			_each(arg, false)
		"tp":
			if arg == "mannequin":
				root.get_node("Mannequin").warp_to_room()
				_print("warped to the mannequin room")
			else:
				_print("[color=orange]tp mannequin[/color]")
		"heart":
			var h = Game.heart
			if h == null:
				_print("[color=orange]no heart[/color]")
			else:
				if arg == "off":
					h.debug_stress = -1.0
				elif arg.is_valid_float():
					h.debug_stress = clampf(arg.to_float(), 0.0, 1.0)
				_print(h.describe())
		"eyes":
			var ey: Node = root.get_node("Eyes")
			if arg == "off":
				ey.debug_set(0)
			elif arg == "auto":
				ey.debug_auto()
			elif arg == "clear":
				ey.debug_clear()
			elif arg.is_valid_int():
				ey.debug_set(clampi(arg.to_int(), 0, ey.MAX_WATCHERS))
			_print(ey.describe())
		"sanity":
			var pl = root.get_node("Player")
			if arg == "off":
				pl.sanity_lock = -1.0
			elif arg.is_valid_float():
				pl.sanity_lock = clampf(arg.to_float(), 0.0, 100.0)
				pl.sanity = pl.sanity_lock
			_print("sanity %d%s  health %d  insanity %.2f" % [int(pl.sanity), " (pinned)" if pl.sanity_lock >= 0.0 else "", int(pl.health), pl.insanity])
		"health":
			var pl2 = root.get_node("Player")
			if arg.is_valid_float():
				pl2.health = clampf(arg.to_float(), 0.0, 100.0)
			_print("health %d" % int(pl2.health))
		"clear":
			log_label.clear()
		_:
			_print("[color=orange]unknown command: " + cmd + "[/color]")

func _each(arg: String, spawn: bool, kind := "") -> void:
	if arg == "":
		_print("[color=orange]%s what? %s, or all[/color]" % ["spawn" if spawn else "despawn", ", ".join(ORDER)])
		return
	if arg == "all":
		for n in ORDER:
			_apply(n, spawn, kind)
		return
	if arg == "entity":
		arg = "bacteria"
	if not ORDER.has(arg):
		_print("[color=orange]unknown entity: " + arg + "[/color]")
		return
	_apply(arg, spawn, kind)

func _node(name: String) -> Node:
	return root.get_node_or_null(ENTITIES[name])

func _active(name: String) -> bool:
	if name == "peek":
		return root.get_node("Mimic").pk_phase != "idle"
	var n := _node(name)
	return n != null and n.debug_active()

func _apply(name: String, spawn: bool, kind := "") -> void:
	if name == "peek":
		var m: Node = root.get_node("Mimic")
		if spawn:
			m.peek_now()
		else:
			m.peek_hide()
		_print("peek %s" % ("started" if spawn else "hidden"))
		return
	var n := _node(name)
	if n == null:
		_print("[color=orange]%s is not in the scene[/color]" % name)
		return
	if spawn:
		var ok = n.debug_spawn(kind) if name == "watcher" else n.debug_spawn()
		if ok == false:
			_print("[color=orange]%s: no room to spawn here, try another spot[/color]" % name)
			return
	else:
		n.debug_despawn()
	_print("%s %s" % [name, "spawned" if spawn else "despawned"])
