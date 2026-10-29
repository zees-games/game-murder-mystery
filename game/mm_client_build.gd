extends "mm_client_netcode.gd"

## Building the blood, ragdolls, HUD, chat, audio and the console binding. Path-based base of [code]mm_client.gd[/code], no class_name.


func _build_blood() -> void:
	blood = MmBlood.new()
	if game.physics != null:
		blood.mask = game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop")
	game.add_child(blood)
	blood.apply_settings(null)


func _ragdoll_sound(id: StringName, at: Vector3, volume: float) -> void:
	if audio != null:
		var _played := audio.on_body(id, at, volume)


func _build_ragdolls() -> void:
	ragdolls = DotPlayerRagdolls.new()
	ragdolls.name = "Ragdolls"
	ragdolls.rules = game.ragdoll_rules
	ragdolls.sound_fn = _ragdoll_sound
	add_child(ragdolls)


func _build_hud() -> void:
	hud = MmHud.new()
	hud.name = "Hud"
	hud.key_fn = _key
	add_child(hud)


## dot-game's chat box and microphone, with this game's channels and voice format.
func _build_chat() -> void:
	chat = DotGameChatClient.new()
	chat.name = "Chat"
	chat.channels = [
		{"id": MmServices.CH_ALL, "label": "All", "colour": Color(0.93, 0.94, 0.96)},
		{"id": MmServices.CH_NEAR, "label": "Near", "colour": Color(0.82, 0.86, 0.72)},
	]
	chat.max_length = MmServices.chat_rules().max_length
	# No team key: this game has no team channel, because a team is a secret (mm_services.gd).
	chat.window_settings = {"team_action": &""}
	chat.voice_config = MmServices.voice_format()
	add_child(chat)


func _build_audio() -> void:
	audio = MmAudio.new()
	audio.name = "Sound"
	add_child(audio)

	var ready_now := audio.setup()

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "no sound", {"why": ready_now.error.message})
		remove_child(audio)
		audio.queue_free()
		audio = null


## Solo, `bot_difficulty` and every `bot_*` setting at the console, the names a server has, and
## `-- --bot_difficulty hard` at launch. Connected, the server's console holds them and a local
## copy would shadow it.
func _bind_bot_console() -> void:
	if console != null:
		var local: Array = console.sources()
		if not local.is_empty() and local[0] is DotConsoleLocal:
			var _icons := MmWeaponIcons.shared.bind_console(local[0])
	if not _offline or console == null or game == null:
		return
	var sources: Array = console.sources()
	if sources.is_empty() or not (sources[0] is DotConsoleLocal):
		return
	var _bound := DotBotSettings.of(game).bind_console(sources[0])
	var args := OS.get_cmdline_user_args()
	var index := args.find("--bot_difficulty")
	if index >= 0 and index + 1 < args.size():
		DotLog.result(CHANNEL, "bot difficulty from the command line", DotBotSettings.of(game).set_difficulty(args[index + 1]))


## The figure an avatar action plays on (the drawn person): that peer's player, or the local one offline.
func _avatar_figure(peer_id: int) -> Object:
	var who: MmPlayer = null
	if bridge != null and peer_id != 0:
		who = _player_of(bridge.player_for_peer(peer_id))
	if who == null and player != null and (net == null or peer_id == net.local_peer_id):
		who = player
	return who.figure.body_node() if who != null and who.figure != null else null
