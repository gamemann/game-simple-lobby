class_name RoomEvents
extends RefCounted

## The wire format for everything that is not a snapshot or an input.
##
## Encoders and decoders in one place, in pairs, because they have to be exact inverses
## and nothing can check that for you — `examples/headless_net.tscn` round-trips every
## one of them for that reason.
##
## [b]Chat travels here now, and that is not a second chat path.[/b] It used to be
## dot-server's, whole — routed, sanitised and flood-limited by [DotChatManager] and
## delivered through [signal DotClientLink.chat_received]. What changed is that
## [DotChatRouter] took over the *rules*, because a lobby wants what dot-server's chat
## does not have: channels with an audience, a radius so somebody across the room is not
## in your conversation, a backlog for whoever just walked in, and a gag that survives a
## reconnect. There is still exactly one path. [RoomModule] cancels dot-server's own
## `player_chat` broadcast and hands the line to the router, and the router's `send_fn`
## comes out here — so the filter is still unskippable and there is still one set of
## rules, they are simply better rules. The thing that would be a bug is *two* of them.
##
## [b]Voice is deliberately NOT here.[/b] It is fifty packets a second and this message is
## reliable; a talk spurt would put a hundred retransmittable events in front of a join.
## [RoomLink] carries it on its own unreliable call — see `send_voice` there for why one
## call serves both a UDP desktop client and a TCP browser one.

## What the authority sends.
enum Kind {
	## Who you are, what tick it is, how big the room is. The first thing a client is told.
	HELLO,
	## Somebody is in the room: their id, their name, and where they entered.
	##
	## Sent once per person on join, and once per person already here when *you* join.
	## One kind for both, because a client that had to distinguish "the roster" from "a
	## join" would need two handlers that must agree, and they would not.
	JOIN,
	## Somebody left.
	LEAVE,
	## An occupant became a replicated entity and should be mirrored.
	SPAWN,
	## An occupant's entity is gone.
	DESPAWN,
	## The roster has been sent in full; everything after this is live.
	##
	## Not decoration: a client that drew its roster as the JOINs arrived would show the
	## room filling up one person at a time on every connect, and would have no moment at
	## which it could say "you are in".
	ROSTER_END,
	## One chat line, already routed, sanitised and addressed by [DotChatRouter].
	##
	## The server decides who gets one; a client that receives it draws it. There is no
	## audience field on the wire for that reason — a client told who *else* could hear a
	## whisper would be a client that could report it.
	CHAT,
	## Somebody put something in the room.
	PROP_PLACED,
	## Something in the room is gone: undone, cleaned up after a leave, or cleared.
	PROP_CLEARED,
	## Somebody's avatar document, as the ids that make it up.
	##
	## Separate from [constant Kind.JOIN] rather than folded into it, because an avatar
	## arrives *later* than the person does — dot-platform resolves a profile and an
	## avatar asynchronously and a lobby must not hold somebody at the door while a
	## cosmetic loads. A player you cannot see is worse than a player with no hat.
	AVATAR,
}

## What a client asks for.
enum Ask {
	## I have loaded and have somewhere to put events. Tell me about the room.
	READY,
	## I typed a line. The server decides what channel it lands on and who hears it.
	##
	## [b]The channel is a request, not an instruction.[/b] It is what the player had
	## selected; [DotChatRouter] validates it against the channel's own permission rules,
	## so asking for the admin channel is refused rather than obeyed.
	SAY,
	## Put this in the room, here.
	PLACE_PROP,
	## Take back the last thing I put in the room.
	UNDO_PROP,
}

## Position range, matching [Dot2DNetSync] so that a position sent as an event and the
## same position sent in a snapshot quantise identically. Two grids for one coordinate is
## a person standing a pixel from where the server says they are, forever.
const POSITION_BITS := Dot2DNetSync.POSITION_BITS
const WORLD_EXTENT := Dot2DNetSync.WORLD_EXTENT

const NAME_BYTES := RoomContent.NAME_BYTES


static func kind_name(kind: int) -> String:
	var names := Kind.keys()
	return String(names[kind]) if kind >= 0 and kind < names.size() else "?"


static func _write_position(writer: DotNetWriter, at: Vector2) -> void:
	writer.write_vector2_range(at, -WORLD_EXTENT, WORLD_EXTENT, POSITION_BITS)


static func _read_position(reader: DotNetReader) -> Vector2:
	return reader.read_vector2_range(-WORLD_EXTENT, WORLD_EXTENT, POSITION_BITS)


# --- HELLO -----------------------------------------------------------------

