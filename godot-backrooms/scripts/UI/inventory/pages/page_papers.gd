extends "res://scripts/UI/inventory/terminal_page.gd"
## [F4] PAPERS: recovered lore, in the order it was found (inventory.gd lore_entries, filled by
## add_lore()).

const CAP := 10                      # papers kept; add_lore() turns away any past this

var body: VBoxContainer

func build() -> Control:
	body = _column(8)
	return root

func refresh() -> void:
	if not body:
		return
	clear(body)
	var lore: Array = term.lore_entries
	body.add_child(label("[RECOVERED PAPERS // %d OF %d]" % [lore.size(), CAP], 21, TEXT, 1))
	body.add_child(spacer(12))
	if lore.is_empty():
		body.add_child(label("NO PAPERS RECOVERED.", 21, TEXT_DIM, 1))
		return
	for i in lore.size():
		var e: Dictionary = lore[i]
		body.add_child(label("%02d. %s" % [i + 1, str(e.title).to_upper()], 21, AMBER, 1, true))
		if str(e.text) != "":
			body.add_child(label(str(e.text), 19, TEXT_DIM, 1, true))
		body.add_child(spacer(10))
