extends "mm_game_use.gd"

## Laying out the map and putting everybody on it, of [code]mm_game.gd[/code]: the map menu's
## change, the next map picked, the map built, everybody to a spawn. Path-based base, no class_name.

## The map menu's change: [param id] now, not after this map's rounds. The next map is set and
## a fresh round begins on it (dot-match's `begin_round_now`: the round called off has no
## winner); with no match running it is simply built. Authority only.
func change_map_now(id: StringName) -> DotResult:
	if not authoritative:
		return DotResult.fail(DotError.CODE_STATE, "Only the server changes the map.")
	if catalogue == null or not catalogue.playable(config.map_ids).has(id):
		return DotResult.fail(DotError.CODE_INVALID, "There is no map called '%s' here." % id)
	next_map_id = id
	if match_node == null or not match_node.begin_round_now(_tick):
		_lay_out_map()
	DotLog.info(CHANNEL, "map changed from the map menu", {"map": String(id)})
	return DotResult.success(id)


func _lay_out_map() -> void:
	if catalogue == null:
		return

	var doc: Dictionary = {}

	if next_map_id != &"" and catalogue.playable(config.map_ids).has(next_map_id):
		doc = catalogue.maps[next_map_id]

	next_map_id = &""

	if doc.is_empty():
		# A map installed since the file was read may match it now.
		apply_rotation()
		var cycling := rotation_file != null and rotation_file.has_rotations() \
			and map_rotation != null and map_rotation.mode == DotMapRotation.Mode.SEQUENTIAL
		doc = catalogue.next_map(
			config.map_ids, config.shuffle_maps and not cycling, random.stream(&"map"),
			StringName(str(map_doc.get("id", ""))), rotation_pool()
		)

	var _built := build_map(doc)
	_rounds_on_map = 0
	_map_unplayed = true
	_place_everybody()


## Builds [param doc] as the map. What the server does between rounds, and what a client does
## when it is sent one.
func build_map(doc: Dictionary) -> DotResult:
	world_clearing.emit()

	var built := map.build(doc)

	if not built.ok:
		DotLog.error(CHANNEL, "a map would not build", {"id": str(doc.get("id", "?")), "why": built.error.message})
		return built

	map_doc = map.doc

	if spectate != null:
		spectate.set_overviews([map.overview(), map.overview()] as Array[Transform3D])

	world_rebuilt.emit()
	return built


## Everybody to a spawn point, at full health, empty handed.
func _place_everybody() -> void:
	var ids := players.keys()
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))

	# Shuffled with the round, so the murderer is not always the one by the stairs.
	var stream := random.stream(&"spawns")
	var offset := stream.next_range_i(0, 63)
	var spots := map.spawn_batch(SPAWN_GROUP, ids.size(), config.spawn_rules(), offset)

	for index in range(ids.size()):
		var id: StringName = ids[index]
		var player: MmPlayer = players[id]
		player.reset_round()
		_heal(player)

		var spot: Array = spots[index]
		player.place_at(spot[0], spot[1])

		if spectate != null:
			spectate.spawned(player.player_id)


func _heal(player: MmPlayer) -> void:
	if player.health != null:
		player.health.max_health = config.player_health
		player.health.health = player.health.max_health
		player.health.alive = true
		player.health.invulnerable = false
