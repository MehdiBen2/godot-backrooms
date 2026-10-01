shader_type spatial;
// The walls of a bottomless pit (scripts/World/level/pit_fall.gd): one storey of shaft, drawn over and over.
// The bottom WALL band of each storey wears the level's own wall material (its wallpaper or PBR wall, the
// same world-space mapping, so the pit's rim meets the room's walls), the band over it is the bare concrete
// of the slab between floors, and a fluorescent tube is fixed under every slab on every cell's width of wall.
//
// No real lights: the tubes' light on the walls is worked out here, from where a pixel is in its storey
// (baked, in effect, only exact and free of a lightmap's texels). It repeats with the storey, and which
// rows of tubes are dead or failing repeats with `rows`, so the player can be moved up by a whole number of
// those repeats without one pixel changing. A real light that reaches the walls (the torch) still lights
// them: the baked light goes in EMISSION, on top of the usual shading, and ambient light is left out.
render_mode cull_disabled, shadows_disabled, ambient_light_disabled, specular_schlick_ggx;

uniform sampler2D wall_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 wall_tint : source_color = vec3(1.0, 0.98, 0.88);
uniform vec2 wall_scale = vec2(0.4444, 1.0);   // x: repeats per metre along the wall, y: repeats up one wall band
uniform float wall_flip = 1.0;                 // 1: the texture's top is the band's top (the wallpaper's ceiling shadow)
uniform sampler2D slab_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D floor_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;   // the fake corridors' carpet
uniform vec3 floor_tint : source_color = vec3(1.0, 0.94, 0.75);
uniform vec2 floor_scale = vec2(0.5, 0.5);   // repeats per metre
uniform vec3 slab_tint : source_color = vec3(0.56, 0.54, 0.5);

uniform float seg_h = 9.0;          // one storey (level_data.gd STOREY_H)
uniform float band_h = 5.4;         // its room-height band of wall (WALL_H); the slab is the rest
uniform float tube_y = 5.05;        // height of the tubes in their storey
uniform float tube_half = 0.6;
uniform float cell = 4.5;
uniform float shaft_w = 4.5;        // across the shaft: how far off the tubes on the far wall are

uniform vec3 tube_color : source_color = vec3(1.0, 0.93, 0.78);
uniform float tube_glow = 7.0;      // the tube itself (HDR: it blooms)
uniform float near_light = 1.6;     // a tube on the wall it is fixed to
uniform float far_light = 0.55;     // the tubes on the other walls
uniform float base_light = 0.035;   // what is left between rows (the dead ones included)
uniform float grime = 0.4;

// A shaft going up (endless_shaft.gd): out of the room's ceiling height the walls and tubes sink into the dark, the
// torch's light on the walls first (it is the real light, and would light the whole shaft), the tubes' own later.
// The defaults, far above any pit, leave a pit as it was.
// The haze a fall closes over the shaft above you (pit_fall.gd): walls over the camera sink into haze_color the
// higher they are, so looking up the shaft ends in an even haze and not a hard edge. Off by default.
uniform vec3 haze_color : source_color = vec3(0.0);
uniform float haze_k = 0.0;         // per metre over the camera
uniform float haze_y = 0.0;         // the camera's height

// ...and the higher, the more run down: damp spreading over the walls, the tubes weaker. 0 at rot_from, full at rot_to.
uniform float rot_from = 100000000.0;
uniform float rot_to = 200000000.0;
uniform float fade_from = 100000000.0;
uniform float fade_to = 200000000.0;

// The rows of tubes, one a storey, PERIOD of them, then the same again (pit_fall.gd WRAP_SEGS):
// 0 dead, 1 steady, 2 failing. 16 is the most there can be.
uniform float rows[16];
uniform int period = 12;

varying vec3 wpos;
varying vec3 wnrm;

float hash11(float n) { return fract(sin(n * 12.9898 + 4.1414) * 43758.5453); }
float vnoise1(float x) {
	float i = floor(x);
	float f = fract(x);
	return mix(hash11(i), hash11(i + 1.0), f * f * (3.0 - 2.0 * f));
}

// How lit row `row` is right now
float row_level(float row, float t) {
	int k = int(mod(row, float(period)));
	float kind = rows[k];
	if (kind < 0.5) return 0.0;
	if (kind < 1.5) return 0.97 + 0.03 * sin(t * 2.3 + float(k) * 1.7);   // a slow, barely-there drift
	// failing: on, then off for a beat or a burst of stutter, at its own pace
	float r = float(k);
	float beat = floor(t * (5.0 + 7.0 * hash11(r + 3.0)));
	float n = hash11(beat * 0.731 + r * 17.0);
	float burst = step(0.55, vnoise1(t * 0.6 + r * 9.0));
	return n < 0.18 + 0.5 * burst ? 0.06 : 1.0;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
}

