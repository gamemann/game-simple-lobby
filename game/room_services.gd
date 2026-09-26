extends DotGameServices

const RoomBridge := preload("room_bridge.gd")
const RoomWorld := preload("room_world.gd")
const RoomContent := preload("room_content.gd")
const RoomOccupant := preload("room_occupant.gd")

## Chat, moderation, voice and the live tools, wired to this room's people and this room's
## wire.
##
## [b]The sequence is [DotGameServices]'s[/b] — moderation first because it publishes
## `dot_mute_source` and both routers look that name up when they start, then the live
## tools, chat, the website relay, voice — and so are the relay, the admission check, the
## punishment subject's shape and the unbinding of the tool commands. What is left here is
## what is actually this lobby's: four channels, one of them a radius; a line longer and
## chattier than a shooter's; voice for the whole room; walls that stop a near line; a chat
## key that is the occupant rather than the account; and a live-tool set for a room where
## nobody can be hurt.
##
## [b]What this is not: a second chat system.[/b] dot-server ships [DotChatManager], which
## sanitises, rate-limits and broadcasts one channel. A lobby is a game whose entire content
## is the conversation, so it wants what that one does not have, and dot-server's broadcast
## is [b]cancelled[/b] in `RoomModule._on_player_chat` rather than left running beside this.
## There is one path. Two would be two sets of rules, and the one that skipped the filter
## would be the one that leaked admin chat.
##
## [b]It also runs with no server at all.[/b] `--offline` runs the real chat router, the
## real moderation manager and the real voice router with no [DotServer], through the
## base's own sequence — [DotGameServices] takes a null server since 2026-09-25, and this
## file's copy of that sequence went with it. See [method setup].

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

## Where punishments are written by default: [method _services_name] is `room`, so
## [DotGameServices] arrives at exactly this path. Kept as a constant because a host that
## redirects it (`RoomModule.punishments_path`) needs something to redirect FROM.
##
## A file, because this is a lobby and a lobby is what one person runs on a box. The store
## is a [DotPunishmentStore] subclass, so a community pointing it at a shared database is
## one assignment — which is dot-moderation's own answer and the reason a ban is not
## dot-server's `bans.json`: that one is per server, and a person banned from a community
## is banned from all of it.
const PUNISHMENTS_PATH := "user://room_punishments.json"

## Toggles that survive a game change here, beyond dot-moderation's own god and buddha
## (which a lobby refuses anyway).
##
## [b]Blind and beacon are about the person, not the room they are standing in.[/b] A
## moderator who blinded somebody or wanted the room to watch them has not changed their
## mind because the map did — and a change is exactly what somebody being dealt with would
## otherwise wait for to end it.
const PERSIST_ACROSS_CHANGE: Array[String] = ["blind", "beacon"]

## Pixels, not metres: a lobby's avatar is about forty across, and dot-moderation's 1.5
## would land one person on top of the other.
const GOTO_STANDOFF := 48.0


## Where a chat line and a voice frame leave through. Set by `RoomModule` before setup.
var bridge: RoomBridge = null

## The room, for the proximity channel, the walls and the live tools. The same object as
## [member DotGameServices.game], typed; `RoomModule` moves both on a game change.
var world: RoomWorld = null

## Where punishments actually go, whoever chose it. Read-only; set
## [member DotGameServices.punishments_file] to move it.
var punishments_path: String:
	get:
		return _punishments_path()


# --- The sequence ----------------------------------------------------------

