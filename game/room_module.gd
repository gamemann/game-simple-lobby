class_name RoomModule
extends DotModule

## Binds a [RoomWorld] and its netcode to a [DotServer].
##
## The only file in this project that names dot-server, and the whole of the dedicated
## server integration: the tick, the join, the leave, and the console surface.
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

const CHANNEL := "room.module"

## The game this module serves. Registered so `changegame` and `votemap` mean something.
const GAME_ID := "simple_lobby"

var world: RoomWorld = null
var net: DotNetManager = null
var bridge: RoomBridge = null

## Chat, moderation and voice. Built here rather than in the world, because they are about
## the people connected rather than about the room — a game change frees the world and
## these have to survive it, exactly as the netcode manager does.
var services: RoomServices = null

## What people have put in the room.
##
## [b]The module's, not the world's, for the same reason.[/b] A prop somebody placed is
## theirs until they leave, and a `changegame` back and forth that emptied the room would
## be a lobby that forgets its furniture every time an operator types a command.
var props: RoomProps = null

## userid -> true, for everybody this module put in the room.
var _joined: Dictionary = {}

var _tick: int = 0


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
		descriptor.scene = "res://scenes/room_server.tscn"
		descriptor.client_scene = ""
	else:
		descriptor.scene = "scenes/room_server.tscn"
		descriptor.client_scene = "scenes/room_client.tscn"

	return descriptor


# --- Lifecycle -------------------------------------------------------------

func _module_load() -> DotResult:
	world = DotRegistry.get_node_service(RoomWorld.SERVICE) as RoomWorld

	if world == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"No RoomWorld is registered.",
			"load the room's scene first, or set DotGameManager.initial_game to '%s'"
				% GAME_ID
		)

	var netted := _build_netcode()

	if not netted.ok:
		return netted

	var propped := _build_props()

	if not propped.ok:
		return propped

	var serviced := _build_services()

	if not serviced.ok:
		return serviced

	hook_post("client_spawn", _on_client_spawn)
	server.client_disconnected.connect(_on_client_disconnected)

	# An avatar arrives after the person does — dot-platform resolves a profile and an
	# avatar asynchronously and a lobby must not hold somebody at the door while a
	# cosmetic loads. `player_avatar_changed` is what DotPlatformModule declares and
	# fires, and hooking it is the whole of the wardrobe integration.
	hook_post("player_avatar_changed", _on_avatar_changed)

	# [b]dot-server's own chat is cancelled here, not listened to.[/b] This used to be a
	# post-hook that only watched, because the routing was [DotChatManager]'s. It is
	# [DotChatRouter]'s now — channels, a radius, a backlog, a `/me`, and a gag that
	# survives a reconnect — and the one thing that must not happen is both running: two
	# sets of rules to keep in step, and the one that skipped the filter would be the one
	# that leaked admin chat. So the pre-hook takes the line, hands it to the router, and
	# cancels the event, which is exactly what `hook_pre` and `DotEvent.cancel` exist for.
	#
	# It is a *pre* hook for that reason: a post hook cannot cancel, and
	# [method DotChatManager.handle_message] broadcasts the moment the event returns
	# uncancelled.
	hook_pre("player_chat", _on_player_chat)

	# [b]dot-server's join and leave announcements are turned off, because dot-chat now
	# makes them.[/b] Leaving both on is two "Ada joined" lines for one arrival on two
	# different paths with two different sets of rules — the same duplication the chat
	# hook above exists to prevent, one message type over. `examples/sandbox.tscn` asserts
	# that nothing at all arrives through dot-server's own chat signal, and this is what
	# makes that true.
	if server.chat != null:
		server.chat.announce_joins = false

	add_command(
		"room_status", _cmd_status, "Show the room", DotAdminFlags.GENERIC
	)
	add_command("room_who", _cmd_who, "List who is in the room", "")
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
	)
	# [b]The punishment commands are MUTE-flagged and the prop clear is GENERIC.[/b]
	# Emptying the room is tidying up; gagging somebody is a record with their name on it
	# that outlives the session, and dot-server's own flags are what distinguish them —
	# `MUTE` rather than `BAN` because that is the flag whose name is exactly what these
	# do, and a server that wanted a moderator who can quiet somebody without being able
	# to remove them would otherwise have to choose between the two.
	add_command(
		"room_gag", _cmd_gag,
		"Stop somebody typing: room_gag <who> <seconds> [reason]", DotAdminFlags.MUTE
	)
	add_command(
		"room_mute", _cmd_mute,
		"Stop somebody talking: room_mute <who> <seconds> [reason]", DotAdminFlags.MUTE
	)
	add_command(
		"room_unpunish", _cmd_unpunish,
		"Lift everything against somebody: room_unpunish <who>", DotAdminFlags.MUTE
	)
	add_command(
		"room_say", _cmd_say,
		"Say something to the room as the server: room_say <text>", DotAdminFlags.CHAT
	)

	if Engine.physics_ticks_per_second != world.tick_rate:
		# Not corrected here: `sv_tickrate` is the operator's and this module is a guest in
		# their server. Loud, because the symptom otherwise is a room that walks at the
		# wrong speed with nothing in the log about it.
		log_warn("sv_tickrate does not match the room's tick rate", {
			"engine": Engine.physics_ticks_per_second,
			"room": world.tick_rate,
		})

	log_info("the room is open", {
		"bounds": world.arena.bounds,
		"capacity": RoomContent.MAX_OCCUPANTS,
	})

	return DotResult.success(null)


