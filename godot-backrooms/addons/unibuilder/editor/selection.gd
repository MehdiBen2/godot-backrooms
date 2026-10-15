@tool
class_name UBSelection
extends RefCounted
## Editor-side selection state: the current edit mode plus the selected
## element sets. Never serialized; the selection lives only for the session.
## Element keys: vertices int, edges Vector2i(lo, hi), faces int.

signal changed

enum Mode { OBJECT, VERTEX, EDGE, FACE }


var _converting := false

var mode := Mode.OBJECT:
	set(value):
		if mode == value:
			return
		mode = value
		clear_elements(false)
		if not _converting:
			changed.emit()

var vertices := {}
var edges := {}
var faces := {}


## Mode switch that converts the selection instead of clearing it: the old
## selection's vertex coverage maps into the new mode. Downward (face to edge
## to vertex) keeps everything touched, upward keeps only fully covered
## elements. Null data, or Object mode on either side, falls back to clearing.
func change_mode(new_mode: int, data) -> void:
	if mode == new_mode:
		return
	if (
		data == null or new_mode == Mode.OBJECT or mode == Mode.OBJECT
		or current().is_empty()
	):
		mode = new_mode
		return
	var verts := gather_vertices(data)
	_converting = true
	mode = new_mode
	_converting = false
	match new_mode:
		Mode.VERTEX:
			vertices = verts
		Mode.EDGE:
			edges = UBSelectQueries.edges_from_vertices(UBTopology.build(data), verts)
		Mode.FACE:
			faces = UBSelectQueries.faces_from_vertices(data, verts)
	changed.emit()


func clear_elements(emit := true) -> void:
	vertices.clear()
	edges.clear()
	faces.clear()
	if emit:
		changed.emit()


## The set for the current mode (a live reference, not a copy).
func current() -> Dictionary:
	match mode:
		Mode.VERTEX:
			return vertices
		Mode.EDGE:
			return edges
		Mode.FACE:
			return faces
	return {}


func click_key(key: Variant, additive: bool) -> void:
	var set := current()
	if additive:
		if set.has(key):
			set.erase(key)
		else:
			set[key] = true
	else:
		set.clear()
		set[key] = true
	changed.emit()


func select_keys(keys: Array, additive: bool) -> void:
	var set := current()
	if not additive:
		set.clear()
	for k in keys:
		set[k] = true
	changed.emit()


func replace_current(with: Dictionary) -> void:
	var set := current()
	set.clear()
	set.merge(with)
	changed.emit()


func notify() -> void:
	changed.emit()


func count() -> int:
	return current().size()


## The vertex set the current selection moves: vertices directly, or every
## vertex of the selected edges and faces. Out-of-range references are
## skipped, since the selection can briefly outlive the mesh it points into
## (undo/redo).
func gather_vertices(data) -> Dictionary:
	var out := {}
	var vn: int = data.positions.size()
	match mode:
		Mode.VERTEX:
			for vi in vertices:
				if vi >= 0 and vi < vn:
					out[vi] = true
		Mode.EDGE:
			for e: Vector2i in edges:
				if e.x >= 0 and e.x < vn and e.y >= 0 and e.y < vn:
					out[e.x] = true
					out[e.y] = true
		Mode.FACE:
			for fi in faces:
				if fi >= 0 and fi < data.faces.size():
					for vi in data.faces[fi].vertices:
						out[vi] = true
	return out


## Drop element references that point outside `data`. Undo/redo restores and
## external edits can shrink the mesh under the live selection, and a stale
## index must never be dereferenced. Surviving keys may name different
## elements than the user picked; that is acceptable for session state.
func prune_invalid(data) -> void:
	var vn: int = data.positions.size()
	var dropped := false
	for vi in vertices.keys():
		if vi < 0 or vi >= vn:
			vertices.erase(vi)
			dropped = true
	for e: Vector2i in edges.keys():
		if e.x < 0 or e.x >= vn or e.y < 0 or e.y >= vn:
			edges.erase(e)
			dropped = true
	for fi in faces.keys():
		if fi < 0 or fi >= data.faces.size():
			faces.erase(fi)
			dropped = true
	if dropped:
		changed.emit()
