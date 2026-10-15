extends Node
## Crash reports you can see (autoload: Crash, the FIRST autoload, so it hears every other one start up).
##
## A native crash (heap corruption, a lost GPU, a driver fault) takes Godot down without a word: no dialog, and
## in a release build the last lines it printed were still sitting in a buffer. So:
##
## 1. Everything the engine and the scripts print, warn or error (with the GDScript call stack, see
##    debug/settings/gdscript/always_track_call_stacks) goes through a Logger into user://crash/run_<pid>.log,
##    flushed after every line: whatever the run said last is on the disk when it dies. Stability.trace's
##    "[boot ...]" lines are the breadcrumbs that say which step it was on.
## 2. A watchdog (Windows, exported builds): crash_watchdog.ps1, a hidden PowerShell process that waits for this
##    one to end. If it ends without run_<pid>.clean, it reads the exit code (heap corruption, access violation,
##    GPU lost...), builds a report from the log and opens a window with it right away (copy, open the folder,
##    restart). A heartbeat file (run_<pid>.alive) lets it tell a freeze that was killed from a crash.
## 3. Next launch: a run that died with no watchdog window (PowerShell blocked, killed with it) gets the same
##    report as a window over the title screen.
##
## Both write user://crash_reports/crash_<time>_summary.txt (+ _log.txt, the whole log), next to Stability's own
## resource report. Editor runs log too but show nothing: stopping a run from the editor is not a crash.
## Testing: the debug console's `crash`, or launch with --crash-test=<seconds> (add --crash-quiet: no window).
## --crash-watchdog turns it all on outside an exported build; --no-crash-watchdog turns the watchdog off.

const DIR := "user://crash/"
const REPORT_DIR := "user://crash_reports/"
const WATCHDOG := "res://scripts/GameLogicEngine/crash_watchdog.ps1"
const HEARTBEAT := 5.0           # s between run_<pid>.alive writes
const STALE := 15.0              # s without a heartbeat: that run is not running any more
const LOG_CAP := 8 * 1024 * 1024 # bytes: past this the log starts over (an error spammed every frame)
const GPU_LOST := ["device was lost", "VK_ERROR_DEVICE_LOST", "DEVICE_REMOVED", "0x887a0005", "0x887a0006", "0x887a0007"]
const OUT_OF_MEMORY := ["out of memory", "ERR_OUT_OF_MEMORY", "Failed to allocate"]

## Everything the engine says, into one file, flushed line by line. Called on any thread.
class CrashLog extends Logger:
	const KINDS := ["ERROR", "WARNING", "SCRIPT ERROR", "SHADER ERROR"]
	var _f: FileAccess
	var _path := ""
	var _lock := Mutex.new()
	var _busy := false           # (Mutex is recursive: an error raised while writing comes straight back in)
	var _last := ""
	var _repeats := 0

	func open(path: String) -> void:
		_path = path
		_f = FileAccess.open(path, FileAccess.WRITE)

	func close() -> void:
		_lock.lock()
		if _f != null:
			_f.close()
		_f = null
		_lock.unlock()

	func _log_message(message: String, _error: bool) -> void:
		write(message.trim_suffix("\n"))

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool,
			error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
		var text := "%s [%.2fs]: %s" % [KINDS[clampi(error_type, 0, 3)], Time.get_ticks_msec() / 1000.0, rationale if rationale != "" else code]
		text += "\n   at: %s (%s:%d)" % [function, file, line]
		for bt in script_backtraces:
			if bt != null and not bt.is_empty():
				text += "\n" + bt.format(3, 3).trim_suffix("\n")
		write(text)

	func write(text: String) -> void:
		_lock.lock()
		if _busy or _f == null:
			_lock.unlock()
			return
		_busy = true
		if text == _last:
			_repeats += 1
			if _repeats in [10, 100, 1000, 10000, 100000]:
				_f.store_line("   (the line above repeated %d times so far)" % _repeats)
				_f.flush()
		else:
			if _repeats > 0:
				_f.store_line("   (the line above repeated %d times)" % _repeats)
			_repeats = 0
			_last = text
			_f.store_line(text)
			_f.flush()
			if _f.get_length() > LOG_CAP:
				_f.close()
				_f = FileAccess.open(_path, FileAccess.WRITE)
				if _f != null:
					_f.store_line("(the log passed %d MB and started over)" % (LOG_CAP / 1048576))
		_busy = false
		_lock.unlock()

