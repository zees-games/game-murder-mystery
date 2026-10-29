extends "mm_game_world.gd"

## The simulation: headless, authoritative, and the only thing that decides anything. The state
## is in mm_game_state.gd; this is the round, the draw, the weapon and the gun.
## Roles are secret: [member sides] lives on the server (docs/design.md).

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
		spectate.on_spawned(player.player_id)


## The spawn group every map is read into.
const SPAWN_GROUP := "players"


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
		spectate.on_left(player_id)

	if progress != null:
		progress.leave(player_id)

	if block_rules != null:
		block_rules.call(&"forget", player_id)
	apply_pass_through()
	player_removed.emit(player_id)

	if authoritative and phase != Phase.IDLE:
		_check_round()


func team_of(player_id: StringName) -> int:
	return int(sides.get(player_id, 0))


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


## player id -> &"murderer", &"gunner" or &"bystander": roles the next draws hand out instead
## of drawing them. Empty in play. With any entry, gunners are only the ones named.
var forced_roles: Dictionary = {}


## Who is the murderer and who has the gun this round, and everybody's shirt.
## Murderers by [DotTeamRotation] over a history, gunners at random from the rest;
## [member forced_roles] overrides the draw for the people it names.
func _draw_roles() -> void:
	var keys: Array[StringName] = []

	for id: StringName in players:
		keys.append(id)

	keys.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))

	var want := config.murderers_for(keys.size())
	# Seats behind a loading cover are not drawn while enough others can be: a murderer that
	# cannot see would sit out the round. If too few are loaded, everybody is a candidate.
	var loaded: Array[StringName] = []

	for id in keys:
		if can_be_harmed(id):
			loaded.append(id)

	var candidates := loaded if loaded.size() >= want else keys
	var picked: Dictionary = DotTeamRotation.pick(
		candidates, want, DotTeamRotation.Mode.RANDOM, murderer_history, _round_seed, {}
	)
	var murderers: Array[StringName] = []

	for id: StringName in picked["picked"]:
		murderers.append(id)

	if not forced_roles.is_empty():
		murderers.clear()
		for id: StringName in keys:
			if forced_roles.get(id, &"") == &"murderer":
				murderers.append(id)
		# Nobody forced to be one: the draw's, less anybody forced to be something else.
		if murderers.is_empty():
			for id: StringName in picked["picked"]:
				if not forced_roles.has(id):
					murderers.append(id)

	DotTeamRotation.note(murderer_history, keys, murderers, round_number)

	var rest: Array[StringName] = []

	for id in keys:
		if not murderers.has(id):
			rest.append(id)

	var stream := random.stream(&"roles")
	var gunners: Array[StringName] = []
	var pool := rest.duplicate()
	var loaded_pool: Array[StringName] = []

	for id in pool:
		if can_be_harmed(id):
			loaded_pool.append(id)

	if loaded_pool.size() >= config.gunners_for(keys.size(), rest.size()):
		pool = loaded_pool

	if not forced_roles.is_empty():
		for id in rest:
			if forced_roles.get(id, &"") == &"gunner":
				gunners.append(id)
				pool.erase(id)
			elif forced_roles.has(id):
				pool.erase(id)

	for _i in range(maxi(config.gunners_for(keys.size(), rest.size()) - gunners.size(), 0)):
		if pool.is_empty() or not forced_roles.is_empty():
			break
		gunners.append(pool.pop_at(stream.next_range_i(0, pool.size() - 1)))

	# The shirts: a shuffled palette, so no two share one until there are more people than
	# colours.
	var palette: Array[int] = []

	for i in range(SHIRTS.size()):
		palette.append(i)

	for i in range(palette.size() - 1, 0, -1):
		var j := stream.next_range_i(0, i)
		var swap := palette[i]
		palette[i] = palette[j]
		palette[j] = swap

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


## The murderer's weapon this server carries: the configured id, or the knife.
func weapon_id() -> StringName:
	var id := StringName(config.murderer_weapon) if config != null else MmWeapons.DEFAULT
	return id if MmWeapons.known(id) else MmWeapons.DEFAULT


