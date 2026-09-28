extends RefCounted
## Inventory icons rendered from an item's 3D model: the .glb is set up in its own little world
## (own_world_3d SubViewport, transparent background, orthographic 3/4 camera, key + fill light),
## framed to fit, drawn for a few frames and then frozen, so the icon costs nothing afterwards.
## One viewport per model, shared by every row / page that shows it.
## Show the texture through outlined() (shaders/item_icon_outline.gdshader) for the orange rim.
## The "model" is a scene (.glb / .tscn), or a script that builds its Node3D in _init
## (World/props/tape_roll.gd).

const SIZE := 256                  # icon resolution, px
const FILL := 0.86                 # share of the frame the model spans, leaving room for the outline
const VIEW_DIR := Vector3(0.9, 0.75, 1.25)   # camera direction from the model: a 3/4 view from above
const OUTLINE_SHADER := preload("res://shaders/item_icon_outline.gdshader")
const OUTLINE := Color("e8702c")   # inventory.gd ORANGE

static var cache := {}             # model path -> ViewportTexture
static var host: Node              # keeps the viewports in the tree (the main viewport's root)

static func texture(model_path: String) -> Texture2D:
	if model_path == "" or not ResourceLoader.exists(model_path):
		return null
	if cache.has(model_path) and is_instance_valid(host):
		return cache[model_path]
	if not is_instance_valid(host):
		cache.clear()
		host = Node.new()
		host.name = "ItemIcons"
		(Engine.get_main_loop() as SceneTree).root.add_child.call_deferred(host)
	var vp := _build(model_path)
	host.add_child(vp)
	cache[model_path] = vp.get_texture()
	return cache[model_path]

## A TextureRect showing the icon with its outline, `px` wide, the rim `rim_px` screen pixels
static func outlined(model_path: String, px: float, color := OUTLINE, rim_px := 3.0) -> TextureRect:
	var r := TextureRect.new()
	r.texture = texture(model_path)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.custom_minimum_size = Vector2(px, px)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = OUTLINE_SHADER
	mat.set_shader_parameter("outline_color", color)
	mat.set_shader_parameter("outline_px", rim_px)
	r.material = mat
	return r

static func _build(model_path: String) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = Vector2i(SIZE, SIZE)
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.68, 0.64)
	env.ambient_light_energy = 1.2
	we.environment = env
	vp.add_child(we)

	var key := DirectionalLight3D.new()
	key.rotation = Vector3(deg_to_rad(-50), deg_to_rad(35), 0)
	key.light_energy = 2.2
	vp.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation = Vector3(deg_to_rad(-15), deg_to_rad(-140), 0)
	fill.light_energy = 0.8
	fill.light_color = Color(1.0, 0.85, 0.65)
	vp.add_child(fill)

	# the model, scaled to 1 m along its longest side and centred on the origin
	var model := instantiate(model_path)
	vp.add_child(model)
	var box := mesh_aabb(model, Transform3D.IDENTITY)
	var longest := maxf(box.size.x, maxf(box.size.y, box.size.z))
	var k := 1.0 / longest if longest > 0.0 else 1.0
	model.scale = Vector3.ONE * k
	model.position = -box.get_center() * k
	box = AABB((box.position - box.get_center()) * k, box.size * k)

	# orthographic camera, sized and shifted so the model's projected outline fills FILL of the frame
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	vp.add_child(cam)
	var dir := VIEW_DIR.normalized()
	cam.transform = Transform3D(Basis.looking_at(-dir, Vector3.UP), dir * 5.0)   # not in the tree yet: no look_at()
	var bx := cam.transform.basis.x
	var by := cam.transform.basis.y
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for i in 8:
		var p := box.get_endpoint(i)
		var q := Vector2(p.dot(bx), p.dot(by))
		lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
		hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))
	var mid := (lo + hi) * 0.5
	cam.position += bx * mid.x + by * mid.y
	cam.size = maxf(hi.x - lo.x, hi.y - lo.y) / FILL
	cam.near = 0.05
	cam.far = 20.0
	cam.current = true

	_freeze(vp)
	return vp

## Draw a few frames (materials settle, MSAA resolves), then stop rendering; the texture keeps the
## last image
static func _freeze(vp: SubViewport) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	for i in 4:
		await tree.process_frame
	if is_instance_valid(vp):
		vp.render_target_update_mode = SubViewport.UPDATE_DISABLED

## The item's model as a node: a scene instanced, or a model script (see the top) made
static func instantiate(model_path: String) -> Node3D:
	var res := load(model_path)
	if res is Script:
		return (res as Script).new()
	return (res as PackedScene).instantiate()

static func mesh_aabb(n: Node, xf: Transform3D) -> AABB:
	var out := AABB()
	var first := true
	var t: Transform3D = xf
	if n is Node3D:
		t = xf * (n as Node3D).transform
	var mi := n as MeshInstance3D
	if mi and mi.mesh:
		out = t * mi.mesh.get_aabb()
		first = false
	for ch in n.get_children():
		var sub := mesh_aabb(ch, t)
		if sub.size == Vector3.ZERO: continue
		out = sub if first else out.merge(sub)
		first = false
	return out