func _module_unload() -> void:
	if server != null and server.client_disconnected.is_connected(_on_client_disconnected):
		server.client_disconnected.disconnect(_on_client_disconnected)

	# Everybody this module put in the room comes out with it. A module that unloaded and
	# left them there would leave the world holding people whose sessions no longer exist,
	# and a netcode manager holding peers nothing will ever drive.
	if bridge != null and is_instance_valid(bridge):
		for userid in _joined.keys():
			bridge.remove_peer(bridge.peer_for_occupant(int(userid)))

	_joined.clear()

	# The world outlives this module — it is a scene [DotGameManager] owns — so the field
	# it was lent has to be given back. A freed [RoomProps] left in `world.props` is a
	# use-after-free on the next tick of the movement, which is the one function this
	# game's whole design says both ends run identically.
	if world != null and is_instance_valid(world):
		world.props = null

	if props != null and is_instance_valid(props):
		props.clear_all()

	if net != null and is_instance_valid(net):
		net.stop()


func _build_netcode() -> DotResult:
	var config := RoomContent.net_config()
	config.tick_rate = world.tick_rate

	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = true
	net.local_peer_id = 1
	net.config = config
	net.config_file = ""
	# The module drives the tick from `server_tick`, in step with dot-server's own, so the
	# manager must not also tick itself from `_physics_process`.
	net.auto_tick = false
	add_child(net)

	var ready := net.setup()

	if not ready.ok:
		return ready.wrap("The netcode could not be set up")

	bridge = RoomBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	var attached := bridge.attach(world, net, server)

	if not attached.ok:
		return attached.wrap("The bridge could not be attached")

	var started := net.start()

	if not started.ok:
		return started

	return DotResult.success(null)


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
	props.placed.connect(_on_prop_placed)
	props.cleared.connect(bridge.broadcast_prop_cleared)

	bridge.place_requested.connect(_on_place_requested)
	bridge.undo_requested.connect(_on_undo_requested)

	return DotResult.success(null)


## Chat, moderation and voice.
func _build_services() -> DotResult:
	services = RoomServices.new()
	services.name = "Services"
	services.bridge = bridge
	services.world = world
	services.server = server
	services.service_scope = world.service_scope
	add_child(services)

	var ready := services.setup()

	if not ready.ok:
		return ready.wrap("The room's services could not be set up")

	bridge.say_requested.connect(_on_say_requested)
	bridge.voice_requested.connect(_on_voice_requested)
	services.command_entered.connect(_on_chat_command)

	# The server's own view of a bubble, off the one signal that fires after a line has
	# been accepted. [b]Not off the request[/b]: a line that was refused for being a
	# duplicate, or that came from somebody gagged, would otherwise still appear over
	# their head in `room_status` — an operator watching a moderated player say things
	# nobody heard.
	services.chat.message_accepted.connect(_on_chat_accepted)

	return DotResult.success(null)


# --- The tick --------------------------------------------------------------

## One authoritative step of the whole room.
##
## Driven from the module's own [code]_physics_process[/code] rather than from a
## dot-server hook, because dot-server does not have one: it gets a player from "typed an
## address" to "in the world" and hands over, and the simulation rate is the engine's.
## [member DotNetManager.auto_tick] is off for the same reason — two things ticking the
## manager is two ticks a frame.
func _physics_process(_delta: float) -> void:
	# `world == null` is not enough: a game change frees the scene the world lives in
	# before this module is unloaded, and a freed Object is not null. Ticking one is a
	# use-after-free — see [method RoomBridge.live_world].
	if not loaded or bridge == null or not is_instance_valid(bridge) \
			or bridge.live_world() == null:
		return

	_tick += 1
	bridge.server_tick(_tick)


