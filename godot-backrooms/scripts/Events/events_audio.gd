extends "res://scripts/Events/events_fx.gd"
## Events about voices and sounds: the machine voice, the roster, hum, phone, footsteps, the listening
## events, the doorbell, countdown.

# ---------------------------------------------------------------- the machine voice
# A text-to-speech voice reads out one line, and the words type themselves across the screen in red as it says them
# (tools/gen_machine_voice.py renders every line in every voice: the Mandela Catalogue's crushed Sam, an emergency
# broadcast, an alternate wearing a voice, a whisper, something deep, an old tape). When something is true of you
# (in the dark, light dying, alone, a teammate dead...) it prefers a line that says so. Out of your own camera, from
# a speaker inside the wall behind you, or (the whisper) right at your ear. Everything else goes quiet for it.
# Never one of the last twelve lines again.
const VOICE_WEIGHTS := {"sam": 3.0, "broadcast": 2.0, "alternate": 2.0, "whisper": 1.5, "deep": 1.5, "tape": 2.0}
var _voice_recent: Array = []

## What it can see of you right now: the tags of machine_voice_lines.gd
func _voice_context() -> Array:
	var tags: Array = []
	var dark: bool = not player.flash_on
	var lv: float = player.ambient_light() if player.has_method("ambient_light") else 1.0
	if dark and lv < 0.3: tags.append("dark")
	if float(player.battery) < 20.0: tags.append("lowbattery")
	if still > 8.0: tags.append("still")
	if bool(player.get("is_sprinting")): tags.append("running")
	if float(player.sanity) < 40.0: tags.append("lowsanity")
	if float(player.get("health") if player.get("health") != null else 100.0) < 40.0: tags.append("lowhealth")
	if Game.time > 1200.0: tags.append("longtime")
	if Game.time < 150.0: tags.append("newarrival")
	if Game.presence > 0.35: tags.append("nearentity")
	if bool(player.get("grid_down")): tags.append("powercut")
	if Net.is_online() and not Net.remotes.is_empty():
		var nearest := INF
		var any_dead := false
		for r in Net.remotes.values():
			if not is_instance_valid(r): continue
			if r.dead: any_dead = true
			elif r.here: nearest = minf(nearest, (r.global_position - player.global_position).length())
		if any_dead: tags.append("teammate_dead")
		if nearest > 40.0: tags.append("alone")
		elif nearest < 8.0: tags.append("group")
	else:
		tags.append("alone")
	return tags

## One of the voices, weighted
func _pick_voice() -> String:
	var total := 0.0
	for v in VOICE_WEIGHTS: total += float(VOICE_WEIGHTS[v])
	var r := rng.randf() * total
	for v in VOICE_WEIGHTS:
		r -= float(VOICE_WEIGHTS[v])
		if r <= 0.0:
			return v
	return "sam"

## A level editor voice trigger (event_trigger.gd context_voice): something just became true of you (`tags`,
## from _voice_context) while you stand in its box, so say a line about one of them. False if there is no
## fresh line for any of them, or a line is still being said.
var _voice_until := 0.0
func play_context_voice(tags: Array) -> bool:
	if Game.time < _voice_until:
		return false
	var pool: Array = []
	for i in MachineVoice.LINES.size():
		if not _voice_recent.has(i) and tags.has(str(MachineVoice.LINES[i].tag)):
			pool.append(i)
	if pool.is_empty():
		return false
	return play_machine_voice(_pick_voice(), int(pool[rng.randi() % pool.size()]), false)    # zone: only for you

func _event_machine_voice() -> void:
	var voice := _pick_voice()
	# the line: one about you if there is one (most of the time), else any; never a recent one
	var ctx := _voice_context()
	var about_you: Array = []
	var any: Array = []
	for i in MachineVoice.LINES.size():
		if _voice_recent.has(i): continue
		var tag := str(MachineVoice.LINES[i].tag)
		if tag == "": any.append(i)
		elif ctx.has(tag): about_you.append(i)
	var pool: Array = about_you if not about_you.is_empty() and rng.randf() < 0.65 else any
	if pool.is_empty(): pool = about_you
	if pool.is_empty(): return
	play_machine_voice(voice, int(pool[rng.randi() % pool.size()]))

## One line in one voice (the debug console's MACHINE VOICE picker calls this directly). False if not imported yet.
func play_machine_voice(voice: String, idx: int, share := true) -> bool:
	if idx < 0 or idx >= MachineVoice.LINES.size():
		return false
	var line: Dictionary = MachineVoice.LINES[idx]
	var path := MachineVoice.path(voice, str(line.id))
	if not ResourceLoader.exists(path):
		return false                                   # (not imported yet: open the project in the editor once)
	if share and _share_voice:
		Net.send_voice(voice, idx)                     # co-op host: everyone hears this same line
	var stream: AudioStream = load(path)
	_voice_recent.append(idx)
	if _voice_recent.size() > 12:
		_voice_recent.pop_front()
	var dur := stream.get_length()
	_voice_until = Game.time + dur + 1.0
	on_clear(func():
		banner.visible_ratio = 1.0
		Game.fx_static = 0.0)
	_hush(dur + 2.0, 0.1)
	haunt(0.5)
	Game.add_glitch(0.35)
	var wall := _wall_face_behind(4.0, 9.0)
	if voice == "whisper":
		var p: AudioStreamPlayer3D = scares.spawn3d(stream, _behind_neck(0.35), 0.7, "Scares", 0.6, 1.0, false)   # at your ear
		p.max_distance = 6.0
	elif voice != "broadcast" and rng.randf() < 0.4 and wall.is_finite():
		scares.spawn3d(stream, wall, 0.9, "Scares", 5.0)          # a speaker somewhere in the wall
	else:
		scares.spawn_flat(stream, 0.5)                             # out of your own camera
	_banner_red(str(line.text))
	banner.visible_ratio = 0.0
	watch(func(dt: float, t: float) -> bool:
		if t > dur + 1.0:
			hide_banner()
			banner.visible_ratio = 1.0
			Game.fx_static = 0.0
			return false
		banner.visible_ratio = clampf((t - 0.25) / maxf(dur * 0.8, 0.1), 0.0, 1.0)
		banner.modulate.a = 0.55 if rng.randf() < 0.06 else 1.0     # the text stutters
		Game.fx_static = 0.1 + 0.06 * sin(t * 11.0)
		return true)
	return true

