extends RefCounted

## The flashlight's config and the server's start rule (the beam, the click and the replication helpers are dot-flashlight's).

const MmMapDoc := preload("mm_map_doc.gd")

const GAME_ID := "game-murder-mystery"


## A config with this game's defaults: F, off on a lit map (the default state is dark-only).
static func make_config() -> DotFlashlightConfig:
	var cfg := DotFlashlightConfig.new()
	cfg.key = "F"
	return cfg


## The binder: `mm_flashlight_<field>` cvars, `cfg/game/game-murder-mystery/flashlight/game.yml`, a workbench set.
static func make_binder(cfg: DotFlashlightConfig) -> DotGameConfigBinder:
	var b := DotGameConfigBinder.create(cfg, GAME_ID, "mm_flashlight")
	b.profile_kind = "flashlight"
	return b


## Whether a player starts the map with the light on: its ambient energy against the config's dark floor.
static func starts_on(cfg: DotFlashlightConfig, map_id: String, doc: Dictionary) -> bool:
	var env: Dictionary = doc.get("environment", {})
	var ambient := float(env.get("ambient_energy", MmMapDoc.DEFAULT_ENV["ambient_energy"]))
	return DotFlashlightRules.start_on(cfg, map_id, ambient)
