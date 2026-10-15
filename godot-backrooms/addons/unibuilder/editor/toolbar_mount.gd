@tool
class_name UBToolbarMount
extends RefCounted
## Finds where the toolbar can move to its own wrapping row just below the 3D
## editor's menu row: from the spatial menu HBox (where add_control_to_container
## puts the toolbar), walk up at most four hops to the Node3DEditor
## VBoxContainer. Four hops reaches Node3DEditor and stops there, so an
## unfamiliar tree falls back instead of grabbing an outer container that
## would show the row on every editor tab. Pure tree inspection, no editor
## singletons.


## Returns {"vbox": VBoxContainer, "anchor": Node}, where anchor is the menu
## row's top-level ancestor inside the vbox (insert the new row at anchor's
## index + 1), or {} when the tree does not match.
static func find_row_anchor(menu_hbox: Node) -> Dictionary:
	if menu_hbox == null:
		return {}
	var node := menu_hbox
	for _hop in 4:
		var parent := node.get_parent()
		if parent == null:
			return {}
		if parent is VBoxContainer:
			return {"vbox": parent, "anchor": node}
		node = parent
	return {}
