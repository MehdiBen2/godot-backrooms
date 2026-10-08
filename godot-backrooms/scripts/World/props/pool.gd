extends Node3D
## A pool sunk into the floor (the level editor's "pool": object_types.json shape "pool"), built by
## level_geometry.gd _build_pools, which also cuts its outline out of the floor (_cut_cell_tris). In its own frame
## (object_transform: +x the arrow) its outline is its "points" (cells, any shape, closed); the basin goes down
## `shallow` m at the end the arrow comes from and `deep` m at the end it points to, its floor a plain slope between.
##  - tiled walls and floor, unrolled for their UVs so the tiles run on round every corner (level_geometry.gd
##    _wall_uv_mat), and a rounded coping round the rim;
##  - steps down into the shallow end and a chrome ladder at the deep end;
##  - water standing `lip` m under the rim (water.gdshader), which you swim in (player.gd) and go under
##    (water_view.gd): level_data.gd water_at() knows the outline;
##  - solids for its walls, floor and steps.

const CELL := 4.5
const COPING := 0.32               # m: the rim's width round the edge
const COPING_H := 0.035            # ...and how far it stands proud of the floor
const STEP_RISE := 0.24
const STEP_TREAD := 0.34
const STEP_WIDE := 2.0
const SEG := 0.5                   # m: walls built in pieces this long, so their foot follows the sloping floor

var poly := PackedVector2Array()   # the outline, metres, in this frame (x, z)
var _x0 := 0.0
var _x1 := 1.0
var _shallow := 1.1
var _deep := 3.0
var _body: StaticBody3D
var _faces := PackedVector3Array()

## The outline of pool `o` in its own frame, metres, anticlockwise (empty if it has under three points)
static func outline(o: Dictionary) -> PackedVector2Array:
	var out := PackedVector2Array()
	var raw = o.get("points", [])
	if raw is Array:
		for q in raw:
			if q is Array and q.size() >= 2:
				var v := Vector2(float(q[0]), float(q[1])) * CELL
				if out.is_empty() or out[out.size() - 1].distance_to(v) > 0.05: out.append(v)
	if out.size() >= 2 and out[0].distance_to(out[out.size() - 1]) < 0.05: out.remove_at(out.size() - 1)
	if out.size() < 3: return PackedVector2Array()
	if Geometry2D.is_polygon_clockwise(out): out.reverse()
	return out

## The floor's depth at x along the pool (m, positive down)
func depth_at(x: float) -> float:
	return lerpf(_shallow, _deep, clampf((x - _x0) / maxf(_x1 - _x0, 0.01), 0.0, 1.0))

## `mats`: level_geometry.gd _piece_mats (its "tile_uv": the unrolled tile, "chrome"); `water_mat`: the surface's
func build(o: Dictionary, mats: Dictionary, water_mat: Material, shell: bool) -> void:
	name = "Pool_%d" % get_index()
	poly = outline(o)
	if poly.is_empty(): return
	_shallow = clampf(float(o.get("shallow", 1.1)), 0.3, 10.0)
	_deep = clampf(float(o.get("deep", 3.0)), 0.3, 10.0)
	_x0 = INF
	_x1 = -INF
	for v in poly:
		_x0 = minf(_x0, v.x)
		_x1 = maxf(_x1, v.x)
	if not shell: _body = StaticBody3D.new()
	var tile: Material = mats.get("tile_uv", mats.tile)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_basin(st)
	st.generate_tangents()
	_mesh(st, tile)
	var rim := SurfaceTool.new()
	rim.begin(Mesh.PRIMITIVE_TRIANGLES)
	_coping(rim)
	_mesh(rim, _coping_mat())
	if bool(o.get("steps", true)): _steps(mats.tile)
	if bool(o.get("ladder", true)): _ladder(mats.chrome)
	_water(water_mat, -clampf(float(o.get("lip", 0.15)), 0.0, 1.5))
	if _body != null:
		var cs := CollisionShape3D.new()
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(_faces)
		shape.backface_collision = true
		cs.shape = shape
		cs.set_meta("surface", "tile")
		_body.add_child(cs)
		add_child(_body)

