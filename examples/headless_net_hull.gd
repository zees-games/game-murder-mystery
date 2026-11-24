extends RefCounted

const MmNetCommand := preload("../game/net/mm_net_command.gd")

## The hull-view section of headless_net, run against its suite so the counts stay one (mp_solidplayers_unlag, opt-in).

var host: Node = null


func _init(p_host: Node) -> void:
	host = p_host


func _check(ok: bool, what: String, detail := "") -> void:
	var _r: bool = host._check(ok, what, detail)


## A command names the hull view it was drawn from, the server keeps a ring of feet to answer it, and the client's step uses the same rule; with unlag off nothing is asked.
func run() -> void:
	host._section("the hulls the mover bumps are the ones its screen drew")
	_codec()
	var sgame: Object = host._server_game
	var cgame: Object = host._client_game
	_check(sgame.hull_view != null and cgame.hull_view != null, "both ends have a hull view")
	_check(not sgame.body_rules.solid and not sgame.body_rules.unlag, "players are not solid by default, so this costs nothing until a server turns it on")

	for game: Object in [sgame, cgame]:
		game.body_rules.solid = true
		game.body_rules.unlag = true
		game.body_rules.refresh()

	await host._steps(60)
	var behaviour: Object = host._server_bridge._behaviours.get(host.SESSION)
	_check(behaviour != null and behaviour.last_hull_q >= 0, "the server read a view off the client's command", str(behaviour.last_hull_q if behaviour != null else -2))
	_check(behaviour != null and behaviour.last_hull_tick > 0, "and the tick it was for")
	var ring: Variant = sgame.hull_view.view.ring_at(host._stand_in.player_id, host._server_net.clock.tick - 2)
	_check(ring is Vector3, "the server's ring holds another player's feet for a recent tick", str(ring))
	var answered: int = 0
	for kind: String in ["ring", "interp", "miss", "teleport", "none"]:
		answered += int(sgame.hull_view.view.counts[kind]) + int(cgame.hull_view.view.counts[kind])
	_check(answered > 0, "the movers' steps asked it", str(sgame.hull_view.view.counts) + str(cgame.hull_view.view.counts))
	_check(int(cgame.hull_view.view.counts["interp"]) > 0, "the client answers from the interpolator", str(cgame.hull_view.view.counts))

	for game: Object in [sgame, cgame]:
		game.body_rules.unlag = false
	var before: int = sgame.hull_view.view.counts["ring"]
	await host._steps(10)
	_check(int(sgame.hull_view.view.counts["ring"]) == before, "with unlag off the step runs against the present and asks nothing")

	for game: Object in [sgame, cgame]:
		game.body_rules.solid = false
		game.body_rules.refresh()
	host._finished()


## The wire: a view and bracket survive it, none costs a bit, a lag with no bracket arrives with none, and the stab lag beside it is unharmed.
func _codec() -> void:
	var viewed := MmNetCommand.new()
	viewed.tick = 90
	viewed.view_lag_q = 25
	viewed.move.buttons = 1
	viewed.hull_lag_q = 37
	viewed.hull_back = 9
	viewed.hull_span = 2
	var bits := GSNetWriter.new()
	viewed._write(bits)
	var read := MmNetCommand.new()
	read._read(GSNetReader.new(bits.to_bytes()))
	_check(read.hull_lag_q == 37 and read.hull_back == 9 and read.hull_span == 2 and read.view_lag_q == 25 and not viewed._equals(MmNetCommand.new()),
		"a command's hull lag and snapshot bracket round-trip beside the stab lag", "%d/%d/%d" % [read.hull_lag_q, read.hull_back, read.hull_span])
	var lag_only := MmNetCommand.new()
	lag_only.hull_lag_q = 5
	var lag_bits := GSNetWriter.new()
	lag_only._write(lag_bits)
	var lag_read := MmNetCommand.new()
	lag_read._read(GSNetReader.new(lag_bits.to_bytes()))
	_check(lag_read.hull_lag_q == 5 and lag_read.hull_back == -1 and not lag_only._equals(viewed), "a lag with no bracket arrives with none")
	var plain := MmNetCommand.new()
	var plain_bits := GSNetWriter.new()
	plain._write(plain_bits)
	var plain_read := MmNetCommand.new()
	plain_read._read(GSNetReader.new(plain_bits.to_bytes()))
	_check(plain_read.hull_lag_q == -1 and plain_bits.to_bytes().size() <= lag_bits.to_bytes().size(), "a command with no view carries one bit for it")
	viewed._neutralise()
	_check(viewed.hull_lag_q == -1 and viewed.hull_back == -1, "a silent player's command names no view")
