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

## The CLASSIFIED ANNEX of a dossier or an entry: its sections in full once the player's clearance
## unlocks "classified" (tsra_clearance.gd); until then a red rule and one line saying what clearance
## releases it. sections: [[title, text or Array of paragraphs]]; an Array under a title with
## "PROTOCOL" / "GUIDANCE" in it is numbered. Empty sections are left out.
func annex(into: VBoxContainer, _key: String, sections: Array, px: int) -> void:
	var open := Clearance.has_unlock("classified")
	var code := Clearance.unlock_code("classified")
	if not open:
		section(into, "CLASSIFIED ANNEX", "", RED)
		into.add_child(leader("ACCESS", "[DENIED // %s CLEARANCE]" % code, RED, 16))
		return
	section(into, "CLASSIFIED ANNEX", "RELEASED AT %s" % code)
	for sec in sections:
		var body = sec[1]
		if (body is String and body == "") or (body is Array and body.is_empty()):
			continue
		into.add_child(spacer(8))
		into.add_child(label(str(sec[0]), 15, MUTED, 3))
		if body is Array:
			if "PROTOCOL" in str(sec[0]) or "GUIDANCE" in str(sec[0]):
				numbered(into, body, px)
			else:
				for line in body:
					para(into, str(line), TEXT, px)
		else:
			para(into, str(body), TEXT, px)
