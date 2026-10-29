extends DotGameModule

const MmNetBridge := preload("net/mm_net_bridge.gd")
const MmServices := preload("mm_services.gd")
const MmGame := preload("mm_game.gd")
const MmPlayer := preload("mm_player.gd")
const MmAvatars := preload("mm_avatars.gd")
const MmVote := preload("mm_vote.gd")
const MmMapConfig := preload("mm_map_config.gd")
const MmAmbience := preload("mm_ambience.gd")
## The workbench kind of the ambience cvar set (saved to cfg/.../ambience/server.yml).
const AMBIENT_KIND := "ambience"
## The drawn ballot's notice topic. The client shell draws one menu per topic.
const MAP_BALLOT_TOPIC := &"map_ballot"

## dot-workbench over the config; the F9 panel off a dedicated server, the HTTP page only with `workbench.enabled`.
var workbench: DotGameWorkbench = null

## `mp_forcecamera`, kept so the deprecated `mm_spectate_camera` writes through it.
var _force_camera_cvar: Object = null

## How many stand-ins, from how many people: dot-server's one rule for every game. See
## [method _keep_the_round_full].
var _quota: DotBotQuota = null

## The players' vote for the next map; null when it could not be built.
var vote: MmVote = null


## The maps the SERVER names (via [DotGameContent]) added to the catalogue; returns how many
## documents. Server-only, and called after EVERY catalogue load, which forgets what it read.
func _add_delivered_maps(world: MmGame) -> int:
	if server == null or world.catalogue == null:
		return 0

	var read := 0

	for root in await DotGameContent.map_dirs(server, "maps"):
		read += world.catalogue.add_directory(root)

	return read


## The numbers an operator is going to want to change, as cvars, each writing through to the
## configuration the world already reads. Nothing here changes the round in progress:
## `mm_players_per_murderer` applies to the NEXT draw.
func _add_tunables(world: MmGame) -> void:
	var config := world.config

	# [b]How the stand-ins see, hear, turn and know a map is dot-bot's[/b]: `bot_difficulty`
	# (easy, medium, hard, nightmare; medium by default) and every `bot_*` setting it bundles,
	# the names every game in the family uses. On the game as metadata, never the registry.
	var _bot_cvars := DotBotSettings.of(world).bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY, add_command)
	_tunable("mm_max_unlag_ms", world.max_unlag_ms,
		"How far back a stab or shot looks at the other players for the shooter's latency, in ms (0 off)",
		func(value: float) -> void: world.max_unlag_ms = maxf(value, 0.0))
	_tunable("mm_grace_seconds", config.grace_seconds,
		"Seconds at the top of a round when nobody can draw or shoot (a map may ask for less)",
		func(value: float) -> void: config.grace_seconds = clampf(value, 0.0, 60.0))
	_tunable("mm_round_seconds", config.round_seconds,
		"Seconds of play after the grace; when they run out the bystanders win (a map may ask for less)",
		func(value: float) -> void: config.round_seconds = clampf(value, 30.0, 1800.0))
	_tunable("mm_players_per_murderer", config.players_per_murderer,
		"One murderer for every this many players, from the next round",
		func(value: float) -> void: config.players_per_murderer = clampf(value, 2.0, 64.0))
	_tunable("mm_min_murderers", float(config.min_murderers),
		"The fewest murderers a round starts with, from the next round",
		func(value: float) -> void: config.min_murderers = clampi(int(value), 1, config.max_murderers))
	_tunable("mm_max_murderers", float(config.max_murderers),
		"The most murderers a round starts with, from the next round",
		func(value: float) -> void: config.max_murderers = clampi(int(value), config.min_murderers, 8))
	_tunable("mm_players_per_gunner", config.players_per_gunner,
		"One bystander with the gun for every this many players, from the next round",
		func(value: float) -> void: config.players_per_gunner = clampf(value, 2.0, 64.0))
	_tunable("mm_min_gunners", float(config.min_gunners),
		"The fewest bystanders handed the gun, from the next round",
		func(value: float) -> void: config.min_gunners = clampi(int(value), 1, config.max_gunners))
	_tunable("mm_max_gunners", float(config.max_gunners),
		"The most bystanders handed the gun, from the next round",
		func(value: float) -> void: config.max_gunners = clampi(int(value), config.min_gunners, 8))
	_tunable("mm_melee_range", config.melee_range,
		"Metres a murderer's strike reaches (0 = the weapon's own)",
		func(value: float) -> void: config.melee_range = clampf(value, 0.0, 4.0))
	_tunable("mm_melee_cooldown", config.melee_cooldown,
		"Seconds between two strikes (0 = the weapon's own)",
		func(value: float) -> void: config.melee_cooldown = clampf(value, 0.0, 10.0))
	_tunable("mm_melee_cone", config.melee_cone,
		"Half-angle in degrees of the cone a strike lands in",
		func(value: float) -> void: config.melee_cone = clampf(value, 5.0, 90.0))
	_add_gun_tunables(world)
	_add_blood_tunables(world)


