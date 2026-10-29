extends "mm_game_state.gd"

## The world's parts and the map rotation of [code]mm_game.gd[/code]: bodies, physics, combat, spectating,
## progress, and maps.yml. Path-based base, no class_name.

## The player's motor mask under `mp_solidplayers`, and the standing hull the others stop at
## (a player's body has no shape of its own). With the rule on, a stand-in stops at your
## shoulder instead of walking into your camera (the first play test, 1:37 and 2:20).
func _apply_body_mask(player: MmPlayer) -> void:
	if physics == null or player == null or player.controller == null:
		return
	body_rules.apply_to(player.controller, physics.collision_mask(&"player"), physics.layer_mask(&"player"))
	var tunables := player.controller.tunables
	body_rules.apply_hull(player, tunables.stand_height, tunables.radius)


## `mp_solidplayers` changed: every player's mask and hull now.
func _on_body_rules_changed() -> void:
	for id in players:
		_apply_body_mask(players[id] as MmPlayer)
	apply_pass_through()


## The side a player is on for dot-team's block rules: everybody is one, because a murderer who
## blocked differently from the rest would give the role away through the body.
func team_of_side(_id: Variant) -> Variant:
	return "1"


## Hands every controller the bodies it passes through under `block_rules`; the same call on every machine, or a client predicts a wall.
func apply_pass_through() -> void:
	var entries := {}
	for id: Variant in players:
		var who := players[id] as MmPlayer
		if who != null and who.controller != null:
			entries[id] = {"body": who, "controller": who.controller}
	body_rules.apply_exceptions(entries)


## Three layers: the building, the people, and the furniture. `mp_solidplayers` is 0 by default
## (`_init`): a murderer's body pinning somebody in a corner would be a different game.
func _build_physics() -> void:
	physics = DotPhysicsLayout.custom(&"murder", [&"world", &"player", &"prop", &"toy", &"footprint"])

	for layer in physics.layers:
		match layer.id:
			&"player":
				layer.collides_with = [&"world", &"prop"]
			# A loose toy: the rooms, the furniture and the other toys, never a person, who
			# walks through it and pushes it (see [method _advance_toys]).
			&"toy":
				layer.collides_with = [&"world", &"prop", &"toy"]
			# A toy's footprint, for the bots' walkable mesh only: nothing collides with it.
			&"footprint":
				layer.collides_with = []
			_:
				layer.collides_with = [&"player"]

	var built := physics.build()

	if not built.ok:
		DotLog.error(CHANNEL, "the collision layout would not build", {"why": built.error.message})
		physics = null


## The gravity the movement is tuned against, on this world's own physics SPACE: a project
## setting does not travel with a delivered pack.
func _apply_gravity() -> void:
	var world := get_world_3d()

	if world == null:
		return

	PhysicsServer3D.area_set_param(world.space, PhysicsServer3D.AREA_PARAM_GRAVITY, config.gravity)


func _build_random() -> void:
	random = DotRandomManager.new()
	random.name = "Random"
	random.register_as_service = false
	add_child(random)
	var _started := random.setup()
	random.reseed(_round_seed)


func _build_props() -> void:
	props_catalogue = MmProps.new()
	var count := props_catalogue.load_file()

	if count == 0:
		DotLog.error(CHANNEL, "no props: every map will be empty rooms", {})


func _build_map() -> void:
	map = MmMap.new()
	map.name = "Map"
	map.physics = physics
	map.catalogue = props_catalogue
	map.draw_world = draw_world
	map.tick_rate = tick_rate
	map.authoritative = authoritative
	map.toy_rules = toy_rules
	map.gravity = config.gravity
	add_child(map)


