extends "res://scripts/UI/inventory/terminal_kit.gd"
## One page of the TAB terminal's right-hand sheet (inventory.gd): [F1] ITEMS, [F2] DOSSIER,
## [F3] ENTRIES, [F4] PAPERS, [F5] CLEARANCE, one script each in scripts/UI/inventory/pages/.
## inventory.gd builds every page into the sheet (build()), shows the active one, types it in and
## calls refresh() when what it shows has changed. `scroll` is the page's ScrollContainer for
## PgUp / PgDn and the scroll rail; hoverables() are the rows that take a click (hand cursor).

var term: Control                    # inventory.gd: selection, tabs, sounds, the sheet's outline
var root: Control                    # what build() returned, shown while this page is active
var scroll_box: ScrollContainer      # scrolled by PgUp / PgDn and the rail

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

## The CLASSIFIED ANNEX of a dossier or an entry: its sections in full once the player's clearance
## unlocks "classified" (asra_clearance.gd), until then each title over redaction bars and the tier
## that releases them. sections: [[title, text or Array of paragraphs]]; an Array under a title with
## "PROTOCOL" / "GUIDANCE" in it is numbered. Empty sections are left out.
func annex(into: VBoxContainer, key: String, sections: Array, px: int) -> void:
	var open := Clearance.has_unlock("classified")
	var code := Clearance.unlock_code("classified")
	into.add_child(spacer(18))
	into.add_child(hline(Color(AMBER if open else RED, 0.5), 2))
	into.add_child(spacer(10))
	if open:
		into.add_child(label("CLASSIFIED ANNEX // RELEASED AT %s" % code, 17, AMBER, 2, true))
	else:
		into.add_child(label("CLASSIFIED ANNEX // %s CLEARANCE REQUIRED" % code, 17, RED, 2, true))
	for sec in sections:
		var body = sec[1]
		if (body is String and body == "") or (body is Array and body.is_empty()):
			continue
		into.add_child(spacer(10))
		into.add_child(label(str(sec[0]), 15, MUTED, 2))
		if not open:
			var rows: int = body.size() if body is Array else 2
			for r in clampi(rows, 1, 4):
				into.add_child(redacted(key + str(sec[0]) + str(r), 2 + (r + str(sec[0]).length()) % 3))
			continue
		if body is Array:
			var numbered: bool = "PROTOCOL" in str(sec[0]) or "GUIDANCE" in str(sec[0])
			for i in body.size():
				into.add_child(label(("%d. %s" % [i + 1, str(body[i])]) if numbered else str(body[i]), px, TEXT, 1, true))
		else:
			into.add_child(label(str(body), px, TEXT, 1, true))
	if not open:
		into.add_child(spacer(10))
		into.add_child(label("YOUR CLEARANCE: %s. FILE READINGS WITH THE FIELD SCANNER TO RAISE IT." % Clearance.tier_label(), 15, AMBER, 1, true))
