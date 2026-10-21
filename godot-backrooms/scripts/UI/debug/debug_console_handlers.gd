extends "res://scripts/UI/debug/debug_console_state.gd"
## What the buttons and commands do: spawn / despawn entities, models and hand clips, the animation test walker.

func _guest_locked() -> bool:
	return Net.is_online() and not Net.hosting

func _sync_quick_buttons() -> void:
	_update_toggle_btn(btn_noclip, Game.noclip, "NOCLIP (FLY)", Color(1.000, 0.680, 0.220))
	_update_toggle_btn(btn_fullbright, Game.fullbright, "FULLBRIGHT", Color(1.0, 0.95, 0.3))
	_update_toggle_btn(btn_godmode, Game.god_mode, "GOD MODE", Color(1.0, 0.7, 0.15))
	_update_toggle_btn(btn_inf_stamina, Game.infinite_stamina, "INF STAMINA", Color(0.3, 1.0, 0.45))
	_update_toggle_btn(btn_inf_sanity, Game.infinite_sanity, "INF SANITY", Color(0.85, 0.4, 1.0))
	_update_toggle_btn(btn_inf_torch, Game.infinite_battery, "INF TORCH", Color(1.0, 0.8, 0.25))
	if btn_freeze_ai != null:
		_update_toggle_btn(btn_freeze_ai, Game.freeze_ai, "FREEZE ALL MONSTERS (PAUSE)", Color(1.000, 0.680, 0.220))
	_sync_hud_state()

func _sync_hud_state() -> void:
	if btn_header_hud != null:
		btn_header_hud.text = "SHOW HUD & HANDS" if Game.hide_hud else "HIDE HUD & HANDS"
		var bg := Color(0.450, 0.306, 0.099, 0.9) if Game.hide_hud else Color(0.180, 0.140, 0.072, 0.8)
		var bdr := Color(0.950, 0.646, 0.209, 0.9) if Game.hide_hud else Color(0.500, 0.340, 0.110, 0.6)
		btn_header_hud.add_theme_stylebox_override("normal", _make_box(bg, bdr, 1, 4, 8))
		btn_header_hud.add_theme_stylebox_override("hover", _make_box(bg * 1.3, Color(1.000, 0.680, 0.220), 1, 4, 8))
	if btn_toggle_hud != null:
		_update_toggle_btn(btn_toggle_hud, Game.hide_hud, "HIDE ALL HUD & HANDS (SCREENSHOT MODE)", Color(1.000, 0.680, 0.220))

func _update_toggle_btn(btn: Button, active: bool, label: String, tint: Color) -> void:
	if btn == null: return
	btn.text = ("● " if active else "○ ") + label
	var bg := tint * Color(1, 1, 1, 0.22) if active else Color(0.100, 0.078, 0.040, 0.8)
	var bdr := tint if active else Color(0.350, 0.238, 0.077, 0.5)
	btn.add_theme_stylebox_override("normal", _make_box(bg, bdr, 1, 4, 6))
	btn.add_theme_stylebox_override("hover", _make_box(bg * 1.3, tint, 1, 4, 6))
	btn.add_theme_stylebox_override("pressed", _make_box(bg, bdr, 1, 4, 6))
	btn.add_theme_color_override("font_color", tint if active else Color(0.712, 0.675, 0.525))

func _make_box(bg: Color, bdr: Color, bdr_w := 1, rad := 4, pad := 6) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = bdr
	s.set_border_width_all(bdr_w)
	s.set_corner_radius_all(0)         # the terminal's boxes are square
	s.set_content_margin_all(pad)
	return s

func _get_player() -> Node:
	return root.get_node_or_null("Player")

func _toggle(on: bool) -> void:
	if on and Game.dead:
		return
	if on and _guest_locked():
		gate.visible = true
		gate_input.clear()
		gate_input.editable = false
		gate_msg.text = "LOCKED // ONLY THE HOST CAN USE THIS IN CO-OP"
		gate_msg.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return
	gate_input.editable = true
	if on and not unlocked and gate_msg.text.begins_with("LOCKED"):
		gate_msg.text = "ENTER to confirm, ESC to cancel"
		gate_msg.add_theme_color_override("font_color", Color(0.712, 0.675, 0.525))
	var requires_code = not unlocked and Net.is_online()
	if on and requires_code:
		gate.visible = true
		gate_input.clear()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		gate_input.grab_focus()
		return
	if not on and gate.visible:
		gate.visible = false
		gate_input.release_focus()
		if not Game.dead:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
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
		_print("[color=#5de08f]Screenshot saved:[/color] " + global_path)
	else:
		_print("[color=#ff4636]Failed to save screenshot (error %d)[/color]" % err)

