extends DotGameNetchaosServer

const MmConfig := preload("../game/mm_config.gd")
const MmGame := preload("../game/mm_game.gd")

## Murder Mystery's side of `tools/netchaos.sh` (dot-game's DotGameNetchaosServer): the practice map, no stand-ins, no warmup or grace.

var _game: MmGame = null


func _configure() -> void:
	map_id = "mm_practice"


func _boot_world() -> void:
	if not (await boot_server()).ok:
		return
	var config := MmConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.grace_seconds = 0.0
	config.map_ids = PackedStringArray([map_id])
	_game = MmGame.new()
	_game.name = "World"
	_game.config = config
	_game.tick_rate = Engine.physics_ticks_per_second
	add_child(_game)
	await get_tree().process_frame
	(load("res://game/mm_module.gd") as GDScript).set("punishments_file", "%s/punishments.json" % data_dir)
	var loaded: DotResult = await server.modules.load_module("res://game/mm_module.gd")
	if not loaded.ok:
		printerr("netchaos server: ", loaded.error)
		return
	module = server.modules.get_module("murder")
	if solid != "":
		var cv: DotConVar = server.console.find_cvar("mp_solidplayers")
		if cv != null:
			cv.force_set(solid)


func _players() -> Array:
	return _game.players.values() if _game != null else []
