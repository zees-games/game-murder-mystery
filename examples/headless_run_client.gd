extends "headless_run_base.gd"

const MmBindings := preload("../game/mm_bindings.gd")
const MmBlood := preload("../game/mm_blood.gd")
const MmEvents := preload("../game/net/mm_events.gd")
const MmSettings := preload("../game/mm_settings.gd")
const MmViewArms := preload("../game/mm_view_arms.gd")

## The client half of the headless_run suite: the client offline, help and the map menu, gore, fall damage and the figure's clock. headless_run.gd extends this and runs it.

func _press(game: MmGame, player: MmPlayer) -> void:
	player.wants_use = true
	await _step(game, 1)
	player.wants_use = false
	await _step(game, 1)


func _test_the_client() -> void:
	_section("the client boots offline: the keys, the HUD by role, the board, the dead")
	var client: Node = (load("res://game/mm_client.gd") as GDScript).new()
	client.set(&"force_offline", true)
	client.set(&"config_file", "user://cfg/headless-none.json")
	add_child(client)
	var platform: DotGameClient = client.get("platform")
	var covered := platform != null and platform.gate != null and not platform.is_shown() \
		and platform.is_input_blocked()
	for i in 240:
		await get_tree().process_frame
		if platform != null and platform.is_shown():
			break
	for i in 8:
		await get_tree().process_frame

	_check(covered and platform.is_shown() and not platform.is_input_blocked() and platform.console != null,
		"the loading cover is up at the start and lifts once the player is in, with the console built",
		str(platform.describe()) if platform != null else "no platform")
	_check(InputMap.has_action(MmBindings.ATTACK) and InputMap.has_action(MmBindings.HOLSTER),
		"the game's keys are actions, from the bindings table")
	_check(client.get("player") != null and client.get("hud") != null and (client.get("hud") as Node).get("game") != null,
		"a player and a HUD bound to the world")
	var snapshot: Dictionary = client.call("board_snapshot")
	_check((snapshot["players"] as Array).size() >= 2, "the board lists the room")
	var tab := InputEventKey.new()
	tab.physical_keycode = KEY_TAB
	tab.pressed = true
	((client.get("settings") as Node).get("menu") as DotMenu).handle_event(tab)
	var board: DotMenuScoreboard = client.get("board")
	_check(board != null and board.is_open() and board.rows().any(func(r: Dictionary) -> bool: return bool(r.get("you", false))),
		"Tab holds the scoreboard up, with this player picked out")
	tab.pressed = false
	((client.get("settings") as Node).get("menu") as DotMenu).handle_event(tab)

	var world: MmGame = client.get("game")
	var hud: Node = client.get("hud")
	await _client_knife(client, world, hud, platform)
	await _client_gunner(client, world, hud)
	await _client_hud(client, world, hud)
	await _client_ragdoll(client, world)
	await _client_death_and_prompt(client, world, hud)

	remove_child(client)
	client.free()
	await get_tree().process_frame
	_finished()



