extends "mm_game_draw.gd"

## The simulation: headless, authoritative, and the only thing that decides anything. State is in
## mm_game_state.gd; this is the round, the draw, the weapon and the gun. Roles are secret:
## [member sides] lives on the server (docs/design.md).

func _ready() -> void:
	if config == null:
		config = MmConfig.new()

	var valid := config.validate()

	if not valid.ok:
		DotLog.error(CHANNEL, "the configuration is not usable", {"why": valid.error.message})
		return

	_round_seed = config.seed_value

	_build_physics()
	if not body_rules.changed.is_connected(_on_body_rules_changed):
		body_rules.changed.connect(_on_body_rules_changed)
	_apply_gravity()
	_build_random()
	_build_props()
	_build_map()
	_build_combat()
	_build_effects()
	_build_match()
	_build_spectate()
	_build_progress()

	if authoritative:
		catalogue = MmCatalogue.new()
		var _loaded := catalogue.load_from(config.map_directory)
		# The other games' packs, mounted beside this one's (see .gitignore's bootstrap links
		# and MmCatalogue.add_extra_directories).
		var _extra := catalogue.add_extra_directories(config.extra_map_directory)
		# Solo in the client shell: the map packs it mounted for this game.
		for root in solo_map_dirs("maps"):
			var _added := catalogue.add_directory(root)
		var _rotation := load_rotation()
		# Laid out now, not on the first round: a warmup on an empty world is
		# indistinguishable from a map that failed to load.
		_lay_out_map()

	if register_service:
		DotRegistry.register(SERVICE, self)

	DotLog.info(CHANNEL, "world ready", config.describe())


## The `<pack>/<subdir>` map directories a host running this game without a server has mounted
## (the client shell's Solo play), read as the module reads its server's. Empty elsewhere;
## duck-typed, because a delivered game may not name a host's class.
static func solo_map_dirs(subdir: String) -> PackedStringArray:
	var host: Object = DotRegistry.get_service(SOLO_SERVICE)
	if host == null or not host.has_method(&"map_dirs"):
		return PackedStringArray()
	return host.call(&"map_dirs", subdir)


func _exit_tree() -> void:
	if register_service:
		DotRegistry.unregister_instance(SERVICE, self)


func _build_match() -> void:
	match_node = DotMatch.new()
	match_node.name = "Match"
	match_node.register_service = false

	var match_config := DotMatchConfig.new()
	match_config.tick_rate = tick_rate
	match_config.auto_start = false
	match_config.log_transitions = false
	# Off: the roles are this game's to draw (see [method _draw_roles]).
	match_config.balance_between_rounds = false
	match_node.config = match_config

	var match_rules: DotMatchRules = MmRules.make()
	match_rules.intermission_sec = config.intermission_seconds
	match_rules.warmup_sec = config.warmup_seconds
	match_rules.countdown_sec = 0.0
	match_rules.team_based = true
	match_rules.min_players = 2
	match_rules.set(&"decision_fn", _decision)
	match_rules.time_limit_sec = config.grace_seconds + config.round_seconds + 60.0
	match_node.rules = match_rules

	# Scoped to the match node, which finds nothing: this game places its own players.
	match_node.spawns_ref = DotNodeRef.of_path(^".")
	add_child(match_node)

	match_node.round_started.connect(_on_round_started)
	match_node.round_ended.connect(_on_round_ended)

	var teams: Array[DotTeam] = [
		DotTeam.make(BYSTANDERS, TEAM_NAMES[0], TEAM_COLOURS[0]),
		DotTeam.make(MURDERERS, TEAM_NAMES[1], TEAM_COLOURS[1]),
	]
	match_node.teams.teams = teams
	match_node.teams.force_balance = false
	match_node.teams.allow_choice = false
	match_node.teams.max_difference = 0
	match_node.teams.reindex()


func _decision() -> Dictionary:
	return {"decided": _decided, "winner": _winner}


