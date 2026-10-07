extends Node3D
## An event trigger placed in the level editor (levels/object_types.json "trigger"): an invisible box, `depth`
## cells along its arrow by `scale` across, that runs its event when the player walks into it, `delay`
## seconds later. Once only by default (remembered across floor changes, level_data.gd fired_triggers);
## with `once` off it fires again each time you come back in. The event is one of the director's
## (events.gd run_event: power cut, whisper, knocking...; co-op shares those) or a small local happening run
## here: a caption, the tubes over the box dying or stuttering, silence, a thump, a drone, static. A trigger
## with Text shows it as a caption whatever its event.
## `context_voice` doesn't fire on the way in: it listens while you are in the box, and when something new
## becomes true of you there (the lights die, your torch goes off or runs low, something comes close, a teammate
## dies, you freeze or bolt...) the machine voice says a line about it (events.gd play_context_voice). At most a
## line every Duration seconds; with Once, only the one.

const Term := preload("res://scripts/UI/inventory/inventory.gd")
const Kit := preload("res://scripts/UI/inventory/terminal_kit.gd")
const CrtLayer := preload("res://scripts/UI/crt/crt_layer.gd")

const REARM := 5.0             # s: an every-time trigger waits at least this long before it can fire again
const CAPTION_IN := 1.2
const CAPTION_HOLD := 3.5
const CAPTION_OUT := 2.2
const REACH := 2.25            # m past the box's edge a tube still counts as over it (lights_out / flicker)

var level: Node
var key := ""                  # this trigger in level.fired_triggers
var half := Vector3.ONE        # the box's half size in metres: x along the arrow, z across it
var event := "message"
var event_list: Array = []
var text := ""
var once := true
var delay := 0.0
var duration := 20.0
var _was_in := false
var _ready_at := 0.0
var listen := false            # context_voice: watching what happens to you while you're in the box
var _ran_once := false         # (Once with context_voice: the other events have run, the voice hasn't spoken)
var _heard: Array = []         # the voice's context tags at the last look
var _pending: Array = []       # ones that became true in here and haven't been said yet
var _look_at := 0.0
var _next_line := 0.0

func setup(l: Node, o: Dictionary, cell: float) -> void:
	level = l
	half = Vector3(float(o.get("depth", 2.0)) * cell * 0.5, 3.0, o.scale * cell * 0.5)
	event = str(o.get("event", "message"))
	if event == "custom":
		var ce := str(o.get("custom_event", "")).strip_edges()
		if ce != "":
			event = ce

	text = str(o.get("text", "")).strip_edges()
	if text == "":
		var ce := str(o.get("custom_event", "")).strip_edges()
		if event in ["message", "text", "alert"] and ce != "":
			text = ce

	event_list.clear()
	var raw_events = o.get("events_list", [])
	if raw_events is Array and not raw_events.is_empty():
		for entry in raw_events:
			var ev_name := ""
			if entry is Dictionary:
				ev_name = str(entry.get("event", ""))
				if ev_name == "custom":
					var c_ev := str(entry.get("custom_event", "")).strip_edges()
					if c_ev != "":
						ev_name = c_ev
				elif ev_name in ["message", "text", "alert"]:
					if text == "":
						var entry_tx := str(entry.get("text", "")).strip_edges()
						if entry_tx != "": text = entry_tx
						else:
							var entry_ce := str(entry.get("custom_event", "")).strip_edges()
							if entry_ce != "": text = entry_ce
			elif entry is String:
				ev_name = str(entry).strip_edges()
			if ev_name != "":
				event_list.append(ev_name)
	if event_list.is_empty():
		event_list.append(event)

	once = bool(o.get("once", true))
	delay = maxf(0.0, float(o.get("delay", 0.0)))
	duration = maxf(1.0, float(o.get("duration", 20.0)))
	key = "%d|%.3f|%.3f|%s" % [Game.level_floor, o.pos_x, o.pos_y, ",".join(event_list)]
	listen = event_list.has("context_voice")
	event_list = event_list.filter(func(e): return e != "context_voice")

func _process(_dt: float) -> void:
	if not Game.playing or level == null: return
	if once and level.fired_triggers.has(key):
		set_process(false)
		return
	var p := Game.player as Node3D
	if p == null or not is_instance_valid(p): return
	var l := global_transform.affine_inverse() * p.global_position
	var inside := absf(l.x) <= half.x and absf(l.z) <= half.z and l.y > -1.0 and l.y < half.y * 2.0
	if inside and not _was_in and Game.time >= _ready_at and not _ran_once:
		_ready_at = Game.time + maxf(REARM, delay)
		if once:
			if listen: _ran_once = true            # (fired for good once the voice has said its line)
			else: level.fired_triggers[key] = true
		if not event_list.is_empty() or text != "":
			if delay > 0.0: get_tree().create_timer(delay, false).timeout.connect(_run)
			else: _run()
	if listen:
		_listen(inside, not _was_in)
	_was_in = inside

