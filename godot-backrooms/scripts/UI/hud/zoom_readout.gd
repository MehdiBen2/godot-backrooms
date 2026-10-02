extends Control
## Camcorder viewfinder while the lens is up (scripts/Player/zoom_tool.gd, hold E). It shows only what a
## camcorder's own display does, burned into the picture like the REC block (hud.gd's OSD layer, same
## tape treatment): the zoom scale along the bottom, W to T with a tick at each doubling and the
## magnification beside it. It appears while the motor runs and slips away a couple of seconds after.
## The autofocus still works (the picture softens while it hunts); it just has no frame drawn.
## The lens grade (shaders/cam_zoom.gdshader) sits on a canvas layer of its own under the HUD (hud.gd), so
## this only feeds it; the HUD's brackets and text are not blurred by it.

const ZoomTool := preload("res://scripts/Player/zoom_tool.gd")
const CrtLayer := preload("res://scripts/UI/crt/crt_layer.gd")

const CREAM := Color("e4ddbe")
const SCALE_W := 360.0           # px at 1080p
const SCALE_BOTTOM := 112.0
const BAR_HOLD := 2.2            # s the scale stays after the lens stops

var zoom: Node                   # zoom_tool.gd (set by hud.gd)
var player: Node
var grade_mat: ShaderMaterial    # cam_zoom.gdshader on the layer under the HUD (set by hud.gd)
var grade_rect: CanvasItem       # the rect wearing it: hidden while the lens is down
var layer: CrtLayer
var canvas: Control
var font := FontVariation.new()
var t := 0.0
var alpha := 0.0                 # the whole display, with the raise
var bar := 0.0                   # eased 0..1: the zoom scale
var bar_hold := 0.0
var shown_zoom := 1.0            # the scale's figure, eased a touch so it reads as it runs

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font.base_font = load("res://fonts/vcr.ttf")
	font.spacing_glyph = 2
	font.variation_embolden = 0.5
	layer = CrtLayer.new()
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(layer)
	# the same burned-in treatment as the REC block (hud.gd)
	layer.mat.set_shader_parameter("split_px", 1.6)
	layer.mat.set_shader_parameter("ghost_px", 5.0)
	layer.mat.set_shader_parameter("ghost_amt", 0.22)
	layer.mat.set_shader_parameter("flicker_amt", 0.07)
	layer.mat.set_shader_parameter("scan_amt", 0.12)
	layer.mat.set_shader_parameter("grain_amt", 0.08)
	layer.mat.set_shader_parameter("bloom_tint", 0.0)
	layer.glow_scale = 0.4
	canvas = Control.new()
	canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.draw.connect(_draw_canvas)
	layer.content.add_child(canvas)

func _process(dt: float) -> void:
	if zoom == null:
		return
	t += dt
	var up: float = zoom.up
	alpha = move_toward(alpha, 1.0 if up > 0.0 else 0.0, dt * 6.0) if up < 1.0 else 1.0
	if grade_mat != null and grade_rect != null:
		grade_mat.set_shader_parameter("amount", up)
		grade_mat.set_shader_parameter("zoom", zoom.magnification())
		grade_mat.set_shader_parameter("lod", zoom.blur)
		grade_mat.set_shader_parameter("anomaly", zoom.anomaly)
		var vp := get_viewport_rect().size
		grade_mat.set_shader_parameter("aspect", vp.x / maxf(vp.y, 1.0))
		grade_rect.visible = up > 0.001
	if up <= 0.001:
		layer.running = false
		bar = 0.0
		bar_hold = 0.0
		return
	layer.running = true
	# the burned-in text tears now and then while something is in the lens
	if zoom.anomaly > 0.15 and randf() < dt * 2.5 * zoom.anomaly:
		layer.burst(0.35 * zoom.anomaly)
	if zoom.motor > 0.05 or zoom.up < 1.0:
		bar_hold = BAR_HOLD
	else:
		bar_hold = maxf(0.0, bar_hold - dt)
	bar = move_toward(bar, 1.0 if bar_hold > 0.0 else 0.0, dt * (9.0 if bar_hold > 0.0 else 2.5))
	shown_zoom = lerpf(shown_zoom, zoom.magnification(), minf(1.0, dt * 14.0))
	canvas.queue_redraw()

func _c(a := 1.0) -> Color:
	return Color(CREAM, CREAM.a * a * alpha)

func _text(pos: Vector2, s: String, px: int, a: float, align := HORIZONTAL_ALIGNMENT_LEFT, width := -1.0) -> void:
	canvas.draw_string(font, pos.round(), s, align, width, px, _c(a))

func _stroke(a: Vector2, b: Vector2, w: float, al: float) -> void:
	canvas.draw_line(a.round() + Vector2(0.5, 0.5), b.round() + Vector2(0.5, 0.5), _c(al), w)

func _draw_canvas() -> void:
	if zoom == null or alpha <= 0.001:
		return
	var k := canvas.size.y / 1080.0
	if bar > 0.01:
		_draw_scale(canvas.size, k)


## W--T scale: a tick per doubling (1x 2x 4x 8x), a marker, and the magnification on the left
func _draw_scale(sz: Vector2, k: float) -> void:
	var w := SCALE_W * k
	var x0 := sz.x * 0.5 - w * 0.5
	var y := sz.y - SCALE_BOTTOM * k
	var a := bar
	var share := clampf(log(shown_zoom) / log(ZoomTool.ZOOM_MAX), 0.0, 1.0)
	_stroke(Vector2(x0, y), Vector2(x0 + w, y), 1.0 * k, 0.45 * a)
	for i in 4:
		var tx := x0 + w * float(i) / 3.0
		_stroke(Vector2(tx, y - 5.0 * k), Vector2(tx, y + 5.0 * k), 1.0 * k, 0.7 * a)
		_text(Vector2(tx - 20.0 * k, y + 28.0 * k), "%dX" % (1 << i), int(14 * k), 0.6 * a, HORIZONTAL_ALIGNMENT_CENTER, 40.0 * k)
	_stroke(Vector2(x0, y), Vector2(x0 + w * share, y), 3.0 * k, a)
	var mx := x0 + w * share
	canvas.draw_colored_polygon(PackedVector2Array([
		Vector2(mx, y - 4.0 * k).round(), Vector2(mx - 6.0 * k, y - 14.0 * k).round(), Vector2(mx + 6.0 * k, y - 14.0 * k).round()]), _c(a))
	_text(Vector2(x0 - 54.0 * k, y + 6.0 * k), "W", int(17 * k), 0.8 * a)
	_text(Vector2(x0 + w + 36.0 * k, y + 6.0 * k), "T", int(17 * k), 0.8 * a)
	_text(Vector2(x0, y - 30.0 * k), "ZOOM  %.1fX" % shown_zoom, int(20 * k), a)