## Health, and the damage a stab and a shot do. The hits themselves are measured here (see
## [method _advance_weapons]) and arrive at dot-combat as damage, so dot-moderation's god and
## buddha work as they do everywhere.
func _build_combat() -> void:
	combat = DotCombatManager.new()
	combat.name = "Combat"
	combat.is_authority = authoritative
	combat.register_service = false

	var damage_rules := DotDamageRules.new()
	# Everybody is one team as dot-combat sees it, and the gunner shooting an innocent is the
	# rule working, so friendly fire is on.
	damage_rules.friendly_fire = true
	damage_rules.self_damage = true
	combat.rules = damage_rules

	var settings := DotCombatConfig.new()
	settings.lag_compensation = false
	combat.config = settings
	var trace := DotTracePhysics.for_world(get_world_3d())

	if physics != null:
		trace.collision_mask = physics.layer_mask(&"world") | physics.layer_mask(&"prop")

	combat.trace = trace
	combat.resolver = DotDamageResolver.with_rules(damage_rules)
	# dot-game's "still loading": every kill passes here, so a seat behind its client's cover is
	# neither stabbed, shot nor eliminated, and a round counts the living from health. An
	# admin's slay or slap is the operator's word, and a fall is a respawn, not a death.
	combat.resolver.adjust = func(damage: DotDamage) -> void:
		if damage.context.get("admin", false) or damage.context.get("why", &"") == DIED_FELL:
			return

		if not can_be_harmed(entities.key_for_id(damage.victim)):
			damage.refuse("still loading")
	add_child(combat)


func _build_effects() -> void:
	if authoritative and not draw_world:
		return

	var fx := DotFxCatalogue.new()

	var go := DotFxDef.new()
	go.id = &"go"
	go.kind = DotFxDef.Kind.SCREEN
	go.flash_peak = 0.18
	go.flash_colour = Color(0.98, 0.86, 0.35, 1.0)
	go.flash_decay_ms = 380
	fx.add(go)

	var hurt := DotFxDef.new()
	hurt.id = &"killed"
	hurt.kind = DotFxDef.Kind.SCREEN
	hurt.flash_peak = 0.45
	hurt.flash_colour = TEAM_COLOURS[1]
	hurt.flash_decay_ms = 700
	fx.add(hurt)

	effects = DotFxManager.new()
	effects.name = "Effects"
	effects.catalogue = fx
	effects.config = DotFxConfig.new()
	effects.register_as_service = false
	add_child(effects)
	DotLog.result(CHANNEL, "the effects layer", effects.setup())


func _build_spectate() -> void:
	spectate = MmSpectate.new()
	spectate.name = "Spectate"
	spectate.players = players
	spectate.sides = sides
	spectate.phase_fn = func() -> int: return phase
	add_child(spectate)

	# The config's number is only the starting point: from here `mp_forcecamera` is the rule.
	spectate_rules.force_camera = clampi(config.spectate_camera, 0, 2)
	var ready_now := spectate.setup(authoritative, tick_rate, spectate_rules, config.death_cam_seconds, config.freeze_cam_seconds)

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "spectating is off", {"why": ready_now.error.message})
		remove_child(spectate)
		spectate.queue_free()
		spectate = null


func _build_progress() -> void:
	if not authoritative or not config.keep_progress:
		return

	progress = MmProgress.new()
	progress.name = "Progress"
	progress.players = players
	progress.sides = sides
	add_child(progress)

	var ready_now := progress.setup(config.progress_directory, config.report_progress)

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "progress is off", {"why": ready_now.error.message})
		remove_child(progress)
		progress.queue_free()
		progress = null
		return

	progress.earned.connect(func(id: StringName, title: String, points: int) -> void:
		achievement_earned.emit(id, title, points)
	)


## Whether [param player_id] may be damaged or eliminated now: false while their client is
## behind its loading cover.
func can_be_harmed(player_id: StringName) -> bool:
	return not harm_gate.is_valid() or bool(harm_gate.call(player_id))


