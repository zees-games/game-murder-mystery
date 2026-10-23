extends Node

## Renders the game and saves a frame. The check no assertion in this repository makes.
## See `tools/shot.sh` for the views. Any `--mm-*` is the game's own configuration.

const MmClient := preload("../game/mm_client.gd")
const MmGame := preload("../game/mm_game.gd")
const MmMapDoc := preload("../game/mm_map_doc.gd")
const MmPlayer := preload("../game/mm_player.gd")

var _view := "bystander"
var _seconds := 3.0
var _board := false
var _out := "res://screenshots/shot.png"
var _at := Vector3.INF
var _look := Vector3.INF
var _third := false
## "open" or "shut": every door one way, to see a door's other pose; empty leaves the map's.
var _doors := ""
var _client: Node = null


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--view="):
			_view = arg.trim_prefix("--view=")
		elif arg == "--board":
			_board = true
		elif arg.begins_with("--seconds="):
			_seconds = arg.trim_prefix("--seconds=").to_float()
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
		elif arg.begins_with("--at="):
			_at = _v3(arg.trim_prefix("--at="))
		elif arg.begins_with("--look="):
			_look = _v3(arg.trim_prefix("--look="))
		elif arg.begins_with("--place="):
			_place = _v3(arg.trim_prefix("--place="))
		elif arg.begins_with("--pick="):
			_pick = arg.trim_prefix("--pick=").to_int()
		elif arg == "--third":
			_third = true
		elif arg.begins_with("--doors="):
			_doors = arg.trim_prefix("--doors=")

	_client = MmClient.new()
	_client.name = "Client"
	_client.set("force_offline", true)
	add_child(_client)
	# --view=cover: the loading cover dot-game's DotGameClient puts up first, before it lifts.
	if _view == "cover":
		for _i in 2:
			await RenderingServer.frame_post_draw
		var platform: DotGameClient = _client.get("platform")
		print("cover %s" % ("lifted" if platform.is_shown() else "up"))
		var cover_path := ProjectSettings.globalize_path(_out)
		DirAccess.make_dir_recursive_absolute(cover_path.get_base_dir())
		print("saved %s: %s" % [_out, error_string(_client.get_viewport().get_texture().get_image().save_png(cover_path))])
		get_tree().quit(0)
		return
	_run.call_deferred()


static func _v3(text: String) -> Vector3:
	var parts := text.split(",")
	return Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float()) if parts.size() == 3 else Vector3.INF


var _pick: int = 0

## Where the person at this keyboard stands for the shot (`--place=x,y,z`), in any view.
var _place: Vector3 = Vector3.INF


