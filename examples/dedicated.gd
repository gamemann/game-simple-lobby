extends Node

const RoomContent := preload("../game/room_content.gd")
const RoomLink := preload("../game/room_link.gd")
const RoomModule := preload("../game/room_module.gd")
const RoomPlatform := preload("../game/room_platform.gd")
const RoomProps := preload("../game/room_props.gd")
const RoomServices := preload("../game/room_services.gd")
const RoomWorld := preload("../game/room_world.gd")

## A real [DotServer] with the room loaded into it, listening for browser clients.
##
## [codeblock]
## godot --headless --path . res://examples/dedicated.tscn            # self-test
## godot --headless --path . res://examples/dedicated.tscn -- --serve # run one
## [/codeblock]
##
## Exits non-zero on any failure.
##
## [b]The WebSocket listener is the point.[/b] A browser has no UDP and Godot's web
## template does not ship `ENetMultiplayerPeer` at all, so a server that expects browser
## clients listens on WebSocket — and then, today, *all* of its clients do.
## [member DotTransportAuto.require_web_clients] defaults to true for exactly this reason,
## and this is the deployment shape a lobby is for.
##
## It does not connect a client: `examples/sandbox.tscn` does that, over a real socket.

const PORT := 27085

## The app's URL segment on the website, which is this game's code name.
##
## Display only — a listing prints it to say which game this is, and nothing treats it as
## proof.
const APP_URL := "lobby"
const SERVER_DIR := "user://room_dedicated"

## Every check this suite runs, section counter included. See docs/testing.md.
const CHECKS := 143

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _server: DotServer = null
var _platform: RoomPlatform = null


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	var serving := "--serve" in OS.get_cmdline_user_args()

	print("game-simple-lobby dedicated server")

	var probe: Array = []
	if not (serving or _is_exit_probe()):
		probe = await _run_exit_probe()

	if not serving:
		DotPaths.remove_tree(SERVER_DIR)

	var built := await _build(serving)

	if serving:
		if built:
			print("")
			print("listening on ws://0.0.0.0:%d — ctrl-c to stop" % PORT)
			for line in _server.status_lines():
				print("  %s" % line)
		return

	if built:
		_test_world()
		_test_module()
		_test_commands()
		_test_joining()
		await _test_live_tools()
		_test_props()
		_test_services()
		_test_query()
		_test_identity()
		_test_transport()
		await _test_game_change()
		await _test_unload()
		_test_no_message_preloads_itself()

	if not probe.is_empty():
		_test_exits_clean(probe)

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
	# announced itself. See docs/testing.md. `--serve` runs no checks and never gets here.
	#
	# The copy of this suite that the exit probe runs does not run the probe itself.
	var checks := CHECKS - (EXIT_PROBE_CHECKS if _is_exit_probe() else 0)

	if _passed + _failed != checks:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, checks
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


## The server half of this game's own server browser.
##
## [b]`RoomBrowser` has existed for as long as this client has, and nothing in this
## repository could answer it.[/b] A lobby's listing row is its occupancy and the split
## between the two sides — how many people are waiting and which way they are leaning —
## and both were unreachable from outside the process.
func _test_query() -> void:
	_section("the server browser's half")

	var module := _module()

	if module == null:
		_check(false, "the module is loaded")
		_done()
		return

	_check(_server.query_source != null, "the server has a query source to contribute to")

	var snapshot := DotQuerySnapshot.new()

	for provider in module._query_providers:
		provider.call("_contribute", snapshot)

	_check(snapshot.game.has("map"), "the query names the room")
	_check(
		int(snapshot.game.get("occupants", -1)) == _world().occupant_count(),
		"the occupancy is the world's own count rather than a second tally",
		str(snapshot.game.get("occupants", -1))
	)
	_check(
		int(snapshot.game.get("capacity", 0)) == RoomContent.MAX_OCCUPANTS,
		"and it says what the room holds, so a full one reads as full"
	)
	# The side picked here is the one taken into the match, which is what this game is for.
	_check(snapshot.game.has("sides"), "and how the two sides are split")

	_done()


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
## A deadline rather than a fixed number of frames: how many frames the module needs
## depends on what else the machine is doing, and "twenty frames is surely enough" is a
## check that passes on an idle box and fails on a busy one.
func _until(condition: Callable, seconds: float = 6.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)

	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true

		await get_tree().physics_frame

	return bool(condition.call())


func _module() -> RoomModule:
	return _server.modules.get_module("room") as RoomModule


func _world() -> RoomWorld:
	return DotRegistry.get_node_service(RoomWorld.SERVICE) as RoomWorld


# --- Boot ------------------------------------------------------------------

