extends Node
## Co-op over WebSocket (autoload: Net). One PC hosts a local WebSocket server; a `cloudflared tunnel` exposes it
## publicly and the game shows only a short ROOM CODE: the host posts "code -> tunnel link" to a tiny public
## relay (ROOM_SERVICE), friends type the code into JOIN and the game looks the link up. The link is never shown. Tunnels only carry
## HTTP/WebSocket (no UDP), which is why this is WebSocketMultiplayerPeer and not ENet.
## Every survivor sends a timestamped snapshot (position, look, speed, torch...) 20 times a second;
## the others draw it with snapshot interpolation (snap_buffer.gd). The host runs THE BACTERIA and the
## event director for everyone and sets which level everyone is on.

signal status_changed(text: String)
signal share_link_changed(text: String)
## A survivor came into the game (their callsign is known now) / dropped out of it. `already`: they were
## there before we arrived (we just joined), not arriving now. hud.gd shows each as a terminal toast.
signal survivor_joined(id: int, callsign: String, already: bool)
signal survivor_left(id: int, callsign: String)
## A survivor's vitals flatlined, and what did it ("UNDETERMINED" from a build that doesn't report it)
signal survivor_died(id: int, callsign: String, cause: String)
## Signal strength between survivors (signal_of): full this close, gone this far (or on another floor)
const SIGNAL_FULL := 14.0
const SIGNAL_LOST := 42.0

const DEFAULT_PORT := 8910
const SEND_INTERVAL := 1.0 / 20.0
const HELLO_TIMEOUT := 6.0       # no hello from the host by then: we are on different game versions
const NAME_MAX := 16
const MAX_PLAYERS := 8
## Bump whenever an RPC signature or snapshot layout changes: peers with a different number are refused
## with a clear message instead of silently desyncing. (A changed _hello signature itself still falls
## back to the HELLO_TIMEOUT check, since Godot drops RPCs whose arguments don't match.)
const PROTOCOL := 7
const TapeMarks := preload("res://scripts/World/props/tape_marks.gd")
const FlashTool := preload("res://scripts/Player/flash_tool.gd")
const TAPE_BATCH_MAX := 1000     # strips one _tape_rpc may carry
const TAPE_CHUNK := 150          # a newcomer gets the tape already up in chunks this size (one huge message stalls the socket)
## WebSocket buffers. Godot's default is 64 KB each way: one big reliable message (a newcomer's tape) or a
## hitch with voice + snapshots queued behind it overflowed that, and the peer dropped the data or the link.
const WS_BUFFER := 4 * 1024 * 1024
const WS_MAX_QUEUED := 8192
## Host monsters: snapshots that didn't change since the last one aren't sent again (a Mimic that is away,
## a Grabber that is off, a still Mannequin), only this often so a guest that just joined still gets them
const KEEPALIVE := 0.5
const MQ_VIEW_KEEPALIVE := 0.25  # a guest repeats "I'm (not) looking at the mannequin" this often (the host forgets after 0.6 s)
enum Ent { BACTERIA, GRABBER, MANNEQUIN, MIMIC, BURNT }
const ENT_NODES := ["Entity", "Grabber", "Mannequin", "Mimic", "Burnt"]
const MAX_COORD := 100000.0      # snapshots further out than this are garbage, not a position
const TUNNEL_DOMAIN := "trycloudflare.com"
const ROOM_SERVICE := "https://ntfy.sh/"      # free public relay that stores "code -> link" for a while; swap for your own Worker any time
const ROOM_PREFIX := "backrooms-coop-1-"      # topic namespace on it
const CODE_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"   # no I/O/0/1
const CODE_LEN := 6                                          # 32^6 ~ 1e9 codes
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
var share_link := ""            # the room code the host sends to friends (a LAN address with --host-local)
var debug := false               # --net-debug: print what the entity is doing on this machine
var _dbg_t := 0.0
var launch_name := ""           # --player-name= from the launcher
var names := {}                 # peer id -> callsign ("" until they send one)
var build_tag := ""             # release tag from the launcher's version.txt ("DEV" when run from the editor)
var remotes := {}               # peer id -> RemotePlayer

