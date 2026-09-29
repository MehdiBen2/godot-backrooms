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
## It keeps out of the way: a row sits faint (IDLE_A, its reading hidden) until it has something to
## say: refilling (stamina getting its breath back, a battery going in; a drain never lights it), at
## or under LIGHT_BELOW, low or critical, or NOISE louder than a walk or heard. Then it comes up with its reading beside the bar,
## and settles back HOLD seconds after it goes quiet.

const Kit := preload("res://scripts/UI/inventory/terminal_kit.gd")
const PlayerScript := preload("res://scripts/Player/player.gd")
const Bacteria := preload("res://scripts/Entities/bacteria/bacteria.gd")
const FootstepsScript := preload("res://scripts/Player/footsteps.gd")

const PANEL := Vector2(322, 168)     # canvas px (1920x1080 layout)
const CURVE := 0.045                 # lens bulge (ui_vhs_overlay distortion, corner-fitted)
const ICON := 24.0
const ROW_GAP := 9
const BAR_H := 11.0
const VALUE_W := 46.0              # the reading right of each bar: "83%", or NOISE's reach "12M"
const IDLE_A := 0.3                  # a row with nothing to say
const HOLD := 2.5                    # s a row stays up after it goes quiet
const FAST := 4.0                    # %/s: rising faster than this counts as refilling
const LIGHT_BELOW := 50.0            # %: at or under this a row stays up
const GLOW := 0.6                    # of the terminal's phosphor glow: less bloom in the corner of your eye
# it rides with the camera like a display on your kit: it lags a turn, bounces with a step or a
# crouch, and tilts with a lean (_sway)
const SWAY_K := 4.5                  # px per rad/s of turn
const SWAY_MAX := Vector2(10.0, 7.0)
const BOB_K := 35.0                  # px per metre the eye moves off its eased height
const HEART_REST := 0.06             # how hard the HEALTH icon swells on a beat at rest ...
const HEART_SCARED := 0.3            # ... and when the heart is racing (heart.gd stress 1)
const ROLL_K := 0.3                  # of the camera's roll
const SHAKE_PX := 3.0                # shaky hands: the most the picture trembles, scared stiff or winded
# damage trail: a sudden loss stays on the bar as dim cells, then drains away (_trail)
const SUDDEN := 2.0                  # % lost in one frame that counts as a hit, not a drain
const TRAIL_HOLD := 0.7              # s it stays before draining
const TRAIL_SPEED := 30.0            # %/s it drains at
const TRAIL_COL := Color(0.949, 0.902, 0.722, 0.5)
# the panel wears down with your sanity (_wear_update): from WEAR_FROM down to nothing it gets more
# scanlines, grain and colour drift, tears more often, rows slip sideways and cells die for a moment
const WEAR_FROM := 60.0
const SEGMENTS := 16
const NOISE_MAX := Bacteria.HEAR_SPRINT * FootstepsScript.TILE_NOISE   # the loudest a step gets
const POP_TIME := 0.8                # s the meter holds a flash's pop
const LIE_BELOW := 40.0              # sanity under this and the readings start to lie now and then
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
var rows := {}                       # name -> {icon, cells, value, shown}
var _t := 0.0
var _heard := 0.0                    # 0..1, eased: how red the NOISE row is
var _lie_k := 0.0                    # 0..1: how often the readings lie (0 above LIE_BELOW)
var _prev_f := Vector3.ZERO          # the camera's facing last frame
var _eye := -1.0                     # eye height over the feet, eased
var _sway := Vector2.ZERO

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
	row.add_theme_constant_override("separation", 10)
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
	var sb := Kit.box(Color(Kit.FILL, 0.5), Color(Kit.AMBER, 0.7), 1, 1)
	sb.set_content_margin_all(2)
	bar.add_theme_stylebox_override("panel", sb)
	bar.custom_minimum_size = Vector2(0, BAR_H)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cells := Kit.cells(SEGMENTS, 2.0, false)
	bar.add_child(cells)
	row.add_child(bar)
	var value := Kit.label("", 15, Kit.TEXT, 1)
	value.custom_minimum_size.x = VALUE_W
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(value)
	row.modulate.a = IDLE_A
	value.modulate.a = 0.0
	rows[key] = {"row": row, "icon": icon, "cells": cells, "value": value, "shown": -1.0, "lie_t": 0.0, "lie": "",
		"speed": 0.0, "active_t": 0.0, "att": 0.0, "last": -1.0, "trail": -1.0, "trail_hold": 0.0,
		"dead": -1, "dead_t": 0.0, "slip": 0.0, "slip_t": 0.0}
	return row