func _run() -> void:
	var game: MmGame = _client.get("game")
	await _until_a_round(game)
	var local: MmPlayer = _client.get("player")
	# The load gate's cover hides the world until the camera, the players and the warm-up are in:
	# a frame saved under it is the cover, so wait for it to lift (a free camera is not the game's).
	var gate: DotLoadGate = _client.get("gate")
	for _i in range(1800):
		if gate == null or gate.is_open():
			break
		await get_tree().process_frame
	if gate != null and not gate.is_open():
		print("the load gate is still closed, held by %s" % [gate.reasons()])

	# The person at this keyboard in the role the view is about, and the stand-ins drawn round
	# them, one of them the murderer when this one is not. Through a fresh draw, so the HUD
	# hears its role the way a round tells it.
	var roles := {}
	var mine := &"bystander"
	if _view in ["murderer", "stab", "end"]:
		mine = &"murderer"
	elif _view in ["gunner", "shot"]:
		mine = &"gunner"
	roles[local.player_id] = mine
	if mine != &"murderer":
		for id: StringName in game.players:
			if id != local.player_id:
				roles[id] = &"murderer"
				break
	game.forced_roles = roles
	var was := game.round_number
	game._decide(0, "the shot draws again")
	for _i in range(900):
		if game.round_number > was and game.phase != MmGame.Phase.IDLE:
			break
		await get_tree().process_frame
	game._place_everybody()
	if _view != "grace":
		game._set_phase(MmGame.Phase.PLAY)

	if _doors != "" and game.map.doors != null:
		for index in range(game.map.doors.count()):
			game.map.doors.apply(index, _doors == "open", false, -1)

	if _third:
		_client.call("toggle_view")

	match _view:
		"overview":
			await _frames(6)
			var box: AABB = game.map.bounds()
			var centre := box.get_center()
			var reach := maxf(box.size.length() * 0.42, 14.0)
			_free_camera().look_at_from_position(centre + Vector3(reach * 0.45, reach * 0.6, reach * 0.55), centre)
		"room":
			if _place != Vector3.INF:
				local.place_at(_place, 0.0)
			await _seconds_of(_seconds)
			if _place != Vector3.INF:
				print("the player's feet at %s" % local.controller.state.position.snapped(Vector3.ONE * 0.01))
			_free_camera().look_at_from_position(_at, _look)
		"grace", "bystander", "gunner":
			if _at != Vector3.INF:
				local.place_at(_at, 0.0)
			await _seconds_of(_seconds)
		"murderer":
			# The weapon out in their own hand.
			if _at != Vector3.INF:
				local.place_at(_at, 0.0)
			var _drawn := game.set_weapon_drawn(local.player_id, true)
			await _seconds_of(_seconds)
		"stab":
			# A stand-in a step in front, the weapon out, the stab, and [member _seconds] of the fall.
			var victim := _somebody_else(game, local)
			await _seconds_of(0.4)
			var feet := local.controller.state.position
			var ahead := Vector3(-sin(deg_to_rad(local.controller.state.yaw)), 0.0, -cos(deg_to_rad(local.controller.state.yaw)))
			victim.place_at(feet + ahead * 1.3, local.controller.state.yaw + 180.0)
			var _drawn := game.set_weapon_drawn(local.player_id, true)
			await _seconds_of(game.config.draw_seconds + 0.3)
			local.controller.state.pitch = -12.0
			var struck := game.attack_now(local.player_id)
			print("stab: %s, %s %s" % [struck, victim.display_name, "dead" if not victim.is_alive() else "alive"])
			await _seconds_of(_seconds)
			if _at != Vector3.INF:
				var spot := game.body_position(victim)
				var splat: Node3D = _client.get("blood").decals.get_child(0).get_child(0) if _client.get("blood").decals.get_child(0).get_child_count() > 0 else null
				print("stab: splat ", splat.global_position if splat != null else "none", " victim ", spot)
				if splat != null:
					spot = splat.global_position
				_free_camera().look_at_from_position(spot + _at, spot + Vector3(0.0, 0.2, 0.0))
				await _frames(4)
		"shot":
			# The gun fired past a stand-in at the wall: the tracer, a moment after.
			await _seconds_of(0.6)
			var fired := game.attack_now(local.player_id)
			print("shot: %s" % fired)
			await _seconds_of(minf(_seconds, 0.12))
		"blood":
			# The murderer stand-in late in the round, bloodied as far as it goes, from a few
			# metres: the tell the bystanders have.
			var murderer: MmPlayer = null
			for id: StringName in game.players:
				if game.team_of(id) == MmGame.MURDERERS:
					murderer = game.players[id]
			await _seconds_of(0.5)
			murderer.blood = int(_seconds) if _seconds >= 1.0 and _seconds <= 7.0 else 7
			murderer.is_bot = false
			if _place != Vector3.INF:
				murderer.place_at(_place, 0.0)
			await _seconds_of(0.6)
			var at: Vector3 = murderer.controller.state.position
			_free_camera().look_at_from_position(_at if _at != Vector3.INF else at + Vector3(1.6, 1.5, 1.8), at + Vector3(0.0, 1.0, 0.0))
			await _frames(4)
		"door":
			# A player a step in front of the first door, facing it through their own camera, so
			# the prompt is the one the client draws for that aim.
			var frame := (game.map.doors.doors[0]["body"] as Node3D).global_transform
			var size := MmMapDoc.v3((game.map.doors.doors[0]["spec"] as Dictionary)["size"])
			var normal := frame.basis.z.normalized()
			var feet := frame.origin + normal * 1.3 - Vector3(0.0, size.y * 0.5, 0.0)
			local.place_at(feet, rad_to_deg(atan2(normal.x, normal.z)))
			await _seconds_of(maxf(_seconds, 1.0))
		"spots":
			# The annotator's spots, links and chokepoints over the map from above (dot-npc-ai's
			# DotNpcAiNavDebug): where the stand-ins wander and a murderer looks for somebody alone.
			await _seconds_of(1.0)
			var ann: DotNpcAiNavAnnotations = game.bots.annotations
			if ann == null:
				push_error("no annotations: the bake or annotation has not finished")
			else:
				var debug := DotNpcAiNavDebug.new()
				game.map.add_child(debug)
				debug.show_annotations(ann)
				var sbox: AABB = game.map.bounds()
				var sc := sbox.get_center()
				_free_camera().look_at_from_position(sc + Vector3(0.0, maxf(sbox.size.x, sbox.size.z) * 0.9, 0.5), sc)
		"ragdoll":
			# A stand-in slain in front of a free camera, and [member _seconds] of its fall:
			# `--seconds=0.15`, `0.6` and `2` are the start, the drop and the body at rest.
			await _seconds_of(0.6)
			var victim := _somebody_else(game, local)
			if _place != Vector3.INF:
				victim.place_at(_place, 0.0)
				await _seconds_of(0.3)
			var feet: Vector3 = victim.controller.state.position
			var camera := _free_camera()
			camera.look_at_from_position(_at if _at != Vector3.INF else feet + Vector3(2.4, 1.6, 2.4), feet + Vector3(0.0, 0.7, 0.0))
			game._kill(victim, null, MmGame.DIED_STABBED)
			print("slew %s at %s: %s" % [victim.display_name, feet.snapped(Vector3.ONE * 0.1), victim.death.describe() if victim.death != null else "no fall"])
			await _seconds_of(_seconds)
		"end":
			# The round decided: the panel that names the murderer at last.
			game.config.intermission_seconds = 30.0
			await _seconds_of(0.5)
			game._decide(MmGame.BYSTANDERS, "the gun found the murderer")
			await _seconds_of(maxf(_seconds, 1.0))
		_:
			await _seconds_of(_seconds)

	if _board:
		var menu: Variant = _client.get("settings").menu
		var tab := InputEventKey.new()
		tab.physical_keycode = KEY_TAB
		tab.pressed = true
		menu.handle_event(tab)

	await _frames(3)
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(_out)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var saved := image.save_png(path)
	print("saved %s (%s): %s" % [_out, _view, error_string(saved)])
	get_tree().quit(0 if saved == OK else 1)


## The first living stand-in that is not [param local], made the suite's to place: no bot
## walks it off between frames.
func _somebody_else(game: MmGame, local: MmPlayer) -> MmPlayer:
	for id: StringName in game.players:
		var p: MmPlayer = game.players[id]
		if p != local and p.is_alive() and game.team_of(id) != MmGame.MURDERERS:
			p.is_bot = false
			return p
	return null


func _until_a_round(game: MmGame) -> void:
	for _i in range(900):
		if game.phase != MmGame.Phase.IDLE and _client.get("player") != null:
			return
		await get_tree().process_frame


func _free_camera() -> Camera3D:
	var camera := Camera3D.new()
	camera.fov = 75.0
	add_child(camera)
	camera.current = true
	# The HUD is the round's; a free camera is looking at the map.
	var hud: CanvasLayer = _client.get("hud")
	if hud != null:
		hud.visible = false
	return camera


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


func _seconds_of(seconds: float) -> void:
	var until := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame
