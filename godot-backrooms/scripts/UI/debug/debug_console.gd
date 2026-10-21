extends "res://scripts/UI/debug/debug_console_ui.gd"
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
##  - ANIMATION TEST: a survivor suit walking forward / backward / strafing / diagonals / a circle, walk run or
##    crouch, head looks, death, slow motion ([ ] next move, ; gait, ' head test, / slow motion)
##  - COMMAND CONSOLE: Full command line with history and existing dev commands

func _ready() -> void:
	layer = 120
	process_mode = Node.PROCESS_MODE_ALWAYS
	root = get_parent()
	font = Kit.font(2)
	_build_ui()
	menu_window.visible = false
	Game.hud_visibility_changed.connect(func(_v: bool):
		_sync_hud_state()
	)
	Game.hands_visibility_changed.connect(func(_v: bool):
		_sync_hud_state()
	)
	_sync_hud_state()
	_print("[color=#b3a57a]T.S.R.A. Diagnostic Matrix online. Press [b]F1[/b] or [b]~[/b] for visual menu, [b]help[/b] for commands.[/color]")

# ---------------------------------------------------------------- CLI Commands
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
	_print("[color=#f0a838]> " + line + "[/color]")
	var raw_lower := line.to_lower().strip_edges()
	if raw_lower in ["hide all hud", "hide hud", "hide all", "hide all huds", "hide all hud and hands", "hide hud and hands", "hide all hud and hand"]:
		Game.hide_hud = true
		_sync_hud_state()
		_print("HUD & Hands: [color=#e8702c]HIDDEN[/color] (Screenshot Mode). Press [b]F1[/b], [b]1[/b] or [b]ESC[/b] to close console and take screenshots.")
		return
	elif raw_lower in ["show all hud", "show hud", "show all", "show all huds", "show all hud and hands", "show hud and hands", "show all hud and hand"]:
		Game.hide_hud = false
		_sync_hud_state()
		_print("HUD & Hands: [color=#5de08f]VISIBLE[/color]")
		return
	elif raw_lower in ["toggle hud", "toggle all hud", "toggle hud and hands", "toggle hud and hand"]:
		Game.hide_hud = not Game.hide_hud
		_sync_hud_state()
		_print("HUD & Hands: " + ("[color=#e8702c]HIDDEN[/color] (Screenshot Mode)" if Game.hide_hud else "[color=#5de08f]VISIBLE[/color]"))
		return
	elif raw_lower in ["hide hand", "hide hands", "hand off", "hands off"]:
		Game.hide_hands = true
		_print("Hands: [color=#e8702c]HIDDEN[/color]")
		return
	elif raw_lower in ["show hand", "show hands", "hand on", "hands on"]:
		Game.hide_hands = false
		_print("Hands: [color=#5de08f]VISIBLE[/color]")
		return
	elif raw_lower in ["toggle hand", "toggle hands"]:
		Game.hide_hands = not Game.hide_hands
		_print("Hands: " + ("[color=#e8702c]HIDDEN[/color]" if Game.hide_hands else "[color=#5de08f]VISIBLE[/color]"))
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
			_help(arg)
		"copy":
			DisplayServer.clipboard_set(log_label.get_parsed_text())
			_print("log copied")
		"echo":
			_print(line.substr(4).strip_edges())
		"heal":
			_heal()
		"battery":
			var pl := _get_player()
			if pl != null and arg.is_valid_float():
				pl.battery = clampf(arg.to_float(), 0.0, 100.0)
			_print("torch %d%%" % int(pl.battery) if pl != null else "no player")
		"suicide":
			Game.kill_player("debug console")
		"entities":
			_entity_report()
		"pos", "where":
			_copy_position()
		"mark":
			_mark_here(arg)
		"goto":
			_goto_mark(arg)
		"back":
			_tp_undo()
		"marks":
			if marks.is_empty():
				_print("[color=#b3a57a]no bookmarks: mark <name>[/color]")
			for k in marks:
				var p: Vector3 = marks[k][0]
				_print("  %-10s %.1f, %.1f, %.1f" % [k, p.x, p.y, p.z])
		"levels":
			var idx := 0
			for l in LevelData.read_index():
				_print("  %s%d  %-24s %s" % [">" if idx == Game.level_index else " ", idx, str(l.get("id", "")), str(l.get("name", ""))])
				idx += 1
		"level":
			var all := LevelData.read_index()
			var target := -1
			if arg == "next":
				target = Game.level_index + 1
			elif arg.is_valid_int():
				target = arg.to_int()
			else:
				for i in all.size():
					if str(all[i].get("id", "")).contains(arg) and arg != "":
						target = i
						break
			if target < 0 and arg != "next":
				_print("[color=#e8702c]level what? levels lists them[/color]")
			else:
				_load_level(target)
		"reload":
			_load_level(Game.level_index)
		"timescale", "ts":
			if arg.is_valid_float():
				_set_time_scale(arg.to_float())
			_print("time scale %.2fx" % Engine.time_scale)
		"gfx":
			if Gfx.PRESETS.has(arg):
				Gfx.set_preset(arg)
			_print("graphics: %s  (%s)" % [Gfx.preset, ", ".join(Gfx.PRESETS.keys())])
		"overlay":
			Game.show_debug_overlay = not Game.show_debug_overlay
			_print("telemetry overlay: " + ("ON" if Game.show_debug_overlay else "OFF"))
		"watchkill":
			_watch_kill()
		"fardeath":
			_friend_death_sound(true)
		"neardeath":
			_friend_death_sound(false)
		"lastcrash":
			if not Crash.show_last_crash():
				_print("[color=#e8702c]no crash report saved yet[/color]")
		"crash":
			_print("[color=#ff4636]crashing on purpose...[/color]")
			Crash.test_crash.call_deferred()
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
		"invisible", "invis", "spectate":
			# hidden from other players and monsters; god mode goes with it so nothing near you can kill you
			Game.invisible = not Game.invisible
			Game.god_mode = Game.invisible
			_sync_quick_buttons()
			_print("invisible: " + ("ON (god mode on too)" if Game.invisible else "OFF"))
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
				_print("  %-10s %s" % [n, "[color=#5de08f]active[/color]" if on else "[color=#b3a57a]off[/color]"])
		"amb", "ambience":
			var amb = root.get_node_or_null("Audio/Ambience")
			if amb == null:
				_print("ambience: not running")
			elif arg == "silence":
				var secs := parts[2].to_float() if parts.size() > 2 and parts[2].is_valid_float() else 120.0
				amb.force_silence(secs)
				_print("ambience: silence for %ds (a threat closing in still breaks it)" % int(secs))
			elif arg == "bed":
				var file: String = amb.force_bed()
				_print("ambience: " + (file if file != "" else "no bed imported yet"))
			else:
				_print("ambience: " + amb.status())
		"grabber":
			_grabber_state(arg)
		"burnt", "theburnt":
			_burnt(arg)
		"tallone", "tall":
			if arg in ["scream", "hunt"]: _tallone("debug_" + arg)
			else: _print("tallone what? scream, hunt (or spawn tallone / despawn tallone)")
		"events":
			for k in EVENTS:
				_print("  %-16s %s" % [EVENTS[k][0], EVENTS[k][1]])
		"event":
			var ev = root.get_node_or_null("Events")
			var key := arg.replace("_", "")
			if key in ["stop", "clear", "off"] and ev != null:
				ev.stop_all()                      # ends every running event (and tells the guests, if you host)
				_print("all events stopped")
			elif EVENTS.has(key) and ev != null:
				ev.run_event(EVENTS[key][0])
				_print("event: %s" % EVENTS[key][0])
			else:
				_print("[color=#e8702c]event what? 'events' lists them, 'event stop' ends them all[/color]")
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
			elif arg.is_valid_float() and parts.size() > 2 and parts[2].is_valid_float() and pl != null:
				_tp_to(Vector3(arg.to_float(), pl.global_position.y, parts[2].to_float()))
				_print("warped to %s, %s" % [arg, parts[2]])
			else:
				_print("[color=#e8702c]tp <x> <z> | tp mannequin | tp spawn[/color]")
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
				_print("[color=#e8702c]restore <grid|health|sanity>[/color]")
		"grid":
			if arg in ["restore", "on", "reset", "up"]:
				_restore_grid()
			elif arg in ["cut", "off", "out", "blackout", "down"]:
				_trigger_blackout()
			else:
				_print("[color=#e8702c]grid <on|off|restore>[/color]")
		"light", "lights", "power":
			if arg in ["on", "restore", "reset", "up"]:
				_restore_grid()
			elif arg in ["off", "out", "cut", "down"]:
				_trigger_blackout()
			else:
				_print("[color=#e8702c]light <on|off>[/color]")
		"archive":
			if arg == "reset":
				Archive.forget_all()
				_print("archive: every entry unlogged")
			else:
				for id in Archive.entities():
					var on := Archive.is_discovered(str(id))
					_print("  %-10s %s" % [id, "[color=#5de08f]logged[/color]" if on else "[color=#b3a57a]not logged[/color]"])
		"clearance":
			if arg == "reset":
				Clearance.reset()
			elif arg == "add" and parts.size() > 2 and parts[2].is_valid_int():
				Clearance.grant(parts[2].to_int())
			_print("clearance %s  %d %s  (next tier at %d)" % [Clearance.tier_label(), Clearance.total, Clearance.unit, Clearance.next_threshold()])
		"stalk":
			var ok: bool = root.get_node("Entity").debug_stalk()
			_print("bacteria stalking" if ok else "[color=#e8702c]no stalk spot found here, try another spot[/color]")
		"model":
			_model_command(arg)
		"walker":
			_walker_command(line.to_lower().trim_prefix("walker").strip_edges())
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
				_print("HUD & Hands: [color=#e8702c]HIDDEN[/color] (Screenshot Mode). Press [b]F1[/b], [b]1[/b] or [b]ESC[/b] to close console and take screenshots.")
			else:
				_print("HUD & Hands: [color=#5de08f]VISIBLE[/color]")
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
			_print("Hands: " + ("[color=#e8702c]HIDDEN[/color]" if Game.hide_hands else "[color=#5de08f]VISIBLE[/color]"))
		"screenshot", "shot", "snap":
			_take_screenshot()
		"clear":
			log_label.clear()
		_:
			_print("[color=#e8702c]unknown command: " + cmd + "[/color]")

