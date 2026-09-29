extends Node3D
## The T.S.R.A. field scanner as a 3D model, built in code from primitive meshes: a gunmetal
## handheld with orange rubber corners, a glowing radar screen, a strip of hazard tape for a
## label, a keypad, a ribbed grip and a stubby antenna with a red tip. Stands upright, screen
## facing +Z, about 16 cm tall. Made in _init so its size is known before it enters the tree;
## item_icon.gd renders the inventory icon from it (hud.gd passes this script's path as the
## scanner's model).

const TAPE_TEXTURE := "res://textures/items/hazard_tapes/hazardous_tapes.jpg"

const W := 0.09                  # body width, height, depth (m)
const H := 0.16
const D := 0.035
const FRONT := D * 0.5

const RADAR_SHADER := """
shader_type spatial;
render_mode unshaded;
// The scanner's screen: range rings, a cross, the sweep with its fading trail and two contacts
void fragment() {
	vec2 p = (UV - 0.5) * vec2(1.2, 1.0) * 2.0;
	float r = length(p);
	vec3 green = vec3(0.3, 1.0, 0.5);
	vec3 col = vec3(0.01, 0.06, 0.03);
	float px = fwidth(r) * 1.5;
	for (int i = 1; i <= 3; i++) {
		col += green * 0.35 * (1.0 - smoothstep(0.0, px, abs(r - float(i) * 0.3)));
	}
	col += green * 0.25 * (1.0 - smoothstep(0.0, px, min(abs(p.x), abs(p.y)))) * step(r, 0.9);
	float a = atan(p.y, p.x);
	float beam = 0.8;
	float behind = mod(beam - a, 6.2831853);
	col += green * 0.55 * pow(max(0.0, 1.0 - behind / 1.2), 2.0) * step(r, 0.9);
	col += green * (1.0 - smoothstep(0.0, px * 1.5, abs(behind))) * step(r, 0.9);
	col += vec3(0.8, 1.0, 0.85) * (1.0 - smoothstep(0.05, 0.08, length(p - vec2(0.35, 0.25))));
	col += vec3(1.0, 0.45, 0.2) * (1.0 - smoothstep(0.04, 0.07, length(p - vec2(-0.4, -0.3))));
	ALBEDO = col;
}
"""

static var _mats := {}

func _init() -> void:
	var body := _mat("body", Color(0.22, 0.23, 0.25), 0.55, 0.4)
	var dark := _mat("dark", Color(0.05, 0.05, 0.055), 0.2, 0.6)
	var rubber := _mat("rubber", Color(0.95, 0.45, 0.08), 0.0, 0.7)
	var grey := _mat("grey", Color(0.5, 0.51, 0.53), 0.7, 0.35)
	var red := _mat("red", Color(0.85, 0.12, 0.08), 0.0, 0.3, Color(0.5, 0.05, 0.02))
	var led := _mat("led", Color(0.3, 1.0, 0.5), 0.0, 0.3, Color(0.3, 1.0, 0.5))

	# body: the shell, with a slightly smaller face plate stood proud of it
	_box(Vector3(W, H, D), Vector3.ZERO, body)
	_box(Vector3(W - 0.012, H - 0.012, 0.002), Vector3(0, 0, FRONT + 0.001), _mat("face", Color(0.3, 0.31, 0.33), 0.5, 0.45))
	# rubber bumpers wrapped round the four corners
	for sx in [-1, 1]:
		for sy in [-1, 1]:
			_box(Vector3(0.022, 0.032, D + 0.008), Vector3(sx * (W * 0.5 - 0.008), sy * (H * 0.5 - 0.012), 0), rubber)
	# screen: black bezel, then the radar
	var sy_ := 0.03
	_box(Vector3(0.072, 0.062, 0.004), Vector3(0, sy_, FRONT + 0.003), dark)
	var screen := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(0.062, 0.052)
	screen.mesh = q
	screen.material_override = _radar()
	screen.position = Vector3(0, sy_, FRONT + 0.0052)
	add_child(screen)
	# hazard tape label under the screen (the same black and yellow tape as the roll)
	var label := MeshInstance3D.new()
	var lq := QuadMesh.new()
	lq.size = Vector2(0.011, 0.07)                 # the tape's length runs across the device
	label.mesh = lq
	label.material_override = _label_mat()
	label.rotation.z = PI * 0.5
	label.position = Vector3(0, -0.013, FRONT + 0.0022)
	add_child(label)
	# keypad: the red trigger, two grey keys, the status LED
	_cyl(0.0095, 0.004, Vector3(-0.02, -0.038, FRONT + 0.002), dark)
	_cyl(0.0075, 0.006, Vector3(-0.02, -0.038, FRONT + 0.004), red)
	for x in [0.008, 0.027]:
		_box(Vector3(0.014, 0.008, 0.005), Vector3(x, -0.038, FRONT + 0.003), grey)
	var bulb := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = 0.0028
	s.height = 0.0056
	bulb.mesh = s
	bulb.material_override = led
	bulb.position = Vector3(0.032, -0.024, FRONT + 0.002)
	add_child(bulb)
	# ribbed grip
	for i in 4:
		_box(Vector3(0.06, 0.0028, 0.003), Vector3(0, -0.053 - i * 0.0065, FRONT + 0.0025), dark)
	# antenna off the top left, red tip; a dial on the right side
	var ant := MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = 0.0028
	c.bottom_radius = 0.0045
	c.height = 0.055
	ant.mesh = c
	ant.material_override = dark
	ant.rotation.z = 0.18
	ant.position = Vector3(-0.028 - 0.005, H * 0.5 + 0.026, 0)
	add_child(ant)
	var tip := MeshInstance3D.new()
	var ts := SphereMesh.new()
	ts.radius = 0.0065
	ts.height = 0.013
	tip.mesh = ts
	tip.material_override = red
	tip.position = Vector3(-0.028 - 0.0105, H * 0.5 + 0.053, 0)
	add_child(tip)
	var dial := _cyl(0.008, 0.008, Vector3(W * 0.5 + 0.004, 0.045, 0), grey)
	dial.rotation = Vector3(0, 0, PI * 0.5)

func _box(size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	return mi

## A short cylinder facing +Z (a button), `depth` deep
func _cyl(radius: float, depth: float, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = radius
	c.bottom_radius = radius
	c.height = depth
	c.radial_segments = 24
	mi.mesh = c
	mi.material_override = mat
	mi.rotation.x = PI * 0.5
	mi.position = pos
	add_child(mi)
	return mi

static func _mat(key: String, col: Color, metal: float, rough: float, glow := Color.BLACK) -> StandardMaterial3D:
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = col
		m.metallic = metal
		m.roughness = rough
		if glow != Color.BLACK:
			m.emission_enabled = true
			m.emission = glow
		_mats[key] = m
	return _mats[key]

static func _radar() -> ShaderMaterial:
	if not _mats.has("radar"):
		var sh := Shader.new()
		sh.code = RADAR_SHADER
		var m := ShaderMaterial.new()
		m.shader = sh
		_mats["radar"] = m
	return _mats["radar"]

static func _label_mat() -> StandardMaterial3D:
	if not _mats.has("label"):
		var m := StandardMaterial3D.new()
		m.albedo_texture = load(TAPE_TEXTURE)
		m.uv1_scale = Vector3(1.0, 0.07 / (0.011 * 998.0 / 561.0), 1.0)   # chevrons at the tape's own size
		m.roughness = 0.2
		m.clearcoat_enabled = true
		m.clearcoat = 0.8
		m.texture_repeat = true
		_mats["label"] = m
	return _mats["label"]
