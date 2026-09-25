shader_type canvas_item;
// Port of the web game's composite pass (js/post.js): barrel-lens "fish eye" with chromatic
// aberration, VHS line jitter and a rolling tracking band, tape chroma bleed, lens dirt lit by
// bright areas, stage grade, shadow lift, vignette, scanlines and grain.
// Tone mapping (ACES) and bloom come from the Godot environment.
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform vec3 grade = vec3(1.04, 1.01, 0.89);
uniform float distortion = 0.26;
uniform float chroma_amt = 0.002;
uniform float grain = 0.045;
uniform float dirt_amt = 0.35;
uniform float fear = 0.0;      // psychological: sanity, darkness, events
uniform float threat = 0.0;    // entity proximity 0..1, smoothed
uniform float glitch = 0.0;    // tape damage from events and scares
uniform float pulse = 0.0;     // heartbeat envelope 0..1
uniform float exhaust = 0.0;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}
float vnoise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1, 0)), f.x), mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), f.x), f.y);
}

void fragment() {
	vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
	float aspect = res.x / res.y;
	float px = SCREEN_PIXEL_SIZE.x;
	vec2 uv = SCREEN_UV;

	// Barrel lens with overscan so the edges never clamp
	vec2 p = uv - 0.5;
	p.x *= aspect;
	float r2 = dot(p, p);
	float max_r2 = 0.25 * (aspect * aspect + 1.0);
	float zoom = 1.0 + max_r2 * (distortion + chroma_amt) * 1.05;
	float chroma = chroma_amt * (1.0 + fear * 1.2 + glitch * 4.0);
	float threat2 = threat * threat;
	float f = (1.0 + r2 * distortion) / zoom;

	// VHS: sub-pixel line jitter, a slow rolling tracking band
	float row = floor(uv.y * res.y * 0.5);
	float tick = floor(TIME * 30.0);
	// weak-signal interference near the entity: rare frames where sync slips
	float burst_tick = floor(TIME * 12.0);
	float burst = step(1.0 - threat2 * 0.07, hash12(vec2(burst_tick, 3.17)));
	float jitter = (hash12(vec2(row, tick)) - 0.5) * px * (0.8 + fear * 1.2 + glitch * 4.0);
	jitter += sin(uv.y * 7.0 + TIME * 1.9) * sin(uv.y * 19.0 - TIME * 4.3) * px * threat * 3.0;
	jitter += burst * (hash12(vec2(burst_tick, 8.3)) - 0.5) * px * 14.0;
	float head_sw = 1.0 - smoothstep(0.0, 0.012 + threat * 0.012, uv.y);
	jitter += head_sw * px * (threat * 8.0 + glitch * 8.0) * (0.6 + 0.4 * hash12(vec2(row, tick)));
	float band_y = fract(TIME * 0.045 + 0.3);
	float band = 1.0 - smoothstep(0.0, 0.025 + glitch * 0.05, abs(uv.y - band_y));
	jitter += band * (hash12(vec2(row, tick + 7.0)) - 0.5) * (0.003 + glitch * 0.008);
	vec2 shift = vec2(0.5 + jitter, 0.5);

	vec2 uvr = p * (f + chroma * r2); uvr.x /= aspect; uvr = clamp(uvr + shift, 0.0, 1.0);
	vec2 uvg = p * f;                     uvg.x /= aspect; uvg = clamp(uvg + shift, 0.0, 1.0);
	vec2 uvb = p * (f - chroma * r2); uvb.x /= aspect; uvb = clamp(uvb + shift, 0.0, 1.0);
	vec3 col = vec3(texture(screen_tex, uvr).r, texture(screen_tex, uvg).g, texture(screen_tex, uvb).b);

	// Tunnel vision: the periphery smears toward the centre as the entity closes in
	float periph = smoothstep(0.18, 0.72, length((uv - 0.5) * vec2(aspect * 0.75, 1.0)));
	float tunnel = threat * (0.7 + 0.3 * pulse);
	if (tunnel > 0.01) {
		vec2 to_c = (vec2(0.5) - uvg) * 0.045 * tunnel * periph;
		vec3 acc = col;
		for (int i = 1; i <= 5; i++) acc += texture(screen_tex, uvg + to_c * (float(i) / 5.0)).rgb;
		col = acc / 6.0;
	}

	// Tape chroma has less bandwidth than luma: colour smears right of edges
	vec2 c_off = vec2(px * (1.5 + threat * 5.0 + glitch * 5.0), 0.0);
	vec3 cs = (col + texture(screen_tex, uvg + c_off).rgb + texture(screen_tex, uvg + c_off * 2.0).rgb) / 3.0;
	vec3 bled = max(vec3(dot(col, vec3(0.299, 0.587, 0.114))) + cs - vec3(dot(cs, vec3(0.299, 0.587, 0.114))), 0.0);
	col = mix(col, bled, clamp(0.4 + threat * 0.6 + glitch, 0.0, 1.0));

	// Lens dirt: smudges and specks that only show where bright light scatters through them
	vec2 dp = vec2(uv.x * aspect, uv.y);
	float dn = vnoise(dp * 3.0 + 7.0) * 0.55 + vnoise(dp * 8.0 + 2.0) * 0.3 + vnoise(dp * 24.0) * 0.15;
	float dirt = smoothstep(0.52, 0.84, dn) * 0.7;
	vec3 glow = textureLod(screen_tex, uvg, 5.0).rgb;
	col += dirt * max(glow - 0.15, 0.0) * dirt_amt * vec3(1.0, 0.94, 0.8);

	col *= grade;
	float luma = dot(col, vec3(0.299, 0.587, 0.114));
	float sat = clamp(0.92 - fear * 0.3 - threat * 0.2, 0.4, 1.0) * (1.0 - burst * 0.8);
	col = mix(vec3(luma), col, sat);                        // colour drains with fear
	col = col * 0.985 + vec3(0.005, 0.004, 0.002);          // lifted amber-black shadows

	vec2 q = (uv - 0.5) * vec2(1.0, 1.15);
	float vig = 1.0 - smoothstep(0.32 - tunnel * 0.12, 0.88 - tunnel * 0.3, length(q));
	float edge = 1.0 - vig;
	col *= mix(0.55 - tunnel * 0.3, 1.0, vig);
	col = mix(col, vec3(dot(col, vec3(0.299, 0.587, 0.114))), clamp(edge * (threat * 0.9 + exhaust * 0.6), 0.0, 0.85));
	col *= 1.0 - edge * exhaust * 0.35;
	col += band * 0.03 * (0.5 + glitch);

	// interference snow band where the sync slipped, and short tape dropout streaks
	float by = hash12(vec2(burst_tick, 5.9));
	float snow_band = burst * (1.0 - smoothstep(0.0, 0.012, abs(uv.y - by)));
	col = mix(col, vec3(hash12(vec2(floor(FRAGCOORD.x * 0.5), row + tick))), snow_band * 0.45);
	float d_tick = floor(TIME * 20.0);
	float d_hit = step(1.0 - (glitch * 0.006 + threat2 * 0.0015), hash12(vec2(row * 1.7, d_tick)));
	float d_start = hash12(vec2(row, d_tick + 3.1));
	float d_len = 0.03 + 0.18 * hash12(vec2(row, d_tick + 5.7));
	float dxs = uv.x - d_start;
	float d_streak = d_hit * step(0.0, dxs) * (1.0 - smoothstep(0.0, d_len, dxs));
	col = mix(col, vec3(0.8, 0.79, 0.76) * (0.55 + 0.45 * hash12(vec2(floor(FRAGCOORD.x * 0.5), row + d_tick))), d_streak * 0.6);

	vec2 fc = FRAGCOORD.xy;
	col *= 0.97 + 0.03 * sin(fc.y * 2.094);                 // scanlines
	float g = hash12(fc + fract(TIME * 7.13) * 917.0) - 0.5;
	col += g * (grain + fear * 0.02 + threat * 0.05 + burst * 0.08) * (1.1 - luma);                        // grain, heavier in the shadows
	COLOR = vec4(clamp(col, 0.0, 1.0), 1.0);
}
