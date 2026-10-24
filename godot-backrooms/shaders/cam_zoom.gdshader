shader_type canvas_item;
// The camcorder raised to the eye (scripts/Player/zoom_tool.gd, drawn by scripts/UI/hud/zoom_readout.gd).
// It reads the finished picture (the post pass is under it) and adds what looking through a zoom lens does:
// - out of focus: `lod` is the autofocus's error as a mip level, so the picture softens while the lens hunts
// - the electronic sharpening halo a camcorder puts on edges, which a soft picture loses
// - colour fringing toward the rim, more the longer the lens
// - the telephoto's small aperture: darker, so the gain comes up and the picture goes grainy
// - the eyepiece: corners falling into shadow, fine interlace lines
// - `anomaly` (0..1): something that should not be there is in the lens. The tape misbehaves in short
//   bursts rather than all the time: a few bands of lines tear sideways, red and blue slip apart, blocks
//   of the picture drop out or come back with the wrong colours, the level flickers. Kept low so it is
//   felt before it is understood.
// `amount` fades it all in with the raise.
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform float zoom = 1.0;
uniform float lod = 0.0;
uniform float anomaly : hint_range(0.0, 1.0) = 0.0;
uniform float aspect = 1.7778;

float h(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }

void fragment() {
	float stops = log2(max(zoom, 1.0));
	vec2 uv = SCREEN_UV;
	// the glitch comes in bursts: a gate that opens for a few frames now and then, more often the stronger
	float step_t = floor(TIME * 12.0);
	float gate = step(1.0 - (0.10 + 0.45 * anomaly), h(vec2(floor(TIME * 3.0), 3.7))) * step(0.02, anomaly);
	float row = floor(uv.y * 90.0);
	float band = step(0.93 - 0.12 * anomaly, h(vec2(row, step_t))) * gate;
	uv.x += (h(vec2(row, step_t + 1.0)) - 0.5) * 0.05 * anomaly * band;
	// blocks drop out (frozen to the block's own average) or come back with the channels swapped
	vec2 blk = floor(uv * vec2(24.0, 14.0));
	float bh = h(blk + step_t * 0.37);
	float drop = step(1.0 - 0.05 * anomaly * gate, bh);
	vec2 p = SCREEN_UV - 0.5;
	vec2 pa = vec2(p.x * aspect, p.y);
	float r2 = dot(pa, pa);
	float soft = lod + r2 * (0.5 + 0.1 * stops) + drop * 3.0;
	vec2 rim = p * (0.0012 + 0.0016 * stops) * (0.4 + r2 * 3.0);
	rim.x += anomaly * (0.0015 + 0.004 * gate);                   // red and blue slipping apart
	vec3 c = vec3(
		textureLod(screen_tex, uv + rim, soft).r,
		textureLod(screen_tex, uv, soft).g,
		textureLod(screen_tex, uv - rim, soft).b);
	// the sharpening halo: gone when the lens is far out of focus
	vec3 bl = textureLod(screen_tex, uv, soft + 1.6).rgb;
	c += (c - bl) * 0.4 * (1.0 - clamp(lod * 0.45, 0.0, 1.0));
	c = mix(c, c.gbr, drop * step(0.5, h(blk + 9.1)) * 0.8);       // wrong colours in the dropped blocks
	// small aperture, gain up: a touch darker and flatter, noisier
	c *= 1.0 - 0.05 * stops;
	c = (c - 0.5) * (1.0 + 0.04 * stops) + 0.5;
	float tick = floor(TIME * 24.0);
	c += (h(FRAGCOORD.xy + tick * 7.13) - 0.5) * (0.02 + 0.035 * stops + 0.05 * anomaly);
	c *= 1.0 + anomaly * (h(vec2(step_t, 5.3)) - 0.5) * 0.16 * (0.4 + gate);   // the level flickers
	// the eyepiece
	c *= 1.0 - 0.55 * smoothstep(0.5, 1.15, sqrt(r2) * (1.0 + 0.05 * stops));
	c *= 1.0 - 0.05 * step(mod(FRAGCOORD.y, 2.0), 1.0);
	COLOR = vec4(max(c, vec3(0.0)), amount);
}
