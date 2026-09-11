class_name RoomServices
extends Node

## Chat, moderation and voice, wired to this room's people and this room's wire.
##
## [b]Three addons that all answer the same question and must answer it the same way.[/b]
## [DotChatRouter] decides whether somebody may type, [DotVoiceRouter] decides whether
## they may talk, and [DotModerationManager] is what makes either answer survive a
## reconnect. They are here together because the joins between them are the whole point:
## the router does not import the moderation addon and the moderation addon does not
## import the router — they meet through two registry names, `dot_mute_source` and
## `dot_ban_source`, and this file is what makes sure something is registered under them.
##
## [b]What this is not: a second chat system.[/b] dot-server ships [DotChatManager], which
## sanitises, rate-limits and broadcasts one channel. That is what this game used, and it
## is exactly right for a server with no game. A lobby is a game whose entire content is
## the conversation, so it wants what that one does not have: a channel you can be near
## rather than in, a backlog for whoever just walked in, a `/me`, and a gag that is still
## there tomorrow. So the rules moved, and dot-server's broadcast is [b]cancelled[/b] in
## [method RoomModule._on_player_chat] rather than left running beside this. There is one
## path. Two would be two sets of rules, and the one that skipped the filter would be the
## one that leaked admin chat.
##
## [b]Everything the router needs to know about a person is a callable[/b], because the
## router has never heard of dot-server and should not: the peers, the names, the keys,
## the positions and who is an admin are all this file's answers to dot-chat's questions.

const CHANNEL := "room.services"

## Channel ids. Constants because they are on the wire — a client sends the id of the
## channel it had selected, and a typo would be a line that vanished.
const CHANNEL_ALL := &"all"
const CHANNEL_NEAR := &"near"
const CHANNEL_ADMIN := &"admin"
const CHANNEL_WHISPER := &"whisper"

## How far "near" reaches, in world units.
##
## The room is 1800 by 1120. 420 is about a quarter of the width: far enough that the
## people you can see are the people you can hear, and short enough that two conversations
## can happen at once — which is the only reason a proximity channel is worth having in a
## room you can see all of.
const NEAR_RANGE := 420.0

## Where punishments are written.
##
## A file, because this is a lobby and a lobby is what one person runs on a box. The store
## is a [DotPunishmentStore] subclass, so a community pointing it at a shared database is
## one assignment — which is dot-moderation's own answer and the reason a ban is not
## dot-server's `bans.json`: that one is per server, and a person banned from a community
## is banned from all of it.
const PUNISHMENTS_PATH := "user://room_punishments.json"


## Somebody typed something that started with `!` or `/` and no command claimed it.
signal command_entered(peer_id: int, command: String, args: PackedStringArray)


var chat: DotChatRouter = null
var moderation: DotModerationManager = null
## The website chat relay, when one is configured. See [method _build_relay].
var relay: DotChatRelay = null

## The relay's configuration. Left null, a default is built and the relay stays OFF.
##
## Off by default for the same reason every other power in this family is: a relay
## carries what your players type to a web page and back, and that is an operator's
## decision rather than a consequence of installing an addon.
@export var relay_config: DotChatRelayConfig = null

## The backbone client the relay posts through, assigned by the host BEFORE setup.
##
## [b]An [Object], not a [DotBackboneClient].[/b] The relay holds it duck-typed so that
## dot-chat need not depend on dot-auth, and keeping one spelling across the seam means
## the duck-typed contract is the only contract.
var backbone: Object = null

var voice: DotVoiceRouter = null

## Where a chat line and a voice frame leave through. Set by [RoomModule].
var bridge: RoomBridge = null

## The room, for the proximity channel and the proximity voice channel.
var world: RoomWorld = null

## The server, for names, keys and permissions.
##
## [b]Optional, and that is what lets `--offline` run the real chat router.[/b] With no
## server there are no sessions, so a name comes from the room and a key is derived from
## the occupant id — which is exactly as durable as an offline session is. The alternative
## is an offline lobby whose chat is a different code path from an online one, and this
## family's own repeated lesson is that a path only one deployment shape reaches is a path
## nothing has run.
var server: DotServer = null