## The walls down from the rim (facing in) and the sloping floor, unrolled for their UVs (metres)
func _basin(st: SurfaceTool) -> void:
	var n := poly.size()
	var run := 0.0
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var e := b - a
		var len := e.length()
		if len < 0.001: continue
		var inward := Vector3(-e.y, 0.0, e.x).normalized()     # anticlockwise: the inside is on the left
		var pieces := maxi(1, ceili(len / SEG))
		for k in pieces:
			var p0 := a.lerp(b, float(k) / pieces)
			var p1 := a.lerp(b, float(k + 1) / pieces)
			var d0 := depth_at(p0.x)
			var d1 := depth_at(p1.x)
			var u0 := run + len * k / pieces
			var u1 := run + len * (k + 1) / pieces
			var q := [Vector3(p0.x, 0.0, p0.y), Vector3(p1.x, 0.0, p1.y), Vector3(p1.x, -d1, p1.y), Vector3(p0.x, -d0, p0.y)]
			_quad_uv(st, q, [Vector2(u0, 0.0), Vector2(u1, 0.0), Vector2(u1, -d1), Vector2(u0, -d0)], inward)
		run += len
	# the floor: the outline cut into triangles, each corner at the floor's depth there
	var slope := (_deep - _shallow) / maxf(_x1 - _x0, 0.01)
	var up := Vector3(slope, 1.0, 0.0).normalized()
	var idx := Geometry2D.triangulate_polygon(poly)
	for t in range(0, idx.size(), 3):
		var tri: Array[Vector3] = []
		for j in 3:
			var v := poly[idx[t + j]]
			tri.append(Vector3(v.x, -depth_at(v.x), v.y))
		var order := [0, 1, 2] if (tri[1] - tri[0]).cross(tri[2] - tri[0]).dot(up) < 0.0 else [0, 2, 1]
		for j: int in order:
			st.set_normal(up)
			st.set_uv(Vector2(tri[j].x, tri[j].z))
			st.add_vertex(tri[j])
			_faces.append(tri[j])

## The coping: a band round the rim, a hair proud of the floor, its inner edge rounded over into the pool
func _coping(st: SurfaceTool) -> void:
	var n := poly.size()
	var out := PackedVector2Array()                 # the band's outer edge: the outline pushed out, corners mitred
	for i in n:
		var prev := poly[(i - 1 + n) % n]
		var cur := poly[i]
		var nxt := poly[(i + 1) % n]
		var e0 := (cur - prev).normalized()
		var e1 := (nxt - cur).normalized()
		var o0 := Vector2(e0.y, -e0.x)               # (outward: the right of an anticlockwise outline)
		var o1 := Vector2(e1.y, -e1.x)
		var m := (o0 + o1).normalized()
		out.append(cur + m * COPING / maxf(m.dot(o1), 0.4))
	var h := COPING_H
	for i in n:
		var j := (i + 1) % n
		var a := Vector3(poly[i].x, 0.0, poly[i].y)
		var b := Vector3(poly[j].x, 0.0, poly[j].y)
		var oa := Vector3(out[i].x, 0.0, out[i].y)
		var ob := Vector3(out[j].x, 0.0, out[j].y)
		var inward := (a - oa).normalized()
		_quad(st, [a + Vector3(0, h, 0), b + Vector3(0, h, 0), ob + Vector3(0, h, 0), oa + Vector3(0, h, 0)], Vector3.UP)
		_quad(st, [oa, ob, ob + Vector3(0, h, 0), oa + Vector3(0, h, 0)], -inward)
		# the bull-nose over the edge: down the inside a little, curving in
		var drop := Vector3(0, -0.07, 0)
		_quad(st, [a + Vector3(0, h, 0), b + Vector3(0, h, 0), b + drop + inward * 0.02, a + drop + inward * 0.02], (inward + Vector3.UP).normalized())

## Steps down into the shallow end: solid treads off the middle of the end wall the arrow comes from
func _steps(m: Material) -> void:
	var zc := 0.0
	var count := 0
	for v in poly:
		if v.x < _x0 + 0.6:
			zc += v.y
			count += 1
	zc = zc / maxi(count, 1)
	var n := maxi(1, floori(_shallow / STEP_RISE))
	var rise := _shallow / (n + 1)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in n:
		var top := -rise * (k + 1)
		var xa := _x0 + STEP_TREAD * k
		var xb := xa + STEP_TREAD
		_box(st, Vector3((xa + xb) * 0.5, (top - _shallow) * 0.5, zc), Vector3(xb - xa, top + _shallow, STEP_WIDE))
	_mesh(st, m)
	# walked up as a slope through the treads' middles, as every stair here is
	if _body != null:
		var x_end := _x0 + STEP_TREAD * n
		var pts := PackedVector3Array()
		for zz: float in [zc - STEP_WIDE * 0.5, zc + STEP_WIDE * 0.5]:
			pts.append_array([Vector3(_x0, 0.0, zz), Vector3(x_end + STEP_TREAD * 0.5, -_shallow, zz), Vector3(_x0, -_shallow, zz)])
		var cs := CollisionShape3D.new()
		var hull := ConvexPolygonShape3D.new()
		hull.points = pts
		cs.shape = hull
		cs.set_meta("surface", "tile")
		_body.add_child(cs)

