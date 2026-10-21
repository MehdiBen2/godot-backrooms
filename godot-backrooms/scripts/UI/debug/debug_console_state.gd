extends CanvasLayer
## Debug console state: constants, node references and fields shared by the layers above it:
## debug_console_handlers.gd (entities, models, animation walker), debug_console_ui.gd (menu, tabs) and
## debug_console.gd (command line).


const SurvivorAnim := preload("res://scripts/Entities/survivor_anim.gd")
const HazmatFit := preload("res://scripts/Entities/hazmat_fit.gd")
const FlashPickup := preload("res://scripts/World/props/flash_pickup.gd")
const TapePickup := preload("res://scripts/World/props/tape_pickup.gd")
const EntityRoster := preload("res://scripts/Entities/entity_roster.gd")
const AnimWalker := preload("res://scripts/UI/debug/anim_walker.gd")

const ENTITIES := {
	"bacteria": "Entity",
	"mannequin": "Mannequin",
	"mimic": "Mimic",
	"killer": "Killer",
	"grabber": "Grabber",
	"skinstealer": "SkinStealer",
	"burnt": "Burnt",
	"tallone": "TallOne",
}
## Scare events the console can fire (`event <id>`, or the buttons on WORLD & EVENTS): id -> what it does
const EVENTS := {
	"preacherwhisper": ["preacherWhisper", "a preacher's voice from down a corridor"],
	"wallknock": ["wallKnock", "knocking in the walls, ending nearer"],
	"breathbehind": ["breathBehind", "a breath on the back of your neck"],
	"powercut": ["powerCut", "the grid dies for a minute, something circles in the dark"],
	"redalert": ["redAlert", "every light drops to slow pulsing emergency red; something walks; a breath beside you"],
	"emergencypulse": ["emergencyPulse", "every light beats red like a heart, quickens, skips, fails"],
	"lightsout": ["lightsOut", "the grid fails in stages, then something walks up to you in the dark"],
	"onelamp": ["oneLamp", "everything dark but the tube over you; something breathes at the next"],
	"deadair": ["deadAir", "deafened: ringing, warped picture, two knocks behind you"],
	"machinevoice": ["machineVoice", "an old crushed TTS voice reads a disturbing line; a different one each time"],
	"ghostroster": ["ghostRoster", "a researcher who isn't anyone joins the expedition (sometimes it's you)"],
	"humrises": ["humRises", "the fluorescent hum climbs until it hurts, then every sound stops"],
	"partywall": ["partyWall", "a party behind the drywall; go to it and it stops dead, then one knock"],
	"phonering": ["phoneRing", "a phone ringing down the halls; it stops before you reach it, then rings behind you"],
	"houndpacing": ["houndPacing", "real footsteps far off behind the walls keeping pace with you; stop and they stop, then one step nearer"],
	"wallfootsteps": ["wallFootsteps", "a heavy walker on the far side of the wall, passing you parallel to where you face, muffled, then gone"],
	"run": ["run", "black, then red lights rush down the hall toward you with something heavy running under them"],
	"itheardyou": ["itHeardYou", "DO NOT SPEAK: it listens to your mic; say anything and the lights die and something comes"],
	"sayyourname": ["sayYourName", "the machine voice slowly says your actual callsign, twice"],
	"answerback": ["answerBack", "two knocks; say something and the wall knocks back once for every word"],
	"yourownvoice": ["yourOwnVoice", "your own voice, saying something you said earlier, from down the hall"],
	"doorbell": ["doorbell", "a doorbell, far off, then nearer, in a building with no doors"],
	"looktogether": ["lookTogether", "an advisory: do not look up... we will look together. Your head tilts back by itself"],
	"soundstoavoid": ["soundsToAvoid", "a card lists three sounds to avoid; a little later you hear the third"],
	"countdown": ["countdown", "a timer counts down from 60; at zero nothing happens; then it counts up"],
}
const ORDER := ["bacteria", "mannequin", "mimic", "killer", "grabber", "skinstealer", "burnt", "tallone"]
# other things you might type for a name
const ALIASES := {"entity": "bacteria", "skin": "skinstealer", "stealer": "skinstealer", "theburnt": "burnt", "tall": "tallone", "tallone": "tallone"}
const GRABBER_STATES := ["hunch", "peek", "chase", "drag"]
const BURNT_ACTIONS := ["peek", "retreat", "hide", "charge", "flank", "commit", "grab", "status"]
# the first-person arms' one-shots (torch_model.gd): console name -> clip. "swap" goes the way R does,
# sound and light with it, but spends no battery pack.
const HAND_ANIMS := {
	"swap": "TorchReload",
	"smack": "TorchSmack",
	"squeeze": "TorchSqueeze",
	"fingers": "TorchFingers",
	"regrip": "TorchRegrip",
	"flinch": "TorchFlinch",
	"look": "IdleLookHand",
	"flex": "IdleFlex",
	"rub": "IdleRub",
}
const HAND_ANIM_LABELS := {"swap": "BATTERY SWAP", "smack": "SMACK TORCH", "squeeze": "SQUEEZE", "fingers": "FINGER ROLL",
	"regrip": "REGRIP", "flinch": "FLINCH", "look": "LOOK AT HAND", "flex": "FLEX HAND", "rub": "RUB FINGERS"}
