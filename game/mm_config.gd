extends DotConfig

## Everything a server owner can tune, layered as every Dot game does:
## defaults < `user://cfg/murder.json` < `MM_*` environment < `--mm-*` arguments.
##
## [b]The round[/b]: a short grace while everybody scatters (the murderer cannot draw yet), then
## the round proper until the clock runs out or one side is gone. [b]The sides[/b]: one or more
## murderers, one or more bystanders handed the gun, and everybody else unarmed. Who is what is
## the server's secret; see docs/design.md "Roles are secret".

# --- The round -------------------------------------------------------------

@export_group("The round")

## Seconds at the top of a round when nobody can be hurt: the murderer cannot draw, the gun
## cannot fire. Long enough to spread out from the spawn.
@export_range(0.0, 60.0, 1.0) var grace_seconds: float = 10.0

## Seconds of play after the grace. When it runs out the bystanders win: the murderer had the
## whole round and did not finish.
@export_range(30.0, 1800.0, 5.0) var round_seconds: float = 180.0

@export_range(0.0, 60.0, 1.0) var intermission_seconds: float = 8.0
@export_range(0.0, 300.0, 1.0) var warmup_seconds: float = 8.0

# --- The sides -------------------------------------------------------------

@export_group("The sides")

## How many murderers: one per this many players, between the two bounds.
@export_range(2.0, 64.0, 0.5) var players_per_murderer: float = 12.0
@export_range(1, 8, 1) var min_murderers: int = 1
@export_range(1, 8, 1) var max_murderers: int = 2

## How many bystanders start with the gun, the same way.
@export_range(2.0, 64.0, 0.5) var players_per_gunner: float = 12.0
@export_range(1, 8, 1) var min_gunners: int = 1
@export_range(1, 8, 1) var max_gunners: int = 2

# --- The murderer's weapon -------------------------------------------------

@export_group("The murderer's weapon")

## Which melee weapon the murderer carries: an id from [code]game/mm_weapons.gd[/code]
## (knife, cleaver, axe, bat, sword). Its reach and its cooldown are the weapon's unless the two
## settings below override them.
@export var murderer_weapon: String = "knife"

## Metres from the murderer's eye a stab reaches. 0 takes the weapon's own.
@export_range(0.0, 4.0, 0.05) var melee_range: float = 0.0

## Seconds between two stabs. 0 takes the weapon's own.
@export_range(0.0, 10.0, 0.05) var melee_cooldown: float = 0.0

## Half-angle of the cone in front of the murderer a stab lands in, in degrees.
@export_range(5.0, 90.0, 1.0) var melee_cone: float = 40.0

## Seconds after drawing before a stab lands: a drawn weapon is a tell, and this is the beat in
## which somebody who saw it can run.
@export_range(0.0, 3.0, 0.05) var draw_seconds: float = 0.35

# --- The gun ---------------------------------------------------------------

@export_group("The gun")

## Seconds between two shots for whoever holds the gun.
@export_range(0.0, 30.0, 0.5) var gun_cooldown: float = 3.0

## How far the gun reaches, in metres.
@export_range(5.0, 300.0, 1.0) var gun_range: float = 120.0

## A miss drops the gun at the shooter's feet. Off, a miss only costs the cooldown.
@export var drop_on_miss: bool = true

## Shooting an innocent drops the gun too, and the shooter cannot pick one up again this round.
@export var drop_on_innocent: bool = true

## Shooting an innocent kills the shooter as well.
@export var innocent_kills_shooter: bool = false

## How close, in metres, somebody has to walk to a dropped gun to pick it up.
@export_range(0.3, 3.0, 0.05) var pickup_range: float = 1.1

# --- Blood -----------------------------------------------------------------

@export_group("Blood")

## Seconds before the end of the round the murderer starts to show blood. 0 never.
@export_range(0.0, 600.0, 5.0) var blood_seconds: float = 60.0

## How many steps the blood comes in. Each kill also adds one, when [member blood_per_kill].
@export_range(1, 8, 1) var blood_stages: int = 4

@export var blood_per_kill: bool = true

# --- Points ----------------------------------------------------------------

@export_group("Points")

