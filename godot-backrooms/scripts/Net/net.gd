extends Node
## Co-op (autoload: Net). One PC hosts an ENet (UDP) server, opens its port through the router with UPnP and
## shows a ROOM CODE: the host's public IP and port packed into 10 letters (no server involved). Friends type
## the code into JOIN. Where UPnP/CGNAT blocks that, "host via tunnel" is the fallback: a WebSocket server
## exposed by `cloudflared tunnel` as a wss:// link (TCP only, so laggier), which JOIN also accepts.
## Every survivor sends a timestamped snapshot (position, look, speed, torch...) 20 times a second;
## the others draw it with snapshot interpolation (snap_buffer.gd). The host runs THE BACTERIA and the
## event director for everyone and sets which level everyone is on.

signal status_changed(text: String)
signal share_link_changed(text: String)

const DEFAULT_PORT := 8910
const SEND_INTERVAL := 1.0 / 20.0
const HELLO_TIMEOUT := 6.0       # no hello from the host by then: we are on different game versions
const NAME_MAX := 16
const MAX_PLAYERS := 8
## Bump whenever an RPC signature or snapshot layout changes: peers with a different number are refused
## with a clear message instead of silently desyncing. (A changed _hello signature itself still falls
## back to the HELLO_TIMEOUT check, since Godot drops RPCs whose arguments don't match.)
const PROTOCOL := 5
const TapeMarks := preload("res://scripts/World/props/tape_marks.gd")
const FlashTool := preload("res://scripts/Player/flash_tool.gd")
const TAPE_BATCH_MAX := 1000     # strips in one _tape_rpc (a newcomer gets everyone's in one go)
const MAX_COORD := 100000.0      # snapshots further out than this are garbage, not a position
const CODE_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"    # 32 symbols, no I/O/0/1
const CODE_LEN := 10                                          # 50 bits >= 4 IP bytes + 2 port bytes
const UPNP_DISCOVER_MS := 2000
const IP_LOOKUP_URL := "https://api.ipify.org"
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
var share_link := ""            # what the host sends to friends: the room code (or the tunnel link)
var debug := false               # --net-debug: print what the entity is doing on this machine
var _dbg_t := 0.0
var launch_name := ""           # --player-name= from the launcher
var names := {}                 # peer id -> callsign ("" until they send one)
var build_tag := ""             # release tag from the launcher's version.txt ("DEV" when run from the editor)
var remotes := {}               # peer id -> RemotePlayer

var _send_t := 0.0
var _cf_pid := -1
var _cf_thread: Thread
var _quit := false
var _upnp: UPNP
var _upnp_thread: Thread
var _port_note := ""            # shown under the room code when the router/ISP will likely block friends
var _host_token := 0           # bumped on every host()/leave(): a slow UPnP/IP lookup from an old lobby is ignored

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	build_tag = _read_build_tag()
	# The launcher passes --join=<host or tunnel link> and --player-name=<name>
	var join_to := ""
	var host_mode := ""
	for a in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if a.begins_with("--join="):
			join_to = a.substr(7)
		elif a.begins_with("--player-name="):
			launch_name = clean_name(a.substr(14))
		elif a == "--host" or a == "--host-local" or a == "--host-tunnel":   # open the lobby straight away (-local: LAN only, -tunnel: cloudflared)
			host_mode = a
		elif a.begins_with("--port="):
			PORT = int(a.substr(7))
		elif a == "--net-debug":
			debug = true
	if join_to != "":
		join.call_deferred(join_to)
	elif host_mode != "":
		host.call_deferred(host_mode == "--host-local", host_mode == "--host-tunnel")

func _exit_tree() -> void:
	_stop_tunnel()
	_stop_upnp()

# ---- public API ---------------------------------------------------------------------
func is_online() -> bool:
	var p := multiplayer.multiplayer_peer
	return p != null and not (p is OfflineMultiplayerPeer) and p.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED

