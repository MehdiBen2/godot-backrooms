extends "res://scripts/Entities/model_entity.gd"
## THE SHROUD. A figure under a heavy black cloth that drags the floor, near five metres tall at the size main.tscn
## gives it (the rig is 2.75 m; everything that depends on its size scales with it: `_k`). Its head is one great eye
## sunk in a crater of raw muscle, ringed with smaller eyes; under the cloth it walks on five human limbs.
##
## THE STARE (its mechanic). Its eye beats you when you look at it; its body beats you when you don't.
##   dormant  it stands still with its eye rolled back to the white. It cannot see. A survivor within wake range in a
##            clear line (WAKE_ROAM, or WAKE_LURK for a mark set to lurk), or light on its eye, and the eye rolls down.
##   watch    SOMEONE is looking at its eye: it does not move a limb. But it stares back, and each survivor looking at
##            it has their own stare taking hold (`_locks`), faster the nearer they are. On your own screen: the view
##            dragged toward the eye, the picture tunnelling and greying, your heart climbing, and past half the torch
##            in your hand flickering.
##   crawl    NOBODY is looking at it: it scuttles at the nearest survivor on its five limbs, faster than a walk,
##            slower than a sprint, and every stare slowly lets go.
##   blind    a torch held on its eye (TORCH_HOLD s), or a camera flash: it recoils, the eye rolls back, every stare is
##            broken, and it backs off. Use the torch early: once your stare is past half, your torch is failing.
##   pull     a stare is full: that survivor is hypnotised and walks to it, the view held on the eye.
##   kill     taken under the shroud (the "kill" clip, art/Shroud_rig.blend): face to face with the eye; the cloth lifts
##            like a curtain and pale hands take your head; dragged down and under into the hollow among its limbs;
##            the hem drops; then, lying on the floor under it, the corridor slides by through the gap under the hem
##            as it crawls off with you. The camera rides the clip's "Cam" bone looking at its "CamLook" bone.
##   fed      it stands over where it took someone, idle, for FED_TIME, then goes dormant.
## Also taken if it reaches you (GRAB_DIST) while nobody is looking. A hiding place (player.hidden) hides you.
##
## Co-op (shroud_net.gd): the host runs it for everyone and sends it out 20 times a second, every survivor's stare
## with it; a guest's copy is a puppet that follows, and shows the guest their own stare. A guest it takes plays the
## pull and the death scene on their own machine (Net.send_shroud_take), while the host plays the clip in the world.
## Placed with an Entity mark of Kind "shroud" in the level editor (roam / lurk), and kept to an "area_shroud"
## territory if one is painted. Console: spawn shroud / despawn shroud / shroud wake|stare|kill|status.

const EntityMarks := preload("res://scripts/Entities/entity_marks.gd")
const ShroudNet := preload("res://scripts/Entities/shroud/shroud_net.gd")
const STATES := ["off", "dormant", "watch", "crawl", "blind", "pull", "kill", "fed"]
const CELL := 4.5
const RADIUS := 0.5                     # (times _k, at most MAX_RADIUS)
const MAX_RADIUS := 0.9

@export var crawl_speed := 3.4          # m/s: faster than a walk (2.6), slower than a sprint (4.55)
@export var look_cos := 0.94            # ~20 degrees from the middle of your view is "looking at it"
@export var stare_near := 2.4           # s of looking to be taken, close up...
@export var stare_far := 5.5            # ...and at STARE_FAR_DIST
@export var view_pull := 1.0            # 0..1 how hard the stare drags your view (reduced motion)
@export var kill_shake := 1.0

const WAKE_ROAM := 22.0                 # m in a clear line: its eye rolls down
const WAKE_LURK := 10.0                 # (a mark set to lurk: it waits for you to come this close)
const STARE_FAR_DIST := 24.0
const SEE_DIST := 36.0
const LOSE_TIME := 10.0                 # s without anyone in a clear line before it goes dormant again
const LOCK_DECAY := 0.3                 # stare per second while that survivor is not looking
const REMOTE_LOOK_COS := 0.92           # a guest's look, as the host rebuilds it from their yaw and pitch
const TORCH_COS := 0.975                # ~13 degrees: the beam's middle
const TORCH_RANGE := 16.0
const TORCH_HOLD := 0.5
const TORCH_FAILS := 0.55               # past this much stare your torch flickers
const BLIND_TORCH := 4.0
const BLIND_FLASH := 9.0
const FLASH_RANGE := 20.0
const FLASH_CONE := 0.9
const GRAB_DIST := 1.7                  # (times _k)
const KILL_DIST := 1.6                  # (times _k) the clip's victim stands this far in front of its root
const PULL_SPEED := 3.2
const PULL_MAX := 8.0                   # s of being pulled before it comes the rest of the way itself
const FED_TIME := 25.0
const CRAWL_CLIP_SPEED := 1.57          # m/s the crawl clip is made for (times _k)
const KILL_T := 6.0
const KILL_BLEND := 0.35
const LOOPED := ["idle", "crawl", "stare"]
const SFX := "res://audio/entity/shroud/"
const STEP_EVERY := 0.175               # s between limbs coming down, at the crawl clip's own speed (5 to a 0.875 s stride)
const CRAWL_LOOP := "res://audio/entity/shroud/crawl_loop.wav"   # five limbs skittering (dragon-studio, giant spider)
const EYE_ROLL := 1.3
const MARK_SPAWN_DIST := 50.0
const MARK_ARRIVE_AFTER := 200.0

