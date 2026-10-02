extends CanvasLayer
## T.S.R.A. FIELD DIAGNOSTIC & DEBUG MENU.
## Opens with F1, ~ (Tilde), F3, the top-screen [DEBUG] button, or the Pause Menu link.
## Press 1 to open directly into the Command Console.
##
## Includes:
##  - NOCLIP: Free-fly through walls with WASD + Space/C/Ctrl + Shift
##  - FULLBRIGHT: High-range ambient light, removes pitch-black darkness & heavy fog
##  - GOD MODE: Complete invulnerability to monsters, grabs, falls, sanity collapse
##  - INFINITE STAMINA: Sprint indefinitely with zero fatigue
##  - INFINITE SANITY: Locks sanity at 100%, removes distortions & mind drain
##  - INFINITE TORCH: Flashlight battery pinned at 100% with zero flicker
##  - SPEED & JUMP BOOSTS: 0.5x to 5.0x walk/fly speeds, high jumps
##  - ENTITY CONTROLLER: Spawn/Despawn/Stalk Bacteria, Mannequins, Mimic, Eyes, Killer, Grabber, Skin Stealer, Burnt, & Freeze Monsters
##  - WORLD & SCARE EVENTS: Blackouts, Power Restore, Audio Scares
##  - TELEPORTATION: Warp to Spawn, Mannequins, Bacteria, Ceiling (+5m), Custom X/Z
##  - LIVE OVERLAY HUD: Realtime on-screen telemetry (FPS, Pos, Speed, Vitals, Radar)
##  - HAND ANIMATION TEST: Battery swap, smack, squeeze, finger roll, regrip, flinch (P plays the last again)
##  - COMMAND CONSOLE: Full command line with history and existing dev commands

const SurvivorAnim := preload("res://scripts/Entities/survivor_anim.gd")
const HazmatFit := preload("res://scripts/Entities/hazmat_fit.gd")
const FlashPickup := preload("res://scripts/World/props/flash_pickup.gd")
const TapePickup := preload("res://scripts/World/props/tape_pickup.gd")

const ENTITIES := {
	"bacteria": "Entity",
	"mannequin": "Mannequin",
	"mimic": "Mimic",
	"killer": "Killer",
	"grabber": "Grabber",
	"skinstealer": "SkinStealer",
	"burnt": "Burnt",
}
const ORDER := ["bacteria", "mannequin", "mimic", "killer", "grabber", "skinstealer", "burnt"]
# other things you might type for a name
const ALIASES := {"entity": "bacteria", "skin": "skinstealer", "stealer": "skinstealer", "theburnt": "burnt"}
const GRABBER_STATES := ["hunch", "peek", "chase", "drag"]
# the first-person arms' one-shots (torch_model.gd): console name -> clip. "swap" goes the way R does,
# sound and light with it, but spends no battery pack.
const HAND_ANIMS := {
	"swap": "TorchReload",
	"smack": "TorchSmack",
	"squeeze": "TorchSqueeze",
	"fingers": "TorchFingers",
	"regrip": "TorchRegrip",
	"flinch": "TorchFlinch",
}
const HAND_ANIM_LABELS := {"swap": "BATTERY SWAP", "smack": "SMACK TORCH", "squeeze": "SQUEEZE", "fingers": "FINGER ROLL",
	"regrip": "REGRIP", "flinch": "FLINCH"}
const HAND_ANIM_WAIT := 0.35      # s from the menu closing to the clip, so its start is seen

const FONT_PATH := "res://fonts/vcr.ttf"
var font: FontFile

var root: Node
var menu_window: PanelContainer
var screen_overlay: PanelContainer
var overlay_label: Label
var quick_badge_btn: Button

# Quick cheat buttons (top bar)
var btn_noclip: Button
var btn_fullbright: Button
var btn_godmode: Button
var btn_inf_stamina: Button
var btn_inf_sanity: Button
var btn_inf_torch: Button
var btn_freeze_ai: Button
var btn_header_hud: Button
var btn_toggle_hud: Button

# Tabs & content panels
var tab_buttons := {}
var tab_panels := {}
var current_tab := "cheats"

# Speed & Jump labels
var speed_label: Label
var speed_slider: HSlider
var jump_label: Label
var jump_slider: HSlider
var eyes_slider: HSlider
var eyes_count_label: Label

# Teleport coordinate inputs
var tp_x_input: LineEdit
var tp_z_input: LineEdit

# Console tab widgets
var log_label: RichTextLabel
var input: LineEdit
var history: Array = []
var history_at := 0

# Survivor model preview
var dbg_model: Node3D
var dbg_anim: AnimationPlayer
var dbg_anims: Array[String] = []
var dbg_anims_idx := 0

var hand_anim_last := "swap"      # the arm clip P plays again

func _ready() -> void:
	layer = 120
	process_mode = Node.PROCESS_MODE_ALWAYS
	root = get_parent()
	if ResourceLoader.exists(FONT_PATH):
		font = load(FONT_PATH)
	_build_ui()
	menu_window.visible = false
	Game.hud_visibility_changed.connect(func(_v: bool):
		_sync_hud_state()
	)
	Game.hands_visibility_changed.connect(func(_v: bool):
		_sync_hud_state()
	)
	_sync_hud_state()
	_print("[color=gray]T.S.R.A. Diagnostic Matrix online. Press [b]F1[/b] or [b]~[/b] for visual menu, [b]help[/b] for commands.[/color]")

func _process(_dt: float) -> void:
	if Game.show_debug_overlay and not Game.hide_hud:
		screen_overlay.visible = true
		_update_overlay_text()
	else:
		screen_overlay.visible = false

# ---------------------------------------------------------------- UI Building
func _build_ui() -> void:
	var root_ctrl := Control.new()
	root_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root_ctrl)

	_build_screen_overlay(root_ctrl)
	_build_quick_badge(root_ctrl)
	_build_menu_window(root_ctrl)

# Top-Left Live Telemetry HUD Overlay
func _build_screen_overlay(parent: Control) -> void:
	screen_overlay = PanelContainer.new()
	screen_overlay.position = Vector2(20, 20)
	screen_overlay.custom_minimum_size = Vector2(340, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.07, 0.82)
	sb.border_color = Color(0.2, 0.8, 0.65, 0.7)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(8)
	screen_overlay.add_theme_stylebox_override("panel", sb)
	screen_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(screen_overlay)

	overlay_label = Label.new()
	if font: overlay_label.add_theme_font_override("font", font)
	overlay_label.add_theme_font_size_override("font_size", 12)
	overlay_label.add_theme_color_override("font_color", Color(0.85, 0.95, 0.9))
	screen_overlay.add_child(overlay_label)

# Top-Right On-Screen Clickable Badge Button
func _build_quick_badge(parent: Control) -> void:
	quick_badge_btn = Button.new()
	quick_badge_btn.text = "DEBUG [F1]"
	quick_badge_btn.visible = false
	if font: quick_badge_btn.add_theme_font_override("font", font)
	quick_badge_btn.add_theme_font_size_override("font_size", 12)
	quick_badge_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	quick_badge_btn.offset_left = -140
	quick_badge_btn.offset_top = 16
	quick_badge_btn.offset_right = -20
	quick_badge_btn.offset_bottom = 44
	quick_badge_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	var normal_sb := _make_box(Color(0.06, 0.08, 0.11, 0.75), Color(0.2, 0.8, 0.65, 0.6), 1, 4, 6)
	var hover_sb := _make_box(Color(0.1, 0.16, 0.2, 0.9), Color(0.3, 1.0, 0.8, 0.95), 1, 4, 6)
	quick_badge_btn.add_theme_stylebox_override("normal", normal_sb)
	quick_badge_btn.add_theme_stylebox_override("hover", hover_sb)
	quick_badge_btn.add_theme_stylebox_override("pressed", hover_sb)
	quick_badge_btn.add_theme_color_override("font_color", Color(0.7, 0.95, 0.85))
	quick_badge_btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))
	quick_badge_btn.pressed.connect(toggle_menu)
	parent.add_child(quick_badge_btn)

