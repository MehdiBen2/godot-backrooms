extends "res://scripts/UI/crt/crt_layer.gd"
## The HUD's vitals, bottom-left: the TAB terminal's readout (inventory.gd vitals) cut down to a
## a small stack of icons and thin segmented bars, nothing else (no frame, no labels: the icons say
## what each is), drawn on the same amber CRT (crt_layer.gd: phosphor glow, scanlines, grain, tear
## glitches) through a slight lens bulge. A bar goes orange when low and pulses red when critical,
## as in the terminal; the icon takes the bar's colour.
##   POWER    torch battery            STAMINA  sprint left (red while winded)
##   SANITY   the dark wears it down   HEALTH   bleeds away below HURT_SANITY
##   NOISE    how far your footsteps (and a flash going off) carry right now: the Bacteria's own
##            hearing (bacteria_senses.gd), so a crouch-walk on carpet reads short and a sprint on
##            tile fills the bar. While it is close enough to hear you (would_hear) the row pulses
##            red.
## Built by hud.gd into hud_root, so it fades with the rest of the OSD under the terminal and the
## pause menu, and stops rendering while it is faded out.

const Kit := preload("res://scripts/UI/inventory/terminal_kit.gd")
const PlayerScript := preload("res://scripts/Player/player.gd")
const Bacteria := preload("res://scripts/Entities/bacteria/bacteria.gd")
const FootstepsScript := preload("res://scripts/Player/footsteps.gd")

const PANEL := Vector2(350, 222)     # canvas px (1920x1080 layout)
const CURVE := 0.045                 # lens bulge (ui_vhs_overlay distortion, corner-fitted)
const ICON := 30.0
const ROW_GAP := 12
const BAR_H := 16.0
const SEGMENTS := 16
const NOISE_MAX := Bacteria.HEAR_SPRINT * FootstepsScript.TILE_NOISE   # the loudest a step gets
const POP_TIME := 0.8                # s the meter holds a flash's pop
const ROWS := [
	["POWER", "res://textures/ui/terminal_battery.png"],
	["STAMINA", "res://textures/ui/terminal_stamina.png"],
	["SANITY", "res://textures/ui/terminal_sanity.png"],
	["HEALTH", "res://textures/ui/terminal_health.png"],
	["NOISE", "res://textures/ui/terminal_noise.png"],
]

var player: Node                     # player.gd (set by hud.gd)
var entity: Node                     # bacteria.gd, for would_hear (set by hud.gd; may be null)
var flash: Node                      # flash_tool.gd: its pop counts as noise
var fade_src: CanvasItem             # hud_root: nothing to render while it is faded out
var rows := {}                       # name -> {icon, cells, shown}
var _t := 0.0
var _heard := 0.0                    # 0..1, eased: how red the NOISE row is

func _ready() -> void:
	super()
	mat.set_shader_parameter("distortion", CURVE)
	mat.set_shader_parameter("fit_corners", true)
	mat.set_shader_parameter("vignette_amt", 0.1)
	mat.set_shader_parameter("chroma_amt", 0.0012)
	mat.set_shader_parameter("bloom_damp", 0.88)
	_build()
	running = true

func _build() -> void:
	var v := VBoxContainer.new()
	v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	v.offset_left = 4; v.offset_top = 4; v.offset_right = -4; v.offset_bottom = -4
	v.alignment = BoxContainer.ALIGNMENT_END
	v.add_theme_constant_override("separation", ROW_GAP)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(v)
	for r in ROWS:
		v.add_child(_row(r[0], r[1]))

## The icon, then a thin segmented bar in a hairline outline
func _row(key: String, icon_path: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon := TextureRect.new()
	icon.texture = load(icon_path)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(ICON, ICON)
	icon.self_modulate = Kit.AMBER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon)
	var bar := PanelContainer.new()
	var sb := Kit.box(Color(Kit.FILL, 0.5), Color(Kit.AMBER, 0.75), 2, 2)
	sb.set_content_margin_all(4)
	bar.add_theme_stylebox_override("panel", sb)
	bar.custom_minimum_size = Vector2(0, BAR_H)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cells := Kit.cells(SEGMENTS, 3.0, false)
	bar.add_child(cells)
	row.add_child(bar)
	rows[key] = {"icon": icon, "cells": cells, "shown": -1.0}
	return row

func _process(dt: float) -> void:
	running = fade_src == null or fade_src.modulate.a > 0.01
	super(dt)
	if not running or player == null:
		return
	_t += dt
	var pulse := 0.65 + 0.35 * sin(_t * 15.0)
	var bat: float = player.battery
	_stat("POWER", bat, _state(bat, PlayerScript.BATTERY_CRIT, PlayerScript.BATTERY_LOW), dt, pulse)
	_stat("STAMINA", player.stamina, "critical" if player.exhausted else "", dt, pulse)
	_stat("SANITY", player.sanity, _state(player.sanity, 25.0, 50.0), dt, pulse)
	_stat("HEALTH", player.health, _state(player.health, 25.0, 50.0), dt, pulse)
	_update_noise(dt, pulse)

func _state(v: float, crit: float, low: float) -> String:
	if v < crit: return "critical"
	if v < low: return "low"
	return ""

## One row: ease toward `value` (0..100) so drains and recoveries glide, then colour it by `state`
func _stat(key: String, value: float, state: String, dt: float, pulse: float) -> void:
	var r: Dictionary = rows[key]
	value = clampf(value, 0.0, 100.0)
	var eased: float = value if r.shown < 0.0 else lerpf(r.shown, value, minf(1.0, dt * 8.0))
	r.shown = eased
	var col := Kit.AMBER
	match state:
		"low": col = Kit.ORANGE
		"critical": col = Color(Kit.RED, pulse)
	_paint(r, clampi(ceili(eased / 100.0 * SEGMENTS - 0.01), 0, SEGMENTS), col)

## How far your sound carries right now, and whether the Bacteria is in earshot of it
func _update_noise(dt: float, pulse: float) -> void:
	var r: Dictionary = rows["NOISE"]
	var reach := 0.0
	if player.is_moving and not player.dead:
		var base := Bacteria.HEAR_SPRINT if player.is_sprinting else (Bacteria.HEAR_CROUCH if player.is_crouching else Bacteria.HEAR_WALK)
		reach = base * player.step_noise()
	if flash != null and flash.since_fired < POP_TIME:
		reach = maxf(reach, Bacteria.FLASH_POP)
	var heard: bool = entity != null and is_instance_valid(entity) and entity.has_method("would_hear") \
		and entity.would_hear(player.global_position, reach)
	_heard = move_toward(_heard, 1.0 if heard else 0.0, dt * (8.0 if heard else 1.5))
	var eased: float = reach if r.shown < 0.0 else lerpf(r.shown, reach, minf(1.0, dt * (14.0 if reach > r.shown else 3.0)))
	r.shown = eased
	var cells := clampi(ceili(eased / NOISE_MAX * SEGMENTS - 0.01), 0, SEGMENTS)
	_paint(r, cells, Kit.AMBER.lerp(Color(Kit.RED, pulse), _heard))

## The bar's cells and the icon, in the row's colour
func _paint(r: Dictionary, cells: int, col: Color) -> void:
	Kit.set_cells(r.cells, cells, col)
	(r.icon as TextureRect).self_modulate = col