var _on := false
var _log: CrashLog
var _base := ""                  # user://crash/run_<pid>
var _beat := 0.0
var _release := false            # an exported build (or --crash-watchdog): crashes get a window
var _quiet := false

func _init() -> void:
	var args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	_quiet = args.has("--crash-quiet")
	_release = OS.has_feature("template") or args.has("--crash-watchdog")
	# tool runs (--script, contact sheets, checks) are not the game
	if args.has("--script") or (DisplayServer.get_name() == "headless" and not args.has("--crash-watchdog")):
		return
	_on = true
	process_mode = Node.PROCESS_MODE_ALWAYS
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	_base = DIR + "run_%d" % OS.get_process_id()
	_pending = _collect_dead_runs()      # before this run's own files exist
	_log = CrashLog.new()
	_log.open(_base + ".log")
	OS.add_logger(_log)
	_write_info(args)
	_heartbeat()
	if OS.get_name() == "Windows" and _release and not args.has("--no-crash-watchdog"):
		_start_watchdog()

func _ready() -> void:
	if not _on:
		return
	for a in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if a.begins_with("--crash-test="):
			get_tree().create_timer(maxf(0.1, a.substr(13).to_float())).timeout.connect(test_crash)
	if not _pending.is_empty():
		_show_report.call_deferred(_pending)

func _process(dt: float) -> void:
	if not _on:
		return
	_beat += dt
	if _beat >= HEARTBEAT:
		_beat = 0.0
		_heartbeat()

## A clean exit: the watchdog sees run_<pid>.clean and goes quietly, the next launch finds nothing to report
func _exit_tree() -> void:
	if not _on:
		return
	_on = false
	_log.write("session end: clean exit after %.0f s" % (Time.get_ticks_msec() / 1000.0))
	OS.remove_logger(_log)
	_log.close()
	var f := FileAccess.open(_base + ".clean", FileAccess.WRITE)
	if f != null:
		f.store_string("clean")
		f.close()
	var last := ProjectSettings.globalize_path(DIR + "last_session.log")
	DirAccess.remove_absolute(last)
	DirAccess.rename_absolute(ProjectSettings.globalize_path(_base + ".log"), last)
	for ext in [".json", ".alive"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_base + ext))

## Debug console `crash`, --crash-test: take the game down on purpose, to see the report
func test_crash() -> void:
	push_error("crash test: crashing on purpose (debug console `crash` or --crash-test)")
	OS.crash("crash test")

# ---- this run ---------------------------------------------------------------------------------------------
func _write_info(args: PackedStringArray) -> void:
	var user_args := OS.get_cmdline_user_args()
	var launch := OS.get_cmdline_args()
	if not user_args.is_empty():
		launch = launch + PackedStringArray(["--"]) + user_args
	var info := {
		"pid": OS.get_process_id(),
		"exe": OS.get_executable_path(),
		"args": launch,
		"build": _build_tag(),
		"started": Time.get_datetime_string_from_system(false, true),
		"os": "%s %s" % [OS.get_name(), OS.get_version()],
		"cpu": "%s (%d threads)" % [OS.get_processor_name(), OS.get_processor_count()],
		"ram_mb": int(OS.get_memory_info().get("physical", 0) / 1048576.0),
		"gpu": "%s / %s (%s %s)" % [RenderingServer.get_video_adapter_vendor(), RenderingServer.get_video_adapter_name(),
			RenderingServer.get_current_rendering_driver_name(), RenderingServer.get_video_adapter_api_version()],
		"engine": Engine.get_version_info().get("string", ""),
	}
	var f := FileAccess.open(_base + ".json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(info, "  "))
		f.close()
	_log.write("session start %s // build %s // %s" % [info.started, info.build, info.engine])
	_log.write("PC: %s // %s // %d MB RAM // %s" % [info.os, info.cpu, info.ram_mb, info.gpu])
	_log.write("launch: %s %s" % [info.exe, " ".join(args)])

func _heartbeat() -> void:
	var f := FileAccess.open(_base + ".alive", FileAccess.WRITE)
	if f != null:
		f.store_string(str(int(Time.get_ticks_msec() / 1000.0)))

## The launcher writes the release tag next to the exe (net.gd _read_build_tag); from the editor there is none
static func _build_tag() -> String:
	var f := FileAccess.open(OS.get_executable_path().get_base_dir().path_join("version.txt"), FileAccess.READ)
	return f.get_as_text().strip_edges().left(24) if f != null else "DEV"

func _start_watchdog() -> void:
	var script := FileAccess.get_file_as_string(WATCHDOG)
	if script.is_empty():
		_log.write("crash watchdog: %s is missing from this build" % WATCHDOG)
		return
	var path := DIR + "crash_watchdog.ps1"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(script)
	f.close()
	var g := func(p: String) -> String: return ProjectSettings.globalize_path(p).trim_suffix("/")
	var args := PackedStringArray(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
		"-File", g.call(path), "-GamePid", str(OS.get_process_id()), "-Dir", g.call(DIR), "-Reports", g.call(REPORT_DIR),
		"-EngineLog", g.call(str(ProjectSettings.get_setting("debug/file_logging/log_path", "user://logs/godot.log")))])
	if _quiet:
		args.append("-NoWindow")
	var pid := OS.create_process("powershell.exe", args)
	_log.write("crash watchdog: " + ("watching (pid %d)" % pid if pid > 0 else "could not start PowerShell"))

