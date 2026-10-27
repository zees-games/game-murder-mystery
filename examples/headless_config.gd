extends Node

## MmConfig through DotGameConfigBinder: fields, cvars, strict refusal, the diff, a shipped yml loading back, and the workbench round trip.
##
## [codeblock]
## godot --headless --path . res://examples/headless_config.tscn
## [/codeblock]

const MmConfig := preload("../game/mm_config.gd")
const MmGame := preload("../game/mm_game.gd")
const CHECKS := 34

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _check(ok: bool, what: String, _detail := "") -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		_failures.append(what)


const ROOT := "user://mm_cfgtest"
const GAME := "game-murder-mystery"


func _run() -> void:
	if OS.get_cmdline_user_args().has("--probe"):
		_probe()
		return
	print("game-murder-mystery: config binder")
	var config := MmConfig.new()
	var binder := MmConfig.make_binder(config)
	binder.strict = true
	_check(binder.load_layers().ok, "defaults load")
	_check(binder.diff().is_empty(), "no diff at the code defaults")
	var keys := PackedStringArray()
	for e: Dictionary in binder.schema():
		keys.append(e["key"])
	for k in ["round_seconds", "players_per_murderer", "gun_cooldown", "hit_radius", "hit_height", "toy_reach",
			"bot_chat_chance", "bot_witness_range", "bot_flee_seconds", "death_cam_seconds", "freeze_cam_seconds"]:
		_check(keys.has(k), "%s is exposed" % k)

	var console := DotConsole.new()
	add_child(console)
	binder.bind_cvars(console.cvar, DotConVar.FLAG_ARCHIVE, console.has_name)
	console.set_cvar("mm_hit_radius", "0.6")
	_check(is_equal_approx(config.hit_radius, 0.6) and binder.source_of("hit_radius") == "cvar", "a cvar writes the field")
	_check(binder.diff_yaml().contains("hit_radius: 0.6"), "the diff names the edit")
	var schema_path := "user://mm_config_schema.json"
	_check(binder.write_schema(schema_path).ok and FileAccess.file_exists(schema_path), "write_schema writes the schema")
	DirAccess.remove_absolute(schema_path)

	var bad := FileAccess.open("user://mm_config_bad.json", FileAccess.WRITE)
	bad.store_string('{"no_such_field": 1}')
	bad.close()
	var strict := MmConfig.make_binder(MmConfig.new(), "user://mm_config_bad.json")
	strict.strict = true
	_check(not strict.load_layers().ok, "strict: an unknown key is refused")
	DirAccess.remove_absolute("user://mm_config_bad.json")

	var fall := MmGame.make_fall_rules()
	var _made := fall.bind_cvars(console.cvar, DotConVar.FLAG_NOTIFY)
	_check(console.get_int("sv_falldamage") == 1 and fall.enabled, "fall damage is on in this game")
	_check(fall.damage_for(20.0) > 0.0 and fall.damage_for(5.0) == 0.0, "a hard landing hurts, a small one does not")
	_check(console.get_int("sv_falldamage_lethal") == 40 and fall.damage_for(45.0) > 1000.0, "only a very high speed kills outright")
	console.set_cvar("sv_falldamage", "0")
	_check(not fall.enabled and fall.damage_for(60.0) == 0.0, "the cvar turns it off")

	_layers()
	_templates(binder)

	var wb := DotGameWorkbench.new()
	wb.panel_mode = 1
	wb.config = {"enabled": false}
	for set: DotProfileSet in binder.profile_sets():
		wb.add_set(set, set.rel_path)
	add_child(wb)
	_check(wb.start().ok, "the workbench starts")
	binder.attach(wb.api.runtime)
	var listed := PackedStringArray()
	for kind: String in wb.api.kinds():
		var got: DotResult = wb.api.handle(DotGameWorkbench.LOCAL_ACTOR, {"op": "get", "kind": kind, "id": binder.profile_id})
		if got.ok:
			listed.append_array(PackedStringArray((got.value as Dictionary).get("values", {}).keys()))
	var missing := PackedStringArray()
	for k in keys:
		if not listed.has(k):
			missing.append(k)
	_check(missing.is_empty() and binder.profile_sets().size() == 6, "the workbench lists all %d keys over %d files" % [keys.size(), binder.profile_sets().size()], ",".join(missing))
	var res: DotResult = wb.api.handle(DotGameWorkbench.LOCAL_ACTOR, {"op": "set", "kind": "config_players", "id": binder.profile_id, "key": "player_health", "value": 150.0})
	_check(res.ok and is_equal_approx(config.player_health, 150.0), "a workbench edit reaches the live config")
	var files: Dictionary = wb.exporter.call("collect")
	var text: String = files.get("cfg/game/game-murder-mystery/config_players/game.yml", "")
	_check(text.contains("player_health: 150.0"), "the export holds the edit in the cfg layout")

	wb.free()
	console.free()
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


