extends "dedicated_base.gd"


## maps.yml on the live module: a map outside the active rotation stays installed and is never
## drawn or balloted; a rotation switch takes effect; a renamed command exists; no file changes
## nothing.
func _test_map_rotation_file() -> void:
	_section("maps.yml")
	var module := _module()
	var vote: Node = module.get("vote") if module != null else null
	_check(vote != null and vote.get("director") != null, "the game has a vote")
	if vote == null or vote.get("director") == null:
		_finished()
		return

	game.config.map_ids = PackedStringArray()
	var kept_file: DotMapRotationFile = game.rotation_file
	_check(server.console.find_cvar("sv_map_rotation_file") != null, "sv_map_rotation_file is a cvar")

	var built := DotMapRotationFile.from_trees([{"defaults": {
		"rotation": "main",
		"rotations": {
			"main": {"mode": "cycle", "cooldown": 0, "maps": ["mm_mansion"]},
			"alt": {"maps": ["mm_motel"]},
		},
		"commands": {"names": {"rtv": "rockthevote", "mm_maps": "maplist"}},
	}}], "game-murder-mystery")
	_check(built.ok, "a maps.yml with two rotations and renamed commands parses",
		"" if built.ok else built.error.message)
	if not built.ok:
		_finished()
		return

	game.rotation_file = built.value
	game.apply_rotation()
	vote.call("refresh_maps")

	_check(game.in_rotation(&"mm_mansion") and not game.in_rotation(&"mm_motel"),
		"the active rotation puts mm_motel out and mm_mansion in")
	_check(game.catalogue.maps.has(&"mm_motel"), "and mm_motel stays installed")

	var drew_motel := false
	for i in 60:
		var doc := game.catalogue.next_map(game.config.map_ids, true, game.random.stream(&"map"),
			&"", game.rotation_pool())
		drew_motel = drew_motel or str(doc.get("id", "")) == "mm_motel"
	_check(not drew_motel and game.rotation_pool() == [&"mm_mansion"],
		"60 draws of the next map never choose a map outside the rotation", str(game.rotation_pool()))

	var ids: Array = []
	for choice: DotVoteChoice in (vote.get("source") as DotVoteListSource).entries:
		ids.append(String(choice.id))
	_check(not ids.has("mm_motel") and ids.has("mm_mansion"),
		"a map outside the rotation is not on the ballot, one inside is", str(ids))

	var listed := _run_command("mm_maps")
	_check(_said(listed, "(not in rotation)"),
		"the map list marks maps that are not in rotation", str(listed))
	var rows := game.map_rows().filter(func(r: Dictionary) -> bool: return r["id"] == "mm_motel")
	_check(rows.size() == 1 and str(rows[0]["detail"]).contains("not in rotation"),
		"and so does the map menu, which still lists it")
	_check(game.catalogue.playable(game.config.map_ids).has(&"mm_motel"),
		"an out-of-rotation map can still be played by name")

	var switched := game.rotation_file.switch(game.map_rotation, "alt")
	game.apply_rotation()
	_check(switched.ok and game.in_rotation(&"mm_motel") and not game.in_rotation(&"mm_mansion"),
		"switching to the alt rotation takes effect")
	_check(not game.rotation_file.switch(game.map_rotation, "nope").ok, "an unknown rotation is refused")

	_rotation_commands_and_fallbacks(module, vote, kept_file)
	_finished()


func _rotation_commands_and_fallbacks(module: DotModule, vote: Node, kept_file: DotMapRotationFile) -> void:
	var rtv := DotVoteCommands.new()
	rtv.director = vote.get("director")
	rtv.spec_fn = game.rotation_commands
	var bound := rtv.bind(server.console)
	_check(bound.ok and rtv.command_name("rtv") == "rockthevote"
		and server.console.find_command("rockthevote") != null,
		"a renamed rtv command is registered from maps.yml's commands")
	_check(DotCommandNames.all_of("", module.call("_renames", game), {}, "mm_maps")[0] == "maplist",
		"mm_maps answers to the name the file gives it")

	# No file again: everything back in, as before maps.yml.
	game.rotation_file = null
	game.apply_rotation()
	vote.call("refresh_maps")
	_check(game.in_rotation(&"mm_motel") and game.in_rotation(&"mm_mansion") and game.rotation_pool().is_empty(),
		"with no file every map is in rotation again and no pool narrows the draw")
	_check(game.rotation_commands().is_empty(), "and no command is renamed")

	# A file that names nothing installed must not strand the server.
	var empty := DotMapRotationFile.from_trees([{"defaults": {"rotations": {"main": {"maps": ["nothing_here"]}}}}],
		"game-murder-mystery")
	game.rotation_file = empty.value
	game.apply_rotation()
	_check(game.in_rotation(&"mm_motel") and game.in_rotation(&"mm_mansion"),
		"a rotation that matches nothing plays every installed map")

	game.rotation_file = kept_file
	game.apply_rotation()
	vote.call("refresh_maps")


