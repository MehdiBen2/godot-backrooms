extends Node3D
## Every freehand sketch line drawn on this floor's walls and floors (sketch_tool.gd draws them). A
## stroke is a dictionary {id, pts, n, col, w, wob, style}: the points along the surface, its normal, the
## colour (with opacity), the width in metres, how much the hand wobbles (0..1) and "solid" / "dashed" /
## "dotted". It is a thin ribbon a few millimetres off the surface; shaders/sketch_marker.gdshader makes it
## felt-tip ink (round ends, a ragged bled edge, the surface's grain showing through, lit like the wall).
## Kept per floor in a static list (like tape_marks.gd) and on disk (mark_store.gd). Built by level_builder.gd.

const MarkStore := preload("res://scripts/World/props/mark_store.gd")
const SHADER := preload("res://shaders/sketch_marker.gdshader")

const WIDTH := 0.03                  # m: the default marker line
const LIFT := 0.006                  # m off the surface (above the tape at 0.004)
const LIFT_STEP := 0.0004
const PAD := 1.4                     # the ribbon is this much wider than the ink (shaders/sketch_marker.gdshader)
const ERASE_RADIUS := 0.1            # m around a line that still counts as pointing at it
const MAX_PER_LEVEL := 800
const MAX_TRASH := 2000
const COLORS := [Color("d92b2b"), Color("e8781a"), Color("e6c619"), Color("2fa84f"), Color("2b6fd9"),
	Color("f2efe6"), Color("1b1b1b"), Color("000000")]
const COLOR_NAMES := ["RED", "ORANGE", "YELLOW", "GREEN", "BLUE", "WHITE", "BLACK", "JET BLACK"]
const STYLES := ["solid", "dashed", "dotted"]

static var placed := {}              # MarkStore.key() -> Array of strokes
static var live = null
static var _loaded := {}
static var _mat: ShaderMaterial

var level_id := ""
# The strokes are drawn in batches, one mesh per BATCH x BATCH metres (one per line would be hundreds of nodes):
# meshes: stroke id -> its batch's key; _batch: key -> that batch's strokes; _batch_mi: key -> its MeshInstance3D
const BATCH := 36.0
# a mesh holds at most 256 surfaces and every stroke is one: a full batch spills into the next page of its cell
const MAX_STROKES_PER_BATCH := 200
const PAGE_STEP := 100000              # page keys sit far off the real cells, so they never collide with one
var meshes := {}
var _batch := {}
var _batch_mi := {}
var _undo: Array = []                # what was done, newest last: {op: add / del / clear, ...}
var _redo: Array = []

func _ready() -> void:
	live = self
	_load()

## Read this floor's saved strokes into `placed` (once a run), moved by however far the level editor has
## shifted the cells since they were saved (mark_store.gd), then draw them
func _load() -> void:
	MarkStore.use_level(get_parent())
	level_id = MarkStore.file_id(str(get_parent().level_meta.get("id", "")))
	var lv := MarkStore.key()
	if not _loaded.has(lv):
		_loaded[lv] = true
		var list: Array = placed.get(lv, [])
		var file := MarkStore.read(level_id)
		list.append_array(_shifted(_unpack(file.get("sketch", [])), MarkStore.moved(file, "sketch")))
		placed[lv] = list
	_spawn_all(lv)

## Wait for the level's colliders to exist before checking what the lines sit on
func _spawn_all(lv: int) -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	if not is_inside_tree():
		return
	_prune(lv)
	for s in placed.get(lv, []):
		if not meshes.has(s.id):
			_spawn(s)

func reload_floor() -> void:
	for m in _batch_mi.values():
		if is_instance_valid(m):
			m.queue_free()
	meshes.clear()
	_batch.clear()
	_batch_mi.clear()
	_undo.clear()
	_redo.clear()
	_load()

func _exit_tree() -> void:
	if live == self:
		live = null

func count() -> int:
	return placed.get(MarkStore.key(), []).size()

## Add a stroke; `st` is {col, w, wob, style} (sketch_tool.gd)
func add(pts: Array, n: Vector3, st: Dictionary) -> void:
	var s := {"id": "%08x%08x" % [randi(), randi()], "pts": pts, "n": n, "col": st.col, "w": st.w,
		"wob": st.wob, "style": st.style}
	var key := MarkStore.key()
	if not placed.has(key):
		placed[key] = []
	placed[key].append(s)
	_spawn(s)
	if placed[key].size() > MAX_PER_LEVEL:
		_drop_mesh(placed[key].pop_front().id)
	_done({"op": "add", "s": s})

