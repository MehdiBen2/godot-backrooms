extends Node

const LensPointer := preload("res://scripts/UI/hud/lens_pointer.gd")

var player: Node
var ui

var drawing := false
var p1_2d := Vector2.ZERO
var p2_2d := Vector2.ZERO
var preview_rect: ColorRect
var ui_down := false

func _ready() -> void:
	var canvas = CanvasLayer.new()
	canvas.layer = 50
	add_child(canvas)
	preview_rect = ColorRect.new()
	preview_rect.color = Color(0.8, 0.2, 1.0, 0.3)
	preview_rect.visible = false
	canvas.add_child(preview_rect)

func _cursor() -> bool:
	return ui != null and ui.cursor_mode

func _process(dt: float) -> void:
	var can: bool = player != null and Game.playing and not Game.dead and not player.dead
	var pen_down: bool = can and _cursor() and ui.tool == "portal" and ui_down
	
	if pen_down:
		var m := LensPointer.render_pos(player.cam.get_viewport())
		if not drawing:
			drawing = true
			p1_2d = m
			preview_rect.visible = true
		p2_2d = m
		
		# Update preview rect
		var min_x = minf(p1_2d.x, p2_2d.x)
		var max_x = maxf(p1_2d.x, p2_2d.x)
		var min_y = minf(p1_2d.y, p2_2d.y)
		var max_y = maxf(p1_2d.y, p2_2d.y)
		preview_rect.position = Vector2(min_x, min_y)
		preview_rect.size = Vector2(max_x - min_x, max_y - min_y)
	else:
		if drawing:
			_finish()
		drawing = false
		preview_rect.visible = false

func _aim(m: Vector2) -> Dictionary:
	var cam: Camera3D = player.cam
	var from = cam.project_ray_origin(m)
	var dir = cam.project_ray_normal(m)
	var q = PhysicsRayQueryParameters3D.create(from, from + dir * 100.0, 1) # WORLD_MASK
	q.exclude = [player.get_rid()]
	return player.get_world_3d().direct_space_state.intersect_ray(q)