const HAND_ANIM_WAIT := 0.35      # s from the menu closing to the clip, so its start is seen

const Kit := preload("res://scripts/UI/inventory/terminal_kit.gd")
const FONT_PATH := "res://fonts/vcr.ttf"
const AMBER := Kit.AMBER
const TEXT := Kit.TEXT
const MUTED := Kit.MUTED
const GREEN := Kit.GREEN
const RED := Kit.RED
var font: Font

# The console stays locked until the code is typed once; static, so it holds until the game is closed
const ACCESS_CODE := "200021"
static var unlocked := false
var gate: PanelContainer
var gate_input: LineEdit
var gate_msg: Label

var root: Node
var menu_window: PanelContainer
var screen_overlay: PanelContainer
var overlay_label: Label
var quick_badge_btn: Button

# Quick cheat buttons (top bar)
var btn_noclip: Button
var btn_fullbright: Button
var btn_godmode: Button
var btn_inf_stamina: Button
var btn_inf_sanity: Button
var btn_inf_torch: Button
var btn_freeze_ai: Button
var btn_header_hud: Button
var btn_toggle_hud: Button

# Tabs & content panels
var tab_buttons := {}
var tab_panels := {}
var current_tab := "cheats"

# Speed & Jump labels
var speed_label: Label
var speed_slider: HSlider
var jump_label: Label
var jump_slider: HSlider
var eyes_slider: HSlider
var eyes_count_label: Label

# Teleport coordinate inputs
var tp_x_input: LineEdit
var tp_z_input: LineEdit

# Console tab widgets
var log_label: RichTextLabel
var input: LineEdit
var history: Array = []
var history_at := 0

# Survivor model preview
var dbg_model: Node3D
var dbg_anim: AnimationPlayer
var dbg_anims: Array[String] = []
var dbg_anims_idx := 0

const LevelData := preload("res://scripts/World/level/level_data.gd")
var marks := {}                   # bookmark name -> [position, yaw]
var marks_flow: HFlowContainer
var level_buttons: Array = []
var time_label: Label
var time_slider: HSlider
var hint_label: Label
var hand_anim_last := "swap"      # the arm clip P plays again

# Animation test walker (ANIMATION tab)
var walker: AnimWalker
var walker_status: Label
var btn_walker_slow: Button

## Into the CONSOLE tab, and Godot's Output panel too: the other tabs' buttons (SPAWN etc.) report here,
## where it isn't seen unless that tab is open
func _print(text: String) -> void:
	if log_label != null:
		log_label.append_text(text + "\n")
	print_rich("[debug] " + text)


# Defined in debug_console.gd (the command line); the menu layers above this one connect to them.
func _submit(_line: String) -> void:
	pass

func _recall(_dir: int) -> void:
	pass