## Add several strokes at once (a stamp), undone together
func add_many(lines: Array, n: Vector3, st: Dictionary) -> void:
	var key := MarkStore.key()
	if not placed.has(key):
		placed[key] = []
	var made: Array = []
	for pts in lines:
		var s := {"id": "%08x%08x" % [randi(), randi()], "pts": pts, "n": n, "col": st.col, "w": st.w,
			"wob": st.wob, "style": st.style}
		placed[key].append(s)
		_spawn(s)
		made.append(s)
	while placed[key].size() > MAX_PER_LEVEL:
		_drop_mesh(placed[key].pop_front().id)
	_done({"op": "addmany", "list": made})

## Rub out the stroke under the point `p` on a surface facing `n` (the newest where they cross)
func remove_near(p: Vector3, n: Vector3) -> bool:
	var list: Array = placed.get(MarkStore.key(), [])
	for i in range(list.size() - 1, -1, -1):
		var s: Dictionary = list[i]
		if (s.n as Vector3).dot(n) < 0.95 or absf((s.n as Vector3).dot(p - s.pts[0])) > 0.05:
			continue
		for q in s.pts:
			if (q as Vector3).distance_to(p) <= maxf(ERASE_RADIUS, float(s.w)):
				list.remove_at(i)
				_drop_mesh(s.id)
				_done({"op": "del", "s": s, "i": i})
				return true
	return false

## Take back the last thing done (a line drawn, rubbed out or cleared)
func undo() -> bool:
	if _undo.is_empty():
		return false
	var op: Dictionary = _undo.pop_back()
	_apply(op, true)
	_redo.append(op)
	save()
	return true

func redo() -> bool:
	if _redo.is_empty():
		return false
	var op: Dictionary = _redo.pop_back()
	_apply(op, false)
	_undo.append(op)
	save()
	return true

func clear_all() -> void:
	var list: Array = placed.get(MarkStore.key(), [])
	if list.is_empty():
		return
	_bin(list)
	_done({"op": "clear", "list": list.duplicate()})
	for s in list:
		_drop_mesh(s.id)
	placed[MarkStore.key()] = []

func _done(op: Dictionary) -> void:
	_undo.append(op)
	if _undo.size() > 200:
		_undo.pop_front()
	_redo.clear()
	save()

## Run `op` backwards (`back`) or forwards again
func _apply(op: Dictionary, back: bool) -> void:
	var key := MarkStore.key()
	if not placed.has(key):
		placed[key] = []
	var list: Array = placed[key]
	match op.op:
		"add":
			if back:
				list.erase(op.s)
				_drop_mesh(op.s.id)
			else:
				list.append(op.s)
				_spawn(op.s)
		"addmany":
			for s in op.list:
				if back:
					list.erase(s)
					_drop_mesh(s.id)
				else:
					list.append(s)
					_spawn(s)
		"del":
			if back:
				list.insert(mini(int(op.i), list.size()), op.s)
				_spawn(op.s)
			else:
				list.erase(op.s)
				_drop_mesh(op.s.id)
		"clear":
			if back:
				for s in op.list:
					list.append(s)
					_spawn(s)
			else:
				for s in op.list:
					_drop_mesh(s.id)
				list.clear()

func _drop_mesh(id: String) -> void:
	if not meshes.has(id): return
	var key: Vector2i = meshes[id]
	meshes.erase(id)
	_batch[key] = (_batch[key] as Array).filter(func(s: Dictionary) -> bool: return s.id != id)
	if (_batch[key] as Array).is_empty():
		if is_instance_valid(_batch_mi[key]): _batch_mi[key].queue_free()
		_batch_mi.erase(key)
		_batch.erase(key)
	else:
		_rebuild(key)

## Write this floor's strokes to disk; false if the file could not be written
func save() -> bool:
	level_id = MarkStore.file_id(str(get_parent().level_meta.get("id", "")))
	return MarkStore.write(level_id, "sketch", _pack(placed.get(MarkStore.key(), [])))

func _pack(list: Array) -> Array:
	var out: Array = []
	for s in list:
		var pts: Array = []
		for p in s.pts:
			pts.append(MarkStore.arr(p))
		out.append({"id": s.id, "pts": pts, "n": MarkStore.arr(s.n), "col": (s.col as Color).to_html(true),
			"w": s.w, "wob": s.wob, "style": s.style})
	return out

func _unpack(data: Array) -> Array:
	var out: Array = []
	for d in data:
		var pts: Array = []
		for p in d.pts:
			pts.append(MarkStore.v3(p))
		var col: Color = COLORS[clampi(int(d.get("c", 0)), 0, COLORS.size() - 1)]
		if d.has("col"):
			col = Color.html(str(d.col))
		out.append({"id": str(d.id), "pts": pts, "n": MarkStore.v3(d.n), "col": col,
			"w": float(d.get("w", WIDTH)), "wob": float(d.get("wob", 1.0)), "style": str(d.get("style", "solid"))})
	return out

