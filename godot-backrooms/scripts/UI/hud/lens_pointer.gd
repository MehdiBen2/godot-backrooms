extends RefCounted
## Where on the 3D render the mouse cursor really points. The camera shader (shaders/render/camera.gdshader) bends the
## picture through a barrel "fish eye" lens (plus zoom and skew), so a pixel of the screen shows a different
## spot of the undistorted render. This runs the shader's screen -> render mapping for the cursor, so a
## camera ray through the result lands on what is under the cursor. Used by the draw tools (draw_ui.gd).

static func render_pos(vp: Viewport) -> Vector2:
	return screen_to_render(vp.get_mouse_position(), vp)

static func screen_to_render(mouse: Vector2, vp: Viewport) -> Vector2:
	var size := vp.get_visible_rect().size
	var mat: ShaderMaterial = Gfx.post_mat
	if mat == null or size.x < 1.0 or size.y < 1.0:
		return mouse
	var dist := _param(mat, "distortion", 0.30)
	var chroma_amt := _param(mat, "chroma_amt", 0.0028)
	var aspect := size.x / size.y
	var uv := mouse / size
	uv = (uv - Vector2(0.5, 0.5)) / (Game.fx_zoom + Game.fx_shock * 0.07) + Vector2(0.5, 0.5)
	uv.x -= tan(deg_to_rad(Game.fx_skew)) * (uv.y - 0.5) * 0.5
	var p := uv - Vector2(0.5, 0.5)
	p.x *= aspect
	var r2 := p.dot(p)
	var max_r2 := 0.25 * (aspect * aspect + 1.0)
	dist *= 1.0 - 0.6 * Game.fx_classic
	var zoom := 1.0 + max_r2 * (dist + chroma_amt) * 1.05
	var f := (1.0 + r2 * dist) / zoom
	var q := p * f
	q.x /= aspect
	return (q + Vector2(0.5, 0.5)) * size

static func _param(mat: ShaderMaterial, name: String, fallback: float) -> float:
	var v = mat.get_shader_parameter(name)
	return float(v) if v != null else fallback
