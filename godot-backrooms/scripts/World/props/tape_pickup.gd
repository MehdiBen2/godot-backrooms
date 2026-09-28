extends Node3D
## A roll of reflective hazard tape lying on the carpet. Walking over it puts it in the
## inventory, where rolls stack (up to STACK); hold T to lay a strip (tape_tool.gd). With the
## stack full it stays on the floor. Spawned at random open cells by level_builder._spawn_tape.

const TapeRoll := preload("res://scripts/World/props/tape_roll.gd")

const TRIGGER_RADIUS := 0.9
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

var used := false

func _ready() -> void:
	var roll := TapeRoll.new()
	roll.rotation.x = randf_range(-0.04, 0.04)    # never quite flat on the carpet pile
	add_child(roll)

func _process(_delta: float) -> void:
	if used or Game.dead or not Game.playing:
		return
	var player: Node3D = get_parent().player
	if player == null:
		return
	var d := Vector2(player.global_position.x - global_position.x, player.global_position.z - global_position.z).length()
	if d < TRIGGER_RADIUS and absf(player.global_position.y - global_position.y) < 2.0:
		var ui: Node = Game.main.get_node_or_null("UI") if Game.main != null else null
		if ui == null or not ui.pick_up_item(ITEM_ID, ITEM_NAME, ITEM_DESC, ITEM_CODE, STACK, MODEL_PATH):
			return                       # stack full: leave it for later
		used = true
		var audio: Node = Game.main.get_node_or_null("Audio")
		if audio:
			audio.play_world("flash_click_on.wav")
		queue_free()
