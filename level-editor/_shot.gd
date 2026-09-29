extends Node
func _ready() -> void:
	var ed = load("res://level_editor.tscn").instantiate()
	add_child(ed)
	await get_tree().process_frame
	await get_tree().process_frame
	var walk := func(n: Node, depth: int, f: Callable) -> void:
		if n is Control and depth < 9 and (n as Control).get_combined_minimum_size().x > 250:
			print("  ".repeat(depth), n.get_class(), " ", n.name, " ", (n as Control).get_combined_minimum_size().x, " ", n.get("text") if n.get("text") else "")
		for c in n.get_children(): f.call(c, depth + 1, f)
	walk.call(ed, 0, walk)
	get_tree().quit()
