extends "headless_net_base.gd"

## Every encoder against its decoder. Nothing checks that two ends of a serialisation are
## inverses for you: dot-moderation once wrote "voice muted" and read back a warning.
func _test_the_codec() -> void:
	_section("every event decodes to what was encoded")

	var hello := MmEvents.read_hello(DotNetReader.new(MmEvents.write_hello(SESSION, 64, 1234, 10.0, 240.0, 3.0, 0.9)))
	_check(bool(hello["ok"]) and int(hello["player_id"]) == SESSION and int(hello["tick_rate"]) == 64
		and absf(float(hello["round_seconds"]) - 240.0) < 0.1 and absf(float(hello["grace_seconds"]) - 10.0) < 0.05
		and absf(float(hello["gun_cooldown"]) - 3.0) < 0.05 and absf(float(hello["melee_cooldown"]) - 0.9) < 0.02,
		"HELLO", str(hello))

	var doc := MmCatalogue.practice()
	var sent := MmEvents.read_map(DotNetReader.new(MmEvents.write_map(MmMapDoc.encode(doc))))
	var decoded := MmMapDoc.decode(sent["encoded"]) if bool(sent["ok"]) else DotResult.fail(DotError.CODE_PARSE, "no map")
	_check(decoded.ok and MmMapDoc.digest(decoded.value) == MmMapDoc.digest(doc), "MAP carries the document whole")

	var join := MmEvents.read_join(DotNetReader.new(MmEvents.write_join(SESSION, 9, "Ada", MmGame.BYSTANDERS, null)))
	_check(bool(join["ok"]) and int(join["team"]) == MmGame.BYSTANDERS and str(join["name"]) == "Ada",
		"JOIN carries the name and the public side", str(join.get("team")))

	var round_info := MmEvents.read_round(DotNetReader.new(MmEvents.write_round(3, false, MmGame.MURDERERS, "time; Ada was the murderer")))
	_check(bool(round_info["ok"]) and int(round_info["winner"]) == MmGame.MURDERERS and not bool(round_info["began"])
		and str(round_info["why"]) == "time; Ada was the murderer", "ROUND carries the winning side and the sentence")

	var role := MmEvents.read_role(DotNetReader.new(MmEvents.write_role(MmGame.MURDERERS, false, &"cleaver")))
	var gunner := MmEvents.read_role(DotNetReader.new(MmEvents.write_role(MmGame.BYSTANDERS, true, &"knife")))
	_check(bool(role["ok"]) and int(role["side"]) == MmGame.MURDERERS and not bool(role["gun"]) and role["weapon_id"] == &"cleaver"
		and bool(gunner["ok"]) and int(gunner["side"]) == MmGame.BYSTANDERS and bool(gunner["gun"]),
		"ROLE carries the side, the gun and the weapon", "%s, %s" % [role, gunner])

	var from := Vector3(1.25, 1.6, -3.5)
	var to := Vector3(9.0, 1.2, -3.25)
	var fired := MmEvents.read_shot(DotNetReader.new(MmEvents.write_shot(SESSION, from, to, true)))
	_check(bool(fired["ok"]) and int(fired["player_id"]) == SESSION and (fired["from"] as Vector3).distance_to(from) < 0.001
		and (fired["to"] as Vector3).distance_to(to) < 0.001 and bool(fired["hit"]), "SHOT carries who, both ends and whether it hit", str(fired))

	var gun := MmEvents.read_gun(DotNetReader.new(MmEvents.write_gun(3, true, to)))
	_check(bool(gun["ok"]) and int(gun["drop_id"]) == 3 and bool(gun["down"]) and (gun["at"] as Vector3).distance_to(to) < 0.001,
		"GUN carries the drop, whether it lies there and where", str(gun))

	var death := MmEvents.read_death(DotNetReader.new(MmEvents.write_death(SESSION, 0, MmGame.DIED_STABBED)))
	_check(bool(death.get("ok", true)) and int(death["player_id"]) == SESSION and int(death["by"]) == 0
		and death["why"] == MmGame.DIED_STABBED, "DEATH carries who and how, and nobody as the killer", str(death))

	var toys := MmEvents.read_toys(DotNetReader.new(MmEvents.write_toys(&"hs_camp", PackedInt64Array([7, 300, 9001]))))
	_check(bool(toys["ok"]) and toys["map_id"] == &"hs_camp" and toys["ids"] == PackedInt64Array([7, 300, 9001]),
		"TOYS carries the map and its toys' ids in order", str(toys))

	var clock := MmEvents.read_clock(DotNetReader.new(MmEvents.write_clock(2, 12.5, 40.25, MmGame.Phase.PLAY, 5, 1, true)))
	_check(bool(clock["ok"]) and int(clock["phase"]) == MmGame.Phase.PLAY and int(clock["round"]) == 2
		and absf(float(clock["play_elapsed"]) - 40.25) < 0.1 and int(clock["alive"]) == 5
		and int(clock["murderers"]) == 1 and bool(clock["playable"]), "CLOCK", str(clock))

	# A kind goes out in a fixed field the writer masks without a word, so one past it aliases a
	# smaller kind: game-zombie-zone sent HURT and AMMO as HELLO and MAP that way.
	# The largest MAP a reader accepts survives the event's own body cap. At 4096 a 4100-byte map
	# went out whole and was read back as no bytes, silently (hs_park with its toys).
	var biggest := PackedByteArray()
	biggest.resize(MmEvents.MAP_BYTES)
	var outgoing := MmEvent.new(MmEvents.Kind.MAP, MmEvents.write_map(biggest))
	var wire := DotNetWriter.new()
	outgoing._write(wire)
	var incoming := MmEvent.new()
	incoming._read(DotNetReader.new(wire.to_bytes()))
	var carried := MmEvents.read_map(incoming.reader())
	_check(bool(carried["ok"]) and (carried["encoded"] as PackedByteArray).size() == MmEvents.MAP_BYTES,
		"a MAP as large as a reader accepts fits in an event", "%d of %d bytes" % [(carried["encoded"] as PackedByteArray).size(), MmEvents.MAP_BYTES])

	_check(MmEvent.fits(), "every event kind fits the event's kind field",
		"%d kinds in %d bits" % [MmEvents.Kind.size(), MmEvent.KIND_BITS])
	_check(MmRequest.fits(), "every request kind fits the request's kind field",
		"%d kinds in %d bits" % [MmEvents.Ask.size(), MmRequest.KIND_BITS])
	_check(MmEvents.chat_kinds_fit(), "every chat kind fits the chat line's kind field",
		"%d kinds in %d bits" % [DotChatMessage.KIND_NAMES.size(), MmEvents.CHAT_KIND_BITS])

	_finished()


