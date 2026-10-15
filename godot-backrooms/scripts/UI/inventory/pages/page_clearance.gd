extends "res://scripts/UI/inventory/terminal_page.gd"
## RECORD: the player's T.S.R.A. personnel file (tsra_clearance.gd): the clearance held and the bar to
## the next tier, the ladder, the privileges, the field record and the last few filings, all as leader
## lines. inventory.gd refreshes it on every filing and when it is opened.

const CL_BAR := 24                   # cells in the progress bar
const RECENT := 6                    # filings listed

var out: VBoxContainer

func build() -> Control:
	out = _column(6)
	return root

func refresh() -> void:
	if not out:
		return
	clear(out)
	var ti := Clearance.tier_index()
	var cur := Clearance.tier()
	var unit := Clearance.unit
	var top := Clearance.is_max_tier()
	heading(out, "PERSONNEL FILE", "FIELD CLEARANCE")
	out.add_child(leader("CLEARANCE HELD", Clearance.tier_label(), AMBER, 18))
	if str(cur.get("brief", "")) != "":
		para(out, str(cur.brief), TEXT_DIM, 16)
	out.add_child(spacer(8))

	# the bar to the next tier
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 16)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var name_l := label("MAXIMUM" if top else "TO %s" % str(Clearance.tier(ti + 1).get("code", "")), 16, MUTED, 2)
	name_l.custom_minimum_size.x = 110
	bar.add_child(name_l)
	var gauge := cells(CL_BAR, 3.0, false)
	gauge.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gauge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	gauge.custom_minimum_size.y = 12
	set_cells(gauge, CL_BAR if top else roundi(Clearance.tier_progress() * CL_BAR), GREEN if top else AMBER)
	bar.add_child(gauge)
	bar.add_child(label("%d %s" % [Clearance.total, unit] if top else "%d / %d %s" % [Clearance.total, Clearance.next_threshold(), unit], 16, TEXT, 2))
	out.add_child(bar)
	if not top:
		var nxt := Clearance.tier(ti + 1)
		out.add_child(leader("NEXT PROMOTION", "%s IN %d %s" % [str(nxt.get("title", "")).to_upper(), Clearance.next_threshold() - Clearance.total, unit], TEXT, 17))

	# the ladder: every tier, and where you stand on it
	section(out, "CLEARANCE LADDER")
	for i in Clearance.tiers.size():
		var td: Dictionary = Clearance.tiers[i]
		var col := GREEN if i < ti else (AMBER if i == ti else TEXT_DIM)
		var row := leader("%s  %s" % [str(td.get("code", "")), str(td.get("title", "")).to_upper()],
			"[HELD]" if i < ti else ("[CURRENT]" if i == ti else "[%d %s]" % [int(td.get("yield", 0)), unit]), col, 17)
		if i > ti:
			(row.get_child(0) as Label).add_theme_color_override("font_color", Color(TEXT_DIM, 0.5))
		out.add_child(row)

	# privileges: what each unlock is, and whether it is yours
	section(out, "PRIVILEGES")
	for td in Clearance.tiers:
		var u: Dictionary = td.get("unlock", {})
		if u.is_empty():
			continue
		var on := Clearance.has_unlock(str(u.get("id", "")))
		out.add_child(leader(str(u.get("name", "")).to_upper(), "[ACTIVE]" if on else "[LOCKED // %s]" % str(td.get("code", "")),
			GREEN if on else TEXT_DIM, 17))
		para(out, str(u.get("text", "")), TEXT if on else TEXT_DIM, 15, 22.0)

	# the field record
	section(out, "FIELD RECORD")
	var on_file := 0
	for id in Archive.entities():
		if Clearance.sites.has(id): on_file += 1
	out.add_child(leader("LIFETIME YIELD", "%d %s" % [Clearance.total, unit], AMBER, 17))
	out.add_child(leader("READINGS FILED", str(Clearance.filings()), TEXT, 17))
	out.add_child(leader("ENTITIES ON FILE", "%d / %d" % [on_file, Archive.entities().size()], TEXT, 17))
	out.add_child(leader("SITES CONFIRMED", str(Clearance.sites_confirmed()), TEXT, 17))
	out.add_child(leader("CELLS MAPPED WITH TAPE", str(int(Clearance.stat("cells_mapped"))), TEXT, 17))

	# the last few filings
	section(out, "FILING LOG", "LAST %d" % RECENT)
	if Clearance.filing_log.is_empty():
		para(out, "NO FILINGS ON RECORD. HOLD [Q] WITH THE FIELD SCANNER ON AN ANOMALY.", TEXT_DIM, 16)
	for i in mini(RECENT, Clearance.filing_log.size()):
		var e: Dictionary = Clearance.filing_log[i]
		var kind := str(e.get("kind", ""))
		var what := str({"first_contact": "FIRST CONTACT", "new_site": "NEW SITE", "supplemental": "SUPPLEMENTAL",
			"grant": "ADJUSTMENT", "survey": "CORRIDOR MAPPED"}.get(kind, kind.to_upper()))
		var id := str(e.get("id", ""))
		if id != "":
			what += " // " + str(Archive.entity_info(id).get("code", id))
		out.add_child(leader("%s  %s" % [local_time(int(e.get("t", 0))).substr(11), what],
			"%+d %s" % [int(e.get("total", 0)), unit], GREEN if kind == "first_contact" else TEXT, 17))
