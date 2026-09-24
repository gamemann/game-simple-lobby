extends Node

const RoomClient := preload("../game/client/room_client.gd")
const RoomContent := preload("../game/room_content.gd")
const RoomModule := preload("../game/room_module.gd")
const RoomProps := preload("../game/room_props.gd")
const RoomServices := preload("../game/room_services.gd")

## A real server and two real clients, over real sockets, in one process.
##
## [codeblock]
## godot --headless --path . res://examples/sandbox.tscn
## godot --headless --path . res://examples/sandbox.tscn -- --verbose
## [/codeblock]
##
## Exits non-zero on any failure.
##
## [b]The one that matters, and the slowest to write.[/b] It is the only place dot-server's
## signon, the RPC node paths, dot-server's chat and this game's netcode all run at once,
## and it is the only place two people are in the same room — which is the thing a
## multiplayer game must do and the thing every per-observer decision is trivially correct
## about with one observer.
##
## [b]Three MultiplayerAPI instances in one process.[/b] There is a single
## [member SceneTree.multiplayer] and three peers here want it, so each half gets its own
## through [method SceneTree.set_multiplayer], scoped to its own subtree. dot-platform's
## sandbox proved the mechanism; the catch it also proved is that RPCs are routed by node
## path *relative to each API root*, so the paths have to line up on both sides — which is
## why every one of the three link nodes is named `Server`.

const PORT := 27086
const SERVER_DIR := "user://room_sandbox"

## Every check this suite runs, section counter included. See docs/testing.md.
const CHECKS := 81

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _server: DotServer = null

var _client_side: Node = null
var _link: DotClientLink = null
var _client: RoomClient = null
var _heard: Array[DotChatMessage] = []

## Anything that came back through dot-server's own chat signal.
##
## [b]Expected to stay empty, and that is the check.[/b] This game moved its chat rules
## onto [DotChatRouter] and cancels dot-server's broadcast, so a line arriving here as
## well would be two paths delivering one message — the failure the cancel exists to
## prevent, and the one nobody would notice because the message still arrives.
var _legacy_heard: Array[Dictionary] = []

## The one thing dot-server's chat signal legitimately carries here.
##
## [b]Not a line, which is why it is kept apart from [member _legacy_heard].[/b]
## [code]DotChatManager.greet[/code] sends `{kind: "state", relay: bool}` to a joining
## client to say whether anything else is carrying the conversation. It has no text and
## draws nothing; counting it as a delivered message would have made the check above read
## as two paths for one line, which is the failure that check exists for.
var _chat_state: Array[Dictionary] = []

var _other_side: Node = null
var _other_link: DotClientLink = null
var _other: RoomClient = null
var _other_heard: Array[DotChatMessage] = []


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("game-simple-lobby sandbox")

	DotPaths.remove_tree(SERVER_DIR)

	if await _build():
		if await _test_join():
			await _test_room()
			await _test_chat()
			await _test_two_people()
			await _test_walking()
			await _test_admin_over_the_socket()
			await _test_blind_and_beacon_over_the_socket()
			await _test_props()
			await _test_voice()
			await _test_earshot()
			await _test_leaving()

	_teardown()
	DotPaths.remove_tree(SERVER_DIR)

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	return condition


## Waits for a condition, or gives up. Returns whether it happened.
##
## A deadline rather than a fixed number of frames: a signon over loopback is several
## round trips, and "a hundred frames is surely enough" is a check that passes on an idle
## box and fails on a busy one.
func _until(condition: Callable, seconds: float = 12.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)

	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true

		await get_tree().physics_frame

	return bool(condition.call())


func _settle(frames: int = 30) -> void:
	for _i in range(frames):
		await get_tree().physics_frame


# --- Building --------------------------------------------------------------

func _build() -> bool:
	print("")
	print("bringing the sandbox up")

	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)

	_client_side = Node.new()
	_client_side.name = "ClientSide"
	add_child(_client_side)

	get_tree().set_multiplayer(
		MultiplayerAPI.create_default_interface(), server_side.get_path()
	)
	get_tree().set_multiplayer(
		MultiplayerAPI.create_default_interface(), _client_side.get_path()
	)

	_check(
		get_tree().get_multiplayer(server_side.get_path())
			!= get_tree().get_multiplayer(_client_side.get_path()),
		"the two halves have separate MultiplayerAPI instances"
	)

	if not await _build_server(server_side):
		return false

	# Named "Server", which looks wrong and is not. Godot addresses an RPC by the
	# receiver's node path relative to its MultiplayerAPI root, so a call from the
	# server's node at ServerSide/Server arrives addressed to "Server" and is looked up
	# under the client's root. Give the client's node any other name and every RPC fails
	# with "Node not found: Server" — the handshake included, whose only symptom is a
	# timeout.
	_link = DotClientLink.new()
	_link.name = "Server"
	_link.player_name = "Ada"
	_client_side.add_child(_link)

	return true


