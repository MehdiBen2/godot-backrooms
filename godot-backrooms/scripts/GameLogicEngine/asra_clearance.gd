extends Node
## T.S.R.A. Field Clearance: the agency's take on XP. Every useful scanner reading files Research
## Yield (RY); lifetime yield sets the player's clearance tier (levels/asra_clearance.json).
## Autoload name: Clearance (listed after Archive, whose entries it reads).
##
## The field scanner (scripts/Player/scanner.gd) calls file() on every completed reading, before
## Archive.discover(). What a reading is worth depends on what it tells the agency:
##   FIRST CONTACT      an entity nobody on file has logged: its full base (scaled by threat class)
##   NEW SITE CONFIRMED a logged entity read on a level it was never read on before
##   SUPPLEMENTAL DATA  a repeat reading on a known site: a trickle that halves every time, and
##                      only once per REREAD_COOLDOWN per entity, so it can't be farmed
## and each is marked up by the conditions it was taken in (close range, off-roster sightings,
## hazard pay while the player is hurt or losing it, readings filed back to back).
## Mapping pays too: hazard tape (scripts/Player/tape_tool.gd) calls file_survey() with the grid
## cells each strip marks, and every cell never marked before on that level files SURVEY_PER_CELL,
## plus a bonus as the level's survey passes each of SURVEY_MILESTONES. Marked cells are saved per
## level, so a level's map only pays once.
## hud.gd turns the report into the terminal toasts; inventory.gd shows the tier in its header.
## Tiers unlock things (has_unlock): C-2 the classified annexes in the dossiers (inventory.gd),
## C-3 the scanner's range-finder and C-4 its deep scan (scan_readout.gd, scanner.gd).

signal yield_filed(report: Dictionary)

const DATA_PATH := "res://levels/asra_clearance.json"
const SAVE_PATH := "user://asra_clearance.cfg"

const BASE := 60                 # + PER_CLASS x threat class: Class 1 = 100 RY .. Class 5 = 260 RY
const PER_CLASS := 40
const NEW_SITE := 0.4            # of base
const SUPPLEMENTAL := 0.12       # of base, halved for every earlier supplemental on that entity
const SUPPLEMENTAL_FLOOR := 3    # below this a reading files nothing
const REREAD_COOLDOWN := 90.0    # seconds between supplemental filings on one entity
const CLOSE_RANGE := 8.0         # PROXIMITY PREMIUM: +25% inside this, +10% inside NEAR_RANGE
const NEAR_RANGE := 16.0
const OFF_ROSTER := 0.3          # the level's dossier doesn't list it
const HAZARD := 0.2              # sanity or health below HAZARD_BELOW when the reading completes
const HAZARD_BELOW := 40.0
const MOMENTUM_WINDOW := 300.0   # a filing within this of the last one adds MOMENTUM_STEP ...
const MOMENTUM_STEP := 0.1
const MOMENTUM_MAX := 3          # ... up to this many steps
const SURVEY_PER_CELL := 1       # RY for each grid cell first marked with tape on a level
const SURVEY_MILESTONES := [[0.25, 25], [0.5, 50], [0.75, 100]]   # [share of the open cells, bonus RY]

var unit := "RY"
var tiers: Array = []            # [{code, title, yield, brief}], ascending

var total := 0                   # lifetime Research Yield
var sites := {}                  # entity_id -> [level ids it has been read on]
var supplementals := {}          # entity_id -> supplemental filings so far
var last_report := {}            # the last file() result (hud.gd reads it for the NEW ENTRY toast)
var surveyed := {}               # level id -> {"x,y": true}: the cells mapped with tape there

var _reread_at := {}             # entity_id -> Time ticks (s) of its last supplemental; not saved
var _last_filed := -1.0e9
var _momentum := 0

func _ready() -> void:
	_read_tiers()
	if not _load():
		_backfill()

func _read_tiers() -> void:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(DATA_PATH))
	if parsed is Dictionary:
		unit = str(parsed.get("unit", unit))
		tiers = parsed.get("tiers", [])
	if tiers.is_empty():
		push_error("cannot read " + DATA_PATH)
		tiers = [{"code": "C-0", "title": "CONTRACTOR", "yield": 0, "brief": ""}]

# ---- tiers ----------------------------------------------------------------------
func tier_index(at_total := -1) -> int:
	var y := total if at_total < 0 else at_total
	var t := 0
	for i in tiers.size():
		if y >= int(tiers[i].get("yield", 0)):
			t = i
	return t

func tier(i := -1) -> Dictionary:
	return tiers[clampi(tier_index() if i < 0 else i, 0, tiers.size() - 1)]