func _client_knife(client: Node, world: MmGame, hud: Node, platform: DotGameClient) -> void:
	world.forced_roles = {&"local": &"murderer"}
	world._on_round_started(world.round_number + 1)
	for i in 4:
		await get_tree().process_frame
	_check(world.team_of(&"local") == MmGame.MURDERERS and hud.call("role_of") == &"murderer",
		"a murderer's own HUD says so")
	# The solo shell's path: the real key, through the client's own polling, no pointer capture
	# (a browser captures only on a click, and a headless display never does).
	world._set_phase(MmGame.Phase.PLAY)
	var self_p: MmPlayer = client.get("player")
	_check(not self_p.weapon_drawn, "a murderer's weapon starts away", str(self_p.weapon_drawn))
	Input.action_press(MmBindings.HOLSTER)
	for i in 6:
		await get_tree().physics_frame
	Input.action_release(MmBindings.HOLSTER)
	for i in 3:
		await get_tree().process_frame
	_check(self_p.weapon_drawn and self_p.armed() == MmPlayer.ARMED_WEAPON,
		"Q, held through the offline client, draws the knife", "mouse_mode=%s input_blocked=%s" % [Input.mouse_mode, platform.is_input_blocked()])
	for i in 8:
		await get_tree().process_frame
	var hands: MmViewArms = client.get("view_arms")
	_check(not MmViewArms.available() or (hands != null and hands.holding()),
		"and your arms are on it in first person", str(hands.holding() if hands != null else "no arms"))
	_check(not MmViewArms.available() or (hands != null and hands.hand_error() >= 0.0 and hands.hand_error() < 0.05),
		"the hand is on the knife's grip", str(hands.hand_error() if hands != null else -1))
	_check(client.get("_view_model_of") == String(self_p.weapon_id), "and it is in the hand in first person", str(client.get("_view_model_of")))
	for wid: StringName in MmWeapons.ids():
		self_p.weapon_id = wid
		for i in 6:
			await get_tree().process_frame
		_check(not MmViewArms.available() or (hands.holding() and hands.hand_error() >= 0.0 and hands.hand_error() < 0.05),
			"the hand is within 5 cm of the %s's grip" % wid, str(hands.hand_error()))
	self_p.weapon_id = MmWeapons.DEFAULT
	for i in 6:
		await get_tree().process_frame
	Input.action_press(MmBindings.HOLSTER)
	for i in 6:
		await get_tree().physics_frame
	Input.action_release(MmBindings.HOLSTER)
	for i in 3:
		await get_tree().process_frame
	_check(not self_p.weapon_drawn, "and Q again puts it away")
	_check(not MmViewArms.available() or not hands.holding(), "and the arms are gone with it")


func _client_gunner(client: Node, world: MmGame, hud: Node) -> void:
	var hands: MmViewArms = client.get("view_arms")
	world.forced_roles = {&"local": &"gunner"}
	world._on_round_started(world.round_number + 1)
	for i in 4:
		await get_tree().process_frame
	_check(hud.call("role_of") == &"gunner", "and a gunner's says that")
	for i in 8:
		await get_tree().process_frame
	_check(not MmViewArms.available() or (hands.holding() and hands.hand_error() >= 0.0 and hands.hand_error() < 0.05),
		"a gunner's arms hold the gun in two hands, both within 5 cm of the grips", str(hands.hand_error()))
	var icon_script: Script = load("res://game/mm_weapon_icons.gd")
	var icons: DotWeaponIconStyle = icon_script.get("shared")
	var icon_rect: DotWeaponIconPlate = hud.get("weapon_icon")
	var unmapped := PackedStringArray()
	for weapon in icon_script.get("TAGS"):
		if not icons.icon_set().has_icon(weapon):
			unmapped.append(String(weapon))
	hud.call("_process", 0.0)
	_check(unmapped.is_empty() and icon_rect != null and icon_rect.texture != null and icon_rect.texture == icons.texture(&"gun"),
		"a gunner's HUD draws the gun's sprite, and every mapped weapon has one", ", ".join(unmapped))
	var _silhouette := icons.set_style(&"silhouette")
	hud.call("_process", 0.0)
	_check(icon_rect != null and icon_rect.texture == null, "cl_weapon_icons silhouette hides the sprite")
	var _pixel := icons.set_style(&"pixel")
	world.forced_roles = {}


