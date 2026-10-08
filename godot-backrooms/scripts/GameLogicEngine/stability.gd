extends Node
## Crash resilience and crash reports (autoload: Stability, after Gfx). A run drops a flag file at start and
## removes it on a clean exit; a flag still there at the next start means the last run died (a driver reset, a
## hang that was killed, a crash). Two things then happen:
##
## 1. The game backs off by itself instead of going straight back into what killed it:
##      1st unclean exit in a row: the Ultra preset drops to High (fewer shadow-casting lights, no live GI)
##      2nd:                       Medium, and on Direct3D 12 the game restarts itself once on Vulkan
##    A clean exit resets the count. Level-editor test runs are killed by the editor when it relaunches one, so
##    a missing clean exit there is only trusted once the run had lasted a while (MIN_RUN).
##
## 2. A crash report says what went wrong. Every SAMPLE_EVERY seconds the run saves a snapshot of its resources
##    (script memory, video memory, node / object / orphan counts, draw calls, slowest frame, level, position)
##    to user://last_state.txt, keeping the last RING_SIZE of them. user://crash_reports/crash_<time>.txt gets:
##    those snapshots, what GREW between the first and the last (the thing that overflowed), the tail of the
##    previous run's engine log, the newest slow frames, and (a moment later, from Windows) the crash code and
##    what it means. The file's folder is printed as a warning at startup.

const FLAG := "user://running.flag"
const STATE := "user://stability.cfg"
const STATE_FILE := "user://last_state.txt"
const REPORT_DIR := "user://crash_reports/"
const MIN_RUN := 25.0            # seconds a flagged run must have lasted for a test run to count as a crash
const RELAUNCH_ARG := "--stability-relaunch"
const SAMPLE_EVERY := 2.0
const VERDICT_ROWS := 10         # the verdict looks at the last 20 seconds
const RING_SIZE := 30            # one minute of history

const FIELDS := ["t", "fps", "worst_ms", "script_mb", "vram_mb", "tex_mb", "buf_mb", "nodes", "objects", "orphans",
	"resources", "draws", "gpu_objs", "phys_objs", "cpu_ms", "audio_lat_ms"]
## Fields that, growing this much over the snapshots, mean something is leaking or piling up
const GROWTH := {"script_mb": 150.0, "vram_mb": 400.0, "nodes": 1500.0, "objects": 3000.0, "orphans": 50.0, "resources": 1500.0}

var crashes := 0
var safe_mode := ""              # what the back-off did this launch, for the debug console
var last_report := ""            # absolute path of the report written this launch ("" = none)

var _t := 0.0
var _ring: Array = []
var _worst_frame := 0.0          # the longest frame since the last snapshot (seconds)

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var cf := ConfigFile.new()
	cf.load(STATE)
	crashes = int(cf.get_value("stability", "crashes", 0))
	if FileAccess.file_exists(FLAG) and _last_run_counts():
		crashes += 1
		_write_report()
		_back_off()
	_save()
	_write_flag(0.0)

func _last_run_counts() -> bool:
	var f := FileAccess.open(FLAG, FileAccess.READ)
	if f == null:
		return false
	var lasted := float(f.get_as_text().strip_edges())
	if Game.editor_test and lasted < MIN_RUN:
		return false             # the editor killing its previous test window
	return true

# ---- back off ----------------------------------------------------------------------------------------
func _back_off() -> void:
	push_warning("Stability: the last run did not exit cleanly (%d in a row), backing off" % crashes)
	if crashes >= 2:
		if Gfx.preset != "medium" and Gfx.preset != "low":
			Gfx.set_preset("medium")
		safe_mode = "medium"
		_relaunch_on_vulkan()
	elif Gfx.preset == "ultra":
		Gfx.set_preset("high")
		safe_mode = "high"

## Direct3D 12 died twice running: the same game on Vulkan, once (the argument stops a restart loop)
func _relaunch_on_vulkan() -> void:
	var user_args := OS.get_cmdline_user_args()
	if RenderingServer.get_current_rendering_driver_name() != "d3d12" or user_args.has(RELAUNCH_ARG):
		return
	var out: PackedStringArray = ["--rendering-driver", "vulkan"]
	if not OS.has_feature("template"):          # run from the Godot executable (editor test): it needs the project
		out.append_array(["--path", ProjectSettings.globalize_path("res://")])
	out.append("--")
	out.append_array(user_args)
	out.append(RELAUNCH_ARG)
	if OS.create_process(OS.get_executable_path(), out) > 0:
		crashes = 0              # (so the new run starts clean)
		_save()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(FLAG))
		get_tree().quit()

