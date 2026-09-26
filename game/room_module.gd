extends DotGameModule

const RoomPaths := preload("room_paths.gd")

const RoomBridge := preload("room_bridge.gd")
const RoomContent := preload("room_content.gd")
const RoomOccupant := preload("room_occupant.gd")
const RoomProps := preload("room_props.gd")
const RoomServices := preload("room_services.gd")
const RoomWorld := preload("room_world.gd")

## Binds a [RoomWorld] and its netcode to a [DotServer].
##
## [b]The sequence is [DotGameModule]'s.[/b] Resolving the world, the netcode and its four
## load-bearing settings, the bridge, the message seal, the services layer, the roster
## — including the one spawn-event field two games in this family read wrong — the
## authoritative tick and a teardown in reverse are all the base's. What is left is what is
## actually this lobby's: the props, a welcome that waits until the client can hear it, a
## leave that tells everybody else before the room forgets the person, dot-server's chat
## cancelled and routed through dot-chat, avatars, the console surface, a query provider
## that reports occupancy, and a module that outlives a game change.
##
## [codeblock]
## server.modules.load_module("res://game/room_module.gd")
## [/codeblock]
##
## [b]The manager outlives the world.[/b] A game change frees the scene the world lives in
## and instantiates the next one; rebuilding the [DotNetManager] with it would reset the
## message ids, the peer records and the clock, which is a disconnect for everybody and
## precisely what changing the game is supposed to avoid. So the manager and the bridge
## are the module's, and [method RoomBridge.rebind] moves the bridge onto the new world.
##
## [b]No `const CHANNEL` here.[/b] [DotGameModule] declares one and GDScript refuses a
## redeclaration; a module logs through [method DotModule.log_info], which stamps its name.

## The game this module serves. Registered so `changegame` and `votemap` mean something.
const GAME_ID := "simple_lobby"

## The room. [member DotGameModule.game], typed, and moved with it on a game change.
var world: RoomWorld = null

## What people have put in the room.
##
## [b]The module's, not the world's.[/b] A prop somebody placed is theirs until they leave,
## and a `changegame` back and forth that emptied the room would be a lobby that forgets
## its furniture every time an operator types a command.
var props: RoomProps = null

## dot-moderation's live tools, which [DotGameServices] builds. Named here because the
## game change below is the one thing that has to tell them anything.
var mod_tools: DotModTools:
	get:
		return services.get("mod_tools") as DotModTools if services != null else null

## Where the services write punishments. [constant RoomServices.PUNISHMENTS_PATH] unless a
## host says otherwise before the module loads.
##
## [b]Static, because the host never holds this module before it exists[/b]: dot-server
## instantiates it from a path inside `load_module`, so there is no instance to set a
## field on first. `examples/dedicated.tscn` wrote a test gag into the real
## `user://room_punishments.json` on every run, 61 of them by the time anybody counted,
## before this could be pointed somewhere else.
static var punishments_path: String = RoomServices.PUNISHMENTS_PATH

## userid -> true, for everybody who has been welcomed since they were seated. A client
## asks for the room again after a game change, and the backlog is not news twice.
var _welcomed: Dictionary = {}


func _module_name() -> String:
	return "room"


func _module_version() -> String:
	return "0.1.0"


func _module_description() -> String:
	return "A lobby: walk about, see who is here, talk to them."


func _module_author() -> String:
	return "dot"


## The descriptor a server registers to be able to run this.
##
## Two shapes, and [param manifest_url] is what chooses between them.
##
## [b]Empty — the room ships inside the build.[/b] The scene is a `res://` path and the
## client scene is deliberately [i]left empty[/i]. That is not an omission:
## [method DotClientLink._resolve_scene] refuses every absolute path outside dot-cloud's
## mount — correctly, because a server that could name one could ask any client to load
## any scene in their build — so naming `res://scenes/room_client.tscn` here means the
## client refuses it, never reports loaded, sits in `LOADING` sending no heartbeats, and
## is timed out for being idle. The symptom is a connection that appears to work and then
## silently does not. [method DotGameDescriptor.client_scene_or_scene] returns the empty
## string for exactly this case, which is the documented "you already have it" path, and
## the application then loads whatever its own build says the client is.
##
## [b]Set — the room is delivered through dot-cloud.[/b] The paths become *relative* and
## resolve under the version-namespaced mount, so a generic client shell that has never
## heard of a room downloads the pack, mounts it, and instantiates the scene named here.
## That is the deployment this game exists for.
static func game_descriptor(manifest_url: String = "") -> DotGameDescriptor:
	var descriptor := DotGameDescriptor.new()
	descriptor.game_id = GAME_ID
	descriptor.display_name = "The Room"
	descriptor.version = "0.1.0"
	descriptor.manifest_url = manifest_url
	descriptor.max_players = RoomContent.MAX_OCCUPANTS
	descriptor.metadata = {"kind": "lobby"}

	if manifest_url == "":
		descriptor.scene = RoomPaths.rebase("res://scenes/room_server.tscn")
		descriptor.client_scene = ""
	else:
		descriptor.scene = "scenes/room_server.tscn"
		descriptor.client_scene = "scenes/room_client.tscn"

	return descriptor


