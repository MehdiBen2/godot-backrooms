extends ConfirmationDialog
## The level editor's event trigger dialog (double click a trigger, or Configure in the inspector): everything
## about one trigger (the game's scripts/World/props/event_trigger.gd), in sections: its events, caption, when
## it fires, how it repeats, the conditions it waits for, its box, and the chain to other triggers. A sentence at
## the bottom says what it will do, and warnings flag settings that can't work. The choices, their help and the
## number ranges are the trigger's entry in levels/object_types.json, so the game and the editor agree.

signal applied(values: Dictionary)

const GOLD := Color("e6c65a")
const CREAM := Color("e6e1cd")
const DIM := Color("8b8f98")
const RED := Color("c4271f")
const WARN := Color("e8a33d")
const WIDTH := 600.0
const CAPTION_EVENTS := ["message", "text", "alert"]
## The event picker's groups, in order (_group_of sorts the events into them)
const GROUPS := ["Caption", "Here, for this player", "Director events", "Monsters", "Deadly", "Other"]
const INT_KEYS := ["nth", "max_fires"]
const CONDITION_LABELS := {"speed": "Crossing", "direction": "Direction", "torch": "Torch", "lighting": "Light"}

var info: Dictionary                # the trigger's object_types.json entry
var events: Dictionary              # event key -> its help
var rows: Array = []                # one per event: {root, num, pick, at, hint, custom, up, down, del}
var ctl := {}                       # param -> its control
var known_tags: Array = []          # the other triggers' tags on this floor (for the chain)
var rows_box: VBoxContainer
var summary: Label
var warnings: Label
var _filling := false               # open() is setting the controls: their signals are not edits

func _init(trigger_info: Dictionary) -> void:
	info = trigger_info
	events = info.get("events", {})
	title = "Event trigger"
	ok_button_text = "Apply"
	confirmed.connect(func(): applied.emit(_values()))
	_build()

## Show the dialog filled in from `vals` (every trigger param, plus "scale"); `tags` for the chain picker
func open(vals: Dictionary, tags: Array) -> void:
	_filling = true
	known_tags = tags
	for r in rows:
		rows_box.remove_child(r.root)
		r.root.queue_free()
	rows.clear()
	var list = vals.get("events_list", [])
	if list is Array and not list.is_empty():
		for e in list:
			_add_row(e if e is Dictionary else {"event": str(e)})
	else:
		_add_row({"event": vals.get("event", "message"), "custom_event": vals.get("custom_event", "")})
	for k in ctl:
		var c = ctl[k]
		var v = vals.get(k)
		if v == null:
			continue
		if k == "once":
			c.select(0 if bool(v) else 1)
		elif c is SpinBox:
			c.set_value_no_signal(float(v))
		elif c is LineEdit:
			c.text = str(v)
		elif c is OptionButton:
			_select_meta(c, str(v))
	_filling = false
	_refresh()
	popup_centered(Vector2i(int(WIDTH) + 60, 700))

