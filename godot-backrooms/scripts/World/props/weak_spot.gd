extends Node3D
## A weak spot: a patch of wallpaper gone soft with water, bulging a little out of the wall and crazed with fine
## cracks. The level builder (spot = {id, key, cell, n, u, xf}) hangs one on a wall face and hands it the wallpaper
## quad that covers the hole (`skin`, the level's: hidden when it breaks, never freed or moved). Hold E at it for
## HOLD_T seconds and it cracks open in three stages, then gives: the paper and the board behind it burst in, dust
## puffs out, and there is a jagged hole with a big cavity behind it. You just walk in (the hole's plug collision goes,
## weak_spots.gd CAV_*); stand back inside it (further in than HIDE_X) and you are hidden like in the metal cabinet
## (player.hidden, player.hiding_in = this): THE TALL ONE cannot see you in there. No button, no animation: the world
## goes dull, the edges close in and your heart picks up the deeper you are and the nearer it is.
## Let go and the push you had made fades back after a moment (the cracks you made stay).
## Its own space: origin at the bottom centre of the hole, on the wall face (floor at y = 0), +X out of the wall into
## the room, -X into the wall, Y up. The hole is z -0.45..0.45, y 0..2.1.
## Online, one survivor breaking it breaks it for everyone (Net.send_weak_spot, net.gd _weak_rpc -> break_open(false));
## a spot already broken when the level is built starts broken, without the dust or the shake.

const WeakSpots := preload("res://scripts/World/level/weak_spots.gd")
const Tooltip := preload("res://scripts/World/props/interact_tooltip.gd")
# No sounds yet: the creak of the board as it gives and the crash of it going are left empty until there are good ones
const CRACK_SOUND := ""
const BREAK_SOUND := ""
const TELL_ALBEDO := "res://textures/weak_spot/tell_albedo.png"
const TELL_NORMAL := "res://textures/weak_spot/tell_normal.png"
const CRACKS := ["res://textures/weak_spot/crack_1.png", "res://textures/weak_spot/crack_2.png",
	"res://textures/weak_spot/crack_3.png"]
const RIM_MODEL := "res://models/props/weak_spot/weak_spot_rim.glb"            # node Rim, x -0.06..0.03
const DEBRIS_MODEL := "res://models/props/weak_spot/weak_spot_debris.glb"      # nodes Debris_0..N, on the floor in front
const HOLD_T := 2.0           # s of holding E to break it
const GRACE := 0.5            # s after you let go before the push fades
const DECAY := 0.08           # progress lost a second after that
const STAGES := [0.25, 0.55, 0.8]   # progress at which each crack stage shows
const REACH := 2.2            # metres from the wall face you can still push on it
const SHAKE_RANGE := 8.0      # m: nearer than this when it gives and your view shakes
const DECAL_SIZE := Vector3(1.2, 0.3, 2.4)     # wide, deep (along the wall's normal), tall
const DECAL_Y := 1.2
const FOV_IN := 6.0           # degrees narrower, all the way in
const EDGES := 0.3            # Game.fx_fade all the way in: the dark closing in round the view
const DEEP := 0.6             # m further in than HIDE_X the effects are full
const NEAR_RANGE := 26.0      # m: THE TALL ONE closer than this and your heart starts to go
const BAR := 10               # cells of the hold bar in the prompt
const PAPER := Color(0.72, 0.66, 0.46)          # placeholder colours (no models yet)
const BOARD := Color(0.22, 0.15, 0.09)
const DUST := Color(0.62, 0.58, 0.5)

var key := ""                 # the spot's key, the same on every machine (net.gd weak_broken)
var broken := false
var progress := 0.0           # 0..1: how far your holding has got
var bounds := AABB(Vector3(WeakSpots.CAV_X0, 0.0, -WeakSpots.CAV_HZ), Vector3(WeakSpots.CAV_X1 - WeakSpots.CAV_X0, WeakSpots.CAV_H, WeakSpots.CAV_HZ * 2.0))   # the cavity (tall_one.gd reads it)
var prop: Node3D              # ourselves: the "prop" tall_one.gd reads off player.hiding_in (+X out of the wall)
var skin: MeshInstance3D
var _spot := {}
var _stage := 0               # crack stages shown (0: none), never goes back
var _idle := 0.0              # s since you last held E
var _tell: Decal
var _crack: Decal
var _tip: Node3D
var _rim: Node3D              # the torn edge, hidden till it gives
var _debris: Node3D           # what falls out, hidden till then
var _zone: Area3D             # the deep part of the cavity: the player's body in it is hidden
var _in_zone := false
var _hid := false             # we set player.hidden
var _blocking := false        # we set player.torch_blocked
var _depth := 0.0             # 0..1 eased: how far in you are
var _fear := 0.0              # 0..1 eased: how near THE TALL ONE is
var _beat_t := 0.0

