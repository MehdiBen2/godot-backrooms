extends "res://scripts/UI/inventory/terminal_page.gd"
## SITE: the current level's threshold dossier in full (zone, threat, every reading, the mandates, the
## classified annex), then the phenomena catalogued there: a line each, with its protocol once it is
## logged. A click on one opens its entry on ARCHIVE. New levels / entities register in
## levels/tsra_dossiers.json / levels/tsra_entities.json (see the top of tsra_archive.gd).

const METRICS := {
	"spatial_reliability": "SPATIAL RELIABILITY",
	"temporal_coherence": "TEMPORAL COHERENCE",
	"cognitive_decay": "COGNITIVE DECAY",
	"atmosphere_substratum": "SUBSTRATUM",
}

var out: VBoxContainer
var link_nodes: Array = []           # phenomena rows: a click opens their entry

func build() -> Control:
	out = _column(6)
	return root

func hoverables() -> Array:
	return link_nodes

func refresh() -> void:
	if not out:
		return
	clear(out)
	link_nodes.clear()
	var d := Archive.current_dossier()
	var designation := str(d.get("designation", "LEVEL // DESIGNATION PENDING"))
	var sheet_no = d.get("log_sheet", 100 + absi(designation.hash()) % 900)
	heading(out, "THRESHOLD DOSSIER", "LOG SHEET #%s" % str(sheet_no))
	out.add_child(leader("ZONE", designation, AMBER, 18))
	out.add_child(leader("THREAT", "<%s>" % str(d.get("threat_classification", "UNDETERMINED")), RED, 18))

	# every reading in full: its name, then the figures under it, one per line
	var metrics: Dictionary = d.get("metrics", {})
	if not metrics.is_empty():
		section(out, "READINGS")
		for key in METRICS:
			if not metrics.has(key):
				continue
			out.add_child(spacer(4))
			out.add_child(label(METRICS[key], 15, MUTED, 3))
			var parts: PackedStringArray = str(metrics[key]).split("//")
			for i in parts.size():
				para(out, parts[i].strip_edges(), TEXT if i == 0 else TEXT_DIM, 17, 22.0)

	var directives: Array = d.get("directives", [])
	if not directives.is_empty():
		section(out, "MANDATES")
		numbered(out, directives)

	var cl: Dictionary = d.get("classified", {})
	if not cl.is_empty():
		annex(out, designation, [["SITE HISTORY", cl.get("history", "")], ["SURVIVAL GUIDANCE", cl.get("survival", [])],
			["SURVEY NOTE", cl.get("survey_note", "")], ["INCIDENT REPORT", cl.get("incident", "")]], 17)

	var ids := Archive.level_entities(Archive.current_level_id())
	var found := 0
	for id in ids:
		if Archive.is_discovered(str(id)): found += 1
	section(out, "PHENOMENA LOGGED", "%d / %d" % [found, ids.size()])
	if ids.is_empty():
		para(out, "NO ANOMALIES CATALOGUED FOR THIS SITE.", TEXT_DIM)
	for id in ids:
		out.add_child(_phenomenon(str(id)))
	if found < ids.size():
		out.add_child(spacer(6))
		para(out, "HOLD [Q] WITH THE FIELD SCANNER ON AN ANOMALY TO LOG IT. CLICK ONE TO READ ITS ENTRY.", MUTED, 15)

## One anomaly: [CONFIRMED] and its code and name with the protocol under it once logged, [NO SCAN]
## and a redaction until then. The whole line is a link to its entry on ARCHIVE.
func _phenomenon(id: String) -> Control:
	var known := Archive.is_discovered(id)
	var info := Archive.entity_info(id)
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.add_theme_stylebox_override("panel", row_box(false))
	p.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			term.open_entry(id)
	)
	p.mouse_entered.connect(func(): p.add_theme_stylebox_override("panel", row_box(false, true)))
	p.mouse_exited.connect(func(): p.add_theme_stylebox_override("panel", row_box(false)))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 14)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if known:
		top.add_child(_status("CONFIRMED", GREEN))
		top.add_child(label(str(info.get("code", "TSRA-EN-??")), 17, MUTED, 2))
		top.add_child(label(str(info.get("common_name", id)).to_upper(), 18, TEXT, 2))
	else:
		top.add_child(_status("NO SCAN", TEXT_DIM))
		top.add_child(label("TSRA-EN-??", 17, TEXT_DIM, 2))
		top.add_child(redacted(id, 2))
	v.add_child(top)
	if known and str(info.get("directive", "")) != "":
		para(v, "PROTOCOL: " + str(info.directive), TEXT_DIM, 16, 22.0)
	p.add_child(v)
	link_nodes.append(p)
	return p

## The status column of a phenomenon line, one width for all of them so the codes line up
func _status(text: String, col: Color) -> Label:
	var l := tag(text, col, 16)
	l.custom_minimum_size.x = 150
	return l
