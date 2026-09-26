extends Node
## Co-op over WebSocket (autoload: Net). One PC hosts a local WebSocket server; `cloudflared tunnel`
## exposes it as a public wss:// URL that the others paste into JOIN. Cloudflare tunnels only carry
## HTTP/WebSocket (no UDP), which is why this is WebSocketMultiplayerPeer and not ENet.
## Every survivor sends a timestamped snapshot (position, look, speed, torch...) 20 times a second;
## the others draw it with snapshot interpolation (snap_buffer.gd). The host runs THE BACTERIA and the
## event director for everyone and sets which level everyone is on.

signal status_changed(text: String)
signal tunnel_url_changed(url: String)

const DEFAULT_PORT := 8910
const SEND_INTERVAL := 1.0 / 20.0
const HELLO_TIMEOUT := 6.0       # no hello from the host by then: we are on different game versions
const NAME_MAX := 16
const MAX_PLAYERS := 8
const CLOUDFLARED_PATHS := [
	"C:/Program Files (x86)/cloudflared/cloudflared.exe",
	"C:/Program Files/cloudflared/cloudflared.exe",
]
const PEER_COLORS := [
	Color("c9a44a"), Color("6fa0b8"), Color("b8666a"), Color("7fae72"),
	Color("a07ec0"), Color("d08a4e"), Color("5fb0a4"), Color("c4c07a"),
]

var hosting := false
var PORT := DEFAULT_PORT        # --port=N overrides it (two copies on one PC)
var _hello_wait := -1.0
var status := "OFFLINE"
var tunnel_url := ""
var debug := false               # --net-debug: print what the entity is doing on this machine
var _dbg_t := 0.0
var launch_name := ""           # --player-name= from the launcher
var names := {}                 # peer id -> callsign ("" until they send one)
var remotes := {}               # peer id -> RemotePlayer

var _send_t := 0.0
var _cf_pid := -1
var _cf_thread: Thread
var _quit := false

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	# The launcher passes --join=<host or tunnel link> and --player-name=<name>
	var join_to := ""
	var host_mode := ""
	for a in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if a.begins_with("--join="):
			join_to = a.substr(7)
		elif a.begins_with("--player-name="):
			launch_name = a.substr(14).strip_edges().left(NAME_MAX).to_upper()
		elif a == "--host" or a == "--host-local":       # open the lobby straight away (-local: no tunnel)
			host_mode = a
		elif a.begins_with("--port="):
			PORT = int(a.substr(7))
		elif a == "--net-debug":
			debug = true
	if join_to != "":
		join.call_deferred(join_to)
	elif host_mode != "":
		host.call_deferred(host_mode == "--host-local")

func _exit_tree() -> void:
	_stop_tunnel()

# ---- public API ---------------------------------------------------------------------
func is_online() -> bool:
	var p := multiplayer.multiplayer_peer
	return p != null and not (p is OfflineMultiplayerPeer) and p.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED

func host(local_only := false) -> void:
	leave()
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(PORT)
	if err != OK:
		_set_status("COULD NOT OPEN PORT %d (ALREADY HOSTING?)" % PORT)
		return
	multiplayer.multiplayer_peer = peer
	hosting = true
	_set_status("LOBBY OPEN ON PORT %d // STARTING TUNNEL..." % PORT)
	if not local_only:
		_start_tunnel()

func join(address: String) -> void:
	var url := normalize_url(address)
	if url == "":
		_set_status("ENTER THE HOST'S ADDRESS")
		return
	leave()
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(url)
	if err != OK:
		_set_status("BAD ADDRESS")
		return
	multiplayer.multiplayer_peer = peer
	_set_status("CONNECTING TO %s ..." % url.get_slice("://", 1).to_upper())

func leave() -> void:
	_stop_tunnel()
	var p := multiplayer.multiplayer_peer
	if p != null and not (p is OfflineMultiplayerPeer):
		p.close()
	multiplayer.multiplayer_peer = null
	hosting = false
	_clear_remotes()
	_set_tunnel_url("")
	_set_status("OFFLINE")

func my_name() -> String:
	var n := ""
	if Game.main and Game.main.get("ui"):
		n = Game.main.ui.menu.callsign.strip_edges().left(NAME_MAX)
	return n if n != "" else launch_name

func label_for(id: int) -> String:
	var n: String = names.get(id, "")
	return n if n != "" else "SURVIVOR %02d" % id

## Host: everyone follows when the level changes (called from Game.change_level)
func broadcast_level(idx: int) -> void:
	if hosting and is_online():
		_level.rpc(idx)

