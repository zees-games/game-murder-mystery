extends DotGameCheckSuite

const MmCatalogue := preload("../game/mm_catalogue.gd")
const MmConfig := preload("../game/mm_config.gd")
const MmEvents := preload("../game/net/mm_events.gd")
const MmGame := preload("../game/mm_game.gd")
const MmNetCommand := preload("../game/net/mm_net_command.gd")
const MmMapDoc := preload("../game/mm_map_doc.gd")
const MmNetBridge := preload("../game/net/mm_net_bridge.gd")
const MmPlayer := preload("../game/mm_player.gd")
const MmEvent := preload("../game/net/mm_event.gd")
const MmRequest := preload("../game/net/mm_request.gd")
const CLIENT_PEER := 7
const SESSION := 42
const SERVER_TICK_RATE := 64
const CLIENT_ENGINE_TICK_RATE := 30
const SNAPSHOT_RATE := 30
const INPUT_LEAD := 3

## Two open stretches of the practice house's kitchen floor, five metres apart.
const KITCHEN_A := Vector3(3.0, 0.05, -3.0)
const KITCHEN_B := Vector3(8.0, 0.05, -3.0)

## The living room, across the wall from the kitchen.
const LIVING := Vector3(-3.0, 0.05, -3.0)

var _sections_entered := 0
var _sections_finished := 0
var _server_game: MmGame = null
var _client_game: MmGame = null
var _server_net: DotNetManager = null
var _client_net: DotNetManager = null
var _server_bridge: MmNetBridge = null
var _client_bridge: MmNetBridge = null
var _stand_in: MmPlayer = null
var _second: MmPlayer = null
var _to_client: Array = []
var _to_server: Array = []
var _tick: int = 0

## What the client was told, by kind, so a section can ask whether an event arrived. The
## repeating kinds (`roles`, `shots`, `guns`, `deaths`) are lists, cleared by [method _into_play].
var _heard: Dictionary = {}


func _build() -> bool:
	_section("bringing both halves up")
	var failed_before := _failed

	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)

	# The client's own physics space: two processes would be two worlds, and one world holding
	# both copies of a map is two of every collider in the same cubic metres.
	var client_view := SubViewport.new()
	client_view.name = "ClientView"
	client_view.own_world_3d = true
	client_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(client_view)

	var client_side := Node.new()
	client_side.name = "ClientSide"
	client_view.add_child(client_side)

	_server_game = _make_game(true, server_side)
	_client_game = _make_game(false, client_side)
	await get_tree().process_frame

	_check(_server_game.get_world_3d() != _client_game.get_world_3d(), "two physics worlds, as two processes would have")
	_check(_client_game.map_doc.is_empty() and _client_game.catalogue == null,
		"the client has no map and reads no map files; it will be sent one")

	Engine.physics_ticks_per_second = CLIENT_ENGINE_TICK_RATE

	_server_net = _make_manager(true, &"server", 1, server_side, SERVER_TICK_RATE)
	_client_net = _make_manager(false, &"client", CLIENT_PEER, client_side, CLIENT_ENGINE_TICK_RATE)
	# The harness stamps every command itself, so the client must not ask for dot-net's input-lead
	# report (it would steer the clock off commands it never stamped). Read by constant map so
	# this parses against a dot-net from before the report.
	var lead_bit := int((DotNetMessageRegistry as Script).get_script_constant_map().get("FEATURE_INPUT_LEAD", 0))
	_client_net.messages.features &= ~lead_bit

	_wire_bridges(server_side, client_side)

	# Started AFTER the bridge exists, which is what the module does: a map laid out before
	# anything listened to `world_rebuilt` would be a map no client is ever sent.
	_server_game.start()
	_check(not _server_game.map_doc.is_empty(), "the server lays its map out on start")
	_finished()
	return _failed == failed_before


## Seats the bridges, links them, and starts the two stand-ins.
func _wire_bridges(server_side: Node, client_side: Node) -> void:
	_server_bridge = MmNetBridge.new()
	_server_bridge.name = "Bridge"
	server_side.add_child(_server_bridge)

	_client_bridge = MmNetBridge.new()
	_client_bridge.name = "Bridge"
	client_side.add_child(_client_bridge)

	var attached := _server_bridge.attach(_server_game, _server_net)
	var client_attached := _client_bridge.attach(_client_game, _client_net)
	_check(attached.ok and client_attached.ok, "both bridges attach")

	_server_bridge.open_link(server_side)
	_client_bridge.open_link(client_side)
	_server_net.messages.seal()
	_client_net.messages.seal()
	_check(_server_net.messages.schema_hash() == _client_net.messages.schema_hash(), "both ends agree on the schema")

	_server_bridge.link.loopback = _on_server_send
	_client_bridge.link.loopback = _on_client_send
	_client_bridge.rtt_source = func() -> float: return 40.0

	var _s := _server_net.start()
	var _c := _client_net.start()

	_listen_to_server()

	_stand_in = _server_bridge.add_bot("Stand-in")
	_second = _server_bridge.add_bot("Second")
	_check(_stand_in != null and _stand_in.is_bot and _second != null, "two stand-ins are seated before anybody joins")
	# Seated as stand-ins, driven by the suite: a stand-in plays its role on its own, and this
	# suite wants them where it puts them.
	_stand_in.is_bot = false
	_second.is_bot = false


