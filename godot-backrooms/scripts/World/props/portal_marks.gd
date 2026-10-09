extends Node3D
## Every custom threshold portal placed on this level's walls.
## Portals are permanent spatial doorways (swirling reality tears with volumetric 3D parallax,
## dual-stage dynamic projection lighting, and spatial audio).
## Saved per level in levels/marks/<level_id>.json under "portals" via mark_store.gd.

const MarkStore := preload("res://scripts/World/props/mark_store.gd")

static var placed := {}              # MarkStore.key() -> Array of portal dictionaries
static var live = null
static var _loaded := {}
static var _shader: Shader

var level_id := ""
var meshes := {}                     # id -> MeshInstance3D
var _undo: Array = []
var _redo: Array = []

func _ready() -> void:
	live = self
	_load()

func _exit_tree() -> void:
	if live == self:
		live = null

func count() -> int:
	return placed.get(MarkStore.key(), []).size()

func reload_floor() -> void:
	for m in meshes.values():
		if is_instance_valid(m):
			m.queue_free()
	meshes.clear()
	_undo.clear()
	_redo.clear()
	_load()

## Read this floor's saved portals into `placed`
func _load() -> void:
	MarkStore.use_level(get_parent())
	level_id = MarkStore.file_id(str(get_parent().level_meta.get("id", "")))
	var lv := MarkStore.key()
	if not _loaded.has(lv):
		_loaded[lv] = true
		if not placed.has(lv):
			placed[lv] = []
		var file := MarkStore.read(level_id)
		var off := MarkStore.moved(file, "portals")
		for d in file.get("portals", []):
			placed[lv].append({
				"id": str(d.get("id", "")),
				"pos1": MarkStore.v3(d.pos1) + off,
				"pos2": MarkStore.v3(d.pos2) + off,
				"n": MarkStore.v3(d.n),
				"t": float(d.get("t", 0.0))
			})
	_spawn_all(lv)

func _spawn_all(lv: int) -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	if not is_inside_tree() or lv != MarkStore.key():
		return
	_settle_all(lv)
	for p in placed.get(lv, []):
		if not meshes.has(p.id):
			_spawn(p)

func _settle_all(lv: int) -> void:
	var list: Array = placed.get(lv, [])
	var space := get_world_3d().direct_space_state
	var changed := false
	for p in list:
		var pts: Array = [p.pos1, p.pos2]
		var at := MarkStore.settle(space, pts, p.n)
		if not at.is_empty() and at.moved:
			p.pos1 = at.pts[0]
			p.pos2 = at.pts[1]
			p.n = at.n
			changed = true
			if meshes.has(p.id):
				var old_mi: Node = meshes[p.id]
				if is_instance_valid(old_mi):
					old_mi.queue_free()
				meshes.erase(p.id)
				_spawn(p)
	if changed:
		save()

