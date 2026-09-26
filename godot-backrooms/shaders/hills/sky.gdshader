shader_type sky;
// Day / night sky. Palette, sun and moon are driven per frame by hills.gd (time of day); this shader
// only draws: gradient, sun and moon, stars, and two cloud layers (warped cumulus + thin cirrus).
uniform vec3 sun_dir = vec3(0.35, 0.5, -0.8);
uniform vec3 moon_dir = vec3(-0.35, -0.5, 0.8);
uniform vec3 zenith_col : source_color = vec3(0.18, 0.38, 0.78);
uniform vec3 mid_col : source_color = vec3(0.5, 0.68, 0.9);
uniform vec3 horizon_col : source_color = vec3(0.78, 0.86, 0.95);
uniform vec3 sun_col : source_color = vec3(1.0, 0.95, 0.85);
uniform vec3 cloud_lit : source_color = vec3(1.0, 0.98, 0.95);
uniform vec3 cloud_shade : source_color = vec3(0.55, 0.6, 0.7);
uniform float night = 0.0;          // 0 day .. 1 full night
uniform float cloud_cover = 0.5;
uniform float cloud_time = 0.0;     // advanced by the script: a shader TIME would force the sky to redraw non-stop

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * vnoise(p);
		p = mat2(vec2(1.6, 1.2), vec2(-1.2, 1.6)) * p + vec2(17.1, 9.7);   // rotate as we go: no grid alignment
		a *= 0.5;
	}
	return v;
}

// cloud density at a sky-plane point: domain-warped fbm gives billowy, ragged-edged cumulus
float cumulus(vec2 uv) {
	vec2 q = vec2(fbm(uv + vec2(0.0, cloud_time * 0.6)), fbm(uv + vec2(5.2, 1.3)));
	return fbm(uv + 1.8 * q + vec2(cloud_time, 0.0));
}

void sky() {
	vec3 d = normalize(EYEDIR);
	vec3 sd_v = normalize(sun_dir);
	vec3 md_v = normalize(moon_dir);
	float sd = max(dot(d, sd_v), 0.0);
	float md = max(dot(d, md_v), 0.0);
	float up = clamp(d.y, 0.0, 1.0);

	vec3 col = mix(horizon_col, mid_col, smoothstep(0.0, 0.2, up));
	col = mix(col, zenith_col, smoothstep(0.12, 0.85, up));
	// glow around the sun: a wide warm haze plus a tight core
	col += sun_col * (pow(sd, 5.0) * 0.22 + pow(sd, 40.0) * 0.5) * (1.0 - night);
	col += vec3(0.5, 0.6, 0.9) * pow(md, 30.0) * 0.12 * night;

	// stars and moon, only once it is dark
	if (night > 0.01 && d.y > -0.05) {
		vec3 p = d * 170.0;
		vec3 cell = floor(p);
		float h = hash(cell.xy + cell.z * 37.17);
		float twinkle = 0.6 + 0.4 * sin(cloud_time * 40.0 * h + h * 30.0);
		float star = step(0.9962, h) * smoothstep(0.55, 0.0, length(fract(p) - 0.5)) * twinkle;
		col += vec3(0.85, 0.9, 1.0) * star * 1.6 * night * smoothstep(0.0, 0.2, d.y);
		col += vec3(0.9, 0.93, 1.0) * smoothstep(0.99935, 0.9996, md) * 3.5 * night;
	}

	if (d.y > 0.0) {
		vec2 uv = d.xz / (d.y + 0.14) * 0.85;
		float dens = cumulus(uv * 1.15);
		float c = smoothstep(1.0 - cloud_cover, 1.0 - cloud_cover + 0.3, dens);
		// light comes from the sun's side: a cloud is bright where the density falls off toward the sun
		float toward = cumulus(uv * 1.15 + sd_v.xz * 0.05);
		float lit = clamp(0.5 + (dens - toward) * 7.0, 0.0, 1.0);
		lit = mix(lit, 1.0, 0.25 * (1.0 - c));                         // thin edges are always brighter
		float rim = c * (1.0 - c) * 4.0;                               // silver lining where the sun is behind the cloud
		vec3 ccol = mix(cloud_shade, cloud_lit, lit);
		ccol += sun_col * rim * pow(sd, 5.0) * 0.9 * (1.0 - night);
		float horizon_fade = smoothstep(0.0, 0.16, d.y);
		// high thin streaks
		float cir = fbm(vec2(uv.x * 0.35, uv.y * 1.9) + vec2(cloud_time * 0.35, 3.0));
		cir = smoothstep(0.52, 0.85, cir) * 0.4 * (1.0 - c) * smoothstep(0.03, 0.3, d.y);
		vec3 cir_col = mix(cloud_shade, cloud_lit, 0.85);
		col = mix(col, cir_col, cir);
		col = mix(col, ccol, c * 0.96 * horizon_fade);
		col += sun_col * smoothstep(0.9992, 0.9998, sd) * 14.0 * (1.0 - night) * (1.0 - c * 0.9);
	} else {
		col = mix(horizon_col * 0.85, horizon_col * 0.25, smoothstep(0.0, 0.4, -d.y));
	}
	COLOR = col;
}
