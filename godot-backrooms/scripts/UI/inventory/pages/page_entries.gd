extends "res://scripts/UI/inventory/terminal_page.gd"
## ARCHIVE: every catalogued entity. A list on the left, one line each (its code and name, ???? until it
## is scanned, a * until its entry has been opened), the selected one in inverse video; its entry on
## the right: designation, threat, overview, behaviour, protocol, where it has been seen and when it
## was logged, then the classified annex. Arrows / clicks pick one; the SITE page's phenomena open
## theirs here (open_entry).

const LIST_W := 300.0

var _head: VBoxContainer             # the page's heading, rebuilt with the count in it
var entries_list: VBoxContainer
var entry_detail: VBoxContainer
var entry_ids: Array = []            # every catalogued entity, in code order
var entry_rows: Array = []           # one PanelContainer per entry
var entry_sel := 0

func build() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var head := VBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(head)
	heading(head, "ANOMALY ARCHIVE", "")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 22)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(row)
	var list_scroll := scroll()
	list_scroll.custom_minimum_size.x = LIST_W
	list_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	entries_list = scroll_body(list_scroll, 2)
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
	_head = head
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
	clear(_head)
	heading(_head, "ANOMALY ARCHIVE", "%d OF %d LOGGED" % [logged, entry_ids.size()])
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

## "EN-01  THE MANNEQUINS *": its code, its name (or ????????), and * while it is new
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
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	h.custom_minimum_size.y = 30
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var code := label(str(info.get("code", "TSRA-EN-??")).replace("TSRA-", "") if logged else "EN-??", 16, MUTED, 2)
	code.custom_minimum_size.x = 64
	code.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(code)
	var nm := label(str(info.get("common_name", id)).to_upper() if logged else "????????", 17, TEXT if logged else TEXT_DIM, 2)
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	nm.clip_text = true
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	h.add_child(nm)
	var badge := label("*", 17, AMBER, 1)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	badge.visible = Archive.is_unread(id)
	h.add_child(badge)
	p.add_child(h)
	p.set_meta("labels", [code, nm, badge])
	p.set_meta("badge", badge)
	p.set_meta("logged", logged)
	return p

func _style_entry_row(i: int) -> void:
	if i >= entry_rows.size():
		return
	var p: PanelContainer = entry_rows[i]
	var sel := i == entry_sel
	p.add_theme_stylebox_override("panel", row_box(sel, p.get_meta("hover")))
	var logged: bool = p.get_meta("logged")
	var ls: Array = p.get_meta("labels")
	(ls[0] as Label).add_theme_color_override("font_color", INK if sel else MUTED)
	(ls[1] as Label).add_theme_color_override("font_color", INK if sel else (TEXT if logged else TEXT_DIM))
	(ls[2] as Label).add_theme_color_override("font_color", INK if sel else AMBER)
	for l in ls:
		(l as Label).add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.0 if sel else 0.8))

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

## ARCHIVE from the SITE page's phenomena: straight to that entity's entry (built before the page
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

## The entry on show is no longer new once it has been opened here
func _mark_seen() -> void:
	if entry_ids.is_empty() or not term.shown or term.active_page != "ENTRIES":
		return
	var id := str(entry_ids[entry_sel])
	if Archive.is_discovered(id) and Archive.is_unread(id):
		Archive.mark_read(id)
		(entry_rows[entry_sel].get_meta("badge") as Label).visible = false
		term.readout.queue_redraw()

## Arriving on ARCHIVE with something new logged: that one first
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
		empty_state(entry_detail, "NO ENTRIES CATALOGUED.", "")
		return
	var id := str(entry_ids[entry_sel])
	var info := Archive.entity_info(id)
	_mark_seen()
	if not Archive.is_discovered(id):
		entry_detail.add_child(label("TSRA-EN-??", 15, MUTED, 3))
		entry_detail.add_child(label("UNREGISTERED ANOMALY", 24, TEXT_DIM, 2, true))
		entry_detail.add_child(leader("STATUS", "[NO SCAN ON FILE]", TEXT_DIM, 17))
		entry_detail.add_child(spacer(10))
		for n in [4, 3, 4, 2]:
			entry_detail.add_child(redacted(id + str(n), n))
		entry_detail.add_child(spacer(12))
		para(entry_detail, "HOLD [Q] WITH THE FIELD SCANNER ON IT TO LOG THIS ENTRY.", MUTED, 15)
		return
	entry_detail.add_child(label(str(info.get("code", "TSRA-EN-??")), 15, MUTED, 3))
	entry_detail.add_child(label(str(info.get("common_name", id)).to_upper(), 24, AMBER, 2, true))
	entry_detail.add_child(spacer(4))
	var cls := str(info.get("threat_class", "Undetermined")).to_upper()
	entry_detail.add_child(leader("THREAT", "[%s]" % cls, RED if cls.to_int() >= 4 else (ORANGE if cls.to_int() == 3 else AMBER), 17))
	var sites := Archive.sites_of(id)
	entry_detail.add_child(leader("SITES", str(sites.size()) if not sites.is_empty() else "NONE ON RECORD", TEXT, 17))
	var when := Archive.logged_info(id)
	if when.has("t"):
		entry_detail.add_child(leader("LOGGED", local_time(int(when.t)), TEXT, 17))
	if info.has("description"):
		section(entry_detail, "OVERVIEW")
		para(entry_detail, str(info.description))
	if str(info.get("behavior_vector", "")) != "":
		section(entry_detail, "BEHAVIOUR")
		para(entry_detail, str(info.behavior_vector))
	if str(info.get("directive", "")) != "":
		section(entry_detail, "FIELD PROTOCOL")
		para(entry_detail, str(info.directive), AMBER)
	if not sites.is_empty():
		section(entry_detail, "KNOWN SITES")
		for s in sites:
			para(entry_detail, str(s), TEXT_DIM, 16)
	var cl: Dictionary = info.get("classified", {})
	if not cl.is_empty():
		annex(entry_detail, id, [["ORIGIN", cl.get("origin", "")], ["SURVIVAL PROTOCOL", cl.get("survival", [])],
			["FIELD NOTES", cl.get("field_notes", [])], ["INCIDENT REPORT", cl.get("incident", "")]], 16)