static func get_portal_shader() -> Shader:
	if _shader != null:
		return _shader
	_shader = Shader.new()
	_shader.code = """
	shader_type spatial;
	render_mode unshaded, cull_disabled;
	
	uniform vec2 portal_size = vec2(1.0, 2.0);
	uniform float time_scale = 0.22;
	
	// Threshold Colors matching reference
	uniform vec3 col_core : source_color = vec3(1.2, 1.15, 0.95);    // Blinding white/cream hot core
	uniform vec3 col_radiant : source_color = vec3(1.0, 0.88, 0.32); // Radiant golden-yellow field
	uniform vec3 col_amber : source_color = vec3(0.82, 0.62, 0.12);   // Amber / mustard fluid structures
	uniform vec3 col_void : source_color = vec3(0.24, 0.18, 0.04);    // Deep void amber-olive tendrils
	
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
			p *= 2.02;
			w *= 0.5;
		}
		return f;
	}
	
	void fragment() {
		// Aspect-ratio corrected UV coordinates so portal dimensions don't stretch the pattern
		vec2 uv = (UV - 0.5) * portal_size;
		float t = TIME * time_scale;
		
		// Parallax perspective offset based on camera view angle
		vec2 view_offset = VIEW.xy * 0.45;
		
		// Layer coordinates with parallax depth
		vec2 uv_front = uv * 1.2 + view_offset * 0.15;
		vec2 uv_deep = uv * 1.2 + view_offset * 0.65;
		
		// Fluid domain warping for organic plasma / threshold tears
		vec2 q = vec2(
			fbm(uv_deep * 1.4 + vec2(t * 0.3, -t * 0.2)),
			fbm(uv_deep * 1.4 + vec2(-t * 0.2, t * 0.25))
		);
		
		vec2 r = vec2(
			fbm(uv_deep * 1.8 + 2.8 * q + vec2(t * 0.35, t * 0.1)),
			fbm(uv_deep * 1.8 + 2.8 * q + vec2(-t * 0.2, -t * 0.25))
		);
		
		// Multi-octave field
		float f = fbm(uv_deep * 1.6 + 3.2 * r) * 0.5 + 0.5;
		
		// High frequency grain & cellular texture
		float grain = fbm(uv_front * 8.0 + vec2(t * 0.8, -t * 0.6)) * 0.5 + 0.5;
		f = mix(f, grain, 0.08);
		
		// Color gradient matching Kane Pixels Threshold
		vec3 col = col_void;
		col = mix(col, col_amber, smoothstep(0.20, 0.42, f));
		col = mix(col, col_radiant, smoothstep(0.42, 0.68, f));
		col = mix(col, col_core, smoothstep(0.68, 0.92, f));
		
		// Threshold subtle electrical pulse
		float pulse = 1.0 + sin(t * 4.0) * 0.04 + sin(t * 9.3) * 0.02;
		
		// HDR boost for true bloom/glow
		col *= 1.9 * pulse;
		
		// Core blinding over-exposure
		if (f > 0.60) {
			float overexposure = smoothstep(0.60, 0.95, f);
			col += vec3(1.4, 1.35, 1.1) * overexposure * 2.2;
		}
		
		ALBEDO = col;
	}
	"""
	return _shader

func _spawn(p: Dictionary) -> MeshInstance3D:
	var pos1: Vector3 = p.pos1
	var pos2: Vector3 = p.pos2
	var n: Vector3 = p.n
	
	var diff = pos2 - pos1
	var up = Vector3.UP
	if absf(n.y) > 0.9:
		up = Vector3.RIGHT
	var right = up.cross(n).normalized()
	up = n.cross(right).normalized()
	
	var width = absf(diff.dot(right))
	var height = absf(diff.dot(up))
	if width < 0.2 or height < 0.2:
		return null
	
	var center = (pos1 + pos2) * 0.5
	# Move the portal surface extremely close to the wall (0.001) so tape (0.003+) draws over it
	center += n * 0.001
	
	var portal_mesh = QuadMesh.new()
	portal_mesh.size = Vector2(width, height)
	
	var mi = MeshInstance3D.new()
	mi.mesh = portal_mesh
	
	var mat = ShaderMaterial.new()
	mat.shader = get_portal_shader()
	mat.set_shader_parameter("portal_size", Vector2(width, height))
	mat.render_priority = -1 # Render behind tape and cables
	mi.material_override = mat
	
	# Realistic threshold doorway lighting:
	# 1) Main forward projection beam into the room (wide cone spanning carpet, walls and ceiling)
	var spot = SpotLight3D.new()
	spot.position = Vector3(0, 0, 0.15)
	spot.rotation.y = PI
	spot.spot_angle = 78.0
	spot.spot_attenuation = 1.0
	spot.spot_range = maxf(width, height) * 4.0 + 8.0
	spot.light_energy = 5.0
	spot.light_color = Color(1.0, 0.94, 0.65)
	spot.light_volumetric_fog_energy = 2.5
	spot.shadow_enabled = true
	spot.shadow_bias = 0.05
	mi.add_child(spot)
	
	# 2) Soft ambient doorway fill (illuminates tape border and wall surrounding the threshold)
	var omni = OmniLight3D.new()
	omni.position = Vector3(0, 0, 0.3)
	omni.omni_range = maxf(width, height) * 2.5 + 4.0
	omni.omni_attenuation = 1.4
	omni.light_energy = 2.5
	omni.light_color = Color(1.0, 0.90, 0.50)
	omni.light_volumetric_fog_energy = 1.5
	omni.shadow_enabled = false
	mi.add_child(omni)
	
	# 3) Low-frequency spatial portal hum audio
	var drone_stream = load("res://audio/drone.wav")
	if drone_stream != null:
		var sfx = AudioStreamPlayer3D.new()
		sfx.stream = drone_stream
		sfx.volume_db = -18.0
		sfx.pitch_scale = 0.85
		sfx.unit_size = 4.0
		sfx.max_distance = 12.0
		sfx.autoplay = true
		sfx.bus = "World"
		sfx.finished.connect(sfx.play)
		mi.add_child(sfx)
	
	add_child(mi)
	mi.global_position = center
	mi.look_at(center - n, up)
	meshes[p.id] = mi
	return mi

