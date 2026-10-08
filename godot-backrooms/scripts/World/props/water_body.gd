extends Node3D
## A body of standing water (the level editor's "water": object_types.json shape "water"), built by
## level_geometry.gd _build_water. In its own frame (object_transform: +x the arrow) it is a box `depth` cells
## along by `scale` across, with its surface `level` metres over the floor. It is only that surface: the floor,
## the walls and anything standing in it are the level's own, seen through it (water.gdshader).
##  - the surface, and a sheer side where an edge ends in the open (not where it runs along a wall);
##  - the ripples of light it throws up the walls round it and in it, and onto a ceiling low enough over it to
##    catch them (water_caustics.gdshader; the ones on whatever is under the water, water.gdshader draws);
##  - nothing solid: you wade (player.gd slows you by level_data.gd water_depth_at), your steps splash
##    (footsteps.gd), and with your head under it the picture and the sound go under too (water_view.gd).

const CELL := 4.5
const PIECE := 0.3                 # m: walls round it are skinned with ripples in pieces this long
const BAND := 2.4                  # m: how far up a wall the ripples reach over the surface
const CEIL_REACH := 4.5            # m: a ceiling closer than this over the water catches them too
## water.gdshader settings per "tint": [absorb per metre, scatter colour]
const TINTS := {
	"teal": [Vector3(0.42, 0.11, 0.13), Color(0.10, 0.46, 0.44)],
	"clear": [Vector3(0.24, 0.06, 0.05), Color(0.16, 0.42, 0.52)],
	"murky": [Vector3(0.9, 0.55, 0.75), Color(0.16, 0.24, 0.12)],
}

static var _surface_shader: Shader
static var _caustic_shader: Shader

var hx := 1.0                      # half its size along / across (m)
var hz := 1.0
var level_y := 0.4
var surface_mat: ShaderMaterial

## `lv`: the level (level_geometry.gd: walls, faces, ceilings). `shell`: a look-only copy of the floor
func build(lv: Node, o: Dictionary, shell: bool) -> void:
	name = "Water_%d" % get_index()
	hx = float(o.get("depth", 3.0)) * CELL * 0.5
	hz = float(o.scale) * CELL * 0.5
	level_y = clampf(float(o.get("level", 0.4)), 0.02, 8.0)
	if _surface_shader == null:
		_surface_shader = load("res://shaders/water.gdshader")
		_caustic_shader = load("res://shaders/water_caustics.gdshader")
	var tint: Array = TINTS.get(str(o.get("tint", "teal")), TINTS.teal)
	surface_mat = ShaderMaterial.new()
	surface_mat.shader = _surface_shader
	surface_mat.set_shader_parameter("absorb", tint[0])
	surface_mat.set_shader_parameter("scatter_color", tint[1])
	surface_mat.set_shader_parameter("surface_y", level_y)
	_build_surface(lv)
	if bool(o.get("caustics", true)) and not shell:
		_build_caustics(lv, tint[1])

## Is the level point `p` (on the floor plane) over this water?
func covers(p: Vector3, grow := 0.0) -> bool:
	var l := transform.affine_inverse() * p
	return absf(l.x) <= hx + grow and absf(l.z) <= hz + grow

func _build_surface(lv: Node) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var y := Vector3(0, level_y, 0)
	# the surface, in pieces of about a metre so it lies flat on a big pool's far side too
	var nx := maxi(1, ceili(hx * 2.0))
	var nz := maxi(1, ceili(hz * 2.0))
	for i in nx:
		for k in nz:
			var a := Vector3(lerpf(-hx, hx, float(i) / nx), level_y, lerpf(-hz, hz, float(k) / nz))
			var b := Vector3(lerpf(-hx, hx, float(i + 1) / nx), level_y, lerpf(-hz, hz, float(k + 1) / nz))
			_quad(st, a, Vector3(b.x, level_y, a.z), b, Vector3(a.x, level_y, b.z), Vector3.UP)
	# a side wherever an edge stands out in the open, not against a wall
	var corners := [Vector3(-hx, 0, -hz), Vector3(hx, 0, -hz), Vector3(hx, 0, hz), Vector3(-hx, 0, hz)]
	for i in 4:
		var a: Vector3 = corners[i]
		var b: Vector3 = corners[(i + 1) % 4]
		var out := Vector3(signf(a.x), 0, 0) if absf(a.x - b.x) < 0.001 else Vector3(0, 0, signf(a.z))
		var pieces := maxi(1, ceili(a.distance_to(b) / 0.5))
		for k in pieces:
			var p0 := a.lerp(b, float(k) / pieces)
			var p1 := a.lerp(b, float(k + 1) / pieces)
			if lv._block_at(lv.cell_of(transform * ((p0 + p1) * 0.5 + out * 0.3))): continue
			_quad(st, p0, p1, p1 + y, p0 + y, out)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = surface_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