func _client_hud(client: Node, world: MmGame, hud: Node) -> void:
	# The clock is dot-ui's DotScoreStrip: everybody alive, and how many murderers are left.
	hud.call("_process", 0.0)
	var xh: DotCrosshair = hud.get("_crosshair")
	_check(xh != null and not xh.suppressed and xh.alive_source.is_valid() and bool(xh.alive_source.call()), "a living player's crosshair is bound to their alive state")
	var strip: DotScoreStrip = hud.get("strip")
	_check(
		strip.clock == DotScoreStrip.clock_text(world.seconds_left()) and strip.sides
		and strip.left_score == world.alive_total() and strip.right_score == world.alive_on(MmGame.MURDERERS),
		"the clock is DotScoreStrip's, with the living and the murderers left as its plates",
		str(strip.describe())
	)

	var themed: DotMenu = (client.get("settings") as Node).get("menu")
	var plate := strip.colour(&"plate")
	_check(plate.get_luminance() < 0.1 and plate.a >= 0.7 and strip.colour(&"highlight") == (load("res://game/mm_hud.gd") as GDScript).get("MAP_COLOUR"),
		"the HUD is dark by default, in the menu's theme, with this game's colour as its accent", str(plate))
	var _t: Variant = themed.settings.set_value(&"ui_theme", &"contrast")
	var hints: Label = hud.get("_hints")
	_check(strip.colour(&"plate") == themed.palette().hud_plate and hints.get_theme_color(&"font_color") == themed.palette().hud_text
		and strip.colour(&"highlight") == (load("res://game/mm_hud.gd") as GDScript).get("MAP_COLOUR"),
		"a theme picked in the menu reaches the clock and the HUD's lines at once, the accent kept")
	_t = themed.settings.set_value(&"ui_theme", &"midnight")


func _client_ragdoll(client: Node, world: MmGame) -> void:
	# A slain stand-in falls as dot-player-char's ragdoll, copied from the figure, which is hidden.
	world._set_phase(MmGame.Phase.PLAY)
	var ragdolls: DotPlayerRagdolls = client.get("ragdolls")
	var victim: MmPlayer = null
	for id: StringName in world.players:
		var p: MmPlayer = world.players[id]
		if p != client.get("player") and p.is_alive() and p.figure != null and p.figure.visible:
			victim = p
			break
	_check(victim != null and ragdolls != null and ragdolls.rules == world.ragdoll_rules,
		"the client keeps the dead under the game's sv_ragdoll* rules")
	if victim != null:
		# Mostly pinned, because the fall is a physics outcome that differed run to run: the seat is
		# the map's first spawn and the killer stands a metre off, as a stab or a shot would have it.
		var spot: Array = world.map.spawn(MmGame.SPAWN_GROUP, 0)
		victim.place_at(spot[0], 0.0)
		var killer: MmPlayer = null
		for id: StringName in world.players:
			if world.players[id] != victim and world.players[id] != client.get("player"):
				killer = world.players[id]
				break
		if killer != null:
			killer.place_at(spot[0] - Vector3(1.0, 0.0, 0.0), 90.0)
		for i in 60:
			await get_tree().physics_frame
		victim.figure.hold(1, &"knife")
		world._kill(victim, killer, MmGame.DIED_SLAIN)
		await get_tree().process_frame
		var dropped := ragdolls.get_node_or_null("DroppedWeapon") as RigidBody3D
		_check(dropped != null and not victim.figure.held_node().visible,
			"a slain player's weapon drops as a prop while the hand's copy hides")
		_check(victim.death != null and DotPlayerDeathReactions.stock().has(victim.death.reaction),
			"the world picked how the body falls", str(victim.death.describe()) if victim.death != null else "none")
		var bodies := ragdolls.live()
		_check(bodies.size() == 1 and not victim.figure.visible,
			"and the client laid the body down from the figure, which is hidden", str(bodies.size()))
		# Until it settles, not for a fixed second: a frame count judged some bodies mid-air. The
		# ragdoll freezes itself at rules.max_sim_time, so this ends.
		for i in 900:
			await get_tree().physics_frame
			if bodies.size() != 1 or not is_instance_valid(bodies[0]) or bodies[0].settled:
				break
		var down := bodies.size() == 1 and is_instance_valid(bodies[0])
		var ground_y := 0.0
		var detail := "gone"
		if down:
			var at: Vector3 = bodies[0].centre()
			var hit := world.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(
				at + Vector3.UP * 0.3, at + Vector3.DOWN * 6.0,
				world.physics.layer_mask(&"world") | world.physics.layer_mask(&"prop")))
			ground_y = (hit["position"] as Vector3).y if not hit.is_empty() else -INF
			detail = "%s ground=%.2f centre.y=%.2f lowest=%.2f" % [bodies[0].describe(), ground_y, at.y, bodies[0].lowest_point()]
		_check(down and ground_y > -INF and bodies[0].centre().y - ground_y < 0.8 and bodies[0].lowest_point() - ground_y > -0.25,
			"once it settles, the body lies on the ground under it: not standing, not through it", detail)
		await _face_plant_sweep(world, ragdolls, victim, spot)
	else:
		for k in 3:
			_check(false, "a stand-in drawn to slay")


