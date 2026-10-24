extends RefCounted
## T.S.R.A. Field Upgrades: the skill tree the terminal's [05] FIELD UPGRADES page sells for research credits
## (terminal_os.gd). Three branches (BRANCHES), each a root node that forks in two and joins again at a
## capstone ABILITY. A node's ranks are bought in order: rank i costs `price[i]` CR and needs clearance tier
## `tier[i]` (levels/tsra_clearance.json), and the node opens once every node in its `req` has a rank.
## `pos` is the node's place on the page: x the sub-column (two per branch), y the row.
## A ranked node scales one number of the player's: scale(id) = 1 + per * rank, read where that number is
## used. An ability (`per` 0) is on or off: has(id), read where it changes the rules.
##   lungs, breath, second_wind  player_body.gd _update_stamina     psych   player_body.gd sanity loss
##   filament  player_body.gd battery     soles, ghost_step  player.gd step_noise
##   low_profile, adrenal  player.gd crouch speed, adrenaline burst
##   amplifier, long_range  scanner.gd SCAN_TIME, RANGE        analyst  tsra_clearance.gd file()
## Ranks are kept on the tape with the credits (save_game.gd "world" "upgrades").

const BRANCHES := ["SURVIVAL", "STEALTH", "RECON"]

const TREE := [
	# ---- SURVIVAL
	{"id": "lungs", "name": "Cardio Conditioning", "short": "CARDIO", "code": "SV-01", "pos": Vector2(0.5, 0), "req": [],
		"per": 0.2, "unit": "SPRINT TIME", "price": [50, 110, 190], "tier": [0, 1, 3],
		"desc": "Agency treadmill protocol, administered between deployments. Operatives who can outrun it come back.",
		"line": "Sprint for longer before you are winded."},
	{"id": "breath", "name": "Breath Discipline", "short": "BREATHWORK", "code": "SV-02", "pos": Vector2(0, 1), "req": ["lungs"],
		"per": 0.25, "unit": "STAMINA RECOVERY", "price": [70, 150], "tier": [1, 4],
		"desc": "Box breathing drills from the hostage-negotiation syllabus. In for four. Hold for four. Out for four.",
		"line": "Stamina comes back faster once you stop running."},
	{"id": "psych", "name": "Psych Conditioning", "short": "PSYCH", "code": "SV-03", "pos": Vector2(1, 1), "req": ["lungs"],
		"per": -0.15, "unit": "SANITY LOSS", "price": [90, 170, 260], "tier": [2, 4, 6],
		"desc": "Sensory deprivation tank sessions. You learn to sit in the dark and let it be only dark.",
		"line": "The dark and drain zones wear your mind down slower."},
	{"id": "second_wind", "name": "Second Wind", "short": "SECOND WIND", "code": "SV-X", "pos": Vector2(0.5, 2), "req": ["breath", "psych"],
		"per": 0.0, "unit": "", "price": [300], "tier": [5],
		"desc": "The body keeps a reserve the mind is not told about. Conditioning teaches you where it is.",
		"line": "ABILITY: running dry refills half your stamina instead of leaving you winded. Once every 90 s."},
	# ---- STEALTH
	{"id": "soles", "name": "Soft-Sole Boots", "short": "SOFT SOLES", "code": "ST-01", "pos": Vector2(2.5, 0), "req": [],
		"per": -0.12, "unit": "FOOTSTEP NOISE", "price": [80, 160, 240], "tier": [1, 3, 5],
		"desc": "Felted crepe soles bonded over the issue boot. Tile and concrete stop announcing you quite so far.",
		"line": "Entities hear your steps from less far away."},
	{"id": "low_profile", "name": "Low Profile", "short": "LOW PROFILE", "code": "ST-02", "pos": Vector2(2, 1), "req": ["soles"],
		"per": 0.15, "unit": "CROUCH SPEED", "price": [70, 140], "tier": [1, 3],
		"desc": "Knee pads and a duck-walk drill. Staying under the sightline no longer means crawling.",
		"line": "Move faster while crouched."},
	{"id": "adrenal", "name": "Adrenal Control", "short": "ADRENAL", "code": "ST-03", "pos": Vector2(3, 1), "req": ["soles"],
		"per": 0.25, "unit": "ADRENALINE BURST", "price": [90, 180], "tier": [2, 4],
		"desc": "Biofeedback training: you learn to hold the spike instead of riding it.",
		"line": "The adrenaline burst when something hunts you lasts longer."},
	{"id": "ghost_step", "name": "Ghost Step", "short": "GHOST STEP", "code": "ST-X", "pos": Vector2(2.5, 2), "req": ["low_profile", "adrenal"],
		"per": 0.0, "unit": "", "price": [320], "tier": [6],
		"desc": "Weight on the outside of the foot, heel last. The floor never quite learns you were there.",
		"line": "ABILITY: crouched footsteps carry 75% less far."},
	# ---- RECON
	{"id": "amplifier", "name": "Signal Amplifier", "short": "SIGNAL AMP", "code": "RC-01", "pos": Vector2(4.5, 0), "req": [],
		"per": -0.1, "unit": "SCAN TIME", "price": [100, 200], "tier": [2, 5],
		"desc": "A low-noise preamp spliced into the field scanner's pickup. Readings lock on sooner.",
		"line": "Scanner readings complete faster."},
	{"id": "filament", "name": "Low-Draw Filament", "short": "LOW-DRAW", "code": "RC-02", "pos": Vector2(4, 1), "req": ["amplifier"],
		"per": -0.15, "unit": "TORCH DRAIN", "price": [60, 120, 200], "tier": [0, 2, 4],
		"desc": "A cooler-running bulb and a trimmed reflector for the standard field torch. Same throw, less current.",
		"line": "Battery lasts longer per cell."},
	{"id": "long_range", "name": "Long-Range Pickup", "short": "LONG RANGE", "code": "RC-03", "pos": Vector2(5, 1), "req": ["amplifier"],
		"per": 0.15, "unit": "SCANNER RANGE", "price": [110, 210], "tier": [3, 5],
		"desc": "A directional antenna for the scanner head. Read them from further back, where it is safer.",
		"line": "The scanner reads entities from further away."},
	{"id": "analyst", "name": "Field Analyst", "short": "ANALYST", "code": "RC-X", "pos": Vector2(4.5, 2), "req": ["filament", "long_range"],
		"per": 0.0, "unit": "", "price": [350], "tier": [6],
		"desc": "Your readings arrive pre-annotated. Surface Command stops asking follow-up questions and starts paying.",
		"line": "ABILITY: +20% XP on every scanner reading."},
]