# --- Joining and leaving ---------------------------------------------------

## A client finished joining.
##
## [b]The event carries `userid`, not `peer_id`.[/b] Looking a session up by a key that is
## not in the payload returns null every time, so the handler returns early, every time,
## and nobody is ever put in the room — with no error, because a null session is a
## legitimate thing to find. game-blob and dot-2d-hungry both shipped that line.
func _on_client_spawn(event: DotEvent) -> void:
	var session := server.session_by_userid(event.get_int("userid"))

	if session == null:
		return

	if _joined.has(session.userid):
		return

	# The session id, not the peer id: a peer id is reassigned on reconnect and the next
	# person to join would inherit this one's place in the room.
	var added := bridge.add_occupant(
		session.peer_id, session.userid, session.display_name
	)

	if not added.ok:
		log_warn("could not admit somebody", {
			"userid": session.userid, "error": str(added.error)
		})
		return

	_joined[session.userid] = true

	# Voice and chat learn about them before anything is sent to them, so a frame or a
	# line that lands in the same flush as the admission has somewhere to go.
	services.add_peer(session.peer_id)

	# A client that already asked is admitted now. The two orderings race on a fast
	# loopback: dot-server's signon and this game's READY are separate messages on
	# separate paths, and neither is entitled to arrive first.
	if bridge.peer_is_ready(session.peer_id):
		bridge._admit(session.peer_id, session.userid)

	_welcome(session)


## What somebody is told once they are in: the backlog, and everybody's avatar.
##
## [b]After the admission, never before it.[/b] Nothing may be sent to a peer before it
## has said it can receive — dot-server's signon finishes and *then* the client builds its
## scene, and everything sent in between lands on a node that does not exist and is lost,
## one "Node not found" per call.
func _welcome(session: DotClientSession) -> void:
	if not bridge.peer_is_ready(session.peer_id):
		return

	# The backlog: what was said in the room before they walked in. dot-chat computes it
	# per peer, because a channel with `backlog = 0` — the proximity one — must not
	# replay a line somebody said quietly in a corner to a stranger who was not there.
	for line in services.chat.backlog_for(session.peer_id):
		bridge.send_chat(session.peer_id, line)

	services.chat.join_notice(session.peer_id, RoomServices.CHANNEL_ALL)

	# Everybody's avatar, including their own. A client that had to synthesise its own
	# row would have a row nothing else produced — the same argument the roster makes.
	for occupant in world.roster():
		var other := server.session_by_userid(occupant.id)

		if other == null:
			continue

		var parts := _avatar_parts_for(other)

		if not parts.is_empty():
			bridge.send_avatar(session.peer_id, occupant.id, parts)


func _on_client_disconnected(session: DotClientSession, _reason: String) -> void:
	if not _joined.has(session.userid):
		return

	# [b]The services first, the props second, the room last, and the order matters
	# twice.[/b] Taking the peer off the voice router before the room means no frame is
	# relayed to a socket that has gone; clearing their props before the room means the
	# PROP_CLEARED broadcasts still reach everybody else, because `_broadcast` walks the
	# ready set and this peer is still in it. Removing them from the room first would
	# leave both to fire at a peer the transport no longer has — which is the "Attempt to
	# call RPC with unknown peer ID" this game already fixed once, from the other end.
	# Off the broadcast set before anything is announced. Everything below tells everybody
	# ELSE something about this person, and their socket has already gone.
	bridge.mark_not_ready(session.peer_id)

	services.chat.leave_notice(session.peer_id, RoomServices.CHANNEL_ALL)
	services.remove_peer(session.peer_id)
	props.clear_owner(session.userid)

	bridge.remove_peer(session.peer_id)
	_joined.erase(session.userid)


# --- Props -----------------------------------------------------------------

func _on_prop_placed(place_id: int, def: DotPropDef, at: Vector2) -> void:
	var entry: Dictionary = props.placements().get(place_id, {})

	bridge.broadcast_prop_placed(
		place_id, def.id, at, float(entry.get("rotation", 0.0)), int(entry.get("owner", 0))
	)