## The same fall again and again at four facings from clear floor.
func _face_plant_sweep(world: MmGame, ragdolls: DotPlayerRagdolls, victim: MmPlayer, spot: Array) -> void:
	# Nobody pushing, which the pinned seed above dodged: one fall in six stays upright with no wall
	# ahead, dot-player-char's to fix (nightly ragdoll-faceplant-upright-1). A wall ahead excuses it.
	# Stands on clear floor, not seat 0, which has a cushion ahead.
	var sweep_spot: Vector3 = spot[0]
	var best_clear := -1.0
	var sweep_state := world.get_world_3d().direct_space_state
	for seat in 12:
		var cand: Vector3 = (world.map.spawn(MmGame.SPAWN_GROUP, seat))[0]
		var clear := 2.0
		for dir in 8:
			var way := Vector3.FORWARD.rotated(Vector3.UP, float(dir) * PI / 4.0)
			for h in [0.15, 0.45, 0.9, 1.5]:
				var from: Vector3 = cand + Vector3.UP * h
				var hit_c := sweep_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + way * 2.0, 0xffff))
				if not hit_c.is_empty():
					clear = minf(clear, from.distance_to(hit_c["position"] as Vector3))
		if clear > best_clear:
			best_clear = clear
			sweep_spot = cand
		if clear >= 2.0:
			break
	var upright := 0
	var excused := 0
	var detail_up: Array[String] = []
	var sweep_n := 12
	for s in sweep_n:
		ragdolls.clear()
		victim.figure.visible = true
		victim.place_at(sweep_spot, float(s % 4) * 45.0)
		for i in 4:
			await get_tree().physics_frame
		var d := DotPlayerDeath.decide(world.ragdoll_rules.reactions(), false, 0.0, Vector3.ZERO,
			DotPlayerDeath.seed_of(victim.entity_id, 1000 + s * 37), null, -1.0, &"face_plant")
		var fwd: Vector3 = -victim.figure.global_basis.z
		var b := ragdolls.spawn(victim.figure, d, Vector3.ZERO)
		# Settled, not a fixed 240 frames: a body mid-fall is not yet a lying one. max_sim_time ends it.
		for i in 900:
			await get_tree().physics_frame
			if b == null or not is_instance_valid(b) or b.settled:
				break
		if b == null or not is_instance_valid(b):
			upright += 1
			detail_up.append("%d:gone %s" % [s, _no_body(victim.figure, b, ragdolls)])
			continue
		var c: Vector3 = b.centre()
		var gh := world.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(
			c + Vector3.UP * 0.3, c + Vector3.DOWN * 6.0,
			world.physics.layer_mask(&"world") | world.physics.layer_mask(&"prop")))
		var gy := (gh["position"] as Vector3).y if not gh.is_empty() else -INF
		# "Through the floor" is judged against the floor, not whatever is under the centre: a body
		# lying across a 0.3 m solid by the seat has an arm on the floor and the ray lands on the solid.
		var floor_y := minf(gy, sweep_spot.y)
		if c.y - gy < 0.8 and b.lowest_point() - floor_y > -0.25:
			continue
		var blocked := false
		for h in [0.15, 0.45, 0.9, 1.5]:
			var at: Vector3 = sweep_spot + Vector3.UP * h
			blocked = blocked or not world.get_world_3d().direct_space_state.intersect_ray(
				PhysicsRayQueryParameters3D.create(at, at + fwd * 2.0, 0xffff)).is_empty()
		if blocked:
			excused += 1
		else:
			upright += 1
			detail_up.append("%d: centre.y=%.2f lowest=%.2f ground=%.2f settled=%s hit=%s %s" % [s, c.y, b.lowest_point(), gy, str(b.settled), str(gh.get("collider")), b.describe()])
	_check(upright == 0, "a face plant with nobody pushing lies down at %d facings (a wall ahead excused)" % sweep_n,
		"%d stayed up, %d excused, clear %.2f m at %s: %s" % [upright, excused, best_clear, str(sweep_spot), str(detail_up)])