# Main Centered Modal Window
func _build_menu_window(parent: Control) -> void:
	menu_window = PanelContainer.new()
	menu_window.set_anchors_preset(Control.PRESET_CENTER)
	menu_window.custom_minimum_size = Vector2(860, 600)
	menu_window.grow_horizontal = Control.GROW_DIRECTION_BOTH
	menu_window.grow_vertical = Control.GROW_DIRECTION_BOTH
	menu_window.position = Vector2(-430, -300)

	var win_sb := StyleBoxFlat.new()
	win_sb.bg_color = Color(0.045, 0.055, 0.075, 0.96)
	win_sb.border_color = Color(0.2, 0.8, 0.68, 0.9)
	win_sb.set_border_width_all(2)
	win_sb.set_corner_radius_all(6)
	win_sb.set_content_margin_all(14)
	win_sb.shadow_color = Color(0, 0, 0, 0.6)
	win_sb.shadow_size = 16
	menu_window.add_theme_stylebox_override("panel", win_sb)
	parent.add_child(menu_window)

	var main_vbox := VBoxContainer.new()
	main_vbox.add_theme_constant_override("separation", 10)
	menu_window.add_child(main_vbox)

	# --- Header Bar ---
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	main_vbox.add_child(header)

	var title_vbox := VBoxContainer.new()
	title_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title_vbox)

	var title_lbl := Label.new()
	title_lbl.text = "T.S.R.A. FIELD DIAGNOSTIC & DEBUG MATRIX // V4.7"
	if font: title_lbl.add_theme_font_override("font", font)
	title_lbl.add_theme_font_size_override("font_size", 16)
	title_lbl.add_theme_color_override("font_color", Color(0.25, 0.95, 0.8))
	title_vbox.add_child(title_lbl)

	var subtitle_lbl := Label.new()
	subtitle_lbl.text = "PRESS F1, ~ (TILDE), OR ESC TO TOGGLE MENU • GAME RUNS IN BACKGROUND"
	if font: subtitle_lbl.add_theme_font_override("font", font)
	subtitle_lbl.add_theme_font_size_override("font_size", 10)
	subtitle_lbl.add_theme_color_override("font_color", Color(0.65, 0.75, 0.72, 0.75))
	title_vbox.add_child(subtitle_lbl)

	btn_header_hud = Button.new()
	btn_header_hud.text = "📷 HIDE HUD & HANDS"
	if font: btn_header_hud.add_theme_font_override("font", font)
	btn_header_hud.add_theme_font_size_override("font_size", 12)
	btn_header_hud.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn_header_hud.pressed.connect(func():
		Game.hide_hud = not Game.hide_hud
		_sync_hud_state()
		_print("HUD & Hands: " + ("[color=orange]HIDDEN (Screenshot Mode)[/color]" if Game.hide_hud else "[color=lime]VISIBLE[/color]"))
	)
	header.add_child(btn_header_hud)

	var close_btn := Button.new()
	close_btn.text = "✕ CLOSE"
	if font: close_btn.add_theme_font_override("font", font)
	close_btn.add_theme_font_size_override("font_size", 12)
	close_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	close_btn.add_theme_stylebox_override("normal", _make_box(Color(0.2, 0.08, 0.08, 0.8), Color(0.8, 0.3, 0.3, 0.8), 1, 4, 8))
	close_btn.add_theme_stylebox_override("hover", _make_box(Color(0.35, 0.1, 0.1, 0.95), Color(1.0, 0.4, 0.4, 1.0), 1, 4, 8))
	close_btn.pressed.connect(func(): _toggle(false))
	header.add_child(close_btn)

	# --- Quick Cheats Bar ---
	var quick_bar := HBoxContainer.new()
	quick_bar.add_theme_constant_override("separation", 6)
	main_vbox.add_child(quick_bar)

	btn_noclip = _make_toggle_btn("NOCLIP (FLY)", Color(0.1, 0.85, 1.0), func(on):
		Game.noclip = on
		_sync_quick_buttons()
	)
	btn_fullbright = _make_toggle_btn("FULLBRIGHT", Color(1.0, 0.95, 0.3), func(on):
		var pl := _get_player()
		if pl != null and pl.has_method("set_fullbright"):
			pl.set_fullbright(on)
		else:
			Game.fullbright = on
		_sync_quick_buttons()
	)
	btn_godmode = _make_toggle_btn("GOD MODE", Color(1.0, 0.7, 0.15), func(on):
		Game.god_mode = on
		_sync_quick_buttons()
	)
	btn_inf_stamina = _make_toggle_btn("INF STAMINA", Color(0.3, 1.0, 0.45), func(on):
		Game.infinite_stamina = on
		_sync_quick_buttons()
	)
	btn_inf_sanity = _make_toggle_btn("INF SANITY", Color(0.85, 0.4, 1.0), func(on):
		Game.infinite_sanity = on
		var pl := _get_player()
		if pl != null:
			pl.sanity = 100.0
			pl.sanity_lock = 100.0 if on else -1.0
		_sync_quick_buttons()
	)
	btn_inf_torch = _make_toggle_btn("INF TORCH", Color(1.0, 0.8, 0.25), func(on):
		Game.infinite_battery = on
		var pl := _get_player()
		if pl != null and on: pl.battery = 100.0
		_sync_quick_buttons()
	)

	quick_bar.add_child(btn_noclip)
	quick_bar.add_child(btn_fullbright)
	quick_bar.add_child(btn_godmode)
	quick_bar.add_child(btn_inf_stamina)
	quick_bar.add_child(btn_inf_sanity)
	quick_bar.add_child(btn_inf_torch)

	# --- Tab Navigation Bar ---
	var nav_bar := HBoxContainer.new()
	nav_bar.add_theme_constant_override("separation", 6)
	main_vbox.add_child(nav_bar)

	var tabs := [
		{"id": "cheats", "label": "CHEATS & PLAYER"},
		{"id": "entities", "label": "MONSTERS & BEHAVIOR"},
		{"id": "world", "label": "WORLD & EVENTS"},
		{"id": "teleport", "label": "TELEPORTATION"},
		{"id": "console", "label": "CONSOLE"}
	]
	for t in tabs:
		var tb := Button.new()
		tb.text = t["label"]
		if font: tb.add_theme_font_override("font", font)
		tb.add_theme_font_size_override("font_size", 12)
		tb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tb.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		tb.pressed.connect(_switch_tab.bind(t["id"]))
		nav_bar.add_child(tb)
		tab_buttons[t["id"]] = tb

	# --- Tab Content Container ---
	var tab_content := PanelContainer.new()
	tab_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var content_sb := _make_box(Color(0.03, 0.04, 0.05, 0.7), Color(0.2, 0.4, 0.35, 0.4), 1, 4, 10)
	tab_content.add_theme_stylebox_override("panel", content_sb)
	main_vbox.add_child(tab_content)

	tab_panels["cheats"] = _build_cheats_tab()
	tab_panels["entities"] = _build_entities_tab()
	tab_panels["world"] = _build_world_tab()
	tab_panels["teleport"] = _build_teleport_tab()
	tab_panels["console"] = _build_console_tab()

	for k in tab_panels:
		tab_content.add_child(tab_panels[k])

	_switch_tab("cheats")
	_sync_quick_buttons()

