extends Node3D
## Every freehand sketch line drawn on this level's walls and floors (sketch_tool.gd draws them). A
## stroke is a dictionary {id, pts, n, c}: the points along the surface, its normal and a colour index
## into COLORS. It is a thin wobbly ribbon a few millimetres off the surface, so it reads as marker
## drawn by hand. Kept per level in a static list (like tape_marks.gd), and on disk when testing from
## the level editor (mark_store.gd). Built by level_builder.gd.

const MarkStore := preload("res://scripts/World/props/mark_store.gd")

const WIDTH := 0.03                  # m: a marker line
const LIFT := 0.006                  # m off the surface (above the tape at 0.004)
const LIFT_STEP := 0.0004
const ERASE_RADIUS := 0.1               # m around a line that still counts as pointing at it
const MAX_PER_LEVEL := 400
const COLORS := [Color("d92b2b"), Color("f2efe6"), Color("1b1b1b"), Color("e6c619"), Color("2b6fd9")]
const COLOR_NAMES := ["RED", "WHITE", "BLACK", "YELLOW", "BLUE"]

static var placed := {}              # level index -> Array of strokes
static var live = null
static var _loaded := {}
static var _mat: StandardMaterial3D

var level_id := ""
var meshes := {}

func _ready() -> void:
	live = self
	level_id = str(get_parent().level_meta.get("id", ""))
	var lv := Game.level_index
	if MarkStore.active() and not _loaded.has(lv):
		_loaded[lv] = true
		var list: Array = placed.get(lv, [])
		for d in MarkStore.read(level_id).get("sketch", []):
			var pts: Array = []
			for p in d.pts:
				pts.append(MarkStore.v3(p))
			list.append({"id": str(d.id), "pts": pts, "n": MarkStore.v3(d.n), "c": int(d.c)})
		placed[lv] = list
	for s in placed.get(lv, []):
		_spawn(s)

func _exit_tree() -> void:
	if live == self:
		live = null

func add(pts: Array, n: Vector3, c: int) -> void:
	var s := {"id": "%08x%08x" % [randi(), randi()], "pts": pts, "n": n, "c": c}
	if not placed.has(Game.level_index):
		placed[Game.level_index] = []
	placed[Game.level_index].append(s)
	_spawn(s)
	if placed[Game.level_index].size() > MAX_PER_LEVEL:
		var old: Dictionary = placed[Game.level_index].pop_front()
		if meshes.has(old.id):
			meshes[old.id].queue_free()
			meshes.erase(old.id)
	_save()

## Rub out the stroke under the point `p` on a surface facing `n` (the newest where they cross)
func remove_near(p: Vector3, n: Vector3) -> bool:
	var list: Array = placed.get(Game.level_index, [])
	for i in range(list.size() - 1, -1, -1):
		var s: Dictionary = list[i]
		if (s.n as Vector3).dot(n) < 0.95 or absf((s.n as Vector3).dot(p - s.pts[0])) > 0.05:
			continue
		for q in s.pts:
			if (q as Vector3).distance_to(p) <= ERASE_RADIUS:
				list.remove_at(i)
				if meshes.has(s.id):
					meshes[s.id].queue_free()
					meshes.erase(s.id)
				_save()
				return true
	return false

func _save() -> void:
	var out: Array = []
	for s in placed.get(Game.level_index, []):
		var pts: Array = []
		for p in s.pts:
			pts.append(MarkStore.arr(p))
		out.append({"id": s.id, "pts": pts, "n": MarkStore.arr(s.n), "c": s.c})
	MarkStore.write(level_id, "sketch", out)

func _spawn(s: Dictionary) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = ribbon(s.pts, s.n, s.c, LIFT + LIFT_STEP * (meshes.size() % 8), global_position)
	mi.material_override = material()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	meshes[s.id] = mi

static func material() -> StandardMaterial3D:
	if _mat == null:
		_mat = StandardMaterial3D.new()
		_mat.vertex_color_use_as_albedo = true
		_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		_mat.roughness = 0.85
	return _mat

## A wobbling ribbon along `pts` on a surface facing `n`. Into `mesh` if given (the live stroke).
static func ribbon(pts: Array, n: Vector3, c: int, lift: float, origin := Vector3.ZERO, mesh: ArrayMesh = null) -> ArrayMesh:
	if mesh == null:
		mesh = ArrayMesh.new()
	mesh.clear_surfaces()
	if pts.size() < 2:
		return mesh
	var col: Color = COLORS[clampi(c, 0, COLORS.size() - 1)]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	st.set_color(col)
	var up := n * lift
	var run := 0.0
	for i in pts.size():
		var p: Vector3 = pts[i]
		var t: Vector3 = (pts[mini(i + 1, pts.size() - 1)] as Vector3) - (pts[maxi(i - 1, 0)] as Vector3)
		if i > 0:
			run += p.distance_to(pts[i - 1])
		var side := n.cross(t.normalized()).normalized()
		# pen pressure: the line swells and thins as it goes, and drifts a hair off the true path
		var w := WIDTH * (0.75 + 0.25 * sin(run * 23.0) + 0.12 * sin(run * 61.0 + 1.3))
		var drift := side * WIDTH * 0.25 * sin(run * 9.0 + 0.7)
		st.set_normal(n)
		st.add_vertex(p - origin + up + drift - side * w * 0.5)
		st.set_normal(n)
		st.add_vertex(p - origin + up + drift + side * w * 0.5)
	st.commit(mesh)
	return mesh