func _client_death_and_prompt(client: Node, world: MmGame, hud: Node) -> void:
	# The fall rides DEATH last and optional, so a death from an older server still reads.
	var fall := DotPlayerDeath.new()
	fall.reaction = &"face_plant"
	fall.roll_seed = 1234
	fall.direction = Vector3(1, 0, 0)
	var died := MmEvents.read_death(DotNetReader.new(MmEvents.write_death(5, 0, MmGame.DIED_STABBED, fall)))
	var carried: DotPlayerDeath = died.get("death")
	_check(bool(died["ok"]) and carried != null and carried.reaction == &"face_plant" and carried.roll_seed == 1234
		and carried.direction.distance_to(Vector3(1, 0, 0)) < 0.02, "a DEATH carries the fall the server picked")
	var bare := MmEvents.read_death(DotNetReader.new(MmEvents.write_death(5, 0, MmGame.DIED_SHOT)))
	_check(bool(bare["ok"]) and not bare.has("death"), "and one without a fall still reads")

	# Somebody a step in front of a door is prompted by DotKeyPrompt with the use key as bound.
	var me: MmPlayer = client.get("player")
	var frame := (world.map.doors.doors[0]["body"] as Node3D).global_transform
	var size := MmMapDoc.v3((world.map.doors.doors[0]["spec"] as Dictionary)["size"])
	var normal := frame.basis.z.normalized()
	me.place_at(frame.origin + normal * 1.3 - Vector3(0.0, size.y * 0.5, 0.0), rad_to_deg(atan2(normal.x, normal.z)))
	for i in 4:
		await get_tree().process_frame
	hud.call("_process", 0.0)
	var prompt: DotKeyPrompt = hud.get("prompt")
	var bound := str(client.call("_key", MmBindings.USE))
	_check(
		prompt.visible and (prompt.words.begins_with("Open") or prompt.words.begins_with("Shut"))
		and prompt.key == bound and bound != "",
		"at a door, DotKeyPrompt names it with the use key as bound", prompt.text()
	)

	# A pack naming these classes does not parse on a shell whose dot-ui predates them, so
	# the requires.json dot-ci derives must ask for dot-ui 13, and nothing may lower it.
	var asks := DotAddonApi.derive()
	_check(
		int(asks.get("dot_ui", 0)) >= 13 and FileAccess.file_exists("res://" + DotAddonApi.FLOOR_FILE),
		"the pack asks a shell for dot-ui level 13, the weapon icons (requires.floor.json)",
		str(asks.get("dot_ui"))
	)


## Why a body is not there: never built (the figure's state says why) or freed since.
func _no_body(figure: Node3D, body: Object, ragdolls: DotPlayerRagdolls) -> String:
	return "%s intree=%s vis=%s meshes=%d style=%s live=%d" % [
		"never built" if body == null else "freed", str(figure.is_inside_tree()), str(figure.visible),
		DotPlayerRagdoll.meshes_of(figure).size(), str(ragdolls.rules.effective_style()), ragdolls.live().size()]


