extends "mm_client_view.gd"

## What the client does with the game's events: phase, role, shot, map, round and death. Path-based base of [code]mm_client.gd[/code], no class_name.


func _on_phase(phase: int) -> void:
	if hud == null or player == null:
		return

	match phase:
		MmGame.Phase.GRACE:
			if audio != null:
				var _heard := audio.on_start()
		MmGame.Phase.PLAY:
			if audio != null:
				var _heard := audio.on_armed()
			if game.effects != null:
				var _flashed := game.effects.flash(&"go")
			if is_murderer():
				hud.shout("%s to draw your %s. Nobody may see." % [_key(MmBindings.HOLSTER), game.weapon_name().to_lower()], 3.0)
			else:
				hud.shout("THE MURDERER IS ARMED" if not player.has_gun else "YOU HAVE THE GUN", 2.4)


## This client's role arrived (the draw, or a reconnect mid-round).
func _on_role(side: int, gun: bool, _weapon_id: StringName) -> void:
	if hud == null:
		return
	if player != null:
		player.retune()
	if side == MmGame.MURDERERS:
		hud.shout("YOU ARE THE MURDERER — kill them all", 4.0)
	elif gun:
		hud.shout("YOU ARE A BYSTANDER WITH THE GUN — find the murderer", 4.0)
	else:
		hud.shout("YOU ARE A BYSTANDER — stay alive", 4.0)
	hud.role_changed()


func _player_of(session_id: int) -> MmPlayer:
	if session_id == _watch_id and player != null:
		return player
	return game.players.get(MmNetBridge.player_key(session_id))


## A thin bright box from [param from] to [param to] that fades in a fifth of a second.
func _tracer(from: Vector3, to: Vector3, hit: bool) -> void:
	if game == null or not game.draw_world or from.distance_to(to) < 0.05:
		return
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.025, 0.025, from.distance_to(to))
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.35, 0.25, 0.9) if hit else Color(1.0, 0.92, 0.6, 0.9)
	mesh.material = mat
	var line := MeshInstance3D.new()
	line.name = "Tracer"
	line.mesh = mesh
	line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	game.add_child(line)
	line.global_position = (from + to) * 0.5
	line.look_at_from_position(line.global_position, to, Vector3.UP if absf((to - from).normalized().y) < 0.99 else Vector3.RIGHT)
	var fade := line.create_tween()
	fade.tween_property(mat, "albedo_color:a", 0.0, 0.2)
	fade.tween_callback(line.queue_free)


## Somebody fired: a tracer from the gun to where the shot stopped, and the bang.
func _on_shot(session_id: int, from: Vector3, to: Vector3, hit: bool) -> void:
	var who := _player_of(session_id)
	if who != null and who.figure != null:
		who.figure.strike()
	if audio != null:
		var _bang := audio.on_shot(from, session_id == _watch_id)
	_tracer(from, to, hit)
	if hit and blood != null and game.draw_world:
		var _splat := blood.on_shot_hit(from, to)


func _toy_sound(id: StringName, at: Vector3, strength: float) -> void:
	if audio != null:
		var _played := audio.on_toy(id, at, strength)


func _on_map(map_id: StringName) -> void:
	if ragdolls != null:
		# A body on the old map would hang in the new one's air.
		ragdolls.clear()
	if blood != null:
		blood.clear()

	# The new map's toys are heard: a bounce, a knock, a switch, a honk.
	if game.map != null and game.map.toys != null and not game.map.toys.sound.is_connected(_toy_sound):
		var _c := game.map.toys.sound.connect(_toy_sound)

	if audio != null:
		audio.on_map_doc(map_id, game.map_doc)

	var name_of := str(game.map_doc.get("name", ""))
	hud.shout(name_of, 3.0)

	if chat != null and name_of != "":
		var author := str(game.map_doc.get("author", ""))
		var blurb := str(game.map_doc.get("blurb", ""))
		chat.say_locally("%s%s%s" % [name_of, " by %s" % author if author != "" else "",
			" — %s" % blurb if blurb != "" else ""], Color(0.80, 0.90, 1.0))


