extends "res://scripts/UI/inventory/terminal_kit.gd"
## One page of the TAB terminal's right-hand sheet (inventory.gd): ITEMS, SITE, ARCHIVE, FILES, RECORD,
## CREW, one script each in scripts/UI/inventory/pages/.
## inventory.gd builds every page into the sheet (build()), shows the active one, types it in and
## calls refresh() when what it shows has changed. `scroll` is the page's ScrollContainer for
## PgUp / PgDn and the scroll track; hoverables() are the rows that take a click (hand cursor).
## The page vocabulary, all text and lines: heading() over a page, section() rules, leader() lines,
## para() blocks of text, tag() statuses, and the classified annex().

var term: Control                    # inventory.gd: selection, tabs, sounds, the sheet's outline
var root: Control                    # what build() returned, shown while this page is active
var scroll_box: ScrollContainer      # scrolled by PgUp / PgDn and the scroll track
var annex_clicks: Array = []         # the annex's [CLICK TO DECLASSIFY] bars (hand cursor, inventory.gd)

func _init(terminal: Control) -> void:
	term = terminal

## The page's controls, added to the sheet once
func build() -> Control:
	return null

## Rebuild what the page shows from the current state
func refresh() -> void:
	pass

func hoverables() -> Array:
	return []

## A single scrolling column, the usual page
func _column(gap: int) -> VBoxContainer:
	scroll_box = scroll()
	root = scroll_box
	return scroll_body(scroll_box, gap)

## The page's title line: the title in amber, a figure at the far end, a heavy rule under both
func heading(into: VBoxContainer, title: String, right := "") -> void:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 16)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var t := label(title, 20, AMBER, 3, true)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(t)
	if right != "":
		var r := label(right, 16, MUTED, 2)
		r.size_flags_vertical = Control.SIZE_SHRINK_END
		h.add_child(r)
	into.add_child(h)
	into.add_child(spacer(2))
	into.add_child(hline(Color(AMBER, 0.6), 2))
	into.add_child(spacer(8))

## A section: room above it, then "-- TITLE ------------- RIGHT --"
func section(into: VBoxContainer, title: String, right := "", col := AMBER) -> void:
	into.add_child(spacer(18))
	into.add_child(rule(title, right, col))
	into.add_child(spacer(6))

## A block of wrapped text, indented `indent` px under whatever introduced it
func para(into: VBoxContainer, text: String, col := TEXT, px := 17, indent := 0.0) -> Label:
	var l := label(text, px, col, 1, true)
	if indent <= 0.0:
		into.add_child(l)
		return l
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", int(indent))
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_child(l)
	into.add_child(m)
	return l

## Numbered lines with a hanging indent: "01  first ..." / "    ...wrapped"
func numbered(into: VBoxContainer, lines: Array, px := 17) -> void:
	for i in lines.size():
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 14)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var n := label("%02d" % (i + 1), px - 1, MUTED, 2)
		n.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		h.add_child(n)
		h.add_child(label(str(lines[i]), px, TEXT, 1, true))
		into.add_child(h)

## A page with nothing on it yet: a prompt line, and what to do about it
func empty_state(into: VBoxContainer, what: String, hint: String) -> void:
	into.add_child(spacer(6))
	into.add_child(label("> " + what, 19, AMBER, 2))
	if hint != "":
		into.add_child(spacer(4))
		para(into, hint, TEXT_DIM, 16, 26.0)

## The CLASSIFIED ANNEX of a dossier or an entry: a red rule until the player's clearance unlocks
## "classified" (tsra_clearance.gd), then its sections, each sealed() with "rank" set. Sections with
## nothing in them are left out.
func annex(into: VBoxContainer, key: String, specs: Array, scans: int) -> void:
	var open := Clearance.has_unlock("classified")
	var code := Clearance.unlock_code("classified")
	section(into, "CLASSIFIED ANNEX", "RELEASED AT %s" % code if open else "LOCKED // %s" % code, AMBER if open else RED)
	for spec in specs:
		spec["rank"] = true
		sealed(into, key, spec, scans, false)

## A section of a file that opens piece by piece. spec: {title, body (text or Array of paragraphs),
## scans (readings of the entity it takes, Clearance.readings), rank (needs "classified"), col, px}.
## Until opened it is redacted bars: LOCKED with what it still takes, or, once that is met, a pulsing
## CLICK TO DECLASSIFY that swaps itself for the text and is remembered (Clearance.declassify).
## `ruled`: under a full section() rule, else a small title (the annex's sections).
func sealed(into: VBoxContainer, key: String, spec: Dictionary, scans: int, ruled := true) -> void:
	var body = spec.get("body", "")
	if (body is String and body == "") or (body is Array and body.is_empty()):
		return
	var title := str(spec.title)
	var state := seal_state(key, spec, scans)
	if ruled:
		section(into, title, "" if state == "open" else "REDACTED")
	else:
		into.add_child(spacer(8))
		into.add_child(label(title, 15, MUTED, 3))
	match state:
		"open":
			_seal_body(into, spec)
		"ready":
			into.add_child(_declassify_bar(into, key, spec))
		_:
			into.add_child(_locked_bar(key + "/" + title, _seal_needs(spec, scans)))

