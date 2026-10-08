shader_type canvas_item;
// THE CAMERA (render engine v2, scripts/Render/render_engine.gd). Everything the player sees passes through
// one simulated camera, which is two cameras blended by `cam_mode`:
//   0  BODYCAM    a modern digital action camera: a true fisheye lens, a CMOS sensor (rolling shutter, noise
//                 that climbs with gain and lives in the shadows), in-camera sharpening, and a video codec that
//                 breaks flat dark areas into blocks
//   1  CAMCORDER  a late-90s tape camcorder: a gentle barrel lens, a CCD (no rolling shutter), film-like grain,
//                 and the whole VHS chain (luma softness, chroma bleed, line jitter, tracking band, head switching)
// Scares push VHS damage into either one (the engine raises `vhs`).
// Gameplay overlays (fear, blood, blink, the fall, the grab...) are the same as the old post.gdshader and keep
// its parameter names, so every script that drives them works unchanged.
// Tone mapping and bloom come from the Godot environment.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D lens_dirt_tex : filter_linear, repeat_disable;
uniform sampler2D lens_smudge_tex : hint_default_black, filter_linear, repeat_disable;

// ---- the camera (set every frame by render_engine.gd)
uniform float cam_mode = 0.0;          // 0 bodycam .. 1 camcorder
uniform vec2 cam_spin = vec2(0.0);     // how fast the picture slides (screen widths / heights per second)
uniform float shutter = 0.016;         // exposure time, seconds: motion blur length
uniform float blur_max_px = 6.0;       // the motion blur never streaks further than this (1080p pixels): no dizziness
uniform float tape = 0.0;              // 0..1 a touch of old tape on top of the digital camera: grain, colour fringing
uniform float iso = 1.0;               // sensor gain (auto exposure pushing a dark scene up): noise follows it
uniform float sharpen = 0.0;           // in-camera sharpening (digital)
uniform float codec = 0.0;             // compression blocks in flat dark areas (digital)
uniform float noise_luma = 0.0;        // digital sensor noise
uniform float noise_chroma = 0.0;
uniform vec3 grade_digital = vec3(0.97, 1.0, 0.96);
uniform float vignette_amt = 0.62;     // corner brightness at the edge (1 = none)

// ---- kept from post.gdshader (same names, same meaning)
uniform vec3 grade = vec3(1.07, 1.03, 0.88);
uniform float distortion = 0.30;       // the barrel lens (see lens())
uniform float chroma_amt = 0.0028;
uniform float grain = 0.034;
uniform float vhs = 1.0;
uniform float vhs_soft = 0.3;
uniform float vhs_color_offset_multiplier : hint_range(0.0, 0.1) = 0.004;
uniform float vhs_color_offset : hint_range(-0.1, 0.1) = 0.005;
uniform float vhs_blur_amount : hint_range(0.0, 3.0) = 1.0;
uniform float dirt_amt = 0.04;
uniform float dirt_base = 0.2;
uniform float smudge_amt = 0.25;
uniform float smudge_base = 0.4;
uniform float smudge_soft = 0.15;
uniform float halation_amt = 0.08;
uniform float glare_amt = 0.35;
uniform float glare = 0.0;
uniform float fear = 0.0;
uniform float threat = 0.0;
uniform float glitch = 0.0;
uniform float pulse = 0.0;
uniform float classic = 0.0;
uniform float corrupt = 0.0;           // 0..1 the recording breaking up into blocks (Game.fx_corrupt)
uniform float banding = 0.0;          // fluorescent banding: 0 off, else how much tube light the picture is lit by
uniform vec3 wb = vec3(1.0);
uniform float black_lift = 0.0;
uniform float exhaust = 0.0;
uniform float adrenaline = 0.0;
uniform float fx_blink = 0.0;
uniform int post_quality = 2;
uniform float insanity = 0.0;
uniform float fx_blur = 0.0;
uniform float fx_contrast = 1.0;
uniform float fx_sat = 1.0;
uniform float fx_hue = 0.0;
uniform float fx_zoom = 1.0;
uniform float fx_skew = 0.0;
uniform float fx_fade = 0.0;
uniform float fx_flash = 0.0;
uniform float fx_shock = 0.0;
uniform float fx_blood = 0.0;
uniform float fx_static = 0.0;
uniform float fx_warp = 0.0;
uniform float fall_blur = 0.0;
uniform vec2 fall_foe = vec2(0.5);
uniform float fall_warp = 0.0;
uniform float fall_fade = 0.0;

