extends DotGameCheckSuite

const MmConfig := preload("../game/mm_config.gd")
const MmDoors := preload("../game/mm_doors.gd")
const MmGame := preload("../game/mm_game.gd")
const MmMapDoc := preload("../game/mm_map_doc.gd")

## Which door somebody would use ([method MmDoors.door_for]) is asked of dot-sim's `DotSimDoorReach` when the library is
## there, and it must answer as the script does: seeded poses (shut, open, flipped, part way), eyes round each door and
## aims any way (some none at all) and reaches on every map with doors give the same door to the bit; a world built with
## [member MmDoors.native_reach] off keeps the script and answers the same; and a bot round with
## [member MmDoors.reach_verify] on re-runs the script beside every live ask with no difference.
## With no library the native half is skipped; [code]GS_SIM_REQUIRE_NATIVE=1[/code] (CI) fails instead.

## The maps asked about: all of these when `maps/` is linked in, else the practice house (CI).
const MAPS := ["mm_practice", "mm_mansion", "mm_motel", "mm_silence_hollow", "mm_factory_winter", "mm_open_yard", "mm_office_murder", "mm_murder_mansion", "mm_deco_mansion", "mm_villa", "mm_functionalist_night", "mm_sunken_resort", "mm_rooftops_2016"]
const SECTIONS := 4
const CHECKS := 8
const BENCH_ASKS := 4000
const BENCH_REPS := 6
## Pose rounds per map, and asks per round.
const ROUNDS := 30
const ASKS := 60
## The live bot round: bots and ticks at the soak's rate.
const BOTS := 12
const LIVE_TICKS := 1600
const LIVE_RATE := 32

var _entered := 0
var _finished := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("Murder Mystery native door reach")
	print("")
	_entered += 1
	print("the library has the door reach")
	if not DotSim.has(&"doors"):
		print("  dot-sim's doors module is not loaded: the native half is skipped")
		var required := (OS.get_environment("GS_SIM_REQUIRE_NATIVE") if OS.has_environment("GS_SIM_REQUIRE_NATIVE") else OS.get_environment("DOT_SIM_REQUIRE_NATIVE")) == "1"
		_check(not required, "the library is loaded (GS_SIM_REQUIRE_NATIVE=1)")
		_finished += 1
		_report_sections(_entered, _finished, 1, 1)
		return
	_check(MmDoors.native_reach, "MmDoors.native_reach is on without the game turning it on")
	_finished += 1

	var linked := DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://maps"))
	var maps: Array = MAPS if linked else ["mm_practice"]

	_entered += 1
	print("seeded poses, eyes, aims and reaches on %d maps: native against the script" % maps.size())
	var asked := 0
	var hits := 0
	var differ: Array[String] = []
	var unbuilt: Array[String] = []
	for id: String in maps:
		var game := await _world(StringName(id))
		var doors: MmDoors = game.map.doors if game.map != null else null
		if doors == null or doors.count() == 0:
			await _dispose(game)
			continue
		if doors._reach == null:
			unbuilt.append(id)
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(id) ^ 0x5eed
		for round in range(ROUNDS):
			_pose_randomly(doors, rng)
			for _ask in range(ASKS):
				var q := _question(doors, rng)
				var native := doors.door_for(q[0], q[1], q[2])
				var script := doors.door_for_script(q[0], q[1], q[2])
				asked += 1
				if native >= 0:
					hits += 1
				if native != script and differ.size() < 8:
					differ.append("%s round %d: native %d script %d eyes %s aim %s reach %s" % [id, round, native, script, q[0], q[1], q[2]])
		await _dispose(game)
	_check(unbuilt.is_empty(), "every map with doors asks the native table", ", ".join(unbuilt))
	_check(differ.is_empty(), "every ask gives the same door", "; ".join(differ))
	_check(asked >= ROUNDS * ASKS and hits > asked / 10 and hits < asked, "the asks found doors and missed them", "%d asks, %d found a door" % [asked, hits])
	print("  %d asks, %d found a door" % [asked, hits])
	_finished += 1

	_entered += 1
	print("native_reach off keeps the script, with the same answers")
	var first := StringName("mm_mansion" if linked else maps[0])
	var on_game := await _world(first)
	MmDoors.native_reach = false
	var off_game := await _world(first)
	MmDoors.native_reach = true
	var on_doors: MmDoors = on_game.map.doors
	var off_doors: MmDoors = off_game.map.doors
	_check(off_doors._reach == null and on_doors._reach != null, "native_reach off builds no native table")
	var same := true
	var rng_on := RandomNumberGenerator.new()
	var rng_off := RandomNumberGenerator.new()
	rng_on.seed = 77
	rng_off.seed = 77
	for _round in range(ROUNDS):
		_pose_randomly(on_doors, rng_on)
		_pose_randomly(off_doors, rng_off)
		for _ask in range(ASKS):
			var q := _question(on_doors, rng_on)
			var _q2 := _question(off_doors, rng_off)
			same = same and on_doors.door_for(q[0], q[1], q[2]) == off_doors.door_for(q[0], q[1], q[2])
	_check(same, "a script world and a native world pick the same doors")
	# The cost of one ask either way, on the same world and the same asks, alternated.
	var asks: Array = []
	for _ask in range(BENCH_ASKS):
		asks.append(_question(on_doors, rng_on))
	var spent := {"native": 0, "script": 0}
	for rep in range(BENCH_REPS):
		for mode: String in (["native", "script"] if rep % 2 == 0 else ["script", "native"]):
			var start := Time.get_ticks_usec()
			for q: Array in asks:
				if mode == "native":
					on_doors.door_for(q[0], q[1], q[2])
				else:
					on_doors.door_for_script(q[0], q[1], q[2])
			spent[mode] += Time.get_ticks_usec() - start
	var calls := float(BENCH_ASKS * BENCH_REPS)
	print("  bench %d asks over %d doors on %s: script %.2f us, native %.2f us per ask" % [calls, on_doors.count(), first, spent["script"] / calls, spent["native"] / calls])
	await _dispose(on_game)
	await _dispose(off_game)
	_finished += 1

	_entered += 1
	var live_map := "mm_mansion" if linked else "mm_practice"
	print("a bot round on %s with reach_verify: the script beside every live ask" % live_map)
	MmDoors.reach_checked = 0
	MmDoors.reach_differ = 0
	MmDoors.reach_verify = true
	await _bot_round(StringName(live_map))
	MmDoors.reach_verify = false
	_check(MmDoors.reach_checked > 0, "the bots asked for doors", "%d asks" % MmDoors.reach_checked)
	_check(MmDoors.reach_differ == 0, "no live ask differed", "%d of %d" % [MmDoors.reach_differ, MmDoors.reach_checked])
	print("  %d live asks checked, %d differed" % [MmDoors.reach_checked, MmDoors.reach_differ])
	_finished += 1

	_report_sections(_entered, _finished, SECTIONS, CHECKS)