## "You was the murderer" (nightly #1489): a solo player is named "You".
func _test_round_sentence_grammar() -> void:
	_section("the round's sentence")
	_check(MmGame.murderer_verb(PackedStringArray(["Ada"])) == "was", "one named murderer was")
	_check(MmGame.murderer_verb(PackedStringArray(["You"])) == "were", "\"You\" were, not was")
	_check(MmGame.murderer_verb(PackedStringArray(["You", "Ada"])) == "were", "two were")
	_check(MmGame.round_sentence("the shot draws again", PackedStringArray(["You"])) == "the shot draws again; you were the murderer", "the solo player is \"you were\" mid-sentence")
	_check(MmGame.round_sentence("time", PackedStringArray(["Ada"])) == "time; Ada was the murderer", "a named murderer keeps the name")
	_finished()


func _test_the_module_loads() -> void:
	_section("the module")

	# The world is built after the server (whose tick rate it reads) and before the module
	# (which refuses to load without a world to run; it cannot build one).
	var config := MmConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.grace_seconds = 3.0
	config.round_seconds = 30.0
	config.minimum_players = 3
	config.map_ids = PackedStringArray(["mm_practice"])

	game = MmGame.new()
	game.name = "World"
	game.config = config
	game.config_binder = MmConfig.make_binder(config)
	game.tick_rate = Engine.physics_ticks_per_second
	add_child(game)
	await get_tree().process_frame

	_check(DotRegistry.get_node_service(MmGame.SERVICE) == game, "the world publishes itself where a module looks")
	_check(not game.map_doc.is_empty(), "and already has a map")

	(load("res://game/mm_module.gd") as GDScript).set("punishments_file", "%s/punishments.json" % SERVER_DIR)
	var loaded: DotResult = await server.modules.load_module("res://game/mm_module.gd")
	_check(loaded.ok, "the module loads into the server", loaded.error.message if not loaded.ok else "")

	var module := _module()
	_check(game != null and game.progress != null and game.progress.durable_key_fn.is_valid(),
		"progress is filed under dot-game's stable stats key")
	_check(module != null and module.get("net") != null and module.get("bridge") != null,
		"with its netcode and the game's bridge")

	var net: DotNetManager = module.get("net") if module != null else null
	_check(net != null and net.config.tick_rate == TICK_RATE, "the netcode runs at the configured rate")
	var freeroam: Object = server.console.find_cvar("mp_freeroam")
	var forcecam: Object = server.console.find_cvar("mp_forcecamera")
	_check(freeroam != null and forcecam != null and server.console.find_cvar("mp_freeroam_speed") != null,
		"mp_freeroam, mp_forcecamera and mp_freeroam_speed are cvars")
	if freeroam != null:
		var _set: Variant = freeroam.set_value("0")
	_check(not game.spectate_rules.allow_roaming, "and mp_freeroam is the game's own rules, not a copy")
	if freeroam != null:
		var _back: Variant = freeroam.set_value("1")
	var alias: Object = server.console.find_cvar("mm_spectate_camera")
	if alias != null:
		var _aliased: Variant = alias.set_value("2")
	_check(forcecam != null and forcecam.get_int() == 2 and game.spectate_rules.force_camera == 2,
		"and mm_spectate_camera writes through mp_forcecamera")
	if alias != null:
		var _reset: Variant = alias.set_value("0")
	_check(net != null and absf(net.config.world_extent - MmGame.NET_WORLD_EXTENT) < 0.01,
		"against the world extent both ends decode with")
	_noblock_and_config(module)
	_finished()