## [param room_size] is sent even though [RoomContent] is a constant on both ends.
##
## Not redundancy for its own sake: the client checks it and refuses a server whose room
## is a different size, because that mismatch is otherwise silent. Every position would
## still decode, every id would still match, and everybody would simply be standing
## somewhere else — the single most confusing failure dot-2d-hungry found, reached from
## the same direction.
static func write_hello(
	occupant_id: int,
	peer_id: int,
	server_tick: int,
	tick_rate: int,
	room_size: Vector2
) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_varint(occupant_id)
	writer.write_varint(peer_id)
	writer.write_uint(server_tick, 32)
	writer.write_uint(tick_rate, 8)
	writer.write_float32(room_size.x)
	writer.write_float32(room_size.y)
	return writer.to_bytes()


static func read_hello(reader: DotNetReader) -> Dictionary:
	var out := {
		"occupant_id": reader.read_varint(),
		"peer_id": reader.read_varint(),
		"tick": reader.read_uint(32),
		"tick_rate": reader.read_uint(8),
		"room_size": Vector2(reader.read_float32(), reader.read_float32()),
	}
	out["ok"] = reader.ok()
	return out


# --- JOIN / LEAVE ----------------------------------------------------------

static func write_join(
	occupant_id: int,
	display_name: String,
	at: Vector2,
	joined_at: int
) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_varint(occupant_id)
	writer.write_string(display_name, NAME_BYTES)
	_write_position(writer, at)
	# Unix seconds, so a client can say "here for 4 minutes" without the server sending
	# a duration that would be stale the moment it arrived.
	writer.write_uint(joined_at, 32)
	return writer.to_bytes()


static func read_join(reader: DotNetReader) -> Dictionary:
	var out := {
		"occupant_id": reader.read_varint(),
		"name": reader.read_string(NAME_BYTES),
		"position": _read_position(reader),
		"joined_at": reader.read_uint(32),
	}
	out["ok"] = reader.ok()
	return out


static func write_occupant(occupant_id: int) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_varint(occupant_id)
	return writer.to_bytes()


static func read_occupant(reader: DotNetReader) -> int:
	return reader.read_varint()


# --- SPAWN / DESPAWN -------------------------------------------------------

## Ties a net id to an occupant, so a client knows whose the arriving state is.
##
## Sent reliably and before any snapshot mentioning it. A client that meets an entity it
## has not been told to spawn abandons the rest of that snapshot — it cannot skip a
## variable-length body without the declarations — so a late spawn costs every other
## entity in the same packet.
static func write_spawn(
	net_id: int,
	peer_id: int,
	occupant_id: int,
	at: Vector2
) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_varint(net_id)
	writer.write_varint(peer_id)
	writer.write_varint(occupant_id)
	_write_position(writer, at)
	return writer.to_bytes()


static func read_spawn(reader: DotNetReader) -> Dictionary:
	var out := {
		"net_id": reader.read_varint(),
		"peer_id": reader.read_varint(),
		"occupant_id": reader.read_varint(),
		"position": _read_position(reader),
	}
	out["ok"] = reader.ok()
	return out


static func write_despawn(net_id: int) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_varint(net_id)
	return writer.to_bytes()


static func read_despawn(reader: DotNetReader) -> int:
	return reader.read_varint()


static func write_empty() -> PackedByteArray:
	return PackedByteArray()


# --- CHAT ------------------------------------------------------------------

## Longest chat line on the wire. Matches [DotChatRules.max_length]'s default; a longer
## one is truncated by the router before it ever reaches here.
const CHAT_BYTES := 256

## Longest a channel id, a sender key or a display name may be.
const CHAT_CHANNEL_BYTES := 24
const CHAT_KEY_BYTES := 48

## Bits for the kind index. [constant DotChatMessage.KIND_NAMES] has seven entries.
const CHAT_KIND_BITS := 4