func _process(dt: float) -> void:
	# nothing to show while it is faded out, or once you are dead (the death card has the corner)
	running = (fade_src == null or fade_src.modulate.a > 0.01) and not Game.dead
	super(dt)
	if not running or player == null:
		return
	_t += dt
	var pulse := 0.65 + 0.35 * sin(_t * 15.0)
	_lie_k = clampf((LIE_BELOW - float(player.sanity)) / 30.0, 0.0, 1.0)
	var bat: float = player.battery
	_stat("POWER", bat, _state(bat, PlayerScript.BATTERY_CRIT, PlayerScript.BATTERY_LOW), dt, pulse)
	_stat("STAMINA", player.stamina, "critical" if player.exhausted else "", dt, pulse)
	_stat("SANITY", player.sanity, _state(player.sanity, 25.0, 50.0), dt, pulse)
	var racing: bool = Game.heart != null and is_instance_valid(Game.heart) and bool(Game.heart.get("audible"))
	_stat("HEALTH", player.health, _state(player.health, 25.0, 50.0), dt, pulse, racing)
	_heartbeat()
	_update_noise(dt, pulse)
	_wear_update(dt)
	_sway_update(dt)
	mat.set_shader_parameter("bloom_amt", float(mat.get_shader_parameter("bloom_amt")) * GLOW)

## The HEALTH icon swells on each of the heart's beats (heart.gd's own beat clock, so it lands with
## the sound): a lub at the beat and a smaller dub a fifth of a beat later. At rest it is barely
## there; as fear drives the heart it beats harder and faster, and once the heart is loud enough to
## hear, the row comes up (_stat's alert) so a glance down shows it racing
func _heartbeat() -> void:
	var icon: TextureRect = rows["HEALTH"].icon
	var heart: Node = Game.heart
	if heart == null or not is_instance_valid(heart):
		icon.scale = Vector2.ONE
		return
	var ph := float(heart.get("phase"))
	var stress := clampf(float(heart.get("stress")), 0.0, 1.0)
	var beat := maxf(exp(-ph * 22.0), 0.55 * exp(-absf(ph - 0.2) * 30.0))
	icon.pivot_offset = icon.size * 0.5
	icon.scale = Vector2.ONE * (1.0 + beat * lerpf(HEART_REST, HEART_SCARED, stress))