## "abc.trycloudflare.com" -> wss://abc.trycloudflare.com; "192.168.1.5" -> ws://192.168.1.5:8910
static func normalize_url(addr: String) -> String:
	var a := addr.strip_edges()
	if a == "":
		return ""
	var scheme := ""
	var i := a.find("://")
	if i >= 0:
		scheme = a.substr(0, i).to_lower()
		a = a.substr(i + 3)
	a = a.trim_suffix("/")
	var host_part := a.get_slice("/", 0).get_slice(":", 0)
	var local := host_part == "localhost" or host_part.is_valid_ip_address()
	var tls := not (local or a.get_slice("/", 0).contains(":"))
	if scheme == "wss" or scheme == "https":
		tls = true
	elif scheme == "ws" or scheme == "http":
		tls = false
	if not tls and not a.get_slice("/", 0).contains(":"):
		a += ":%d" % DEFAULT_PORT
	return ("wss://" if tls else "ws://") + a

# ---- connection events ----------------------------------------------------------------
func _on_peer_connected(id: int) -> void:
	if multiplayer.get_peers().size() + 1 > MAX_PLAYERS and hosting:
		multiplayer.multiplayer_peer.disconnect_peer(id)
		return
	names[id] = ""
	_hello.rpc_id(id, my_name())
	if hosting:
		_level.rpc_id(id, Game.level_index)
	_ensure_remote(id)
	_update_count()

func _on_peer_disconnected(id: int) -> void:
	var r: Node = remotes.get(id)
	if r:
		r.queue_free()
	remotes.erase(id)
	names.erase(id)
	_update_count()

func _on_connected() -> void:
	_hello_wait = HELLO_TIMEOUT
	_set_status("CONNECTED // %d SURVIVOR(S)" % (multiplayer.get_peers().size() + 1))

func _on_connection_failed() -> void:
	leave()
	_set_status("COULD NOT CONNECT // CHECK THE ADDRESS AND THAT THE HOST IS ONLINE")

func _on_server_disconnected() -> void:
	leave()
	_set_status("SIGNAL LOST // HOST CLOSED THE LOBBY")

func _update_count() -> void:
	if not is_online():
		return
	var n := multiplayer.get_peers().size() + 1
	if hosting:
		var extra := ("  //  " + tunnel_url) if tunnel_url != "" else ""
		_set_status("HOSTING // %d SURVIVOR(S)%s" % [n, extra])
	else:
		_set_status("CONNECTED // %d SURVIVORS" % n)

# ---- RPCs -------------------------------------------------------------------------------
@rpc("any_peer", "reliable")
func _hello(callsign: String) -> void:
	var id := multiplayer.get_remote_sender_id()
	names[id] = callsign.strip_edges().left(NAME_MAX).to_upper()
	if id == 1:
		_hello_wait = -1.0
	var r: Node = remotes.get(id)
	if r:
		r.set_label(label_for(id))

@rpc("authority", "call_remote", "reliable")
func _level(idx: int) -> void:
	if idx != Game.level_index:
		Game.change_level(idx)

@rpc("any_peer", "call_remote", "unreliable_ordered")
func _state(t: float, pos: Vector3, yaw: float, pitch: float, spd: float, flags: int, level: int) -> void:
	var id := multiplayer.get_remote_sender_id()
	var r: Node = _ensure_remote(id)
	r.push_state(t, pos, yaw, pitch, spd, flags, level)

## Snapshot clock: simulated time of the physics step the position comes from. Wall time would be off
## by up to a frame (several physics steps run back to back in one frame), which shows as stutter.
static func clock() -> float:
	return Engine.get_physics_frames() / float(Engine.physics_ticks_per_second)

# ---- monsters and events: the host's PC decides, everyone else follows ----------------------
func id_of(node: Node) -> int:
	for id in remotes:
		if remotes[id] == node:
			return id
	return 0

func _scene_node(node_name: String) -> Node:
	if Game.main != null and is_instance_valid(Game.main):
		return Game.main.get_node_or_null(node_name)
	return null

func send_entity(m: Array) -> void:
	if hosting and is_online() and not multiplayer.get_peers().is_empty():
		_entity.rpc(clock(), m)

@rpc("authority", "call_remote", "unreliable_ordered")
func _entity(t: float, m: Array) -> void:
	var ent := _scene_node("Entity")
	if ent != null and ent.has_method("net_apply"):
		ent.net_apply(t, m)

## Host: an event just started (or was stopped): everyone gets the same scare at the same moment
func send_event(event_name: String) -> void:
	if hosting and is_online() and not multiplayer.get_peers().is_empty():
		_event.rpc(event_name)

func send_stop_events() -> void:
	if hosting and is_online() and not multiplayer.get_peers().is_empty():
		_stop_events.rpc()

@rpc("authority", "call_remote", "reliable")
func _event(event_name: String) -> void:
	var ev := _scene_node("Events")
	if ev != null:
		ev.run_event(event_name)

