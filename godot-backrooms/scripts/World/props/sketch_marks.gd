extends Node3D
## Every freehand sketch line drawn on this floor's walls and floors (sketch_tool.gd draws them). A
## stroke is a dictionary {id, pts, n, col, w, wob, style}: the points along the surface, its normal, the
## colour (with opacity), the width in metres, how much the hand wobbles (0..1) and "solid" / "dashed" /
## "dotted". It is a thin ribbon a few millimetres off the surface, so it reads as marker drawn by hand.
## Kept per floor in a static list (like tape_marks.gd) and on disk (mark_store.gd). Built by level_builder.gd.

const MarkStore := preload("res://scripts/World/props/mark_store.gd")

const WIDTH := 0.03                  # m: the default marker line
const LIFT := 0.006                  # m off the surface (above the tape at 0.004)
const LIFT_STEP := 0.0004
const ERASE_RADIUS := 0.1            # m around a line that still counts as pointing at it
const MAX_PER_LEVEL := 400
const COLORS := [Color("d92b2b"), Color("e8781a"), Color("e6c619"), Color("2fa84f"), Color("2b6fd9"),
	Color("f2efe6"), Color("1b1b1b"), Color("000000")]
const COLOR_NAMES := ["RED", "ORANGE", "YELLOW", "GREEN", "BLUE", "WHITE", "BLACK", "JET BLACK"]
const STYLES := ["solid", "dashed", "dotted"]

static var placed := {}              # MarkStore.key() -> Array of strokes
static var live = null
static var _loaded := {}
static var _mat: StandardMaterial3D

var level_id := ""
var meshes := {}
var _undo: Array = []                # what was done, newest last: {op: add / del / clear, ...}
var _redo: Array = []

func _ready() -> void:
	live = self
	level_id = MarkStore.file_id(str(get_parent().level_meta.get("id", "")))
	var lv := MarkStore.key()
	if not _loaded.has(lv):
		_loaded[lv] = true
		var list: Array = placed.get(lv, [])
		for d in MarkStore.read(level_id).get("sketch", []):
			var pts: Array = []
			for p in d.pts:
				pts.append(MarkStore.v3(p))
			var col: Color = COLORS[clampi(int(d.get("c", 0)), 0, COLORS.size() - 1)]
			if d.has("col"):
				col = Color.html(str(d.col))
			list.append({"id": str(d.id), "pts": pts, "n": MarkStore.v3(d.n), "col": col,
				"w": float(d.get("w", WIDTH)), "wob": float(d.get("wob", 1.0)), "style": str(d.get("style", "solid"))})
		placed[lv] = list
	_spawn_all(lv)

## Wait for the level's colliders to exist before checking what the lines sit on
func _spawn_all(lv: String) -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	if not is_inside_tree():
		return
	_prune(lv)
	for s in placed.get(lv, []):
		if not meshes.has(s.id):
			_spawn(s)

func reload_floor() -> void:
	for m in meshes.values():
		if is_instance_valid(m):
			m.queue_free()
	meshes.clear()
	_undo.clear()
	_redo.clear()
	level_id = MarkStore.file_id(str(get_parent().level_meta.get("id", "")))
	var lv := MarkStore.key()
	if not _loaded.has(lv):
		_loaded[lv] = true
		var list: Array = placed.get(lv, [])
		for d in MarkStore.read(level_id).get("sketch", []):
			var pts: Array = []
			for p in d.pts:
				pts.append(MarkStore.v3(p))
			var col: Color = COLORS[clampi(int(d.get("c", 0)), 0, COLORS.size() - 1)]
			if d.has("col"):
				col = Color.html(str(d.col))
			list.append({"id": str(d.id), "pts": pts, "n": MarkStore.v3(d.n), "col": col,
				"w": float(d.get("w", WIDTH)), "wob": float(d.get("wob", 1.0)), "style": str(d.get("style", "solid"))})
		placed[lv] = list
	_spawn_all(lv)

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
	if meshes.has(id):
		meshes[id].queue_free()
		meshes.erase(id)