var state := "off"
var t := 0.0
var yaw := 0.0
var lock := 0.0                         # 0..1 this machine's own player's stare (the screen effects)
var scares: Node
var _pl                                  # this machine's player (player.gd), untyped for its fields
var skel: Skeleton3D
var _ap: AnimationPlayer
var _clip := ""
var _bone := {}
var _k := 1.0                           # how big it is next to its rig
var _eye_fwd_local := Vector3.FORWARD
var _eye_dir := Vector3.ZERO
var _eye_mode := "roll"                 # roll | player | front
var _speed := 0.0
var _unseen := 0.0
var _torch_t := 0.0
var _blind_for := 0.0
var _blind_from := Vector3.ZERO
var _looked := false                    # this machine's player is looking at it
var _flicker_t := 0.0
var _hb_t := 0.0
var _crawl: AudioStreamPlayer3D        # the skitter under the cloak, louder and quicker the faster it goes
var _crawl_gain := 0.0
var _step_t := 0.0
var _takes := {}                        # sound name -> its takes' paths
var _last_take := {}
var _fx := {}
var _locks := {}                        # host: survivor id -> 0..1 their stare
var _tid := -1                          # host: the survivor it goes for
var _lurk := false
var _mark_pending := false
var _lod_go := false
# co-op
var net: RefCounted
var puppet := false
var _victim_id := -1                    # host: the guest it is taking (their machine plays the camera)
var _victim_t := 0.0
var _net_taken := false                 # guest: it is taking this machine's player
var _snub := 0.0
# the kill (on the victim's own machine)
var _from := Transform3D.IDENTITY
var _from_fov := 75.0
var _sounded := {}
var _light: OmniLight3D
var _muffled := false

func _ready() -> void:
	super._ready()
	nav.area_kind = "shroud"
	process_priority = 100              # after the player: during the stare and the kill the view is ours to bend
	scares = get_parent().get_node_or_null("Scares")
	_pl = player
	net = ShroudNet.new(self)
	var marks := EntityMarks.of_kind(level, "shroud")
	_mark_pending = not marks.is_empty()
	EntityLOD.register(self, {} if marks.is_empty() else {"mark": EntityMarks.world_pos(marks[0]),
		"spawn_dist": MARK_SPAWN_DIST, "arrive_after": MARK_ARRIVE_AFTER})

func lod_spawned() -> bool:
	return present or _lod_go

func lod_engaged() -> bool:
	return state not in ["off", "dormant", "fed"]

func lod_spawn(_at_mark: bool) -> void:
	_lod_go = true

func _spawn_from_mark() -> void:
	var marks := EntityMarks.of_kind(level, "shroud")
	if marks.is_empty() or not spawn_at(EntityMarks.world_pos(marks[0])):
		return
	yaw = rotation.y
	_lurk = EntityMarks.lurks(marks[0])
	_go_dormant()

func _build() -> bool:
	if not super._build(): return false
	_k = body.scale.x
	var found := body.find_children("*", "Skeleton3D", true, false)
	skel = found[0] as Skeleton3D if not found.is_empty() else null
	if skel != null:
		for n in ["Eye", "Head", "Cam", "CamLook", "Root", "Body"]:
			var i := skel.find_bone(n)
			if i >= 0: _bone[n] = i
		if _bone.has("Eye"):
			# the model's front (+Z) in skeleton space, in the eye bone's own axes: its look axis
			var fwd_s := (skel.global_transform.basis.inverse() * global_transform.basis.z).normalized()
			_eye_fwd_local = (skel.get_bone_global_rest(_bone.Eye).basis.inverse() * fwd_s).normalized()
	var aps := body.find_children("*", "AnimationPlayer", true, false)
	_ap = aps[0] as AnimationPlayer if not aps.is_empty() else null
	if _ap != null:
		_ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		for a in LOOPED:
			if _ap.has_animation(a): _ap.get_animation(a).loop_mode = Animation.LOOP_LINEAR
	else:
		push_warning("Shroud: %s has no clips" % model)
	for mi: MeshInstance3D in body.find_children("*", "MeshInstance3D", true, false):
		mi.extra_cull_margin = 4.0 * _k    # (the lifted hem and the reaching arms leave the rest-pose box)
	return true

# ---------------------------------------------------------------- the mind (single player and the co-op host)
func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	puppet = Net.is_online() and not Net.hosting
	if puppet:
		_physics_puppet(delta)
		return
	if Net.is_online(): net.send(delta)
	if _mark_pending and Game.playing and not Game.dead and player != null and EntityLOD.is_spawned(self):
		_mark_pending = false
		_spawn_from_mark()
	if not present or player == null: return
	if Game.freeze_ai and state not in ["kill", "pull"]: return
	t += delta
	match state:
		"dormant": _dormant(delta)
		"watch", "crawl": _hunt(delta)
		"blind": _blind(delta)
		"pull": _pull(delta)
		"kill": _kill_tick(delta)
		"fed":
			if t > FED_TIME: _go_dormant()

func _go_dormant() -> void:
	state = "dormant"
	t = 0.0
	_speed = 0.0
	_eye_mode = "roll"
	_locks = {}
	_victim_id = -1
	_set_lock(0.0)

func _dormant(delta: float) -> void:
	_eye_mode = "roll"
	_set_lock(maxf(0.0, lock - delta * LOCK_DECAY))
	var wake := WAKE_LURK if _lurk else WAKE_ROAM
	for sv: Dictionary in _targets():
		var d := _flat_dist(sv.pos)
		if (d < wake and _clear_to(sv.pos)) or (_torching(sv) and d < TORCH_RANGE):
			_tid = sv.id
			_wake()
			return

func _wake() -> void:
	state = "watch"
	t = 0.0
	_unseen = 0.0
	_lurk = false
	_eye_mode = "player"
	if scares != null:
		_snd("wake", _eye_pos(), 1.0, 8.0 * _k)
	Game.fear = maxf(Game.fear, 0.6)

