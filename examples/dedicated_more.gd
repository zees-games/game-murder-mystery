extends "dedicated_tests.gd"


## The players' vote decides the next map: a ballot over the server's maps, one vote cast,
## and the round's end puts the winner on the next round. Driven by hand rather than by
## the clock, because stand-ins are not voters and a server of stand-ins never opens one.
func _test_the_map_vote() -> void:
	_section("the map vote")
	var module := _module()
	var vote: Node = module.get("vote") if module != null else null
	_check(vote != null, "the module built a map vote")

	if vote == null:
		_finished()
		return

	_check(server.console.find_command("vote") != null if server.console.has_method("find_command") else true,
		"and registered dot-vote's vote command")
	_vote_sleeps_with_the_server(vote)
	await _vote_map_menu(vote)
	_vote_ballot_decides(vote)
	_finished()


## Hibernation: the vote follows the server's sleep and waking starts the ballot again from the top.
func _vote_sleeps_with_the_server(vote: Node) -> void:
	var sleeper: DotVoteDirector = vote.get("director")
	_check(server.hibernation_changed.is_connected(sleeper.set_hibernating),
		"the vote follows the server's hibernation without a line of this game's")
	vote.set("_opened_this_map", true)
	server.console.execute("sv_hibernate_when_empty 1")
	_check(server.is_hibernating() and sleeper.hibernating, "an empty server sleeps, and the vote with it",
		server.state_name())
	var on_map: float = vote.get("_on_map_sec")
	vote.call("advance", 600.0)
	_check(is_equal_approx(vote.get("_on_map_sec"), on_map), "ten minutes asleep do not count towards the ballot")
	server.console.execute("sv_hibernate_when_empty 0")
	_check(not sleeper.hibernating, "waking wakes the vote")
	_check(is_zero_approx(vote.get("_on_map_sec")) and not vote.get("_opened_this_map"),
		"and the map ballot is owed again from the top")


## The ballot offers every map in the directory and the map menu's server half changes the map for staff.
func _vote_map_menu(vote: Node) -> void:
	# Every map in the directory, not only this suite's practice house.
	game.config.map_ids = PackedStringArray()
	vote.call("refresh_maps")
	var ids: Array = []

	for choice: DotVoteChoice in (vote.get("source") as DotVoteListSource).entries:
		ids.append(String(choice.id))

	_check(ids.has("mm_mansion") and ids.has("mm_motel"), "it offers the delivered maps", str(ids))

	# The map menu's server half (M): the owner's flag changes the map now, anybody else
	# gets a nomination and a rock-the-vote. Contexts as dot-server makes them for a chat line.
	var menu_half: Object = vote.get("commands").get("map_menu")
	_check(menu_half != null and server.console.find_command("mapmenu") != null
		and server.console.find_cvar("sv_map_menu_flag").get_string() == "generic"
		and (menu_half.get("change_fn") as Callable).is_valid(),
		"the map menu is there, staff-only by default, changing the map now")
	var staff := DotCmdContext.new()
	staff.source = DotCmdContext.Source.CHAT
	staff.permissions = PackedStringArray(["generic"])
	var player := DotCmdContext.new()
	player.source = DotCmdContext.Source.CHAT
	var menu_offer: Dictionary = menu_half.call("offer", player)
	_check((menu_offer["maps"] as Array).size() > 1 and not bool(menu_offer["allowed"]) and bool(menu_offer["vote"]),
		"a player is offered every map, as a vote")
	var target: StringName = &""
	for row: Dictionary in menu_offer["maps"]:
		if not bool(row["current"]):
			target = StringName(str(row["id"]))
			break
	var menu_changed: Dictionary = await menu_half.call("choose", staff, target)
	_check(bool(menu_changed["ok"]) and StringName(str(game.map_doc.get("id", ""))) == target, "staff choosing one changes the map on the spot",
		"%s: %s" % [target, menu_changed.get("text", "")])


func _voter_seven() -> Array:
	return [&"7"]


func _voter_console() -> Array:
	return [&"console"]


func _count_opened(_options: Array, _seconds: float, opened_count: Array) -> void:
	opened_count[0] += 1


func _record_applied(id: StringName, applied: Array) -> DotResult:
	applied.append(id)
	return DotResult.success(id)


func _four_players() -> int:
	return 4


