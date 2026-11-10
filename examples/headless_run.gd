extends "headless_run_client.gd"

const MmCatalogue := preload("../game/mm_catalogue.gd")
const MmKillPov := preload("../game/mm_kill_pov.gd")
const MmProps := preload("../game/mm_props.gd")

## The simulation, headless: the prop catalogue and the map documents, the draw of the roles,
## the grace, the murderer's weapon (drawn, holstered, its reach, its cone, walls), the gun (a
## hit, a miss that drops it, an innocent shot, who may pick it up), the blood, how a round is
## decided, falls, joiners, the numbers dot-stats keeps, the bots' chat, doors, toys, the
## client offline, and the help and map menus.
##
## [b]Counts sections AND checks, and the second is the one that matters.[/b] A script error
## inside a section aborts that function and the section counter is already satisfied,
## because the section announced itself on the way in. dot-settings has the story.
##
## Every number about the map here is the built-in practice house's
## ([method MmCatalogue.practice]): the wall between the rooms at x 0 with its door at
## z -1..0.8, the kitchen east of it, the living room west, the garden past x 10.

const SECTIONS := 29

const CHECKS := 207

## The first chair round the kitchen table in the practice house: where it stands.
const CHAIR_AT := Vector3(3.6, 0.0, 1.2)


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("murder headless run")
	print("")

	_test_config()
	_test_catalogue()
	_test_documents()
	await _test_world_builds()
	await _test_the_draw()
	await _test_the_grace()
	await _test_draw_and_holster()
	await _test_the_stab()
	await _test_the_hit()
	await _test_the_miss()
	await _test_an_innocent()
	await _test_blood()
	await _test_free_roam()
	await _test_the_flashlight()
	await _test_the_round()
	await _test_falls()
	await _test_fall_damage()
	await _test_joiners()
	await _test_progress()
	_test_bot_chat()
	await _test_bots()
	await _test_doors()
	await _test_toys()
	await _test_the_client()
	await _test_help_and_menu()
	await _test_the_map_menu()
	await _test_gore()
	_test_weapons_table()
	await _test_figure_game_time()

	for world in _worlds.duplicate():
		await _dispose(world)

	await get_tree().process_frame

	_report_sections(_sections_entered, _sections_finished, SECTIONS, CHECKS)


func _test_config() -> void:
	_section("the configuration")
	var config := MmConfig.new()
	_check(config.validate().ok, "the defaults validate")
	_check(config.murderers_for(1) == 0, "one person is not a round")
	_check(config.murderers_for(2) == 1 and config.murderers_for(12) == 1, "one murderer up to twelve players")
	_check(config.murderers_for(13) == 2 and config.murderers_for(64) == config.max_murderers,
		"two from thirteen, and never more than the most")
	_check(config.gunners_for(2, 1) == 1 and config.gunners_for(8, 7) == 1 and config.gunners_for(2, 0) == 0,
		"one gunner out of the bystanders, none when there are none")
	config.min_murderers = 3
	config.max_murderers = 2
	_check(not config.validate().ok, "more murderers at least than at most is refused")
	_finished()


func _test_weapons_table() -> void:
	_section("the murderer's weapons are a table, and an unknown id is the knife")
	var bad := 0
	for id in MmWeapons.ids():
		var e := MmWeapons.entry(id)
		if float(e["reach"]) <= 1.0 or float(e["cooldown"]) <= 0.0 or (e["parts"] as Array).is_empty():
			bad += 1
	_check(MmWeapons.ids().size() >= 5 and bad == 0, "every weapon has a reach, a cooldown and a shape (%d)" % MmWeapons.ids().size())
	_check(not MmWeapons.known(&"spoon") and MmWeapons.entry(&"spoon")["name"] == "Knife", "a weapon nobody knows is the knife")
	var held := MmWeapons.build(MmWeapons.entry(&"axe")["parts"])
	_check(held.get_child_count() == 2, "a shape builds as its boxes")
	held.free()
	var gunner := Node.new()
	gunner.set_script(null)
	_check(MmKillPov.weapon_name(MmKillPov.hash_of(&"gun")) != "" and MmKillPov.weapon_name(MmKillPov.hash_of(&"axe")) == String(MmWeapons.entry(&"axe")["name"]),
		"the killer's screen names the gun and a blade from the recorded hash")
	_check(MmKillPov.aux_of(gunner) == [0.0] and MmKillPov.weapon_name(0.0) == "", "nothing out records nothing")
	gunner.free()
	_finished()


