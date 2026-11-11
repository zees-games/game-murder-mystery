extends "mm_game_death.gd"

## Damage from the world and from heads: the stomp rule and the fall below the map, of
## [code]mm_game.gd[/code]. Path-based base, no class_name.

## Scratch list of the hulls [method _resolve_stomps] hands to [DotStomp], kept so a tick allocates none.
var _stomp_hulls: Array = []


## After everybody moved: a player who came down onto another's head hurts them (cvars `sv_stomp*`, off by
## default), and bounces. Server-side; a client sees the health arrive.
func _resolve_stomps() -> void:
	if not authoritative or not stomp.rules.enabled or combat == null or phase == Phase.IDLE:
		return

	_stomp_hulls.clear()
	var hulls := _stomp_hulls

	for id: StringName in players:
		var other: MmPlayer = players[id]

		if other.is_alive() and not other.watching and other.controller != null:
			hulls.append({"id": other.entity_id, "feet": other.controller.state.position,
				"height": other.hull_height(), "radius": other.controller.tunables.radius, "team": -1})

	for id: StringName in _pre_vy:
		var player: MmPlayer = players[id]

		if not player.is_alive():
			continue

		var state: DotFpsState = player.controller.state
		var victim_id := stomp.find(player.entity_id, state.position, player.controller.tunables.radius,
			-float(_pre_vy[id]), -1, hulls, _tick, tick_rate)

		if victim_id == 0:
			continue

		var hit := DotDamage.make(player.entity_id, victim_id, stomp.amount(), null)
		hit.tick = _tick
		hit.point = state.position
		hit.context = {"why": &"stomp", "ignores_teams": true}
		var _applied := combat.apply_damage(hit)

		if hit.refused:
			continue

		if stomp.rules.bounce > 0.0:
			state.velocity.y = stomp.rules.bounce


## Somebody below the map has fallen. A height test, not a trigger volume: something falling
## fast crosses a thin trigger between two ticks without ever being inside it.
func _watch_world() -> void:
	if map == null or map.doc.is_empty():
		return

	for id: StringName in players:
		var player: MmPlayer = players[id]

		if not player.is_alive() or player.watching:
			continue

		if player.controller.state.position.y < map.kill_height():
			var fall := DotDamage.make(0, player.entity_id, player.health.max_health * 10.0, null)
			fall.tick = _tick
			fall.context = {"why": DIED_FELL}
			var _applied := combat.apply_damage(fall)