# the fallback textures, made once for every weak spot (only while the real ones are missing)
static var _fb_tell: Texture2D
static var _fb_cracks := {}
static var _fb_dot: Texture2D
# the models, read once for every weak spot (a .glb not imported yet is parsed from its file: that stalled the frame it broke on)
static var _models := {}

func setup(spot: Dictionary, p_skin: MeshInstance3D) -> void:
	_spot = spot
	prop = self
	process_priority = 100        # after the player: the fov is set over its own
	key = str(spot.get("key", ""))
	skin = p_skin
	add_to_group("weak_spots")    # net.gd _weak_rpc finds us here by key
	_build_decals()
	# everything the break shows is built now, at the level's build: on the frame it gave, the materials loading
	# and the meshes being made froze the game. The inside stays drawn behind the skin (so its shaders are ready).
	add_child(_wall_interior())
	_rim = _add_model(RIM_MODEL, "rim")
	_debris = _add_model(DEBRIS_MODEL, "debris")
	_debris.add_child(_dust_patch())     # (shown with the debris, when it gives)
	if _net_broken():             # someone broke it before we got here
		_break(false)
		return
	add_to_group("interactables") # the player's interact focus scans this group (player_body.gd _find_interactable_door)
	var tip := Tooltip.new()
	tip.name = "InteractTooltip"  # (hud.gd draws no prompt of its own for a prop with one: it showed twice)
	tip.height = 0.3
	add_child(tip)
	_tip = tip

func _net_broken() -> bool:
	if key.is_empty() or not ("weak_broken" in Net): return false
	var wb: Variant = Net.get("weak_broken")
	return wb is Dictionary and (wb as Dictionary).has(key)

# ---------------------------------------------------------------- interaction (player.gd)
func can_interact(from_pos: Vector3) -> bool:
	if broken or Game.dead or not Game.playing or not can_process() or not is_visible_in_tree(): return false
	var local := to_local(from_pos)
	if local.x < 0.05: return false                          # not from inside the wall
	return Vector2(local.x, local.z).length() < REACH

func get_interact_prompt() -> String:
	if progress <= 0.0: return "[HOLD E] BREAK THROUGH"
	var n := clampi(int(progress * BAR), 0, BAR)
	return "[HOLD E] [" + "|".repeat(n) + ".".repeat(BAR - n) + "]"

func get_interact_title() -> String:
	return "Soft wall"

func get_handle_global_pos() -> Vector3:
	return to_global(Vector3(0.0, 1.2, 0.0))

## The press itself (player.gd): holding is read in _process
func interact(_p: Node3D) -> bool:
	if broken: return false
	_idle = 0.0
	return true

# ---------------------------------------------------------------- holding E
func _process(delta: float) -> void:
	if broken:
		_hide_tick(delta)
		return
	var pl: Node = Game.player
	var focused: bool = pl != null and is_instance_valid(pl) and pl.get("focused_door") == self
	var held: bool = focused and Game.playing and not Game.dead and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED \
		and (Input.is_action_pressed("interact") or Input.is_physical_key_pressed(KEY_E))
	if held:
		_idle = 0.0
		progress = minf(1.0, progress + delta / HOLD_T)
	elif progress > 0.0:
		_idle += delta
		if _idle > GRACE: progress = maxf(0.0, progress - DECAY * delta)
	var s := 0
	for t in STAGES:
		if progress >= float(t): s += 1
	if s > _stage: _set_stage(s)
	if progress >= 1.0: break_open(true)

## The next crack stage: the board creaks, the paper splits a little further
func _set_stage(s: int) -> void:
	_stage = s
	if _crack != null:
		_crack.texture_albedo = _crack_tex(s)
		_crack.visible = true
	_sound(CRACK_SOUND, 0.9 + 0.1 * s)
	_shake(0.04 + 0.02 * s)

# ---------------------------------------------------------------- breaking
## Broken open: `local` when this player did it (the others are told), false when the network told us
func break_open(local: bool) -> void:
	if broken: return
	_break(true)
	if local and Net.has_method("send_weak_spot"): Net.call("send_weak_spot", key)

## The hole, the cavity and the hiding place. `fx`: the dust, the shake and the crash (not for one already broken)
func _break(fx: bool) -> void:
	broken = true
	progress = 1.0
	set_process(false)             # (back on when the player steps into the cavity)
	var plug = _spot.get("plug")
	if plug is CollisionShape3D and is_instance_valid(plug): (plug as CollisionShape3D).set_deferred("disabled", true)
	remove_from_group("interactables")
	if _tip != null and is_instance_valid(_tip): _tip.queue_free()
	_tip = null
	if skin != null and is_instance_valid(skin): skin.visible = false
	_spot["broken"] = true               # (the trim may be built after us: level_trim.gd reads it)
	var sk = _spot.get("skirt")          # the skirting across the patch (level_trim.gd _weak_skirt): it goes with the wall
	if sk is Node3D and is_instance_valid(sk): (sk as Node3D).visible = false
	# the stain and the cracks would land on the torn rim and the cavity too: the rim model has its own torn edge
	if _tell != null: _tell.visible = false
	if _crack != null: _crack.visible = false
	if _rim != null: _rim.visible = true
	if _debris != null: _debris.visible = true
	if fx:
		_dust()
		_shake(0.3)
		_sound(BREAK_SOUND, 1.0)
	_build_zone()

