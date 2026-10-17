extends SceneTree
# scratch (delete after): a floor change by the stairs, frame by frame
func _initialize() -> void:
	change_scene_to_file("res://scenes/main_menu.tscn")
	_run.call_deferred()

var t_phys := 0
var t_proc := 0
var t_pre := 0
var phys_ms := 0.0
var proc_ms := 0.0
var draw_ms := 0.0
func _phys() -> void: t_phys = Time.get_ticks_usec()
func _proc() -> void:
	t_proc = Time.get_ticks_usec()
	phys_ms = (t_proc - t_phys) / 1000.0
func _pre() -> void:
	t_pre = Time.get_ticks_usec()
	tail_ms = (t_pre - t_last) / 1000.0
	proc_ms = (t_pre - t_proc) / 1000.0
func _post() -> void: draw_ms = (Time.get_ticks_usec() - t_pre) / 1000.0
var t_first := 0
var t_last := 0
var nodes_ms := 0.0
var tail_ms := 0.0
class Marker extends Node:
	var cb: Callable
	func _process(_d: float) -> void: cb.call()
func _run() -> void:
	var m1 := Marker.new(); m1.process_priority = -1000000; m1.cb = func(): t_first = Time.get_ticks_usec()
	var m2 := Marker.new(); m2.process_priority = 1000000; m2.cb = func():
		t_last = Time.get_ticks_usec()
		nodes_ms = (t_last - t_first) / 1000.0
	m1.process_mode = Node.PROCESS_MODE_ALWAYS; m2.process_mode = Node.PROCESS_MODE_ALWAYS
	root.add_child(m1); root.add_child(m2)
	physics_frame.connect(_phys)
	process_frame.connect(_proc)
	RenderingServer.frame_pre_draw.connect(_pre)
	RenderingServer.frame_post_draw.connect(_post)
	var game = root.get_node("Game")
	while game.level == null or not is_instance_valid(game.level) or game.player == null:
		await process_frame
	for i in 300: await process_frame
	var L = game.level
	var p: Node3D = game.player
	print("BENCH floor ", L.built_floor, " size ", L.size)
	for round_i in 4:
		var well = null
		for s in L.stairwells: well = s
		# on the far landing, down-lane half, where the stairs swap floors
		p.global_position = well.to_global(Vector3(9.5, (-4.5 if L.built_floor == 0 else 4.5) + 0.1, -2.6))
		for i in 30: await process_frame
		print("BENCH paused=", paused)
		var target: int = -1 if L.built_floor == 0 else 0
		var t0 := Time.get_ticks_usec()
		game.change_floor(target, well._from, "stairs", -(target - L.built_floor) * 9.0)
		var frames: Array = []
		var last := Time.get_ticks_usec()
		var done_at := -1.0
		while (Time.get_ticks_usec() - t0) < 3500000:
			await process_frame
			var now := Time.get_ticks_usec()
			frames.append((now - last) / 1000.0)
			if (now - last) > 30000: print("BENCH   spike [proc %.1f (nodes %.1f, after nodes %.1f) draw %.1f lastphys %.1f]" % [proc_ms, nodes_ms, tail_ms, draw_ms, phys_ms], " spike %.1f ms at %.2f s rebuilding=%s slice=%d" % [(now - last) / 1000.0, (now - t0) / 1000000.0, L.rebuilding, L.slice_usec])
			last = now
			if done_at < 0.0 and not L.rebuilding: done_at = (now - t0) / 1000000.0
		var worst := frames.duplicate()
		worst.sort()
		worst.reverse()
		var sum := 0.0
		for f in frames: sum += f
		print("BENCH stairs -> %d: built in %.2f s over %d frames, avg %.1f ms, worst %s" % [target, done_at, frames.size(), sum / frames.size(), str(worst.slice(0, 8))])
	# the instant way (a level change, a drop hole): all at once, still whole
	var a := Time.get_ticks_usec()
	L.rebuild_floor_seamless(-1 if L.built_floor == 0 else 0, {})
	print("BENCH instant rebuild %.1f ms, rebuilding=%s, fx=%d, children=%d" % [(Time.get_ticks_usec() - a) / 1000.0, L.rebuilding, L.fx.size(), L.get_child_count()])
	quit()
