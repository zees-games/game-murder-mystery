extends GSNetMessage

const MmEvents := preload("mm_events.gd")

## Anything the authority tells a client that is not a snapshot. Reliable, to clients.

const NAME := &"mm.event"
const KIND_BITS := 5
## Room for the largest MAP a reader accepts ([constant MmEvents.MAP_BYTES]) and its length. A body past the cap is
## read as EMPTY with no error (game-hide-n-seek's hs_park once grew past 4096 and clients built no map); headless_net
## round-trips a MAP of the largest size through this message.
const MAX_BODY := MmEvents.MAP_BYTES + 8

var kind: int = 0
var body: PackedByteArray = PackedByteArray()


## [b]Built with [code]new(kind, body)[/code], and this file does not preload itself.[/b] A script extending [GSNetMessage]
## that preloads ITSELF, loaded from a runtime-loaded module, leaks the script graph at exit on Godot 4.7.2 (mg-buses-from-hell 8ed866c). The registry decodes with a bare `new()`: both args default.
func _init(p_kind: int = 0, p_body: PackedByteArray = PackedByteArray()) -> void:
	kind = p_kind
	body = p_body


func _type_name() -> StringName:
	return NAME


func _write(writer: GSNetWriter) -> void:
	writer.write_uint(kind, KIND_BITS)
	writer.write_bytes(body)


func _read(reader: GSNetReader) -> void:
	kind = reader.read_uint(KIND_BITS)
	body = reader.read_bytes(MAX_BODY)


func _validate() -> GSResult:
	if kind < 0 or kind >= MmEvents.Kind.size():
		return GSResult.fail(GSError.CODE_INVALID, "Unknown event kind %d." % kind)

	return GSResult.success(true)


## Whether every [enum MmEvents.Kind] fits in [constant KIND_BITS]. What a check reads: the writer
## masks a value to its field, so a kind past it goes out as a smaller one and nothing errors.
static func fits() -> bool:
	return int(MmEvents.Kind.values().max()) < (1 << KIND_BITS)


func reader() -> GSNetReader:
	return GSNetReader.new(body)


func _to_string() -> String:
	return "MmEvent(%s, %d bytes)" % [MmEvents.kind_name(kind), body.size()]
