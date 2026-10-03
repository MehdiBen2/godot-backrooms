extends GPUParticles3D
## Dust in the light. Every room has it hanging in the air, and you only see it where a lamp shines through
## it: a slow drift of specks in the cone under each tube, brightest looking toward the light (dust throws
## light forward). One emitter rides along with the player and fills the air round them; each speck is lit by
## the nearest working tubes (level_light_pool.gd hands them over every frame, set_lamps), so it shows in their
## cones, flickers with them and is gone in the dark. Off on the Low preset; how much of it by Gfx.particle_scale().

const LAMPS := 6                    # the tubes that light it, nearest first
const REACH := 7.0                  # metres round the player it fills
const SPECK := 0.004                # metres: a mote as the camera sees it (drawn never under ~2.5 pixels)

var _mat: ShaderMaterial
var _lamps := PackedVector4Array()

func _init() -> void:
	name = "DustMotes"
	local_coords = false                       # the air stays where it is as the player walks through it
	lifetime = 12.0
	preprocess = 12.0
	randomness = 0.5
	amount = maxi(150, int(1400 * Gfx.particle_scale()))     # (about one a cubic metre: a lamp's glare shows a few)
	visibility_aabb = AABB(Vector3(-REACH - 2.0, -4.0, -REACH - 2.0), Vector3(REACH * 2.0 + 4.0, 10.0, REACH * 2.0 + 4.0))
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(REACH, 2.6, REACH)
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 180.0
	pm.initial_velocity_min = 0.004
	pm.initial_velocity_max = 0.02
	pm.gravity = Vector3(0.0, -0.003, 0.0)    # it settles, very slowly
	# the room's air is never still: slow eddies carry it about
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.8
	pm.turbulence_noise_scale = 3.5
	pm.turbulence_noise_speed = Vector3(0.02, 0.01, 0.02)
	pm.turbulence_influence_min = 0.01
	pm.turbulence_influence_max = 0.04
	process_material = pm
	_mat = ShaderMaterial.new()
	_mat.shader = _shader()
	_mat.set_shader_parameter("cone_cos", cos(deg_to_rad(80.0)))       # level_fixtures.gd SPOT_ANGLE
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	quad.material = _mat
	draw_pass_1 = quad
	_lamps.resize(LAMPS)

## The tubes lighting the air now: [position, strength] pairs, nearest first (at most LAMPS); `color` their white
func set_lamps(list: Array, color: Color) -> void:
	for i in LAMPS:
		if i < list.size():
			var p: Vector3 = list[i][0]
			_lamps[i] = Vector4(p.x, p.y, p.z, float(list[i][1]))
		else:
			_lamps[i] = Vector4(0.0, -1000.0, 0.0, 0.0)
	_mat.set_shader_parameter("lamps", _lamps)
	_mat.set_shader_parameter("lamp_color", color)

## The player's torch (a SpotLight3D, or null / hidden when off): its beam shows the dust best of all
func set_torch(torch: SpotLight3D) -> void:
	var on := torch != null and torch.is_visible_in_tree() and torch.light_energy > 0.01
	_mat.set_shader_parameter("torch_energy", torch.light_energy if on else 0.0)
	if not on: return
	_mat.set_shader_parameter("torch_pos", torch.global_position)
	_mat.set_shader_parameter("torch_dir", -torch.global_basis.z.normalized())
	_mat.set_shader_parameter("torch_cos", cos(deg_to_rad(torch.spot_angle)))
	_mat.set_shader_parameter("torch_color", torch.light_color)

static var _code: Shader
static func _shader() -> Shader:
	if _code != null: return _code
	_code = Shader.new()
	_code.code = """shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
uniform vec4 lamps[6];                  // xyz: a tube's light, w: how much it puts out now
uniform vec3 lamp_color : source_color = vec3(1.0, 0.93, 0.78);
uniform float cone_cos = 0.1736;
uniform float brightness = 0.8;
uniform vec3 dust_tint : source_color = vec3(0.92, 0.86, 0.74);   // the motes' own colour: lint and skin, not white
uniform float speck = 0.004;
// the player's torch: its beam lights the dust round you most of all
uniform vec3 torch_pos;
uniform vec3 torch_dir = vec3(0.0, 0.0, -1.0);
uniform float torch_cos = 0.8;
uniform float torch_energy = 0.0;
uniform vec3 torch_color : source_color = vec3(1.0);
varying vec3 glow;
void vertex() {
	vec3 at = MODEL_MATRIX[3].xyz;
	vec3 eye = at - CAMERA_POSITION_WORLD;
	float dist = max(length(eye), 0.01);
	// never drawn under ~2.5 pixels (a smaller speck shimmers, and TAA smears it away), and dimmed a little as
	// it is drawn bigger than it is, so the far ones thin out instead of turning into a snowstorm
	float px = 2.0 * dist / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	float size = max(speck, px * 2.5);
	float g = 0.0;
	for (int i = 0; i < 6; i++) {
		vec3 l = lamps[i].xyz - at;
		float d = max(length(l), 0.05);
		// only in the strong core of the light under a tube (its outer cone is too dim to show a mote)...
		float core = smoothstep(0.55, 0.85, l.y / d);
		// ...and dust throws light forward: it shows where it is between you and the lamp, against the glare,
		// and is next to invisible lit from the side or behind you
		float fwd = 0.08 + 2.0 * pow(max(dot(eye / dist, l / d), 0.0), 8.0);
		g += lamps[i].w * core * fwd / (1.0 + d * d * 0.15);
	}
	vec3 c = lamp_color * g;
	if (torch_energy > 0.0) {
		vec3 tl = at - torch_pos;
		float td = max(length(tl), 0.05);
		float beam = smoothstep(torch_cos, mix(torch_cos, 1.0, 0.35), dot(tl / td, torch_dir));
		// (a torch's energy runs about 6.5 where a tube's here is about 1, and its light comes from behind you:
		// dust scatters little back, so it gets a small share)
		c += torch_color * torch_energy * 0.06 * beam / (1.0 + td * td * 0.25);
	}
	glow = c * pow(speck / size, 0.8) * smoothstep(0.25, 0.7, dist) * (1.0 - smoothstep(5.5, 7.0, dist));
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	VERTEX *= size;
}
void fragment() {
	vec2 q = UV * 2.0 - 1.0;
	float disc = max(1.0 - dot(q, q), 0.0);
	ALBEDO = glow * dust_tint * brightness * disc * disc;
}
"""
	return _code
