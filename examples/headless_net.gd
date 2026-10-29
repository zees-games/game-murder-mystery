extends "headless_net_tests.gd"

const WorkbenchSection := preload("headless_net_workbench.gd")

## The real path minus the socket: two worlds, two managers, two bridges, two links with the
## RPC replaced by a queue, so the codec, the seal, the snapshots, the prediction and the
## reconciliation all run, in one process, in two physics worlds.
##
## [b]What this suite is for is the claims the game rests on over a wire.[/b] Roles are secret
## on the wire, not only on the screen: TEAM and JOIN carry everybody as a bystander, a ROLE goes
## to its owner alone, a DEATH never says by whom and the spectate camera is given no killer, so
## a client that drew every field it was sent would still not know who the murderer is. What is
## meant to be seen is: a weapon drawn, a gun in a hand, blood, a shot's tracer, a gun on the
## floor. Then everything else that crosses: the map document, prediction against doors, the
## toys, a client that missed its map, the result with the murderer named.
##
## Sections and checks are both counted; mg-smash-copter's notes say why the second matters.

const SECTIONS := 17
const CHECKS := 114


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
		await _test_a_shot_crosses()
		await _test_the_round_ends()
		await _test_a_shot_is_rewound()
		await _test_a_lagged_shot_over_the_link()
		await _test_the_toys_cross()
		await _test_a_client_without_the_map()
		await _test_leaving()

	WorkbenchSection.new(self, SERVER_TICK_RATE).run()

	_report_sections(_sections_entered, _sections_finished, SECTIONS, CHECKS)
