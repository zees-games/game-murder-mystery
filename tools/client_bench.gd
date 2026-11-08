extends DotGameClientBench

const MmConfig := preload("../game/mm_config.gd")
const MmGame := preload("../game/mm_game.gd")

## Client prediction bench (dot-game's DotGameClientBench): see that class for the flags.
## The world is the practice map under the module a dedicated server loads; the module fills seats with its own stand-ins, so `--bots` is ignored.


func _configure() -> void:
	client_scene = "res://game/mm.tscn"
	forward_action = &"dot_fps_forward"


func _boot_server(_bots_wanted: int, data_dir: String) -> DotNetManager:
	var dir := ProjectSettings.globalize_path(data_dir)
	var config := make_server_config(data_dir)
	config.max_players = 16
	var server := DotServer.new()
	server.name = "Server"
	server.config = config
	add_child(server)
	for _i in 60:
		await get_tree().process_frame
		if server.state == DotServer.State.RUNNING:
			break
	var world_config := MmConfig.new()
	world_config.warmup_seconds = 0.0
	world_config.intermission_seconds = 0.0
	world_config.map_ids = PackedStringArray(["mm_practice"])
	var game := MmGame.new()
	game.name = "World"
	game.config = world_config
	game.tick_rate = Engine.physics_ticks_per_second
	add_child(game)
	await get_tree().process_frame
	(load("res://game/mm_module.gd") as GDScript).set("punishments_file", "%s/punishments.json" % dir)
	var loaded: DotResult = await server.modules.load_module("res://game/mm_module.gd")
	if not loaded.ok:
		printerr("client_bench server: ", loaded.error)
		return null
	for n in server.modules.loaded_names():
		var m: Object = server.modules.get_module(n)
		if m != null and m.get("net") != null:
			return m.get("net")
	return null