## Builds the four layers, in [DotGameServices]'s order.
##
## [b]A null [param p_server] is `--offline`[/b], and the base takes it: every seam past its
## old server guard already answered "no server" sensibly. **No live tools offline** —
## they are commands on a server's console and there is no console, and an offline lobby
## never had them — so [member DotGameServices.mod_tools_enabled] is switched off first.
##
## Deliberately not a coroutine: `RoomOffline` calls it bare, and so does nothing else that
## would notice — [DotGameModule] awaits it, which costs nothing on a function that never
## suspends.
func setup(p_server: DotServer, p_game: Object, p_link: Object) -> DotResult:
	if bridge == null or world == null:
		return DotResult.fail(
			DotError.CODE_STATE, "The room's services need a bridge and a world."
		)

	if p_server == null:
		mod_tools_enabled = false

	var ready: DotResult = super.setup(p_server, p_game, p_link)

	if not ready.ok:
		return ready

	if moderation != null and not (moderation as DotModerationManager).store.is_writable():
		DotLog.warn(CHANNEL, "the punishment store cannot be written to", {
			"path": punishments_path,
		})

	return ready


func _services_name() -> String:
	return "room"


# --- What this lobby says and how --------------------------------------------

func _chat_channels() -> Array:
	return chat_channels()


func _chat_rules() -> Object:
	return chat_rules()


func _voice_config() -> Object:
	return voice_config()


## [b]Everybody, not proximity, and this is the one place the two chat channels and the
## voice channel deliberately disagree.[/b] Text has a near channel because you can read two
## conversations at once and choose; voice you cannot, and a lobby where you walk out of
## earshot mid-sentence is a lobby where nobody uses voice. The proximity machinery is wired
## and reachable — `position_fn` and `can_hear_fn` are both set — so a deployment that wants
## it changes this one line.
func _voice_default_channel() -> int:
	return DotVoiceRouter.Channel.ALL


## The four channels this room has.
##
## [b]Static, and read by the client as well[/b] — the channel palette and the client's own
## router are built from this, so the two ends cannot disagree about what exists.
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


# --- Who somebody is, as this room answers it ---------------------------------

## Who a peer is, for a punishment: the durable account uid.
##
## [b]Not the same answer [method _key_of] gives dot-chat[/b] — a punishment is against a
## person who will come back, a chat line is attributed to somebody standing in this room
## right now, and two guests connecting from one machine share a device id and therefore a
## uid. `examples/sandbox.tscn` runs two clients in one process and found it.
##
## The base's answer, plus the one it cannot give: with no server, an offline run, the
## session is the occupant, prefixed so it can never be mistaken for a real uid in a
## stored punishment.
func _subject_for_peer(peer_id: int) -> String:
	if _session_for(peer_id) != null:
		return super._subject_for_peer(peer_id)

	var occupant := bridge.occupant_for_peer(peer_id) if bridge != null else null
	return DotPunishmentSubject.for_uid("offline:%d" % occupant.id) \
		if occupant != null else ""


## The key a chat line is attributed to: the speaker's OCCUPANT, as a string.
##
## Online that is the session's userid — the base's own answer, because an occupant id IS
## dot-server's session id — and offline, with no session, it is still an answer. It is
## still pseudonymous and never leaves this server as an account id: an occupant id means
## nothing to anybody who was not in this room at this moment.
func _key_of(peer_id: int) -> String:
	var occupant := bridge.occupant_for_peer(peer_id) if bridge != null else null
	return str(occupant.id) if occupant != null else ""


func _name_of(peer_id: int) -> String:
	if _session_for(peer_id) != null:
		return super._name_of(peer_id)

	var occupant := bridge.occupant_for_peer(peer_id) if bridge != null else null
	return occupant.display_name if occupant != null else "player %d" % peer_id


## Everybody who has said they can receive — NOT dot-server's playing sessions, the base's
## answer. A session exists from the moment a socket connects; a ready peer is one that has
## built its scene. Routing a chat line to the first is a "Node not found" per recipient
## and a line nobody got. It is also the only answer offline has.
func _chat_peers() -> PackedInt32Array:
	return bridge.ready_peers() if bridge != null else PackedInt32Array()