func melee_reach() -> float:
	return config.melee_range if config.melee_range > 0.0 else float(MmWeapons.entry(weapon_id())["reach"])


func melee_cooldown() -> float:
	return config.melee_cooldown if config.melee_cooldown > 0.0 else float(MmWeapons.entry(weapon_id())["cooldown"])


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


## The map menu's change: [param id] now, not after this map's rounds. The next map is set and
## a fresh round begins on it (dot-match's `begin_round_now`: the round called off has no
## winner); with no match running it is simply built. Authority only.
func change_map_now(id: StringName) -> DotResult:
	if not authoritative:
		return DotResult.fail(DotError.CODE_STATE, "Only the server changes the map.")
	if catalogue == null or not catalogue.playable(config.map_ids).has(id):
		return DotResult.fail(DotError.CODE_INVALID, "There is no map called '%s' here." % id)
	next_map_id = id
	if match_node == null or not match_node.begin_round_now(_tick):
		_lay_out_map()
	DotLog.info(CHANNEL, "map changed from the map menu", {"map": String(id)})
	return DotResult.success(id)


func _lay_out_map() -> void:
	if catalogue == null:
		return

	var doc: Dictionary = {}

	if next_map_id != &"" and catalogue.playable(config.map_ids).has(next_map_id):
		doc = catalogue.maps[next_map_id]

	next_map_id = &""

	if doc.is_empty():
		# A map installed since the file was read may match it now.
		apply_rotation()
		var cycling := rotation_file != null and rotation_file.has_rotations() \
			and map_rotation != null and map_rotation.mode == DotMapRotation.Mode.SEQUENTIAL
		doc = catalogue.next_map(
			config.map_ids, config.shuffle_maps and not cycling, random.stream(&"map"),
			StringName(str(map_doc.get("id", ""))), rotation_pool()
		)

	var _built := build_map(doc)
	_rounds_on_map = 0
	_map_unplayed = true
	_place_everybody()


## Builds [param doc] as the map. What the server does between rounds, and what a client does
## when it is sent one.
func build_map(doc: Dictionary) -> DotResult:
	world_clearing.emit()

	var built := map.build(doc)

	if not built.ok:
		DotLog.error(CHANNEL, "a map would not build", {"id": str(doc.get("id", "?")), "why": built.error.message})
		return built

	map_doc = map.doc

	if spectate != null:
		spectate.set_overviews(map.overview(), map.overview())

	world_rebuilt.emit()
	return built


## Everybody to a spawn point, at full health, empty handed.
func _place_everybody() -> void:
	var ids := players.keys()
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))

	# Shuffled with the round, so the murderer is not always the one by the stairs.
	var stream := random.stream(&"spawns")
	var offset := stream.next_range_i(0, 63)
	var spots := map.spawn_batch(SPAWN_GROUP, ids.size(), config.spawn_rules(), offset)

	for index in range(ids.size()):
		var id: StringName = ids[index]
		var player: MmPlayer = players[id]
		player.reset_round()
		_heal(player)

		var spot: Array = spots[index]
		player.place_at(spot[0], spot[1])

		if spectate != null:
			spectate.on_spawned(player.player_id)


func _heal(player: MmPlayer) -> void:
	if player.health != null:
		player.health.max_health = config.player_health
		player.health.health = player.health.max_health
		player.health.alive = true
		player.health.invulnerable = false


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


## How long the hunt lasts: the map's, under the server's ceiling.
func round_limit() -> float:
	var asked := float(map_doc.get("round_seconds", 0.0))
	return minf(asked, config.round_seconds) if asked > 0.0 else config.round_seconds


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


## Everybody's hand on the doors: a use is the use key going down in front of one, then every
## door is posed for this tick. The edge is made here from the held state, as for the weapons.
func _advance_doors() -> void:
	if map == null or map.doors == null or map.doors.count() == 0:
		return

	map.doors.pose_at(_tick)