func _save() -> void:
	var cf := ConfigFile.new()
	cf.set_value("stability", "crashes", crashes)
	cf.save(STATE)

func _write_flag(seconds: float) -> void:
	var f := FileAccess.open(FLAG, FileAccess.WRITE)
	if f != null:
		f.store_string(str(seconds))

func _clean_exit() -> void:
	crashes = 0
	_save()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(FLAG))

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_clean_exit()

func _exit_tree() -> void:
	_clean_exit()

# ---- snapshots ---------------------------------------------------------------------------------------
func _process(dt: float) -> void:
	_worst_frame = maxf(_worst_frame, dt)
	_t += dt
	if _t >= SAMPLE_EVERY:       # also how long this run has lasted, so a killed test window can be told from a crash
		_t = 0.0
		_write_flag(Time.get_ticks_msec() / 1000.0)
		_snapshot()

func _snapshot() -> void:
	var mb := 1.0 / 1048576.0
	var row := {
		"t": snappedf(Time.get_ticks_msec() / 1000.0, 0.1),
		"fps": int(Performance.get_monitor(Performance.TIME_FPS)),
		"worst_ms": int(_worst_frame * 1000.0),
		"script_mb": int(Performance.get_monitor(Performance.MEMORY_STATIC) * mb),
		"vram_mb": int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) * mb),
		"tex_mb": int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) * mb),
		"buf_mb": int(Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) * mb),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"orphans": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"resources": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"draws": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"gpu_objs": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"phys_objs": int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)),
		"cpu_ms": int(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0),
		"audio_lat_ms": int(Performance.get_monitor(Performance.AUDIO_OUTPUT_LATENCY) * 1000.0),
	}
	_worst_frame = 0.0
	_ring.append(row)
	if _ring.size() > RING_SIZE:
		_ring.pop_front()
	var f := FileAccess.open(STATE_FILE, FileAccess.WRITE)
	if f == null:
		return
	f.store_line("driver=%s gpu=%s preset=%s level=%s floor=%s playing=%s" % [
		RenderingServer.get_current_rendering_driver_name(), RenderingServer.get_video_adapter_name(), Gfx.preset,
		Game.test_level, str(Game.level_floor), str(Game.playing)])
	f.store_line(_where())
	f.store_line("\t".join(FIELDS))
	for r in _ring:
		var cells: PackedStringArray = []
		for k in FIELDS:
			cells.append(str(r[k]))
		f.store_line("\t".join(cells))

func _where() -> String:
	var pos := "-"
	var p = Game.get("player")
	if p is Node3D and is_instance_valid(p):
		pos = str((p as Node3D).global_position.snapped(Vector3.ONE * 0.1))
	var scene := get_tree().current_scene
	return "scene=%s pos=%s" % [scene.name if scene else "-", pos]

# ---- the report --------------------------------------------------------------------------------------
func _write_report() -> void:
	var state := FileAccess.get_file_as_string(STATE_FILE) if FileAccess.file_exists(STATE_FILE) else ""
	var rows: Array = []
	var lines := state.split("\n", false)
	for i in range(3, lines.size()):
		rows.append(lines[i].split("\t"))
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var out: PackedStringArray = []
	out.append("CRASH REPORT  %s  (the previous run did not exit cleanly; %d in a row)" % [stamp, crashes])
	out.append("")
	out.append("== Verdict (what grew or spiked in the snapshots before it died)")
	out.append_array(_verdict(rows))
	out.append("")
	out.append("== Last snapshots (every %d s, oldest first)" % int(SAMPLE_EVERY))
	out.append(state if state != "" else "(none: it died before the first snapshot, i.e. during startup / loading)")
	out.append("")
	out.append("== Newest slow frames (hitches.log)")
	out.append_array(_tail("user://hitches.log", 6, 330))
	out.append("")
	out.append("== End of the previous run's engine log")
	var log_path := _previous_log()
	out.append(log_path if log_path != "" else "(no earlier log found)")
	if log_path != "":
		out.append_array(_tail(log_path, 40, 300))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(REPORT_DIR))
	var path := REPORT_DIR + "crash_%s.txt" % stamp
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string("\n".join(out) + "\n")
	f.close()
	last_report = ProjectSettings.globalize_path(path)
	push_warning("Stability: crash report written to %s" % last_report)
	_append_windows_crash(last_report)

