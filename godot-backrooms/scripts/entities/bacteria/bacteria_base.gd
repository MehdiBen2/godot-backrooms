extends Node3D
## THE BACTERIA, layer 1 of 5: its tuning (ENTITY in js/config.js), the scene it lives in and the
## state machine's bookkeeping. The layers build on each other:
##   bacteria_base.gd    config, references, state          (this file)
##   bacteria_nav.gd     flow fields, steering, picking places to go
##   bacteria_senses.gd  sight, hearing, who it hunts
##   bacteria_stalk.gd   stalking from corners, fleeing, lying in wait
##   bacteria.gd         the brain, movement, voice, fear and the kill (the node's script)

const GridNav := preload("res://scripts/world/grid_nav.gd")
const CELL := 4.5

const RADIUS := 0.6
const TERROR_DISTANCE := 18.0
const ROAM_SPEED := 1.1
const INVESTIGATE_SPEED := 2.0
const SEARCH_SPEED := 1.6
const CHASE_SPEED := 6.0
const LUNGE_SPEED := 7.5
const TURN_RATE := 6.0
const SIGHT_RANGE := 16.0
const SIGHT_FOV := 2.2
const TORCH_SIGHT_BONUS := 1.6
const CROUCH_SIGHT := 0.55
const STILL_SIGHT := 3.5
const AWARENESS_RISE := 2.2
const AWARENESS_FALL := 0.3
const HEAR_SPRINT := 15.0
const HEAR_WALK := 6.0
const HEAR_CROUCH := 1.2
const HEAR_GUNSHOT := 45.0
const LOSE_TRACK_TIME := 3.5
const SEARCH_TIME := 16.0
const LUNGE_RANGE := 2.6
const MENACE_TIME := 50.0
const GIVE_UP_DISTANCE := 20.0
const GIVE_UP_TIME := 1.8
const WINDED_TIME := 8.0
const LOUDNESS := 0.85
const STALK_COOLDOWN := 60.0
const STALK_CHANCE := 0.35
const STALK_MIN_DIST := 9.0
const STALK_MAX_DIST := 26.0
const STALK_TIME := 14.0
const STALK_WATCHED := 0.5
const STALK_FLUSH_DIST := 6.0
const MANNEQUIN_FEAR_RANGE := 12.0
const FLEE_SPEED := 9.5
const RESPAWN_MIN_CELLS := 18
const SPAWN_GRACE := 8.0
const MODEL_HEIGHT := 4.6
const KILL_DISTANCE := 1.35
# Lying in wait: having lost you, now and then it doesn't wander off. It creeps to where you were
# heading and crouches there in silence, sharper-eyed and sharper-eared than usual, until you walk into it.
const LURK_CHANCE := 0.45
const LURK_TIME := 26.0
const LURK_SPEED := 1.4
const LURK_SENSE := 2.4           # awareness builds this much faster while it waits
const LURK_HEAR := 1.4            # and it hears this much further
const LURK_POUNCE := 7.0          # seen this close while it waits: it doesn't wait for certainty

# ---- co-op: the host's PC runs the AI and hunts the nearest living survivor; everyone else gets a
# puppet that follows the host's broadcast (bacteria_net.gd). Order matters: it is sent as an index.
const STATES := ["roam", "investigate", "search", "chase", "screech", "stalk", "stunned", "flee", "lurk"]

var level: Node
var player: CharacterBody3D
var scares: Node
var mannequin: Node                    # optional: it bolts from THE MANNEQUIN
var nav: GridNav
var n := 0
var rng := RandomNumberGenerator.new()
var rig: Node3D                        # bacteria_rig.gd: the body and its animation

# ---- state machine
var state := "roam"
var state_time := 0.0
var pause := 0.0
var look_yaw := NAN
var yaw := 0.0
var speed_now := 0.0
var vel := Vector3.ZERO
var winded := 0.0
var enraged := 0.0
var staring := 0.0
var stun_timer := 0.0
var lunge := 0.0
var lunge_windup := 0.0
var since_encounter := 0.0

func set_state(s: String) -> void:
	if state == s:
		return
	state = s
	state_time = 0.0
	pause = 0.0
	look_yaw = NAN

func hunting() -> bool:
	return state == "chase" or state == "screech"

func turn_toward(target_yaw: float, rate: float, delta: float) -> void:
	var d := wrapf(target_yaw - yaw, -PI, PI)
	yaw += clampf(d, -rate * delta, rate * delta)