func _test_a_client_joins() -> void:
	_section("a client joins, and is told who it is")
	# The READY first, as over ENet with loss: a client is PLAYING by its own reckoning once it has
	# sent `loaded`, on another channel, so its READY can reach the server before its seat. Kept,
	# and answered by the seat; a bridge that drops it never tells this client who it is.
	_client_bridge.ask_ready()
	_exchange()
	_check(_client_bridge.local_player_id != SESSION, "a READY before the seat is told nothing yet")
	var seated := _server_bridge.add_player(CLIENT_PEER, SESSION, "Ada")
	_check(seated.ok, "the server seats them")
	_exchange()
	_exchange()
	await _steps(6)

	_check(_client_bridge.local_player_id == SESSION, "the client is told who it is")
	_check(_client_game.tick_rate == SERVER_TICK_RATE, "it adopts the server's tick rate", "%d" % _client_game.tick_rate)
	_check(Engine.max_physics_steps_per_frame >= ceili(0.25 * float(SERVER_TICK_RATE)),
		"the engine's step cap covers a quarter second at the adopted rate",
		"%d steps, need %d" % [Engine.max_physics_steps_per_frame, ceili(0.25 * float(SERVER_TICK_RATE))])
	_check(_client_game.players.size() == 3, "it has a body for itself and for both stand-ins", "%d" % _client_game.players.size())
	_finished()


func _test_the_map_arrives() -> void:
	_section("the map arrives, as the document the server built")
	_check(not _client_game.map_doc.is_empty(), "the client built a map")
	_check(MmMapDoc.digest(_client_game.map_doc) == MmMapDoc.digest(_server_game.map_doc),
		"the same document, to the byte", MmMapDoc.digest(_client_game.map_doc))
	_check(_client_game.map.props.size() == _server_game.map.props.size() and _client_game.map.props.size() > 0,
		"every prop in it", "%d" % _client_game.map.props.size())
	_check(_heard.has("map"), "and the client said so")
	_finished()


