extends Node
## The camera flash in the hand. G (or a right click) fires one: a blinding white burst from where
## you stand, lighting the whole hall for an instant. The Bacteria caught in it, close and near the
## middle of the frame, is blinded for a few seconds (bacteria.gd flashed / blind); when its eyes
## clear it only comes straight back for you if you are still close and in plain sight, so the flash
## buys the seconds to get round a corner or far down the hall. Missing it is loud: the pop tells it
## where you are. THE GRABBER caught in it reels and runs off into the dark for a while (grabber.gd
## flashed); flash it on the ceiling and it drops, then runs.
## Each flash in the inventory is one charge (flash_pickup.gd, ITEM_ID); after one goes off the next
## needs RECHARGE seconds to charge up (the whine), and a press with none left, or still charging,
## is the dead click.
## In co-op everyone sees and hears everyone's flash (Net.send_flash), and only the host's copy of
## the Bacteria, the one that runs its brain, takes the hit.
## Built by hud.gd.

const FlashPickup := preload("res://scripts/World/props/flash_pickup.gd")

const KEY := KEY_G
const RECHARGE := 1.8            # s before the next flash can go off
const LIGHT_ENERGY := 14.0
const LIGHT_RANGE := 20.0
const LIGHT_FADE := 0.22         # s for the burst to die away
const GLARE := 0.5               # your own eyes: Game.fx_flash (post shader) on firing
const COLOR := Color(0.92, 0.95, 1.0)

var player: Node                 # player.gd (set by hud.gd)
var inventory: Node              # inventory.gd
var charging := 0.0              # s left until it can fire again
var last_hit := false            # the last flash caught the Bacteria (for the tests / debug)
var since_fired := INF           # s since the last one went off (the HUD's noise meter shows the pop)
var _charge_sfx: AudioStreamPlayer

func _ready() -> void:
	_charge_sfx = AudioStreamPlayer.new()
	_charge_sfx.stream = load("res://audio/flash_charge.wav")
	_charge_sfx.bus = "World"
	_charge_sfx.volume_db = -14.0
	add_child(_charge_sfx)

func _process(dt: float) -> void:
	charging = maxf(0.0, charging - dt)
	since_fired += dt

func _unhandled_input(e: InputEvent) -> void:
	var k := e as InputEventKey
	var mb := e as InputEventMouseButton
	var pressed := (k != null and k.pressed and not k.echo and k.physical_keycode == KEY) \
		or (mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_RIGHT)
	if not pressed or not _can():
		return
	get_viewport().set_input_as_handled()
	fire()

func _can() -> bool:
	return player != null and inventory != null and Game.playing and not Game.dead and not player.dead \
		and not player.frozen and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED

## Set one off, if there is a charge and it is ready. True when it went off.
func fire() -> bool:
	if charging > 0.0 or not inventory.has_item(FlashPickup.ITEM_ID):
		player.dead_click.emit()
		return false
	inventory.remove_item(FlashPickup.ITEM_ID)
	charging = RECHARGE
	since_fired = 0.0
	var cam: Camera3D = player.cam
	var look := -cam.global_transform.basis.z
	var origin := cam.global_position
	Game.fx_flash = maxf(Game.fx_flash, GLARE)
	burst(origin + look * 0.35)
	if inventory.has_item(FlashPickup.ITEM_ID):
		_charge_sfx.play()
	last_hit = false
	if not Net.is_online() or Net.hosting:
		last_hit = hit(origin, look)
	Net.send_flash(origin, look)
	return true

## Whoever fired it: the Bacteria and the Grabber take it if they are in the way (on the machine that runs
## their brains)
static func hit(origin: Vector3, look: Vector3) -> bool:
	if Game.main == null or not is_instance_valid(Game.main):
		return false
	var took := false
	for name in ["Entity", "Grabber"]:            # the Bacteria, and THE GRABBER (grabber.gd flashed())
		var ent: Node = Game.main.get_node_or_null(name)
		if ent != null and ent.has_method("flashed") and ent.flashed(origin, look):
			took = true
	return took

## The flash going off at `pos`: a shadowed white light that dies away in LIGHT_FADE, and the pop
static func burst(pos: Vector3) -> void:
	if Game.main == null or not is_instance_valid(Game.main):
		return
	var root := Node3D.new()
	Game.main.add_child(root)
	root.global_position = pos
	var light := OmniLight3D.new()
	light.light_color = COLOR
	light.light_energy = LIGHT_ENERGY
	light.omni_range = LIGHT_RANGE
	light.omni_attenuation = 0.7
	light.shadow_enabled = true
	root.add_child(light)
	var pop := AudioStreamPlayer3D.new()
	pop.stream = load("res://audio/flash_fire.wav")
	pop.bus = "World"
	pop.unit_size = 8.0
	pop.max_distance = 60.0
	root.add_child(pop)
	pop.play()
	var tw := root.create_tween()
	tw.tween_property(light, "light_energy", 0.0, LIGHT_FADE).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.5)                  # the pop's tail
	tw.tween_callback(root.queue_free)