## "open" (declassified), "ready" (can be clicked open) or "locked"
func seal_state(key: String, spec: Dictionary, scans: int) -> String:
	if Clearance.is_declassified("%s/%s" % [key, spec.title]):
		return "open"
	return "locked" if _seal_needs(spec, scans) != "" else "ready"

## What a sealed section still takes: "RANK 3 + SCAN 1/3", or "" when nothing
func _seal_needs(spec: Dictionary, scans: int) -> String:
	var why := PackedStringArray()
	if spec.get("rank", false) and not Clearance.has_unlock("classified"):
		why.append(Clearance.unlock_code("classified"))
	var need := int(spec.get("scans", 0))
	if scans < need:
		why.append("SCAN %d/%d" % [scans, need])
	return " + ".join(why)

## Called once a section has been clicked open (page_entries.gd updates its count and badge)
func declassified(_key: String) -> void:
	pass

func _seal_body(into: VBoxContainer, spec: Dictionary) -> void:
	var body = spec.body
	var col: Color = spec.get("col", TEXT)
	var px := int(spec.get("px", 17))
	if body is Array:
		if "PROTOCOL" in str(spec.title) or "GUIDANCE" in str(spec.title):
			numbered(into, body, px)
		else:
			for line in body:
				para(into, str(line), col, px)
	else:
		para(into, str(body), col, px)

## Three lines of blacked-out text filling the column (the bars stretch, so nothing overflows), the
## last one short with `end` at its far end
func _redaction(id: String, bar: Color, end: Control) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 7)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var rng := RandomNumberGenerator.new()
	rng.seed = id.hash()
	for line in 3:
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 8)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		for i in (rng.randi_range(2, 3) if line < 2 else 1):
			var r := ColorRect.new()
			r.color = bar
			r.custom_minimum_size = Vector2(24, 13)
			r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			r.size_flags_stretch_ratio = rng.randf_range(0.5, 1.6)
			r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			r.mouse_filter = Control.MOUSE_FILTER_IGNORE
			h.add_child(r)
		if line == 2:
			h.add_child(end)
		v.add_child(h)
	return v

## Still out of reach: dim bars and what it takes
func _locked_bar(id: String, needs: String) -> Control:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 10)
	m.add_theme_constant_override("margin_right", 10)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	m.add_child(_redaction(id, Color(TEXT, 0.12), tag("LOCKED // " + needs, Color(RED, 0.85))))
	return m

## Within reach: a pulsing bar that takes a click and types the text in where it was
func _declassify_bar(into: VBoxContainer, key: String, spec: Dictionary) -> Control:
	var id := "%s/%s" % [key, spec.title]
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.add_theme_stylebox_override("panel", row_box(false))
	var v := _redaction(id, Color(AMBER, 0.32), tag("CLICK TO DECLASSIFY", AMBER))
	p.add_child(v)
	var tw := p.create_tween().set_loops()
	tw.tween_property(v, "modulate:a", 0.5, 0.55).set_trans(Tween.TRANS_SINE)
	tw.tween_property(v, "modulate:a", 1.0, 0.55).set_trans(Tween.TRANS_SINE)
	p.mouse_entered.connect(func(): p.add_theme_stylebox_override("panel", row_box(true, true)))
	p.mouse_exited.connect(func(): p.add_theme_stylebox_override("panel", row_box(false)))
	p.gui_input.connect(func(e: InputEvent):
		if not (e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT):
			return
		Clearance.declassify(id)
		term.play_sfx("select")
		var at := p.get_index()
		var tmp := VBoxContainer.new()
		_seal_body(tmp, spec)
		p.queue_free()
		for c in tmp.get_children():
			tmp.remove_child(c)
			into.add_child(c)
			into.move_child(c, at)
			at += 1
			_type_in(c)
		tmp.free()
		declassified(key)
	)
	annex_clicks = annex_clicks.filter(func(c): return is_instance_valid(c))
	annex_clicks.append(p)
	return p

## Every label under `n` types itself in, as the page does when it opens
func _type_in(n: Node) -> void:
	if n is Label:
		(n as Label).visible_ratio = 0.0
		n.create_tween().tween_property(n, "visible_ratio", 1.0, 0.25 + 0.006 * (n as Label).text.length())
	for c in n.get_children():
		_type_in(c)