## Suffix for every registry name this node publishes.
##
## [b]Not cosmetic.[/b] `examples/sandbox.tscn` runs a server and two clients in one
## process, and three routers registered under one name means two of them are invisible
## and dot-chat's gag lookup finds whichever registered last.
var service_scope: StringName = &""

## Where punishments are written. Overridable so a test does not write to a real one.
var punishments_path: String = PUNISHMENTS_PATH

## Whether the store had answered by the time [method setup] returned.
##
## True for a file store, which is every deployment of this game. Reported by
## `room_services`, because a server enforcing nothing and a server with nothing to
## enforce look identical from outside.
var punishments_loaded: bool = false


## Builds all three.
##
## [b]Deliberately not a coroutine, and that is a constraint from dot-server rather than a
## preference.[/b] [method DotModuleHost.load_module] calls `_module_load()` with a bare
## call and reads `result.ok` on the next line — so a module whose load suspends returns
## null there and the host crashes on a module that was working. Every call in here is
## therefore synchronous, and the one thing that genuinely could suspend — reading the
## punishment store — is handled in [method _build_moderation] with the reason written
## beside it.
func setup() -> DotResult:
	if bridge == null or world == null:
		return DotResult.fail(
			DotError.CODE_STATE, "The room's services need a bridge and a world."
		)

	# [b]Moderation first, and the order is load bearing.[/b] It is what registers
	# `dot_mute_source`, and [method DotChatRouter.start] warns once — and then never
	# again — when there is nothing under that name. Starting the router first would
	# produce a server that logs "no gag source" on boot and then gags nobody, with the
	# warning scrolled off by the time anybody tried.
	var punished := _build_moderation()

	if not punished.ok:
		return punished

	var talking := _build_chat()

	if not talking.ok:
		return talking

	# After chat, because it needs the router; not fatal, because a relay that cannot
	# start is a server that still runs a perfectly good match.
	var relayed := _build_relay()
	DotLog.result(CHANNEL, "the website chat relay", relayed)

	return _build_voice()


func _exit_tree() -> void:
	# Nothing is unregistered by hand: every one of the three unregisters itself in its
	# own `_exit_tree`, and doing it twice is how a scope that is still in use gets
	# cleared out from under the other copy.
	pass


# --- Moderation ------------------------------------------------------------

func _build_moderation() -> DotResult:
	moderation = DotModerationManager.new()
	moderation.name = "Moderation"
	moderation.store = DotPunishmentStoreFile.new(punishments_path)

	# [b]No scope, and that is the case worth getting right.[/b] dot-moderation shipped a
	# bug where a server with no scope saw no scoped punishments — so the unconfigured
	# case, which is the only case a single-server lobby is ever in, was the one that
	# silently enforced nothing. Left empty here deliberately, so this game runs the
	# configuration that used to be broken.
	moderation.server_scope = ""
	moderation.register_mute_source = true
	moderation.register_ban_source = true

	# Zero means "no immunity to respect", not "the highest rank there is". A lobby that
	# has not configured immunity at all is every ordinary unmute, and requiring strictly
	# greater immunity unconditionally made 0 unable to act on 0 — dot-moderation's own
	# bug, and the reason this is set rather than left.
	moderation.equal_immunity_may_act = true

	# How a peer becomes a person. [b]The account uid when there is one, and the session's
	# own uid otherwise[/b] — never the peer id, which is reassigned on reconnect, and
	# never the address, which is what a household shares.
	moderation.key_for_peer = _subject_for_peer

	add_child(moderation)

	# [b]A bare statement call, and this is the one place in this file that needs
	# explaining.[/b] [method DotModerationManager.load_all] is a coroutine because a
	# store MAY be an HTTP one; [DotPunishmentStoreFile] is not, so the call runs to
	# completion without ever suspending and the records are in force by the next line.
	# It cannot be awaited here, because this is reached from `_module_load` and
	# dot-server's module host does not await that — see [method setup].
	#
	# A deployment that swaps in [DotPunishmentStoreRest] genuinely does suspend, and the
	# check below is what says so out loud rather than leaving a server that quietly
	# enforces nothing for the first second of its life. That is the honest half: the fix
	# is a `PROFILE`-shaped load stage in dot-server, which is the same gap dot-platform's
	# module documents.
	moderation.load_all()

	if not moderation.store.is_writable():
		DotLog.warn(CHANNEL, "the punishment store cannot be written to", {
			"path": punishments_path,
		})

	punishments_loaded = true

	return DotResult.success(null)


