extends "mm_client_spectate.gd"

## One local player, a camera and a HUD over a [MmGame], offline or against a server. Offline is
## the same world class with `authoritative` true and stand-ins; a [DotClientLink] in the registry
## under `dot_client_link` picks the connected half, `--offline` forces it. First person (F5 for third).


## The game's own keys, from the bindings. True when one was used.
func _key_pressed(event: InputEvent) -> bool:
	if event.is_action_pressed(MmBindings.ROAM) and is_spectating():
		toggle_roam()
		return true

	if event.is_action_pressed(MmBindings.VIEW):
		if is_spectating():
			spectate_step(0)
		else:
			toggle_view()
		return true

	if player == null or not player.is_alive() or is_spectating():
		return false

	return false


func _unhandled_input(event: InputEvent) -> void:
	if _covered():
		return

	# Tab, M and a click taking the pointer back are the platform's (DotGameClient).
	if event.is_action_pressed("ui_cancel"):
		if settings != null:
			settings.open()
		return

	if event is InputEventKey and (event as InputEventKey).pressed and not event.is_echo():
		if _key_pressed(event):
			get_viewport().set_input_as_handled()
			return

	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton

		if is_spectating():
			if button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
				spectate_step(1)
			elif button.pressed and button.button_index == MOUSE_BUTTON_RIGHT:
				spectate_step(-1)
			return

	if player == null:
		return

	if is_roaming() and event is InputEventMouseMotion:
		# The free camera turns on the mouse, and the dead body's view stays put.
		if _pointer_ours():
			_roam_look += (event as InputEventMouseMotion).relative
		return

	if event is InputEventMouseMotion and _pointer_ours():
		if _offline and player.sampler != null:
			player.sampler.handle_event(event)
		elif _sampler != null:
			_sampler.handle_event(event)


func describe() -> Dictionary:
	var out := {
		"offline": _offline,
		"session": _watch_id,
		"player": player != null,
		"view": "third" if third_person else "first",
	}

	if bridge != null:
		out["bridge"] = bridge.describe()

	if chat != null:
		out["chat"] = chat.describe()

	if game != null:
		out["world"] = game.describe()

	return out
