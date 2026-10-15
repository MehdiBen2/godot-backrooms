// The T.S.R.A. launch panel's little LCD (scripts/World/props/tsra_emergency_panel.gd). A next pass over the panel
// mesh: everything outside the screen's rectangle on the texture atlas is discarded, inside it draws the screen.
// The atlas is stored upside down (the model reads it flipped vertically), so the screen's top is the rect's bottom.
//
// Layout: the agency emblem (textures/ui/tsra_logo.png, the terminal's pixel art, kept square) on the left; on the
// right the "T.S.R.A." wordmark, the status line and the charge bar.
// boot   0 -> 1: off, a line opens out of the middle, the emblem wipes in from the top
// state  0 standby ("STANDBY"), 1 a hand near the lever ("PULL LEVER", blinking), 2 charging (the bar fills with
//        `charge`, light beats faster through the split between the shards), 3 open (a flash, then steady)
// Text lines are rows of textures/tsra/tsra_screen_status.png (the last row is the wordmark), typed on.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled;

uniform vec4 screen_rect = vec4(0.41797, 0.75586, 0.53906, 0.81836);   // uv x0 y0 x1 y1 (tools/make_tsra_branding.py)
uniform vec2 screen_px = vec2(124.0, 64.0);                              // its size on the atlas: the LCD's pixel grid
uniform sampler2D logo_tex : source_color, filter_nearest, repeat_disable;
uniform sampler2D status_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform int status_rows = 5;
uniform float status_aspect = 5.333;  // one row's width / height
uniform int state = 0;
uniform float state_time = 0.0;      // s since the state began
uniform float boot = 1.0;
uniform float charge = 0.0;
uniform vec3 ink : source_color = vec3(0.941, 0.659, 0.22);
uniform vec3 bg : source_color = vec3(0.022, 0.026, 0.03);
uniform float energy = 1.5;          // > 1 so the screen catches the glow
uniform float lift = 0.0003;         // m off the panel's own surface

void vertex() {
	VERTEX += NORMAL * lift;
}

float inside(vec2 p) {
	return step(0.0, p.x) * step(p.x, 1.0) * step(0.0, p.y) * step(p.y, 1.0);
}

void fragment() {
	vec2 s = (UV - screen_rect.xy) / (screen_rect.zw - screen_rect.xy);
	if (s.x < 0.0 || s.x > 1.0 || s.y < 0.0 || s.y > 1.0) {
		discard;
	}
	s.y = 1.0 - s.y;
	float aspect = screen_px.x / screen_px.y;
	float t = TIME;

	// ---- the emblem: a square on the left, wiping in from the top once the tube is open
	float logo_h = 0.84;
	vec2 lp = vec2((s.x - 0.05) * aspect / logo_h, (s.y - 0.08) / logo_h);
	float wipe = smoothstep(0.55, 1.0, boot) * 1.15;
	vec4 lg = texture(logo_tex, lp) * inside(lp) * step(lp.y, wipe);
	float edge = smoothstep(0.06, 0.0, abs(lp.y - wipe)) * step(wipe, 1.1) * inside(lp) * 0.5;

	// light through the split between the shards: breathes, races while charging, burns once open
	float beat = 0.3 + 0.2 * sin(t * 1.8);
	if (state == 2) {
		beat = 0.55 + 0.45 * sin(t * (5.0 + 22.0 * charge));
	} else if (state == 3) {
		beat = 1.0 + 0.08 * sin(t * 31.0);
	}
	vec2 rd = (lp - vec2(0.5, 0.49)) * vec2(9.0, 1.25);
	float rift = exp(-dot(rd, rd) * 2.5) * beat * wipe;

	// ---- the right column: wordmark, status (typed on, blinking while it asks for the lever), charge bar
	float col_x = 0.52;
	float col_w = 0.44;
	float row_h = col_w * aspect / status_aspect;
	vec2 wp = vec2((s.x - col_x) / col_w, (s.y - 0.20) / row_h);
	float word = texture(status_tex, vec2(wp.x, (float(status_rows - 1) + clamp(wp.y, 0.0, 1.0)) / float(status_rows))).a * inside(wp);
	word *= step(wp.x, (boot - 0.85) * 8.0);
	vec2 sp = vec2((s.x - col_x) / col_w, (s.y - 0.46) / row_h);
	int row = clamp(state, 0, status_rows - 2);
	float status = texture(status_tex, vec2(sp.x, (float(row) + clamp(sp.y, 0.0, 1.0)) / float(status_rows))).a * inside(sp);
	status *= step(sp.x, state_time * 1.6) * step(0.98, boot) * 0.8;
	if (state == 1) {
		status *= step(0.35, fract(t * 1.4));
	}
	float bar_on = (state == 2) ? charge : (state == 3 ? 1.0 : 0.0);
	vec2 bp = vec2((s.x - col_x) / col_w, (s.y - 0.72) / 0.07);
	float bar = inside(bp) * step(bp.x, bar_on);
	float frame = inside(bp) * (1.0 - step(0.03, bp.x) * step(bp.x, 0.97) * step(0.15, bp.y) * step(bp.y, 0.85)) * (state >= 2 ? 1.0 : 0.0);

	float lit = word + status + bar + 0.5 * frame;
	vec3 col = bg + lg.rgb * lg.a * 1.1 + ink * lit + ink * rift * 0.4 + ink * edge;

	// scan sweep every 5 s, the open flash
	col += ink * 0.12 * smoothstep(0.08, 0.0, abs(s.y - (fract(t / 5.0) * 1.4 - 0.2)));
	if (state == 3) {
		col = mix(col, ink * 1.8, clamp(1.0 - state_time / 0.35, 0.0, 1.0));
	}

	// ---- LCD: pixel grid, a faint flicker
	vec2 cell = fract(s * screen_px);
	float grid = 0.8 + 0.2 * step(0.18, cell.x) * step(0.18, cell.y);
	col *= grid * (0.97 + 0.03 * sin(t * 57.0));

	// ---- boot: a hot line widening across the middle, then opening up
	float bx = clamp(boot / 0.25, 0.0, 1.0);
	float by = clamp((boot - 0.25) / 0.3, 0.0, 1.0);
	float open_area = step(abs(s.x - 0.5), bx * 0.5) * step(abs(s.y - 0.5), max(by * 0.5, 0.025));
	col = mix(ink * 1.6, col, by) * open_area + bg * 0.4 * (1.0 - open_area);

	ALBEDO = col * energy;
	ALPHA = 1.0;
}
