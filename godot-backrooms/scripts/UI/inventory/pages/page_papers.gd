extends "res://scripts/UI/inventory/terminal_page.gd"
## FILES: recovered lore, in the order it was found (inventory.gd lore_entries, filled by add_lore()).
## Each paper is a numbered section rule over its text.

const CAP := 10                      # papers kept; add_lore() turns away any past this

var body: VBoxContainer

func build() -> Control:
	body = _column(6)
	return root

func refresh() -> void:
	if not body:
		return
	clear(body)
	var lore: Array = term.lore_entries
	heading(body, "RECOVERED FILES", "%d OF %d" % [lore.size(), CAP])
	if lore.is_empty():
		empty_state(body, "NO FILES ON RECORD.", "Papers and notes recovered in the field are transcribed here.")
		return
	for i in lore.size():
		var e: Dictionary = lore[i]
		section(body, "FILE %02d" % (i + 1))
		body.add_child(label(str(e.title).to_upper(), 19, AMBER, 2, true))
		if str(e.text) != "":
			para(body, str(e.text), TEXT, 17)