# ---------------------------------------------------------------- layout
func _build() -> void:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(WIDTH + 20, 600)
	add_child(scroll)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 8)
	scroll.add_child(v)

	v.add_child(_heading("Events"))
	rows_box = VBoxContainer.new()
	rows_box.add_theme_constant_override("separation", 10)
	v.add_child(rows_box)
	var bar := HBoxContainer.new()
	bar.add_child(_btn("+ Add event", "Another event when it fires", func():
		_add_row({"event": "flicker"})
		_refresh()))
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(gap)
	bar.add_child(_label("Run", 13, DIM))
	var mode := _choice("event_mode")
	mode.custom_minimum_size = Vector2(340, 0)
	mode.size_flags_horizontal = Control.SIZE_FILL
	bar.add_child(mode)
	v.add_child(bar)

	v.add_child(_heading("Caption"))
	var g := _grid(v)
	var tx := LineEdit.new()
	tx.placeholder_text = "text on screen when it fires (optional)"
	tx.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tx.text_changed.connect(func(_t): _refresh())
	ctl["text"] = tx
	_row(g, "Text", tx)
	_row(g, "Style", _choice("text_style"))

	v.add_child(_heading("When"))
	g = _grid(v)
	_row(g, "Fires", _choice("fire_on"))
	_row(g, "Dwell", _spin("dwell"))
	_row(g, "From visit #", _spin("nth"))
	_row(g, "Delay", _spin("delay", [0.0, 60.0, 0.1, " s", "seconds from the moment it fires to its events"]))

	v.add_child(_heading("Repeat"))
	g = _grid(v)
	var rep := OptionButton.new()
	rep.add_item("Once: never again this run (kept across floor changes)")
	rep.add_item("Every time it is set off")
	rep.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rep.item_selected.connect(func(_i): _refresh())
	ctl["once"] = rep
	_row(g, "Fires", rep)
	_row(g, "Cooldown", _spin("cooldown"))
	_row(g, "At most", _spin("max_fires"))

	v.add_child(_heading("Conditions (all must pass)"))
	g = _grid(v)
	for k in CONDITION_LABELS:
		_row(g, CONDITION_LABELS[k], _choice(k))
	_row(g, "Sanity under", _spin("sanity_below"))
	_row(g, "Chance", _spin("chance"))

	v.add_child(_heading("Box and timing"))
	g = _grid(v)
	_row(g, "Width", _spin("scale", [0.5, 40.0, 0.5, " cells", "across the arrow"]))
	_row(g, "Depth", _spin("depth", [0.5, 40.0, 0.5, " cells", "along the arrow"]))
	_row(g, "Duration", _spin("duration", [1.0, 120.0, 1.0, " s",
		"how long lights_out, silence, drone, reverse_ambience (max 12 s) last; context_voice: seconds between lines"]))

	v.add_child(_heading("Chain"))
	g = _grid(v)
	var tag := LineEdit.new()
	tag.placeholder_text = "a name other triggers can set this one off by"
	tag.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tag.text_changed.connect(func(_t): _refresh())
	ctl["tag"] = tag
	_row(g, "Tag", tag)
	var ch_box := HBoxContainer.new()
	ch_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var ch := LineEdit.new()
	ch.placeholder_text = "tag of the trigger(s) to set off after its events"
	ch.tooltip_text = "Every trigger with this tag goes as if walked into (its box and conditions aside; its own Delay, Once and Cooldown still hold)"
	ch.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ch.text_changed.connect(func(_t): _refresh())
	ctl["chain"] = ch
	ch_box.add_child(ch)
	var pick := MenuButton.new()
	pick.text = "Pick"
	pick.flat = false
	pick.tooltip_text = "The tags of this floor's other triggers"
	pick.about_to_popup.connect(func():
		var pm := pick.get_popup()
		pm.clear()
		for t in known_tags:
			pm.add_item(str(t))
		if known_tags.is_empty():
			pm.add_item("(no other trigger on this floor has a tag)")
			pm.set_item_disabled(0, true))
	pick.get_popup().index_pressed.connect(func(i):
		ch.text = pick.get_popup().get_item_text(i)
		_refresh())
	ch_box.add_child(pick)
	_row(g, "Then sets off", ch_box)

	v.add_child(HSeparator.new())
	summary = _wrap(_label("", 14, CREAM))
	v.add_child(summary)
	warnings = _wrap(_label("", 13, WARN))
	v.add_child(warnings)
	register_text_enter(tx)             # Enter in the caption box = Apply