## Awake: someone looks (watch) or nobody does (crawl)
func _hunt(delta: float) -> void:
	var svs := _targets()
	_looked = false
	var watched := false
	var watcher := Vector3.ZERO
	var any_clear := false
	var torched := false
	var torch_from := Vector3.ZERO
	var seen_ids := {}
	for sv: Dictionary in svs:
		var id: int = sv.id
		seen_ids[id] = true
		var d := _flat_dist(sv.pos)
		var clear := d < SEE_DIST and _clear_to(sv.pos)
		if not clear:
			_locks[id] = maxf(0.0, float(_locks.get(id, 0.0)) - delta * LOCK_DECAY)
			continue
		any_clear = true
		if _torching(sv):
			torched = true
			torch_from = _eye_of(sv)
		var looking := _watching(sv)
		if sv.local: _looked = looking
		if looking:
			if not watched: watcher = sv.pos
			watched = true
			var near := clampf((d - 3.0 * _k) / (STARE_FAR_DIST - 3.0 * _k), 0.0, 1.0)
			_locks[id] = float(_locks.get(id, 0.0)) + delta / lerpf(stare_near, stare_far, near)
			if _locks[id] >= 1.0:
				_take(sv, true)
				return
		else:
			_locks[id] = maxf(0.0, float(_locks.get(id, 0.0)) - delta * LOCK_DECAY)
	for id in _locks.keys():
		if not seen_ids.has(id): _locks.erase(id)
	var me := _local_id()
	_set_lock(float(_locks.get(me, 0.0)))
	if not seen_ids.has(me): _looked = false
	# a torch on its eye: it recoils
	if torched:
		_torch_t += delta
		if _torch_t >= TORCH_HOLD:
			blind(BLIND_TORCH, torch_from, false)
			return
	else:
		_torch_t = maxf(0.0, _torch_t - delta)
	_unseen = 0.0 if any_clear else _unseen + delta
	if svs.is_empty() or _unseen > LOSE_TIME:
		_go_dormant()
		return
	if watched:
		state = "watch"
		_speed = move_toward(_speed, 0.0, delta * 12.0)          # it stops dead the moment anyone looks
		_face(watcher, delta * 3.0)
	else:
		state = "crawl"
		var tg := Net.nearest_survivor(global_position, _tid)
		if tg.is_empty() or (tg.local and not _can_target_local()):
			tg = _nearest_of(svs)
		if tg.is_empty():
			return
		_tid = tg.id
		_speed = move_toward(_speed, crawl_speed, delta * 6.0)
		_move_toward(tg.pos, _speed, delta)
		if _flat_dist(tg.pos) < GRAB_DIST * _k:
			_take(tg, false)
			return
	_stare_fx(delta)

## It has someone: hypnotised (`pull`) or grabbed. The local player plays it here; a guest on their own machine
func _take(sv: Dictionary, pull: bool) -> void:
	_tid = sv.id
	if sv.local:
		if pull: _begin_pull()
		else: _begin_kill()
		return
	_victim_id = sv.id
	_victim_t = 0.0
	Net.send_shroud_take(_victim_id, pull)
	if pull:
		state = "pull"                      # (it waits, staring, while they walk to it on their own screen)
		t = 0.0
		_speed = 0.0
	else:
		_root_kill(sv.pos)

## One of its recorded sounds at `pos`: audio/entity/shroud/<name>.wav or one of its takes (<name>_2.wav, <name>_3.wav,
## ...), picked at random and never the same take twice running, so it never sounds like the same clip again
func _snd(name: String, pos: Vector3, level: float, ref: float, occlude := true) -> void:
	if scares == null: return
	if not _takes.has(name):
		var list: Array[String] = [SFX + name + ".wav"]
		var i := 2
		while ResourceLoader.exists(SFX + "%s_%d.wav" % [name, i]):
			list.append(SFX + "%s_%d.wav" % [name, i])
			i += 1
		_takes[name] = list
	var takes: Array = _takes[name]
	var pick := randi() % takes.size()
	if takes.size() > 1 and pick == int(_last_take.get(name, -1)):
		pick = (pick + 1 + randi() % (takes.size() - 1)) % takes.size()
	_last_take[name] = pick
	scares.spawn3d(load(takes[pick]), pos, level, "Scares", ref, randf_range(0.94, 1.05), occlude)

## Every frame, host and puppet alike. Crawling flat out it is one long skitter (the loop, louder and quicker the
## faster it goes); creeping (backing off from a torch, setting off, pulling up) the loop falls away and each limb is
## heard coming down on its own, a footfall cut from the same recording, five to a stride, further apart the slower it
## goes. Everything cuts out the moment it stops dead.
func _crawl_audio(delta: float) -> void:
	var r := 0.0                                   # its speed against the crawl clip's
	if present and body != null and is_visible_in_tree() and state in ["crawl", "watch", "blind", "pull", "kill"]:
		r = clampf(_speed / (CRAWL_CLIP_SPEED * _k), 0.0, 1.3)
	var fast := smoothstep(0.5, 0.85, r)
	_slow_steps(delta, r, 1.0 - fast)
	var want := r * fast
	_crawl_gain = move_toward(_crawl_gain, want, delta * (10.0 if want < _crawl_gain else 4.0))
	if _crawl_gain <= 0.01:
		if _crawl != null and _crawl.playing: _crawl.stop()
		return
	if _crawl == null:
		_crawl = AudioStreamPlayer3D.new()
		_crawl.stream = load(CRAWL_LOOP)
		_crawl.bus = "Scares"
		_crawl.max_distance = 60.0
		_crawl.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(_crawl)
	_crawl.unit_size = 5.0 * _k
	_crawl.position = Vector3.UP * 0.3
	if not _crawl.playing:
		_crawl.play(randf() * 3.0)
	var audio = scares.audio if scares != null else null
	if audio != null: audio.occlude(_crawl)
	_crawl.volume_db = linear_to_db(maxf(_crawl_gain * 0.9, 0.0001))
	_crawl.pitch_scale = lerpf(0.8, 1.0, clampf(_crawl_gain, 0.0, 1.0))