# ---------------------------------------------------------------- Tabs Content
# TAB 1: Cheats & Player
func _build_cheats_tab() -> Control:
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 12)
	scroll.add_child(v)

	v.add_child(_section_header("MOVEMENT & SPEED BOOSTS"))

	# Speed Slider & Presets
	var speed_box := VBoxContainer.new()
	speed_box.add_theme_constant_override("separation", 4)
	v.add_child(speed_box)

	var speed_row := HBoxContainer.new()
	speed_row.add_theme_constant_override("separation", 10)
	speed_box.add_child(speed_row)

	speed_label = Label.new()
	speed_label.text = "MOVEMENT / FLY SPEED: 1.0x"
	if font: speed_label.add_theme_font_override("font", font)
	speed_label.add_theme_font_size_override("font_size", 12)
	speed_label.add_theme_color_override("font_color", Color(0.85, 0.9, 0.8))
	speed_row.add_child(speed_label)

	for s in [1.0, 1.5, 2.0, 3.0, 5.0]:
		var pb := Button.new()
		pb.text = "%.1fx" % s
		if font: pb.add_theme_font_override("font", font)
		pb.add_theme_font_size_override("font_size", 11)
		pb.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		pb.pressed.connect(func(): _set_speed(s))
		speed_row.add_child(pb)

	speed_slider = HSlider.new()
	speed_slider.min_value = 0.5
	speed_slider.max_value = 5.0
	speed_slider.step = 0.25
	speed_slider.value = Game.speed_mult
	speed_slider.value_changed.connect(func(val): _set_speed(val))
	speed_box.add_child(speed_slider)

	# Jump Slider & Presets
	var jump_box := VBoxContainer.new()
	jump_box.add_theme_constant_override("separation", 4)
	v.add_child(jump_box)

	var jump_row := HBoxContainer.new()
	jump_row.add_theme_constant_override("separation", 10)
	jump_box.add_child(jump_row)

	jump_label = Label.new()
	jump_label.text = "JUMP HEIGHT BOOST: 1.0x"
	if font: jump_label.add_theme_font_override("font", font)
	jump_label.add_theme_font_size_override("font_size", 12)
	jump_label.add_theme_color_override("font_color", Color(0.85, 0.9, 0.8))
	jump_row.add_child(jump_label)

	for j in [1.0, 1.5, 2.0, 3.0]:
		var jb := Button.new()
		jb.text = "%.1fx" % j
		if font: jb.add_theme_font_override("font", font)
		jb.add_theme_font_size_override("font_size", 11)
		jb.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		jb.pressed.connect(func(): _set_jump(j))
		jump_row.add_child(jb)

	jump_slider = HSlider.new()
	jump_slider.min_value = 1.0
	jump_slider.max_value = 3.0
	jump_slider.step = 0.25
	jump_slider.value = Game.jump_mult
	jump_slider.value_changed.connect(func(val): _set_jump(val))
	jump_box.add_child(jump_slider)

	v.add_child(_section_header("INSTANT RESTORE & EQUIPMENT REFILLS"))

	var refills := HBoxContainer.new()
	refills.add_theme_constant_override("separation", 8)
	v.add_child(refills)

	refills.add_child(_action_btn("RESTORE 100% HEALTH", func():
		var pl := _get_player()
		if pl != null: pl.health = 100.0
	))
	refills.add_child(_action_btn("RESTORE 100% SANITY", func():
		var pl := _get_player()
		if pl != null:
			pl.sanity = 100.0
			pl.insanity = 0.0
	))
	refills.add_child(_action_btn("+5 CAMERA FLASHES", func(): _refill_flash()))
	refills.add_child(_action_btn("+300M HAZARD TAPE", func(): _refill_tape()))

	# The arms can't be seen behind this window: a button closes it, then plays its clip
	v.add_child(_section_header("HAND ANIMATION TEST (MENU CLOSES TO PLAY • PRESS P TO PLAY THE LAST ONE AGAIN)"))
	var hands_row := HBoxContainer.new()
	hands_row.add_theme_constant_override("separation", 8)
	v.add_child(hands_row)
	for what in HAND_ANIMS:
		hands_row.add_child(_action_btn(HAND_ANIM_LABELS[what], func(): _hand_anim(what)))

	v.add_child(_section_header("HUD & SCREENSHOTS"))
	var hud_row := HBoxContainer.new()
	hud_row.add_theme_constant_override("separation", 8)
	v.add_child(hud_row)

	btn_toggle_hud = _make_toggle_btn("HIDE ALL HUD & HANDS (SCREENSHOT MODE)", Color(0.2, 0.85, 1.0), func(on):
		Game.hide_hud = on
		_sync_hud_state()
		_print("HUD & Hands: " + ("[color=orange]HIDDEN (Screenshot Mode)[/color]" if Game.hide_hud else "[color=lime]VISIBLE[/color]"))
	)
	hud_row.add_child(btn_toggle_hud)

	var snap_btn := _action_btn("📷 TAKE SCREENSHOT", func():
		_take_screenshot()
	)
	hud_row.add_child(snap_btn)

	var hud_btn := _action_btn("TOGGLE TELEMETRY OVERLAY", func():
		Game.show_debug_overlay = not Game.show_debug_overlay
	)
	hud_row.add_child(hud_btn)

	return scroll