## One vote decides, the round's end hands the map to the world, and rock-the-vote opens one ballot.
func _vote_ballot_decides(vote: Node) -> void:
	vote.set("voters_fn", _voter_seven)
	var director: DotVoteDirector = vote.get("director")
	var opened := director.open_vote(DotVoteClock.REASON_MANUAL)
	_check(opened.ok and director.is_voting(), "a ballot opens", opened.error.message if not opened.ok else "")

	# A map the ballot actually offers: it draws a handful from the server's maps, and with more
	# maps than places a fixed id is on it some runs and not others.
	var offered := director.ballot.option_ids() if director.ballot != null else []
	var maps_offered := offered.filter(func(id: StringName) -> bool: return String(id).begins_with("mm_"))
	var choice: StringName = &"mm_mansion" if offered.has(&"mm_mansion") or maps_offered.is_empty() else StringName(maps_offered[0])
	var cast := director.cast_one(&"7", choice)
	# Everybody has voted; the director closes on its next advance, which is the server's tick.
	director.advance(0.05)
	_check(cast.ok and director.pending_id() == choice, "one vote decides it, waiting for the round's end",
		"%s %s of %s" % [cast.ok, director.pending_id(), offered])

	# No frame between these: the stand-ins' rounds are still running, and one that started in
	# between would lay the voted map itself and leave this check reading the rotation's.
	vote.call("note_round_end")
	_check(game.next_map_id == choice, "the round's end hands it to the world", str(game.next_map_id))

	game.call("_lay_out_map")
	_check(StringName(str(game.map_doc.get("id", ""))) == choice and game.next_map_id == &"",
		"and the next map laid is the one voted for, once", "%s / %s" % [game.map_doc.get("id", ""), game.next_map_id])

	# Rock the vote as !rtv reaches it, on the director alone so the map's own ballot timer
	# opens nothing first; past dot-vote's cooldown between two ballots.
	var laid := StringName(str(game.map_doc.get("id", "")))
	_check(director.current_id() == laid and not director.is_voting(),
		"the new map starts the vote over", "%s / %s" % [director.current_id(), laid])
	vote.set("voters_fn", _voter_console)
	director.rules.rtv_delay_sec = 0.0
	director.rules.min_players_to_vote = 1
	director.rules.rtv_min_players = 1
	director.rules.allow_single_voter_auto = true
	director.advance(director.rules.vote_cooldown_sec + 0.1)
	var opened_count := [0]
	var counter := _count_opened.bind(opened_count)
	director.vote_opened.connect(counter)
	var rocked := _run_command("rtv")
	vote.call("advance", 0.05)
	_check(director.is_voting(), "and a passing rock-the-vote opens a ballot", str(rocked))
	# The director opens it under MANUAL; the game must not open a second.
	_check(opened_count[0] == 1, "and opens exactly one rtv ballot, not a second from the game", str(opened_count[0]))
	director.vote_opened.disconnect(counter)


## `time_up: finish_round` waits for a round being played, never for warmup, through the game's
## `round_in_progress_fn`. Run on a director of its own so the real vote's clock is untouched.
func _test_finish_round_waits_for_a_live_round() -> void:
	_section("finish_round waits for a live round, not warmup")
	var module := _module()
	var vote: Node = module.get("vote") if module != null else null
	var director: DotVoteDirector = vote.get("director") if vote != null else null
	var hook: Variant = director.get("round_in_progress_fn") if director != null else null
	_check(hook is Callable and (hook as Callable).is_valid(), "the game tells its vote whether a round is live")

	if not (hook is Callable and (hook as Callable).is_valid()) or game == null or game.match_node == null:
		_finished()
		return

	var match_node: DotMatch = game.match_node
	var was := match_node.state
	match_node.state = DotMatch.State.WARMUP
	var warm_applied := []
	var warm := _finish_round_probe(hook, warm_applied)
	_check(warm_applied == [&"b"] and not warm.is_finishing_round(),
		"in warmup a time limit with finish_round changes at once", str(warm_applied))

	match_node.state = DotMatch.State.LIVE
	var live_applied := []
	var live := _finish_round_probe(hook, live_applied)
	_check(live_applied.is_empty() and live.is_finishing_round(),
		"during a live round it waits for the round", str(live_applied))

	match_node.state = DotMatch.State.INTERMISSION
	live.advance(0.1)
	_check(live_applied == [&"b"], "and the round ending is the change", str(live_applied))

	match_node.state = was
	warm.queue_free()
	live.queue_free()
	_finished()