func _build_server(server_side: Node) -> bool:
	var config := DotServerConfig.new()
	config.hostname = "room sandbox"
	config.port = PORT
	config.bind_address = "127.0.0.1"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % SERVER_DIR
	config.bans_path = "%s/bans.json" % SERVER_DIR
	config.audit_log_path = "%s/audit.jsonl" % SERVER_DIR
	config.hibernate_when_empty = false
	config.startup_config = ""
	config.autoexec_config = ""
	# A self-test takes no commands. The console's stdin reader blocks in a read nothing
	# can wake, so on an open pipe that never closes — `sleep 130 | godot ...`, measured —
	# this suite printed "62 passed, 0 failed" and then never exited.
	config.stdin_console_enabled = false

	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	server_side.add_child(_server)

	var booted: DotResult = await _server.boot()

	if not _check(booted.ok, "the server boots and listens on %d" % PORT, str(booted.error)):
		return false

	# No dot-auth in this tree, so everybody is a guest with a per-device id through
	# [DotGuestIdentity]. That is the simplest deployment shape there is, and the family's
	# own rule says a path only one shape reaches is a path nothing has run.
	_check(
		not DotRegistry.has(&"dot_auth_server"),
		"with no dot-auth, so everybody arrives as a guest"
	)

	_server.games.add_game(RoomModule.game_descriptor())

	var loaded: DotResult = await _server.games.change_game(RoomModule.GAME_ID, "boot")

	if not _check(loaded.ok, "the room loads", str(loaded.error)):
		return false

	# Into this run's own directory rather than the store a real server enforces.
	RoomModule.punishments_path = "%s/punishments.json" % SERVER_DIR

	var module: DotResult = await _server.modules.load_module(
		"res://game/room_module.gd"
	)
	return _check(module.ok, "and the module loads into it", str(module.error))


func _teardown() -> void:
	for link in [_other_link, _link]:
		if link != null and is_instance_valid(link):
			link.disconnect_from_server("shutdown")

	if _server != null and is_instance_valid(_server):
		_server.shutdown("sandbox finished")


func _module() -> RoomModule:
	return _server.modules.get_module("room") as RoomModule


## Instantiates the client scene against a given link.
##
## The link is assigned *before* the node enters the tree, because [method Node._ready] is
## where the client wires itself up — and a client that found no link would stand up an
## offline room instead of joining this one, silently and quite convincingly.
func _make_client(parent: Node, link: DotClientLink) -> RoomClient:
	var packed: Variant = load("res://scenes/room_client.tscn")
	var client := (packed as PackedScene).instantiate() as RoomClient
	client.link = link
	parent.add_child(client)
	return client


# --- Sections --------------------------------------------------------------

func _test_join() -> bool:
	_section("a client connects")

	var spawned := [false]
	var refused := [""]

	# Captured through Arrays, not bools. GDScript lambdas capture locals by value, so a
	# flag set inside a handler stays false outside it — and the test reports a failure
	# for a signal that fired perfectly.
	_link.spawned.connect(func() -> void: spawned[0] = true)
	_link.disconnected.connect(func(reason: String) -> void: refused[0] = reason)
	# [b]dot-server's own `chat_received` is deliberately NOT what this listens on.[/b]
	# The module cancels that path and routes every line through [DotChatRouter] onto
	# this game's own wire; a test that still listened there would pass on a server
	# running the old path and fail on the one that ships.
	_link.chat_received.connect(func(payload: Dictionary) -> void:
		if str(payload.get("kind", "")) == "state":
			_chat_state.append(payload)
			return

		_legacy_heard.append(payload)
	)

	var connecting: DotResult = await _link.connect_to_server("127.0.0.1:%d" % PORT)

	if not _check(connecting.ok, "the client starts connecting", str(connecting.error)):
		_done()
		return false

	var admitted := await _until(func() -> bool: return spawned[0] or refused[0] != "")

	if not _check(admitted, "and finishes signon", "refused: %s" % refused[0]):
		_done()
		return false

	_check(refused[0] == "", "without being refused")
	_check(_server.sessions().size() == 1, "the server has one session")

	# The room ships inside the build, so the descriptor names no manifest and
	# [method DotGameDescriptor.client_scene_or_scene] hands the client the empty string —
	# the documented "you already have it" path. A server that fell back to its own
	# absolute scene path would have the client refuse it and time out in LOADING.
	_check(
		_link.phase == DotClientLink.Phase.PLAYING,
		"and is playing rather than stuck loading (%s)" % _link.phase
	)

	_client = _make_client(_client_side, _link)
	_client.chat.message_received.connect(
		func(message: DotChatMessage, _channel: StringName) -> void:
			_heard.append(message)
	)

	var told := await _until(func() -> bool:
		return _client.bridge != null and _client.bridge.local_occupant_id != 0
	)

	_check(told, "the client scene is told who it is")
	_done()
	return told