## Shifts the CRT picture (not the panel, so the anchors stay put): behind a turn (a turn right leaves
## it a little to the left, looking up leaves it low), off the eye's quick ups and downs, and tilted
## with the camera's roll; it eases back to rest when the camera settles
func _sway_update(dt: float) -> void:
	var cam: Camera3D = player.get("cam")
	if cam == null or dt <= 0.0:
		return
	var f := -cam.global_transform.basis.z
	var target := Vector2.ZERO
	if _prev_f != Vector3.ZERO:
		var yaw_rate := wrapf(atan2(f.x, f.z) - atan2(_prev_f.x, _prev_f.z), -PI, PI) / dt
		var pitch_rate := (asin(clampf(f.y, -1.0, 1.0)) - asin(clampf(_prev_f.y, -1.0, 1.0))) / dt
		target = Vector2(yaw_rate, pitch_rate) * SWAY_K
	_prev_f = f
	var eye: float = cam.global_position.y - (player as Node3D).global_position.y
	_eye = eye if _eye < 0.0 else lerpf(_eye, eye, minf(1.0, dt * 4.0))
	target.y += (eye - _eye) * BOB_K
	_sway = _sway.lerp(target.clamp(-SWAY_MAX, SWAY_MAX), minf(1.0, dt * 10.0))
	# shaky hands: a fine 7-12 Hz tremble with fear (the heart's stress) or when winded; still when calm
	var fear := 0.0
	if Game.heart != null and is_instance_valid(Game.heart):
		fear = smoothstep(0.35, 1.0, float(Game.heart.get("stress")))
	var winded := 1.0 if bool(player.get("exhausted")) else clampf((30.0 - float(player.get("stamina"))) / 30.0, 0.0, 1.0)
	var shake := maxf(fear, winded * 0.8)
	var tremor := Vector2(sin(_t * 47.0) + 0.6 * sin(_t * 73.0 + 1.3), sin(_t * 53.0 + 0.7) + 0.6 * sin(_t * 67.0 + 2.1))
	screen.position = _sway + tremor * 0.6 * SHAKE_PX * shake
	screen.pivot_offset = screen.size * 0.5
	screen.rotation = cam.global_rotation.z * ROLL_K + sin(_t * 41.0) * 0.004 * shake

## Low sanity wears the little screen down: more scanlines, grain and colour drift, a tear across it
## now and then, a row slipping sideways for a moment, a cell going dead, and at the very bottom
## the whole picture swimming in and out. Nothing at WEAR_FROM, barely readable at 0
func _wear_update(dt: float) -> void:
	var k := clampf((WEAR_FROM - float(player.sanity)) / WEAR_FROM, 0.0, 1.0)
	mat.set_shader_parameter("scan_amt", 0.14 + 0.32 * k)
	mat.set_shader_parameter("grain_amt", 0.04 + 0.14 * k)
	mat.set_shader_parameter("chroma_amt", 0.0012 + 0.012 * k)
	if randf() < k * k * 1.2 * dt:
		burst(0.2 + 0.5 * k)
	for key in rows:
		var r: Dictionary = rows[key]
		r.slip_t = maxf(0.0, float(r.slip_t) - dt)
		if r.slip_t <= 0.0 and randf() < k * 0.35 * dt:
			r.slip_t = randf_range(0.05, 0.18)
			r.slip = randf_range(-1.0, 1.0) * (4.0 + 14.0 * k)
		(r.row as Control).position.x = float(r.slip) if r.slip_t > 0.0 else 0.0
		r.dead_t = maxf(0.0, float(r.dead_t) - dt)
		if r.dead_t <= 0.0:
			r.dead = -1
			if randf() < k * 0.25 * dt:
				r.dead = randi() % SEGMENTS
				r.dead_t = randf_range(0.3, 0.3 + 1.5 * k)
	content.modulate.a = 1.0 - k * k * 0.35 * (0.5 + 0.5 * sin(_t * 1.7 + sin(_t * 4.3)))

func _state(v: float, crit: float, low: float) -> String:
	if v < crit: return "critical"
	if v < low: return "low"
	return ""