# ---------------------------------------------------------------- hiding in the cavity
## The trigger over the whole cavity: in it your torch stays down (no room to raise it, and nothing in there is
## meant to be seen); further in than HIDE_X you are hidden
func _build_zone() -> void:
	_zone = Area3D.new()
	_zone.name = "HideZone"
	_zone.collision_layer = 0
	_zone.collision_mask = 1               # the player's body (a CharacterBody3D on the default layer)
	_zone.monitorable = false
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	var x0 := WeakSpots.CAV_X0
	var x1 := 0.05                         # (from just outside the hole: the beam goes down as you step in)
	bs.size = Vector3(x1 - x0, WeakSpots.CAV_H, WeakSpots.CAV_HZ * 2.0)
	cs.shape = bs
	cs.position = Vector3((x0 + x1) * 0.5, WeakSpots.CAV_H * 0.5, 0.0)
	_zone.add_child(cs)
	add_child(_zone)
	_zone.body_entered.connect(_on_zone_entered)
	_zone.body_exited.connect(_on_zone_exited)

func _on_zone_entered(body: Node3D) -> void:
	if body != Game.player or Game.dead: return
	_in_zone = true
	set_process(true)

func _on_zone_exited(body: Node3D) -> void:
	if body == Game.player: _in_zone = false

## Hidden while the body is in the zone; the atmosphere eases in with how deep you are and out when you leave
func _hide_tick(delta: float) -> void:
	var pl: Node = Game.player
	if pl == null or not is_instance_valid(pl) or not (pl is Node3D) or Game.dead or bool(pl.get("dead")) or not can_process():
		_release()
		return
	var at := to_local((pl as Node3D).global_position)
	var deep := _in_zone and at.x < WeakSpots.HIDE_X
	if _in_zone != _blocking:
		_blocking = _in_zone
		pl.set("torch_blocked", _in_zone)
	if deep and not _hid:
		var other = pl.get("hiding_in")
		if other == null or not is_instance_valid(other):
			_hid = true
			pl.set("hidden", true)
			pl.set("hiding_in", self)
			_set_muffled(true)
	elif _hid and not deep:
		_unhide()
	var target := 0.0
	if _hid:
		target = smoothstep(WeakSpots.HIDE_X, WeakSpots.HIDE_X - DEEP, at.x)
		if absf(at.z) > WeakSpots.HOLE_W * 0.5 + 0.3: target = minf(1.0, target + 0.35)   # in a pocket beside the hole, out of its line
	_depth = lerpf(_depth, target, 1.0 - exp(-delta * 2.0))
	if _hid or _depth > 0.01:
		Game.fx_fade = EDGES * _depth
		var cam = pl.get("cam")
		var flat = pl.get("fov_flat")
		if cam is Camera3D and flat != null: (cam as Camera3D).fov = float(flat) - FOV_IN * _depth
		_tick_fear(delta, pl as Node3D)
	elif not _in_zone:
		_depth = 0.0
		_fear = 0.0
		set_process(false)

## How near THE TALL ONE is, eased, and the heart that goes with it
func _tick_fear(delta: float, pl: Node3D) -> void:
	var near := 0.0
	var tall: Node3D = Game.main.get_node_or_null("TallOne") if Game.main != null else null
	if _hid and tall != null and tall.visible and bool(tall.get("present")):
		near = clampf(1.0 - tall.global_position.distance_to(pl.global_position) / NEAR_RANGE, 0.0, 1.0)
	_fear = move_toward(_fear, near, delta * (0.8 if near > _fear else 0.25))
	if not _hid or _fear < 0.05: return
	_beat_t -= delta
	if _beat_t <= 0.0:
		_beat_t = lerpf(1.1, 0.42, _fear)
		var scares: Node = Game.main.get_node_or_null("Scares") if Game.main != null else null
		if scares != null: scares.heartbeat((0.35 + 0.65 * _fear) * _depth, 1.0 + 0.1 * _fear)

## No longer hidden (left, died, floor demoted, freed): gives the flags back if they are ours
func _unhide() -> void:
	if not _hid: return
	_hid = false
	var pl: Node = Game.player
	if pl != null and is_instance_valid(pl):
		if pl.get("hiding_in") == self:
			pl.set("hidden", false)
			pl.set("hiding_in", null)
		if not bool(pl.get("dead")) and not Game.dead: _set_muffled(false)

