shader_type spatial;
// Drop ceiling with square light panels baked into its texture (textures/pbr/BRC_A). One quad per level
// cell, drawn from a MultiMesh (level_lighting.gd, _build_panel_ceiling). Each cell's instance colour is
// that cell's panel glow: level_lighting.gd sets it per fixture, so burnt cells, flicker, power cuts and
// event tints reach the panels exactly as they reach the real lights under them.
render_mode cull_back;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D orm_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D emission_tex : source_color, hint_default_black, filter_linear_mipmap, repeat_enable;
uniform vec3 albedo_tint : source_color = vec3(0.96, 0.9, 0.7);   // the reference ceilings are cream-yellow, not grey
uniform float normal_depth = 1.0;
uniform float metal_amt = 0.35;         // the ORM marks the T-bar grid fully metallic; that reads black with no reflections around
uniform float ao_light_affect = 0.6;
uniform float specular = 0.4;
uniform float dead_panel = 0.55;        // how grey an unlit panel looks (its diffuse is a pale blue diffuser)

void fragment() {
	vec3 orm = texture(orm_tex, UV).rgb;
	vec3 emit = texture(emission_tex, UV).rgb;
	float panel = clamp(dot(emit, vec3(0.333)) * 1.4, 0.0, 1.0);
	vec3 alb = texture(albedo_tex, UV).rgb * albedo_tint;
	float glow = max(max(COLOR.r, COLOR.g), COLOR.b);
	ALBEDO = mix(alb, alb * dead_panel, panel * (1.0 - clamp(glow, 0.0, 1.0)));
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	NORMAL_MAP_DEPTH = normal_depth;
	AO = orm.r;
	AO_LIGHT_AFFECT = ao_light_affect;
	ROUGHNESS = orm.g;
	METALLIC = orm.b * metal_amt;
	SPECULAR = specular;
	EMISSION = emit * COLOR.rgb;
}