## Config cvars, the workbench's sync into a hand-written cvar, and dot-team's block rules through dot-game's DotGameNoblock.
func _noblock_and_config(module: DotModule) -> void:
	var teamblock := server.console.find_cvar("mp_teamblock")
	var enemyblock := server.console.find_cvar("mp_enemyblock")
	_check(teamblock != null and teamblock.get_string() == "0" and enemyblock != null and enemyblock.get_string() == "1",
		"mp_teamblock is 0 and mp_enemyblock is 1 by default")
	_check(server.console.has_name("mm_hit_radius") and server.console.has_name("mm_bot_witness_range") and server.console.has_name("mm_death_cam_seconds"),
		"config fields with no hand-written cvar are mm_ cvars")
	_check(module.get("workbench") != null, "the module hosts the workbench")
	game.config.gun_cooldown = 4.5
	module.call("_on_config_field", "gun_cooldown", 4.5, "workbench")
	_check(server.console.find_cvar("mm_gun_cooldown").get_string().to_float() == 4.5, "a workbench edit reaches the hand-written cvar",
		server.console.find_cvar("mm_gun_cooldown").get_string())
	var _a := game.add_player(&"u91", "Walker")
	var _b := game.add_player(&"u92", "Other")
	game.body_rules.solid = true
	_check(not game.body_rules.blocks(&"u91", &"u92"), "everybody is one side, so with mp_teamblock 0 players pass")
	teamblock.set_value("1")
	_check(game.body_rules.blocks(&"u91", &"u92"), "mp_teamblock 1 makes them block")
	teamblock.set_value("0")
	game.body_rules.solid = false
	game.remove_player(&"u91")
	game.remove_player(&"u92")


func _test_the_commands() -> void:
	_section("the console")
	_check(_said(_run_command("mm_status"), "murder"), "mm_status says what the round is doing")
	_check(_said(_run_command("mm_maps"), "mm_practice"), "mm_maps lists the maps")
	_check(_said(_run_command("mm_grace_seconds"), "3"), "mm_grace_seconds reports the grace")
	_check(_said(_run_command("mm_net"), "bridge"), "mm_net says what the netcode is doing")

	# A cvar's default is the value the world was built with, and setting one writes through.
	_check(_said(_run_command("mm_round_seconds"), "30"), "mm_round_seconds reports the world's own value")
	var _set := _run_command("mm_round_seconds 45")
	_check(is_equal_approx(game.config.round_seconds, 45.0), "and setting it writes through to the world",
		"%.1f" % game.config.round_seconds)
	var _back := _run_command("mm_max_murderers 0")
	_check(game.config.max_murderers == 1, "a round with no murderer is not one: it is taken as one",
		"%d" % game.config.max_murderers)
	_finished()


## A whole round, played by the stand-ins the module seats on its own.
func _test_a_round_runs() -> void:
	_section("a round, played by the stand-ins")
	var rounds: Array = []
	var drawn: Array = []
	game.round_over.connect(_note_round_over.bind(rounds))
	game.round_began.connect(_note_round_began.bind(drawn))

	# Bounded in the server's ticks: a wall-clock bound turns a busy machine into a failure.
	# The wall clock only caps a server that stopped ticking at all.
	var started := Time.get_ticks_msec()
	var sim_limit := game.current_tick() + int((game.config.grace_seconds + game.config.round_seconds + 20.0) * game.tick_rate)
	var hard := started + 300000

	while rounds.is_empty() and game.current_tick() < sim_limit and Time.get_ticks_msec() < hard:
		await get_tree().physics_frame

	var bots := 0

	for id: StringName in game.players:
		if (game.players[id] as MmPlayer).is_bot:
			bots += 1

	_check(bots == game.config.minimum_players, "the module seated stand-ins up to the minimum", "%d" % bots)
	_check(not drawn.is_empty() and drawn[0] == 1, "and drew one of them to be the murderer", str(drawn))
	print("(the round took %.1f s of real time)" % ((Time.get_ticks_msec() - started) / 1000.0))
	_check(not rounds.is_empty(), "and a round was decided", str(rounds))
	_check(not rounds.is_empty() and str(rounds[0][2]) != "", "with a sentence saying why", str(rounds))
	_stand_ins_fill_for_people()

	_check(_said(_run_command("mm_status"), "round"), "and mm_status still answers")
	# Between rounds nobody has a side (the draw is per round), so the next round must be on: the
	# stand-ins' round just decided leaves the world idle for its intermission, and asking then
	# lists nobody as the murderer, which is right.
	var next_by := game.current_tick() + int((game.config.warmup_seconds + game.config.intermission_seconds + 20.0) * game.tick_rate)

	while game.phase == MmGame.Phase.IDLE and game.current_tick() < next_by:
		await get_tree().physics_frame

	_check(_said(_run_command("mm_roles"), "murderer"), "and mm_roles, on the server's own console, says who the murderer is",
		"phase %s: %s" % [game.phase, "; ".join(_run_command("mm_roles"))])
	_finished()


func _note_round_over(n: int, winner: int, why: String, rounds: Array) -> void:
	rounds.append([n, winner, why])


func _note_round_began(_n: int, _map: StringName, drawn: Array) -> void:
	drawn.append(game.players_on(MmGame.MURDERERS).size())


