extends RefCounted
## Model-only entities and characters (no behaviour, no AI yet): the debug console stands them in front of the
## player (ENTITIES tab, or `spawn <id>`) to see how each reads in a level. Each is a model_entity.gd node made
## the first time it is asked for, under main beside the other entities. They stand where they were put, playing
## their idle clip if the file has one.
##   id: [label, file in models/entities/extra/, height in metres (0: as big as the file has it, for a group or
##   a set piece), group ("entity", "character", or "new": imported, AI and animations still to do),
##   (piece: the node to keep, for a file holding several)]
## An id can also be an Entity mark's Kind in the level editor (object_types.json): the floor's build stands the
## model on the mark (place()).

const ModelEntity := preload("res://scripts/Entities/model_entity.gd")
const DIR := "res://models/entities/extra/"

const ROSTER := {
	"smiler": ["Smiler", "smiler.glb", 2.3, "entity"],
	"skinstealer2": ["Skin Stealer (animated)", "skin_stealer_animated.glb", 2.6, "entity"],
	"skinless": ["Skinless Man", "skinless_man.glb", 2.0, "entity"],
	"snatcher": ["Snatcher (PSX)", "psx_snatcher.glb", 2.2, "entity"],
	"kitty": ["Kitty", "kitty.glb", 2.0, "entity"],
	"librarian": ["Library entity", "library_entity.glb", 2.4, "entity"],
	"creature": ["Creature 002", "creature_002.glb", 2.2, "entity"],
	"stilllife": ["Still Life", "still_life_custom.glb", 1.9, "entity"],
	"stilllife2": ["Still Life (FF3)", "still_life_ff3.glb", 1.9, "entity"],
	"stilllife3": ["Still Life (FF3, rigged)", "still_life_ff3_rigged.glb", 1.9, "entity"],
	"partygoer": ["Partygoer", "partygoer.glb", 1.75, "entity"],
	"zombie": ["Zombie (animated)", "zombie_animated_a.glb", 1.8, "entity"],
	"zombie2": ["Zombie (rig)", "zombie_animated_b.glb", 1.8, "entity"],
	"labhorror": ["Abandoned lab horror (set piece)", "abandoned_lab_horror.glb", 0.0, "entity"],
	"piratequeen": ["Pirate Queen", "pirate_queen.glb", 1.75, "character"],
	"roykenshi": ["Roy Kenshi", "roy_kenshi.glb", 1.8, "character"],
	"extras": ["Extras (group)", "characters_extras.glb", 0.0, "character"],
	# the next batch, waiting for their AI and animations (source files: asetsuimprot/newentities)
	"ceilingcrawler": ["Ceiling Crawler", "ceiling_crawler.glb", 1.2, "new"],
	"child": ["Child", "child.glb", 1.2, "new"],
	"hazmat": ["Combine Hazmat", "combine_hazmat.glb", 1.8, "new"],
	"roadcreature": ["Country Road Creature", "country_road_creature.glb", 2.8, "new"],
	"eldermimic": ["Elder Mimic", "elder_mimic.glb", 2.4, "new"],
	"screamface": ["Screaming face statue", "screaming_face_statue.glb", 0.6, "new"],
	# sculpture.glb is a pack of draped furniture: one entry per piece (5th field: its node in the file), at the
	# size the file has it
	"sculpture_tall": ["Sculpture: tall draped figure", "sculpture.glb", 0.0, "new", "02"],
	"sculpture_chair": ["Sculpture: draped chair", "sculpture.glb", 0.0, "new", "02_2"],
	"sculpture_wide": ["Sculpture: wide draped heap", "sculpture.glb", 0.0, "new", "03_1"],
	"sculpture_low1": ["Sculpture: low draped heap 1", "sculpture.glb", 0.0, "new", "03"],
	"sculpture_low2": ["Sculpture: low draped heap 2", "sculpture.glb", 0.0, "new", "03_2"],
	"sculpture_low3": ["Sculpture: low draped heap 3", "sculpture.glb", 0.0, "new", "03_3"],
	"sculpture_low4": ["Sculpture: low draped heap 4", "sculpture.glb", 0.0, "new", "02_1"],
	"gardencrawler": ["Garden Crawler", "garden_crawler.glb", 1.0, "new"],
	"goose": ["Goose", "goose.glb", 0.9, "new"],
	"maxwell": ["Maxwell the cat", "maxwell_cat.glb", 0.45, "new"],
	"breakingnews": ["Breaking News", "breaking_news.glb", 2.4, "new"],
	"goat": ["Nightmare Goat", "nightmare_goat.glb", 1.6, "new"],
	"smiley": ["Smiley horror monster", "smiley_horror.glb", 2.0, "new"],
	"suction": ["Suction", "suction.glb", 1.5, "new"],
	"telekung": ["Telekung", "telekung.glb", 1.7, "new"],
	# clown_heads.glb: four heads, two thin and two fat; bust-sized, to sit on a table or a seat
	"clownhead_thin1": ["Clown head: thin 1", "clown_heads.glb", 0.45, "new", "Tete_mince1_low"],
	"clownhead_thin2": ["Clown head: thin 2", "clown_heads.glb", 0.45, "new", "Tete_mince2_low"],
	"clownhead_fat1": ["Clown head: fat 1", "clown_heads.glb", 0.45, "new", "Tete_gros1_low"],
	"clownhead_fat2": ["Clown head: fat 2", "clown_heads.glb", 0.45, "new", "Tete_gros2_low"],
	"moon": ["The Moon Woke Up", "moon_woke_up.glb", 2.0, "new"],
	"rollinggiant": ["Rolling Giant", "rolling_giant.glb", 2.4, "new"],
	"sheetzombies": ["Zombies under sheets (group)", "zombies_under_sheets.glb", 1.8, "new"],
}

