extends Node

const MmConfig := preload("../game/mm_config.gd")
const MmGame := preload("../game/mm_game.gd")
const MmPlayer := preload("../game/mm_player.gd")

## Stand-ins play whole rounds against each other on the real maps, and the suite holds what
## they do to bands.
##
## [b]Why rounds, not a unit test.[/b] Whether a murderer bot is any good is whether it kills
## anybody before the clock, and whether the bystanders are any good is whether the gun ever
## finds it. So this plays rounds (eight stand-ins, the game drawing its own murderer and gun
## by its default rules, `bot_difficulty medium`) and checks:
##
## - that the murderer kills somebody in most rounds, and does not win every round;
## - that somebody fires the gun in some rounds, and a gun on the floor is fetched when one lies
##   in view;
## - that a murderer draws only when it means to (draws are not far over stabs);
## - that the bystanders keep together during the grace (mean distance to the nearest other);
## - that they talk, rationed;
## - that no stand-in stays stuck for long.
##
## Eight rounds by default, two a map. `-- --rounds N` plays another number, `-- --first N`
## starts at the Nth round's map and seed, `-- --difficulty hard` plays another preset, and
## `MM_BOTS_TRACE=1` prints every death as it happens. Without `maps/` linked it plays the
## practice house.

## Maps the rounds rotate through, when `maps/` is there: ours, and one of each other game's
## that is mounted.
const MAPS := ["mm_mansion", "mm_motel", "hs_manor", "ph_house"]

var TICK_RATE := 32
var TICK := 1.0 / float(TICK_RATE)
const BOTS := 8

## The share of rounds in which the murderer kills at least once.
const MIN_KILLING := 0.6

## The share of rounds the murderers may win at most: a murderer that always wins is a broken
## bystander.
const MAX_MURDERER_WINS := 0.9

## Mean metres from each bystander to the nearest other person when the grace ends.
const MAX_SPREAD := 12.0

## The longest any stand-in may stay stuck, in seconds.
const MAX_STUCK := 12.0

const SECTIONS := 1
const CHECKS := 7

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0
var _failures := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	# The world ticks itself (simulate) and waits for a physics frame after each tick so doors
	# and bodies are where the physics server says; physics frames come at their rate in real
	# time, so a fast rate lets a round of minutes play in seconds.
	Engine.physics_ticks_per_second = 1920
	Engine.max_physics_steps_per_frame = 64
	_run.call_deferred()


func _run() -> void:
	print("murder bots")
	print("")
	var args := OS.get_cmdline_user_args()
	var rounds := 8
	var at := args.find("--rounds")
	if at >= 0 and at + 1 < args.size():
		rounds = maxi(1, int(args[at + 1]))
	var difficulty := "medium"
	at = args.find("--difficulty")
	if at >= 0 and at + 1 < args.size():
		difficulty = args[at + 1]
	var first := 0
	at = args.find("--first")
	if at >= 0 and at + 1 < args.size():
		first = maxi(0, int(args[at + 1]))

	var linked := DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://maps"))
	var results: Array[Dictionary] = []

	_section("%d rounds of stand-ins at %s%s" % [rounds, difficulty, "" if linked else " (no maps/: the practice house)"])
	for r in range(first, first + rounds):
		var map_id: String = MAPS[(r / 2) % MAPS.size()] if linked else "mm_practice"
		var result := await _round(map_id, r, difficulty)
		results.append(result)
		print("  round %2d %-12s %-9s in %5.1f s  dead %d of %d  first kill %5.1f s  draws %d stabs %d shots %d fetched %d lines %d  spread %4.1f m  stuck %4.1f s" % [
			r + 1, map_id, result["winner"], result["seconds"], result["dead"], BOTS, minf(float(result["first_kill"]), 999.0),
			result["draws"], result["stabs"], result["shots"], result["fetched"], result["lines"], result["spread"], result["stuck"]])

	var n := float(results.size())
	var killing := results.filter(func(r: Dictionary) -> bool: return int(r["kills"]) > 0).size()
	var murderer_wins := results.filter(func(r: Dictionary) -> bool: return r["winner"] == "murderer").size()
	var shot_rounds := results.filter(func(r: Dictionary) -> bool: return int(r["shots"]) > 0).size()
	var draws := 0
	var stabs := 0
	var lines := 0
	var fetch_chances := 0
	var fetched := 0
	var spread := 0.0
	var stuck := 0.0
	for r in results:
		draws += int(r["draws"])
		stabs += int(r["stabs"])
		lines += int(r["lines"])
		spread += float(r["spread"]) / n
		stuck = maxf(stuck, float(r["stuck"]))
		if int(r["drops"]) > 0:
			fetch_chances += 1
			fetched += 1 if int(r["fetched"]) > 0 else 0

	_check(float(killing) / n >= MIN_KILLING, "the murderer kills somebody in most rounds", "%d of %d" % [killing, results.size()])
	_check(float(murderer_wins) / n <= MAX_MURDERER_WINS or results.size() < 4, "and does not win them all", "%d of %d" % [murderer_wins, results.size()])
	_check(shot_rounds > 0, "somebody fires the gun", "in %d of %d rounds" % [shot_rounds, results.size()])
	_check(fetch_chances == 0 or fetched > 0, "a gun on the floor is fetched", "in %d of %d rounds it lay there" % [fetched, fetch_chances])
	_check(draws <= stabs * 3 + results.size() * 2, "a murderer draws to strike, not to wave it about", "%d draws, %d stabs" % [draws, stabs])
	_check(spread <= MAX_SPREAD and lines > 0, "the bystanders keep together and talk", "%.1f m to the nearest, %d lines" % [spread, lines])
	_check(stuck <= MAX_STUCK, "nobody stays stuck for long", "%.1f s" % stuck)
	_completed += 1

	print("")
	print("%d sections entered, %d finished" % [_entered, _completed])
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	var code := 1 if _failed > 0 else 0
	if _entered != SECTIONS or _completed != SECTIONS or _passed + _failed != CHECKS:
		print("ERROR: %d of %d sections, %d of %d checks." % [_completed, SECTIONS, _passed + _failed, CHECKS])
		code = 1
	get_tree().quit(code)


