extends Node
## Blood on the surface behind or under somebody who was shot or stabbed. Every client works it out
## from the SHOT and DEATH events it already gets, so the server sends nothing extra.

var decals := DotFxDecals.new()
## Layers the splatter may land on; the game's rooms and props.
var mask := 0xFFFFFFFF


func _init() -> void:
	name = "Blood"
	decals.name = "Decals"
	add_child(decals)


## Takes the player's `gore` and `fx_quality`.
func apply_settings(store: DotSettingsManager) -> void:
	var cfg := DotFxDecalConfig.new()
	if store != null:
		cfg.gore = store.get_bool(&"gore", true)
		cfg.quality = store.get_int(&"fx_quality", 3)
	decals.apply_config(cfg)


func follow(store: DotSettingsManager) -> void:
	apply_settings(store)
	if store != null and not store.changed.is_connected(_on_changed):
		store.changed.connect(_on_changed.bind(store))


func _on_changed(key: StringName, _value: Variant, _why: StringName, store: DotSettingsManager) -> void:
	if key == &"gore" or key == &"fx_quality":
		apply_settings(store)


## A shot that hit somebody ended at [param to]: blood on the first surface behind it.
func on_shot_hit(from: Vector3, to: Vector3, reach: float = 3.0) -> Node3D:
	var along := to - from
	if along.length() < 0.01:
		return null
	return _cast(to, along.normalized(), reach)


## A stab killed somebody standing at [param feet]: blood on the floor under them.
func on_stab(feet: Vector3) -> Node3D:
	return _cast(feet + Vector3(0.0, 0.5, 0.0), Vector3.DOWN, 4.0)


func _cast(point: Vector3, direction: Vector3, reach: float) -> Node3D:
	var world := get_viewport().find_world_3d() if get_viewport() != null else null
	if world == null:
		return null
	var query := PhysicsRayQueryParameters3D.create(point, point + direction * reach, mask)
	var hit := world.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return null
	return decals.splatter(hit["position"], hit["normal"], 0.8)


func advance(delta: float) -> void:
	decals.advance(delta)


func clear() -> void:
	decals.clear_blood()