## Write this floor's strokes to disk; false if the file could not be written
func save() -> bool:
	level_id = MarkStore.file_id(str(get_parent().level_meta.get("id", "")))
	var out: Array = []
	for s in placed.get(MarkStore.key(), []):
		var pts: Array = []
		for p in s.pts:
			pts.append(MarkStore.arr(p))
		out.append({"id": s.id, "pts": pts, "n": MarkStore.arr(s.n), "col": (s.col as Color).to_html(true),
			"w": s.w, "wob": s.wob, "style": s.style})
	return MarkStore.write(level_id, "sketch", out)

## Delete the parts of every line that no longer have a surface under them (a wall was removed): a
## stroke is cut down to the stretches still on a surface, or dropped if none is left. Saved if changed.
func _prune(lv: String) -> void:
	var list: Array = placed.get(lv, [])
	var out: Array = []
	var changed := false
	for s in list:
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
		save()

func _spawn(s: Dictionary) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = ribbon(s.pts, s.n, s, LIFT + LIFT_STEP * (meshes.size() % 8), global_position)
	mi.material_override = material()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	meshes[s.id] = mi

func _supported_runs(s: Dictionary) -> Array:
	var space := get_world_3d().direct_space_state
	var n: Vector3 = s.n
	var runs: Array = []
	var cur: Array = []
	for p in s.pts:
		var q := PhysicsRayQueryParameters3D.create(p + n * 0.1, p - n * 0.1, 1)
		if space.intersect_ray(q).is_empty():
			if cur.size() >= 2:
				runs.append(cur)
			cur = []
		else:
			cur.append(p)
	if cur.size() >= 2:
		runs.append(cur)
	return runs

static func material() -> StandardMaterial3D:
	if _mat == null:
		_mat = StandardMaterial3D.new()
		_mat.vertex_color_use_as_albedo = true
		_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_mat.roughness = 0.9
		_mat.metallic_specular = 0.1         # so black is black, not a grey sheen
	return _mat

## A ribbon along `pts` on a surface facing `n`, drawn with `st` ({col, w, wob, style}). Into `mesh` if given
## (the live stroke). The wobble is pen pressure (the line swells and thins) and a drift off the true path.
static func ribbon(pts: Array, n: Vector3, st: Dictionary, lift: float, origin := Vector3.ZERO, mesh: ArrayMesh = null) -> ArrayMesh:
	if mesh == null:
		mesh = ArrayMesh.new()
	mesh.clear_surfaces()
	if pts.size() < 2:
		return mesh
	var width: float = st.w
	var wob: float = st.wob
	var style: String = st.style
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	tool.set_color(st.col)
	var up := n * lift
	var run := 0.0
	var prev_l := Vector3.ZERO
	var prev_r := Vector3.ZERO
	for i in pts.size():
		var p: Vector3 = pts[i]
		var t: Vector3 = (pts[mini(i + 1, pts.size() - 1)] as Vector3) - (pts[maxi(i - 1, 0)] as Vector3)
		var seg := 0.0
		if i > 0:
			seg = p.distance_to(pts[i - 1])
			run += seg
		var side := n.cross(t.normalized()).normalized()
		var w := width * (1.0 - 0.25 * wob + wob * (0.25 * sin(run * 23.0) + 0.12 * sin(run * 61.0 + 1.3)))
		var drift := side * width * 0.25 * wob * sin(run * 9.0 + 0.7)
		var l := p - origin + up + drift - side * w * 0.5
		var r := p - origin + up + drift + side * w * 0.5
		if i > 0 and _ink(style, run - seg * 0.5, width):
			for v in [prev_l, prev_r, r, prev_l, r, l]:
				tool.set_normal(n)
				tool.add_vertex(v)
		prev_l = l
		prev_r = r
	tool.commit(mesh)
	return mesh

## Is there ink `at` metres along the line: always for solid, in dashes or dots otherwise
static func _ink(style: String, at: float, width: float) -> bool:
	match style:
		"dashed":
			return fmod(at, 0.16) < 0.10
		"dotted":
			var period := maxf(0.06, width * 2.6)
			return fmod(at, period) < period * 0.45
	return true