func _test_catalogue() -> void:
	_section("the prop catalogue is what the models measure")
	var props := MmProps.new()
	var count := props.load_file()
	_check(count > 100, "it reads (%d props)" % count)
	_check((props.size_of(&"furniture_chair") - Vector3(0.46, 1.08, 0.46)).length() < 0.01,
		"a chair is the size measured", str(props.size_of(&"furniture_chair")))

	var bad := 0
	for id in props.order:
		var e := props.entry(id)
		if not ResourceLoader.exists("res://" + str(e["model"])):
			bad += 1
	_check(bad == 0, "every prop's model is in the game", "%d missing" % bad)

	# Part-shaped collision (props/pieces.json, dot-props' DotPropPieces): a tree is pieces, a
	# fridge stays its box, and no piece reaches outside the prop's measured box by more than
	# the decomposition's slack, or a player would bump into air beside the model.
	var outside := PackedStringArray()
	var shaped := 0
	for id in props.order:
		var pieces := props.pieces_of(id)
		if pieces.is_empty():
			continue
		shaped += 1
		var size := props.size_of(id)
		var box := AABB(Vector3(-size.x * 0.5, 0.0, -size.z * 0.5), size).grow(0.08)
		var inner := DotPropPieces.bounds(pieces)
		if not box.encloses(inner):
			outside.append(String(id))
	_check(not props.pieces_of(&"nature_tree_default").is_empty() and props.pieces_of(&"furniture_kitchen_fridge").is_empty()
		and props.shapes_of(&"nature_tree_default").size() == props.pieces_of(&"nature_tree_default").size(),
		"a tree collides as pieces (%d props shaped) and a fridge as its box" % shaped)
	_check(outside.is_empty(), "every prop's pieces stay inside its measured box", ", ".join(outside))
	_finished()


func _test_documents() -> void:
	_section("a map is a document, and a bad one is refused with a reason")
	var practice := MmCatalogue.practice()
	_check(str(practice.get("id", "")) == "mm_practice", "the practice house validates")
	_check(practice["boxes"][0]["at"] is Array, "positions are normalised to plain arrays")
	_check(((practice["spawns"] as Dictionary)["players"] as Array).size() >= 8, "its spawns are one group, the players'")

	var props := MmProps.new()
	var _n := props.load_file()
	var unknown := 0
	for prop: Dictionary in practice["props"]:
		if not props.has(StringName(str(prop["id"]))):
			unknown += 1
	_check(unknown == 0, "every prop it names is in the catalogue")

	var bare := practice.duplicate(true)
	bare["spawns"] = {"players": []}
	var refused := MmMapDoc.validate(bare)
	_check(not refused.ok and str(refused.error).contains("players"), "a map with no spawns is refused, saying so")

	var wrong := practice.duplicate(true)
	wrong["kind"] = "prophunt_map"
	_check(not MmMapDoc.validate(wrong).ok, "a document of another kind is refused as it stands")

	var encoded := MmMapDoc.encode(practice)
	var decoded := MmMapDoc.decode(encoded)
	_check(decoded.ok and MmMapDoc.digest(decoded.value) == MmMapDoc.digest(practice),
		"it survives the wire whole (%d bytes)" % encoded.size())

	var torn := encoded.slice(0, encoded.size() - 3)
	_check(not MmMapDoc.decode(torn).ok, "a torn one is refused rather than half built")
	_finished()


func _test_world_builds() -> void:
	_section("the practice house builds, solid where it should be")
	var game := await _world()
	_check(game.map.id() == &"mm_practice", "the map is built")
	_check(game.map.props.size() == (game.map_doc["props"] as Array).size(), "every prop is in it (%d)" % game.map.props.size())

	var space := game.get_world_3d().direct_space_state
	var clear := 0
	var floored := 0
	var spawns: Array = (game.map_doc["spawns"] as Dictionary)["players"]

	for spawn: Dictionary in spawns:
		var at := MmMapDoc.v3(spawn["at"])
		var hull := CapsuleShape3D.new()
		hull.radius = 0.35
		hull.height = 1.8
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = hull
		query.transform = Transform3D(Basis.IDENTITY, at + Vector3(0.0, 0.95, 0.0))
		query.collision_mask = game.physics.collision_mask(&"player")
		if space.intersect_shape(query, 1).is_empty():
			clear += 1
		var ray := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 0.5, at + Vector3.DOWN * 1.0)
		if not space.intersect_ray(ray).is_empty():
			floored += 1

	_check(clear == spawns.size(), "nobody starts inside anything (%d of %d clear)" % [clear, spawns.size()])
	_check(floored == spawns.size(), "and every spawn has a floor under it (%d of %d)" % [floored, spawns.size()])

	var chair := _prop_near(game, CHAIR_AT)
	_check(chair >= 0 and game.map.prop_id(chair) == &"furniture_chair", "the chair is where the document puts it")
	_finished()


