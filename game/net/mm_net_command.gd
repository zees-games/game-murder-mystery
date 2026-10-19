extends DotNetInput

const MmNetCommand := preload("mm_net_command.gd")

## One tick of a player's intent, on the wire: a movement command and nothing else.
##
## [b]An attack is a button, never a claim.[/b] Use, attack and holster ride in
## [member DotFpsCommand.buttons] (USER_0..2) for the reason a jump does; the server decides
## from where it has the bodies whether a stab reached or a shot hit, and a client cannot send
## "I hit them".

var move: DotFpsCommand = DotFpsCommand.new()

## How far behind this command's tick the client was drawing everybody else, in quarter ticks:
## the tick a stab or a shot on it was aimed at, which the server rewinds the other bodies to
## (`MmGame.unlag_tick_for`). Sent only while a button is down, and capped by the server, never
## trusted: a client claiming more only gets [member MmGame.max_unlag_ms].
var view_lag_q: int = -1

const MAX_VIEW_LAG_Q := 1023
const VIEW_LAG_BITS := 10


func _write(writer: DotNetWriter) -> void:
	move.write(writer)
	var lagged := move.buttons != 0 and view_lag_q >= 0
	writer.write_bool(lagged)
	if lagged:
		writer.write_uint(clampi(view_lag_q, 0, MAX_VIEW_LAG_Q), VIEW_LAG_BITS)


func _read(reader: DotNetReader) -> void:
	move = DotFpsCommand.new()
	move.read(reader)
	view_lag_q = reader.read_uint(VIEW_LAG_BITS) if reader.read_bool() else -1


## Not optional. Quantisation bounds each field; it cannot bound the relationship between
## them, and a move vector of (1, 1) is 41% more speed than anybody else — somebody who crosses
## a room before the murderer can turn round.
func _sanitise() -> void:
	move.sanitise()
	view_lag_q = clampi(view_lag_q, -1, MAX_VIEW_LAG_Q)


## The view lag in ticks, or -1 for none sent.
func view_lag_ticks() -> float:
	return float(view_lag_q) * 0.25 if view_lag_q >= 0 else -1.0


func _equals(other: DotNetInput) -> bool:
	var them := other as MmNetCommand
	return them != null and move.equals(them.move) and view_lag_q == them.view_lag_q