func _release() -> void:
	_unhide()
	if _blocking:
		_blocking = false
		var pl: Node = Game.player
		if pl != null and is_instance_valid(pl): pl.set("torch_blocked", false)
	_in_zone = false
	_depth = 0.0
	_fear = 0.0
	set_process(false)

func _set_muffled(on: bool) -> void:
	var au: Node = Game.main.get_node_or_null("Audio") if Game.main != null else null
	if au != null and au.has_method("set_muffled"): au.set_muffled(on)

func _exit_tree() -> void:
	if _hid or _blocking: _release()     # (a rebuild while you are in it: the torch and the flags are given back)

func _notification(what: int) -> void:
	if what == NOTIFICATION_DISABLED and broken: _release()

## The model (or its placeholder) added hidden, for the break to show
func _add_model(path: String, kind: String) -> Node3D:
	var m := _instance(path)
	if m == null:
		match kind:
			"rim": m = _placeholder_rim()
			_: m = _placeholder_debris()
	m.visible = false
	add_child(m)
	return m

## The view shakes for anyone near enough, a little less the further off
func _shake(amount: float) -> void:
	var pl: Node = Game.player
	if pl == null or not is_instance_valid(pl) or not pl.has_method("add_trauma") or not (pl is Node3D): return
	var from := to_global(Vector3(0.2, 1.1, 0.0))
	var d := (pl as Node3D).global_position.distance_to(from)
	if d > SHAKE_RANGE: return
	pl.call("add_trauma", amount * lerpf(1.0, 0.35, d / SHAKE_RANGE), from)

## A one-shot puff of plaster dust out of the hole, settling slowly
func _dust() -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.amount = 48
	p.lifetime = 1.5
	p.explosiveness = 0.85
	p.randomness = 0.4
	p.local_coords = false
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(0.08, 0.9, 0.38)
	p.direction = Vector3(1.0, 0.15, 0.0)
	p.spread = 55.0
	p.initial_velocity_min = 0.6
	p.initial_velocity_max = 2.0
	p.gravity = Vector3(0.0, -0.6, 0.0)
	p.damping_min = 1.5
	p.damping_max = 2.5
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.6
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, 0.4))
	grow.add_point(Vector2(1.0, 1.0))
	p.scale_amount_curve = grow
	var ramp := Gradient.new()
	ramp.set_color(0, Color(DUST, 0.55))
	ramp.set_color(1, Color(DUST, 0.0))
	p.color_ramp = ramp
	var quad := QuadMesh.new()
	quad.size = Vector2(0.35, 0.35)
	var mat := StandardMaterial3D.new()
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = _dot_tex()
	mat.roughness = 1.0
	quad.material = mat
	p.mesh = quad
	add_child(p)
	p.position = Vector3(0.12, 1.05, 0.0)
	p.emitting = true
	get_tree().create_timer(p.lifetime + 1.0).timeout.connect(p.queue_free)

## A sound at the hole (none yet: see CRACK_SOUND)
func _sound(path: String, pitch: float) -> void:
	if path == "" or not ResourceLoader.exists(path) or not is_inside_tree(): return
	var a := AudioStreamPlayer3D.new()
	a.stream = load(path)
	a.bus = "World"
	a.pitch_scale = pitch
	a.unit_size = 2.0
	a.max_distance = 40.0
	add_child(a)
	a.global_position = get_handle_global_pos()
	a.finished.connect(a.queue_free)
	a.play()

# ---------------------------------------------------------------- the tell and the cracks
## Two decals on the wall face: the stain and bulge you can spot it by, and the cracks your pushing opens up. A
## Decal projects along its own -Y: that points into the wall (our -X), its X along the wall to your right as you
## face it and its Z down, so the top of the texture is the top of the patch
func _build_decals() -> void:
	_tell = _decal()
	_tell.name = "Tell"
	_tell.texture_albedo = _load_tex(TELL_ALBEDO)
	if _tell.texture_albedo == null: _tell.texture_albedo = _fallback_tell()
	_tell.texture_normal = _load_tex(TELL_NORMAL)
	_crack = _decal()
	_crack.name = "Cracks"
	_crack.visible = false

func _decal() -> Decal:
	var d := Decal.new()
	d.size = DECAL_SIZE
	d.normal_fade = 0.5           # not onto the floor or the side walls
	d.upper_fade = 0.2
	d.lower_fade = 0.2
	d.distance_fade_enabled = true
	d.distance_fade_begin = 18.0
	d.distance_fade_length = 6.0
	add_child(d)
	d.transform = Transform3D(Basis(Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, -1, 0)), Vector3(0, DECAL_Y, 0))
	return d