func _build(serving: bool) -> bool:
	print("")
	print("booting")

	var config := DotServerConfig.new()
	config.hostname = "a room"
	config.port = PORT
	config.bind_address = "0.0.0.0" if serving else "127.0.0.1"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % SERVER_DIR
	config.bans_path = "%s/bans.json" % SERVER_DIR
	config.audit_log_path = "%s/audit.jsonl" % SERVER_DIR
	# A lobby is the one thing that should never hibernate: it is where people wait, and a
	# server that stops ticking when it empties stops moving the last person out of it.
	config.hibernate_when_empty = false
	# The addon ships a default `server.cfg` that the search path would find, which is
	# correct layering and would make this test assert against whatever that file says.
	config.startup_config = ""
	config.autoexec_config = ""
	# A self-test takes no commands, and its stdin is whatever the runner left open. The
	# console's reader thread blocks in `read_string_from_stdin`, which nothing can wake,
	# and on an open pipe that never closes — `sleep 60 | godot ...`, or a CI step — the
	# process printed its whole result and then never exited. A tty and /dev/null both
	# exit, which is why it only showed once the suite ran long enough for the reader to
	# be blocked by the time it quit. `--serve` keeps it, because that one is a server.
	config.stdin_console_enabled = serving
	# The query listeners. A lobby is the server in this family a person is most likely to
	# be choosing off a list, and this game has shipped `RoomBrowser` against a server that
	# answered nothing at all.
	config.query_enabled = true
	config.query_port = PORT + 1

	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	add_child(_server)

	# Answering a query is its own addon, and a server only answers if a host is plugged
	# in. Added before boot() so the listener opens with everything else.
	var query_host := DotQueryHost.new()
	query_host.name = "QueryHost"
	query_host.app_url = APP_URL
	query_host.server_ref = DotNodeRef.of_path(NodePath("../Server"))
	add_child(query_host)

	var booted: DotResult = await _server.boot()

	if not _check(booted.ok, "the server boots and listens on %d" % PORT, str(booted.error)):
		return false

	_server.games.add_game(RoomModule.game_descriptor())

	var loaded: DotResult = await _server.games.change_game(RoomModule.GAME_ID, "boot")

	if not _check(loaded.ok, "the room's scene loads", str(loaded.error)):
		return false

	# [b]The identity half, before the modules.[/b] [DotPlatformModule] refuses to load
	# without a [DotPlatformHub] in the registry, and building the hub is awaited work —
	# which is why it is here, in the application, rather than inside a module's
	# `_module_load`, which dot-server's module host does not await.
	_platform = RoomPlatform.new()
	_platform.name = "Identity"
	_platform.directory = "%s/identity" % SERVER_DIR
	add_child(_platform)

	var identity: DotResult = await _platform.setup()

	if not _check(identity.ok, "profiles and avatars are up", str(identity.error)):
		return false

	var platform: DotResult = await _server.modules.load_module(
		"res://addons/dot_platform/dot_platform_module.gd"
	)

	if not _check(platform.ok, "the platform module loads", str(platform.error)):
		return false

	# Into this run's own directory, which is deleted on the way in and out. The default
	# is the store a `--serve` of this same scene enforces, and a self-test gag written
	# there is a real record against a real (if made-up) uid.
	if not serving:
		RoomModule.punishments_path = "%s/punishments.json" % SERVER_DIR

	var module: DotResult = await _server.modules.load_module(
		"res://game/room_module.gd"
	)
	return _check(module.ok, "and the module loads into it", str(module.error))


func _teardown() -> void:
	if _server == null or not is_instance_valid(_server):
		return

	_server.shutdown("test over")
	remove_child(_server)

	# Freed rather than queued. A `queue_free` on the last line before `quit()` is a free
	# that never happens: the deferred call is dropped with the tree, and every node under
	# it is reported as leaked at exit — which is true, and says nothing about a cycle.
	_server.free()


# --- Sections --------------------------------------------------------------

func _test_world() -> void:
	_section("the room")

	var world := _world()

	_check(world != null, "the game scene registered one")

	if world == null:
		_done()
		return

	_check(world.is_authority, "and it is the authority")
	_check(world.occupant_count() == 0, "with nobody in it yet")
	_check(
		world.arena.bounds.size.is_equal_approx(RoomContent.ROOM_EXTENT * 2.0),
		"at the size RoomContent says"
	)
	_done()


func _test_module() -> void:
	_section("the module")

	_check(_server.modules.has_module("room"), "is listed among the server's modules")

	var module := _module()
	_check(module != null and module.world == _world(), "and holds the room")
	_check(module != null and module.net != null, "with a netcode manager of its own")
	_check(
		module != null and module.net != null and module.net.is_server,
		"which is the authority"
	)
	_check(
		module != null and module.bridge != null and module.bridge.link != null,
		"and a link where RPCs will find it"
	)
	_check(
		module != null and module.bridge != null
			and module.bridge.link.name == RoomLink.NODE_NAME,
		"named %s, because the name is the routing" % RoomLink.NODE_NAME
	)
	_check(
		module != null and module.bridge != null
			and module.bridge.link.get_parent() == _server,
		"under the server, which the client's half calls by the same name"
	)

	for command in ["room_status", "room_who", "room_net"]:
		_check(
			_server.console.find_command(command) != null, "registered %s" % command
		)

	_check(
		_server.games.find_game(RoomModule.GAME_ID) != null,
		"and its game descriptor is registered, so changelevel can reach it"
	)
	_done()


func _test_commands() -> void:
	_section("its commands")

	for command in ["room_status", "room_who", "room_net"]:
		_check(_server.console.execute(command).ok, "%s runs" % command)

	# A punishment's length. `arg_int` answered every non-integer with 0, and 0 is
	# permanent: `room_gag ada 10m` gagged somebody for ever, against a uid that outlives
	# their session on purpose.
	var lengths := {
		"90": 90, "0": 0, "10m": 600, "2h": 7200, "perm": 0,
		"10x": -1, "spamming": -1, "-5": -1,
	}

	for typed: String in lengths:
		var got := RoomModule.parse_seconds(typed)
		_check(
			got == int(lengths[typed]),
			"a punishment typed as '%s' lasts %d (%d)" % [typed, int(lengths[typed]), got]
		)

	var said := _command_output("room_gag nobody spamming")
	_check(
		said.size() == 1 and said[0].contains("is not a length"),
		"and a length that is not one is refused before anybody is looked up",
		" / ".join(said)
	)

	_done()


## What a console command said, line by line.
##
## [b]Read, rather than trusting `execute(...).ok`.[/b] A handler that dies on a freed
## object still leaves the console reporting success — the game-change section below had
## `room_status` pass while the engine printed a SCRIPT ERROR from inside it.
func _command_output(line: String) -> PackedStringArray:
	var ctx := DotCmdContext.console("", PackedStringArray())
	var lines := PackedStringArray()
	ctx.reply_sink = func(text: String) -> void: lines.append(text)
	_server.console.execute(line, ctx)
	return lines


