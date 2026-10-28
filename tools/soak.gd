extends Node

const MmConfig := preload("../game/mm_config.gd")
const MmGame := preload("../game/mm_game.gd")

## Bot soak on the real game: N stand-ins play rounds back to back on one map for M simulated
## minutes through dot-bot's DotBotSoak (`./game.sh soak [map] [minutes]`). Writes
## `.godot/test-logs/soak-<map>.json`, prints the SOAK line, exits 1 when the run fails.

const DEFAULT_MAP := "mm_mansion"
const DEFAULT_MINUTES := 1.0
const DEFAULT_BOTS := 8
const TICK_RATE := 32

var _game: MmGame
var _kills := 0
var _deaths := 0
var _rounds := 0
var _trace := OS.get_cmdline_user_args().has("--trace")


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--" + name)
	if at >= 0 and at + 1 < args.size():
		return args[at + 1]
	return fallback


func _run() -> void:
	var map_id := _arg("map", DEFAULT_MAP)
	var cfg := DotBotSoakConfig.new()
	cfg.minutes = DEFAULT_MINUTES
	cfg.bots = DEFAULT_BOTS
	cfg.apply_cli()
	cfg.minutes = float(_arg("minutes", str(cfg.minutes)))
	cfg.bots = int(_arg("bots", str(cfg.bots)))

	var config := MmConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 2.0
	config.minimum_players = 0
	config.keep_progress = false
	config.map_ids = PackedStringArray([map_id])
	config.seed_value = cfg.seed_value
	config.round_seconds = 150.0
	config.grace_seconds = 8.0

	_game = MmGame.new()
	_game.config = config
	_game.tick_rate = TICK_RATE
	_game.authoritative = true
	_game.register_service = false
	add_child(_game)
	_game.set_physics_process(false)
	await get_tree().physics_frame
	if _game.map == null:
		_fail("map %s did not build" % map_id)
		return
	for i in range(cfg.bots):
		var bot := _game.add_player(StringName("u%d" % (900 + i)), "Bot%d" % i)
		bot.is_bot = true
	_game.player_died.connect(_on_died)
	_game.round_over.connect(func(_n: int, _w: int, _s: String) -> void: _rounds += 1)
	_game.start()

	var watch := DotSpawnWatch.new()
	watch.rules.enabled = true
	watch.rules.kill_y = -200.0

	var soak := DotBotSoak.new(cfg)
	soak.watch = watch
	soak.movers_fn = _movers
	soak.stats_fn = func() -> Dictionary: return {"kills": _kills, "deaths": _deaths, "damage": 0.0}
	soak.object_count_fn = func() -> int: return int(Performance.get_monitor(Performance.OBJECT_COUNT))
	soak.step_fn = _step

	var delta := 1.0 / float(TICK_RATE)
	while not soak.is_done():
		soak.advance(delta)
		# The world's doors and bodies are where the physics server says after a frame.
		await get_tree().physics_frame

	var report := soak.finish()
	report["map"] = map_id
	report["rounds"] = _rounds
	var counts: Dictionary = _game.bots.counts
	report["bot_counts"] = counts.duplicate()
	report["longest_stuck"] = {"seconds": _game.bots.longest_stuck, "who": String(_game.bots.longest_stuck_who)}
	print(DotBotSoak.summary(report))
	print(DotBotSoak.report_line(report))
	var path := ProjectSettings.globalize_path("res://.godot/test-logs/soak-%s.json" % map_id)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if soak.write_report(report, path) != OK:
		push_error("could not write %s" % path)
	await _release_game()
	get_tree().quit(0 if report["ok"] else 1)


## Frees the game before quitting: a map still loaded at quit can abort the process.
func _release_game() -> void:
	remove_child(_game)
	_game.free()
	for _i in range(3):
		await get_tree().process_frame


func _on_died(id: StringName, by: StringName, why: StringName) -> void:
	if why == MmGame.DIED_FELL:
		return
	_deaths += 1
	# A gunner shooting a murderer is combat as much as a stab is: on a small house map two rounds
	# can pass with every murderer shot before a clean moment, and "zero kills" means no fighting.
	if by != id and by != &"":
		_kills += 1


func _step(_delta: float) -> void:
	_game.simulate(1.0 / float(TICK_RATE))


func _movers() -> Array:
	var out: Array = []
	var playing: bool = _game.phase == MmGame.Phase.PLAY
	for id: StringName in _game.players:
		var player = _game.players[id]
		if not player.is_bot:
			continue
		var at: Vector3 = player.controller.state.position
		var st0: Dictionary = _game.bots.call("_state_of", player)
		var goal: Vector3 = st0.get("goal", Vector3.INF)
		var walking: bool = _game.bots.now() - float(st0.get("walk_at", -INF)) < 0.25
		# Reported every tick so the watch's clock stops while a bot is dead, in the grace or
		# standing about (at its goal, or a murderer holding still near its target): none is stuck.
		var moving: bool = playing and player.is_alive() and walking and goal != Vector3.INF and goal.distance_to(at) > 1.5
		out.append({"id": id, "position": at, "kind": &"bot", "has_goal": moving})
		if _trace and playing and Engine.get_physics_frames() % TICK_RATE == 0:
			var st: Dictionary = _game.bots.call("_state_of", player)
			var path: PackedVector3Array = st.get("path", PackedVector3Array())
			var extra := {}
			if true:
				for k in st:
					if not ["path", "stream", "who", "goal", "stuck", "picked_at", "path_at"].has(k):
						extra[k] = st[k]
			print("soak trace %s role=%s t=%.0f at=%s goal=%s moving=%s corner=%s/%d next=%s state=%s" % [id, _game.team_of(id), _game.bots.now(), at.snapped(Vector3.ONE * 0.05), goal.snapped(Vector3.ONE * 0.05), moving, st.get("corner"), path.size(), path[int(st.get("corner", 0))] if int(st.get("corner", 0)) < path.size() else "-", extra])
	return out


func _fail(why: String) -> void:
	printerr("SOAK setup failed: ", why)
	get_tree().quit(2)
