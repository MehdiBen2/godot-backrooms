extends CanvasLayer
## Performance overlay and benchmark (autoload: Perf).
##
## F12 shows what a frame costs and why: GPU and CPU render time (measured on the viewport, not guessed from the
## frame rate), draw calls, objects and primitives in view, the real lights lit and how many cast shadows, and
## each monster's simulation tier (EntityLOD: FULL / SLOW / ASLEEP / not spawned).
##
## Benchmark: launch with  -- --test-level=<id> --bench  and the game stands at a fixed set of spots round the
## level, turns a full circle at each, and writes the numbers to user://bench.txt, then quits. The spots and the
## turn are the same every run, so two runs before and after a change can be compared directly.

const BENCH_SPOTS := [Vector2(0.5, 0.5), Vector2(0.25, 0.25), Vector2(0.75, 0.25), Vector2(0.25, 0.75), Vector2(0.75, 0.75)]
const BENCH_TURN := 5.0           # s for one full turn at a spot
const BENCH_SETTLE := 1.5         # s at a spot before measuring (the light pool fades in, shaders compile)

var _label: Label
var _vp_rid: RID
var _acc := 0.0
var bench := OS.get_cmdline_user_args().has("--bench") or OS.get_cmdline_args().has("--bench")
var _bench_spot := -1
var _bench_t := 0.0
var _bench_rows: Array = []      # [frame_ms, gpu_ms, cpu_ms, draws, objects, prims] per measured frame
var _bench_lvl_t := 0.0

func _ready() -> void:
	layer = 120
	process_mode = Node.PROCESS_MODE_ALWAYS
	_label = Label.new()
	_label.position = Vector2(12, 12)
	_label.add_theme_font_size_override("font_size", 13)
	_label.add_theme_color_override("font_color", Color(0.85, 1.0, 0.85))
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 4)
	_label.visible = false
	add_child(_label)
	_vp_rid = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp_rid, true)
	if bench:
		_bench_settings()

## --bench-preset=<name> and --bench-set=<key>:<value> pick the settings for this run only (graphics.cfg is not
## written), so one setting can be measured on and off
func _bench_settings() -> void:
	for a in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if a.begins_with("--bench-preset="):
			var n := a.substr(15)
			if Gfx.PRESETS.has(n):
				Gfx.preset = n
				Gfx.s = Gfx.PRESETS[n].duplicate()
		elif a.begins_with("--bench-skip="):
			for p in a.substr(13).split(","):
				_skips[p] = true
		elif a.begins_with("--bench-set="):
			var kv := a.substr(12).split(":")
			if kv.size() == 2 and Gfx.s.has(kv[0]):
				Gfx.s[kv[0]] = type_convert(str_to_var(kv[1]), typeof(Gfx.s[kv[0]]))
	Gfx.apply()

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.physical_keycode == KEY_F12:
		_label.visible = not _label.visible

## Script time by system: the main per-frame functions report here (`Perf.add("Level", start_usec)` round their
## body). Summed per frame, shown smoothed in the overlay and averaged by the benchmark.
var _sys_frame := {}             # key -> usec this frame
var _sys_avg := {}               # key -> ms, smoothed (overlay)
var _sys_sum := {}               # key -> usec summed over the benchmark's measured frames
var _sys_frames := 0

func add(key: String, since_usec: int) -> void:
	_sys_frame[key] = _sys_frame.get(key, 0) + (Time.get_ticks_usec() - since_usec)

func _roll_systems(measuring: bool) -> void:
	for k in _sys_frame:
		var ms: float = _sys_frame[k] / 1000.0
		_sys_avg[k] = lerpf(float(_sys_avg.get(k, ms)), ms, 0.05)
		if measuring:
			_sys_sum[k] = _sys_sum.get(k, 0) + _sys_frame[k]
	if measuring:
		_sys_frames += 1
	_sys_frame.clear()

func _systems_text(src: Dictionary, scale: float) -> PackedStringArray:
	var keys := src.keys()
	keys.sort_custom(func(a, b): return float(src[a]) > float(src[b]))
	var out: PackedStringArray = []
	var total := 0.0
	for k in keys:
		total += float(src[k]) * scale
	out.append("scripts total %.2f ms" % total)
	for k in keys:
		out.append("  %-16s %6.2f ms" % [k, float(src[k]) * scale])
	return out

## The renderer's own timestamps for the last frame it finished (what Godot's visual profiler shows): each pass's
## GPU time, as the gap to the next stamp. Summed into _pass_sum by the benchmark.
var _pass_sum := {}
var _pass_frames := 0

func gpu_passes() -> Dictionary:
	var rd := RenderingServer.get_rendering_device()
	var out := {}
	if rd == null:
		return out
	var n := rd.get_captured_timestamps_count()
	for i in range(n - 1):
		var nm := rd.get_captured_timestamp_name(i)
		var ms := float(rd.get_captured_timestamp_gpu_time(i + 1) - rd.get_captured_timestamp_gpu_time(i)) / 1000.0
		var cpu := float(rd.get_captured_timestamp_cpu_time(i + 1) - rd.get_captured_timestamp_cpu_time(i)) / 1000.0
		if ms >= 0.0:
			out["gpu " + nm] = float(out.get("gpu " + nm, 0.0)) + ms
		if cpu >= 0.0:
			out["cpu " + nm] = float(out.get("cpu " + nm, 0.0)) + cpu
	return out

