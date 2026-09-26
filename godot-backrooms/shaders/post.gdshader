shader_type canvas_item;
// Port of the web game's composite pass (js/post.js): barrel-lens "fish eye" with chromatic
// aberration, VHS line jitter and a rolling tracking band, tape chroma bleed, lens dirt lit by
// bright areas, stage grade, shadow lift, vignette, scanlines and grain.
// Tone mapping (ACES) and bloom come from the Godot environment.
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D lens_dirt_tex : filter_linear, repeat_disable;
uniform vec3 grade = vec3(1.07, 1.03, 0.88);
uniform float distortion = 0.12;
uniform float chroma_amt = 0.0028;
uniform float grain = 0.038;
uniform float dirt_amt = 0.04;
uniform float halation_amt = 0.08;
uniform float glare_amt = 0.35;
uniform float fear = 0.0;      // psychological: sanity, darkness, events
uniform float threat = 0.0;    // entity proximity 0..1, smoothed
uniform float glitch = 0.0;    // tape damage from events and scares
uniform float pulse = 0.0;     // heartbeat envelope 0..1
uniform float exhaust = 0.0;
uniform float adrenaline = 0.0;   // 0..1 burst while running from the bacteria
uniform float fx_blink = 0.0;        // 0 open .. 1 shut: the player's own blink (scares.gd)
uniform float insanity = 0.0;     // 0..1 low sanity: swimming blur, double vision, sagging edges
// Grab / snap screen work (the web's CSS filter + transform on the canvas, and #grab-fade)
uniform float fx_blur = 0.0;      // px
uniform float fx_contrast = 1.0;
uniform float fx_sat = 1.0;
uniform float fx_hue = 0.0;       // degrees
uniform float fx_zoom = 1.0;
uniform float fx_skew = 0.0;      // degrees
uniform float fx_fade = 0.0;      // edges close in to red-black
uniform float fx_flash = 0.0;     // white-hot impact flash (the neck snap)
uniform float fx_shock = 0.0;
uniform float fx_blood = 0.0;     // screen turning to blood: red edges, dark runs, slow pulse
uniform float fx_static = 0.0;    // subtle snow
uniform float fx_warp = 0.0;      // subtle wobble of the picture     // radial zoom-blur + chroma split burst

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
	// scale(zoom) skewX(deg) about the centre
	uv = (uv - 0.5) / (fx_zoom + fx_shock * 0.07) + 0.5;
	uv.x -= tan(radians(fx_skew)) * (uv.y - 0.5) * 0.5;
	// picture wobble
	uv.x += fx_warp * sin(uv.y * 38.0 + TIME * 7.0) * sin(uv.y * 11.0 - TIME * 3.1);
	uv.y += fx_warp * 0.4 * sin(uv.x * 23.0 + TIME * 5.0);
	// a slipping mind: the whole picture slowly swims
	uv += insanity * vec2(0.0016 * sin(uv.y * 9.0 + TIME * 1.3), 0.0012 * sin(uv.x * 7.0 - TIME * 1.1));

	// Barrel lens with overscan so the edges never clamp
	vec2 p = uv - 0.5;
	p.x *= aspect;
	float r2 = dot(p, p);
	float max_r2 = 0.25 * (aspect * aspect + 1.0);
	float zoom = 1.0 + max_r2 * (distortion + chroma_amt) * 1.05;
	float chroma = chroma_amt * (1.0 + fear * 1.2 + glitch * 4.0) + fx_shock * 0.012;
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

	// Subtle, realistic lateral chromatic aberration (increases smoothly with radial distance)
	float dist_r = sqrt(r2);
	vec2 ca_dir = (dist_r > 0.0001) ? (p / dist_r) : vec2(0.0);
	float ca_disp = (dist_r * 0.55 + r2 * 0.8) * chroma;
	vec2 uvr = (p * f + ca_dir * ca_disp); uvr.x /= aspect; uvr = clamp(uvr + shift, 0.0, 1.0);
	vec2 uvg = p * f;                     uvg.x /= aspect; uvg = clamp(uvg + shift, 0.0, 1.0);
	vec2 uvb = (p * f - ca_dir * ca_disp); uvb.x /= aspect; uvb = clamp(uvb + shift, 0.0, 1.0);
	vec3 col = vec3(texture(screen_tex, uvr).r, texture(screen_tex, uvg).g, texture(screen_tex, uvb).b);

	// blur: the grab's CSS blur() px, plus the focus of a failing mind breathing in and out
	float ins_breath = 0.5 + 0.5 * sin(TIME * 0.7 + 1.8 * sin(TIME * 0.31));
	float ins_px = insanity * (1.2 + 4.2 * ins_breath);
	float blur_px = fx_blur + ins_px + fx_blink * 7.0;
	if (blur_px > 0.02) {
		vec3 acc2 = col;
		for (int i = 0; i < 8; i++) {
			float a = float(i) * 0.785398;
			vec2 o = vec2(cos(a), sin(a)) * blur_px * SCREEN_PIXEL_SIZE * 1.6;
			acc2 += texture(screen_tex, clamp(uvg + o, 0.0, 1.0)).rgb + texture(screen_tex, clamp(uvg + o * 0.5, 0.0, 1.0)).rgb * 0.0;
		}
		col = acc2 / 9.0;
	}
	// double vision: a ghost of the picture drifts off and back, stronger toward the edges
	if (insanity > 0.02) {
		vec2 gd = vec2(sin(TIME * 0.9), cos(TIME * 0.7 + 1.0)) * (0.004 + 0.012 * ins_breath) * insanity;
		float ge = 0.5 + 0.5 * smoothstep(0.1, 0.7, length(uvg - 0.5));
		vec3 ghost = texture(screen_tex, clamp(uvg + gd * ge, 0.0, 1.0)).rgb;
		col = mix(col, ghost, 0.42 * insanity);
	}

	// shock: radial zoom-blur streaking out from the centre
	if (fx_shock > 0.02) {
		vec2 dir = (vec2(0.5) - uvg) * 0.09 * fx_shock;
		vec3 racc = col;
		for (int i = 1; i <= 6; i++) racc += texture(screen_tex, clamp(uvg + dir * (float(i) / 6.0), 0.0, 1.0)).rgb;
		col = racc / 7.0;
	}

	// Tunnel vision: the periphery smears toward the centre as the entity closes in
	// (and harder on adrenaline: the edges streak past as you run, only the way out stays sharp)
	float periph = smoothstep(0.18, 0.72, length((uv - 0.5) * vec2(aspect * 0.75, 1.0)));
	float tunnel = max(threat * (0.7 + 0.3 * pulse), adrenaline * (0.8 + 0.4 * pulse));
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

	// Camera lens dirt: subtle dust specks catching direct bright lights only
	vec2 dirt_uv = uv;
	dirt_uv.x = (dirt_uv.x - 0.5) * (aspect / 1.77778) + 0.5;
	vec3 raw_dirt = texture(lens_dirt_tex, clamp(dirt_uv, 0.0, 1.0)).rgb;
	// Cut off lifted black pedestal so clear lens areas stay 100% transparent with zero milky haze
	vec3 dirt_rgb = max(raw_dirt - vec3(0.22), vec3(0.0)) * 1.4;

	vec3 local_light = textureLod(screen_tex, uvg, 3.5).rgb;
	float luma_local = dot(local_light, vec3(0.299, 0.587, 0.114));
	// Only illuminate when facing actual bright light sources (ceiling fixtures / high glare)
	float light_on_lens = smoothstep(0.58, 0.95, luma_local);
	col += dirt_rgb * light_on_lens * dirt_amt * vec3(1.10, 1.05, 0.90);

	// Optical lens glare: subtle horizontal streak & gentle ghosts when looking at bright lights
	if (glare_amt > 0.01) {
		// Anamorphic horizontal glare streak across the lens
		vec3 glare_streak = vec3(0.0);
		vec2 s_dir = vec2(px * 14.0, 0.0);
		for (int i = -4; i <= 4; i++) {
			if (i == 0) continue;
			float fi = float(i);
			vec2 suv = clamp(uvg + s_dir * fi, 0.0, 1.0);
			vec3 sc = textureLod(screen_tex, suv, 3.0).rgb;
			float sl = dot(sc, vec3(0.299, 0.587, 0.114));
			if (sl > 0.68) {
				float weight = exp(-abs(fi) * 0.45);
				glare_streak += sc * (sl - 0.68) * weight;
			}
		}
		col += glare_streak * vec3(1.15, 1.02, 0.78) * 0.035 * glare_amt;

		// Gentle lens flare ghosts
		vec2 ghost_vec = vec2(0.5) - uvg;
		vec3 ghosts = vec3(0.0);
		for (int i = 1; i <= 2; i++) {
			float g_scale = float(i) * 0.5;
			vec2 guv = clamp(uvg + ghost_vec * g_scale, 0.0, 1.0);
			vec3 gc = textureLod(screen_tex, guv, 3.5).rgb;
			float gl = dot(gc, vec3(0.299, 0.587, 0.114));
			if (gl > 0.78) {
				float g_dist = length(guv - 0.5);
				vec3 g_tint = mix(vec3(0.75, 0.9, 1.15), vec3(1.15, 0.95, 0.7), float(i) * 0.5);
				ghosts += gc * (gl - 0.78) * g_tint * (1.0 - smoothstep(0.0, 0.6, g_dist));
			}
		}
		col += ghosts * 0.04 * glare_amt;
	}

	// Lens halation: subtle diffusion around direct bulb elements
	vec3 bloom_sample = textureLod(screen_tex, uvg, 3.5).rgb;
	float bloom_luma = dot(bloom_sample, vec3(0.299, 0.587, 0.114));
	if (bloom_luma > 0.60) {
		col += bloom_sample * vec3(1.12, 0.98, 0.75) * (bloom_luma - 0.60) * halation_amt;
	}

	col *= grade;
	float luma = dot(col, vec3(0.299, 0.587, 0.114));
	float sat = clamp(0.92 - fear * 0.3 - threat * 0.2, 0.4, 1.0) * (1.0 - burst * 0.8);
	col = mix(vec3(luma), col, sat);                        // colour drains with fear
	col = col * 0.965 + vec3(0.015, 0.012, 0.005);          // lifted amber-black shadows matching camcorder tape
	// grab colour work: contrast, saturation, hue rotation (CSS filter equivalents)
	if (fx_contrast != 1.0 || fx_sat != 1.0 || fx_hue != 0.0) {
		col = (col - 0.5) * fx_contrast + 0.5;
		float l2 = dot(col, vec3(0.299, 0.587, 0.114));
		col = mix(vec3(l2), col, fx_sat);
		float h = radians(fx_hue);
		float cs2 = cos(h), sn2 = sin(h);
		mat3 hm = mat3(
			vec3(0.213 + cs2 * 0.787 - sn2 * 0.213, 0.213 - cs2 * 0.213 + sn2 * 0.143, 0.213 - cs2 * 0.213 - sn2 * 0.787),
			vec3(0.715 - cs2 * 0.715 - sn2 * 0.715, 0.715 + cs2 * 0.285 + sn2 * 0.140, 0.715 - cs2 * 0.715 + sn2 * 0.715),
			vec3(0.072 - cs2 * 0.072 + sn2 * 0.928, 0.072 - cs2 * 0.072 - sn2 * 0.283, 0.072 + cs2 * 0.928 + sn2 * 0.072));
		col = clamp(hm * col, 0.0, 1.0);
	}

	vec2 q = (uv - 0.5) * vec2(1.0, 1.15);
	float vig = 1.0 - smoothstep(0.32 - tunnel * 0.12 - insanity * 0.08, 0.88 - tunnel * 0.3 - insanity * 0.18, length(q));
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

	// blood on the lens: deep red creeping in from the edges with darker runs, breathing with the pulse
	if (fx_blood > 0.002) {
		vec2 bq = (SCREEN_UV - 0.5) * vec2(aspect * 0.8, 1.0);
		float pe = smoothstep(0.18, 0.95, length(bq));
		float runs = smoothstep(0.52, 0.78, vnoise(vec2(SCREEN_UV.x * aspect * 12.0, SCREEN_UV.y * 1.4 - TIME * 0.03)));
		float amt = fx_blood * (0.3 + 0.7 * pe) * (1.0 + 0.12 * pulse);
		vec3 tinted = col * vec3(1.0, 0.24, 0.22) + vec3(0.09, 0.0, 0.005) * pe;
		col = mix(col, tinted, clamp(amt, 0.0, 1.0));
		col = mix(col, col * vec3(0.55, 0.05, 0.05), clamp(runs * pe * fx_blood, 0.0, 0.7));
		col *= 1.0 - 0.28 * fx_blood * pe;
	}
	// snow
	if (fx_static > 0.002) {
		float sn = hash12(FRAGCOORD.xy + fract(TIME * 13.7) * 811.0);
		float row_n = hash12(vec2(floor(FRAGCOORD.y * 0.5), floor(TIME * 24.0)));
		col = mix(col, vec3(sn), fx_static * 0.16 * (0.55 + 0.45 * row_n));
	}

	// impact flash: hot white in the middle, falling off toward the edges
	if (fx_flash > 0.002) {
		float fr = length((SCREEN_UV - 0.5) * 2.0) / 1.41421;
		col += fx_flash * vec3(1.0, 0.92, 0.86) * (1.0 - 0.55 * fr);
	}

	// #grab-fade: radial gradient rgba(40,0,0,0) 12% -> rgba(15,0,0,.88) 68% -> black 100%
	if (fx_fade > 0.001) {
		float rr = length((SCREEN_UV - 0.5) * 2.0) / 1.41421;
		float fa = mix(0.0, 0.88, smoothstep(0.12, 0.68, rr));
		fa = mix(fa, 1.0, smoothstep(0.68, 1.0, rr));
		vec3 fcol = mix(vec3(0.157, 0.0, 0.0), vec3(0.059, 0.0, 0.0), smoothstep(0.12, 0.68, rr)) * (1.0 - smoothstep(0.68, 1.0, rr));
		col = mix(col, fcol, fa * fx_fade);
	}

	// adrenaline (body.adrenaline::after): red creeping in at the edges, throbbing ~80 bpm and
	// kicking with each heartbeat; the centre gets a touch hotter and punchier
	if (adrenaline > 0.002) {
		float ar = length((SCREEN_UV - 0.5) * vec2(aspect * 0.8, 1.0)) / 0.8;
		float throb = 0.55 + 0.45 * (0.5 + 0.5 * sin(TIME * 8.3776)) + 0.35 * pulse;
		float red = smoothstep(0.45, 1.0, ar) * 0.38 * throb * adrenaline;
		col = mix(col, vec3(0.59, 0.04, 0.04), clamp(red, 0.0, 0.8));
		float c_amt = adrenaline * (1.0 - smoothstep(0.2, 0.7, ar));
		col = mix(col, (col - 0.5) * 1.12 + 0.5, c_amt * 0.6);
	}

	// blink: two eyelids sweep in from the top and bottom, each with a bowed edge and a soft dark
	// penumbra; the lids themselves are drawn pure black at the very end; what is left of the picture blurs and darkens
	float blink_lids = 0.0;
	if (fx_blink > 0.002) {
		float bow = 0.07 * (1.0 - 4.0 * (SCREEN_UV.x - 0.5) * (SCREEN_UV.x - 0.5));
		float top_edge = fx_blink * 0.5 + bow * fx_blink;
		float bot_edge = 1.0 - fx_blink * 0.5 - bow * fx_blink * 0.7;
		float lid_t = 1.0 - smoothstep(top_edge - 0.03, top_edge + 0.01, SCREEN_UV.y);
		float lid_b = smoothstep(bot_edge - 0.01, bot_edge + 0.03, SCREEN_UV.y);
		float lids = max(lid_t, lid_b);
		float pen = (1.0 - smoothstep(top_edge, top_edge + 0.09, SCREEN_UV.y)) + smoothstep(bot_edge - 0.09, bot_edge, SCREEN_UV.y);
		col *= 1.0 - 0.7 * fx_blink * clamp(pen, 0.0, 1.0);
		blink_lids = lids;
	}

	vec2 fc = FRAGCOORD.xy;
	col *= 0.98 + 0.02 * sin(fc.y * 1.57);                 // soft analog scanlines
	float g = hash12(fc + fract(TIME * 7.13) * 917.0) - 0.5;
	col += g * (grain + fear * 0.02 + threat * 0.05 + burst * 0.08) * (1.15 - luma * 0.6); // organic film grain
	col = mix(col, vec3(0.0), blink_lids);                  // the lids are pure black, over grain and all
	COLOR = vec4(clamp(col, 0.0, 1.0), 1.0);
}
