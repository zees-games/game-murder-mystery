extends Node

const MmBindings := preload("../game/mm_bindings.gd")
const MmBotChat := preload("../game/mm_bot_chat.gd")
const MmCatalogue := preload("../game/mm_catalogue.gd")
const MmConfig := preload("../game/mm_config.gd")
const MmGame := preload("../game/mm_game.gd")
const MmEvents := preload("../game/net/mm_events.gd")
const MmMapDoc := preload("../game/mm_map_doc.gd")
const MmPlayer := preload("../game/mm_player.gd")
const MmProgress := preload("../game/mm_progress.gd")
const MmProps := preload("../game/mm_props.gd")
const MmSettings := preload("../game/mm_settings.gd")
const MmWeapons := preload("../game/mm_weapons.gd")

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

const SECTIONS := 24

const CHECKS := 150

const TICK_RATE := 64
const TICK := 1.0 / float(TICK_RATE)

## The first chair round the kitchen table in the practice house: where it stands.
const CHAIR_AT := Vector3(3.6, 0.0, 1.2)

## An open stretch of the kitchen floor, and a spot in the living room, either side of the wall.
const KITCHEN_A := Vector3(3.0, 0.05, -3.0)
const KITCHEN_B := Vector3(8.0, 0.05, -3.0)
const LIVING := Vector3(-3.0, 0.05, -3.0)

## Out of everybody's way, in the garden: where a test parks whoever it is not about.
const PARK := Vector3(18.0, 0.05, 5.0)

## The roles most sections play: one murderer, one gunner, two bystanders.
const FOUR := {&"u1m": &"murderer", &"u2g": &"gunner", &"u3b": &"bystander", &"u4b": &"bystander"}

var _passed := 0
var _failed := 0
var _sections_entered := 0
var _sections_finished := 0
var _failures := PackedStringArray()