# ---------------------------------------------------------------- event rows
func _add_row(entry: Dictionary, at_index := -1) -> void:
	var ev := str(entry.get("event", "flicker"))
	var custom_name := str(entry.get("custom_event", ""))
	if not events.has(ev):              # a name typed straight into the .lvl: it's a custom one
		custom_name = ev if custom_name == "" else custom_name
		ev = "custom"
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 3)
	var top := HBoxContainer.new()
	root.add_child(top)
	var num := _label("1", 13, GOLD)
	num.custom_minimum_size = Vector2(22, 0)
	top.add_child(num)
	var pick := _event_picker(ev)
	top.add_child(pick)
	top.add_child(_label("at +", 12, DIM))
	var at := SpinBox.new()
	at.min_value = 0.0
	at.max_value = 120.0
	at.step = 0.1
	at.suffix = " s"
	at.custom_minimum_size = Vector2(96, 0)
	at.value = float(entry.get("at", 0.0))
	at.tooltip_text = "seconds after the trigger's Delay that this event runs"
	top.add_child(at)
	var row := {"root": root, "num": num, "pick": pick, "at": at}
	row["up"] = _btn("Up", "Move up", func(): _move_row(row, -1))
	row["down"] = _btn("Dn", "Move down", func(): _move_row(row, 1))
	row["dup"] = _btn("Copy", "Duplicate this event", func():
		_add_row(_row_entry(row), rows.find(row) + 1)
		_refresh())
	row["del"] = _btn("X", "Remove this event", func(): _remove_row(row))
	row.del.add_theme_color_override("font_color", RED)
	for b in ["up", "down", "dup", "del"]:
		top.add_child(row[b])
	var hint := _wrap(_label("", 12, DIM))
	root.add_child(hint)
	var custom := LineEdit.new()
	custom.placeholder_text = "event name (a director event, e.g. wallKnock)"
	custom.text = custom_name
	custom.text_changed.connect(func(_t): _refresh())
	root.add_child(custom)
	row["hint"] = hint
	row["custom"] = custom
	pick.item_selected.connect(func(_i): _refresh())
	at.value_changed.connect(func(_v): _refresh())
	rows_box.add_child(root)
	if at_index >= 0 and at_index < rows.size():
		rows.insert(at_index, row)
		rows_box.move_child(root, at_index)
	else:
		rows.append(row)

func _move_row(row: Dictionary, d: int) -> void:
	var i := rows.find(row)
	var j := clampi(i + d, 0, rows.size() - 1)
	if i < 0 or i == j:
		return
	rows.remove_at(i)
	rows.insert(j, row)
	rows_box.move_child(row.root, j)
	_refresh()

func _remove_row(row: Dictionary) -> void:
	if rows.size() <= 1:
		return
	rows.erase(row)
	rows_box.remove_child(row.root)
	row.root.queue_free()
	_refresh()

func _row_entry(row: Dictionary) -> Dictionary:
	return {"event": _meta(row.pick), "custom_event": (row.custom as LineEdit).text.strip_edges(), "at": (row.at as SpinBox).value}

## What the summary calls a row's event: a custom one by its name
func _row_name(row: Dictionary) -> String:
	var k := _meta(row.pick)
	if k != "custom":
		return k
	var n := (row.custom as LineEdit).text.strip_edges()
	return n if n != "" else "(unnamed custom)"

func _group_of(k: String) -> int:
	if k in CAPTION_EVENTS: return 0
	if k == "custom": return 5
	if k.begins_with("spawn_"): return 3
	if k.contains("death") or k == "pain_area": return 4
	if str(events[k]).begins_with("Director event"): return 2
	return 1

func _event_picker(sel: String) -> OptionButton:
	var b := OptionButton.new()
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for gi in GROUPS.size():
		var first := true
		for k in events:
			if _group_of(k) != gi:
				continue
			if first:
				b.add_separator(GROUPS[gi])
				first = false
			b.add_item(k)
			b.set_item_metadata(b.item_count - 1, k)
			b.set_item_tooltip(b.item_count - 1, str(events[k]))
	_select_meta(b, sel)
	return b

# ---------------------------------------------------------------- state
func _values() -> Dictionary:
	var list: Array = []
	for r in rows:
		list.append(_row_entry(r))
	var out := {"events_list": list, "event": list[0].event, "custom_event": list[0].custom_event}
	for k in ctl:
		var c = ctl[k]
		if k == "once":
			out[k] = c.selected == 0
		elif c is SpinBox:
			out[k] = int(c.value) if k in INT_KEYS else c.value
		elif c is LineEdit:
			out[k] = c.text if k == "text" else c.text.strip_edges()
		elif c is OptionButton:
			out[k] = _meta(c)
	return out

