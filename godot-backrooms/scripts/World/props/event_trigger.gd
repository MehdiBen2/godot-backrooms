extends Node3D
## An event trigger placed in the level editor (levels/object_types.json "trigger"): an invisible box, `depth`
## cells along its arrow by `scale` across, that runs its event when the player walks into it, `delay`
## seconds later. Once only by default (remembered across floor changes, level_data.gd fired_triggers);
## with `once` off it fires again each time you come back in. The event is one of the director's
## (events.gd run_event: power cut, whisper, knocking...; co-op shares those) or a small local happening run
## here: a caption, the tubes over the box dying or stuttering, silence, a thump, a drone, static. A trigger
## with Text shows it as a caption whatever its event.

const REARM := 5.0             # s: an every-time trigger waits at least this long before it can fire again
const CAPTION_IN := 1.2
const CAPTION_HOLD := 3.5
const CAPTION_OUT := 2.2
const REACH := 2.25            # m past the box's edge a tube still counts as over it (lights_out / flicker)

var level: Node
var key := ""                  # this trigger in level.fired_triggers
var half := Vector3.ONE        # the box's half size in metres: x along the arrow, z across it
var event := "message"
var text := ""
var once := true
var delay := 0.0
var duration := 20.0
var _was_in := false
var _ready_at := 0.0

func setup(l: Node, o: Dictionary, cell: float) -> void:
	level = l
	half = Vector3(float(o.get("depth", 2.0)) * cell * 0.5, 3.0, o.scale * cell * 0.5)
	event = str(o.get("event", "message"))
	text = str(o.get("text", ""))
	once = bool(o.get("once", true))
	delay = maxf(0.0, float(o.get("delay", 0.0)))
	duration = maxf(1.0, float(o.get("duration", 20.0)))
	key = "%d|%.3f|%.3f|%s" % [Game.level_floor, o.pos_x, o.pos_y, event]

func _process(_dt: float) -> void:
	if not Game.playing or level == null: return
	if once and level.fired_triggers.has(key):
		set_process(false)
		return
	var p := Game.player as Node3D
	if p == null or not is_instance_valid(p): return
	var l := global_transform.affine_inverse() * p.global_position
	var inside := absf(l.x) <= half.x and absf(l.z) <= half.z and l.y > -1.0 and l.y < half.y * 2.0
	if inside and not _was_in and Game.time >= _ready_at:
		_ready_at = Game.time + maxf(REARM, delay)
		if once: level.fired_triggers[key] = true
		if delay > 0.0: get_tree().create_timer(delay, false).timeout.connect(_run)
		else: _run()
	_was_in = inside

func _run() -> void:
	var root := level.get_parent()
	var p := Game.player as Node3D
	match event:
		"message":
			pass                               # the caption below is all it does
		"lights_out":
			for f in level.lit:
				if _over(f.pos): level.cut_fixture(f, duration)
		"flicker":
			level.disturb(global_position, maxf(half.x, half.z) + REACH, 1.0)
		"silence":
			var amb := root.get_node_or_null("Audio/Ambience")
			if amb != null: amb.hush_for(0.02, duration)
		"thump", "drone", "static":
			var scares := root.get_node_or_null("Scares")
			if scares == null: return
			match event:
				"thump":
					# a step somewhere behind you, where you just came from
					var at := global_position + Vector3(0, 1.2, 0)
					if p != null: at = p.global_position + p.global_transform.basis.z * 6.0 + Vector3(0, 1.2, 0)
					scares.play_scare("footThump", at, 1.0)
				"drone": scares.play_scare("drone", duration)
				"static": scares.play_scare("staticHit", 1.0)
		_:
			var ev := root.get_node_or_null("Events")
			if ev == null or not ev.run_event(event):
				push_warning("event trigger: no event called '%s'" % event)
	if text.strip_edges() != "":
		_caption(text)

## A tube (world position) over the box, give or take REACH
func _over(pos: Vector3) -> bool:
	var l := global_transform.affine_inverse() * pos
	return absf(l.x) <= half.x + REACH and absf(l.z) <= half.z + REACH

## The text low on the screen in the camcorder's font, fading in and out like a thought
func _caption(t: String) -> void:
	var layer := CanvasLayer.new()
	layer.layer = 6
	add_child(layer)
	var lbl := Label.new()
	lbl.text = t
	lbl.add_theme_font_override("font", load("res://fonts/vcr.ttf"))
	lbl.add_theme_font_size_override("font_size", 26)
	lbl.add_theme_color_override("font_color", Color("e6e1cd"))
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	lbl.add_theme_constant_override("shadow_offset_x", 2)
	lbl.add_theme_constant_override("shadow_offset_y", 2)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	lbl.position = Vector2(-450, -170)
	lbl.size = Vector2(900, 80)
	lbl.modulate.a = 0.0
	layer.add_child(lbl)
	var tw := create_tween()
	tw.tween_property(lbl, "modulate:a", 1.0, CAPTION_IN)
	tw.tween_interval(CAPTION_HOLD)
	tw.tween_property(lbl, "modulate:a", 0.0, CAPTION_OUT)
	tw.tween_callback(layer.queue_free)
