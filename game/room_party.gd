class_name RoomParty
extends Node

## Hosting this room for friends, with no dedicated server anywhere.
##
## [b]Of the five games in this family, the lobby is the one peer-to-peer actually
## suits.[/b] It is worth saying why, because the other four make the opposite decision
## and the difference is the point:
##
## - There is nothing to cheat at. A lobby has no score, no records, no entitlements and
##   no reward. A host who can lie about the simulation can lie about where a bench is.
## - It is small. Eight people in one room is inside what a domestic uplink carries, which
##   a sixty-four-player match is not.
## - It is exactly the case a dedicated server is too much for. "Come and sit in a room
##   with me" should not need somebody to rent a box.
##
## So the trust model here is [constant DotP2PConfig.Trust.HOST_AUTHORITATIVE] and that is
## a considered answer rather than a default: the host decides, the host could cheat, and
## there is nothing worth cheating for. `game-g2gfast` takes the same addon and refuses,
## because its entire output is records.
##
## [b]What this does not do is replace the netcode.[/b] dot-net still carries the
## simulation and [RoomBridge] still speaks it; this produces a `MultiplayerPeer` and a
## membership list, which is the part dot-server would otherwise have provided.

const CHANNEL := "room.party"

## The session is up. [param code] is what a friend types.
signal open(code: String)

## It ended, with the reason.
signal closed(res: DotResult)

var session: DotP2PSession = null

## Where the rendezvous is. Empty means the loopback one, which is only useful in a suite.
@export var signalling_url: String = ""

var _http: DotHttp = null


func setup() -> DotResult:
	session = DotP2PSession.new()
	session.name = "P2P"
	session.config = _config()
	add_child(session)

	var res := session.setup()
	if not res.ok:
		return res.wrap("the party session")

	session.signaller = _make_signaller()
	session.membership_changed.connect(_on_membership)
	session.host_changed.connect(_on_host_changed)
	session.ended.connect(func(r: DotResult) -> void: closed.emit(r))
	return DotResult.success(null)


func _config() -> DotP2PConfig:
	var c := DotP2PConfig.new()
	# Eight, which is what this room is sized for and what a domestic uplink carries.
	c.max_peers = 8
	c.trust = DotP2PConfig.Trust.HOST_AUTHORITATIVE
	# A lobby whose host leaves should not end; that is somebody's evening. And the
	# election is a pure function of the member list, so nobody has to be asked at the one
	# moment messages are not arriving.
	c.migrate_host = true
	c.signalling_url = signalling_url
	return c


func _make_signaller() -> DotP2PSignaller:
	if signalling_url.is_empty():
		# A loopback signaller is honest about what it is: two peers in one process. It
		# is what the suite uses, and it is what a split-screen build would.
		return DotP2PSignallerLoopback.new(session.local_id)

	_http = DotHttp.new()
	_http.name = "PartyHttp"
	add_child(_http)
	return DotP2PSignallerHttp.new(signalling_url, session.local_id, _http)


## Opens a room and returns the code to read out.
func host(display_name: String) -> DotResult:
	if not DotP2PSession.available():
		# Named, not silent. A build with no WebRTC extension and a browser with none are
		# two different problems with two different answers, and a player can act on both.
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"this build cannot host for friends",
			DotP2PSession.unavailable_reason()
		)

	var res := session.host(display_name)
	if res.ok:
		open.emit(str(res.value))
		DotLog.info(CHANNEL, "the room is open", {"code": str(res.value)})
	return res


func join(code: String, display_name: String) -> DotResult:
	return session.join(code, display_name)


func leave() -> void:
	session.leave()


func code() -> String:
	return session.lobby.code


func is_host() -> bool:
	return session.is_host()


func members() -> PackedStringArray:
	return session.lobby.member_ids()


func _on_membership(ids: PackedStringArray) -> void:
	DotLog.debug(CHANNEL, "membership", {"count": ids.size()})


func _on_host_changed(from_id: StringName, to_id: StringName) -> void:
	# Worth saying out loud in a lobby, because the person it happens to is the only one
	# who can tell: everybody else's room carries on looking exactly the same.
	DotLog.info(CHANNEL, "the host changed", {"from": String(from_id), "to": String(to_id)})


func describe_lines() -> PackedStringArray:
	return session.describe_lines() if session != null else PackedStringArray(["no party"])
