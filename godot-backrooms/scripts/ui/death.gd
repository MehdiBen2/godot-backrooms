extends Node
## Death camera + blood-screen overlay (js/game/death.js + grab.js endGrab(dying=true)).
##
## Sequence (same timings as the web game):
##
##   t=0            blood-scream already played by scares.splat() at the snap/bite moment
##                  blood-screen image fades in and slides down (opacity 0->0.55, translateY -8%->0)
##   t=0..1.18s     camera smoothsteps from FPS eye position to 3rd-person (4.2m back, 2.5m up)
##   t=1.18s..15s   slow 360 deg orbit, eased spin, 0.003 floating drift
##
## DO NOT call scares.splat() or play any audio here — that is done at the snap/bite moment
## in mannequin.gd / entity.gd, BEFORE kill_player() is called.

const ORBIT_SECONDS := 14.0
const PULL_SECONDS  := 1.176   # 1 / 0.85 (JS: progress = timer * 0.85, capped at 1)
const ORBIT_RADIUS  := 4.2
const ORBIT_HEIGHT  := 2.5
const BODY_CENTER_Y := 0.35

var active     := false
var timer      := 0.0
var reason     := ""

var cam_start  := Vector3.ZERO
var death_pos  := Vector3.ZERO
var player_yaw := 0.0

var _cam: Camera3D    = null
var _player: Node3D   = null

# Blood-screen overlay
var _blood_overlay: CanvasLayer = null
var _blood_rect:    TextureRect = null
var _blood_tween:   Tween       = null
var _blood_tex:     Texture2D   = null

var _fx: Node = null
var _start_rot := Quaternion.IDENTITY
var _have_start_rot := false

func _ready() -> void:
	_fx = load("res://scripts/ui/death_fx.gd").new()
	add_child(_fx)
	# Preload blood texture — Godot will import it on first editor open
	if ResourceLoader.exists("res://textures/blood/PsoSI8.png"):
		_blood_tex = load("res://textures/blood/PsoSI8.png")
	if _blood_tex == null:
		push_warning("Death: blood texture failed to load")

func bind(cam: Camera3D, player: Node3D, _scares: Node) -> void:
	_cam    = cam
	_player = player

## Called by Game.kill_player().
## cam_start_global: camera world pos at death.
## p_pos: player feet world pos.
## p_yaw: player.rotation.y.
func start(killer: String, p_pos: Vector3, cam_start_global: Vector3, p_yaw: float) -> void:
	if active:
		return
	active     = true
	_have_start_rot = false
	timer      = 0.0
	reason     = killer
	death_pos  = p_pos
	cam_start  = cam_start_global
	player_yaw = p_yaw

	_show_blood_screen()
	# The killer is right in front of the view: the bite / snap sprays from about there
	var fwd := Vector3(-sin(p_yaw), 0.0, -cos(p_yaw))
	if killer != "THE BACTERIA" and killer != "THE MANNEQUIN":   # those two already sprayed at the bite / snap (bite())
		_fx.feast(cam_start_global + fwd * 0.8, p_pos)
	_fx.spawn_ragdoll(p_pos, p_yaw)
	_thud()

## The bacteria's jaws close on you: blood sprays from its mouth and pools on the floor. Called from entity.gd at the bite.
# The body hitting the floor: a low heavy thump as the fall clip lands
func _thud() -> void:
	await get_tree().create_timer(0.85).timeout
	if not active:
		return
	var sc := get_tree().current_scene.get_node_or_null("Scares") if get_tree().current_scene else null
	if sc != null:
		sc.heartbeat(1.6)

func bite(mouth: Vector3, victim: Vector3, cam_pos: Vector3) -> void:
	_fx.feast(mouth, victim)
	# most of the spray is thrown at you, the rest sprays out
	var to_victim := cam_pos - mouth
	_fx.spray(mouth, to_victim if to_victim.length() > 0.01 else Vector3.UP)

## The grab begins: clear last run's blood
func grab_begin() -> void:
	_fx.clear()

## A single droplet (js bloodDrop): flies, falls and stains where it lands
func bite_drop(pos: Vector3, vel: Vector3, size: float) -> void:
	_fx.drop(pos, vel, size)

func bite_drip(from: Vector3) -> void:
	_fx.drop(from, Vector3(randf_range(-0.3, 0.3), 0.0, randf_range(-0.3, 0.3)), randf_range(0.02, 0.05))

func stop() -> void:
	active = false
	timer  = 0.0
	_hide_blood_screen()
	_fx.clear()
	_cam    = null
	_player = null

