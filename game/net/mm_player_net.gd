extends DotNetBehaviour

const MmNetCommand := preload("mm_net_command.gd")
const MmPlayer := preload("../mm_player.gd")
const MmController := preload("../mm_controller.gd")

## What a networked player replicates: the movement state (dot-player-controller's own table),
## health, what shows in a hand, blood and shirt. Which side somebody is on is deliberately NOT
## here: the owner learns it from a ROLE event (docs/design.md "Roles are secret").

var player: MmPlayer = null
var bridge: Node = null

var net_position: Vector3 = Vector3.ZERO
var net_velocity: Vector3 = Vector3.ZERO
var net_yaw: float = 0.0
var net_pitch: float = 0.0
var net_crouch: float = 0.0
var net_flags: int = 0
var net_modifiers: int = 0

## Hit points, and the one field with a hard cap on the wire.
##
## [b]Sent against 0..1000 rather than against the player's own maximum.[/b] A server that
## raised `player_health` mid-round would otherwise change what every previously sent number
## MEANT, which is the quantisation version of the map-size bug: the value does not get less
## precise, it becomes a different value.
var net_health: float = 100.0

## What full health is, for the HUD.
var net_max_health: float = 100.0

## Points this match and the server's ping for the player, for everybody's Tab board.
var net_points: int = 0
var net_ping: int = 0

## What is in their hand where everybody can see it (`MmPlayer.armed`): nothing, the weapon
## drawn, or the gun. [b]A holstered weapon is nothing here[/b], which is the whole of the
## holster: the server never sends what a murderer carries, only what they show.
var net_armed: int = 0

## How much blood shows on them, 0..7 (`MmPlayer.blood`). Everybody's: it is the tell.
var net_blood: int = 0

## Their shirt this round, an index into `MmGame.SHIRTS`.
var net_shirt: int = 0

## `MmPlayer.attacks`, four bits: a change is a swing or a shot to draw.
var net_attacks: int = 0

## Seconds until their weapon or gun is ready. Owner only, for the HUD.
var net_ready_in: float = 0.0

## Held still. Owner only, for the HUD; the hold itself is a modifier in the movement state.
var net_held: bool = false

## Sitting this round out, having joined after it started.
var net_watching: bool = false

## `MmPlayer.beacon`, an administrator's mark. Everybody's.
var net_beacon: bool = false

## `MmPlayer.warps`, four bits of it: how many times the server has put this player
## somewhere rather than moved them there. See [method _forget_the_path].
var net_warp: int = 0

## The last [member net_warp] this mirror acted on.
var _seen_warp: int = -1

## Retained, not cleared: a player whose packet was lost keeps moving in a straight line
## rather than stopping dead. The controller says the same of its own command.
var last_move: DotFpsCommand = DotFpsCommand.new()

## The newest command's view lag in ticks, or -1; see [member MmNetCommand.view_lag_q].
var last_view_lag: float = -1.0

var last_state_tick: int = -1


func _register_net_vars() -> void:
	for spec in DotFpsNetSync.state_specs():
		var declaration := replicate(spec["property"], DotNetVar.Type[spec["type"]])

		if int(spec["bits"]) > 0:
			declaration.bits(int(spec["bits"]))

		if bool(spec["interpolated"]):
			declaration.interpolated()

		if spec["property"] == &"net_crouch":
			declaration.range_of(0.0, 1.0)

	replicate(&"net_health", DotNetVar.Type.FLOAT_RANGE).range_of(0.0, 1000.0).bits(12)
	replicate(&"net_max_health", DotNetVar.Type.FLOAT_RANGE).range_of(0.0, 1000.0).bits(14)
	replicate(&"net_points", DotNetVar.Type.UINT).bits(16)
	replicate(&"net_ping", DotNetVar.Type.UINT).bits(10)
	replicate(&"net_watching", DotNetVar.Type.BOOL)
	replicate(&"net_armed", DotNetVar.Type.UINT).bits(2)
	replicate(&"net_blood", DotNetVar.Type.UINT).bits(3)
	replicate(&"net_shirt", DotNetVar.Type.UINT).bits(4)
	replicate(&"net_attacks", DotNetVar.Type.UINT).bits(4)
	var _ready := replicate(&"net_ready_in", DotNetVar.Type.FLOAT_RANGE).range_of(0.0, 30.0).bits(8).to_owner_only()
	var _held := replicate(&"net_held", DotNetVar.Type.BOOL).to_owner_only()

	# [b]Per-player state rather than an event[/b]: a client that joins after the admin typed
	# `beacon`, or a lost snapshot, is corrected by the next one, where an event is missed.
	replicate(&"net_beacon", DotNetVar.Type.BOOL)
	replicate(&"net_warp", DotNetVar.Type.UINT).bits(4)