# --- What DotGameModule asks for ---------------------------------------------

func _game_service() -> StringName:
	return RoomWorld.SERVICE


func _game_missing_hint() -> String:
	return "load the room's scene first, or set DotGameManager.initial_game to '%s'" % GAME_ID


## [method RoomContent.net_config], in one place so three call sites cannot drift, at the
## world's tick rate.
func _net_config() -> DotNetConfig:
	var config := RoomContent.net_config()
	config.tick_rate = (game as RoomWorld).tick_rate
	return config


func _make_bridge() -> Node:
	return RoomBridge.new()


## Chat, moderation, voice and the live tools. Built here rather than in the world, because
## they are about the people connected rather than about the room — a game change frees the
## world and these have to survive it, exactly as the netcode manager does.
func _make_services() -> Node:
	var made := RoomServices.new()
	made.bridge = bridge as RoomBridge
	made.world = game as RoomWorld
	made.service_scope = (game as RoomWorld).service_scope
	made.punishments_file = punishments_path
	return made


## Everything the skeleton does not know about. Runs after the netcode, the services and
## the roster are up.
func _game_load() -> DotResult:
	world = game as RoomWorld

	# [b]Refused, where [DotGameModule] would only log.[/b] Its reasoning — a server with no
	# chat is still a server — is right for a game with something else in it. A lobby is a
	# game whose entire content is the conversation, and this module has always refused to
	# load without it.
	if services == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The room's chat, voice and moderation could not start.",
			"see the game.services lines above; a lobby with no chat is an empty room"
		)

	var propped := _build_props()

	if not propped.ok:
		return propped

	_wire_services()
	_wire_roster()

	# An avatar arrives after the person does — dot-platform resolves a profile and an
	# avatar asynchronously and a lobby must not hold somebody at the door while a
	# cosmetic loads. `player_avatar_changed` is what DotPlatformModule declares and
	# fires, and hooking it is the whole of the wardrobe integration.
	hook_post("player_avatar_changed", _on_avatar_changed)

	# [b]dot-server's own chat is cancelled here, not listened to.[/b] The routing is
	# [DotChatRouter]'s — channels, a radius, a backlog, a `/me`, and a gag that survives a
	# reconnect — and the one thing that must not happen is both running: two sets of rules
	# to keep in step, and the one that skipped the filter would be the one that leaked
	# admin chat. So the pre-hook takes the line, hands it to the router, and cancels the
	# event. A *pre* hook because a post hook cannot cancel, and
	# [method DotChatManager.handle_message] broadcasts the moment the event returns
	# uncancelled.
	hook_pre("player_chat", _on_player_chat)

	# [b]dot-server's join and leave announcements are turned off, because dot-chat now
	# makes them.[/b] Leaving both on is two "Ada joined" lines for one arrival on two
	# paths with two sets of rules. `examples/sandbox.tscn` asserts that nothing at all
	# arrives through dot-server's own chat signal, and this is what makes that true.
	if server.chat != null:
		server.chat.announce_joins = false

	_add_commands()

	if Engine.physics_ticks_per_second != world.tick_rate:
		# Not corrected here: `sv_tickrate` is the operator's and this module is a guest in
		# their server. Loud, because the symptom otherwise is a room that walks at the
		# wrong speed with nothing in the log about it.
		log_warn("sv_tickrate does not match the room's tick rate", {
			"engine": Engine.physics_ticks_per_second,
			"room": world.tick_rate,
		})

	_build_query_provider()

	log_info("the room is open", {
		"bounds": world.arena.bounds,
		"capacity": RoomContent.MAX_OCCUPANTS,
	})

	return DotResult.success(null)


## **`.with_chat()` says a command is typable whatever the server's default is.**
## `sv_chat_commands` ships on, so an unmarked command is reachable from chat too and the
## flag it carries is what decides who may run it — the same check, on the same line, for
## chat, RCON and the terminal. What marking buys is survival: these stay typable on a
## server whose operator turned that default off, because they are what a player is
## expected to type.
##
## [b]The punishment commands are MUTE-flagged and the prop clear is GENERIC.[/b] Emptying
## the room is tidying up; gagging somebody is a record with their name on it that outlives
## the session. `MUTE` rather than `BAN` because that is the flag whose name is exactly what
## these do.
func _add_commands() -> void:
	add_command(
		"room_status", _cmd_status, "Show the room", DotAdminFlags.GENERIC
	).with_chat()
	add_command("room_who", _cmd_who, "List who is in the room", "").with_chat()
	add_command(
		"room_net", _cmd_net, "Show the netcode's counters", DotAdminFlags.GENERIC
	)
	add_command(
		"room_props", _cmd_props,
		"Show what is in the room: room_props [clear]", DotAdminFlags.GENERIC
	)
	add_command(
		"room_services", _cmd_services,
		"Show chat, voice and moderation", DotAdminFlags.GENERIC
	).with_chat()
	add_command(
		"room_gag", _cmd_gag,
		"Stop somebody typing: room_gag <who> <seconds> [reason]", DotAdminFlags.MUTE
	).with_chat()
	add_command(
		"room_mute", _cmd_mute,
		"Stop somebody talking: room_mute <who> <seconds> [reason]", DotAdminFlags.MUTE
	).with_chat()
	add_command(
		"room_unpunish", _cmd_unpunish,
		"Lift everything against somebody: room_unpunish <who>", DotAdminFlags.MUTE
	).with_chat()
	add_command(
		"room_say", _cmd_say,
		"Say something to the room as the server: room_say <text>", DotAdminFlags.CHAT
	)