## A director under `time_up: finish_round` carrying [param hook], its clock run out with a
## winner already decided: what dot-vote's own suite builds, with the game's answer in it.
func _finish_round_probe(hook: Callable, applied: Array) -> DotVoteDirector:
	var source := DotVoteListSource.new()
	var _a := source.add(DotVoteChoice.of(&"a", "A"))
	var _b := source.add(DotVoteChoice.of(&"b", "B"))
	source.apply_fn = _record_applied.bind(applied)

	var rules := DotVoteRules.new()
	rules.apply_delay_sec = 0.0
	rules.duration_sec = 100.0
	rules.vote_lead_sec = 40.0
	rules.vote_duration_sec = 5.0
	rules.include_extend = false
	rules.apply = DotVoteRules.Apply.END_OF_TIME
	rules.cooldown = 0
	rules.time_up = DotVoteRules.TimeUp.FINISH_ROUND
	# For ever: only the hook may release it.
	rules.finish_round_max_sec = 0.0

	var probe := DotVoteDirector.new()
	probe.rules = rules
	probe.source = source
	probe.register_service = false
	probe.self_advance = false
	probe.round_based = true
	probe.player_count_fn = _four_players
	probe.set(&"round_in_progress_fn", hook)
	add_child(probe)
	probe.begin(&"a")
	source.current = &"a"

	for i in range(61):
		probe.advance(1.0)

	probe.cast_one(&"p1", &"b")

	# The ballot closes, then the limit (100 s) runs out with the winner decided.
	for i in range(46):
		probe.advance(1.0)

	return probe


