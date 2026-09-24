extends Node

const RoomBridge := preload("room_bridge.gd")
const RoomLink := preload("room_link.gd")

## The four remote calls this game needs, on one node that exists on both ends.
##
## [b]Why one class rather than a server half and a client half.[/b] Godot refuses an RPC
## unless both ends declare the [i]same set[/i] of [code]@rpc[/code] methods — it compares
## a checksum over them — and it routes the call by the receiver's node path relative to
## its [MultiplayerAPI] root. dot-server learned this the expensive way: putting chat's
## two methods on [DotClientLink] instead of on a mirrored child broke the paths [i]and[/i]
## changed the checksum, so every RPC between client and server was refused, handshake
## included, with a timeout as the only symptom.
##
## Using literally the same script on both sides makes the checksum identical by
## construction. All that is left is the path, and that is why this node is named the same
## on both ends and parented to the node that is itself named the same on both ends —
## [DotServer] on one side and [DotClientLink] on the other, both called
## [code]Server[/code].
##
## [codeblock]
## Server            <- DotServer, or DotClientLink named to match
##   Chat            <- DotChatManager / DotClientChat
##   Room            <- this, on both
## [/codeblock]

const CHANNEL := "room.link"

## The node name both ends must use. It is the routing, so it is a constant.
const NODE_NAME := &"Room"

## Everything here rides [constant DotTransport.Channel.STATE], which dot-server reserves
## for exactly this and uses for nothing itself. Sharing chat's channel would make a burst
## of snapshots delay a chat line — which in a room whose entire point is the chat is the
## one delay anybody would notice.
const CHANNEL_STATE := 1

## Voice, and only voice.
##
## [constant DotTransport.Channel.EVENT] is what dot-server reserves for chat and events,
## and this game's chat has moved onto [DotChatRouter] and rides `event` on the state
## channel with everything else — so this one is free. Voice gets it to itself for the
## reason the state channel exists at all: fifty packets a second must not sit behind a
## snapshot, and a snapshot must not sit behind a talk spurt.
const CHANNEL_VOICE := 2

## The bridge these calls are delivered to. Set by whoever creates this node.
var bridge: RoomBridge = null

## Whether this end is the authority. Used only to refuse an obviously misrouted call
## early, with a log line naming the node rather than a silent no-op.
var is_server: bool = false

## Where calls go instead of onto the network.
##
## Signature: [code]func(method: StringName, peer_id: int, payload: PackedByteArray)[/code],
## with [code]method[/code] one of [code]snapshot[/code], [code]event[/code],
## [code]input[/code] or [code]request[/code].
##
## A test seam, and the only way this netcode can be checked deterministically: a real
## socket does not reproduce the same latency, reordering and loss twice. Unset — which is
## every real deployment — every send goes out as an RPC.
var loopback: Callable = Callable()

var snapshots_sent: int = 0
var snapshots_received: int = 0
var events_sent: int = 0
var events_received: int = 0
var inputs_sent: int = 0
var inputs_received: int = 0
var requests_sent: int = 0
var requests_received: int = 0
var voice_sent: int = 0
var voice_received: int = 0

## Sends dropped because there was no connection to send on. Counted per episode.
var dropped_sends: int = 0
var _dropping := false
var _warned_unbridged := false


static func attached_to(parent: Node, p_bridge: RoomBridge, server: bool) -> RoomLink:
	var link := RoomLink.new()
	link.name = NODE_NAME
	link.bridge = p_bridge
	link.is_server = server
	parent.add_child(link)
	return link


func _live() -> bool:
	if loopback.is_valid():
		return true

	var live := is_inside_tree() \
		and multiplayer != null \
		and multiplayer.has_multiplayer_peer()

	# [b]Logged on the edges, never per send.[/b] A snapshot a tick to every client is
	# the hottest path in the game, and a line per dropped one would be sixty a second.
	# DEBUG, because dropping is correct — before a connection and after one, there is
	# nobody to send to — and what somebody debugging a silent client wants is when it
	# started and how much went nowhere.
	if not live:
		dropped_sends += 1
		if not _dropping:
			_dropping = true
			DotLog.debug(CHANNEL, "no connection: sends are dropped until there is one", {
				"server": is_server,
			})
	elif _dropping:
		_dropping = false
		DotLog.debug(CHANNEL, "connected again", {
			"server": is_server, "dropped": dropped_sends,
		})
		dropped_sends = 0

	return live


# --- Sending ---------------------------------------------------------------

## A state snapshot. Server to one client, or to all of them when [param peer_id] is 0.
func send_snapshot(peer_id: int, payload: PackedByteArray) -> void:
	if not _live():
		return

	snapshots_sent += 1

	if loopback.is_valid():
		loopback.call(&"snapshot", peer_id, payload)
	elif peer_id == 0:
		_net_snapshot.rpc(payload)
	else:
		_net_snapshot.rpc_id(peer_id, payload)


func send_event(peer_id: int, payload: PackedByteArray) -> void:
	if not _live():
		return

	events_sent += 1

	if loopback.is_valid():
		loopback.call(&"event", peer_id, payload)
	elif peer_id == 0:
		_net_event.rpc(payload)
	else:
		_net_event.rpc_id(peer_id, payload)


func send_input(payload: PackedByteArray) -> void:
	if not _live():
		return

	inputs_sent += 1

	if loopback.is_valid():
		loopback.call(&"input", 1, payload)
	else:
		_net_client_input.rpc_id(1, payload)