## A person takes a stand-in's place and leaving gives it back (DotBotQuota's fill mode), driven by the roster check, not its interval.
func _stand_ins_fill_for_people() -> void:
	var quota_module := _module()
	var quota_bridge: Object = quota_module.get("bridge") if quota_module != null else null
	_check(server.console.find_cvar("bot_quota") != null and server.console.find_cvar("bot_quota_mode") != null,
		"the shared bot_quota cvars are registered")
	# How the stand-ins see, hear and know a map is dot-bot's: the family's names, medium by default.
	var bot_settings := DotBotSettings.of(game)
	_check(server.console.get_string("bot_difficulty", "") == "medium" and bot_settings.difficulty() == "medium",
		"bot_difficulty is the module's and medium is the default")
	var _hard := _run_command("bot_difficulty hard")
	_check(bot_settings.difficulty() == "hard" and is_equal_approx(server.console.get_float("bot_sight"), DotBotProfile.preset_value("hard", "sight")),
		"bot_difficulty hard writes every bot_* setting", server.console.get_string("bot_sight"))
	var _medium := _run_command("bot_difficulty medium")
	var _alias := _run_command("mm_min_players 3")
	_check(server.console.find_cvar("bot_quota") != null and server.console.find_cvar("bot_quota").get_int() == 3,
		"and the old mm_min_players sets bot_quota",
		server.console.find_cvar("bot_quota").get_string() if server.console.find_cvar("bot_quota") != null else "missing")

	if quota_module != null and quota_bridge != null:
		quota_module.call("_keep_the_round_full")
		var bots_before: int = (quota_module.get("_bot_ids") as Array).size()
		var joined: DotResult = quota_bridge.call("add_player", 0, 9001, "Person")
		quota_module.call("_keep_the_round_full")
		var bots_with: int = (quota_module.get("_bot_ids") as Array).size()
		_check(joined.ok and bots_before == 3 and bots_with == bots_before - 1,
			"a person joining takes a stand-in's place", "%d -> %d" % [bots_before, bots_with])
		quota_bridge.call("remove_player", 9001)
		quota_module.call("_keep_the_round_full")
		var bots_after: int = (quota_module.get("_bot_ids") as Array).size()
		_check(bots_after == bots_before, "and a stand-in comes back when they leave",
			"%d -> %d" % [bots_with, bots_after])
	else:
		_check(false, "a person joining takes a stand-in's place", "no module")
		_check(false, "and a stand-in comes back when they leave", "no module")

	var _restored := _run_command("mm_min_players 3")


## The murderer's avatar action is refused through the relay the module bound (dot-game's
## relay path), but only while a round is in PLAY; bystanders and every other phase may act.
func _test_the_murderer_plays_no_action() -> void:
	_section("the murderer plays no avatar action in a round")
	var module := _module()
	var net: DotNetManager = module.get("net") if module != null else null
	var bridge: Object = module.get("bridge") if module != null else null
	var relay := net.get_meta(DotGameAvatarActionRelay.NET_META, null) as DotGameAvatarActionRelay if net != null else null
	_check(relay != null and relay.veto_fn.is_valid(), "the module bound its veto to the relay")

	if relay == null or bridge == null:
		for _i in 5:
			_check(false, "no relay or bridge")
		_finished()
		return

	var murderer_peer := 9101
	var bystander_peer := 9102
	var _m: DotResult = bridge.call("add_player", murderer_peer, 9201, "Killer")
	var _b: DotResult = bridge.call("add_player", bystander_peer, 9202, "Bystander")
	var killer := game.players.get(MmNetBridge.player_key(bridge.call("player_for_peer", murderer_peer))) as MmPlayer
	var innocent := game.players.get(MmNetBridge.player_key(bridge.call("player_for_peer", bystander_peer))) as MmPlayer
	_check(killer != null and innocent != null, "both seats exist")

	if killer == null or innocent == null:
		for _i in 4:
			_check(false, "no seat")
		_finished()
		return

	var saved_phase := game.phase
	var saved_team := killer.team
	killer.team = MmGame.MURDERERS
	innocent.team = MmGame.BYSTANDERS

	game.phase = MmGame.Phase.PLAY
	relay.forget(murderer_peer)
	relay.forget(bystander_peer)
	_check(not relay.allow(murderer_peer, "dance"), "in PLAY the murderer's dance is refused")
	_check(relay.allow(bystander_peer, "dance"), "in PLAY a bystander's is allowed")

	game.phase = MmGame.Phase.IDLE
	relay.forget(murderer_peer)
	_check(relay.allow(murderer_peer, "dance"), "between rounds the murderer may")

	game.phase = MmGame.Phase.PLAY
	killer.team = MmGame.BYSTANDERS
	relay.forget(murderer_peer)
	_check(relay.allow(murderer_peer, "dance"), "and in PLAY, a seat that is not the murderer may")

	game.phase = saved_phase
	killer.team = saved_team
	bridge.call("remove_player", 9201)
	bridge.call("remove_player", 9202)
	_finished()