@rpc("authority", "call_remote", "reliable")
func _stop_events() -> void:
	var ev := _scene_node("Events")
	if ev != null:
		ev.stop_all()

# ---- remote survivors ----------------------------------------------------------------------
func _ensure_remote(id: int) -> Node:
	if remotes.has(id) and is_instance_valid(remotes[id]):
		return remotes[id]
	var r: Node3D = load("res://scripts/net/remote_player.gd").new()
	r.color = PEER_COLORS[id % PEER_COLORS.size()]
	add_child(r)      # the autoload outlives level reloads, so peers don't vanish on respawn
	r.set_label(label_for(id))
	remotes[id] = r
	return r

func _clear_remotes() -> void:
	for r in remotes.values():
		if is_instance_valid(r):
			r.queue_free()
	remotes.clear()
	names.clear()

func _process(dt: float) -> void:
	if not is_online():
		return
	if _hello_wait > 0.0:
		_hello_wait -= dt
		if _hello_wait <= 0.0:
			leave()
			_set_status("THE HOST RUNS A DIFFERENT VERSION // BOTH OF YOU: UPDATE IN THE LAUNCHER")
			return
	if debug:
		_dbg_t -= dt
		if _dbg_t <= 0.0:
			_dbg_t = 2.0
			var ent := _scene_node("Entity")
			if ent != null:
				printerr("NETDBG ", "HOST" if hosting else "GUEST", " peers=", multiplayer.get_peers().size(), " remotes=", remotes.size(),
					" entity=(%.1f,%.1f) state=%s puppet=%s" % [ent.global_position.x, ent.global_position.z, ent.state, ent.puppet],
					" me=", Game.player.global_position if Game.player else Vector3.ZERO, " sees=", remotes.values().map(func(r): return r.global_position))

# Snapshots go out from the physics step, where positions are set: 20 per second on a fixed grid
func _send_state(dt: float) -> void:
	_send_t -= dt
	if _send_t > 0.0:
		return
	_send_t += SEND_INTERVAL
	if _send_t < -SEND_INTERVAL:
		_send_t = 0.0                  # fell far behind (hitch): don't burst
	var p: Node = Game.player
	if p == null or not is_instance_valid(p):
		return
	var cam: Camera3D = p.get_node_or_null("Camera3D")
	var v: Vector3 = p.velocity if p is CharacterBody3D else Vector3.ZERO
	var flags := (1 if p.get("is_crouching") else 0) | (2 if p.get("flash_on") else 0) | (4 if p.get("dead") else 0) | (8 if Game.playing else 0)
	_state.rpc(clock(), p.global_position, p.rotation.y, cam.rotation.x if cam else 0.0,
		Vector2(v.x, v.z).length(), flags, Game.level_index)

# ---- cloudflared ------------------------------------------------------------------------------
func _start_tunnel() -> void:
	var exe := "cloudflared"
	for path in CLOUDFLARED_PATHS:
		if FileAccess.file_exists(path):
			exe = path
			break
	var info := OS.execute_with_pipe(exe, ["tunnel", "--url", "http://localhost:%d" % PORT])
	if info.is_empty():
		_set_status("LOBBY OPEN // CLOUDFLARED NOT FOUND: INSTALL IT (winget install Cloudflare.cloudflared) OR SHARE YOUR IP:%d" % PORT)
		return
	_cf_pid = info["pid"]
	_quit = false
	_cf_thread = Thread.new()
	_cf_thread.start(_read_tunnel.bind(info["stderr"]))     # cloudflared logs to stderr

func _read_tunnel(pipe: FileAccess) -> void:
	var re := RegEx.new()
	re.compile("https://[a-z0-9-]+\\.trycloudflare\\.com")
	while not _quit and pipe.is_open():
		var line := pipe.get_line()
		if line == "" and pipe.get_error() != OK:
			break
		var m := re.search(line)
		if m and m.get_string() != "https://api.trycloudflare.com":
			_tunnel_found.call_deferred(m.get_string())

func _tunnel_found(url: String) -> void:
	if not hosting:
		return
	_set_tunnel_url(url)
	_update_count()

func _stop_tunnel() -> void:
	_quit = true
	if _cf_pid > 0:
		OS.kill(_cf_pid)         # closes the pipe, which unblocks the reader thread
		_cf_pid = -1
	if _cf_thread and _cf_thread.is_started():
		_cf_thread.wait_to_finish()
	_cf_thread = null

func _set_tunnel_url(url: String) -> void:
	tunnel_url = url
	tunnel_url_changed.emit(url)

func _set_status(text: String) -> void:
	status = text
	status_changed.emit(text)

# Snapshots are sent from the physics step, on a fixed grid
func _physics_process(dt: float) -> void:
	if not is_online():
		return
	_send_state(dt)
