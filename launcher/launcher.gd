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
var http_notes: HTTPRequest
var status: Label
var version_label: Label
var notes_box: RichTextLabel
var bar: ProgressBar
var play_btn: Button
var check_btn: Button
var name_edit: LineEdit
var addr_edit: LineEdit
var config := ConfigFile.new()
var bg: TextureRect
var rec_dot: Label
var status_dot: ColorRect
var notes_panel: PanelContainer
var notes_title: Label
var notes_btn: Button
var pct_label: Label
var asset_size := 0        # bytes, from the release data (the CDN often omits Content-Length)
var _t := 0.0
var _check_timer := 0.0
var _silent_check := false   # true while a background poll is in flight (no UI disruption)
const CHECK_INTERVAL := 60.0  # poll for updates every minute so new releases show up fast

const BG_PATH := "res://img/background.png"
const GREEN := Color("7fae72")

# Palette and font match the game's menu (scripts/menu.gd / ui.gd)
const CREAM := Color("e6e1cd")
const TITLE := Color("d8d3bd")
const RED := Color("c4271f")
const REC_RED := Color("ff3b30")
const AMBER := Color("ffc107")
const INK := Color(0.9, 0.882, 0.804)   # cream at varying alpha
var font: FontFile = load("res://fonts/vcr.ttf")
var title_font: FontFile = load("res://fonts/archivo_title.ttf")   # heavy condensed grotesque, only for the title