## Default: ENet + UPnP + room code. local_only: LAN code, no UPnP. tunnel: the cloudflared WebSocket fallback.
func host(local_only := false, tunnel := false) -> void:
	leave()
	if tunnel:
		var ws := WebSocketMultiplayerPeer.new()
		if ws.create_server(PORT) != OK:
			_set_status("COULD NOT OPEN PORT %d (ALREADY HOSTING?)" % PORT)
			return
		multiplayer.multiplayer_peer = ws
		hosting = true
		_set_status("LOBBY OPEN ON PORT %d // STARTING TUNNEL..." % PORT)
		_start_tunnel()
		return
	var peer := ENetMultiplayerPeer.new()
	if peer.create_server(PORT, MAX_PLAYERS - 1) != OK:
		_set_status("COULD NOT OPEN UDP PORT %d (ALREADY HOSTING?)" % PORT)
		return
	multiplayer.multiplayer_peer = peer
	hosting = true
	if local_only:
		var lan := _lan_address()
		_set_share_link(encode_code(lan, PORT) if lan != "" else "")
		_set_status("LAN LOBBY OPEN ON PORT %d" % PORT)
		return
	_set_status("LOBBY OPEN ON PORT %d // OPENING THE ROUTER PORT..." % PORT)
	_upnp_thread = Thread.new()
	_upnp_thread.start(_upnp_worker.bind(PORT, _host_token))

## "ABCDE-FGHJK" or "1.2.3.4[:port]" -> ENet; a wss:// link or a hostname -> the WebSocket tunnel
func join(address: String) -> void:
	var target := parse_address(address)
	if target.is_empty():
		_set_status("ENTER THE HOST'S ROOM CODE")
		return
	leave()
	if target.has("url"):
		var ws := WebSocketMultiplayerPeer.new()
		if ws.create_client(target.url) != OK:
			_set_status("BAD ADDRESS")
			return
		multiplayer.multiplayer_peer = ws
		_set_status("CONNECTING TO %s ..." % target.url.get_slice("://", 1).to_upper())
		return
	var peer := ENetMultiplayerPeer.new()
	if peer.create_client(target.ip, target.port) != OK:
		_set_status("BAD ROOM CODE")
		return
	multiplayer.multiplayer_peer = peer
	_set_status("CONNECTING ...")

func leave() -> void:
	_stop_tunnel()
	_stop_upnp()
	var p := multiplayer.multiplayer_peer
	if p != null and not (p is OfflineMultiplayerPeer):
		p.close()
	multiplayer.multiplayer_peer = null
	hosting = false
	_clear_remotes()
	_set_share_link("")
	_set_status("OFFLINE")

# ---- room codes: IP (4 bytes) + port (2 bytes) as 10 letters, e.g. K7QM2-XD9PA -----------------------
static func encode_code(ip: String, port: int) -> String:
	var parts := ip.split(".")
	if parts.size() != 4 or port <= 0 or port > 65535:
		return ""
	var n := port
	for i in 4:
		var b := int(parts[i])
		if not parts[i].is_valid_int() or b < 0 or b > 255:
			return ""
		n |= b << (16 + 8 * (3 - i))
	var out := ""
	for i in CODE_LEN:
		out = CODE_ALPHABET[n & 31] + out
		n >>= 5
	return out.left(5) + "-" + out.substr(5)

## {"ip", "port"} for a valid code, else {}
static func decode_code(code: String) -> Dictionary:
	var s := code.to_upper().replace("-", "").replace(" ", "")
	if s.length() != CODE_LEN:
		return {}
	var n := 0
	for c in s:
		var v := CODE_ALPHABET.find(c)
		if v < 0:
			return {}
		n = (n << 5) | v
	if n >> 48 != 0:
		return {}
	var port := n & 0xFFFF
	if port == 0:
		return {}
	return {"ip": "%d.%d.%d.%d" % [(n >> 40) & 255, (n >> 32) & 255, (n >> 24) & 255, (n >> 16) & 255], "port": port}

## What the JOIN field means: {"ip","port"} (ENet), {"url"} (WebSocket tunnel) or {} (empty)
static func parse_address(addr: String) -> Dictionary:
	var a := addr.strip_edges()
	if a == "":
		return {}
	var code := decode_code(a)
	if not code.is_empty():
		return code
	var host_part := a.get_slice(":", 0)
	if "://" not in a and host_part.is_valid_ip_address():
		var port := int(a.get_slice(":", 1)) if ":" in a else DEFAULT_PORT
		return {"ip": host_part, "port": port if port > 0 and port <= 65535 else DEFAULT_PORT}
	return {"url": normalize_url(a)}

func _lan_address() -> String:
	for ip in IP.get_local_addresses():
		if ip.count(".") == 3 and (ip.begins_with("192.168.") or ip.begins_with("10.") or ip.begins_with("172.")):
			return ip
	return ""

