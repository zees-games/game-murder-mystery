extends "mm_client_platform.gd"

## Start-up and the per-physics-frame input. Path-based base of [code]mm_client.gd[/code], no class_name.


func _ready() -> void:
	# First, before anything can be drawn: the platform puts the loading cover up, held until the
	# player exists and the camera is current, finds the link and reports the cover to the server.
	platform = DotGameClient.new()
	platform.name = "Platform"
	platform.force_offline = force_offline
	platform.spawned_fn = func() -> bool: return player != null and camera != null and camera.is_inside_tree()
	platform.scoreboard_action = MmBindings.SCOREBOARD
	add_child(platform)
	gate = platform.gate

	var config := MmConfig.new()
	var binder := MmConfig.make_binder(config, config_file)
	var loaded := binder.load_layers()

	if not loaded.ok:
		DotLog.warn(CHANNEL, "falling back to defaults", {"why": loaded.error.message})

	link = platform.link as Node
	_offline = platform.offline

	game = MmGame.new()
	game.name = "World"
	game.config = config
	game.config_binder = binder
	game.authoritative = _offline
	game.register_service = _offline
	game.tick_rate = int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 64))
	game.draw_world = true
	# Before the world is added: a server-less world lays its first map out in its own _ready.
	_hold_for_maps()
	add_child(game)
	_build_ragdolls()
	_build_blood()

	_sampler = DotFpsSampler.new(MmPlayer.tunables_for(config))
	MmPlayer.register_actions(_sampler)

	_build_hud()
	_build_chat()
	_build_audio()
	_build_settings()

	if _offline:
		_start_offline()
	else:
		var netted := _build_netcode()
		DotLog.result(CHANNEL, "the netcode", netted)
		if netted.ok and link != null:
			_start_remote_workbench()


## The load gate is [member DotGameClient.gate]: covered, and the local body and the input still,
## until the level is built and the local player and its camera exist. A frozen player is also
## skipped by [method MmPlayer.simulate], which `process_mode` does not stop.


## True while the load gate covers the screen: no input, no prediction sampling.
func _covered() -> bool:
	return gate != null and not gate.is_open()


## Swaps the view, where the server's `mp_forceview` allows.
func toggle_view() -> void:
	var wanted := game.view_rules.toggled(third_person)
	if wanted == third_person:
		if hud != null and game.view_rules.refusal() != "":
			hud.shout(game.view_rules.refusal(), 1.6)
		return
	third_person = wanted
	_place_camera()

	if audio != null:
		var _heard := audio.click()


## Whether the pointer is the game's: captured. A menu frees it and the platform takes it back.
func _pointer_ours() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


## Whether [param action] is held now, by a player whose pointer is the game's.
func _held(action: StringName) -> bool:
	return _pointer_ours() and not _covered() and InputMap.has_action(action) and Input.is_action_pressed(action)


## Whether the keyboard action [param action] is held now. Unlike [method _held] it does not need
## the pointer captured: a browser captures it only on a click. The menu, the chat and the
## cover still block it through the platform.
func _key_held(action: StringName) -> bool:
	if _covered() or not InputMap.has_action(action) or not Input.is_action_pressed(action):
		return false

	return platform == null or not platform.is_input_blocked()


func is_roaming() -> bool:
	return game != null and game.spectate != null and player != null \
		and game.spectate.is_roaming(player.player_id)


func _physics_process(delta: float) -> void:
	# The use key, held: the game makes the press from the edge, on the server or here.
	var use := _key_held(MmBindings.USE)
	var attack := _held(MmBindings.ATTACK) and not is_spectating()
	var holster := _key_held(MmBindings.HOLSTER)

	if _offline:
		if player != null:
			player.wants_use = use
			player.wants_attack = attack
			player.wants_holster = holster
			player.input_off = is_roaming()
		return

	if net == null or not net.is_running() or bridge == null:
		return

	var ticks := net.clock.advance(delta)

	# The clock has advanced; only the sampling waits, so the mouse does not pile up a turn
	# behind the cover and the server sees an idle body until it lifts.
	if _covered():
		return

	var move := _sampler.sample(delta) if _sampler != null else DotFpsCommand.new()
	move.set_button(MmPlayer.USE_BUTTON, use)
	move.set_button(MmPlayer.ATTACK_BUTTON, attack)
	move.set_button(MmPlayer.HOLSTER_BUTTON, holster)

	if is_roaming():
		# The roaming spectator flies a camera and does not walk the dead body about.
		move.move = Vector2.ZERO
		move.buttons = 0

	for i in range(ticks):
		if not net.clock.is_synced():
			continue

		bridge.client_tick(net.clock.input_tick() - (ticks - 1 - i), move)