## Every door set off or left at rest, either way, then posed on a tick that leaves some part way.
func _pose_randomly(doors: MmDoors, rng: RandomNumberGenerator) -> void:
	for index in range(doors.count()):
		var since := -1 if rng.randf() < 0.4 else rng.randi_range(0, 120)
		doors.apply(index, rng.randf() < 0.5, rng.randf() < 0.5, since)
	doors.pose_at(rng.randi_range(0, 200))


## `[eyes, aim, reach]`: eyes round a random door (sometimes in its panel), an aim at it, anywhere or nowhere, and the
## game's reaches or any.
func _question(doors: MmDoors, rng: RandomNumberGenerator) -> Array:
	var index := rng.randi_range(0, doors.count() - 1)
	var middle := (doors.doors[index]["body"] as Node3D).transform.origin
	var eyes := middle
	if rng.randf() > 0.03:
		eyes += Vector3(rng.randf_range(-3.0, 3.0), rng.randf_range(-1.0, 1.2), rng.randf_range(-3.0, 3.0))
	var aim := Vector3.ZERO
	var pick := rng.randf()
	if pick < 0.45:
		aim = (middle - eyes) * rng.randf_range(0.2, 3.0) + Vector3(rng.randfn(), rng.randfn(), rng.randfn()) * 0.3
	elif pick < 0.95:
		aim = Vector3(rng.randfn(), rng.randfn(), rng.randfn()) * rng.randf_range(0.1, 4.0)
	var reach: float = [MmDoors.REACH, 1.6, rng.randf_range(0.0, 4.0)][rng.randi_range(0, 2)]
	return [eyes, aim, reach]


## A server round with bots on [param id], as `tools/soak.gd` plays one, for [constant LIVE_TICKS] ticks.
func _bot_round(id: StringName) -> void:
	var config := MmConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 2.0
	config.minimum_players = 0
	config.keep_progress = false
	config.map_ids = PackedStringArray([String(id)])
	config.seed_value = 4242
	config.round_seconds = 150.0
	config.grace_seconds = 8.0
	var game := MmGame.new()
	game.config = config
	game.tick_rate = LIVE_RATE
	game.authoritative = true
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	await get_tree().physics_frame
	for i in range(BOTS):
		var bot := game.add_player(StringName("u%d" % (900 + i)), "Bot%d" % i)
		bot.is_bot = true
	game.start()
	for _tick in range(LIVE_TICKS):
		game.simulate(1.0 / float(LIVE_RATE))
		await get_tree().physics_frame
	await _dispose(game)


func _world(id: StringName) -> MmGame:
	var config := MmConfig.new()
	config.warmup_seconds = 0.0
	config.minimum_players = 0
	config.keep_progress = false
	config.map_ids = PackedStringArray([String(id)])
	var game := MmGame.new()
	game.name = "World_%s" % String(id)
	game.config = config
	game.tick_rate = 60
	game.authoritative = true
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	await get_tree().physics_frame
	await get_tree().physics_frame
	return game


func _dispose(game: MmGame) -> void:
	remove_child(game)
	game.free()
	await get_tree().process_frame