func _verdict(rows: Array) -> PackedStringArray:
	var out: PackedStringArray = []
	if rows.size() < 2:
		out.append("Not enough snapshots: it died within %d seconds of starting (startup / level load)." % int(SAMPLE_EVERY * 2))
		return out
	# only the stretch just before the end: the first snapshots can sit in the menu, before the level (and its
	# memory) loaded, which is growth that is normal
	rows = rows.slice(maxi(0, rows.size() - VERDICT_ROWS))
	var first: PackedStringArray = rows[0]
	var last: PackedStringArray = rows[rows.size() - 1]
	var found := false
	for k in GROWTH:
		var i := FIELDS.find(k)
		var grew := float(last[i]) - float(first[i])
		if grew >= GROWTH[k]:
			out.append("OVERFLOW?  %s grew by %d over about %d s (%s -> %s)" % [k, grew, int((rows.size() - 1) * SAMPLE_EVERY), first[i], last[i]])
			found = true
	var worst := 0
	for r in rows:
		worst = maxi(worst, int(r[FIELDS.find("worst_ms")]))
	if worst >= 1000:
		out.append("FREEZE     one frame took %d ms: the main thread was blocked that long (a hang the OS or the driver gave up on)" % worst)
		found = true
	var vram := int(last[FIELDS.find("vram_mb")])
	if vram >= 6500:
		out.append("VRAM       %d MB of video memory in use at the end: close to a typical 8 GB card's limit" % vram)
		found = true
	if not found:
		out.append("Nothing grew or spiked in the snapshots: script memory, video memory and object counts were steady and no frame")
		out.append("stalled over a second. That points away from a leak and toward the graphics driver / engine itself (see the Windows")
		out.append("crash code below), or a single sudden event between two snapshots (%d s apart)." % int(SAMPLE_EVERY))
	return out

func _tail(path: String, count: int, width: int) -> PackedStringArray:
	var out: PackedStringArray = []
	if not FileAccess.file_exists(path):
		return out
	var lines := FileAccess.get_file_as_string(path).split("\n", false)
	for i in range(maxi(0, lines.size() - count), lines.size()):
		out.append(lines[i].left(width))
	return out

## Godot renames the last run's log when a new one starts: the newest godot*.log that is not godot.log
func _previous_log() -> String:
	var dir := DirAccess.open("user://logs")
	if dir == null:
		return ""
	var best := ""
	for n in dir.get_files():
		if n != "godot.log" and n.begins_with("godot") and n > best:
			best = n
	return "user://logs/" + best if best != "" else ""

## Windows keeps the crash it recorded (exception code, faulting module, offset) in the Application log. Asked in a
## separate process so the game does not wait for it; it appends to the report a few seconds after start.
func _append_windows_crash(report: String) -> void:
	if OS.get_name() != "Windows":
		return
	var script := "$e = Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1000} -MaxEvents 40 -ErrorAction SilentlyContinue | " \
		+ "Where-Object { $_.Message -match 'Godot' } | Select-Object -First 1; " \
		+ "$t = \"`n== Windows crash record (newest Godot entry)`n\"; " \
		+ "if ($e) { $m = $e.Message; $c = [regex]::Match($m, '0x[0-9a-fA-F]{8}').Value; " \
		+ "$k = switch ($c.ToLower()) { " \
		+ "'0xc0000005' {'access violation: the engine or driver touched memory it does not own'} " \
		+ "'0xc0000374' {'heap corruption: something wrote past the end of a buffer'} " \
		+ "'0xc000001d' {'illegal instruction'} '0xc00000fd' {'stack overflow'} " \
		+ "'0xe06d7363' {'unhandled C++ exception'} default {'see the code'} }; " \
		+ "$t += $e.TimeCreated.ToString() + \"`n\" + $m + \"`nMeaning of \" + $c + ': ' + $k } " \
		+ "else { $t += '(none: the process was closed or killed rather than crashing, e.g. a hang)' }; " \
		+ "Add-Content -Path '" + report + "' -Value $t -Encoding UTF8"
	OS.create_process("powershell", ["-NoProfile", "-WindowStyle", "Hidden", "-Command", script])
