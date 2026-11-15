extends RefCounted

## Murder Mystery's per-map settings: the round rules a map file may change, through dot-game's [DotGameMapConfig].
##
## `cfg/game/game-murder-mystery/dot_map/map/<name>.yml` (a glob such as `mm_%.yml` covers a class of maps), overridable from `cfg/server/...`. Only these keys are accepted; the game has no movement cvars, so nothing here touches prediction and the client has nothing to mirror.

const GAME_ID := "game-murder-mystery"

## cvar -> its constraint: the same least as `MmModuleConfig.TUNABLE_BOUNDS`, and no most (a map may set a longer round or reach than any default; a value under the least is refused with a warning and the old one stays, never clamped). 0 as `mm_max_murderers` or `mm_max_gunners` is no most. The one ceiling left is `mm_doors`, a switch. Never a command, a path or the weapon's name.
const KEYS := {
	"mm_grace_seconds": {"type": "float", "min": 0.0},
	"mm_round_seconds": {"type": "float", "min": 30.0},
	"mm_players_per_murderer": {"type": "float", "min": 2.0},
	"mm_min_murderers": {"type": "int", "min": 1},
	"mm_max_murderers": {"type": "int", "min": 0},
	"mm_players_per_gunner": {"type": "float", "min": 2.0},
	"mm_min_gunners": {"type": "int", "min": 1},
	"mm_max_gunners": {"type": "int", "min": 0},
	"mm_melee_range": {"type": "float", "min": 0.0},
	"mm_melee_cooldown": {"type": "float", "min": 0.0},
	"mm_gun_cooldown": {"type": "float", "min": 0.0},
	"mm_gun_range": {"type": "float", "min": 5.0},
	"mm_blood_seconds": {"type": "float", "min": 0.0},
	"mm_murderer_speed": {"type": "float", "min": 0.5},
	"mm_doors": {"type": "int", "min": 0, "max": 1},
}
