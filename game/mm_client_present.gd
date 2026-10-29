extends "mm_client_frame.gd"

## What is drawn each frame in hand and on the floor. Path-based base of [code]mm_client.gd[/code], no class_name.


## The last seconds of the grace, beeped.
func _present_hide() -> void:
	if game == null or game.phase != MmGame.Phase.GRACE:
		_beeped = -1
		return

	var second := int(ceilf(game.seconds_left()))

	if second != _beeped and second <= 5 and second > 0:
		_beeped = second

		if audio != null:
			var _heard := audio.on_countdown()


func _present_view_model() -> void:
	if camera == null or player == null:
		return
	var what := ""
	if not third_person and player.is_alive() and not is_spectating():
		match player.armed():
			MmPlayer.ARMED_GUN:
				what = "gun"
			MmPlayer.ARMED_WEAPON:
				what = String(player.weapon_id)
	if what != _view_model_of:
		_view_model_of = what
		if _view_model != null and is_instance_valid(_view_model):
			_view_model.queue_free()
		_view_model = null
		if what != "":
			var parts: Array = MmWeapons.GUN_PARTS if what == "gun" else MmWeapons.entry(StringName(what))["parts"]
			_view_model = MmWeapons.build(parts, 1.0)
			_view_model.name = "ViewModel"
			camera.add_child(_view_model)
			_view_model.position = Vector3(0.22, -0.2, -0.42)
			if what != "gun":
				_view_model.rotation = Vector3(-PI / 2.6, 0.15, 0.0)
	if _view_model != null:
		# A jab forward for a moment after each attack.
		var since := float(Time.get_ticks_msec()) / 1000.0 - _swing_at
		var jab := maxf(0.0, 1.0 - since / 0.18) * 0.18
		_view_model.position.z = -0.42 - jab
		if player.attacks != _swings_seen:
			_swings_seen = player.attacks
			_swing_at = float(Time.get_ticks_msec()) / 1000.0


func _present_guns() -> void:
	if game == null or not game.draw_world:
		return
	for drop_id: int in _gun_nodes.keys():
		if not game.gun_drops.has(drop_id):
			var gone: Node3D = _gun_nodes[drop_id]
			if is_instance_valid(gone):
				gone.queue_free()
			_gun_nodes.erase(drop_id)
	for drop_id: int in game.gun_drops:
		var node: Node3D = _gun_nodes.get(drop_id)
		if node == null or not is_instance_valid(node):
			node = MmWeapons.build(MmWeapons.GUN_PARTS, 2.0)
			node.name = "DroppedGun%d" % drop_id
			game.add_child(node)
			_gun_nodes[drop_id] = node
		node.global_position = (game.gun_drops[drop_id]["at"] as Vector3) + Vector3(0.0, 0.25 + 0.05 * sin(Time.get_ticks_msec() / 300.0), 0.0)
		node.rotation.y = Time.get_ticks_msec() / 800.0


func _present_effects(delta: float) -> void:
	if audio != null:
		audio.listen_from(camera.global_position)
		audio.keep_walkers(game.players.values())

	if game.effects != null:
		game.effects.viewer_position = camera.global_position
		game.effects.advance(delta)
