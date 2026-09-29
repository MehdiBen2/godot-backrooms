extends "res://scripts/UI/inventory/terminal_page.gd"
## [F5] CLEARANCE: the player's T.S.R.A. service record (asra_clearance.gd): where they stand, the
## ladder and what each tier grants, how their yield was earned, per entity, the corridor survey,
## the filing log and the rules. inventory.gd refreshes it on every filing and when it is opened
## (the re-read cooldowns tick while it is closed).

const Scanner := preload("res://scripts/Player/scanner.gd")
const CL_BAR := 20                   # cells in the page's bars

var out: VBoxContainer

func build() -> Control:
	out = _column(4)
	return root

func refresh() -> void:
	if not out:
		return
	clear(out)
	var ti := Clearance.tier_index()
	var cur := Clearance.tier()
	var unit := Clearance.unit
	out.add_child(label("[T.S.R.A. PERSONNEL FILE // FIELD CLEARANCE]", 21, TEXT, 1))
	out.add_child(spacer(12))

	# -- status
	out.add_child(label("CLEARANCE HELD", 15, MUTED, 2))
	out.add_child(label(Clearance.tier_label(), 26, AMBER, 2, true))
	out.add_child(label(str(cur.get("brief", "")), 17, TEXT_DIM, 1, true))
	out.add_child(spacer(8))
	var to_next := Clearance.next_threshold() - Clearance.total
	if Clearance.is_max_tier():
		out.add_child(_bar_row("LIFETIME YIELD", 1.0, "%d %s" % [Clearance.total, unit], GREEN))
		out.add_child(label("MAXIMUM CLEARANCE. THE AGENCY HAS NOTHING LEFT TO GIVE YOU.", 16, GREEN, 1, true))
	else:
		var nxt := Clearance.tier(ti + 1)
		out.add_child(_bar_row("TO %s" % str(nxt.get("code", "")), Clearance.tier_progress(), "%d / %d" % [Clearance.total, Clearance.next_threshold()], AMBER))
		out.add_child(_kv("NEXT PROMOTION", "%s IN %d %s" % [str(nxt.get("title", "")), to_next, unit], TEXT))
		for i in range(ti + 1, Clearance.tiers.size()):
			var u: Dictionary = Clearance.tier(i).get("unlock", {})
			if not u.is_empty():
				out.add_child(_kv("NEXT PRIVILEGE", "%s AT %s (%d %s TO GO)" % [str(u.get("name", "")), str(Clearance.tier(i).get("code", "")),
					int(Clearance.tier(i).get("yield", 0)) - Clearance.total, unit], AMBER))
				break

	# -- ladder
	_section("CLEARANCE LADDER")
	for i in Clearance.tiers.size():
		var td: Dictionary = Clearance.tiers[i]
		var tag := "HELD" if i < ti else ("CURRENT" if i == ti else "LOCKED")
		var col := GREEN if i < ti else (AMBER if i == ti else TEXT_DIM)
		var row := _kv("%s  %s" % [str(td.get("code", "")), str(td.get("title", ""))], "%s // %d %s" % [tag, int(td.get("yield", 0)), unit], col)
		out.add_child(row)
		var u: Dictionary = td.get("unlock", {})
		if not u.is_empty():
			out.add_child(label("      GRANTS: " + str(u.get("name", "")), 15, col if i <= ti else Color(TEXT_DIM, 0.35), 1, true))

	# -- privileges
	_section("PRIVILEGES")
	for td in Clearance.tiers:
		var u: Dictionary = td.get("unlock", {})
		if u.is_empty():
			continue
		var on := Clearance.has_unlock(str(u.get("id", "")))
		out.add_child(_kv(str(u.get("name", "")), "ACTIVE" if on else "LOCKED // %s" % str(td.get("code", "")), GREEN if on else TEXT_DIM))
		out.add_child(label(str(u.get("text", "")), 16, TEXT if on else TEXT_DIM, 1, true))
		out.add_child(spacer(4))
	var cal := Clearance.scan_time_scale()
	out.add_child(_kv("SCANNER CALIBRATION", "READING TIME %.2f S (-%d%%)" % [Scanner.SCAN_TIME * cal, roundi((1.0 - cal) * 100.0)], GREEN if ti > 0 else TEXT_DIM))
	out.add_child(label("Every tier held shaves 5% off the time a reading takes.", 16, TEXT_DIM, 1, true))

	# -- performance
	_section("FIELD PERFORMANCE")
	var n := Clearance.filings()
	out.add_child(_kv("LIFETIME YIELD", "%d %s" % [Clearance.total, unit], AMBER))
	out.add_child(_kv("READINGS FILED", "%d  (%d FIRST CONTACT // %d NEW SITE // %d SUPPLEMENTAL)" % [n,
		int(Clearance.stat("filings_first_contact")), int(Clearance.stat("filings_new_site")), int(Clearance.stat("filings_supplemental"))], TEXT))
	# on file = ever logged (clearance's record); the archive itself starts empty every run
	var on_file := 0
	var this_run := 0
	for id in Archive.entities():
		if Clearance.sites.has(id): on_file += 1
		if Archive.is_discovered(str(id)): this_run += 1
	out.add_child(_kv("ENTITIES ON FILE", "%d / %d  (%d LOGGED THIS RUN)" % [on_file, Archive.entities().size(), this_run], TEXT))
	out.add_child(_kv("SITES CONFIRMED", str(Clearance.sites_confirmed()), TEXT))
	out.add_child(_kv("AVERAGE FILING", "%d %s" % [roundi(float(_scan_yield()) / n), unit] if n > 0 else "NO DATA", TEXT))
	var best_id := str(Clearance.stat("best_id", ""))
	out.add_child(_kv("BEST SINGLE FILING", "%d %s // %s" % [int(Clearance.stat("best_total")), unit, _code(best_id)] if best_id != "" else "NO DATA", TEXT))
	var near_id := str(Clearance.stat("closest_id", ""))
	out.add_child(_kv("CLOSEST READING", "%.1f M // %s" % [float(Clearance.stat("closest_dist", 0.0)), _code(near_id)] if near_id != "" else "NO DATA",
		RED if near_id != "" and float(Clearance.stat("closest_dist", 99.0)) < 4.0 else TEXT))
	out.add_child(_kv("BEST MOMENTUM STREAK", "x%d" % int(Clearance.stat("best_momentum", 1)) if n > 0 else "NO DATA", TEXT))
	out.add_child(_kv("AGENCY ASSESSMENT", _assessment(n), AMBER))
	out.add_child(_kv("CELLS MAPPED WITH TAPE", "%d  (%d STRIPS)" % [int(Clearance.stat("cells_mapped")), int(Clearance.stat("filings_survey"))], TEXT))
	out.add_child(spacer(10))
	out.add_child(label("YIELD BY SOURCE", 15, MUTED, 2))
	var most := 1
	for src in Clearance.SOURCES:
		most = maxi(most, int(Clearance.stat("ry_" + str(src[0]))))
	for src in Clearance.SOURCES:
		var v := int(Clearance.stat("ry_" + str(src[0])))
		out.add_child(_bar_row(str(src[1]), float(v) / most, "%d %s" % [v, unit], AMBER if v > 0 else TEXT_DIM))

	# -- per entity
	_section("YIELD BY ENTITY")
	var all := Archive.entities()
	var ids: Array = all.keys()
	ids.sort_custom(func(a, b): return str(all[a].get("code", "")) < str(all[b].get("code", "")))
	for id in ids:
		var info: Dictionary = all[id]
		if not Clearance.sites.has(id):
			out.add_child(_kv("TSRA-EN-??  UNREGISTERED", "0 " + unit, TEXT_DIM))
			out.add_child(label("      NO SCAN ON FILE // FIRST CONTACT PENDING", 15, TEXT_DIM, 1, true))
			continue
		out.add_child(_kv("%s  %s" % [str(info.get("code", "")), str(info.get("common_name", id)).to_upper()],
			"%d %s" % [int(Clearance.entity_yield.get(id, 0)), unit], TEXT))
		var sup := Clearance.next_supplemental(str(id))
		var wait := Clearance.reread_ready_in(str(id))
		var next := "RE-READS EXHAUSTED"
		if sup > 0:
			next = "NEXT RE-READ %d %s" % [sup, unit] + (" IN %d S" % ceili(wait) if wait > 0.0 else " // READY")
		out.add_child(label("      THREAT %s // SITES %d // RE-READS %d // %s" % [str(info.get("threat_class", "?")).to_upper(),
			(Clearance.sites.get(id, []) as Array).size(), int(Clearance.supplementals.get(id, 0)), next], 15, MUTED, 1, true))

	# -- tape survey, per level
	_section("CORRIDOR SURVEY")
	var levels: Array = Clearance.surveyed.keys()
	var here := Archive.current_level_id()
	if here != "" and not (here in levels):
		levels.push_front(here)
	for level in levels:
		var mapped := (Clearance.surveyed.get(level, {}) as Dictionary).size()
		var cov := Clearance.survey_coverage(str(level))
		var where := str(Archive.dossiers().get(level, {}).get("designation", str(level).to_upper()))
		if where.count("\"") >= 2:
			where = where.get_slice("\"", 1)       # LEVEL 2 - "THE YELLOW HALLS" -> THE YELLOW HALLS
		var fig := "%d CELLS // %d%%" % [mapped, roundi(cov * 100.0)] if int(Clearance.survey_open.get(level, 0)) > 0 else "%d CELLS" % mapped
		out.add_child(_bar_row(vcr(where), cov, fig, GREEN if cov >= 0.75 else (AMBER if mapped > 0 else TEXT_DIM)))
	out.add_child(label("Mark walls and floors with hazard tape. Every cell mapped for the first time files yield; a level's map pays once.", 15, TEXT_DIM, 1, true))

	# -- log
	_section("FILING LOG // LAST %d" % Clearance.LOG_MAX)
	if Clearance.filing_log.is_empty():
		out.add_child(label("NO FILINGS ON RECORD. HOLD Q WITH THE FIELD SCANNER ON AN ANOMALY.", 16, TEXT_DIM, 1, true))
	for e in Clearance.filing_log:
		var kind := str(e.get("kind", ""))
		var what := str({"first_contact": "FIRST CONTACT", "new_site": "NEW SITE", "supplemental": "SUPPLEMENTAL", "grant": "ADJUSTMENT",
			"survey": "CORRIDOR MAPPED"}.get(kind, kind.to_upper()))
		var d := float(e.get("dist", -1.0))
		var where := "%s%s" % [_code(str(e.get("id", ""))) if str(e.get("id", "")) != "" else "ADMIN", " @ %.1f M" % d if d >= 0.0 else ""]
		if kind == "survey":
			where = "%d CELLS" % int(e.get("cells", 0))
		out.add_child(_kv("%s  %s // %s" % [local_time(int(e.get("t", 0))).substr(5), what, where],
			"%+d %s" % [int(e.get("total", 0)), unit], GREEN if kind == "first_contact" else TEXT))

	# -- rules
	_section("YIELD SCHEDULE")
	var b1 := Clearance.BASE + Clearance.PER_CLASS
	var b5 := Clearance.BASE + Clearance.PER_CLASS * 5
	out.add_child(_kv("FIRST CONTACT", "%d-%d %s BY THREAT CLASS" % [b1, b5, unit], TEXT))
	out.add_child(_kv("NEW SITE CONFIRMED", "%d%% OF FIRST CONTACT" % roundi(Clearance.NEW_SITE * 100.0), TEXT))
	out.add_child(_kv("SUPPLEMENTAL DATA", "%d%%, HALVING EACH TIME // 1 PER %d S" % [roundi(Clearance.SUPPLEMENTAL * 100.0), int(Clearance.REREAD_COOLDOWN)], TEXT))
	out.add_child(_kv("PROXIMITY PREMIUM", "+25%% UNDER %d M // +10%% UNDER %d M" % [int(Clearance.CLOSE_RANGE), int(Clearance.NEAR_RANGE)], TEXT))
	out.add_child(_kv("OFF-ROSTER SIGHTING", "+%d%% IF THE DOSSIER DOESN'T LIST IT" % roundi(Clearance.OFF_ROSTER * 100.0), TEXT))
	out.add_child(_kv("HAZARD PAY", "+%d%% UNDER %d SANITY OR HEALTH" % [roundi(Clearance.HAZARD * 100.0), int(Clearance.HAZARD_BELOW)], TEXT))
	out.add_child(_kv("FIELD MOMENTUM", "+%d%% PER FILING WITHIN %d MIN (MAX +%d%%)" % [roundi(Clearance.MOMENTUM_STEP * 100.0),
		int(Clearance.MOMENTUM_WINDOW / 60.0), roundi(Clearance.MOMENTUM_STEP * Clearance.MOMENTUM_MAX * 100.0)], TEXT))
	out.add_child(_kv("CORRIDOR MAPPED", "%d %s PER CELL FIRST TAPED" % [Clearance.SURVEY_PER_CELL, unit], TEXT))
	var ms: Array = []
	for m in Clearance.SURVEY_MILESTONES:
		ms.append("+%d AT %d%%" % [int(m[1]), roundi(float(m[0]) * 100.0)])
	out.add_child(_kv("SURVEY MILESTONES", " // ".join(ms), TEXT))
	out.add_child(spacer(6))
	out.add_child(label("Readings of a known entity on a known site pay a trickle, then nothing. The agency pays for new information, not for staring.", 15, TEXT_DIM, 1, true))