func _each(arg: String, spawn: bool) -> void:
	if arg == "":
		_print("[color=#e8702c]%s what? %s, or all[/color]" % ["spawn" if spawn else "despawn", ", ".join(ORDER)])
		return
	if arg == "all":
		for n in ORDER:
			_apply(n, spawn)
		return
	arg = ALIASES.get(arg, arg)
	if EntityRoster.ROSTER.has(arg):
		_roster_apply(arg, spawn)
		return
	if not ORDER.has(arg):
		_print("[color=#e8702c]unknown entity: " + arg + "[/color]")
		return
	_apply(arg, spawn)

## A model-only entity or character from entity_roster.gd: stood in front of you, or taken away
func _roster_apply(id: String, spawn: bool) -> void:
	var n := EntityRoster.node_for(root, id)
	if n == null:
		_print("[color=#e8702c]unknown entity: " + id + "[/color]")
		return
	if spawn:
		if not n.debug_spawn():
			var why = n.get("last_error")
			_print("[color=#e8702c]%s: %s[/color]" % [id, why if why else "no room to spawn here, try another spot"])
			return
	else:
		n.debug_despawn()
	_print("%s %s" % [id, "spawned" if spawn else "despawned"])

func _node(name: String) -> Node:
	return root.get_node_or_null(ENTITIES[name])

func _active(name: String) -> bool:
	var n := _node(name)
	return n != null and n.debug_active()

## THE TALL ONE straight into the scream (start of the 7 s window) or the hunt (running at you, kills you)
func _tallone(method: String) -> void:
	var n := _node("tallone")
	if n == null:
		_print("[color=#e8702c]tallone is not in the scene[/color]")
		return
	if n.call(method):
		_print("tallone: " + method.trim_prefix("debug_"))
	else:
		_print("[color=#e8702c]tallone: %s[/color]" % n.get("last_error"))

## THE BURNT into one of its moves, or its status (console: burnt <action>)
func _burnt(act: String) -> void:
	var n := _node("burnt")
	if n == null:
		_print("[color=#e8702c]burnt is not in the scene[/color]")
		return
	if act == "status":
		_print(n.debug_status())
		return
	if not BURNT_ACTIONS.has(act):
		_print("[color=#e8702c]burnt what? %s[/color]" % ", ".join(BURNT_ACTIONS))
		return
	var was: bool = n.present
	var ok: bool = n.debug_peek(act == "retreat") if act in ["peek", "retreat"] else n.call("debug_" + act)
	if ok:
		_print("burnt: " + act)
		return
	_print("[color=#e8702c]burnt: %s[/color]" % n.get("last_error"))
	if not was and n.present: n.debug_despawn()          # (spawned for it: not left stood next to you)

## THE GRABBER straight into hunch / peek / chase / drag (console: grabber <state>)
func _grabber_state(st: String) -> void:
	if not GRABBER_STATES.has(st):
		_print("[color=#e8702c]grabber what? %s[/color]" % ", ".join(GRABBER_STATES))
		return
	var n := _node("grabber")
	if n == null:
		_print("[color=#e8702c]grabber is not in the scene[/color]")
		return
	if n.debug_state(st):
		_print("grabber: " + st)
	else:
		_print("[color=#e8702c]grabber: no room to %s here, try another spot[/color]" % st)

func _apply(name: String, spawn: bool) -> void:
	var n := _node(name)
	if n == null:
		_print("[color=#e8702c]%s is not in the scene[/color]" % name)
		return
	if spawn:
		var ok = n.debug_spawn()
		if ok == false:
			var why = n.get("last_error")
			_print("[color=#e8702c]%s: %s[/color]" % [name, why if why else "no room to spawn here, try another spot"])
			return
	else:
		n.debug_despawn()
	_print("%s %s" % [name, "spawned" if spawn else "despawned"])

## Play one of the first-person arms' clips (HAND_ANIMS; console: anim <name>). The menu is closed first
## and the clip held back a moment, so it's watched from its start.
func _hand_anim(what: String) -> void:
	if not HAND_ANIMS.has(what):
		_print("[color=#e8702c]anim what? %s[/color]" % ", ".join(HAND_ANIMS.keys()))
		return
	hand_anim_last = what
	if menu_window.visible:
		_toggle(false)
		await get_tree().create_timer(HAND_ANIM_WAIT).timeout
	var pl := _get_player()
	var torch = pl.get("torch") if pl != null else null
	if torch == null:
		_print("[color=#e8702c]anim %s: no torch model on the player[/color]" % what)
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
		_print("[color=#e8702c]anim %s: %s[/color]" % [what, why])
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
		_print("[color=#e8702c]survivor model missing or has no animations[/color]")
		return
	if arg == "next" or arg == "prev":
		dbg_anims_idx = posmod(dbg_anims_idx + (1 if arg == "next" else -1), dbg_anims.size())
	elif arg != "" and dbg_anims.has(arg):
		dbg_anims_idx = dbg_anims.find(arg)
	elif arg != "":
		_print("[color=#e8702c]unknown clip: %s. clips: %s[/color]" % [arg, ", ".join(dbg_anims)])
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