const vec3 LUMA = vec3(0.299, 0.587, 0.114);

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
float vhs_line_noise(vec2 uv, float offset) {
	return (fract(sin(dot(uv * offset, vec2(12.9898, 78.233))) * 43758.5453) - 0.5) * 2.0;
}
vec3 rgb_to_yuv(vec3 rgb) {
	const mat3 RGB_TO_YUV = mat3(vec3(0.299, 0.587, 0.114), vec3(-0.14713, -0.28886, 0.436), vec3(0.615, -0.51499, -0.10001));
	return rgb * RGB_TO_YUV;
}
vec3 yuv_to_rgb(vec3 yuv) {
	const mat3 YUV_TO_RGB = mat3(vec3(1.0, 0.0, 1.13983), vec3(1.0, -0.39465, -0.58060), vec3(1.0, 2.03211, 0.0));
	return clamp(yuv * YUV_TO_RGB, vec3(0.0), vec3(1.0));
}

// The lens: the original game's barrel "fish eye" (post.gdshader), exactly: bends the picture outward with
// enough overscan that the edges never clamp, gentler in a Classic zone, bent harder by a long fall.
// lens_pointer.gd runs the same maths for the cursor.
vec2 lens(vec2 uv, float aspect) {
	vec2 p = uv - 0.5;
	p.x *= aspect;
	float r2 = dot(p, p);
	float max_r2 = 0.25 * (aspect * aspect + 1.0);
	float dist = distortion * (1.0 - 0.6 * classic) + fall_warp;
	float zoom = 1.0 + max_r2 * (dist + chroma_amt) * 1.05;
	p *= (1.0 + r2 * dist) / zoom;
	p.x /= aspect;
	return p + 0.5;
}

