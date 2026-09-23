extends DotNetMessage

const RoomEvents := preload("room_events.gd")

## Everything a client asks the authority for.
##
## Today that is one thing — "I have loaded, tell me about the room" — and it is still a
## message with a kind rather than a bare signal, because the next one (a name change, a
## seat, an emote) must not be a second registered type on one side only.
##
## [b]Nothing here carries state.[/b] A client sends what it *wants*; where it is standing
## is [RoomNetCommand]'s, and even that is an intent rather than a position. A client that
## could send a position could send any position.

const NAME := &"room.request"

const KIND_BITS := 4
const MAX_BODY := 512

var kind: int = 0
var body: PackedByteArray = PackedByteArray()


## [b]Built with [code]new(kind, body)[/code], and this file does not preload itself.[/b]
## It used to, for a typed [code]static func of() -> RoomRequest[/code] factory. A script that
## [code]extends DotNetMessage[/code] and preloads ITSELF, first loaded from a module a
## running [DotServer] loads at runtime — which is how every deployed server loads this
## game — leaks the whole script graph at exit on Godot 4.7.2. Measured in
## mg-buses-from-hell (8ed866c) with a two-line reproduction. The registry decodes with a
## bare [code]new()[/code], which is why both arguments default.
func _init(p_kind: int = 0, p_body: PackedByteArray = PackedByteArray()) -> void:
	kind = p_kind
	body = p_body


func _type_name() -> StringName:
	return NAME


func _write(writer: DotNetWriter) -> void:
	writer.write_uint(kind, KIND_BITS)
	writer.write_bytes(body)


func _read(reader: DotNetReader) -> void:
	kind = reader.read_uint(KIND_BITS)
	body = reader.read_bytes(MAX_BODY)


func _validate() -> DotResult:
	if kind < 0 or kind >= RoomEvents.Ask.size():
		return DotResult.fail(DotError.CODE_INVALID, "Unknown ask %d." % kind)

	return DotResult.success(true)


func reader() -> DotNetReader:
	return DotNetReader.new(body)


func _to_string() -> String:
	return "RoomRequest(%d, %d bytes)" % [kind, body.size()]