# ---------------------------------------------------------------- shared by the events below
## A looping player (the imported wav doesn't loop, so it restarts itself), flat or at `pos`
func _loop_player(path: String, pos := Vector3.INF) -> Node:
	if not ResourceLoader.exists(path):
		return null
	var stream: AudioStream = load(path)
	var p: Node
	if pos.is_finite():
		var p3 := AudioStreamPlayer3D.new()
		p3.stream = stream
		p3.bus = "Scares"
		p3.unit_size = 4.0
		p3.max_distance = 45.0
		p3.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p3.volume_db = -60.0
		add_child(p3)
		p3.global_position = pos
		if scares.audio != null:
			scares.audio.occlude(p3, true)                          # through the wall: muffled
		p3.finished.connect(p3.play)
		p3.play()
		p = p3
	else:
		var p2 := AudioStreamPlayer.new()
		p2.stream = stream
		p2.bus = "Scares"
		p2.volume_db = -60.0
		add_child(p2)
		p2.finished.connect(p2.play)
		p2.play()
		p = p2
	return p

func _free(n) -> void:
	if n != null and is_instance_valid(n):
		n.queue_free()

## The wall face nearest you within `max_d` (the side of a wall cell that looks into an open one)
func _wall_face_nearest(max_d: float) -> Vector3:
	var p := player.global_position
	var cell := GridNav.CELL
	var cx := GridNav.cell(p.x)
	var cz := GridNav.cell(p.z)
	var r := ceili(max_d / cell) + 1
	var best := Vector3.INF
	var best_d := INF
	for x in range(cx - r, cx + r + 1):
		for z in range(cz - r, cz + r + 1):
			if not nav.is_wall(x, z):
				continue
			for o in GridNav.NEIGHBOURS:
				if nav.blocked(x + o.x, z + o.y):
					continue
				var face := Vector3(x * cell + o.x * cell * 0.5, p.y + 0.6, z * cell + o.y * cell * 0.5)
				var d := Vector2(face.x - p.x, face.z - p.z).length()
				if d < best_d and d <= max_d:
					best_d = d
					best = face
	return best

# ---------------------------------------------------------------- someone joined
# A terminal card: a field researcher has joined the expedition. Nobody joined. Sometimes it is a name nobody has,
# sometimes it is one of your teammates, who is standing next to you, and sometimes it is you. The [F6] CREW page
# lists them: alive, 0 m away, on your floor. A while later their signal is lost.
const GHOST_NAMES := ["HALVERSON", "R. OKAFOR", "DELACROIX", "M. VOSS", "J. ABERNATHY", "SURVIVOR 00", "NOBODY",
	"E. LINDQVIST", "THE OTHER ONE", "K. MARSH"]

func _event_ghost_roster() -> void:
	var callsign: String = GHOST_NAMES[rng.randi() % GHOST_NAMES.size()]
	var roll := rng.randf()
	if roll < 0.3:
		var me: String = Net.my_name()
		callsign = me if me != "" else "YOU"
	elif roll < 0.5 and not Net.remotes.is_empty():
		var ids: Array = Net.remotes.keys()
		callsign = Net.label_for(int(ids[rng.randi() % ids.size()]))
	var id := 9000 + rng.randi() % 900
	# somewhere out in the halls, wandering: a distance that drifts, so the roster reads like a real one
	Net.phantoms[id] = {"name": callsign, "dist": rng.randf_range(18.0, 150.0), "drift": rng.randf_range(-2.5, 2.5)}
	on_clear(func(): Net.phantoms.erase(id))
	Net.survivor_joined.emit(id, callsign, false)
	haunt(0.4)
	later(rng.randf_range(40.0, 70.0), func():
		if Net.phantoms.has(id):
			Net.phantoms.erase(id)
			Net.survivor_left.emit(id, callsign))

