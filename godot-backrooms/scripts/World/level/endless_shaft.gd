extends Node3D
## The Endless Ceiling zone (level_data.gd `endless_ceiling`), and any Open ceiling with nothing above to look up
## into (`shaft_up`): a ceiling that is not there. Look up and the walls round the
## area go on climbing, storey after storey of this level's own wall, the bare slab between floors and a
## buzzing tube under every slab, more run down the higher it goes (damp, dead and failing tubes), sinking
## into the abyss's sickly haze. It is the abyss (pit_fall.gd) turned over, drawn
## with the same shader (pit_shaft.gdshader) and the same look, but only ever looked at: nothing falls up.
##
## Cheap: STOREYS copies of one storey of mesh, no real lights (the tubes' light on the walls is worked out in the
## shader), no shadows. The torch would otherwise light every wall of the shaft as far as it reaches, which
## reads as a lit box and not as endless, so the shader takes the walls' response to real light away
## from FADE_FROM metres over the ceiling, and the tubes' own light after it, to nothing at FADE_TO.

const PitFall := preload("res://scripts/World/level/pit_fall.gd")
const DIRS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

const STOREYS := 12                # drawn: past FADE_TO nothing shows, so the top of the last is never seen
const FADE_FROM := 7.0             # m over the ceiling
const FADE_TO := 95.0
const ROT_FROM := 6.0              # m over the ceiling: the damp and the dying tubes start...
const ROT_TO := 60.0               # ...and are at their worst
const HAZE_FROM := 5.0             # m over the ceiling: the haze starts
const HAZE_K := 0.04               # per metre: 95 % haze 75 m further up

var level: Node3D
var cells := {}                    # the cells it rises from
var seg_h := 9.0
var cell := 4.5
var wall_h := 5.4
var _haze := Color.BLACK           # what the top of the shaft dissolves into (pit_fall.gd SICK, by the level's look)

func setup(lvl: Node3D, from: Dictionary) -> void:
	level = lvl
	cells = from
	seg_h = lvl.STOREY_H
	cell = lvl.CELL
	wall_h = lvl.WALL_H
	_haze = PitFall.SICK.get(lvl.atmosphere(), PitFall.SICK.dim)
	var runs := _runs(cells)
	var mat := _material()
	# storey 0 starts at the ceiling: below it is the room, whose own walls stand there
	var first := _segment_mesh(runs, wall_h)
	var rest := _segment_mesh(runs, 0.0)
	for k in STOREYS:
		var mi := MeshInstance3D.new()
		mi.mesh = first if k == 0 else rest
		mi.material_override = mat
		mi.position = Vector3(0.0, k * seg_h, 0.0)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		add_child(mi)
	_add_cap(cells)