func _finish() -> void:
	if p1_2d.distance_to(p2_2d) < 10.0: return # Too small
	
	var hit1 = _aim(p1_2d)
	var hit2 = _aim(p2_2d)
	
	if hit1.is_empty() or hit2.is_empty(): return
	
	var pos1: Vector3 = hit1.position
	var pos2: Vector3 = hit2.position
	var n: Vector3 = hit1.normal
	
	if n.dot(hit2.normal) < 0.9: return # Must be on the same flat surface
	
	var center = (pos1 + pos2) * 0.5
	center += n * 0.05 # Lift it slightly off the wall
	
	var portal_mesh = QuadMesh.new()
	var diff = pos2 - pos1
	var up = Vector3.UP
	if absf(n.y) > 0.9:
		up = Vector3.RIGHT
	var right = up.cross(n).normalized()
	up = n.cross(right).normalized()
	
	var width = absf(diff.dot(right))
	var height = absf(diff.dot(up))
	if width < 0.2 or height < 0.2: return
	
	portal_mesh.size = Vector2(width, height)
	
	var mi = MeshInstance3D.new()
	mi.mesh = portal_mesh
	
	var mat = ShaderMaterial.new()
	var shader = Shader.new()
	shader.code = """
	shader_type spatial;
	render_mode unshaded, cull_disabled;
	
	uniform vec3 color1 : source_color = vec3(1.0, 0.9, 0.2); // Core Bright Yellow
	uniform vec3 color2 : source_color = vec3(0.5, 0.7, 0.1); // Mid Green/Yellow
	uniform vec3 color3 : source_color = vec3(0.05, 0.1, 0.05); // Deep Void Dark Green
	uniform float time_scale = 0.3;
	
	vec2 hash( vec2 p ) {
		p = vec2( dot(p,vec2(127.1,311.7)), dot(p,vec2(269.5,183.3)) );
		return -1.0 + 2.0*fract(sin(p)*43758.5453123);
	}
	
	float noise( in vec2 p ) {
		const float K1 = 0.366025404; 
		const float K2 = 0.211324865; 
		vec2 i = floor( p + (p.x+p.y)*K1 );
		vec2 a = p - i + (i.x+i.y)*K2;
		vec2 o = (a.x>a.y) ? vec2(1.0,0.0) : vec2(0.0,1.0);
		vec2 b = a - o + K2;
		vec2 c = a - 1.0 + 2.0*K2;
		vec3 h = max( 0.5-vec3(dot(a,a), dot(b,b), dot(c,c) ), 0.0 );
		vec3 n = h*h*h*h*vec3( dot(a,hash(i+0.0)), dot(b,hash(i+o)), dot(c,hash(i+1.0)));
		return dot( n, vec3(70.0) );
	}
	
	float fbm(vec2 p) {
		float f = 0.0;
		float w = 0.5;
		for (int i = 0; i < 4; i++) {
			f += w * noise(p);
			p *= 2.0;
			w *= 0.5;
		}
		return f;
	}
	
	void fragment() {
		vec2 uv = UV * 2.0 - 1.0; 
		float t = TIME * time_scale;
		
		// Parallax offset (gives the 3D depth effect as the player moves)
		vec2 view_offset = VIEW.xy * 0.5;
		
		// Three layers of depth for true 3D volumetric feel
		float n1 = fbm(uv * 1.5 + view_offset * 1.0 + vec2(t * 0.4, -t * 0.2));
		float n2 = fbm(uv * 3.0 + view_offset * 0.5 + vec2(-t * 0.6, t * 0.4));
		float n3 = fbm(uv * 6.0 + vec2(t * 0.8, t * 0.8));
		
		float n = (n1 * 0.5 + n2 * 0.3 + n3 * 0.2) * 0.5 + 0.5;
		
		// High frequency grain texture
		float grain = fbm(uv * 20.0 + t * 5.0);
		n = mix(n, grain * 0.5 + 0.5, 0.05);
		
		// Map colors to the noise density
		vec3 col = mix(color3, color2, smoothstep(0.2, 0.55, n));
		col = mix(col, color1, smoothstep(0.55, 0.8, n));
		
		// Deep dark swirling pits (giving infinite black depth)
		if (n < 0.35) {
			col *= smoothstep(0.1, 0.35, n);
		}
		
		// Burning bright highlights over-exposing the camera
		if (n > 0.75) {
			col += vec3(1.0, 1.0, 0.8) * pow(n - 0.75, 2.0) * 15.0;
		}
		
		// Edge darkening (Vignette to make it look like a deep tunnel into the wall)
		float edge = max(abs(uv.x), abs(uv.y)); 
		float vignette = smoothstep(1.0, 0.6, edge);
		col *= mix(0.1, 1.0, vignette); // Edges fade to dark inside the frame
		
		ALBEDO = col;
	}
	"""
	mat.shader = shader
	mat.render_priority = -1 # Render behind tape and cables
	mi.material_override = mat
	
	# Move the portal surface extremely close to the wall (0.001) so tape (0.003+) draws over it
	center -= n * 0.049
	
	# 3D Frame around the portal
	var frame_mat = StandardMaterial3D.new()
	frame_mat.albedo_color = Color(0.1, 0.1, 0.1)
	frame_mat.roughness = 0.9
	
	var frame_thickness = 0.1
	var frame_depth = 0.2
	
	for d in [
		[Vector3(0, height/2.0 + frame_thickness/2.0, 0), Vector3(width + frame_thickness*2, frame_thickness, frame_depth)], # Top
		[Vector3(0, -height/2.0 - frame_thickness/2.0, 0), Vector3(width + frame_thickness*2, frame_thickness, frame_depth)], # Bottom
		[Vector3(width/2.0 + frame_thickness/2.0, 0, 0), Vector3(frame_thickness, height, frame_depth)], # Right
		[Vector3(-width/2.0 - frame_thickness/2.0, 0, 0), Vector3(frame_thickness, height, frame_depth)] # Left
	]:
		var fm = MeshInstance3D.new()
		var bx = BoxMesh.new()
		bx.size = d[1]
		fm.mesh = bx
		fm.material_override = frame_mat
		fm.position = d[0] + Vector3(0, 0, -frame_depth/2.0) # Stick out into the room (since -Z points out)
		mi.add_child(fm)
	
	var light = OmniLight3D.new()
	light.light_color = Color(0.95, 0.85, 0.15)
	light.light_energy = 4.0
	light.omni_range = maxf(width, height) * 4.0
	light.position = Vector3(0, 0, -0.5) 
	mi.add_child(light)
	
	var level = player.get_parent().get_node_or_null("Level")
	if level != null:
		level.add_child(mi)
		mi.global_position = center
		mi.look_at(center - n, up)
		active_portals.append(mi)

var active_portals := []

func undo() -> bool:
	if active_portals.is_empty(): return false
	var p = active_portals.pop_back()
	if is_instance_valid(p):
		p.queue_free()
	return true

func remove_near(pos: Vector3, radius: float) -> void:
	for i in range(active_portals.size() - 1, -1, -1):
		var p = active_portals[i]
		if is_instance_valid(p):
			if p.global_position.distance_to(pos) < radius:
				p.queue_free()
				active_portals.remove_at(i)
