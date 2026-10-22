shader_type canvas_item;

#define MAX_STEPS 100
#define MAX_DIST 100.0
#define MIN_DIST 0.1

const vec4 sphere = vec4(0.0, 1.0, 6.0, 1.0);
const vec3 lightpos = vec3(1.0, 7.0, 6.0);

float getdist(vec3 raypos) {
	float planedist = raypos.y;
	float spheredist = length(raypos - sphere.xyz) - sphere.w;
	return min(planedist, spheredist);
}

vec3 getnormal(vec3 p) {
	return normalize(sphere.xyz - p);
}

float getlight(vec3 p) {
	vec3 lightdir = normalize(lightpos - p);
	vec3 normal = getnormal(p);
	float diff = dot(normal, lightdir);
	return diff;
}

float raymarch(vec3 camera, vec3 dir) {
	float dist = 0.0;
	for (int i = 0; i < MAX_STEPS; i++) {
		vec3 pos = camera + dir * dist;
		float stepdist = getdist(pos);
		dist += stepdist;
		if (dist > MAX_DIST || dist < MIN_DIST) {
			break;
		}
	}
	return dist;
}

void fragment() {
	vec2 iResolution = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 uv = (FRAGCOORD.xy - iResolution.xy * 0.5) / iResolution.y;
	vec3 col = vec3(0.0);

	vec3 camera = vec3(0.0, 1.0, 1.0);
	vec3 ray = vec3(uv.x, uv.y, camera.z);
	float d = raymarch(camera, normalize(ray));
	vec3 p = camera + ray * d;
	float diff = getlight(p);
	col += vec3(1.0 - diff);

	COLOR = vec4(col, 1.0);
}