## Child process: loads the layers strictly over the test root and prints what the live config holds.
func _probe() -> void:
	var config := MmConfig.new()
	var binder := MmConfig.make_binder(config)
	binder.strict = true
	binder.roots = PackedStringArray([ProjectSettings.globalize_path(ROOT)])
	var loaded := binder.load_layers()
	var game := preload("../game/mm_game.gd").new()
	game.config = config
	var console := DotConsole.new()
	add_child(console)
	binder.bind_cvars(console.cvar, DotConVar.FLAG_ARCHIVE, console.has_name)
	print("PROBE ok=%s round=%s murderers=%s gun=%s gun_src=%s cvar=%s blood=%s blood_src=%s range=%s reach=%s reach_src=%s round_src=%s" % [
		loaded.ok, game.config.round_seconds, game.config.murderers_for(12), game.config.gun_cooldown, binder.source_of("gun_cooldown"),
		console.find_cvar("mm_gun_cooldown").get_string(), game.config.blood_stages, binder.source_of("blood_stages"),
		game.config.gun_range, game.config.toy_reach, binder.source_of("toy_reach"), binder.source_of("round_seconds")])
	get_tree().quit(0)


func _write(rel: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ROOT.path_join(rel).get_base_dir())
	var f := FileAccess.open(ROOT.path_join(rel), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _child() -> String:
	var out: Array = []
	OS.execute(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"),
		"res://examples/headless_config.tscn", "--", "--probe", "--mm-blood-stages=6", "--mm-toy-reach=3.3"], out, true)
	return "".join(PackedStringArray(out))


## A value set in a cfg file, the environment and argv each reaches the live config, and later layers win.
func _layers() -> void:
	_write("game/%s/config_round/game.yml" % GAME, "round_seconds: 222.0\nplayers_per_murderer: 3.0\nmax_murderers: 4\n")
	_write("game/%s/config_weapons/game.yml" % GAME, "gun_cooldown: 2.5\nblood_stages: 3\ngun_range: 77.0\n")
	OS.set_environment("MM_GUN_COOLDOWN", "1.75")
	var text := _child()
	_check(text.contains("PROBE ok=true"), "the layers load strictly in a fresh process", text.right(300))
	_check(text.contains("round=222") and text.contains("round_src=yml") and text.contains("murderers=4"), "a cfg file reaches the live config (round_seconds, the murderer count it drives)")
	_check(text.contains("range=77"), "a second file (config_weapons) reaches it too")
	_check(text.contains(" gun=1.75") and text.contains("gun_src=env") and text.contains("cvar=1.75"), "the environment beats the file and reaches the cvar")
	_check(text.contains("blood=6") and text.contains("blood_src=argv"), "argv beats the file")
	_check(text.contains("reach=3.3") and text.contains("reach_src=argv"), "argv alone reaches the config")
	OS.unset_environment("MM_GUN_COOLDOWN")
	_write("game/%s/config_round/game.yml" % GAME, "gun_cooldown: 2.5\n")
	_check(_child().contains("PROBE ok=false"), "strict: a key in the wrong file is refused")
	for f in ["config_round", "config_weapons"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(ROOT.path_join("game/%s/%s/game.yml" % [GAME, f])))


## The shipped cfg files hold every key, in step with MmConfig, and change nothing as they are.
func _templates(binder: DotGameConfigBinder) -> void:
	var files := binder.template_files()
	_check(files.size() == 6, "six shipped cfg files", str(files.size()))
	var stale := PackedStringArray()
	for path: String in files:
		if not FileAccess.file_exists("res://" + path) or FileAccess.get_file_as_string("res://" + path) != files[path]:
			stale.append(path)
	_check(stale.is_empty(), "the shipped files match the config (run tools/cfg_templates.gd)", ",".join(stale))