## --bench-skip=atmo,pool,... : parts of a system that are left out this run (each asks Perf.skip("<part>"))
var _skips := {}
func skip(part: String) -> bool:
	return _skips.has(part)

func gpu_ms() -> float:
	return RenderingServer.viewport_get_measured_render_time_gpu(_vp_rid)

func cpu_ms() -> float:
	return RenderingServer.viewport_get_measured_render_time_cpu(_vp_rid)

func _process(dt: float) -> void:
	# (an autoload: this runs before the scene's own _process, so it closes the books on the frame before)
	_roll_systems(bench and _bench_t > BENCH_SETTLE and _bench_spot >= 0)
	if bench:
		_bench_step(dt)
	if not _label.visible:
		return
	_acc -= dt
	if _acc > 0.0:
		return
	_acc = 0.25
	_label.text = _report()

## Real lights lit right now in the level's pool (level_light_pool.gd), and how many of them cast shadows
func light_counts() -> Vector2i:
	var lvl: Node = Game.level if Game.level != null and is_instance_valid(Game.level) else null
	if lvl == null or not ("pool" in lvl):
		return Vector2i.ZERO
	var lit := 0
	var shadowed := 0
	for key in ["pool", "pool_b", "far_pool", "ceil_glow"]:
		for l: Light3D in lvl.get(key):
			if l.visible and l.light_energy > 0.001:
				lit += 1
				if l.shadow_enabled:
					shadowed += 1
	return Vector2i(lit, shadowed)

func _report() -> String:
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var lc := light_counts()
	var lines: PackedStringArray = [
		"FPS %d   frame %.1f ms" % [fps, 1000.0 / maxf(fps, 1.0)],
		"GPU %.2f ms   render CPU %.2f ms   script %.2f ms   physics %.2f ms" % [gpu_ms(), cpu_ms(),
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0],
		"draws %d   objects %d   prims %dk" % [Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME), Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1000],
		"lights %d   shadow casters %d   VRAM %d MB   nodes %d" % [lc.x, lc.y,
			Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576, Performance.get_monitor(Performance.OBJECT_NODE_COUNT)],
		"preset %s   GI %s" % [Gfx.preset, "baked" if bool(Gfx.s.get("baked_gi", false)) else "off"],
	]
	lines.append_array(_systems_text(_sys_avg, 1.0))
	lines.append("entities:")
	for e in EntityLOD.entities:
		if is_instance_valid(e):
			var tier := EntityLOD.tier_name(e) if e.is_visible_in_tree() or not EntityLOD.is_spawned(e) else "hidden"
			lines.append("  %-10s %-11s %5.0f m" % [e.name, tier, EntityLOD.distance_of(e)])
	return "\n".join(lines)

# ---- benchmark --------------------------------------------------------------------------------------------
func _bench_step(dt: float) -> void:
	var lvl: Node = Game.level if Game.level != null and is_instance_valid(Game.level) else null
	var p: Node3D = Game.player if Game.player != null and is_instance_valid(Game.player) else null
	if lvl == null or p == null or not ("size" in lvl):
		return
	if not Game.playing and Game.main != null and Game.main.has_method("set_paused"):
		Game.main.set_paused(false)            # past the start screen (and back in, if the window lost focus)
		return
	# uncapped, so the frame time is what the machine takes, not the screen's refresh rate. Set only when it
	# differs: changing the vsync mode rebuilds the swapchain, and doing that every frame was most of the frame.
	if Engine.max_fps != 0:
		Engine.max_fps = 0
	if DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Game.god_mode = true
	_bench_lvl_t += dt
	if _bench_lvl_t < 3.0:
		return                                 # the level's first seconds: loading hitches are not the steady cost
	if _bench_spot < 0 or _bench_t >= BENCH_SETTLE + BENCH_TURN:
		_bench_spot += 1
		_bench_t = 0.0
		if _bench_spot >= BENCH_SPOTS.size():
			_bench_write()
			get_tree().quit()
			return
		if _bench_spot == 0:
			_bench_switch_off()
		var f: Vector2 = BENCH_SPOTS[_bench_spot]
		var c: Vector2i = lvl._nearest_open(Vector2i(int(lvl.size * f.x), int(lvl.size * f.y)))
		p.global_position = Vector3(c.x * lvl.CELL, 0.05, c.y * lvl.CELL)
		if "velocity" in p:
			p.velocity = Vector3.ZERO
	var was := _bench_t
	_bench_t += dt
	if was <= BENCH_SETTLE and _bench_t > BENCH_SETTLE:
		var tiers: PackedStringArray = []
		for e in EntityLOD.entities:
			if is_instance_valid(e):
				tiers.append("%s=%s@%.0fm" % [e.name, EntityLOD.tier_name(e) if e.is_visible_in_tree() or not EntityLOD.is_spawned(e) else "hidden", EntityLOD.distance_of(e)])
		print("BENCH_SPOT %d  %s" % [_bench_spot, "  ".join(tiers)])
	# --bench-shots=<tag>: a picture at each spot as measuring starts (user://bench_<tag>_<spot>.png), to compare looks
	if was <= BENCH_SETTLE and _bench_t > BENCH_SETTLE:
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--bench-shots="):
				var img := get_viewport().get_texture().get_image()
				img.save_png("user://bench_%s_%d.png" % [a.substr(14), _bench_spot])
	p.rotate_y(TAU / BENCH_TURN * dt)
	if _bench_t > BENCH_SETTLE:
		_bench_rows.append([dt * 1000.0, RenderingServer.get_frame_setup_time_cpu(),
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME), Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)])
		var passes := gpu_passes()
		if not passes.is_empty():
			_pass_frames += 1
			for k in passes:
				_pass_sum[k] = float(_pass_sum.get(k, 0.0)) + passes[k]