static var ranks := {}       # node id -> ranks bought

static func entry(id: String) -> Dictionary:
	for u in TREE:
		if u.id == id:
			return u
	return {}

static func rank(id: String) -> int:
	return int(ranks.get(id, 0))

static func has(id: String) -> bool:
	return rank(id) > 0

static func max_rank(id: String) -> int:
	return (entry(id).get("price", []) as Array).size()

static func is_ability(id: String) -> bool:
	return float(entry(id).get("per", 0.0)) == 0.0

## Every node it hangs off has a rank
static func is_open(id: String) -> bool:
	for r in entry(id).get("req", []):
		if not has(r):
			return false
	return true

## What node `id` multiplies its number by at `r` ranks (its current ranks by default)
static func scale(id: String, r := -1) -> float:
	return 1.0 + float(entry(id).get("per", 0.0)) * (rank(id) if r < 0 else r)

## The next rank's price and clearance tier ({} once it is maxed)
static func next(id: String) -> Dictionary:
	var u := entry(id)
	var r := rank(id)
	if r >= max_rank(id):
		return {}
	return {"price": int(u.price[r]), "tier": int(u.tier[r])}

static func buy(id: String) -> void:
	ranks[id] = mini(rank(id) + 1, max_rank(id))

static func reset() -> void:
	ranks = {}

static func restore(d) -> void:
	ranks = (d as Dictionary).duplicate() if d is Dictionary else {}