## The ripples of light: a skin a hair in front of every wall face round and in the water (the grid's blocks,
## placed walls, pillars and columns), from the waterline up BAND metres (strong at the waterline, gone at the
## top), and under any ceiling close enough over it
func _build_caustics(lv: Node, tint: Color) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var count := 0
	var inv := transform.affine_inverse()
	var o0 := transform * Vector3(-hx, 0, -hz)
	var box := Rect2(Vector2(o0.x, o0.z), Vector2.ZERO)
	for c: Vector3 in [Vector3(hx, 0, -hz), Vector3(hx, 0, hz), Vector3(-hx, 0, hz)]:
		var w := transform * c
		box = box.expand(Vector2(w.x, w.z))
	var inside := func(p: Vector3) -> bool: return covers(p, 0.05)
	for f: Array in lv.wall_faces_near(inside, box):
		var a: Vector3 = f[0]
		var b: Vector3 = f[1]
		var n: Vector3 = f[2]
		var pieces := maxi(1, ceili(a.distance_to(b) / PIECE))
		for k in pieces:
			var p0 := a.lerp(b, float(k) / pieces)
			var p1 := a.lerp(b, float(k + 1) / pieces)
			if not inside.call((p0 + p1) * 0.5 + n * 0.2): continue
			var off := n * 0.012
			var top := minf(BAND, lv.ceiling_height(lv.cell_of((p0 + p1) * 0.5 + n * 0.3)) - level_y - 0.02)
			if top <= 0.05: continue
			var lo := Vector3(0, level_y, 0)
			var hi := Vector3(0, level_y + top, 0)
			var fade := clampf(top / BAND, 0.0, 1.0)
			_quad_c(st, inv * (p0 + off + lo), inv * (p1 + off + lo), inv * (p1 + off + hi), inv * (p0 + off + hi), inv.basis * n,
				[1.0, 1.0, 1.0 - fade, 1.0 - fade])
			count += 1
	# a ceiling the ripples reach: over each cell (in metre squares) whose middle is over the water
	for x in range(floori(box.position.x / CELL) - 1, ceili(box.end.x / CELL) + 2):
		for z in range(floori(box.position.y / CELL) - 1, ceili(box.end.y / CELL) + 2):
			var cc := Vector2i(x, z)
			if lv.walls.has(cc) or lv.open_above.has(cc): continue
			var ch: float = lv.ceiling_height(cc)
			if ch - level_y > CEIL_REACH or ch <= level_y: continue
			var strength := clampf(1.25 - (ch - level_y) / CEIL_REACH, 0.15, 1.0)
			for i in 5:
				for k in 5:
					var q0 := Vector3(x * CELL - CELL * 0.5 + i * 0.9, 0.0, z * CELL - CELL * 0.5 + k * 0.9)
					if not inside.call(q0 + Vector3(0.45, 0, 0.45)): continue
					var y := ch - 0.012
					var q := [q0, q0 + Vector3(0.9, 0, 0), q0 + Vector3(0.9, 0, 0.9), q0 + Vector3(0, 0, 0.9)]
					_quad_c(st, inv * (q[0] + Vector3(0, y, 0)), inv * (q[1] + Vector3(0, y, 0)), inv * (q[2] + Vector3(0, y, 0)),
						inv * (q[3] + Vector3(0, y, 0)), inv.basis * Vector3.DOWN, [strength, strength, strength, strength])
					count += 1
	if count == 0: return
	var mat := ShaderMaterial.new()
	mat.shader = _caustic_shader
	mat.set_shader_parameter("tint", Color(0.85, 1.0, 0.97).lerp(tint.lightened(0.6), 0.25))
	mat.render_priority = 1
	var mi := MeshInstance3D.new()
	mi.name = "Caustics"
	mi.mesh = st.commit()
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
	var order := [a, b, c, a, c, d]
	if (b - a).cross(c - a).dot(n) > 0.0:
		order = [a, c, b, a, d, c]
	for v: Vector3 in order:
		st.set_normal(n)
		st.add_vertex(v)

## A quad with a vertex colour's red per corner (a, b, c, d): how strongly each catches the ripples
func _quad_c(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, k: Array) -> void:
	var v := [a, b, c, d]
	var order := [0, 1, 2, 0, 2, 3]
	if (b - a).cross(c - a).dot(n) > 0.0:
		order = [0, 2, 1, 0, 3, 2]
	for i: int in order:
		st.set_normal(n)
		st.set_color(Color(float(k[i]), 0.0, 0.0))
		st.add_vertex(v[i])