func _on_round(number: int, began: bool, winner: int, why: String = "", killer: int = 0) -> void:
	if began:
		if killcam != null and killcam.is_playing():
			killcam.skip()
		hud.shout("ROUND %d" % number, 2.0)
		return

	if audio != null and player != null:
		var _heard := audio.on_round_end(winner != 0 and game.team_of(player.player_id) == winner)

	# Everybody back to the public side: the round is over and the next draw is a new secret.
	if hud != null:
		hud.role_changed()

	var who := game.side_name(winner).to_upper() + " WIN" if winner != 0 else "DRAW"
	hud.shout("%s — %s" % [who, why] if why != "" else who, 4.0)

	if chat != null and why != "":
		chat.say_locally(why, Color(0.98, 0.86, 0.40))

	_play_killcam(killer)


## The round's last kill again, from the drawn frames. [param killer] is known only now, after
## the reveal; during the round the buffer holds the kill with no killer.
func _play_killcam(killer: int) -> void:
	if killcam == null or killer == 0 or game.config.killcam_seconds <= 0.0:
		return
	var kill := killcam.buffer.last_event(&"kill")
	if kill.is_empty():
		return
	(kill["data"] as Dictionary)["killer"] = killer
	var _playing := killcam.match_ended()


## The killcam's host, off unless dot-replay has it (API 6).
func _build_killcam() -> void:
	if DotAddonApi.build_level("dot_replay") < 6:
		return
	killcam = DotKillcamHost.new()
	MmKillcamBodies.configure(killcam)
	killcam.name = "FinalKillcam"
	killcam.players_fn = func() -> Array: return game.players.values() if game != null else []
	killcam.player_for_fn = func(id: int) -> Variant: return _player_of(id)
	killcam.id_of_fn = func(p: MmPlayer) -> int: return _session(p.player_id)
	killcam.no_id = 0
	killcam.seconds_fn = func() -> float: return game.config.killcam_seconds if game != null else 0.0
	add_child(killcam)


## Records the frame, or draws the replay over it.
func _killcam_frame() -> void:
	if killcam == null:
		return
	killcam.hide_while_playing = [hud, _view_model]
	if game.physics != null:
		killcam.world_mask = game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop")
	killcam.frame()


## [param who]'s body falls the way the server picked ([member MmPlayer.death]), copied from the
## figure this client draws; the figure itself stays hidden while they are dead. Called from
## [method _on_death], solo and connected alike.
func _fall(who: MmPlayer) -> void:
	if who == null or ragdolls == null or who.figure == null or not who.figure.is_inside_tree():
		return
	if game.physics != null:
		# The rooms and the props: a body lands on them and on nothing else (not on a person).
		game.ragdoll_rules.collision_mask = game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop")
	var velocity := who.controller.state.velocity if who.controller != null else Vector3.ZERO
	var _body := ragdolls.spawn(who.figure, who.death if who.death != null else DotPlayerDeath.new(), velocity)
	# The blade or gun falls with the hand that held it, as a short-lived prop (sv_ragdoll_weapon_drop).
	var held := who.figure.held_node()
	if held != null:
		var _prop := ragdolls.drop_prop(held, velocity)
		held.visible = false


func _on_death(session_id: int, by: int, why: StringName) -> void:
	if killcam != null and why != MmGame.DIED_FELL:
		killcam.note_kill(by, session_id, String(why))
	var who := _player_of(session_id)
	_fall(who)

	if audio != null and who != null and why != MmGame.DIED_FELL and why != MmGame.DIED_SHOT:
		var _heard := audio.on_stab(who.global_position, session_id == _watch_id)
	if who != null and blood != null and game.draw_world and why != MmGame.DIED_FELL and why != MmGame.DIED_SHOT:
		var _splat := blood.on_stab(game.body_position(who))

	if session_id == _watch_id and hud != null:
		hud.shout("YOU DIED" if why != MmGame.DIED_FELL else "YOU FELL", 2.5)

	if chat == null or who == null:
		return

	# Who did it is never said: the server does not send it (see the bridge), and offline the
	# client says no more than a connected one would.
	match why:
		MmGame.DIED_FELL:
			chat.say_locally("%s fell" % who.display_name, Color(0.80, 0.82, 0.86))
		MmGame.DIED_SHOT:
			chat.say_locally("%s was shot" % who.display_name, Color(0.95, 0.75, 0.55))
		_:
			chat.say_locally("%s was killed" % who.display_name, Color(0.95, 0.55, 0.55))