var _worlds: Array[MmGame] = []


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
	await _test_the_round()
	await _test_falls()
	await _test_joiners()
	await _test_progress()
	_test_bot_chat()
	await _test_bots()
	await _test_doors()
	await _test_toys()
	await _test_the_client()
	await _test_help_and_menu()
	await _test_the_map_menu()
	_test_weapons_table()

	for world in _worlds.duplicate():
		await _dispose(world)

	await get_tree().process_frame

	print("")
	print("%d sections entered, %d finished" % [_sections_entered, _sections_finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	if _sections_entered != _sections_finished or _sections_entered != SECTIONS:
		print("ERROR: %d of %d sections finished, %d expected." % [
			_sections_finished, _sections_entered, SECTIONS
		])
		code = 1

	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		code = 1

	get_tree().quit(code)


# --- Without a world ------------------------------------------------------------

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
	_finished()


func _test_bot_chat() -> void:
	_section("the bots' chat is rationed")
	var chat := MmBotChat.new()
	var stream := DotRandomStream.new(7, &"chat_test")
	var first := chat.line(&"a", &"body", 0.0, stream, "", true)
	_check(first != "" and (MmBotChat.LINES[&"body"] as Array).has(first), "a line from the moment's pool", first)
	_check(chat.line(&"b", &"body", 1.0, stream, "", true) == "", "nobody else straight after it")
	_check(chat.line(&"b", &"body", 3.0, stream, "", true) != "", "somebody else a few seconds on")
	_check(chat.line(&"a", &"body", 7.0, stream, "", true) == "", "but not the same bot again so soon")
	_check(chat.line(&"c", &"witness", 20.0, stream, "", true) == "", "a line that names somebody needs a name")
	var named := chat.line(&"c", &"witness", 20.0, stream, "Pip", true)
	_check(named.contains("Pip"), "and has it", named)
	var said := 0
	var quiet := MmBotChat.new()
	for i in range(200):
		if quiet.line(StringName("b%d" % i), &"group", float(i) * 3.0, stream) != "":
			said += 1
	_check(said > 40 and said < 160, "only some moments get a line (%d of 200)" % said)
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


# --- A world ---------------------------------------------------------------------

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


func _test_progress() -> void:
	_section("what a round is worth to a player's numbers")
	var game := await _round(FOUR)
	var m := _p(game, &"u1m")
	var g := _p(game, &"u2g")
	var b := _p(game, &"u3b")
	var victim := _p(game, &"u4b")
	game._kill(victim, m, MmGame.DIED_STABBED)
	g.place_at(KITCHEN_A, 0.0)
	b.place_at(PARK, 0.0)
	m.place_at(LIVING, 0.0)
	await _step(game, 2)
	_aim(g, KITCHEN_A + Vector3(0.0, 1.6, -4.0))
	var _missed := game.attack_now(g.player_id)
	# Out of the way: b picks the gun up where g stood, and a shot from there would hit g first.
	g.place_at(PARK + Vector3(3.0, 0.0, 0.0), 0.0)
	b.place_at(KITCHEN_A, 0.0)
	await _step(game, TICK_RATE)
	m.place_at(KITCHEN_B, 0.0)
	await _step(game, 2)
	_aim(b, _chest(m))
	var _hit := game.attack_now(b.player_id)
	var of := func(id: StringName, stat: StringName) -> float: return game.progress.session_values(id).get_value(stat)
	_check(of.call(m.player_id, MmProgress.KILLS) == 1.0 and of.call(victim.player_id, MmProgress.DEATHS) == 1.0,
		"a stab is a kill for one and a death for the other")
	_check(of.call(g.player_id, MmProgress.MISSES) == 1.0, "a miss is counted")
	_check(of.call(b.player_id, MmProgress.PICKUPS) == 1.0 and of.call(b.player_id, MmProgress.HEROICS) == 1.0,
		"and the gun picked up and the murderer shot", "%s %s (hit %s, murderer alive %s, gun %s, phase %s)" % [of.call(b.player_id, MmProgress.PICKUPS), of.call(b.player_id, MmProgress.HEROICS), _hit, m.is_alive(), b.has_gun, game.phase])

	var declared := MmProgress.ids()
	var unread: Array = []
	for achievement in MmProgress.catalogue().achievements:
		for rule in achievement.requirements:
			if not declared.has(rule.stat):
				unread.append(String(achievement.id))
	_check(unread.is_empty(), "every achievement reads a number this game records", str(unread))
	_finished()


func _test_bots() -> void:
	_section("stand-ins play a round by themselves")
	var game := await _world(func(c: MmConfig) -> void:
		c.grace_seconds = 3.0
		c.round_seconds = 50.0)
	for i in range(6):
		var bot := game.add_player(StringName("u%d" % (900 + i)), "Bot%d" % i)
		bot.is_bot = true
	game.start()
	await _step(game, 2)
	var starts := {}
	for id: StringName in game.players:
		starts[id] = (game.players[id] as MmPlayer).controller.state.position
	await _step(game, TICK_RATE * 6)
	var moved := 0
	for id: StringName in game.players:
		if (game.players[id] as MmPlayer).controller.state.position.distance_to(starts[id]) > 1.5:
			moved += 1
	_check(moved >= 4, "they spread out and walk about (%d of 6)" % moved)
	var round_before := game.round_number
	await _step(game, TICK_RATE * 20)
	var counts: Dictionary = game.bots.counts
	_check(int(counts["draws"]) >= 1 or game.alive_total() < 6 or game.round_number > round_before,
		"the murderer goes to work without anybody at the keyboard", str(counts))
	_check(game.phase != MmGame.Phase.IDLE or game.round_number > round_before, "and the rounds go on",
		"phase %d, round %d" % [game.phase, game.round_number])
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

	# A trampoline: landing on it throws a person up, from inside their movement (so a
	# predicting client is thrown on the same tick), and counts the bounce for everybody to hear.
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

	# A roundabout: a person standing on it a metre from the hub goes round with it, in their
	# movement (MmController.carrier, dot-props' carry_for), and is still a metre out after.
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

	var _off := game.toy_rules.set_cvar(DotPropToyRules.CVAR_ENABLED, "0")
	_check(not toys.toy(0).visible and toys.toy(0).process_mode == Node.PROCESS_MODE_DISABLED, "sv_toys 0 takes the toys away")
	var _on := game.toy_rules.set_cvar(DotPropToyRules.CVAR_ENABLED, "1")

	await _end_round(game)
	var home := toys.toy(1)
	_check(home.body.global_position.distance_to(home.rest.origin) < 0.05, "a new round puts every toy home",
		"%.2f m away" % home.body.global_position.distance_to(home.rest.origin))
	_finished()


## The use key down for a tick and up again: the game makes a press from the edge.
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
	# The map used to be drawn, and steered, while it was still being built.
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
	world.forced_roles = {&"local": &"murderer"}
	world._on_round_started(world.round_number + 1)
	for i in 4:
		await get_tree().process_frame
	_check(world.team_of(&"local") == MmGame.MURDERERS and hud.call("role_of") == &"murderer",
		"a murderer's own HUD says so")
	world.forced_roles = {&"local": &"gunner"}
	world._on_round_started(world.round_number + 1)
	for i in 4:
		await get_tree().process_frame
	_check(hud.call("role_of") == &"gunner", "and a gunner's says that")
	world.forced_roles = {}

	# The clock is dot-ui's DotScoreStrip: everybody alive, and how many murderers are left.
	hud.call("_process", 0.0)
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

	# A slain stand-in falls as dot-player-char's ragdoll: the world picked the fall, and the
	# client copied the body from the figure it draws, under the game's rules, the figure hidden.
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
		# Most of this is pinned, because the fall is a physics outcome and it differed
		# run to run: the seat is the map's first spawn (the ones the seating picked included
		# a table top, where a body jittered for six seconds), the killer stands a metre off as
		# a stab or a shot would have it (a death with no direction pushes nothing). The tick the
		# reaction is seeded from is not pinned any more: a face plant stood up on some ticks
		# until dot-player-char kept its spin up, and the sweep below covers every facing.
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
		world._kill(victim, killer, MmGame.DIED_SLAIN)
		await get_tree().process_frame
		_check(victim.death != null and DotPlayerDeathReactions.stock().has(victim.death.reaction),
			"the world picked how the body falls", str(victim.death.describe()) if victim.death != null else "none")
		var bodies := ragdolls.live()
		_check(bodies.size() == 1 and not victim.figure.visible,
			"and the client laid the body down from the figure, which is hidden", str(bodies.size()))
		# Until it settles, not for a fixed second: how long a fall takes depends on the reaction
		# the seed picked and where it lands, and a count of frames judged some bodies mid-air.
		# The ragdoll freezes itself at rules.max_sim_time, so this ends.
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
		# The same fall again and again, nobody pushing, at four facings. This is what the pinned
		# seed above dodged, and the seed was never the cause: a face plant spins the whole body
		# 1.6 rad/s about its toes and draws nothing from the seed. About one fall in six stays up
		# on its feet with no wall in the way (the spin dies in a few frames, the box still flush
		# with the floor; seen at facings with nothing within 2 m ahead), so it is dot-player-char's
		# to fix (nightly ragdoll-faceplant-upright-1). A body that has a wall ahead is excused.
		# This stays armed: a game whose falls all stay up, or a fix that makes none, shows here.
		# Where the sweep stands is picked for clear floor, not taken as seat 0: seat 0 of the
		# practice house has a seat cushion and a table edge a third of a metre ahead, and a body
		# that falls across a 0.3-0.5 m solid ends up draped over it (centre 1.1 m, one arm on the
		# floor, settled, six parts): lying down, but not by this check's bounds, and whether it
		# fell on the cushion or beside it differed run to run (one full run in about three).
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
			for i in 240:
				await get_tree().physics_frame
				if b == null or not is_instance_valid(b) or b.settled:
					break
			if b == null or not is_instance_valid(b):
				upright += 1
				detail_up.append("%d:gone" % s)
				continue
			var c: Vector3 = b.centre()
			var gh := world.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(
				c + Vector3.UP * 0.3, c + Vector3.DOWN * 6.0,
				world.physics.layer_mask(&"world") | world.physics.layer_mask(&"prop")))
			var gy := (gh["position"] as Vector3).y if not gh.is_empty() else -INF
			# "Through the floor" is judged against the floor, not against whatever is under the
			# centre: a body lying across a 0.3 m solid by the seat has an arm on the floor and the
			# ray from its middle lands on the solid, so lowest-gy read -0.30 and a body that was
			# plainly lying down failed one run in several (lowest 0.00, settled, 6 parts, landed).
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
	else:
		for k in 3:
			_check(false, "a stand-in drawn to slay")

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
	# the requires.json dot-ci derives must ask for dot-ui 4, and nothing may lower it.
	var asks := DotAddonApi.derive()
	_check(
		int(asks.get("dot_ui", 0)) >= 4 and not FileAccess.file_exists("res://" + DotAddonApi.FLOOR_FILE),
		"the pack asks a shell for dot-ui level 4, the glance pieces",
		str(asks.get("dot_ui"))
	)

	remove_child(client)
	client.free()
	await get_tree().process_frame
	_finished()


## The family's rule since the first play test: H opens help in every game, nothing else in
## the table is on H, and the Escape menu has Help & commands and Leave.
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


# --- Helpers --------------------------------------------------------------------

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


func _section(name: String) -> void:
	_sections_entered += 1
	print(name)


func _finished() -> void:
	_sections_finished += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
		return

	_failed += 1
	var line := "%s%s" % [what, "" if detail == "" else "  (%s)" % detail]
	_failures.append(line)
	print("  FAIL  %s" % line)


## A key down for a tick and up again: the game makes a press from the edge, as from a packet.
func _press_key(game: MmGame, player: MmPlayer, key: StringName) -> void:
	player.set("wants_" + String(key), true)
	await _step(game, 1)
	player.set("wants_" + String(key), false)
	await _step(game, 1)


## A world on the practice house, stepped by hand. The previous one is freed first: every
## world here shares ONE physics space, and every map is built at the origin.
func _world(configure: Callable = Callable()) -> MmGame:
	for old in _worlds.duplicate():
		await _dispose(old)

	var config := MmConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.map_ids = PackedStringArray(["mm_practice"])
	config.keep_progress = true
	config.grace_seconds = 0.25
	config.bot_chat = false

	if configure.is_valid():
		configure.call(config)

	var game := MmGame.new()
	game.name = "World%d" % _worlds.size()
	game.config = config
	game.tick_rate = TICK_RATE
	game.authoritative = true
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	_worlds.append(game)

	await _physics_frame()
	await _physics_frame()
	return game


## A world with [param roles] (id -> role) forced, its round started, and (unless
## [param to_play] is false) its grace over.
func _round(roles: Dictionary, configure: Callable = Callable(), to_play: bool = true) -> MmGame:
	var game := await _world(configure)
	var index := 0
	for id: StringName in roles:
		var _p := game.add_player(id, "Person%d" % index)
		index += 1
	game.forced_roles = roles.duplicate()
	game.start()
	await _wait_for(game, MmGame.Phase.GRACE)
	if to_play:
		await _wait_for(game, MmGame.Phase.PLAY)
	return game


func _p(game: MmGame, id: StringName) -> MmPlayer:
	return game.players[id]


## Everybody named out to the garden, a step apart, where nothing in the house can reach them.
func _park(game: MmGame, ids: Array) -> void:
	var i := 0
	for id: StringName in ids:
		_p(game, id).place_at(PARK + Vector3(float(i) * 1.5, 0.0, 0.0), 0.0)
		i += 1


func _chest(player: MmPlayer) -> Vector3:
	return player.controller.state.position + Vector3(0.0, 1.2, 0.0)


func _gunners(game: MmGame) -> Array[MmPlayer]:
	var out: Array[MmPlayer] = []
	for id: StringName in game.players:
		if (game.players[id] as MmPlayer).has_gun:
			out.append(game.players[id])
	return out


func _wait_for(game: MmGame, phase: int) -> void:
	for i in range(TICK_RATE * 20):
		if game.phase == phase:
			return
		await _step(game, 1)


## Ends the round in play (the murderers die, the bystanders win) and waits for the next.
func _end_round(game: MmGame) -> void:
	var number := game.round_number
	while game.phase == MmGame.Phase.GRACE:
		await _step(game, 1)
	for murderer in game.players_on(MmGame.MURDERERS):
		game._kill(murderer, null, MmGame.DIED_SLAIN)
	for i in range(TICK_RATE * 20):
		await _step(game, 1)
		if game.round_number > number and game.phase != MmGame.Phase.IDLE:
			return


func _step(game: MmGame, ticks: int) -> void:
	for _i in range(ticks):
		game.simulate(TICK)
		await _physics_frame()


func _physics_frame() -> void:
	await get_tree().physics_frame


func _dispose(game: MmGame) -> void:
	_worlds.erase(game)

	if not is_instance_valid(game):
		return

	remove_child(game)
	game.free()
	await get_tree().process_frame


func _drive(player: MmPlayer, move: Vector2) -> void:
	var command := DotFpsCommand.new()
	command.yaw = player.controller.state.yaw
	command.move = move
	player.controller.apply_command(command)


func _aim(player: MmPlayer, target: Vector3) -> void:
	var look := target - player.eye_position()
	var command := DotFpsCommand.new()
	command.yaw = rad_to_deg(atan2(-look.x, -look.z))
	command.pitch = clampf(rad_to_deg(asin(clampf(look.normalized().y, -1.0, 1.0))), -89.0, 89.0)
	player.controller.state.yaw = command.yaw
	player.controller.state.pitch = command.pitch
	player.controller.apply_command(command)


func _prop_near(game: MmGame, at: Vector3) -> int:
	for index in range(game.map.props.size()):
		if ((game.map.props[index] as Dictionary)["transform"] as Transform3D).origin.distance_to(at) < 0.05:
			return index
	return -1