## Who a peer is, for a punishment.
##
## [b]The durable account uid, and NOT the same answer [method _key_of] gives dot-chat.[/b]
## The two addons ask two different questions through two different seams and this is the
## whole reason both seams exist:
##
## - a punishment is against a **person who will come back**, so it is keyed by something
##   that survives a reconnect — otherwise a gag lasts until the gagged player presses
##   reconnect, which is the first thing anybody who has been gagged tries, and is exactly
##   the bug dot-moderation was written to fix in dot-server's two-booleans-on-a-session;
## - a chat line is attributed to **somebody standing in this room right now**, which is
##   an occupant.
##
## They are not interchangeable and the difference is measurable: two guests connecting
## from one machine share a device id and therefore share a uid, so keying a chat line by
## it puts the second person's words over the first person's head. That is not
## hypothetical — `examples/sandbox.tscn` runs two clients in one process and found it.
func _subject_for_peer(peer_id: int) -> String:
	var session := _session_for(peer_id)

	if session == null:
		# No server: an offline run, where a session id is the most durable thing there
		# is. Prefixed so it can never be mistaken for a real uid in a stored punishment.
		var occupant := bridge.occupant_for_peer(peer_id) if bridge != null else null
		return DotPunishmentSubject.for_uid("offline:%d" % occupant.id) \
			if occupant != null else ""

	return DotPunishmentSubject.for_uid(session.uid())


# --- Chat ------------------------------------------------------------------

func _build_chat() -> DotResult:
	chat = DotChatRouter.new()
	chat.name = "Chat"
	chat.rules = chat_rules()
	chat.rules_file = ""
	# The defaults are a shooter's — everyone, team, whisper — and this room has no teams.
	# Building them here means the set is exactly the four below and a fifth cannot arrive
	# from a version bump nobody noticed.
	chat.install_default_channels = false
	chat.handle_me_command = true
	chat.register_as = _scoped(DotChatRouter.SERVICE)
	chat.mute_service = _scoped(DotModerationManager.MUTE_SERVICE) \
		if service_scope != &"" else DotModerationManager.MUTE_SERVICE

	chat.send_fn = _send_chat
	chat.peers_fn = _chat_peers
	chat.name_fn = _name_of
	chat.key_fn = _key_of
	chat.position_fn = _position_of
	chat.is_admin_fn = _is_admin

	add_child(chat)

	var started := chat.start()

	if not started.ok:
		return started.wrap("The chat router could not start")

	for channel in chat_channels():
		var added := chat.add_channel(channel)

		if not added.ok:
			return added.wrap("A chat channel was refused")

	chat.command_entered.connect(_on_command_entered)

	return DotResult.success(null)