func _on_place_requested(
	peer_id: int, prop_index: int, at: Vector2, rotation: float
) -> void:
	var occupant := bridge.occupant_for_peer(peer_id)

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
		services.chat.notice(peer_id, placed.error.message, RoomServices.CHANNEL_ALL)


func _on_undo_requested(peer_id: int) -> void:
	var occupant := bridge.occupant_for_peer(peer_id)

	if occupant == null:
		return

	if not props.undo(occupant.id):
		services.chat.notice(
			peer_id, "You have not put anything in the room.", RoomServices.CHANNEL_ALL
		)


# --- Chat and voice --------------------------------------------------------

## Somebody typed something on this game's own wire.
func _on_say_requested(peer_id: int, channel_id: StringName, text: String) -> void:
	var said := services.chat.submit(peer_id, channel_id, text)

	if not said.ok and said.error != null:
		# The refusal goes back to the sender and nowhere else. dot-chat is deliberate
		# that a rate-limited or gagged player must not be able to measure the difference
		# from outside, and a refusal broadcast to the room is exactly that measurement.
		services.chat.notice(peer_id, said.error.message, channel_id)


## A voice frame. Relayed, never inspected.
##
## [b]The speaker is stamped by the router from the transport's own sender id[/b], not
## read out of the packet — without that any client can put words in any other player's
## mouth and the only symptom is confusion.
func _on_voice_requested(peer_id: int, payload: PackedByteArray) -> void:
	services.voice.relay(peer_id, payload)


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
			services.chat.notice(peer_id, line, RoomServices.CHANNEL_ALL)
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

	var occupant := bridge.occupant_for_peer(message.sender_peer)

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

	if session == null or not _joined.has(session.userid):
		return

	bridge.broadcast_avatar(session.userid, _avatar_parts_for(session))


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

	if session == null or services == null or services.chat == null:
		return

	# The channel is the one dot-server's client had no way to name. A player using the
	# legacy path — the browser shell's own chat box, or `say` at a client console — lands
	# on the room channel, which is the one they would have picked.
	_on_say_requested(session.peer_id, RoomServices.CHANNEL_ALL, event.get_string("text"))


# --- Commands --------------------------------------------------------------

func _cmd_status(ctx: DotCmdContext) -> void:
	ctx.reply_lines(world.describe_lines())


func _cmd_who(ctx: DotCmdContext) -> void:
	var now := int(Time.get_unix_time_from_system())

	ctx.reply("%-6s %-22s %-9s %s" % ["id", "name", "here for", "at"])

	for occupant in world.roster():
		ctx.reply("%-6d %-22s %6ds   %6.0f,%6.0f" % [
			occupant.id,
			occupant.display_name,
			maxi(0, now - occupant.joined_at),
			occupant.position().x,
			occupant.position().y,
		])


func _cmd_net(ctx: DotCmdContext) -> void:
	ctx.reply_lines(bridge.describe_lines())

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
	var said := services.chat.announce(text, RoomServices.CHANNEL_ALL)

	if not said.ok:
		ctx.reply("Refused: %s" % said.error.message)
		return

	ctx.reply("Said to %d." % bridge.ready_peer_count())


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
	var seconds := maxi(0, ctx.arg_int(1))
	var reason := ctx.rest(2) if ctx.args.size() > 2 else "No reason given."

	var issued: DotResult = await services.moderation.issue(
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
	services.chat.notice(
		session.peer_id, punishment.player_message(), RoomServices.CHANNEL_ALL
	)


func _cmd_unpunish(ctx: DotCmdContext) -> void:
	if ctx.args.is_empty():
		ctx.reply("Usage: room_unpunish <who>")
		return

	var targets := server.find_sessions(ctx.args[0], ctx.session)

	if targets.is_empty():
		ctx.reply("Nobody matches '%s'." % ctx.args[0])
		return

	var session := targets[0]
	var subject := DotPunishmentSubject.for_uid(session.uid())
	var lifted := 0

	# [b]Per kind, because that is the shape dot-moderation offers.[/b] `revoke_all` takes
	# one kind — a moderator lifting a gag should not silently lift a ban as well — so
	# "everything against this person" is the loop, and it is here rather than in the
	# addon for exactly that reason.
	for kind in [DotPunishment.Kind.GAG, DotPunishment.Kind.VOICE_MUTE]:
		var result: DotResult = await services.moderation.revoke_all(
			subject, kind, ctx.caller_label(), ctx.immunity
		)

		if result.ok:
			lifted += int(result.value)

	ctx.reply("Lifted %d against %s." % [lifted, session.display_name])

