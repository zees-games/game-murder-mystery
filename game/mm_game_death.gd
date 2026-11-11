extends "mm_game_map.gd"

## Sides, how a round ends and what a death does, of [code]mm_game.gd[/code]: who is on which
## side, the check for a decided round, the decision, a player dying, and the fall the body gets.
## Path-based base, no class_name.


func side_name(side: int) -> String:
	if side == BYSTANDERS or side == MURDERERS:
		return TEAM_NAMES[side - 1]

	return "nobody"


func side_colour(side: int) -> Color:
	if side == BYSTANDERS or side == MURDERERS:
		return TEAM_COLOURS[side - 1]

	return Color(0.7, 0.7, 0.7)


## The shirt [param player] wears this round.
func shirt_colour(player: MmPlayer) -> Color:
	return SHIRTS[posmod(player.shirt, SHIRTS.size())]


func shirt_name(player: MmPlayer) -> String:
	return SHIRT_NAMES[posmod(player.shirt, SHIRT_NAMES.size())]


func players_on(side: int) -> Array[MmPlayer]:
	var out: Array[MmPlayer] = []

	for id: StringName in players:
		if int(sides.get(id, 0)) == side:
			out.append(players[id])

	return out


## How many of a side are up and in the round. On a client only the totals it was told:
## everybody alive (any side), and murderers alive.
func alive_on(side: int) -> int:
	if not authoritative:
		if side == MURDERERS and remote_murderers >= 0:
			return remote_murderers
		if side == BYSTANDERS and remote_alive >= 0:
			return maxi(remote_alive - maxi(remote_murderers, 0), 0)

	var total := 0

	for player in players_on(side):
		if player.is_alive() and not player.watching:
			total += 1

	return total


## Everybody still in the round, whatever their role.
func alive_total() -> int:
	return alive_on(BYSTANDERS) + alive_on(MURDERERS)


func sides_are_playable() -> bool:
	if not authoritative:
		return remote_playable

	return players.size() >= 2


## "was" or "were" for the names in the sentence that ends a round. A solo player is called
## "You", which takes "were" as one person: "You were the murderer".
static func murderer_verb(names: PackedStringArray) -> String:
	return "was" if names.size() == 1 and names[0] != "You" else "were"


## "<why>; <names> was|were the murderer(s)". Mid-sentence the solo player is "you", not "You".
static func round_sentence(why: String, names: PackedStringArray) -> String:
	var said := PackedStringArray()
	for who in names:
		said.append("you" if who == "You" else who)
	return "%s; %s %s the murderer%s" % [why, ", ".join(said), murderer_verb(names), "" if names.size() == 1 else "s"]


static func _names(of: Array[MmPlayer]) -> PackedStringArray:
	var out := PackedStringArray()
	for player in of:
		out.append(player.display_name)
	return out


## The murderers gone, everybody else gone, or the clock.
func _check_round() -> void:
	if not authoritative or _decided or phase == Phase.IDLE:
		return

	var murderers_left := alive_on(MURDERERS)
	var others_left := alive_on(BYSTANDERS)

	if murderers_left == 0 and others_left == 0:
		_decide(0, "nobody is left")
	elif murderers_left == 0:
		var why := "nobody was the murderer"
		if not players_on(MURDERERS).is_empty():
			why = "the murderer is dead" if players_on(MURDERERS).size() == 1 else "the murderers are dead"
		_decide(BYSTANDERS, why)
	elif others_left == 0:
		_decide(MURDERERS, "nobody is left alive")
	elif phase == Phase.PLAY and play_elapsed >= round_limit():
		_decide(BYSTANDERS, "time: %d survived" % others_left)


func _decide(winner: int, why: String) -> void:
	if _decided:
		return

	_decided = true
	_winner = winner
	revealed = _names(players_on(MURDERERS))
	var told := why

	if not revealed.is_empty():
		told = round_sentence(why, revealed)

	_winner_name = told

	for id: StringName in players:
		var player: MmPlayer = players[id]

		if winner != 0 and team_of(id) == winner:
			player.points += config.winner_points

		if team_of(id) == BYSTANDERS and player.is_alive() and not player.watching:
			player.points += config.survive_points

			if progress != null:
				progress.on_survived(id)

	if progress != null:
		progress.on_decided(winner)

	DotLog.info(CHANNEL, "the round is decided", {"winner": winner, "why": told})


func _on_player_died(player: MmPlayer, damage: DotDamage) -> void:
	var by := entities.key_for_id(damage.attacker)
	var why: StringName = damage.context.get("why", DIED_SLAIN)

	if not authoritative:
		player_died.emit(player.player_id, by, why)
		return

	# A fall is a respawn; see [method _respawn_the_fallen]. Anything else is out for the round.
	if why == DIED_FELL:
		if not _to_respawn.has(player.player_id):
			_to_respawn.append(player.player_id)
	else:
		player.killed_by = by
		player.weapon_drawn = false

		if player.has_gun:
			_drop_gun(player, player.controller.state.position)

		var killer: MmPlayer = players.get(by) if by != &"" else null

		if killer != null and killer != player:
			last_killer = by
			killer.kills += 1
			if team_of(by) == MURDERERS:
				killer.points += config.kill_points
			if match_node != null:
				var _fed := match_node.report_kill(String(by), String(player.player_id), why, _tick)

		if progress != null:
			progress.on_killed(player.player_id, by, why)

		# No killer for the camera: a freeze camera on whoever did it would show the dead the
		# murderer, and the dead can still type in all chat. See docs/design.md "Roles are secret".
		if spectate != null:
			spectate.on_died(
				player.player_id, &"", false,
				damage.point if damage.point != Vector3.ZERO else player.global_position,
				map.kill_height() + 8.0, _tick
			)

	if progress != null and why == DIED_FELL:
		progress.on_fell(player.player_id)

	# How the body falls, picked once, here, and carried on DEATH to every client.
	player.death = decide_death(player, damage)

	player_died.emit(player.player_id, by, why)
	bots.on_died(player.player_id, by, why)
	DotLog.debug(CHANNEL, "player died", {"id": String(player.player_id), "by": String(by), "why": String(why)})

	if why != DIED_FELL:
		_check_round()


## The fall a death gets: dot-player-char's reaction rule over the server's weights, seeded from
## the player and the tick. A stab or a shot pushes the body away from whoever did it (the
## direction `_kill` puts on the damage, or the attacker's position), and a fall pushes nothing.
func decide_death(player: MmPlayer, damage: DotDamage) -> DotPlayerDeath:
	var direction := damage.direction
	var attacker: MmPlayer = players.get(entities.key_for_id(damage.attacker)) if damage.attacker != 0 else null
	if direction.length_squared() < 0.0001 and attacker != null and attacker != player:
		direction = player.controller.state.position - attacker.controller.state.position
	return DotPlayerDeath.decide(
		ragdoll_rules.reactions(), damage.is_headshot(), damage.amount, direction,
		DotPlayerDeath.seed_of(player.entity_id, _tick)
	)