# TAB 2: Entities & Behavior
func _build_entities_tab() -> Control:
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 10)
	scroll.add_child(v)

	v.add_child(_section_header("MASTER MONSTER CONTROLS"))
	btn_freeze_ai = _make_toggle_btn("FREEZE ALL MONSTERS (PAUSE)", Color(0.2, 0.8, 1.0), func(on):
		Game.freeze_ai = on
		_sync_quick_buttons()
	)
	v.add_child(btn_freeze_ai)

	v.add_child(_section_header("INDIVIDUAL ENTITY SPAWN & CONTROLS"))

	# Bacteria Row
	var bac_box := HBoxContainer.new()
	bac_box.add_theme_constant_override("separation", 8)
	v.add_child(bac_box)
	bac_box.add_child(_label("BACTERIA (HOWLER):", 12, Color(0.9, 0.8, 0.6), 160))
	bac_box.add_child(_action_btn("SPAWN", func(): _apply("bacteria", true)))
	bac_box.add_child(_action_btn("DESPAWN", func(): _apply("bacteria", false)))
	bac_box.add_child(_action_btn("FORCE STALK", func():
		var ent = root.get_node_or_null("Entity")
		if ent and ent.has_method("debug_stalk"):
			_print("Bacteria stalk: %s" % str(ent.debug_stalk()))
	))

	# Mannequin Row
	var man_box := HBoxContainer.new()
	man_box.add_theme_constant_override("separation", 8)
	v.add_child(man_box)
	man_box.add_child(_label("MANNEQUIN:", 12, Color(0.9, 0.8, 0.6), 160))
	man_box.add_child(_action_btn("SPAWN / WARP", func():
		var m = root.get_node_or_null("Mannequin")
		if m and m.has_method("warp_to_room"): m.warp_to_room()
	))
	man_box.add_child(_action_btn("DESPAWN", func(): _apply("mannequin", false)))

	# Mimic Row
	var mim_box := HBoxContainer.new()
	mim_box.add_theme_constant_override("separation", 8)
	v.add_child(mim_box)
	mim_box.add_child(_label("MIMIC (SURVIVOR):", 12, Color(0.9, 0.8, 0.6), 160))
	mim_box.add_child(_action_btn("SPAWN", func(): _apply("mimic", true)))
	mim_box.add_child(_action_btn("DESPAWN", func(): _apply("mimic", false)))

	# Eyes Row
	var eyes_box := VBoxContainer.new()
	eyes_box.add_theme_constant_override("separation", 4)
	v.add_child(eyes_box)

	var eyes_row := HBoxContainer.new()
	eyes_row.add_theme_constant_override("separation", 8)
	eyes_box.add_child(eyes_row)
	eyes_row.add_child(_label("EYES IN THE DARK:", 12, Color(0.9, 0.8, 0.6), 160))

	eyes_count_label = _label("COUNT: AUTO", 12, Color(0.8, 0.9, 0.85), 110)
	eyes_row.add_child(eyes_count_label)
	eyes_row.add_child(_action_btn("AUTO (SANITY)", func():
		var ey = root.get_node_or_null("Eyes")
		if ey: ey.debug_auto(); eyes_count_label.text = "COUNT: AUTO"
	))
	eyes_row.add_child(_action_btn("CLEAR ALL", func():
		var ey = root.get_node_or_null("Eyes")
		if ey: ey.debug_clear(); eyes_count_label.text = "COUNT: 0"
	))

	eyes_slider = HSlider.new()
	eyes_slider.min_value = 0
	eyes_slider.max_value = 8
	eyes_slider.step = 1
	eyes_slider.value_changed.connect(func(v):
		var ey = root.get_node_or_null("Eyes")
		if ey:
			ey.debug_set(int(v))
			eyes_count_label.text = "COUNT: %d" % int(v)
	)
	eyes_box.add_child(eyes_slider)

	# Killer Row
	var kil_box := HBoxContainer.new()
	kil_box.add_theme_constant_override("separation", 8)
	v.add_child(kil_box)
	kil_box.add_child(_label("KILLER (TEST MESH):", 12, Color(0.9, 0.8, 0.6), 160))
	kil_box.add_child(_action_btn("SPAWN", func(): _apply("killer", true)))
	kil_box.add_child(_action_btn("DESPAWN", func(): _apply("killer", false)))

	# Skin Stealer & Burnt Rows: models only for now, stood in front of you
	for row in [["SKIN STEALER (MODEL):", "skinstealer"], ["THE BURNT (MODEL):", "burnt"]]:
		var mdl_box := HBoxContainer.new()
		mdl_box.add_theme_constant_override("separation", 8)
		v.add_child(mdl_box)
		mdl_box.add_child(_label(row[0], 12, Color(0.9, 0.8, 0.6), 160))
		mdl_box.add_child(_action_btn("SPAWN", func(): _apply(row[1], true)))
		mdl_box.add_child(_action_btn("DESPAWN", func(): _apply(row[1], false)))

	# Grabber Row: spawn it on the ceiling ahead, or drop it straight into a state
	var grb_box := HBoxContainer.new()
	grb_box.add_theme_constant_override("separation", 8)
	v.add_child(grb_box)
	grb_box.add_child(_label("GRABBER:", 12, Color(0.9, 0.8, 0.6), 160))
	grb_box.add_child(_action_btn("SPAWN", func(): _apply("grabber", true)))
	grb_box.add_child(_action_btn("DESPAWN", func(): _apply("grabber", false)))
	for st in GRABBER_STATES:
		grb_box.add_child(_action_btn(st.to_upper(), func(): _grabber_state(st)))

	# All Monsters Action
	var all_box := HBoxContainer.new()
	all_box.add_theme_constant_override("separation", 8)
	v.add_child(all_box)
	all_box.add_child(_label("BATCH ACTIONS:", 12, Color(0.9, 0.8, 0.6), 160))
	all_box.add_child(_action_btn("SPAWN ALL", func(): _each("all", true)))
	all_box.add_child(_action_btn("DESPAWN ALL", func(): _each("all", false)))

	return scroll

# TAB 3: World & Events
func _build_world_tab() -> Control:
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 10)
	scroll.add_child(v)

	v.add_child(_section_header("LEVEL"))
	var level_row := HBoxContainer.new()
	level_row.add_theme_constant_override("separation", 8)
	v.add_child(level_row)
	# Re-reads the .lvl from disk, so the latest level editor save shows up without restarting the game.
	level_row.add_child(_action_btn("RELOAD LEVEL (LATEST EDITOR SAVE)", func():
		Game.change_level(Game.level_index)
	))

	v.add_child(_section_header("ELECTRICAL GRID & LIGHTING"))
	var light_row := HBoxContainer.new()
	light_row.add_theme_constant_override("separation", 8)
	v.add_child(light_row)

	light_row.add_child(_action_btn("TRIGGER BLACKOUT (POWER CUT)", func():
		_trigger_blackout()
	))
	light_row.add_child(_action_btn("RESTORE GRID LIGHTS", func():
		_restore_grid()
	))

	v.add_child(_section_header("AMBIENT SCARE DIRECTORS"))
	var scare_row := HBoxContainer.new()
	scare_row.add_theme_constant_override("separation", 8)
	v.add_child(scare_row)

	scare_row.add_child(_action_btn("PREACHER WHISPER", func():
		var ev = root.get_node_or_null("Events")
		if ev: ev.run_event("preacherWhisper")
	))
	scare_row.add_child(_action_btn("WALL KNOCK", func():
		var ev = root.get_node_or_null("Events")
		if ev: ev.run_event("wallKnock")
	))
	scare_row.add_child(_action_btn("BREATH BEHIND", func():
		var ev = root.get_node_or_null("Events")
		if ev: ev.run_event("breathBehind")
	))

	v.add_child(_section_header("T.S.R.A. PROGRESSION & ARCHIVES"))
	var prog_row := HBoxContainer.new()
	prog_row.add_theme_constant_override("separation", 8)
	v.add_child(prog_row)

	prog_row.add_child(_action_btn("GRANT MAX CLEARANCE (TIER 4)", func():
		Clearance.grant(1200)
		_print("Granted Clearance Tier 4.")
	))
	prog_row.add_child(_action_btn("UNLOCK ALL DOSSIERS", func():
		for id in Archive.entities():
			Archive.discover(str(id))
		_print("Unlocked all entity dossiers in Archive.")
	))
	prog_row.add_child(_action_btn("RESET CLEARANCE & ARCHIVE", func():
		Clearance.reset()
		Archive.forget_all()
		_print("Clearance and Archive reset.")
	))

	return scroll

# TAB 4: Teleportation
func _build_teleport_tab() -> Control:
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 10)
	scroll.add_child(v)

	v.add_child(_section_header("WARP DESTINATIONS"))
	var warp_row := HBoxContainer.new()
	warp_row.add_theme_constant_override("separation", 8)
	v.add_child(warp_row)

	warp_row.add_child(_action_btn("WARP: LEVEL SPAWN", func():
		var pl := _get_player()
		var lvl = root.get_node_or_null("Level")
		if pl != null and lvl != null and "spawn_pos" in lvl:
			pl.global_position = lvl.spawn_pos
	))
	warp_row.add_child(_action_btn("WARP: MANNEQUIN ROOM", func():
		var man = root.get_node_or_null("Mannequin")
		if man and man.has_method("warp_to_room"): man.warp_to_room()
	))
	warp_row.add_child(_action_btn("WARP: TO BACTERIA", func():
		var pl := _get_player()
		var ent = root.get_node_or_null("Entity")
		if pl != null and ent != null and ent.is_inside_tree():
			pl.global_position = ent.global_position + Vector3(0, 0, 5)
	))
	warp_row.add_child(_action_btn("WARP: +5M UP (CEILING)", func():
		var pl := _get_player()
		if pl != null: pl.global_position.y += 5.0
	))

	v.add_child(_section_header("WARP TO CUSTOM COORDINATES"))
	var coord_row := HBoxContainer.new()
	coord_row.add_theme_constant_override("separation", 8)
	v.add_child(coord_row)

	coord_row.add_child(_label("X:", 12, Color.WHITE, 20))
	tp_x_input = LineEdit.new()
	tp_x_input.placeholder_text = "0.0"
	tp_x_input.custom_minimum_size = Vector2(80, 0)
	coord_row.add_child(tp_x_input)

	coord_row.add_child(_label("Z:", 12, Color.WHITE, 20))
	tp_z_input = LineEdit.new()
	tp_z_input.placeholder_text = "0.0"
	tp_z_input.custom_minimum_size = Vector2(80, 0)
	coord_row.add_child(tp_z_input)

	coord_row.add_child(_action_btn("TELEPORT TO (X, Z)", func():
		var pl := _get_player()
		if pl != null and tp_x_input.text.is_valid_float() and tp_z_input.text.is_valid_float():
			pl.global_position = Vector3(tp_x_input.text.to_float(), pl.global_position.y, tp_z_input.text.to_float())
	))

	return scroll