## Everything [method _game_load] set up that [DotGameModule]'s teardown does not undo.
func _game_unload() -> void:
	# Everybody this module put in the room comes out with it. The world outlives this
	# module — it is a scene [DotGameManager] owns — and [method DotGameRoster.clear] is
	# deliberately not "remove everybody", so without this the world would hold people
	# whose sessions no longer exist and a manager would hold peers nothing drives.
	var room := _room_bridge()

	if room != null and roster != null:
		for userid in roster.joined.keys():
			room.remove_peer(room.peer_for_occupant(int(userid)))

	# The field the world was lent has to be given back. A freed [RoomProps] left in
	# `world.props` is a use-after-free on the next tick of the movement, which is the one
	# function this game's whole design says both ends run identically.
	if world != null and is_instance_valid(world):
		world.props = null

	if props != null and is_instance_valid(props):
		props.clear_all()

	_welcomed.clear()
	world = null


## Moves everything that held the old world onto the one the new game brought.
##
## Called by [DotModuleHost] after [DotGameManager] has swapped the scene. [b]This module
## was written to outlive a game change — the netcode, the props and the services are all
## its own for that reason — and until this override existed nothing moved it.[/b] The
## bridge kept the freed world, [method RoomBridge.live_world] answered null, the tick
## returned early on every frame, and the room froze with everybody still in it.
## `examples/dedicated.tscn`'s "a game change" section is what says it moves now.
## [DotGameModule] has no opinion about a game change, which is right: most games are
## unloaded with their world.
func _module_game_changed(content_key: String) -> void:
	var next := DotRegistry.get_node_service(RoomWorld.SERVICE) as RoomWorld
	var talk := _room_services()

	if next == null:
		# A different game with no room in it. The module goes idle rather than failing:
		# everything that reads the world goes through `live_world()` and finds nothing,
		# and the next change back to a room rebinds from here.
		log_info("the new game has no room; the lobby is idle", {"content_key": content_key})
		world = null
		game = null

		if talk != null:
			talk.world = null
			talk.game = null

		return

	if next == world:
		return

	world = next
	game = next

	# Everything that holds a world holds the new one, before the bridge repopulates it —
	# `rebind` re-adds everybody, and the first tick after it resolves them against the
	# props the world is told about here.
	world.props = props

	if props != null:
		props.rebind_world(world)

	if talk != null:
		talk.world = world
		talk.game = world

	var rebound := _room_bridge().rebind(world)

	if not rebound.ok:
		log_warn("could not move the room onto the new world", {
			"content_key": content_key, "error": str(rebound.error),
		})
		return

	_carry_mod_tools()

	log_info("the room moved onto a new world", {
		"content_key": content_key, "occupants": world.occupant_count(),
	})


## Tells the live tools that everybody in the room has a new body, after a game change.
##
## [b]Without this the record and the room disagree.[/b] `RoomBridge.rebind` re-adds every
## occupant from scratch, so a noclip or a freeze on the old one was gone while
## `modtools <player>` still listed it — and a blind and a beacon, which should have
## carried across, were gone too. [method DotModTools.respawned] is dot-moderation's own
## answer to "the body a handler changed is gone": what persists
## ([constant RoomServices.PERSIST_ACROSS_CHANGE]) is applied to the new one, and
## everything else is switched off through its handler and forgotten.
##
## [b]And the return history goes, for everybody.[/b] Every position in it is a point in the
## room that was just freed, so `return <player>` after a change teleported them to where
## they had stood in a different map. `respawned` keeps it on purpose, because in a game
## where a body respawns in the same map a return still means something; a game change is
## the one case here where none of it can, and that includes people who left before it.
func _carry_mod_tools() -> void:
	var tools := mod_tools

	if tools == null or world == null:
		return

	for occupant in world.roster():
		tools.respawned(StringName(str(occupant.id)))
	tools.clear_history()