## The use key going down, for everybody: on a toy looked at (a ray, so only the one in the
## middle of the view), else on the nearest door in reach.
func _advance_use() -> void:
	for id: StringName in players:
		var player: MmPlayer = players[id]
		var pressed := player.wants_use and not player.use_was_held
		player.use_was_held = player.wants_use

		if not pressed or not player.is_alive() or player.watching or map == null:
			continue

		# Held is held: somebody an admin froze does not open the door they are facing.
		if player.controller.has_modifier(MmController.HOLD):
			continue

		var toy := toy_aimed(player)

		if toy >= 0:
			var _played := use_toy(toy, id)
			continue

		if map.doors == null or map.doors.count() == 0:
			continue

		var index := map.doors.door_for(player.eye_position(), player.aim_direction())

		if index >= 0:
			var _used := use_door(index, id)


## Opens or shuts door [param index] for [param by], now, if it can be. What the use key does,
## and what a suite and a bot do directly.
func use_door(index: int, by: StringName) -> bool:
	if map == null or map.doors == null or index < 0 or index >= map.doors.count():
		return false

	if not config.doors_enabled:
		return false

	if map.doors.moving(index, _tick):
		return false

	# Nobody anywhere the panel will pass through: see MmDoors. Opening, it goes away from
	# whoever opened it.
	var from := map.doors.fraction(index, _tick)
	var to := 0.0 if map.doors.is_open(index) else 1.0
	var user := (players[by] as MmPlayer).eye_position() if players.has(by) else Vector3.INF
	var flip := map.doors.is_flipped(index)

	if to > 0.5 and user != Vector3.INF:
		flip = map.doors.flips_for(index, user)

	for id: StringName in players:
		var player: MmPlayer = players[id]

		if not player.is_alive() or player.watching:
			continue

		if map.doors.sweeps(index, player.controller.state.position, MmPlayer.BODY_RADIUS,
				player.hull_height(), from, to, 1 if flip else 0):
			if players.has(by) and not (players[by] as MmPlayer).is_bot:
				refused.emit(by, "Somebody is in the way of the %s." % map.doors.name_of(index))
			return false

	var open := to > 0.5
	map.doors.apply(index, open, flip, _tick)
	door_used.emit(index, open, flip, _tick, by)

	if progress != null and players.has(by):
		progress.on_door(by)

	DotLog.debug(CHANNEL, "a door was used", {
		"door": map.doors.name_of(index), "open": open, "by": String(by), "tick": _tick,
	})
	return true


## The toy [param player] is looking at within reach, or -1. Both ends: the client asks it
## for the use prompt.
func toy_aimed(player: MmPlayer) -> int:
	if map == null or map.toys == null or player == null:
		return -1
	return map.toys.aimed(player.eye_position(), player.aim_direction(), config.toy_reach)


## How far the use key reaches a toy: a ball at your feet, a switch at arm's length.


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


func current_tick() -> int:
	return _tick


## Simulated seconds, from the tick. What every timer in the game counts.
## A stand-in's chat line, from MmBots.
func bot_say(id: StringName, text: String) -> void:
	if players.has(id) and text != "":
		bot_said.emit(id, text)


func _now() -> float:
	return float(_tick) / float(maxi(tick_rate, 1))


func _step(delta: float) -> void:
	_respawn_the_fallen()
	_advance_phase(delta)
	_advance_holds()
	_drive_bots()
	_advance_use()
	_advance_doors()

	for id: StringName in players:
		var player: MmPlayer = players[id]

		if player.is_alive() and not player.watching:
			player.simulate(_tick, delta)

	if authoritative:
		_record_trail()

	_advance_toys(delta)

	_watch_world()
	_advance_weapons()

	if combat != null:
		combat.tick(_tick, delta)

	if spectate != null:
		spectate.advance(_tick)

	if not sides_are_playable() and phase == Phase.IDLE:
		return

	match_node.tick(_tick)


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
			spectate.on_spawned(id)


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


## What every stand-in presses this tick: [code]mm_bots.gd[/code].
func _drive_bots() -> void:
	bots.drive()


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
