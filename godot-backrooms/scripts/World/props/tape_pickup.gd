extends Node3D
## A roll of reflective hazard tape lying on the carpet. Walking over it, or looking at it and pressing E,
## puts it in the inventory, where rolls stack (up to STACK); hold T to lay a strip (tape_tool.gd). With the
## stack full it stays on the floor. The pickup tooltip is pickup_prompt.gd. Spawned at random open cells by
## level_builder._spawn_tape.

const TapeRoll := preload("res://scripts/World/props/tape_roll.gd")
const PickupPrompt := preload("res://scripts/World/props/pickup_prompt.gd")

const ITEM_ID := "tape"
const ITEM_NAME := "Reflective Hazard Tape"
const ITEM_CODE := "TAPE"
const STACK := 4
const ROLL_LENGTH := 250.0     # m of tape on one roll
const MODEL_PATH := "res://scripts/World/props/tape_roll.gd"
const ITEM_DESC := "A fat roll of black and yellow retroreflective tape, 20 cm wide, 250 m to a roll. " \
	+ "Hold T on a wall or the floor within reach and drag the view to pull a strip out (up to 20 m), " \
	+ "let go to tear it off. The chevrons point the way you pulled. Mark the corridors you have " \
	+ "already walked: when the halls loop back on themselves, the tape tells you. It catches the " \
	+ "torch from a long way off."

func _ready() -> void:
	var roll := TapeRoll.new()
	roll.rotation.x = randf_range(-0.04, 0.04)    # never quite flat on the carpet pile
	add_child(roll)
	var prompt := PickupPrompt.new()
	add_child(prompt)
	prompt.setup({"id": ITEM_ID, "name": ITEM_NAME, "code": ITEM_CODE, "desc": ITEM_DESC, "stack": STACK,
		"model": MODEL_PATH, "sound": "items/torch/flash_click_on.wav", "height": 0.55, "walk_over": true})