## Puts somebody in the world. [param wanted_side] is ignored but for a suite's
## [constant MURDERERS]. Somebody who joins during the hunt watches until the next round: a
## newcomer with no role would be a free body for the murderer.
func add_player(
	player_id: StringName,
	display_name: String,
	wanted_side: int = 0,
	samples_input: bool = false
) -> MmPlayer:
	if players.has(player_id):
		return players[player_id]

	var side := MURDERERS if wanted_side == MURDERERS else BYSTANDERS

	var player := MmPlayer.new()
	player.name = "Player_%s" % String(player_id)
	player.player_id = player_id
	player.display_name = display_name
	player.samples_input = samples_input
	player.tick_rate = tick_rate
	player.config = config
	player.team = side
	player.weapon_id = weapon_id()
	player.shirt = (players.size() * 5 + 3) % SHIRTS.size()
	add_child(player)

	if physics != null:
		var applied := physics.apply_to(player, &"player")

		if not applied.ok:
			DotLog.warn(CHANNEL, "a player could not be put on its collision layer", {"why": applied.error.message})

		_apply_body_mask(player)

	var opened := entities.open(
		DotEntity.KIND_PLAYER, player, &"", player_id, float(_tick) / float(maxi(tick_rate, 1))
	)
	player.entity_id = (opened.value as DotEntityHandle).id if opened.ok else 0

	var health := DotHealth.new()
	health.name = "Health"
	health.max_health = config.player_health
	health.health = health.max_health
	player.add_child(health)
	player.health = health

	if combat != null:
		combat.register_health(player.entity_id, health)

	if combat != null and player.controller != null:
		var fall := DotFallDamage.new()
		fall.name = "FallDamage"
		fall.rules = fall_rules
		fall.victim = player.entity_id
		fall.controller = DotNodeRef.of_path(player.controller.get_path())
		fall.controller.mode = DotNodeRef.Mode.ABSOLUTE
		fall.combat = DotNodeRef.of_path(combat.get_path())
		fall.combat.mode = DotNodeRef.Mode.ABSOLUTE
		# No ladders or noclip here; nobody is hurt between rounds (the intermission).
		fall.context_checks = {&"protected": func() -> bool: return phase == Phase.IDLE}
		player.add_child(fall)

	health.died.connect(func(damage: DotDamage) -> void: _on_player_died(player, damage))

	players[player_id] = player
	sides[player_id] = side

	player.controller.launcher = _launch
	var _b := player.controller.bounced.connect(_on_bounced)
	player.controller.carrier = _carry

	if match_node != null:
		var seated := match_node.add_player(String(player_id), display_name, _tick, side)

		if not seated.ok:
			DotLog.error(CHANNEL, "dot-match refused a player", {"id": String(player_id), "why": seated.error.message})

	place_one(player)

	if authoritative and phase == Phase.PLAY and wanted_side == 0:
		_bench(player)

	player.retune()
	DotLog.debug(CHANNEL, "player joined", {"id": String(player_id)})
	apply_pass_through()
	player_added.emit(player_id)
	return player


## Puts one player at a spawn point. Every map's points are one group here (see mm_map_doc.gd).
func place_one(player: MmPlayer) -> void:
	if map == null or map.doc.is_empty():
		return

	var spot := map.spawn(SPAWN_GROUP, players.size() - 1)
	player.place_at(spot[0], spot[1])

	if spectate != null:
		spectate.spawned(player.player_id)


func _bench(player: MmPlayer) -> void:
	player.watching = true

	if player.health != null:
		player.health.invulnerable = true

	if spectate != null:
		spectate.on_died(player.player_id, &"", false, player.controller.state.position,
			map.kill_height() + 8.0, _tick)


func remove_player(player_id: StringName) -> void:
	if not players.has(player_id):
		return

	var player: MmPlayer = players[player_id]

	if authoritative and player.has_gun and player.is_alive():
		_drop_gun(player, player.controller.state.position)

	if combat != null and is_instance_valid(combat) and player.entity_id != 0:
		combat.forget(player.entity_id)
		var _closed := entities.close(player.entity_id, DotEntityTable.REASON_OWNER_LEFT)

	var _gone := _trail.erase(player_id)

	if match_node != null:
		match_node.remove_player(String(player_id))

	players.erase(player_id)
	sides.erase(player_id)
	bots.forget(player_id)
	_to_respawn.erase(player_id)

	player.queue_free()

	if spectate != null:
		spectate.left(player_id)

	if progress != null:
		progress.leave(player_id)

	if block_rules != null:
		block_rules.call(&"forget", player_id)
	apply_pass_through()
	player_removed.emit(player_id)

	if authoritative and phase != Phase.IDLE:
		_check_round()


func start() -> void:
	if not authoritative:
		return

	# Built again here: on a server nothing was listening when the world opened (the module
	# builds the bridge after), and a map built before it is a map no client is ever sent.
	var id := StringName(str(map_doc.get("id", "")))

	if not map_doc.is_empty() and catalogue != null and catalogue.playable(config.map_ids).has(id):
		var _rebuilt := build_map(map_doc)
		_place_everybody()
	else:
		_lay_out_map()

	match_node.start(_tick)