## Turns a server-side stand-in to look at [param target], and keeps it looking.
## Records what the client is told, so a section can ask whether an event arrived.
func _listen_to_server() -> void:
	_client_bridge.map_received.connect(func(id: StringName) -> void:
		_heard["map"] = id)
	for key: String in ["roles", "shots", "guns", "deaths"]:
		_heard[key] = []
	_client_bridge.role_received.connect(func(side: int, gun: bool, weapon_id: StringName) -> void:
		(_heard["roles"] as Array).append([side, gun, weapon_id]))
	_client_bridge.shot_received.connect(func(who: int, from: Vector3, to: Vector3, hit: bool) -> void:
		(_heard["shots"] as Array).append([who, from, to, hit]))
	_client_bridge.gun_received.connect(func(drop_id: int, down: bool, at: Vector3) -> void:
		(_heard["guns"] as Array).append([drop_id, down, at]))
	_client_bridge.death_received.connect(func(who: int, by: int, why: StringName) -> void:
		(_heard["deaths"] as Array).append([who, by, why]))
	_client_bridge.round_changed.connect(func(n: int, began: bool, winner: int, why: String) -> void:
		if not began:
			_heard["round_over"] = [n, winner, why])


func _look(player: MmPlayer, target: Vector3) -> void:
	var look := target - player.eye_position()
	var command := DotFpsCommand.new()
	command.yaw = rad_to_deg(atan2(-look.x, -look.z))
	command.pitch = clampf(rad_to_deg(asin(clampf(look.normalized().y, -1.0, 1.0))), -89.0, 89.0)
	player.controller.state.yaw = command.yaw
	player.controller.state.pitch = command.pitch
	player.controller.apply_command(command)


func _me() -> StringName:
	return MmNetBridge.player_key(SESSION)


func _mine() -> MmPlayer:
	return _client_game.players.get(_me())


func _server_me() -> MmPlayer:
	return _server_game.players[_me()]


## A command that looks from [param player]'s eye at [param target].
func _aim_at(player: MmPlayer, target: Vector3) -> DotFpsCommand:
	var look := target - player.eye_position()
	var command := DotFpsCommand.new()
	command.yaw = rad_to_deg(atan2(-look.x, -look.z))
	command.pitch = clampf(rad_to_deg(asin(clampf(look.normalized().y, -1.0, 1.0))), -89.0, 89.0)
	return command


## Ends the round in hand and plays into the next one's PLAY with [param roles] forced
## (`player id -> &"murderer" | &"gunner" | &"bystander"`), the lists in [member _heard] cleared
## first so a section reads only its own.
func _into_play(roles: Dictionary) -> void:
	_server_game.forced_roles = roles.duplicate()
	# Cleared before the end, not after the next begins: the new round's ROLE can arrive on the
	# very tick its number goes up.
	for key: String in ["roles", "shots", "guns", "deaths"]:
		_heard[key] = []
	var was := _server_game.round_number
	_server_game._decide(0, "the suite starts another")
	for _i in range(SERVER_TICK_RATE * 10):
		if _server_game.round_number > was:
			break
		await _step()
	_heard.erase("round_over")
	for _i in range(SERVER_TICK_RATE * 10):
		if _server_game.phase == MmGame.Phase.PLAY:
			break
		await _step()
	await _steps(8)


func _make_game(server: bool, parent: Node) -> MmGame:
	var config := MmConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.grace_seconds = 0.5
	config.round_seconds = 600.0
	config.minimum_players = 0
	config.keep_progress = false
	config.bot_chat = false
	config.map_ids = PackedStringArray(["mm_practice"])

	var game := MmGame.new()
	game.name = "World"
	game.config = config
	game.authoritative = server
	game.tick_rate = SERVER_TICK_RATE if server else CLIENT_ENGINE_TICK_RATE
	game.register_service = false
	parent.add_child(game)
	game.set_physics_process(false)
	return game


func _make_manager(server: bool, scope: StringName, peer_id: int, parent: Node, tick_rate: int) -> DotNetManager:
	var manager := DotNetManager.new()
	manager.name = "Server" if server else "Client"
	manager.is_server = server
	manager.local_peer_id = peer_id
	manager.service_scope = scope
	manager.auto_tick = false
	manager.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = tick_rate
	config.snapshot_rate = SNAPSHOT_RATE
	config.enable_prediction = true
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 192
	config.world_extent = MmGame.NET_WORLD_EXTENT
	manager.config = config

	parent.add_child(manager)
	var _ready_now := manager.setup()
	return manager


func _on_server_send(method: StringName, peer_id: int, payload: PackedByteArray) -> void:
	if peer_id != 0 and peer_id != CLIENT_PEER:
		return

	_to_client.append({"method": method, "payload": payload})


func _on_client_send(method: StringName, _peer_id: int, payload: PackedByteArray) -> void:
	_to_server.append({"method": method, "payload": payload})


func _flush() -> void:
	var to_client := _to_client.duplicate()
	var to_server := _to_server.duplicate()
	_to_client.clear()
	_to_server.clear()

	for entry in to_client:
		_client_bridge.link.deliver(entry["method"], 1, entry["payload"])

	for entry in to_server:
		_server_bridge.link.deliver(entry["method"], CLIENT_PEER, entry["payload"])


func _exchange() -> void:
	_flush()
	_flush()


## One tick on both ends, with a real physics frame between them.
func _step(command: DotFpsCommand = null) -> void:
	_tick += 1
	var _ticks := _client_net.clock.advance(1.0 / float(maxi(_client_game.tick_rate, 1)))
	_server_bridge.server_tick(_tick)
	_flush()
	_client_bridge.client_tick(_tick + INPUT_LEAD, command if command != null else DotFpsCommand.new())
	_flush()
	await get_tree().physics_frame


func _steps(count: int, command: DotFpsCommand = null) -> void:
	for _i in range(count):
		await _step(command)


func _section(name: String) -> void:
	_sections_entered += 1
	print(name)


func _finished() -> void:
	_sections_finished += 1