## Lines wiped by CLEAR LINES are kept in the marks file too ("sketch_trash"), so they can be recovered
## even after the game was closed
func _bin(lines: Array) -> void:
	level_id = MarkStore.file_id(str(get_parent().level_meta.get("id", "")))
	var file := MarkStore.read(level_id)
	var all: Array = _shifted(_unpack(file.get("sketch_trash", [])), MarkStore.moved(file, "sketch_trash"))
	var have := {}
	for s in all:
		have[s.id] = true
	for s in lines:
		if not have.has(s.id):
			all.append(s)
	if all.size() > MAX_TRASH:
		all = all.slice(all.size() - MAX_TRASH)
	MarkStore.write(level_id, "sketch_trash", _pack(all))

## How many wiped lines could come back
func trash_count() -> int:
	level_id = MarkStore.file_id(str(get_parent().level_meta.get("id", "")))
	var live_ids := {}
	for s in placed.get(MarkStore.key(), []):
		live_ids[s.id] = true
	var n := 0
	for d in MarkStore.read(level_id).get("sketch_trash", []):
		if not live_ids.has(str(d.id)):
			n += 1
	return n

## Bring back every wiped line that isn't on the wall; one undo step. Returns how many came back.
func recover() -> int:
	level_id = MarkStore.file_id(str(get_parent().level_meta.get("id", "")))
	var key := MarkStore.key()
	if not placed.has(key):
		placed[key] = []
	var have := {}
	for s in placed[key]:
		have[s.id] = true
	var made: Array = []
	var file := MarkStore.read(level_id)
	var space := get_world_3d().direct_space_state
	for s in _shifted(_unpack(file.get("sketch_trash", [])), MarkStore.moved(file, "sketch_trash")):
		if not have.has(s.id):
			var at := MarkStore.settle(space, s.pts, s.n)
			if at.is_empty():
				continue
			s.pts = at.pts
			s.n = at.n
			placed[key].append(s)
			_spawn(s)
			made.append(s)
	if made.is_empty():
		return 0
	_done({"op": "addmany", "list": made})
	return made.size()

func _shifted(list: Array, off: Vector3) -> Array:
	if off != Vector3.ZERO:
		for s in list:
			for i in s.pts.size():
				s.pts[i] += off
	return list

## Put every line back on a surface: one whose wall moved or went (the level was edited) is snapped onto
## the nearest wall (MarkStore.settle), then cut down to the stretches with a surface under them; one with
## no wall anywhere near goes in the bin (RECOVER brings it back). Saved if changed.
func _prune(lv: int) -> void:
	var list: Array = placed.get(lv, [])
	var out: Array = []
	var lost: Array = []
	var changed := false
	var space := get_world_3d().direct_space_state
	for s in list:
		var at := MarkStore.settle(space, s.pts, s.n)
		if at.is_empty():
			lost.append(s)
			changed = true
			continue
		if at.moved:
			s.pts = at.pts
			s.n = at.n
			changed = true
		var runs := _supported_runs(s)
		if runs.size() == 1 and runs[0].size() == s.pts.size():
			out.append(s)
			continue
		changed = true
		for run in runs:
			var piece: Dictionary = s.duplicate()
			piece.id = "%08x%08x" % [randi(), randi()]
			piece.pts = run
			out.append(piece)
	if changed:
		placed[lv] = out
		if not lost.is_empty():
			_bin(lost)
		save()

func _spawn(s: Dictionary) -> void:
	var p: Vector3 = s.pts[0]
	var cell := Vector2i(floori(p.x / BATCH), floori(p.z / BATCH))
	var key := cell
	var page := 0
	while _batch.has(key) and (_batch[key] as Array).size() >= MAX_STROKES_PER_BATCH:
		page += 1
		key = cell + Vector2i(PAGE_STEP * page, 0)
	if not _batch.has(key):
		_batch[key] = []
		var mi := MeshInstance3D.new()
		mi.material_override = material()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# a batch drops out past the fog like the floor it lies on (level_geometry.gd _chunk_reach)
		mi.visibility_range_end = get_parent()._chunk_reach()
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		add_child(mi)
		_batch_mi[key] = mi
	(_batch[key] as Array).append(s)
	meshes[s.id] = key
	_rebuild(key)

## Draw a batch again: every stroke in it, one surface each, lifted a little apart so they don't fight
func _rebuild(key: Vector2i) -> void:
	var mesh := ArrayMesh.new()
	var list: Array = _batch[key]
	for i in list.size():
		var s: Dictionary = list[i]
		ribbon(s.pts, s.n, s, LIFT + LIFT_STEP * (i % 8), global_position, mesh, true)
	(_batch_mi[key] as MeshInstance3D).mesh = mesh