## context_voice: a few times a second, what is true of you now that wasn't at the last look; the first chance
## the voice has (not mid-line, Duration since the last one), it says something about it
func _listen(inside: bool, entered: bool) -> void:
	var ev := _director()
	if not inside or ev == null or not ev.has_method("play_context_voice") \
			or preload("res://scripts/Events/events.gd").DISABLED:
		_pending.clear()
		return
	if Game.time < _look_at and not entered:
		return
	_look_at = Game.time + 0.4
	var now: Array = ev._voice_context()
	if entered:
		_heard = now                         # what was already so when you walked in isn't news
		return
	for t in now:
		if not _heard.has(t) and not _pending.has(t):
			_pending.append(t)
	_pending = _pending.filter(func(t): return now.has(t))     # over before it was said: drop it
	_heard = now
	if _pending.is_empty() or Game.time < _next_line or not ev.play_context_voice(_pending):
		return
	_pending.clear()
	_next_line = Game.time + maxf(duration, 8.0)
	if once:
		level.fired_triggers[key] = true

func _director() -> Node:
	var root: Node = level.get_parent() if level != null else null
	if root == null and Game.main != null:
		root = Game.main
	return root.get_node_or_null("Events") if root != null else null

func _run() -> void:
	for ev_name in event_list:
		_execute_event(ev_name)
	if text.strip_edges() != "":
		# "alert": the new prominent upper-center T.S.R.A. terminal CRT alert bar (chime, typewriter, 5s draining life bar)
		# "message" / "text" (and default): TV camcorder message with black box at top of screen
		if event_list.has("alert") or event == "alert":
			show_alert_bar(get_tree(), text, 5.0)
		else:
			_caption(text)

## Run by the host in co-op: monsters (a guest's are puppets of the host's) and the director's events
## (shared by everyone). Everything else here is what this player alone sees and hears.
const HOST_EVENTS := ["spawn_bacteria", "spawn_mimic"]
const LOCAL_EVENTS := ["message", "text", "alert", "context_voice", "lights_out", "flicker", "silence", "thump", "drone", "static",
	"spawn_mannequin", "camera_shake", "sanity_drain", "hallucination"]

