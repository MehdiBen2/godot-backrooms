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
var event_list: Array = []
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
	if event == "custom":
		var ce := str(o.get("custom_event", "")).strip_edges()
		if ce != "":
			event = ce

	text = str(o.get("text", "")).strip_edges()
	if text == "":
		var ce := str(o.get("custom_event", "")).strip_edges()
		if event in ["message", "text"] and ce != "":
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
				elif ev_name in ["message", "text"]:
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
	for ev_name in event_list:
		_execute_event(ev_name)
	if text.strip_edges() != "":
		_caption(text)

func _execute_event(ev: String) -> void:
	var root := level.get_parent()
	var p := Game.player as Node3D
	match ev:
		"message", "text":
			pass                               # the caption below is all it does
		"lights_out":
			var count := 0
			for f in level.lit:
				if _over(f.pos):
					level.cut_fixture(f, duration)
					count += 1
			if count == 0 and not level.lit.is_empty():
				var sorted_lit := level.lit.duplicate()
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
			var entity: Node = root.get_node_or_null("Entity")
			if entity != null and entity.has_method("summon"):
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

## The text low on the screen in the camcorder's font, fading in and out like a thought
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

	var lbl := Label.new()
	lbl.text = t
	if ResourceLoader.exists("res://fonts/vcr.ttf"):
		lbl.add_theme_font_override("font", load("res://fonts/vcr.ttf"))
	lbl.add_theme_font_size_override("font_size", 28)
	lbl.add_theme_color_override("font_color", Color("e6e1cd"))
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
	lbl.add_theme_constant_override("shadow_offset_x", 2)
	lbl.add_theme_constant_override("shadow_offset_y", 2)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	lbl.offset_left = 60
	lbl.offset_right = -60
	lbl.offset_top = -200
	lbl.offset_bottom = -110
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.modulate.a = 0.0
	root_ctrl.add_child(lbl)

	var tw := layer.create_tween()
	tw.tween_property(lbl, "modulate:a", 1.0, CAPTION_IN)
	tw.tween_interval(CAPTION_HOLD)
	tw.tween_property(lbl, "modulate:a", 0.0, CAPTION_OUT)
	tw.tween_callback(layer.queue_free)