func _ready() -> void:
	config.load(CONFIG_PATH)
	_build_ui()
	# fade in, and let the picture drift slowly like a held camera
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, 0.7).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	bg.pivot_offset = get_viewport_rect().size / 2.0
	var drift := create_tween().set_loops()
	drift.tween_property(bg, "scale", Vector2.ONE * 1.06, 16.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	drift.tween_property(bg, "scale", Vector2.ONE, 16.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	http_check = HTTPRequest.new()
	add_child(http_check)
	http_check.max_redirects = 0
	http_check.request_completed.connect(_on_check_done)
	http_notes = HTTPRequest.new()
	add_child(http_notes)
	http_notes.request_completed.connect(_on_notes_done)
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

func check_for_update(silent := false) -> void:
	# github.com/<repo>/releases/latest redirects to .../releases/tag/<tag>: the tag comes from that
	# redirect, which (unlike api.github.com, 60 requests/hour per IP) has no rate limit.
	_check_timer = 0.0
	if http_check.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		return  # a check is already in flight; don't stack requests
	_silent_check = silent
	if not silent:
		_set_state(State.CHECKING)
	var err := http_check.request("https://github.com/%s/releases/latest" % REPO,
		PackedStringArray(["User-Agent: backrooms-launcher", "Cache-Control: no-cache, no-store", "Pragma: no-cache"]))
	if err != OK and not silent:
		_go_offline("Could not start the update check.")


func _on_check_done(result: int, code: int, headers: PackedStringArray, _body: PackedByteArray) -> void:
	var silent := _silent_check
	_silent_check = false
	# max_redirects = 0, so the 302 we are after is reported as "redirect limit reached"
	if result != HTTPRequest.RESULT_SUCCESS and result != HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED:
		if not silent:
			_go_offline("Update check failed: no connection.")
		return  # background poll failed quietly: keep whatever state we were in and retry next tick
	var tag := ""
	for h in headers:
		if h.to_lower().begins_with("location:"):
			var loc := h.substr(9).strip_edges()
			if "/releases/tag/" in loc:
				tag = loc.get_slice("/releases/tag/", 1).uri_decode()
	if tag == "":
		if not silent:
			_go_offline("Update check failed: no release published yet." if code == 302 or code == 404 else "Update check failed: GitHub returned %d." % code)
		return
	if silent and tag == remote_version:
		return  # nothing changed: don't touch the UI at all
	remote_version = tag
	asset_url = "https://github.com/%s/releases/download/%s/%s" % [REPO, tag, ASSET_NAME]
	notes = ""
	asset_size = 0
	notes_box.text = ""
	notes_btn.visible = false
	_set_state(State.UPDATE if local_version != remote_version else State.READY)
	# release notes + exact file size: nice to have, so a rate-limited API only costs the notes
	http_notes.request("https://api.github.com/repos/%s/releases/tags/%s" % [REPO, tag.uri_encode()],
		PackedStringArray(["User-Agent: backrooms-launcher", "Accept: application/vnd.github+json"]))


func _on_notes_done(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		return
	var data = JSON.parse_string(body.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY or str(data.get("tag_name", "")) != remote_version:
		return
	notes = str(data.get("body", ""))
	for a in data.get("assets", []):
		if a.get("name", "") == ASSET_NAME:
			asset_size = int(a.get("size", 0))
	notes_box.text = notes
	notes_btn.visible = notes != ""
	if state == State.UPDATE and notes != "":
		notes_panel.visible = true


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
	var busy := s == State.DOWNLOADING or s == State.INSTALLING
	bar.get_parent().modulate.a = 1.0 if busy else 0.0       # invisible, not hidden: no layout jump
	if s == State.INSTALLING:
		bar.value = 100.0
		pct_label.text = "100%"
	elif s != State.DOWNLOADING:
		bar.value = 0.0
		pct_label.text = ""
	_style_play(s == State.UPDATE)
	status_dot.color = {
		State.CHECKING: Color(INK, 0.6), State.READY: GREEN, State.UPDATE: AMBER,
		State.DOWNLOADING: AMBER, State.INSTALLING: AMBER, State.OFFLINE: REC_RED}[s]
	if s == State.UPDATE and notes != "":
		notes_panel.visible = true                            # show what's new when an update waits
	notes_title.text = "WHAT'S NEW  //  %s" % remote_version if remote_version != "" else "WHAT'S NEW"
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


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN and state != State.CHECKING \
			and state != State.DOWNLOADING and state != State.INSTALLING:
		check_for_update(true)


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and (e.keycode == KEY_ENTER or e.keycode == KEY_KP_ENTER) and not play_btn.disabled:
		_on_play_pressed()


func _process(dt: float) -> void:
	_t += dt
	rec_dot.modulate.a = 1.0 if fmod(_t, 1.1) < 0.55 else 0.0      # REC light blinks like the game's
	if state == State.DOWNLOADING:
		var total := http_dl.get_body_size()
		if total <= 0:
			total = asset_size
		var got := http_dl.get_downloaded_bytes()
		var frac := clampf(float(got) / total, 0.0, 1.0) if total > 0 else 0.0
		bar.value = frac * 100.0
		pct_label.text = "%d%%" % int(frac * 100.0) if total > 0 else "..."
		if total > 0:
			status.text = "Downloading %s   %.1f / %.1f MB" % [remote_version, got / 1048576.0, total / 1048576.0]
		else:
			status.text = "Downloading %s   %.1f MB" % [remote_version, got / 1048576.0]
	elif _game_pid > 0 and not _game_running():
		_game_pid = -1
		if state != State.CHECKING:
			status.text = "Up to date." if state == State.READY else status.text
	# Poll for updates in the background: silent, so it never interrupts the player.
	if state != State.CHECKING and state != State.DOWNLOADING and state != State.INSTALLING:
		_check_timer += dt
		if _check_timer >= CHECK_INTERVAL:
			check_for_update(true)


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


func _full(c: Control) -> Control:
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	return c


# Vertical gradient texture (top -> bottom) stretched over a rect
func _fade(colors: PackedColorArray, offsets: PackedFloat32Array) -> TextureRect:
	var g := Gradient.new()
	g.offsets = offsets
	g.colors = colors
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.width = 4
	gt.height = 256
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(0, 1)
	var tr := TextureRect.new()
	tr.texture = gt
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr


func _btn_box(fill: Color, border: Color) -> StyleBoxFlat:
	var sb := _box(fill, border, Vector4(1, 1, 1, 1))
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	return sb


# The big action button: outlined normally, filled red when an update/install is waiting
func _style_play(hot: bool) -> void:
	var fill := Color(RED, 0.9) if hot else Color(0, 0, 0, 0.35)
	var border := RED if hot else Color(INK, 0.55)
	play_btn.add_theme_stylebox_override("normal", _btn_box(fill, border))
	play_btn.add_theme_stylebox_override("hover", _btn_box(Color(RED, 0.95), Color("e0453b")))
	play_btn.add_theme_stylebox_override("pressed", _btn_box(Color("8f1c16"), RED))
	play_btn.add_theme_stylebox_override("disabled", _btn_box(Color(0, 0, 0, 0.25), Color(INK, 0.12)))


func _spacer_w(w: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size.x = w
	return c


# Minimise / close square in the title bar; the close one goes red on hover
func _win_button(text: String, close: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.custom_minimum_size = Vector2(34, 26)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.add_theme_font_override("font", _font(0))
	b.add_theme_font_size_override("font_size", 14)
	b.add_theme_color_override("font_color", Color(INK, 0.65))
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	var hover := _box(Color(RED, 0.9) if close else Color(INK, 0.14))
	b.add_theme_stylebox_override("normal", _box(Color(0, 0, 0, 0)))
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", _box(Color("8f1c16") if close else Color(INK, 0.22)))
	return b


func _build_ui() -> void:
	var black := ColorRect.new()
	black.color = Color(0.012, 0.012, 0.008)
	add_child(_full(black))

	# The frame is very dark, so lift it a little; it drifts slowly like a held camera
	bg = TextureRect.new()
	if ResourceLoader.exists(BG_PATH):
		bg.texture = load(BG_PATH)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.modulate = Color(1.8, 1.7, 1.5)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_full(bg))

	# top veil so the HUD text stays readable over the picture
	var top := _fade(PackedColorArray([Color(0.012, 0.012, 0.008, 0.75), Color(0.012, 0.012, 0.008, 0.0)]), PackedFloat32Array([0.0, 1.0]))
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top.offset_bottom = 110
	add_child(top)

	# bottom strip: the picture fades to near-black behind the controls
	var strip := _fade(PackedColorArray([
		Color(0.012, 0.012, 0.008, 0.0), Color(0.012, 0.012, 0.008, 0.72), Color(0.012, 0.012, 0.008, 0.96)]),
		PackedFloat32Array([0.0, 0.42, 1.0]))
	strip.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	strip.offset_top = -318
	strip.offset_bottom = 0
	add_child(strip)

	# --- custom title bar: drag anywhere along the top to move the window ---
	var drag := Control.new()
	drag.set_anchors_preset(Control.PRESET_TOP_WIDE)
	drag.offset_bottom = 52
	drag.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			DisplayServer.window_start_drag())
	add_child(drag)

	# --- top HUD: REC tag on the left, versions on the right ---
	var hud := MarginContainer.new()
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_theme_constant_override("margin_left", 40)
	hud.add_theme_constant_override("margin_right", 40)
	hud.add_theme_constant_override("margin_top", 26)
	add_child(_full(hud))
	var hud_row := HBoxContainer.new()
	hud_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_row.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	hud_row.add_theme_constant_override("separation", 10)
	hud.add_child(hud_row)
	rec_dot = _label("●", 12, REC_RED)
	hud_row.add_child(rec_dot)
	hud_row.add_child(_label("ARCHIVAL FOOTAGE // LEVEL 0", 12, Color(INK, 0.6), 4))
	var hud_gap := Control.new()
	hud_gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hud_row.add_child(hud_gap)
	version_label = _label("", 12, Color(INK, 0.55), 3)
	hud_row.add_child(version_label)
	hud_row.add_child(_spacer_w(18))
	var min_btn := _win_button("_", false)
	min_btn.pressed.connect(func(): DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED))
	hud_row.add_child(min_btn)
	var close_btn := _win_button("X", true)
	close_btn.pressed.connect(func(): get_tree().quit())
	hud_row.add_child(close_btn)

	# --- release notes card (hidden until asked for, or an update is waiting) ---
	notes_panel = PanelContainer.new()
	notes_panel.visible = false
	notes_panel.anchor_left = 1.0
	notes_panel.anchor_right = 1.0
	notes_panel.anchor_top = 0.0
	notes_panel.anchor_bottom = 1.0
	notes_panel.offset_left = -400
	notes_panel.offset_right = -40
	notes_panel.offset_top = 70
	notes_panel.offset_bottom = -330
	var card := _box(Color(0.02, 0.02, 0.015, 0.84), RED, Vector4(2, 0, 0, 0))
	card.content_margin_left = 20
	card.content_margin_right = 18
	card.content_margin_top = 14
	card.content_margin_bottom = 14
	notes_panel.add_theme_stylebox_override("panel", card)
	add_child(notes_panel)
	var card_box := VBoxContainer.new()
	card_box.add_theme_constant_override("separation", 8)
	notes_panel.add_child(card_box)
	notes_title = _label("WHAT'S NEW", 12, Color(INK, 0.55), 4)
	card_box.add_child(notes_title)
	notes_box = RichTextLabel.new()
	notes_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	notes_box.add_theme_font_override("normal_font", _font(1))
	notes_box.add_theme_font_size_override("normal_font_size", 14)
	notes_box.add_theme_color_override("default_color", Color(INK, 0.78))
	card_box.add_child(notes_box)

	# --- controls, sitting in the strip ---
	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", 48)
	margin.add_theme_constant_override("margin_right", 48)
	margin.add_theme_constant_override("margin_top", 96)
	margin.add_theme_constant_override("margin_bottom", 30)
	strip.add_child(_full(margin))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	box.alignment = BoxContainer.ALIGNMENT_END
	margin.add_child(box)

	# same face and trim as the game's title (scripts/UI/menu/menu_widgets.gd _title_font)
	var title := _label("THE BACKROOMS", 76, TITLE)
	var tf := FontVariation.new()
	tf.base_font = title_font
	tf.spacing_glyph = -1
	tf.spacing_space = 5
	tf.set_spacing(TextServer.SPACING_TOP, -8)
	tf.set_spacing(TextServer.SPACING_BOTTOM, -9)
	title.add_theme_font_override("font", tf)
	title.add_theme_color_override("font_shadow_color", Color(0.627, 0.078, 0.059, 0.4))
	title.add_theme_constant_override("shadow_offset_x", 2)
	box.add_child(title)

	# status line: coloured dot + text, "what's new" on the right
	var st_row := HBoxContainer.new()
	st_row.add_theme_constant_override("separation", 10)
	box.add_child(st_row)
	var dot_c := CenterContainer.new()
	status_dot = ColorRect.new()
	status_dot.custom_minimum_size = Vector2(8, 8)
	status_dot.color = AMBER
	dot_c.add_child(status_dot)
	st_row.add_child(dot_c)
	status = _label("", 13, Color(INK, 0.85), 2)
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.clip_text = true
	status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	st_row.add_child(status)
	notes_btn = _link_button("what's new")
	notes_btn.visible = false
	notes_btn.pressed.connect(func(): notes_panel.visible = not notes_panel.visible)
	st_row.add_child(notes_btn)

	# download progress: thick bar + percentage (transparent until a download starts)
	var bar_row := HBoxContainer.new()
	bar_row.add_theme_constant_override("separation", 14)
	bar_row.modulate.a = 0.0
	box.add_child(bar_row)
	bar = ProgressBar.new()
	bar.show_percentage = false
	bar.max_value = 100.0
	bar.custom_minimum_size.y = 12
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.add_theme_stylebox_override("background", _box(Color(INK, 0.1), Color(INK, 0.25), Vector4(1, 1, 1, 1)))
	bar.add_theme_stylebox_override("fill", _box(AMBER))
	bar_row.add_child(bar)
	pct_label = _label("", 13, AMBER, 2)
	pct_label.custom_minimum_size.x = 48
	pct_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bar_row.add_child(pct_label)

	var mp := HBoxContainer.new()
	mp.add_theme_constant_override("separation", 14)
	box.add_child(mp)
	mp.add_child(_label("CALLSIGN", 12, Color(INK, 0.5), 3))
	name_edit = _line_edit("UNKNOWN", str(config.get_value("player", "name", "")))
	name_edit.custom_minimum_size.x = 170
	name_edit.max_length = 16
	name_edit.text_submitted.connect(func(_s): name_edit.release_focus())
	mp.add_child(name_edit)
	mp.add_child(_label("JOIN", 12, Color(INK, 0.5), 3))
	addr_edit = _line_edit("PASTE THE HOST'S LINK (OPTIONAL)", str(config.get_value("player", "join", "")))
	addr_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	addr_edit.text_submitted.connect(func(_s): addr_edit.release_focus())
	mp.add_child(addr_edit)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 30)
	box.add_child(row)
	play_btn = Button.new()
	play_btn.focus_mode = Control.FOCUS_NONE
	play_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	play_btn.custom_minimum_size = Vector2(280, 52)
	play_btn.add_theme_font_override("font", _font(6))
	play_btn.add_theme_font_size_override("font_size", 18)
	play_btn.add_theme_color_override("font_color", CREAM)
	play_btn.add_theme_color_override("font_hover_color", Color.WHITE)
	play_btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	play_btn.add_theme_color_override("font_disabled_color", Color(INK, 0.3))
	_style_play(false)
	play_btn.pressed.connect(_on_play_pressed)
	row.add_child(play_btn)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(gap)
	check_btn = _link_button("Check for updates")
	check_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	check_btn.pressed.connect(check_for_update)
	row.add_child(check_btn)

	var frame := Panel.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_theme_stylebox_override("panel", _box(Color(0, 0, 0, 0), Color(INK, 0.18), Vector4(1, 1, 1, 1)))
	add_child(_full(frame))