# ---- router port (UPnP) and public IP ----------------------------------------------------------------
func _upnp_worker(port: int, token: int) -> void:
	var u := UPNP.new()
	var mapped := false
	var ext := ""
	if u.discover(UPNP_DISCOVER_MS, 2, "InternetGatewayDevice") == UPNP.UPNP_RESULT_SUCCESS \
			and u.get_gateway() != null and u.get_gateway().is_valid_gateway():
		mapped = u.add_port_mapping(port, port, "Backrooms", "UDP") == UPNP.UPNP_RESULT_SUCCESS
		ext = u.query_external_address()
	_upnp_done.call_deferred(u, mapped, ext, token)

func _upnp_done(u: UPNP, mapped: bool, router_ip: String, token: int) -> void:
	if token != _host_token or not hosting:      # a stale lobby (its thread was already joined by _stop_upnp)
		if mapped:
			u.delete_port_mapping(PORT, "UDP")
		return
	_upnp_thread.wait_to_finish()
	_upnp_thread = null
	_upnp = u if mapped else null
	var http := HTTPRequest.new()
	http.timeout = 6.0
	add_child(http)
	http.request_completed.connect(_ip_looked_up.bind(http, mapped, router_ip, token))
	if http.request(IP_LOOKUP_URL) != OK:
		http.queue_free()
		_publish_code("", mapped, router_ip)

func _ip_looked_up(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray,
		http: HTTPRequest, mapped: bool, router_ip: String, token: int) -> void:
	http.queue_free()
	if token != _host_token or not hosting:
		return
	var ip := body.get_string_from_utf8().strip_edges() if result == HTTPRequest.RESULT_SUCCESS and code == 200 else ""
	_publish_code(ip if ip.is_valid_ip_address() else "", mapped, router_ip)

func _publish_code(web_ip: String, mapped: bool, router_ip: String) -> void:
	var ip := web_ip if web_ip != "" else router_ip
	var code := encode_code(ip, PORT) if ip.count(".") == 3 else ""
	if code == "":
		_set_status("LOBBY OPEN // COULD NOT FIND YOUR PUBLIC IP: CHECK YOUR INTERNET, OR USE HOST VIA TUNNEL")
		return
	_set_share_link(code)
	_port_note = ""
	if router_ip != "" and web_ip != "" and router_ip != web_ip:
		_port_note = "YOUR ISP SHARES ONE IP (CGNAT): FRIENDS CAN'T REACH YOU, USE HOST VIA TUNNEL"
	elif not mapped:
		_port_note = "ROUTER REFUSED UPNP: FORWARD UDP PORT %d TO THIS PC, OR USE HOST VIA TUNNEL" % PORT
	_update_count()

func _stop_upnp() -> void:
	_host_token += 1
	if _upnp_thread != null:
		_upnp_thread.wait_to_finish()       # a few seconds at most (discover timeout); its callback sees the new token
		_upnp_thread = null
	if _upnp != null:
		_upnp.delete_port_mapping(PORT, "UDP")
		_upnp = null
	_port_note = ""

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
	_hello.rpc_id(id, my_name(), PROTOCOL, build_tag)
	if hosting:
		_level.rpc_id(id, Game.level_index)
		if mq_level >= 0:
			_mq_seed_rpc.rpc_id(id, mq_level, mq_seed)      # the same mannequin room for the newcomer
	var tape := TapeMarks.pack_mine()
	if not tape.is_empty():
		_tape_rpc.rpc_id(id, tape.slice(-TAPE_BATCH_MAX))  # the tape we already stuck up, for the newcomer
	_ensure_remote(id)
	_update_count()

func _on_peer_disconnected(id: int) -> void:
	var r: Node = remotes.get(id)
	if r:
		r.queue_free()
	remotes.erase(id)
	names.erase(id)
	_mq_view.erase(id)
	_update_count()

func _on_connected() -> void:
	_hello_wait = HELLO_TIMEOUT
	_set_status("CONNECTED // %d SURVIVOR(S)" % (multiplayer.get_peers().size() + 1))

func _on_connection_failed() -> void:
	leave()
	_set_status("COULD NOT CONNECT // CHECK THE CODE, THAT THE HOST IS ONLINE, AND THAT THEIR ROUTER OPENED THE PORT")

func _on_server_disconnected() -> void:
	leave()
	_set_status("SIGNAL LOST // HOST CLOSED THE LOBBY")

func _update_count() -> void:
	if not is_online():
		return
	var n := multiplayer.get_peers().size() + 1
	if hosting:
		var extra := ("  //  " + share_link) if share_link != "" else ""
		if _port_note != "":
			extra += "  //  " + _port_note
		_set_status("HOSTING // %d SURVIVOR(S)%s" % [n, extra])
	else:
		_set_status("CONNECTED // %d SURVIVORS" % n)