func _net_apply_input(input: DotNetInput, _tick: int) -> void:
	var command := input as MmNetCommand

	if command != null:
		last_move = command.move
		last_view_lag = command.view_lag_ticks()


## On the authority the whole game ticks as one — every player moves, then the catches, the
## attacks and the round are decided — so the first behaviour through drives the whole world and
## the rest find it done. On a predicting client there is one predicted player, and simulating
## it is the whole of what a client may compute.
func _net_simulate(tick: int, delta: float) -> void:
	if player == null:
		return

	if identity != null and identity.is_authoritative:
		if bridge != null:
			bridge.ensure_game_ticked(tick)
	else:
		# The prediction: the controller's own tick, with the same hold modifier the server
		# applies, which travels in the movement state.
		player.controller.apply_command(last_move.duplicate_command())
		player.controller.simulate_tick(tick, delta)

	pull()


## Authority only: what the simulation left this player as.
func pull() -> void:
	if player == null:
		return

	DotFpsNetSync.pull(player.controller.state, self)

	if player.health != null:
		net_health = player.health.health
		net_max_health = player.health.max_health

	net_points = clampi(player.points, 0, 65535)
	net_ping = clampi(player.ping_ms, 0, 1023)
	net_watching = player.watching
	net_armed = clampi(player.armed(), 0, 3)
	net_blood = clampi(player.blood, 0, 7)
	net_shirt = clampi(player.shirt, 0, 15)
	net_attacks = player.attacks & 0xF
	net_ready_in = clampf(player.ready_in, 0.0, 30.0)
	net_held = player.controller.has_modifier(MmController.HOLD) if player.controller != null else false
	net_beacon = player.beacon
	net_warp = player.warps & 0xF


## The server's answer, adopted wholesale. On the owner it is the rewind half of
## reconciliation and the predictor replays every unacknowledged command on top.
func _net_state_applied(tick: int) -> void:
	if player == null:
		return

	last_state_tick = tick
	_forget_the_path()
	DotFpsNetSync.push(self, player.controller.state)
	_adopt()

	# NOT the node, on a predicted entity: `receive_snapshot` calls this BEFORE the
	# predictor reconciles, and reconcile's first act is to read the node as "what the
	# client is showing". Moving it here makes the measured error the whole replay distance,
	# and the correction rate then reads as if every snapshot snapped. Two games in this
	# family shipped that line.
	#
	if identity == null or not identity.is_predicted():
		player.global_position = player.controller.state.position


## A teleport is not a movement, so the interpolator must not draw one. The server counts the
## times it PUT this player somewhere and a mirror that sees it change drops the track before
## the new snapshot is added, so the body appears in its corner rather than crossing the sky.
func _forget_the_path() -> void:
	if identity == null or identity.is_authoritative or identity.is_predicted():
		_seen_warp = net_warp
		return

	if _seen_warp >= 0 and net_warp != _seen_warp and bridge != null:
		var manager: Variant = bridge.get(&"net")
		if manager is DotNetManager and (manager as DotNetManager).interpolator != null:
			(manager as DotNetManager).interpolator.forget(identity.net_id)

	_seen_warp = net_warp


## Every frame on a remote player. Without this the interpolator's work sits in a property
## nothing reads and a remote player moves in snapshot-sized steps.
func _net_interpolated(_tick: int) -> void:
	if player == null:
		return

	DotFpsNetSync.push(self, player.controller.state)
	player.global_position = player.controller.state.position


## The game half of a snapshot, on a mirror: what the server decided about this player.
func _adopt() -> void:
	if player == null or identity == null or identity.is_authoritative:
		return

	if player.health != null:
		player.health.max_health = maxf(net_max_health, 1.0)
		player.health.health = net_health
		player.health.alive = net_health > 0.0

	player.points = net_points
	player.ping_ms = net_ping
	player.watching = net_watching
	player.held_until = 1.0 if net_held else -1.0
	player.beacon = net_beacon
	player.blood = net_blood
	player.shirt = net_shirt
	player.ready_in = net_ready_in
	# What the mirror knows of a hand is what shows: the gun, or a drawn weapon.
	player.has_gun = net_armed == MmPlayer.ARMED_GUN
	player.weapon_drawn = net_armed == MmPlayer.ARMED_WEAPON
	player.attacks = net_attacks