func _test_room() -> void:
	_section("the room, from the client's side")

	await _settle(60)

	var mine := _client.bridge.local_occupant_id
	var session := _server.sessions()[0]

	_check(
		mine == session.userid,
		"the client's id is the server's session id (%d, %d)" % [mine, session.userid]
	)
	_check(
		_client.world.occupant_count() == 1,
		"and its room has one person in it (%d)" % _client.world.occupant_count()
	)

	var me := _client.world.occupant_for(mine)
	_check(me != null and me.is_local, "who is marked as the local one")
	_check(
		me != null and me.display_name == "Ada",
		"with the name the link was given (%s)"
			% (me.display_name if me != null else "-")
	)
	_check(
		_client.bridge.entity_count() == 1,
		"and one replicated entity behind them"
	)

	# The one thing a mismatch is completely silent about: every position would still
	# decode and every id would still match, and everybody would simply be standing
	# somewhere else.
	_check(
		_client.world.arena.bounds.size.is_equal_approx(
			_module().world.arena.bounds.size
		),
		"both ends agree how big the room is"
	)
	_done()


func _test_chat() -> void:
	_section("chat")

	# This game's own wire, through [DotChatRouter]: sanitised, flood-limited, gag-checked
	# and addressed there, and delivered as a [constant RoomEvents.Kind.CHAT] event.
	_client.bridge.say(RoomServices.CHANNEL_ALL, "hello from Ada")

	var heard := await _until(func() -> bool:
		return _text_heard(_heard, "hello from Ada")
	)

	_check(heard, "a line the client sent comes back to it")

	var me := _client.world.occupant_for(_client.bridge.local_occupant_id)
	_check(
		me != null and me.bubble_text == "hello from Ada",
		"and becomes a bubble over the person who said it"
	)

	var on_server := _module().world.occupant_for(_client.bridge.local_occupant_id)
	_check(
		on_server != null and on_server.bubble_text == "hello from Ada",
		"on the server too, which is what `room_who` reports from"
	)

	# [b]And the one payload that legitimately comes down dot-server's chat signal.[/b]
	# A joining client is told what is carrying the conversation before it has any line to
	# draw, so it can decide whether to draw a chat box at all rather than drawing one and
	# taking it away a moment later.
	_check(
		_chat_state.size() >= 1,
		"the server told the client what is carrying chat, on joining (%d)" % _chat_state.size()
	)

	_check(
		_legacy_heard.is_empty(),
		"and dot-server's own chat delivered nothing beside it (%d)"
			% _legacy_heard.size(),
		"two paths for one message is two sets of rules, and the one that skipped the "
		+ "filter would be the one that leaked admin chat"
	)

	# Sanitising is dot-chat's now. What matters here is the same thing it always did:
	# that this game did not route around it.
	_client.bridge.say(RoomServices.CHANNEL_ALL, "a​b")
	await _settle(30)

	var last := _heard[_heard.size() - 1].text if not _heard.is_empty() else ""
	_check(
		not last.contains("​"),
		"and a zero-width character is stripped before anybody sees it (%s)" % last,
		"used to spoof names and hide text; a second chat path would skip this"
	)

	# [b]The legacy path still works and is still the router's.[/b] A browser shell's own
	# chat box and a client console's `say` both go through dot-server, and the module
	# forwards them rather than dropping them — so the check is that a line sent the old
	# way comes back on the new wire.
	_link.send_chat("said the old way")

	var forwarded := await _until(func() -> bool:
		return _text_heard(_heard, "said the old way")
	)

	_check(
		forwarded,
		"a line sent through dot-server's own chat is forwarded onto this game's wire",
		"the browser shell has no way to name a channel and must still be able to talk"
	)
	_done()


## Whether any line in [param lines] says exactly [param text].
func _text_heard(lines: Array[DotChatMessage], text: String) -> bool:
	for message in lines:
		if message.text == text:
			return true

	return false


