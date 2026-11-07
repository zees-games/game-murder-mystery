extends "mm_game_world.gd"

## Doors, toys and the position trail of [code]mm_game.gd[/code]: what the use key and lag
## compensation read. Path-based base, no class_name.

## The flashlight config, made on first use.
func flashlight_conf() -> DotFlashlightConfig:
	if flashlight_config == null:
		flashlight_config = MmFlashlight.make_config()
		flashlight_binder = MmFlashlight.make_binder(flashlight_config)
		DotLog.result(CHANNEL, "flashlight config", flashlight_binder.load_layers())
	return flashlight_config


## A new map sets everybody's light by the map (dark ones start lit). Server side.
func _advance_flashlights() -> void:
	if not authoritative:
		return

	var cfg := flashlight_conf()
	var map_id := str(map_doc.get("id", ""))

	if map_id != _flashlight_map:
		_flashlight_map = map_id
		for p: MmPlayer in players.values():
			p.flashlight_ready = false

	for player: MmPlayer in players.values():
		if not player.flashlight_ready:
			player.flashlight_ready = true
			player.flashlight = MmFlashlight.starts_on(cfg, map_id, map_doc)


## A living player in the round switches their light, whatever they are (murderer, gunner or bystander). Refused for the dead and the benched, and where the map or the config disallows it. Server side.
func toggle_flashlight(id: StringName) -> bool:
	var player: MmPlayer = players.get(id)
	var cfg := flashlight_conf()

	if player == null or not player.is_alive() or player.watching \
			or not DotFlashlightRules.allowed_on(cfg, str(map_doc.get("id", ""))):
		return false

	player.flashlight = not player.flashlight
	return true


## Everybody's hand on the doors: a use is the use key going down in front of one, then every
## door is posed for this tick. The edge is made here from the held state, as for the weapons.
func _advance_doors() -> void:
	if map == null or map.doors == null or map.doors.count() == 0:
		return

	map.doors.pose_at(_tick)


## The toy [param player] is looking at within reach, or -1. Both ends: the client asks it
## for the use prompt.
func toy_aimed(player: MmPlayer) -> int:
	if map == null or map.toys == null or player == null:
		return -1
	return map.toys.aimed(player.eye_position(), player.aim_direction(), config.toy_reach)


## Toy [param index] used by [param by]: a kick, a push, a switch, a honk. Server side.
func use_toy(index: int, by: StringName) -> bool:
	var player: MmPlayer = players.get(by)
	if map == null or map.toys == null or player == null:
		return false
	return map.toys.use(index, player.eye_position(), player.aim_direction())


## Everybody against the toys this tick, after they moved: a walk into a ball pushes it, weight
## on a see-saw tips it, and then the box's own tick (the awake cap, the lost sent home). A
## person is not a rigid body, so this is how one touches a toy at all. Server side.
func _advance_toys(delta: float) -> void:
	if map == null or map.toys == null or not authoritative:
		return

	for id: StringName in players:
		var player: MmPlayer = players[id]

		if not player.is_alive() or player.watching:
			continue

		var state := player.controller.state
		var _pushed := map.toys.push_from(state.position, state.velocity, MmPlayer.BODY_RADIUS, player.hull_height())

		if state.mode == DotFpsState.Mode.GROUND:
			var _bore := map.toys.stand_on(state.position, PERSON_MASS)

	map.toys.advance(delta)


## The trampolines and bounce pads, for every player's movement on both ends
## ([member MmController.launcher]): `{velocity, index}` or empty.
func _launch(feet: Vector3, velocity: Vector3) -> Dictionary:
	if map == null or map.toys == null:
		return {}
	return map.toys.launch_for(feet, velocity)


## A turning roundabout under a person, for their movement on both ends
## ([member MmController.carrier]): `{offset, yaw, index}` or empty.
func _carry(feet: Vector3, delta: float, ground_id: int) -> Dictionary:
	if map == null or map.toys == null:
		return {}
	return map.toys.carry_for(feet, delta, ground_id)


## A person thrown by a toy: its count goes up, which every client hears. Server side.
func _on_bounced(index: int) -> void:
	if authoritative and map != null and map.toys != null:
		map.toys.launched(index)


## A use the server made, applied on a client.
func apply_door(index: int, open: bool, flip: bool, tick: int) -> void:
	if map != null and map.doors != null:
		map.doors.apply(index, open, flip, tick)


## Every body's position for this tick, for [method unlag_position_at].
func _record_trail() -> void:
	for id: StringName in players:
		var player: MmPlayer = players[id]
		var ring: Array = _trail.get(id, [])

		if ring.is_empty():
			var positions := PackedVector3Array()
			positions.resize(UNLAG_HISTORY)
			var ticks := PackedInt32Array()
			ticks.resize(UNLAG_HISTORY)
			ticks.fill(-1)
			ring = [positions, ticks]

		# Packed arrays are values: taken out, written, put back.
		var positions: PackedVector3Array = ring[0]
		var ticks: PackedInt32Array = ring[1]
		var slot := _tick % UNLAG_HISTORY
		var before := (_tick - 1) % UNLAG_HISTORY
		var here := player.controller.state.position

		# A respawn or a fall is a teleport: rewinding across it would stand a body where it
		# died, so the trail starts again from here.
		if ticks[before] == _tick - 1 and positions[before].distance_to(here) > 10.0:
			ticks.fill(-1)

		positions[slot] = here
		ticks[slot] = _tick
		ring[0] = positions
		ring[1] = ticks
		_trail[id] = ring


## Where [param id] was at [param at] (a fractional tick), or null when the trail does not reach.
func unlag_position_at(id: StringName, at: float) -> Variant:
	var ring: Array = _trail.get(id, [])

	if ring.is_empty():
		return null

	var positions: PackedVector3Array = ring[0]
	var ticks: PackedInt32Array = ring[1]
	var lo := floori(at)
	var a := lo % UNLAG_HISTORY
	var b := (lo + 1) % UNLAG_HISTORY

	if ticks[a] != lo:
		return null

	if ticks[b] != lo + 1:
		return positions[a]

	return positions[a].lerp(positions[b], at - float(lo))


## The tick a stab or shot by [param shooter] is judged at: the present less the lag their client
## reported, capped at [member max_unlag_ms]; -1 for the present.
func unlag_tick_for(shooter: MmPlayer) -> float:
	if max_unlag_ms <= 0.0 or shooter.view_lag < 0.0:
		return -1.0

	var cap := max_unlag_ms * 0.001 * float(tick_rate)
	return float(_tick) - minf(shooter.view_lag, cap)


## Where [param other] is, for a stab or a shot being judged: where they were at [member _rewind_to]
## when that is set and the trail reaches, else where they are.
func body_position(other: MmPlayer) -> Vector3:
	if _rewind_to >= 0.0:
		var then: Variant = unlag_position_at(other.player_id, _rewind_to)

		if then != null:
			return then

	return other.controller.state.position