var _send_t := 0.0
var _sim_t := 0.0               # clock(): physics time this machine has simulated (see clock())
var _out := {}                  # Ent -> [t, bytes]: monster snapshots waiting for this frame's _flush_world
var _sent := {}                 # Ent -> [t, bytes, sent_at]: the last one that went out
var _held := {}                 # Ent -> [t, bytes]: the newest one NOT sent because nothing had changed
var _flush_queued := false
var _mq_view_last := -1         # what we last told the host (-1 never), and when
var _mq_view_at := 0.0
var _survivors_cache: Array = []
var _survivors_frame := -1
var _cf_pid := -1
var _cf_thread: Thread
var _quit := false
var phantoms := {}               # id -> {name, dist, drift}: survivors on the roster who aren't anyone (the ghostRoster event)
var _deaths := {}                # peer id -> {at, said}: a death seen on their snapshot, and whether it was announced
var _online_since := -INF        # when this guest connected (survivors already there are "on site", not "joined")
var _room_token := 0            # bumped on host()/leave(): a slow lookup/publish from an old lobby is ignored

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	Game.player_died.connect(_on_local_death)
	build_tag = _read_build_tag()
	# The launcher passes --join=<host or tunnel link> and --player-name=<name>
	var join_to := ""
	var host_mode := ""
	for a in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if a.begins_with("--join="):
			join_to = a.substr(7)
		elif a.begins_with("--player-name="):
			launch_name = clean_name(a.substr(14))
		elif a == "--host" or a == "--host-local":       # open the lobby straight away (-local: no tunnel, LAN address only)
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

## Opens the lobby. The online tunnel starts in the background and the room code shows up once it is ready;
## local_only skips it (same-network testing: friends type this PC's address instead).
func host(local_only := false) -> void:
	leave()
	var peer := _new_peer()
	if peer.create_server(PORT) != OK:
		_set_status("COULD NOT OPEN PORT %d (ALREADY HOSTING?)" % PORT)
		return
	multiplayer.multiplayer_peer = peer
	hosting = true
	if local_only:
		_set_share_link(_lan_address())
		_set_status("LOCAL LOBBY OPEN ON PORT %d" % PORT)
		return
	_set_status("LOBBY OPEN // CREATING ROOM CODE...")
	_start_tunnel()

## A short room code, or an address typed in directly (127.0.0.1, 192.168.x.x:port) for testing on one network
func join(address: String) -> void:
	var code := normalize_code(address)
	var url := "" if code != "" else normalize_url(address)
	if code == "" and url == "":
		_set_status("ENTER THE HOST'S ROOM CODE")
		return
	leave()
	if code != "":
		_set_status("LOOKING UP ROOM %s ..." % code)
		_lookup_room(code, _room_token)
	else:
		_connect_url(url)

func _connect_url(url: String) -> void:
	var peer := _new_peer()
	if peer.create_client(url) != OK:
		_set_status("BAD ROOM CODE")
		return
	multiplayer.multiplayer_peer = peer
	_set_status("CONNECTING ...")

func _new_peer() -> WebSocketMultiplayerPeer:
	var peer := WebSocketMultiplayerPeer.new()
	peer.inbound_buffer_size = WS_BUFFER
	peer.outbound_buffer_size = WS_BUFFER
	peer.max_queued_packets = WS_MAX_QUEUED
	return peer

func leave() -> void:
	_room_token += 1
	_stop_tunnel()
	var p := multiplayer.multiplayer_peer
	if p != null and not (p is OfflineMultiplayerPeer):
		p.close()
	multiplayer.multiplayer_peer = null
	hosting = false
	_clear_remotes()
	_out.clear()
	_sent.clear()
	_held.clear()
	_mq_view.clear()
	_mq_view_last = -1
	_set_share_link("")
	_set_status("OFFLINE")

## Leave with a message, from inside a network callback (a signal the peer emits while it is being polled,
## or an RPC being dispatched): pulling the peer out from under SceneMultiplayer mid-poll can crash, so it
## waits for the end of the frame
func _drop(msg: String) -> void:
	leave()
	_set_status(msg)