func _test_the_draw() -> void:
	_section("the draw: one murderer, one gun, never the same murderer twice running")
	var game := await _world(func(c: MmConfig) -> void: c.grace_seconds = 0.25)
	var ids: Array[StringName] = []
	var drawn: Array = []
	game.role_drawn.connect(func(id: StringName, side: int, gun: bool) -> void: drawn.append([id, side, gun]))
	for i in range(6):
		var p := game.add_player(StringName("u%d" % (100 + i)), "P%d" % i)
		ids.append(p.player_id)

	game.start()
	await _step(game, 2)
	_check(game.players_on(MmGame.MURDERERS).size() == 1 and _gunners(game).size() == 1,
		"six players: one murderer and one gunner", "%d %d" % [game.players_on(MmGame.MURDERERS).size(), _gunners(game).size()])
	_check(game.team_of(_gunners(game)[0].player_id) == MmGame.BYSTANDERS, "and the gunner is a bystander")
	_check(drawn.size() == 6, "everybody was told their role, once", str(drawn.size()))
	_check(game.players.values().all(func(p: MmPlayer) -> bool: return p.weapon_id == game.weapon_id()),
		"everybody's figure knows the server's weapon")

	var murderers: Array[StringName] = []
	var twice := false
	for round_index in range(6):
		var now: StringName = game.players_on(MmGame.MURDERERS)[0].player_id
		if not murderers.is_empty() and murderers[-1] == now:
			twice = true
		murderers.append(now)
		await _end_round(game)
	_check(not twice, "nobody is the murderer two rounds running", str(murderers))
	var shirts := {}
	for id in ids:
		shirts[(game.players[id] as MmPlayer).shirt] = true
	_check(shirts.size() == ids.size(), "six people, six shirts")

	game.forced_roles = {ids[4]: &"murderer", ids[2]: &"gunner"}
	await _end_round(game)
	_check(game.team_of(ids[4]) == MmGame.MURDERERS and (game.players[ids[2]] as MmPlayer).has_gun and _gunners(game).size() == 1,
		"roles forced by a test or an operator are what they say")
	_finished()


func _test_the_grace() -> void:
	_section("the grace: nobody can draw or shoot until it is over")
	var refusals: Array = []
	var game := await _round(FOUR, func(c: MmConfig) -> void: c.grace_seconds = 1.0, false)
	game.refused.connect(func(id: StringName, why: String) -> void: refusals.append([id, why]))
	var m := _p(game, &"u1m")
	var g := _p(game, &"u2g")
	_check(game.phase == MmGame.Phase.GRACE, "a round starts with the grace")
	_check(not game.set_weapon_drawn(m.player_id, true) and not m.weapon_drawn and refusals.size() == 1
		and str(refusals[0][1]).contains("knife"), "the murderer cannot draw yet, and is told why", str(refusals))
	_check(not game.attack_now(g.player_id) and g.has_gun, "the gun does not fire yet")
	_check(game.seconds_left() > 0.5 and game.seconds_left() <= 1.0, "the clock counts the grace down", "%.2f" % game.seconds_left())
	await _wait_for(game, MmGame.Phase.PLAY)
	_check(game.phase == MmGame.Phase.PLAY and game.set_weapon_drawn(m.player_id, true), "after it, they can")
	_check(game.seconds_left() > game.round_limit() - 0.5, "and the clock is the round's")
	_finished()


func _test_draw_and_holster() -> void:
	_section("the murderer's weapon: the holster key draws and puts it away, nobody else has one")
	var game := await _round(FOUR)
	var m := _p(game, &"u1m")
	var b := _p(game, &"u3b")
	var seen: Array = []
	game.weapon_changed.connect(func(id: StringName, drawn: bool) -> void: seen.append([id, drawn]))
	_check(m.armed() == MmPlayer.ARMED_NONE, "a round starts with it holstered")
	await _press_key(game, m, &"holster")
	_check(m.weapon_drawn and m.armed() == MmPlayer.ARMED_WEAPON and seen == [[m.player_id, true]], "the key draws it")
	await _press_key(game, m, &"holster")
	_check(not m.weapon_drawn and seen.size() == 2, "and puts it away again")
	await _press_key(game, b, &"holster")
	_check(not b.weapon_drawn and not game.set_weapon_drawn(b.player_id, true), "a bystander has nothing to draw")
	_finished()


func _test_the_stab() -> void:
	_section("a stab: in reach, in front, not through a wall, and then the cooldown")
	var game := await _round(FOUR)
	var m := _p(game, &"u1m")
	var b := _p(game, &"u3b")
	var other := _p(game, &"u4b")
	_park(game, [&"u2g", &"u4b"])

	m.place_at(KITCHEN_A, 0.0)
	b.place_at(KITCHEN_A + Vector3(2.8, 0.0, 0.0), 0.0)
	await _step(game, 2)
	_aim(m, _chest(b))
	_check(game.set_weapon_drawn(m.player_id, true) and not game.attack_now(m.player_id),
		"a weapon just drawn does not land yet (the beat to run in)")
	m.drawn_at = game._now() - 1.0
	_check(game.attack_now(m.player_id) and b.is_alive() and m.attacks == 1, "a swing at somebody out of reach is a swing at nobody")
	_check(not game.attack_now(m.player_id), "and costs the cooldown")
	m.ready_at = 0.0

	b.place_at(KITCHEN_A + Vector3(-1.2, 0.0, 0.0), 0.0)
	await _step(game, 2)
	_check(game.stab_target(m) == null, "nobody behind the murderer is in the cone")

	m.place_at(Vector3(0.6, 0.05, -3.0), 0.0)
	b.place_at(Vector3(-0.6, 0.05, -3.0), 0.0)
	await _step(game, 2)
	_aim(m, _chest(b))
	_check(game.stab_target(m) == null, "a metre away through the wall is out of reach")

	b.place_at(KITCHEN_A + Vector3(1.3, 0.0, 0.0), 0.0)
	m.place_at(KITCHEN_A, 0.0)
	await _step(game, 2)
	_aim(m, _chest(b))
	var died: Array = []
	game.player_died.connect(func(id: StringName, by: StringName, why: StringName) -> void: died.append([id, by, why]))
	await _press_key(game, m, &"attack")
	_check(not b.is_alive() and died.size() == 1 and died[0][2] == MmGame.DIED_STABBED,
		"the attack key in reach and in front stabs them", str(died))
	_check(m.kills == 1 and m.points >= game.config.kill_points, "the murderer is paid for it")
	_check(game.stab_target(m) == null or game.stab_target(m) == other, "the dead are not stabbed twice")
	_check(game.players_on(MmGame.MURDERERS).size() == 1 and game.phase == MmGame.Phase.PLAY,
		"and the round goes on while bystanders are left")
	_finished()