## Reads maps.yml (the shipped `res://maps.yml` under [member MmConfig.map_rotation_file], also
## looked for in the `--config` directory) and applies it. A present but unreadable file is an
## ERROR and changes nothing: rotating every map beats rotating none.
func load_rotation() -> DotResult:
	var stem := config.map_rotation_file if config != null else ""
	var dir := DotMapRotationFile.config_dir_arg()
	var found := DotMapRotationFile.find(stem, dir)

	if found == "" and stem != "" and (dir != "" or stem != MmConfig.new().map_rotation_file):
		# The default name being absent is an install with no maps.yml; a name or a directory
		# somebody chose that finds nothing is a typo they would otherwise never hear about.
		DotLog.warn(CHANNEL, "the map rotation file was not found; every map rotates", {
			"file": stem, "config_dir": dir,
		})

	var paths := PackedStringArray()
	for candidate in ["res://maps.yml", found]:
		if candidate != "" and not paths.has(candidate) and FileAccess.file_exists(candidate):
			paths.append(candidate)

	var read := DotMapRotationFile.load_files(paths, "game-murder-mystery")

	if not read.ok:
		DotLog.error(CHANNEL, "the map rotation file could not be read; every map rotates", {
			"why": read.error.message,
		})
		rotation_file = null
		apply_rotation()
		return read

	rotation_file = read.value
	if rotation_file.has_rotations():
		DotLog.info(CHANNEL, "the map rotation file", {
			"paths": ", ".join(rotation_file.sources), "active": rotation_file.active_name(),
		})

	apply_rotation()
	return read


## Marks every document in or out of rotation from the file. With no file, or one with no
## rotations, every map is in: what this game did before maps.yml. Rebuilds the defs from the
## catalogue each time, so a reload or a delivered map is seen.
func apply_rotation() -> void:
	if catalogue == null:
		return

	map_rotation_defs = DotMapCatalogue.new()
	for id in catalogue.maps:
		var doc: Dictionary = catalogue.maps[id]
		var def := DotMapDef.new()
		def.id = id
		def.display_name = str(doc.get("name", id))
		def.scene_path = "doc:%s" % id
		var _added := map_rotation_defs.add(def)

	map_rotation = DotMapRotation.of(map_rotation_defs)
	map_rotation.cooldown = 1

	if rotation_file != null and rotation_file.has_rotations():
		# An empty rotation plays every installed map: the same set as having no file.
		rotation_file.fallback_in = func(_map: DotMapDef) -> bool: return true
		var _applied := rotation_file.apply(map_rotation)


## Whether maps.yml's active rotation plays [param id]. With no file every map does; with one,
## a map the catalogue lacks does not.
func in_rotation(id: StringName) -> bool:
	if rotation_file == null or not rotation_file.has_rotations():
		return true

	var def: DotMapDef = map_rotation_defs.get_map(id) if map_rotation_defs != null else null

	return def != null and def.in_rotation


## The ids the next-map draw may pick, in the file's order; empty with no file (every map).
func rotation_pool() -> Array[StringName]:
	var out: Array[StringName] = []

	if rotation_file == null or not rotation_file.has_rotations() or map_rotation == null:
		return out

	var ordered: Array[StringName] = map_rotation.order.duplicate()
	for id in catalogue.playable(config.map_ids):
		if not ordered.has(id) and in_rotation(id):
			ordered.append(id)

	for id in ordered:
		if in_rotation(id):
			out.append(id)

	return out


## maps.yml's `commands:` block (prefix and names), or empty with no file.
func rotation_commands() -> Dictionary:
	return rotation_file.commands() if rotation_file != null else {}


## Every map this server plays, as the map menu (M) lists them: `{id, name, detail, current}`.
## Solo the client's list, online the server's, so both say the same.
func map_rows() -> Array:
	var out: Array = []
	if catalogue == null:
		return out
	var now := StringName(str(map_doc.get("id", "")))
	for id in catalogue.playable(config.map_ids):
		var doc: Dictionary = catalogue.maps.get(id, {})
		var blurb := str(doc.get("blurb", ""))
		if not in_rotation(id):
			blurb = ("%s (not in rotation)" % blurb).strip_edges()
		var row := {"id": String(id), "name": str(doc.get("name", id)), "current": id == now,
			"detail": blurb}
		if doc.has("thumbnail"):
			row["thumbnail"] = str(doc["thumbnail"])
		out.append(row)
	return out