# ──────────────────────────────────────── blood-screen overlay ─────────────────
# Web equivalent: endGrab(dying=true) → blood image fades in 0.7s and slides from
# translateY(-8%) to translateY(0) over 9s, opacity 0 -> 0.55.
func _show_blood_screen() -> void:
	if _blood_tex == null:
		return
	if _blood_overlay != null:
		_blood_overlay.queue_free()

	_blood_overlay = CanvasLayer.new()
	_blood_overlay.layer = 20          # above the 3D scene, below the SIGNAL LOST overlay (30)
	add_child(_blood_overlay)

	_blood_rect = TextureRect.new()
	_blood_rect.texture = _blood_tex
	_blood_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_blood_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_blood_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_blood_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_blood_rect.modulate.a = 0.0
	_blood_overlay.add_child(_blood_rect)
	# Start offset: slide down from -8% of screen height (web: translateY(-8%)).
	# Set after add_child so the anchor layout doesn't overwrite it.
	# Web: transform-origin 50% 0, translateY(-8%) scale(1.1) -> translateY(0) scale(1.04); the scale keeps
	# the bottom edge covered while it slides down, so no gap shows below the image.
	var vs := get_viewport().get_visible_rect().size
	_blood_rect.pivot_offset = Vector2(vs.x * 0.5, 0.0)
	_blood_rect.scale = Vector2(1.1, 1.1)
	_blood_rect.position = Vector2(0.0, -vs.y * 0.08)

	# Kill any previous tween
	if _blood_tween != null and _blood_tween.is_valid():
		_blood_tween.kill()
	_blood_tween = create_tween().set_parallel(true)
	# Fade in: opacity 0 -> 0.55 over 0.7s (web: transition: opacity 0.7s ease-out)
	_blood_tween.tween_property(_blood_rect, "modulate:a", 0.55, 0.7).set_ease(Tween.EASE_OUT)
	# Slide down: -8% Y -> 0 over 9s (web: transform 9s cubic-bezier(0.2,0.6,0.3,1))
	_blood_tween.tween_property(_blood_rect, "position:y", 0.0, 9.0).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_blood_tween.tween_property(_blood_rect, "scale", Vector2(1.04, 1.04), 9.0).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)

func _hide_blood_screen() -> void:
	if _blood_tween != null and _blood_tween.is_valid():
		_blood_tween.kill()
	if _blood_overlay != null and is_instance_valid(_blood_overlay):
		_blood_overlay.queue_free()
		_blood_overlay = null
		_blood_rect = null

# ──────────────────────────────────────── camera orbit ─────────────────────────
func _process(delta: float) -> void:
	if not active:
		return
	if not is_instance_valid(_cam):
		active = false
		return
	timer += delta
	# Mirror of death.js updateDeath() ─────────────────────────────────────────
	#   progress  = min(1, timer * 0.85)
	#   smooth    = smoothstep(progress)
	#   orbitT    = max(0, timer - PULL_SECONDS)
	#   orbitAng  = min(1, orbitT / 14) * TAU
	#   ease      = min(1, orbitT / 1.5)
	#   ang       = player_yaw + orbitAng * ease
	#   orbitPos  = (dp.x + sin*4.2, dp.y + 2.5, dp.z + cos*4.2)
	#   cam.pos   = lerp(camStart, orbitPos, smooth)
	var progress  := minf(1.0, timer * 0.85)
	var sm        := _smoothstep(progress)
	var orbit_t   := maxf(0.0, timer - PULL_SECONDS)
	var orbit_ang := minf(1.0, orbit_t / ORBIT_SECONDS) * TAU
	var spin_in   := minf(1.0, orbit_t / 1.5)
	var ang       := player_yaw + orbit_ang * spin_in
	var dp        := death_pos

	var orbit_pos := Vector3(
		dp.x + sin(ang) * ORBIT_RADIUS,
		dp.y + ORBIT_HEIGHT,
		dp.z + cos(ang) * ORBIT_RADIUS
	)
	_cam.global_position = cam_start.lerp(orbit_pos, sm)

	# Floating drift after 1.2s (JS: sin(timer * 1.5) * 0.003)
	if timer > 1.2:
		_cam.global_position.y += sin(timer * 1.5) * 0.003

	# Look at body centre — guard against degenerate look_at
	var body_centre := Vector3(dp.x, dp.y + BODY_CENTER_Y, dp.z)
	if _cam.global_position.distance_squared_to(body_centre) > 0.0001:
		# Ease the view from the snapped-head stare round to the body instead of cutting to it
		var target := Transform3D(Basis.IDENTITY, _cam.global_position).looking_at(body_centre, Vector3.UP).basis.get_rotation_quaternion()
		if not _have_start_rot:
			_start_rot = _cam.global_transform.basis.get_rotation_quaternion()
			_have_start_rot = true
		_cam.global_transform.basis = Basis(_start_rot.slerp(target, sm))

