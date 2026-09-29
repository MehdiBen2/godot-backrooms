extends Node3D
## A flight of stairs between floors of a level (level editor objects "stairs_up" / "stairs_down", built by
## level_geometry.gd _build_stairs). It runs along its local +x: up from floor level to `rise`, or down into its
## pit cell to -rise. Near the far end, in the dark doorway, you are taken to the next floor (Game.change_floor):
## beside that floor's opposite stairs, nearest this spot.

const CELL := 4.5

var up := true
var rise := 3.0
var half_width := CELL * 0.5
var from := Vector2.ZERO             # this flight's own position, in cells
var used := false

func _process(_delta: float) -> void:
	if used or Game.dead or not Game.playing:
		return
	var player: Node3D = get_parent().player
	if player == null:
		return
	var p := to_local(player.global_position)
	if absf(p.z) > half_width or p.x < CELL * 0.22 or p.x > CELL * 0.75:
		return
	if (up and p.y > rise * 0.55) or (not up and p.y < -rise * 0.45):
		used = true
		Game.change_floor(Game.level_floor + (1 if up else -1), from, "stairs_down" if up else "stairs_up")