func _execute_event(ev: String) -> void:
	if preload("res://scripts/Events/events.gd").DISABLED:
		return                        # TEMP: all events off while hunting a crash
	var root: Node = level.get_parent() if level != null else null
	if root == null and Game.main != null:
		root = Game.main
	var p := Game.player as Node3D
	if Net.is_online() and not Net.hosting and (ev in HOST_EVENTS or ev not in LOCAL_EVENTS):
		Net.send_trigger(ev, p.global_position if p != null else global_position)
		return
	match ev:
		"message", "text", "alert":
			pass                               # the caption/alert bar below is all it does
		"lights_out":
			var count := 0
			for f in level.lit:
				if _over(f.pos):
					level.cut_fixture(f, duration)
					count += 1
			if count == 0 and not level.lit.is_empty():
				var sorted_lit: Array = level.lit.duplicate()
				sorted_lit.sort_custom(func(a, b):
					var da := Vector2(a.pos.x - global_position.x, a.pos.z - global_position.z).length_squared()
					var db := Vector2(b.pos.x - global_position.x, b.pos.z - global_position.z).length_squared()
					return da < db
				)
				for i in mini(2, sorted_lit.size()):
					level.cut_fixture(sorted_lit[i], duration)
		"flicker":
			var r := maxf(maxf(half.x, half.z) + REACH + 4.5, 14.0)
			if level != null and level.has_method("flicker_fixtures"):
				level.flicker_fixtures(global_position, r, maxf(duration, 3.0))
			elif level != null and level.has_method("disturb"):
				level.disturb(global_position, r, 1.0)
			if p != null and p.has_method("trigger_flicker"):
				p.trigger_flicker(minf(maxf(duration, 2.5), 6.0))
			var scares := root.get_node_or_null("Scares")
			if scares != null:
				scares.play_scare("staticHit", 0.6)
		"silence":
			var amb := root.get_node_or_null("Audio/Ambience")
			if amb != null: amb.hush_for(0.02, duration)
		"thump", "drone", "static":
			var scares := root.get_node_or_null("Scares")
			if scares == null: return
			match ev:
				"thump":
					# a step somewhere behind you, where you just came from
					var at := global_position + Vector3(0, 1.2, 0)
					if p != null: at = p.global_position + p.global_transform.basis.z * 6.0 + Vector3(0, 1.2, 0)
					scares.play_scare("footThump", at, 1.0)
				"drone": scares.play_scare("drone", duration)
				"static": scares.play_scare("staticHit", 1.0)
		"spawn_bacteria":
			var entity: Node = root.get_node_or_null("Entity") if root != null else null
			if entity == null and Game.main != null:
				entity = Game.main.get_node_or_null("Entity")
			if entity != null:
				if entity.has_method("spawn_stalk"):
					entity.spawn_stalk(true)
				elif entity.has_method("debug_stalk"):
					entity.debug_stalk()
				elif entity.has_method("summon"):
					var pp := p.global_position if p != null else global_position
					entity.summon(global_position.x, global_position.z, pp.x, pp.z)
		"spawn_mimic":
			var mimic: Node = root.get_node_or_null("Mimic")
			if mimic != null and mimic.has_method("appear"):
				mimic.appear()
		"spawn_mannequin":
			var man: Node = root.get_node_or_null("Mannequin")
			if man != null and man.has_method("warp_to_room"):
				man.warp_to_room()
		"camera_shake":
			if p != null:
				if p.has_method("trigger_flicker"):
					p.trigger_flicker(1.5)
				var heart: Node = root.get_node_or_null("Heart")
				if heart != null and heart.has_method("feed"):
					heart.feed("camera_shake", 0.7)
		"sanity_drain":
			if p != null and "sanity" in p:
				p.sanity = maxf(0.0, p.sanity - 25.0)
		"hallucination":
			var scares := root.get_node_or_null("Scares")
			if scares != null:
				scares.breath_behind(global_position + Vector3(0, 1.2, 0))
				scares.play_scare("staticHit", 0.6)
			if p != null:
				if p.has_method("trigger_flicker"):
					p.trigger_flicker(1.0)
				var heart: Node = root.get_node_or_null("Heart")
				if heart != null and heart.has_method("feed"):
					heart.feed("hallucination", 0.5)
		_:
			var director_ev := root.get_node_or_null("Events")
			if director_ev == null or not director_ev.run_event(ev):
				push_warning("event trigger: no event called '%s'" % ev)

## A tube (world position) over the box, give or take REACH
func _over(pos: Vector3) -> bool:
	var l := global_transform.affine_inverse() * pos
	return absf(l.x) <= half.x + REACH and absf(l.z) <= half.z + REACH

## The TV camcorder message displayed on top of the screen with square black backing
func _caption(t: String) -> void:
	var root: Node = level.get_parent() if level != null else null
	if root == null: root = get_tree().root

	var layer := CanvasLayer.new()
	layer.layer = 25
	root.add_child(layer)

	var root_ctrl := Control.new()
	root_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root_ctrl)

	# a camcorder recording of the words: red and cyan fringes split either side (added over the text),
	# then the text itself with scanlines, grain, tracking jitter and the odd tape tear
	root_ctrl.modulate.a = 0.0

	# A translucent dark backing so the caption is readable against bright walls/lighting
	var font_res: Font = load("res://fonts/vcr.ttf") if ResourceLoader.exists("res://fonts/vcr.ttf") else null
	var font_size := 28
	var max_w := 1600.0
	var text_sz := Vector2(800.0, 36.0)
	if font_res != null:
		text_sz = font_res.get_multiline_string_size(t, HORIZONTAL_ALIGNMENT_CENTER, max_w, font_size)
	else:
		text_sz = Vector2(minf(t.length() * 18.0, max_w), 36.0)
	var pad_x := 36.0
	var pad_y := 14.0
	var bg_w := clampf(text_sz.x + pad_x * 2.0, 240.0, 1720.0)
	var bg_h := maxf(text_sz.y + pad_y * 2.0, 52.0)
	var top_y := 125.0

	var bg := Panel.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.65)
	style.set_corner_radius_all(0)
	bg.add_theme_stylebox_override("panel", style)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_preset(Control.PRESET_CENTER_TOP)
	bg.offset_left = -bg_w * 0.5
	bg.offset_right = bg_w * 0.5
	bg.offset_top = top_y
	bg.offset_bottom = top_y + bg_h
	root_ctrl.add_child(bg)

	for item in [
		{"col": Color(1.0, 0.12, 0.08, 0.75), "split": -2.5, "fringe": true},
		{"col": Color(0.1, 0.85, 1.0, 0.75), "split": 2.5, "fringe": true},
		{"col": Color.WHITE, "split": 0.0, "fringe": false}
	]:
		var lbl := _label_vhs(t, item.col, item.split, item.fringe, font_size)
		lbl.set_anchors_preset(Control.PRESET_CENTER_TOP)
		lbl.offset_left = -bg_w * 0.5
		lbl.offset_right = bg_w * 0.5
		lbl.offset_top = top_y
		lbl.offset_bottom = top_y + bg_h
		root_ctrl.add_child(lbl)

	var tw := layer.create_tween()
	tw.tween_property(root_ctrl, "modulate:a", 1.0, CAPTION_IN)
	tw.tween_interval(CAPTION_HOLD)
	tw.tween_property(root_ctrl, "modulate:a", 0.0, CAPTION_OUT)
	tw.tween_callback(layer.queue_free)

