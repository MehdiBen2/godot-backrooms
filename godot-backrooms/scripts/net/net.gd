extends Node
## Co-op over WebSocket (autoload: Net). One PC hosts a local WebSocket server; `cloudflared tunnel`
## exposes it as a public wss:// URL that the others paste into JOIN. Cloudflare tunnels only carry
## HTTP/WebSocket (no UDP), which is why this is WebSocketMultiplayerPeer and not ENet.
## Every survivor sends position / look / torch at 15 Hz; the host also sets which level everyone is on.
## The entities still run locally on each machine (not synced yet).

signal status_changed(text: String)
signal tunnel_url_changed(url: String)

const PORT := 8910
const SEND_INTERVAL := 1.0 / 15.0
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
var status := "OFFLINE"
var tunnel_url := ""
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
	for a in OS.get_cmdline_args():
		if a.begins_with("--join="):
			join_to = a.substr(7)
		elif a.begins_with("--player-name="):
			launch_name = a.substr(14).strip_edges().left(NAME_MAX).to_upper()
	if join_to != "":
		join.call_deferred(join_to)

func _exit_tree() -> void:
	_stop_tunnel()

# ---- public API ---------------------------------------------------------------------
func is_online() -> bool:
	var p := multiplayer.multiplayer_peer
	return p != null and not (p is OfflineMultiplayerPeer) and p.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED

func host() -> void:
	leave()
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(PORT)
	if err != OK:
		_set_status("COULD NOT OPEN PORT %d (ALREADY HOSTING?)" % PORT)
		return
	multiplayer.multiplayer_peer = peer
	hosting = true
	_set_status("LOBBY OPEN ON PORT %d // STARTING TUNNEL..." % PORT)
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
		a += ":%d" % PORT
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
	var r: Node = remotes.get(id)
	if r:
		r.set_label(label_for(id))

@rpc("authority", "call_remote", "reliable")
func _level(idx: int) -> void:
	if idx != Game.level_index:
		Game.change_level(idx)

@rpc("any_peer", "call_remote", "unreliable_ordered")
func _state(pos: Vector3, yaw: float, pitch: float, crouch: bool, torch: bool, dead: bool) -> void:
	var id := multiplayer.get_remote_sender_id()
	var r: Node = _ensure_remote(id)
	r.apply_state(pos, yaw, pitch, crouch, torch, dead)

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
	_send_t -= dt
	if _send_t > 0.0:
		return
	_send_t = SEND_INTERVAL
	var p: Node = Game.player
	if p == null or not is_instance_valid(p):
		return
	var cam: Camera3D = p.get_node_or_null("Camera3D")
	_state.rpc(p.global_position, p.rotation.y, cam.rotation.x if cam else 0.0,
		bool(p.get("is_crouching")), bool(p.get("flash_on")), bool(p.get("dead")))

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