## Creeping: one limb at a time, somewhere under the hem
func _slow_steps(delta: float, r: float, level: float) -> void:
	if r < 0.05 or level <= 0.02:
		_step_t = minf(_step_t, 0.05)              # (the first limb lands as soon as it moves again)
		return
	_step_t -= delta
	if _step_t > 0.0: return
	_step_t = STEP_EVERY / r * randf_range(0.75, 1.3)   # (five limbs never keep perfect time)
	var a := randf() * TAU
	var p := global_position + Vector3(sin(a), 0.05, cos(a)) * 0.7 * _k
	_snd("step", p, 0.75 * level * randf_range(0.7, 1.0), 4.0 * _k)

## Blinded (torch held on its eye, or a camera flash): it recoils, the eye rolls back, every stare is broken
func blind(seconds: float, from: Vector3, flash: bool) -> void:
	_blind_for = seconds
	_blind_from = from
	state = "blind"
	t = 0.0
	_torch_t = 0.0
	_eye_mode = "roll"
	_clip = ""
	_locks = {}
	_set_lock(0.0)
	_restore_fx()
	if scares != null:
		_snd("recoil_flash" if flash else "recoil", _eye_pos(), 1.0, 8.0 * _k)

func _blind(delta: float) -> void:
	_eye_mode = "roll"
	if t > 0.9:                                    # after the flinch it backs away from the light
		var away := global_position - _blind_from
		away.y = 0.0
		var spd := 2.6 if _blind_for >= BLIND_FLASH else 1.0
		if away.length() > 0.1 and t < _blind_for * 0.7:
			_speed = spd
			var keep := yaw
			_move_toward(global_position + away.normalized() * 4.0, spd, delta)
			yaw = lerp_angle(keep, atan2(-away.x, -away.z), minf(1.0, delta * 4.0))   # (backs off, still facing it)
			rotation.y = yaw
		else:
			_speed = 0.0
	if t >= _blind_for:
		for sv: Dictionary in _targets():
			if _flat_dist(sv.pos) < SEE_DIST and _clear_to(sv.pos):
				_wake()
				return
		_go_dormant()

## A camera flash went off at `origin` along `look` (flash_tool.gd hit; in co-op the host runs it for everyone's)
func flashed(origin: Vector3, look: Vector3) -> bool:
	if puppet or not present or not visible or state in ["off", "pull", "kill", "fed"]: return false
	var to := _eye_pos() - origin
	if to.length() > FLASH_RANGE: return false
	if to.normalized().dot(look) < FLASH_CONE: return false
	if not nav.clear_line(origin.x, origin.z, global_position.x, global_position.z): return false
	blind(BLIND_FLASH, origin, true)
	return true

# ---------------------------------------------------------------- who it can see
## The survivors it can go for (Net.survivors: this machine's player and, on the host, the guests)
func _targets() -> Array:
	var out: Array = []
	for sv: Dictionary in Net.survivors():
		if sv.local and not _can_target_local(): continue
		out.append(sv)
	return out

func _nearest_of(svs: Array) -> Dictionary:
	var best := {}
	var bd := INF
	for sv: Dictionary in svs:
		var d := _flat_dist(sv.pos)
		if d < bd:
			bd = d
			best = sv
	return best

func _can_target_local() -> bool:
	if _pl.dead or _pl.spawn_grace > 0.0 or Game.god_mode: return false
	var h = _pl.get("hidden")
	return not (h != null and bool(h))

func _local_id() -> int:
	return multiplayer.get_unique_id() if Net.is_online() else 1

## A survivor's eyes, and the way they look (a guest's from the yaw and pitch they send: remote_player.gd)
func _eye_of(sv: Dictionary) -> Vector3:
	if sv.local: return (_pl.cam as Camera3D).global_position
	return (sv.pos as Vector3) + Vector3.UP * 1.6

func _look_of(sv: Dictionary) -> Vector3:
	if sv.local: return -(_pl.cam as Camera3D).global_transform.basis.z
	var r: Node = sv.node
	var yw: float = r.get("target_yaw") if r.get("target_yaw") != null else 0.0
	var pt: float = r.get("target_pitch") if r.get("target_pitch") != null else 0.0
	return Vector3(-sin(yw) * cos(pt), sin(pt), -cos(yw) * cos(pt))

func _watching(sv: Dictionary) -> bool:
	var to := (_eye_pos() - _eye_of(sv)).normalized()
	return _look_of(sv).dot(to) > (look_cos if sv.local else REMOTE_LOOK_COS)

func _torching(sv: Dictionary) -> bool:
	var on := false
	if sv.local:
		on = _pl.flash_on and _pl.battery > 0.0
	else:
		var r: Node = sv.node
		on = r.get("torch_on") != null and bool(r.get("torch_on"))
	if not on: return false
	var to := _eye_pos() - _eye_of(sv)
	if to.length() > TORCH_RANGE: return false
	return _look_of(sv).dot(to.normalized()) > TORCH_COS

func _flat_dist(q: Vector3) -> float:
	var p := global_position
	return Vector2(q.x - p.x, q.z - p.z).length()

func _clear_to(q: Vector3) -> bool:
	var p := global_position
	return nav.clear_line(p.x, p.z, q.x, q.z)

func _dist() -> float:
	return _flat_dist(player.global_position)

# ---------------------------------------------------------------- the stare, on your own screen
func _set_lock(v: float) -> void:
	lock = clampf(v, 0.0, 1.0)

func _stare_fx(delta: float) -> void:
	var k := lock
	_apply_fx({"fx_fade": 0.55 * k * k, "fx_sat": -0.65 * k, "fx_zoom": 0.06 * k * k, "fx_blur": 0.5 * k * k,
		"fx_warp": 0.006 * k * k})
	if state in ["watch", "crawl"]: Game.terror = maxf(Game.terror, 0.3 + 0.6 * k)
	if k > 0.05:
		_hb_t -= delta
		if _hb_t <= 0.0 and scares != null:
			_hb_t = lerpf(1.1, 0.38, k)
			scares.heartbeat(0.4 + 0.6 * k, 1.0 + 0.3 * k)
	if k > TORCH_FAILS and _pl.flash_on:
		_flicker_t -= delta
		if _flicker_t <= 0.0:
			_flicker_t = randf_range(0.6, 1.4) * (1.6 - k)
			_pl.trigger_flicker(randf_range(0.15, 0.4) * k)

