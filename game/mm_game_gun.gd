extends "mm_game_stomp.gd"

## The weapon and the gun of [code]mm_game.gd[/code]: the keys, the stab, the shot, the drops and who may pick them up. Path-based base, no class_name.

## The murderer's weapon this server carries: the configured id, or the knife.
func weapon_id() -> StringName:
	var id := StringName(config.murderer_weapon) if config != null else MmWeapons.DEFAULT
	return id if MmWeapons.known(id) else MmWeapons.DEFAULT


func melee_reach() -> float:
	return config.melee_range if config.melee_range > 0.0 else float(MmWeapons.entry(weapon_id())["reach"])


func melee_cooldown() -> float:
	return config.melee_cooldown if config.melee_cooldown > 0.0 else float(MmWeapons.entry(weapon_id())["cooldown"])


func _now() -> float:
	return float(_tick) / float(maxi(tick_rate, 1))


## Whether nothing solid is between two points: the walls, and with [param furniture] the
## map's props as well.
func _clear_between(from: Vector3, to: Vector3, furniture: bool = false) -> bool:
	var world := get_world_3d()

	if world == null:
		return true

	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = physics.layer_mask(&"world") if physics != null else 1

	if furniture and physics != null:
		# The toys too: somebody crouched behind a barrel or the roundabout is behind something.
		query.collision_mask |= physics.layer_mask(&"prop") | physics.layer_mask(&"toy")

	return world.direct_space_state.intersect_ray(query).is_empty()


## Everybody's hands, this tick: the holster key, the attack key, and the guns on the floor.
## Edges are made here from the held state, because the keys ride in every input packet.
func _advance_weapons() -> void:
	if not authoritative:
		return

	var now := _now()

	for id: StringName in players:
		var player: MmPlayer = players[id]
		var holster := player.wants_holster and not player.holster_was_held
		var attack := player.wants_attack and not player.attack_was_held
		player.holster_was_held = player.wants_holster
		player.attack_was_held = player.wants_attack
		player.ready_in = maxf(player.ready_at - now, 0.0)

		if not player.is_alive() or player.watching or phase == Phase.IDLE:
			continue

		if holster and team_of(id) == MURDERERS:
			set_weapon_drawn(id, not player.weapon_drawn)

		if attack:
			var _did := attack_now(id)

	_advance_pickups()


## Draws or holsters [param id]'s weapon. Refused in the grace, and for anybody but a murderer.
func set_weapon_drawn(id: StringName, drawn: bool) -> bool:
	var player: MmPlayer = players.get(id)

	if player == null or team_of(id) != MURDERERS or not player.is_alive() or player.watching:
		return false

	if drawn and phase != Phase.PLAY:
		refused.emit(id, "You cannot draw your %s yet." % weapon_name().to_lower())
		return false

	if player.weapon_drawn == drawn:
		return true

	player.weapon_drawn = drawn
	player.drawn_at = _now() if drawn else -1.0
	weapon_changed.emit(id, drawn)
	return true


func weapon_name() -> String:
	return str(MmWeapons.entry(weapon_id())["name"])


## The attack key for [param id]: a stab for a murderer with the weapon out, a shot for whoever
## holds the gun. Server side; what a suite and a bot call directly too.
func attack_now(id: StringName) -> bool:
	var player: MmPlayer = players.get(id)

	if player == null or not player.is_alive() or player.watching or phase != Phase.PLAY:
		return false

	var now := _now()

	if now < player.ready_at:
		return false

	if player.has_gun:
		_shoot(player)
		return true

	if team_of(id) == MURDERERS and player.weapon_drawn and now - player.drawn_at >= config.draw_seconds:
		_stab(player)
		return true

	return false


## A stab: the nearest living somebody within reach of the murderer's eye, inside the cone,
## with nothing solid between. A swing at nobody still costs the cooldown and is still seen.
func _stab(murderer: MmPlayer) -> void:
	murderer.ready_at = _now() + melee_cooldown()
	murderer.attacked_at = _now()
	murderer.attacks += 1
	_rewind_to = unlag_tick_for(murderer)
	var victim := stab_target(murderer)
	_rewind_to = -1.0
	struck.emit(murderer.player_id)

	if victim != null:
		_kill(victim, murderer, DIED_STABBED)