## The draw, the gun and its drops.
func _add_gun_tunables(world: MmGame) -> void:
	var config := world.config
	_tunable("mm_draw_seconds", config.draw_seconds,
		"Seconds after drawing before a strike can land",
		func(value: float) -> void: config.draw_seconds = clampf(value, 0.0, 3.0))
	_tunable("mm_gun_cooldown", config.gun_cooldown,
		"Seconds between two shots of the gun",
		func(value: float) -> void: config.gun_cooldown = clampf(value, 0.0, 30.0))
	_tunable("mm_gun_range", config.gun_range, "Metres the gun reaches",
		func(value: float) -> void: config.gun_range = clampf(value, 5.0, 300.0))
	_tunable("mm_drop_on_miss", 1.0 if config.drop_on_miss else 0.0,
		"1 = a miss drops the gun for somebody else to pick up, 0 = a miss only costs the cooldown",
		func(value: float) -> void: config.drop_on_miss = value >= 0.5)
	_tunable("mm_drop_on_innocent", 1.0 if config.drop_on_innocent else 0.0,
		"1 = shooting an innocent drops the gun and bans the shooter from it this round",
		func(value: float) -> void: config.drop_on_innocent = value >= 0.5)
	_tunable("mm_innocent_kills_shooter", 1.0 if config.innocent_kills_shooter else 0.0,
		"1 = shooting an innocent kills the shooter as well",
		func(value: float) -> void: config.innocent_kills_shooter = value >= 0.5)
	_tunable("mm_pickup_range", config.pickup_range,
		"Metres from a dropped gun at which walking over it picks it up",
		func(value: float) -> void: config.pickup_range = clampf(value, 0.3, 3.0))


## Blood, the weapon, rounds, gravity and the deprecated forwards.
func _add_blood_tunables(world: MmGame) -> void:
	var config := world.config
	_tunable("mm_blood_seconds", config.blood_seconds,
		"Seconds before the end of the round the murderer starts to show blood (0 never)",
		func(value: float) -> void: config.blood_seconds = clampf(value, 0.0, 600.0))
	_tunable("mm_blood_stages", float(config.blood_stages),
		"How many steps the blood comes in",
		func(value: float) -> void: config.blood_stages = clampi(int(value), 1, 8))
	_tunable("mm_blood_per_kill", 1.0 if config.blood_per_kill else 0.0,
		"1 = each kill adds a step of blood too",
		func(value: float) -> void: config.blood_per_kill = value >= 0.5)
	_tunable("mm_murderer_speed", config.murderer_speed_scale,
		"The murderer's run speed against everybody else's, from the next round",
		func(value: float) -> void: config.murderer_speed_scale = clampf(value, 0.5, 2.0))
	_tunable("mm_bot_chat", 1.0 if config.bot_chat else 0.0,
		"1 = the stand-ins talk in chat",
		func(value: float) -> void: config.bot_chat = value >= 0.5)
	_tunable("mm_doors", 1.0 if config.doors_enabled else 0.0,
		"1 = the use key opens and shuts doors, 0 = every door stays as the map has it",
		func(value: float) -> void: config.doors_enabled = value >= 0.5)
	var weapon := add_cvar("mm_murderer_weapon", config.murderer_weapon,
		"The murderer's melee weapon, from the next round: %s" % ", ".join(MmGame.MmWeapons.ids()))
	if weapon != null:
		weapon.changed.connect(func(_old: String, now: String) -> void:
			if MmGame.MmWeapons.known(StringName(now)):
				config.murderer_weapon = now
				log_info("a tunable changed", {"cvar": "mm_murderer_weapon", "now": now})
			else:
				log_warn("no such weapon; kept the last one", {"asked": now, "kept": config.murderer_weapon})
		)
	_tunable("mm_rounds_per_map", float(config.rounds_per_map),
		"Rounds on a map before the next one",
		func(value: float) -> void: config.rounds_per_map = clampi(int(value), 1, 50))
	_tunable("mm_gravity", config.gravity, "Metres per second squared, for everything",
		func(value: float) -> void: config.gravity = value)
	_tunable("mm_autobhop", 1.0 if config.auto_bunny_hop else 0.0,
		"Whether holding jump hops again on landing, from the next round",
		func(value: float) -> void:
			config.auto_bunny_hop = value > 0.5
			for id: StringName in world.players:
				(world.players[id] as MmPlayer).retune())
	_tunable("mm_spectate_camera", float(config.spectate_camera),
		"Deprecated, sets mp_forcecamera. Who somebody who is out may watch: 0 anybody, 2 nobody (1, their own side, is anybody here: sides are secret)",
		func(value: float) -> void:
			config.spectate_camera = clampi(int(value), 0, 2)
			# Through the cvar, so what `mp_forcecamera` reports is what is in force.
			if _force_camera_cvar != null:
				var _set: Variant = _force_camera_cvar.set_value(str(config.spectate_camera))
			elif world.spectate != null:
				world.spectate.set_force_camera(config.spectate_camera))
	# [b]Deprecated: the count is `bot_quota` now[/b], and this forwards to it. Kept rather than
	# removed because every shipped server config sets it; left as its own number it would be
	# a second cvar deciding the same count, and whichever was read last would win.
	_tunable("mm_min_players", float(config.minimum_players),
		"Deprecated, sets bot_quota. How many players the server keeps in a round with stand-ins",
		func(value: float) -> void:
			config.minimum_players = clampi(int(value), 0, 24)
			if _quota != null and _quota.quota_cvar != null:
				var _set := _quota.quota_cvar.set_value(str(config.minimum_players)))

