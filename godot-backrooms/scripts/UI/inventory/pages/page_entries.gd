extends "res://scripts/UI/inventory/terminal_page.gd"
## [F3] ENTRIES: every catalogued entity, a list on the left (redacted until scanned, NEW until
## opened), the chosen one's full entry on the right. Arrows / clicks pick one; the dossier's
## phenomena rows open theirs here (open_entry).

var entries_title: Label
var entries_list: VBoxContainer
var entry_detail: VBoxContainer
var entry_ids: Array = []            # every catalogued entity, in code order
var entry_rows: Array = []           # one PanelContainer per entry
var entry_sel := 0

func build() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	entries_title = label("[ANOMALY ENTRIES]", 21, TEXT, 1)
	v.add_child(entries_title)
	v.add_child(spacer(14))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(row)
	var list_scroll := scroll()
	list_scroll.custom_minimum_size.x = 250
	entries_list = scroll_body(list_scroll, 6)
	row.add_child(list_scroll)
	var div := ColorRect.new()
	div.color = Color(AMBER, 0.35)
	div.custom_minimum_size = Vector2(2, 0)
	div.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(div)
	scroll_box = scroll()
	scroll_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	entry_detail = scroll_body(scroll_box, 6)
	row.add_child(scroll_box)
	root = v
	return root

func hoverables() -> Array:
	return entry_rows

func refresh() -> void:
	if not entries_list:
		return
	var all := Archive.entities()
	entry_ids = all.keys()
	entry_ids.sort_custom(func(a, b): return str(all[a].get("code", "")) < str(all[b].get("code", "")))
	var logged := 0
	for id in entry_ids:
		if Archive.is_discovered(str(id)): logged += 1
	entries_title.text = "[ANOMALY ENTRIES // %d OF %d LOGGED]" % [logged, entry_ids.size()]
	clear(entries_list)
	entry_rows.clear()
	for i in entry_ids.size():
		var row := _entry_row(i, str(entry_ids[i]))
		entries_list.add_child(row)
		entry_rows.append(row)
	entry_sel = clampi(entry_sel, 0, maxi(entry_ids.size() - 1, 0))
	for i in entry_rows.size():
		_style_entry_row(i)
	_show_entry()

## A list row: the code (and NEW until it is opened), the name under it; redacted until logged
func _entry_row(i: int, id: String) -> Control:
	var logged := Archive.is_discovered(id)
	var info := Archive.entity_info(id)
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.set_meta("hover", false)
	p.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			select_entry(i)
	)
	p.mouse_entered.connect(func(): p.set_meta("hover", true); _style_entry_row(i))
	p.mouse_exited.connect(func(): p.set_meta("hover", false); _style_entry_row(i))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var top := HBoxContainer.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var code := label(str(info.get("code", "TSRA-EN-??")) if logged else "TSRA-EN-??", 19, TEXT if logged else TEXT_DIM, 1)
	code.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(code)
	var badge := label("NEW", 15, AMBER, 2)
	badge.visible = Archive.is_unread(id)
	top.add_child(badge)
	v.add_child(top)
	var nm := label(str(info.get("common_name", id)).to_upper() if logged else "UNREGISTERED", 15, TEXT_DIM, 1)
	nm.clip_text = true
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	v.add_child(nm)
	p.add_child(v)
	p.set_meta("code", code)
	p.set_meta("badge", badge)
	p.set_meta("logged", logged)
	return p

func _style_entry_row(i: int) -> void:
	if i >= entry_rows.size():
		return
	var p: PanelContainer = entry_rows[i]
	var sel := i == entry_sel
	var bg := Color(0, 0, 0, 0)
	if sel: bg = Color(AMBER, 0.16)
	elif p.get_meta("hover"): bg = Color(AMBER, 0.07)
	var sb := box(bg, AMBER)
	sb.border_width_left = LINE if sel else 0
	sb.content_margin_left = 12; sb.content_margin_right = 10
	sb.content_margin_top = 5; sb.content_margin_bottom = 5
	p.add_theme_stylebox_override("panel", sb)
	var logged: bool = p.get_meta("logged")
	(p.get_meta("code") as Label).add_theme_color_override("font_color", AMBER if sel else (TEXT if logged else TEXT_DIM))