@export_range(0, 100, 1) var winner_points: int = 10
@export_range(0, 100, 1) var kill_points: int = 5
@export_range(0, 100, 1) var hero_points: int = 15
@export_range(0, 100, 1) var survive_points: int = 5

@export var doors_enabled: bool = true

# --- The players -----------------------------------------------------------

@export_group("The players")

@export_range(1.0, 400.0, 1.0) var player_health: float = 100.0
@export_range(1.0, 20.0, 0.1) var run_speed: float = 6.0
@export_range(1.0, 3.0, 0.05) var sprint_scale: float = 1.3

## The murderer's speed against everybody else's. Over 1 a chase can be won.
@export_range(0.5, 2.0, 0.01) var murderer_speed_scale: float = 1.05

@export_range(0.1, 5.0, 0.05) var jump_height: float = 1.15
@export_range(1.0, 60.0, 0.5) var gravity: float = 20.0
@export var auto_bunny_hop: bool = false
@export_range(0.0, 200.0, 1.0) var air_accelerate: float = 20.0

# --- The maps --------------------------------------------------------------

@export_group("The maps")

@export var map_ids: PackedStringArray = PackedStringArray()
@export var shuffle_maps: bool = true
@export_range(1, 50, 1) var rounds_per_map: int = 3
@export var map_directory: String = "maps"

## Where the other games' map packs are mounted, one directory per pack under it. Hide & Seek,
## Prop Hunt and Playground documents are read there and converted (see mm_map_doc.gd).
@export var extra_map_directory: String = "maps_extra"

@export var seed_value: int = 20261018

# --- Bots ------------------------------------------------------------------

@export_group("Bots")

@export_range(0, 24, 1) var minimum_players: int = 6

## Whether the stand-ins talk in chat ("did anyone see that?"). Canned lines; see mm_bot_chat.gd.
@export var bot_chat: bool = true

# --- Watching --------------------------------------------------------------

@export_group("Watching")

@export_enum("anybody", "own side", "nobody") var spectate_camera: int = 0

# --- Progress --------------------------------------------------------------

@export_group("Progress")

@export var keep_progress: bool = true
@export var progress_directory: String = ""
@export var report_progress: bool = false


func env_prefix() -> String:
	return "MM_"


func cli_prefix() -> String:
	return "--mm-"


## How many murderers for [param players] people. Never so many that nobody is left to murder.
func murderers_for(players: int) -> int:
	if players < 2:
		return 0
	return mini(DotTeamRotation.count_for(players, players_per_murderer, min_murderers, max_murderers), players - 1)


## How many gunners, out of the [param bystanders] who are not murderers.
func gunners_for(players: int, bystanders: int) -> int:
	if bystanders < 1:
		return 0
	return mini(DotTeamRotation.count_for(players, players_per_gunner, min_gunners, max_gunners), bystanders)


func validate() -> DotResult:
	if round_seconds <= 0.0:
		return DotResult.fail(DotError.CODE_INVALID, "A round has to last some time.")
	if min_murderers > max_murderers:
		return DotResult.fail(DotError.CODE_INVALID, "min_murderers is over max_murderers.")
	if min_gunners > max_gunners:
		return DotResult.fail(DotError.CODE_INVALID, "min_gunners is over max_gunners.")
	return DotResult.success(null)


func describe() -> Dictionary:
	return {
		"round": "%.0f s grace, %.0f s play" % [grace_seconds, round_seconds],
		"murderers": "1 per %.1f, %d..%d" % [players_per_murderer, min_murderers, max_murderers],
		"gunners": "1 per %.1f, %d..%d" % [players_per_gunner, min_gunners, max_gunners],
		"weapon": murderer_weapon,
		"gun": "%.1f s cooldown, %s on a miss" % [gun_cooldown, "drops" if drop_on_miss else "kept"],
		"blood": "last %.0f s, %d stages" % [blood_seconds, blood_stages] if blood_seconds > 0.0 else "never",
		"maps": "all" if map_ids.is_empty() else ",".join(map_ids),
		"bots": minimum_players,
	}


func describe_lines(_redact_sensitive: bool = true) -> PackedStringArray:
	var lines := PackedStringArray()
	lines.append("murder configuration")
	var facts := describe()
	for key: String in facts:
		lines.append("  %-10s %s" % [key, facts[key]])
	return lines