## Your view, dragged toward the eye while you look at it (in _process, after the player has turned it)
func _drag_view(delta: float) -> void:
	if not _looked or state != "watch" or lock <= 0.0 or _pl.dead: return
	var cam: Camera3D = _pl.cam
	var to := (_eye_pos() - cam.global_position).normalized()
	var fwd := -cam.global_transform.basis.z
	var k := minf(1.0, delta * (0.4 + 4.0 * lock * lock) * view_pull)
	var want_yaw := atan2(-to.x, -to.z)
	var have_yaw := atan2(-fwd.x, -fwd.z)
	player.rotate_y(wrapf(want_yaw - have_yaw, -PI, PI) * k)
	cam.rotation.x = lerpf(cam.rotation.x, asin(clampf(to.y, -1.0, 1.0)), k)

## Game.fx_* are shared: add ours on top of whatever else drives them, and take back only ours
func _apply_fx(want: Dictionary) -> void:
	for key: String in want:
		var had: float = _fx.get(key, 0.0)
		var cur: float = Game.get(key)
		Game.set(key, cur - had + float(want[key]))
		_fx[key] = float(want[key])

func _restore_fx() -> void:
	for key: String in _fx:
		Game.set(key, float(Game.get(key)) - float(_fx[key]))
	_fx = {}

# ---------------------------------------------------------------- pulled in, and taken
## This machine's player is hypnotised: they walk to it
func _begin_pull() -> void:
	state = "pull"
	t = 0.0
	_speed = 0.0
	_pl.frozen = true
	player.velocity = Vector3.ZERO
	Game.fear = 1.0
	if scares != null:
		_snd("stare_full", _eye_pos(), 0.9, 8.0 * _k)

func _pull(delta: float) -> void:
	if _victim_id >= 0:                             # host: a guest walking to it on their own screen
		var sv := _survivor(_victim_id)
		if sv.is_empty():
			_go_dormant()
			return
		_face(sv.pos, delta * 6.0)
		if _flat_dist(sv.pos) <= KILL_DIST * _k + 0.4 or t > PULL_MAX:
			_root_kill(sv.pos)
		return
	if _pl.dead:
		_go_dormant()
		return
	_face(player.global_position, delta * 6.0)
	var to := global_position - player.global_position
	to.y = 0.0
	var d := to.length()
	var stop := KILL_DIST * _k
	if d <= stop + 0.08 or t > PULL_MAX:
		_begin_kill()
		return
	var spd := minf(PULL_SPEED, 0.6 + t * 2.2)
	var np := nav.resolve(player.global_position + to.normalized() * minf(spd * delta, d - stop), 0.35)
	player.global_position = Vector3(np.x, player.global_position.y, np.z)
	player.velocity = Vector3.ZERO

func _survivor(id: int) -> Dictionary:
	for sv: Dictionary in Net.survivors():
		if sv.id == id: return sv
	return {}

## Into the kill clip with the victim at `pp`: its root KILL_DIST behind them, facing them (where the clip has them)
func _root_kill(pp: Vector3) -> void:
	state = "kill"
	t = 0.0
	_clip = ""
	_speed = 0.0
	var f := Vector3(pp.x - global_position.x, 0.0, pp.z - global_position.z)
	var dir := f.normalized() if f.length() > 0.01 else Vector3(sin(yaw), 0.0, cos(yaw))
	var np := nav.resolve(pp - dir * KILL_DIST * _k, 0.2)
	global_position = Vector3(np.x, global_position.y, np.z)
	yaw = atan2(dir.x, dir.z)
	rotation.y = yaw

## This machine's player is taken: freeze, take the view
func _begin_kill() -> void:
	_root_kill(player.global_position)
	_sounded = {}
	_restore_fx()
	_set_lock(0.0)
	_pl.frozen = true
	player.velocity = Vector3.ZERO
	var cam: Camera3D = _pl.cam
	_from = cam.global_transform
	_from_fov = cam.fov
	Death.grab_begin()
	Game.fx_reset()
	if _light == null:
		_light = OmniLight3D.new()
		_light.light_color = Color(1.0, 0.35, 0.25)
		_light.shadow_enabled = false
		add_child(_light)
	_light.omni_range = 2.5 * _k
	_light.light_energy = 0.0
	_light.visible = true
	if scares != null:
		scares.seize()
		scares.gasp(0.8)

func _kill_tick(delta: float) -> void:
	if _victim_id >= 0:                             # host: a guest's death scene, playing on their screen
		_victim_t += delta
		if _victim_t > KILL_T + PULL_MAX + 6.0: _fed()       # (their result never came)
		return
	if t >= KILL_T: _die()