## The prop layer, and the world that will hold the bodies.
##
## [b]The bodies go under the world's scene, and the book-keeping does not.[/b] A game
## change frees that scene; the placements survive it, which is why [RoomProps] is a child
## of the module and only its [DotPropSpawner]'s `world_ref` points into the scene.
func _build_props() -> DotResult:
	props = RoomProps.new()
	props.name = "Props"
	add_child(props)

	var ready := props.setup(true, world)

	if not ready.ok:
		return ready.wrap("The room's props could not be set up")

	world.props = props

	# One path out to the clients for each direction, rather than one per caller. An undo,
	# a disconnect, an admin clear and a world-budget eviction all end at `cleared`, so
	# there is one place that tells everybody rather than four that must remember to.
	var room := _room_bridge()
	props.placed.connect(_on_prop_placed)
	props.cleared.connect(room.broadcast_prop_cleared)

	room.place_requested.connect(_on_place_requested)
	room.undo_requested.connect(_on_undo_requested)

	return DotResult.success(null)


## This game's own wire, into the services.
##
## [b]Voice is a signal here rather than [DotGameModule]'s `voice_relay_fn`[/b], which the
## base assigns only on a bridge that has one; this bridge emits, and the relay is the
## base's own [method DotGameServices.relay_voice] — which stamps the speaker from the peer
## the transport reported, not from the packet.
func _wire_services() -> void:
	var room := _room_bridge()
	var talk := _room_services()

	room.say_requested.connect(_on_say_requested)
	room.peer_admitted.connect(_on_peer_admitted)
	room.voice_requested.connect(talk.relay_voice)
	talk.command_entered.connect(_on_chat_command)

	# The server's own view of a bubble, off the one signal that fires after a line has
	# been accepted. [b]Not off the request[/b]: a line that was refused for being a
	# duplicate, or that came from somebody gagged, would otherwise still appear over
	# their head in `room_status` — an operator watching a moderated player say things
	# nobody heard.
	_chat().message_accepted.connect(_on_chat_accepted)


# --- Joining and leaving ---------------------------------------------------

## What [DotGameRoster] does on a join and a leave, in this room.
##
## The lookup — `client_spawn` carries `userid`, not `peer_id`, the line two games in this
## family shipped wrong — the admission check and the bookkeeping are the base's. What the
## room adds is who is seated and how, and a welcome.
##
## [b]This module follows its own roster, AFTER the services.[/b] [DotGameRoster] tells its
## followers in the order they were added, and [DotGameModule] added the services first:
## so voice learns about somebody before anything is sent to them, and a frame or a line
## that lands in the same flush as the admission has somewhere to go.
func _wire_roster() -> void:
	roster.add_fn = _seat
	roster.remove_fn = _unseat
	roster.follow(self)


## Puts somebody in the room. A failure leaves them out, and the roster says so.
##
## [b]Nobody can be admitted to a room that is not there:[/b] between a game change freeing
## the scene and [method _module_game_changed] — or for as long as the game running is not
## a room at all — the world is freed or null.
func _seat(session: DotClientSession) -> DotResult:
	var room := _room_bridge()

	if room == null or room.live_world() == null:
		return DotResult.fail(DotError.CODE_STATE, "There is no room running.")

	# The session id, not the peer id: a peer id is reassigned on reconnect and the next
	# person to join would inherit this one's place in the room.
	return room.add_occupant(session.peer_id, session.userid, session.display_name)


## [DotGameRoster]'s follower call, after the services have had theirs.
##
## A client that already asked is admitted now. The two orderings race on a fast loopback:
## dot-server's signon and this game's READY are separate messages on separate paths, and
## neither is entitled to arrive first. Either way the welcome follows the admission —
## [signal RoomBridge.peer_admitted] — and not this call.
func add_peer(peer_id: int) -> void:
	var session := server.session_of(peer_id) if server != null else null
	var room := _room_bridge()

	if session != null and room != null and room.peer_is_ready(peer_id):
		room._admit(peer_id, session.userid)


## A seated peer can now receive: welcome them, once.
##
## [b]Off the admission, and before this it was off the seating, which never worked over a
## socket.[/b] The welcome ran from the spawn handler and returned if the peer was not yet
## ready — and over a real connection it never is: the client builds its scene after signon
## and only then asks for the room. Nothing welcomed it afterwards, so a newcomer got no
## backlog, the room got no "joined" line and nobody's avatar was sent to them. `sandbox`
## measured it: both clients were unready at spawn, and the second received none of the
## three lines said before it arrived. Its **a second person** section counts them now.
func _on_peer_admitted(peer_id: int, _occupant_id: int) -> void:
	var session := server.session_of(peer_id) if server != null else null

	if session == null or roster == null or not roster.has(session.userid):
		return

	if _welcomed.has(session.userid):
		return

	_welcomed[session.userid] = true
	_welcome(session)