# TAB 5: CLI Command Console
func _build_console_tab() -> Control:
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.add_theme_constant_override("separation", 6)

	log_label = RichTextLabel.new()
	log_label.bbcode_enabled = true
	log_label.scroll_following = true
	log_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_label.add_theme_font_size_override("normal_font_size", 13)
	v.add_child(log_label)

	input = LineEdit.new()
	input.placeholder_text = "type a command (e.g. help, list, spawn bacteria, lightout)"
	input.text_submitted.connect(_submit)
	v.add_child(input)

	var chips_row := HBoxContainer.new()
	chips_row.add_theme_constant_override("separation", 6)
	v.add_child(chips_row)

	for cmd in ["help", "list", "hud", "spawn all", "kill all", "screenshot", "stalk", "lightout", "clear"]:
		var chip := Button.new()
		chip.text = cmd
		if font: chip.add_theme_font_override("font", font)
		chip.add_theme_font_size_override("font_size", 10)
		chip.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		chip.pressed.connect(func():
			input.text = cmd
			_submit(cmd)
		)
		chips_row.add_child(chip)

	return v

# ---------------------------------------------------------------- Quick Helpers & Styles
func _switch_tab(id: String) -> void:
	current_tab = id
	for k in tab_panels:
		tab_panels[k].visible = (k == id)
	for k in tab_buttons:
		var tb: Button = tab_buttons[k]
		var active: bool = (str(k) == id)
		var bg := Color(0.12, 0.22, 0.26, 0.95) if active else Color(0.06, 0.08, 0.1, 0.8)
		var bdr := Color(0.3, 0.95, 0.8, 0.95) if active else Color(0.2, 0.35, 0.35, 0.5)
		tb.add_theme_stylebox_override("normal", _make_box(bg, bdr, 1, 4, 6))
		tb.add_theme_stylebox_override("hover", _make_box(Color(0.16, 0.26, 0.3, 0.95), Color(0.4, 1.0, 0.85, 1.0), 1, 4, 6))
		tb.add_theme_stylebox_override("pressed", _make_box(bg, bdr, 1, 4, 6))
		tb.add_theme_color_override("font_color", Color(0.9, 1.0, 0.95) if active else Color(0.65, 0.75, 0.72))

func _sync_quick_buttons() -> void:
	_update_toggle_btn(btn_noclip, Game.noclip, "NOCLIP (FLY)", Color(0.1, 0.85, 1.0))
	_update_toggle_btn(btn_fullbright, Game.fullbright, "FULLBRIGHT", Color(1.0, 0.95, 0.3))
	_update_toggle_btn(btn_godmode, Game.god_mode, "GOD MODE", Color(1.0, 0.7, 0.15))
	_update_toggle_btn(btn_inf_stamina, Game.infinite_stamina, "INF STAMINA", Color(0.3, 1.0, 0.45))
	_update_toggle_btn(btn_inf_sanity, Game.infinite_sanity, "INF SANITY", Color(0.85, 0.4, 1.0))
	_update_toggle_btn(btn_inf_torch, Game.infinite_battery, "INF TORCH", Color(1.0, 0.8, 0.25))
	if btn_freeze_ai != null:
		_update_toggle_btn(btn_freeze_ai, Game.freeze_ai, "❄ FREEZE ALL MONSTERS (PAUSE)", Color(0.2, 0.8, 1.0))
	_sync_hud_state()

func _sync_hud_state() -> void:
	if btn_header_hud != null:
		btn_header_hud.text = "📷 SHOW HUD & HANDS" if Game.hide_hud else "📷 HIDE HUD & HANDS"
		var bg := Color(0.18, 0.45, 0.35, 0.9) if Game.hide_hud else Color(0.1, 0.14, 0.18, 0.8)
		var bdr := Color(0.3, 0.95, 0.7, 0.9) if Game.hide_hud else Color(0.3, 0.5, 0.5, 0.6)
		btn_header_hud.add_theme_stylebox_override("normal", _make_box(bg, bdr, 1, 4, 8))
		btn_header_hud.add_theme_stylebox_override("hover", _make_box(bg * 1.3, Color(0.4, 1.0, 0.85), 1, 4, 8))
	if btn_toggle_hud != null:
		_update_toggle_btn(btn_toggle_hud, Game.hide_hud, "HIDE ALL HUD & HANDS (SCREENSHOT MODE)", Color(0.2, 0.85, 1.0))