## The four channels this room has.
##
## [b]"Near" is the one that is not decoration.[/b] A lobby with one channel is a lobby
## where thirty people are in one conversation and nobody can have another; a lobby where
## walking over to somebody means something is a lobby that is a place. It is also the
## only reason the room has landmarks — "by the north-west pillar" is a thing you can say
## because standing there means being heard by the people who are also there.
static func chat_channels() -> Array[DotChatChannel]:
	var out: Array[DotChatChannel] = []

	var everyone := DotChatChannel.make(CHANNEL_ALL, "Room", DotChatChannel.Scope.EVERYONE)
	everyone.prefix = ""
	everyone.colour = Color(0.93, 0.94, 0.96)
	# Enough that somebody who joins mid-conversation is not staring at an empty box, and
	# few enough that the wire cost of a join is a few kilobytes rather than a hundred.
	everyone.backlog = 20
	everyone.history_limit = 200
	out.append(everyone)

	var near := DotChatChannel.make(CHANNEL_NEAR, "Near", DotChatChannel.Scope.RADIUS)
	near.prefix = "[near]"
	near.colour = Color(0.68, 0.83, 0.62)
	near.radius = NEAR_RANGE
	# [b]No backlog on a proximity channel, and that is a privacy decision rather than a
	# bandwidth one.[/b] A backlog is sent to whoever joins, and a line somebody said
	# quietly in a corner is precisely the line that must not be replayed to a stranger
	# who was not standing there.
	near.backlog = 0
	near.history_limit = 120
	out.append(near)

	var admin := DotChatChannel.make(CHANNEL_ADMIN, "Admin", DotChatChannel.Scope.EVERYONE)
	admin.prefix = "[ADMIN]"
	admin.colour = Color(0.98, 0.72, 0.35)
	admin.admin_only = true
	# An admin talking to other admins is not something a gag should stop: a gag is about
	# a player's speech, and an admin who has been gagged has a bigger problem than chat.
	admin.ignores_gag = true
	admin.backlog = 0
	out.append(admin)

	var whisper := DotChatChannel.make(
		CHANNEL_WHISPER, "Whisper", DotChatChannel.Scope.DIRECT
	)
	whisper.prefix = "[w]"
	whisper.colour = Color(0.78, 0.71, 0.93)
	whisper.backlog = 0
	out.append(whisper)

	return out


## What a line may be.
##
## Every one of these is a lobby-specific number rather than dot-chat's default, and the
## two that differ most are the ones a room full of people notices: a lobby is chattier
## than a shooter, so the rate is higher, and a lobby is read rather than glanced at, so
## the line is longer.
static func chat_rules() -> DotChatRules:
	var rules := DotChatRules.new()
	rules.max_length = 200
	rules.refuse_over_length = false
	rules.allow_newlines = false
	rules.escape_markup = true
	rules.strip_invisible = true
	rules.collapse_whitespace = true
	rules.rate_per_minute = 30
	rules.burst = 5.0
	# Ten seconds of silence for a flood, rather than nothing. Nothing means the limiter
	# refuses one line and lets the next through, which is a flood with gaps in it.
	rules.flood_penalty_sec = 10.0
	rules.duplicate_window_sec = 8.0
	rules.duplicate_depth = 3
	rules.command_prefixes = PackedStringArray(["!", "/"])
	# An unclaimed `!command` is not broadcast. Otherwise a player typing `!ban` at a
	# server with no such command says "!ban" to the whole room, which is worse than
	# nothing happening.
	rules.broadcast_unknown_commands = false
	rules.history_limit = 400
	return rules


func _on_command_entered(
	peer: int, command: String, args: PackedStringArray, _raw: String
) -> void:
	command_entered.emit(peer, command, args)


## Where a routed line goes. dot-chat has already decided exactly who gets it.
func _send_chat(wire: Dictionary, recipients: PackedInt32Array) -> void:
	if bridge == null:
		return

	# Who said it, as an occupant id, so a client can put a bubble over the right head.
	#
	# [b]It is already in the wire: the key IS the occupant.[/b] See [method _key_of] for
	# why that is the right key rather than the account uid. This lifts it into the one
	# meta field this game's wire carries, so a client can use it without having to parse
	# a field it is meant to treat as opaque.
	var addressed := wire.duplicate()
	var occupant_id := _occupant_for_key(str(wire.get("s", "")))

	if occupant_id > 0:
		addressed["x"] = {"o": occupant_id}

	for peer_id in recipients:
		# Peer by peer, never a broadcast. The router's whole job on a whisper is to
		# produce a list of two, and handing that to a broadcast would undo it.
		bridge.send_chat(int(peer_id), addressed)


func _occupant_for_key(key: String) -> int:
	return key.to_int() if key.is_valid_int() else 0



# --- The website relay -----------------------------------------------------