# ---- the run before ---------------------------------------------------------------------------------------
var _pending := {}               # the newest run that died unreported: {report, summary} for the window

## Runs that left their files behind died. Each is archived to crash_reports/; the newest the watchdog did not
## already show is returned for the window. ({} in the editor, where stopping a run is how every run ends.)
func _collect_dead_runs() -> Dictionary:
	var dir := DirAccess.open(DIR)
	if dir == null:
		return {}
	var now := Time.get_unix_time_from_system()
	var newest := {}
	for n in dir.get_files():
		if n.ends_with(".clean") and now - FileAccess.get_modified_time(DIR + n) > STALE:
			dir.remove(n)                # a clean exit no watchdog picked up
		if not (n.begins_with("run_") and n.ends_with(".json")):
			continue
		var base := DIR + n.trim_suffix(".json")
		var beat := FileAccess.get_modified_time(base + ".alive")
		if beat > 0 and now - beat < STALE:
			continue                     # another copy of the game, still running
		var found := _archive(base, now)
		if not found.is_empty() and float(found.started) > float(newest.get("started", -1.0)):
			newest = found
	return newest

func _archive(base: String, now: float) -> Dictionary:
	var reported := FileAccess.file_exists(base + ".reported")
	var info = JSON.parse_string(FileAccess.get_file_as_string(base + ".json"))
	if not (info is Dictionary):
		info = {}
	var log_text := FileAccess.get_file_as_string(base + ".log")
	var report := FileAccess.get_file_as_string(base + ".report.txt")     # the watchdog's, with the exit code
	var out := {}
	if _release:
		var stamp := Time.get_datetime_string_from_system().replace(":", "-") + "_" + base.get_file().trim_prefix("run_")
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(REPORT_DIR))
		if report.is_empty():
			report = _build_report(info, log_text, int(FileAccess.get_file_as_string(base + ".alive").to_int()))
			var f := FileAccess.open(REPORT_DIR + "crash_%s_summary.txt" % stamp, FileAccess.WRITE)
			if f != null:
				f.store_string(report)
		var lf := FileAccess.open(REPORT_DIR + "crash_%s_log.txt" % stamp, FileAccess.WRITE)
		if lf != null:
			lf.store_string(log_text)
		if not reported:
			out = {"report": report, "summary": _summary(report), "started": FileAccess.get_modified_time(base + ".json")}
	for ext in [".json", ".log", ".alive", ".clean", ".reported", ".report.txt"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(base + ext))
	return out

