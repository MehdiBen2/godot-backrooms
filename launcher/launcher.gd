extends Control
## Backrooms launcher: checks GitHub Releases for a newer build, downloads and
## unpacks it next to the launcher, then starts the game.
##
## Layout on disk (release build):
##   launcher.exe
##   game/backrooms.exe, backrooms.pck, version.txt
## Each release must carry a zip asset named ASSET_NAME with the exported game at its root.

const REPO := "MehdiBen2/godot-backrooms"
const ASSET_NAME := "backrooms-windows.zip"
const GAME_EXE := "backrooms.exe"
const CONFIG_PATH := "user://launcher.cfg"

enum State { CHECKING, READY, UPDATE, DOWNLOADING, INSTALLING, OFFLINE }

var state := State.CHECKING
var local_version := ""
var remote_version := ""
var asset_url := ""
var notes := ""

var http_check: HTTPRequest
var http_dl: HTTPRequest
var status: Label
var version_label: Label
var notes_box: RichTextLabel
var bar: ProgressBar
var play_btn: Button
var check_btn: Button
var name_edit: LineEdit
var addr_edit: LineEdit
var config := ConfigFile.new()

# Palette and font match the game's menu (scripts/menu.gd / ui.gd)
const CREAM := Color("e6e1cd")
const TITLE := Color("d8d3bd")
const RED := Color("c4271f")
const REC_RED := Color("ff3b30")
const AMBER := Color("ffc107")
const INK := Color(0.9, 0.882, 0.804)   # cream at varying alpha
var font: FontFile = load("res://fonts/vcr.ttf")


func _ready() -> void:
	config.load(CONFIG_PATH)
	_build_ui()
	http_check = HTTPRequest.new()
	add_child(http_check)
	http_check.request_completed.connect(_on_check_done)
	http_dl = HTTPRequest.new()
	add_child(http_dl)
	http_dl.request_completed.connect(_on_download_done)
	local_version = _read_local_version()
	check_for_update()


# ------------------------------------------------------------------ paths

func install_dir() -> String:
	# In the editor, install beside the project so the launcher can be tested safely.
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://").path_join("_dev_install")
	return OS.get_executable_path().get_base_dir().path_join("game")


func game_exe() -> String:
	return install_dir().path_join(GAME_EXE)


func _read_local_version() -> String:
	var f := FileAccess.open(install_dir().path_join("version.txt"), FileAccess.READ)
	if f == null or not FileAccess.file_exists(game_exe()):
		return ""
	return f.get_as_text().strip_edges()


# ------------------------------------------------------------------ update check

func check_for_update() -> void:
	_set_state(State.CHECKING)
	var headers := PackedStringArray(["User-Agent: backrooms-launcher", "Accept: application/vnd.github+json"])
	var err := http_check.request("https://api.github.com/repos/%s/releases/latest" % REPO, headers)
	if err != OK:
		_go_offline("Could not start the update check.")


