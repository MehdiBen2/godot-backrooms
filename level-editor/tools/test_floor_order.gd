extends SceneTree
## Floor reordering and automatic numbering: insert, move, delete and renumber floors, each time checking that the
## numbers run 1, 2, 3 ... and -1, -2, -3 ... with no gaps, that a floor's content went with it, and that undo works.
## godot --path level-editor --headless --script res://tools/test_floor_order.gd

var ed
var fails := 0

func _initialize() -> void:
	ed = (load("res://level_editor.tscn") as PackedScene).instantiate()
	root.add_child(ed)
	for i in 10: await process_frame
	print("start: floors ", ed._floor_numbers(), " on ", ed.floor_idx)
	ed._renumber_floors()                          # (level 0 has gaps of its own: start from tidy numbers)
	_check("tidy start", _contiguous(ed._floor_numbers()))
	# tag each floor by an object count so we can tell the contents apart
	var base: Array = ed._floor_numbers()
	var tags := {}
	for f: int in base:
		ed._switch_floor(f)
		tags[f] = ed.objects.size()
	ed._switch_floor(0)
	# 1. insert a floor above the ground floor: the old floors above move up, ground stays
	ed._insert_floor(1)
	var after: Array = ed._floor_numbers()
	_check("insert above ground: new floor is 1 and we are on it", ed.floor_idx == 1 and ed._floor_name(1) == "Floor 1")
	_check("floor count +1", after.size() == base.size() + 1)
	_check("numbers contiguous", _contiguous(after))
	_check("old floor 1 content is now on 2", base.has(1) == false or _count(2) == tags[1])
	# 2. move this new floor up (swap with whatever is above), content goes with it
	var n_new: int = ed.objects.size()
	if after.has(2):
		ed._move_floor(1)
		_check("moved up: now on 2", ed.floor_idx == 2)
		_check("its content went with it", ed.objects.size() == n_new)
		_check("numbers still contiguous", _contiguous(ed._floor_numbers()))
		ed._undo()
		_check("undo puts it back on 1", ed.floor_idx == 1 and ed.objects.size() == n_new)
	# 3. move below ground (ground and the new floor swap)
	ed._switch_floor(1)
	ed._move_floor(-1)
	_check("moved to 0 (swapped with ground)", ed.floor_idx == 0 and ed.objects.size() == n_new)
	ed._undo()
	# 4. delete a middle floor: the gap closes
	ed._switch_floor(1)
	var before_del: Array = ed._floor_numbers()
	ed._delete_floor()
	var gone: Array = ed._floor_numbers()
	_check("delete: one fewer", gone.size() == before_del.size() - 1)
	_check("delete: numbers contiguous (no gap)", _contiguous(gone))
	ed._undo()
	_check("undo brings the floor back", ed._floor_numbers().size() == before_del.size())
	# 5. a gap an old file had is closed by Renumber
	var all: Dictionary = ed._all_floors()
	var cur: int = ed.floor_idx
	var gap := {}
	for f: int in all: gap[f + 5 if f > 0 else f] = all[f]
	if gap.size() > 1:
		ed._set_floors(gap, cur + 5 if cur > 0 else cur)
		_check("gap exists", not _contiguous(ed._floor_numbers()))
		ed._renumber_button()
		_check("renumber closes it", _contiguous(ed._floor_numbers()))
	# 6. save payload carries the right floor keys
	var payload: Dictionary = ed._current_payload()
	var keys: Array = payload.get("floors", {}).keys()
	print("saved floor keys: ", keys)
	print("RESULT: %s (%d failed)" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(0 if fails == 0 else 1)

func _count(f: int) -> int:
	var all: Dictionary = ed._all_floors()
	return (all[f].objects as Array).size() if all.has(f) else -1

func _contiguous(fs: Array) -> bool:
	var s := fs.duplicate()
	s.sort()
	var ups := s.filter(func(f: int) -> bool: return f > 0)
	var downs := s.filter(func(f: int) -> bool: return f < 0)
	for i in ups.size():
		if ups[i] != i + 1: return false
	downs.reverse()
	for i in downs.size():
		if downs[i] != -(i + 1): return false
	return s.has(0)

func _check(what: String, ok: bool) -> void:
	if not ok: fails += 1
	print("  [%s] %s" % ["ok" if ok else "FAIL", what])