## VHS tape caption shader, the look of an old camcorder recording (the text itself stays put): `split` px
## sideways for the chromatic fringe, horizontal colour bleed / softness, scanlines, grain, a rolling
## brighter band, and now and then a tracking hiccup that tears a few lines sideways. Fringes draw additively.
const VHS_SHADER := """
shader_type canvas_item;
render_mode %s;
uniform vec4 tint = vec4(1.0);
uniform float split = 0.0;
float hash(float n) { return fract(sin(n) * 43758.5453); }
void vertex() {
	VERTEX.x += split;
}
void fragment() {
	float tick = floor(TIME * 24.0);
	float band = floor(FRAGCOORD.y / 16.0);
	float tracking = step(0.97, hash(floor(TIME * 3.0) * 1.73));      // a rare tracking hiccup
	float tear = step(0.9 - tracking * 0.5, hash(band + tick * 3.1)) * (hash(floor(FRAGCOORD.y / 3.0) + tick) - 0.5);
	vec2 uv = UV + vec2(tear * 5.0 * TEXTURE_PIXEL_SIZE.x, 0.0);
	vec2 px = vec2(TEXTURE_PIXEL_SIZE.x, 0.0);
	// tape bleed: the signal smears to the right, a soft trail rather than crisp edges
	vec4 c = texture(TEXTURE, uv) * 0.55 + texture(TEXTURE, uv - px) * 0.25 + texture(TEXTURE, uv - px * 2.0) * 0.2;
	c *= COLOR * tint;
	float scan = 0.72 + 0.28 * sin(FRAGCOORD.y * 3.14159);
	float grain = 0.8 + 0.4 * hash(FRAGCOORD.x * 0.37 + FRAGCOORD.y * 91.7 + TIME * 61.0);
	float roll = 1.0 + 0.35 * (1.0 - smoothstep(0.0, 0.04, abs(fract(SCREEN_UV.y * 0.8 - TIME * 0.18) - 0.5)));
	c.rgb *= scan * grain * roll;
	c.a *= 0.85 + 0.15 * hash(tick * 0.31);
	COLOR = c;
}
"""
static var _vhs_mix: Shader
static var _vhs_add: Shader
static var _active_alert_layer: CanvasLayer = null

static func _label_vhs(t: String, tint: Color, split: float, fringe: bool, font_size := 28) -> Label:
	if _vhs_mix == null:
		_vhs_mix = Shader.new(); _vhs_mix.code = VHS_SHADER % "blend_mix"
		_vhs_add = Shader.new(); _vhs_add.code = VHS_SHADER % "blend_add"
	var lbl := Label.new()
	lbl.text = t
	if ResourceLoader.exists("res://fonts/vcr.ttf"):
		lbl.add_theme_font_override("font", load("res://fonts/vcr.ttf"))
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", Color("e6e1cd"))
	if not fringe:
		lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
		lbl.add_theme_constant_override("shadow_offset_x", 2)
		lbl.add_theme_constant_override("shadow_offset_y", 2)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = _vhs_add if fringe else _vhs_mix
	mat.set_shader_parameter("tint", tint)
	mat.set_shader_parameter("split", split)
	lbl.material = mat
	return lbl

