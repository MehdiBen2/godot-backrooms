extends RefCounted
## Model-only entities and characters (no behaviour, no AI yet): the debug console stands them in front of the
## player (ENTITIES tab, or `spawn <id>`) to see how each reads in a level. Each is a model_entity.gd node made
## the first time it is asked for, under main beside the other entities. They stand where they were put, playing
## their idle clip if the file has one.
##   id: [label, file in models/entities/extra/, height in metres (0: as big as the file has it, for a group or
##   a set piece), group]

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
}

## The node for roster entry `id` under `main` (made, not yet shown, the first time); null for an unknown id
static func node_for(main: Node, id: String) -> Node:
	if not ROSTER.has(id): return null
	var node_name := "Roster_" + id
	var n := main.get_node_or_null(node_name)
	if n != null: return n
	var e: Array = ROSTER[id]
	var m := ModelEntity.new()
	m.name = node_name
	m.model = DIR + str(e[1])
	m.height = float(e[2])
	m.source_height = 0.0                 # measured when built (model_entity.gd _fit)
	m.auto_anim = true
	main.add_child(m)
	return m