## The claim the game rests on: a client is told its own role and nobody else's. Everything the
## HUD hides is also not on the wire, so a modified client learns nothing more.
func _test_roles_are_secret() -> void:
	_section("roles are secret: a client is told its own, and everybody else is a bystander to it")
	await _into_play({_me(): &"bystander", _stand_in.player_id: &"murderer", _second.player_id: &"gunner"})
	var roles: Array = _heard["roles"]
	_check(roles.size() == 1 and int(roles[0][0]) == MmGame.BYSTANDERS and not bool(roles[0][1]),
		"the client is told its own role, once, and nobody else's", str(roles))
	_check(_client_bridge.local_role == MmGame.BYSTANDERS and _client_game.team_of(_me()) == MmGame.BYSTANDERS,
		"and plays it")
	_check(_server_game.team_of(_stand_in.player_id) == MmGame.MURDERERS
		and _client_game.team_of(_stand_in.player_id) == MmGame.BYSTANDERS
		and _client_game.team_of(_second.player_id) == MmGame.BYSTANDERS,
		"the murderer is a bystander on the client, as the gunner is", "server %d, client %d" % [
			_server_game.team_of(_stand_in.player_id), _client_game.team_of(_stand_in.player_id)])

	var theirs: MmPlayer = _client_game.players[_stand_in.player_id]
	var gunner: MmPlayer = _client_game.players[_second.player_id]
	_check(theirs.armed() == MmPlayer.ARMED_NONE, "a holstered weapon is not in the murderer's hand on the client")
	_check(_second.has_gun and gunner.has_gun and gunner.armed() == MmPlayer.ARMED_GUN,
		"a gun in a hand is seen, as it is meant to be")
	var _drawn := _server_game.set_weapon_drawn(_stand_in.player_id, true)
	await _steps(8)
	_check(theirs.weapon_drawn and theirs.armed() == MmPlayer.ARMED_WEAPON,
		"a weapon drawn is: that is the tell")
	var _put_away := _server_game.set_weapon_drawn(_stand_in.player_id, false)
	await _steps(8)

	# The online board is dot-server's roster (sessions only); the stand-ins must be added by the
	# game. Both stand-ins here have is_bot false on the client, as in a browser.
	var client_script: GDScript = load("res://game/mm_client.gd")
	var roster := {"players": [{"id": SESSION, "name": "Ada", "ping": 20, "seconds": 5, "bot": false}]}
	client_script.call("add_bot_rows", roster, _client_game)
	client_script.call("add_bot_rows", roster, _client_game)
	var board_ids: Array = []
	for r in (roster["players"] as Array):
		board_ids.append(str((r as Dictionary)["id"]))
	_check((roster["players"] as Array).size() == 3 and board_ids.has(String(_stand_in.player_id))
		and board_ids.has(String(_second.player_id)),
		"the online board gains a row for each stand-in the roster lacks, once however often it is built", str(board_ids))
	_check(not theirs.weapon_drawn and board_ids.count(String(_stand_in.player_id)) == 1,
		"and the murderer's row is one more bystander's")
	_finished()


## A stab is the server's; the client is told it died and how, and never by whom.
func _test_a_stab_crosses() -> void:
	_section("a stab crosses as a death by nobody")
	var server_me := _server_me()
	server_me.place_at(KITCHEN_A, 0.0)
	_stand_in.place_at(KITCHEN_A + Vector3(0.0, 0.0, 1.2), 0.0)
	_second.place_at(LIVING, 0.0)
	var _drawn := _server_game.set_weapon_drawn(_stand_in.player_id, true)
	await _steps(int(_server_game.config.draw_seconds * SERVER_TICK_RATE) + 8)
	_look(_stand_in, KITCHEN_A + Vector3(0.0, 1.2, 0.0))
	var struck := _server_game.attack_now(_stand_in.player_id)
	await _steps(8)
	_check(struck and not server_me.is_alive(), "the murderer stabs the client's player on the server")
	var deaths: Array = _heard["deaths"]
	var mine: Array = deaths.filter(func(d: Array) -> bool: return int(d[0]) == SESSION)
	_check(mine.size() == 1 and mine[0][2] == MmGame.DIED_STABBED, "the client is told it died, and how", str(deaths))
	_check(mine.size() == 1 and int(mine[0][1]) == 0, "and not by whom", str(deaths))
	_check(not _mine().is_alive(), "its own copy is dead")
	var view: Variant = null
	if _client_game.spectate != null and _client_game.spectate.manager != null:
		view = _client_game.spectate.manager.view(String(_me()))
	_check(view == null or str(view.killer) == "", "the spectate camera is given no killer to turn to",
		"none" if view == null else "'%s'" % view.killer)
	_check(_client_game.team_of(_stand_in.player_id) == MmGame.BYSTANDERS, "and the murderer is still a bystander to it")
	_finished()