# ---- RPCs -------------------------------------------------------------------------------
@rpc("any_peer", "reliable")
func _hello(callsign: String, protocol: int, their_build: String) -> void:
	var id := multiplayer.get_remote_sender_id()
	if protocol != PROTOCOL:
		var theirs := their_build.left(24).to_upper()
		if hosting:
			multiplayer.multiplayer_peer.disconnect_peer(id)    # they get the message from their own side
		elif id == 1:
			leave()
			_set_status("VERSION MISMATCH // HOST: %s  YOU: %s // BOTH OF YOU: UPDATE IN THE LAUNCHER" % [theirs, build_tag])
		return
	names[id] = clean_name(callsign)
	if id == 1:
		_hello_wait = -1.0
	var r: Node = remotes.get(id)
	if r:
		r.set_label(label_for(id))

@rpc("authority", "call_remote", "reliable")
func _level(idx: int) -> void:
	if idx < 0 or idx >= 64:       # Game.level_count may not be loaded yet on a guest; change_level wraps it anyway
		return
	if idx != Game.level_index:
		Game.change_level(idx)

@rpc("any_peer", "call_remote", "unreliable_ordered")
func _state(t: float, pos: Vector3, yaw: float, pitch: float, spd: float, flags: int, level: int) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not _is_peer(id) or not _valid_state(t, pos, yaw, pitch, spd, level):
		return
	var r: Node = _ensure_remote(id)
	r.push_state(t, pos, yaw, pitch, spd, flags, level)

## Snapshot clock: simulated time of the physics step the position comes from. Wall time would be off
## by up to a frame (several physics steps run back to back in one frame), which shows as stutter.
static func _valid_state(t: float, pos: Vector3, yaw: float, pitch: float, spd: float, level: int) -> bool:
	if not (is_finite(t) and pos.is_finite() and is_finite(yaw) and is_finite(pitch) and is_finite(spd)):
		return false
	return absf(pos.x) < MAX_COORD and absf(pos.y) < MAX_COORD and absf(pos.z) < MAX_COORD \
		and spd >= 0.0 and spd < 1000.0 and level >= 0 and level < 64

## A peer that is actually connected right now (a late packet must not bring a player back after they left)
func _is_peer(id: int) -> bool:
	return id > 0 and multiplayer.get_peers().has(id)

## Callsigns are shown on 3D labels and in the lobby list: printable ASCII only, trimmed, capped
static func clean_name(raw: String) -> String:
	var out := ""
	for c in raw.strip_edges().to_upper():
		var u := c.unicode_at(0)
		if u >= 32 and u < 127 and c != "[" and c != "]":
			out += c
		if out.length() >= NAME_MAX:
			break
	return out.strip_edges()

## The launcher writes the release tag next to the exe; from the editor there is none
static func _read_build_tag() -> String:
	var path := OS.get_executable_path().get_base_dir().path_join("version.txt")
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "DEV"
	return f.get_as_text().strip_edges().left(24)

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

# ---- who the monsters can hunt ------------------------------------------------------------------
## Every survivor a monster may target right now: this player and each remote one that is alive and in
## the game (not dead, not sitting in a menu). {node, id, pos, fwd (flat, unit), local}
func survivors() -> Array:
	var out: Array = []
	var p: Node = Game.player
	if p != null and is_instance_valid(p) and not p.dead and Game.playing:
		var f: Vector3 = -p.global_transform.basis.z
		f.y = 0.0
		out.append({"node": p, "id": multiplayer.get_unique_id() if is_online() else 1, "pos": p.global_position,
			"fwd": f.normalized() if f.length() > 0.001 else Vector3.FORWARD, "local": true})
	for id in remotes:
		var r: Node3D = remotes[id]
		if is_instance_valid(r) and r.seen and r.visible and r.playing and not r.dead:
			out.append({"node": r, "id": id, "pos": r.target_pos, "fwd": Vector3(-sin(r.rotation.y), 0.0, -cos(r.rotation.y)),
				"local": false})
	return out

## The closest of them to `from`; the one it already hunts (prev_id) keeps a small edge so it doesn't flip-flop
func nearest_survivor(from: Vector3, prev_id := -1) -> Dictionary:
	var best := {}
	var best_key := INF
	for s in survivors():
		var key: float = from.distance_squared_to(s.pos) * (0.8 if s.id == prev_id else 1.0)
		if key < best_key:
			best_key = key
			best = s
	return best