## Where somebody is standing, as dot-chat and dot-voice both ask for it.
##
## [b]A [Vector3] with z fixed at zero, and the third component being always zero on both
## sides is what makes this correct.[/b] Both addons compare with a 3D distance; here there
## is no vertical to lose, so the 3D distance IS the 2D one.
func _position_of(peer_id: int) -> Vector3:
	if bridge == null or world == null:
		return Vector3.ZERO

	var occupant := bridge.occupant_for_peer(peer_id)

	if occupant == null:
		return Vector3.ZERO

	var at := occupant.position()
	return Vector3(at.x, at.y, 0.0)


## Whether a listener inside the near radius can hear the speaker through the room.
##
## [b]The level's answer, not the addons'.[/b] dot-chat and dot-voice know a distance and
## nothing about walls, which is right: what blocks a voice is this room's decision and
## lives in [method RoomContent.within_earshot] beside the posts it tests. Both routers
## ask this one function — [DotGameServices] wires it into both as their `can_hear_fn`
## — so nobody can read a line from somebody they could not hear. Without it the wing is a
## separate room geometrically and not acoustically: "near" reaches 420 and the partition
## is 180 thick.
func _can_hear(_listener: int, _speaker: int, listener_at: Vector3, speaker_at: Vector3) -> bool:
	return RoomContent.within_earshot(
		Vector2(listener_at.x, listener_at.y), Vector2(speaker_at.x, speaker_at.y)
	)


# --- The wire ------------------------------------------------------------------

## Where a routed line goes. dot-chat has already decided exactly who gets it.
##
## The base's fan-out, plus one field: who said it, as an occupant id, so a client can put
## a bubble over the right head. It is already in the wire — the key IS the occupant, see
## [method _key_of] — and this lifts it into the one meta field this game's wire carries,
## so a client need not parse a field it is meant to treat as opaque.
func _send_chat(wire: Dictionary, recipients: PackedInt32Array) -> void:
	if bridge == null:
		return

	var addressed := wire.duplicate()
	var key := str(wire.get("s", ""))
	var occupant_id := key.to_int() if key.is_valid_int() else 0

	if occupant_id > 0:
		addressed["x"] = {"o": occupant_id}

	for peer_id in recipients:
		# Peer by peer, never a broadcast. The router's whole job on a whisper is to
		# produce a list of two, and handing that to a broadcast would undo it.
		bridge.send_chat(int(peer_id), addressed)


## Never at seating: the backlog waits for the welcome.
##
## [DotGameServices.add_peer] would send it at once, and in this game that is too early: a
## peer is added when dot-server says it spawned, and the client builds its scene after
## that, so a line sent now lands on a node that does not exist, one "Node not found" per
## line. `RoomModule._welcome` sends it once the peer has said it can receive. Voice is
## still added at seating, by the base.
func _peer_can_receive(_peer_id: int) -> bool:
	return false


# --- The live tools, in a room where nobody can be hurt ------------------------