# ---------------------------------------------------------------- animation test walker
## Puts a walker in front of you (replacing one already out when `fresh`). False if the model is missing.
func _walker_summon(fresh: bool) -> bool:
	var pl := _get_player() as Node3D
	if pl == null:
		return false
	if is_instance_valid(walker):
		if not fresh:
			return true
		walker.queue_free()
	walker = AnimWalker.new()
	walker.name = "AnimWalker"
	if not walker.build(pl.global_rotation.y):
		walker.queue_free()
		walker = null
		_print("[color=#e8702c]survivor model missing or has no animations[/color]")
		return false
	# 3.5 m in front of you, so its lane crosses your view
	var fwd := -pl.global_transform.basis.z
	fwd.y = 0.0
	walker.position = pl.global_position + fwd.normalized() * 3.5
	root.add_child(walker)
	_walker_report()
	return true

func _walker_off() -> void:
	if is_instance_valid(walker):
		walker.queue_free()
	walker = null
	_walker_report()

## Runs `what(walker)`, summoning one first if needed; `close` shuts the menu so it can be seen.
func _walker_do(what: Callable, close: bool) -> void:
	if not _walker_summon(false):
		return
	what.call(walker)
	_walker_report()
	if close and menu_window.visible:
		_toggle(false)

func _walker_command(arg: String) -> void:
	var parts := arg.split(" ", false)
	var a := parts[0] if parts.size() > 0 else ""
	var keys: Array = AnimWalker.MOVES.keys()
	match a:
		"off", "dismiss":
			_walker_off()
			return
		"", "summon":
			_walker_summon(true)
			return
		"next", "prev":
			if _walker_summon(false):
				var i := keys.find(walker.move)
				walker.set_move(keys[posmod(i + (1 if a == "next" else -1), keys.size())])
		"gait":
			if _walker_summon(false):
				var gs: Array = AnimWalker.GAITS
				walker.set_gait(gs[(gs.find(walker.gait) + 1) % gs.size()])
		"walk", "run", "crouch":
			_walker_do(func(w): w.set_gait(a), false)
		"look":
			if _walker_summon(false):
				var ls: Array = AnimWalker.LOOKS.keys()
				var which := parts[1] if parts.size() > 1 else str(ls[(ls.find(walker.look) + 1) % ls.size()])
				walker.set_look(which)
		"die", "dead":
			_walker_do(func(w): w.dead = true, false)
		"snap", "necksnap":
			_walker_do(_walker_snap, false)
		"revive":
			_walker_do(func(w): w.revive(), false)
		"slow":
			_walker_do(func(w): w.time_scale = 1.0 if w.time_scale < 1.0 else 0.25, false)
		_:
			if AnimWalker.MOVES.has(a):
				_walker_do(func(w): w.set_move(a), false)
			else:
				_print("[color=#e8702c]walker what? %s[/color]" % ", ".join(keys))
				return
	_walker_report()

## THE MANNEQUIN's kill as a friend sees it in co-op (mannequin.gd debug_watch_kill): the menu closes to watch
func _watch_kill() -> void:
	var m = root.get_node_or_null("Mannequin")
	if m == null or not m.has_method("debug_watch_kill"):
		return
	if not m.debug_watch_kill():
		_print("Mannequin: can't stage it here (no mannequin on this level, or a kill is already on)")
		return
	_print("Mannequin: a stand-in survivor, a few metres ahead. Keep watching it.")
	if menu_window.visible:
		_toggle(false)

## What a friend's death sounds like from here, without staging it: a far one (their voice reverbed, repeating
## and fading) 30 m off, or a near one (gasp and neck crack) 4 m off, ahead of you
func _friend_death_sound(far: bool) -> void:
	var sc = root.get_node_or_null("Scares")
	var p = _get_player()
	if sc == null or not sc.has_method("friend_death_far") or not p is Node3D:
		_print("Scares: not available here")
		return
	var ahead: Vector3 = -p.global_transform.basis.z
	ahead.y = 0.0
	var pos: Vector3 = p.global_position + ahead.normalized() * (30.0 if far else 4.0)
	if far:
		sc.friend_death_far(pos)
	else:
		sc.friend_death_near(pos)
	_print("Scares: friend dies %s (%d m off)" % ["far" if far else "near", 30 if far else 4])

## The walker's neck snap with the mannequin round it and your blink (as a friend sees it); just the clip if
## this level has no mannequin to be had
func _walker_snap(w: AnimWalker) -> void:
	var m = root.get_node_or_null("Mannequin")
	if m != null and m.has_method("debug_walker_kill") and m.debug_walker_kill(w):
		return
	if not w.snap_neck():
		_print("Walker: the suit has no death_neck_snap clip")

func _walker_report() -> void:
	var text := walker.describe() if is_instance_valid(walker) else "none"
	if walker_status:
		walker_status.text = "WALKER: " + text
	if btn_walker_slow:
		_update_toggle_btn(btn_walker_slow, is_instance_valid(walker) and walker.time_scale < 1.0, "SLOW MOTION 0.25x", Color(0.85, 0.6, 1.0))
	_print("walker: " + text)
