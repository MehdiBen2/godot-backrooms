extends CanvasLayer
## Camcorder HUD + pause menu, replicating the web game's #hud (backrooms.html / style.css):
## REC block + objective (top-left), level / timecode / tape mode (top-right), four meters
## (bottom-left), key hints (bottom-right), viewfinder corner brackets and the crosshair dot.
## Designed for a 1920x1080 canvas so pixel sizes match the browser.

const SCALE := 1.15                       # --hud-scale in the web CSS
const CREAM := Color("e4e1c6")            # camera OSD off-white
const TAPE := Color("c9bea0")
const HINT := Color("9c9268")
const HINT_STRONG := Color("ded6ad")
const METER_LABEL := Color("b5a975")
const METER_VAL := Color("ded6ad")
const REC_RED := Color("ff3b30")
const AMBER := Color("ffc107")
const DIM := Color(0.9, 0.88, 0.8, 0.55)

var font: FontFile = load("res://fonts/vcr.ttf")
var pause_root: Control
var menu: Control
var hud_root: Control
var hud_fade: Tween
var shown_vals := {}      # meter name -> displayed value (eased toward the real one)
var t := 0.0
var playing_label: Label
var time_label: Label
var rec_dot: ColorRect
var post_mat: ShaderMaterial
var threat_s := 0.0
var fear_s := 0.0
var papers_val: RichTextLabel
var meters := {}          # name -> {fill, text}
var player: Node
var level: Node

func _ready() -> void:
	layer = 5
	player = get_parent().get_node("Player")
	level = get_parent().get_node("Level")

	# Post-process sits under the UI so text stays crisp
	var post_layer := CanvasLayer.new()
	post_layer.layer = 1
	var post := ColorRect.new()
	post.set_anchors_preset(Control.PRESET_FULL_RECT)
	post.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/post.gdshader")
	if ResourceLoader.exists("res://textures/lens_dirt.png"):
		mat.set_shader_parameter("lens_dirt_tex", load("res://textures/lens_dirt.png"))
	post.material = mat
	post_mat = mat
	Gfx.register_post(mat)
	post_layer.add_child(post)
	get_parent().add_child.call_deferred(post_layer)

	_build_hud()
	_build_pause()

# ---- helpers ------------------------------------------------------------------
func _font(spacing: float) -> FontVariation:
	var fv := FontVariation.new()
	fv.base_font = font
	fv.spacing_glyph = int(spacing)
	return fv

func _label(text: String, size: float, color: Color, spacing := 1.5) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _font(spacing))
	l.add_theme_font_size_override("font_size", int(size * SCALE))
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("shadow_offset_x", 0)
	l.add_theme_constant_override("shadow_offset_y", 1)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _gradient_rect(h: float, from: Color, to: Color) -> TextureRect:
	var g := Gradient.new()
	g.set_color(0, from)
	g.set_color(1, to)
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.width = 256
	gt.height = 1
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(1, 0)
	var tr := TextureRect.new()
	tr.texture = gt
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.custom_minimum_size = Vector2(0, h)
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr

func _vbox(gap: float) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", int(gap * SCALE))
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return v

func _hbox(gap: float) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", int(gap * SCALE))
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return h

func _corner(anchor: Control.LayoutPreset, x: float, y: float, top: bool, left: bool) -> Control:
	# Viewfinder bracket: two 2px lines, 30px long
	var c := Control.new()
	c.set_anchors_and_offsets_preset(anchor)
	c.offset_left = x; c.offset_top = y; c.offset_right = x + 30; c.offset_bottom = y + 30
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var col := Color(0.894, 0.882, 0.776, 0.7)
	var h := ColorRect.new(); h.color = col; h.size = Vector2(30, 2); h.position = Vector2(0, 0 if top else 28)
	var v := ColorRect.new(); v.color = col; v.size = Vector2(2, 30); v.position = Vector2(0 if left else 28, 0)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(h)
	c.add_child(v)
	return c

