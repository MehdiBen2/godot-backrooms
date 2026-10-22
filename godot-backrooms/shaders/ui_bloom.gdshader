shader_type canvas_item;
// Clean vanilla pass-through: UI bloom disabled
uniform vec2 direction = vec2(1.0, 0.0);
uniform float spacing = 2.0;
uniform bool bright_pass = false;
uniform float threshold = 0.3;

void fragment() {
	COLOR = vec4(0.0);
}