void fragment() {
	float h = mod(wpos.y, seg_h);             // height in this storey
	float row = floor(wpos.y / seg_h);
	vec3 n = normalize(wnrm);
	bool x_wall = abs(n.x) > 0.5;
	float along = x_wall ? wpos.z : wpos.x;
	float off = along - cell * round(along / cell);   // from the middle of the cell edge (the tube's middle)
	float rot = smoothstep(rot_from, rot_to, wpos.y);

	if (COLOR.a < 0.5) {
		// a tube: its row's light, a touch hotter along the glass
		float lv = row_level(row, TIME);
		ALBEDO = vec3(0.85);
		ROUGHNESS = 0.4;
		EMISSION = tube_color * tube_glow * lv * (0.75 + 0.25 * COLOR.r) * (1.0 - 0.5 * rot);
	} else if (COLOR.r < 0.9) {
		// a fake corridor behind a doorway (pit_fall.gd _corridor): carpet, ceiling tiles, the level's wallpaper, and
		// a pool of light under every ceiling light, dying away down its length. Some of them are dark.
		float depth = UV.x;
		float id = UV.y + row * 3.1;
		float lv = hash11(id) < 0.22 ? 0.1 : 1.0;
		vec3 base;
		if (n.y > 0.5) {
			base = texture(floor_tex, wpos.xz * floor_scale).rgb * floor_tint;
		} else if (n.y < -0.5) {
			base = vec3(0.62, 0.58, 0.47);
		} else {
			vec2 uv = vec2(depth * wall_scale.x, (wall_flip > 0.5 ? 1.0 - h / band_h : h / band_h) * wall_scale.y);
			base = texture(wall_tex, uv).rgb * wall_tint;
		}
		float pools = 0.25 + 0.75 * pow(0.5 + 0.5 * cos(depth * 6.2832 / cell + 1.2), 3.0);
		float reach = exp(-depth / 12.0);
		ALBEDO = base;
		ROUGHNESS = 0.95;
		EMISSION = base * tube_color * lv * pools * reach * 2.2 * (1.0 - 0.55 * rot);
	} else {
		vec3 base;
		float rough;
		if (h < band_h) {
			vec2 uv = vec2(along * wall_scale.x, (wall_flip > 0.5 ? 1.0 - h / band_h : h / band_h) * wall_scale.y);
			base = texture(wall_tex, uv).rgb * wall_tint;
			rough = 0.92;
		} else {
			base = texture(slab_tex, vec2(along, h) * 0.5).rgb * slab_tint;
			rough = 1.0;
		}
		// damp: streaks run down from under each slab, a few of them all the way
		float k = mod(row, float(period));
		float streak = vnoise1(along * 1.9 + k * 7.3) * vnoise1(along * 0.37 + 11.0 + k);
		float reach = 1.0 + 4.5 * vnoise1(along * 0.8 + k * 3.1);
		float wet = streak * smoothstep(band_h - reach, band_h, h) * step(h, band_h);
		base *= 1.0 - min(grime + 0.45 * rot, 0.95) * wet;
		// rot: big blotches of damp, whole stretches of wall gone dark with it
		base *= 1.0 - 0.6 * rot * vnoise1(along * 0.31 + k * 4.7) * vnoise1(h * 0.55 + along * 0.13 + k * 1.9);
		// the joint between wall and slab, and the slab's own seam at the storey line
		base *= mix(0.55, 1.0, smoothstep(0.0, 0.05, abs(h - band_h)));
		base *= mix(0.7, 1.0, smoothstep(0.0, 0.04, min(h, seg_h - h)));
		// inside corners (UV.x: metres along this run of wall, UV.y: its length)
		float ao = mix(0.5, 1.0, smoothstep(0.0, 0.9, min(UV.x, UV.y - UV.x)));

		float da = max(abs(off) - tube_half, 0.0);
		float light = base_light;
		for (int i = -1; i <= 1; i++) {
			float lv = row_level(row + float(i), TIME);
			if (lv <= 0.0) continue;
			float dy = h - (tube_y + float(i) * seg_h);
			// the tube on this wall throws a scallop up and down it; the ones across the shaft light it evenly
			float near = near_light / (1.0 + 1.8 * (da * da + dy * dy));
			float far = far_light * shaft_w * shaft_w / (shaft_w * shaft_w + dy * dy * 1.6);
			light += lv * (near + far);
		}
		ALBEDO = base;
		ROUGHNESS = rough;
		EMISSION = base * tube_color * light * ao * (1.0 - 0.45 * rot);
	}
	float lit = 1.0 - smoothstep(fade_from, mix(fade_from, fade_to, 0.4), wpos.y);
	ALBEDO *= lit;
	SPECULAR = 0.5 * lit;
	EMISSION *= 1.0 - smoothstep(fade_from, fade_to, wpos.y);
	float hz = 1.0 - exp(-max(wpos.y - haze_y, 0.0) * haze_k);
	ALBEDO *= 1.0 - hz;
	SPECULAR *= 1.0 - hz;
	EMISSION = mix(EMISSION, haze_color, hz);
}