func _smoothstep(t: float) -> float:
	var c := clampf(t, 0.0, 1.0)
	return c * c * (3.0 - 2.0 * c)


# ──────────────────────────────────────── respawn through static (death.js respawnPlayer) ───
# The screen dissolves into TV static; only once it is fully covered is the level reloaded (you never
# see the swap), then the static clears. RESPAWN = { fadeIn 0.35, hold 0.45, fadeOut 0.9 }.
const RESPAWN_FADE_IN := 0.35
const RESPAWN_HOLD := 0.45
const RESPAWN_FADE_OUT := 1.2
const STATIC_SHADER := """
shader_type canvas_item;
// Plain dark TV snow: fine grain that reshuffles every frame, faint scanlines. Nothing else.
float hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}
void fragment() {
	vec2 px = floor(FRAGCOORD.xy * 0.5);
	float n = hash(px + fract(TIME * 9.7) * 731.0);
	float v = 0.02 + n * n * 0.42;
	v *= 0.9 + 0.1 * sin(FRAGCOORD.y * 3.14159);
	COLOR = vec4(vec3(v), 1.0);
}
"""

var _static_layer: CanvasLayer = null
var _static_rect: ColorRect = null
var _static_audio: AudioStreamPlayer = null
var respawn_busy := false

func _ensure_static_layer() -> void:
	if _static_layer != null:
		return
	_static_layer = CanvasLayer.new()
	_static_layer.layer = 100
	add_child(_static_layer)
	_static_rect = ColorRect.new()
	_static_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_static_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = STATIC_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	_static_rect.material = mat
	_static_layer.add_child(_static_rect)
	_static_audio = AudioStreamPlayer.new()
	add_child(_static_audio)

## Called once the level is up: compile shaders / pipelines and start loading assets now, so the first
## death does not hitch.
func warmup() -> void:
	if respawn_busy:      # the level was just reloaded behind the static: leave the static alone
		return
	ResourceLoader.load_threaded_request("res://models/entities/hazmat.glb")
	_ensure_static_layer()
	_static_layer.visible = true
	_static_rect.modulate.a = 0.004      # drawn for a couple of frames so its pipeline is compiled
	_fx.warm()
	await get_tree().create_timer(0.6).timeout
	if not respawn_busy:
		_static_rect.modulate.a = 0.0
		_static_layer.visible = false

## Cover the screen with static, run `swap` (reload / reset) behind it, then fade the static out.
func respawn_transition(swap: Callable) -> void:
	if respawn_busy:
		return
	respawn_busy = true
	_ensure_static_layer()
	_static_layer.visible = true
	_static_rect.modulate.a = 0.0
	# sound: the web's staticHit, plus a burst of snow that swells with the picture
	var scares := get_tree().current_scene.get_node_or_null("Scares") if get_tree().current_scene else null
	var noise: AudioStream = null
	if scares != null:
		scares.play_scare("staticHit", 0.35)
		noise = scares.synth("static")
	if noise != null:
		_static_audio.stream = noise
		_static_audio.volume_db = -30.0
		_static_audio.play()
	var tw := create_tween().set_parallel(true)
	tw.tween_property(_static_rect, "modulate:a", 1.0, RESPAWN_FADE_IN).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(_static_audio, "volume_db", -6.0, RESPAWN_FADE_IN)
	await tw.finished
	swap.call()
	# The reload is a heavy frame. Wait until the new level is up and has rendered a few frames, hold,
	# and only then fade out, so the fade is actually seen instead of being swallowed by the hitch.
	for i in 8:
		await get_tree().process_frame
	await get_tree().create_timer(RESPAWN_HOLD).timeout
	var tw2 := create_tween().set_parallel(true)
	tw2.tween_property(_static_rect, "modulate:a", 0.0, RESPAWN_FADE_OUT).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw2.tween_property(_static_audio, "volume_db", -60.0, RESPAWN_FADE_OUT)
	await tw2.finished
	_static_audio.stop()
	_static_layer.visible = false
	respawn_busy = false
