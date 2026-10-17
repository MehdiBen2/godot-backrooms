extends SceneTree
# scratch: times a floor change, piece by piece and frame by frame
var frames: Array = []
var last := 0
func _initialize() -> void:
	change_scene_to_file("res://scenes/main_menu.tscn")
	_run.call_deferred()

func t0() -> int: return Time.get_ticks_usec()
func ms(a: int) -> String: return "%.1f" % ((Time.get_ticks_usec() - a) / 1000.0)

var t_pre := 0
var draw_ms := 0.0
var t_phys := 0
var t_proc := 0
var phys_ms := 0.0
var proc_ms := 0.0
func _phys() -> void: t_phys = Time.get_ticks_usec()
func _proc() -> void:
	t_proc = Time.get_ticks_usec()
	phys_ms = (t_proc - t_phys) / 1000.0
func _pre() -> void:
	t_pre = Time.get_ticks_usec()
	proc_ms = (t_pre - t_proc) / 1000.0
func _post() -> void: draw_ms = (Time.get_ticks_usec() - t_pre) / 1000.0
func _run() -> void:
	RenderingServer.frame_pre_draw.connect(_pre)
	physics_frame.connect(_phys)
	process_frame.connect(_proc)
	RenderingServer.frame_post_draw.connect(_post)
	var game = root.get_node("Game")
	while game.level == null or not is_instance_valid(game.level) or game.player == null:
		await process_frame
	for i in 240: await process_frame          # settle: shells, shaders
	var L = game.level
	print("BENCH floor ", L.built_floor, " size ", L.size)
	var vp := root.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	for round_i in 2:
		var f: int = -1 if L.built_floor == 0 else 0
		L.built_floor = f
		game.level_floor = f
		L._shell_run += 1
		var a := t0()
		L._tear_down(0 if f == -1 else -1, null, null, false)
		L.load_floor(f, L.level_raw)
		L._place_shells()
		L._step_mask = PackedByteArray()
		L.step_mask()
		print("BENCH -> floor ", f, " teardown+load ", ms(a))
		var steps := [
			["materials", func(): L._make_materials()], ["surfaces A", func(): L._build_surfaces(true, false)],
			["surfaces B", func(): L._build_surfaces(false, true)], ["walls", L._build_walls], ["objects", L._build_objects], ["trim", func(): L.call("_build_trim")],
			["ceiling steps", func(): L._build_ceiling_steps()], ["pit shafts", func(): L._build_pit_shafts()], ["dirt", L._build_dirt],
			["place fixtures", func(): (L._place_panel_fixtures() if L.panel_ceiling != null else L._place_fixtures())],
			["fixture meshes", func(): (L._build_panel_ceiling() if L.panel_ceiling != null else L._build_fixture_meshes())],
			["floor reflections", func(): L._build_floor_reflections()], ["floor glow", func(): L._build_floor_glow()],
			["gi", func(): L.grid_gi = null; L._apply_gi()],
			["exit", func(): L._build_exit()], ["ray", func():
				var a2 := t0()
				var q := PhysicsRayQueryParameters3D.create(game.player.global_position + Vector3(0, 1.5, 0), game.player.global_position + Vector3(3, 0.2, 3), 1)
				L.get_world_3d().direct_space_state.intersect_ray(q)
				print("BENCH      first ray ", ms(a2))], ["batteries", func(): L._spawn_batteries()], ["tape", func(): L._spawn_tape()], ["flashes", func(): L._spawn_flashes()], ["survey", func(): L._spawn_survey_props()], ["idle", func(): pass], ["idle2", func(): pass]]
		L.rebuilding = true
		for st in steps:
			await process_frame
			a = t0()
			st[1].call()
			var sc := ms(a)
			a = t0()
			await process_frame
			print("BENCH  %-18s script %6s ms | next frame %s ms (proc %.1f draw %.1f lastphys %.1f)" % [st[0], sc, ms(a), proc_ms, draw_ms, phys_ms])
			var sysf: Dictionary = root.get_node("Perf")._sys_frame
			var big := []
			for k in sysf: if sysf[k] > 2000: big.append("%s %.1f" % [k, sysf[k] / 1000.0])
			if not big.is_empty(): print("BENCH      sys ", big)
		L.rebuilding = false
		L._floor_ready()
		a = t0()
		L._sync_shells()
		for k in 30:
			var b := t0()
			await process_frame
			var d := (Time.get_ticks_usec() - b) / 1000.0
			var sysg: Dictionary = root.get_node("Perf")._sys_frame
			if d > 25.0:
				for kk in sysg: if sysg[kk] > 4000: print("BENCH      sys ", kk, " ", sysg[kk] / 1000.0)
			if d > 25.0: print("BENCH  after build frame %d: %.1f ms (draw %.1f)" % [k, d, draw_ms])
	quit()
