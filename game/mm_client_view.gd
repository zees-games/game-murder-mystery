extends "mm_client_state.gd"

## Camera placement, the view toggle and the lookups other parts share. Path-based base of [code]mm_client.gd[/code], no class_name.


## A map is built: held from the moment the old one starts to go, released once the new one
## stands. [signal MmGame.world_clearing] and [signal MmGame.world_rebuilt] fire for the first
## map, a map change, and a map a server sent.
func _hold_for_maps() -> void:
	game.world_clearing.connect(func() -> void: gate.hold(&"map", "Loading the map"))
	game.world_rebuilt.connect(func() -> void: gate.release(&"map"))


## Hangs the camera where the view wants it: at the eyes, or on an arm behind a prop as far
## back as the prop is big.
func _place_camera() -> void:
	if camera == null or player == null:
		return

	if camera.get_parent() != null:
		camera.get_parent().remove_child(camera)

	if _arm != null and is_instance_valid(_arm):
		_arm.queue_free()
		_arm = null

	var eye := player.eye_position() - player.controller.state.position

	if not third_person:
		player.add_child(camera)
		_rig_height = eye.y
		camera.position = Vector3(0.0, eye.y, 0.0)
		camera.rotation = Vector3.ZERO
		if _fade != null:
			_fade.focus = null
		return

	# dot-core's boom, swept from the eye with the height above it added in the world's up:
	# a pivot above the head can be inside a tree's canopy (the play test, 0:33), and the
	# spring arm it replaced cast a ray from there and snapped to whatever it hit.
	_arm = DotCameraBoom.new()
	_arm.name = "Chase"
	_arm.spring_length = CHASE_BACK
	# Against the building and the furniture, never the player's own body.
	_arm.collision_mask = game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop") \
		if game.physics != null else 1
	_arm.add_excluded_object(player.get_rid())
	_arm.margin = 0.15
	_arm.lift = CHASE_UP
	_rig_height = eye.y
	player.add_child(_arm)
	_arm.add_child(camera)
	camera.position = Vector3.ZERO
	camera.rotation = Vector3.ZERO
	if _fade != null:
		_fade.focus = _arm


## Everybody but this player, for the camera fade.
func _other_players() -> Array:
	var out: Array = []
	if game == null:
		return out
	for id in game.players:
		var other: Node3D = game.players[id]
		if other != player and is_instance_valid(other):
			out.append(other)
	return out


func is_spectating() -> bool:
	return player != null and game != null and game.spectate != null \
		and game.spectate.is_spectating(player.player_id)


## The server changed `mp_forceview`: the view it allows now.
func _on_view_rules_changed() -> void:
	var allowed := game.view_rules.resolve(third_person)
	if allowed != third_person:
		third_person = allowed
		if not is_spectating():
			_place_camera()


func _build_camera() -> void:
	if camera != null or player == null:
		return

	camera = Camera3D.new()
	camera.name = "Eye"
	camera.fov = 90.0
	camera.current = true

	# Other players and stand-ins, handed over (their hulls are off while players pass
	# through each other): hidden at the lens, faded in third person between the camera and
	# you. It rides the camera wherever the camera goes.
	_fade = DotCameraFade.new()
	_fade.name = "Fade"
	_fade.bodies_fn = _other_players
	camera.add_child(_fade)

	if not game.view_rules.changed.is_connected(_on_view_rules_changed):
		game.view_rules.changed.connect(_on_view_rules_changed)
	third_person = game.view_rules.resolve(third_person)
	_place_camera()


func _adopt(candidate: MmPlayer) -> void:
	if candidate == null or player == candidate:
		return

	player = candidate
	if touch != null and _offline and player.sampler != null:
		# The one touch sampler, so the buttons' jump and the stick reach the simulated body.
		player.sampler = _sampler
	gate.freeze(player)
	_build_camera()

	if settings != null:
		settings.bind_camera(camera)
		if player.sampler != null:
			settings.bind_look(player.sampler.tunables)

	if hud != null:
		hud.bind(game, player)


## The local world's ids are `local` for this keyboard and `u<session>` for everybody else.
func _session(id: StringName) -> int:
	return _watch_id if id == &"local" else MmNetBridge.session_of(id)


## Whether this client's own player is a murderer this round. Only this client's own role is
## known here: everybody else is a bystander on the wire.
func is_murderer() -> bool:
	return player != null and game != null and game.team_of(player.player_id) == MmGame.MURDERERS


## The key an action is on, as the player has it bound.
func _key(action: StringName) -> String:
	if settings != null and settings.bindings != null:
		var text := settings.bindings.key_for(action)
		if text != "":
			return text

	var row := MmBindings.make().row_for_action(action)
	return str(row.get("default", action))


## The sound manager the flashlight clicks play through, or null before audio is up.
func _flash_audio_ref() -> DotNodeRef:
	if audio == null or audio.manager == null or not audio.manager.is_inside_tree():
		return null
	return DotNodeRef.of_path(audio.manager.get_path())


## The light on the eye follows the server's state (but not for 0.4 s after our own switch, which is shown at once); everybody else's beam, and ours when the camera is not our eye, comes from the crowd.
func _present_flashlights(delta: float) -> void:
	var cfg := game.flashlight_conf()
	var map_id := str(game.map_doc.get("id", ""))

	if flash == null or not is_instance_valid(flash):
		flash = DotFlashlight.new()
		flash.name = "Flashlight"
		flash.config = cfg
		flash.handle_input = false
		flash.authoritative = false
		flash.audio = _flash_audio_ref()
		flash.switch_requested.connect(_on_flash_switch)
		camera.add_child(flash)

	flash.allowed = DotFlashlightRules.allowed_on(cfg, map_id)

	if flash_crowd == null:
		flash_crowd = DotFlashlightCrowd.new()
		flash_crowd.name = "Flashlights"
		flash_crowd.config = cfg
		flash_crowd.audio = _flash_audio_ref()
		add_child(flash_crowd)

	var own_eye := not third_person and not is_spectating()
	var lit := player.flashlight and player.is_alive() and not player.watching

	if own_eye and Time.get_ticks_msec() - _flash_msec > 400:
		flash.apply_state({"on": lit})
	elif not own_eye:
		flash.apply_state({"on": false})

	flash_crowd.set_viewer(camera.global_position)

	for key: Variant in game.players:
		var other: MmPlayer = game.players[key]
		var shown := other.flashlight and other.is_alive() and not other.watching and (other != player or not own_eye)
		flash_crowd.set_lit(key, shown)
		if shown:
			flash_crowd.place(key, other.eye_position(), other.aim_direction())

	_flash_retain -= delta
	if _flash_retain <= 0.0:
		_flash_retain = 2.0
		flash_crowd.retain(game.players.keys())


## Our own switch: shown at once, asked of the server (or done here, offline).
func _on_flash_switch(_want: bool) -> void:
	_flash_msec = Time.get_ticks_msec()
	if bridge != null:
		bridge.ask_flashlight()
	elif game != null and player != null:
		var _switched := game.toggle_flashlight(player.player_id)