func _to_host_ready() -> bool:
	return is_online() and not hosting

func _has_peers() -> bool:
	return hosting and is_online() and not multiplayer.get_peers().is_empty()

# ---- THE GRABBER: the host runs it; whoever it takes plays the drag on their own machine ----------
func send_grabber(m: Array) -> void:
	if _has_peers():
		_grabber_snap_rpc.rpc(clock(), m)

@rpc("authority", "call_remote", "unreliable_ordered")
func _grabber_snap_rpc(t: float, m: Array) -> void:
	var g := _scene_node("Grabber")
	if g != null and g.has_method("net_apply"):
		g.net_apply(t, m)

## Host: it has taken `peer_id`'s survivor
func send_grabber_grab(peer_id: int) -> void:
	if _has_peers() and _is_peer(peer_id):
		_grabber_grab_rpc.rpc_id(peer_id)

@rpc("authority", "call_remote", "reliable")
func _grabber_grab_rpc() -> void:
	var g := _scene_node("Grabber")
	if g != null and g.has_method("net_grabbed"):
		g.net_grabbed()

## Guest: how being dragged ended (tore loose, or taken)
func send_grabber_result(escaped: bool) -> void:
	if _to_host_ready():
		_grabber_result_rpc.rpc_id(1, escaped)

@rpc("any_peer", "call_remote", "reliable")
func _grabber_result_rpc(escaped: bool) -> void:
	if not hosting or not _is_peer(multiplayer.get_remote_sender_id()):
		return
	var g := _scene_node("Grabber")
	if g != null and g.has_method("net_drag_result"):
		g.net_drag_result(multiplayer.get_remote_sender_id(), escaped)

# ---- THE MANNEQUIN: the host rolls the room and runs the real one ---------------------------------
var mq_seed := 0
var mq_level := -1
var _mq_view := {}                # peer id -> [saw it, time]: guests tell the host whether they are looking at it

func send_mq_seed(seed_v: int) -> void:
	mq_seed = seed_v
	mq_level = Game.level_index
	if _has_peers():
		_mq_seed_rpc.rpc(mq_level, seed_v)

@rpc("authority", "call_remote", "reliable")
func _mq_seed_rpc(level_idx: int, seed_v: int) -> void:
	mq_seed = seed_v
	mq_level = level_idx
	var mq := _scene_node("Mannequin")
	if mq != null and level_idx == Game.level_index and mq.has_method("net_seed"):
		mq.net_seed(seed_v)

func send_mq(m: Array) -> void:
	if _has_peers():
		_mq_snap_rpc.rpc(clock(), m)

@rpc("authority", "call_remote", "unreliable_ordered")
func _mq_snap_rpc(t: float, m: Array) -> void:
	var mq := _scene_node("Mannequin")
	if mq != null and mq.has_method("net_apply"):
		mq.net_apply(t, m)

func send_mq_view(seen: bool) -> void:
	if _to_host_ready():
		_mq_view_rpc.rpc_id(1, seen)

@rpc("any_peer", "call_remote", "unreliable_ordered")
func _mq_view_rpc(seen: bool) -> void:
	if not hosting or not _is_peer(multiplayer.get_remote_sender_id()):
		return
	_mq_view[multiplayer.get_remote_sender_id()] = [seen, Time.get_ticks_msec() / 1000.0]

## Host: is any other survivor looking at it? (it only ever moves when nobody is)
func mq_seen_by_peers() -> bool:
	var now := Time.get_ticks_msec() / 1000.0
	for id in _mq_view:
		if _mq_view[id][0] and now - _mq_view[id][1] < 0.6 and remotes.has(id):
			return true
	return false

func send_mq_kill(id: int) -> void:
	if _has_peers():
		_mq_kill_rpc.rpc_id(id)

@rpc("authority", "call_remote", "reliable")
func _mq_kill_rpc() -> void:
	var mq := _scene_node("Mannequin")
	if mq != null and mq.has_method("net_snap"):
		mq.net_snap()

# ---- THE MIMIC: the host runs the body, each survivor gets the same one ---------------------------
func send_mm(m: Array) -> void:
	if _has_peers():
		_mm_rpc.rpc(clock(), m)

@rpc("authority", "call_remote", "unreliable_ordered")
func _mm_rpc(t: float, m: Array) -> void:
	var mm := _scene_node("Mimic")
	if mm != null and mm.has_method("net_apply"):
		mm.net_apply(t, m)