func select_entry(i: int, quiet := false) -> void:
	if entry_ids.is_empty():
		return
	i = clampi(i, 0, entry_ids.size() - 1)
	if i != entry_sel and not quiet: term.play_sfx("select")
	entry_sel = i
	for j in entry_rows.size():
		_style_entry_row(j)
	_show_entry()

## The arrows: the next / previous entry
func step(delta: int) -> void:
	select_entry(entry_sel + delta)

## [F3] from the dossier's phenomena list: straight to that entity's entry (built before the page
## switch, so it types in with the rest of the page)
func open_entry(id: String) -> void:
	var i := entry_ids.find(id)
	if i >= 0 and i != entry_sel:
		entry_sel = i
		for j in entry_rows.size():
			_style_entry_row(j)
		_show_entry()
	term.select_tab("ENTRIES", false, false)
	_mark_seen()

## The entry on show is no longer new once it has been opened on [F3]
func _mark_seen() -> void:
	if entry_ids.is_empty() or not term.shown or term.active_page != "ENTRIES":
		return
	var id := str(entry_ids[entry_sel])
	if Archive.is_discovered(id) and Archive.is_unread(id):
		Archive.mark_read(id)
		(entry_rows[entry_sel].get_meta("badge") as Label).visible = false
		term.readout.queue_redraw()

## Arriving on [F3] with something new logged: that one first
func focus_unread() -> void:
	for i in entry_ids.size():
		if Archive.is_unread(str(entry_ids[i])):
			select_entry(i, true)
			return

func _show_entry() -> void:
	if not entry_detail:
		return
	clear(entry_detail)
	if entry_ids.is_empty():
		entry_detail.add_child(label("NO ENTRIES CATALOGUED.", 19, TEXT_DIM, 1))
		return
	var id := str(entry_ids[entry_sel])
	var info := Archive.entity_info(id)
	_mark_seen()
	if Archive.is_discovered(id):
		entry_detail.add_child(label(str(info.get("code", "TSRA-EN-??")), 26, AMBER, 2))
		entry_detail.add_child(label(str(info.get("common_name", id)).to_upper(), 21, TEXT, 1, true))
		entry_detail.add_child(label("THREAT CLASS: " + str(info.get("threat_class", "Undetermined")), 18, RED, 1, true))
		if info.has("description"):
			_entry_section("OVERVIEW", str(info.description))
		_entry_section("BEHAVIOUR VECTOR", str(info.get("behavior_vector", "")))
		_entry_section("FIELD PROTOCOL", str(info.get("directive", "")))
		var cl: Dictionary = info.get("classified", {})
		if not cl.is_empty():
			annex(entry_detail, id, [["ORIGIN", cl.get("origin", "")], ["SURVIVAL PROTOCOL", cl.get("survival", [])],
				["FIELD NOTES", cl.get("field_notes", [])], ["INCIDENT REPORT", cl.get("incident", "")]], 18)
	else:
		entry_detail.add_child(label("TSRA-EN-??", 26, TEXT_DIM, 2))
		entry_detail.add_child(label("UNREGISTERED ANOMALY", 21, TEXT_DIM, 1))
		entry_detail.add_child(spacer(14))
		for n in [4, 3, 4, 2]:
			entry_detail.add_child(redacted(id + str(n), n))
		entry_detail.add_child(spacer(12))
		entry_detail.add_child(label("NO SCAN ON FILE. HOLD Q WITH THE FIELD SCANNER ON IT TO LOG THIS ENTRY.", 17, AMBER, 1, true))
	var sites := Archive.sites_of(id)
	_entry_section("KNOWN SITES", "\n".join(sites) if not sites.is_empty() else "NONE ON RECORD")
	var when := Archive.logged_info(id)
	if when.has("t"):
		var level_id := str(when.get("level", ""))
		var where := str(Archive.dossiers().get(level_id, {}).get("designation", level_id))
		entry_detail.add_child(spacer(12))
		entry_detail.add_child(label("LOGGED %s // %s" % [local_time(int(when.t)), where], 15, MUTED, 1, true))

func _entry_section(title: String, text: String) -> void:
	entry_detail.add_child(spacer(12))
	entry_detail.add_child(label(title, 15, MUTED, 2))
	entry_detail.add_child(label(text, 18, TEXT, 1, true))