## Joins this server's chat to its room on the website.
##
## [b]Every seam points at something that already existed.[/b] The backbone client is
## dot-auth's. The permission answer is dot-server's admin manager, through
## `uid_has_permission` — the method written for exactly this, deciding what somebody may
## do when they are not connected. The command runner is `DotServer.run_command_as_uid`,
## which builds a context with that uid's OWN flags rather than RCON's root.
##
## Nothing here is a new policy. A relayed command is checked against the same file, by
## the same flags, as the same person typing it in game.
func _build_relay() -> DotResult:
	if relay_config == null:
		relay_config = DotChatRelayConfig.new()

	if not relay_config.enabled:
		return DotResult.success(null)

	if backbone == null:
		# **Found, not handed over.** A backbone client is built by whatever owns the
		# server's credential — dot-server-setup-test's `TmcReport`, or this game's own
		# identity layer — and a relay built during module load exists before any host
		# could assign one. `DotBackboneClient` publishes itself under this name for
		# exactly that reason; the ordering trap is the one that left dot-server's audit
		# log unopened in every default configuration.
		backbone = DotRegistry.get_service(&"dot_backbone_client")

	if backbone == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The chat relay is on but no backbone client was handed to services."
		)

	relay = DotChatRelay.new()
	relay.name = "ChatRelay"
	relay.router = chat
	relay.config = relay_config
	relay.client = backbone
	relay.permission_fn = _uid_has_permission
	relay.command_fn = _run_relayed_command

	add_child(relay)

	var started := relay.start()

	if not started.ok:
		remove_child(relay)
		relay.queue_free()
		relay = null
		return started

	relay.site_command.connect(_on_site_command)

	return DotResult.success(relay)


func _uid_has_permission(uid: String, flag: String) -> bool:
	if server == null or server.admins == null:
		return false
	return server.admins.uid_has_permission(uid, flag)


func _run_relayed_command(
	uid: String, command: String, args: PackedStringArray, source: int
) -> void:
	if server == null:
		return

	for reply in server.run_command_as_uid(uid, command, args, source):
		DotLog.info(CHANNEL, "relayed command reply", {"uid": uid, "line": reply})


func _on_site_command(uid: String, command: String, allowed: bool) -> void:
	# Audited either way. A refusal is the half worth having a record of: it is somebody
	# trying to drive the server from a web page without the rights to.
	if server != null and server.audit != null:
		server.audit.record(
			"relay_command", "web:%s" % uid, command, {"allowed": allowed}
		)


# --- Voice -----------------------------------------------------------------

func _build_voice() -> DotResult:
	var config := voice_config()
	var problem := config.validate()

	if not problem.ok:
		return problem.wrap("The room's voice configuration is not usable")

	voice = DotVoiceRouter.new()
	voice.name = "Voice"
	voice.config = config
	# [b]Everybody, not proximity, and this is the one place the two chat channels and
	# the voice channel deliberately disagree.[/b] Text has a near channel because you can
	# read two conversations at once and choose; voice you cannot, and a lobby where you
	# walk out of earshot mid-sentence is a lobby where nobody uses voice. The proximity
	# machinery is wired and reachable — `position_fn` is set below — so a deployment that
	# wants it changes one line.
	voice.default_channel = DotVoiceRouter.Channel.ALL
	voice.proximity_range = config.proximity_range
	voice.max_bytes_per_second = config.max_bytes_per_second
	voice.send_fn = _send_voice
	# The same answer text's proximity channel gets, from the same function. A second
	# "where is this person" is a second thing that can be a tick out of step with the
	# first, and the visible failure would be hearing somebody you cannot read.
	voice.position_fn = _position_of

	add_child(voice)

	return DotResult.success(null)


## The voice format, which both ends must agree on exactly.
##
## [b]Static, and read by the client as well.[/b] [DotVoiceConfig.format_fingerprint]
## exists because a sample rate or a frame length that differs between two peers is a
## stream of packets the router refuses for being the wrong length — with the refusal
## counted and nothing said to anybody. Same argument as the room's size: a value both
## ends need and neither can measure belongs in one file.
static func voice_config() -> DotVoiceConfig:
	var config := DotVoiceConfig.new()
	# 16 kHz rather than 24: this is speech in a chat room, not a broadcast, and it is a
	# third fewer bytes for a difference nobody notices through a laptop speaker.
	config.sample_rate = 16000
	config.frame_ms = 20.0
	config.codec_id = &"adpcm"
	config.push_to_talk = true
	config.activation_rms = 0.02
	config.hangover_ms = 250.0
	config.input_gain = 1.0
	config.jitter_ms = 60.0
	config.jitter_max_ms = 400.0
	config.output_gain = 1.0
	config.proximity_range = NEAR_RANGE
	# One speaker at 16 kHz ADPCM is about 4 kB/s. The cap is a little over that, so a
	# client sending its own frames plus a burst is fine and a client sending twice the
	# frame rate is not.
	config.max_bytes_per_second = 6144
	return config