void fragment() {
	vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
	float aspect = res.x / res.y;
	float px = SCREEN_PIXEL_SIZE.x;
	float lpx = 1.0 / (1080.0 * aspect);       // one pixel of a 1080p picture: tape work looks the same at any size
	float digital = 1.0 - cam_mode;

	vec2 uv = SCREEN_UV;
	uv = (uv - 0.5) / (fx_zoom + fx_shock * 0.07) + 0.5;
	uv.x -= tan(radians(fx_skew)) * (uv.y - 0.5) * 0.5;
	uv.x += fx_warp * sin(uv.y * 38.0 + TIME * 7.0) * sin(uv.y * 11.0 - TIME * 3.1);
	uv.y += fx_warp * 0.4 * sin(uv.x * 23.0 + TIME * 5.0);
	uv += insanity * vec2(0.0016 * sin(uv.y * 9.0 + TIME * 1.3), 0.0012 * sin(uv.x * 7.0 - TIME * 1.1));

	vec2 base = lens(uv, aspect);

	// ---- VHS sync: line jitter, tracking band, head switching (scaled by `vhs`)
	float threat2 = threat * threat;
	float row = floor(uv.y * res.y * 0.5);
	float tick = floor(TIME * 30.0);
	float burst_tick = floor(TIME * 12.0);
	float burst = step(1.0 - threat2 * 0.07, hash12(vec2(burst_tick, 3.17))) * vhs;
	float jitter = (hash12(vec2(row, tick)) - 0.5) * lpx * (0.5 * vhs + fear * 1.2 * vhs + glitch * 4.0);
	jitter += sin(uv.y * 7.0 + TIME * 1.9) * sin(uv.y * 19.0 - TIME * 4.3) * lpx * threat * 3.0 * vhs;
	jitter += burst * (hash12(vec2(burst_tick, 8.3)) - 0.5) * lpx * 14.0;
	float head_sw = 1.0 - smoothstep(0.0, 0.012 + threat * 0.012, uv.y);
	jitter += head_sw * lpx * (threat * 8.0 + glitch * 8.0) * vhs * (0.6 + 0.4 * hash12(vec2(row, tick)));
	float head_b = smoothstep(0.988, 1.0, uv.y);
	jitter += head_b * lpx * vhs * (2.5 + 2.0 * hash12(vec2(row, tick + 2.0)));
	float band_y = fract(TIME * 0.045 + 0.3);
	float band_on = clamp(smoothstep(0.55, 0.8, vnoise(vec2(TIME * 0.06, 1.7))) * vhs + glitch * 2.0, 0.0, 1.0);
	float band = (1.0 - smoothstep(0.0, 0.025 + glitch * 0.05, abs(uv.y - band_y))) * band_on;
	jitter += band * (hash12(vec2(row, tick + 7.0)) - 0.5) * (0.0015 + glitch * 0.008);
	base.x += jitter;

	// ---- lateral chromatic aberration, growing toward the edge of the lens
	float chroma = chroma_amt * (1.0 + fear * 1.2 + glitch * 4.0) + fx_shock * 0.012;
	vec2 pc = (base - 0.5) * vec2(aspect, 1.0);
	float rr = length(pc);
	vec2 ca_dir = rr > 0.0001 ? pc / rr : vec2(0.0);
	vec2 ca_off = ca_dir * (rr * 0.55 + rr * rr * 0.8) * chroma / vec2(aspect, 1.0);
	vec2 uvg = clamp(base, 0.0, 1.0);
	vec3 col = vec3(texture(screen_tex, clamp(base + ca_off, 0.0, 1.0)).r, texture(screen_tex, uvg).g,
		texture(screen_tex, clamp(base - ca_off, 0.0, 1.0)).b);

	// ---- motion blur: the shutter stays open while the picture slides (both cameras have one)
	// Kept short and capped (blur_max_px): a long smear on every head turn reads as dizziness, not as a camera.
	vec2 mb = cam_spin * shutter;
	float px_scale = res.y / 1080.0;
	float mb_px = length(mb * res) / px_scale;            // in 1080p pixels, so it looks the same at any size
	// the bodycam's is a little livelier (it starts earlier, blends more, reaches further) than the camcorder's
	float mb_dead = mix(2.0, 2.5, cam_mode);
	float mb_cap = mix(blur_max_px + 1.0, blur_max_px, cam_mode);
	if (mb_px > mb_dead) {
		mb *= min(mb_px, mb_cap) / mb_px;
		vec3 macc = vec3(0.0);
		for (int i = 0; i < 6; i++) {
			macc += texture(screen_tex, clamp(uvg + mb * (float(i) / 5.0 - 0.5), 0.0, 1.0)).rgb;
		}
		col = mix(col, macc / 6.0, clamp((mb_px - mb_dead) / mix(5.0, 6.0, cam_mode), 0.0, mix(0.65, 0.7, cam_mode)));
	}

	// ---- tape luma bandwidth (camcorder): a soft horizontal smear, luma only
	if (vhs_soft * vhs > 0.01) {
		vec2 ho = vec2(lpx * 1.2, 0.0);
		vec3 hs = texture(screen_tex, uvg - ho).rgb * 0.3 + texture(screen_tex, uvg + ho).rgb * 0.3
			+ texture(screen_tex, uvg - ho * 2.2).rgb * 0.2 + texture(screen_tex, uvg + ho * 2.2).rgb * 0.2;
		col = max(col + dot(hs - col, LUMA) * clamp(vhs_soft * vhs, 0.0, 1.0), 0.0);
	}

	// ---- in-camera sharpening (digital): an unsharp mask off the screen's own mip chain, one extra read.
	// Cheap cameras overdo it: edges get a thin bright/dark halo.
	if (sharpen * digital > 0.01) {
		vec3 soft = textureLod(screen_tex, uvg, 1.2).rgb;
		col = max(col + (col - soft) * sharpen * digital, 0.0);
	}

	// ---- gameplay blurs (kept from post.gdshader)
	float ins_breath = 0.5 + 0.5 * sin(TIME * 0.7 + 1.8 * sin(TIME * 0.31));
	float blur_px = fx_blur + insanity * (1.2 + 4.2 * ins_breath) + fx_blink * 7.0;
	if (blur_px > 0.02) {
		vec3 acc2 = col;
		for (int i = 0; i < 8; i++) {
			float a = float(i) * 0.785398;
			acc2 += texture(screen_tex, clamp(uvg + vec2(cos(a), sin(a)) * blur_px * SCREEN_PIXEL_SIZE * 1.6, 0.0, 1.0)).rgb;
		}
		col = acc2 / 9.0;
	}
	if (fall_blur > 0.0005) {
		vec2 fd = uvg - fall_foe;
		fd.x *= aspect;
		float fl = length(fd);
		vec2 fdir = fd / max(fl, 1e-4);
		fdir.x /= aspect;
		float flen = fall_blur * smoothstep(0.02, 0.7, fl);
		vec3 facc = vec3(0.0);
		for (int i = 0; i < 8; i++) {
			facc += texture(screen_tex, clamp(uvg + fdir * flen * (float(i) / 7.0 - 0.5), 0.0, 1.0)).rgb;
		}
		col = mix(col, facc / 8.0, 0.85);
	}
	if (insanity > 0.02) {
		vec2 gd = vec2(sin(TIME * 0.9), cos(TIME * 0.7 + 1.0)) * (0.004 + 0.012 * ins_breath) * insanity;
		float ge = 0.5 + 0.5 * smoothstep(0.1, 0.7, length(uvg - 0.5));
		col = mix(col, texture(screen_tex, clamp(uvg + gd * ge, 0.0, 1.0)).rgb, 0.42 * insanity);
	}
	if (fx_shock > 0.02) {
		vec2 dir = (vec2(0.5) - uvg) * 0.09 * fx_shock;
		vec3 racc = col;
		for (int i = 1; i <= 6; i++) racc += texture(screen_tex, clamp(uvg + dir * (float(i) / 6.0), 0.0, 1.0)).rgb;
		col = racc / 7.0;
	}
	float periph = smoothstep(0.18, 0.72, length((uv - 0.5) * vec2(aspect * 0.75, 1.0)));
	float tunnel = max(threat * (0.7 + 0.3 * pulse), adrenaline * (0.8 + 0.4 * pulse));
	if (tunnel > 0.01) {
		vec2 to_c = (vec2(0.5) - uvg) * 0.045 * tunnel * periph;
		vec3 acc = col;
		for (int i = 1; i <= 5; i++) acc += texture(screen_tex, uvg + to_c * (float(i) / 5.0)).rgb;
		col = acc / 6.0;
	}

	// ---- tape colour-under (camcorder / VHS damage): chroma drifts per line and smears, luma stays put
	if (vhs > 0.001) {
		float line_n = vhs_line_noise(vec2(floor(uv.y * 487.0), fract(uv.y * 487.0)), TIME);
		float x_off = (vhs_color_offset + line_n * vhs_color_offset_multiplier) * vhs * (1.0 + glitch * 2.0 + threat * 0.4);
		vec3 chroma_src = textureLod(screen_tex, clamp(uvg + vec2(x_off, 0.0), 0.0, 1.0), vhs_blur_amount).rgb;
		vec3 yuv_l = rgb_to_yuv(col);
		col = mix(col, yuv_to_rgb(vec3(yuv_l.x, rgb_to_yuv(chroma_src).yz)), vhs);
	}

	// ---- video codec (digital): flat, dark areas lose their fine gradation and fall into 8x8 macroblocks,
	// the way a bitrate-starved bodycam file looks in the dark. The block average is the screen's mip 3 at the
	// block's centre (one read): detail and bright areas keep their bits.
	if (codec * digital > 0.01 && post_quality >= 1) {
		float bs = 8.0 * res.y / 1080.0;
		vec2 bc = (floor(FRAGCOORD.xy / bs) + 0.5) * bs * SCREEN_PIXEL_SIZE;
		vec3 avg = textureLod(screen_tex, clamp(lens(bc, aspect), 0.0, 1.0), 3.0).rgb;
		float l = dot(col, LUMA);
		float flat_w = 1.0 - smoothstep(0.015, 0.07, abs(l - dot(avg, LUMA)));
		float dark_w = 1.0 - smoothstep(0.06, 0.3, l);
		col = mix(col, avg + (col - avg) * 0.3, clamp(codec * digital * flat_w * dark_w, 0.0, 0.9));
	}

	// ---- the front glass: dust, smudges, halation, glare (kept from post.gdshader)
	float luma_local = 0.0;
	if (post_quality >= 1) {
		vec2 dirt_uv = uv;
		dirt_uv.x = (dirt_uv.x - 0.5) * (aspect / 1.77778) + 0.5;
		vec3 raw_dirt = texture(lens_dirt_tex, clamp(dirt_uv, 0.0, 1.0)).rgb;
		vec2 rim = abs(dirt_uv - 0.5) * 2.0;
		float rim_fade = 1.0 - smoothstep(0.72, 0.98, max(rim.x, rim.y));
		float dirt_l = max(dot(raw_dirt, LUMA) - 0.22, 0.0) * 1.4 * rim_fade;
		vec3 local_light = textureLod(screen_tex, uvg, 3.5).rgb;
		luma_local = dot(local_light, LUMA);
		vec3 light_tint = mix(vec3(1.0), min(local_light / max(luma_local, 0.001), vec3(1.6)), 0.5);
		vec3 dirt_rgb = dirt_l * light_tint;
		float lens_clean = 1.0 - 0.7 * classic;
		col += dirt_rgb * local_light * dirt_base * lens_clean;
		float lens_t = 0.58 - 0.18 * glare;
		col += dirt_rgb * smoothstep(lens_t, 0.95, luma_local) * dirt_amt * (1.0 + 3.0 * glare) * vec3(1.10, 1.05, 0.90);
		float smudge = texture(lens_smudge_tex, clamp(dirt_uv, 0.0, 1.0)).r * lens_clean;
		if (smudge > 0.004) {
			col = mix(col, textureLod(screen_tex, uvg, 2.0).rgb, clamp(smudge * smudge_soft, 0.0, 0.5));
			float smudge_lit = smudge_base + smoothstep(lens_t - 0.3, 0.95, luma_local) * (1.0 + 2.5 * glare);
			col += smudge * light_tint * local_light * smudge_lit * smudge_amt;
		}
		if (luma_local > lens_t) {
			col += local_light * vec3(1.12, 0.98, 0.75) * (luma_local - lens_t) * halation_amt * (1.0 + 2.0 * glare);
		}
	}
	if (post_quality >= 2 && glare_amt > 0.01) {
		float st = 0.68 - 0.15 * glare;
		// Fast threshold gate: only compute horizontal streak when local region has sufficient luminance
		if (luma_local > st * 0.45) {
			vec3 glare_streak = vec3(0.0);
			vec2 s_dir = vec2(px * 14.0, 0.0);
			for (int i = -4; i <= 4; i++) {
				if (i == 0) continue;
				float fi = float(i);
				vec3 sc = textureLod(screen_tex, clamp(uvg + s_dir * fi, 0.0, 1.0), 3.0).rgb;
				float sl = dot(sc, LUMA);
				if (sl > st) glare_streak += sc * (sl - st) * exp(-abs(fi) * 0.45);
			}
			col += glare_streak * vec3(1.15, 1.02, 0.78) * 0.035 * glare_amt * (1.0 + 1.5 * glare);
		}
		if (luma_local > 0.45 || glare > 0.1) {
			vec2 ghost_vec = vec2(0.5) - uvg;
			vec3 ghosts = vec3(0.0);
			for (int i = 1; i <= 2; i++) {
				vec2 guv = clamp(uvg + ghost_vec * float(i) * 0.5, 0.0, 1.0);
				vec3 gc = textureLod(screen_tex, guv, 3.5).rgb;
				float gl = dot(gc, LUMA);
				if (gl > 0.78) {
					vec3 g_tint = mix(vec3(0.75, 0.9, 1.15), vec3(1.15, 0.95, 0.7), float(i) * 0.5);
					ghosts += gc * (gl - 0.78) * g_tint * (1.0 - smoothstep(0.0, 0.6, length(guv - 0.5)));
				}
			}
			col += ghosts * 0.04 * glare_amt;
		}
	}

	// ---- Classic zone, the Kane Pixels look: the camcorder's highlights bleed softly round every bright panel,
	// the colour is washed out (fluorescent light on a cheap CCD), and the blacks sit on an olive tape pedestal
	if (classic > 0.001) {
		vec3 b1 = textureLod(screen_tex, uvg, 3.0).rgb;
		vec3 b2 = textureLod(screen_tex, uvg, 5.0).rgb;
		col += (b1 * smoothstep(0.5, 0.95, dot(b1, LUMA)) * 0.05 + b2 * smoothstep(0.65, 1.0, dot(b2, LUMA)) * 0.025) * classic * vec3(1.0, 0.96, 0.82);
		col = mix(col, vec3(dot(col, LUMA)), 0.16 * classic);
		col = mix(col, col * vec3(1.0, 0.99, 0.88) + vec3(0.035, 0.032, 0.01), classic);
	}

	// ---- the recording breaking up (the Burnt, Game.fx_corrupt): a digital camera's codec losing the stream. The
	// picture comes apart in square macroblocks: one copied from somewhere else, one frozen to a flat smear of
	// colour, one with its channels swapped, one posterized to a few wrong colours, one smeared down from its top
	// row, one inverted. Bands of rows slip sideways, and dead columns of sensor light streak down. It updates
	// in jerky steps, faster the worse it gets, never smoothly.
	if (corrupt > 0.001) {
		float cq_tick = floor(TIME * mix(5.0, 16.0, corrupt));
		vec2 cq_px = FRAGCOORD.xy;
		for (int cq_l = 0; cq_l < 3; cq_l++) {
			float cq_bs = cq_l == 0 ? 96.0 : (cq_l == 1 ? 48.0 : 16.0);       // big blocks rare, small ones common
			vec2 cq_cell = floor(cq_px / cq_bs);
			float cq_h = hash12(cq_cell + cq_tick * 13.1 + float(cq_l) * 71.0);
			if (cq_h >= corrupt * (cq_l == 0 ? 0.12 : (cq_l == 1 ? 0.22 : 0.3))) continue;
			float cq_kind = hash12(cq_cell * 1.7 + cq_tick + float(cq_l));
			vec2 cq_jump = (vec2(hash12(cq_cell + cq_tick * 3.3), hash12(cq_cell + cq_tick * 5.7)) - 0.5) * 0.3 * corrupt;
			vec3 cq_b = textureLod(screen_tex, clamp(SCREEN_UV + cq_jump, 0.0, 1.0), 0.0).rgb;
			if (cq_kind < 0.28) col = cq_b;
			else if (cq_kind < 0.46) col = textureLod(screen_tex, clamp((cq_cell + 0.5) * cq_bs * SCREEN_PIXEL_SIZE, 0.0, 1.0), 4.5).rgb;
			else if (cq_kind < 0.6) col = cq_b.gbr;
			else if (cq_kind < 0.74) col = floor(cq_b * 3.0 + 0.5) / 3.0 * vec3(1.25, 0.75, 1.15);
			else if (cq_kind < 0.88) col = textureLod(screen_tex, clamp(vec2(SCREEN_UV.x, cq_cell.y * cq_bs * SCREEN_PIXEL_SIZE.y), 0.0, 1.0), 0.0).rgb;
			else col = vec3(1.0) - clamp(cq_b, 0.0, 1.0);
			// the block's edge: codecs leave a hard seam round a broken block
			vec2 cq_e = fract(cq_px / cq_bs);
			if (min(min(cq_e.x, cq_e.y), min(1.0 - cq_e.x, 1.0 - cq_e.y)) * cq_bs < 1.0) col *= 0.6;
			break;
		}
		// whole bands of rows slip sideways
		float cq_band = floor(cq_px.y / 6.0);
		if (hash12(vec2(cq_band, cq_tick * 0.7)) < corrupt * 0.12) {
			float cq_slip = (hash12(vec2(cq_band, cq_tick + 4.0)) - 0.5) * 0.2 * corrupt;
			col = mix(col, textureLod(screen_tex, clamp(SCREEN_UV + vec2(cq_slip, 0.0), 0.0, 1.0), 0.0).rgb, 0.85);
		}
		// dead sensor columns: thin streaks of light down the frame
		float cq_col = floor(cq_px.x / 2.0);
		if (hash12(vec2(cq_col, floor(TIME * 3.0))) < corrupt * 0.006) col += vec3(0.7, 0.75, 0.9) * corrupt;
	}

	// ---- fluorescent banding: the tubes flicker 100 / 120 times a second and a CMOS sensor reads the frame a line
	// at a time, so the flicker lands on the picture as soft horizontal bands crawling slowly up it (the beat of
	// the mains against the frame rate). A camcorder's CCD reads the whole frame at once: there it is a faint pulse
	// of the picture instead. A multiply, so only what the tubes light shows it (render_engine.gd sets how much).
	if (banding > 0.001) {
		float yb = SCREEN_UV.y;
		float bands = sin((yb * 1.6 + TIME * 0.08) * 6.2832);      // a couple of wide bands, drifting slowly one way
		float frame_beat = sin(TIME * 6.2832 * 0.35);   // (not `pulse`: that is the heartbeat uniform)
		float kb = mix(bands, frame_beat * 0.6, cam_mode) * banding;
		col *= vec3(1.0 + 0.03 * kb, 1.0 + 0.028 * kb, 1.0 + 0.024 * kb);     // (gentle: any stronger is hard on the eyes)
	}

	// ---- colour: the camcorder's warm tape grade, or the bodycam's flatter, slightly green fluorescent read
	col *= mix(grade_digital, grade, cam_mode) * wb;
	col = col * (1.0 - black_lift) + black_lift * vec3(0.8, 0.75, 0.58);
	float luma = dot(col, LUMA);
	float sat = clamp(mix(0.86, 0.92, cam_mode) - fear * 0.3 - threat * 0.2, 0.4, 1.0) * (1.0 - burst * 0.8);
	col = mix(vec3(luma), col, sat);
	col = mix(col, col * 0.965 + vec3(0.015, 0.012, 0.005), cam_mode);    // tape's lifted amber blacks
	if (fx_contrast != 1.0 || fx_sat != 1.0 || fx_hue != 0.0) {
		col = (col - 0.5) * fx_contrast + 0.5;
		col = mix(vec3(dot(col, LUMA)), col, fx_sat);
		float h = radians(fx_hue);
		float cs2 = cos(h), sn2 = sin(h);
		mat3 hm = mat3(
			vec3(0.213 + cs2 * 0.787 - sn2 * 0.213, 0.213 - cs2 * 0.213 + sn2 * 0.143, 0.213 - cs2 * 0.213 - sn2 * 0.787),
			vec3(0.715 - cs2 * 0.715 - sn2 * 0.715, 0.715 + cs2 * 0.285 + sn2 * 0.140, 0.715 - cs2 * 0.715 + sn2 * 0.715),
			vec3(0.072 - cs2 * 0.072 + sn2 * 0.928, 0.072 - cs2 * 0.072 - sn2 * 0.283, 0.072 + cs2 * 0.928 + sn2 * 0.072));
		col = clamp(hm * col, 0.0, 1.0);
	}

	// ---- vignette: a wide lens falls off harder toward the corners
	vec2 q = (uv - 0.5) * vec2(1.0, 1.15);
	float vig = 1.0 - smoothstep(0.32 - tunnel * 0.12 - insanity * 0.08, 0.88 - tunnel * 0.3 - insanity * 0.18, length(q));
	float edge = 1.0 - vig;
	col *= mix(mix(vignette_amt, 0.9, classic) - tunnel * 0.3, 1.0, vig);
	col = mix(col, vec3(dot(col, LUMA)), clamp(edge * (threat * 0.9 + exhaust * 0.6), 0.0, 0.85));
	col *= 1.0 - edge * exhaust * 0.35;
	col += band * 0.02 * (0.5 + glitch);

	// ---- tape damage: interference snow band, dropout streaks
	float by = hash12(vec2(burst_tick, 5.9));
	float snow_band = burst * (1.0 - smoothstep(0.0, 0.012, abs(uv.y - by)));
	col = mix(col, vec3(hash12(vec2(floor(FRAGCOORD.x * 0.5), row + tick))), snow_band * 0.45);
	float d_tick = floor(TIME * 20.0);
	float d_hit = step(1.0 - (glitch * 0.006 + threat2 * 0.0015) * vhs, hash12(vec2(row * 1.7, d_tick)));
	float dxs = uv.x - hash12(vec2(row, d_tick + 3.1));
	float d_streak = d_hit * step(0.0, dxs) * (1.0 - smoothstep(0.0, 0.03 + 0.18 * hash12(vec2(row, d_tick + 5.7)), dxs));
	col = mix(col, vec3(0.8, 0.79, 0.76) * (0.55 + 0.45 * hash12(vec2(floor(FRAGCOORD.x * 0.5), row + d_tick))), d_streak * 0.6);

	// ---- gameplay overlays (kept from post.gdshader)
	if (fx_blood > 0.002) {
		vec2 bq = (SCREEN_UV - 0.5) * vec2(aspect * 0.8, 1.0);
		float pe = smoothstep(0.18, 0.95, length(bq));
		float runs = smoothstep(0.52, 0.78, vnoise(vec2(SCREEN_UV.x * aspect * 12.0, SCREEN_UV.y * 1.4 - TIME * 0.03)));
		float amt = fx_blood * (0.3 + 0.7 * pe) * (1.0 + 0.12 * pulse);
		col = mix(col, col * vec3(1.0, 0.24, 0.22) + vec3(0.09, 0.0, 0.005) * pe, clamp(amt, 0.0, 1.0));
		col = mix(col, col * vec3(0.55, 0.05, 0.05), clamp(runs * pe * fx_blood, 0.0, 0.7));
		col *= 1.0 - 0.28 * fx_blood * pe;
	}
	if (fx_static > 0.002) {
		float sn = hash12(FRAGCOORD.xy + fract(TIME * 13.7) * 811.0);
		float row_n = hash12(vec2(floor(FRAGCOORD.y * 0.5), floor(TIME * 24.0)));
		col = mix(col, vec3(sn), fx_static * 0.16 * (0.55 + 0.45 * row_n));
	}
	if (fx_flash > 0.002) {
		float fr = length((SCREEN_UV - 0.5) * 2.0) / 1.41421;
		col += fx_flash * vec3(1.0, 0.92, 0.86) * (1.0 - 0.55 * fr);
	}
	if (fx_fade > 0.001) {
		float rr2 = length((SCREEN_UV - 0.5) * 2.0) / 1.41421;
		float fa = mix(mix(0.0, 0.88, smoothstep(0.12, 0.68, rr2)), 1.0, smoothstep(0.68, 1.0, rr2));
		vec3 fcol = mix(vec3(0.157, 0.0, 0.0), vec3(0.059, 0.0, 0.0), smoothstep(0.12, 0.68, rr2)) * (1.0 - smoothstep(0.68, 1.0, rr2));
		col = mix(col, fcol, fa * fx_fade);
	}
	if (adrenaline > 0.002) {
		float ar = length((SCREEN_UV - 0.5) * vec2(aspect * 0.8, 1.0)) / 0.8;
		float throb = 0.55 + 0.45 * (0.5 + 0.5 * sin(TIME * 8.3776)) + 0.35 * pulse;
		col = mix(col, vec3(0.59, 0.04, 0.04), clamp(smoothstep(0.45, 1.0, ar) * 0.38 * throb * adrenaline, 0.0, 0.8));
		col = mix(col, (col - 0.5) * 1.12 + 0.5, adrenaline * (1.0 - smoothstep(0.2, 0.7, ar)) * 0.6);
	}
	float blink_lids = 0.0;
	if (fx_blink > 0.002) {
		float bow = 0.07 * (1.0 - 4.0 * (SCREEN_UV.x - 0.5) * (SCREEN_UV.x - 0.5));
		float top_edge = fx_blink * 0.5 + bow * fx_blink;
		float bot_edge = 1.0 - fx_blink * 0.5 - bow * fx_blink * 0.7;
		float lid_t = 1.0 - smoothstep(top_edge - 0.03, top_edge + 0.01, SCREEN_UV.y);
		float lid_b = smoothstep(bot_edge - 0.01, bot_edge + 0.03, SCREEN_UV.y);
		float lids = max(max(lid_t, lid_b), smoothstep(0.9, 1.0, fx_blink));
		float pen = (1.0 - smoothstep(top_edge, top_edge + 0.09, SCREEN_UV.y)) + smoothstep(bot_edge - 0.09, bot_edge, SCREEN_UV.y);
		col *= 1.0 - 0.7 * fx_blink * clamp(pen, 0.0, 1.0);
		blink_lids = lids;
	}

	// ---- the sensor's own noise, last (it is in the signal, under nothing)
	vec2 fc = FRAGCOORD.xy;
	float l_out = dot(col, LUMA);
	// camcorder: tape grain and soft scanlines
	col *= 1.0 - 0.015 * vhs * (0.5 + 0.5 * sin(fc.y * 1.57));
	// Deep black stays nearly clean: a real camera crushes its blacks (and there is next to no signal there to be
	// noisy), so the noise lives in the dim shadows just above them. Added at full strength on black, it turned a
	// dark hall or a power cut into a screen of TV static.
	float black_w = 0.2 + 0.8 * smoothstep(0.0, 0.15, l_out);
	float g = hash12(fc + fract(TIME * 7.13) * 917.0) - 0.5;
	col += g * ((grain * max(cam_mode, tape) * (1.0 - 0.7 * classic) + fear * 0.02 + threat * 0.05) * black_w + burst * 0.08) * (1.15 - l_out * 0.6);
	// bodycam: CMOS noise. Lives in the shadows and climbs with gain; the colour part comes in soft 2 px blotches
	if (digital > 0.01) {
		float shadow_w = black_w * (0.3 + 0.7 * (1.0 - smoothstep(0.1, 0.5, l_out)));
		// the gain shows in the noise gently: the eye adaptation opening up in the dark used to triple it
		float gain = clamp(sqrt(max(iso, 0.0)), 0.8, 1.35);
		float ln = (hash12(fc * 1.37 + fract(TIME * 11.3) * 613.0) + hash12(fc * 0.71 + fract(TIME * 5.9) * 271.0) - 1.0);
		vec2 cfc = floor(fc * 0.5);
		vec3 cn = vec3(hash12(cfc + fract(TIME * 9.1) * 401.0), hash12(cfc + 17.3 + fract(TIME * 9.1) * 401.0),
			hash12(cfc + 41.9 + fract(TIME * 9.1) * 401.0)) - 0.5;
		col += (ln * noise_luma + (cn - dot(cn, LUMA)) * noise_chroma) * shadow_w * gain * digital;
	}
	col = mix(col, vec3(0.0), max(blink_lids, fall_fade));
	COLOR = vec4(clamp(col, 0.0, 1.0), 1.0);
}