## The family's rule since the first play test: H opens help in every game, nothing else in
## the table is on H, and the Escape menu has Help & commands and Leave.
func _test_spectate_tap() -> void:
	_section("out, one tap or left click steps once, whether or not the engine emulates the mouse")
	var game := await _round(FOUR)
	var m := _p(game, &"u1m")
	var b := _p(game, &"u3b")
	var id := b.player_id
	game._kill(b, m, MmGame.DIED_STABBED)
	game.spectate.manager.set_mode(String(id), DotSpectatorView.Mode.CHASE)
	var client: Node = (load("res://game/mm_client.gd") as GDScript).new()
	client.set(&"game", game)
	client.set(&"player", b)
	_check(client.is_spectating(), "the client is out and spectating")

	# Two live targets besides the first, so a double step lands somewhere a single step does not.
	var start: Variant = game.spectate.watching(id)
	var touch := InputEventScreenTouch.new()
	touch.pressed = true
	client._unhandled_input(touch)
	var after_touch: Variant = game.spectate.watching(id)
	_check(after_touch != start, "a real touch steps to the next target")

	var emulated := InputEventMouseButton.new()
	emulated.button_index = MOUSE_BUTTON_LEFT
	emulated.pressed = true
	emulated.device = InputEvent.DEVICE_ID_EMULATION
	client._unhandled_input(emulated)
	_check(game.spectate.watching(id) == after_touch, "the mouse press the engine emulates from it steps nothing more")

	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	client._unhandled_input(click)
	var after_click: Variant = game.spectate.watching(id)
	_check(after_click != after_touch and after_click != start, "a real left click steps once")

	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	client._unhandled_input(release)
	_check(game.spectate.watching(id) == after_click, "and a release steps nothing")

	var right := InputEventMouseButton.new()
	right.button_index = MOUSE_BUTTON_RIGHT
	right.pressed = true
	client._unhandled_input(right)
	_check(game.spectate.watching(id) == after_touch, "the right button still steps back")
	client.free()
	_finished()


func _test_help_and_menu() -> void:
	_section("H opens help, and the Escape menu has Help and Leave")
	var settings := MmSettings.new()
	add_child(settings)
	var built: DotResult = settings.setup(DotSettingsStoreMemory.new())
	var keys: DotMenuBindings = settings.bindings
	_check(built.ok and keys != null and keys.key_for(DotMenuBindings.HELP_ACTION) == "H", "help is on H")
	_check(keys.defaults_on("H").size() == 1, "and nothing else in the table defaults to H",
		str(keys.defaults_on("H").map(func(r: Dictionary) -> String: return str(r["label"]))))
	# Chat is a row, so the Controls page moves it; there is no team chat (roles are secret).
	var _k := settings.settings.set_value(&"bind_chat", "K")
	_check(keys.key_for(MmBindings.CHAT) == "K" and DotInputBinding.describe_action(MmBindings.CHAT) == "K"
		and keys.defaults_on("U").is_empty(), "chat is a row, rebinding it moves its key, and there is no team chat on U",
		"%s %d" % [keys.key_for(MmBindings.CHAT), keys.defaults_on("U").size()])
	_check(keys.key_for(MmBindings.ATTACK) != "" and keys.key_for(MmBindings.HOLSTER) != "", "attack and holster are bound",
		"%s %s" % [keys.key_for(MmBindings.ATTACK), keys.key_for(MmBindings.HOLSTER)])
	var h := InputEventKey.new()
	h.physical_keycode = KEY_H
	h.keycode = KEY_H
	h.pressed = true
	_check(settings.menu.handle_event(h) and settings.menu.help.is_open(), "H opens the help screen")
	_check(settings.menu.help.about != "" and settings.menu.help.heading() == "How to play Murder Mystery",
		"which says what the game is before the keys")
	settings.menu.help.close()
	settings.open()
	var help_button := settings.menu.screen.find_child("Action_help", true, false) as Button
	var leave_button := settings.menu.screen.find_child("Action_leave", true, false) as Button
	_check(help_button != null and leave_button != null and leave_button.visible,
		"the Escape menu has Help & commands and Leave")
	settings.close()
	settings.queue_free()
	await get_tree().process_frame
	_finished()