func _test_the_hit() -> void:
	_section("the gun: a shot at the murderer kills them and the bystanders win")
	var game := await _round(FOUR)
	var winners: Array = []
	var named: Array = []
	game.round_over.connect(func(_n: int, winner: int, _why: String) -> void:
		winners.append(winner)
		named.append_array(game.revealed))
	var m := _p(game, &"u1m")
	var g := _p(game, &"u2g")
	_park(game, [&"u3b", &"u4b"])
	var points := g.points
	g.place_at(KITCHEN_A, 0.0)
	m.place_at(KITCHEN_B, 0.0)
	await _step(game, 2)
	_aim(g, _chest(m))
	var shots: Array = []
	game.shot.connect(func(by: StringName, _from: Vector3, _to: Vector3, hit: StringName) -> void: shots.append([by, hit]))
	_check(game.attack_now(g.player_id) and not m.is_alive(), "the gunner shoots the murderer dead")
	_check(shots == [[g.player_id, m.player_id]] and g.has_gun, "the shot is heard as a hit, and the gun is kept")
	await _step(game, 4)
	_check(winners == [MmGame.BYSTANDERS], "the murderer dead is the bystanders' round")
	_check(g.points >= points + game.config.hero_points + game.config.winner_points, "and the hero is paid for it")
	# Read when the round ends: with intermission 0 the next draw clears it on the same tick.
	_check(named.has(m.display_name), "the murderer's name is out at the end", str(named))
	_finished()


func _test_the_miss() -> void:
	_section("a miss drops the gun, and only a bystander who has not missed may take it")
	var game := await _round(FOUR)
	var m := _p(game, &"u1m")
	var g := _p(game, &"u2g")
	var b := _p(game, &"u3b")
	_park(game, [&"u4b"])
	g.place_at(KITCHEN_A, 0.0)
	m.place_at(LIVING, 0.0)
	b.place_at(KITCHEN_B + Vector3(0.0, 0.0, 3.0), 0.0)
	await _step(game, 2)
	_aim(g, KITCHEN_A + Vector3(0.0, 1.6, -4.0))
	var dropped: Array = []
	var taken: Array = []
	game.gun_dropped.connect(func(drop_id: int, at: Vector3) -> void: dropped.append([drop_id, at]))
	game.gun_taken.connect(func(drop_id: int, by: StringName) -> void: taken.append([drop_id, by]))
	_check(game.attack_now(g.player_id) and not g.has_gun and g.gun_banned, "a miss costs the gun")
	_check(dropped.size() == 1 and (dropped[0][1] as Vector3).distance_to(KITCHEN_A) < 0.3 and game.gun_drops.size() == 1,
		"it lies where the shooter stood")
	await _step(game, 4)
	_check(game.gun_drops.size() == 1 and not g.has_gun, "the shooter standing on it does not get it back")

	m.place_at(KITCHEN_A, 0.0)
	await _step(game, 4)
	_check(game.gun_drops.size() == 1 and not m.has_gun, "the murderer walking over it cannot take it")

	m.place_at(LIVING, 0.0)
	b.place_at(KITCHEN_A + Vector3(0.4, 0.0, 0.0), 0.0)
	await _step(game, 2)
	_check(b.has_gun and game.gun_drops.is_empty() and taken.size() == 1 and taken[0][1] == b.player_id,
		"a bystander who walks onto it has it now")
	_check(not game.attack_now(b.player_id), "and has a moment before it fires")
	_check(not game.may_pick_up(m) and not game.may_pick_up(g) and not game.may_pick_up(b), "nobody may hold two, or hold it again")

	b.place_at(KITCHEN_A, 0.0)
	await _step(game, 2)
	game._kill(b, m, MmGame.DIED_STABBED)
	_check(game.gun_drops.size() == 1 and not b.has_gun, "a gunner killed drops it too")
	_finished()