## Number the rows, show what applies, and say what it will do
func _refresh() -> void:
	if _filling or summary == null:
		return
	for i in rows.size():
		var r: Dictionary = rows[i]
		var k := _meta(r.pick)
		r.num.text = "%d" % (i + 1)
		r.hint.text = str(events.get(k, ""))
		r.custom.visible = k == "custom"
		r.up.disabled = i == 0
		r.down.disabled = i == rows.size() - 1
		r.del.disabled = rows.size() <= 1
	var dwell := _meta(ctl.fire_on) == "dwell"
	var every: bool = ctl.once.selected == 1
	ctl.dwell.editable = dwell
	ctl.speed.disabled = dwell
	ctl.direction.disabled = dwell
	ctl.cooldown.editable = every
	ctl.max_fires.editable = every
	summary.text = _sentence()
	var w := _warnings()
	warnings.text = "\n".join(w)
	warnings.visible = not w.is_empty()

func _sentence() -> String:
	var dwell := _meta(ctl.fire_on) == "dwell"
	var s := ""
	match _meta(ctl.fire_on):
		"exit": s = "When the player walks out of the box"
		"dwell": s = "When the player has stood still in the box for %s s" % _num(ctl.dwell.value)
		_: s = "When the player walks into the box"
	var gates: Array = []
	if not dwell:
		match _meta(ctl.speed):
			"run": gates.append("sprinting")
			"walk": gates.append("walking")
			"creep": gates.append("crouched")
		match _meta(ctl.direction):
			"along": gates.append("along the arrow")
			"against": gates.append("against the arrow")
	if ctl.nth.value > 1:
		gates.append("from the %s visit on" % _ordinal(int(ctl.nth.value)))
	match _meta(ctl.torch):
		"on": gates.append("torch on")
		"off": gates.append("torch off")
	match _meta(ctl.lighting):
		"lit": gates.append("in the light")
		"dark": gates.append("in the dark")
	if ctl.sanity_below.value < 100.0:
		gates.append("sanity under %d" % int(ctl.sanity_below.value))
	if ctl.chance.value < 100.0:
		gates.append("%d%% of the time" % int(ctl.chance.value))
	if not gates.is_empty():
		s += " (" + ", ".join(gates) + ")"
	s += ": "
	if ctl.delay.value > 0.0:
		s += "after %s s, " % _num(ctl.delay.value)
	var timed: Array = []
	for r in rows:
		var a: float = r.at.value
		timed.append(_row_name(r) if a <= 0.0 else "%s at +%s s" % [_row_name(r), _num(a)])
	match _meta(ctl.event_mode):
		"random": s += "one of " + ", ".join(timed) + " at random"
		"cycle": s += "the next of " + ", ".join(timed) + " in turn"
		_: s += ", ".join(timed)
	var tx: String = ctl.text.text.strip_edges()
	if tx != "":
		var alert: bool = _meta(ctl.text_style) == "alert" or (_meta(ctl.text_style) == "auto" and _has_event("alert"))
		s += ", and shows \"%s\" as %s" % [tx, "an alert" if alert else "a camcorder caption"]
	if ctl.once.selected == 0:
		s += ". Once only"
	else:
		s += ". Again each time, at most every %s s" % _num(maxf(ctl.cooldown.value, ctl.delay.value))
		if ctl.max_fires.value > 0:
			s += ", %d times in all" % int(ctl.max_fires.value)
	var ch: String = ctl.chain.text.strip_edges()
	if ch != "":
		s += ". Then sets off every trigger tagged \"%s\"" % ch
	return s + "."