func _make_toggle_btn(label: String, tint: Color, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = "○ " + label
	if font: btn.add_theme_font_override("font", font)
	btn.add_theme_font_size_override("font_size", 11)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.pressed.connect(func():
		var cur := false
		match label:
			"NOCLIP (FLY)": cur = not Game.noclip
			"FULLBRIGHT": cur = not Game.fullbright
			"GOD MODE": cur = not Game.god_mode
			"INF STAMINA": cur = not Game.infinite_stamina
			"INF SANITY": cur = not Game.infinite_sanity
			"INF TORCH": cur = not Game.infinite_battery
			_: cur = not Game.freeze_ai
		callback.call(cur)
	)
	return btn

func _update_toggle_btn(btn: Button, active: bool, label: String, tint: Color) -> void:
	if btn == null: return
	btn.text = ("● " if active else "○ ") + label
	var bg := tint * Color(1, 1, 1, 0.22) if active else Color(0.06, 0.08, 0.1, 0.8)
	var bdr := tint if active else Color(0.25, 0.35, 0.35, 0.5)
	btn.add_theme_stylebox_override("normal", _make_box(bg, bdr, 1, 4, 6))
	btn.add_theme_stylebox_override("hover", _make_box(bg * 1.3, tint, 1, 4, 6))
	btn.add_theme_stylebox_override("pressed", _make_box(bg, bdr, 1, 4, 6))
	btn.add_theme_color_override("font_color", tint if active else Color(0.7, 0.75, 0.75))

func _action_btn(label: String, callback: Callable) -> Button:
	var b := Button.new()
	b.text = label
	if font: b.add_theme_font_override("font", font)
	b.add_theme_font_size_override("font_size", 11)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.add_theme_stylebox_override("normal", _make_box(Color(0.08, 0.12, 0.15, 0.85), Color(0.25, 0.45, 0.45, 0.7), 1, 4, 6))
	b.add_theme_stylebox_override("hover", _make_box(Color(0.12, 0.2, 0.25, 0.95), Color(0.4, 0.9, 0.8, 1.0), 1, 4, 6))
	b.pressed.connect(callback)
	return b

func _section_header(title: String) -> Control:
	var h := Label.new()
	h.text = "— " + title + " —"
	if font: h.add_theme_font_override("font", font)
	h.add_theme_font_size_override("font_size", 12)
	h.add_theme_color_override("font_color", Color(0.4, 0.85, 0.75))
	return h

func _label(text: String, size := 12, color := Color.WHITE, min_w := 0) -> Label:
	var l := Label.new()
	l.text = text
	if font: l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if min_w > 0: l.custom_minimum_size = Vector2(min_w, 0)
	return l

func _make_box(bg: Color, bdr: Color, bdr_w := 1, rad := 4, pad := 6) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = bdr
	s.set_border_width_all(bdr_w)
	s.set_corner_radius_all(rad)
	s.set_content_margin_all(pad)
	return s

# ---------------------------------------------------------------- Telemetry Overlay Text
func _update_overlay_text() -> void:
	var fps: int = Engine.get_frames_per_second()
	var pl: Node = _get_player()
	var pos: Vector3 = pl.global_position if pl != null and "global_position" in pl else Vector3.ZERO
	var rot_y: int = roundi(rad_to_deg(pl.rotation.y)) if pl != null and "rotation" in pl else 0
	var spd: float = Vector2(pl.velocity.x, pl.velocity.z).length() if pl != null and "velocity" in pl else 0.0
	var hp: int = int(pl.health) if pl != null and "health" in pl else 100
	var san: int = int(pl.sanity) if pl != null and "sanity" in pl else 100
	var stm: int = int(pl.stamina) if pl != null and "stamina" in pl else 100
	var bat: int = int(pl.battery) if pl != null and "battery" in pl else 100

	var cheats: Array[String] = []
	if Game.noclip: cheats.append("NOCLIP")
	if Game.fullbright: cheats.append("FULLBRIGHT")
	if Game.god_mode: cheats.append("GOD")
	if Game.infinite_stamina: cheats.append("INF-STAM")
	if Game.infinite_sanity: cheats.append("INF-SAN")
	if Game.infinite_battery: cheats.append("INF-BATT")
	if Game.freeze_ai: cheats.append("FROZEN")
	var cheats_str: String = ", ".join(cheats) if not cheats.is_empty() else "NONE"

	var ent: Node = root.get_node_or_null("Entity")
	var ent_str := "AWAY"
	if ent != null and ent.is_inside_tree() and ent.is_visible_in_tree() and pl != null:
		var d: float = ent.global_position.distance_to(pl.global_position)
		ent_str = "%s (%.1fm)" % [str(ent.get("state")), d]

	overlay_label.text = "FPS: %d | POS: (%.1f, %.1f, %.1f) | YAW: %d°\nSPEED: %.1f m/s (x%.1f) | HP: %d%% | SAN: %d%% | STM: %d%% | TORCH: %d%%\nCHEATS: [%s]\nBACTERIA: %s" % [
		fps, pos.x, pos.y, pos.z, rot_y,
		spd, Game.speed_mult, hp, san, stm, bat,
		cheats_str,
		ent_str
	]

# ---------------------------------------------------------------- Controls & Handlers
func _set_speed(s: float) -> void:
	Game.speed_mult = s
	if speed_label: speed_label.text = "MOVEMENT / FLY SPEED: %.1fx" % s
	if speed_slider: speed_slider.value = s

func _set_jump(j: float) -> void:
	Game.jump_mult = j
	if jump_label: jump_label.text = "JUMP HEIGHT BOOST: %.1fx" % j
	if jump_slider: jump_slider.value = j

func _refill_flash() -> void:
	var pl := _get_player()
	if pl == null: return
	var ui_node = root.get_node_or_null("UI")
	if ui_node and "inventory" in ui_node and ui_node.inventory != null:
		ui_node.inventory.add_item(FlashPickup.ITEM_ID, FlashPickup.ITEM_NAME, FlashPickup.ITEM_DESC, 5,
			FlashPickup.ITEM_CODE, FlashPickup.STACK, FlashPickup.MODEL_PATH)
		_print("Added 5 Camera Flash charges to inventory.")

func _refill_tape() -> void:
	var pl := _get_player()
	if pl == null: return
	var ui_node = root.get_node_or_null("UI")
	if ui_node and "inventory" in ui_node and ui_node.inventory != null:
		ui_node.inventory.add_item(TapePickup.ITEM_ID, TapePickup.ITEM_NAME, TapePickup.ITEM_DESC, 300,
			TapePickup.ITEM_CODE, TapePickup.STACK, TapePickup.MODEL_PATH)
		_print("Added 300m Reflective Hazard Tape to inventory.")

func _get_player() -> Node:
	return root.get_node_or_null("Player")

func _trigger_blackout() -> void:
	var ev = root.get_node_or_null("Events")
	if ev != null and ev.has_method("run_event"):
		var ok = ev.run_event("powerCut")
		_print("grid blackout: %s" % str(ok))
	else:
		var lvl = root.get_node_or_null("Level")
		if lvl != null and lvl.has_method("cut_power"):
			lvl.cut_power(60.0)
			_print("grid power cut (direct)")
		else:
			_print("[color=orange]Events/Level node not found[/color]")

func _restore_grid() -> void:
	var lvl = root.get_node_or_null("Level")
	if lvl != null:
		if lvl.has_method("restore_all"):
			lvl.restore_all()
		elif lvl.has_method("restore_power"):
			lvl.restore_power()
			if lvl.has_method("set_tint"):
				lvl.set_tint(Color.WHITE)
	var ev = root.get_node_or_null("Events")
	if ev != null and ev.has_method("clear_events"):
		ev.clear_events()
	var pl = _get_player()
	if pl != null and "grid_down" in pl:
		pl.grid_down = false
	var sc = root.get_node_or_null("Scares")
	if sc != null and sc.has_method("grid_on"):
		sc.grid_on()
	_print("grid restored")

func toggle_menu() -> void:
	_toggle(not menu_window.visible)

func open_menu() -> void:
	_toggle(true)

func close_menu() -> void:
	_toggle(false)

func _toggle(on: bool) -> void:
	if on and Game.dead:
		return
	menu_window.visible = on
	if on:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_sync_quick_buttons()
		if current_tab == "console":
			input.clear()
			input.grab_focus()
	else:
		input.release_focus()
		var menu_shown := false
		if root.get_node_or_null("UI") and "menu" in root.get_node("UI") and root.get_node("UI").menu != null:
			menu_shown = root.get_node("UI").menu.shown
		if not Game.dead and not menu_shown:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed and not e.echo):
		return

	# Special toggle buttons: F1, Tilde (`~`), F3
	if e.physical_keycode == KEY_F1 or e.physical_keycode == KEY_QUOTELEFT or e.physical_keycode == KEY_SECTION:
		toggle_menu()
		get_viewport().set_input_as_handled()
		return
	elif e.physical_keycode == KEY_1:
		if not menu_window.visible:
			_switch_tab("console")
			_toggle(true)
		else:
			_toggle(false)
		get_viewport().set_input_as_handled()
		return
	elif menu_window.visible and e.physical_keycode == KEY_ESCAPE:
		_toggle(false)
		get_viewport().set_input_as_handled()
		return
	elif menu_window.visible and current_tab == "console" and e.physical_keycode == KEY_UP:
		_recall(-1)
		get_viewport().set_input_as_handled()
		return
	elif menu_window.visible and current_tab == "console" and e.physical_keycode == KEY_DOWN:
		_recall(1)
		get_viewport().set_input_as_handled()
		return

	if not Game.dev_keys:
		return

	# Survivor model preview hotkeys
	if not menu_window.visible and e.physical_keycode == KEY_M:
		_model_command("")
		get_viewport().set_input_as_handled()
	elif not menu_window.visible and e.physical_keycode == KEY_COMMA:
		_model_command("prev")
		get_viewport().set_input_as_handled()
	elif not menu_window.visible and e.physical_keycode == KEY_PERIOD:
		_model_command("next")
		get_viewport().set_input_as_handled()
	# the arm clip tested last, again
	elif not menu_window.visible and e.physical_keycode == KEY_P:
		_hand_anim(hand_anim_last)
		get_viewport().set_input_as_handled()

# ---------------------------------------------------------------- CLI Commands
func _print(text: String) -> void:
	if log_label != null:
		log_label.append_text(text + "\n")

func _recall(dir: int) -> void:
	if history.is_empty(): return
	history_at = clampi(history_at + dir, 0, history.size())
	input.text = "" if history_at >= history.size() else history[history_at]
	input.caret_column = input.text.length()

