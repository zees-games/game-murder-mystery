extends "dedicated_tests.gd"

## The game as a deployed server runs it: a real [DotServer] booted from a config file, the module loaded BY PATH.
## The only suite where [MmModule] loads, [DotGameModule]'s order runs, a cvar is typed at a console and a round is
## played by nothing but the stand-ins the module seats itself; `headless_run` and `headless_net` cannot reach these.

const SECTIONS := 16
const CHECKS := 119


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("murder as a dedicated server")
	print("")

	var probe: Array = []
	if not _is_exit_probe():
		probe = await _run_exit_probe()

	DotPaths.remove_tree(SERVER_DIR)
	DirAccess.make_dir_recursive_absolute(SERVER_DIR)

	await _boot()

	if server != null and server.state == DotServer.State.RUNNING:
		await _test_the_module_loads()
		_test_the_commands()
		await _test_a_round_runs()
		_test_the_murderer_plays_no_action()
		await _test_a_reload_keeps_delivered_maps()
		await _test_the_map_vote()
		await _test_map_rotation_file()
		_test_round_sentence_grammar()
		_test_finish_round_waits_for_a_live_round()
		await _test_a_module_reload_keeps_one_link()
		await _test_loading_cover()
		await _test_ambient_cvars_reach_the_client()
		await _test_it_unloads_cleanly()

	_test_no_message_preloads_itself()

	if not probe.is_empty():
		_test_exits_clean(probe)

	# The copy of this suite that the exit probe runs does not run the probe itself.
	var sections := SECTIONS - (1 if _is_exit_probe() else 0)
	var checks := CHECKS - (EXIT_PROBE_CHECKS if _is_exit_probe() else 0)

	await _shut_down()
	DotPaths.remove_tree(SERVER_DIR)
	_report_sections(_sections_entered, _sections_finished, sections, checks)