## Lay a portal on the surface between pos1 and pos2 facing normal n
func place(pos1: Vector3, pos2: Vector3, n: Vector3) -> Dictionary:
	var id := "%08x%08x" % [randi(), randi()]
	var p := {
		"id": id,
		"pos1": pos1,
		"pos2": pos2,
		"n": n,
		"t": Time.get_unix_time_from_system()
	}
	var lv := MarkStore.key()
	if not placed.has(lv):
		placed[lv] = []
	placed[lv].append(p)
	_undo.append({"kind": "add", "portal": p})
	_redo.clear()
	_spawn(p)
	save()
	return p

## Undo last placed portal
func undo() -> bool:
	if _undo.is_empty():
		return false
	var act: Dictionary = _undo.pop_back()
	if act.kind == "add":
		var p: Dictionary = act.portal
		_remove_id(p.id)
		_redo.append(act)
		save()
		return true
	return false

## Redo last undone portal
func redo() -> bool:
	if _redo.is_empty():
		return false
	var act: Dictionary = _redo.pop_back()
	if act.kind == "add":
		var p: Dictionary = act.portal
		var lv := MarkStore.key()
		if not placed.has(lv):
			placed[lv] = []
		placed[lv].append(p)
		_spawn(p)
		_undo.append(act)
		save()
		return true
	return false

## Remove portal(s) near a point (for eraser tool)
func remove_near(pos: Vector3, radius: float) -> int:
	var lv := MarkStore.key()
	var list: Array = placed.get(lv, [])
	var removed := 0
	for i in range(list.size() - 1, -1, -1):
		var p: Dictionary = list[i]
		var center = (p.pos1 + p.pos2) * 0.5
		if center.distance_to(pos) < radius or p.pos1.distance_to(pos) < radius or p.pos2.distance_to(pos) < radius:
			_remove_id(p.id)
			removed += 1
	if removed > 0:
		save()
	return removed

func _remove_id(id: String) -> void:
	if meshes.has(id):
		var mi: Node = meshes[id]
		if is_instance_valid(mi):
			mi.queue_free()
		meshes.erase(id)
	var lv := MarkStore.key()
	var list: Array = placed.get(lv, [])
	for i in range(list.size() - 1, -1, -1):
		if list[i].id == id:
			list.remove_at(i)

## Write this level's portals to disk (levels/marks/<level_id>.json)
func save() -> bool:
	level_id = MarkStore.file_id(str(get_parent().level_meta.get("id", "")))
	var out: Array = []
	for p in placed.get(MarkStore.key(), []):
		out.append({
			"id": p.id,
			"pos1": MarkStore.arr(p.pos1),
			"pos2": MarkStore.arr(p.pos2),
			"n": MarkStore.arr(p.n),
			"t": p.t
		})
	return MarkStore.write(level_id, "portals", out)
