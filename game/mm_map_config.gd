extends RefCounted

## Murder Mystery's per-map settings: the round rules a map file may change, through dot-game's [DotGameMapConfig].
##
## `cfg/game/game-murder-mystery/dot_map/map/<name>.yml` (a glob such as `mm_*.yml` covers a class of maps), overridable from `cfg/server/...`. Only these keys are accepted; the game has no movement cvars, so nothing here touches prediction and the client has nothing to mirror.

const GAME_ID := "game-murder-mystery"

## cvar -> its constraint. Never a command, a path or the weapon's name.
const KEYS := {
	"mm_grace_seconds": {"type": "float", "min": 0.0, "max": 300.0},
	"mm_round_seconds": {"type": "float", "min": 30.0, "max": 3600.0},
	"mm_players_per_murderer": {"type": "float", "min": 1.0, "max": 64.0},
	"mm_min_murderers": {"type": "int", "min": 1, "max": 8},
	"mm_max_murderers": {"type": "int", "min": 1, "max": 8},
	"mm_players_per_gunner": {"type": "float", "min": 1.0, "max": 64.0},
	"mm_min_gunners": {"type": "int", "min": 0, "max": 8},
	"mm_max_gunners": {"type": "int", "min": 0, "max": 8},
	"mm_melee_range": {"type": "float", "min": 0.5, "max": 5.0},
	"mm_melee_cooldown": {"type": "float", "min": 0.1, "max": 30.0},
	"mm_gun_cooldown": {"type": "float", "min": 0.1, "max": 60.0},
	"mm_gun_range": {"type": "float", "min": 5.0, "max": 500.0},
	"mm_blood_seconds": {"type": "float", "min": 0.0, "max": 3600.0},
	"mm_murderer_speed": {"type": "float", "min": 0.5, "max": 2.0},
	"mm_doors": {"type": "int", "min": 0, "max": 1},
}