## A second person, over a second socket, in a third MultiplayerAPI.
##
## Everything before this is one client: it proves the signon, the RPC paths and the
## netcode, and proves nothing at all about whether two people can see each other. The
## roster, the join broadcast and the entity mirroring are all per-observer, and every one
## of them is trivially correct with one observer.
func _test_two_people() -> void:
	_section("a second person")

	_other_side = Node.new()
	_other_side.name = "OtherSide"
	add_child(_other_side)

	get_tree().set_multiplayer(
		MultiplayerAPI.create_default_interface(), _other_side.get_path()
	)

	_other_link = DotClientLink.new()
	# "Server", the same as the first one and the same as [DotServer]. The name is the
	# routing, not a description.
	_other_link.name = "Server"
	_other_link.player_name = "Grace"
	_other_side.add_child(_other_link)

	var spawned := [false]
	_other_link.spawned.connect(func() -> void: spawned[0] = true)
	_other_link.chat_received.connect(func(payload: Dictionary) -> void:
		if str(payload.get("kind", "")) == "state":
			_chat_state.append(payload)
			return

		_legacy_heard.append(payload)
	)

	var connecting: DotResult = await _other_link.connect_to_server("127.0.0.1:%d" % PORT)

	if not _check(connecting.ok, "it connects", str(connecting.error)):
		_done()
		return

	if not _check(await _until(func() -> bool: return spawned[0]), "and completes signon"):
		_done()
		return

	_check(_server.sessions().size() == 2, "the server has two sessions")

	_other = _make_client(_other_side, _other_link)
	_other.chat.message_received.connect(
		func(message: DotChatMessage, _channel: StringName) -> void:
			_other_heard.append(message)
	)

	var told := await _until(func() -> bool:
		return _other.bridge != null and _other.bridge.local_occupant_id != 0
	)

	if not _check(told, "and the second client is told who it is"):
		_done()
		return

	var mine := _client.bridge.local_occupant_id
	var theirs := _other.bridge.local_occupant_id

	_check(mine != theirs, "the two have different ids (%d and %d)" % [mine, theirs])

	var both_seen := await _until(func() -> bool:
		return _client.world.occupant_count() == 2 \
			and _other.world.occupant_count() == 2
	)

	_check(
		both_seen,
		"each of them can see the other (%d and %d in the room)"
			% [_client.world.occupant_count(), _other.world.occupant_count()],
		"the roster and the join broadcast are per-observer and are both trivially "
		+ "correct with one observer"
	)

	var grace_to_ada := _client.world.occupant_for(theirs)
	var ada_to_grace := _other.world.occupant_for(mine)

	_check(
		grace_to_ada != null and grace_to_ada.display_name == "Grace",
		"by name, on the first client (%s)"
			% (grace_to_ada.display_name if grace_to_ada != null else "-")
	)
	_check(
		ada_to_grace != null and ada_to_grace.display_name == "Ada",
		"and on the second (%s)"
			% (ada_to_grace.display_name if ada_to_grace != null else "-")
	)
	_check(
		grace_to_ada != null and not grace_to_ada.is_local,
		"and somebody else's occupant is not marked local"
	)

	# Chat from the second reaches the first, through the server, and becomes a bubble
	# over the right head — which is the whole of what a lobby is.
	_other.bridge.say(RoomServices.CHANNEL_ALL, "hello from Grace")

	var relayed := await _until(func() -> bool:
		return _text_heard(_heard, "hello from Grace")
	)

	_check(relayed, "and what one says reaches the other")
	_check(
		grace_to_ada != null and grace_to_ada.bubble_text == "hello from Grace",
		"over the right head"
	)
	_done()


## Somebody walking, seen from the other client.
##
## This is the path nothing but two real clients reaches: the input goes out over a socket,
## the server simulates it, the snapshot comes back to a *different* peer, and the
## interpolator has to put the smoothed value somewhere the renderer reads. Both other
## games in this family shipped a version where it did not.
func _test_walking() -> void:
	_section("walking, seen by somebody else")

	var theirs := _other.bridge.local_occupant_id
	var seen_by_ada := _client.world.occupant_for(theirs)

	if not _check(seen_by_ada != null, "the first client can see the second"):
		_done()
		return

	var before := seen_by_ada.position()

	# Through the second client's own sampler, so this is the whole real path: sample,
	# quantise, send over a socket, simulate on the server, snapshot to a *different*
	# peer, interpolate, draw. Driving `client_tick` by hand instead would race the
	# client's own `_physics_process`, which is sampling "stopped" on the same frames — so
	# the two would take turns and the person would shuffle.
	var target := _other.world.arena.bounds.get_center()
	var command := Dot2DCommand.new()
	command.move = (target - _other.world.occupant_for(theirs).position()).normalized()
	_other.input.command_source = func() -> Dot2DCommand: return command

	await _settle(180)

	_other.input.command_source = Callable()

	var on_server := _module().world.occupant_for(theirs)

	_check(
		on_server != null and on_server.position().distance_to(before) > 30.0,
		"the server moved them (%.0f units)"
			% (on_server.position().distance_to(before) if on_server != null else 0.0),
		"an input stamped for a tick the server has passed is discarded as late, for "
		+ "ever, with no error on either end"
	)
	_check(
		seen_by_ada.position().distance_to(before) > 30.0,
		"and the other client sees it (%.0f units)"
			% seen_by_ada.position().distance_to(before),
		"an interpolated value written into a property nothing reads looks exactly like "
		+ "an interpolator that does not work"
	)
	_check(
		on_server != null
			and seen_by_ada.position().distance_to(on_server.position()) < 60.0,
		"within %.0f units of where the server has them"
			% (seen_by_ada.position().distance_to(on_server.position())
				if on_server != null else -1.0)
	)
	_done()


