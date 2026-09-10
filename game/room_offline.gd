class_name RoomOffline
extends Node

## A server and a client in one tree, with a loopback between them.
##
## What `--offline` is, and what `examples/headless_net.tscn` drives. There is no socket,
## no [DotServer] and no signon: two [RoomBridge]s, two [DotNetManager]s and two
## [RoomWorld]s, with each end's [member RoomLink.loopback] pointed at the other's
## [method RoomLink.deliver].
##
## [b]Every byte still goes through the real encoders.[/b] The loopback replaces the
## socket and nothing else — the same snapshots, the same events, the same acknowledgement
## header, the same prediction and the same reconciliation. What it buys is a run that
## reproduces exactly, twice, which a real socket cannot: latency, reordering and loss are
## different every time, and a netcode check that cannot be repeated is a netcode check
## that cannot be trusted when it fails.
##
## It also, deliberately, buys a way to look at the room with nobody else in it. A scene
## that can only be run by connecting to something is a scene nobody ever runs.

const CHANNEL := "room.offline"

## Peer id the local client is given. Anything but 1, which is the server's.
const CLIENT_PEER := 2

## Session id the local person gets. Well clear of anything a real server hands out,
## which counts up from 1 — so a transcript from an offline run is never mistaken for one
## from a real session.
const CLIENT_OCCUPANT := 500001

var server_world: RoomWorld = null
var server_net: DotNetManager = null
var server_bridge: RoomBridge = null

## The real chat router, the real moderation manager and the real voice router, on the
## authority half.
##
## [b]Not a stub, and that is the point.[/b] `--offline` used to restate the shape of a
## chat payload in [method say] because there was nothing to route it; now the same
## [DotChatRouter] runs, with the same rules, the same channels and the same backlog, and
## the only thing missing is a [DotServer] to look names up in. A path only one deployment
## shape reaches is a path nothing has run, and offline is the shape a person looking at
## this game actually runs.
var services: RoomServices = null

## What has been put in the room, on the authority half.
var server_props: RoomProps = null

## The mirroring copy, on the client half. Two [RoomProps], exactly as there are two
## worlds and two bridges — because the point of this file is that both ends are real.
var client_props: RoomProps = null

var client_world: RoomWorld = null
var client_net: DotNetManager = null
var client_bridge: RoomBridge = null

## Ticks each direction is delayed, for a run that wants to see prediction work.
##
## [b]Ticks, not milliseconds.[/b] A wall-clock delay measured against a loop that
## advances a tick per *frame* is not a delay at all: a headless run does several hundred
## frames a second, so a "60 ms" latency swallows every packet for the first fifty ticks
## and the client predicts into a void. The first version of this file did that, and the
## symptom was 240 units of drift under packet loss — which reads as a broken predictor
## and is a broken clock. Ticks are also what makes the loopback reproducible, which is
## its entire reason for existing.
##
## Zero by default: an offline lobby should feel like a local game, and a person looking
## at the room to check it draws correctly does not want a simulated round trip.
var latency_ticks: int = 0

## Fraction of snapshots dropped, for the same reason. Zero by default.
##
## Only snapshots: dropping a reliable event would be dropping something the transport
## promises to redeliver and this loopback does not implement retransmission. A test that
## wants to see a lost join is testing dot-net's reliability layer, not this.
var loss: float = 0.0

var _server_link_host: Node = null
var _client_link_host: Node = null
var _pending: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()

## The newest tick [method server_tick] was given. What a delay is measured in.
var _tick: int = 0


## Builds both ends and puts one person in the room.
func start(display_name: String, seed_value: int = 20260829) -> DotResult:
	_rng.seed = seed_value

	# The link's parent is what the RPC path is made of on a real connection — [DotServer]
	# on one side, [DotClientLink] on the other, both named `Server`. Here nothing is
	# routed by path, and the names are kept anyway: a loopback whose tree differed from
	# the real one would be a loopback that could not reproduce a routing bug.
	_server_link_host = Node.new()
	_server_link_host.name = "Server"
	add_child(_server_link_host)

	_client_link_host = Node.new()
	_client_link_host.name = "Server"
	add_child(_client_link_host)

	var built := _build_server()

	if not built.ok:
		return built

	var joined := _build_client()

	if not joined.ok:
		return joined

	var serviced := _build_services()

	if not serviced.ok:
		return serviced

	var added := server_bridge.add_occupant(CLIENT_PEER, CLIENT_OCCUPANT, display_name)

	if not added.ok:
		return added

	return DotResult.success(self)


