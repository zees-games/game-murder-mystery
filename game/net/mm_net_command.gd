extends GSNetInput

const MmNetCommand := preload("mm_net_command.gd")

## One tick of a player's intent, on the wire: a movement command and nothing else. [b]An attack is a button, never a
## claim[/b]: use, attack and holster ride in [member GSFpsCommand.buttons] (USER_0..2); the server decides from where it
## has the bodies whether a stab reached or a shot hit, and a client cannot send "I hit them".

var move: GSFpsCommand = GSFpsCommand.new()

## How far behind this command's tick the client was drawing everybody else, in quarter ticks: the tick a stab or shot on
## it was aimed at (`MmGame.unlag_tick_for`). Sent only while a button is down and capped by the server, never trusted:
## a client claiming more only gets [member MmGame.max_unlag_ms].
var view_lag_q: int = -1

const MAX_VIEW_LAG_Q := 1023
const VIEW_LAG_BITS := 10

## The hull view (`mp_solidplayers_unlag`, [MmHullView]): sent on every command while the rule is on, one bit when it is not. [member hull_lag_q] is how far behind this tick the sender drew the other players, in quarter ticks; `hull_back` and `hull_span` the snapshot pair it drew between (`tick - hull_back` the older, `+ hull_span` the newer). -1: none named; a view the pair does not fit goes with the lag alone, never clamped.
var hull_lag_q: int = -1
var hull_back: int = -1
var hull_span: int = 0
const HULL_LAG_BITS := 12
const MAX_HULL_LAG_Q := (1 << HULL_LAG_BITS) - 1
const HULL_BACK_BITS := 10
const HULL_SPAN_BITS := 6


func _write(writer: GSNetWriter) -> void:
	move.write(writer)
	var lagged := move.buttons != 0 and view_lag_q >= 0
	writer.write_bool(lagged)
	if lagged:
		writer.write_uint(clampi(view_lag_q, 0, MAX_VIEW_LAG_Q), VIEW_LAG_BITS)
	# Appended after the stab/shot lag, as every addition to this wire is.
	var hulled := hull_lag_q >= 0
	writer.write_bool(hulled)
	if hulled:
		writer.write_uint(clampi(hull_lag_q, 0, MAX_HULL_LAG_Q), HULL_LAG_BITS)
		var bracketed := hull_back >= 0
		writer.write_bool(bracketed)
		if bracketed:
			writer.write_uint(clampi(hull_back, 0, (1 << HULL_BACK_BITS) - 1), HULL_BACK_BITS)
			writer.write_uint(clampi(hull_span, 0, (1 << HULL_SPAN_BITS) - 1), HULL_SPAN_BITS)


func _read(reader: GSNetReader) -> void:
	move = GSFpsCommand.new()
	move.read(reader)
	view_lag_q = reader.read_uint(VIEW_LAG_BITS) if reader.read_bool() else -1
	hull_lag_q = -1
	hull_back = -1
	hull_span = 0
	if reader.read_bool():
		hull_lag_q = reader.read_uint(HULL_LAG_BITS)
		if reader.read_bool():
			hull_back = reader.read_uint(HULL_BACK_BITS)
			hull_span = reader.read_uint(HULL_SPAN_BITS)


## Not optional. Quantisation bounds each field; it cannot bound the relationship between
## them, and a move vector of (1, 1) is 41% more speed than anybody else — somebody who crosses
## a room before the murderer can turn round.
func _sanitise() -> void:
	move.sanitise()
	view_lag_q = clampi(view_lag_q, -1, MAX_VIEW_LAG_Q)
	hull_lag_q = clampi(hull_lag_q, -1, MAX_HULL_LAG_Q)
	hull_back = clampi(hull_back, -1, (1 << HULL_BACK_BITS) - 1)
	hull_span = clampi(hull_span, 0, (1 << HULL_SPAN_BITS) - 1)


## A silent player lets go: the default neutralises `move`, and the views are dropped here.
func _neutralise() -> void:
	super()
	view_lag_q = -1
	hull_lag_q = -1
	hull_back = -1
	hull_span = 0


## The view lag in ticks, or -1 for none sent.
func view_lag_ticks() -> float:
	return float(view_lag_q) * 0.25 if view_lag_q >= 0 else -1.0


func _equals(other: GSNetInput) -> bool:
	var them := other as MmNetCommand
	return them != null and move.equals(them.move) and view_lag_q == them.view_lag_q \
			and hull_lag_q == them.hull_lag_q and hull_back == them.hull_back and hull_span == them.hull_span