## What somebody is told once they are in: the backlog, and everybody's avatar.
##
## [b]After the admission, never before it.[/b] Nothing may be sent to a peer before it
## has said it can receive — dot-server's signon finishes and *then* the client builds its
## scene, and everything sent in between lands on a node that does not exist and is lost,
## one "Node not found" per call. That is why [method RoomServices._peer_can_receive]
## answers no, and the base leaves the backlog to this.
func _welcome(session: DotClientSession) -> void:
	var room := _room_bridge()

	# The backlog: what was said in the room before they walked in. dot-chat computes it
	# per peer, because a channel with `backlog = 0` — the proximity one — must not
	# replay a line somebody said quietly in a corner to a stranger who was not there.
	for line in _chat().backlog_for(session.peer_id):
		room.send_chat(session.peer_id, line)

	_chat().join_notice(session.peer_id, RoomServices.CHANNEL_ALL)

	# Everybody's avatar, including their own. A client that had to synthesise its own
	# row would have a row nothing else produced — the same argument the roster makes.
	for occupant in world.roster():
		var other := server.session_by_userid(occupant.id)

		if other == null:
			continue

		var parts := _avatar_parts_for(other)

		if not parts.is_empty():
			room.send_avatar(session.peer_id, occupant.id, parts)


## Takes somebody out of the room. [DotGameRoster] then tells the services (voice and the
## chat limiter forget the peer) and the live tools (where a bring would return them to).
##
## [b]Off the broadcast set first, the room last.[/b] Everything between tells everybody
## ELSE something about this person — the leave notice, the PROP_CLEARED for each thing
## they put down — and their socket has already gone: sending to it is the "Attempt to
## call RPC with unknown peer ID" this game already fixed once, from the other end.
func _unseat(session: DotClientSession) -> void:
	var room := _room_bridge()

	if room == null:
		return

	_welcomed.erase(session.userid)
	room.mark_not_ready(session.peer_id)
	_chat().leave_notice(session.peer_id, RoomServices.CHANNEL_ALL)
	props.clear_owner(session.userid)
	room.remove_peer(session.peer_id)


# --- The tick --------------------------------------------------------------

## [DotGameModule]'s tick, but not on a world that is not there.
##
## `world == null` is not enough: a game change frees the scene the world lives in before
## this module hears about it, and a freed Object is not null. Ticking one is a
## use-after-free — see [method RoomBridge.live_world]. The base asks this before every
## tick since 2026-09-25; before that this overrode `_physics_process`.
func _can_tick() -> bool:
	var room := _room_bridge()
	return room != null and room.live_world() != null


# --- Typed views of what the base holds untyped ------------------------------

func _room_bridge() -> RoomBridge:
	return bridge as RoomBridge if bridge != null and is_instance_valid(bridge) else null


func _room_services() -> RoomServices:
	return services as RoomServices if services != null else null


func _chat() -> DotChatRouter:
	return services.get("chat") as DotChatRouter if services != null else null


## What a server browser is told about this room.
##
## [b]This game ships `RoomBrowser` and answered no query at all.[/b] A lobby is the one
## server in this family a person is most likely to be *choosing* from a list — it is where
## people wait for each other — and until now it could not be found by the browser it ships
## with. dot-server answers A2S and DQP once a query host is plugged in, and what a listing
## row says about the GAME comes from a provider like this one.
##
## **The occupancy is the row.** A lobby's whole state is how many people are in it against
## how many it holds, and a browser showing 0/0 for a room with five people waiting in it
## is a browser nobody would use twice.
func _build_query_provider() -> void:
	var provider := RoomQueryProvider.new()
	provider.module = self

	# DEBUG rather than ERROR: a room with neither query protocol enabled is a legitimate
	# deployment — a peer-to-peer lobby has no listener to answer on at all.
	DotLog.result(
		CHANNEL, "the query provider", add_query_provider(provider), DotLog.Level.DEBUG
	)


## A [DotQueryProvider] over this module. An inner class because it is one method and a
## reference, which is what game-arena does for the same thing.
class RoomQueryProvider extends DotQueryProvider:
	## Held as an [Object]: this script has no [code]class_name[/code] and an inner class
	## cannot name the outer script it lives in.
	var module: Object = null

	func _provider_name() -> String:
		return "room"

	func _contribute(snapshot: DotQuerySnapshot) -> void:
		# `is_instance_valid` rather than null: a query can arrive between a game change
		# freeing the scene and the module moving onto the next one.
		if module == null or module.world == null or not is_instance_valid(module.world):
			return

		var world: RoomWorld = module.world
		var values := {
			# A lobby has one room and it is always this one, so the map is a constant
			# rather than a lookup. Said rather than omitted: a listing column that is
			# blank reads as a server that failed to answer.
			"map": "the room",
			"occupants": world.occupant_count(),
			"capacity": RoomContent.MAX_OCCUPANTS,
			"props": module.props.count() if module.props != null else 0,
			"tick_rate": world.tick_rate,
		}

		# The side somebody picks here is the one they take into the match they go to,
		# which is this game's whole reason for existing — so the split is worth a row.
		# `counts()` rather than a loop over the definitions: the roster already builds
		# exactly this dictionary, and a second tally is a second thing that can disagree.
		if world.player_stack != null and world.player_stack.teams != null:
			# Hoisted: `counts()` builds a fresh dictionary on every call, and
			# `count_on` is a call to it per side.
			var counts := world.player_stack.teams.counts()
			var sides := PackedStringArray()

			for id: StringName in counts:
				sides.append("%s:%d" % [String(id), int(counts[id])])

			values["sides"] = " ".join(Array(sides))

		for key: String in values:
			snapshot.game[key] = values[key]