## A reload keeps the maps the server names: `mm_reload` re-reads the directory and must not
## forget delivered ones. A mounted pack and a descriptor stand in for dot-cloud and the deployment.
func _test_a_reload_keeps_delivered_maps() -> void:
	_section("a reload keeps the maps the server names")
	var key := "dot-test/hs-delivered@1.0.0"
	var mount := DotGameContent.mount_of(key)
	var dir := mount.path_join("maps")
	var id := &"mm_delivered_check"
	DirAccess.make_dir_recursive_absolute(dir)
	var doc: Dictionary = game.catalogue.practice()
	doc["id"] = String(id)
	var file := FileAccess.open(dir.path_join("delivered_check.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(doc))
	file.close()

	# The manager's running descriptor, named the way a deployment names it. Restored below:
	# `_current` is the manager's own, and nothing else in this suite should see the pack.
	var manager: Object = server.games
	var was: Variant = manager.get("_current")
	var named := DotGameDescriptor.new()
	named.maps = PackedStringArray([key])
	manager.set("_current", named)

	var _first := _run_command("mm_reload")
	for _i in range(3):
		await get_tree().process_frame
	_check(game.catalogue.maps.has(id), "a map the server names is in the catalogue after mm_reload",
		str(game.catalogue.maps.keys()))
	_check(game.catalogue.maps.has(&"mm_practice"),
		"beside the built-in one")

	# The ballot sees them from boot, not only after a reload: unload and load is a boot (module_reload
	# is not), with every map and the catalogue as a boot finds it, as the vote builds before maps arrive.
	var only := game.config.map_ids
	game.config.map_ids = PackedStringArray()
	var _builtin := game.catalogue.load_from(game.config.map_directory)
	var reloaded := _run_command("module_unload murder")
	reloaded.append_array(_run_command("module_load res://game/mm_module.gd"))
	for _i in range(60):
		await get_tree().process_frame

		if _module() != null and _module().get("vote") != null:
			break
	var booted_vote: Node = _module().get("vote") if _module() != null else null
	var booted_ids: Array = []

	if booted_vote != null:
		for choice: DotVoteChoice in (booted_vote.get("source") as DotVoteListSource).entries:
			booted_ids.append(String(choice.id))

	_check(booted_ids.has(String(id)), "and on the ballot of a module that boots with it named, unrefreshed",
		"%s %s" % [reloaded, booted_ids])
	game.config.map_ids = only

	manager.set("_current", was)
	var _second := _run_command("mm_reload")
	for _i in range(3):
		await get_tree().process_frame
	_check(not game.catalogue.maps.has(id), "and it came from the server's list: unnamed, a reload drops it")

	DirAccess.remove_absolute(dir.path_join("delivered_check.json"))
	var path := dir
	while path != "res://dot_cloud":
		DirAccess.remove_absolute(path)
		path = path.get_base_dir()
	DirAccess.remove_absolute("res://dot_cloud")
	_finished()


## A bystander behind its loading cover cannot be killed (stab, kill, draw), an operator's slay
## lands, and once `game.cover` crosses the real wire the same kill lands.
func _test_loading_cover() -> void:
	_section("a client behind its loading cover cannot be killed")

	var module := _module()
	var roster: DotGameRoster = module.get("roster") if module != null else null

	var known: Dictionary = {}
	for each in server.playing_sessions():
		known[each.userid] = true

	var side := Node.new()
	side.name = "CoverClient"
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
	# Under a node named like this suite's own, so the RPC path the server sends resolves in the
	# client's separate multiplayer tree too.
	var mirror := Node.new()
	mirror.name = name
	side.add_child(mirror)
	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Cover"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % PORT
	mirror.add_child(link)
	link.connect_to_server("127.0.0.1:%d" % PORT)
	var _stand_in := _seat_receiver_on_join(link, side)

	var seat: Array = [null]
	for _i in 1800:
		await get_tree().physics_frame
		for each in server.playing_sessions():
			if not known.has(each.userid) and game.players.has(StringName("u%d" % each.userid)):
				seat[0] = each
		if seat[0] != null:
			break

	_check(seat[0] != null and roster != null, "a real client joins over the socket", str(link.last_error))

	var murderer: MmPlayer = null
	for id: StringName in game.players:
		if (game.players[id] as MmPlayer).is_bot:
			murderer = game.players[id]
			break

	if seat[0] == null or roster == null or murderer == null:
		for what in ["held as loading", "a stab", "a kill", "the murderer draw", "an operator's slay",
				"the cover report", "the kill after", "bots and strangers", "leaving"]:
			_check(false, "%s (no runner joined)" % what)
		link.disconnect_from_server("done")
		side.queue_free()
		_finished()
		return

	await _cover_checks(link, roster, murderer, seat[0].userid)
	side.queue_free()
	_finished()


## The covered seat: refused harm, not drawn, slain by an operator, then harmable once its cover report lands.
func _cover_checks(link: DotClientLink, roster: DotGameRoster, murderer: MmPlayer, userid: int) -> void:
	var key := StringName("u%d" % userid)
	var victim: MmPlayer = game.players[key]
	# A seat joining mid-round is benched, so every refusal below would pass for the wrong
	# reason: the seat is put in the round first, as a lobby join would be.
	victim.watching = false
	game._heal(victim)
	_check(roster.is_loading(userid), "the server holds the seat as loading from its spawn", str(roster.describe()))

	# The setup and the attempts are one run with no await, so nothing ticks between.
	var was_phase: int = game.phase
	game.phase = MmGame.Phase.PLAY
	game._set_side(key, MmGame.BYSTANDERS)
	game._set_side(murderer.player_id, MmGame.MURDERERS)
	murderer.place_at(victim.controller.state.position - Vector3(0.0, 0.0, 0.5), 0.0)
	var target: MmPlayer = game.stab_target(murderer)
	_check(target != victim, "a stab does not find it", "target=%s" % (target.player_id if target != null else "none"))

	game._kill(victim, murderer, MmGame.DIED_STABBED)
	_check(victim.is_alive(), "and a kill on it is refused", "alive=%s" % victim.is_alive())

	# The draw leaves a covered seat unarmed and innocent while others can be drawn.
	var drawn := 0
	for _i in 12:
		game._round_seed = _i
		game.murderer_history.clear()
		game._draw_roles()
		if game.team_of(key) == MmGame.MURDERERS or victim.has_gun:
			drawn += 1
	_check(drawn == 0, "a covered seat is not drawn murderer or gunner", "%d of 12 draws" % drawn)

	game.phase = MmGame.Phase.PLAY
	game._set_side(key, MmGame.BYSTANDERS)
	game._set_side(murderer.player_id, MmGame.MURDERERS)
	var slay := DotDamage.make(0, victim.entity_id, victim.health.health + 1000.0, null)
	slay.context = {"admin": true}
	var _slain := game.combat.apply_damage(slay)
	_check(not victim.is_alive(), "an operator's slay still lands",
		"refused=%s %s hp=%s" % [_slain.refused, _slain.refusal if "refusal" in _slain else "", victim.health.health])
	victim.health.revive()
	game.phase = was_phase

	DotGameClient.report_cover(link, false)
	var lifted := false
	for _i in 900:
		await get_tree().physics_frame
		if not roster.is_loading(userid):
			lifted = true
			break
	_check(lifted, "its cover report crosses the wire and ends the loading state")

	game.phase = MmGame.Phase.PLAY
	game._set_side(key, MmGame.BYSTANDERS)
	game._set_side(murderer.player_id, MmGame.MURDERERS)
	game._kill(victim, murderer, MmGame.DIED_STABBED)
	_check(not victim.is_alive(), "and the same kill now lands", "alive=%s" % victim.is_alive())
	game.phase = was_phase

	_check(game.can_be_harmed(murderer.player_id) and game.can_be_harmed(&"u99999"),
		"a bot, or a seat the roster does not hold, is never loading")

	link.disconnect_from_server("done")
	var gone := false
	for _i in 900:
		await get_tree().physics_frame
		if not game.players.has(key):
			gone = true
			break
	_check(gone and not roster.is_loading(userid), "it leaves and the roster forgets it")


## [b]`mm_ambient*` on a client.[/b] The server's ambience intent rides the replicated cvars over a real socket, and a
## director that follows the game's rules (as [MmClient] wires it) has it in its layer's config.
func _test_ambient_cvars_reach_the_client() -> void:
	_section("the server's mm_ambient* reaches a client's ambience director, live")
	var side := Node.new()
	side.name = "AmbientClient"
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
	var mirror := Node.new()
	mirror.name = name
	side.add_child(mirror)
	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Ambient"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % PORT
	mirror.add_child(link)
	link.connect_to_server("127.0.0.1:%d" % PORT)
	var _stand_in := _seat_receiver_on_join(link, side)
	var rules := MmAmbience.make_rules()
	var _followed := rules.follow_cvars(link)
	var director := DotAmbienceDirector.new()
	director.ambient = DotAmbience.new()
	director.follow_settings(null, rules)
	var joined := false
	for _i in 1800:
		await get_tree().physics_frame
		if link.replicated_cvar("mm_ambient_volume", "") != "":
			joined = true
			break
	_check(joined and link.replicated_cvar("mm_ambient_dir", "x") == "x",
		"the join carried mm_ambient_volume, and the machine-local mm_ambient_dir stayed home", str(link.replicated_cvars))
	var _vol := server.console.set_cvar("mm_ambient_volume", "0.8")
	var _mood := server.console.set_cvar("mm_ambient_mood", "swamp")
	var _off := server.console.set_cvar("mm_ambient", "0")
	var arrived := false
	for _i in 900:
		await get_tree().physics_frame
		if is_equal_approx(director.ambient.config.volume, 0.8) and director.ambient.config.mood == "swamp" \
				and not director.ambient.config.enabled:
			arrived = true
			break
	_check(arrived, "a change of volume, mood and the switch reaches the director live", str(rules.describe()))
	var _back_vol := server.console.set_cvar("mm_ambient_volume", "0.3")
	var _back_mood := server.console.set_cvar("mm_ambient_mood", "")
	var _back_on := server.console.set_cvar("mm_ambient", "1")
	var back := false
	for _i in 900:
		await get_tree().physics_frame
		if rules.is_on() and rules.mood == "":
			back = true
			break
	_check(back, "and back", str(rules.describe()))
	director.ambient.free()
	director.free()
	link.disconnect_from_server("done")
	for _i in 120:
		await get_tree().physics_frame
	side.queue_free()
	_finished()


func _test_it_unloads_cleanly() -> void:
	_section("unloading")
	server.modules.unload_all()
	await get_tree().process_frame
	_check(_module() == null, "the module unloads")
	_check(server.console.find_command("mm_status") == null if server.console.has_method("find_command") else true,
		"and takes its commands with it")
	_check(is_instance_valid(game), "and leaves the world, which outlives it")
	_finished()


## No message script preloads itself: in mg-buses-from-hell that one line leaked the whole
## script graph at exit (8ed866c), and the leak is printed after `quit()`, where no assertion
## reaches. So the cause is checked, on the source.
func _test_no_message_preloads_itself() -> void:
	_section("exiting clean")
	var offenders := PackedStringArray()
	var dir := DirAccess.open("res://game/net")

	for file in dir.get_files():
		if not file.ends_with(".gd"):
			continue

		var source := FileAccess.get_file_as_string("res://game/net/" + file)

		if source.contains("extends DotNetMessage") and source.contains("preload(\"%s\")" % file):
			offenders.append(file)

	_check(offenders.is_empty(), "no message preloads itself", ", ".join(offenders))
	_finished()
