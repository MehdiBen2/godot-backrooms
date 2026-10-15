@tool
class_name UBToast
extends PanelContainer
## Transient notice floating over the 3D viewport's bottom edge, used for
## user-facing refusals and notices instead of a modal dialog. Non-interactive:
## MOUSE_FILTER_IGNORE on every node, so a toast never eats the viewport click
## that follows it. Uses the shared floating-card style (UBPanelStyle.float_card)
## with the Unibuilder mark in front of the message; fades in fast and out slow.
## The card keeps the dark look on both editor themes, so the label sets an
## explicit light font colour. Parented under the editor's input surface and
## placed by plugin._process from the SubViewport size.

## Seconds fully visible before the fade starts; a new message resets it.
const HOLD_SEC := 4.0
const FADE_IN_SEC := 0.15
const FADE_OUT_SEC := 0.6
## Messages longer than this wrap at WRAP_WIDTH instead of widening the card.
const WRAP_CHARS := 90
const WRAP_WIDTH := 460.0

const SCENE := "res://addons/unibuilder/editor/toast.tscn"

var _label: Label
var _shown_at := 0.0
var _hold_until := 0.0


## The one way to make this control (plugin and tests both use it): the
## layout lives in toast.tscn, and the editor-dependent dressing is applied
## here rather than on instantiation, so opening the scene in the editor and
## saving it never bakes run-time styling into the file.
static func create() -> UBToast:
	var toast := (load(SCENE) as PackedScene).instantiate() as UBToast
	toast._dress()
	return toast


func _notification(what: int) -> void:
	if what == NOTIFICATION_SCENE_INSTANTIATED:
		_label = %Message
		set_process(false)


func _dress() -> void:
	UBPanelStyle.float_card(self)
	UBPanelStyle.scale_layout(self)

	(%Mark as TextureRect).texture = UBOverlayToolbar._icon("logo")


func show_message(msg: String) -> void:
	_label.text = msg
	if msg.length() > WRAP_CHARS:
		_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_label.custom_minimum_size.x = WRAP_WIDTH * EditorInterface.get_editor_scale()
	else:
		_label.autowrap_mode = TextServer.AUTOWRAP_OFF
		_label.custom_minimum_size.x = 0.0
	var now := Time.get_ticks_msec() / 1000.0

	_shown_at = now - (FADE_IN_SEC if visible else 0.0)
	_hold_until = now + HOLD_SEC
	modulate.a = 1.0 if visible else 0.0
	visible = true
	set_process(true)


func dismiss() -> void:
	visible = false
	set_process(false)


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var over := now - _hold_until
	if over >= FADE_OUT_SEC:
		dismiss()
		return
	var a_in := clampf((now - _shown_at) / FADE_IN_SEC, 0.0, 1.0)
	var a_out := 1.0 if over <= 0.0 else 1.0 - over / FADE_OUT_SEC
	modulate.a = minf(a_in, a_out)