## The prop layers and the services, once both bridges exist.
##
## Built after both ends rather than inside either, because the authority's props have to
## be able to announce themselves to a client that already has somewhere to put them.
func _build_services() -> DotResult:
	server_props = RoomProps.new()
	server_props.name = "ServerProps"
	add_child(server_props)

	var placed := server_props.setup(true, server_world)

	if not placed.ok:
		return placed

	server_world.props = server_props

	client_props = RoomProps.new()
	client_props.name = "ClientProps"
	add_child(client_props)
	client_props.setup(false, client_world)
	client_world.props = client_props

	server_props.placed.connect(_on_prop_placed)
	server_props.cleared.connect(server_bridge.broadcast_prop_cleared)
	server_bridge.place_requested.connect(_on_place_requested)
	server_bridge.undo_requested.connect(_on_undo_requested)

	services = RoomServices.new()
	services.name = "Services"
	services.bridge = server_bridge
	services.world = server_world
	# No DotServer offline. [RoomServices] is built for that: names come out of the room
	# and keys are derived from the occupant id.
	services.server = null
	services.service_scope = &"offline"
	# A punishment file an offline run wrote would be a punishment a real server then
	# loaded, against a key that means nothing to it. Its own path, deliberately.
	services.punishments_path = "user://room_punishments_offline.json"
	add_child(services)

	var ready := services.setup()

	if not ready.ok:
		return ready

	server_bridge.say_requested.connect(_on_say_requested)
	server_bridge.voice_requested.connect(_on_voice_requested)
	services.add_peer(CLIENT_PEER)

	return DotResult.success(null)


func _on_prop_placed(place_id: int, def: DotPropDef, at: Vector2) -> void:
	var entry: Dictionary = server_props.placements().get(place_id, {})
	server_bridge.broadcast_prop_placed(
		place_id, def.id, at, float(entry.get("rotation", 0.0)), int(entry.get("owner", 0))
	)


func _on_place_requested(
	peer_id: int, prop_index: int, at: Vector2, rotation: float
) -> void:
	var occupant := server_bridge.occupant_for_peer(peer_id)
	var prop_id := RoomProps.id_at(prop_index)

	if occupant == null or prop_id == &"":
		return

	var placed := server_props.place(occupant.id, prop_id, at, rotation)

	if not placed.ok:
		services.chat.notice(peer_id, placed.error.message, RoomServices.CHANNEL_ALL)


func _on_undo_requested(peer_id: int) -> void:
	var occupant := server_bridge.occupant_for_peer(peer_id)

	if occupant != null and not server_props.undo(occupant.id):
		services.chat.notice(
			peer_id, "You have not put anything in the room.", RoomServices.CHANNEL_ALL
		)


func _on_say_requested(peer_id: int, channel_id: StringName, text: String) -> void:
	var said := services.chat.submit(peer_id, channel_id, text)

	if not said.ok and said.error != null:
		services.chat.notice(peer_id, said.error.message, channel_id)


## A voice frame, relayed by the real router — which offline means straight back.
##
## [b]Kept rather than short-circuited.[/b] One client talking to itself is exactly what
## exercises the encode, the packet header, the router's own stamping and rate cap, and
## the jitter buffer, in one loop with nothing else running. It is the only place in this
## game where the whole voice path can be driven deterministically.
func _on_voice_requested(peer_id: int, payload: PackedByteArray) -> void:
	services.voice.relay(peer_id, payload)


func _build_server() -> DotResult:
	server_world = _world(true, &"offline_server")

	var config := RoomContent.net_config()

	server_net = DotNetManager.new()
	server_net.name = "ServerNet"
	server_net.is_server = true
	server_net.local_peer_id = 1
	server_net.config = config
	server_net.config_file = ""
	server_net.auto_tick = false
	add_child(server_net)

	var ready := server_net.setup()

	if not ready.ok:
		return ready

	server_bridge = RoomBridge.new()
	server_bridge.name = "ServerBridge"
	add_child(server_bridge)

	var attached := server_bridge.attach(server_world, server_net, _server_link_host)

	if not attached.ok:
		return attached

	server_bridge.link.loopback = func(
		method: StringName, peer_id: int, payload: PackedByteArray
	) -> void:
		_queue(false, method, peer_id, payload)

	return server_net.start()