func _submit(line: String) -> void:
	input.clear()
	line = line.strip_edges()
	if line == "": return
	history.append(line)
	history_at = history.size()
	_print("[color=cyan]> " + line + "[/color]")
	var raw_lower := line.to_lower().strip_edges()
	if raw_lower in ["hide all hud", "hide hud", "hide all", "hide all huds", "hide all hud and hands", "hide hud and hands", "hide all hud and hand"]:
		Game.hide_hud = true
		_sync_hud_state()
		_print("HUD & Hands: [color=orange]HIDDEN[/color] (Screenshot Mode). Press [b]F1[/b], [b]1[/b] or [b]ESC[/b] to close console and take screenshots.")
		return
	elif raw_lower in ["show all hud", "show hud", "show all", "show all huds", "show all hud and hands", "show hud and hands", "show all hud and hand"]:
		Game.hide_hud = false
		_sync_hud_state()
		_print("HUD & Hands: [color=lime]VISIBLE[/color]")
		return
	elif raw_lower in ["toggle hud", "toggle all hud", "toggle hud and hands", "toggle hud and hand"]:
		Game.hide_hud = not Game.hide_hud
		_sync_hud_state()
		_print("HUD & Hands: " + ("[color=orange]HIDDEN[/color] (Screenshot Mode)" if Game.hide_hud else "[color=lime]VISIBLE[/color]"))
		return
	elif raw_lower in ["hide hand", "hide hands", "hand off", "hands off"]:
		Game.hide_hands = true
		_print("Hands: [color=orange]HIDDEN[/color]")
		return
	elif raw_lower in ["show hand", "show hands", "hand on", "hands on"]:
		Game.hide_hands = false
		_print("Hands: [color=lime]VISIBLE[/color]")
		return
	elif raw_lower in ["toggle hand", "toggle hands"]:
		Game.hide_hands = not Game.hide_hands
		_print("Hands: " + ("[color=orange]HIDDEN[/color]" if Game.hide_hands else "[color=lime]VISIBLE[/color]"))
		return
	elif raw_lower in ["restore grid", "restore the grid", "restore lights", "restore grid lights", "restore grid light", "restore light", "restore power"]:
		_restore_grid()
		return
	elif raw_lower in ["cut power", "power cut", "trigger blackout", "blackout", "lights out", "lights off", "light off", "light out"]:
		_trigger_blackout()
		return

	var parts := line.to_lower().split(" ", false)
	var cmd := parts[0]
	var arg := parts[1] if parts.size() > 1 else ""
	match cmd:
		"help", "?":
			_print("Cheats: noclip, fullbright, god, stamina, sanity <0-100|off>, health <0-100>, speed <mult>")
			_print("Hands: anim <%s> (the menu closes to play it; P plays it again)" % "|".join(HAND_ANIMS.keys()))
			_print("Entities: spawn <name|all>, despawn <name|all>, stalk, eyes [n|off|auto|clear], grabber <hunch|peek|chase|drag>, freeze")
			_print("World: restore grid, lighton, lightout, tp <spawn|mannequin>, archive [list|reset], clearance [reset|add n]")
			_print("HUD / Screenshots: hud [on|off], hands [on|off], screenshot")
			_print("Names: " + ", ".join(ORDER))
		"noclip":
			Game.noclip = not Game.noclip
			_sync_quick_buttons()
			_print("noclip: " + ("ON" if Game.noclip else "OFF"))
		"fullbright", "bright":
			var pl := _get_player()
			if pl and pl.has_method("set_fullbright"):
				pl.set_fullbright(not Game.fullbright)
			else:
				Game.fullbright = not Game.fullbright
			_sync_quick_buttons()
			_print("fullbright: " + ("ON" if Game.fullbright else "OFF"))
		"god", "godmode":
			Game.god_mode = not Game.god_mode
			_sync_quick_buttons()
			_print("god mode: " + ("ON" if Game.god_mode else "OFF"))
		"stamina":
			Game.infinite_stamina = not Game.infinite_stamina
			_sync_quick_buttons()
			_print("infinite stamina: " + ("ON" if Game.infinite_stamina else "OFF"))
		"speed":
			if arg.is_valid_float():
				_set_speed(clampf(arg.to_float(), 0.5, 10.0))
			_print("speed: %.1fx" % Game.speed_mult)
		"list":
			for n in ORDER:
				var on := _active(n)
				_print("  %-10s %s" % [n, "[color=lime]active[/color]" if on else "[color=gray]off[/color]"])
		"grabber":
			_grabber_state(arg)
		"spawn":
			_each(arg, true)
		"despawn", "kill":
			_each(arg, false)
		"freeze":
			Game.freeze_ai = not Game.freeze_ai
			_sync_quick_buttons()
			_print("freeze monsters: " + ("ON" if Game.freeze_ai else "OFF"))
		"tp":
			var pl := _get_player()
			if arg == "mannequin":
				root.get_node("Mannequin").warp_to_room()
				_print("warped to the mannequin room")
			elif arg == "spawn":
				var lvl = root.get_node_or_null("Level")
				if pl != null and lvl != null and "spawn_pos" in lvl:
					pl.global_position = lvl.spawn_pos
					_print("warped to spawn")
			else:
				_print("[color=orange]tp mannequin | tp spawn[/color]")
		"eyes":
			var ey: Node = root.get_node("Eyes")
			if arg == "off":
				ey.debug_set(0)
			elif arg == "auto":
				ey.debug_auto()
			elif arg == "clear":
				ey.debug_clear()
			elif arg.is_valid_int():
				ey.debug_set(clampi(arg.to_int(), 0, ey.MAX_WATCHERS))
			_print(ey.describe())
		"sanity":
			var pl := _get_player()
			if arg == "off":
				pl.sanity_lock = -1.0
			elif arg.is_valid_float():
				pl.sanity_lock = clampf(arg.to_float(), 0.0, 100.0)
				pl.sanity = pl.sanity_lock
			_print("sanity %d%s  health %d" % [int(pl.sanity), " (pinned)" if pl.sanity_lock >= 0.0 else "", int(pl.health)])
		"health":
			var pl := _get_player()
			if arg.is_valid_float():
				pl.health = clampf(arg.to_float(), 0.0, 100.0)
			_print("health %d" % int(pl.health))
		"lightout", "lightsout", "lightsoff", "blackout":
			_trigger_blackout()
		"lighton", "lightson", "restoregrid", "poweron":
			_restore_grid()
		"restore":
			if arg in ["grid", "lights", "light", "power", ""]:
				_restore_grid()
			elif arg == "health":
				var pl := _get_player()
				if pl != null: pl.health = 100.0
				_print("health restored to 100%")
			elif arg == "sanity":
				var pl := _get_player()
				if pl != null:
					pl.sanity = 100.0
					pl.insanity = 0.0
				_print("sanity restored to 100%")
			else:
				_print("[color=orange]restore <grid|health|sanity>[/color]")
		"grid":
			if arg in ["restore", "on", "reset", "up"]:
				_restore_grid()
			elif arg in ["cut", "off", "out", "blackout", "down"]:
				_trigger_blackout()
			else:
				_print("[color=orange]grid <on|off|restore>[/color]")
		"light", "lights", "power":
			if arg in ["on", "restore", "reset", "up"]:
				_restore_grid()
			elif arg in ["off", "out", "cut", "down"]:
				_trigger_blackout()
			else:
				_print("[color=orange]light <on|off>[/color]")
		"archive":
			if arg == "reset":
				Archive.forget_all()
				_print("archive: every entry unlogged")
			else:
				for id in Archive.entities():
					var on := Archive.is_discovered(str(id))
					_print("  %-10s %s" % [id, "[color=lime]logged[/color]" if on else "[color=gray]not logged[/color]"])
		"clearance":
			if arg == "reset":
				Clearance.reset()
			elif arg == "add" and parts.size() > 2 and parts[2].is_valid_int():
				Clearance.grant(parts[2].to_int())
			_print("clearance %s  %d %s  (next tier at %d)" % [Clearance.tier_label(), Clearance.total, Clearance.unit, Clearance.next_threshold()])
		"stalk":
			var ok: bool = root.get_node("Entity").debug_stalk()
			_print("bacteria stalking" if ok else "[color=orange]no stalk spot found here, try another spot[/color]")
		"model":
			_model_command(arg)
		"anim":
			_hand_anim(arg)
		"hud", "hidehud", "showhud", "togglehud":
			if arg == "off" or arg == "hide" or arg == "0":
				Game.hide_hud = true
			elif arg == "on" or arg == "show" or arg == "1":
				Game.hide_hud = false
			elif cmd == "hidehud":
				Game.hide_hud = true
			elif cmd == "showhud":
				Game.hide_hud = false
			else:
				Game.hide_hud = not Game.hide_hud
			_sync_hud_state()
			if Game.hide_hud:
				_print("HUD & Hands: [color=orange]HIDDEN[/color] (Screenshot Mode). Press [b]F1[/b], [b]1[/b] or [b]ESC[/b] to close console and take screenshots.")
			else:
				_print("HUD & Hands: [color=lime]VISIBLE[/color]")
		"hand", "hands", "hidehand", "showhand", "togglehand":
			if arg == "off" or arg == "hide" or arg == "0":
				Game.hide_hands = true
			elif arg == "on" or arg == "show" or arg == "1":
				Game.hide_hands = false
			elif cmd == "hidehand":
				Game.hide_hands = true
			elif cmd == "showhand":
				Game.hide_hands = false
			else:
				Game.hide_hands = not Game.hide_hands
			_print("Hands: " + ("[color=orange]HIDDEN[/color]" if Game.hide_hands else "[color=lime]VISIBLE[/color]"))
		"screenshot", "shot", "snap":
			_take_screenshot()
		"clear":
			log_label.clear()
		_:
			_print("[color=orange]unknown command: " + cmd + "[/color]")