## The client's player is dead after the stab above, so it is the watcher here.
func _test_free_roam_crosses() -> void:
	_section("free roam is asked for, the server decides, and the mode crosses the wire")
	var spectate := _server_game.spectate
	await _steps(SERVER_TICK_RATE * 4)
	_check(MmRequest.fits() and MmEvents.write_ask_roam().size() == 1,
		"the ROAM request is a kind the codec can write")
	_check(spectate.is_spectating(_me()) and not spectate.is_roaming(_me()),
		"a watcher starts on a player, not in a free camera", str(spectate.mode_of(_me())))
	_check(_client_game.spectate.is_spectating(_me()), "and the client's mirror is watching too")

	_client_bridge.ask_roam()
	await _steps(6)
	_check(spectate.is_roaming(_me()), "the server puts a watcher who asks into the free camera")
	_check(_client_game.spectate.is_roaming(_me()), "and the client's mirror is told ROAMING")

	_client_bridge.ask_roam()
	await _steps(6)
	_check(not spectate.is_roaming(_me()) and not _client_game.spectate.is_roaming(_me()),
		"the same key hands the camera back to a player on both ends")

	_server_game.spectate_rules.allow_roaming = false
	_client_bridge.ask_roam()
	await _steps(6)
	_check(not spectate.is_roaming(_me()) and not _client_game.spectate.is_roaming(_me()),
		"mp_freeroam 0 refuses the request")
	_server_game.spectate_rules.allow_roaming = true

	_server_game.spectate_rules.force_camera = 1
	_client_bridge.ask_roam()
	await _steps(6)
	_check(not spectate.is_roaming(_me()), "mp_forcecamera 1 refuses it too")
	_server_game.spectate_rules.force_camera = 0

	_client_bridge.ask_roam()
	await _steps(6)
	_server_game.spectate_rules.allow_roaming = false
	await _steps(6)
	_check(not spectate.is_roaming(_me()) and not _client_game.spectate.is_roaming(_me()),
		"switching mp_freeroam off mid-roam puts the roamer back on a player on both ends")
	_server_game.spectate_rules.allow_roaming = true
	_finished()


## A shot is everybody's to see: the tracer, the gun falling on a miss, and who picks it up.
func _test_a_shot_crosses() -> void:
	_section("a shot, a dropped gun and a pickup cross")
	await _into_play({_me(): &"murderer", _stand_in.player_id: &"bystander", _second.player_id: &"gunner"})
	var roles: Array = _heard["roles"]
	_check(roles.size() == 1 and int(roles[0][0]) == MmGame.MURDERERS and roles[0][2] == _server_game.weapon_id(),
		"the client is told it is the murderer, and with what", str(roles))
	_check(_client_bridge.local_role == MmGame.MURDERERS and _client_game.team_of(_me()) == MmGame.MURDERERS
		and _client_game.team_of(_second.player_id) == MmGame.BYSTANDERS,
		"it sees itself as one, and the gunner as a bystander")

	_server_me().place_at(LIVING, 0.0)
	_stand_in.place_at(LIVING + Vector3(0.0, 0.0, 2.0), 0.0)
	_second.place_at(KITCHEN_B, 0.0)
	await _steps(8)
	_look(_second, KITCHEN_B + Vector3(-1.5, 0.0, 0.0))
	var fired := _server_game.attack_now(_second.player_id)
	await _steps(8)
	var shots: Array = _heard["shots"]
	_check(fired and shots.size() == 1 and int(shots[0][0]) == MmNetBridge.session_of(_second.player_id) and not bool(shots[0][3]),
		"a miss is told to everybody, by whom, and that it hit nobody", str(shots))
	var guns: Array = _heard["guns"]
	_check(guns.size() == 1 and bool(guns[0][1]) and (guns[0][2] as Vector3).distance_to(KITCHEN_B) < 3.0,
		"the gun falls where the gunner stood, and every client is told", str(guns))
	var shooter: MmPlayer = _client_game.players[_second.player_id]
	_check(not _second.has_gun and not shooter.has_gun, "and it is gone from the gunner's hand on both ends")

	var at: Vector3 = guns[0][2] if guns.size() > 0 else KITCHEN_B
	_second.place_at(LIVING + Vector3(0.0, 0.0, -2.0), 0.0)
	_stand_in.place_at(at, 0.0)
	await _steps(12)
	guns = _heard["guns"]
	var holder: MmPlayer = _client_game.players[_stand_in.player_id]
	_check(guns.size() == 2 and not bool(guns[1][1]) and _stand_in.has_gun and holder.has_gun,
		"a bystander walks onto it and picks it up, and the client sees it go and the gun in their hand", str(guns))
	_finished()