func _kick(id: int) -> void:
	if hosting and is_online() and multiplayer.get_peers().has(id):
		multiplayer.multiplayer_peer.disconnect_peer(id)

# ---- room codes: a short random code, mapped to the tunnel link by the relay ----------------------------
static func new_code() -> String:
	var out := ""
	for i in CODE_LEN:
		out += CODE_ALPHABET[randi() % CODE_ALPHABET.length()]
	return out

## "k7q-m2x", "K7QM2X" -> "K7QM2X"; "" if it is not a room code (so 127.0.0.1 etc. fall through to normalize_url)
static func normalize_code(raw: String) -> String:
	var c := raw.strip_edges().to_upper().replace("-", "").replace(" ", "")
	if c.length() != CODE_LEN:
		return ""
	for ch in c:
		if CODE_ALPHABET.find(ch) < 0:
			return ""
	return c

## Only ever connect to a tunnel link: a relay entry must not be able to send players anywhere else
static func is_tunnel_url(url: String) -> bool:
	var re := RegEx.create_from_string("^https://[a-z0-9-]+\\." + TUNNEL_DOMAIN.replace(".", "\\.") + "/?$")
	return re.search(url.strip_edges()) != null

static func _room_url(code: String) -> String:
	return ROOM_SERVICE + ROOM_PREFIX + code

## Host: tunnel is up -> pick a code and post it with the link
func _publish_room(url: String) -> void:
	var code := new_code()
	var http := HTTPRequest.new()
	http.timeout = 8.0
	add_child(http)
	http.request_completed.connect(_room_published.bind(http, code, _room_token))
	if http.request(_room_url(code), ["Content-Type: text/plain"], HTTPClient.METHOD_POST, url) != OK:
		http.queue_free()
		_set_status("LOBBY OPEN // COULD NOT CREATE A ROOM CODE")

func _room_published(result: int, response: int, _h: PackedStringArray, _b: PackedByteArray, http: HTTPRequest, code: String, token: int) -> void:
	http.queue_free()
	if token != _room_token or not hosting:
		return
	if result != HTTPRequest.RESULT_SUCCESS or response != 200:
		_set_status("LOBBY OPEN // COULD NOT CREATE A ROOM CODE (NO INTERNET?)")
		return
	_set_share_link(code.left(3) + "-" + code.substr(3))
	_update_count()

## Guest: code -> link -> connect
func _lookup_room(code: String, token: int) -> void:
	var http := HTTPRequest.new()
	http.timeout = 8.0
	add_child(http)
	http.request_completed.connect(_room_found.bind(http, token))
	if http.request(_room_url(code) + "/json?poll=1&since=all") != OK:
		http.queue_free()
		_set_status("COULD NOT REACH THE ROOM SERVICE")

func _room_found(result: int, response: int, _h: PackedStringArray, body: PackedByteArray, http: HTTPRequest, token: int) -> void:
	http.queue_free()
	if token != _room_token:
		return
	if result != HTTPRequest.RESULT_SUCCESS or response != 200:
		_set_status("COULD NOT REACH THE ROOM SERVICE // CHECK YOUR INTERNET")
		return
	var link := ""
	for line in body.get_string_from_utf8().split("\n", false):     # one JSON event per line; the newest message wins
		var ev = JSON.parse_string(line)
		if ev is Dictionary and ev.get("event", "") == "message":
			link = str(ev.get("message", "")).strip_edges()
	if not is_tunnel_url(link):
		_set_status("ROOM NOT FOUND // CHECK THE CODE (THE HOST MAY HAVE CLOSED IT)")
		return
	_connect_url(link.replace("https://", "wss://").trim_suffix("/"))