func _test_free_roam() -> void:
	_section("whoever is out may free-roam by default, unless an operator says otherwise")
	_check(MmConfig.new().spectate_camera == 0, "the config lets anybody be watched, so a free camera is not ruled out")
	var game := await _round(FOUR)
	var m := _p(game, &"u1m")
	var b := _p(game, &"u3b")
	var id := b.player_id
	_park(game, [&"u2g", &"u4b"])
	_check(game.spectate_rules.roaming_permitted() and game.spectate.manager.rules == game.spectate_rules,
		"the game's rules allow roaming and are the manager's own")
	game._kill(b, m, MmGame.DIED_STABBED)
	game.spectate.manager.set_mode(String(id), DotSpectatorView.Mode.CHASE)
	_check(not b.is_alive() and game.spectate.can_roam(id), "somebody stabbed sits out, and may roam")
	_check(game.spectate.toggle_roam(id).ok and game.spectate.is_roaming(id), "the key enters the free camera")
	var cam := DotSpectatorFreeCam.new()
	cam.rules = game.spectate_rules
	cam.seed_from(Transform3D(Basis.IDENTITY, Vector3(0, 2, 0)))
	var pose := cam.step(Vector3(0, 0, 1), false, false, 0.5)
	_check(pose.origin.distance_to(Vector3(0, 2, 0)) > 0.5, "and flying moves it", str(pose.origin))
	_check(game.spectate.manager.move_free(String(id), pose.origin, pose.basis).ok
		and game.spectate.camera_for(id).origin.is_equal_approx(pose.origin), "the manager keeps where it is")
	_check(game.spectate.toggle_roam(id).ok and not game.spectate.is_roaming(id), "the key again goes back to a player")

	var _off := game.spectate_rules.set_cvar("mp_freeroam", "0")
	var refused := game.spectate.toggle_roam(id)
	_check(not refused.ok and refused.error.code == DotError.CODE_FORBIDDEN and not game.spectate.is_roaming(id),
		"mp_freeroam 0 refuses it")
	var _on := game.spectate_rules.set_cvar("mp_freeroam", "1")
	var _own := game.spectate_rules.set_cvar("mp_forcecamera", "1")
	_check(not game.spectate.toggle_roam(id).ok and not game.spectate.is_roaming(id), "mp_forcecamera 1 refuses it")
	var _free := game.spectate_rules.set_cvar("mp_forcecamera", "0")

	var _in := game.spectate.toggle_roam(id)
	var _gone := game.spectate_rules.set_cvar("mp_freeroam", "0")
	game.spectate.advance(game._tick + 1)
	_check(not game.spectate.is_roaming(id), "switching mp_freeroam off mid-roam puts the roamer back on a player")
	_check(game.spectate is DotSpectatorHost and game.spectate.guard_roam, "spectating is dot-spectate's host, roaming guarded")
	var playing := StringName("nobody-out")
	_check(not game.spectate.can_roam(playing) and game.spectate.toggle_roam(playing).error.code == DotError.CODE_STATE,
		"somebody who is playing may not roam, and is told they are playing")

	var restricted := await _world(func(c: MmConfig) -> void:
		c.spectate_camera = 2)
	_check(restricted.spectate_rules.force_camera == 2 and not restricted.spectate_rules.roaming_permitted(),
		"a config that restricts the camera turns roaming off")
	_finished()


func _test_an_innocent() -> void:
	_section("shooting an innocent costs the gun for the round")
	var game := await _round(FOUR)
	var g := _p(game, &"u2g")
	var b := _p(game, &"u3b")
	_park(game, [&"u1m", &"u4b"])
	g.place_at(KITCHEN_A, 0.0)
	b.place_at(KITCHEN_B, 0.0)
	await _step(game, 2)
	_aim(g, _chest(b))
	_check(game.attack_now(g.player_id) and not b.is_alive(), "the shot kills whoever it hits")
	_check(not g.has_gun and g.gun_banned and game.gun_drops.size() == 1 and g.is_alive(),
		"an innocent shot drops the gun, bans the shooter, and by default they live")
	_check(game.phase == MmGame.Phase.PLAY, "and the round goes on")
	_finished()


func _test_blood() -> void:
	_section("blood comes on the murderer near the end, in stages, and with each kill")
	var game := await _round(FOUR, func(c: MmConfig) -> void:
		c.round_seconds = 180.0
		c.blood_seconds = 60.0
		c.blood_stages = 4)
	var m := _p(game, &"u1m")
	await _step(game, 2)
	_check(m.blood == 0, "none early in the round")
	game.play_elapsed = 121.0
	await _step(game, 1)
	_check(m.blood == 1, "the first stage a minute from the end", str(m.blood))
	game.play_elapsed = 179.0
	await _step(game, 1)
	_check(m.blood == 4, "all of it at the buzzer", str(m.blood))
	_check(game.players_on(MmGame.BYSTANDERS).all(func(p: MmPlayer) -> bool: return p.blood == 0), "and never on anybody else")
	game.play_elapsed = 100.0
	game._kill(_p(game, &"u3b"), m, MmGame.DIED_STABBED)
	await _step(game, 1)
	_check(m.blood == 1, "a kill is a stage of its own, before the clock's", str(m.blood))
	_finished()