## Blood splatters: the Video row, gore off draws nothing, on draws one at a stab and a shot, and the
## setting survives a save and a fresh load.
func _test_gore() -> void:
	_section("Blood splatters: the row, off draws nothing, on draws, and it persists")
	var scratch := "user://headless_gore_persist"
	var first := MmSettings.new()
	first.directory = scratch
	add_child(first)
	var _b1 := first.setup(DotSettingsStoreFile.new(scratch))
	var image: DotMenuSection = first.menu.page(&"video").section("Image")
	var row: DotMenuRow = image.find_row(&"gore") if image != null else null
	_check(row != null and first.schema.has(&"gore") and first.settings.get_bool(&"gore", false),
		"the Video page has a Blood splatters row on the gore setting, on by default")
	var _g1 := first.settings.set_value(&"gore", false)
	var flushed := first.settings.flush()
	_check(flushed.ok and not DirAccess.get_files_at(scratch).is_empty(), "turning it off and saving writes the settings file")
	var second := MmSettings.new()
	second.directory = scratch
	add_child(second)
	var _b2 := second.setup(DotSettingsStoreFile.new(scratch), false)
	_check(second.settings.get_bool(&"gore", true) == false, "a fresh settings manager loading that file reads gore as off")

	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20, 1, 20)
	shape.shape = box
	floor_body.add_child(shape)
	add_child(floor_body)
	floor_body.global_position = Vector3(0, -0.5, 0)
	var blood := MmBlood.new()
	add_child(blood)
	await get_tree().physics_frame
	await get_tree().physics_frame
	blood.apply_settings(second.settings)
	_check(not blood.decals.config.gore and blood.on_stab(Vector3(0, 0, 0)) == null, "gore off: a stab draws no splatter")
	_check(blood.on_shot_hit(Vector3(0, 3, 0), Vector3(0, 1.5, 0)) == null, "gore off: a shot draws none either")
	var _g2 := second.settings.set_value(&"gore", true)
	blood.apply_settings(second.settings)
	_check(blood.on_stab(Vector3(0, 0, 0)) != null, "gore on: a stab splatters the floor under the victim")
	_check(blood.on_shot_hit(Vector3(0, 3, 0), Vector3(0, 1.5, 0)) != null, "gore on: a shot that hit splatters the surface behind")
	_check(blood.on_stab(Vector3(0, -6, 0)) == null, "and no surface in reach, no splatter")
	blood.queue_free()
	floor_body.queue_free()
	first.queue_free()
	second.queue_free()
	var real := ProjectSettings.globalize_path(scratch)
	for f in DirAccess.get_files_at(real):
		var _rm := DirAccess.remove_absolute(real.path_join(f))
	var _rd := DirAccess.remove_absolute(real)
	await get_tree().process_frame
	_finished()