# ---- HUD ------------------------------------------------------------------------
func _build_hud() -> void:
	var hud := Control.new()
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hud)
	hud_root = hud

	# Corner brackets (16 px from top/bottom, 18 px from the sides)
	hud.add_child(_corner(Control.PRESET_TOP_LEFT, 18, 16, true, true))
	hud.add_child(_corner(Control.PRESET_TOP_RIGHT, -18 - 30, 16, true, false))
	hud.add_child(_corner(Control.PRESET_BOTTOM_LEFT, 18, -16 - 30, false, true))
	hud.add_child(_corner(Control.PRESET_BOTTOM_RIGHT, -18 - 30, -16 - 30, false, false))

	# Crosshair: a 3 px dot
	var dot := ColorRect.new()
	dot.color = Color(0.92, 0.882, 0.686, 0.6)
	dot.size = Vector2(3, 3)
	dot.set_anchors_preset(Control.PRESET_CENTER)
	dot.position = Vector2(-1.5, -1.5)
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(dot)

	# --- top-left: REC + objective ---
	var tl := _vbox(5)
	tl.position = Vector2(42, 32)
	hud.add_child(tl)
	var rec := _hbox(8)
	rec_dot = ColorRect.new()
	rec_dot.color = REC_RED
	rec_dot.custom_minimum_size = Vector2(8 * SCALE, 8 * SCALE)
	var dot_c := CenterContainer.new()
	dot_c.add_child(rec_dot)
	dot_c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rec.add_child(dot_c)
	rec.add_child(_label("REC", 12, REC_RED, 3))
	rec.add_child(_label("CAM 04", 12, CREAM, 2))
	tl.add_child(rec)
	tl.add_child(_gradient_rect(1, Color(1, 0.231, 0.188, 0.8), Color(1, 0.231, 0.188, 0.15)))
	var obj := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.059, 0.047, 0.024, 0.5)
	sb.border_color = Color(1, 0.757, 0.027, 0.25)
	sb.set_border_width_all(1)
	sb.content_margin_left = 8; sb.content_margin_right = 8
	sb.content_margin_top = 3; sb.content_margin_bottom = 3
	obj.add_theme_stylebox_override("panel", sb)
	obj.mouse_filter = Control.MOUSE_FILTER_IGNORE
	obj.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var orow := _hbox(6)
	var odot := ColorRect.new()
	odot.color = AMBER
	odot.custom_minimum_size = Vector2(6 * SCALE, 6 * SCALE)
	var odot_c := CenterContainer.new()
	odot_c.add_child(odot)
	orow.add_child(odot_c)
	orow.add_child(_label("ARCHIVE PAPERS:", 11, AMBER))
	papers_val = null
	var pv := _label("0 / 10", 11, AMBER)
	pv.name = "PapersVal"
	orow.add_child(pv)
	obj.add_child(orow)
	var obj_wrap := MarginContainer.new()
	obj_wrap.add_theme_constant_override("margin_top", int(4 * SCALE))
	obj_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	obj_wrap.add_child(obj)
	tl.add_child(obj_wrap)

	# --- top-right: level title, timecode, tape mode ---
	var tr := _vbox(4)
	tr.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	tr.offset_left = -42 - 300; tr.offset_right = -42; tr.offset_top = 32; tr.offset_bottom = 32
	hud.add_child(tr)
	var title := _label(str(level.level_name).to_upper(), 11, TAPE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	tr.add_child(title)
	time_label = _label("00:00:00", 11, TAPE)
	time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	tr.add_child(time_label)
	var mode := _hbox(14)
	mode.alignment = BoxContainer.ALIGNMENT_END
	playing_label = _label("► PLAY", 11, CREAM)
	mode.add_child(playing_label)
	mode.add_child(_label("SP", 11, CREAM))
	tr.add_child(mode)
	tr.add_child(_gradient_rect(1, Color(0, 0, 0, 0), Color(0.788, 0.745, 0.627, 0.6)))

	# --- bottom-left: meters ---
	var bl := _vbox(16)
	hud.add_child(bl)
	bl.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	bl.offset_left = 42; bl.offset_right = 42 + 220 * SCALE; bl.offset_bottom = -32; bl.offset_top = -32
	bl.grow_vertical = Control.GROW_DIRECTION_BEGIN
	for m in [["STAMINA", Color("e0d494")], ["HEALTH", Color("c8503c")], ["SANITY", Color("a89d62")], ["BATTERY", Color("39e58c")]]:
		bl.add_child(_meter(m[0], m[1]))

	# --- bottom-right: key hints ---
	var br := _vbox(6)
	br.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	br.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	br.grow_vertical = Control.GROW_DIRECTION_BEGIN
	hud.add_child(br)
	var row := _hbox(12)
	row.alignment = BoxContainer.ALIGNMENT_END
	var hints := ["SHIFT // SPRINT", "C // CROUCH", "F // TORCH", "ESC // PAUSE"]
	for i in hints.size():
		row.add_child(_label(hints[i], 11, HINT))
		if i < hints.size() - 1: row.add_child(_label("•", 11, HINT))
	br.add_child(row)
	br.add_child(_gradient_rect(1, Color(0, 0, 0, 0), Color(0.612, 0.573, 0.408, 0.5)))
	br.offset_left = -42 - 720
	br.offset_top = -32 - 40
	br.offset_right = -42
	br.offset_bottom = -32

func _meter(name: String, color: Color) -> Control:
	var block := _vbox(5)
	var meta := HBoxContainer.new()
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var n := _label(name, 11, METER_LABEL, 2.5)
	n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := _label("100%", 11, METER_VAL)
	meta.add_child(n)
	meta.add_child(v)
	block.add_child(meta)
	var track := ColorRect.new()
	track.color = Color(1, 1, 1, 0.12)
	track.custom_minimum_size = Vector2(0, 2)
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fill := ColorRect.new()
	fill.color = color
	fill.position = Vector2.ZERO
	fill.size = Vector2(0, 2)
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	track.add_child(fill)
	block.add_child(track)
	meters[name] = {"fill": fill, "text": v, "track": track, "base": color, "label": n}
	return block

# ---- pause menu (same look as the web menu) ----------------------------------------
func _build_pause() -> void:
	menu = load("res://scripts/ui/menu/menu.gd").new()
	pause_root = menu
	menu.modulate.a = 0.0
	pause_root.visible = false
	add_child(pause_root)
	menu.settings_changed.connect(apply_settings)
	apply_settings()

## Push the menu's saved settings into the audio buses / player (js/game/settings.js)
func apply_settings() -> void:
	var v: Dictionary = menu.volumes
	AudioServer.set_bus_volume_linear(AudioServer.get_bus_index("Master"), v.master)
	var steps := AudioServer.get_bus_index("Steps")
	if steps >= 0: AudioServer.set_bus_volume_linear(steps, v.footsteps)
	var audio := get_parent().get_node_or_null("Audio")
	if audio:
		audio.vol.hum = v.hum
		audio.vol.breathing = v.breathing
		audio.vol.ambient = v.get("ambient", 1.0)
	if player:
		player.sens = menu.mouse_sens()
		player.base_fov = float(menu.fov)
		player.head_bob = 1.0 if menu.head_bob else 0.0

## Start screen (first launch) and pause share one menu; only the title block differs
func set_paused(on: bool, start := false) -> void:
	menu.show_menu(on)
	if hud_root:
		if hud_fade: hud_fade.kill()
		hud_fade = create_tween()
		hud_fade.tween_property(hud_root, "modulate:a", 0.3 if on else 1.0, 0.45)
	if on:
		if start:
			menu.set_text("THE BACKROOMS", "THRESHOLD SECTOR • NON-EUCLIDEAN ZONE", "Unknown area, unknown location.", "CLICK TO ENTER THE LOBBY")
		else:
			menu.set_text("THE BACKROOMS", "THRESHOLD SECTOR • NON-EUCLIDEAN ZONE", "Unknown area, unknown location.", "CLICK OR PRESS ESC TO RESUME")
	else:
		menu.release_focus_all()
	playing_label.text = "|| PAUSE" if on else "► PLAY"

# ---- per-frame values -----------------------------------------------------------------
func _set_meter(name: String, value: float, cls := "") -> void:
	var m: Dictionary = meters[name]
	# Ease the bar toward the real value so drains / recoveries glide instead of stepping
	value = lerpf(shown_vals.get(name, value), value, minf(1.0, get_process_delta_time() * 8.0))
	shown_vals[name] = value
	var fill: ColorRect = m.fill
	var track: ColorRect = m.track
	fill.size = Vector2(track.size.x * clampf(value / 100.0, 0.0, 1.0), track.size.y)
	var txt_s := "%d%%" % int(round(value))
	if (m.text as Label).text != txt_s:          # only on change: a label re-shapes its text when set
		(m.text as Label).text = txt_s
	var col: Color = m.base
	var txt := METER_VAL
	var pulse := 0.65 + 0.35 * sin(t * 15.0)
	match cls:
		"low": col = Color("e59d3a")
		"critical":
			col = Color("ff3b30"); col.a = pulse; txt = Color("ff5545")
		"exhausted":
			col = Color("ff3b30"); col.a = pulse
	fill.color = col
	if m.get("txt_col") != txt:                   # a theme override every frame is a theme update every frame
		m["txt_col"] = txt
		(m.text as Label).add_theme_color_override("font_color", txt)

func _process(dt: float) -> void:
	t += dt
	# fear channels for the post shader (game.fear / terror / glitch in the web pipeline)
	threat_s += (Game.terror - threat_s) * minf(1.0, dt * 3.0)
	fear_s += (Game.fear - fear_s) * minf(1.0, dt * 6.0)
	if post_mat:
		post_mat.set_shader_parameter("fear", fear_s)
		post_mat.set_shader_parameter("threat", threat_s)
		post_mat.set_shader_parameter("glitch", Game.glitch)
		post_mat.set_shader_parameter("pulse", Game.pulse)
		post_mat.set_shader_parameter("classic", Game.fx_classic)
		post_mat.set_shader_parameter("fx_blur", Game.fx_blur)
		post_mat.set_shader_parameter("fx_contrast", Game.fx_contrast)
		post_mat.set_shader_parameter("fx_sat", Game.fx_sat)
		post_mat.set_shader_parameter("fx_hue", Game.fx_hue)
		post_mat.set_shader_parameter("fx_zoom", Game.fx_zoom)
		post_mat.set_shader_parameter("fx_skew", Game.fx_skew)
		post_mat.set_shader_parameter("fx_fade", Game.fx_fade)
		post_mat.set_shader_parameter("fx_flash", Game.fx_flash)
		post_mat.set_shader_parameter("fx_shock", Game.fx_shock)
		post_mat.set_shader_parameter("fx_blood", Game.fx_blood)
		post_mat.set_shader_parameter("fx_static", Game.fx_static)
		post_mat.set_shader_parameter("fx_warp", Game.fx_warp)
		post_mat.set_shader_parameter("fx_blink", Game.fx_blink)
		post_mat.set_shader_parameter("exhaust", 0.8 if (player and player.get("exhausted")) else 0.0)
		post_mat.set_shader_parameter("adrenaline", player.adrenaline if player else 0.0)
		post_mat.set_shader_parameter("insanity", player.insanity if player else 0.0)
	rec_dot.visible = fmod(t, 1.2) < 0.6
	var s := int(t)
	time_label.text = "%02d:%02d:%02d" % [s / 3600, (s / 60) % 60, s % 60]
	if not player: return
	_set_meter("STAMINA", player.stamina, "exhausted" if player.exhausted else "")
	_set_meter("HEALTH", player.health, "critical" if player.health < 25.0 else "")
	var san_cls := ""
	if player.sanity < 25.0: san_cls = "critical"
	elif player.sanity < 50.0: san_cls = "low"
	_set_meter("SANITY", player.sanity, san_cls)
	var bat_cls := ""
	if player.battery < 10.0: bat_cls = "critical"
	elif player.battery < 25.0: bat_cls = "low"
	_set_meter("BATTERY", player.battery, bat_cls)
