@tool
class_name UBNodeSwap
extends RefCounted
## Node swaps for the Bake and Convert undo entries. The entries used to call
## methods on the plugin instance itself, which a plugin reload (Ctrl+Alt+R)
## frees: undoing a bake afterwards hit a dead object and editor history went
## out of step with the scene. An instance of this class is the target
## instead. UndoRedo keeps a reference to every RefCounted it is asked to call,
## so the helper lives exactly as long as the history entries that use it.


## Swap `from` for `to` at the same tree position. replace_by moves the
## children but clears their scene ownership, so capture the owned set first
## and re-own everything after. `select` makes `to` the editor's sole
## selection (Convert passes false and selects every new node at the end).
func swap(from: Node3D, to: Node3D, root: Node, select := true) -> void:

	drop_managed_collision(from)
	drop_managed_collision(to)
	if from is UBMeshInstance3D and not (to is UBMeshInstance3D):

		var baked_body := (from as UBMeshInstance3D).build_collision_body()
		if baked_body != null:
			to.add_child(baked_body)
	var owned: Array[Node] = from.find_children("*", "", true, true)

	var incoming: Array[Node] = to.find_children("*", "", true, false)
	var xform := from.transform
	from.replace_by(to, true)
	to.transform = xform
	to.owner = root
	for n in owned + incoming:
		if is_instance_valid(n):
			n.owner = root
	if to is UBMeshInstance3D:
		(to as UBMeshInstance3D).refresh_collision()
	if select:
		select_nodes([to])


## Make `nodes` the editor's whole selection (invalid entries skipped).
func select_nodes(nodes: Array) -> void:
	var editor_selection := EditorInterface.get_selection()
	editor_selection.clear()
	for n in nodes:
		if n is Node and is_instance_valid(n) and (n as Node).is_inside_tree():
			editor_selection.add_node(n)


static func drop_managed_collision(node: Node) -> void:
	var body: Node = node.get_node_or_null(NodePath(UBMeshInstance3D.COLLISION_BODY_NAME))
	if body != null:
		node.remove_child(body)
		body.free()
