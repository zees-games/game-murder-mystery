extends "mm_client_present.gd"

## Spectating, roaming and the free camera. Path-based base of [code]mm_client.gd[/code], no class_name.


func _watched_through_eyes() -> MmPlayer:
	if not is_spectating():
		return null

	var mode := game.spectate.mode_of(player.player_id)

	if mode != DotSpectatorView.Mode.FIRST_PERSON and mode != DotSpectatorView.Mode.FREEZE_CAM:
		return null

	return game.players.get(game.spectate.watching(player.player_id))


## One frame of the free camera: the mouse turn folded in, then the movement keys. Seeded
## from where the camera was on the first frame of a roam, so it starts where the spectator
## looked. The pose is kept in the manager too, so a later hand-over starts from it.
func _fly_free_camera() -> Transform3D:
	if _free_cam == null:
		_free_cam = DotSpectatorFreeCam.new()
		_free_cam.rules = game.spectate_rules
		_free_cam.seed_from(camera.global_transform)

	var sens := deg_to_rad(_sampler.tunables.mouse_sensitivity) if _sampler != null else 0.0025
	_free_cam.look(Vector2(-_roam_look.x, -_roam_look.y) * sens)
	_roam_look = Vector2.ZERO

	var move := Vector3.ZERO

	if _pointer_ours() and not _covered():
		move = Vector3(
			_strength(&"dot_fps_right") - _strength(&"dot_fps_left"),
			_strength(&"dot_fps_jump") - _strength(&"dot_fps_crouch"),
			_strength(&"dot_fps_forward") - _strength(&"dot_fps_back"),
		)

	var pose := _free_cam.step(
		move, _held(&"dot_fps_sprint"), _held(&"dot_fps_walk"), get_process_delta_time()
	)
	var _kept := game.spectate.manager.move_free(String(player.player_id), pose.origin, pose.basis)
	return pose


static func _strength(action: StringName) -> float:
	return Input.get_action_strength(action) if InputMap.has_action(action) else 0.0


func _drive_spectator_camera() -> bool:
	if not is_spectating():
		if camera.get_parent() == self:
			_place_camera()

		if hud != null:
			hud.set_watching("")

		return false

	if camera.get_parent() != self:
		camera.get_parent().remove_child(camera)
		add_child(camera)
		camera.current = true

		if _arm != null and is_instance_valid(_arm):
			_arm.queue_free()
			_arm = null

	# Chase and death cameras pulled out of the house by dot-spectate, given the level.
	var manager: DotSpectatorManager = game.spectate.manager
	if manager != null and manager.camera_world == null and game.physics != null:
		manager.camera_world = camera.get_world_3d()
		manager.camera_mask = game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop")

	var where := game.spectate.camera_for(player.player_id)

	if game.spectate.is_roaming(player.player_id):
		where = _fly_free_camera()
	else:
		_free_cam = null

	if where != Transform3D.IDENTITY:
		camera.global_transform = where

	if hud != null:
		game.spectate.roam_key = _key(MmBindings.ROAM)
		hud.set_watching(game.spectate.line_for(player.player_id))

	return true


func _process(delta: float) -> void:
	if blood != null:
		blood.advance(delta)
	var _shown := present_frame(net, game, player, not third_person, delta, -1.0, _watched_through_eyes())
	if audio != null and audio.ambient != null and camera != null and camera.is_inside_tree() and game.physics != null:
		audio.ambient.follow_roof(delta, camera.global_position, camera.get_world_3d().direct_space_state, game.physics.mask_of([&"world"]))
	_present_hide()
	_present_guns()

	if camera == null or player == null:
		return

	if _drive_spectator_camera():
		_present_effects(delta)
		return

	var state := player.controller.state
	var pitch := deg_to_rad(state.pitch)
	var yaw := deg_to_rad(state.yaw)
	var rig: Node3D = _arm if _arm != null and is_instance_valid(_arm) else camera
	rig.rotation = Vector3(pitch, yaw, 0.0)

	var drawn := player.controller.render_state()
	var eye_height := _rig_height

	# First person follows a crouch down, as the server's eye does for the sight rule.
	if not third_person:
		eye_height = player.eye_position().y - state.position.y

	rig.global_position = drawn.position + Vector3(0.0, eye_height, 0.0)

	_present_view_model()
	_present_effects(delta)


## The free-roam key: into a free camera while out, and back onto a player from it. On a
## connected client the server decides (it owns the mode, and says no with a notice when
## `mp_freeroam 0` or `mp_forcecamera` forbids it); offline the local world is the server.
func toggle_roam() -> void:
	if not is_spectating():
		return

	_free_cam = null
	_roam_look = Vector2.ZERO

	if bridge != null:
		bridge.ask_roam()
		return

	var res := game.spectate.toggle_roam(player.player_id)

	if not res.ok and chat != null:
		chat.notice(res.error.message)


func spectate_step(direction: int) -> void:
	if audio != null:
		var _heard := audio.click()

	if bridge != null:
		bridge.ask_spectate(direction)
		return

	if game == null or game.spectate == null or player == null:
		return

	var moved := game.spectate.step(player.player_id, direction)

	if not moved.ok and chat != null:
		chat.notice(moved.error.message)


## Everything a frame draws that a tick does not: the netcode's interpolation, every player in
## their shirt (never a side's colour, which would be the secret), every admin beacon. Returns
## how many are shown; static so the net suite drives exactly this. [param first_person] hides [param own]'s body.
static func present_frame(
	p_net: DotNetManager,
	p_game: MmGame,
	own: MmPlayer,
	first_person: bool,
	delta: float,
	alpha: float = -1.0,
	watched: MmPlayer = null
) -> int:
	var networked := p_net != null and p_net.is_running()

	if networked:
		p_net.interpolate_frame(alpha)

	# Your own player is drawn at the clock's render alpha, not the engine's fraction: the clock
	# stretches its ticks while it settles on the server, so the engine's fraction stood the eye
	# still one frame and doubled it the next. Null offline, where each frame is one tick.
	if own != null and own.controller != null:
		own.controller.set(&"render_clock", p_net.clock if networked else null)

	if p_game == null:
		return 0

	var shown := 0
	var period := 2.0

	for key: StringName in p_game.players:
		var body: MmPlayer = p_game.players[key]

		if body == null or not is_instance_valid(body) or not body.is_inside_tree():
			continue

		var mine := body == own
		var at := drawn_position(body, networked and not mine)
		var colour := p_game.shirt_colour(body)
		var hidden := (mine and first_person) or body == watched

		if body.present_body(hidden, at, colour):
			shown += 1

		var _pinged := body.present_beacon(delta, at, mine and first_person, period)

	return shown


static func drawn_position(body: MmPlayer, remote: bool) -> Vector3:
	if remote or body.controller == null:
		return body.global_position

	return body.controller.render_state().position
