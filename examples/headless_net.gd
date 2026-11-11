extends "headless_net_tests.gd"

const WorkbenchSection := preload("headless_net_workbench.gd")

## The real path minus the socket: two worlds, managers, bridges and links with the RPC replaced by a queue, in one process.
## It holds the claims the game rests on over a wire: roles are secret (TEAM and JOIN carry everybody as a bystander,
## ROLE goes to its owner, DEATH never says by whom), then the map, doors, toys, the result. Sections and checks are both counted.

const SECTIONS := 18
const CHECKS := 118


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("murder over the wire")
	print("")

	_test_the_codec()

	if await _build():
		await _test_a_client_joins()
		await _test_the_map_arrives()
		await _test_roles_are_secret()
		await _test_the_local_player_is_predicted()
		await _test_a_door_crosses()
		await _test_a_stab_crosses()
		await _test_free_roam_crosses()
		await _test_the_flashlight_crosses()
		await _test_a_shot_crosses()
		await _test_the_round_ends()
		await _test_a_shot_is_rewound()
		await _test_a_lagged_shot_over_the_link()
		await _test_the_toys_cross()
		await _test_a_client_without_the_map()
		await _test_leaving()

	WorkbenchSection.new(self, SERVER_TICK_RATE).run()

	_report_sections(_sections_entered, _sections_finished, SECTIONS, CHECKS)