# ---------------------------------------------------------------- the hum rises
# The fluorescent buzz you stopped hearing hours ago starts to climb. (The level's own hum fades out under it, so
# there is only the one.) Louder, harsher, a little higher, until it hurts: your eyes water and won't stay open,
# blinking harder and more often, squinting, the picture swimming. Then it stops, and so does every other sound:
# nothing at all, for long enough to make you wonder whether you can still hear. Then the hum comes back.
func _event_hum_rises() -> void:
	var au: Node = get_parent().get_node_or_null("Audio")
	var hum = _loop_player("res://audio/events/hum_loop.wav")
	var lids = player.get("blink")                             # player/blink.gd: the player's own blink
	if au != null: au.hum_event_target = 0.0
	on_clear(func():
		_free(hum)
		Game.fx_reset()
		if au != null:
			au.set_muffled(false)
			au.hum_event_target = 1.0)
	haunt(0.3)
	var st := {"next": 3.0}
	watch(func(dt: float, t: float) -> bool:
		if t >= 15.0:
			return false
		var k := pow(t / 15.0, 2.2)
		if hum != null and is_instance_valid(hum):
			hum.volume_db = linear_to_db(0.015 + 0.55 * k)
			hum.pitch_scale = 1.0 + 0.06 * k
		Game.fx_blur = 0.38 * k
		Game.fx_shock = maxf(Game.fx_shock, 0.15 * k * (0.5 + 0.5 * sin(t * 37.0)))
		# the eyes: blinks coming harder and closer together, and a squint between them
		st.next -= dt
		if lids != null and t > 2.0:
			if st.next <= 0.0:
				st.next = lerpf(3.2, 0.6, k) + rng.randf() * 0.5
				lids.blink(lerpf(1.0, 1.9, k))                       # slower, heavier as it hurts
			elif not lids.blinking():
				Game.fx_blink = 0.32 * k * k                         # squinting against it
		if k > 0.45 and rng.randf() < dt * 2.0:
			level.disturb(player.global_position, 12.0, 0.6)
		return true)
	later(15.0, func():
		_free(hum)
		Game.fx_reset()
		if au != null: au.set_muffled(true)
		_hush(8.0))
	later(16.5, func(): scares.spawn_flat(scares.synth("tinnitus", 4.0), 0.06))
	later(22.0, func():
		if au != null:
			au.set_muffled(false)
			au.hum_event_target = 1.0                          # the level's hum fades back in
		scares.play_scare("restrike"))

# ---------------------------------------------------------------- the party
# Through the drywall beside you: music, a thumping bass, a crowd talking and laughing, someone shrieking with
# laughter. A party, somewhere in here. Follow it and it stays just the other side of the wall. Put your ear to
# it and it stops dead, all of it at once, the way a room goes quiet when someone walks in. Then a single knock.
func _event_party_wall() -> void:
	var wall := _wall_face_behind(5.0, 13.0)
	if not wall.is_finite():
		wall = _wall_face_nearest(12.0)
	if not wall.is_finite():
		return
	var party = _loop_player("res://audio/events/party_muffled.wav", wall)
	if party == null:
		return
	on_clear(func(): _free(party))
	haunt(0.3)
	var life := rng.randf_range(30.0, 60.0)                      # how long the party goes on, if you leave it be
	const FADE := 5.0
	watch(func(dt: float, t: float) -> bool:
		if party == null or not is_instance_valid(party):
			return false
		var p := player.global_position
		if Vector2(wall.x - p.x, wall.z - p.z).length() < 3.0 and t > 2.0:
			_free(party)                                         # it heard you
			_hush(5.0)
			later(2.6, func(): scares.knock(wall, 1.1, scares.KNOCK_KNUCKLE))
			later(3.0, func(): haunt(0.9))
			return false
		# in over 4 s, on for `life`, then winding down over FADE s, as if the party were drifting off elsewhere
		var level_k := smoothstep(0.0, 4.0, t) * (1.0 - smoothstep(life - FADE, life, t))
		party.volume_db = linear_to_db(maxf(0.75 * level_k, 0.0001))
		if t >= life:
			_free(party)
			return false
		return true)

# ---------------------------------------------------------------- the phone
# Somewhere down the halls an old desk phone is ringing. It keeps ringing. Go to it and it stops mid-ring before
# you get there. A moment of quiet. Then it rings once more, very close, behind you, and is cut off.
func _event_phone_ring() -> void:
	var spot: Vector3 = find_corridor_spot(14.0, 26.0).pos
	if not ResourceLoader.exists("res://audio/events/phone_ring.wav"):
		return
	var ring: AudioStream = load("res://audio/events/phone_ring.wav")
	var st := {"next": 0.6, "count": 0, "now": null}
	on_clear(func(): _free(st.now))
	watch(func(dt: float, t: float) -> bool:
		var p := player.global_position
		if Vector2(spot.x - p.x, spot.z - p.z).length() < 5.0:
			_free(st.now)                                        # it stops before you reach it
			_hush(5.0, 0.2)
			later(3.4, func():
				var close: AudioStreamPlayer3D = scares.spawn3d(ring, _behind_neck(1.6), 0.45, "Scares", 1.5, 1.0, false)
				get_tree().create_timer(0.55).timeout.connect(func(): _free(close))
				haunt(1.0))
			return false
		st.next -= dt
		if st.next <= 0.0:
			if st.count >= 9:
				return false
			st.count += 1
			st.next = 6.0
			st.now = scares.spawn3d(ring, spot, 0.8, "Scares", 7.0, 1.0)
		return true)

# ---------------------------------------------------------------- the pacer
# Footsteps, real ones, on carpet, somewhere off to one side of you: far, muffled through the walls, keeping pace.
# Walk and they walk, a beat behind your own; stop and they stop. Over the minute it goes on they come a little
# nearer, from the next corridor over to the one beside yours. Stand still long enough and they stop too, and
# then there is one more step. Closer.
var _carpet_steps: Array = []

func _carpet_step(pos: Vector3, volume: float) -> void:
	if _carpet_steps.is_empty():
		for i in range(1, 5):
			var path := "res://audio/footsteps/carpet/carpet_walk_%d.wav" % i
			if ResourceLoader.exists(path):
				_carpet_steps.append(load(path))
	if _carpet_steps.is_empty():
		return
	var s: AudioStream = _carpet_steps[rng.randi() % _carpet_steps.size()]
	scares.spawn3d(s, pos, volume, "Scares", 4.0, rng.randf_range(0.84, 0.94))     # (walls between muffle it)

