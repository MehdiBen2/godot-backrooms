// A faint red stain creeping in along the screen borders at death (death.gd): subtle, like blood on the lens rim.
shader_type canvas_item;
uniform float amount = 0.0;
float h21(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vno(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h21(i), h21(i + vec2(1.0, 0.0)), f.x), mix(h21(i + vec2(0.0, 1.0)), h21(i + vec2(1.0, 1.0)), f.x), f.y);
}
void fragment() {
	vec2 d = abs(UV - 0.5) * 2.0;
	float edge = max(d.x, d.y * 0.9);
	edge += (vno(UV * 6.0) - 0.5) * 0.12;
	float a = smoothstep(0.55, 1.05, edge);
	COLOR = vec4(0.42, 0.015, 0.02, a * a * 0.55 * amount);
}
