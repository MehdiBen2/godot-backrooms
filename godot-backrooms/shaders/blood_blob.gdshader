// The flying blood blob (death_fx.gd): a sphere whose vertices bob around the surface so it wobbles
// like a loose mass of blood.
shader_type spatial;
render_mode specular_schlick_ggx;
uniform float seed = 0.0;
void vertex() {
	float t = TIME * 10.0 + seed * 6.0;
	float k = sin(VERTEX.x * 13.0 + t) * sin(VERTEX.y * 11.0 - t * 1.4) * sin(VERTEX.z * 12.0 + t * 0.8);
	VERTEX += NORMAL * k * 0.16;
}
void fragment() {
	ALBEDO = vec3(0.17, 0.005, 0.01);
	ROUGHNESS = 0.18;
	SPECULAR = 0.85;
	METALLIC = 0.02;
}