## One row: ease toward `value` (0..100) so drains and recoveries glide, then colour it by `state`
func _stat(key: String, value: float, state: String, dt: float, pulse: float, alert := false) -> void:
	var r: Dictionary = rows[key]
	value = clampf(value, 0.0, 100.0)
	var eased: float = value if r.shown < 0.0 else lerpf(r.shown, value, minf(1.0, dt * 8.0))
	if r.shown >= 0.0 and dt > 0.0:          # how fast it is moving, smoothed
		r.speed = lerpf(float(r.speed), (eased - float(r.shown)) / dt, minf(1.0, dt * 6.0))   # signed: + refilling
	r.shown = eased
	_trail(r, value, eased, dt)
	var col := Kit.AMBER
	match state:
		"low": col = Kit.ORANGE
		"critical": col = Color(Kit.RED, pulse)
	_paint(r, clampi(ceili(eased / 100.0 * SEGMENTS - 0.01), 0, SEGMENTS), col)
	_value(r, _lie(r, "%d%%" % roundi(eased), dt, false), Kit.TEXT if state == "" else col)
	_attend(r, alert or state != "" or eased <= LIGHT_BELOW, float(r.speed) > FAST, dt)

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
	var col := Kit.AMBER.lerp(Color(Kit.RED, pulse), _heard)
	_paint(r, cells, col)
	_value(r, _lie(r, "%dM" % roundi(eased), dt, true), Kit.TEXT.lerp(col, _heard))   # how far your steps carry
	_attend(r, _heard > 0.05, reach > Bacteria.HEAR_WALK * 1.05, dt)

## Low sanity: a reading flicks to a wrong number for a moment (up to about one every two seconds a
## row at the worst), sometimes to nothing a number could be; the bars keep telling the truth
func _lie(r: Dictionary, truth: String, dt: float, metres: bool) -> String:
	r.lie_t = maxf(0.0, float(r.lie_t) - dt)
	if r.lie_t <= 0.0 and _lie_k > 0.0 and randf() < _lie_k * 0.5 * dt:
		r.lie_t = randf_range(0.08, 0.3)
		r.active_t = maxf(float(r.active_t), r.lie_t + 0.2)   # a lie shows itself, even on a quiet row
		if randf() < 0.15:
			r.lie = "??M" if metres else "??%"
		else:
			r.lie = ("%dM" % randi_range(0, 40)) if metres else ("%d%%" % randi_range(0, 100))
	return str(r.lie) if r.lie_t > 0.0 else truth

## Up when it is `alert` (low, critical, half gone, heard) or `busy` (refilling, loud), and HOLD s after;
## otherwise faint with its reading hidden. Comes up quickly, settles slowly
func _attend(r: Dictionary, alert: bool, busy: bool, dt: float) -> void:
	r.active_t = HOLD if busy else maxf(0.0, float(r.active_t) - dt)
	var want := 1.0 if alert or r.active_t > 0.0 else 0.0
	r.att = move_toward(float(r.att), want, dt * (6.0 if want > r.att else 1.2))
	(r.row as Control).modulate.a = lerpf(IDLE_A, 1.0, r.att)
	(r.value as Control).modulate.a = r.att

## The reading beside the bar; the text is only set when it changes (a Label reshapes on every set)
func _value(r: Dictionary, text: String, col: Color) -> void:
	var l: Label = r.value
	if l.text != text:
		l.text = text
	l.add_theme_color_override("font_color", col)

## Damage trail: a sudden loss (more than SUDDEN in one frame: a hit, a sanity shock) leaves the lost
## part on the bar as dim cells for TRAIL_HOLD s, then drains away; a steady drain never leaves one
func _trail(r: Dictionary, value: float, eased: float, dt: float) -> void:
	if float(r.last) >= 0.0 and float(r.last) - value > SUDDEN:
		r.trail = maxf(float(r.trail), float(r.last))
		r.trail_hold = TRAIL_HOLD
	r.last = value
	r.trail_hold = maxf(0.0, float(r.trail_hold) - dt)
	if r.trail_hold <= 0.0:
		r.trail = move_toward(float(r.trail), eased, TRAIL_SPEED * dt)
	r.trail = maxf(float(r.trail), eased)

## The bar's cells (with its trail and any dead cell) and the icon, in the row's colour
func _paint(r: Dictionary, cells: int, col: Color) -> void:
	Kit.set_cells(r.cells, cells, col)
	var trail := clampi(ceili(float(r.trail) / 100.0 * SEGMENTS - 0.01), 0, SEGMENTS)
	Kit.set_extras(r.cells, trail, TRAIL_COL, int(r.dead))
	(r.icon as TextureRect).self_modulate = col