func _build_client() -> DotResult:
	client_world = _world(false, &"offline_client")

	var config := RoomContent.net_config()

	client_net = DotNetManager.new()
	client_net.name = "ClientNet"
	client_net.is_server = false
	client_net.local_peer_id = CLIENT_PEER
	client_net.config = config
	client_net.config_file = ""
	client_net.auto_tick = false
	add_child(client_net)

	var ready := client_net.setup()

	if not ready.ok:
		return ready

	client_bridge = RoomBridge.new()
	client_bridge.name = "ClientBridge"
	add_child(client_bridge)

	var attached := client_bridge.attach(client_world, client_net, _client_link_host)

	if not attached.ok:
		return attached

	# The loopback knows exactly what it is delaying, so it says so rather than leaving
	# the clock to assume a perfect link. This is the same wiring a real client does from
	# [method DotClientLink.ping_ms]; only the source differs.
	client_bridge.rtt_source = func() -> float:
		return float(latency_ticks) * 2.0 * client_net.clock.tick_duration() * 1000.0

	client_bridge.link.loopback = func(
		method: StringName, _peer_id: int, payload: PackedByteArray
	) -> void:
		_queue(true, method, CLIENT_PEER, payload)

	return client_net.start()


func _world(authority: bool, scope: StringName) -> RoomWorld:
	var made := RoomWorld.new()
	made.name = "AuthorityWorld" if authority else "MirrorWorld"
	made.is_authority = authority
	made.tick_rate = RoomContent.TICK_RATE
	# Not published. Two worlds in one process under one name means one of them is
	# invisible and a module binds to whichever registered last — and here there are two
	# by construction.
	made.register_service = false
	made.service_scope = scope
	add_child(made)
	made.setup()
	return made


# --- The wire --------------------------------------------------------------

## Queues one payload for the other end.
func _queue(
	to_server: bool,
	method: StringName,
	peer_id: int,
	payload: PackedByteArray
) -> void:
	if method == &"snapshot" and loss > 0.0 and _rng.randf() < loss:
		return

	_pending.append({
		"to_server": to_server,
		"method": method,
		"peer": peer_id,
		"payload": payload,
		"at": _tick + latency_ticks,
	})


## Delivers whatever is due. Called from [method server_tick].
func _flush() -> void:
	if _pending.is_empty():
		return

	var keep: Array[Dictionary] = []

	for entry in _pending:
		if int(entry["at"]) > _tick:
			keep.append(entry)
			continue

		var link: RoomLink = (
			server_bridge.link if bool(entry["to_server"]) else client_bridge.link
		)

		if link != null and is_instance_valid(link):
			link.deliver(entry["method"], int(entry["peer"]), entry["payload"])

	_pending = keep


## One authoritative tick, and one delivery pass.
##
## The client's own tick is driven by whoever owns this — [RoomClient] from its
## `_physics_process`, or a test from a loop — because the client half is the thing under
## test and a helper that ticked both would hide the ordering.
func server_tick(tick: int) -> void:
	_tick = tick

	if server_bridge != null:
		server_bridge.server_tick(tick)

	_flush()


## Puts a chat line into the offline room, through the real router.
##
## [b]It goes over the loopback like everything else.[/b] The client's `SAY` request
## reaches the authority, [DotChatRouter] applies every rule, and the reply comes back as
## a `CHAT` event the client's own [DotChatClient] files — the same six steps an online
## line takes. The previous version of this function restated dot-server's payload shape
## by hand, which meant the one code path a person running `--offline` exercised was the
## one path nothing else used.
func say(text: String, channel_id: StringName = RoomServices.CHANNEL_ALL) -> void:
	if client_bridge != null:
		client_bridge.say(channel_id, text)


func describe() -> Dictionary:
	return {
		"pending": _pending.size(),
		"latency_ticks": latency_ticks,
		"loss": loss,
		"server": server_bridge.describe() if server_bridge != null else {},
		"client": client_bridge.describe() if client_bridge != null else {},
	}