## Where a relayed voice frame goes.
func _send_voice(peer_id: int, payload: PackedByteArray) -> void:
	if bridge == null or bridge.link == null:
		return

	bridge.link.send_voice(peer_id, payload)


# --- Peers -----------------------------------------------------------------

## Somebody can now hear and be heard.
func add_peer(peer_id: int) -> void:
	if voice != null:
		voice.add_peer(peer_id)


func remove_peer(peer_id: int) -> void:
	if voice != null:
		voice.remove_peer(peer_id)

	if chat != null:
		# The rate limiter's and the repeat detector's memory of this peer, dropped.
		# Without it a reconnecting player inherits whatever the last holder of that peer
		# id had been saying, and the visible failure is "you are repeating yourself" to
		# somebody who has said one thing.
		chat.forget(peer_id)


func _chat_peers() -> PackedInt32Array:
	return bridge.ready_peers() if bridge != null else PackedInt32Array()


func _session_for(peer_id: int) -> DotClientSession:
	if server == null:
		return null

	return server.session_of(peer_id)


func _name_of(peer_id: int) -> String:
	var session := _session_for(peer_id)

	if session != null:
		return session.display_name

	var occupant := bridge.occupant_for_peer(peer_id) if bridge != null else null
	return occupant.display_name if occupant != null else "player %d" % peer_id


## The key a chat line is attributed to: the speaker's occupant, as a string.
##
## [b]Not the account uid, and the difference is the subject of the comment on
## [method _subject_for_peer].[/b] "Who said this" is a question about the room — the
## bubble goes over a head, the name in the log is a name in this room, and a client
## resolving it has a roster and nothing else. Two guests behind one device id share a
## uid, so keying by that draws the second person's words over the first person's face,
## and every count still matches.
##
## [b]It is still pseudonymous and it still never leaves this server as an account id.[/b]
## An occupant id is dot-server's session id: it means nothing to anybody who was not in
## this room at this moment, which is exactly the property dot-user's per-scope ids exist
## for and dot-stats refuses an account id in order to keep.
func _key_of(peer_id: int) -> String:
	var occupant := bridge.occupant_for_peer(peer_id) if bridge != null else null
	return str(occupant.id) if occupant != null else ""


## Where somebody is standing, as dot-chat and dot-voice both ask for it.
##
## [b]A [Vector3] with z fixed at zero, and the third component being always zero on both
## sides is what makes this correct.[/b] Both addons compare with a 3D distance;
## dot-npc-ai measured two NPCs standing on each other as 1.8 metres apart by asking a 3D
## question about a horizontal problem. Here there is no vertical to lose, so the 3D
## distance IS the 2D one.
func _position_of(peer_id: int) -> Vector3:
	if bridge == null or world == null:
		return Vector3.ZERO

	var occupant := bridge.occupant_for_peer(peer_id)

	if occupant == null:
		return Vector3.ZERO

	var at := occupant.position()
	return Vector3(at.x, at.y, 0.0)


func _is_admin(peer_id: int) -> bool:
	var session := _session_for(peer_id)
	return session != null and session.is_admin()


func _scoped(base: StringName) -> StringName:
	return base if service_scope == &"" else StringName("%s:%s" % [base, service_scope])


# --- Reporting -------------------------------------------------------------

func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if chat != null:
		out.append_array(chat.describe_lines())

	if voice != null:
		out.append_array(voice.describe_lines())

	if moderation != null:
		out.append_array(moderation.describe_lines())
		out.append("punishments  %s" % (
			"loaded" if punishments_loaded else "STILL LOADING — nothing is enforced"
		))

	return out