## The same report the watchdog writes, minus what only it can know (the exit code, the moment it ended)
static func _build_report(info: Dictionary, log_text: String, ran: int) -> String:
	var lines := log_text.split("\n")
	var out := PackedStringArray()
	out.append("THE BACKROOMS: NULLSPACE - CRASH REPORT")
	out.append("The last session ended without shutting down (found when the game was started again).")
	out.append("")
	out.append("Started:      %s   (ran for about %d s)" % [info.get("started", "?"), ran])
	out.append("Build:        %s   engine %s" % [info.get("build", "?"), info.get("engine", "?")])
	out.append("PC:           %s // %s // %s MB RAM" % [info.get("os", "?"), info.get("cpu", "?"), str(info.get("ram_mb", "?"))])
	out.append("GPU:          %s" % info.get("gpu", "?"))
	out.append("Exit code:    unknown (no watchdog was running)")
	out.append("Verdict:      " + _verdict(log_text))
	out.append("Last step:    " + _last_step(lines))
	out.append("")
	out.append("== Errors and warnings (newest last)")
	var errs := _error_blocks(lines, 15)
	out.append_array(errs if not errs.is_empty() else PackedStringArray(["(none)"]))
	out.append("")
	out.append("== The end of the game's log")
	out.append_array(lines.slice(maxi(0, lines.size() - 80)))
	return "\n".join(out)

static func _verdict(log_text: String) -> String:
	for k in GPU_LOST:
		if log_text.containsn(k):
			return "the graphics card / driver stopped responding (GPU lost): update the graphics driver, try a lower preset"
	for k in OUT_OF_MEMORY:
		if log_text.containsn(k):
			return "the game ran out of memory"
	return "a crash inside the engine or a driver (see the last step and the errors before it)"

static func _last_step(lines: PackedStringArray) -> String:
	for i in range(lines.size() - 1, -1, -1):
		if lines[i].begins_with("[boot "):
			return lines[i]
	return "(no step recorded: it died while starting up)"

## The last `count` errors / warnings, each with its "at:" line and call stack
static func _error_blocks(lines: PackedStringArray, count: int) -> PackedStringArray:
	var blocks: Array[PackedStringArray] = []
	var cur := PackedStringArray()
	var inside := false
	for l in lines:
		if l.begins_with("ERROR") or l.begins_with("WARNING") or l.begins_with("SCRIPT ERROR") or l.begins_with("SHADER ERROR"):
			if inside:
				blocks.append(cur)
			cur = PackedStringArray([l])
			inside = true
		elif inside and (l.begins_with(" ") or l.begins_with("\t")):
			cur.append(l)
		elif inside:
			blocks.append(cur)
			inside = false
	if inside:
		blocks.append(cur)
	var out := PackedStringArray()
	for b in blocks.slice(maxi(0, blocks.size() - count)):
		out.append_array(b)
	return out

## The report's three headline lines (the watchdog's report has them too)
static func _summary(report: String) -> String:
	var out := PackedStringArray()
	for l in report.split("\n"):
		for k in ["Exit code:", "Verdict:", "Last step:"]:
			if l.begins_with(k):
				out.append(k + " " + l.substr(k.length()).strip_edges())
	return "\n".join(out)

# ---- the window -------------------------------------------------------------------------------------------
func _show_report(found: Dictionary) -> void:
	await get_tree().create_timer(1.0).timeout      # over the title screen, once it is up
	var dlg := AcceptDialog.new()
	dlg.title = "The game crashed last time"
	dlg.ok_button_text = "Close"
	dlg.process_mode = Node.PROCESS_MODE_ALWAYS
	dlg.always_on_top = true
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	var head := Label.new()
	head.text = "The last session crashed. This is what it was doing; the report is saved in the crash folder.\n" + str(found.summary)
	head.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head.custom_minimum_size.x = 900.0
	box.add_child(head)
	var text := TextEdit.new()
	text.text = str(found.report)
	text.editable = false
	text.custom_minimum_size = Vector2(900, 440)
	text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["Consolas", "Cascadia Mono", "Courier New", "monospace"])
	text.add_theme_font_override("font", mono)
	text.add_theme_font_size_override("font_size", 14)
	box.add_child(text)
	dlg.add_child(box)
	dlg.add_button("Copy report", true, "copy")
	dlg.add_button("Open crash folder", true, "folder")
	dlg.custom_action.connect(func(action: StringName) -> void:
		if action == &"copy":
			DisplayServer.clipboard_set(str(found.report))
		elif action == &"folder":
			OS.shell_open(ProjectSettings.globalize_path(REPORT_DIR)))
	dlg.confirmed.connect(dlg.queue_free)
	dlg.canceled.connect(dlg.queue_free)
	get_tree().root.add_child(dlg)
	dlg.popup_centered(Vector2i(960, 640))
