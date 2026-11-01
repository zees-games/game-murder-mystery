extends DotGameWorkbenchSuite

## game-murder-mystery: the workbench over the config binder, one edit per profile set, the export and its cfg round trip.
## Run: godot --headless --path . res://examples/headless_workbench.tscn

const MmConfig := preload("../game/mm_config.gd")


func _make_config() -> DotConfig:
	return MmConfig.new()


func _make_binder(config: DotConfig) -> DotGameConfigBinder:
	return MmConfig.make_binder(config)