## Config fields whose hand-written cvar is not `mm_<field>`.
const HAND_RENAMES := {
	"murderer_speed_scale": "mm_murderer_speed", "doors_enabled": "mm_doors",
	"auto_bunny_hop": "mm_autobhop", "minimum_players": "mm_min_players",
}


## The hand-written cvar of a config field, or "" when the binder makes its own.
func _hand_cvar(key: String) -> String:
	var name: String = HAND_RENAMES.get(key, "mm_%s" % key)
	return name if console.has_name(name) else ""


## Every config field as an `mm_<field>` cvar (the hand-written ones keep their handlers and follow workbench edits), the cfg/ diff commands, the workbench and dot-team's block rules.
func _bind_config(world: MmGame) -> DotResult:
	var binder := world.config_binder
	if binder == null:
		return DotResult.success(null)
	workbench = DotGameWorkbench.new()
	workbench.name = "Workbench"
	workbench.dedicated = DisplayServer.get_name() == "headless"
	workbench.listen_host_fn = func() -> bool: return DisplayServer.get_name() != "headless"
	workbench.permit_fn = func(actor: Variant, flag: String) -> bool:
		return server != null and server.admins != null and actor is String \
			and bool(server.admins.uid_has_permission(actor, flag))
	for set: DotProfileSet in binder.profile_sets():
		workbench.add_set(set, "Game settings: %s" % set.rel_path.trim_prefix("config_"))
	var ambient_set := DotGameWorkbench.cvar_set(console, MmAmbience.cvar_types(), AMBIENT_KIND)
	if ambient_set != null:
		workbench.add_set(ambient_set, "Ambience (mm_ambient*)")
	add_child(workbench)
	var started := workbench.start(world.ensure_runtime())
	# Off until the owner sets sv_workbench_remote 1; then flagged admins edit from a client.
	if started.ok and net != null:
		var _served := workbench.serve_remote(net)
	var runtime: DotProfileRuntime = workbench.api.runtime if started.ok and workbench.api != null else null
	if not started.ok:
		log_warn("the workbench did not start", {"why": started.error.message})

	binder.bind_cvars(add_cvar, DotConVar.FLAG_ARCHIVE,
		func(name: String) -> bool: return console.has_name(name))
	binder.bind_commands(add_command)
	if ambient_set != null:
		DotGameWorkbench.bind_cvar_set(ambient_set, runtime, console)
	binder.field_changed.connect(_on_config_field)
	if runtime != null:
		binder.attach(runtime)

	return DotResult.success(null)


## Everybody is one side (see [method MmGame.team_of_side]).
func _noblock_side(id: Variant) -> Variant:
	return game.call(&"team_of_side", id) if game != null else ""


## The workbench's runtime, so its "noblock" kind is listed beside the config.
func _noblock_runtime() -> Object:
	return workbench.api.runtime if workbench != null and workbench.api != null else null


## The block commands are keyed by the player ids the world uses (`u<userid>`), not the bare userid.
func _build_noblock() -> DotResult:
	var built := super()
	if built.ok and noblock != null and noblock.commands != null:
		noblock.commands.set(&"key_fn", func(ctx: Object) -> Variant:
			var session: Variant = ctx.get("session")
			return MmNetBridge.player_key(int(session.get("userid"))) if session is Object else null)
	return built


## A workbench or file edit of a field: pushed through its hand-written cvar so the handler runs.
func _on_config_field(key: String, _value: Variant, source: String) -> void:
	if source == "cvar":
		return
	var hand := _hand_cvar(key)
	if hand == "":
		return
	var text: Variant = game.config.get(key)
	if text is bool:
		text = "1" if text else "0"
	console.set_cvar(hand, str(text))


## A number as an operator would type it: `34`, not `34.000000`.
## Not `%g`: GDScript parses it but fails at RUNTIME, inside `_game_load`, which unwinds the whole
## module sequence.
static func _number(value: float) -> String:
	return "%d" % int(round(value)) if is_equal_approx(value, round(value)) else "%.3f" % value


## One cvar, its default taken from the configuration rather than written twice.
## A literal default would be a second copy of a number `defaults < JSON < env < argv` has decided,
## and would reset an operator's own setting the moment anything wrote the value back.
func _tunable(
	cvar_name: String, current: float, description: String, apply: Callable
) -> void:
	var cvar := add_cvar(cvar_name, _number(current), description)

	if cvar == null:
		return

	# The handler must not capture `cvar`: it would be a reference cycle the engine never frees.
	cvar.changed.connect(func(_old: String, new_value: String) -> void:
		apply.call(new_value.to_float())
		log_info("a tunable changed", {"cvar": cvar_name, "now": new_value})
	)