func _event_hound_pacing() -> void:
	var side_sign := 1.0 if rng.randf() < 0.5 else -1.0
	var st := {"last": player.global_position, "moved": 0.0, "still": 0.0, "n": 0}
	haunt(0.4)
	watch(func(dt: float, t: float) -> bool:
		var p := player.global_position
		var b := player.global_transform.basis
		var fwd := Vector3(-b.z.x, 0.0, -b.z.z).normalized()
		var side := Vector3(-fwd.z, 0.0, fwd.x) * side_sign
		var away := lerpf(17.0, 8.0, clampf(t / 45.0, 0.0, 1.0))          # the next corridor over, then nearer
		var at := p + side * away - fwd * 1.5 + Vector3.UP * 0.1
		var mv := Vector2(p.x - st.last.x, p.z - st.last.z).length()
		st.last = p
		if mv > 0.01:
			st.still = 0.0
			st.moved += mv
			if st.moved >= 0.85:                                      # one of theirs for each of yours
				st.moved = 0.0
				st.n += 1
				later(rng.randf_range(0.12, 0.3), func(): _carpet_step(at, 0.75))
		else:
			st.still += dt
			if st.n >= 6 and st.still > 3.0:
				# they wait with you. Then one more step, nearer
				later(1.6, func(): _carpet_step(p + side * 4.5 - fwd * 1.0, 0.85))
				later(2.2, func(): haunt(0.8))
				return false
		return t < 60.0)

# ---------------------------------------------------------------- stalker's tell
# Footsteps trail you from behind, one for each of yours. Keep the torch on and it holds its distance; switch it
# off and it closes, step by step, until it is breathing at your neck.
const STALK_START := 14.0       # m behind you
const STALK_CLOSE := 1.4        # m/s it gains in the dark
const STALK_ARRIVE := 2.0

func _event_stalker_tell() -> void:
	var st := {"last": player.global_position, "gap": STALK_START, "step": 0.0}
	haunt(0.4)
	watch(func(dt: float, t: float) -> bool:
		var p := player.global_position
		var b := player.global_transform.basis
		var fwd := Vector3(-b.z.x, 0.0, -b.z.z).normalized()
		var mv := Vector2(p.x - st.last.x, p.z - st.last.z).length()
		st.last = p
		var closed := 0.0 if player.flash_on else minf(STALK_CLOSE * dt, st.gap)
		st.gap -= closed
		st.step += mv + closed
		if st.step >= 0.85:
			st.step = 0.0
			var at: Vector3 = p - fwd * st.gap + Vector3.UP * 0.1
			var vol := clampf(1.0 - st.gap / 20.0, 0.3, 0.95)
			later(rng.randf_range(0.1, 0.25), func(): _carpet_step(at, vol))
		if st.gap <= STALK_ARRIVE:
			scares.breath_behind(p - fwd * 1.2 + Vector3.UP * 1.2)
			haunt(1.0)
			return false
		return t < 60.0)

# ---------------------------------------------------------------- footsteps behind the walls
# A recording of someone walking, heavy, on the far side of the wall beside you. It walks a line parallel to where
# you face, a few metres off behind the drywall: from ahead of you to just past you, and fades out down the hall.
# The walls keep it muffled the whole way (audio.gd occlude, re-checked as it moves).
const WALKER_PATH := "res://audio/events/footsteps_walls.mp3"

func _event_wall_footsteps() -> void:
	if not ResourceLoader.exists(WALKER_PATH):
		return
	var stream: AudioStream = load(WALKER_PATH)
	var secs := stream.get_length()
	if secs <= 0.5:
		return
	var b := player.global_transform.basis
	var fwd := Vector3(-b.z.x, 0.0, -b.z.z).normalized()
	var side := Vector3(-fwd.z, 0.0, fwd.x) * (1.0 if rng.randf() < 0.5 else -1.0)
	var lane := rng.randf_range(6.0, 9.0)                       # how far off, through the wall
	var p0 := player.global_position
	var walker: AudioStreamPlayer3D = scares.spawn3d(stream, p0 + side * lane + fwd * 12.0 + Vector3.UP * 0.2,
		0.8, "Scares", 4.0, rng.randf_range(0.92, 1.0))
	on_clear(func(): _free(walker))
	haunt(0.3)
	later(secs * 0.7, func(): haunt(0.5))
	var st := {"occ": 0.0}
	watch(func(dt: float, t: float) -> bool:
		if walker == null or not is_instance_valid(walker):
			return false
		var k := clampf(t / secs, 0.0, 1.0)
		walker.global_position = p0 + side * lane + fwd * lerpf(12.0, -6.0, k) + Vector3.UP * 0.2
		st.occ -= dt
		if st.occ <= 0.0 and scares.audio != null:
			st.occ = 0.25
			scares.audio.occlude(walker)                        # re-check the walls as it moves
		return t < secs)

