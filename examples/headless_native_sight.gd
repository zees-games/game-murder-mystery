extends GSGameCheckSuite

const MmBots := preload("../game/mm_bots.gd")
const MmConfig := preload("../game/mm_config.gd")
const MmGame := preload("../game/mm_game.gd")

## The bots' line of sight ([code]_los[/code]) is asked of dot-sim's `GSSimSightRay.clear_to` when the library has it,
## and it must answer as the game's `_clear_between(a, b, true)` does: seeded rays over every map (some too short to
## cast, some from inside the furniture) give the same answer to the bit; [member MmBots.native_sight] off keeps the
## script; and a bot round with [member MmBots.sight_verify] on re-runs the script beside every live ray with no
## difference. With no library the native half is skipped; [code]GS_SIM_REQUIRE_NATIVE=1[/code] (CI) fails instead.

## The maps asked about: all of these when `maps/` is linked in, else the practice house (CI).
const MAPS := ["mm_practice", "mm_mansion", "mm_motel", "mm_factory_winter", "mm_open_yard", "mm_villa"]
const RAYS := 3000
const BENCH_REPS := 6
## The live bot round: bots and ticks at the soak's rate.
const BOTS := 16
const LIVE_TICKS := 1200
const LIVE_RATE := 32

var _entered := 0
var _finished := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("Murder Mystery native sight")
	print("")
	_entered += 1
	print("the library has the sight ray")
	var native := GSSim.has(&"sight") and ClassDB.class_has_method(&"GSSimSightRay", &"clear_to")
	if not native:
		print("  dot-sim's sight module (with clear_to) is not loaded: the native half is skipped")
		var required := (OS.get_environment("GS_SIM_REQUIRE_NATIVE") if OS.has_environment("GS_SIM_REQUIRE_NATIVE") else OS.get_environment("DOT_SIM_REQUIRE_NATIVE")) == "1"
		_check(not required, "the library is loaded (GS_SIM_REQUIRE_NATIVE=1)")
		_finished += 1
		_report_sections(_entered, _finished, 1, 1)
		return
	_check(MmBots.native_sight, "MmBots.native_sight is on without the game turning it on")
	_finished += 1

	var linked := DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://maps"))
	var maps: Array = MAPS if linked else ["mm_practice"]
	var checks := 1

	for id: String in maps:
		_entered += 1
		await _seeded_rays(StringName(id))
		checks += 2
		_finished += 1

	_entered += 1
	await _off_and_bench(StringName("mm_mansion" if linked else "mm_practice"))
	checks += 2
	_finished += 1

	_entered += 1
	await _live_round(StringName("mm_mansion" if linked else "mm_practice"))
	checks += 2
	_finished += 1

	_report_sections(_entered, _finished, 3 + maps.size(), checks)


## [constant RAYS] seeded rays over [param id]'s bounds through the bots' bound ray against `_clear_between`.
func _seeded_rays(id: StringName) -> void:
	print("seeded rays on %s: native against the script" % id)
	var game := await _world(id)
	var bots: Object = game.bots
	bots.call("_sight_bind")
	var rays := _rays(game, hash(String(id)) ^ 0x51647)
	var blocked := 0
	var first := ""
	var differ := 0
	for ray: Array in rays:
		var got: bool = bots.call("_los", ray[0], ray[1])
		var want: bool = game._clear_between(ray[0], ray[1], true)
		blocked += 0 if want else 1
		if got != want:
			differ += 1
			if first.is_empty():
				first = "%s to %s: native %s, script %s" % [ray[0], ray[1], got, want]
	_check(bots.get("_sight") != null, "%s: the bots ask the native ray" % id)
	_check(differ == 0 and blocked > rays.size() / 20 and blocked < rays.size(), "%s: %d rays, %d blocked, every answer the script's" % [id, rays.size(), blocked], "%d differ; first %s" % [differ, first])
	await _dispose(game)


## [member MmBots.native_sight] off asks the script; then the cost of one ray either way, alternated, on the same rays.
func _off_and_bench(id: StringName) -> void:
	print("native_sight off keeps the script; the cost of a ray")
	var game := await _world(id)
	var bots: Object = game.bots
	MmBots.native_sight = false
	bots.call("_sight_bind")
	_check(bots.get("_sight") == null, "native_sight off binds no native ray")
	MmBots.native_sight = true
	var rays := _rays(game, 99)
	var spent := {"native": 0, "script": 0}
	var same := true
	for rep in range(BENCH_REPS):
		for mode: String in (["native", "script"] if rep % 2 == 0 else ["script", "native"]):
			MmBots.native_sight = mode == "native"
			bots.call("_sight_bind")
			var start := Time.get_ticks_usec()
			for ray: Array in rays:
				bots.call("_los", ray[0], ray[1])
			spent[mode] += Time.get_ticks_usec() - start
	MmBots.native_sight = true
	for ray: Array in rays:
		same = same and bool(bots.call("_los", ray[0], ray[1])) == game._clear_between(ray[0], ray[1], true)
	_check(same, "the native ray answers as the script after the bench")
	var calls := float(rays.size() * BENCH_REPS / 2)
	print("  bench %d rays on %s: script %.2f us, native %.2f us per ray" % [calls, id, spent["script"] / calls, spent["native"] / calls])
	await _dispose(game)


## A bot round with sight_verify on, the script beside every live ray.
func _live_round(id: StringName) -> void:
	print("a bot round on %s with sight_verify: the script beside every live ray" % id)
	MmBots.sight_checked = 0
	MmBots.sight_differ = 0
	MmBots.sight_verify = true
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
	MmBots.sight_verify = false
	_check(MmBots.sight_checked > 1000, "the bots cast rays", "%d rays" % MmBots.sight_checked)
	_check(MmBots.sight_differ == 0, "no live ray differed", "%d of %d" % [MmBots.sight_differ, MmBots.sight_checked])
	print("  %d live rays checked, %d differed" % [MmBots.sight_checked, MmBots.sight_differ])


## `[from, to]` pairs over the map: between its solid bodies (eye and chest heights), some along a wall, some too short
## to cast.
func _rays(game: Node3D, seed_value: int) -> Array:
	var points: Array[Vector3] = []
	for node: Node in game.find_children("*", "CollisionObject3D", true, false):
		points.append((node as Node3D).global_position)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var out: Array = []
	for i in range(RAYS):
		var a := points[rng.randi() % points.size()] + Vector3(rng.randf_range(-3.0, 3.0), rng.randf_range(0.2, 1.8), rng.randf_range(-3.0, 3.0))
		var b := points[rng.randi() % points.size()] + Vector3(rng.randf_range(-3.0, 3.0), rng.randf_range(0.2, 1.8), rng.randf_range(-3.0, 3.0))
		if i % 40 == 0:
			b = a + Vector3(0.00003, 0.0, 0.00004)
		elif i % 7 == 0:
			b = a + Vector3(rng.randf_range(-1.0, 1.0), 0.0, rng.randf_range(-1.0, 1.0))
		out.append([a, b])
	return out


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