# --- Props -----------------------------------------------------------------

func _on_prop_placed(place_id: int, def: DotPropDef, at: Vector2) -> void:
	var entry: Dictionary = props.placements().get(place_id, {})

	_room_bridge().broadcast_prop_placed(
		place_id, def.id, at, float(entry.get("rotation", 0.0)), int(entry.get("owner", 0))
	)


func _on_place_requested(
	peer_id: int, prop_index: int, at: Vector2, rotation: float
) -> void:
	var occupant := _room_bridge().occupant_for_peer(peer_id)

	if occupant == null:
		return

	var prop_id := RoomProps.id_at(prop_index)

	if prop_id == &"":
		# A client asking for an index this build has no prop at. Not an error worth a
		# log line per click — it is what an older or newer client looks like — and not
		# silent either, because the same message from a build that agrees would be a
		# real bug.
		log_warn("a client asked for a prop index that is not in the catalogue", {
			"peer": peer_id, "index": prop_index,
		})
		return

	var placed := props.place(occupant.id, prop_id, at, rotation)

	if not placed.ok:
		# Told to the person who asked, on the channel they are already reading, rather
		# than logged where only an operator would see it. A budget nobody is told about
		# is a button that stops working.
		_chat().notice(peer_id, placed.error.message, RoomServices.CHANNEL_ALL)


func _on_undo_requested(peer_id: int) -> void:
	var occupant := _room_bridge().occupant_for_peer(peer_id)

	if occupant == null:
		return

	if not props.undo(occupant.id):
		_chat().notice(
			peer_id, "You have not put anything in the room.", RoomServices.CHANNEL_ALL
		)


# --- Chat and voice --------------------------------------------------------

## Somebody typed something on this game's own wire.
func _on_say_requested(peer_id: int, channel_id: StringName, text: String) -> void:
	var said := _room_services().say(peer_id, channel_id, text)

	if not said.ok and said.error != null:
		# The refusal goes back to the sender and nowhere else. dot-chat is deliberate
		# that a rate-limited or gagged player must not be able to measure the difference
		# from outside, and a refusal broadcast to the room is exactly that measurement.
		_chat().notice(peer_id, said.error.message, channel_id)


## An unclaimed `!command` from chat.
##
## [b]Routed into dot-server's own console with the player's permissions[/b], rather than
## given a second command table here. dot-server already decides what a session may run,
## logs it to the audit log and answers it; a lobby that reimplemented that would be a
## lobby whose chat commands were not audited.
func _on_chat_command(peer_id: int, command: String, args: PackedStringArray) -> void:
	var session := server.session_of(peer_id)

	if session == null:
		return

	if server.console.find_command(command) == null:
		# Silently ignored rather than answered. dot-server's own chat commands do the
		# same and for the better reason: answering confirms which commands exist to
		# anybody probing, and a player typing "!!" should not get a console error.
		DotLog.debug(CHANNEL, "an unknown chat command was ignored", {
			"peer": peer_id, "command": command,
		})
		return

	# Replies go to the speaker and nowhere else — through the chat router, so an admin
	# command's output lands in the same window the player is already reading rather than
	# in dot-server's system channel, which this game no longer routes.
	var ctx := session.make_context(
		command,
		args,
		DotCmdContext.Source.CHAT,
		func(line: String) -> void:
			_chat().notice(peer_id, line, RoomServices.CHANNEL_ALL)
	)

	# Dispatched through the console so permissions, argument checks and the audit trail
	# all apply exactly as they do over RCON. A lobby with its own command table would be
	# a lobby whose chat commands were not audited.
	var line := command

	for arg in args:
		line += " " + arg

	server.console.execute(line, ctx)


## A line was accepted. Put it over the speaker's head, on the server's own copy.
##
## The bubble a client draws comes from the same message on the same path — see
## [method RoomClient._on_chat]. One payload, two ends, so a bubble can never say
## something the log does not.
func _on_chat_accepted(message: DotChatMessage, _recipients: PackedInt32Array) -> void:
	if message.sender_peer <= 0:
		return

	var occupant := _room_bridge().occupant_for_peer(message.sender_peer)

	if occupant != null:
		occupant.say(message.text, Time.get_ticks_msec())


# --- Avatars ---------------------------------------------------------------