# ---------------------------------------------------------------- run
# Every light dies. Two seconds of black and your own heartbeat. Then, far down the hall, the lights come back on
# in red, one after another, coming toward you, fast, with something heavy running under them. It does not stop.
# It goes straight through where you are standing, and on past you, and the red keeps lighting up behind you.
func _event_run() -> void:
	var p0 := player.global_position
	var spot := find_corridor_spot(16.0, 30.0)
	var dir := Vector3(spot.pos.x - p0.x, 0.0, spot.pos.z - p0.z).normalized()
	var line: Array = []
	for f: Dictionary in level.fixtures_near(p0, 46.0):
		var d := Vector3(f.pos.x - p0.x, 0.0, f.pos.z - p0.z)
		var along := d.dot(dir)
		if along > -26.0 and (d - dir * along).length() < 3.5:
			line.append([along, f])
	if line.size() < 4:
		return
	line.sort_custom(func(x, y): return x[0] > y[0])
	var start: float = line[0][0] + 2.0
	on_clear(func():
		_red_mode(false)
		level.set_tint(Color.WHITE)
		level.restore_power()
		Game.fx_reset())
	_red_mode(true)
	level.cut_power(40.0)
	level.set_tint(EMERGENCY * 1.7)
	scares.grid_off(sound_spot(10.0, rng.randf() * TAU, 2.4))
	_hush(30.0, 0.1)
	haunt(0.6)
	later(0.9, func(): scares.heartbeat(0.9))
	later(1.8, func(): scares.heartbeat(1.0))
	const SPEED := 8.5
	var st := {"idx": 0, "step": 0.0, "passed": false, "done": -1.0}
	watch(func(dt: float, t: float) -> bool:
		if t < 2.4:
			return true
		var front := start - SPEED * (t - 2.4)
		while st.idx < line.size() and line[st.idx][0] >= front:
			var f: Dictionary = line[st.idx][1]
			level.cut_fixture(f, 0.02)                            # strikes back on, red
			st.idx += 1
		var mine := (player.global_position - p0).dot(dir)
		st.step -= dt
		if st.step <= 0.0 and st.done < 0.0:
			st.step = 0.26
			var near := 1.0 - clampf(absf(front - mine) / 30.0, 0.0, 1.0)
			scares.spawn3d(scares.synth("thump"), p0 + dir * front + Vector3.UP * 0.2, 0.35 + 0.65 * near, "Scares", 6.0, 0.55)
		if not st.passed and front < mine + 0.5:
			st.passed = true                                      # through you
			Game.fx_shock = 1.0
			Game.fx_flash = 0.35
			Game.add_glitch(0.7)
			scares.spawn_flat(scares.synth("thump"), 0.9, "Scares", 0.38)
			haunt(1.0)
		if st.idx >= line.size() and st.done < 0.0:
			st.done = t
		if (st.done >= 0.0 and t - st.done > 2.5) or t > 26.0:
			level.set_tint(Color.WHITE)
			level.restore_power()
			_red_mode(false)
			scares.grid_on()
			Game.fx_reset()
			return false
		return true)

# ---------------------------------------------------------------- shared by the listening events
## The HUD's terminal card (hud.gd toast), for the events that speak through the terminal
func _toast(title: String, lines: Array) -> void:
	var ui: Node = get_parent().get_node_or_null("UI")
	var t = ui.get("toast") if ui != null else null
	if t != null and t.has_method("push"):
		t.push(title, lines)

## Listen to your own voice (Voice.you_spoke) for as long as the event lasts; `fn(pcm, syllables, loud)`
func _listen(fn: Callable) -> void:
	if not Voice.you_spoke.is_connected(fn):
		Voice.you_spoke.connect(fn)
	on_clear(func():
		if Voice.you_spoke.is_connected(fn): Voice.you_spoke.disconnect(fn))

func _unlisten(fn: Callable) -> void:
	if Voice.you_spoke.is_connected(fn):
		Voice.you_spoke.disconnect(fn)

# ---------------------------------------------------------------- it heard you
# The hum drops away to almost nothing, the way a room goes quiet when something in it starts to listen. Two
# words on the screen: DO NOT SPEAK. For half a minute it listens: to your microphone (Voice.you_spoke, which works
# in single player too), and to your feet (sprinting is noise too, so it works without a mic). Stay quiet and the
# hum comes back and nothing happened. Make a sound, and the tubes go out around you, one after another, from you
# outward, and footsteps start toward you from far off, closer each time, and stop just short of you.
func _event_it_heard_you() -> void:
	var au: Node = get_parent().get_node_or_null("Audio")
	var st := {"heard": false}
	on_clear(func():
		if au != null: au.hum_event_target = 1.0)
	if au != null: au.hum_event_target = 0.12
	_banner_red("DO NOT SPEAK")
	later(3.5, hide_banner)
	haunt(0.3)
	var heard := func() -> void:
		if st.heard: return
		st.heard = true
		var p := player.global_position
		var near: Array = level.fixtures_near(p, 20.0)
		near.sort_custom(func(x, y): return Vector2(x.pos.x - p.x, x.pos.z - p.z).length() < Vector2(y.pos.x - p.x, y.pos.z - p.z).length())
		for i in mini(near.size(), 12):
			var f: Dictionary = near[i]
			later(0.4 + i * 0.16, func():
				if f.black <= 0.0:
					level.cut_fixture(f, 14.0)
					level.fixture_event.emit(f, false))
		haunt(0.8)
		var from := sound_spot(20.0)
		for k in 6:
			later(2.2 + k * 0.85, func(): _carpet_step(from.lerp(p, 0.15 * k), 0.5 + 0.08 * k))
		later(8.0, func(): scares.heartbeat(0.9))
		later(13.0, func():
			if au != null: au.hum_event_target = 1.0)
	var on_voice := func(_pcm: PackedFloat32Array, _syl: int, _loud: float) -> void: heard.call()
	_listen(on_voice)
	watch(func(dt: float, t: float) -> bool:
		if st.heard: return false
		if t > 1.5 and (Voice.speaking_now or bool(player.get("is_sprinting"))):
			heard.call()                                          # (mid-word counts: it doesn't wait for you to finish)
			return false
		return t < 32.0)
	later(32.0, func():
		_unlisten(on_voice)
		if not st.heard and au != null:
			au.hum_event_target = 1.0)                          # you held your breath: nothing

