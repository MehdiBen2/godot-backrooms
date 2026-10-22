// The perforated black strip along the head of an outpost window (props/outpost_glazing.gd): powder-coated steel
// punched with rows of small round holes, staggered, the light behind the glass showing faintly through them.
// The holes are worked out from where the point is in the window's own frame (model space: z along the window,
// y up), so they are round and evenly spaced whatever length the strip is built to.
shader_type spatial;

uniform float pitch = 0.032;            // metres between holes along a row
uniform float radius = 0.0085;          // a hole's radius
uniform vec3 plate : source_color = vec3(0.03, 0.031, 0.033);
uniform vec3 through : source_color = vec3(0.32, 0.31, 0.28);

varying vec3 lp;

void vertex() {
	lp = VERTEX;
}

void fragment() {
	vec2 q = vec2(lp.z, lp.y) / pitch;
	float row = floor(q.y);
	q.x += mod(row, 2.0) * 0.5;               // every other row half a hole along
	vec2 c = fract(q) - 0.5;
	float d = length(c) * pitch;
	float hole = 1.0 - smoothstep(radius - 0.0012, radius + 0.0012, d);
	ALBEDO = mix(plate, through, hole);
	ROUGHNESS = mix(0.55, 0.9, hole);
	SPECULAR = mix(0.4, 0.0, hole);
}