## What the live admin set means in a lobby, which is very little, and says so.
##
## [b]Moving people and renaming them is what a lobby needs a moderator for[/b] — so bring,
## goto, send, return and rename work, and so do noclip, freeze and speed, the first being
## the one a lobby actually needs, for somebody wedged in the furniture. Those three are
## dot-2d's [Dot2DAdminModifiers], in the occupant's replicated state, because a server that
## moved somebody their own client does not know about would rubber-band them;
## `headless_net` measures that against a naive control. Blind and beacon are two flags on
## the occupant the client draws — the blind replicated to its owner alone, the beacon to
## everybody.
##
## The blind takes the room away and nothing else: the blinded person still walks, and
## still has the chat log, the roster and the entry, because in a lobby those are how a
## moderator tells them why. One who wants them to stop moving as well has freeze.
func _mod_abilities() -> Dictionary:
	return {
		DotModTools.ACTION_RENAME: func(id: StringName, args: Dictionary) -> DotResult:
			var occupant := _occupant(id)
			if occupant == null:
				return _nobody()
			occupant.display_name = str(args["name"]).strip_edges().substr(0, 32)
			return DotResult.success(occupant.display_name),
		DotModTools.ACTION_NOCLIP: func(id: StringName, args: Dictionary) -> DotResult:
			return Dot2DAdminModifiers.set_noclip(_occupant_state(id), bool(args["on"])),
		DotModTools.ACTION_FREEZE: func(id: StringName, args: Dictionary) -> DotResult:
			return Dot2DAdminModifiers.set_frozen(_occupant_state(id), bool(args["on"])),
		DotModTools.ACTION_SPEED: func(id: StringName, args: Dictionary) -> DotResult:
			return Dot2DAdminModifiers.set_speed(_occupant_state(id), float(args["scale"])),
		DotModTools.ACTION_BLIND: func(id: StringName, args: Dictionary) -> DotResult:
			var occupant := _occupant(id)
			if occupant == null:
				return _nobody()
			occupant.blinded = bool(args["on"])
			return DotResult.success(occupant.blinded),
		DotModTools.ACTION_BEACON: func(id: StringName, args: Dictionary) -> DotResult:
			var occupant := _occupant(id)
			if occupant == null:
				return _nobody()
			occupant.beacon = bool(args["on"])
			return DotResult.success(occupant.beacon),
	}


## Everything else, refused with a reason `modtools` prints.
func _mod_unsupported() -> Dictionary:
	var harmless := "nobody can be hurt in a lobby"
	var nothing := "there is nothing to hold in a lobby"

	return {
		DotModTools.ACTION_GRAVITY: "there is no gravity in a top-down room",
		DotModTools.ACTION_GOD: harmless,
		DotModTools.ACTION_BUDDHA: harmless,
		DotModTools.ACTION_HEALTH: harmless,
		DotModTools.ACTION_SLAY: harmless,
		DotModTools.ACTION_SLAP: harmless,
		DotModTools.ACTION_BURN: harmless,
		DotModTools.ACTION_RESPAWN: "nobody dies in a lobby; bring or send moves somebody",
		DotModTools.ACTION_GIVE: nothing,
		DotModTools.ACTION_STRIP: nothing,
	}


func _mod_can_teleport() -> bool:
	return true


func _mod_position(id: StringName) -> Variant:
	var occupant := _occupant(id)
	return occupant.state.position if occupant != null else null


func _mod_teleport(id: StringName, to: Variant) -> void:
	var occupant := _occupant(id)

	if occupant != null and to is Vector2:
		occupant.state.position = to as Vector2
		occupant.state.velocity = Vector2.ZERO


## The two settings a lobby's tools differ in, before they are bound.
##
## A lobby has no respawn, and its "new body" is a game change — `RoomBridge.rebind`
## re-adds everybody as a fresh occupant, and `RoomModule` then calls `respawned` for each —
## so [constant PERSIST_ACROSS_CHANGE] is what survives it.
func _mod_configure_tools(tools: Object) -> void:
	var mod := tools as DotModTools

	if mod == null:
		return

	mod.goto_standoff = GOTO_STANDOFF

	for action in PERSIST_ACROSS_CHANGE:
		if not mod.persist_on_respawn.has(action):
			mod.persist_on_respawn.append(action)


## The occupant a moderator named, or null. The id is the session userid as a string,
## which is the occupant id — see [method _key_of].
func _occupant(id: StringName) -> RoomOccupant:
	if world == null or not is_instance_valid(world) or not String(id).is_valid_int():
		return null

	return world.occupant_for(String(id).to_int())


## The state an admin modifier is written into, or null — which [Dot2DAdminModifiers]
## refuses with a reason rather than crashing on.
func _occupant_state(id: StringName) -> Dot2DState:
	var occupant := _occupant(id)
	return occupant.state if occupant != null else null


func _nobody() -> DotResult:
	return DotResult.fail(DotError.CODE_STATE, "Nobody by that id is in the room.")
