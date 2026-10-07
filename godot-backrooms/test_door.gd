extends SceneTree

func _init() -> void:
	print("--- TESTING DOOR SYSTEM: PASSABILITY, PEEK SUPPRESSION & CAMERA ANIMATION ---")
	var door_script = load("res://scripts/World/props/door.gd")
	if door_script == null:
		print("FAIL: Could not load door.gd")
		quit(1)
		return
	
	var door: Node3D = door_script.new()
	var root := Node3D.new()
	root.add_child(door)
	
	var wall_mat := StandardMaterial3D.new()
	var frame_mat := StandardMaterial3D.new()
	var leaf_mat := StandardMaterial3D.new()
	var hw_mat := StandardMaterial3D.new()
	
	door.build(4.5, 0.3, 3.2, wall_mat, frame_mat, leaf_mat, hw_mat)
	
	# Verify collision shape when closed
	if door.leaf_collision == null or door.leaf_body == null:
		print("FAIL: leaf_collision or leaf_body is null")
		quit(1)
		return
		
	if door.leaf_collision.disabled:
		print("FAIL: leaf_collision should NOT be disabled when closed!")
		quit(1)
		return
	print("CHECK 1 PASSED: Closed door has solid collision (disabled = false)")
	
	# Create player
	var player_script = load("res://scripts/Player/player.gd")
	var player: Node = player_script.new()
	root.add_child(player)
	player.global_position = Vector3(0, 0, 1.5)
	
	# Test near_door check
	if not player.call("_near_door"):
		print("FAIL: _near_door() should be true when close to the door")
		quit(1)
		return
	print("CHECK 2 PASSED: Player detects near door (suppresses accidental wall hug & peek)")
	
	# Interact to open
	door.interact(player)
	if not door.is_open or door.target_open_amount != 1.0:
		print("FAIL: Door did not set open on interact")
		quit(1)
		return
	print("CHECK 3 PASSED: Door opened on interact()!")
	
	if not player.get("_door_anim_active"):
		print("FAIL: Player camera door animation not active")
		quit(1)
		return
	print("CHECK 4 PASSED: Realistic player camera animation activated!")
	
	# Simulate physics: the opening takes REACH_OPEN + OPEN_TIME
	for i in range(90):
		door._physics_process(0.05)
	
	# The leaf stays solid open too
	if door.leaf_collision.disabled or not is_equal_approx(door.open_amount, 1.0):
		print("FAIL: door should be fully open with its leaf still solid")
		quit(1)
		return
	print("CHECK 5 PASSED: Open door is fully swung and its leaf keeps its collision")
	
	print("Player door cam pos offset:", player.get("_door_cam_pos"))
	print("Player door cam rot offset:", player.get("_door_cam_rot"))
	
	# Interact to close
	door.interact(player)
	for i in range(45):
		door._physics_process(0.05)
		
	if door.open_amount != 0.0 or door.leaf_collision.disabled:
		print("FAIL: Door did not fully close and become solid again")
		quit(1)
		return
	print("CHECK 6 PASSED: Closed door re-locks collision firmly (disabled = false)")
	
	print("ALL DOOR CHECKS PASSED PERFECTLY!")
	root.free()
	quit(0)