## --bench-off=Entity,Mannequin,... : those nodes of the main scene don't run or draw, to see what each one costs
func _bench_switch_off() -> void:
	for a in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if not a.begins_with("--bench-off="):
			continue
		for nm: String in a.substr(12).split(","):
			var run_only := nm.begins_with("~")        # "~Level": stop it running, keep drawing it
			nm = nm.trim_prefix("~")
			var n: Node = Game.main.get_node_or_null(nm)
			if n == null and Game.level != null:
				n = Game.level.get_node_or_null(nm)
			if n == null:
				continue
			n.process_mode = Node.PROCESS_MODE_DISABLED
			if run_only:
				continue
			if n is Node3D: (n as Node3D).visible = false
			elif n is CanvasLayer: (n as CanvasLayer).visible = false

func _stat(col: int) -> String:
	var v: Array = []
	for r in _bench_rows:
		v.append(float(r[col]))
	v.sort()
	if v.is_empty():
		return "-"
	var sum := 0.0
	for x in v:
		sum += x
	return "avg %8.2f   p95 %8.2f   max %8.2f" % [sum / v.size(), v[int(v.size() * 0.95)], v[-1]]

## Every node that runs each frame, counted by its script (or class): what the frame's unexplained time is spent on
func _census() -> PackedStringArray:
	var counts := {}
	var stack: Array[Node] = [get_tree().root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children(true):
			stack.append(c)
		if not n.can_process():
			continue
		var kinds: PackedStringArray = []
		if n.is_processing(): kinds.append("process")
		if n.is_physics_processing(): kinds.append("physics")
		if n.is_processing_internal(): kinds.append("internal")
		if n.is_physics_processing_internal(): kinds.append("phys-internal")
		if kinds.is_empty():
			continue
		var s: Script = n.get_script()
		var key := "%s [%s]" % [s.resource_path.get_file() if s != null else n.get_class(), ",".join(kinds)]
		counts[key] = int(counts.get(key, 0)) + 1
	var keys := counts.keys()
	keys.sort_custom(func(a, b): return counts[a] > counts[b])
	var out: PackedStringArray = ["nodes running every frame:"]
	for k in keys.slice(0, 40):
		out.append("  %5d  %s" % [counts[k], k])
	return out

func _bench_write() -> void:
	var out: PackedStringArray = [
		"BENCH %s  preset=%s  driver=%s  gpu=%s  frames=%d" % [Time.get_datetime_string_from_system(), Gfx.preset,
			RenderingServer.get_current_rendering_driver_name(), RenderingServer.get_video_adapter_name(), _bench_rows.size()],
		"settings  " + str(Gfx.s),
		"window %s  screen %s  3D scale %.2f  refresh %d Hz" % [str(get_viewport().get_visible_rect().size), str(DisplayServer.screen_get_size()),
			get_viewport().scaling_3d_scale, roundi(DisplayServer.screen_get_refresh_rate())],
		"frame ms   " + _stat(0),
		"setup ms   " + _stat(1),
		"physics ms " + _stat(2),
		"draws      " + _stat(3),
		"objects    " + _stat(4),
		"prims      " + _stat(5),
	]
	out.append_array(_systems_text(_sys_sum, 1.0 / 1000.0 / maxf(_sys_frames, 1)))
	out.append_array(_census())
	for side in ["gpu", "cpu"]:
		var part := {}
		for k: String in _pass_sum:
			if k.begins_with(side + " "): part[k.substr(4)] = _pass_sum[k]
		out.append("render passes, %s (%d frames)" % [side.to_upper(), _pass_frames])
		var gp := _systems_text(part, 1.0 / maxf(_pass_frames, 1))
		for i in mini(gp.size(), 22):
			out.append(gp[i].replace("scripts total", side + " total"))
	var f := FileAccess.open("user://bench.txt", FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(out) + "\n")
	print("\n".join(out))
