extends "res://scripts/UI/inventory/terminal_page.gd"
## [F2] DOSSIER: the current level's threshold dossier over the phenomena logged there. New levels /
## entities register in levels/asra_dossiers.json / levels/asra_entities.json (see the top of
## asra_archive.gd).

const METRICS := {
	"spatial_reliability": "SPATIAL RELIABILITY",
	"temporal_coherence": "TEMPORAL COHERENCE",
	"cognitive_decay": "COGNITIVE DECAY",
	"atmosphere_substratum": "SUBSTRATUM",
}

var dossier_text: VBoxContainer
var phenomena_title: Label
var phenomena_list: VBoxContainer
var link_nodes: Array = []           # phenomena rows: a click opens their entry

func build() -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scroll_box = scroll()
	scroll_box.size_flags_stretch_ratio = 1.6
	dossier_text = scroll_body(scroll_box, 4)
	v.add_child(scroll_box)
	v.add_child(spacer(12))
	v.add_child(hline(Color(AMBER, 0.8), LINE))
	v.add_child(spacer(12))
	phenomena_title = label("PHENOMENA LOGGED:", 21, TEXT, 1)
	v.add_child(phenomena_title)
	v.add_child(spacer(10))
	var frame := PanelContainer.new()
	var sb := box(Color(0, 0, 0, 0.3), Color(AMBER, 0.75), LINE, 3)
	sb.content_margin_left = 16; sb.content_margin_right = 6
	sb.content_margin_top = 12; sb.content_margin_bottom = 12
	frame.add_theme_stylebox_override("panel", sb)
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ps := scroll()
	phenomena_list = scroll_body(ps, 16)
	frame.add_child(ps)
	v.add_child(frame)
	root = v
	return root

func hoverables() -> Array:
	return link_nodes

func refresh() -> void:
	if not dossier_text:
		return
	var d := Archive.current_dossier()
	var designation := str(d.get("designation", "LEVEL // DESIGNATION PENDING"))
	clear(dossier_text)
	var sheet_no = d.get("log_sheet", 100 + absi(designation.hash()) % 900)
	dossier_text.add_child(label("THRESHOLD DOSSIER // LOG SHEET #%s" % str(sheet_no), 21, TEXT, 1))
	dossier_text.add_child(spacer(14))
	dossier_text.add_child(label("ZONE: " + designation, 21, TEXT, 1, true))
	dossier_text.add_child(label("THREAT: <%s>" % str(d.get("threat_classification", "UNDETERMINED")), 21, RED, 1, true))
	dossier_text.add_child(spacer(14))
	var metrics: Dictionary = d.get("metrics", {})
	for key in METRICS:
		if metrics.has(key):
			dossier_text.add_child(label("- %s: %s" % [METRICS[key], str(metrics[key])], 21, TEXT, 1, true))
	var directives: Array = d.get("directives", [])
	if not directives.is_empty():
		dossier_text.add_child(spacer(14))
		dossier_text.add_child(label("MANDATES:", 21, TEXT, 1))
		for i in directives.size():
			dossier_text.add_child(label("%d. %s" % [i + 1, str(directives[i])], 21, TEXT, 1, true))
	var cl: Dictionary = d.get("classified", {})
	if not cl.is_empty():
		annex(dossier_text, designation, [["SITE HISTORY", cl.get("history", "")], ["SURVIVAL GUIDANCE", cl.get("survival", [])],
			["SURVEY NOTE", cl.get("survey_note", "")], ["INCIDENT REPORT", cl.get("incident", "")]], 19)

	clear(phenomena_list)
	link_nodes.clear()
	var ids := Archive.level_entities(Archive.current_level_id())
	var found := 0
	for id in ids:
		if Archive.is_discovered(str(id)): found += 1
		phenomena_list.add_child(_phenomenon(str(id)))
	if ids.is_empty():
		phenomena_list.add_child(label("NO ANOMALIES CATALOGUED FOR THIS SITE.", 19, TEXT_DIM, 1, true))
	elif found < ids.size():
		# entries only come from the field scanner (scripts/Player/scanner.gd): say how, above them
		var hint := label("HOLD Q WITH THE FIELD SCANNER ON AN ANOMALY TO LOG IT.", 17, AMBER, 1, true)
		phenomena_list.add_child(hint)
		phenomena_list.move_child(hint, 0)
	if not ids.is_empty():
		phenomena_list.add_child(label("CLICK AN ENTRY OR PRESS F3 TO READ IT IN FULL.", 15, MUTED, 1, true))
	phenomena_title.text = "PHENOMENA LOGGED: %d/%d" % [found, ids.size()]

## One line per anomaly catalogued for this level: its code and name once it is logged (and the
## protocol to follow), redacted until then. A click opens its full entry on [F3] ENTRIES.
func _phenomenon(id: String) -> Control:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.add_theme_stylebox_override("panel", box(Color(0, 0, 0, 0)))
	p.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			term.open_entry(id)
	)
	p.mouse_entered.connect(func(): p.add_theme_stylebox_override("panel", box(Color(AMBER, 0.07))))
	p.mouse_exited.connect(func(): p.add_theme_stylebox_override("panel", box(Color(0, 0, 0, 0))))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 3)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if Archive.is_discovered(id):
		var info := Archive.entity_info(id)
		v.add_child(label("[CONFIRMED] %s (%s)" % [str(info.get("code", "TSRA-EN-??")), str(info.get("common_name", id)).to_upper()], 19, GREEN, 1, true))
		v.add_child(label("Protocol: " + str(info.get("directive", "")), 17, TEXT, 1, true))
	else:
		v.add_child(label("[UNCONFIRMED] NO SCAN ON FILE", 19, TEXT_DIM, 1))
		v.add_child(redacted(id, 3))
	p.add_child(v)
	link_nodes.append(p)
	return p