## dot-platform resolved somebody's avatar. Draw it on them, for everybody.
##
## [b]Duck-typed against the platform module rather than depending on it.[/b] A LAN lobby
## with no dot-platform is a legitimate deployment and the most common one; naming
## [DotPlatformModule] here would make it impossible to run without an identity stack.
## game-hungario's module takes the same shape for the same reason.
func _on_avatar_changed(event: DotEvent) -> void:
	var session := server.session_by_userid(event.get_int("userid"))

	if session == null or roster == null or not roster.has(session.userid):
		return

	_room_bridge().broadcast_avatar(session.userid, _avatar_parts_for(session))


## Somebody's avatar as slot/part/colour rows, or an empty list when there is no platform.
##
## [b]Ids and colours, never a scene.[/b] That is dot-user-avatar's whole claim — an
## avatar is a bounded document a server validates against a schema and an entitlement set
## without ever loading a part — and it is what makes drawing sixty-four of them a
## question of two circles rather than of sixty-four downloads.
func _avatar_parts_for(session: DotClientSession) -> Array:
	var platform: Object = server.modules.get_module("platform")

	if platform == null or not platform.has_method("player_for"):
		return []

	var player: Variant = platform.call("player_for", session)

	if player == null or not (player is Object):
		return []

	var avatar: Variant = (player as Object).get("avatar")

	if not (avatar is DotAvatar):
		return []

	var doc := avatar as DotAvatar
	var out: Array = []

	for slot in doc.filled_slots():
		out.append({
			"slot": String(slot),
			"part": String(doc.part_in(slot)),
			"colour": doc.colour_of(slot, 0),
		})

	return out


## Somebody said something through dot-server's own chat path.
##
## [b]Taken and cancelled, not watched.[/b] dot-server's [DotChatManager] is about to
## broadcast this to everybody on one channel with its own rules; this game's rules are
## [DotChatRouter]'s. Cancelling is what makes there be exactly one path rather than two,
## and it is the documented use of a pre-hook: [method DotChatManager.handle_message]
## broadcasts the moment the event returns uncancelled.
##
## The line still reaches every player — through the router, which has already sanitised
## it, checked the gag, checked the rate and worked out who can hear it.
func _on_player_chat(event: DotEvent) -> void:
	event.cancel("routed by the room's chat", _module_name())

	var session := event.get_session()

	if session == null or _chat() == null:
		return

	# The channel is the one dot-server's client had no way to name. A player using the
	# legacy path — the browser shell's own chat box, or `say` at a client console — lands
	# on the room channel, which is the one they would have picked.
	_on_say_requested(session.peer_id, RoomServices.CHANNEL_ALL, event.get_string("text"))


# --- Commands --------------------------------------------------------------

## The world, or null with the operator told why. The commands outlive a game change and
## the world does not; see [method RoomBridge.live_world].
func _world_for(ctx: DotCmdContext) -> RoomWorld:
	var room := _room_bridge()
	var live := room.live_world() if room != null else null

	if live == null:
		ctx.reply("There is no room running.")

	return live


func _cmd_status(ctx: DotCmdContext) -> void:
	var live := _world_for(ctx)

	if live != null:
		ctx.reply_lines(live.describe_lines())


func _cmd_who(ctx: DotCmdContext) -> void:
	var live := _world_for(ctx)

	if live == null:
		return

	var now := int(Time.get_unix_time_from_system())

	ctx.reply("%-6s %-22s %-9s %s" % ["id", "name", "here for", "at"])

	for occupant in live.roster():
		ctx.reply("%-6d %-22s %6ds   %6.0f,%6.0f" % [
			occupant.id,
			occupant.display_name,
			maxi(0, now - occupant.joined_at),
			occupant.position().x,
			occupant.position().y,
		])


func _cmd_net(ctx: DotCmdContext) -> void:
	ctx.reply_lines(_room_bridge().describe_lines())

	if net != null:
		ctx.reply_lines(net.describe_lines())


func _cmd_props(ctx: DotCmdContext) -> void:
	if ctx.args.size() > 0 and ctx.args[0] == "clear":
		var gone := props.clear_all()
		ctx.reply("Cleared %d." % gone)
		return

	ctx.reply_lines(props.describe_lines())

	for key in props.placements().keys():
		var entry: Dictionary = props.placements()[key]
		var def: DotPropDef = entry["def"]
		var at: Vector2 = entry["at"]
		ctx.reply("  %-6d %-14s %6.0f,%6.0f  by %d" % [
			int(key), def.name_or_id(), at.x, at.y, int(entry["owner"]),
		])


func _cmd_services(ctx: DotCmdContext) -> void:
	ctx.reply_lines(services.describe_lines())


func _cmd_say(ctx: DotCmdContext) -> void:
	if ctx.args.is_empty():
		ctx.reply("Say what?")
		return

	var text := " ".join(ctx.args)
	var said := _chat().announce(text, RoomServices.CHANNEL_ALL)

	if not said.ok:
		ctx.reply("Refused: %s" % said.error.message)
		return

	ctx.reply("Said to %d." % _room_bridge().ready_peer_count())