func _take_screenshot() -> void:
	var was_visible := menu_window.visible
	if was_visible:
		menu_window.visible = false
	await get_tree().process_frame
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	if was_visible:
		menu_window.visible = true
	var dir_path := "user://screenshots"
	DirAccess.make_dir_recursive_absolute(dir_path)
	var dt := Time.get_datetime_dict_from_system()
	var filename := "screenshot_%04d%02d%02d_%02d%02d%02d.png" % [
		dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second
	]
	var full_path := dir_path + "/" + filename
	var err := img.save_png(full_path)
	if err == OK:
		var global_path := ProjectSettings.globalize_path(full_path)
		_print("[color=lime]Screenshot saved:[/color] " + global_path)
	else:
		_print("[color=red]Failed to save screenshot (error %d)[/color]" % err)

func _each(arg: String, spawn: bool) -> void:
	if arg == "":
		_print("[color=orange]%s what? %s, or all[/color]" % ["spawn" if spawn else "despawn", ", ".join(ORDER)])
		return
	if arg == "all":
		for n in ORDER:
			_apply(n, spawn)
		return
	arg = ALIASES.get(arg, arg)
	if not ORDER.has(arg):
		_print("[color=orange]unknown entity: " + arg + "[/color]")
		return
	_apply(arg, spawn)

func _node(name: String) -> Node:
	return root.get_node_or_null(ENTITIES[name])

func _active(name: String) -> bool:
	var n := _node(name)
	return n != null and n.debug_active()

## THE GRABBER straight into hunch / peek / chase / drag (console: grabber <state>)
func _grabber_state(st: String) -> void:
	if not GRABBER_STATES.has(st):
		_print("[color=orange]grabber what? %s[/color]" % ", ".join(GRABBER_STATES))
		return
	var n := _node("grabber")
	if n == null:
		_print("[color=orange]grabber is not in the scene[/color]")
		return
	if n.debug_state(st):
		_print("grabber: " + st)
	else:
		_print("[color=orange]grabber: no room to %s here, try another spot[/color]" % st)

func _apply(name: String, spawn: bool) -> void:
	var n := _node(name)
	if n == null:
		_print("[color=orange]%s is not in the scene[/color]" % name)
		return
	if spawn:
		var ok = n.debug_spawn()
		if ok == false:
			var why = n.get("last_error")
			_print("[color=orange]%s: %s[/color]" % [name, why if why else "no room to spawn here, try another spot"])
			return
	else:
		n.debug_despawn()
	_print("%s %s" % [name, "spawned" if spawn else "despawned"])

## Play one of the first-person arms' clips (HAND_ANIMS; console: anim <name>). The menu is closed first
## and the clip held back a moment, so it's watched from its start.
func _hand_anim(what: String) -> void:
	if not HAND_ANIMS.has(what):
		_print("[color=orange]anim what? %s[/color]" % ", ".join(HAND_ANIMS.keys()))
		return
	hand_anim_last = what
	if menu_window.visible:
		_toggle(false)
		await get_tree().create_timer(HAND_ANIM_WAIT).timeout
	var pl := _get_player()
	var torch = pl.get("torch") if pl != null else null
	if torch == null:
		_print("[color=orange]anim %s: no torch model on the player[/color]" % what)
		return
	var why := ""
	if what == "swap":
		if pl.swapping():
			why = "a battery swap is under way"
		else:
			pl.swap_battery(0.0)
	else:
		why = torch.debug_play(HAND_ANIMS[what])
	if why != "":
		_print("[color=orange]anim %s: %s[/color]" % [what, why])
	else:
		_print("anim: " + what)

func _model_command(arg: String) -> void:
	var pl := _get_player()
	if pl == null: return
	if arg == "off" or (arg == "" and is_instance_valid(dbg_model)):
		if is_instance_valid(dbg_model):
			dbg_model.queue_free()
		dbg_model = null
		_print("model dismissed")
		return
	if not is_instance_valid(dbg_model) and not _summon_model(pl):
		_print("[color=orange]survivor model missing or has no animations[/color]")
		return
	if arg == "next" or arg == "prev":
		dbg_anims_idx = posmod(dbg_anims_idx + (1 if arg == "next" else -1), dbg_anims.size())
	elif arg != "" and dbg_anims.has(arg):
		dbg_anims_idx = dbg_anims.find(arg)
	elif arg != "":
		_print("[color=orange]unknown clip: %s. clips: %s[/color]" % [arg, ", ".join(dbg_anims)])
		return
	_play_model_clip()

func _summon_model(pl: Node3D) -> bool:
	var packed := load(SurvivorAnim.MODEL) as PackedScene
	if packed == null: return false
	var inst: Node3D = packed.instantiate()
	var aps := inst.find_children("*", "AnimationPlayer", true, false)
	if aps.is_empty():
		inst.queue_free()
		return false
	dbg_model = Node3D.new()
	dbg_model.name = "DebugModel"
	root.add_child(dbg_model)
	var holder := Node3D.new()
	dbg_model.add_child(holder)
	holder.add_child(inst)
	inst.transform = HazmatFit.fit(inst, holder, 2.0)
	holder.rotation.y = PI
	var ap: AnimationPlayer = aps[0]
	SurvivorAnim.find_clips(ap)
	dbg_anim = ap
	dbg_anims.clear()
	for n in ap.get_animation_list():
		if n != "RESET":
			dbg_anims.append(str(n))
			ap.get_animation(n).loop_mode = Animation.LOOP_LINEAR
	dbg_anims_idx = 0
	var fwd := -pl.global_transform.basis.z
	fwd.y = 0.0
	dbg_model.global_position = pl.global_position + fwd.normalized() * 2.5
	dbg_model.rotation.y = pl.rotation.y
	return not dbg_anims.is_empty()

func _play_model_clip() -> void:
	var clip: String = dbg_anims[dbg_anims_idx]
	dbg_anim.play(clip)
	_print("model clip %d/%d: %s" % [dbg_anims_idx + 1, dbg_anims.size(), clip])