## [b]A module reload leaves one link, and a real client still hears the server.[/b] The link
## sits under the server node by name; a bare add_child left one more per reload, the live one
## renamed `@Node@n`, and every RPC to a real client was dropped without an error.
func _test_a_module_reload_keeps_one_link() -> void:
	_section("a module reload leaves one live link")
	for _i in range(2):
		var gone := server.modules.unload_module("murder")
		_check(gone.ok, "the module unloads", gone.error.message if not gone.ok else "")
		var back: DotResult = await server.modules.load_module("res://game/mm_module.gd")
		_check(back.ok, "and loads again", back.error.message if not back.ok else "")
	for _i in range(5):
		await get_tree().process_frame

	var links := 0
	for child in server.get_children():
		if child.get_script() == MmNetLink:
			links += 1
	_check(links == 1 and server.has_node(NodePath(String(MmNetLink.NODE_NAME))),
		"exactly one link, under the name a client routes to", "%d" % links)

	var side := Node.new()
	side.name = "ReloadClient"
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
	var mirror := Node.new()
	mirror.name = name
	side.add_child(mirror)
	var client := DotClientLink.new()
	client.name = "Server"
	client.player_name = "Reload"
	client.transport_preference = "udp"
	client.udp_address = "127.0.0.1:%d" % PORT
	mirror.add_child(client)
	client.connect_to_server("127.0.0.1:%d" % PORT)

	var known: Dictionary = {}
	var receiver: MmNetLink = _seat_receiver_on_join(client, side)
	var seated := false
	for _i in 1800:
		await get_tree().physics_frame
		if receiver.is_inside_tree():
			seated = true
			# The server tells a peer nothing until it says READY (its world exists, which
			# the bridge does when it is built); this stand-in has no bridge, so it says it.
			var writer := DotNetWriter.new()
			var _asked: DotResult = _module().get("bridge").net.messages.encode(
				load("res://game/net/mm_request.gd").new(MmEvents.Ask.READY, PackedByteArray([0])), writer)
			receiver.send_request(writer.to_bytes())
			break
	if not seated:
		receiver = null
	known.clear()

	var heard := false
	for _i in 600:
		await get_tree().physics_frame
		if receiver != null and receiver.events_received + receiver.snapshots_received > 0:
			heard = true
			break
	_check(heard, "a real client receives the reloaded server's RPCs",
		"events=%d snapshots=%d" % [receiver.events_received, receiver.snapshots_received] if receiver != null else "never seated")

	client.disconnect_from_server("done")
	for _i in 120:
		await get_tree().physics_frame
	side.queue_free()
	_finished()


func _test_exits_clean(probe: Array) -> void:
	_section("exiting clean, as a second process saw it")

	var code: int = probe[0]
	var stdout: String = probe[1]
	var stderr: String = probe[2]
	var hung: bool = probe[3]
	var seconds: int = probe[4]
	# Leak lines are the engine's, written to stderr; both streams are searched and shown apart,
	# as their interleaving is lost and a hung copy's whereabouts is the end of its stdout.
	var text := stdout + "\n" + stderr
	var tail := "its last lines:\n%s\nand the last on stderr:\n%s" % [
		_last_lines(stdout, 15), _last_lines(stderr, 10)
	]

	# A copy that was killed never reached its exit, so neither of the last two was seen, and
	# passing them on an absence of lines would be passing them blind.
	var passes_detail := ""
	if hung:
		passes_detail = ("still running after %d s, so it was killed — a scene that failed to "
			+ "parse, or a thread still blocked when it quit; %s") % [seconds, tail]
	elif code != 0:
		passes_detail = "exit %d; %s" % [code, tail]
	_check(not hung and code == 0, "this suite, run again in a fresh process, passes",
		passes_detail)
	_check(not hung and not text.contains("leaked at exit"), "and leaves no object alive at exit",
		"it was killed before it reached its exit" if hung else _line_with(text, "leaked at exit"))
	_check(not hung and not text.contains("still in use at exit"), "and no resource",
		"it was killed before it reached its exit" if hung else _line_with(text, "still in use at exit"))
	_finished()
