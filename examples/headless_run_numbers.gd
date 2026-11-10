extends "headless_run_flashlight.gd"

const MmBotChat := preload("../game/mm_bot_chat.gd")
const MmProgress := preload("../game/mm_progress.gd")

## The headless_run sections about what the round is worth and who plays it: the numbers dot-stats
## keeps, the bots' chat and the bots themselves. headless_run.gd runs them through its parents.


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

	var _held := DotStatsValues.new()
	_held.values = {String(MmProgress.KILLS): 10.0}
	game.progress.rank.seed_baseline(&"rank-probe", _held)
	var _life: float = game.progress.rank.publish_lifetime(&"rank-probe", DotStatsValues.new(), game.progress.stats.schema)
	_check(game.progress.stats.schema.has(MmProgress.RANK_SCORE) and _life == 10.0,
		"rank_score is declared and ranks on a stored lifetime baseline", "%.1f" % _life)
	game.progress.rank.forget(&"rank-probe")
	_check(of.call(m.player_id, MmProgress.RANK_SCORE) == 1.0, "a kill files a rank_score of 1", str(of.call(m.player_id, MmProgress.RANK_SCORE)))

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