## Who a stab from [param murderer] would land on now, or null.
func stab_target(murderer: MmPlayer) -> MmPlayer:
	var eye := murderer.eye_position()
	var aim := murderer.aim_direction()
	var flat := Vector3(aim.x, 0.0, aim.z).normalized()
	var reach := melee_reach()
	var cone := cos(deg_to_rad(config.melee_cone))
	var best: MmPlayer = null
	var best_distance := INF

	for id: StringName in players:
		var other: MmPlayer = players[id]

		if other == murderer or not other.is_alive() or other.watching or team_of(id) == MURDERERS \
				or not can_be_harmed(id):
			continue

		var chest := body_position(other) + Vector3(0.0, 1.1, 0.0)
		var offset := chest - eye
		var distance := Vector2(offset.x, offset.z).length()

		if distance > reach or absf(offset.y) > 1.4:
			continue

		var toward := Vector3(offset.x, 0.0, offset.z).normalized()

		if distance > 0.45 and flat.dot(toward) < cone:
			continue

		if distance < best_distance and _clear_between(eye, chest):
			best = other
			best_distance = distance

	return best


## A shot, from the gunner's eye along their aim: the first body it passes through before a
## wall or a piece of furniture. A miss drops the gun; so does an innocent, by default.
func _shoot(gunner: MmPlayer) -> void:
	gunner.ready_at = _now() + config.gun_cooldown
	gunner.attacked_at = _now()
	gunner.attacks += 1
	var from := gunner.eye_position()
	var aim := gunner.aim_direction()
	var wall := _wall_along(from, aim, config.gun_range)
	_rewind_to = unlag_tick_for(gunner)
	var hit := shot_target(gunner, from, aim, wall)
	var to := from + aim * wall

	if hit != null:
		to = body_position(hit) + Vector3(0.0, 1.2, 0.0)

	_rewind_to = -1.0

	shot.emit(gunner.player_id, from, to, hit.player_id if hit != null else &"")

	if progress != null:
		progress.on_shot(gunner.player_id, hit != null)

	if hit == null:
		if progress != null:
			progress.on_missed(gunner.player_id)
		if config.drop_on_miss:
			_drop_gun(gunner, gunner.controller.state.position)
			gunner.gun_banned = true
		return

	var innocent := team_of(hit.player_id) != MURDERERS
	_kill(hit, gunner, DIED_SHOT)

	if not innocent:
		gunner.points += config.hero_points
		if progress != null:
			progress.on_hero(gunner.player_id)
		return

	if progress != null:
		progress.on_innocent(gunner.player_id)

	if config.drop_on_innocent and gunner.has_gun:
		_drop_gun(gunner, gunner.controller.state.position)
		gunner.gun_banned = true

	if config.innocent_kills_shooter and gunner.is_alive():
		_kill(gunner, null, DIED_SLAIN)


## The first living body the ray from [param from] along [param aim] passes within
## [member MmConfig.hit_radius] of, before [param limit] metres. Standing capsules, measured here.
func shot_target(gunner: MmPlayer, from: Vector3, aim: Vector3, limit: float) -> MmPlayer:
	var best: MmPlayer = null
	var best_along := limit

	for id: StringName in players:
		var other: MmPlayer = players[id]

		# A covered seat cannot be hit, so a shot passes it and costs the gunner no innocent.
		if other == gunner or not other.is_alive() or other.watching or not can_be_harmed(id):
			continue

		var feet := body_position(other)
		var height := lerpf(config.hit_height, MmPlayer.BODY_CROUCH, other.controller.state.crouch_fraction)
		var along := _ray_capsule(from, aim, feet, height, config.hit_radius)

		if along >= 0.0 and along < best_along:
			best = other
			best_along = along

	return best