## An admin's noclip and freeze, over a real socket, on the person's own predicted body.
##
## `headless_net` is where this is PROVED, tick by tick, with a naive control that has to
## diverge, over a loopback that behaves the same way twice. What only a socket reaches is
## the rest: the console's tools on a live module, the bit riding a real snapshot, and the
## client's own sampler driving a prediction that holds through the island. The tolerance
## is the one "walking" already uses for agreement.
func _test_admin_over_the_socket() -> void:
	_section("an admin's noclip and freeze, over the socket")

	var module := _module()
	var mine := _client.bridge.local_occupant_id
	var id := StringName(str(mine))
	var on_server := module.world.occupant_for(mine)
	var on_client := _client.world.occupant_for(mine)

	if on_server == null or on_client == null:
		for what in ["predicted", "noclip", "learned", "through", "agreed", "freeze", "held"]:
			_check(false, what, "nobody to act on")
		_done()
		return

	# Over a socket, not a loopback: the client learns its peer id from the hello, after
	# its netcode is set up, and until dot-net forwarded that to its registry the client
	# registered its own body as somebody else's — unpredicted, a round trip behind the
	# keyboard, with every loopback suite (which sets the id first) saying otherwise. A
	# freeze predicted by a client that predicts nothing is not a freeze being predicted.
	var behaviour: Variant = _client.bridge.behaviour_for(mine)
	_check(
		behaviour != null and behaviour.identity != null and behaviour.identity.is_predicted(),
		"their client predicts its own body over a real socket"
	)

	var island := RoomContent.furniture()[0]
	var centre := Vector2(island.x, island.y)
	var heading := (centre - on_server.position()).normalized()

	var on: DotResult = await module.mod_tools.toggle(&"console", id, DotModTools.ACTION_NOCLIP, true, 100)
	_check(on.ok, "the server's tools noclip them", str(on.error))
	_check(
		await _until(func() -> bool: return Dot2DAdminModifiers.is_noclipped(on_client.state), 5.0),
		"and their client learns it from a snapshot"
	)

	var command := Dot2DCommand.new()
	command.move = heading
	_client.input.command_source = func() -> Dot2DCommand: return command

	var worst := [0.0]
	var through := await _until(func() -> bool:
		worst[0] = maxf(worst[0], on_client.position().distance_to(on_server.position()))
		return (on_server.position() - centre).dot(heading) > 0.0
	, 10.0)
	_check(through, "the server walks them through the island",
		"%.1f from its centre" % on_server.position().distance_to(centre))
	_check(worst[0] < 60.0, "and their client stays with them the whole way (worst %.1f units apart)" % worst[0])

	# Frozen in the middle of the island with the stick still held: the one place a
	# prediction that got freeze wrong could not hide, because letting go of noclip there
	# would push them out.
	var frozen: DotResult = await module.mod_tools.toggle(&"console", id, DotModTools.ACTION_FREEZE, true, 100)
	_check(frozen.ok, "the server's tools freeze them", str(frozen.error))
	var _told := await _until(func() -> bool: return Dot2DAdminModifiers.is_frozen(on_client.state), 5.0)
	var server_at := on_server.position()
	var client_at := on_client.position()
	await _settle(60)
	_check(
		on_server.position().distance_to(server_at) < 1.0
			and on_client.position().distance_to(client_at) < 1.0,
		"and neither end moves them under a held stick (server %.2f, client %.2f)" % [
			on_server.position().distance_to(server_at), on_client.position().distance_to(client_at)
		]
	)

	_client.input.command_source = Callable()
	var _thaw: DotResult = await module.mod_tools.toggle(&"console", id, DotModTools.ACTION_FREEZE, false, 100)
	var _off: DotResult = await module.mod_tools.toggle(&"console", id, DotModTools.ACTION_NOCLIP, false, 100)
	await _settle(30)
	_done()


## An admin's blind and beacon, over the socket, between two real clients.
##
## `headless_net` asserts the audience over a loopback with one client; this is the same
## question asked of two, with dot-server's signon and real RPC paths in the way, and it
## ends at the real `RoomClient`'s own overlay rather than at a flag.
func _test_blind_and_beacon_over_the_socket() -> void:
	_section("an admin's blind and beacon, over the socket")

	var module := _module()
	var mine := _client.bridge.local_occupant_id
	var id := StringName(str(mine))
	var on_client := _client.world.occupant_for(mine)
	var on_other := _other.world.occupant_for(mine)

	if on_client == null or on_other == null:
		for what in ["blind", "beacon", "not told", "overlay", "off"]:
			_check(false, what, "nobody to act on")
		_done()
		return

	var dark: DotResult = await module.mod_tools.toggle(&"console", id, DotModTools.ACTION_BLIND, true, 100)
	var lit: DotResult = await module.mod_tools.toggle(&"console", id, DotModTools.ACTION_BEACON, true, 100)
	_check(dark.ok and lit.ok, "the server's tools blind and beacon them", "%s / %s" % [dark.error, lit.error])

	# The beacon reaching the OTHER client is what says snapshots about this person have
	# arrived there, so the blind's absence afterwards is an absence and not a delay.
	var told := await _until(func() -> bool: return on_client.blinded and on_client.beacon and on_other.beacon, 5.0)
	_check(told, "their own client is blinded, and both clients draw the beacon")
	_check(
		not on_other.blinded,
		"and the other client is never told they are blinded",
		"a room that received it would know exactly who a moderator had just dealt with"
	)
	await _settle(20)
	_check(
		_client.ui.blind_overlay.visible and _client.ui.blind_overlay.modulate.a > 0.99
			and not _other.ui.blind_overlay.visible,
		"the blinded client's screen goes dark, and the other's does not",
		"%.2f / %s" % [_client.ui.blind_overlay.modulate.a, _other.ui.blind_overlay.visible]
	)

	var _lift: DotResult = await module.mod_tools.toggle(&"console", id, DotModTools.ACTION_BLIND, false, 100)
	var _unlit: DotResult = await module.mod_tools.toggle(&"console", id, DotModTools.ACTION_BEACON, false, 100)
	_check(
		await _until(func() -> bool: return not on_client.blinded and not on_client.beacon and not on_other.beacon, 5.0),
		"and turning both off reaches both clients"
	)
	_done()