func _test_the_round() -> void:
	_section("a round: the murderer kills everybody, or the clock runs out")
	var game := await _round(FOUR)
	var winners: Array = []
	game.round_over.connect(func(_n: int, winner: int, _why: String) -> void: winners.append(winner))
	var m := _p(game, &"u1m")
	var points := m.points
	for id: StringName in [&"u2g", &"u3b", &"u4b"]:
		game._kill(_p(game, id), m, MmGame.DIED_STABBED)
	await _step(game, 4)
	_check(winners == [MmGame.MURDERERS], "everybody else dead is the murderer's round")
	_check(m.points >= points + game.config.winner_points + 3 * game.config.kill_points,
		"and the murderer is paid for each kill and for winning")

	await _wait_for(game, MmGame.Phase.PLAY)
	_check(game.players_on(MmGame.MURDERERS).size() == 1 and game.alive_total() == 4, "the next round starts everybody alive")
	var survivor := _p(game, &"u3b")
	var kept := survivor.points
	game.play_elapsed = game.round_limit() - 0.05
	await _step(game, 6)
	_check(winners.size() == 2 and winners[1] == MmGame.BYSTANDERS, "the clock is the bystanders' round")
	_check(survivor.points >= kept + game.config.winner_points + game.config.survive_points,
		"and a bystander alive at the end is paid for winning and for surviving")
	_finished()


func _test_falls() -> void:
	_section("a fall off the map is a respawn, not a death")
	var game := await _round(FOUR)
	var g := _p(game, &"u2g")
	var m := _p(game, &"u1m")
	g.place_at(Vector3(0.0, game.map.kill_height() - 5.0, 0.0), 0.0)
	await _step(game, 3)
	_check(g.is_alive() and g.controller.state.position.y > game.map.kill_height() + 1.0 and g.has_gun,
		"a gunner who falls is back on their feet at a spawn, gun in hand")
	m.place_at(Vector3(0.0, game.map.kill_height() - 5.0, 0.0), 0.0)
	await _step(game, 3)
	_check(m.is_alive() and game.phase == MmGame.Phase.PLAY, "a murderer who falls has not lost the round")
	_check(_death_sounds_listed(), "the death sounds are in the game's catalogue")
	_finished()


func _test_joiners() -> void:
	_section("somebody who joins mid-round watches until the next")
	var game := await _round(FOUR, func(c: MmConfig) -> void: c.grace_seconds = 2.0, false)
	var early := game.add_player(&"u5e", "Early")
	_check(not early.watching and game.team_of(early.player_id) == MmGame.BYSTANDERS, "joining in the grace plays, as a bystander")
	await _wait_for(game, MmGame.Phase.PLAY)
	var total := game.alive_total()
	var late := game.add_player(&"u6l", "Late")
	_check(late.watching and game.alive_total() == total and not late.has_gun, "joining in the round proper watches, and is not counted")
	_check(game.stab_target(_p(game, &"u1m")) != late, "and cannot be stabbed")
	await _end_round(game)
	_check(not late.watching and late.is_alive(), "and plays the next round")
	_finished()


func _death_sounds_listed() -> bool:
	var catalogue: DotAudioCatalogue = (load("res://game/mm_audio.gd") as GDScript).call("sound_catalogue")
	for row: Dictionary in DotPlayerDeathSounds.rows():
		if catalogue.find(row["id"]) == null:
			return false
	return not DotPlayerDeathSounds.rows().is_empty()


## The practice house's garden door: shut, in the east wall, swinging out into the garden.
const GARDEN_DOOR := 1
const GARDEN_DOOR_AT := Vector3(10.1, 1.1, 0.0)