## One encoded [DotVoicePacket], in whichever direction this end is.
##
## [b]One call for both, because there is only one question and the answer differs by
## transport rather than by code.[/b] A desktop client is on ENet, where `unreliable`
## means a UDP datagram that is never retransmitted — which is what voice wants, since a
## frame that arrives late is a frame the jitter buffer has already concealed. A browser
## client is on a WebSocket, where every transfer mode is TCP underneath and this is
## delivered reliably and in order whether or not it was asked for. That is a property of
## the transport, not a gap here: the same bytes, the same [DotVoiceRouter], the same
## jitter buffer, and a browser simply pays for retransmission it did not want. Writing
## two paths would mean two paths to keep in step for a difference neither end can act on.
##
## [param peer_id] is the recipient on a server and is ignored on a client, which always
## sends to the authority. **Zero is not "everybody"**: the router names its listeners one
## at a time, for the reason [method RoomBridge._tell] gives.
func send_voice(peer_id: int, payload: PackedByteArray) -> void:
	if not _live():
		return

	voice_sent += 1

	if loopback.is_valid():
		loopback.call(&"voice", peer_id if is_server else 1, payload)
	elif is_server:
		if peer_id > 0:
			_net_voice.rpc_id(peer_id, payload)
	else:
		_net_voice.rpc_id(1, payload)


func send_request(payload: PackedByteArray) -> void:
	if not _live():
		return

	requests_sent += 1

	if loopback.is_valid():
		loopback.call(&"request", 1, payload)
	else:
		_net_request.rpc_id(1, payload)


# --- Receiving -------------------------------------------------------------

## State from the authority. Unreliable: a newer snapshot supersedes a lost one, and
## resending a hundred-millisecond-old position is worse than useless.
##
## Note that over WebSocket — which is every browser client, and therefore every client
## on a server that has one — this is delivered reliably and in order anyway. That is a
## property of TCP rather than a gap here, and it is why the snapshot rate is 15 and not
## 60: fewer, larger, self-contained updates degrade more gracefully on a stream that
## cannot drop one.
@rpc("authority", "unreliable", "call_remote", CHANNEL_STATE)
func _net_snapshot(payload: PackedByteArray) -> void:
	snapshots_received += 1

	if bridge == null:
		_note_unbridged(&"snapshot")
		return

	bridge.receive_snapshot(payload)


## Anything from the authority that must arrive: the hello, the roster, joins and leaves.
@rpc("authority", "reliable", "call_remote", CHANNEL_STATE)
func _net_event(payload: PackedByteArray) -> void:
	events_received += 1

	if bridge == null:
		_note_unbridged(&"event")
		return

	bridge.receive_event(payload)


## A client's intent. Unreliable, and not resent: the next tick's packet carries the newer
## command anyway, and a retransmit would arrive after its tick had passed.
@rpc("any_peer", "unreliable", "call_remote", CHANNEL_STATE)
func _net_client_input(payload: PackedByteArray) -> void:
	inputs_received += 1

	if bridge == null:
		_note_unbridged(&"input")
		return

	# The sender comes from the transport, never from inside the payload. A peer id in
	# a body is a claim; this is a fact.
	bridge.receive_input(multiplayer.get_remote_sender_id(), payload)


## A client asking for something. Reliable and rare.
@rpc("any_peer", "reliable", "call_remote", CHANNEL_STATE)
func _net_request(payload: PackedByteArray) -> void:
	requests_received += 1

	if bridge == null:
		_note_unbridged(&"request")
		return

	bridge.receive_request(multiplayer.get_remote_sender_id(), payload)


## A voice frame, either way.
##
## [b]`any_peer`, which on the server means the sender is a claim until the transport is
## asked.[/b] [method MultiplayerAPI.get_remote_sender_id] is the fact, and
## [method DotVoiceRouter.relay] stamps it over whatever the packet's own speaker field
## said — because without that any client can put words in any other player's mouth and
## the only symptom is confusion.
@rpc("any_peer", "unreliable", "call_remote", CHANNEL_VOICE)
func _net_voice(payload: PackedByteArray) -> void:
	voice_received += 1

	if bridge == null:
		_note_unbridged(&"voice")
		return

	bridge.receive_voice(multiplayer.get_remote_sender_id(), payload)


## Hands a payload to this end as though it had arrived over the wire.
##
## What the other end's [member loopback] calls. It goes through the same counters and the
## same bridge entry points the RPCs do, so a test exercises the real path minus the
## socket.
func deliver(method: StringName, from_peer_id: int, payload: PackedByteArray) -> void:
	if bridge == null:
		_note_unbridged(method)
		return

	match method:
		&"snapshot":
			snapshots_received += 1
			bridge.receive_snapshot(payload)
		&"event":
			events_received += 1
			bridge.receive_event(payload)
		&"input":
			inputs_received += 1
			bridge.receive_input(from_peer_id, payload)
		&"request":
			requests_received += 1
			bridge.receive_request(from_peer_id, payload)
		&"voice":
			voice_received += 1
			bridge.receive_voice(from_peer_id, payload)


## A payload arrived with no bridge to hand it to, so it went nowhere.
##
## WARN, once per link: a link is attached with its bridge, so this is a node kept past
## its teardown or wired wrong, and every later payload would say the same thing.
func _note_unbridged(method: StringName) -> void:
	if _warned_unbridged:
		return
	_warned_unbridged = true
	DotLog.warn(CHANNEL, "a payload arrived at a link with no bridge and was dropped", {
		"method": String(method), "server": is_server,
	})


func describe() -> Dictionary:
	return {
		"server": is_server,
		"dropped_sends": dropped_sends,
		"snapshots": [snapshots_sent, snapshots_received],
		"events": [events_sent, events_received],
		"inputs": [inputs_sent, inputs_received],
		"requests": [requests_sent, requests_received],
		"voice": [voice_sent, voice_received],
	}