## Membership, through the bridge rather than through a socket.
##
## [b]The admission path itself is not faked here.[/b] dot-server's session table is
## private, deliberately, so a test that reached into it would be testing a table it had
## filled in itself — and the two bugs this family has had in exactly this place were both
## about which key the *event* carries. Only a real client can show that, and
## `examples/sandbox.tscn` is where one connects.
##
## What this covers is everything downstream of admission, which is the part a socket
## would only slow down.
## dot-moderation's live tools in a lobby: moving people, renaming them and the three
## movement modifiers work, and everything else is refused with the lobby's reason.
func _test_live_tools() -> void:
	_section("the moderator's live tools")

	var module := _module()
	_check(
		_server.console.find_command("send") != null and _server.console.find_command("slay") != null,
		"the live tools' commands are on the console"
	)

	var sessions: Array[DotClientSession] = []
	for entry in [[52, 5252, "Bea"], [53, 5353, "Cy"]]:
		var session := DotClientSession.new()
		session.peer_id = int(entry[0])
		session.userid = int(entry[1])
		session.display_name = str(entry[2])
		var _adopted := _server.adopt_session(session)
		var _in := module.bridge.add_occupant(session.peer_id, session.userid, session.display_name)
		sessions.append(session)

	var bea := _world().occupant_for(5252)
	var cy := _world().occupant_for(5353)
	# On open floor. (100, 100) was inside the island, so whether `return` read back exactly
	# depended on whether a room tick — which pushes her out of it — landed inside the two
	# frames `_live` waits: it failed on two runs in three.
	bea.state.position = Vector2(250.0, -250.0)
	cy.state.position = Vector2(600.0, 400.0)

	var _sent := await _live("send Bea Cy")
	_check(
		bea.state.position.distance_to(cy.state.position) < 60.0
			and bea.state.position.distance_to(cy.state.position) > 1.0,
		"`send Bea Cy` puts Bea beside Cy, not on top of them",
		"%.1f px apart" % bea.state.position.distance_to(cy.state.position)
	)

	var _back := await _live("return Bea")
	_check(bea.state.position.is_equal_approx(Vector2(250.0, -250.0)),
		"and `return Bea` puts her back exactly", str(bea.state.position))

	var _renamed := await _live("rename Bea Beatrice")
	_check(bea.display_name == "Beatrice", "`rename` reaches the roster")

	# Noclip, freeze and speed are dot-2d's admin modifiers, in the occupant's replicated
	# state; `headless_net` measures that the owning client predicts them.
	var clipped := await _live("noclip Cy")
	_check(Dot2DAdminModifiers.is_noclipped(cy.state), "`noclip Cy` reaches Cy's state", " | ".join(clipped))
	var held := await _live("freeze Cy")
	_check(Dot2DAdminModifiers.is_frozen(cy.state) and cy.state.velocity == Vector2.ZERO,
		"`freeze Cy` holds her still", " | ".join(held))
	var quick := await _live("speed Cy 1.4")
	_check(is_equal_approx(Dot2DAdminModifiers.speed_of(cy.state), 1.5) and " ".join(quick).contains("1.5×"),
		"`speed Cy 1.4` lands on the 1.5x step, and says so", " | ".join(quick))
	var _clear := await _live("noclip Cy off")
	var _thaw := await _live("unfreeze Cy")
	var _normal := await _live("speed Cy 1")
	_check(cy.state.admin == 0, "and all three come off again", str(Dot2DAdminModifiers.words(cy.state.admin)))

	# The two that are about a screen: a flag each on the occupant, on the entity the
	# netcode sends. Who RECEIVES them is `headless_net`'s, and what they look like is
	# `tools/screenshot.sh --admin`'s.
	var dark := await _live("blind Cy")
	_check(cy.blinded, "`blind Cy` blacks her screen out", " | ".join(dark))
	await get_tree().physics_frame
	await get_tree().physics_frame
	var cy_net := module.bridge.behaviour_for(5353)
	_check(cy_net != null and cy_net.net_blind, "and it is on the entity the netcode sends her")
	var _lift := await _live("blind Cy off")
	_check(not cy.blinded, "`blind Cy off` lifts it")
	# A blind is a spell. dot-moderation lifts it through the same handler when the time
	# is up, so what is checked is the flag, not the timer.
	var _spell := await _live("blind Cy 0.2")
	_check(cy.blinded, "`blind Cy 0.2` blinds her for a fifth of a second")
	await get_tree().create_timer(0.4).timeout
	_check(not cy.blinded, "and it lifts on its own when the time is up")
	var lit := await _live("beacon Cy")
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(
		cy.beacon and cy_net != null and cy_net.net_beacon,
		"`beacon Cy` rings her, on the entity everybody is sent", " | ".join(lit)
	)
	var listed := " | ".join(await _live("modtools"))
	_check(
		listed.contains("blind") and listed.contains("beacon")
			and not listed.contains("draws no"),
		"and `modtools` lists both as supported, not refused", listed
	)
	var _unlit := await _live("beacon Cy off")
	_check(
		not cy.beacon and not module.mod_tools.is_active(&"5353", DotModTools.ACTION_BEACON)
			and not module.mod_tools.is_active(&"5353", DotModTools.ACTION_BLIND),
		"`beacon Cy off` puts it out, and the tools' record agrees with the room"
	)

	var slay := await _live("slay Cy")
	_check(" ".join(slay).contains("nobody can be hurt"),
		"`slay` is refused with the lobby's reason", " | ".join(slay))

	for session in sessions:
		module.bridge.remove_peer(session.peer_id)
		var _released := _server.release_session(session.peer_id)
	_done()


func _live(line: String) -> PackedStringArray:
	var captured: Array[String] = []
	var context := DotCmdContext.console("", PackedStringArray())
	context.reply_sink = func(text: String) -> void: captured.append(text)
	_server.console.execute(line, context)
	await get_tree().process_frame
	await get_tree().process_frame
	return PackedStringArray(captured)