func send_mm_hit(id: int) -> void:
	if _has_peers():
		_mm_hit_rpc.rpc_id(id)

@rpc("authority", "call_remote", "reliable")
func _mm_hit_rpc() -> void:
	var mm := _scene_node("Mimic")
	if mm != null:
		mm.hit_player()

# ---- hazard tape: every strip anyone sticks up or peels off, everyone sees (tape_marks.gd) -----
## strips: TapeMarks.pack()ed, [[level, a, b, n, id, t, by], ...]
func send_tape(strips: Array) -> void:
	if is_online() and not multiplayer.get_peers().is_empty():
		_tape_rpc.rpc(strips)

func send_tape_removed(level: int, id: String) -> void:
	if is_online() and not multiplayer.get_peers().is_empty():
		_tape_removed_rpc.rpc(level, id)

@rpc("any_peer", "call_remote", "reliable")
func _tape_rpc(strips: Array) -> void:
	if not _is_peer(multiplayer.get_remote_sender_id()) or strips.size() > TAPE_BATCH_MAX:
		return
	for s in strips:
		if not (s is Array) or s.size() != 7 or typeof(s[0]) != TYPE_INT:
			continue
		var level: int = s[0]
		if level < 0 or level >= 1000000 or typeof(s[1]) != TYPE_VECTOR3 or typeof(s[2]) != TYPE_VECTOR3 or typeof(s[3]) != TYPE_VECTOR3 \
				or typeof(s[4]) != TYPE_STRING or typeof(s[5]) != TYPE_FLOAT or typeof(s[6]) != TYPE_STRING:
			continue
		var a: Vector3 = s[1]
		var b: Vector3 = s[2]
		var n: Vector3 = s[3]
		var id: String = s[4]
		if not (a.is_finite() and b.is_finite() and n.is_finite()) or absf(a.x) > MAX_COORD or absf(a.y) > MAX_COORD \
				or absf(a.z) > MAX_COORD or a.distance_to(b) > 25.0 or absf(n.length() - 1.0) > 0.01 \
				or id.length() == 0 or id.length() > 32:
			continue
		TapeMarks.receive(level, {"id": id, "a": a, "b": b, "n": n, "t": float(s[5]), "by": clean_name(str(s[6]))})

@rpc("any_peer", "call_remote", "reliable")
func _tape_removed_rpc(level: int, id: String) -> void:
	if not _is_peer(multiplayer.get_remote_sender_id()) or level < 0 or level >= 1000000 or id.length() > 32:
		return
	TapeMarks.receive_removed(level, id)

# ---- the camera flash (flash_tool.gd): everyone sees and hears it go off; the host's Bacteria,
# the one that runs its brain, is the one it can blind -------------------------------------------
func send_flash(origin: Vector3, look: Vector3) -> void:
	if is_online() and not multiplayer.get_peers().is_empty():
		_flash_rpc.rpc(origin, look)

@rpc("any_peer", "call_remote", "reliable")
func _flash_rpc(origin: Vector3, look: Vector3) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not _is_peer(id) or not origin.is_finite() or not look.is_finite() or absf(look.length() - 1.0) > 0.05:
		return
	var r: Node3D = remotes.get(id)
	if r == null or not is_instance_valid(r) or r.target_pos.distance_to(origin) > 4.0:
		return                            # it has to go off where that survivor actually is
	FlashTool.burst(origin)
	if hosting:
		FlashTool.hit(origin, look)

# ---- remote survivors ----------------------------------------------------------------------
func _ensure_remote(id: int) -> Node:
	if remotes.has(id) and is_instance_valid(remotes[id]):
		return remotes[id]
	var r: Node3D = load("res://scripts/Net/remote_player.gd").new()
	r.color = PEER_COLORS[id % PEER_COLORS.size()]
	r.peer_id = id
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
	_set_share_link(url)
	_update_count()

func _stop_tunnel() -> void:
	_quit = true
	if _cf_pid > 0:
		OS.kill(_cf_pid)         # closes the pipe, which unblocks the reader thread
		_cf_pid = -1
	if _cf_thread and _cf_thread.is_started():
		_cf_thread.wait_to_finish()
	_cf_thread = null

func _set_share_link(text: String) -> void:
	share_link = text
	share_link_changed.emit(text)

func _set_status(text: String) -> void:
	status = text
	status_changed.emit(text)

# Snapshots are sent from the physics step, on a fixed grid
func _physics_process(dt: float) -> void:
	if not is_online():
		return
	_send_state(dt)
