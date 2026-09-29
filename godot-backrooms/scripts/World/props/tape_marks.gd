extends Node3D
## Every strip of reflective hazard tape stuck on this level's walls and floors (tape_tool.gd lays
## them, and peels them back off). The strips are kept per level in a static list, so they are
## still there after a respawn or a trip to another level and back: the whole point is to find
## your own marks again when the corridors loop. In co-op each strip goes to the others as well
## (Net.send_tape / Net.send_tape_removed) and theirs come in through receive() / receive_removed().
##
## A strip is a dictionary {id, a, b, n, t, by}: its ends and the surface normal, when it went down
## (unix time, so the scanner can tell you how long ago: scanner.gd) and the callsign of whoever
## stuck it. It is drawn as a flat quad a few millimetres off the surface, WIDTH across, with the
## tape texture repeating along it; the chevrons point from where you started pulling to where you
## let go. The look (glossy vinyl, retroreflective under the torch) is shaders/reflective_tape.gdshader.
## Built by level_builder.gd.

const WIDTH := 0.2                   # m: wide floor-marking tape, easy to spot down a corridor
const LIFT := 0.004                  # m off the surface
const LIFT_STEP := 0.0007            # each later strip sits a hair higher, so crossings don't z-fight
const MAX_PER_LEVEL := 240           # the oldest strip comes off past this
const TEXTURE := "res://textures/items/hazard_tapes/hazardous_tapes.jpg"
const TEX_ASPECT := 998.0 / 561.0    # the texture's height over its width: one repeat is this many widths
const SHADER := preload("res://shaders/reflective_tape.gdshader")
const MarkStore := preload("res://scripts/World/props/mark_store.gd")
const PICK_SLACK := 0.04             # m around a strip that still counts as aiming at it

static var placed := {}              # level index -> Array of strips (see the top)
static var mine := {}                # id -> level index: the strips stuck up on this PC
static var live = null               # the TapeMarks of the level loaded right now
static var _mat: ShaderMaterial
static var _loaded := {}             # levels whose saved strips (mark_store.gd) are in `placed`

var level_id := ""

var meshes := {}                     # id -> MeshInstance3D
var order: Array = []                # ids, oldest first

func _ready() -> void:
	live = self
	level_id = MarkStore.file_id(str(get_parent().level_meta.get("id", "")))
	var lv := MarkStore.key()
	if MarkStore.active() and not _loaded.has(lv):
		_loaded[lv] = true
		if not placed.has(lv):
			placed[lv] = []
		for d in MarkStore.read(level_id).get("tape", []):
			placed[lv].append({"id": str(d.id), "a": MarkStore.v3(d.a), "b": MarkStore.v3(d.b),
				"n": MarkStore.v3(d.n), "t": float(d.t), "by": str(d.by)})
	for s in placed.get(MarkStore.key(), []):
		_spawn(s)

func _exit_tree() -> void:
	if live == self:
		live = null

## Lay a strip from `a` to `b` on the surface with normal `n` (tape_tool.gd, on release)
func place(a: Vector3, b: Vector3, n: Vector3) -> Dictionary:
	var s := {"id": "%08x%08x" % [randi(), randi()], "a": a, "b": b, "n": n,
		"t": Time.get_unix_time_from_system(), "by": Net.my_name()}
	_store(MarkStore.key(), s)
	mine[s.id] = MarkStore.key()
	_spawn(s)
	Net.send_tape([pack(MarkStore.key(), s)])
	save()
	return s

## Take a strip off the wall (tape_tool.gd peeled it) and tell the others
func remove(id: String) -> void:
	_forget(MarkStore.key(), id)
	Net.send_tape_removed(MarkStore.key(), id)
	save()

## Write this level's strips to disk (a level-editor test launch only: mark_store.gd)
func save() -> bool:
	var out: Array = []
	for s in placed.get(MarkStore.key(), []):
		out.append({"id": s.id, "a": MarkStore.arr(s.a), "b": MarkStore.arr(s.b), "n": MarkStore.arr(s.n),
			"t": s.t, "by": s.by})
	return MarkStore.write(level_id, "tape", out)

static func is_mine(id: String) -> bool:
	return mine.has(id)

## The strip under the point `p` on a surface facing `n`, or {} (the newest one where they cross)
func strip_at(p: Vector3, n: Vector3) -> Dictionary:
	var list: Array = placed.get(MarkStore.key(), [])
	for i in range(list.size() - 1, -1, -1):
		var s: Dictionary = list[i]
		var sn: Vector3 = s.n
		if sn.dot(n) < 0.95 or absf(sn.dot(p - s.a)) > 0.05:
			continue
		var along: Vector3 = s.b - s.a
		var l := along.length()
		if l < 0.001:
			continue
		var dir := along / l
		var d := p - (s.a as Vector3)
		var t := d.dot(dir)
		var off := (d - dir * t - sn * sn.dot(d)).length()
		if t >= -PICK_SLACK and t <= l + PICK_SLACK and off <= WIDTH * 0.5 + PICK_SLACK:
			return s
	return {}

## Redraw strip `id` from its start to `k` (0..1) of the way along: it peeling back
func set_extent(id: String, k: float) -> void:
	var mi: MeshInstance3D = meshes.get(id)
	var s := _find(MarkStore.key(), id)
	if mi == null or s.is_empty():
		return
	var a: Vector3 = s.a
	var b: Vector3 = s.b
	strip_mesh(a - global_position, a.lerp(b, clampf(k, 0.0, 1.0)) - global_position, s.n, mi.get_meta("lift"), mi.mesh as ArrayMesh)