func _test_joining() -> void:
	_section("membership")

	var module := _module()
	var added := module.bridge.add_occupant(9, 4242, "Ada")

	_check(added.ok, "the bridge puts somebody in the room", str(added.error))
	_check(_world().occupant_count() == 1, "and the room has one person in it")

	var occupant := _world().occupant_for(4242)
	_check(
		occupant != null,
		"under their session id, not their peer id",
		"a peer id is reassigned on reconnect and the next person would inherit their place"
	)
	_check(
		occupant != null and occupant.display_name == "Ada",
		"with the name they were admitted under"
	)
	_check(
		module.bridge.peer_for_occupant(4242) == 9,
		"and the bridge knows which peer they are (%d)"
			% module.bridge.peer_for_occupant(4242)
	)

	var behaviour := module.bridge.behaviour_for(4242)
	_check(
		behaviour != null and behaviour.identity != null
			and behaviour.identity.owner_peer_id == 9,
		"their entity is owned by that peer",
		"an entity owned by peer 0 replicates perfectly and never receives an input, so "
		+ "the player moves on their own screen and nowhere else"
	)
	_check(
		behaviour != null and behaviour.identity != null
			and behaviour.identity.always_relevant,
		"and is always relevant, because a lobby is smaller than a screen"
	)

	# The bubble comes off [DotChatRouter], and the route to it is what this checks:
	# `submit` applies every rule, `message_accepted` fires, and the module puts the text
	# over the speaker's head. dot-server's own `player_chat` is cancelled by this module,
	# so firing that event is now a check that it is cancelled rather than a way in.
	var said := module.services.chat.submit(9, RoomServices.CHANNEL_ALL, "hello")
	_check(said.ok, "a line is accepted by the chat router", str(said.error))
	_check(
		occupant != null and occupant.bubble_text == "hello",
		"and reaches the person who said it, over their own head"
	)

	# dot-server's own chat path is CANCELLED by this module rather than left running
	# beside the router. Two paths would be two sets of rules to keep in step, and the one
	# that skipped the filter would be the one that leaked admin chat — so the check is
	# that firing dot-server's event does not produce a second delivery.
	var legacy := _server.events.fire("player_chat", {
		"userid": 4242, "name": "Ada", "text": "again", "team_only": false,
	})
	_check(
		legacy.cancelled,
		"dot-server's own chat broadcast is cancelled, so there is exactly one path"
	)

	# And the module survives one for somebody who is not here, which is every system
	# message and every line said between a disconnect and the world noticing.
	_server.events.fire("player_chat", {
		"userid": 999999, "name": "Ghost", "text": "boo", "team_only": false,
	})
	_check(true, "and a line from somebody who is not in the room is ignored")

	module.bridge.remove_peer(9)
	_check(_world().occupant_count() == 0, "removing the peer empties the room")
	_check(
		module.bridge.behaviour_for(4242) == null,
		"and takes their entity, not merely their name"
	)
	_done()


## What people put in the room, and the budget that stops one person filling it.
func _test_props() -> void:
	_section("props")

	var module := _module()
	var props := module.props

	_check(props != null and props.authoritative, "the server holds the prop layer")
	_check(
		props.spawner != null and props.spawner.catalogue.size() == 8,
		"with eight things in the catalogue (%d)"
			% (props.spawner.catalogue.size() if props.spawner != null else -1)
	)

	# [b]The wire index has to be stable, and it is sorted as String rather than as
	# StringName.[/b] `Array.sort()` on a StringName compares interned pointers, so two
	# peers give the same thing two different indices and hash two different worlds —
	# dot-net shipped exactly that with message ids and only a browser client could see
	# it, because every suite in this family runs both ends in one intern table.
	var ids := RoomProps.wire_ids()
	var sorted := ids.duplicate()
	sorted.sort()
	_check(
		Array(ids) == Array(sorted),
		"the wire order is lexicographic, not interned-pointer order"
	)
	_check(
		RoomProps.id_at(RoomProps.index_of(&"bench")) == &"bench",
		"an id round-trips through its wire index"
	)

	var placed := props.place(4242, &"bench", Vector2(100.0, 60.0))

	_check(placed.ok, "a bench goes down", str(placed.error))
	_check(props.count() == 1, "and the room has one thing in it")
	_check(
		props.obstacles().size() == 1,
		"which is an obstacle both ends resolve against"
	)

	# A rug is a prop and is not an obstacle. The field is read rather than assumed:
	# dot-props' own sweep found `per_player_frozen` and `size` declared and read by
	# nothing, which is this family's most repeated bug.
	props.spawner.limits.spawn_interval = 0.0
	var rug := props.place(4242, &"rug", Vector2(-200.0, 0.0))

	_check(rug.ok, "a rug goes down too", str(rug.error))
	_check(
		props.obstacles().size() == 1,
		"and is NOT an obstacle (%d solid of %d placed)"
			% [props.obstacles().size(), props.count()],
		"a rug you could not stand on is not a rug"
	)

	# Placed inside the island, which is at the origin with a radius of 150. The
	# placement is RESOLVED rather than refused: a player aiming at a landmark meant
	# "next to the landmark", and refusing gives them a button that silently does
	# nothing near half the room.
	var inside := props.place(4242, &"stool", Vector2.ZERO)
	_check(inside.ok, "something aimed at a pillar is placed rather than refused")

	var moved: Vector2 = props.placements()[int(inside.value)]["at"]
	_check(
		moved.length() >= 150.0,
		"and comes out beside it rather than inside it (%.0f units from the centre)"
			% moved.length()
	)

	# The budget. Placed as somebody else so this player's three do not count against it.
	var refused := 0

	for index in range(RoomProps.PER_PLAYER + 4):
		if not props.place(7777, &"stool", Vector2(400.0, float(index) * 10.0)).ok:
			refused += 1

	_check(refused > 0, "a per-player budget refuses the rest (%d refused)" % refused)
	_check(
		props.count_for(7777) <= RoomProps.PER_PLAYER,
		"and nobody holds more than it (%d of %d)"
			% [props.count_for(7777), RoomProps.PER_PLAYER]
	)

	_check(props.undo(4242), "undo takes back the newest one")

	var cleared := props.clear_owner(7777)
	_check(cleared > 0, "and a leave clears everything that person put down (%d)" % cleared)
	_check(
		props.count_for(7777) == 0,
		"leaving them holding nothing against their budget"
	)

	props.clear_all()
	_check(props.count() == 0, "an admin clear empties the room")
	_done()