## The family's rule since the first play test: M opens the map list, and solo a choice
## changes it now. The server's half (the owner's flag, the vote) is in `dedicated` and dot-vote.
func _test_the_map_menu() -> void:
	_section("M opens the map list, and solo a choice changes it")
	var game := await _world(func(c: MmConfig) -> void: c.map_ids = PackedStringArray())
	var _a := game.add_player(&"u1", "Ada")
	var _b := game.add_player(&"u2", "Bo")
	game.start()
	await _step(game, 4)
	var settings := MmSettings.new()
	add_child(settings)
	var _built: DotResult = settings.setup(DotSettingsStoreMemory.new())
	var keys: DotMenuBindings = settings.bindings
	_check(keys.key_for(DotMenuBindings.MAPS_ACTION) == "M" and keys.defaults_on("M").size() == 1,
		"the map menu is on M, and nothing else in the table defaults to M",
		str(keys.defaults_on("M").map(func(r: Dictionary) -> String: return str(r["label"]))))
	var rows: Array = game.map_rows()
	_check(rows.size() > 1 and rows.filter(func(r: Dictionary) -> bool: return bool(r["current"])).size() == 1,
		"there is more than one to choose, the one playing marked", "%d" % rows.size())
	var _maps := settings.use_maps(game.map_rows, game.change_map_now)
	var m := InputEventKey.new()
	m.physical_keycode = KEY_M
	m.keycode = KEY_M
	m.pressed = true
	_check(settings.menu.handle_event(m) and settings.menu.picker.is_open(), "M opens the picker")
	var wanted: StringName = &""
	var key := KEY_NONE
	for row in range(1, DotMenuPicker.PAGE_SIZE + 1):
		var it: Variant = settings.menu.picker.at_row(row)
		if it is Dictionary and not bool((it as Dictionary)["current"]):
			wanted = StringName(str((it as Dictionary)["id"]))
			key = KEY_0 + row
			break
	var digit := InputEventKey.new()
	digit.physical_keycode = key
	digit.keycode = key
	digit.pressed = true
	var _k := settings.menu.handle_event(digit)
	for _i in 4:
		await get_tree().physics_frame
	_check(wanted != &"" and StringName(str(game.map_doc.get("id", ""))) == wanted, "choosing one changes to it now", "%s, now %s" % [wanted, StringName(str(game.map_doc.get("id", "")))])
	_check(not settings.menu.picker.is_open(), "and the picker is closed")
	settings.queue_free()
	await get_tree().process_frame
	_finished()


func _test_fall_damage() -> void:
	_section("sv_falldamage: a hard landing costs health, a short drop and the cvar off cost none")
	var game := await _round(FOUR)
	var me = _p(game, &"u1m")
	_check(game.fall_rules.enabled and me.get_node_or_null("FallDamage") != null, "on in this game, a component per player")
	var floor_at: Vector3 = me.controller.state.position
	var hurt := {}
	for case in [["high", 14.0, true], ["short", 0.6, true], ["off", 14.0, false]]:
		game.fall_rules.enabled = case[2]
		me.health.health = me.health.max_health
		me.place_at(floor_at + Vector3(0.0, case[1], 0.0), 0.0)
		await _step(game, TICK_RATE * 2)
		hurt[case[0]] = me.health.max_health - me.health.health
	_check(hurt["high"] > 0.0, "a drop from 14 m hurts", "lost %.1f" % hurt["high"])
	_check(hurt["short"] == 0.0, "a short drop does not", "lost %.1f" % hurt["short"])
	_check(hurt["off"] == 0.0, "cvar off: a 14 m drop does not hurt", "lost %.1f" % hurt["off"])
	_finished()



## A figure stepped under a slowed time scale advances by game time, not by the wall clock.
func _test_figure_game_time() -> void:
	_section("a figure's clip advances by game time under slow motion")
	var figure = (load("res://game/mm_figure.gd") as GDScript).new()
	add_child(figure)
	figure.build(1.8, "a", Color.WHITE)
	var anim: AnimationPlayer = figure.person.find_children("*", "AnimationPlayer", true, false)[0]
	var old := Engine.time_scale
	Engine.time_scale = 0.05
	figure.pose(Vector3.ZERO, 0.0, 3.0)
	await get_tree().process_frame
	figure.pose(Vector3.ZERO, 0.0, 3.0)
	var from := anim.current_animation_position
	var wall := Time.get_ticks_usec()
	for i in 6:
		await get_tree().process_frame
		figure.pose(Vector3.ZERO, 0.0, 3.0)
	var wall_s := (Time.get_ticks_usec() - wall) / 1e6
	var moved := absf(anim.current_animation_position - from)
	Engine.time_scale = old
	figure.queue_free()
	_check(moved > 0.0 and moved < wall_s * 0.5,
		"at 0.05x time the clip moves a fraction of the wall time", "clip %.4f s over %.4f s wall" % [moved, wall_s])
	_finished()
