extends DotCoverServer

const MmConfig := preload("../game/mm_config.gd")
const MmGame := preload("../game/mm_game.gd")

## A headless dedicated world for tools/render_cover.gd to join: the boot examples/dedicated.gd does (DotServer, the
## world, the module), left running. Run: `godot --headless --path . res://tools/cover_server.tscn -- --port 27431`

var game: MmGame = null


func _default_port() -> int:
	return 27431


func _max_players() -> int:
	return 4


func _boot(dir: String) -> void:
	var world_config := MmConfig.new()
	world_config.warmup_seconds = 0.0
	world_config.map_ids = PackedStringArray(["mm_practice"])
	world_config.minimum_players = 3
	world_config.grace_seconds = 3.0
	game = MmGame.new()
	game.name = "World"
	game.config = world_config
	game.tick_rate = Engine.physics_ticks_per_second
	add_child(game)
	await get_tree().process_frame

	(load("res://game/mm_module.gd") as GDScript).set("punishments_file", "%s/punishments.json" % dir)
	var loaded: DotResult = await server.modules.load_module("res://game/mm_module.gd")
	print("cover_server: module loaded=%s port=%d" % [loaded.ok, port])
