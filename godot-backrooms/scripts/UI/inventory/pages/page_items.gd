extends "res://scripts/UI/inventory/terminal_page.gd"
## ITEMS: the record of the item selected in the pack (inventory.gd items / selected): its wireframe in
## a square frame beside its designation, code and quantity, then its description.

const ItemIcon := preload("res://scripts/UI/inventory/item_icon.gd")
const PAGE_ICON := 180.0         # the item's wireframe, drawn from its model

var body: VBoxContainer

func build() -> Control:
	body = _column(6)
	return root

func refresh() -> void:
	if not body:
		return
	clear(body)
	var items: Array = term.items
	var selected: int = term.selected
	if selected < 0 or selected >= items.size():
		heading(body, "ITEM RECORD", "NO SELECTION")
		empty_state(body, "NO ITEMS CARRIED.", "Pick up supplies in the field, or requisition them at the spawn terminal.")
		return
	var it: Dictionary = items[selected]
	heading(body, "ITEM RECORD", "SLOT %02d / %02d" % [selected + 1, term.SLOT_COUNT])
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 26)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if it.icon != "":
		var fr := frame("")
		fr.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		fr.add_child(ItemIcon.outlined(it.icon, PAGE_ICON, ORANGE, 4.0))
		top.add_child(fr)
	var facts := VBoxContainer.new()
	facts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	facts.add_theme_constant_override("separation", 10)
	facts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	facts.add_child(spacer(14))
	facts.add_child(leader("DESIGNATION", str(it.name).to_upper(), AMBER, 18))
	facts.add_child(leader("CODE", str(it.code), TEXT, 18))
	facts.add_child(leader("QUANTITY", "%d / %d" % [it.count, it.stack], TEXT, 18))
	if int(it.stack) > 1:
		var n := mini(int(it.stack), term.STACK_CELLS)
		var gauge := cells(n, 4.0, false)
		gauge.custom_minimum_size = Vector2(0, 12)
		gauge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		set_cells(gauge, mini(int(it.count), n), AMBER)
		facts.add_child(gauge)
	top.add_child(facts)
	body.add_child(top)
	if str(it.desc) != "":
		section(body, "DESCRIPTION")
		para(body, str(it.desc), TEXT, 18)
