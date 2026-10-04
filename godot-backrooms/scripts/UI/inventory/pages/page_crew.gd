extends "res://scripts/UI/inventory/terminal_page.gd"
## [F6] CREW: the expedition roster in co-op. Every field researcher on the channel, you first: callsign,
## whether they are alive, in the menu or flatlined, how far off they are, which level and floor, and the
## strength of their signal (Net.signal_of: it fades with distance, and is gone on another floor). The
## terminal rebuilds it every second while it is the open page (inventory.gd _process).

var body: VBoxContainer

func build() -> Control:
	body = _column(8)
	return root

func refresh() -> void:
	if not body:
		return
	clear(body)
	if not Net.is_online() and Net.phantoms.is_empty():
		body.add_child(label("[EXPEDITION ROSTER // NO LINK]", 21, TEXT, 1))
		body.add_child(spacer(12))
		body.add_child(label("SOLO DEPLOYMENT. NO OTHER FIELD RESEARCHERS ON THIS CHANNEL.", 19, TEXT_DIM, 1, true))
		return
	var ids: Array = Net.remotes.keys() if Net.is_online() else []
	body.add_child(label("[EXPEDITION ROSTER // %d IN THE FIELD]" % (ids.size() + 1 + Net.phantoms.size()), 21, TEXT, 1))
	body.add_child(label("HOST: %s" % ("YOU" if Net.hosting or not Net.is_online() else Net.label_for(1)), 15, MUTED, 2))
	body.add_child(spacer(14))
	var me: String = Net.my_name()
	var pl: Node = Game.player
	var my_dead: bool = pl != null and is_instance_valid(pl) and bool(pl.get("dead"))
	_row(me if me != "" else "YOU", "YOU", "FLATLINED" if my_dead else "ALIVE", RED if my_dead else GREEN,
		"--", "LV %d  FL %d" % [Game.level_index + 1, Game.level_floor], -1.0)
	for id in ids:
		var r: Node3D = Net.remotes[id]
		if not is_instance_valid(r):
			continue
		var status := "ALIVE"
		var col := GREEN
		if not r.seen:
			status = "CONNECTING"
			col = MUTED
		elif r.dead:
			status = "FLATLINED"
			col = RED
		elif not r.playing:
			status = "OFF SHIFT"
			col = MUTED
		var dist := "--"
		if r.seen and r.here and pl != null and is_instance_valid(pl):
			dist = "%d M" % roundi((r.global_position - (pl as Node3D).global_position).length())
		var where := "LV %d  FL %d" % [int(r.level_i) + 1, int(r.floor_i)] if r.seen else "--"
		_row(Net.label_for(id), "#%02d" % (int(id) % 100), status, col, dist, where, Net.signal_of(id))
	# the ones who aren't anyone: alive, right where you are
	# (they wander: the distance drifts each time the page is rebuilt, and the signal follows it like anyone's)
	for id in Net.phantoms:
		var ph: Dictionary = Net.phantoms[id]
		ph.dist = clampf(float(ph.dist) + float(ph.drift) + randf_range(-1.2, 1.2), 4.0, 220.0)
		if randf() < 0.04: ph.drift = -float(ph.drift)                     # turned round
		var d: float = ph.dist
		_row(str(ph.name), "#%02d" % (int(id) % 100), "ALIVE", GREEN, "%d M" % roundi(d),
			"LV %d  FL %d" % [Game.level_index + 1, Game.level_floor], 1.0 - smoothstep(Net.SIGNAL_FULL, Net.SIGNAL_LOST, d))

## One researcher: name and tag, then status / distance / location, then the signal gauge (`sig` < 0: us)
func _row(callsign: String, tag: String, status: String, status_col: Color, dist: String, where: String, sig: float) -> void:
	body.add_child(hline(Color(AMBER, 0.25), 1))
	body.add_child(spacer(6))
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 14)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(label(callsign, 23, AMBER, 1))
	var t := label(tag, 15, MUTED, 2)
	t.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(t)
	body.add_child(top)
	var info := HBoxContainer.new()
	info.add_theme_constant_override("separation", 26)
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.add_child(_field("STATUS", status, status_col))
	info.add_child(_field("DIST", dist, TEXT))
	info.add_child(_field("LOCATION", where, TEXT))
	body.add_child(info)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 12)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(label("SIGNAL", 15, MUTED, 2))
	var gauge := cells(10, 4.0, false)
	gauge.custom_minimum_size = Vector2(220, 14)
	gauge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(gauge)
	if sig < 0.0:
		set_cells(gauge, 10, AMBER)
		line.add_child(label("LOCAL", 15, TEXT_DIM, 2))
	else:
		var col := GREEN if sig > 0.6 else (AMBER if sig > 0.25 else RED)
		set_cells(gauge, roundi(sig * 10.0), col)
		line.add_child(label("LOST" if sig <= 0.0 else "%d%%" % roundi(sig * 100.0), 15, col, 2))
	body.add_child(line)
	body.add_child(spacer(8))

func _field(name: String, value: String, col: Color) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var n := label(name, 14, MUTED, 2)
	n.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(n)
	h.add_child(label(value, 18, col, 1))
	return h
