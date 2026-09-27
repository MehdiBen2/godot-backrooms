extends "res://scripts/World/level/level_geometry.gd"
## THE LEVEL, layer 3: freeform props. The .lvl's optional "thin_walls" ([{piece, pos, rot}, ...]) -
## individually placed panels from the imported wall kit (res://Assets/LoafbrrAssets/BackroomsLikeAsset2/
## Scenes/Wall/<piece>.tscn), positioned anywhere in world space rather than snapped to the grid. Each
## kit scene already ships its own collision, so placing it is all that's needed.

const WALL_KIT_DIR := "res://Assets/LoafbrrAssets/BackroomsLikeAsset2/Scenes/Wall/"

var _wall_piece_cache: Dictionary = {}       # piece name -> PackedScene

func build_thin_walls() -> void:
	var thin_walls: Array = level_data.get("thin_walls", [])
	for i in thin_walls.size():
		var entry: Dictionary = thin_walls[i]
		var piece := str(entry.get("piece", ""))
		if piece.is_empty(): continue
		var scene := _load_wall_piece(piece)
		if scene == null: continue
		var inst := scene.instantiate() as Node3D
		var pos: Array = entry.get("pos", [0.0, 0.0, 0.0])
		inst.position = Vector3(pos[0], pos[1], pos[2])
		inst.rotation.y = deg_to_rad(float(entry.get("rot", 0.0)))
		inst.set_meta("thin_wall_index", i)   # so a dev-mode tool (build_mode.gd) can find/remove it by index
		add_child(inst)

func _load_wall_piece(piece: String) -> PackedScene:
	if not _wall_piece_cache.has(piece):
		var path := WALL_KIT_DIR + piece + ".tscn"
		_wall_piece_cache[piece] = load(path) if ResourceLoader.exists(path) else null
	return _wall_piece_cache[piece]
