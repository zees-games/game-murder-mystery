extends "mm_client_board.gd"

## Settings, the workbench and the input block. Path-based base of [code]mm_client.gd[/code], no class_name.


## dot-team's block rules followed from the server, and the F9 tuning panel where this process hosts the game.
func _add_noblock_and_workbench() -> void:
	if link != null:
		DotLog.result(CHANNEL, "noblock", platform.add_noblock(game, Callable(game, "team_of_side")))
		return
	var wb := DotGameWorkbench.new()
	wb.name = "Workbench"
	wb.listen_host_fn = func() -> bool: return true
	workbench = wb
	wb.config = {"enabled": false}
	if game.config_binder != null:
		for set: DotProfileSet in game.config_binder.profile_sets():
			wb.add_set(set, "Game settings: %s" % set.rel_path.trim_prefix("config_"))
	add_child(wb)
	var started := wb.start()
	DotLog.result(CHANNEL, "the workbench", started)
	if started.ok and game.config_binder != null:
		game.config_binder.attach(wb.api.runtime)
	platform.add_workbench(wb)


func _suspend_input(suspended: bool) -> void:
	if _sampler != null:
		_sampler.suspended = suspended

	if player != null and player.sampler != null:
		player.sampler.suspended = suspended


## Where a roster row's player stands, for dot-game's look-to-gag key (G, K).
func _look_position(row: Dictionary) -> Variant:
	if game == null:
		return null
	for who: MmPlayer in game.players.values():
		if who != player and who.display_name == row["name"]:
			return who.global_position + Vector3.UP * 1.5
	return null


func _build_settings() -> void:
	settings = MmSettings.new()
	settings.name = "Settings"
	add_child(settings)
	platform.settings = settings
	# Not handed over: MmHud follows the menu's theme itself, below.
	platform.chat = chat
	platform.look_position_fn = _look_position
	platform.board_snapshot_fn = board_snapshot
	# M: the map list. Solo a choice changes the map here at once; connected the server decides,
	# by the owner's `sv_map_menu_flag`, and anybody without it gets a vote instead (dot-vote's
	# map menu, wired in [MmModule]).
	platform.maps_rows_fn = func() -> Array: return game.map_rows() if game != null else []
	platform.maps_change_fn = func(id: StringName) -> DotResult: return game.change_map_now(id)
	DotLog.result(CHANNEL, "the platform", platform.setup())
	# The starter set: the equipped list needs a credential the client does not hold (the server reads it).
	DotLog.result(CHANNEL, "avatar actions", platform.add_avatar_actions(net, _avatar_figure))
	# Walking is off while the cover is up, a menu is open or a line is typed: the sampler polls
	# the keyboard.
	platform.input_blocked_changed.connect(_suspend_input)
	_suspend_input(platform.is_input_blocked())

	settings = platform.settings as MmSettings
	console = platform.console as DotConsoleController
	_add_noblock_and_workbench()

	if settings == null:
		return

	if _sampler != null:
		settings.bind_look(_sampler.tunables)

	if audio != null:
		settings.bind_audio(audio.manager)
		# The server's mm_ambient* drive the quiet layer; the player's sliders multiply on top.
		if audio.ambient != null:
			audio.ambient.follow_settings(settings.settings, game.ambient_rules)

	if blood != null:
		blood.follow(settings.settings)

	if settings.menu != null:
		# The HUD in the menu's theme and at the player's HUD size, live.
		if hud != null:
			hud.follow_menu(settings.menu)
		_bind_bot_console()
		board = platform.board as DotMenuScoreboard
		_dress_board()


## Online: no local trust and no panel until the server names this player an admin (sv_workbench_remote). The sets are the game's own; the rows are the server's, through the bridge's profile link.
func _start_remote_workbench() -> void:
	if workbench_remote == null:
		return
	var wb := DotGameWorkbench.new()
	wb.name = "Workbench"
	wb.remote_client = workbench_remote
	wb.remote_fn = func() -> bool: return true
	if game.config_binder != null:
		for set: DotProfileSet in game.config_binder.profile_sets():
			wb.add_set(set, "Game settings: %s" % set.rel_path.trim_prefix("config_"))
	add_child(wb)
	var started := wb.start(game.ensure_runtime())
	DotLog.result(CHANNEL, "the remote workbench", started)
	if not started.ok:
		wb.queue_free()
		return
	workbench = wb
	platform.add_workbench(wb)