## The camera, riding the clip (_process: after the player, after the clip has been advanced)
func _kill_view(delta: float) -> void:
	if skel == null or not _bone.has("Cam"): return
	var cam: Camera3D = _pl.cam
	var pos := _bone_pos("Cam")
	var look := _bone_pos("CamLook")
	var dir := (look - pos).normalized()
	var fwd := Vector3(sin(yaw), 0.0, cos(yaw))
	var up := Vector3.UP.lerp(-fwd, smoothstep(0.8, 0.98, absf(dir.y))).normalized()
	var xf := Transform3D(Basis.looking_at(dir, up), pos)
	xf = _from.interpolate_with(xf, smoothstep(0.0, KILL_BLEND, t))
	var tr := 0.05 * _bump(t, 2.45, 0.5) + 0.04 * _bump(t, 3.0, 0.6) + 0.012 * smoothstep(4.6, 5.0, t)
	var jit := Vector3(sin(Game.time * 37.0), sin(Game.time * 29.0 + 1.3), sin(Game.time * 23.0 + 2.1)) * tr * kill_shake
	cam.global_transform = Transform3D(xf.basis, xf.origin + jit)
	var fov := _from_fov
	fov = lerpf(fov, 48.0, smoothstep(0.2, 1.4, t))       # into the eye
	fov = lerpf(fov, 82.0, smoothstep(2.2, 3.0, t))       # wide and close in the dark under it
	fov = lerpf(fov, 70.0, smoothstep(4.4, 5.2, t))
	cam.fov = fov
	player.velocity = Vector3.ZERO
	if _light != null:                                  # a little red light under the cloth, so the dark is not empty
		_light.global_position = pos + Vector3.UP * 0.25 * _k
		_light.light_energy = 0.7 * smoothstep(2.4, 3.0, t) * (1.0 - 0.6 * smoothstep(3.6, 4.2, t)) * (1.0 - smoothstep(5.4, 6.0, t))
	_kill_beats(delta)

func _bump(x: float, at: float, w: float) -> float:
	return maxf(0.0, 1.0 - absf(x - at) / w)

func _kill_beats(_delta: float) -> void:
	var cam_pos := (_pl.cam as Camera3D).global_position
	Game.fx_sat = lerpf(1.0, 0.35, smoothstep(0.0, 1.4, t))
	Game.fx_blur = 0.6 * smoothstep(0.6, 1.4, t) * (1.0 - smoothstep(1.4, 2.0, t))
	_once("quiet", t >= 0.3, func():
		_quiet(true)
		if scares != null: scares.heartbeat(1.0, 0.8)
	)
	_once("hem", t >= 1.3, func():
		if scares != null:
			_snd("kill_hem", global_position + Vector3.UP * _k, 1.0, 3.0 * _k, false)
	)
	_once("grab", t >= 2.45, func():
		Game.fx_shock = 1.0
		Game.glitch = 1.0
		_pl.jolt(2.0)
		if scares != null:
			scares.seize()
			scares.gasp(1.0)
			_snd("kill_grab", cam_pos, 1.0, 2.0, false)
		Death.lens_splat(Vector2(0.38, 0.42), Vector2(0.3, 1.0), 0.08)
	)
	_once("haul", t >= 3.0, func():
		_pl.jolt(1.5)
		if scares != null:
			_snd("kill_haul", global_position, 1.1, 4.0 * _k, false)
			scares.splat()
	)
	_once("dark", t >= 3.8, func():
		if scares != null:
			_snd("kill_dark", cam_pos, 0.9, 2.0, false)
			scares.heartbeat(1.0, 0.7)
	)
	Game.fx_static = 0.05 + 0.25 * smoothstep(2.4, 3.2, t) * (1.0 - 0.7 * smoothstep(4.5, 5.5, t))
	Game.fx_contrast = 1.0 + 0.25 * smoothstep(2.4, 3.2, t)
	Game.glitch = maxf(Game.glitch, 0.2 * smoothstep(2.4, 3.0, t))
	Game.terror = 1.0
	_once("drag", t >= 4.7, func():
		if scares != null: _snd("kill_drag", cam_pos, 1.0, 3.0, false)
	)
	if t > 4.7:
		_speed = CRAWL_CLIP_SPEED * _k
	_once("last", t >= 5.4, func():
		if scares != null: scares.death_voice()
	)
	Game.fx_blink = clampf(smoothstep(5.2, 5.95, t), 0.0, 1.0)
	Game.fx_fade = smoothstep(5.0, 6.0, t)

func _once(key: String, when: bool, call: Callable) -> void:
	if not when or _sounded.has(key): return
	_sounded[key] = true
	call.call()

func _quiet(on: bool) -> void:
	_muffled = on
	var au: Node = get_parent().get_node_or_null("Audio")
	if au != null:
		au.set_muffled(on)
		if on: au.set_dread(0.0)
	var amb: Node = get_parent().get_node_or_null("Audio/Ambience")
	if on and amb != null: amb.hush_for(0.02, KILL_T + 2.0)

## This machine's player dies under it
func _die() -> void:
	_pl.frozen = false
	if _light != null: _light.visible = false
	var fwd := Vector3(sin(yaw), 0.0, cos(yaw))
	Death.lying(global_position + fwd * 0.15 * _k, fwd)       # left lying under it, head toward where it faces
	Game.kill_player("THE SHROUD", Game.DeathType.STRANGLED)
	if _net_taken:                                            # (a guest: the host hears it is over)
		_net_taken = false
		_snub = 2.0
		Net.send_shroud_result()
	_fed()

func _fed() -> void:
	state = "fed"
	t = 0.0
	_speed = 0.0
	_eye_mode = "front"
	_clip = ""
	_victim_id = -1
	_locks = {}

# ---------------------------------------------------------------- body: the clips and the eye
func _process(delta: float) -> void:
	_crawl_audio(delta)
	if not present or body == null: return
	body.position = Vector3.ZERO
	body.rotation = Vector3(0.0, deg_to_rad(yaw_offset), 0.0)
	_animate(delta)
	_aim_eye(delta)
	var mine := state == "kill" and _victim_id < 0 and (not puppet or _net_taken)
	if mine:
		_kill_view(delta)
	elif state == "pull" and _victim_id < 0 and (not puppet or _net_taken):
		_pull_view(delta)
	else:
		if puppet: _looked = _clear_to(player.global_position) and _can_target_local() and _watching(_local_sv())
		_drag_view(delta)
	if state not in ["watch", "crawl", "pull", "kill"] and not _fx.is_empty():
		_restore_fx()

func _local_sv() -> Dictionary:
	return {"local": true, "pos": player.global_position, "id": _local_id()}