## A shot is judged against the bodies where the shooter saw them, up to a limit. The client's
## latency is simulated by the view lag its command would carry: the target steps aside, and
## the gunner aims at the spot it saw them in.
func _test_a_shot_is_rewound() -> void:
	_section("a shot is rewound to what the shooter saw, and no further than the limit")

	var sent := MmNetCommand.new()
	sent.move = DotFpsCommand.new()
	sent.move.buttons = MmPlayer.ATTACK_BUTTON
	sent.view_lag_q = 25
	var writer := DotNetWriter.new()
	sent._write(writer)
	var got := MmNetCommand.new()
	got._read(DotNetReader.new(writer.to_bytes()))
	_check(got.view_lag_q == 25 and absf(got.view_lag_ticks() - 6.25) < 0.001, "the view lag crosses with a button down")
	var idle := MmNetCommand.new()
	idle.view_lag_q = 25
	var idle_writer := DotNetWriter.new()
	idle._write(idle_writer)
	var idle_got := MmNetCommand.new()
	idle_got._read(DotNetReader.new(idle_writer.to_bytes()))
	_check(idle_got.view_lag_q == -1, "and is not sent when nothing is pressed")

	# Two murderers, so a kill does not end the round before the section does.
	await _into_play({_me(): &"murderer", _stand_in.player_id: &"murderer", _second.player_id: &"gunner"})
	var gunner := _second
	var target := _stand_in
	var seen_at := KITCHEN_A
	var moved_to := KITCHEN_A + Vector3(0.0, 0.0, 1.5)
	gunner.place_at(KITCHEN_B, 0.0)
	_server_me().place_at(LIVING, 0.0)
	target.place_at(seen_at, 0.0)
	await _steps(10)
	target.place_at(moved_to, 0.0)
	var lag := 6
	await _steps(lag)
	_look(gunner, seen_at + Vector3(0.0, 1.0, 0.0))
	var from := gunner.eye_position()
	var aim := gunner.aim_direction()

	_server_game._rewind_to = -1.0
	_check(_server_game.shot_target(gunner, from, aim, 100.0) != target,
		"on the present, a shot at where the target was seen misses it")
	gunner.view_lag = float(lag)
	_server_game._rewind_to = _server_game.unlag_tick_for(gunner)
	var rewound := _server_game.shot_target(gunner, from, aim, 100.0)
	_server_game._rewind_to = -1.0
	_check(rewound == target, "rewound by the lag the shooter saw, it hits",
		"tick %d, to %.1f" % [_server_game.current_tick(), _server_game.unlag_tick_for(gunner)])

	_server_game.max_unlag_ms = 1000.0 * 2.0 / float(SERVER_TICK_RATE)
	_server_game._rewind_to = _server_game.unlag_tick_for(gunner)
	var capped := _server_game.shot_target(gunner, from, aim, 100.0)
	_server_game._rewind_to = -1.0
	_check(capped != target, "a lag beyond the limit is capped, and the shot misses",
		"cap %d ticks, lag %d" % [2, lag])
	_server_game.max_unlag_ms = 0.0
	gunner.view_lag = float(lag)
	_check(_server_game.unlag_tick_for(gunner) == -1.0, "a limit of zero judges everything on the present")
	_server_game.max_unlag_ms = 1000.0

	gunner.view_lag = -1.0
	_check(_server_game.unlag_tick_for(gunner) == -1.0, "a shooter with no measured lag is judged on the present")
	_check(Vector2(_server_game.body_position(target).x - moved_to.x, _server_game.body_position(target).z - moved_to.z).length() < 0.01, "and bodies read where they are")

	# The real shot, through attack_now: the gun, the cooldown and the kill, all on the rewound target.
	gunner.view_lag = float(lag)
	gunner.ready_at = 0.0
	var fired := _server_game.attack_now(gunner.player_id)
	_check(fired and not target.is_alive(), "and a real shot at the remembered spot kills the target",
		"fired %s" % fired)
	_check(gunner.is_alive() and _server_game.team_of(target.player_id) == MmGame.MURDERERS,
		"and it was a murderer, so the gunner lives")
	_check(_server_game.max_unlag_ms == 1000.0 and _server_game._rewind_to == -1.0, "the rewind is put back after a shot")
	gunner.view_lag = -1.0
	_finished()


