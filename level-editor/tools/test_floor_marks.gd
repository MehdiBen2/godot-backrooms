extends SceneTree
## The sketches / tape of a floor follow it when the floor changes number (level_editor_files.gd _marks_follow).
## Runs on a throwaway level id ("zz_marks_test"): its .lvl and marks files are made and deleted here, nothing real is touched.
## godot --path level-editor --headless --script res://tools/test_floor_marks.gd

var ed
var fails := 0
const ID := "zz_marks_test"

func _initialize() -> void:
	ed = (load("res://level_editor.tscn") as PackedScene).instantiate()
	root.add_child(ed)
	for i in 10: await process_frame
	var lv: String = ed.GAME.path_join("levels/")
	var mk: String = lv + "marks/"
	DirAccess.make_dir_recursive_absolute(mk)
	# a throwaway level: the real one's index entry is pointed at it for the test, then put back
	var keep: Dictionary = ed.index[ed.current].duplicate()
	ed.index[ed.current]["id"] = ID
	ed.index[ed.current]["file"] = ID + ".lvl"
	ed.floor_uid = {}
	ed.marks_loc = {}
	for f: int in ed._floor_numbers():
		ed.floor_uid[f] = f
		ed.marks_loc[f] = f
	ed._renumber_floors()                          # (level 0 has gaps: start from tidy numbers; the files follow, under the test id)
	var fl: Array = ed._floor_numbers()
	print("floors ", fl)
	# one marks file per floor, each holding its own floor number, so we can tell them apart
	for f: int in fl:
		_write(ed._marks_path(ID, f), {"floor_was": f})
	# 1. insert a floor above ground: floors above (none) ... then move a basement floor and see its file go with it
	ed._switch_floor(-2)
	ed._move_floor(1)                              # -2 swaps with -1: it is now -1
	_check("moved floor is now -1", ed.floor_idx == -1)
	_check("its file is under -1", _read(ed._marks_path(ID, -1)).get("floor_was") == -2)
	_check("the one it swapped with is under -2", _read(ed._marks_path(ID, -2)).get("floor_was") == -1)
	ed._undo()
	_check("undo: back under -2", _read(ed._marks_path(ID, -2)).get("floor_was") == -2)
	_check("undo: the other back under -1", _read(ed._marks_path(ID, -1)).get("floor_was") == -1)
	# 2. insert a floor between: the ones beyond move down one and their files with them
	ed._switch_floor(-1)
	ed._insert_floor(-1)                           # a new floor between -1 and -2: old -2 -> -3, and so on
	_check("old -2 file now under -3", _read(ed._marks_path(ID, -3)).get("floor_was") == -2)
	_check("new floor has no file", not FileAccess.file_exists(ed._marks_path(ID, -2)))
	_check("-1 stayed", _read(ed._marks_path(ID, -1)).get("floor_was") == -1)
	ed._undo()
	_check("undo insert: -2 back", _read(ed._marks_path(ID, -2)).get("floor_was") == -2)
	# 3. delete a floor: the ones beyond close the gap, files with them; undo brings it all back
	ed._switch_floor(-2)
	ed._delete_floor()
	_check("deleted: old -3 file is under -2 now", _read(ed._marks_path(ID, -2)).get("floor_was") == -3)
	ed._undo()
	_check("undo delete: -2's own file is back", _read(ed._marks_path(ID, -2)).get("floor_was") == -2)
	_check("undo delete: -3 back", _read(ed._marks_path(ID, -3)).get("floor_was") == -3)
	# clean up everything the test made
	for f in DirAccess.get_files_at(mk):
		if f.begins_with(ID): DirAccess.remove_absolute(mk + f)
	DirAccess.remove_absolute(lv + ID + ".lvl")
	ed.index[ed.current] = keep
	print("RESULT: %s (%d failed)" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(0 if fails == 0 else 1)

func _write(path: String, d: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(d))

func _read(path: String) -> Dictionary:
	if not FileAccess.file_exists(path): return {}
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	return d if d is Dictionary else {}

func _check(what: String, ok: bool) -> void:
	if not ok: fails += 1
	print("  [%s] %s" % ["ok" if ok else "FAIL", what])
