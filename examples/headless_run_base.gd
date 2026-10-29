extends DotGameCheckSuite
## The headless_run suite's world builders and drivers, so the suite itself holds only the tests.

const MmConfig := preload("../game/mm_config.gd")
const MmGame := preload("../game/mm_game.gd")
const MmPlayer := preload("../game/mm_player.gd")

const TICK_RATE := 64
const TICK := 1.0 / float(TICK_RATE)

## Out of everybody's way, in the garden: where a test parks whoever it is not about.
const PARK := Vector3(18.0, 0.05, 5.0)

var _worlds: Array[MmGame] = []


## A world on the practice house, stepped by hand. The previous one is freed first: every
## world here shares ONE physics space, and every map is built at the origin.
func _world(configure: Callable = Callable()) -> MmGame:
	for old in _worlds.duplicate():
		await _dispose(old)

	var config := MmConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.map_ids = PackedStringArray(["mm_practice"])
	config.keep_progress = true
	config.grace_seconds = 0.25
	config.bot_chat = false

	if configure.is_valid():
		configure.call(config)

	var game := MmGame.new()
	game.name = "World%d" % _worlds.size()
	game.config = config
	game.tick_rate = TICK_RATE
	game.authoritative = true
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	_worlds.append(game)

	await _physics_frame()
	await _physics_frame()
	return game


## A world with [param roles] (id -> role) forced, its round started, and (unless
## [param to_play] is false) its grace over.
func _round(roles: Dictionary, configure: Callable = Callable(), to_play: bool = true) -> MmGame:
	var game := await _world(configure)
	var index := 0
	for id: StringName in roles:
		var _p := game.add_player(id, "Person%d" % index)
		index += 1
	game.forced_roles = roles.duplicate()
	game.start()
	await _wait_for(game, MmGame.Phase.GRACE)
	if to_play:
		await _wait_for(game, MmGame.Phase.PLAY)
	return game


func _p(game: MmGame, id: StringName) -> MmPlayer:
	return game.players[id]


## Everybody named out to the garden, a step apart, where nothing in the house can reach them.
func _park(game: MmGame, ids: Array) -> void:
	var i := 0
	for id: StringName in ids:
		_p(game, id).place_at(PARK + Vector3(float(i) * 1.5, 0.0, 0.0), 0.0)
		i += 1


func _chest(player: MmPlayer) -> Vector3:
	return player.controller.state.position + Vector3(0.0, 1.2, 0.0)


func _gunners(game: MmGame) -> Array[MmPlayer]:
	var out: Array[MmPlayer] = []
	for id: StringName in game.players:
		if (game.players[id] as MmPlayer).has_gun:
			out.append(game.players[id])
	return out


func _wait_for(game: MmGame, phase: int) -> void:
	for i in range(TICK_RATE * 20):
		if game.phase == phase:
			return
		await _step(game, 1)


## Ends the round in play (the murderers die, the bystanders win) and waits for the next.
func _end_round(game: MmGame) -> void:
	var number := game.round_number
	while game.phase == MmGame.Phase.GRACE:
		await _step(game, 1)
	for murderer in game.players_on(MmGame.MURDERERS):
		game._kill(murderer, null, MmGame.DIED_SLAIN)
	for i in range(TICK_RATE * 20):
		await _step(game, 1)
		if game.round_number > number and game.phase != MmGame.Phase.IDLE:
			return


func _step(game: MmGame, ticks: int) -> void:
	for _i in range(ticks):
		game.simulate(TICK)
		await _physics_frame()


func _physics_frame() -> void:
	await get_tree().physics_frame


func _dispose(game: MmGame) -> void:
	_worlds.erase(game)

	if not is_instance_valid(game):
		return

	remove_child(game)
	game.free()
	await get_tree().process_frame


func _drive(player: MmPlayer, move: Vector2) -> void:
	var command := DotFpsCommand.new()
	command.yaw = player.controller.state.yaw
	command.move = move
	player.controller.apply_command(command)


func _aim(player: MmPlayer, target: Vector3) -> void:
	var look := target - player.eye_position()
	var command := DotFpsCommand.new()
	command.yaw = rad_to_deg(atan2(-look.x, -look.z))
	command.pitch = clampf(rad_to_deg(asin(clampf(look.normalized().y, -1.0, 1.0))), -89.0, 89.0)
	player.controller.state.yaw = command.yaw
	player.controller.state.pitch = command.pitch
	player.controller.apply_command(command)


func _prop_near(game: MmGame, at: Vector3) -> int:
	for index in range(game.map.props.size()):
		if ((game.map.props[index] as Dictionary)["transform"] as Transform3D).origin.distance_to(at) < 0.05:
			return index
	return -1