## Props, over a real socket, seen by somebody who did not place them.
##
## [b]This is the only place a placement crosses a wire.[/b] `dedicated` places props and
## checks the budget in one process, which proves the book-keeping and nothing about the
## protocol: the index, the quantised position, the adopted id and the fact that both ends
## then collide against the same circle are all invisible with one end.
func _test_props() -> void:
	_section("props, seen by somebody else")

	var module := _module()
	var mine := _client.bridge.local_occupant_id

	_client.bridge.ask_to_place(&"bench", Vector2(240.0, -160.0))

	var landed := await _until(func() -> bool:
		return module.props.count() == 1
	)

	if not _check(landed, "the server places what a client asked for"):
		_done()
		return

	# [b]On BOTH clients, and the second one is the check that matters.[/b] The first
	# client asked for it, so a bug that echoed the request back locally would look
	# identical to a bug-free wire — and the person who did not ask is the one who finds
	# out whether it was actually sent.
	var seen_by_both := await _until(func() -> bool:
		return _client.props.count() == 1 and _other.props.count() == 1
	)

	_check(
		seen_by_both,
		"and both clients have it (%d and %d)"
			% [_client.props.count(), _other.props.count()]
	)

	var placed_id: int = module.props.placements().keys()[0]
	var on_server: Vector2 = module.props.placements()[placed_id]["at"]
	var on_other: Vector2 = _other.props.placements().get(placed_id, {}).get(
		"at", Vector2(9999, 9999)
	)

	# [b]The id is adopted, not allocated.[/b] A receiving peer that numbered things
	# itself would give the same bench two names on two machines, and every count would
	# still match — the bug dot-2d had to gain `Dot2DScatter.adopt` to fix.
	_check(
		_other.props.has(placed_id),
		"under the id the server gave it, not one the client made up"
	)
	_check(
		on_server.distance_to(on_other) < 1.0,
		"at the same place (%.2f units apart)" % on_server.distance_to(on_other),
		"the position is quantised over the same range as a snapshot's, so a mismatch "
		+ "would be a different position rather than a less precise one"
	)

	# The thing both ends have to agree about, which is not the drawing.
	_check(
		module.props.obstacles().size() == _other.props.obstacles().size(),
		"and both ends collide against the same number of circles (%d and %d)"
			% [module.props.obstacles().size(), _other.props.obstacles().size()]
	)

	# A rug: placed, drawn, and not an obstacle on either end.
	# [b]After the cooldown, and it is a real one.[/b] A budget alone does not stop a held
	# key — reach the cap, undo one, place another is a place and a free every frame,
	# which costs the server more than the props do. `spawn_interval` is dot-props' answer
	# and this is a test that would otherwise be measuring it rather than the wire.
	await _settle(int(RoomProps.PLACE_INTERVAL * RoomContent.TICK_RATE) + 10)

	_client.bridge.ask_to_place(&"rug", Vector2(-300.0, 200.0))

	var rugged := await _until(func() -> bool:
		return _other.props.count() == 2
	)

	_check(rugged, "a rug reaches the other client too")
	_check(
		_other.props.obstacles().size() == 1,
		"and is not an obstacle on either end (%d solid of %d)"
			% [_other.props.obstacles().size(), _other.props.count()]
	)

	_client.bridge.ask_to_undo()

	var undone := await _until(func() -> bool:
		return _other.props.count() == 1
	)

	_check(undone, "an undo reaches everybody, not just the person who asked")
	_check(
		module.props.count_for(mine) == 1,
		"and the budget goes back down with it (%d)" % module.props.count_for(mine)
	)
	_done()