func _lan_address() -> String:
	for ip in IP.get_local_addresses():
		if ip.count(".") == 3 and (ip.begins_with("192.168.") or ip.begins_with("10.") or ip.begins_with("172.")):
			return ip
	return ""

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
		_kick.call_deferred(id)
		return
	names[id] = ""
	_hello.rpc_id(id, my_name(), PROTOCOL, build_tag)
	if hosting:
		_level.rpc_id(id, Game.level_index)
		if mq_level >= 0:
			_mq_seed_rpc.rpc_id(id, mq_level, mq_seed)      # the same mannequin room for the newcomer
		_sent.clear()                                        # every monster goes out in full next frame, for the newcomer
	var tape := TapeMarks.pack_mine()
	if not tape.is_empty():
		tape = tape.slice(-TAPE_BATCH_MAX)                  # the tape we already stuck up, for the newcomer
		for i in range(0, tape.size(), TAPE_CHUNK):
			_tape_rpc.rpc_id(id, tape.slice(i, i + TAPE_CHUNK))
	_ensure_remote(id)
	_update_count()

func _on_peer_disconnected(id: int) -> void:
	if str(names.get(id, "")) != "":                 # (never said hello: a refused version, not a survivor)
		survivor_left.emit(id, label_for(id))
	var r: Node = remotes.get(id)
	if r:
		r.queue_free()
	remotes.erase(id)
	names.erase(id)
	_deaths.erase(id)
	_mq_view.erase(id)
	_survivors_frame = -1
	_update_count()

func _on_connected() -> void:
	_online_since = Time.get_ticks_msec() / 1000.0
	_hello_wait = HELLO_TIMEOUT
	_set_status("CONNECTED // %d SURVIVOR(S)" % (multiplayer.get_peers().size() + 1))

func _on_connection_failed() -> void:
	_drop.call_deferred("COULD NOT CONNECT // CHECK THE CODE AND THAT THE HOST IS STILL IN THE LOBBY")

func _on_server_disconnected() -> void:
	_drop.call_deferred("SIGNAL LOST // HOST CLOSED THE LOBBY")

func _update_count() -> void:
	if not is_online():
		return
	var n := multiplayer.get_peers().size() + 1
	if hosting:
		var extra := ("  //  " + share_link) if share_link != "" else ""
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
			_kick.call_deferred(id)                         # they get the message from their own side
		elif id == 1:
			_drop.call_deferred("VERSION MISMATCH // HOST: %s  YOU: %s // BOTH OF YOU: UPDATE IN THE LAUNCHER" % [theirs, build_tag])
		return
	var first := str(names.get(id, "")) == ""
	names[id] = clean_name(callsign)
	if first:
		survivor_joined.emit(id, label_for(id), not hosting and Time.get_ticks_msec() / 1000.0 - _online_since < 5.0)
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

## A survivor's snapshot, 36 bytes: t (f64), feet x y z, yaw, pitch, ground speed (f32), flags (u8),
## level (u8), floor (s16). Floors matter: two survivors on different floors of one level share x/z.
const STATE_SIZE := 36

