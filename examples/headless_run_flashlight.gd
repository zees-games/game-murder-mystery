extends "headless_run_base.gd"

## The flashlight section of the headless_run suite (headless_run_client.gd extends this): the map sets it, any role in the round switches it, the dead and a map may forbid it.


func _test_the_flashlight() -> void:
	_section("the flashlight: the map sets it, every role in the round switches it, the dead and a map may not")
	var game := await _round(FOUR)
	var cfg := game.flashlight_conf()
	var murderer := _p(game, &"u1m")
	var gunner := _p(game, &"u2g")
	var bystander := _p(game, &"u3b")
	_check(cfg.key == "F" and game.flashlight_binder != null, "the key is F and the config has a binder", cfg.key)

	cfg.default_state = DotFlashlightConfig.START_ON
	murderer.flashlight_ready = false
	await _step(game, 2)
	_check(murderer.flashlight, "a map that starts lit lights the player")
	cfg.default_state = DotFlashlightConfig.START_OFF
	murderer.flashlight_ready = false
	await _step(game, 2)
	_check(not murderer.flashlight, "and one that starts dark does not")

	_check(game.toggle_flashlight(murderer.player_id) and murderer.flashlight, "the switch turns a murderer's light on")
	_check(game.toggle_flashlight(gunner.player_id) and gunner.flashlight, "and the gunner's")
	_check(game.toggle_flashlight(bystander.player_id) and bystander.flashlight, "and a bystander's")
	_check(game.toggle_flashlight(murderer.player_id) and not murderer.flashlight, "and the next press turns it off")

	bystander.watching = true
	_check(not game.toggle_flashlight(bystander.player_id) and bystander.flashlight, "somebody out of the round has no switch")

	cfg.allowed_maps = PackedStringArray(["no_such_map"])
	_check(not game.toggle_flashlight(gunner.player_id) and gunner.flashlight, "a map outside allowed_maps has no light")
	cfg.allowed_maps = PackedStringArray()
	cfg.default_state = DotFlashlightConfig.START_DARK
	_finished()