## How far along the ray a vertical capsule from [param feet] up [param height] is first within
## [param radius], or -1. Sampled along the closest approach of the ray to the axis.
static func _ray_capsule(from: Vector3, dir: Vector3, feet: Vector3, height: float, radius: float) -> float:
	var top := feet + Vector3(0.0, height, 0.0)
	var closest := Geometry3D.get_closest_points_between_segments(from, from + dir * 1000.0, feet, top)
	var on_ray: Vector3 = closest[0]
	var on_axis: Vector3 = closest[1]

	if on_ray.distance_to(on_axis) > radius:
		return -1.0

	return maxf((on_ray - from).dot(dir) - radius * 0.5, 0.0)


## How far a shot goes before something solid: the walls and the furniture.
func _wall_along(from: Vector3, aim: Vector3, limit: float) -> float:
	var world := get_world_3d()

	if world == null:
		return limit

	var query := PhysicsRayQueryParameters3D.create(from, from + aim * limit)
	query.collision_mask = physics.layer_mask(&"world") | physics.layer_mask(&"prop") | physics.layer_mask(&"toy") \
		if physics != null else 1
	var hit := world.direct_space_state.intersect_ray(query)
	return from.distance_to(hit["position"]) if not hit.is_empty() else limit


## [param victim] killed by [param by] (null for nobody), as damage through dot-combat.
func _kill(victim: MmPlayer, by: MmPlayer, how: StringName) -> void:
	if combat == null or not victim.is_alive():
		return

	var hit := DotDamage.make(by.entity_id if by != null else 0, victim.entity_id, victim.health.max_health * 10.0, null)
	hit.tick = _tick
	hit.context = {"why": how}

	if by != null:
		hit.direction = (victim.controller.state.position - by.controller.state.position).normalized()

	var _applied := combat.apply_damage(hit)


## The gun out of [param holder]'s hands and onto the floor at [param at].
func _drop_gun(holder: MmPlayer, at: Vector3) -> void:
	if not holder.has_gun:
		return

	holder.has_gun = false

	# Below the map, it goes to a spawn point instead: a gun nobody can reach is a round with
	# no gun.
	if map != null and at.y < map.kill_height() + 1.0:
		at = map.spawn(SPAWN_GROUP, _next_drop_id)[0]

	var drop_id := _next_drop_id
	_next_drop_id += 1
	gun_drops[drop_id] = {"at": at + Vector3(0.0, 0.05, 0.0), "dropped_by": holder.player_id, "since": _now()}
	gun_dropped.emit(drop_id, gun_drops[drop_id]["at"])
	DotLog.debug(CHANNEL, "the gun was dropped", {"by": String(holder.player_id), "at": str(at.snapped(Vector3.ONE * 0.1))})


## A gun on the floor goes to the first living bystander who walks onto it and may hold one: not
## a murderer, not one who dropped a gun this round, not one who already has one.
func _advance_pickups() -> void:
	if gun_drops.is_empty():
		return

	for drop_id: int in gun_drops.keys():
		var at: Vector3 = gun_drops[drop_id]["at"]

		for id: StringName in players:
			var player: MmPlayer = players[id]

			if not may_pick_up(player):
				continue

			var feet := player.controller.state.position
			if Vector2(feet.x - at.x, feet.z - at.z).length() > config.pickup_range or absf(feet.y - at.y) > 1.2:
				continue

			gun_drops.erase(drop_id)
			player.has_gun = true
			player.ready_at = maxf(player.ready_at, _now() + 0.5)
			gun_taken.emit(drop_id, id)

			if progress != null:
				progress.on_picked_up(id)

			break


func may_pick_up(player: MmPlayer) -> bool:
	return player != null and player.is_alive() and not player.watching and not player.has_gun \
		and not player.gun_banned and team_of(player.player_id) != MURDERERS


func _clear_drops() -> void:
	for drop_id: int in gun_drops.keys():
		gun_taken.emit(drop_id, &"")
	gun_drops.clear()


## Lets go of anybody whose hold has run out.
func _advance_holds() -> void:
	var now := _now()

	for id: StringName in players:
		var player: MmPlayer = players[id]

		if player.held_until >= 0.0 and now >= player.held_until:
			player.held_until = -1.0
			var _let_go := player.controller.remove_modifier(MmController.HOLD)