func _cmd_gag(ctx: DotCmdContext) -> void:
	_punish(ctx, DotPunishment.Kind.GAG, "gagged")


func _cmd_mute(ctx: DotCmdContext) -> void:
	_punish(ctx, DotPunishment.Kind.VOICE_MUTE, "muted")


## The shared half of gag and mute.
##
## [b]The two commands are one function because the only difference is a kind.[/b]
## dot-moderation already models both as one record with an expiry, a scope and a
## revocation, and writing them separately would be two chances to forget the duration
## parsing or the immunity.
func _punish(ctx: DotCmdContext, kind: DotPunishment.Kind, verb: String) -> void:
	if ctx.args.size() < 2:
		ctx.reply("Usage: %s <who> <seconds, 0 for permanent> [reason]" % ctx.command)
		return

	# Read before anybody is looked up, so a typo is answered as a typo.
	var seconds := parse_seconds(ctx.args[1])

	if seconds < 0:
		ctx.reply(
			"'%s' is not a length. Seconds, or 30s / 10m / 2h / 7d; 0 or perm for permanent."
				% ctx.args[1]
		)
		return

	var targets := server.find_sessions(ctx.args[0], ctx.session)

	if targets.is_empty():
		ctx.reply("Nobody matches '%s'." % ctx.args[0])
		return

	if targets.size() > 1:
		# Refused rather than applied to all of them. `@me` and a name prefix both match
		# more than one person, and a mute applied to four people by accident is a thing
		# an operator finds out about from the four people.
		ctx.reply("'%s' matches %d people. Be more specific." % [
			ctx.args[0], targets.size()
		])
		return

	var session := targets[0]
	var reason := ctx.rest(2) if ctx.args.size() > 2 else "No reason given."

	var issued: DotResult = await _moderation().issue(
		kind,
		DotPunishmentSubject.for_uid(session.uid()),
		reason,
		ctx.caller_label(),
		seconds,
		ctx.immunity
	)

	if not issued.ok:
		ctx.reply("Refused: %s" % issued.error.message)
		return

	var punishment: DotPunishment = issued.value

	ctx.reply("%s %s: %s" % [
		session.display_name, verb, DotPunishment.format_duration(seconds)
	])

	# Told to the person it happened to, on the channel they are reading. A mute nobody
	# is told about is a microphone that has stopped working — which is what the player
	# reports, to somebody who then goes looking at the audio code.
	_chat().notice(
		session.peer_id, punishment.player_message(), RoomServices.CHANNEL_ALL
	)


## A punishment's length from what an operator typed, in seconds, or -1 for nonsense.
##
## [b]Refusing is the whole point.[/b] This read `ctx.arg_int(1)`, which answers anything
## that is not an integer with its default of 0 — and 0 is PERMANENT. So `room_gag ada 10m`,
## and `room_gag ada spamming` with the length forgotten, both issued a permanent gag
## against the account uid, which outlives the session by design and is the one mistake
## in this file that follows somebody home.
##
## A bare number stays seconds, because that is what the usage line has always said. A
## suffix goes through [method DotBanManager.parse_duration], dot-server's own reader, so
## `10m` means here what it means to dot-server's own `ban`.
static func parse_seconds(text: String) -> int:
	var s := text.strip_edges()

	if s.is_valid_int():
		var n := s.to_int()
		return n if n >= 0 else -1

	return DotBanManager.parse_duration(s)


func _cmd_unpunish(ctx: DotCmdContext) -> void:
	if ctx.args.is_empty():
		ctx.reply("Usage: room_unpunish <who>")
		return

	var targets := server.find_sessions(ctx.args[0], ctx.session)

	if targets.is_empty():
		ctx.reply("Nobody matches '%s'." % ctx.args[0])
		return

	# Refused for the reason [method _punish] refuses: a name prefix that matches four
	# people lifted everything against whichever of them happened to be first.
	if targets.size() > 1:
		ctx.reply("'%s' matches %d people. Be more specific." % [
			ctx.args[0], targets.size()
		])
		return

	var session := targets[0]
	var subject := DotPunishmentSubject.for_uid(session.uid())
	var lifted := 0

	# [b]Per kind, because that is the shape dot-moderation offers.[/b] `revoke_all` takes
	# one kind — a moderator lifting a gag should not silently lift a ban as well — so
	# "everything against this person" is the loop, and it is here rather than in the
	# addon for exactly that reason.
	for kind in [DotPunishment.Kind.GAG, DotPunishment.Kind.VOICE_MUTE]:
		var result: DotResult = await _moderation().revoke_all(
			subject, kind, ctx.caller_label(), ctx.immunity
		)

		if result.ok:
			lifted += int(result.value)

	ctx.reply("Lifted %d against %s." % [lifted, session.display_name])


func _moderation() -> DotModerationManager:
	return services.get("moderation") as DotModerationManager if services != null else null
