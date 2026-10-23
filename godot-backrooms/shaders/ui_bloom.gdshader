shader_type canvas_item;
// One pass of the inventory terminal's bloom (inventory.gd _bloom_pass): a 13-tap Gaussian along
// `direction`, run twice at half resolution, horizontal then vertical over the first pass's result.
// The first pass (bright_pass) keeps only what should glow: the amber lines, bar segments, icons and
// text, not the dark panel fills. ui_vhs_overlay.gdshader adds the result back over the terminal.
// TEXTURE is premultiplied colour (a transparent SubViewport), so the glow carries its own coverage.
// Downscaling by 2 puts each output pixel's centre on (about) a 2x2 texel corner, so the bilinear
// taps average every source texel and no thin line slips between them.
uniform vec2 direction = vec2(1.0, 0.0);
uniform float spacing = 2.0;        // source texels between taps: the glow's reach / 6
uniform bool bright_pass = false;
uniform float threshold = 0.3;      // brightest channel (premultiplied) where glow starts

const float SIGMA = 2.6;            // in taps
const float WEIGHT_SUM = 6.43976;   // sum of exp(-0.5 (k / SIGMA)^2), k = -6..6

void fragment() {
	vec2 stp = direction * TEXTURE_PIXEL_SIZE * spacing;
	vec3 acc = vec3(0.0);
	for (int k = -6; k <= 6; k++) {
		vec3 s = texture(TEXTURE, UV + stp * float(k)).rgb;
		if (bright_pass) {
			s *= smoothstep(threshold, threshold + 0.45, max(s.r, max(s.g, s.b)));
		}
		float fk = float(k) / SIGMA;
		acc += s * exp(-0.5 * fk * fk);
	}
	COLOR = vec4(acc / WEIGHT_SUM, 1.0);
}