func _crack_tex(stage: int) -> Texture2D:
	var t := _load_tex(CRACKS[clampi(stage, 1, 3) - 1])
	return t if t != null else _fallback_crack(stage)

## A texture by path: imported, or read straight from its file if Godot has not imported it yet
static func _load_tex(path: String) -> Texture2D:
	if ResourceLoader.exists(path): return load(path) as Texture2D
	if FileAccess.file_exists(path):
		var img := Image.load_from_file(path)
		if img != null and not img.is_empty(): return ImageTexture.create_from_image(img)
	return null

## The model as a scene; a .glb not imported yet is read straight from its file (as industrial_prop.gd _instance)
static func _instance(path: String) -> Node3D:
	var t := _template(path)
	return t.duplicate() as Node3D if t != null else null

## The model read once (null: missing); every spot gets a copy of it
static func _template(path: String) -> Node3D:
	if _models.has(path): return _models[path]
	var n: Node3D = null
	if ResourceLoader.exists(path):
		var scene := load(path) as PackedScene
		n = scene.instantiate() as Node3D if scene != null else null
	elif FileAccess.file_exists(path):
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		if doc.append_from_file(ProjectSettings.globalize_path(path), state) == OK:
			n = doc.generate_scene(state) as Node3D
	_models[path] = n
	return n

# ---------------------------------------------------------------- fallbacks (until the textures and models land)
## A faint brown water stain, darker at its tide line
static func _fallback_tell() -> Texture2D:
	if _fb_tell != null: return _fb_tell
	var g := Gradient.new()
	g.set_color(0, Color(0.36, 0.28, 0.14, 0.16))
	g.set_color(1, Color(0.3, 0.22, 0.1, 0.0))
	g.add_point(0.72, Color(0.32, 0.24, 0.11, 0.24))
	g.add_point(0.86, Color(0.24, 0.17, 0.08, 0.36))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 128
	t.height = 256
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.54)
	t.fill_to = Vector2(0.5, 0.12)
	_fb_tell = t
	return t

## Dark crack lines out from the middle of the bulge, more and longer each stage
static func _fallback_crack(stage: int) -> Texture2D:
	if _fb_cracks.has(stage): return _fb_cracks[stage]
	var w := 256
	var h := 512
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7341                       # the same strands every stage: each one only adds to the last
	var ink := Color(0.07, 0.05, 0.03, 0.85)
	var origin := Vector2(w * 0.5, h * 0.54)
	for i in 12:
		var ang := rng.randf() * TAU
		var steps := 4 + rng.randi() % 6
		var shown := i < 4 * stage
		var at := origin + Vector2(rng.randf_range(-12.0, 12.0), rng.randf_range(-20.0, 20.0))
		for j in steps:
			ang += rng.randf_range(-0.6, 0.6)
			var seg := rng.randf_range(8.0, 18.0) * (0.6 + 0.25 * stage)
			var to := at + Vector2(cos(ang), sin(ang) * 1.6) * seg
			if shown and j < int(steps * stage / 3.0) + 1: _line(img, at, to, ink)
			at = to
	var t := ImageTexture.create_from_image(img)
	_fb_cracks[stage] = t
	return t

static func _line(img: Image, a: Vector2, b: Vector2, c: Color) -> void:
	var n := maxi(1, int(a.distance_to(b)))
	for k in n + 1:
		var p := a.lerp(b, float(k) / n)
		for o: Vector2i in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)]:
			var q := Vector2i(int(p.x), int(p.y)) + o
			if q.x >= 0 and q.y >= 0 and q.x < img.get_width() and q.y < img.get_height(): img.set_pixelv(q, c)

## The soft round dust mote
## Plaster dust spilled out over the floor in front of the hole and in through it, soft-edged: the carpet does not
## stop dead at the wall line
func _dust_patch() -> Decal:
	var d := Decal.new()
	d.name = "Dust"
	d.size = Vector3(1.5, 0.4, 1.9)                  # out from the wall, the projection's depth, along the wall
	d.position = Vector3(0.25, 0.1, 0.0)             # (projects down: straddles the wall line, mostly out in the room)
	d.texture_albedo = _dot_tex()
	d.modulate = Color(0.78, 0.74, 0.66, 0.85)
	d.albedo_mix = 0.8
	d.upper_fade = 0.3
	d.lower_fade = 0.3
	d.normal_fade = 0.6                              # (the floor only, not the wall face and skirting it also reaches)
	d.cull_mask = 1                                 # (the floor and what lies on it, not the player)
	return d

static func _dot_tex() -> Texture2D:
	if _fb_dot != null: return _fb_dot
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 64
	t.height = 64
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(0.5, 0.0)
	_fb_dot = t
	return t

static func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.9
	return m