## A chrome pool ladder on the middle of the deep end's wall: two rails up out of the water and over the coping
func _ladder(m: Material) -> void:
	var zc := 0.0
	var count := 0
	for v in poly:
		if v.x > _x1 - 0.6:
			zc += v.y
			count += 1
	zc = zc / maxi(count, 1)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var x := _x1 - 0.16
	var low := -minf(_deep, 2.2) + 0.25
	for s: float in [-0.26, 0.26]:
		var z := zc + s
		_tube(st, Vector3(x, low, z), Vector3(x, 0.85, z), 0.024)
		_tube(st, Vector3(x, 0.85, z), Vector3(x + 0.22, 0.95, z), 0.024)
		_tube(st, Vector3(x + 0.22, 0.95, z), Vector3(x + 0.42, 0.75, z), 0.024)
		_tube(st, Vector3(x + 0.42, 0.75, z), Vector3(x + 0.42, COPING_H, z), 0.024)
	var y := low + 0.15
	while y < -0.1:
		_box(st, Vector3(x, y, zc), Vector3(0.09, 0.03, 0.52))
		y += 0.28
	_mesh(st, m)

func _water(m: Material, y: float) -> void:
	if m == null: return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var idx := Geometry2D.triangulate_polygon(poly)
	for t in range(0, idx.size(), 3):
		var tri: Array[Vector3] = []
		for j in 3:
			var v := poly[idx[t + j]]
			tri.append(Vector3(v.x, y, v.y))
		var order := [0, 1, 2] if (tri[1] - tri[0]).cross(tri[2] - tri[0]).y < 0.0 else [0, 2, 1]
		for j: int in order:
			st.set_normal(Vector3.UP)
			st.add_vertex(tri[j])
	var mi := MeshInstance3D.new()
	mi.name = "Water"
	mi.mesh = st.commit()
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

static var _cope: StandardMaterial3D
func _coping_mat() -> StandardMaterial3D:
	if _cope == null:
		_cope = StandardMaterial3D.new()             # a white glazed bull-nose
		_cope.albedo_color = Color(0.93, 0.93, 0.9)
		_cope.roughness = 0.38
		_cope.metallic_specular = 0.45
	return _cope

func _mesh(st: SurfaceTool, m: Material) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = m
	add_child(mi)

func _quad_uv(st: SurfaceTool, v: Array, uv: Array, n: Vector3) -> void:
	var order := [0, 1, 2, 0, 2, 3]
	if ((v[1] as Vector3) - (v[0] as Vector3)).cross((v[2] as Vector3) - (v[0] as Vector3)).dot(n) > 0.0:
		order = [0, 2, 1, 0, 3, 2]
	for k: int in order:
		st.set_normal(n)
		st.set_uv(uv[k])
		st.add_vertex(v[k])
		_faces.append(v[k])

func _quad(st: SurfaceTool, v: Array, n: Vector3) -> void:
	var order := [0, 1, 2, 0, 2, 3]
	if ((v[1] as Vector3) - (v[0] as Vector3)).cross((v[2] as Vector3) - (v[0] as Vector3)).dot(n) > 0.0:
		order = [0, 2, 1, 0, 3, 2]
	for k: int in order:
		st.set_normal(n)
		st.set_uv(Vector2((v[k] as Vector3).x, (v[k] as Vector3).z))
		st.add_vertex(v[k])

func _box(st: SurfaceTool, at: Vector3, size: Vector3) -> void:
	var h := size * 0.5
	for axis in 3:
		var u := (axis + 1) % 3
		var w := (axis + 2) % 3
		for sgn: float in [-1.0, 1.0]:
			var n := Vector3.ZERO
			n[axis] = sgn
			var q: Array = []
			for k: Array in [[-1.0, -1.0], [1.0, -1.0], [1.0, 1.0], [-1.0, 1.0]]:
				var p := Vector3.ZERO
				p[axis] = sgn * h[axis]
				p[u] = k[0] * h[u]
				p[w] = k[1] * h[w]
				q.append(at + p)
			_quad(st, q, n)

func _tube(st: SurfaceTool, a: Vector3, b: Vector3, r: float) -> void:
	var d := (b - a).normalized()
	var side := (Vector3.UP if absf(d.y) < 0.9 else Vector3.RIGHT).cross(d).normalized()
	var other := d.cross(side)
	for i in 8:
		var n0 := side * cos(TAU * i / 8.0) + other * sin(TAU * i / 8.0)
		var n1 := side * cos(TAU * (i + 1) / 8.0) + other * sin(TAU * (i + 1) / 8.0)
		_quad(st, [a + n0 * r, a + n1 * r, b + n1 * r, b + n0 * r], (n0 + n1).normalized())