## One chat line, from [method DotChatMessage.to_dictionary], plus who said it.
##
## [b]Encoded field by field rather than as JSON.[/b] A JSON body is a variable-length
## blob a reader cannot bound and a hostile server could make enormous, and it costs about
## three times the bytes for a message whose whole point is that it is small and frequent.
##
## [b]The `x` (meta) field is not carried as a dictionary, and one value is lifted out of
## it.[/b] A wire that carried an arbitrary dictionary would be an arbitrary dictionary a
## server could put anything in. What this game needs from it is exactly one number — the
## occupant the line belongs to, so a bubble can be drawn over the right head — so that is
## a field, bounded like every other, and the reader puts it back under `x` where
## [method DotChatMessage.from_dictionary] will find it. Two or three bytes a line against
## forty-eight bytes a person on the join, which is what carrying the key on the roster
## instead would have cost.
##
## The kind travels as an **index into [constant DotChatMessage.KIND_NAMES]**, not as the
## name. The names are the table dot-moderation shipped a bug about — a store that wrote a
## player-facing name and read it back through a parser that had no case for it — so this
## uses the one table in both directions and `headless_net` walks every value of the enum
## through the pair.
static func write_chat(wire: Dictionary) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_varint(int(wire.get("n", 0)))
	writer.write_uint(int(wire.get("t", 0)), 32)
	writer.write_string(str(wire.get("c", "")), CHAT_CHANNEL_BYTES)
	writer.write_uint(
		maxi(0, DotChatMessage.kind_from_name(str(wire.get("k", "say")))), CHAT_KIND_BITS
	)
	writer.write_string(str(wire.get("s", "")), CHAT_KEY_BYTES)
	writer.write_string(str(wire.get("d", "")), NAME_BYTES)
	writer.write_string(str(wire.get("w", "")), CHAT_KEY_BYTES)
	writer.write_string(str(wire.get("m", "")), CHAT_BYTES)

	var meta: Variant = wire.get("x")
	var occupant_id: int = 0

	if typeof(meta) == TYPE_DICTIONARY:
		occupant_id = int((meta as Dictionary).get("o", 0))

	writer.write_varint(maxi(0, occupant_id))
	return writer.to_bytes()


## The inverse. Returns the dictionary [method DotChatClient.receive] takes.
##
## An unknown kind index comes back as `"say"` rather than as an empty string, because
## [method DotChatMessage.from_dictionary] refuses a name it does not know and refusing a
## whole line for a field nobody can see loses the text as well.
static func read_chat(reader: DotNetReader) -> Dictionary:
	var out := {
		"n": reader.read_varint(),
		"t": reader.read_uint(32),
		"c": reader.read_string(CHAT_CHANNEL_BYTES),
	}

	var kind := reader.read_uint(CHAT_KIND_BITS)
	out["k"] = DotChatMessage.KIND_NAMES[kind] \
		if kind >= 0 and kind < DotChatMessage.KIND_NAMES.size() else "say"

	out["s"] = reader.read_string(CHAT_KEY_BYTES)
	out["d"] = reader.read_string(NAME_BYTES)
	out["w"] = reader.read_string(CHAT_KEY_BYTES)
	out["m"] = reader.read_string(CHAT_BYTES)

	var occupant_id := reader.read_varint()

	if occupant_id > 0:
		out["x"] = {"o": occupant_id}

	out["ok"] = reader.ok()
	return out


## What a client sends when somebody presses Enter.
static func write_say(channel_id: StringName, text: String) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_string(String(channel_id), CHAT_CHANNEL_BYTES)
	writer.write_string(text, CHAT_BYTES)
	return writer.to_bytes()


static func read_say(reader: DotNetReader) -> Dictionary:
	var out := {
		"channel": reader.read_string(CHAT_CHANNEL_BYTES),
		"text": reader.read_string(CHAT_BYTES),
	}
	out["ok"] = reader.ok()
	return out


# --- PROPS -----------------------------------------------------------------

## Bits for a prop's index into [method RoomProps.wire_ids].
##
## [b]An index, not a name.[/b] The catalogue is built from the same file on both ends —
## exactly as the room's size is — so sending "bench" would be sending a string both
## machines already have. What travels is which one, and the ordering it indexes is sorted
## as [String] rather than as [StringName], because `Array.sort()` on a StringName
## compares interned pointers: dot-net shipped that bug and two peers gave the same
## message two different ids.
const PROP_KIND_BITS := 8

## Bits for a place id. Monotonic and never reused, so it has to be wide enough for a
## long-lived server: a lobby placing one prop a second wraps this in nine days.
const PLACE_ID_BITS := 20

## Quantisation for a prop's angle. A prop is drawn as a circle or a small rectangle and
## nothing about a lobby needs a tenth of a degree.
const PROP_ROTATION_BITS := 8


static func write_prop_placed(
	place_id: int, prop_index: int, at: Vector2, rotation: float, owner_id: int
) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_uint(place_id, PLACE_ID_BITS)
	writer.write_uint(prop_index, PROP_KIND_BITS)
	_write_position(writer, at)
	writer.write_float_range(rotation, -PI, PI, PROP_ROTATION_BITS)
	writer.write_varint(owner_id)
	return writer.to_bytes()