func is_max_tier() -> bool:
	return tier_index() >= tiers.size() - 1

## 0..1 of the way from the current tier to the next (1 at the top)
func tier_progress() -> float:
	var i := tier_index()
	if i >= tiers.size() - 1:
		return 1.0
	var lo := int(tiers[i].get("yield", 0))
	var hi := int(tiers[i + 1].get("yield", lo + 1))
	return clampf(float(total - lo) / float(maxi(hi - lo, 1)), 0.0, 1.0)

## Scanner calibration: each tier shaves 5% off a reading's time (scanner.gd SCAN_TIME)
func scan_time_scale() -> float:
	return 1.0 - 0.05 * tier_index()

## The tier whose "unlock" has this id (-1 if none does): classified / rangefinder / deep_scan
func unlock_tier(id: String) -> int:
	for i in tiers.size():
		if str(tiers[i].get("unlock", {}).get("id", "")) == id:
			return i
	return -1

## Has the player's clearance reached the tier that grants `id`? (see levels/asra_clearance.json)
func has_unlock(id: String) -> bool:
	var i := unlock_tier(id)
	return i >= 0 and tier_index() >= i

## "C-2" for the tier that grants `id`
func unlock_code(id: String) -> String:
	var i := unlock_tier(id)
	return str(tiers[i].get("code", "")) if i >= 0 else "C-?"

## Yield the next tier needs in all (the current total at the top)
func next_threshold() -> int:
	var i := tier_index()
	return total if i >= tiers.size() - 1 else int(tiers[i + 1].get("yield", total))

## "C-2 // FIELD ANALYST"
func tier_label(i := -1) -> String:
	var t := tier(i)
	return "%s // %s" % [str(t.get("code", "")), str(t.get("title", ""))]

# ---- yield ----------------------------------------------------------------------
func base_yield(entity_id: String) -> int:
	var cls := str(Archive.entity_info(entity_id).get("threat_class", "Class 1"))
	var n := cls.get_slice(" ", 1).to_int() if " " in cls else cls.to_int()
	return BASE + PER_CLASS * clampi(n, 1, 5)

## Called by the field scanner when a reading completes, BEFORE Archive.discover(). Returns the
## report (and emits yield_filed with it): {id, kind, title, lines: [[label, RY], ...], total,
## tier_from, tier_to}. kind is first_contact / new_site / supplemental, or "" when the reading
## filed nothing (a supplemental still cooling down or worn down to nothing).
func file(entity_id: String, dist: float, player: Node = null) -> Dictionary:
	var level := Archive.current_level_id()
	var base := base_yield(entity_id)
	var seen: Array = sites.get(entity_id, [])
	var now := Time.get_ticks_msec() / 1000.0
	var kind := ""
	var title := ""
	var core := 0
	# first contact off clearance's own saved record, not the archive: the archive starts empty
	# every level (asra_archive.gd), and re-reading a known entity must not pay first contact again
	if not sites.has(entity_id):
		kind = "first_contact"
		title = "FIRST CONTACT"
		core = base
	elif not (level in seen):
		kind = "new_site"
		title = "NEW SITE CONFIRMED"
		core = roundi(base * NEW_SITE)
	elif now - float(_reread_at.get(entity_id, -1.0e9)) >= REREAD_COOLDOWN:
		var n: int = supplementals.get(entity_id, 0)
		core = roundi(base * SUPPLEMENTAL / pow(2.0, n))
		if core >= SUPPLEMENTAL_FLOOR:
			kind = "supplemental"
			title = "SUPPLEMENTAL DATA"
	var report := {"id": entity_id, "kind": kind, "title": title, "lines": [], "total": 0,
		"tier_from": tier_index(), "tier_to": tier_index()}
	if kind == "":
		return report

	var lines: Array = [[title, core]]
	if dist < CLOSE_RANGE:
		lines.append(["PROXIMITY PREMIUM", 0.25])
	elif dist < NEAR_RANGE:
		lines.append(["PROXIMITY PREMIUM", 0.1])
	if kind != "supplemental" and not (entity_id in Archive.current_dossier().get("entities", [])):
		lines.append(["OFF-ROSTER SIGHTING", OFF_ROSTER])
	if player and (float(player.get("sanity")) < HAZARD_BELOW or float(player.get("health")) < HAZARD_BELOW):
		lines.append(["HAZARD PAY", HAZARD])
	if kind != "supplemental":
		_momentum = mini(_momentum + 1, MOMENTUM_MAX) if now - _last_filed <= MOMENTUM_WINDOW else 0
		_last_filed = now
		if _momentum > 0:
			lines.append(["FIELD MOMENTUM x%d" % (_momentum + 1), MOMENTUM_STEP * _momentum])
	# the markups as whole RY, off the core amount; the filing is what the lines add up to
	var gained := core
	for ln in lines.slice(1):
		ln[1] = roundi(core * float(ln[1]))
		gained += int(ln[1])

	match kind:
		"new_site", "first_contact":
			if not (level in seen):
				seen.append(level)
			sites[entity_id] = seen
		"supplemental":
			supplementals[entity_id] = int(supplementals.get(entity_id, 0)) + 1
			_reread_at[entity_id] = now
	total += gained
	report.lines = lines
	report.total = gained
	report.tier_to = tier_index()
	last_report = report
	_save()
	yield_filed.emit(report)
	return report