func has_strip(id: String) -> bool:
	return meshes.has(id)

## The strips this PC laid on level `level` (the exit bonus counts them: level_exit.gd)
static func mine_on(level: int) -> Array:
	var out: Array = []
	for s in placed.get(level, []):
		if mine.has(s.id):
			out.append(s)
	return out

# ---- co-op --------------------------------------------------------------------------------
## One strip for the wire: [level, a, b, n, id, t, by]
static func pack(level: int, s: Dictionary) -> Array:
	return [level, s.a, s.b, s.n, s.id, s.t, s.by]

## Every strip this PC laid, packed (for a survivor who just joined)
static func pack_mine() -> Array:
	var out: Array = []
	for level in placed:
		for s in placed[level]:
			if mine.has(s.id):
				out.append(pack(level, s))
	return out

## A strip from another survivor (Net._tape_rpc): kept for its level, drawn if that's this one
static func receive(level: int, s: Dictionary) -> void:
	if not _find(level, s.id).is_empty():
		return
	_store(level, s)
	if live != null and is_instance_valid(live) and level == MarkStore.key():
		live._spawn(s)

static func receive_removed(level: int, id: String) -> void:
	if live != null and is_instance_valid(live) and level == MarkStore.key():
		live._forget(level, id)
	else:
		_drop(level, id)

# ---- storage and meshes ---------------------------------------------------------------------
static func _store(level: int, s: Dictionary) -> void:
	if not placed.has(level):
		placed[level] = []
	var list: Array = placed[level]
	list.append(s)
	if list.size() > MAX_PER_LEVEL:
		mine.erase(list.pop_front().id)

## Metres of tape this PC has stuck up since `unix` and not peeled back off (the death card)
static func laid_since(unix: float) -> float:
	var total := 0.0
	for id in mine:
		var s := _find(int(mine[id]), str(id))
		if not s.is_empty() and float(s.get("t", 0.0)) >= unix:
			total += (s.a as Vector3).distance_to(s.b as Vector3)
	return total

static func _find(level: int, id: String) -> Dictionary:
	for s in placed.get(level, []):
		if s.id == id:
			return s
	return {}

static func _drop(level: int, id: String) -> void:
	var list: Array = placed.get(level, [])
	for i in list.size():
		if list[i].id == id:
			list.remove_at(i)
			break
	mine.erase(id)

func _forget(level: int, id: String) -> void:
	_drop(level, id)
	var mi: MeshInstance3D = meshes.get(id)
	if mi != null:
		mi.queue_free()
	meshes.erase(id)
	order.erase(id)

func _spawn(s: Dictionary) -> void:
	var mi := MeshInstance3D.new()
	var lift := LIFT + LIFT_STEP * (order.size() % 8)
	mi.set_meta("lift", lift)
	mi.mesh = strip_mesh((s.a as Vector3) - global_position, (s.b as Vector3) - global_position, s.n, lift)
	mi.material_override = material()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	meshes[s.id] = mi
	order.append(s.id)
	if order.size() > MAX_PER_LEVEL:
		var old: String = order.pop_front()
		var om: MeshInstance3D = meshes.get(old)
		if om != null:
			om.queue_free()
		meshes.erase(old)

## The shared tape material (strips, the one being pulled, the roll's outside)
static func material() -> ShaderMaterial:
	if _mat == null:
		_mat = ShaderMaterial.new()
		_mat.shader = SHADER
		_mat.set_shader_parameter("albedo_tex", load(TEXTURE))
	return _mat

## A flat strip `a` -> `b` lying on a surface facing `n`, `lift` off it. Into `mesh` if given
## (the strip being pulled reuses its mesh every frame), else a new one.
static func strip_mesh(a: Vector3, b: Vector3, n: Vector3, lift: float, mesh: ArrayMesh = null) -> ArrayMesh:
	if mesh == null:
		mesh = ArrayMesh.new()
	mesh.clear_surfaces()
	var along := b - a
	var length := along.length()
	if length < 0.001:
		return mesh
	var dir := along / length
	var side := n.cross(dir).normalized() * WIDTH * 0.5
	var up := n * lift
	var v_end := length / (WIDTH * TEX_ASPECT)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	quad(st, n,
		[a - side + up, a + side + up, b + side + up, b - side + up],
		[Vector2(0, 0), Vector2(1, 0), Vector2(1, v_end), Vector2(0, v_end)])
	st.commit(mesh)
	return mesh

## Two triangles facing `n` (Godot's front faces wind clockwise; the order is fixed up here so
## callers can list the corners either way round). `normals`: one per corner for a curved face.
static func quad(st: SurfaceTool, n: Vector3, p: Array, uv: Array, normals: Array = []) -> void:
	for t in [[0, 1, 2], [0, 2, 3]]:
		var i: Array = t
		if (p[i[1]] - p[i[0]]).cross(p[i[2]] - p[i[0]]).dot(n) > 0.0:
			i = [i[0], i[2], i[1]]
		for k in i:
			st.set_normal(normals[k] if normals.size() == 4 else n)
			st.set_uv(uv[k])
			st.add_vertex(p[k])