static func pack_state(t: float, pos: Vector3, yaw: float, pitch: float, spd: float, flags: int, level: int, floor_i: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(STATE_SIZE)
	b.encode_double(0, t)
	b.encode_float(8, pos.x)
	b.encode_float(12, pos.y)
	b.encode_float(16, pos.z)
	b.encode_float(20, yaw)
	b.encode_float(24, pitch)
	b.encode_float(28, spd)
	b.encode_u8(32, flags & 0xFF)
	b.encode_u8(33, clampi(level, 0, 255))
	b.encode_s16(34, clampi(floor_i, -32768, 32767))
	return b

@rpc("any_peer", "call_remote", "unreliable_ordered")
func _state(b: PackedByteArray) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not _is_peer(id) or b.size() != STATE_SIZE:
		return
	var t := b.decode_double(0)
	var pos := Vector3(b.decode_float(8), b.decode_float(12), b.decode_float(16))
	var yaw := b.decode_float(20)
	var pitch := b.decode_float(24)
	var spd := b.decode_float(28)
	var level := b.decode_u8(33)
	if not _valid_state(t, pos, yaw, pitch, spd, level):
		return
	var r: Node = _ensure_remote(id)
	r.push_state(t, pos, yaw, pitch, spd, b.decode_u8(32), level, b.decode_s16(34))

## Snapshot clock: simulated time of the physics step the position comes from. Wall time would be off
## by up to a frame (several physics steps run back to back in one frame), which shows as stutter.
static func _valid_state(t: float, pos: Vector3, yaw: float, pitch: float, spd: float, level: int) -> bool:
	if not (is_finite(t) and pos.is_finite() and is_finite(yaw) and is_finite(pitch) and is_finite(spd)):
		return false
	return absf(pos.x) < MAX_COORD and absf(pos.y) < MAX_COORD and absf(pos.z) < MAX_COORD \
		and spd >= 0.0 and spd < 1000.0 and level >= 0 and level < 64

## A peer that is actually connected right now (a late packet must not bring a player back after they left).
## `names` holds exactly the connected peers (peer_connected / peer_disconnected) and, unlike
## multiplayer.get_peers(), doesn't build a fresh array for every packet.
func _is_peer(id: int) -> bool:
	return id > 0 and names.has(id)

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

## Snapshot clock: the physics time this machine has simulated, summed step by step. (Physics frames
## divided by the tick rate jumped whenever the tick rate changed: a graphics setting, the display's
## refresh rate, Gfx easing the rate off on a struggling PC. Every jump read as a hitch on the far side.)
func clock() -> float:
	return _sim_t

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

## Host: the monsters' snapshots (bacteria_net.gd, grabber_net.gd, mannequin.gd, mimic.gd each hand one
## over 20 times a second). They used to go out as four messages of Variant arrays (a float 12 bytes, a
## bool 8); now whatever was handed over this frame goes out once at the end of it, as one message of
## packed bytes, and a snapshot identical to the last one sent is held back (KEEPALIVE).
func send_entity(m: Array) -> void:
	_queue_ent(Ent.BACTERIA, m)

func _queue_ent(kind: int, m: Array) -> void:
	if not _has_peers():
		return
	_out[kind] = [clock(), pack_values(m)]
	if not _flush_queued:
		_flush_queued = true
		_flush_world.call_deferred()

func _flush_world() -> void:
	_flush_queued = false
	if _out.is_empty() or not _has_peers():
		_out.clear()
		return
	var now := Time.get_ticks_msec() / 1000.0
	var w := StreamPeerBuffer.new()
	var n := 0
	w.put_u8(0)                                   # entry count, filled in below
	for kind: int in _out:
		var t: float = _out[kind][0]
		var bytes: PackedByteArray = _out[kind][1]
		var last: Array = _sent.get(kind, [])
		if not last.is_empty() and last[1] == bytes and now - float(last[2]) < KEEPALIVE:
			_held[kind] = [t, bytes]                  # nothing new: hold it back
			continue
		# it starts moving again: the snapshot from just before goes first, so a guest draws it standing
		# still until then instead of gliding there from the last one it got (up to KEEPALIVE ago)
		var held: Array = _held.get(kind, [])
		if not held.is_empty() and held[1] != bytes and held[0] > (last[0] if not last.is_empty() else -INF):
			_put_entry(w, kind, held[0], held[1])
			n += 1
		_held.erase(kind)
		_put_entry(w, kind, t, bytes)
		n += 1
		_sent[kind] = [t, bytes, now]
	_out.clear()
	if n == 0:
		return
	var b := w.data_array
	b[0] = n
	_world.rpc(b)

static func _put_entry(w: StreamPeerBuffer, kind: int, t: float, bytes: PackedByteArray) -> void:
	w.put_u8(kind)
	w.put_double(t)
	w.put_u16(bytes.size())
	w.put_data(bytes)

@rpc("authority", "call_remote", "unreliable_ordered")
func _world(b: PackedByteArray) -> void:
	var r := StreamPeerBuffer.new()
	r.data_array = b
	if r.get_available_bytes() < 1:
		return
	var n := r.get_u8()
	for i in n:
		if r.get_available_bytes() < 11:
			return
		var kind := r.get_u8()
		var t := r.get_double()
		var size := r.get_u16()
		if r.get_available_bytes() < size or kind >= ENT_NODES.size() or not is_finite(t):
			return
		var got: Array = r.get_data(size)
		var m = unpack_values(got[1])
		if m == null:
			continue
		var node := _scene_node(ENT_NODES[kind])
		if node != null and node.has_method("net_apply"):
			node.net_apply(t, m)

## Snapshot values as bytes: a tag, then the value. Floats travel as 32-bit (plenty for positions, angles
## and clip times), ints as 32-bit (peer ids fit), bools as the tag alone, arrays (one level: the
## mannequin's pose) as a count and their values.
enum Tag { F32, I32, FALSE, TRUE, ARR }

static func pack_values(m: Array) -> PackedByteArray:
	var w := StreamPeerBuffer.new()
	_pack_into(w, m)
	return w.data_array

static func _pack_into(w: StreamPeerBuffer, m: Array) -> void:
	w.put_u8(mini(m.size(), 255))
	for i in mini(m.size(), 255):
		var v = m[i]
		match typeof(v):
			TYPE_BOOL:
				w.put_u8(Tag.TRUE if v else Tag.FALSE)
			TYPE_INT:
				w.put_u8(Tag.I32)
				w.put_32(clampi(v, -2147483648, 2147483647))
			TYPE_ARRAY:
				w.put_u8(Tag.ARR)
				_pack_into(w, v)
			_:
				w.put_u8(Tag.F32)
				w.put_float(float(v) if (typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT) else 0.0)

## null if the bytes are malformed (never trust the wire)
static func unpack_values(b: PackedByteArray) -> Variant:
	var r := StreamPeerBuffer.new()
	r.data_array = b
	return _unpack_from(r, 0)

static func _unpack_from(r: StreamPeerBuffer, depth: int) -> Variant:
	if depth > 2 or r.get_available_bytes() < 1:
		return null
	var n := r.get_u8()
	var out: Array = []
	out.resize(n)
	for i in n:
		if r.get_available_bytes() < 1:
			return null
		match r.get_u8():
			Tag.F32:
				if r.get_available_bytes() < 4:
					return null
				var f := r.get_float()
				out[i] = f if is_finite(f) else 0.0
			Tag.I32:
				if r.get_available_bytes() < 4:
					return null
				out[i] = r.get_32()
			Tag.FALSE:
				out[i] = false
			Tag.TRUE:
				out[i] = true
			Tag.ARR:
				var sub = _unpack_from(r, depth + 1)
				if sub == null:
					return null
				out[i] = sub
			_:
				return null
	return out

## Host: an event just started (or was stopped): everyone gets the same scare at the same moment
func send_event(event_name: String) -> void:
	if hosting and is_online() and not multiplayer.get_peers().is_empty():
		_event.rpc(event_name)

func send_stop_events() -> void:
	if hosting and is_online() and not multiplayer.get_peers().is_empty():
		_stop_events.rpc()

@rpc("authority", "call_remote", "reliable")
func _event(event_name: String) -> void:
	if event_name == "machineVoice":
		return                            # the host picks the voice and line: it arrives through _voice
	var ev := _scene_node("Events")
	if ev != null:
		ev.run_event(event_name)

## Host: the machine voice said this line in this voice, so everyone hears the same one
func send_voice(voice: String, idx: int) -> void:
	if hosting and is_online() and not multiplayer.get_peers().is_empty():
		_voice.rpc(voice, idx)

@rpc("authority", "call_remote", "reliable")
func _voice(voice: String, idx: int) -> void:
	var ev := _scene_node("Events")
	if ev != null and voice.length() <= 16:
		ev.play_machine_voice(voice, idx, false)

@rpc("authority", "call_remote", "reliable")
func _stop_events() -> void:
	var ev := _scene_node("Events")
	if ev != null:
		ev.stop_all()

# ---- who the monsters can hunt ------------------------------------------------------------------
## Every survivor a monster may target right now: this player and each remote one that is alive and in
## the game (not dead, not sitting in a menu). {node, id, pos, fwd (flat, unit), local}
## Built once per frame and shared (every monster asks several times a frame): treat it as read-only.
func survivors() -> Array:
	var frame := Engine.get_process_frames() * 64 + Engine.get_physics_frames() % 64
	if frame == _survivors_frame:
		return _survivors_cache
	_survivors_frame = frame
	_survivors_cache = _build_survivors()
	return _survivors_cache

func _build_survivors() -> Array:
	var out: Array = []
	var p: Node = Game.player
	if p != null and is_instance_valid(p) and not p.dead and Game.playing and not Game.invisible:
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
	_queue_ent(Ent.GRABBER, m)

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

# ---- THE BURNT: the host runs it; whoever it takes plays the sequence on their own machine --------
func send_burnt(m: Array) -> void:
	_queue_ent(Ent.BURNT, m)

## Host: it has taken `peer_id`'s survivor
func send_burnt_take(peer_id: int) -> void:
	if _has_peers() and _is_peer(peer_id):
		_burnt_take_rpc.rpc_id(peer_id)

@rpc("authority", "call_remote", "reliable")
func _burnt_take_rpc() -> void:
	var b := _scene_node("Burnt")
	if b != null and b.has_method("net_taken"):
		b.net_taken()

## Guest: the sequence is over (they died, or something else ended it)
func send_burnt_result() -> void:
	if _to_host_ready():
		_burnt_result_rpc.rpc_id(1)

@rpc("any_peer", "call_remote", "reliable")
func _burnt_result_rpc() -> void:
	if not hosting or not _is_peer(multiplayer.get_remote_sender_id()):
		return
	var b := _scene_node("Burnt")
	if b != null and b.has_method("net_result"):
		b.net_result(multiplayer.get_remote_sender_id())

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
	_queue_ent(Ent.MANNEQUIN, m)

## Guest: only when it changes, and every MQ_VIEW_KEEPALIVE while it holds (it was 10 messages a second)
func send_mq_view(seen: bool) -> void:
	if not _to_host_ready():
		return
	var now := Time.get_ticks_msec() / 1000.0
	if int(seen) == _mq_view_last and now - _mq_view_at < MQ_VIEW_KEEPALIVE:
		return
	_mq_view_last = int(seen)
	_mq_view_at = now
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
	_queue_ent(Ent.MIMIC, m)

func send_mm_hit(id: int) -> void:
	if _has_peers() and _is_peer(id):
		_mm_hit_rpc.rpc_id(id)

@rpc("authority", "call_remote", "reliable")
func _mm_hit_rpc() -> void:
	var mm := _scene_node("Mimic")
	if mm != null and mm.has_method("hit_player"):
		mm.hit_player()

## Is the host on this level and floor? (its monsters live on its floor: on another one they would walk
## through our walls, so the puppets hide). True for the host itself and before its first snapshot.
func host_here() -> bool:
	if not is_online() or hosting:
		return true
	var h: Node = remotes.get(1)
	return h == null or not is_instance_valid(h) or not h.seen or h.here

# ---- event triggers a guest walks into (event_trigger.gd): what the host runs, the host runs ------------
## Guest: a trigger fired a monster or a director event. The host does it, for everyone (a guest's own copy
## of those is a puppet, or has no say), near the guest who walked in.
func send_trigger(ev: String, at: Vector3) -> void:
	if _to_host_ready() and ev.length() <= 64 and at.is_finite():
		_trigger_rpc.rpc_id(1, ev, at)

@rpc("any_peer", "call_remote", "reliable")
func _trigger_rpc(ev: String, at: Vector3) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not hosting or not _is_peer(id) or ev.length() > 64 or not at.is_finite():
		return
	var r: Node3D = remotes.get(id)
	if r == null or not is_instance_valid(r) or not r.here or r.target_pos.distance_to(at) > 30.0:
		return                            # it has to be where that survivor actually is, on our floor
	var root := Game.main if Game.main != null and is_instance_valid(Game.main) else null
	if root == null:
		return
	match ev:
		"spawn_mimic":
			var mm := root.get_node_or_null("Mimic")
			if mm != null and mm.has_method("appear"):
				mm.appear(r.target_pos)
		"spawn_bacteria":
			var ent := root.get_node_or_null("Entity")
			if ent != null and ent.has_method("spawn_stalk"):
				ent.spawn_stalk(true)
		_:
			var evs := root.get_node_or_null("Events")
			if evs != null and evs.has_method("run_event"):
				evs.run_event(ev, false)       # (a zone's event is for the walker only: guests run theirs locally)

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
	_survivors_frame = -1

func _process(dt: float) -> void:
	if not is_online():
		return
	if _hello_wait > 0.0:
		_hello_wait -= dt
		if _hello_wait <= 0.0:
			_drop("THE HOST RUNS A DIFFERENT VERSION // BOTH OF YOU: UPDATE IN THE LAUNCHER")
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
	var flags := (1 if p.get("is_crouching") else 0) | (2 if p.get("flash_on") else 0) | (4 if p.get("dead") else 0) | (8 if Game.playing else 0) | (16 if Game.invisible else 0)
	_state.rpc(pack_state(clock(), p.global_position, p.rotation.y, cam.rotation.x if cam else 0.0,
		Vector2(v.x, v.z).length(), flags, Game.level_index, Game.level_floor))

# ---- cloudflared ------------------------------------------------------------------------------
func _start_tunnel() -> void:
	var exe := "cloudflared"
	var bundled := OS.get_executable_path().get_base_dir().path_join("cloudflared.exe")    # shipped next to the game
	for path in [bundled] + CLOUDFLARED_PATHS:
		if FileAccess.file_exists(path):
			exe = path
			break
	var info := OS.execute_with_pipe(exe, ["tunnel", "--url", "http://localhost:%d" % PORT])
	if info.is_empty():
		_set_status("LOBBY OPEN // ONLINE SERVICE MISSING (cloudflared.exe NEXT TO THE GAME) // NO ROOM CODE")
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
	if not is_tunnel_url(url):
		_set_status("LOBBY OPEN // COULD NOT CREATE A ROOM CODE")
		return
	_publish_room(url)

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
	_sim_t += dt                       # first thing each step (an autoload steps before the scene): the whole step reads one clock
	if not is_online():
		return
	_send_state(dt)
	_watch_deaths()

# ---- the expedition: signal and deaths ------------------------------------------------------------
## 0..1, how clear another survivor's signal is from here: full within SIGNAL_FULL m, gone by SIGNAL_LOST,
## and gone on another level or floor. Their voice (voice_speaker.gd), name tag (remote_player.gd) and the
## [F6] CREW page break up with it.
func signal_of(id: int) -> float:
	var r: Node3D = remotes.get(id)
	var p: Node = Game.player
	if r == null or not is_instance_valid(r) or not r.seen or not r.here or p == null or not is_instance_valid(p):
		return 0.0
	return 1.0 - smoothstep(SIGNAL_FULL, SIGNAL_LOST, r.global_position.distance_to((p as Node3D).global_position))

static func clean_cause(raw: String) -> String:
	var out := ""
	for c in raw.strip_edges().to_upper():
		var u := c.unicode_at(0)
		if u >= 32 and u < 127 and c != "[" and c != "]":
			out += c
	out = out.left(32)
	return out if out != "" else "UNDETERMINED"

## This machine's player died: everyone else is told what did it
func _on_local_death(reason: String) -> void:
	if is_online():
		report_death.rpc(clean_cause(reason))

## A survivor's snapshot says dead but no cause came (a build without report_death): announce it anyway.
## Someone already dead when we joined is not news.
func _watch_deaths() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	for id in remotes:
		var r: Node3D = remotes[id]
		if not is_instance_valid(r) or not r.seen:
			continue
		var d: Dictionary = _deaths.get(id, {})
		if r.dead:
			if d.is_empty():
				_deaths[id] = {"at": now, "said": not hosting and now - _online_since < 5.0}
			elif not d.said and now - float(d.at) > 1.5:
				d.said = true
				survivor_died.emit(id, label_for(id), "UNDETERMINED")
		elif not d.is_empty() and now - float(d.at) > 4.0:
			_deaths.erase(id)                  # back on their feet

## Named and placed so it is the LAST RPC of this node (every other one starts with "_"): an older build
## keeps the same numbering for all the rest, and only drops this one.
@rpc("any_peer", "call_remote", "reliable")
func report_death(cause: String) -> void:
	var id := multiplayer.get_remote_sender_id()
	if not _is_peer(id):
		return
	var d: Dictionary = _deaths.get(id, {})
	if not d.is_empty() and d.said:
		return
	_deaths[id] = {"at": Time.get_ticks_msec() / 1000.0, "said": true}
	survivor_died.emit(id, label_for(id), clean_cause(cause))
