extends DotGameCheckSuite

const MmConfig := preload("../game/mm_config.gd")
const MmGame := preload("../game/mm_game.gd")
const MmPlayer := preload("../game/mm_player.gd")

## Stand-ins play whole rounds against each other on the real maps, and the suite holds what
## they do to bands: the murderer kills in most rounds without winning every one, the gun is
## fired and fetched, draws are not far over stabs, bystanders keep together, talk is rationed
## and nobody stays stuck. `-- --rounds N`, `--first N`, `--difficulty hard`, `MM_BOTS_TRACE=1`.

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

const SECTIONS := 2
const CHECKS := 14

var _entered := 0
var _completed := 0


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

	var only := ""
	at = args.find("--map")
	if at >= 0 and at + 1 < args.size():
		only = args[at + 1]

	var linked := DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://maps"))
	var results: Array[Dictionary] = []

	_section("%d rounds of stand-ins at %s%s" % [rounds, difficulty, "" if linked else " (no maps/: the practice house)"])
	for r in range(first, first + rounds):
		var map_id: String = only if only != "" else (MAPS[(r / 2) % MAPS.size()] if linked else "mm_practice")
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
	var stuck_where := ""
	for r in results:
		draws += int(r["draws"])
		stabs += int(r["stabs"])
		lines += int(r["lines"])
		spread += float(r["spread"]) / n
		if float(r["stuck"]) > stuck:
			stuck = float(r["stuck"])
			stuck_where = str(r["stuck_where"])
		if int(r["drops"]) > 0:
			fetch_chances += 1
			fetched += 1 if int(r["fetched"]) > 0 else 0

	_check(float(killing) / n >= MIN_KILLING, "the murderer kills somebody in most rounds", "%d of %d" % [killing, results.size()])
	_check(float(murderer_wins) / n <= MAX_MURDERER_WINS or results.size() < 4, "and does not win them all", "%d of %d" % [murderer_wins, results.size()])
	_check(shot_rounds > 0, "somebody fires the gun", "in %d of %d rounds" % [shot_rounds, results.size()])
	_check(fetch_chances == 0 or fetched > 0, "a gun on the floor is fetched", "in %d of %d rounds it lay there" % [fetched, fetch_chances])
	_check(draws <= stabs * 3 + results.size() * 2, "a murderer draws to strike, not to wave it about", "%d draws, %d stabs" % [draws, stabs])
	_check(spread <= MAX_SPREAD and lines > 0, "the bystanders keep together and talk", "%.1f m to the nearest, %d lines" % [spread, lines])
	_check(stuck <= MAX_STUCK, "nobody stays stuck for long", "%.1f s, %s" % [stuck, stuck_where])
	_completed += 1

	await _test_grenades()
	_report_sections(_entered, _completed, SECTIONS, CHECKS)


func _test_grenades() -> void:
	_section("a stand-in does not see through smoke, and is blind while flashed")
	var config := MmConfig.new()
	config.minimum_players = 0
	config.map_ids = PackedStringArray(["mm_practice"])
	var game := MmGame.new()
	game.config = config
	game.tick_rate = TICK_RATE
	game.authoritative = true
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	await get_tree().physics_frame
	var me := game.add_player(&"u1", "Me")
	var other := game.add_player(&"u2", "Other")
	game.start()
	for _i in range(4):
		game.simulate(TICK)
		await get_tree().physics_frame

	var bots: Object = game.bots
	var spot: Vector3 = me.controller.state.position
	var face := func() -> void:
		me.controller.state.position = spot
		other.controller.state.position = spot + Vector3(2.0, 0.0, 0.0)
		me.controller.state.yaw = -90.0
		me.controller.state.pitch = 0.0
	face.call()
	_check(bots._sees(me, other), "before any smoke it sees the other")
	var mid: Vector3 = me.eye_position().lerp(other.eye_position(), 0.5)
	var _id: int = bots.add_smoke(mid, 0.8, 5.0)
	_check(not bots._sees(me, other), "with a cloud between them it does not")
	for _i in range(6 * TICK_RATE):
		game.simulate(TICK)
	face.call()
	_check(bots._sees(me, other), "when the cloud ends it does again")
	bots.blind_for(me.player_id, 2.0)
	_check(not bots._sees(me, other), "a flashed stand-in sees nothing")
	_check(bots.is_blind(me.player_id), "and is blind")
	for _i in range(3 * TICK_RATE):
		game.simulate(TICK)
	face.call()
	_check(not bots.is_blind(me.player_id), "the flash wears off")
	_check(bots._sees(me, other), "and it sees again")
	_completed += 1
	remove_child(game)
	game.free()
	await get_tree().process_frame


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
	result["stuck_where"] = "%s at %s" % [game.bots.longest_stuck_who, str(game.bots.longest_stuck_at.snapped(Vector3.ONE * 0.1))] if game.bots.longest_stuck > 0.0 else ""
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

