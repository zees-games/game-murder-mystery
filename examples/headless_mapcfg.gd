extends DotGameCheckSuite

const MmMapConfig := preload("../game/mm_map_config.gd")

## A map with a file gets its values and the next map has the previous ones back.
##
## [codeblock]
## godot --headless --path . res://examples/headless_mapcfg.tscn
## [/codeblock]
##
## The file is written to the server tier into user://, so the check does not depend on what ships.

const CHECKS := 8


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-murder-mystery: per-map rules from cfg/game/game-murder-mystery/dot_map/map")
	if not ResourceLoader.exists("res://addons/dot_map/config/dot_map_config.gd"):
		print("SKIPPED: dot-map is not linked at addons/dot_map")
		get_tree().quit(0)
		return
	var console := DotConsole.new()
	add_child(console)
	console.cvar("mm_round_seconds", "300", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("mm_doors", "1", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("mm_bots", "1", "", DotConVar.FLAG_ARCHIVE)
	var cfg := DotGameMapConfig.for_console(MmMapConfig.GAME_ID, console, MmMapConfig.KEYS)

	var dir := "res://cfg/server/game/%s/dot_map/map" % MmMapConfig.GAME_ID
	var real := ProjectSettings.globalize_path(dir)
	DirAccess.make_dir_recursive_absolute(real)
	var path := real.path_join("mm_testhouse.yml")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("mm_round_seconds: 120\nmm_doors: 0\nmm_bots: 0\nmm_gun_range: 9999\n")
	f.close()

	var got := cfg.apply("mm_testhouse")
	_check(got.size() == 2, "the map's two whitelisted keys apply (%s)" % [got])
	_check(console.find_cvar("mm_round_seconds").get_float() == 120.0, "mm_round_seconds is 120 on that map")
	_check(console.find_cvar("mm_doors").get_int() == 0, "mm_doors is 0 on that map")
	_check(console.find_cvar("mm_bots").get_int() == 1, "a cvar outside the whitelist is untouched")

	cfg.apply("mm_other")
	_check(console.find_cvar("mm_round_seconds").get_float() == 300.0, "the next map has mm_round_seconds back")
	_check(console.find_cvar("mm_doors").get_int() == 1, "and mm_doors")
	_check(cfg.applied().is_empty(), "a map with no active values applies nothing")

	cfg.restore()
	DirAccess.remove_absolute(path)
	var up := real
	for _i in 5:
		DirAccess.remove_absolute(up)
		up = up.get_base_dir()
	_check(not FileAccess.file_exists(path), "the test file is removed")

	_report(CHECKS)