static func read_prop_placed(reader: DotNetReader) -> Dictionary:
	var out := {
		"place_id": reader.read_uint(PLACE_ID_BITS),
		"prop_index": reader.read_uint(PROP_KIND_BITS),
		"position": _read_position(reader),
		"rotation": reader.read_float_range(-PI, PI, PROP_ROTATION_BITS),
		"owner_id": reader.read_varint(),
	}
	out["ok"] = reader.ok()
	return out


static func write_prop_cleared(place_id: int) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_uint(place_id, PLACE_ID_BITS)
	return writer.to_bytes()


static func read_prop_cleared(reader: DotNetReader) -> int:
	return reader.read_uint(PLACE_ID_BITS)


## What a client asks for when somebody clicks "place".
##
## [b]A position, and the server moves it.[/b] That looks like the thing this family keeps
## warning about — a client that can send a position can send any position — and it is
## not, because [method RoomProps.place] clamps it into the room and pushes it out of the
## furniture before anything is created. What a client is asking for is "about here"; what
## it gets is somewhere legal. Refusing instead would give the player a button that
## silently does nothing near half the landmarks in the room.
static func write_place_prop(
	prop_index: int, at: Vector2, rotation: float
) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_uint(prop_index, PROP_KIND_BITS)
	_write_position(writer, at)
	writer.write_float_range(rotation, -PI, PI, PROP_ROTATION_BITS)
	return writer.to_bytes()


static func read_place_prop(reader: DotNetReader) -> Dictionary:
	var out := {
		"prop_index": reader.read_uint(PROP_KIND_BITS),
		"position": _read_position(reader),
		"rotation": reader.read_float_range(-PI, PI, PROP_ROTATION_BITS),
	}
	out["ok"] = reader.ok()
	return out


# --- AVATARS ---------------------------------------------------------------

## Longest an avatar part id may be, and the most parts one avatar may have.
##
## [b]Bounded on the wire rather than trusted.[/b] An avatar document comes from a store
## and a store is a deployment's, so "how long is a part id" is not a question this game
## gets to assume the answer to. dot-user-avatar validates against a schema; this bounds
## what can arrive before the schema is consulted, which is the half a schema cannot do.
const AVATAR_PART_BYTES := 40
const AVATAR_MAX_PARTS := 12
const AVATAR_SLOT_BITS := 5


## Somebody's avatar, as slot/part pairs and their colours.
##
## [b]Ids only. No mesh, no texture, no scene path.[/b] That is dot-user-avatar's whole
## claim — an avatar is a bounded document a server validates against a schema and an
## entitlement set without ever loading a part — and it is what makes this affordable in a
## room of sixty-four people. What a client does with the ids is a client's business:
## here it draws two circles and a colour, and game-hungario draws a rider.
static func write_avatar(occupant_id: int, parts: Array) -> PackedByteArray:
	var writer := DotNetWriter.new()
	writer.write_varint(occupant_id)

	var count := mini(parts.size(), AVATAR_MAX_PARTS)
	writer.write_uint(count, AVATAR_SLOT_BITS)

	for index in count:
		var entry: Dictionary = parts[index]
		writer.write_string(str(entry.get("slot", "")), AVATAR_PART_BYTES)
		writer.write_string(str(entry.get("part", "")), AVATAR_PART_BYTES)
		var tint: Color = entry.get("colour", Color.WHITE)
		writer.write_uint(tint.to_rgba32() >> 8, 24)

	return writer.to_bytes()


static func read_avatar(reader: DotNetReader) -> Dictionary:
	var occupant_id := reader.read_varint()
	var count := reader.read_uint(AVATAR_SLOT_BITS)
	var parts: Array = []

	for _index in mini(count, AVATAR_MAX_PARTS):
		var slot := reader.read_string(AVATAR_PART_BYTES)
		var part := reader.read_string(AVATAR_PART_BYTES)
		var rgb := reader.read_uint(24)

		# Read past the end returns zeros rather than failing — dot-timer found that with
		# a truncated replay that parsed as a valid replay of nothing — so the loop stops
		# on the reader rather than on the count.
		if not reader.ok():
			break

		parts.append({
			"slot": slot,
			"part": part,
			"colour": Color(
				float((rgb >> 16) & 0xFF) / 255.0,
				float((rgb >> 8) & 0xFF) / 255.0,
				float(rgb & 0xFF) / 255.0
			),
		})

	return {"occupant_id": occupant_id, "parts": parts, "ok": reader.ok()}
