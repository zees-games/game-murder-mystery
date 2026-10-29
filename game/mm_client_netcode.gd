extends "mm_client_events.gd"

## The netcode build and the connected half's hello and roster. Path-based base of [code]mm_client.gd[/code], no class_name.


## Offline: the world is the authority, so its own signals are what happened. A connected
## client hears the same from the bridge and calls the same functions with the same arguments,
## so the two can only differ in where a fact came from.
func _hear_the_world() -> void:
	game.world_rebuilt.connect(func() -> void: _on_map(game.map.id()))
	game.phase_changed.connect(_on_phase)
	game.round_began.connect(func(n: int, _map: StringName) -> void: _on_round(n, true, 0))
	game.round_over.connect(func(n: int, winner: int, why: String) -> void: _on_round(n, false, winner, why))
	game.player_died.connect(func(id: StringName, by: StringName, why: StringName) -> void:
		_on_death(_session(id), _session(by) if by != &"" else 0, why))
	game.role_drawn.connect(func(id: StringName, side: int, gun: bool) -> void:
		if id == &"local":
			_on_role(side, gun, game.weapon_id()))
	game.shot.connect(func(by: StringName, from: Vector3, to: Vector3, hit: StringName) -> void:
		_on_shot(_session(by), from, to, hit != &""))
	game.bot_said.connect(func(id: StringName, text: String) -> void:
		var who: MmPlayer = game.players.get(id)
		if chat != null and who != null:
			chat.say_locally("%s: %s" % [who.display_name, text], Color(0.93, 0.94, 0.96)))
	game.refused.connect(func(id: StringName, why: String) -> void:
		if id == &"local" and chat != null:
			chat.notice(why)
			if audio != null:
				var _denied := audio.deny())


func _start_offline() -> void:
	for i in range(offline_bots):
		var bot := game.add_player(StringName("u%d" % (MmNetBridge.FIRST_BOT_SESSION + i)), _bot_name(i))
		bot.is_bot = true

	_adopt(game.add_player(&"local", "You", 0, true))
	_hear_the_world()

	game.achievement_earned.connect(func(id: StringName, title: String, points: int) -> void:
		if player != null and id == player.player_id and chat != null:
			chat.say_locally("Achievement: %s (+%d)" % [title, points], Color(0.98, 0.84, 0.40))
	)
	game.start()
	DotLog.result(CHANNEL, "chat, offline", chat.attach(null))


## A solo stand-in's name: the server's list, through dot-bot's pick, so solo and a server
## name them alike.
static func _bot_name(index: int) -> String:
	var taken: Array = []
	for i in range(index):
		taken.append(DotBotNames.pick(taken, i, MmGame.BOT_NAMES))
	return DotBotNames.pick(taken, index, MmGame.BOT_NAMES)


func _say_ready() -> void:
	if workbench_remote != null:
		workbench_remote.ask()
	if bridge != null:
		bridge.ask_ready()


func _on_hello(session_id: int) -> void:
	_watch_id = session_id
	_adopt(game.players.get(MmNetBridge.player_key(session_id)))


func _on_roster_changed(session_id: int) -> void:
	if session_id == _watch_id and player == null:
		_adopt(game.players.get(MmNetBridge.player_key(session_id)))


func _build_netcode() -> DotResult:
	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = false
	net.local_peer_id = multiplayer.get_unique_id() if multiplayer != null else 2
	net.auto_tick = false
	net.config_file = ""

	var net_config := DotNetConfig.new()
	net_config.tick_rate = game.tick_rate
	net_config.snapshot_rate = MmGame.NET_SNAPSHOT_RATE
	net_config.enable_prediction = true
	net_config.enable_lag_compensation = false
	net_config.max_entities_per_snapshot = 64
	net_config.world_extent = MmGame.NET_WORLD_EXTENT
	net.config = net_config
	add_child(net)

	var started := net.setup()

	if not started.ok:
		return started

	bridge = MmNetBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	var attached := bridge.attach(game, net)

	if not attached.ok:
		return attached

	bridge.open_link(link)
	# The server's mp_forceview and mp_solidplayers: this end places its own camera and
	# predicts its own player.
	var _view := game.view_rules.follow_cvars(link)
	var _solid := game.body_rules.follow_cvars(link)
	var _ambient := game.ambient_rules.follow_cvars(link)
	# The server's sv_ragdoll* set: this end draws the bodies.
	var _dead := game.ragdoll_rules.follow_cvars(link)
	# And sv_toys*: a client hides the toys a server took away.
	var _toys := game.toy_rules.follow_cvars(link)
	# And mp_forcecamera / mp_freeroam*: this end flies the spectator's free camera.
	var _spectate := game.spectate_rules.follow_cvars(link)
	# Before the seal and in the server's order (after the bridge), or the actions stay local.
	DotLog.result(CHANNEL, "avatar action message", DotGameAvatarActionMessage.register(net))
	# The server's order again (after the avatar frame): the remote workbench's frame.
	workbench_remote = DotGameWorkbenchRemoteClient.attach(net)
	net.messages.seal()

	bridge.hello_received.connect(_on_hello)
	bridge.roster_changed.connect(_on_roster_changed)
	bridge.phase_received.connect(_on_phase)
	bridge.round_changed.connect(_on_round)
	bridge.death_received.connect(_on_death)
	bridge.map_received.connect(_on_map)
	bridge.role_received.connect(_on_role)
	bridge.shot_received.connect(_on_shot)
	bridge.notice_received.connect(func(text: String) -> void:
		if chat != null:
			chat.notice(text)
		if audio != null:
			var _denied := audio.deny())
	if link != null and link.has_method("ping_ms"):
		bridge.rtt_source = func() -> float:
			return float(maxi(0, int(link.call("ping_ms"))))

	DotLog.result(CHANNEL, "chat and voice", chat.attach(bridge))

	if link != null and link.has_method("is_playing") and bool(link.call("is_playing")):
		_say_ready()
	elif link != null and link.has_signal("spawned"):
		link.connect("spawned", _say_ready, CONNECT_ONE_SHOT)

	return net.start()
