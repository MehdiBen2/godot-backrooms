extends Node3D
## A window (the level editor's "window": object_types.json shape "window", mounted on a wall), built by
## level_geometry.gd _build_window. In its own frame its back is on the wall face and its arrow (+x) points into
## the room; z runs along the wall, y up from the floor. It is a window onto a bright outside that isn't there:
##  - the glass shows a sky drawn from the way you look through it (window_sky.gdshader), so it is as far off as
##    a real one and the sun stands still in it;
##  - a white frame and glazing bars stand proud of the wall, with a sill;
##  - the sun comes in as sunlight does: a light far back behind the window (its rays all but parallel, nothing
##    of the wall in its way), its projector the window's own outline and bars seen from the sun (_mask), edges
##    softened as the sun's own width softens them. So the patch on the floor is the window's shape drawn out
##    along the sun's angle, bars and all, as a real one is;
##  - that patch lights the room back up a little (a soft bounce off it), and daylight spills in round the glass;
##  - where the level's air is hazy (volumetric fog), the sunlight shows as shafts in it.
## Styles ("frame"): pane (lights in a row, a transom across), porthole (round, Width its diameter), arched
## (lights under a round head) and panorama (a wall of glass from the sill nearly to the ceiling).

const CELL := 4.5
const FRAME_W := 0.1               # m: the frame's face, round the glass
const FRAME_D := 0.2               # m: how far it stands out from the wall: the glass sits back in it, in a reveal
const BAR_W := 0.05                # m: a glazing bar
const BAR_D := 0.06
const SUN_GAIN := 0.42             # "sun" 8 throws about one and a half times a ceiling lamp's light (level_fixtures.gd LIGHT_ENERGY)
const SKY := {
	# zenith, horizon, ground, sun (in the sky), light (thrown in), sky exposure
	"noon": [Color(0.30, 0.54, 0.93), Color(0.86, 0.92, 0.98), Color(0.62, 0.70, 0.74), Color(1.0, 0.97, 0.9), Color(1.0, 0.96, 0.9), 2.2],
	"golden": [Color(0.36, 0.46, 0.76), Color(1.0, 0.83, 0.62), Color(0.62, 0.55, 0.5), Color(1.0, 0.76, 0.46), Color(1.0, 0.8, 0.56), 2.0],
	"overcast": [Color(0.8, 0.82, 0.85), Color(0.93, 0.94, 0.95), Color(0.7, 0.72, 0.74), Color(0.25, 0.25, 0.25), Color(0.9, 0.93, 0.97), 1.8],
}

static var _sky_shader: Shader
static var _masks := {}            # key -> ImageTexture: the sun's projector per window shape
static var _frame_mat: StandardMaterial3D

var sun: SpotLight3D
var fill: SpotLight3D
var bounce: OmniLight3D
var _solid: Callable

const SUN_BACK := 16.0             # m behind the glass the sun light stands: far enough that its rays run (nearly) parallel
const SUN_MAX := 0.75              # the most a window's sun may be (a ceiling lamp's pool is about 1)
const SUN_SOFT := 0.012            # how far the sun's width spreads a shadow's edge, per metre from what casts it

## `ceiling`: the ceiling height of the room it looks into (a panorama runs up to just under it). `solid`: is a
## point (in the level) inside a wall block (no bounce light is put in a wall)
func build(o: Dictionary, ceiling: float, shell: bool, solid := Callable()) -> void:
	_solid = solid
	name = "Window_%d" % get_index()
	var style := str(o.get("frame", "pane"))
	var w := float(o.scale) * CELL
	var sill := maxf(0.0, float(o.get("elev", 0.9)))
	var h := float(o.get("height", 2.2))
	if h <= 0.0: h = 2.2
	if style == "panorama":
		sill = minf(sill, 0.6)
		h = maxf(0.5, ceiling - sill - 0.3)
	elif style == "porthole":
		var d := minf(w, h)
		w = d
		h = d
	h = minf(h, maxf(0.3, ceiling - sill - 0.05))
	var panes := clampi(roundi(float(o.get("panes", 3.0))), 1, 12)
	var outline := _outline(style, w, h, sill)
	_build_glass(outline, o)
	_build_frame(style, outline, w, h, sill, panes)
	if shell: return
	_build_light(o, style, w, h, sill, panes)