func _on_round_started(number: int) -> void:
	round_number = number
	_round_seed = config.seed_value + number * 7919
	random.reseed(_round_seed)

	# A new map once this one has had its rounds, or as soon as the players voted for one.
	if next_map_id != &"" or (_rounds_on_map >= config.rounds_per_map and not _map_unplayed):
		_lay_out_map()

	_map_unplayed = false
	_decided = false
	_winner = 0
	_winner_name = ""
	revealed = PackedStringArray()
	last_killer = &""
	play_elapsed = 0.0
	bots.reset()
	_to_respawn.clear()
	_clear_drops()

	if map.doors != null:
		map.doors.reset()

	if map.toys != null:
		map.toys.reset()

	_place_everybody()
	_draw_roles()

	if progress != null:
		progress.on_round_began()

	_set_phase(Phase.GRACE)

	# Told after the phase moves: the net bridge sends nothing to a seat while the phase is IDLE
	# (a role is only a thing in a round), so a first round told from inside the draw went out
	# to nobody.
	var drawn: Array = players.keys()
	drawn.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))

	for id: StringName in drawn:
		role_drawn.emit(id, team_of(id), (players[id] as MmPlayer).has_gun)

	round_began.emit(number, map.id())

	DotLog.info(CHANNEL, "round began", {
		"number": number, "map": String(map.id()), "seed": _round_seed,
		"players": players.size(), "murderers": ", ".join(_names(players_on(MURDERERS))),
	})


func _on_round_ended(number: int, winner: int, _outcome: int) -> void:
	_set_phase(Phase.IDLE)
	_rounds_on_map += 1

	if not _decided:
		_winner_name = "the round ran out"
		revealed = _names(players_on(MURDERERS))

	if progress != null:
		progress.on_round_over(winner)

	round_over.emit(number, winner, _winner_name)
	DotLog.info(CHANNEL, "round over", {"number": number, "winner": _winner_name})



## Who is the murderer and who has the gun this round, and everybody's shirt.
## Murderers by [DotTeamRotation] over a history, gunners at random from the rest;
## [member forced_roles] overrides the draw for the people it names.
func _draw_roles() -> void:
	var keys: Array[StringName] = []

	for id: StringName in players:
		keys.append(id)

	keys.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))

	var murderers := _draw_murderers(keys)

	DotTeamRotation.note(murderer_history, keys, murderers, round_number)

	var rest: Array[StringName] = []

	for id in keys:
		if not murderers.has(id):
			rest.append(id)

	var stream := random.stream(&"roles")
	var gunners := _draw_gunners(keys.size(), rest, stream)
	var palette := _shirt_palette(stream)
	var weapon := weapon_id()

	for index in range(keys.size()):
		var id := keys[index]
		var player: MmPlayer = players[id]
		player.shirt = palette[index % palette.size()]
		player.weapon_id = weapon
		_set_side(id, MURDERERS if murderers.has(id) else BYSTANDERS)
		player.has_gun = gunners.has(id)
		player.retune()


func _set_side(id: StringName, side: int) -> void:
	var player: MmPlayer = players.get(id)

	if player == null:
		return

	var was := int(sides.get(id, 0))
	sides[id] = side
	player.team = side

	if match_node != null and was != side:
		var _moved := match_node.switch_team(String(id), side, _tick)

	if was != side:
		side_changed.emit(id, side)


func _set_phase(to: int) -> void:
	if phase == to:
		return

	phase = to
	phase_elapsed = 0.0

	phase_changed.emit(to)
	DotLog.debug(CHANNEL, "the round changed phase", {"phase": Phase.keys()[to]})


func _advance_phase(delta: float) -> void:
	if phase == Phase.IDLE:
		return

	phase_elapsed += delta

	match phase:
		Phase.GRACE:
			if phase_elapsed >= grace_limit():
				play_elapsed = 0.0
				_set_phase(Phase.PLAY)
			else:
				_check_round()
		Phase.PLAY:
			play_elapsed += delta
			_advance_blood()
			_check_round()


## Rounds still to play on this map, this one included. 1 is the last.
func rounds_left_on_map() -> int:
	return maxi(config.rounds_per_map - _rounds_on_map, 1)


## How long the grace lasts: the map's, under the server's.
func grace_limit() -> float:
	var asked := float(map_doc.get("grace_seconds", 0.0))
	return minf(asked, config.grace_seconds) if asked > 0.0 else config.grace_seconds