## Prominent upper-center alert bar in T.S.R.A. terminal style (CRT bloom, typewriter text, draining life bar, chime)
static func show_alert_bar(tree: SceneTree, t: String, duration := 5.0) -> void:
	if tree == null or tree.root == null: return
	if is_instance_valid(_active_alert_layer):
		_active_alert_layer.queue_free()
		_active_alert_layer = null

	var canvas_layer := CanvasLayer.new()
	canvas_layer.layer = 26
	canvas_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	_active_alert_layer = canvas_layer
	tree.root.add_child(canvas_layer)

	var root_ctrl := Control.new()
	root_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_ctrl.process_mode = Node.PROCESS_MODE_ALWAYS
	canvas_layer.add_child(root_ctrl)

	# Determine accent color and text breakdown
	var upper := t.to_upper()
	var accent: Color = Term.AMBER
	if "LOST" in upper or "FLATLINE" in upper or "DANGER" in upper or "CRITICAL" in upper or "DEAD" in upper or "DECEASED" in upper or "FAIL" in upper:
		accent = Term.RED
	elif "LINK" in upper or "ESTABLISHED" in upper or "ON SITE" in upper or "JOINED" in upper or "RESTORE" in upper or "CLEAR" in upper or "CONNECTED" in upper:
		accent = Term.GREEN

	var code_part := "T.S.R.A. FIELD BROADCAST"
	var tag_part := "ALERT NOTIFICATION"
	var body_part := t.strip_edges()

	if t.contains("//"):
		var parts := t.split("//", false, 1)
		var left := parts[0].strip_edges()
		var right := parts[1].strip_edges()
		if left.begins_with("["):
			tag_part = left.trim_prefix("[").trim_suffix("]").strip_edges()
			body_part = right
		else:
			tag_part = right.trim_prefix("[").trim_suffix("]").strip_edges()
			body_part = left
	elif body_part.begins_with("[") and body_part.contains("]"):
		var close_idx := body_part.find("]")
		tag_part = body_part.substr(1, close_idx - 1).strip_edges()
		body_part = body_part.substr(close_idx + 1).strip_edges()

	var font_body := Kit.font(1.0)
	var font_head := Kit.font(2.0)
	var body_sz := font_body.get_string_size(body_part, HORIZONTAL_ALIGNMENT_LEFT, -1, 18)
	var header_sz := font_head.get_string_size(code_part + " // " + tag_part, HORIZONTAL_ALIGNMENT_LEFT, -1, 12)

	var INSET := 22.0
	var RIGHT_PAD := 22.0
	var TOP_PAD := 12.0
	var BOTTOM_PAD := 12.0
	var PAD := 26.0

	var max_inner := 820.0
	var inner_w := clampf(maxf(body_sz.x, header_sz.x), 380.0, max_inner)
	var w := inner_w + INSET + RIGHT_PAD
	var is_wrap := body_sz.x > (max_inner - 20.0)
	var h := 74.0 if not is_wrap else 94.0

	var total_w := w + PAD * 2.0
	var total_h := h + PAD * 2.0
	var top_y := 115.0

	var layer := CrtLayer.new()
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	layer.size = Vector2(total_w, total_h)
	layer.aberration = 1.2
	root_ctrl.add_child(layer)

	layer.set_anchors_preset(Control.PRESET_CENTER_TOP)
	layer.offset_left = -total_w * 0.5
	layer.offset_right = total_w * 0.5
	layer.offset_top = top_y - PAD
	layer.offset_bottom = top_y - PAD + total_h

	var sheet := Control.new()
	sheet.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sheet.position = Vector2(PAD, PAD)
	sheet.size = Vector2(w, h)
	layer.content.add_child(sheet)

	var life_ref := {"val": 1.0}
	var chamfer := 10.0
	var line_w := 1.0
	var bar_w := 3.0

	sheet.draw.connect(func():
		var cur_w := sheet.size.x
		var cur_h := sheet.size.y
		if cur_h <= chamfer * 2.0: return
		var shape := PackedVector2Array([
			Vector2(0, 0),
			Vector2(cur_w - chamfer, 0),
			Vector2(cur_w, chamfer),
			Vector2(cur_w, cur_h),
			Vector2(0, cur_h)
		])
		sheet.draw_colored_polygon(shape, Term.FILL)
		shape.append(Vector2(0, 0))
		sheet.draw_polyline(shape, Color(accent, 0.32), line_w, true)
		sheet.draw_line(Vector2(cur_w - chamfer, 0), Vector2(cur_w, chamfer), Color(accent, 0.85), line_w + 1.0, true)
		# Left-edge life bar track
		sheet.draw_rect(Rect2(0.0, 0.0, bar_w, cur_h), Color(accent, 0.18))
		if life_ref.val > 0.0:
			sheet.draw_rect(Rect2(0.0, cur_h * (1.0 - life_ref.val), bar_w, cur_h * life_ref.val), accent)
	)

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 3)
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.position = Vector2(INSET, TOP_PAD)
	body.size = Vector2(inner_w, 0.0)
	sheet.add_child(body)

	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 8)
	header_row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var code_lbl := Label.new()
	code_lbl.text = code_part
	code_lbl.add_theme_font_override("font", font_head)
	code_lbl.add_theme_font_size_override("font_size", 12)
	code_lbl.add_theme_color_override("font_color", Term.MUTED)
	code_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header_row.add_child(code_lbl)

	var sep_lbl := Label.new()
	sep_lbl.text = "//"
	sep_lbl.add_theme_font_override("font", font_head)
	sep_lbl.add_theme_font_size_override("font_size", 12)
	sep_lbl.add_theme_color_override("font_color", Color(Term.MUTED, 0.45))
	sep_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header_row.add_child(sep_lbl)

	var tag_lbl := Label.new()
	tag_lbl.text = tag_part
	tag_lbl.add_theme_font_override("font", font_head)
	tag_lbl.add_theme_font_size_override("font_size", 12)
	tag_lbl.add_theme_color_override("font_color", accent)
	tag_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header_row.add_child(tag_lbl)
	body.add_child(header_row)

	var rule_margin := MarginContainer.new()
	rule_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rule_margin.add_theme_constant_override("margin_top", 1)
	rule_margin.add_theme_constant_override("margin_bottom", 2)

	var rule := ColorRect.new()
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rule.color = Color(accent, 0.35)
	rule.custom_minimum_size = Vector2(inner_w, 1.0)
	rule.scale.x = 0.001
	rule_margin.add_child(rule)
	body.add_child(rule_margin)

	var msg_lbl := Label.new()
	msg_lbl.text = body_part
	msg_lbl.add_theme_font_override("font", font_body)
	msg_lbl.add_theme_font_size_override("font_size", 18)
	msg_lbl.add_theme_color_override("font_color", Term.TEXT)
	msg_lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	msg_lbl.add_theme_constant_override("shadow_offset_y", 2)
	msg_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	msg_lbl.visible_characters_behavior = TextServer.VC_CHARS_AFTER_SHAPING
	msg_lbl.visible_ratio = 0.0
	if is_wrap:
		msg_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		msg_lbl.custom_minimum_size.x = inner_w
	body.add_child(msg_lbl)

	# Sound effect
	if ResourceLoader.exists("res://audio/terminal/terminal_logged.wav"):
		var chime := AudioStreamPlayer.new()
		chime.stream = load("res://audio/terminal/terminal_logged.wav")
		chime.volume_db = -14.0
		root_ctrl.add_child(chime)
		chime.play()

	# Start CRT layer
	layer.running = true
	layer.burst(0.6)

	# Animation
	sheet.modulate.a = 0.0
	var home_y := layer.offset_top
	var slide_dist := 24.0
	layer.offset_top = home_y - slide_dist
	layer.offset_bottom = layer.offset_top + total_h

	var tw := canvas_layer.create_tween()
	tw.set_parallel(true)
	tw.tween_property(layer, "offset_top", home_y, 0.3).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(layer, "offset_bottom", home_y + total_h, 0.3).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_method(func(x: float): if is_instance_valid(sheet): sheet.modulate.a = Term.flicker(x), 0.0, 1.0, 0.3)

	tw.tween_property(rule, "scale:x", 1.0, 0.3).set_delay(0.08).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	var type_dur := clampf(body_part.length() * 0.012, 0.1, 0.35)
	tw.tween_property(msg_lbl, "visible_ratio", 1.0, type_dur).set_delay(0.08)

	tw.set_parallel(false)
	tw.tween_method(func(v: float):
		life_ref.val = v
		if is_instance_valid(sheet): sheet.queue_redraw()
	, 1.0, 0.0, duration)

	tw.tween_callback(func():
		if is_instance_valid(layer): layer.burst(0.35)
	)
	tw.set_parallel(true)
	tw.tween_property(layer, "offset_top", home_y - slide_dist, 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(layer, "offset_bottom", home_y - slide_dist + total_h, 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(sheet, "modulate:a", 0.0, 0.25)

	tw.chain().tween_callback(func():
		if _active_alert_layer == canvas_layer:
			_active_alert_layer = null
		canvas_layer.queue_free()
	)