func _pull_view(delta: float) -> void:
	var cam: Camera3D = _pl.cam
	var to := (_eye_pos() - cam.global_position).normalized()
	var want := Transform3D(Basis.looking_at(to, Vector3.UP), cam.global_position)
	cam.global_transform = cam.global_transform.interpolate_with(want, minf(1.0, delta * 6.0))
	cam.fov = lerpf(cam.fov, 62.0, minf(1.0, delta * 1.5))
	_apply_fx({"fx_fade": 0.6, "fx_sat": -0.7, "fx_zoom": 0.07, "fx_blur": 0.5, "fx_warp": 0.01})

func _animate(delta: float) -> void:
	if _ap == null: return
	var clip := "idle"
	var speed := 1.0
	var fade := 0.3
	var stride := CRAWL_CLIP_SPEED * _k
	match state:
		"watch":
			clip = "stare"
			fade = 0.25
		"crawl":
			clip = "crawl" if _speed > 0.3 else "stare"
			speed = maxf(0.6, _speed / stride)
			fade = 0.15
		"blind":
			if t < 1.0:
				clip = "recoil"
				fade = 0.08
			elif _speed > 0.3:
				clip = "crawl"
				speed = -maxf(0.6, _speed / stride)        # (backing away: the scuttle run backward)
		"pull":
			clip = "stare"
		"kill":
			clip = "kill"
			fade = 0.05
	if clip != _clip:
		if not _ap.has_animation(clip): return
		_ap.play(clip, fade)
		if clip == "kill" and puppet and not _net_taken: _ap.seek(t, true)   # (a guest watching it take someone else)
		_clip = clip
	_ap.speed_scale = speed
	_ap.advance(delta)

## The great eye: rolled back to the white when it cannot see; else on this machine's player (every survivor feels
## watched), or on the victim's eyes in the death scene
func _aim_eye(delta: float) -> void:
	if skel == null or not _bone.has("Eye"): return
	var ei: int = _bone.Eye
	var g := skel.get_bone_global_pose(ei)
	var fwd: Vector3 = (g.basis * _eye_fwd_local).normalized()
	var up_s := (skel.global_transform.basis.inverse() * Vector3.UP).normalized()
	var mode := _eye_mode
	if puppet and not _net_taken:
		mode = "roll" if state in ["dormant", "blind", "off"] else ("front" if state == "fed" else "player")
	var want := fwd
	match mode:
		"roll":
			want = fwd.rotated(fwd.cross(up_s).normalized(), -EYE_ROLL) if absf(fwd.dot(up_s)) < 0.98 else fwd
		"player":
			var c: Vector3 = (_pl.cam as Camera3D).global_position if state != "kill" else _bone_pos("Cam")
			var to := skel.global_transform.affine_inverse() * c - g.origin
			if to.length() > 0.01: want = to.normalized()
			if want.angle_to(fwd) > 1.1: want = fwd.slerp(want, 1.1 / want.angle_to(fwd))   # (it can only turn so far)
	if state == "kill" and t < 2.6:
		var c2 := skel.global_transform.affine_inverse() * _bone_pos("Cam") - g.origin
		if c2.length() > 0.01: want = c2.normalized()
	if _eye_dir == Vector3.ZERO: _eye_dir = want
	var rate := 9.0 if mode == "player" else 4.0
	_eye_dir = _eye_dir.slerp(want, minf(1.0, delta * rate)).normalized()
	if _eye_dir.is_equal_approx(fwd): return
	var newb := Basis(Quaternion(fwd, _eye_dir)) * g.basis
	var parent := skel.get_bone_parent(ei)
	var pb := skel.get_bone_global_pose(parent).basis if parent >= 0 else Basis.IDENTITY
	skel.set_bone_pose_rotation(ei, (pb.inverse() * newb).get_rotation_quaternion())

# ---------------------------------------------------------------- helpers
func _bone_pos(n: String) -> Vector3:
	if skel == null or not _bone.has(n): return global_position + Vector3.UP * 2.5 * _k
	return skel.global_transform * skel.get_bone_global_pose(_bone[n]).origin

func _eye_pos() -> Vector3:
	return _bone_pos("Eye")

func _face(at: Vector3, k: float) -> void:
	yaw = lerp_angle(yaw, atan2(at.x - global_position.x, at.z - global_position.z), minf(1.0, k))
	rotation.y = yaw

## Toward `to`: straight when it can see it, else down the grid's flow (nav.bfs)
var _flow := PackedInt32Array()
var _flow_key := -1
var _flow_timer := 0.0
func _move_toward(to: Vector3, speed: float, delta: float) -> void:
	var p := global_position
	var dir := Vector3(to.x - p.x, 0.0, to.z - p.z)
	if dir.length() > 9.0 or not nav.clear_line(p.x, p.z, to.x, to.z):
		dir = _flow_dir(to, delta)
	if dir.length_squared() < 0.0001: return
	dir = dir.normalized()
	yaw = lerp_angle(yaw, atan2(dir.x, dir.z), minf(1.0, delta * 8.0))
	var np := nav.resolve(p + dir * speed * delta, minf(MAX_RADIUS, RADIUS * _k))
	global_position = Vector3(np.x, p.y, np.z)
	rotation.y = yaw

func _flow_dir(to: Vector3, delta: float) -> Vector3:
	var n: int = nav.n
	if _flow.size() != n * n: _flow.resize(n * n)
	var gx := GridNav.cell(to.x)
	var gz := GridNav.cell(to.z)
	var key := gx * n + gz
	_flow_timer -= delta
	if key != _flow_key or _flow_timer <= 0.0:
		_flow_key = key
		_flow_timer = 0.4
		nav.bfs(gx, gz, _flow)
	var p := global_position
	var x := GridNav.cell(p.x)
	var z := GridNav.cell(p.z)
	var bx := to.x
	var bz := to.z
	for step in 4:
		var here := _flow[x * n + z] if (x >= 0 and z >= 0 and x < n and z < n) else -1
		var best: float = INF if here < 0 else float(here)
		var nx := -1
		var nz := -1
		for o in GridNav.NEIGHBOURS:
			var ax: int = x + o.x
			var az: int = z + o.y
			if ax < 0 or az < 0 or ax >= n or az >= n or not nav.can_step(x, z, ax, az): continue
			var v := _flow[ax * n + az]
			if v >= 0 and v < best:
				best = v
				nx = ax
				nz = az
		if nx < 0: break
		x = nx
		z = nz
		if step == 0 or nav.clear_line(p.x, p.z, x * CELL, z * CELL):
			bx = x * CELL
			bz = z * CELL
		else:
			break
	return Vector3(bx - p.x, 0.0, bz - p.z)