## Chat, voice and moderation, and the one join between them that has to work.
func _test_services() -> void:
	_section("chat, voice and moderation")

	var services := _module().services

	_check(services != null, "the services are up")
	_check(
		services.chat != null and services.chat.channel_ids().size() == 4,
		"with four chat channels (%d)"
			% (services.chat.channel_ids().size() if services.chat != null else -1)
	)
	_check(
		services.chat.channel(RoomServices.CHANNEL_NEAR).scope
			== DotChatChannel.Scope.RADIUS,
		"one of which is a radius rather than a room"
	)
	_check(
		services.chat.channel(RoomServices.CHANNEL_NEAR).backlog == 0,
		"and has no backlog, because a line said quietly must not be replayed to a "
		+ "stranger who was not standing there"
	)

	# [b]THE join.[/b] dot-chat consults a `dot_mute_source` and dot-moderation publishes
	# one, and neither imports the other — so the only thing that makes a gag work is
	# that something is registered under that name. dot-moderation exists because
	# dot-server's mute is two booleans on a session object and a session dies with its
	# connection; a gag that did not survive a reconnect would be the one thing the addon
	# is for not working.
	_check(
		DotRegistry.has(DotModerationManager.MUTE_SERVICE),
		"a mute source is registered, which is the only thing that makes a gag work"
	)
	_check(
		DotRegistry.has(DotModerationManager.BAN_SERVICE),
		"and a ban source, which dot-server's admission check consults"
	)

	_check(
		services.punishments_path.begins_with(SERVER_DIR),
		"into this run's own store, not the one a real server enforces (%s)"
			% services.punishments_path
	)

	var gagged: DotResult = await services.moderation.issue(
		DotPunishment.Kind.GAG, DotPunishmentSubject.for_uid("uid-test"),
		"testing", "console", 60
	)
	_check(gagged.ok, "a gag is issued and stored", str(gagged.error))

	# Round-tripped through the store, because the two ends of a serialisation are
	# exactly as capable of never meeting as the two ends of a wire — dot-moderation
	# shipped a voice mute that loaded back as a warning, which enforces nothing.
	var reloaded := DotModerationManager.new()
	reloaded.store = DotPunishmentStoreFile.new(services.punishments_path)
	reloaded.register_mute_source = false
	reloaded.register_ban_source = false
	add_child(reloaded)
	reloaded.load_all()

	var found := reloaded.active_of_kind(
		DotPunishmentSubject.for_uid("uid-test"), DotPunishment.Kind.GAG
	)
	_check(
		found != null and found.kind == DotPunishment.Kind.GAG,
		"and comes back off disk as a GAG rather than as a WARN",
		"the kind is written and read through one table for exactly this reason"
	)
	reloaded.queue_free()

	# Voice. The format is what both ends have to agree on and neither can measure.
	_check(services.voice != null, "the voice router is up")
	_check(
		services.voice.config.format_fingerprint()
			== RoomServices.voice_config().format_fingerprint(),
		"and its format is the one a client builds from the same file"
	)

	var packet := DotVoicePacket.new()
	packet.speaker = 999
	packet.channel = DotVoiceRouter.Channel.ALL
	packet.codec_id = &"adpcm"
	packet.sample_count = services.voice.config.frame_samples()
	packet.payload = PackedByteArray()
	packet.payload.resize(
		DotVoiceCodec.instance_for(&"adpcm").bytes_for(packet.sample_count)
	)

	var relayed: DotResult = services.voice.relay(9, packet.to_bytes())
	_check(relayed.ok, "a frame relays", str(relayed.error))

	# [b]Stamped, not trusted.[/b] The packet claimed to be speaker 999; whoever sent it
	# was peer 9. Without this any client can put words in any other player's mouth and
	# the only symptom is confusion.
	_check(
		services.voice.relayed_packets == 1,
		"and the router counted it rather than refusing the format"
	)
	_done()


## Profiles and avatars: ids and a schema, and no art anywhere.
func _test_identity() -> void:
	_section("identity")

	_check(_platform.hub != null and _platform.hub.is_ready(), "the platform is up")
	_check(
		_server.modules.get_module("platform") != null,
		"and its module is loaded beside the room's"
	)

	var schema := RoomContent.avatar_schema()
	var problems := schema.validate_schema()

	# [b]A schema that validates is not a formality.[/b] game-hungario shipped a part
	# that was its own fallback — a resolution loop that cannot terminate — and its suite
	# never noticed, because it never validated a schema.
	_check(problems.ok, "the avatar schema is valid", str(problems.error))

	var legal := DotAvatar.make(&"room_person")
	legal.set_part(&"face", &"face_wide")
	legal.set_part(&"hat", &"hat_cap")

	var checked := schema.validate(legal, DotAvatarEntitlements.none())
	_check(checked.ok, "a free avatar is accepted with no entitlements at all")

	var locked := DotAvatar.make(&"room_person")
	locked.set_part(&"face", &"face_plain")
	locked.set_part(&"hat", &"hat_crown")

	# [b]Entitlements default to nothing and that default is the important one.[/b] A
	# server that granted everything would work perfectly in every test, ship, and
	# quietly be a game where every unlock is free — and nobody reports that as a bug.
	_check(
		not schema.validate(locked, DotAvatarEntitlements.none()).ok,
		"and one nobody has unlocked is refused"
	)
	_check(
		schema.validate(locked, DotAvatarEntitlements.of([&"hat_crown"])).ok,
		"until they hold it"
	)

	# The whole point of the document: a server decides all of that without loading
	# anything. If this ever needs a `load()`, that is the thing to push back on.
	var drawn := RoomContent.default_avatar(4242)
	_check(
		drawn.filled_slots().size() > 0,
		"a person with no stored avatar still has one, derived from their id"
	)
	_check(
		RoomContent.default_avatar(4242).digest()
			== RoomContent.default_avatar(4242).digest(),
		"and it is the same on every machine, which is why a default is worth having"
	)
	_done()


