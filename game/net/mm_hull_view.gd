extends RefCounted

## Where every other player stood on a mover's screen, for `mp_solidplayers_unlag`: this game's wiring of gs-player-controller's [GSPlayerHullView] (the ring, the resolve rule and the client's fill live there; its docs/collision.md "Sharing the view"). Opt-in: players are non-solid by default, so none of this runs until an operator sets both `mp_solidplayers 1` and `mp_solidplayers_unlag 1`.
## A command names how far behind its tick the sender drew the others and the snapshot pair it drew between ([MmNetCommand.hull_lag_q], `hull_back`, `hull_span`, kept per player as `MmPlayerNet.last_hull_*`). The server answers from its per-tick ring of feet, the client from the interpolator's samples of the same two ticks, so the hull a bump meets is the same one on both. This is the movement half only: a stab and a shot are still judged by `MmGame.unlag_tick_for` against the game's own trail.
## The bodies it moves are `MmGame.players` (each has its `SolidHull` from `GSPlayerBodyRules.apply_hull`). A stand-in or a player with no command sends no view and its step runs against the present.

const MmNetCommand := preload("mm_net_command.gd")
const MmPlayerNet := preload("mm_player_net.gd")
const MmPlayer := preload("../mm_player.gd")

## The shared view: `counts`, `capacity` and `rewind` are read off it.
var view := GSPlayerHullView.new()

var _game: Object = null
var _net: GSNetManager = null
## The bridge's behaviours by session id, shared by reference.
var _behaviours: Dictionary = {}
var _wire_var: GSNetVar = null


func _init(game: Object, net: GSNetManager, behaviours: Dictionary) -> void:
	_game = game
	_net = net
	_behaviours = behaviours
	view.is_server = net.is_server
	view.snap_fn = _snap
	view.view_fn = _view_of
	view.client_fn = _drawn_feet


## Runs [param work] for [param mover]'s step at [param tick] with the other hulls where the mover's last command said they were drawn.
func around(mover: StringName, tick: int, work: Callable) -> Variant:
	return view.around(_game.body_rules, mover, _game.players, tick, work)


## Server, after the tick's moves: every player's feet on the wire's grid. Kept while players are solid, so turning `mp_solidplayers_unlag` on finds history already there.
func record(tick: int) -> void:
	if not _game.body_rules.solid:
		return

	var config: Object = _game.combat.config if _game.combat != null else null
	var max_rewind_sec: float = config.max_rewind_ms / 1000.0 if config != null else 1.0
	view.capacity = ceili(max_rewind_sec * float(_game.tick_rate)) + 4
	var positions := {}

	for id: StringName in _game.players:
		positions[id] = (_game.players[id] as MmPlayer).controller.state.position

	view.record(tick, positions)


## Client, building a command for [param tick]: the lag and bracket as this client draws the others now, kept on [param mine] (its own behaviour) for the predicted step. Leaves none when the rules are off or the interpolator is not running yet.
func fill(command: MmNetCommand, tick: int, mine: MmPlayerNet) -> void:
	command.hull_lag_q = -1
	command.hull_back = -1
	command.hull_span = 0

	if _game.body_rules.solid and _game.body_rules.unlag and _net.interpolator != null and _net.clock.is_synced():
		_name_view(command, tick)

	if mine != null:
		mine.last_hull_q = command.hull_lag_q
		mine.last_hull_back = command.hull_back
		mine.last_hull_span = command.hull_span
		mine.last_hull_tick = tick


func _name_view(command: MmNetCommand, tick: int) -> void:
	var net := _net
	var drawn: float = float(net.clock.received_tick()) + clampf(net.clock.render_alpha(), -1.0, 2.0) + net.clock.receive_slip() - net.interpolator.delay_ticks()
	var q := GSPlayerHullView.lag_q_for(tick, drawn, MmNetCommand.MAX_HULL_LAG_Q)
	var pair: Vector2i = net.interpolator.bracket_at(float(tick) - float(q) * 0.25)
	var bracket := GSPlayerHullView.bracket_for(tick, pair, MmNetCommand.HULL_BACK_BITS, MmNetCommand.HULL_SPAN_BITS)
	command.hull_lag_q = q
	command.hull_back = bracket[0]
	command.hull_span = bracket[1]


## `[lag_q, command_tick, back, span]` of the mover's last command, or null (a stand-in has no behaviour, and no view).
func _view_of(mover: Variant) -> Variant:
	var behaviour: MmPlayerNet = _behaviour(mover)

	if behaviour == null:
		return null

	return [behaviour.last_hull_q, behaviour.last_hull_tick, behaviour.last_hull_back, behaviour.last_hull_span]


## Client: [param other]'s drawn feet at [param render], from the interpolator's samples.
func _drawn_feet(other: Variant, older: int, span: int, render: float) -> Variant:
	var theirs: MmPlayerNet = _behaviour(other)

	if theirs == null or theirs.identity == null or _net.interpolator == null:
		return null

	var id: int = theirs.identity.net_id

	if older >= 0:
		return _net.interpolator.value_between(id, &"net_position", older, older + span, render, view.teleport_cut)

	return _net.interpolator.value_at(id, &"net_position", render, view.teleport_cut)


## The behaviour of the player with this id, or null (a stand-in has none; neither has an id that is not one).
func _behaviour(id: Variant) -> MmPlayerNet:
	if typeof(id) != TYPE_STRING_NAME:
		return null

	return _behaviours.get(String(id).trim_prefix("u").to_int())


func _snap(feet: Vector3) -> Vector3:
	if _wire_var == null:
		for id: StringName in _game.players:
			var behaviour: MmPlayerNet = _behaviour(id)

			if behaviour != null:
				_wire_var = behaviour.find_var(&"net_position")

				if _wire_var != null:
					break

	return _wire_var.wire_value(feet) if _wire_var != null else feet