## Voice, over the same socket, relayed by the server to the other person.
##
## [b]Headless, with no microphone anywhere.[/b] That is the point of
## [DotVoiceSource] / [DotVoiceSink] being an interface: the whole path — encode, packet,
## the router's stamping and rate cap, the wire, the jitter buffer, decode — runs with a
## buffer at each end and nothing that needs a sound card. dot-voice's own suite exists
## for that reason and this is the same claim across two processes' worth of sockets.
func _test_voice() -> void:
	_section("voice")

	var services := _module().services
	var config := RoomServices.voice_config()

	_check(
		_client.voice != null and _client.voice.manager != null,
		"a client has a voice manager even with no microphone"
	)
	_check(
		not _client.voice.available,
		"and knows it has no microphone rather than reporting a working one",
		"AudioServer reports a 44100 Hz mix rate and a Default input device in a "
		+ "headless run; only get_driver_name() says Dummy"
	)

	# A frame, built the way the capture path builds one, sent the way the client sends
	# one. The manager's own send path needs a microphone; the wire does not.
	var packet := DotVoicePacket.new()
	packet.channel = DotVoiceRouter.Channel.ALL
	packet.codec_id = config.codec_id
	packet.sample_count = config.frame_samples()
	packet.starts_talk_spurt = true
	packet.payload = DotVoiceCodec.instance_for(config.codec_id).encode(
		DotVoiceSourceBuffer.tone(440.0, config.frame_ms / 1000.0, config.sample_rate)
	)

	var before := services.voice.relayed_packets

	# [b]Several, because a jitter buffer is not a pipe.[/b] It holds `jitter_ms` worth of
	# frames before it plays any of them — three at this configuration — so one packet
	# arrives, is buffered, and is correctly played by nobody. A test that sent one and
	# then asserted somebody was speaking would be asserting that the buffer does not
	# work.
	for index in range(8):
		packet.sequence = index
		packet.starts_talk_spurt = index == 0
		_client.bridge.link.send_voice(1, packet.to_bytes())
		await _settle(2)

	var relayed := await _until(func() -> bool:
		return services.voice.relayed_packets > before
	)

	if not _check(relayed, "a frame reaches the server's router"):
		_done()
		return

	var heard := await _until(func() -> bool:
		return _other.voice.active_speakers().size() > 0
	)

	_check(heard, "and the other client hears somebody")

	# [b]An amplitude, not a frame count.[/b] A count says the packets arrived; this says
	# they decoded to something. The sink is a buffer rather than an audio device, which
	# is the only reason a headless run can ask the question at all — and is what
	# [DotVoiceSink] being an interface is for.
	_check(
		_other.voice.buffered_playback,
		"with playback buffered, because a headless run has no audio device"
	)
	_check(
		_other.voice.heard_rms(_link_peer()) > 0.0,
		"and what arrived decoded to sound rather than to silence (%.4f rms)"
			% _other.voice.heard_rms(_link_peer())
	)

	# [b]Stamped by the server, and this is what stops one client speaking as another.[/b]
	# The packet went out with speaker 0; what the listener has is the peer that actually
	# sent it.
	var speakers := _other.voice.active_speakers()
	_check(
		speakers.size() > 0 and int(speakers[0]) == _link_peer(),
		"stamped with the peer that actually sent it, not with what the packet claimed",
		"speakers: %s, sender peer: %d" % [str(speakers), _link_peer()]
	)

	# The sender does not hear themselves. dot-voice's router excludes the speaker, and a
	# client that heard its own voice back at the round-trip delay would be unusable.
	_check(
		_client.voice.active_speakers().size() == 0,
		"and the speaker does not hear themselves"
	)

	# A frame of the wrong length is refused rather than relayed. Two peers that disagree
	# about the format otherwise produce a silence nobody can explain, with the refusal
	# counted and said to nobody — which is why the format is in one file both ends read.
	var wrong := DotVoicePacket.new()
	wrong.channel = DotVoiceRouter.Channel.ALL
	wrong.codec_id = config.codec_id
	wrong.sample_count = config.frame_samples() / 2
	wrong.payload = PackedByteArray()
	wrong.payload.resize(
		DotVoiceCodec.instance_for(config.codec_id).bytes_for(wrong.sample_count)
	)

	var refused_before := services.voice.refused_format
	_client.bridge.link.send_voice(1, wrong.to_bytes())
	await _settle(20)

	_check(
		services.voice.refused_format > refused_before,
		"a frame of the wrong length is refused rather than relayed"
	)
	_done()