## A browser client needs a WebSocket listener, and dot-core has to be able to make one on
## this build.
##
## Checked through [DotTransportWebSocket] rather than by booting a second server: what can
## go wrong is that the engine build has no WebSocket peer, and that is a property of the
## binary rather than of the configuration.
func _test_transport() -> void:
	_section("browser clients")

	var transport := DotTransportWebSocket.new()
	_check(transport != null, "dot-core can build a WebSocket transport")
	_check(
		transport.supports_web_clients(),
		"which is the one that browser clients can reach"
	)

	var available := transport._is_available()
	_check(
		available.ok,
		"and this engine build has the peer it needs",
		"a build without it cannot serve browser clients at all: %s" % str(available.error)
	)

	# The constraint that shapes the whole deployment: a browser cannot listen, so the web
	# build is a client and the server is somewhere else.
	_check(
		not DotPlatform.is_web(),
		"and this process can listen, because it is not a browser"
	)
	_done()


## A game change under a loaded module: the scene goes, the module and the people stay.
##
## [b]The module is written to outlive the world and nothing ever moved it onto the next
## one.[/b] [method RoomBridge.rebind] existed, was documented as what a game change does,
## and had no caller — [DotModuleHost] calls `_module_game_changed` and this module did not
## override it. So after any `changegame` on a server that keeps its modules loaded, the
## module held the freed world: [method RoomBridge.live_world] answered null, the tick
## returned early forever, and the room froze with everybody in it. The next person to
## connect reached `add_occupant` on the freed world.
##
## The same scene under a second id is the change: dot-server refuses to change to the
## game that is already running, and a second descriptor is what an operator with two
## rooms has anyway.
func _test_game_change() -> void:
	_section("a game change")

	var module := _module()
	var before := _world()
	var again := RoomModule.game_descriptor()
	again.game_id = "simple_lobby_again"
	_server.games.add_game(again)

	var added := module.bridge.add_occupant(31, 5151, "Grace")
	_check(added.ok, "somebody is in the room before it changes", str(added.error))

	module.props.spawner.limits.spawn_interval = 0.0
	var bench := module.props.place(5151, &"bench", Vector2(300.0, 200.0))
	_check(bench.ok, "and has put a bench down", str(bench.error))

	# A moderator's marks on her, across the change. A lobby has no respawn and this is its
	# "new body": `rebind` re-adds everybody, and `RoomModule._carry_mod_tools` tells the
	# tools so. Blind and beacon are about the person and carry; noclip is about the body.
	var tools := module.mod_tools
	var _blind: DotResult = await tools.toggle(&"", &"5151", DotModTools.ACTION_BLIND, true)
	var _beacon: DotResult = await tools.toggle(&"", &"5151", DotModTools.ACTION_BEACON, true)
	var _clip: DotResult = await tools.toggle(&"", &"5151", DotModTools.ACTION_NOCLIP, true)
	_check(
		tools.is_active(&"5151", DotModTools.ACTION_BLIND)
			and tools.is_active(&"5151", DotModTools.ACTION_NOCLIP),
		"and is blinded, beaconed and noclipped"
	)
	# And has been moved once, so `return` has somewhere to put her — a position in THIS
	# room, which the change is about to free.
	var _moved: DotResult = await tools.teleport(&"", &"5151", Vector2(-200.0, 150.0))
	_check(tools.can_return(&"5151"), "and has been moved, so `return` has somewhere to put her")

	var changed: DotResult = await _server.games.change_game(again.game_id, "test")
	_check(changed.ok, "the game changes", str(changed.error))

	# One physics frame so the module's own tick runs against whatever it now holds.
	await get_tree().physics_frame
	await get_tree().physics_frame

	var after := _world()
	_check(
		after != null and after != before,
		"to a new world, because the scene was replaced"
	)
	_check(
		module.world == after,
		"and the module holds the new world rather than the freed one"
	)
	_check(
		module.bridge.live_world() == after,
		"and so does the bridge, so the room still ticks",
		"a bridge left on the freed world returns early from every tick"
	)

	var tick_was := after.current_tick() if after != null else -1
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(
		after != null and after.current_tick() > tick_was,
		"and it does tick (%d -> %d)"
			% [tick_was, after.current_tick() if after != null else -1]
	)

	var grace := after.occupant_for(5151) if after != null else null
	_check(grace != null, "the person in the room is in the new one too")
	_check(
		grace != null and grace.display_name == "Grace",
		"under their own name rather than a placeholder (%s)"
			% (grace.display_name if grace != null else "-")
	)
	_check(
		module.bridge.behaviour_for(5151) != null,
		"and is a replicated entity again"
	)
	_check(
		after != null and after.props == module.props,
		"the new world collides against the props the module kept"
	)
	_check(
		module.props.count_for(5151) == 1,
		"and the bench outlived the change (%d)" % module.props.count_for(5151)
	)

	_check(
		grace != null and grace.blinded and grace.beacon,
		"and is still blinded and beaconed, which are about her rather than the room"
	)
	_check(
		grace != null and not Dot2DAdminModifiers.is_noclipped(grace.state)
			and not tools.is_active(&"5151", DotModTools.ACTION_NOCLIP),
		"while the noclip ended with the old room, and the tools' record says so",
		"a record that still listed it would be `modtools Grace` describing a body that is gone"
	)
	var returned: DotResult = await tools.return_player(&"", &"5151")
	_check(
		not tools.can_return(&"5151") and not returned.ok,
		"and `return` has nowhere to put her, rather than a spot in the room that is gone",
		"it put her at %s, a position from the previous room" % str(returned.value) if returned.ok else ""
	)
	var _dark_off: DotResult = await tools.toggle(&"", &"5151", DotModTools.ACTION_BLIND, false)
	var _unlit: DotResult = await tools.toggle(&"", &"5151", DotModTools.ACTION_BEACON, false)

	var later := module.props.place(5151, &"stool", Vector2(-300.0, 200.0))
	_check(later.ok, "a prop can be placed in the new world", str(later.error))
	var status := _command_output("room_status")
	_check(
		status.size() > 0 and status[0].begins_with("room"),
		"and room_status describes it",
		" / ".join(status)
	)

	module.props.clear_owner(5151)
	module.bridge.remove_peer(31)
	_check(
		after != null and after.occupant_count() == 0,
		"and leaving empties the new room, not the old one"
	)

	# A game with no room in it: the module goes idle rather than holding a freed world.
	# A real scene rather than a scene-less descriptor, because dot-server frees the
	# running scene before it finds out a descriptor has none to load, and then never
	# announces the change at all — see the report on dot-server, not this game.
	var elsewhere := DotGameDescriptor.new()
	elsewhere.game_id = "not_a_room"
	elsewhere.scene = "res://fixtures/not_a_room.tscn"
	_server.games.add_game(elsewhere)

	var left: DotResult = await _server.games.change_game(elsewhere.game_id, "test")
	_check(left.ok, "the server changes to a game that is not a room", str(left.error))
	await get_tree().physics_frame

	_check(module.world == null, "and the module lets go of the world")
	var idle := _command_output("room_status")
	_check(
		idle.size() == 1 and idle[0].contains("no room"),
		"and room_status says there is no room rather than reading a freed one",
		" / ".join(idle)
	)

	var back: DotResult = await _server.games.change_game(RoomModule.GAME_ID, "test")
	_check(back.ok, "and changes back", str(back.error))
	await get_tree().physics_frame
	_check(
		module.world != null and module.world == _world()
			and module.bridge.live_world() == module.world,
		"and the module is holding the room again"
	)
	_done()