## The ones that don't stand on the floor (model_entity.gd mount, entity_mount.gd): "wall" goes flat on the wall
## nearest its mark and nowhere else, "prop" sits itself on the nearest prop's free top
const MOUNTS := {
	"screamface": "wall",
	"clownhead_thin1": "prop", "clownhead_thin2": "prop", "clownhead_fat1": "prop", "clownhead_fat2": "prop",
}

## The node for roster entry `id` under `main` (made, not yet shown, the first time); null for an unknown id
static func node_for(main: Node, id: String) -> Node:
	if not ROSTER.has(id): return null
	var node_name := "Roster_" + id
	var n := main.get_node_or_null(node_name)
	if n != null: return n
	var m := ModelEntity.new()
	m.name = node_name
	_setup(m, id)
	main.add_child(m)
	return m

static func _setup(m: Node, id: String) -> void:
	var e: Array = ROSTER[id]
	m.model = DIR + str(e[1])
	m.height = float(e[2])
	m.source_height = 0.0                 # measured when built (model_entity.gd _fit)
	m.auto_anim = true
	if e.size() > 4: m.part = str(e[4])
	m.mount = MOUNTS.get(id, "")

## Roster entry `id` stood on an Entity mark: under `parent` (the level, so it goes with the floor) at `xf`, its
## front along the mark's arrow, `size` times as big. Null for an unknown id or a model that won't load.
static func place(parent: Node, id: String, xf: Transform3D, size := 1.0) -> Node3D:
	if not ROSTER.has(id): return null
	var m := ModelEntity.new()
	m.name = "Placed_" + id
	_setup(m, id)
	m.placed = true
	m.level = parent
	m.size = size
	parent.add_child(m)
	if not m._build():
		m.free()
		return null
	m.transform = xf * Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3.ZERO)   # (the model's front is +Z, the mark's +X)
	m._solid()
	m.visible = true
	if m.mount != "":
		m.settle_later(m.global_position, xf.basis.x.normalized())      # its wall / prop, once the floor is solid
	else:
		m.present = true
	return m
