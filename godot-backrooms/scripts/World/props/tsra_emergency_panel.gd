extends Node3D
## The T.S.R.A. launch panel for the hub's launch bay: a yellow emergency lever box (Sketchfab model retextured by
## tools/make_tsra_branding.py: "T.S.R.A." over the handle, the agency logo on its LCD), facing +Z with its back on
## the plane z = 0 and its feet at y = 0. The LCD runs shaders/tsra_panel_screen.gdshader as a next pass over the
## panel's own material; the lever swing is the model's own animation.
##
## pull() is what the launch bay calls when the player works the lever: the lever swings down and stays down,
## `pulled` fires, the screen charges for `charge_time` and `charged` fires (the portal opens on that). reset()
## swings it back up. The screen asks for the lever ("PULL LEVER") while the player's interact focus is on it,
## or while set_hint(true). [E] on it pulls (interact(), with the shared world tooltip); scripts/World/props/
## tsra_launch_bay.gd puts it on the launch console and hands `charged` to the gate.

signal pulled
signal charged

const Prop := preload("res://scripts/World/props/industrial_prop.gd")
const InteractTooltip := preload("res://scripts/World/props/interact_tooltip.gd")
const MODEL := "res://models/props/tsra/tsra_emergency_panel.glb"
const SCREEN_SHADER := preload("res://shaders/tsra_panel_screen.gdshader")
const LOGO := "res://textures/ui/tsra_logo.png"          # the agency emblem, as the terminal shows it
const STATUS := "res://textures/tsra/tsra_screen_status.png"
const AMBER := Color("f0a838")

enum Screen { STANDBY, ENGAGE, CHARGING, OPEN }

const BOOT_TIME := 1.6
const LEVER_DOWN := 0.9         # s into the model's swing: down and settled
const LEVER_UP := 2.05          # s into it: the swing back up starts
const SCREEN_AT := Vector3(0.0, 0.174, 0.056)   # the LCD's middle, in this node's space

@export var charge_time := 4.0
@export var model_scale := 1.0  # the file is a real-size box, 22 x 38 cm
@export var powered := true

var screen_mat: ShaderMaterial
var anim: AnimationPlayer
var swing := ""
var glow: OmniLight3D
var state := Screen.STANDBY
var state_t := 0.0
var boot := 0.0
var charge := 0.0
var hint := false
var down := false

func _ready() -> void:
	var model := Prop._instance(MODEL)
	if model == null:
		return
	model.rotation.y = -PI / 2.0                 # the file faces +X
	model.scale = Vector3.ONE * model_scale
	add_child(model)

	screen_mat = ShaderMaterial.new()
	screen_mat.shader = SCREEN_SHADER
	screen_mat.set_shader_parameter("ink", Color(AMBER.r, AMBER.g, AMBER.b))
	screen_mat.set_shader_parameter("logo_tex", _texture(LOGO))
	screen_mat.set_shader_parameter("status_tex", _texture(STATUS))
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		if str(mi.name).begins_with("EmergencyPanelLever"):
			continue                             # the handle shares the atlas but not the screen
		for i in mi.get_surface_override_material_count():
			var base := mi.get_active_material(i)
			if base == null:
				continue
			var m := base.duplicate() as Material
			m.next_pass = screen_mat
			mi.set_surface_override_material(i, m)

	var players := model.find_children("*", "AnimationPlayer", true, false)
	if not players.is_empty():
		anim = players[0]
		for a in anim.get_animation_list():
			if a != "RESET":
				swing = a
				break
		if swing != "":
			anim.get_animation(swing).loop_mode = Animation.LOOP_NONE

	glow = OmniLight3D.new()
	glow.light_color = AMBER
	glow.omni_range = 0.9 * model_scale
	glow.light_specular = 0.0
	glow.shadow_enabled = false
	glow.position = SCREEN_AT * model_scale + Vector3(0.0, 0.0, 0.08 * model_scale)
	add_child(glow)

	# something for the interact ray to land on, and the [E] prompt over it
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.24, 0.4, 0.1) * model_scale
	shape.shape = box
	shape.position = Vector3(0.0, 0.19, 0.05) * model_scale
	body.add_child(shape)
	add_child(body)
	add_to_group("interactables")
	var tip := InteractTooltip.new()
	tip.name = "InteractTooltip"
	tip.height = 0.5 * model_scale
	add_child(tip)
	_push()

func _process(dt: float) -> void:
	if screen_mat == null:
		return
	state_t += dt
	boot = clampf(boot + (dt if powered else -dt * 3.0) / BOOT_TIME, 0.0, 1.0)
	if state == Screen.CHARGING:
		charge = minf(charge + dt / charge_time, 1.0)
		if charge >= 1.0:
			_set_state(Screen.OPEN)
			charged.emit()
	var asked := hint or _focused()
	if state == Screen.STANDBY and asked and not down:
		_set_state(Screen.ENGAGE)
	elif state == Screen.ENGAGE and not asked:
		_set_state(Screen.STANDBY)
	# hold the lever down once it has swung there
	if down and anim and anim.current_animation == swing and anim.current_animation_position >= LEVER_DOWN:
		anim.pause()
	_push()

## Swing the lever down and start charging. False if it is already down or the panel is off.
func pull() -> bool:
	if down or not powered or boot < 1.0:
		return false
	down = true
	if anim and swing != "":
		anim.play(swing)
	get_tree().create_timer(0.4).timeout.connect(_lever_hit)
	return true

## Swing the lever back up and go back to standby
func reset() -> void:
	if not down:
		return
	down = false
	charge = 0.0
	if anim and swing != "":
		anim.play(swing)
		anim.seek(maxf(LEVER_UP, anim.current_animation_position), true)
	_set_state(Screen.STANDBY)

func set_hint(on: bool) -> void:
	hint = on

# ---------------------------------------------------------------- interaction (player.gd focus, interact_tooltip.gd)
func can_interact(_from_pos: Vector3) -> bool:
	return not down and powered and boot >= 1.0

func get_interact_prompt() -> String:
	return "[E] PULL"

func get_interact_title() -> String:
	return "Threshold Engage"

func get_handle_global_pos() -> Vector3:
	return to_global(Vector3(0.0, 0.3, 0.08) * model_scale)

func interact(_p: Node3D) -> bool:
	return pull()

func _focused() -> bool:
	var p: Node = Game.player
	return p != null and is_instance_valid(p) and p.get("focused_door") == self

func _lever_hit() -> void:
	if not down:
		return
	pulled.emit()
	charge = 0.0
	_set_state(Screen.CHARGING)

## Imported if the editor has seen it, else read straight from the file (a fresh checkout)
func _texture(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path)
	var img := Image.load_from_file(ProjectSettings.globalize_path(path))
	return ImageTexture.create_from_image(img) if img else null

func _set_state(s: int) -> void:
	state = s
	state_t = 0.0

func _push() -> void:
	screen_mat.set_shader_parameter("state", state)
	screen_mat.set_shader_parameter("state_time", state_t)
	screen_mat.set_shader_parameter("boot", boot)
	screen_mat.set_shader_parameter("charge", charge)
	var e := 0.12
	match state:
		Screen.CHARGING: e = 0.12 + 0.35 * charge
		Screen.OPEN: e = 0.5
	glow.light_energy = e * boot