func _on_check_done(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		var why := "no connection" if result != HTTPRequest.RESULT_SUCCESS else "GitHub returned %d (no release yet, or repo is private)" % code
		_go_offline("Update check failed: %s." % why)
		return
	var data = JSON.parse_string(body.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		_go_offline("Update check returned bad data.")
		return
	remote_version = str(data.get("tag_name", ""))
	notes = str(data.get("body", ""))
	asset_url = ""
	for a in data.get("assets", []):
		if a.get("name", "") == ASSET_NAME:
			asset_url = a.get("browser_download_url", "")
	if asset_url == "":
		_go_offline("Latest release has no %s asset." % ASSET_NAME)
		return
	notes_box.text = notes if notes != "" else "(no release notes)"
	if local_version != remote_version:
		_set_state(State.UPDATE)
	else:
		_set_state(State.READY)


func _go_offline(msg: String) -> void:
	_set_state(State.OFFLINE)
	status.text = msg + (" You can still play the installed version." if local_version != "" else "")


# ------------------------------------------------------------------ download + install

func start_download() -> void:
	if _game_running():
		status.text = "Close the game before updating."
		return
	DirAccess.make_dir_recursive_absolute(install_dir())
	http_dl.download_file = install_dir().path_join("update.zip.part")
	http_dl.max_redirects = 8
	var err := http_dl.request(asset_url, PackedStringArray(["User-Agent: backrooms-launcher"]))
	if err != OK:
		_go_offline("Could not start the download.")
		return
	_set_state(State.DOWNLOADING)


func _on_download_done(result: int, code: int, _h: PackedStringArray, _b: PackedByteArray) -> void:
	var part := install_dir().path_join("update.zip.part")
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		DirAccess.remove_absolute(part)
		_go_offline("Download failed (result %d, HTTP %d)." % [result, code])
		return
	_set_state(State.INSTALLING)
	await get_tree().process_frame
	var zip_path := install_dir().path_join("update.zip")
	DirAccess.rename_absolute(part, zip_path)
	var ok := _unpack(zip_path)
	DirAccess.remove_absolute(zip_path)
	if not ok:
		_go_offline("Install failed: the update archive is invalid.")
		return
	var f := FileAccess.open(install_dir().path_join("version.txt"), FileAccess.WRITE)
	f.store_string(remote_version)
	f.close()
	local_version = remote_version
	_set_state(State.READY)


func _unpack(zip_path: String) -> bool:
	var zip := ZIPReader.new()
	if zip.open(zip_path) != OK:
		return false
	var found_exe := false
	for entry in zip.get_files():
		if entry.ends_with("/"):
			continue
		# Refuse paths that would escape the install folder.
		if entry.begins_with("/") or ".." in entry.split("/"):
			continue
		var dest := install_dir().path_join(entry)
		DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
		var f := FileAccess.open(dest, FileAccess.WRITE)
		if f == null:
			zip.close()
			return false
		f.store_buffer(zip.read_file(entry))
		f.close()
		if entry == GAME_EXE:
			found_exe = true
	zip.close()
	return found_exe


# ------------------------------------------------------------------ launching

var _game_pid := -1


func _game_running() -> bool:
	return _game_pid > 0 and OS.is_process_running(_game_pid)


func launch_game() -> void:
	if not FileAccess.file_exists(game_exe()):
		status.text = "Game is not installed yet."
		return
	_save_config()
	var args := PackedStringArray()
	# Multiplayer hooks: the game will read these once networking is ported.
	if name_edit.text.strip_edges() != "":
		args.append("--player-name=" + name_edit.text.strip_edges())
	if addr_edit.text.strip_edges() != "":
		args.append("--join=" + addr_edit.text.strip_edges())
	_game_pid = OS.create_process(game_exe(), args)
	if _game_pid <= 0:
		status.text = "Failed to start the game."
		return
	status.text = "Game running..."


func _save_config() -> void:
	config.set_value("player", "name", name_edit.text)
	config.set_value("player", "join", addr_edit.text)
	config.save(CONFIG_PATH)


# ------------------------------------------------------------------ UI

func _set_state(s: State) -> void:
	state = s
	bar.visible = s == State.DOWNLOADING or s == State.INSTALLING
	play_btn.disabled = false
	check_btn.disabled = s == State.CHECKING or s == State.DOWNLOADING or s == State.INSTALLING
	version_label.text = "Installed: %s    Latest: %s" % [
		local_version if local_version != "" else "none",
		remote_version if remote_version != "" else "?"]
	match s:
		State.CHECKING:
			status.text = "Checking for updates..."
			play_btn.text = ("Please wait").to_upper()
			play_btn.disabled = true
		State.UPDATE:
			status.text = "A new version is available."
			play_btn.text = ("Update" if local_version != "" else "Install").to_upper()
		State.READY:
			status.text = "Up to date."
			play_btn.text = ("Play").to_upper()
		State.DOWNLOADING:
			status.text = "Downloading %s..." % remote_version
			play_btn.text = ("Downloading").to_upper()
			play_btn.disabled = true
		State.INSTALLING:
			status.text = "Installing..."
			play_btn.text = ("Installing").to_upper()
			play_btn.disabled = true
		State.OFFLINE:
			play_btn.text = ("Play" if local_version != "" else "Retry").to_upper()


func _process(_dt: float) -> void:
	if state == State.DOWNLOADING:
		var total := http_dl.get_body_size()
		var got := http_dl.get_downloaded_bytes()
		bar.value = 100.0 * got / total if total > 0 else 0.0
		status.text = "Downloading %s... %.1f MB" % [remote_version, got / 1048576.0]
	elif _game_pid > 0 and not _game_running():
		_game_pid = -1
		if state != State.CHECKING:
			status.text = "Up to date." if state == State.READY else status.text


func _on_play_pressed() -> void:
	match state:
		State.UPDATE:
			start_download()
		State.READY:
			launch_game()
		State.OFFLINE:
			if local_version != "":
				launch_game()
			else:
				check_for_update()


# ---- style helpers (same look as the game menu) -----------------------------

func _font(spacing: float) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = font
	fv.spacing_glyph = int(spacing)
	return fv


func _label(text: String, size: int, color: Color, spacing := 0.0) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _font(spacing))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("shadow_offset_y", 1)
	return l


func _box(fill: Color, border := Color(0, 0, 0, 0), bw := Vector4.ZERO) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = border
	sb.border_width_left = int(bw.x)
	sb.border_width_top = int(bw.y)
	sb.border_width_right = int(bw.z)
	sb.border_width_bottom = int(bw.w)
	return sb


func _underline(color: Color) -> StyleBoxFlat:
	var sb := _box(Color(0, 0, 0, 0), color, Vector4(0, 0, 0, 1))
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb


func _link_button(text: String, size := 12) -> Button:
	var b := Button.new()
	b.text = text.to_upper()
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.add_theme_font_override("font", _font(3))
	b.add_theme_font_size_override("font_size", size)
	b.add_theme_color_override("font_color", Color(INK, 0.7))
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_hover_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_disabled_color", Color(INK, 0.25))
	b.add_theme_stylebox_override("normal", _underline(Color(INK, 0.25)))
	b.add_theme_stylebox_override("hover", _underline(RED))
	b.add_theme_stylebox_override("pressed", _underline(RED))
	b.add_theme_stylebox_override("hover_pressed", _underline(RED))
	b.add_theme_stylebox_override("disabled", _underline(Color(INK, 0.1)))
	return b


func _line_edit(placeholder: String, text: String) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.text = text
	e.add_theme_font_override("font", _font(2))
	e.add_theme_font_size_override("font_size", 14)
	e.add_theme_color_override("font_color", CREAM)
	e.add_theme_color_override("font_placeholder_color", Color(INK, 0.25))
	e.add_theme_color_override("caret_color", CREAM)
	e.add_theme_stylebox_override("normal", _underline(Color(INK, 0.3)))
	e.add_theme_stylebox_override("focus", _underline(RED))
	return e


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.012, 0.012, 0.008)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 36
	box.offset_right = -36
	box.offset_top = 26
	box.offset_bottom = -26
	box.add_theme_constant_override("separation", 12)
	add_child(box)

	# camera-OSD header: red REC dot + tag, like the in-game HUD
	var tag := HBoxContainer.new()
	tag.add_theme_constant_override("separation", 8)
	box.add_child(tag)
	tag.add_child(_label("●", 12, REC_RED))
	tag.add_child(_label("ARCHIVAL FOOTAGE // LEVEL 0", 12, Color(INK, 0.55), 4))

	var title := _label("THE BACKROOMS", 34, TITLE, 6)
	title.add_theme_color_override("font_shadow_color", Color(0.627, 0.078, 0.059, 0.55))
	title.add_theme_constant_override("shadow_offset_x", 2)
	box.add_child(title)

	version_label = _label("", 12, Color(INK, 0.5), 3)
	box.add_child(version_label)
	box.add_child(_rule())

	notes_box = RichTextLabel.new()
	notes_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	notes_box.custom_minimum_size.y = 90
	notes_box.add_theme_font_override("normal_font", _font(1))
	notes_box.add_theme_font_size_override("normal_font_size", 14)
	notes_box.add_theme_color_override("default_color", Color(INK, 0.6))
	box.add_child(notes_box)

	var mp := HBoxContainer.new()
	mp.add_theme_constant_override("separation", 14)
	box.add_child(mp)
	mp.add_child(_label("CALLSIGN", 12, Color(INK, 0.5), 3))
	name_edit = _line_edit("UNKNOWN", str(config.get_value("player", "name", "")))
	name_edit.custom_minimum_size.x = 150
	mp.add_child(name_edit)
	mp.add_child(_label("JOIN", 12, Color(INK, 0.5), 3))
	addr_edit = _line_edit("HOST:PORT (OPTIONAL)", str(config.get_value("player", "join", "")))
	addr_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mp.add_child(addr_edit)

	bar = ProgressBar.new()
	bar.visible = false
	bar.show_percentage = false
	bar.custom_minimum_size.y = 3
	bar.add_theme_stylebox_override("background", _box(Color(INK, 0.12)))
	bar.add_theme_stylebox_override("fill", _box(AMBER))
	box.add_child(bar)

	status = _label("", 12, Color(INK, 0.75), 2)
	box.add_child(status)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 26)
	box.add_child(row)
	play_btn = _link_button("Play", 16)
	play_btn.custom_minimum_size.x = 170
	play_btn.pressed.connect(_on_play_pressed)
	row.add_child(play_btn)
	check_btn = _link_button("Check for updates")
	check_btn.pressed.connect(check_for_update)
	row.add_child(check_btn)


func _rule() -> ColorRect:
	var r := ColorRect.new()
	r.color = Color(INK, 0.12)
	r.custom_minimum_size.y = 1
	return r