func _test_doors() -> void:
	_section("a door opens with the use key, stops what a wall stops, and never shuts on anybody")
	var game := await _round(FOUR)
	var doors := game.map.doors
	var killer := _p(game, &"u1m")
	var walker := _p(game, &"u3b")
	_p(game, &"u4b").place_at(Vector3(-6.0, 0.05, 5.0), 0.0)
	_p(game, &"u2g").place_at(Vector3(-6.0, 0.05, 4.0), 0.0)
	killer.place_at(Vector3(-6.0, 0.05, -5.0), 0.0)
	var used: Array = []
	var refusals: Array = []
	game.door_used.connect(func(index: int, open: bool, _flip: bool, _tick: int, by: StringName) -> void:
		used.append([index, open, by]))
	game.refused.connect(func(id: StringName, why: String) -> void: refusals.append([id, why]))

	# From inside: the use key, looking at it.
	walker.place_at(Vector3(8.6, 0.05, 0.0), -90.0)
	_aim(walker, GARDEN_DOOR_AT)
	await _press(game, walker)
	_check(doors.is_open(GARDEN_DOOR) and used.size() == 1 and used[0][2] == walker.player_id,
		"the use key opens the door in front of them", str(used))
	await _step(game, TICK_RATE)
	var panel := (doors.doors[GARDEN_DOOR]["body"] as Node3D).global_position
	_check(panel.x > GARDEN_DOOR_AT.x + 0.4 and doors.flips_for(GARDEN_DOOR, Vector3(12.0, 1.6, 0.4)),
		"it swings away from whoever opened it, whichever side they are on", "panel at %s" % panel.snapped(Vector3.ONE * 0.1))

	for i in range(TICK_RATE * 2):
		_drive(walker, Vector2(0.0, 1.0))
		await _step(game, 1)
	_check(walker.controller.state.position.x > 11.0, "an open door is a way through",
		"x %.2f" % walker.controller.state.position.x)

	# From the garden, out of its way: shut it.
	walker.place_at(Vector3(12.8, 0.05, 0.4), 90.0)
	_aim(walker, panel)
	await _press(game, walker)
	await _step(game, TICK_RATE)
	_check(not doors.is_open(GARDEN_DOOR) and not doors.moving(GARDEN_DOOR, game.current_tick()),
		"and the use key shuts it again", str(used))

	walker.place_at(Vector3(11.5, 0.05, 0.0), 90.0)
	for i in range(TICK_RATE * 2):
		_drive(walker, Vector2(0.0, 1.0))
		await _step(game, 1)
	_check(walker.controller.state.position.x > GARDEN_DOOR_AT.x, "a shut door stops a body, as a wall does",
		"x %.2f" % walker.controller.state.position.x)

	# A metre apart with the door between: no stab, as through a wall.
	walker.place_at(Vector3(10.65, 0.05, 0.0), 90.0)
	killer.place_at(Vector3(9.55, 0.05, 0.0), -90.0)
	await _step(game, 4)
	_aim(killer, _chest(walker))
	var _drawn := game.set_weapon_drawn(killer.player_id, true)
	killer.drawn_at = game._now() - 1.0
	var _swung := game.attack_now(killer.player_id)
	_check(walker.is_alive(), "and a stab through it")
	var _away := game.set_weapon_drawn(killer.player_id, false)

	# The killer opens it, into the walker standing against it: refused, and the door stays.
	_aim(killer, GARDEN_DOOR_AT)
	var before := used.size()
	await _press(game, killer)
	_check(not doors.is_open(GARDEN_DOOR) and used.size() == before and not refusals.is_empty()
		and refusals[-1][0] == killer.player_id, "a door does not open into somebody", str(refusals))

	walker.place_at(Vector3(16.0, 0.05, 6.0), 0.0)
	await _press(game, killer)
	await _step(game, 4)

	await _end_round(game)
	_check(not doors.is_open(GARDEN_DOOR) and doors.is_open(0), "a new round puts every door back as the map has it",
		"garden %s, kitchen %s" % [doors.is_open(GARDEN_DOOR), doors.is_open(0)])

	# A stand-in walking out to the garden opens the door on its way.
	var bot := game.add_player(&"u990", "DoorBot", MmGame.BYSTANDERS)
	bot.is_bot = true
	bot.place_at(Vector3(8.4, 0.05, 0.2), -90.0)
	var walk: Dictionary = game.bots._state_of(bot)
	walk["said_start"] = true
	walk["goal"] = Vector3(16.0, 0.0, 0.2)
	walk["mode"] = &"company"
	walk["picked_at"] = game.bots.now() + 30.0
	for i in range(TICK_RATE * 4):
		await _step(game, 1)
		if bot.controller.state.position.x > 12.0:
			break
	_check(bot.controller.state.position.x > 12.0, "a stand-in opens a shut door it walks into",
		"at %s; the door is %s" % [bot.controller.state.position.snapped(Vector3.ONE * 0.1), "open" if doors.is_open(GARDEN_DOOR) else "shut"])
	_finished()