func _supported_runs(s: Dictionary) -> Array:
	var space := get_world_3d().direct_space_state
	var n: Vector3 = s.n
	var runs: Array = []
	var cur: Array = []
	for p in s.pts:
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(p + n * 0.1, p - n * 0.1, 1))
		if hit.is_empty() or (hit.normal as Vector3).dot(n) < 0.9:
			if cur.size() >= 2:
				runs.append(cur)
			cur = []
		else:
			cur.append(p)
	if cur.size() >= 2:
		runs.append(cur)
	return runs

## The shared marker material: felt-tip ink with ragged round-capped edges that takes the light and the
## grain of the surface (shaders/sketch_marker.gdshader)
static func material() -> ShaderMaterial:
	if _mat == null:
		_mat = ShaderMaterial.new()
		_mat.shader = SHADER
	return _mat

## A ribbon along `pts` on a surface facing `n`, drawn with `st` ({col, w, wob, style}). Into `mesh` if given
## (the live stroke). The wobble is pen pressure (the line swells and thins) and a drift off the true path;
## the hand's jitter is smoothed out first. The strip is PAD times wider than the ink and runs on past both
## ends: the shader cuts the round caps, the dashes and the ragged edge out of it.
static func ribbon(pts: Array, n: Vector3, st: Dictionary, lift: float, origin := Vector3.ZERO, mesh: ArrayMesh = null, keep := false) -> ArrayMesh:
	if mesh == null:
		mesh = ArrayMesh.new()
	if not keep: mesh.clear_surfaces()          # (keep: add this line as one more surface of the batch)
	if pts.size() < 2:
		return mesh
	var width: float = st.w
	var wob: float = st.wob
	var line := _smooth(pts)
	var count := line.size()
	var dist: Array[float] = [0.0]
	for i in range(1, count):
		dist.append(dist[i - 1] + (line[i] as Vector3).distance_to(line[i - 1]))
	var cap := width * 0.5 * PAD
	var length := dist[count - 1] + cap * 2.0
	# one seed a stroke (from where it starts) so every line's streaks and edge are its own
	var p0: Vector3 = line[0]
	var grain := fposmod(p0.x * 12.9898 + p0.y * 78.233 + p0.z * 37.719, 97.0)
	var style := float(maxi(0, STYLES.find(st.style)))
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	tool.set_custom_format(0, SurfaceTool.CUSTOM_RGBA_FLOAT)
	tool.set_color(st.col)
	tool.set_custom(0, Color(style, grain, width, 0.0))
	tool.set_normal(n)
	var up := n * lift
	# the strip's rungs: a cap's length before the first point, every point, a cap's length past the last
	var rungs: Array = []
	var t0: Vector3 = ((line[1] as Vector3) - p0).normalized()
	var t1: Vector3 = ((line[count - 1] as Vector3) - (line[count - 2] as Vector3)).normalized()
	rungs.append([p0 - t0 * cap, t0, 0.0, 0.0])
	for i in count:
		var t: Vector3 = (line[mini(i + 1, count - 1)] as Vector3) - (line[maxi(i - 1, 0)] as Vector3)
		rungs.append([line[i], t.normalized(), dist[i], dist[i] + cap])
	rungs.append([(line[count - 1] as Vector3) + t1 * cap, t1, dist[count - 1], length])
	for g in rungs:
		var p: Vector3 = g[0]
		var run: float = g[2]
		var side := n.cross(g[1]).normalized()
		var w := width * (1.0 - 0.25 * wob + wob * (0.25 * sin(run * 23.0 + grain) + 0.12 * sin(run * 61.0 + 1.3 + grain)))
		var drift := side * width * 0.25 * wob * sin(run * 9.0 + 0.7 + grain)
		var half := side * w * 0.5 * PAD
		tool.set_tangent(Plane(side, 1.0))
		tool.set_uv2(Vector2(w, length))
		tool.set_uv(Vector2(0.0, g[3]))
		tool.add_vertex(p - origin + up + drift - half)
		tool.set_uv(Vector2(1.0, g[3]))
		tool.add_vertex(p - origin + up + drift + half)
	tool.commit(mesh)
	return mesh

## The points with the hand's jitter taken out: two passes of a light average, the ends kept where they are
static func _smooth(pts: Array) -> Array:
	var out := pts.duplicate()
	if out.size() < 4:
		return out
	for pass_ in 2:
		var prev := out.duplicate()
		for i in range(1, out.size() - 1):
			out[i] = (prev[i - 1] as Vector3) * 0.25 + (prev[i] as Vector3) * 0.5 + (prev[i + 1] as Vector3) * 0.25
	return out