# ---------------------------------------------------------------- co-op
## Guest: follow the host's copy (shroud_net.gd), or, while it is taking this machine's player, run the pull and the
## death scene here
func _physics_puppet(delta: float) -> void:
	_snub = maxf(0.0, _snub - delta)
	if _net_taken:
		t += delta
		if state == "pull": _pull(delta)
		elif state == "kill": _kill_tick(delta)
		return
	if _snub <= 0.0: net.step(delta)
	_stare_fx(delta)

func net_apply(t_: float, m: Array) -> void:
	net.apply(t_, m)

## Net (guest): it has this machine's player (pull: hypnotised, walk to it first; else grabbed)
func net_taken(pull: bool) -> void:
	if _pl.dead or _net_taken or (body == null and not _build()):
		Net.send_shroud_result()
		return
	_net_taken = true
	_victim_id = -1
	present = true
	visible = true
	if pull: _begin_pull()
	else: _begin_kill()

## Net (host): the guest it took is done (dead, or the sequence was cut short)
func net_result(peer_id: int) -> void:
	if peer_id == _victim_id: _fed()

## Guest: the host's copy is gone
func _despawn_quietly() -> void:
	if _net_taken:
		_net_taken = false
		_snub = 2.0
		Net.send_shroud_result()
	if _light != null: _light.visible = false
	_restore_fx()
	state = "off"
	present = false
	visible = false
	_speed = 0.0
	_clip = ""
	if _ap != null: _ap.stop()

# ---------------------------------------------------------------- T.S.R.A. scanner
func _enter_tree() -> void:
	add_to_group(Archive.SCANNABLE)
	set_meta("tsra_id", "shroud")

func scan_points() -> Array:
	if not present or body == null or not visible:
		return []
	return [global_position + Vector3.UP * 1.4 * _k, _eye_pos()]

func scan_behavior(_at: Vector3) -> Dictionary:
	match state:
		"dormant", "fed":
			return {"state": "DORMANT", "detail": "OCULAR MASS ROLLED BACK // NO VISUAL CONTACT", "danger": 1}
		"watch":
			return {"state": "STARING", "detail": "MOTIONLESS WHILE OBSERVED // GAZE LOCK %d%%" % int(lock * 100.0), "danger": 2}
		"crawl":
			return {"state": "ADVANCING", "detail": "MOVES ONLY WHEN UNOBSERVED // FIVE POINTS OF CONTACT", "danger": 2}
		"blind":
			return {"state": "RECOILING", "detail": "OCULAR TRAUMA // LIGHT-AVERSE", "danger": 1}
	return {"state": "ACQUIRING", "detail": "SUBJECT CONTACT", "danger": 2}

# ---------------------------------------------------------------- debug console
func debug_spawn() -> bool:
	if Net.is_online() and not Net.hosting:
		last_error = "only the host can spawn it in co-op"
		return false
	last_error = ""
	if body == null and not _build():
		return false
	var p: Vector3 = player.global_position
	var fwd: Vector3 = -player.global_transform.basis.z
	fwd = Vector3(fwd.x, 0.0, fwd.z).normalized()
	var turns: Array = [0.0]
	for i in range(1, 9):                               # ahead first, then further and further round you
		turns.append(TAU * i / 16.0)
		turns.append(-TAU * i / 16.0)
	for turn: float in turns:
		var dir := fwd.rotated(Vector3.UP, turn)
		var d := 14.0
		while d >= 4.5:
			var c := p + dir * d
			if nav.open_at(c.x, c.z) and nav.clear_line(p.x, p.z, c.x, c.z):
				global_position = Vector3(c.x, _floor_y(c, p.y), c.z)
				yaw = atan2(-dir.x, -dir.z)
				rotation.y = yaw
				present = true
				visible = true
				_eye_dir = Vector3.ZERO
				_lurk = false
				_go_dormant()
				return true
			d -= 1.0
	last_error = "no room to spawn here, try another spot"
	return false

func debug_wake() -> bool:
	if not present and not debug_spawn(): return false
	_tid = _local_id()
	_wake()
	return true

## Console: your stare most of the way there (look at it and it has you in a moment)
func debug_stare() -> bool:
	if not present and not debug_spawn(): return false
	if state in ["dormant", "fed", "blind"]: _wake()
	_locks[_local_id()] = 0.85
	_set_lock(0.85)
	return true

## Console: straight into the death scene
func debug_kill() -> bool:
	if not present and not debug_spawn(): return false
	if _pl.dead:
		last_error = "you are already dead"
		return false
	_wake()
	_begin_kill()
	return true

func debug_status() -> String:
	return "shroud: %s  your stare %.2f  dist %.1f m  %s  size x%.2f  stares %s" % [state, lock, _dist(),
		"looking" if _looked else "not looking", _k, str(_locks)]

func debug_despawn() -> void:
	if state in ["kill", "pull"] and _victim_id < 0 and player != null and not _pl.dead:
		_pl.frozen = false
		Game.fx_reset()
		(_pl.cam as Camera3D).fov = _from_fov
	if _muffled: _quiet(false)
	if _light != null: _light.visible = false
	_restore_fx()
	state = "off"
	_victim_id = -1
	_locks = {}
	_set_lock(0.0)
	super.debug_despawn()