## The haze over the top, so the far end is never a hole to the sky
func _add_cap(cells: Dictionary) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var y := STOREYS * seg_h
	var h := cell * 0.5
	for c: Vector2i in cells:
		var x := c.x * cell
		var z := c.y * cell
		_quad(st, [Vector3(x - h, y, z - h), Vector3(x + h, y, z - h), Vector3(x + h, y, z + h), Vector3(x - h, y, z + h)],
				Vector3.DOWN, Color.WHITE, [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	var black := StandardMaterial3D.new()
	black.albedo_color = _haze
	black.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	black.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = black
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

## The walls round a set of cells, as straight runs: {from, to (at y 0), n (facing into the shaft), cells}
func _runs(cells: Dictionary) -> Array:
	var lines := {}
	for c: Vector2i in cells:
		for d: Vector2i in DIRS:
			if cells.has(c + d): continue
			var key := Vector3i(0, d.x, c.x) if d.x != 0 else Vector3i(1, d.y, c.y)
			if not lines.has(key): lines[key] = []
			lines[key].append(c.y if d.x != 0 else c.x)
	var out: Array = []
	for key: Vector3i in lines:
		var list: Array = lines[key]
		list.sort()
		var start: int = list[0]
		var prev: int = start
		for i in range(1, list.size() + 1):
			if i < list.size() and list[i] == prev + 1:
				prev = list[i]
				continue
			var plane := (key.z + key.y * 0.5) * cell
			var a0 := (start - 0.5) * cell
			var b0 := (prev + 0.5) * cell
			if key.x == 0:
				out.append({"from": Vector3(plane, 0, a0), "to": Vector3(plane, 0, b0), "n": Vector3(-key.y, 0, 0), "cells": prev - start + 1})
			else:
				out.append({"from": Vector3(a0, 0, plane), "to": Vector3(b0, 0, plane), "n": Vector3(0, 0, -key.y), "cells": prev - start + 1})
			if i < list.size():
				start = list[i]
				prev = start
	return out

## One storey of shaft from height `y0` to seg_h: a quad a run of wall (the shader paints wall and slab on it)
## and a tube on every cell's width of it (left out where the storey starts above it). UV: metres along
## the run, and its length (for the corner shading).
func _segment_mesh(runs: Array, y0: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lo_y := Vector3(0.0, y0, 0.0)
	var hi_y := Vector3(0.0, seg_h, 0.0)
	for r: Dictionary in runs:
		var a: Vector3 = r.from
		var b: Vector3 = r.to
		var n: Vector3 = r.n
		var ln := a.distance_to(b)
		var dir0 := (b - a) / ln
		if y0 > 0.0:                    # the storey that starts at the ceiling: no doorways, they would be inside the room
			_quad(st, [a + lo_y, b + lo_y, b + hi_y, a + hi_y], n, Color.WHITE, [Vector2(0, ln), Vector2(ln, ln), Vector2(ln, ln), Vector2(0, ln)])
		else:                           # doorways onto fake corridors, as in the abyss (pit_fall.gd)
			PitFall._wall(st, a, dir0, ln, n, int(r.cells), cell, seg_h)
		if PitFall.TUBE_Y - PitFall.TUBE_THICK < y0: continue
		var dir := (b - a) / ln
		for i in int(r.cells):
			var mid := a + dir * (cell * (i + 0.5)) + Vector3(0.0, PitFall.TUBE_Y, 0.0)
			var s := dir * PitFall.TUBE_HALF
			var lo := Vector3(0.0, -PitFall.TUBE_THICK, 0.0)
			var hi := Vector3(0.0, PitFall.TUBE_THICK, 0.0)
			var back := n * 0.02
			var front := n * PitFall.TUBE_OUT
			var glass := Color(1, 1, 1, 0)
			var housing := Color(0, 0, 0, 0)
			var none := [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]
			_quad(st, [mid - s + front + lo, mid + s + front + lo, mid + s + front + hi, mid - s + front + hi], n, glass, none)
			_quad(st, [mid - s + back + lo, mid + s + back + lo, mid + s + front + lo, mid - s + front + lo], Vector3.DOWN, glass, none)
			_quad(st, [mid - s + back + hi, mid + s + back + hi, mid + s + front + hi, mid - s + front + hi], Vector3.UP, housing, none)
			_quad(st, [mid - s + back + lo, mid - s + front + lo, mid - s + front + hi, mid - s + back + hi], -dir, housing, none)
			_quad(st, [mid + s + back + lo, mid + s + front + lo, mid + s + front + hi, mid + s + back + hi], dir, housing, none)
	return st.commit()

## A quad facing `n`, wound clockwise seen from that side (Godot's front face)
func _quad(st: SurfaceTool, v: Array, n: Vector3, col: Color, uv: Array) -> void:
	var order := [0, 1, 2, 0, 2, 3]
	var v0: Vector3 = v[0]
	var v1: Vector3 = v[1]
	var v2: Vector3 = v[2]
	if (v1 - v0).cross(v2 - v0).dot(n) > 0.0: order = [0, 2, 1, 0, 3, 2]
	for k: int in order:
		st.set_normal(n)
		st.set_color(col)
		st.set_uv(uv[k])
		st.add_vertex(v[k])

## The level's wall as the walls round the zone wear it (a wall painted with another material there wins)
func _wall_source() -> StandardMaterial3D:
	var count := {}
	var paint: Dictionary = level.painted("wall")
	for c: Vector2i in cells:
		for d: Vector2i in DIRS:
			if paint.has(c + d): count[paint[c + d]] = int(count.get(paint[c + d], 0)) + 1
	var best := ""
	for id: String in count:
		if best == "" or count[id] > count[best]: best = id
	if best != "": return level._painted_mat(best)
	return level.wall_mat

func _material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = PitFall.ShaftShader
	var src := _wall_source()
	if src != null and src.albedo_texture != null:
		var sc := src.uv1_scale
		var flip := sc.y < 0.0            # the generated wallpaper: one texture a wall height, top at the top
		m.set_shader_parameter("wall_tex", src.albedo_texture)
		m.set_shader_parameter("wall_tint", src.albedo_color)
		m.set_shader_parameter("wall_scale", Vector2(absf(sc.x), 1.0 if flip else maxf(1.0, roundf(wall_h * absf(sc.y)))))
		m.set_shader_parameter("wall_flip", 1.0 if flip else 0.0)
	var fm: StandardMaterial3D = level._pbr_or("floor") if level._has_pbr("floor") else null
	if fm != null and fm.albedo_texture != null:
		m.set_shader_parameter("floor_tex", fm.albedo_texture)
		m.set_shader_parameter("floor_tint", fm.albedo_color)
		m.set_shader_parameter("floor_scale", Vector2(absf(fm.uv1_scale.x), absf(fm.uv1_scale.y)))
	else:
		m.set_shader_parameter("floor_tex", load("res://textures/l0_carpet_color.webp"))
	m.set_shader_parameter("slab_tex", load("res://textures/concrete_color.jpg"))
	m.set_shader_parameter("seg_h", seg_h)
	m.set_shader_parameter("band_h", wall_h)
	m.set_shader_parameter("tube_y", PitFall.TUBE_Y)
	m.set_shader_parameter("tube_half", PitFall.TUBE_HALF)
	m.set_shader_parameter("cell", cell)
	m.set_shader_parameter("shaft_w", cell)
	m.set_shader_parameter("fade_from", wall_h + FADE_FROM)
	m.set_shader_parameter("fade_to", wall_h + FADE_TO)
	var look: String = level.atmosphere()
	var tube: Color = level.LIGHT_COLOR
	if look == "liminal": tube = level.ATMOSPHERES.liminal.light
	elif look == "classic": tube = Color(1.0, 0.99, 0.96)
	m.set_shader_parameter("tube_color", tube)
	var r := RandomNumberGenerator.new()
	r.seed = hash(str(level.level_meta.get("id", "")) + ":up:" + str(level.floor_no))
	var rows := PackedFloat32Array()
	rows.resize(16)
	for k in 16:
		var v := r.randf()
		rows[k] = 0.0 if v < 0.2 else (2.0 if v < 0.42 else 1.0)       # dead, failing, steady: more of it failing than in the abyss
	rows[0] = 1.0                       # (the rows over the ceiling are lit: it is what you see of the shaft from below)
	rows[1] = 1.0
	# the abyss's own light (the shader's defaults), dirtier walls, and the higher the more run down
	m.set_shader_parameter("grime", 0.6)
	m.set_shader_parameter("rot_from", wall_h + ROT_FROM)
	m.set_shader_parameter("rot_to", wall_h + ROT_TO)
	# it sinks into the abyss's sickly haze, not into black
	m.set_shader_parameter("haze_color", _haze)
	m.set_shader_parameter("haze_k", HAZE_K)
	m.set_shader_parameter("haze_y", wall_h + HAZE_FROM)
	m.set_shader_parameter("rows", rows)
	m.set_shader_parameter("period", PitFall.ROW_PERIOD)
	return m