## The glass's outline in the wall's plane, round the way: [z, y] points
func _outline(style: String, w: float, h: float, sill: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	match style:
		"porthole":
			var r := w * 0.5
			for i in 40:
				var a := TAU * i / 40.0
				out.append(Vector2(cos(a) * r, sill + r + sin(a) * r))
		"arched":
			var r := w * 0.5
			var spring := sill + maxf(h - r, 0.0)
			out.append(Vector2(-r, sill))
			out.append(Vector2(r, sill))
			for i in 25:
				var a := PI * i / 24.0
				out.append(Vector2(cos(a) * r, spring + sin(a) * r))
		_:
			out.append_array([Vector2(-w * 0.5, sill), Vector2(w * 0.5, sill), Vector2(w * 0.5, sill + h), Vector2(-w * 0.5, sill + h)])
	return out

func _build_glass(outline: PackedVector2Array, o: Dictionary) -> void:
	if _sky_shader == null: _sky_shader = load("res://shaders/window_sky.gdshader")
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mid := Vector2.ZERO
	for p in outline: mid += p
	mid /= outline.size()
	for i in outline.size():
		var a := outline[i]
		var b := outline[(i + 1) % outline.size()]
		_tri(st, Vector3(0.004, mid.y, mid.x), Vector3(0.004, a.y, a.x), Vector3(0.004, b.y, b.x), Vector3.RIGHT)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var m := ShaderMaterial.new()
	m.shader = _sky_shader
	var sky: Array = SKY.get(str(o.get("sky", "noon")), SKY.noon)
	m.set_shader_parameter("zenith", sky[0])
	m.set_shader_parameter("horizon", sky[1])
	m.set_shader_parameter("ground", sky[2])
	m.set_shader_parameter("sun_color", sky[3])
	m.set_shader_parameter("exposure", sky[5])
	m.set_shader_parameter("sun_dir", -_sun_dir_world(o))
	m.set_shader_parameter("clouds", 0.6 if str(o.get("sky", "noon")) == "overcast" else 0.2)
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

## Which way the sunlight travels, in the window's frame: into the room and down at the sun's angle
func _sun_dir_local(o: Dictionary) -> Vector3:
	var p := deg_to_rad(clampf(float(o.get("sun_angle", 35.0)), 5.0, 85.0))
	return Vector3(cos(p), -sin(p), 0.0)

func _sun_dir_world(o: Dictionary) -> Vector3:
	return (transform.basis * _sun_dir_local(o)).normalized()      # (the level and its look-only copies are never turned)

func _build_frame(style: String, outline: PackedVector2Array, w: float, h: float, sill: float, panes: int) -> void:
	if _frame_mat == null:
		_frame_mat = StandardMaterial3D.new()        # white enamelled steel, as the pool rooms' windows have
		_frame_mat.albedo_color = Color(0.86, 0.86, 0.84)       # (old gloss paint, gone a little matt)
		_frame_mat.roughness = 0.55
		_frame_mat.metallic_specular = 0.35
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var fw := FRAME_W * (1.6 if style == "porthole" else 1.0)
	var fd := FRAME_D * (1.6 if style == "porthole" else 1.0)
	# the frame: a band round the outline, its face out at fd, its reveal back to the glass and its outer edge to the wall
	var n := outline.size()
	var mid := Vector2.ZERO
	for p in outline: mid += p
	mid /= n
	var outer := PackedVector2Array()
	for i in n:
		var prev := outline[(i - 1 + n) % n]
		var cur := outline[i]
		var nxt := outline[(i + 1) % n]
		var e0 := (cur - prev).normalized()
		var e1 := (nxt - cur).normalized()
		var n0 := Vector2(e0.y, -e0.x)
		var n1 := Vector2(e1.y, -e1.x)
		if n0.dot(cur - mid) < 0.0:
			n0 = -n0
			n1 = -n1
		var m := (n0 + n1).normalized()
		outer.append(cur + m * fw / maxf(m.dot(n1), 0.35))
	var v3 := func(p: Vector2, x: float) -> Vector3: return Vector3(x, p.y, p.x)
	for i in n:
		var j := (i + 1) % n
		var face := Vector3.RIGHT
		_quad(st, v3.call(outline[i], fd), v3.call(outline[j], fd), v3.call(outer[j], fd), v3.call(outer[i], fd), face)
		var inward := Vector3(0.0, mid.y - (outline[i].y + outline[j].y) * 0.5, mid.x - (outline[i].x + outline[j].x) * 0.5).normalized()
		_quad(st, v3.call(outline[i], 0.0), v3.call(outline[j], 0.0), v3.call(outline[j], fd), v3.call(outline[i], fd), inward)
		_quad(st, v3.call(outer[i], 0.0), v3.call(outer[j], 0.0), v3.call(outer[j], fd), v3.call(outer[i], fd), -inward)
	# glazing bars, and a transom across a tall pane window
	if style != "porthole":
		var top_at := func(z: float) -> float:
			if style == "arched":
				var r := w * 0.5
				return sill + maxf(h - r, 0.0) + sqrt(maxf(r * r - z * z, 0.0))
			return sill + h
		for k in range(1, panes):
			var z := -w * 0.5 + w * k / panes
			var top: float = top_at.call(z)
			_box(st, Vector3(BAR_D * 0.5, (sill + top) * 0.5, z), Vector3(BAR_D, top - sill, BAR_W))
		if style == "pane" and h > 1.3:
			var y := sill + h * 0.64
			_box(st, Vector3(BAR_D * 0.5, y, 0.0), Vector3(BAR_D, BAR_W, w))
		elif style == "arched":
			_box(st, Vector3(BAR_D * 0.5, sill + maxf(h - w * 0.5, 0.0), 0.0), Vector3(BAR_D, BAR_W, w))
		# the sill board under it
		_box(st, Vector3(0.11, sill - 0.025, 0.0), Vector3(0.22, 0.05, w + fw * 2.0 + 0.1))
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _frame_mat
	add_child(mi)

func _build_light(o: Dictionary, style: String, w: float, h: float, sill: float, panes: int) -> void:
	var sky: Array = SKY.get(str(o.get("sky", "noon")), SKY.noon)
	var power := maxf(float(o.get("sun", 8.0)), 0.0)
	if power <= 0.0: return
	var overcast := str(o.get("sky", "noon")) == "overcast"
	var d := _sun_dir_local(o)
	var mid := Vector3(0.0, sill + h * 0.5, 0.0)
	var pitch := deg_to_rad(clampf(float(o.get("sun_angle", 35.0)), 5.0, 85.0))
	# the window as the sun sees it: as wide, its height foreshortened by the sun's angle; the cone is fitted round it
	var side := maxf(w, h * cos(pitch)) * 1.25
	var reach := mid.y / maxf(-d.y, 0.1)                 # from the glass down to the floor, along the sun's way
	var size_k := clampf(w * h / 2.5, 0.4, 3.0)
	if not overcast:
		sun = SpotLight3D.new()
		sun.name = "Sun"
		sun.position = mid - d * SUN_BACK
		sun.basis = Basis.looking_at(d, Vector3.UP)
		sun.light_color = sky[4]
		# a patch of sun a little brighter than the lamps' pools, never far past it: any more and the camera's bloom
		# and lens dirt smear it into a glowing blob (the room round it is dim, and the exposure follows the room)
		sun.light_energy = minf(power * SUN_GAIN * 0.16, SUN_MAX)
		sun.spot_range = SUN_BACK + reach * 1.8 + 6.0
		sun.spot_attenuation = 0.0                       # sunlight doesn't fade across a room
		sun.spot_angle = clampf(rad_to_deg(atan(side * 0.5 / SUN_BACK)), 0.5, 60.0)
		sun.spot_angle_attenuation = 0.01                # (its edge is the projector's, softened like the sun's)
		sun.light_specular = 0.08
		sun.light_volumetric_fog_energy = 1.2
		sun.shadow_enabled = false                       # (the wall it shines through would stop it)
		sun.light_projector = _mask(style, w, h, panes, cos(pitch), side, reach, bool(o.get("shadows", true)))
		sun.distance_fade_enabled = true
		sun.distance_fade_begin = 50.0
		sun.distance_fade_length = 12.0
		add_child(sun)
		# the patch on the floor lights the room back up: a soft glow off it, in the sun's colour, with no glint
		var patch := mid + d * reach + Vector3(0.0, 0.6, 0.0)
		var free := not _solid.is_valid() or not bool(_solid.call(transform * patch))
		if free and reach < 12.0:
			bounce = OmniLight3D.new()
			bounce.name = "Bounce"
			bounce.position = patch
			bounce.light_color = (sky[4] as Color).lerp(Color(0.95, 0.95, 0.92), 0.3)
			bounce.light_energy = minf(power * SUN_GAIN * 0.025 * size_k, 0.15)
			bounce.omni_range = 4.0 + maxf(w, h) * 1.6
			bounce.omni_attenuation = 1.6
			bounce.light_specular = 0.0
			bounce.shadow_enabled = false
			bounce.distance_fade_enabled = true
			bounce.distance_fade_begin = 40.0
			bounce.distance_fade_length = 10.0
			add_child(bounce)
	# daylight in round the glass: a broad soft wash from the window into the room (facing away from the wall, so
	# it never makes a hot spot on the tiles beside the window)
	fill = SpotLight3D.new()
	fill.name = "Daylight"
	fill.position = mid + Vector3(0.05, 0.0, 0.0)
	fill.basis = Basis.looking_at(Vector3(1.0, -0.35, 0.0).normalized(), Vector3.UP)
	fill.light_color = (sky[1] as Color).lerp(sky[4], 0.4)
	fill.light_energy = minf(power * SUN_GAIN * (0.08 if overcast else 0.03) * size_k, 0.25)
	fill.spot_range = 6.0 + maxf(w, h) * 2.0
	fill.spot_angle = 80.0
	fill.spot_angle_attenuation = 1.6
	fill.spot_attenuation = 1.3
	fill.light_specular = 0.0
	fill.shadow_enabled = false
	fill.distance_fade_enabled = true
	fill.distance_fade_begin = 40.0
	fill.distance_fade_length = 10.0
	add_child(fill)

## The window as the sun sees it, for its light's projector: white glass, black frame and bars, square (`side`
## metres across: the cone's width at the glass), its height squashed by `squash` (the sun's angle foreshortens
## it). Blurred by what the sun's width does to an edge over `reach` metres, so the patch is soft-edged like a
## real one. `bars`: the glazing bars throw their shadows too. Made once per shape.
func _mask(style: String, w: float, h: float, panes: int, squash: float, side: float, reach: float, bars: bool) -> ImageTexture:
	var key := "%s|%.2f|%.2f|%d|%.2f|%.2f|%s" % [style, w, h, panes, squash, reach, bars]
	if _masks.has(key): return _masks[key]
	const N := 160
	var img := Image.create(N, N, false, Image.FORMAT_L8)
	var bar := BAR_W * 0.5 + 0.025          # (a bar's shadow, with the frame's depth round it, is wider than the bar)
	for py in N:
		for px in N:
			var z := ((float(px) + 0.5) / N - 0.5) * side
			var y := h * 0.5 - ((float(py) + 0.5) / N - 0.5) * side / maxf(squash, 0.1)    # up the window: up the texture
			var inside := false
			match style:
				"porthole":
					inside = Vector2(z, y - h * 0.5).length() < w * 0.5 - FRAME_W * 0.3
				"arched":
					var r := w * 0.5
					var spring := maxf(h - r, 0.0)
					inside = absf(z) < r and y > 0.0 and (y < spring or Vector2(z, y - spring).length() < r)
				_:
					inside = absf(z) < w * 0.5 and y > 0.0 and y < h
			if inside and bars and style != "porthole":
				for k in range(1, panes):
					if absf(z - (-w * 0.5 + w * k / panes)) < bar: inside = false
				if style == "pane" and h > 1.3 and absf(y - h * 0.64) < bar: inside = false
				if style == "arched" and absf(y - maxf(h - w * 0.5, 0.0)) < bar: inside = false
			img.set_pixel(px, py, Color.WHITE if inside else Color.BLACK)
	# the sun's half degree: an edge spreads by reach * SUN_SOFT on the floor
	var blur := clampi(roundi(reach * SUN_SOFT / side * N * 0.5), 1, 4)
	_box_blur(img, blur)
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_masks[key] = tex
	return tex

static func _box_blur(img: Image, r: int) -> void:
	var n := img.get_width()
	var src := img.get_data()
	var tmp := PackedFloat32Array()
	tmp.resize(n * n)
	for y in n:                          # across
		var acc := 0.0
		for x in range(-r, n + r + 1):
			if x + r < n and x + r >= 0: acc += src[y * n + x + r]
			if x - r - 1 >= 0 and x - r - 1 < n: acc -= src[y * n + x - r - 1]
			if x >= 0 and x < n: tmp[y * n + x] = acc / (2 * r + 1)
	var out := PackedByteArray()
	out.resize(n * n)
	for x in n:                          # and down
		var acc := 0.0
		for y in range(-r, n + r + 1):
			if y + r < n and y + r >= 0: acc += tmp[(y + r) * n + x]
			if y - r - 1 >= 0 and y - r - 1 < n: acc -= tmp[(y - r - 1) * n + x]
			if y >= 0 and y < n: out[y * n + x] = clampi(roundi(acc / (2 * r + 1)), 0, 255)
	img.set_data(n, n, false, Image.FORMAT_L8, out)

func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, n: Vector3) -> void:
	var order := [a, b, c]
	if (b - a).cross(c - a).dot(n) > 0.0:
		order = [a, c, b]
	for v: Vector3 in order:
		st.set_normal(n)
		st.add_vertex(v)

func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
	_tri(st, a, b, c, n)
	_tri(st, a, c, d, n)

func _box(st: SurfaceTool, at: Vector3, size: Vector3) -> void:
	var h := size * 0.5
	for axis in 3:
		var u := (axis + 1) % 3
		var v := (axis + 2) % 3
		for sgn: float in [-1.0, 1.0]:
			var n := Vector3.ZERO
			n[axis] = sgn
			var q: Array[Vector3] = []
			for k: Array in [[-1.0, -1.0], [1.0, -1.0], [1.0, 1.0], [-1.0, 1.0]]:
				var p := Vector3.ZERO
				p[axis] = sgn * h[axis]
				p[u] = k[0] * h[u]
				p[v] = k[1] * h[v]
				q.append(at + p)
			_quad(st, q[0], q[1], q[2], q[3], n)
