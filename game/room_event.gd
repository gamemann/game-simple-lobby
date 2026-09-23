extends DotNetMessage

const RoomEvents := preload("room_events.gd")

## Everything the authority tells a client that is not a snapshot.
##
## [b]One message type with a kind byte, rather than six registered types.[/b]
## [DotNetMessageRegistry] fixes ids from the sorted names and hashes the set, so two
## builds that disagree about the schema are refused rather than misread — and that
## guarantee is exactly as strong with one type as with six, while the failure mode of
## "a type registered on one side only" disappears entirely. The kind is validated
## against [enum RoomEvents.Kind] on receipt, which is the check the registry would
## have done.
##
## The direction is [constant DotNetMessage.Direction.TO_CLIENT], enforced on receipt
## against the [i]transport's[/i] view of the sender. Without it any client could tell
## every other client that somebody had left.

const NAME := &"room.event"

const KIND_BITS := 4

## Largest body accepted. The biggest thing that travels is one JOIN, which is well
## under a hundred bytes; anything larger is a bug or a hostile server, and neither
## should be allocated for.
const MAX_BODY := 1024

var kind: int = 0
var body: PackedByteArray = PackedByteArray()


## [b]Built with [code]new(kind, body)[/code], and this file does not preload itself.[/b]
## It used to, for a typed [code]static func of() -> RoomEvent[/code] factory. A script that
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
	if kind < 0 or kind >= RoomEvents.Kind.size():
		return DotResult.fail(DotError.CODE_INVALID, "Unknown event kind %d." % kind)

	return DotResult.success(true)


func reader() -> DotNetReader:
	return DotNetReader.new(body)


func _to_string() -> String:
	return "RoomEvent(%s, %d bytes)" % [RoomEvents.kind_name(kind), body.size()]