func _test_unload() -> void:
	_section("unloading")

	_check(_server.modules.unload_module("room").ok, "the module unloads")
	_check(
		_server.console.find_command("room_status") == null,
		"and takes its commands with it",
		"a handler left behind points at a freed object and the console calls it"
	)
	_check(
		(await _server.modules.load_module("res://game/room_module.gd")).ok,
		"and loads again cleanly"
	)
	_done()


## [b]The one line that leaked mg-buses-from-hell's whole script graph at exit.[/b]
##
## A script that `extends DotNetMessage` and preloads ITSELF, first loaded from a module a
## running [DotServer] loads — which is how every deployed server loads this game — leaves
## every loaded script alive at exit on Godot 4.7.2 (measured in mg-buses-from-hell,
## 8ed866c). This game's event and request both did it, for a typed `of()` factory.
##
## [b]Asserted on the source, because the symptom is where no check can reach.[/b] The
## leak is reported after `quit()`, by the engine, as warnings a CI filter already treats
## as noise; an assertion here runs before any of it exists. So this checks the cause
## instead: every message script in `game/`, read as text.
func _test_no_message_preloads_itself() -> void:
	_section("exiting clean")

	var messages := PackedStringArray()
	var offenders := PackedStringArray()
	var pending: Array[String] = ["res://game"]

	while not pending.is_empty():
		var dir_path: String = pending.pop_back()

		for sub in DirAccess.get_directories_at(dir_path):
			pending.append(dir_path.path_join(sub))

		for file in DirAccess.get_files_at(dir_path):
			if not file.ends_with(".gd"):
				continue

			var path := dir_path.path_join(file)
			var source := FileAccess.get_file_as_string(path)

			if not _extends_message(source):
				continue

			messages.append(path)

			if source.contains('preload("%s")' % file) or source.contains('preload("%s")' % path):
				offenders.append(path)

	_check(
		messages.size() >= 2,
		"this game's message scripts are found, so the next check is about something",
		", ".join(messages)
	)
	_check(
		offenders.is_empty(),
		"and none of them preloads itself, which leaks every script at exit",
		", ".join(offenders)
	)

	_done()


func _extends_message(source: String) -> bool:
	for line in source.split("\n"):
		if line.begins_with("extends "):
			return line.contains("DotNetMessage") or line.contains("dot_net_message.gd")
	return false


# --- Exiting clean ----------------------------------------------------------------

## The flag this suite hands the copy of itself it runs. See [method _run_exit_probe].
const EXIT_PROBE_FLAG := "--exit-probe"

## What the exit probe adds to a run — one section, these checks — and the copy does not.
const EXIT_PROBE_CHECKS := 3


## How long the copy may run before it is killed and this probe fails. A copy that is still
## running this long after it started is hung, and the likeliest reason is the one that says
## nothing at all: a scene whose script failed to parse never reaches `quit()` and prints
## nothing. `-- --exit-probe-seconds N` lowers it, which is how the deadline itself is armed —
## any N shorter than the suite takes is a copy that is still running when it expires.
const EXIT_PROBE_SECONDS := 300


func _is_exit_probe() -> bool:
	return EXIT_PROBE_FLAG in OS.get_cmdline_user_args()


func _exit_probe_seconds() -> int:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--exit-probe-seconds")
	if at >= 0 and at + 1 < args.size() and args[at + 1].is_valid_int():
		return maxi(1, args[at + 1].to_int())
	return EXIT_PROBE_SECONDS


