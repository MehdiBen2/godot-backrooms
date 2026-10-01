extends SceneTree

func _init() -> void:
	var f := FileAccess.open("c:/Users/alhyu/Documents/GitHub/godot-backrooms/diag_output.txt", FileAccess.WRITE)
	f.store_line("=== DIAG TRIGGER START ===")
	
	# Load level0
	var level_data_script = load("res://scripts/World/level/level_data.gd")
	var ldata = level_data_script.read_level("level0")
	f.store_line("Level0 loaded, objects count: " + str(ldata.objects.size()))
	
	var triggers := []
	for o in ldata.objects:
		if o.type == "trigger":
			triggers.append(o)
	f.store_line("Found triggers in level0: " + str(triggers.size()))
	for i in triggers.size():
		var t = triggers[i]
		f.store_line("Trigger %d: pos=(%s,%s) text='%s' event='%s' list=%s once=%s delay=%s duration=%s depth=%s scale=%s" % [
			i, str(t.pos_x), str(t.pos_y), str(t.get("text", "")), str(t.get("event", "")),
			str(t.get("events_list", [])), str(t.get("once", true)), str(t.get("delay", 0)),
			str(t.get("duration", 20)), str(t.get("depth", 2)), str(t.get("scale", 1))
		])
	
	# Test EventTrigger instantiation
	var EventTrigger = load("res://scripts/World/props/event_trigger.gd")
	var root = Node3D.new()
	root.name = "Main"
	get_root().add_child(root)
	
	var tr = EventTrigger.new()
	root.add_child(tr)
	tr.setup(root, triggers[0], 4.5)
	
	f.store_line("EventTrigger instance created:")
	f.store_line("  key: " + tr.key)
	f.store_line("  text: '" + tr.text + "'")
	f.store_line("  event_list: " + str(tr.event_list))
	f.store_line("  half: " + str(tr.half))
	
	# Simulate player inside
	var dummy_player = Node3D.new()
	dummy_player.name = "Player"
	root.add_child(dummy_player)
	dummy_player.global_position = Vector3(ldata.spawn_pos.x, 0.1, ldata.spawn_pos.z)
	f.store_line("Player spawn_pos: " + str(dummy_player.global_position))
	
	var l := tr.global_transform.affine_inverse() * dummy_player.global_position
	var inside := absf(l.x) <= tr.half.x and absf(l.z) <= tr.half.z and l.y > -1.0 and l.y < tr.half.y * 2.0
	f.store_line("Local offset l: " + str(l))
	f.store_line("Inside check: " + str(inside))
	
	# Call _run
	f.store_line("Testing tr._run()...")
	tr._run()
	
	# Check children of root for CanvasLayer
	var found_layer: CanvasLayer = null
	for c in root.get_children():
		if c is CanvasLayer:
			found_layer = c
			break
	if found_layer == null:
		f.store_line("ERROR: CanvasLayer NOT found in root!")
	else:
		f.store_line("CanvasLayer found! layer=" + str(found_layer.layer))
		f.store_line("CanvasLayer children count: " + str(found_layer.get_child_count()))
		for c in found_layer.get_children():
			f.store_line("  Layer child: " + c.name + " (" + c.get_class() + ")")
			if c is Control:
				f.store_line("    Control size: " + str(c.size) + " pos: " + str(c.position))
				for c2 in c.get_children():
					f.store_line("    Subchild: " + c2.name + " (" + c2.get_class() + ")")
					if c2 is Label:
						f.store_line("      Label text: '" + c2.text + "'")
						f.store_line("      Label visible: " + str(c2.visible))
						f.store_line("      Label modulate.a: " + str(c2.modulate.a))
						f.store_line("      Label pos: " + str(c2.position) + " size: " + str(c2.size))
						f.store_line("      Label offsets: L=" + str(c2.offset_left) + " R=" + str(c2.offset_right) + " T=" + str(c2.offset_top) + " B=" + str(c2.offset_bottom))
						f.store_line("      Label anchors: L=" + str(c2.anchor_left) + " R=" + str(c2.anchor_right) + " T=" + str(c2.anchor_top) + " B=" + str(c2.anchor_bottom))
	
	f.store_line("=== DIAG TRIGGER END ===")
	f.close()
	quit()