func _warnings() -> Array:
	var w: Array = []
	for i in rows.size():
		if _meta(rows[i].pick) == "custom" and (rows[i].custom as LineEdit).text.strip_edges() == "":
			w.append("Event %d is Custom but has no name: nothing will run." % (i + 1))
	var dwell := _meta(ctl.fire_on) == "dwell"
	if dwell and (_meta(ctl.speed) != "any" or _meta(ctl.direction) != "any"):
		w.append("Crossing and Direction are ignored while it fires on Dwell.")
	if _meta(ctl.event_mode) != "all" and rows.size() < 2:
		w.append("Only one event: Random and In turn make no difference.")
	if _meta(ctl.event_mode) != "all" and _has_event("context_voice"):
		w.append("context_voice always listens while the player is in the box; Random / In turn never pick it.")
	if ctl.text.text.strip_edges() == "" and _has_any(CAPTION_EVENTS) and _only(CAPTION_EVENTS):
		w.append("Its only events are captions, but Text is empty: nothing will show.")
	if ctl.once.selected == 1 and ctl.cooldown.value < ctl.delay.value:
		w.append("Cooldown is shorter than the Delay: it waits the Delay (%s s) between fires." % _num(ctl.delay.value))
	var tag: String = ctl.tag.text.strip_edges()
	var ch: String = ctl.chain.text.strip_edges()
	if ch != "" and ch == tag:
		w.append("Then sets off its own tag: a trigger can't set itself off.")
	elif ch != "" and not known_tags.has(ch):
		w.append("No other trigger on this floor has the tag \"%s\" (yet)." % ch)
	if tag != "" and known_tags.has(tag):
		w.append("Another trigger here is tagged \"%s\" too: a chain to it sets off both." % tag)
	return w

func _has_event(k: String) -> bool:
	return rows.any(func(r): return _meta(r.pick) == k)

func _has_any(keys: Array) -> bool:
	return rows.any(func(r): return keys.has(_meta(r.pick)))

func _only(keys: Array) -> bool:
	return rows.all(func(r): return keys.has(_meta(r.pick)))

# ---------------------------------------------------------------- helpers
func _choice(key: String) -> OptionButton:
	var b := OptionButton.new()
	var opts: Dictionary = info.get("choices", {}).get(key, {})
	for k in opts:
		b.add_item(str(opts[k]))         # (the help reads better than the key)
		b.set_item_metadata(b.item_count - 1, k)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.item_selected.connect(func(_i): _refresh())
	ctl[key] = b
	return b

## A number box with its object_types.json "ranges" [min, max, step, suffix, help], or `r`
func _spin(key: String, r: Array = []) -> SpinBox:
	if r.is_empty():
		r = info.get("ranges", {}).get(key, [0.0, 100.0, 1.0, "", ""])
	var s := SpinBox.new()
	s.min_value = float(r[0])
	s.max_value = float(r[1])
	s.step = float(r[2])
	s.suffix = str(r[3])
	s.tooltip_text = str(r[4])
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.value_changed.connect(func(_v): _refresh())
	ctl[key] = s
	return s

func _select_meta(b: OptionButton, value: String) -> void:
	for i in b.item_count:
		if str(b.get_item_metadata(i)) == value and not b.is_item_separator(i):
			b.select(i)
			return
	for i in b.item_count:                  # not one of its choices: the first that is
		if not b.is_item_separator(i):
			b.select(i)
			return

func _meta(b: OptionButton) -> String:
	return str(b.get_item_metadata(b.selected)) if b.selected >= 0 else ""

func _grid(parent: Control) -> GridContainer:
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 12)
	g.add_theme_constant_override("v_separation", 6)
	parent.add_child(g)
	return g

func _row(g: GridContainer, title_text: String, c: Control) -> void:
	var l := _label(title_text, 13, DIM)
	l.custom_minimum_size = Vector2(110, 0)
	l.tooltip_text = c.tooltip_text
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	g.add_child(l)
	g.add_child(c)

func _label(text: String, size := 14, color := CREAM) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

func _wrap(l: Label) -> Label:
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(WIDTH, 0)
	return l

func _heading(text: String) -> Label:
	return _label(text.to_upper(), 13, GOLD)

func _btn(text: String, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.text = text
	b.tooltip_text = tip
	b.pressed.connect(cb)
	return b

func _num(f: float) -> String:
	return String.num(f, 1).trim_suffix(".0")

func _ordinal(n: int) -> String:
	var suffix := "th"
	if n % 100 < 11 or n % 100 > 13:
		match n % 10:
			1: suffix = "st"
			2: suffix = "nd"
			3: suffix = "rd"
	return "%d%s" % [n, suffix]
