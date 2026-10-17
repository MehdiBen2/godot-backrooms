extends SceneTree

func _initialize() -> void:
	print("--- TESTING DELETING DOOR ON FLOOR -1 IN LEVEL 0 ---")
	var ed = (load("res://level_editor.tscn") as PackedScene).instantiate()
	root.add_child(ed)
	for i in 10: await process_frame

	ed._switch_floor(-1)
	for i in 10: await process_frame
	
	var g = ed.wall_graph
	print("Floor -1 edges: ", g.edges.keys())
	print("g.edges has 6: ", g.edges.has(6))
	if g.edges.has(6):
		print("Edge 6 ops: ", g.edges[6].get("ops", []))
		ed.wsel_op = {"e": 6, "i": 0}
		ed._walls_changed()
		print("wsel_op: ", ed.wsel_op)
		print("Deleting with _delete_selected()...")
		ed._delete_selected()
		print("Deleted successfully!")

	print("--- TEST FINISHED ---")
	quit(0)
