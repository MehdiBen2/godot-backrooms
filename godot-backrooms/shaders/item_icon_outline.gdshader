shader_type canvas_item;
// Inventory item icon (scripts/UI/inventory/item_icon.gd): the model rendered into a transparent
// SubViewport, with a solid rim traced around its silhouette. The rim is measured in screen pixels
// (fwidth(UV)), so it stays the same weight whether the icon is drawn small on an INV row or large
// on the item record. A 3D render into a transparent viewport comes out premultiplied (it
// composites over transparent black), so this blends premultiplied too.
render_mode blend_premul_alpha;

uniform vec4 outline_color : source_color = vec4(0.91, 0.44, 0.17, 1.0);
uniform float outline_px = 3.0;   // rim width, screen pixels
uniform float fill_tint = 0.12;   // pull the model's colours toward the rim colour, so it sits in the amber UI

const int DIRS = 16;

varying vec4 modulate;   // fragment() COLOR arrives already multiplied by the texture

void vertex() {
	modulate = COLOR;
}

void fragment() {
	vec4 col = texture(TEXTURE, UV);
	vec2 r = fwidth(UV) * outline_px;
	float a = 0.0;
	for (int i = 0; i < DIRS; i++) {
		float ang = TAU * float(i) / float(DIRS);
		vec2 d = vec2(cos(ang), sin(ang));
		a = max(a, texture(TEXTURE, UV + d * r).a);
		a = max(a, texture(TEXTURE, UV + d * r * 0.5).a);
	}
	a = smoothstep(0.05, 0.5, a) * outline_color.a;
	vec3 body = mix(col.rgb, outline_color.rgb * dot(col.rgb, vec3(0.299, 0.587, 0.114)) * 1.6, fill_tint);
	COLOR = vec4(body + outline_color.rgb * a * (1.0 - col.a), col.a + a * (1.0 - col.a)) * modulate.a;
}