# ---------------------------------------------------------------- it says your name
# Everything goes quiet. Then the machine voice, slow and low, crushed like the rest of them, says your name. Your
# actual callsign. A pause. It says it again, and the letters type across the screen as it does.
# On Windows the name is rendered on the spot by the system's speech voice (PowerShell, as tools/gen_machine_voice.py
# does) and wrecked here the way the Sam voice is (_wreck_voice); elsewhere, or if that fails, the system voice
# says it through DisplayServer.
var _name_stream: AudioStreamWAV
var _name_for := ""

func _event_say_your_name() -> void:
	var me: String = Net.my_name()
	if me == "": me = "researcher"
	on_clear(func():
		DisplayServer.tts_stop()
		Game.fx_static = 0.0)
	_hush(12.0, 0.08)
	haunt(0.5)
	var st := {"said": 0, "next": 1.5}
	if _name_for != me:
		_name_stream = null
		_render_name(me)
	watch(func(dt: float, t: float) -> bool:
		if _name_stream == null and _name_for == me:
			_name_stream = _load_name()                          # ready yet?
		if t < st.next: return true
		if _name_stream == null and t < 6.0: return true          # (give the render a few seconds)
		st.said += 1
		Game.fx_static = 0.12
		Game.add_glitch(0.3)
		if _name_stream != null:
			scares.spawn_flat(_name_stream, 0.6)
		else:
			var voices := DisplayServer.tts_get_voices_for_language("en")
			if not voices.is_empty(): DisplayServer.tts_speak(me.to_lower(), voices[0], 70, 0.3, 0.55)
		if st.said == 2:
			_banner_red(" ".join(me.to_upper().split("")))
			haunt(0.9)
			later(4.0, func():
				hide_banner()
				Game.fx_static = 0.0)
			return false
		st.next = t + 3.2
		return true)

## Windows: the system voice says `who` into user://tts_name_raw.wav, in the background
func _render_name(who: String) -> void:
	_name_for = who
	if OS.get_name() != "Windows":
		return
	var out := ProjectSettings.globalize_path("user://tts_name_raw.wav")
	var txt := ProjectSettings.globalize_path("user://tts_name.txt")
	DirAccess.remove_absolute(out)
	var f := FileAccess.open(txt, FileAccess.WRITE)
	if f == null: return
	f.store_string(who)
	f.close()
	var ps := ("Add-Type -AssemblyName System.Speech;$s = New-Object System.Speech.Synthesis.SpeechSynthesizer;" +
		"$v = $s.GetInstalledVoices() | Where-Object { $_.VoiceInfo.Culture.Name -like 'en-*' } | Select-Object -First 1;" +
		"if ($v) { $s.SelectVoice($v.VoiceInfo.Name) };$s.Rate = -4;" +
		"$fmt = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(22050, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono);" +
		"$s.SetOutputToWaveFile('%s.tmp', $fmt);$s.Speak([IO.File]::ReadAllText('%s'));$s.Dispose();" +
		"Move-Item -Force '%s.tmp' '%s'") % [out, txt, out, out]
	OS.create_process("powershell", ["-NoProfile", "-WindowStyle", "Hidden", "-Command", ps])

## The rendered name, wrecked, once it is there (the render writes a .tmp and renames it when done)
func _load_name() -> AudioStreamWAV:
	var path := ProjectSettings.globalize_path("user://tts_name_raw.wav")
	if not FileAccess.file_exists(path): return null
	var bytes := FileAccess.get_file_as_bytes(path)
	var at := 12
	var data := PackedByteArray()
	while at + 8 <= bytes.size():                                 # the RIFF chunks: find "data"
		var id := bytes.slice(at, at + 4).get_string_from_ascii()
		var size := bytes.decode_u32(at + 4)
		if id == "data":
			data = bytes.slice(at + 8, at + 8 + size)
			break
		at += 8 + size + (size & 1)
	if data.size() < 2000: return null
	var x := PackedFloat32Array()
	x.resize(data.size() / 2)
	for i in x.size():
		x[i] = data.decode_s16(i * 2) / 32768.0
	return _wreck_voice(x, 22050)

