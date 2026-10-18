extends DotNetInput

const MmNetCommand := preload("mm_net_command.gd")

## One tick of a player's intent, on the wire: a movement command and nothing else.
##
## [b]An attack is a button, never a claim.[/b] Use, attack and holster ride in
## [member DotFpsCommand.buttons] (USER_0..2) for the reason a jump does; the server decides
## from where it has the bodies whether a stab reached or a shot hit, and a client cannot send
## "I hit them".

var move: DotFpsCommand = DotFpsCommand.new()


func _write(writer: DotNetWriter) -> void:
	move.write(writer)


func _read(reader: DotNetReader) -> void:
	move = DotFpsCommand.new()
	move.read(reader)


## Not optional. Quantisation bounds each field; it cannot bound the relationship between
## them, and a move vector of (1, 1) is 41% more speed than anybody else — somebody who crosses
## a room before the murderer can turn round.
func _sanitise() -> void:
	move.sanitise()


func _equals(other: DotNetInput) -> bool:
	var them := other as MmNetCommand
	return them != null and move.equals(them.move)