## The practice house's garden toys (dot-props'): the beach ball at 16.5, -2.5, the football at
## 14, 3, the tyre, and the lamp (3) on its switch (4) at 12, -3.
func _test_toys() -> void:
	_section("toys: walked into, kicked, switched, bounced on, home again at the next round")
	var game := await _round(FOUR)
	var toys := game.map.toys
	var walker := _p(game, &"u3b")
	_park(game, [&"u1m", &"u2g", &"u4b"])

	# A person is not a rigid body: walking into the ball is the game's push, every tick.
	var ball := toys.toy(0)
	var start := ball.body.global_position
	walker.place_at(Vector3(13.0, 0.05, -2.5), -90.0)
	for _i in range(TICK_RATE):
		_drive(walker, Vector2(0.0, 1.0))
		await _step(game, 1)
	_check(ball.body.global_position.x > start.x + 0.8, "walking into the beach ball sends it on ahead",
		"%.2f m" % (ball.body.global_position.x - start.x))

	var football := toys.toy(1)
	var kick_from := football.body.global_position
	walker.place_at(kick_from + Vector3(0.0, 0.05, 1.3), 0.0)
	_drive(walker, Vector2.ZERO)
	await _step(game, 2)
	_aim(walker, kick_from)
	_check(game.toy_aimed(walker) == football.index and toys.toy(game.toy_aimed(walker)).prompt() == "Kick the football",
		"looking at the football, the use key's prompt says so", toys.toy(game.toy_aimed(walker)).prompt() if game.toy_aimed(walker) >= 0 else "nothing aimed")
	await _press(game, walker)
	await _step(game, TICK_RATE / 2)
	_check(football.body.global_position.distance_to(kick_from) > 1.5, "and the use key kicks it",
		"%.2f m" % football.body.global_position.distance_to(kick_from))

	var lamp := toys.toy(3)
	var switch := toys.toy(4)
	var was_lit := lamp.on
	walker.place_at(switch.global_position + Vector3(0.0, 0.05, 1.2), 0.0)
	await _step(game, 2)
	_aim(walker, switch.global_position + Vector3(0.0, 0.9, 0.0))
	await _press(game, walker)
	_check(lamp.on != was_lit and switch.count == 1, "the switch turns the lamp", "lit %s" % lamp.on)
	var freed: Dictionary = (load("res://examples/toy_freed_prompt.gd") as GDScript).call("run", toys, switch)
	_check(bool(freed["ok"]), "the HUD's prompt for a toy, or its box, freed under it is empty, with no engine error", str(freed))

	# A trampoline throws a person up from inside their movement (a predicting client agrees) and counts each bounce.
	var placements: Array = (game.map_doc["toys"] as Array).duplicate()
	placements.append({"toy": "trampoline", "at": [19.5, 0.0, 0.0]})
	placements.append({"toy": "merry_go_round", "at": [16.0, 0.0, 4.5]})
	var _rebuilt := toys.build(placements)
	var tramp := toys.toy(placements.size() - 2)
	var deck := toys.toy(placements.size() - 1)
	walker.place_at(Vector3(19.5, 1.2, 0.0), 0.0)
	var highest := 0.0
	for _i in range(TICK_RATE * 2):
		_drive(walker, Vector2.ZERO)
		await _step(game, 1)
		highest = maxf(highest, walker.controller.state.position.y)
	_check(highest > 2.0, "landing on the trampoline throws a person up", "%.2f m at the top (at %s; toy %s %s at %s of %d, built %s)" % [highest, walker.controller.state.position, tramp.index, tramp.kind, tramp.global_position, toys.toys.size(), _rebuilt])
	_check(tramp.count >= 2, "and every bounce is counted, which is what a client hears", str(tramp.count))

	# A roundabout carries a person standing a metre from the hub round with it (MmController.carrier).
	var hub := deck.global_position
	walker.place_at(hub + Vector3(1.0, 0.5, 0.0), 0.0)
	for _i in range(TICK_RATE / 2):
		_drive(walker, Vector2.ZERO)
		await _step(game, 1)
	var before := walker.controller.state.position - hub
	var _spun := toys.use(deck.index, hub + Vector3(0.0, 1.5, 2.5), Vector3(1.0, -0.3, 0.0))
	var turned := 0.0
	var last := atan2(before.z, before.x)
	for _i in range(TICK_RATE):
		_drive(walker, Vector2.ZERO)
		await _step(game, 1)
		var now := walker.controller.state.position - hub
		turned += absf(wrapf(atan2(now.z, now.x) - last, -PI, PI))
		last = atan2(now.z, now.x)
	var after := walker.controller.state.position - hub
	var out := Vector2(after.x, after.z).length()
	_check(turned > 0.8 and walker.controller.state.is_grounded(), "standing on a turning roundabout carries a person round its hub",
		"%.0f degrees in a second" % rad_to_deg(turned))
	_check(absf(out - Vector2(before.x, before.z).length()) < 0.25, "and leaves them as far out as they stood",
		"%.2f m from the hub, from %.2f" % [out, Vector2(before.x, before.z).length()])

	var _off := game.toy_rules.set_cvar(DotPropBodyRules.CVAR_ENABLED, "0")
	_check(not toys.toy(0).visible and toys.toy(0).process_mode == Node.PROCESS_MODE_DISABLED, "sv_toys 0 takes the toys away")
	var _on := game.toy_rules.set_cvar(DotPropBodyRules.CVAR_ENABLED, "1")

	await _end_round(game)
	var home := toys.toy(1)
	_check(home.body.global_position.distance_to(home.rest.origin) < 0.05, "a new round puts every toy home",
		"%.2f m away" % home.body.global_position.distance_to(home.rest.origin))
	_finished()


## A key down for a tick and up again: the game makes a press from the edge, as from a packet.
func _press_key(game: MmGame, player: MmPlayer, key: StringName) -> void:
	player.set("wants_" + String(key), true)
	await _step(game, 1)
	player.set("wants_" + String(key), false)
	await _step(game, 1)
