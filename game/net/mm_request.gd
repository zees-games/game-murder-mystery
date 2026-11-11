extends DotNetMessage

const MmEvents := preload("mm_events.gd")

## Anything a client asks the authority for. Reliable, rare, to the server only. [b]None of these is a per-tick intent[/b]:
## moving is the input packet, ordered against its tick; this is for what happens once and must not be lost ("my world
## exists", "I am ready", "I want to watch somebody else"). Nothing here can catch anybody: a catch is the server's measurement.

const NAME := &"mm.request"
const KIND_BITS := 4
const MAX_BODY := 256

var kind: int = 0
var body: PackedByteArray = PackedByteArray()


## [b]Built with [code]new(kind, body)[/code], and this file does not preload itself.[/b] A script extending [DotNetMessage]
## that preloads ITSELF, loaded from a runtime-loaded module, leaks the script graph at exit on Godot 4.7.2 (mg-buses-from-hell 8ed866c). The registry decodes with a bare `new()`: both args default.
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
	if kind < 0 or kind >= MmEvents.Ask.size():
		return DotResult.fail(DotError.CODE_INVALID, "Unknown request kind %d." % kind)

	return DotResult.success(true)


## Whether every [enum MmEvents.Ask] fits in [constant KIND_BITS]. What a check reads: the writer
## masks a value to its field, so a kind past it goes out as a smaller one and nothing errors.
static func fits() -> bool:
	return int(MmEvents.Ask.values().max()) < (1 << KIND_BITS)


func reader() -> DotNetReader:
	return DotNetReader.new(body)


func _to_string() -> String:
	return "MmRequest(%s, %d bytes)" % [MmEvents.ask_name(kind), body.size()]