func _round(map_id: String, index: int, difficulty: String) -> Dictionary:
	var config := MmConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.keep_progress = false
	config.map_ids = PackedStringArray([map_id])
	config.seed_value = 20261018 + index * 7919
	config.round_seconds = 150.0
	config.grace_seconds = 8.0

	var game := MmGame.new()
	game.name = "Bots_%d" % index
	game.config = config
	game.tick_rate = TICK_RATE
	game.authoritative = true
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	var _set := DotBotSettings.of(game).set_difficulty(difficulty)
	await get_tree().physics_frame

	for i in range(BOTS):
		var bot := game.add_player(StringName("u%d" % (900 + i)), "Bot%d" % i)
		bot.is_bot = true

	var result := {"winner": "none", "seconds": 0.0, "dead": 0, "kills": 0, "first_kill": INF, "drops": 0, "spread": 0.0}
	var trace := OS.has_environment("MM_BOTS_TRACE")
	game.player_died.connect(func(id: StringName, by: StringName, why: StringName) -> void:
		if why == MmGame.DIED_FELL:
			return
		result["dead"] = int(result["dead"]) + 1
		if game.team_of(by) == MmGame.MURDERERS and by != id:
			result["kills"] = int(result["kills"]) + 1
			result["first_kill"] = minf(float(result["first_kill"]), game.play_elapsed)
		if trace:
			print("    %5.1f s  %s %s by %s" % [game.play_elapsed, id, why, by]))
	game.gun_dropped.connect(func(_d: int, _at: Vector3) -> void: result["drops"] = int(result["drops"]) + 1)
	var decided := false
	game.round_over.connect(func(_n: int, winner: int, _why: String) -> void:
		decided = true
		result["winner"] = "murderer" if winner == MmGame.MURDERERS else ("bystanders" if winner == MmGame.BYSTANDERS else "nobody"))
	game.start()

	var limit := int((config.grace_seconds + config.round_seconds + 10.0) * TICK_RATE)
	var spread_taken := false
	for tick in range(limit):
		game.simulate(TICK)
		await get_tree().physics_frame
		if not spread_taken and game.phase == MmGame.Phase.PLAY:
			spread_taken = true
			result["spread"] = _spread(game)
		if decided:
			break

	result["seconds"] = game.play_elapsed
	var counts: Dictionary = game.bots.counts
	for key: String in ["draws", "stabs", "shots", "fetched", "lines"]:
		result[key] = int(counts.get(key, 0))
	result["stuck"] = game.bots.longest_stuck
	remove_child(game)
	game.free()
	await get_tree().process_frame
	return result


## Mean distance from each bystander to the nearest other living person.
func _spread(game: MmGame) -> float:
	var total := 0.0
	var n := 0
	for p in game.players_on(MmGame.BYSTANDERS):
		var best := INF
		for q: MmPlayer in game.players.values():
			if q != p and q.is_alive():
				best = minf(best, p.controller.state.position.distance_to(q.controller.state.position))
		if best < INF:
			total += best
			n += 1
	return total / float(maxi(n, 1))


func _section(name: String) -> void:
	_entered += 1
	print(name)


func _check(ok: bool, what: String, detail: String = "") -> void:
	var line := "%s%s" % [what, "" if detail == "" else "  (%s)" % detail]
	if ok:
		_passed += 1
		print("  ok    %s" % line)
		return
	_failed += 1
	_failures.append(line)
	print("  FAIL  %s" % line)