## Which peer the first client is, from the server's own view of it.
## [lobby-earshot-1]: the wing is a separate room acoustically as well as geometrically.
##
## [b]Here and not only in `headless_room`, because this is where the rule meets both
## routers.[/b] The geometry is checked on its own there; what only this can say is that
## dot-chat's and dot-voice's `can_hear_fn` are wired to it on a real server, so a line
## said over a real socket does not arrive at a real client on the other side of a wall.
## Before it, "near" reached 420 and the partition is 180 thick.
func _test_earshot() -> void:
	_section("out of earshot through the partition")

	var module := _module()
	var services := module.services
	var ada := module.world.occupant_for(_client.bridge.local_occupant_id)
	var grace := module.world.occupant_for(_other.bridge.local_occupant_id)

	if ada == null or grace == null:
		for what in ["range", "accepted", "wing", "hall", "same room", "voice", "voice wall"]:
			_check(false, what, "nobody to place")
		_done()
		return

	# Placed on the server, which is the only place a position decides anything. Neither
	# client is sending movement by now, so nothing walks them back.
	var place := func(who: Object, at: Vector2) -> void:
		who.get("state").position = at
		who.get("state").velocity = Vector2.ZERO

	var in_wing := Vector2(RoomContent.WALL_X - 150.0, -150.0)
	var in_hall := Vector2(RoomContent.WALL_X + 160.0, -150.0)
	place.call(ada, in_wing)
	place.call(grace, in_hall)
	await _settle(5)

	_check(
		ada.position().distance_to(grace.position()) < RoomServices.NEAR_RANGE
			and RoomContent.in_wing(ada.position())
			and not RoomContent.in_wing(grace.position()),
		"Ada in the wing and Grace in the hall are %.0f apart, inside near's %.0f"
			% [ada.position().distance_to(grace.position()), RoomServices.NEAR_RANGE]
	)

	# [b]A negative needs a marker behind it.[/b] Both lines go down one ordered
	# connection, so once the room-wide line after it has arrived, a near line that was
	# going to arrive already has.
	_client.bridge.say(RoomServices.CHANNEL_NEAR, "said in the wing")
	_client.bridge.say(RoomServices.CHANNEL_ALL, "marker after the wing")
	var marked := await _until(func() -> bool:
		return _text_heard(_other_heard, "marker after the wing")
	)
	_check(
		marked and _text_heard(_heard, "said in the wing"),
		"a near line from the wing is accepted (its speaker sees it)"
	)
	_check(
		marked and not _text_heard(_other_heard, "said in the wing"),
		"and does not reach the hall through the partition"
	)

	_other.bridge.say(RoomServices.CHANNEL_NEAR, "said in the hall")
	_other.bridge.say(RoomServices.CHANNEL_ALL, "marker after the hall")
	var marked_back := await _until(func() -> bool:
		return _text_heard(_heard, "marker after the hall")
	)
	_check(
		marked_back and not _text_heard(_heard, "said in the hall"),
		"nor does a near line from the hall reach the wing"
	)

	place.call(grace, Vector2(RoomContent.WALL_X - 150.0, 150.0))
	await _settle(5)
	_other.bridge.say(RoomServices.CHANNEL_NEAR, "said beside you")
	_check(
		await _until(func() -> bool: return _text_heard(_heard, "said beside you")),
		"but once both are in the wing, near reaches (%.0f apart)"
			% ada.position().distance_to(grace.position())
	)

	# Proximity voice, through the same function. The lobby's voice is room-wide by
	# default and a client asks for proximity per packet, which is what this sends.
	var config := RoomServices.voice_config()
	var packet := DotVoicePacket.new()
	packet.channel = DotVoiceRouter.Channel.PROXIMITY
	packet.codec_id = config.codec_id
	packet.sample_count = config.frame_samples()
	packet.payload = DotVoiceCodec.instance_for(config.codec_id).encode(
		DotVoiceSourceBuffer.tone(440.0, config.frame_ms / 1000.0, config.sample_rate)
	)
	var counts: Array[int] = []
	var speaker := _link_peer()
	var count_it := func(from: int, listeners: int) -> void:
		if from == speaker:
			counts.append(listeners)
	services.voice.speech_relayed.connect(count_it)

	packet.sequence = 100
	_client.bridge.link.send_voice(1, packet.to_bytes())
	var same := await _until(func() -> bool: return counts.size() >= 1, 5.0)
	_check(
		same and counts[0] == 1,
		"a proximity voice frame in the wing reaches the other person in it (%s)" % str(counts)
	)

	place.call(grace, in_hall)
	await _settle(5)
	packet.sequence = 101
	_client.bridge.link.send_voice(1, packet.to_bytes())
	var walled := await _until(func() -> bool: return counts.size() >= 2, 5.0)
	_check(
		walled and counts[1] == 0,
		"and one through the partition reaches nobody (%s)" % str(counts)
	)
	services.voice.speech_relayed.disconnect(count_it)
	_done()


func _link_peer() -> int:
	return _module().bridge.peer_for_occupant(_client.bridge.local_occupant_id)


func _test_leaving() -> void:
	_section("leaving")

	_other_link.disconnect_from_server("done")

	var noticed := await _until(func() -> bool:
		return _client.world.occupant_count() == 1
	)

	_check(noticed, "the first client is told the second left")
	_check(
		_module().world.occupant_count() == 1,
		"and the server's room has one person in it"
	)
	_check(
		_client.bridge.entity_count() == 1,
		"with one entity, not a ghost (%d)" % _client.bridge.entity_count()
	)
	_check(
		_server.sessions().size() == 1,
		"and one session (%d)" % _server.sessions().size()
	)
	_done()