## The same claim end to end: the client's own command carries the lag it measured from its
## interpolation and the input lead, the server reads it off the wire, and a shot aimed at where
## the client DREW a moving murderer hits it. With the rewind off, or capped to nothing, the same
## shot at the same drawn position misses, because the target has moved on by the lag.
func _test_a_lagged_shot_over_the_link() -> void:
	_section("a shot aimed at what the client drew hits over the link, and not without the rewind")
	await _into_play({_me(): &"gunner", _stand_in.player_id: &"murderer", _second.player_id: &"murderer"})
	var me := _server_me()
	var target := _stand_in
	_second.place_at(LIVING, 0.0)
	me.place_at(KITCHEN_B, 0.0)
	var z := -3.5
	var dz := 0.12
	await _steps(30)

	var results: Array = []
	var lags: Array = []

	# Three trials: the present only, a cap of half a tick, and the full limit.
	for limit in [0.0, 1000.0 * 0.5 / float(SERVER_TICK_RATE), 1000.0]:
		_server_game.max_unlag_ms = limit
		me.has_gun = true
		me.gun_banned = false
		me.ready_at = 0.0
		target.place_at(Vector3(KITCHEN_A.x, 0.05, z), 0.0)
		# Walk it across the kitchen at a run so a few ticks of lag are a body's width.
		for _i in range(24):
			z += dz
			if z > -1.5 or z < -3.5:
				dz = -dz
			target.place_at(Vector3(KITCHEN_A.x, 0.05, z), 0.0)
			await _step()

		var drawn_node: Node3D = _client_game.players[target.player_id]
		var seen := drawn_node.global_position + Vector3(0.0, 1.0, 0.0)
		var fire := _aim_at(_mine(), seen)
		fire.buttons |= MmPlayer.ATTACK_BUTTON
		# One tick down, then released, with the target still walking.
		z += dz
		target.place_at(Vector3(KITCHEN_A.x, 0.05, z), 0.0)
		var heard := -1.0
		await _step(fire)
		for _i in range(INPUT_LEAD + 6):
			z += dz
			if z > -1.5 or z < -3.5:
				dz = -dz
			target.place_at(Vector3(KITCHEN_A.x, 0.05, z), 0.0)
			await _step()
			heard = maxf(heard, me.view_lag)
		results.append(not target.is_alive())
		lags.append(heard)
		if not target.is_alive():
			break

	_check(float(lags[0]) >= 1.0, "the server read the lag the client measured off its command", str(lags))
	_check(not results[0], "judged on the present, the shot at the drawn body misses", str(results))
	_check(results.size() > 1 and not results[1], "a cap of half a tick is no better", str(results))
	_check(results.size() > 2 and results[2], "with the limit open, the same shot kills it", "%s lag %s" % [results, lags])
	_server_game.max_unlag_ms = 1000.0
	_finished()


func _test_the_round_ends() -> void:
	_section("the round ends, and the client is told who won and who the murderer was")
	_server_me().place_at(KITCHEN_A, 0.0)
	_stand_in.place_at(KITCHEN_B, 0.0)
	await _steps(SERVER_TICK_RATE)
	_look(_stand_in, KITCHEN_A + Vector3(0.0, 1.2, 0.0))
	var fired := _server_game.attack_now(_stand_in.player_id)
	await _steps(8)
	var shots: Array = _heard["shots"]
	_check(fired and shots.size() == 2 and bool(shots[1][3]), "the new holder shoots the murderer", str(shots))
	var deaths: Array = _heard["deaths"]
	_check(deaths.size() == 1 and int(deaths[0][0]) == SESSION and int(deaths[0][1]) == 0 and deaths[0][2] == MmGame.DIED_SHOT,
		"the client is told it was shot, by nobody", str(deaths))
	_check(_heard.has("round_over") and int(_heard["round_over"][1]) == MmGame.BYSTANDERS,
		"the bystanders won, and the client is told", str(_heard.get("round_over")))
	_check(_heard.has("round_over") and str(_heard["round_over"][2]).contains("Ada was the murderer"),
		"with the server's own sentence, which names the murderer at last", str(_heard.get("round_over")))
	_finished()