static func _box(size: Vector3, at: Vector3, c: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	b.material = _mat(c)
	mi.mesh = b
	mi.position = at
	return mi

## Four thin strips of torn paper and board round the hole
func _placeholder_rim() -> Node3D:
	var r := Node3D.new()
	r.name = "Rim"
	r.add_child(_box(Vector3(0.09, 2.14, 0.06), Vector3(-0.015, 1.07, -0.47), PAPER))
	r.add_child(_box(Vector3(0.09, 2.14, 0.06), Vector3(-0.015, 1.07, 0.47), PAPER))
	r.add_child(_box(Vector3(0.09, 0.06, 1.0), Vector3(-0.015, 2.13, 0.0), PAPER))
	r.add_child(_box(Vector3(0.09, 0.03, 1.0), Vector3(-0.015, 0.015, 0.0), PAPER))
	return r

## The hollow behind the hole: not a room but a rough void gouged out of the wall's mass. Its sides, back and top are
## pushed out unevenly (noise, never in past the collision's box, so nothing you see stands where you can walk), its
## floor flat; it meets the wall face square at the front. What is left of the framing stands in it: a few studs at
## uneven spacing, some snapped off with the broken lengths lying on the floor, a noggin or two hanging askew.
## Real scans (Poly Haven): OSB for the void, sawn softwood for the timber.
func _wall_interior() -> Node3D:
	var x0 := WeakSpots.CAV_X0
	var x1 := WeakSpots.CAV_X1
	var z := WeakSpots.CAV_HZ
	var y1 := WeakSpots.CAV_H
	var hw := WeakSpots.HOLE_W * 0.5
	var hh := WeakSpots.HOLE_H
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(key)                # the same on every machine
	var noise := FastNoiseLite.new()
	noise.seed = rng.randi()
	noise.frequency = 0.55
	noise.fractal_octaves = 3
	var root := Node3D.new()
	root.name = "Cavity"
	# the void: a box of grids, every vertex pushed out along the faces it lies on (shared edges move together)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var push := func(q: Vector3) -> Vector3:
		var k := smoothstep(0.0, 0.45, x1 - q.x)                       # none at the front: it meets the face
		var amt := (0.06 + 0.4 * absf(noise.get_noise_3dv(q))) * k
		var o := Vector3.ZERO
		if absf(q.z - z) < 0.001: o.z += minf(amt, SIDE_PUSH)        # (the sides stop short of the block's edge)
		if absf(q.z + z) < 0.001: o.z -= minf(amt, SIDE_PUSH)
		if absf(q.x - x0) < 0.001: o.x -= amt
		if absf(q.y - y1) < 0.001: o.y += amt * 0.7
		return q + o
	_grid(st, push, Vector3(x0, 0, -z), Vector3(0, 0, 2.0 * z), Vector3(0, y1, 0), 12, 12)       # back
	_grid(st, push, Vector3(x0, 0, -z), Vector3(x1 - x0, 0, 0), Vector3(0, y1, 0), 12, 12, true)  # sides
	_grid(st, push, Vector3(x0, 0, z), Vector3(x1 - x0, 0, 0), Vector3(0, y1, 0), 12, 12)
	_grid(st, push, Vector3(x0, y1, -z), Vector3(x1 - x0, 0, 0), Vector3(0, 0, 2.0 * z), 12, 12, true)  # top
	_grid(st, push, Vector3(x0, FLOOR_Y, -z), Vector3(x1 - x0, 0, 0), Vector3(0, 0, 2.0 * z), 12, 12)  # floor (only its rim moves, sideways)
	st.index()
	st.generate_normals()
	st.generate_tangents()
	var void_mi := MeshInstance3D.new()
	void_mi.mesh = st.commit()
	var osb := _pbr("PH_OSB", Color(0.55, 0.51, 0.45), 1.0 / 2.51)
	(osb as BaseMaterial3D).cull_mode = BaseMaterial3D.CULL_DISABLED       # (seen from inside, whichever way a pushed face turned)
	void_mi.material_override = osb
	root.add_child(void_mi)
	# the wall face round the hole, seen from inside
	var fc := SurfaceTool.new()
	fc.begin(Mesh.PRIMITIVE_TRIANGLES)
	_quad(fc, Vector3(x1, 0, -z), Vector3(x1, 0, -hw), Vector3(x1, y1, -hw), Vector3(x1, y1, -z), Vector3.LEFT)
	_quad(fc, Vector3(x1, 0, hw), Vector3(x1, 0, z), Vector3(x1, y1, z), Vector3(x1, y1, hw), Vector3.LEFT)
	_quad(fc, Vector3(x1, hh, -hw), Vector3(x1, hh, hw), Vector3(x1, y1, hw), Vector3(x1, y1, -hw), Vector3.LEFT)
	root.add_child(_merged(fc, osb))
	# what is left of the framing
	var fr := SurfaceTool.new()
	fr.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lean := func(axis: Vector3, a: float) -> Basis: return Basis(axis, a)
	# a few studs across the back, unevenly spaced, some snapped
	var t := -z + rng.randf_range(0.15, 0.45)
	while t < z - 0.2:
		var bx := x0 + STUD_D * 0.5 + rng.randf_range(0.0, 0.25)
		var full := rng.randf() < 0.45
		var h := y1 - 0.05 if full else rng.randf_range(0.6, 1.9)
		var tilt: Basis = lean.call(Vector3.RIGHT, rng.randf_range(-0.05, 0.05))
		_add_box(fr, Vector3(STUD_D, h, STUD_W), Vector3(bx, h * 0.5, t), tilt)
		if not full:            # its broken length, on the floor in front of it
			# (laid along the wall, across the shallow void, short enough to stay inside it)
			var lh := rng.randf_range(0.4, 0.9)
			var lie: Basis = lean.call(Vector3.UP, rng.randf_range(-0.3, 0.3)) * lean.call(Vector3.RIGHT, PI * 0.5 + rng.randf_range(-0.1, 0.1))
			var lz := clampf(t + rng.randf_range(-0.2, 0.2), -z + lh * 0.5 + 0.1, z - lh * 0.5 - 0.1)
			_add_box(fr, Vector3(STUD_D, lh, STUD_W), Vector3(bx + 0.2 + rng.randf_range(0.0, 0.25), FLOOR_Y + STUD_W * 0.5 + 0.005, lz), lie)
		elif rng.randf() < 0.6:  # a noggin off it, hanging from one nail
			var nl_len := rng.randf_range(0.35, 0.6)
			var hang: Basis = lean.call(Vector3.RIGHT, rng.randf_range(0.35, 0.9) * (1.0 if rng.randf() < 0.5 else -1.0))
			_add_box(fr, Vector3(STUD_D, STUD_W, nl_len), Vector3(bx, rng.randf_range(1.0, 1.6), t + nl_len * 0.5), hang)
		t += rng.randf_range(0.45, 0.8)
	# one or two along each side, standing a little off it
	for sd: float in [-1.0, 1.0]:
		for i in rng.randi_range(1, 2):
			var sx := rng.randf_range(x0 + 0.4, x1 - 0.5)
			var h := rng.randf_range(1.2, y1 - 0.05)
			var tilt: Basis = lean.call(Vector3.BACK, rng.randf_range(-0.06, 0.06))
			_add_box(fr, Vector3(STUD_W, h, STUD_D), Vector3(sx, h * 0.5, sd * (z - STUD_D * 0.5 - rng.randf_range(0.0, 0.15))), tilt)
	# the wall's sole plate, lying flat along its foot right across the hole: the step you come over (and what the
	# void's floor, a little above the level's, butts up to: no thin sheet floating over the carpet)
	_add_box(fr, Vector3(STUD_D + 0.03, PLATE_H, z * 2.0), Vector3(x1 - (STUD_D + 0.03) * 0.5, PLATE_H * 0.5, 0))
	# the opening's own framing, from inside: a king stud each side and a header over it (the hole was cut between them)
	for side: float in [-1.0, 1.0]:
		_add_box(fr, Vector3(STUD_D, y1 - 0.05, STUD_W), Vector3(x1 - STUD_D * 0.5, (y1 - 0.05) * 0.5, side * (hw + STUD_W * 0.5)))
	_add_box(fr, Vector3(STUD_D, STUD_W * 1.8, hw * 2.0 + STUD_W * 2.0), Vector3(x1 - STUD_D * 0.5, hh + STUD_W * 0.9, 0))
	# splinters and offcuts on the floor
	for i in 7:
		var sz := Vector3(rng.randf_range(0.08, 0.4), rng.randf_range(0.015, 0.04), rng.randf_range(0.03, 0.09))
		var at := Vector3(rng.randf_range(x0 + 0.2, x1 - 0.3), FLOOR_Y + sz.y * 0.5 + 0.003, rng.randf_range(-z + 0.2, z - 0.2))
		_add_box(fr, sz, at, lean.call(Vector3.UP, rng.randf_range(0.0, TAU)))
	fr.generate_tangents()
	root.add_child(_merged(fr, _pbr("PH_Plywood", Color(0.85, 0.8, 0.72), 1.0 / 0.5, false)))   # sawn softwood grain (Poly Haven scan), along each piece
	return root

## A grid of `nu` x `nv` quads from `o` across `u` and `v`, every vertex through `warp`, facing -(u x v) (`flip`: u x v)
static func _grid(st: SurfaceTool, warp: Callable, o: Vector3, u: Vector3, v: Vector3, nu: int, nv: int, flip := false) -> void:
	for i in nu:
		for j in nv:
			var a: Vector3 = warp.call(o + u * (float(i) / nu) + v * (float(j) / nv))
			var b: Vector3 = warp.call(o + u * (float(i + 1) / nu) + v * (float(j) / nv))
			var c: Vector3 = warp.call(o + u * (float(i + 1) / nu) + v * (float(j + 1) / nv))
			var d: Vector3 = warp.call(o + u * (float(i) / nu) + v * (float(j + 1) / nv))
			for q: Vector3 in ([a, d, c, a, c, b] if flip else [a, b, c, a, c, d]):
				st.add_vertex(q)

const SIDE_PUSH := 0.22      # m: the most the void's sides go out (the block's edge is 0.3 m off)
const FLOOR_Y := 0.025       # m: the void's floor over the level's (its carpet runs on under the wall: they flickered)
const STUD_W := 0.045         # m: a stud's narrow face, toward you (2x4 on edge)
const STUD_D := 0.09          # m: its depth, out from the board behind it
const PLATE_H := 0.045        # m: a plate's / a block's height
const STUD_STEP := 0.6        # m between stud centres
const BLOCK_Y := 1.25         # m: the row of blocking

## A box `length` along a wall, `h` tall, `d` deep out of it; `across`: the wall runs along z
static func _run(length: float, h: float, d: float, across: bool) -> Vector3:
	return Vector3(d, h, length) if across else Vector3(length, h, d)

## A box into `st`: six faces, `size` about `at`, turned by `b`. UVs in metres, with the texture's grain (its u)
## along the piece's longest side on every face, as sawn timber's runs; each box starts at its own random place in it
static func _add_box(st: SurfaceTool, size: Vector3, at: Vector3, b := Basis.IDENTITY) -> void:
	var h := size * 0.5
	var long := 0 if size.x >= size.y and size.x >= size.z else (1 if size.y >= size.z else 2)
	var off := Vector2(fposmod(at.x * 7.13 + at.z * 3.71, 1.0), fposmod(at.y * 5.37 + at.z * 1.93, 1.0)) * 2.0
	for ax in 3:
		for sgn: float in [-1.0, 1.0]:
			var n := Vector3.ZERO
			n[ax] = sgn
			# the face's two in-plane axes: the grain first when it lies in this face
			var ia := (ax + 1) % 3
			var ib := (ax + 2) % 3
			if ib == long:
				ia = long
				ib = (ax + 1) % 3
			var u := Vector3.ZERO
			u[ia] = h[ia]
			var v := Vector3.ZERO
			v[ib] = h[ib]
			var c := n * h[ax]
			var pts := [c - u - v, c + u - v, c + u + v, c - u + v]
			var uvs := [Vector2(-h[ia], -h[ib]), Vector2(h[ia], -h[ib]), Vector2(h[ia], h[ib]), Vector2(-h[ia], h[ib])]
			if (pts[1] - pts[0]).cross(pts[2] - pts[0]).dot(n) > 0.0:      # wound the way Godot draws front faces
				pts = [pts[0], pts[3], pts[2], pts[1]]
				uvs = [uvs[0], uvs[3], uvs[2], uvs[1]]
			for k in [0, 1, 2, 0, 2, 3]:
				st.set_normal(b * n)
				st.set_uv((uvs[k] as Vector2) + off)
				st.add_vertex(at + b * (pts[k] as Vector3))

## One mesh from `st`, with its material
static func _merged(st: SurfaceTool, m: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = m
	return mi

## A textures/pbr material, tinted, at `scale` repeats a metre: laid on by its own triplanar, or (`triplanar`
## false) by the mesh's UVs, which are in metres
static func _pbr(id: String, tint: Color, scale: float, triplanar := true) -> Material:
	var path := "res://textures/pbr/%s/%s.tres" % [id, id]
	if not ResourceLoader.exists(path): return _mat(tint)
	var m := (load(path) as StandardMaterial3D).duplicate() as StandardMaterial3D
	m.albedo_color = tint
	m.uv1_triplanar = triplanar
	m.uv1_scale = Vector3.ONE * scale
	m.emission_enabled = false
	return m

## A quad facing `n`, wound the way Godot draws front faces (clockwise seen from in front)
static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
	if (b - a).cross(c - a).dot(n) > 0.0:
		var t := b
		b = d
		d = t
	for v in [a, b, c, a, c, d]:
		st.set_normal(n)
		st.add_vertex(v)

## A few lumps of board and plaster on the floor in front
func _placeholder_debris() -> Node3D:
	var r := Node3D.new()
	r.name = "Debris"
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(key)
	for i in 6:
		var s := Vector3(rng.randf_range(0.06, 0.2), rng.randf_range(0.02, 0.06), rng.randf_range(0.05, 0.16))
		var b := _box(s, Vector3(rng.randf_range(0.15, 1.2), s.y * 0.5, rng.randf_range(-0.5, 0.5)),
			PAPER if i % 2 == 0 else BOARD)
		b.rotation.y = rng.randf() * TAU
		r.add_child(b)
	return r