## A section title over a thin rule
func _section(title: String) -> void:
	out.add_child(spacer(18))
	out.add_child(label(title, 15, MUTED, 2))
	out.add_child(hline(Color(AMBER, 0.35), 2))
	out.add_child(spacer(4))

## "KEY ...... VALUE": the key on the left, the value right-aligned in `col`
func _kv(key: String, value: String, col: Color) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 16)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var k := label(key, 17, TEXT_DIM if col != TEXT_DIM else Color(TEXT_DIM, 0.35), 1)
	k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	k.clip_text = true
	k.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	h.add_child(k)
	var v := label(value, 17, col, 1)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h.add_child(v)
	return h

## A label, a bar of CL_BAR cells filled to `frac`, and the figure
func _bar_row(key: String, frac: float, value: String, col: Color) -> Control:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	h.custom_minimum_size.y = 24          # a slim bar in a taller row: the bars stay apart
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var k := label(key, 15, TEXT_DIM, 1)
	k.custom_minimum_size.x = 230
	k.clip_text = true
	k.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	h.add_child(k)
	var gauge := cells(CL_BAR, 2.0, false)
	gauge.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gauge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	gauge.custom_minimum_size.y = 10
	set_cells(gauge, roundi(clampf(frac, 0.0, 1.0) * CL_BAR) if frac > 0.0 else 0, col)
	if frac > 0.0 and gauge.get_meta("filled") == 0:
		set_cells(gauge, 1, col)            # anything at all shows as one cell
	h.add_child(gauge)
	var v := label(value, 15, col, 1)
	v.custom_minimum_size.x = 150
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	h.add_child(v)
	return h

## Yield from scanner readings alone (tape surveys and adjustments left out): the per-entity totals
func _scan_yield() -> int:
	var y := 0
	for id in Clearance.entity_yield:
		y += int(Clearance.entity_yield[id])
	return y

func _code(id: String) -> String:
	return str(Archive.entity_info(id).get("code", "TSRA-EN-??")) if id != "" else "-"

## The agency's one-line verdict, off the average filing
func _assessment(n: int) -> String:
	if n == 0:
		return "PENDING FIRST FILING"
	var avg := float(_scan_yield()) / n
	if avg < 60.0: return "BELOW EXPECTATIONS"
	if avg < 140.0: return "MEETS EXPECTATIONS"
	if avg < 220.0: return "EXCEEDS EXPECTATIONS"
	return "EXEMPLARY // FLAGGED FOR REVIEW"