## The toys are the server's physics, drawn on the client from snapshots: the practice house's
## garden has a beach ball, a football, a tyre and a lamp on a switch.
func _test_the_toys_cross() -> void:
	_section("the toys are the server's, and every client sees them where the server has them")
	var server_toys := _server_game.map.toys
	var client_toys := _client_game.map.toys
	_check(server_toys.count() == 5 and client_toys.count() == server_toys.count()
		and _server_bridge.toy_count() == server_toys.count() and _client_bridge.toy_count() == client_toys.count(),
		"both ends build the map's toys, and each is an entity on both", "%d and %d, %d and %d replicated" % [
			server_toys.count(), client_toys.count(), _server_bridge.toy_count(), _client_bridge.toy_count()])
	var ball := server_toys.toy(0)
	var copy := client_toys.toy(0)
	_check(not ball.body.freeze and copy.body.freeze and not copy.authoritative,
		"the server simulates the beach ball; the client's is frozen and drawn")

	var was := copy.body.global_position
	var _kicked := server_toys.use(0, ball.body.global_position + Vector3(-1.0, 1.4, 0.0), Vector3(1.0, -0.3, 0.0))
	await _steps(60)
	_check(ball.body.global_position.distance_to(was) > 1.0 and copy.body.global_position.distance_to(ball.body.global_position) < 0.3,
		"a ball kicked on the server comes to rest on the client where the server has it",
		"moved %.2f m, %.2f m apart" % [ball.body.global_position.distance_to(was), copy.body.global_position.distance_to(ball.body.global_position)])

	var _again := server_toys.use(0, ball.body.global_position + Vector3(0.0, 1.4, 1.0), Vector3(0.0, -0.3, -1.0))
	for _i in range(20):
		await _step()
	var moving := ball.body.linear_velocity.length()
	await _steps(30)
	_check(moving > 0.5 and copy.body.global_position.distance_to(ball.body.global_position) < 0.4,
		"a ball in motion is followed, a snapshot behind", "moving %.1f m/s, %.2f m apart" % [moving, copy.body.global_position.distance_to(ball.body.global_position)])

	var lamp := server_toys.toy(3)
	var switch := server_toys.toy(4)
	var was_lit := lamp.on
	var _pressed := server_toys.use(4, switch.global_position + Vector3(0.0, 1.5, 1.0), Vector3(0.0, -0.4, -1.0))
	await _steps(30)
	_check(lamp.on != was_lit and client_toys.toy(3).on == lamp.on and client_toys.toy(4).count == switch.count and switch.count > 0,
		"the switch is pressed on the server, and the client's lamp goes out with it", "lit %s, count %d" % [client_toys.toy(3).on, client_toys.toy(4).count])
	_finished()


func _test_the_local_player_is_predicted() -> void:
	_section("the client's own player is predicted, and the server agrees")
	var mine := _mine()
	var server_me := _server_me()
	server_me.place_at(Vector3(-2.0, 0.05, 0.0), 0.0)
	await _steps(20)
	var before := mine.controller.state.position
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	await _step(forward)
	_check(mine.controller.state.position.distance_to(before) > 0.01,
		"a key moves the client's own player on the tick it is pressed")
	await _steps(20, forward)
	await _steps(24)
	var apart := mine.controller.state.position.distance_to(server_me.controller.state.position)
	_check(apart < 0.25, "and after running, the two ends agree", "%.3f m" % apart)
	_finished()


## A door is the server's: a use is one event, a door and the tick it went, and the client
## poses it from that and predicts itself against it. The practice house's garden door.
func _test_a_door_crosses() -> void:
	_section("a door is the server's, and the client predicts against it")
	var heard: Array = []
	_client_bridge.door_received.connect(func(index: int, open: bool, tick: int) -> void:
		heard.append([index, open, tick]))
	var server_doors := _server_game.map.doors
	var client_doors := _client_game.map.doors
	var server_me := _server_me()
	var mine := _mine()
	server_me.place_at(Vector3(8.6, 0.05, 0.0), -90.0)
	await _steps(20)

	var _opened := _server_game.use_door(1, _me())
	await _steps(SERVER_TICK_RATE)
	_check(heard.size() == 1 and int(heard[0][0]) == 1 and bool(heard[0][1]) and client_doors.is_open(1),
		"the client is told a door opened, and on which tick", str(heard))
	var server_panel := (server_doors.doors[1]["body"] as Node3D).global_transform
	var client_panel := (client_doors.doors[1]["body"] as Node3D).global_transform
	_check(server_panel.origin.distance_to(client_panel.origin) < 0.05
		and server_panel.basis.z.dot(client_panel.basis.z) > 0.999,
		"and poses it where the server has it", "%.3f m apart" % server_panel.origin.distance_to(client_panel.origin))

	var _shut := _server_game.use_door(1, _me())
	await _steps(SERVER_TICK_RATE)
	var east := DotFpsCommand.new()
	east.yaw = -90.0
	east.move = Vector2(0.0, 1.0)
	await _steps(SERVER_TICK_RATE * 2, east)
	await _steps(24)
	var apart := mine.controller.state.position.distance_to(server_me.controller.state.position)
	_check(not client_doors.is_open(1) and mine.controller.state.position.x < 10.1
		and server_me.controller.state.position.x < 10.1 and apart < 0.25,
		"a shut door stops the client's own prediction where it stops the server",
		"client x %.2f, server x %.2f, %.3f m apart" % [mine.controller.state.position.x, server_me.controller.state.position.x, apart])
	_finished()