## The Sam voice, in GDScript (tools/gen_machine_voice.py v_sam, without the extras): slowed and lowered,
## sample-and-hold aliasing, bit-crushed, a slow ring modulation, soft-clipped, a short cheap echo, hiss
func _wreck_voice(x: PackedFloat32Array, rate: int) -> AudioStreamWAV:
	var slow := 0.8
	var n := int(x.size() / slow)
	var y := PackedFloat32Array()
	y.resize(n + int(rate * 0.8))
	var peak := 0.001
	for i in n:
		var src := i * slow
		var k := int(src)
		var a := x[mini(k, x.size() - 1)]
		var b := x[mini(k + 1, x.size() - 1)]
		peak = maxf(peak, absf(lerpf(a, b, src - k)))
	var held := 0.0
	var echo := int(rate * 0.11)
	for i in n:
		if i % 3 == 0:                                             # sample and hold
			var src := i * slow
			var k := int(src)
			held = lerpf(x[mini(k, x.size() - 1)], x[mini(k + 1, x.size() - 1)], src - k) / peak
		var v := roundf(held * 32.0) / 32.0                        # crushed
		v *= 0.72 + 0.28 * sin(TAU * 47.0 * i / rate)              # the metal in it
		v = tanh(v * 2.2) / tanh(2.2)
		y[i] += v
		if i + echo < y.size(): y[i + echo] += v * 0.22
	for i in y.size():
		y[i] = clampf(y[i] * 0.8 + randf_range(-0.012, 0.012), -1.0, 1.0)
	var pcm := PackedByteArray()
	pcm.resize(y.size() * 2)
	for i in y.size():
		pcm.encode_s16(i * 2, int(y[i] * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = pcm
	return wav

# ---------------------------------------------------------------- answer back
# Two knocks in the wall beside you. Then it waits. Say anything, and when you stop, after a moment, the wall knocks
# back: once for every word you said. (No microphone: it knocks back three times anyway, after a while.)
func _event_answer_back() -> void:
	var face := _wall_face_nearest(6.0)
	if not face.is_finite():
		face = _wall_face_behind(4.0, 9.0)
	if not face.is_finite():
		return
	var st := {"done": false}
	later(0.5, func(): scares.knock(face, 0.9))
	later(0.95, func(): scares.knock(face, 0.9))
	haunt(0.3)
	var knock_back := func(n: int) -> void:
		if st.done: return
		st.done = true
		_hush(4.0 + n * 0.5, 0.1)
		for i in n:
			later(1.8 + i * 0.45, func(): scares.knock(face, 1.0 + 0.04 * i))
		later(2.0 + n * 0.45, func(): haunt(0.9))
	var answer := func(_pcm: PackedFloat32Array, syl: int, _loud: float) -> void: knock_back.call(clampi(syl, 1, 9))
	_listen(answer)
	if not Voice.mic_live():
		later(9.0, func(): knock_back.call(3))
	later(45.0, func(): _unlisten(answer))

# ---------------------------------------------------------------- your own voice
# Your voice, saying something you said a while ago, from somewhere ahead of you down the hall, clear, as if you were
# standing there. A little later, again, nearer, a little lower. (Your own last few sentences into the mic, kept on
# your machine only, single player too. Nothing recorded yet: the terminal says so, and nothing plays.)
func _event_your_own_voice() -> void:
	var clip: PackedFloat32Array = Voice.my_clip()
	if clip.is_empty():
		_toast("ACOUSTIC ARCHIVE", [{"kind": "text", "text": "NO RECORDING OF YOUR VOICE YET.", "size": 15},
			{"kind": "text", "text": "SPEAK INTO YOUR MICROPHONE. IT IS LISTENING.", "size": 13, "color": Color(0.949, 0.902, 0.722, 0.5)}])
		return
	var stream := Voice.pcm_stream(clip)
	var far: Vector3 = find_corridor_spot(9.0, 18.0).pos
	haunt(0.5)
	_hush(10.0, 0.2)
	later(0.8, func():
		var p: AudioStreamPlayer3D = scares.spawn3d(stream, far, 1.0, "Scares", 7.0, 1.0, false)     # not through walls: clear
		p.max_distance = 40.0)
	later(8.0, func():
		var nearer := far.lerp(player.global_position + Vector3.UP * 1.4, 0.6)
		var p: AudioStreamPlayer3D = scares.spawn3d(stream, nearer, 0.95, "Scares", 5.0, 0.95, false)
		p.max_distance = 30.0
		haunt(0.8))

# ---------------------------------------------------------------- the doorbell
# A doorbell. Ding, dong. In a building with no doors that open onto anything. Far off down the halls; a while
# later, nearer.
func _event_doorbell() -> void:
	if not ResourceLoader.exists("res://audio/events/doorbell.wav"):
		return
	var bell: AudioStream = load("res://audio/events/doorbell.wav")
	var far: Vector3 = find_corridor_spot(14.0, 26.0).pos
	_hush(4.0, 0.3)
	later(0.6, func(): scares.spawn3d(bell, far, 0.8, "Scares", 7.0, 1.0))
	later(9.0, func():
		scares.spawn3d(bell, far.lerp(player.global_position + Vector3.UP * 1.4, 0.6), 0.7, "Scares", 5.0, 0.97)
		haunt(0.7))

# ---------------------------------------------------------------- look up
# A terminal advisory, calm and official: a meteorological event overhead, do not look up. A moment later, another
# card: IF YOU ARE AFRAID, WE WILL LOOK TOGETHER. And your head tilts back, by itself, slowly, until you are looking
# straight up at the ceiling tiles. The tubes over you go out. You hold there in the dark, then you are let go.
# (Local 58, "Weather Service".)
func _event_look_together() -> void:
	on_clear(func():
		player.frozen = false
		player.held_by_event = false
		Game.fx_reset())
	_toast("COUNTY SERVICE ADVISORY", [
		{"kind": "text", "text": "A METEOROLOGICAL EVENT IS IN PROGRESS OVERHEAD.", "size": 16, "wrap": true},
		{"kind": "rule"},
		{"kind": "pair", "left": "DO NOT LOOK UP", "right": "ADVISED", "color": Color("ff4636")},
	])
	_hush(20.0, 0.2)
	later(7.5, func():
		_toast("COUNTY SERVICE ADVISORY", [
			{"kind": "text", "text": "IF YOU ARE AFRAID, WE WILL LOOK TOGETHER.", "size": 18, "wrap": true},
		])
		haunt(0.6))
	var st := {"fired": false}
	watch(func(dt: float, t: float) -> bool:
		if t < 9.5:
			return true
		if t > 18.0:
			player.frozen = false
			player.held_by_event = false
			Game.fx_reset()
			return false
		player.frozen = true
		player.held_by_event = true   # (nothing has you: the hands stay, torch_model.gd)
		var cam: Camera3D = player.cam
		if t < 15.0:
			cam.rotation.x = minf(cam.rotation.x + dt * 0.24, 1.35)          # your head going back, slowly
			Game.fx_blur = 0.12 * smoothstep(9.5, 15.0, t)
		elif not st.fired:
			st.fired = true
			for f in level.fixtures_near(player.global_position, 7.0):
				level.cut_fixture(f, 6.0)
				level.fixture_event.emit(f, false)
			scares.heartbeat(1.0)
			haunt(1.0)
		return true)

# ---------------------------------------------------------------- sounds to avoid
# A terminal card lists three sounds to avoid, plainly, like a safety leaflet. A little later you hear the third
# one. (Gemini Home Entertainment, "Sounds to Avoid".)
func _avoid_knocks() -> void:
	var face := _wall_face_behind(4.0, 10.0)
	if not face.is_finite(): face = sound_spot(6.0)
	for i in 3:
		later(i * 0.9, func(): scares.knock(face, 1.1, scares.KNOCK_FIST))

func _avoid_breath() -> void:
	scares.breath_behind(_behind_neck(0.7), 1.0)

func _avoid_steps() -> void:
	var at := sound_spot(5.0)
	for i in 3:
		later(i * 0.7, func(): _carpet_step(at, 0.7))

func _avoid_doorbell() -> void:
	if ResourceLoader.exists("res://audio/events/doorbell.wav"):
		scares.spawn3d(load("res://audio/events/doorbell.wav"), find_corridor_spot(8.0, 16.0).pos, 0.75, "Scares", 6.0, 1.0)

func _avoid_phone() -> void:
	if ResourceLoader.exists("res://audio/events/phone_ring.wav"):
		var p: AudioStreamPlayer3D = scares.spawn3d(load("res://audio/events/phone_ring.wav"), find_corridor_spot(10.0, 20.0).pos, 0.8, "Scares", 7.0, 1.0)
		get_tree().create_timer(1.1).timeout.connect(func(): _free(p))

func _avoid_own_voice() -> void:
	var clip: PackedFloat32Array = Voice.my_clip()
	if not clip.is_empty():
		scares.spawn3d(Voice.pcm_stream(clip), find_corridor_spot(8.0, 16.0).pos, 0.9, "Scares", 5.0, 0.96)

func _event_sounds_to_avoid() -> void:
	var options: Array = [
		["THREE SLOW KNOCKS", _avoid_knocks],
		["BREATHING THAT IS NOT YOUR OWN", _avoid_breath],
		["FOOTSTEPS THAT STOP WHEN YOU DO", _avoid_steps],
		["A DOORBELL", _avoid_doorbell],
		["A PHONE THAT STOPS RINGING", _avoid_phone],
	]
	if not Voice.my_clips.is_empty():
		options.append(["YOUR OWN VOICE", _avoid_own_voice])
	options.shuffle()
	var picks: Array = options.slice(0, 3)
	_toast("SOUNDS TO AVOID", [
		{"kind": "text", "text": "01   %s" % picks[0][0], "size": 15},
		{"kind": "text", "text": "02   %s" % picks[1][0], "size": 15},
		{"kind": "text", "text": "03   %s" % picks[2][0], "size": 15},
		{"kind": "rule"},
		{"kind": "text", "text": "IF YOU HEAR ONE OF THESE, DO NOT RESPOND.", "size": 14, "color": Color(0.949, 0.902, 0.722, 0.5), "wrap": true},
	])
	later(10.0, func():
		_hush(6.0, 0.15)
		(picks[2][1] as Callable).call()
		haunt(0.8))

# ---------------------------------------------------------------- countdown
# A timer appears at the top of the screen, counting down from sixty. Nothing explains it. At zero it blinks, and
# nothing happens. Then it starts counting up.
var _count_label: Label

func _event_countdown() -> void:
	if _count_label == null or not is_instance_valid(_count_label):
		_count_label = Label.new()
		_count_label.add_theme_font_override("font", load("res://fonts/vcr.ttf"))
		_count_label.add_theme_font_size_override("font_size", 40)
		_count_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
		_count_label.add_theme_constant_override("shadow_offset_y", 2)
		_count_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
		_count_label.position = Vector2(-200, 130)
		_count_label.size = Vector2(400, 50)
		_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		banner_layer.add_child(_count_label)
	var lab := _count_label
	lab.visible = not Game.hide_hud
	on_clear(func():
		if is_instance_valid(lab): lab.visible = false)
	haunt(0.2)
	watch(func(dt: float, t: float) -> bool:
		if not is_instance_valid(lab):
			return false
		lab.visible = not Game.hide_hud
		if t < 60.0:
			var left := ceili(60.0 - t)
			lab.text = "00:%02d" % left
			lab.add_theme_color_override("font_color", Color(0.85, 0.12, 0.08) if left <= 10 else Color(0.75, 0.1, 0.06, 0.85))
		elif t < 64.0:
			lab.text = "00:00"
			lab.modulate.a = 1.0 if fmod(t, 0.6) < 0.3 else 0.0           # it blinks. Nothing happens
		elif t < 94.0:
			lab.modulate.a = 1.0
			lab.text = "+00:%02d" % int(t - 64.0)
			lab.add_theme_color_override("font_color", Color(0.6, 0.08, 0.05, 0.55))
		else:
			lab.visible = false
			return false
		return true)
	later(60.0, func():
		_hush(4.0, 0.0)
		haunt(0.7))