## Hazard tape just went down: `cells` (Vector2i) are the grid cells the strip marks on this level,
## `open_cells` how many open cells the level has (for the milestones). Returns the report like
## file() does, kind "survey" ({..., "cells": new cells, "coverage": 0..1}), or kind "" when every
## cell was already on the map.
func file_survey(cells: Array, open_cells: int) -> Dictionary:
	var level := Archive.current_level_id()
	if level == "":
		level = "unknown"
	var done: Dictionary = surveyed.get(level, {})
	var before := done.size()
	for c in cells:
		done["%d,%d" % [c.x, c.y]] = true
	var fresh := done.size() - before
	var report := {"id": "", "kind": "", "title": "CORRIDOR MAPPED", "lines": [], "total": 0,
		"tier_from": tier_index(), "tier_to": tier_index(), "cells": fresh,
		"coverage": float(done.size()) / float(maxi(open_cells, 1))}
	if fresh <= 0:
		return report
	surveyed[level] = done
	var lines: Array = [["CORRIDOR MAPPED", fresh * SURVEY_PER_CELL]]
	if open_cells > 0:
		for m in SURVEY_MILESTONES:
			var need: float = open_cells * float(m[0])
			if before < need and done.size() >= need:
				lines.append(["SURVEY %d%% COMPLETE" % roundi(float(m[0]) * 100.0), int(m[1])])
	var gained := 0
	for ln in lines:
		gained += int(ln[1])
	total += gained
	report.kind = "survey"
	report.lines = lines
	report.total = gained
	report.tier_to = tier_index()
	last_report = report
	_save()
	yield_filed.emit(report)
	return report

## Debug console `clearance add <n>`
func grant(amount: int) -> Dictionary:
	var from := tier_index()
	total = maxi(0, total + amount)
	var report := {"id": "", "kind": "grant", "title": "ADMINISTRATIVE ADJUSTMENT",
		"lines": [["ADMINISTRATIVE ADJUSTMENT", amount]], "total": amount, "tier_from": from, "tier_to": tier_index()}
	_save()
	yield_filed.emit(report)
	return report

## Debug console `clearance reset` / `archive reset`
func reset() -> void:
	var from := tier_index()
	total = 0
	sites.clear()
	supplementals.clear()
	surveyed.clear()
	_reread_at.clear()
	_momentum = 0
	last_report = {}
	_save()
	yield_filed.emit({"id": "", "kind": "reset", "title": "", "lines": [], "total": 0, "tier_from": from, "tier_to": 0})

# ---- save -----------------------------------------------------------------------
## Saves from before clearance existed: credit every entity already logged with its first contact
func _backfill() -> void:
	for id in Archive.discovered:
		total += base_yield(str(id))
		var level := str(Archive.logged_info(str(id)).get("level", ""))
		sites[str(id)] = [level] if level != "" else []
	if total > 0:
		_save()

func _load() -> bool:
	var cf := ConfigFile.new()
	if cf.load(SAVE_PATH) != OK:
		return false
	total = int(cf.get_value("clearance", "total", 0))
	if cf.has_section("sites"):
		for id in cf.get_section_keys("sites"):
			var v = cf.get_value("sites", id, [])
			sites[id] = v if v is Array else []
	if cf.has_section("supplementals"):
		for id in cf.get_section_keys("supplementals"):
			supplementals[id] = int(cf.get_value("supplementals", id, 0))
	if cf.has_section("survey"):
		for id in cf.get_section_keys("survey"):
			var done := {}
			for k in cf.get_value("survey", id, []):
				done[str(k)] = true
			surveyed[id] = done
	return true

func _save() -> void:
	var cf := ConfigFile.new()
	cf.set_value("clearance", "total", total)
	for id in sites:
		cf.set_value("sites", id, sites[id])
	for id in supplementals:
		cf.set_value("supplementals", id, supplementals[id])
	for id in surveyed:
		cf.set_value("survey", id, (surveyed[id] as Dictionary).keys())
	cf.save(SAVE_PATH)