## The blood on the murderers: none until [member MmConfig.blood_seconds] before the end, then
## rising in [member MmConfig.blood_stages] steps to the whole of it at the buzzer, with a step
## more for each kill when [member MmConfig.blood_per_kill].
func _advance_blood() -> void:
	var stages := config.blood_stages
	var timed := 0

	if config.blood_seconds > 0.0:
		var into := config.blood_seconds - (round_limit() - play_elapsed)
		if into > 0.0:
			timed = clampi(int(ceil(into / config.blood_seconds * float(stages))), 1, stages)

	for player in players_on(MURDERERS):
		var from_kills := player.kills if config.blood_per_kill and config.blood_seconds > 0.0 else 0
		player.blood = mini(timed + from_kills, stages)


func _physics_process(delta: float) -> void:
	if not authoritative or match_node == null or external_tick:
		return

	simulate(delta)


## One tick, counted by this world. What an offline client and the suite use.
func simulate(delta: float) -> void:
	_tick += 1
	_step(delta)


## One tick, numbered by the netcode. What the bridge uses.
func tick_once(tick: int) -> void:
	if match_node == null:
		return

	_tick = tick
	_step(delta_for_tick())


func current_tick() -> int:
	return _tick


## Simulated seconds, from the tick. What every timer in the game counts.
## A stand-in's chat line, from MmBots.
func bot_say(id: StringName, text: String) -> void:
	if players.has(id) and text != "":
		bot_said.emit(id, text)


func _step(delta: float) -> void:
	_respawn_the_fallen()
	_advance_phase(delta)
	_advance_holds()
	_drive_bots()
	_advance_use()
	_advance_doors()

	_pre_vy.clear()

	for id: StringName in players:
		var player: MmPlayer = players[id]

		if player.is_alive() and not player.watching:
			_pre_vy[id] = player.controller.state.velocity.y
			player.simulate(_tick, delta)

	_resolve_stomps()

	if authoritative:
		_record_trail()

	_advance_toys(delta)
	_advance_flashlights()
	_watch_world()
	_advance_weapons()

	if combat != null:
		combat.tick(_tick, delta)

	if spectate != null:
		spectate.advance(_tick)

	if not sides_are_playable() and phase == Phase.IDLE:
		return

	match_node.tick(_tick)


## A fall below the map is not the end of anybody: they start again at a spawn point, with what
## they carried.
func _respawn_the_fallen() -> void:
	if _to_respawn.is_empty():
		return

	var queue := _to_respawn.duplicate()
	_to_respawn.clear()

	for id: StringName in queue:
		var player: MmPlayer = players.get(id)

		if player == null:
			continue

		_heal(player)

		if player.watching:
			continue

		var spot := map.spawn(SPAWN_GROUP, _tick % 97)
		player.place_at(spot[0], spot[1])

		if spectate != null:
			spectate.spawned(id)


func delta_for_tick() -> float:
	return 1.0 / float(maxi(tick_rate, 1))


func set_tick_rate(rate: int) -> bool:
	if rate <= 0 or rate == tick_rate:
		return false

	tick_rate = rate

	for id: StringName in players:
		(players[id] as MmPlayer).tick_rate = rate

	if match_node != null and match_node.config != null:
		match_node.config.tick_rate = rate

	if map != null:
		map.tick_rate = rate

		if map.doors != null:
			map.doors.set_tick_rate(rate)

	return true


## What every stand-in presses this tick: [code]mm_bots.gd[/code].
func _drive_bots() -> void:
	bots.drive()


func seconds_left() -> float:
	match phase:
		Phase.GRACE:
			return maxf(grace_limit() - phase_elapsed, 0.0)
		Phase.PLAY:
			return maxf(round_limit() - play_elapsed, 0.0)
		_:
			return 0.0


func describe() -> Dictionary:
	return {
		"round": round_number,
		"phase": Phase.keys()[phase],
		"left": "%.0f s" % seconds_left(),
		"map": str(map_doc.get("id", "-")),
		"players": players.size(),
		"alive": alive_total(),
		"murderers": alive_on(MURDERERS),
		"guns down": gun_drops.size(),
		"decided": _winner_name if _decided else "-",
		"maps": catalogue.maps.size() if catalogue != null else 0,
		"phase_id": phase,
	}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["murder, round %d" % round_number])
	var facts := describe()

	for key: String in facts:
		lines.append("  %-12s %s" % [key, facts[key]])

	for id: StringName in players:
		var player: MmPlayer = players[id]
		lines.append("  %-10s %-18s %s%s%s" % [
			side_name(team_of(id)), player.display_name,
			"gun" if player.has_gun else ("drawn" if player.weapon_drawn else "-"),
			" blood %d" % player.blood if player.blood > 0 else "",
			"" if player.is_alive() else " (out)",
		])

	if map != null:
		lines.append_array(map.describe_lines())

	return lines