## Runs this same suite in a fresh process: `[exit code, its stdout, its stderr, whether it
## had to be killed, the seconds it was allowed]`.
##
## [b]A leak is reported after `quit()`, by the engine, where nothing in the process that
## leaked can read it.[/b] "N ObjectDB instances were leaked at exit" is printed once the
## scene tree is gone, so the only process that can check a run's exit is another one. On
## Godot 4.7.2 a script that names itself, loaded after its base, cuts the engine's exit
## teardown short and every script loaded before it is reported leaked — hundreds of lines
## a passing run printed for weeks, which is why this is a check now and not a warning.
##
## [b]First, before this run opens a port[/b], so the two never contend for a socket — and
## so this run is always the second one against the same `user://`, which is the other
## thing no single run can see.
##
## [b]Not `OS.execute`.[/b] That blocks until the copy exits, so a copy that hangs held this
## run for ever; and when the outer `timeout` then killed this run, the copy was left behind
## holding the suite's directory and port. So the copy is started, polled against a deadline
## and killed at it. Two deadlines, because Godot dies on SIGTERM without running a line of
## script — nothing in this process can clean up after it is killed:
##
## - coreutils `timeout` wraps the copy where it exists. It is an exec wrapper, not a shell,
##   and it outlives this process, so a copy orphaned by the outer `timeout` still dies on
##   time. Its exit status 124 is how its expiry is recognised.
## - this loop's own deadline, a little later, for a platform without it.
##
## `execute_with_pipe` rather than `create_process`, because the latter captures nothing and
## the whole point is reading what the copy printed. Non-blocking, and drained on every pass
## rather than once at the end: a pipe holds 64 KiB, and a copy that fills it blocks on its
## next print — a hang this probe would then report as the suite's own. The copy's stdin is
## the other end of a pipe this process holds open, which is why every suite turns the
## server's stdin console off: a reader blocked on it never lets the copy exit.
func _run_exit_probe() -> Array:
	var seconds := _exit_probe_seconds()
	print("(running this suite once more in a fresh process, to read what it leaves at exit — %d s allowed)" % seconds)
	var scene := scene_file_path if scene_file_path != "" else "res://examples/dedicated.tscn"
	var exe := OS.get_executable_path()
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		scene, "--", EXIT_PROBE_FLAG,
	])
	var wrapped := false
	for wrapper: String in ["/usr/bin/timeout", "/bin/timeout"]:
		if FileAccess.file_exists(wrapper):
			var outer := PackedStringArray(["--kill-after=10", str(seconds), exe])
			outer.append_array(args)
			exe = wrapper
			args = outer
			wrapped = true
			break

	var proc := OS.execute_with_pipe(exe, args, false)
	if proc.is_empty():
		return [-1, "", "could not start %s" % exe, false, seconds]
	var pid: int = proc["pid"]
	var pipes: Array[FileAccess] = [proc["stdio"], proc["stderr"]]
	var bytes: Array[PackedByteArray] = [PackedByteArray(), PackedByteArray()]
	var deadline := Time.get_ticks_msec() + (seconds + 30) * 1000
	var hung := false
	while OS.is_process_running(pid):
		_drain_exit_probe(pipes, bytes)
		if Time.get_ticks_msec() > deadline:
			OS.kill(pid)
			hung = true
			break
		await get_tree().create_timer(0.1).timeout
	# Once more after it exits: what it wrote between the last pass and its exit is still in
	# the pipe, and the leak report is always the last thing it writes.
	_drain_exit_probe(pipes, bytes)

	# OS.kill has already reaped it, and asking for the exit code of a reaped pid is an error.
	var code := -1 if hung else OS.get_process_exit_code(pid)
	if wrapped and code == 124:
		hung = true
	return [code, bytes[0].get_string_from_utf8(), bytes[1].get_string_from_utf8(), hung, seconds]


func _drain_exit_probe(pipes: Array[FileAccess], bytes: Array[PackedByteArray]) -> void:
	for i in pipes.size():
		while true:
			var chunk := pipes[i].get_buffer(65536)
			if chunk.is_empty():
				break
			bytes[i].append_array(chunk)


func _test_exits_clean(probe: Array) -> void:
	_section("exiting clean, as a second process saw it")

	var code: int = probe[0]
	var stdout: String = probe[1]
	var stderr: String = probe[2]
	var hung: bool = probe[3]
	var seconds: int = probe[4]
	# Every leak line is the engine's, and the engine writes them to stderr; both are
	# searched so that stays a fact about the engine rather than an assumption here. Shown
	# apart, because a pipe each is two streams whose interleaving is lost, and where a hung
	# copy had got to is the end of its stdout.
	var text := stdout + "\n" + stderr
	var tail := "its last lines:\n%s\nand the last on stderr:\n%s" % [
		_last_lines(stdout, 15), _last_lines(stderr, 10)
	]

	# A copy that was killed never reached its exit, so neither of the last two was seen, and
	# passing them on an absence of lines would be passing them blind.
	var passes_detail := ""
	if hung:
		passes_detail = ("still running after %d s, so it was killed — a scene that failed to "
			+ "parse, or a thread still blocked when it quit; %s") % [seconds, tail]
	elif code != 0:
		passes_detail = "exit %d; %s" % [code, tail]
	_check(not hung and code == 0, "this suite, run again in a fresh process, passes",
		passes_detail)
	_check(not hung and not text.contains("leaked at exit"), "and leaves no object alive at exit",
		"it was killed before it reached its exit" if hung else _line_with(text, "leaked at exit"))
	_check(not hung and not text.contains("still in use at exit"), "and no resource",
		"it was killed before it reached its exit" if hung else _line_with(text, "still in use at exit"))
	_done()


func _line_with(text: String, needle: String) -> String:
	for line in text.split("\n"):
		if line.contains(needle):
			return line.strip_edges()
	return ""


func _last_lines(text: String, count: int) -> String:
	var lines := text.strip_edges().split("\n")
	return "\n".join(lines.slice(maxi(0, lines.size() - count)))