## A client whose MAP never came (one past a browser socket's buffer, or a format behind) still
## reads every snapshot. dot-net stops reading one at the first entity a client does not know,
## so the TOYS for a map it has not built are registered as mirrors anyway, and paired with
## its toys when the map arrives. Armed: registering them only once the map was built here
## froze every player seated after the toys.
func _test_a_client_without_the_map() -> void:
	_section("a client without the server's map still follows every player, and pairs the toys when it comes")
	await _steps(4)
	# The server lays out another map (the same house under another id) and this client is sent
	# its TOYS but not its MAP, after losing its own map: a joiner's whose MAP never arrived.
	var other := _server_game.map_doc.duplicate(true)
	other["id"] = "practice_again"
	var ready_peers: Dictionary = _server_bridge.get("_ready_peers")
	ready_peers.erase(CLIENT_PEER)
	var built := _server_game.build_map(other)
	ready_peers[CLIENT_PEER] = true
	_client_game.map.clear()
	_server_bridge._tell(CLIENT_PEER, MmEvents.Kind.TOYS, _server_bridge.get("_toys_body"))
	# Seated after the toys, so listed after them in every snapshot.
	var third := _server_bridge.add_bot("Third")
	third.is_bot = false
	await _steps(8)
	var ids: Array = []
	for behaviour: Node in (_server_bridge.get("_toy_nets") as Array):
		ids.append((behaviour.get("identity") as DotNetIdentity).net_id)
	var known := ids.filter(func(id: int) -> bool: return _client_net.registry.has(id)).size()
	_check(built.ok and ids.size() == 5 and known == ids.size() and _client_bridge.toy_count() == 0,
		"the client registers the new map's toys at once, paired with nothing", "%d of %d known, %d paired" % [known, ids.size(), _client_bridge.toy_count()])

	# Every snapshot read to its end: one abandoned at an unknown toy never says it was applied.
	var applied := [0]
	var count_applied := func(_t: int) -> void: applied[0] += 1
	_client_net.snapshot_applied.connect(count_applied)
	var received := _client_net.stats.snapshots_received
	third.place_at(KITCHEN_B, 0.0)
	await _steps(30)
	_client_net.snapshot_applied.disconnect(count_applied)
	received = _client_net.stats.snapshots_received - received
	var copy: MmPlayer = _client_game.players.get(third.player_id)
	_check(copy != null and copy.global_position.distance_to(third.global_position) < 0.3 and received > 10 and applied[0] == received,
		"and reads every snapshot to its end, a player seated after them included", "%s, %d of %d snapshots applied" % [
			"no copy" if copy == null else "%.2f m apart" % copy.global_position.distance_to(third.global_position), applied[0], received])

	# The MAP arrives late: the same mirrors are handed the toys, nothing registered again.
	_server_bridge._tell(CLIENT_PEER, MmEvents.Kind.MAP, _server_bridge.get("_map_body"))
	await _steps(6)
	var still := ids.filter(func(id: int) -> bool: return _client_net.registry.has(id)).size()
	_check(_client_game.map.id() == &"practice_again" and _client_bridge.toy_count() == 5 and still == ids.size()
		and _client_bridge.toy_entities() == ids.size(),
		"when the map comes, the same mirrors are paired with its toys", "%s, %d paired" % [_client_game.map.id(), _client_bridge.toy_count()])

	var ball := _server_game.map.toys.toy(0)
	var mirror := _client_game.map.toys.toy(0)
	var _kicked := _server_game.map.toys.use(0, ball.body.global_position + Vector3(-1.0, 1.4, 0.0), Vector3(1.0, -0.3, 0.0))
	await _steps(50)
	_check(ball.body.global_position.distance_to(ball.rest.origin) > 1.0 and mirror.body.global_position.distance_to(ball.body.global_position) < 0.3,
		"and a ball kicked on the server is followed on the client", "%.2f m apart" % mirror.body.global_position.distance_to(ball.body.global_position))

	# A TOYS again (a resend, or a new set): the old mirrors leave the tree at once as well as
	# the registry, or a new identity beside a freed one collects it and the next snapshot breaks.
	_server_bridge._tell(CLIENT_PEER, MmEvents.Kind.TOYS, _server_bridge.get("_toys_body"))
	await _steps(2)
	var holder: Node = _client_bridge.get("_toy_holder")
	_check(holder != null and holder.get_child_count() == 5 and _client_bridge.toy_count() == 5,
		"a second TOYS replaces the mirrors, and nothing of the first is left", "%d under the holder" % (holder.get_child_count() if holder != null else -1))
	_finished()


func _test_leaving() -> void:
	_section("leaving")
	_server_bridge.remove_peer(CLIENT_PEER)
	await _steps(4)
	_check(not _server_game.players.has(_me()), "the server lets them go")
	_check(_server_bridge.describe()["ready_peers"] == 0, "and stops talking to them")
	_finished()
