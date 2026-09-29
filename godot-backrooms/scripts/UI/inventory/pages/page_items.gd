extends "res://scripts/UI/inventory/terminal_page.gd"
## [F1] ITEMS: the record of the item selected in the terminal's inventory list (inventory.gd
## items / selected): its icon, designation, code, quantity and description.

const ItemIcon := preload("res://scripts/UI/inventory/item_icon.gd")
const PAGE_ICON := 190.0         # the item's icon, larger than on its inventory row

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
		body.add_child(label("[ITEM RECORD // NO SELECTION]", 21, TEXT, 1))
		body.add_child(spacer(12))
		body.add_child(label("NO ITEMS CARRIED.", 21, TEXT_DIM, 1, true))
		return
	var it: Dictionary = items[selected]
	body.add_child(label("[ITEM RECORD // SLOT %02d OF %02d]" % [selected + 1, term.SLOT_COUNT], 21, TEXT, 1))
	body.add_child(spacer(12))
	if it.icon != "":
		var frame := PanelContainer.new()       # the icon in a bordered square, like the vitals'
		var sb := box(Color(AMBER, 0.05), AMBER_DIM, 2)
		sb.set_content_margin_all(10)
		frame.add_theme_stylebox_override("panel", sb)
		frame.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
		frame.add_child(ItemIcon.outlined(it.icon, PAGE_ICON, ORANGE, 4.0))
		body.add_child(frame)
		body.add_child(spacer(12))
	body.add_child(label("DESIGNATION: " + str(it.name).to_upper(), 21, TEXT, 1, true))
	body.add_child(label("CODE: " + str(it.code), 21, TEXT, 1))
	body.add_child(label("QUANTITY: %d / %d" % [it.count, it.stack], 21, TEXT, 1))
	if str(it.desc) != "":
		body.add_child(spacer(12))
		body.add_child(label(str(it.desc), 21, TEXT_DIM, 1, true))
