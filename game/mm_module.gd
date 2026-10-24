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

## This game, as a module a dedicated server loads.
##
## [b]A hundred and forty lines, against the five hand-written modules' 837 to 1,816.[/b]
## [DotGameModule] holds the netcode and its four load-bearing constants, the bridge, the
## message seal, the identity layer, the roster, the authoritative tick and a teardown in
## the reverse order. Two of those five hand-written copies had the same line wrong and
## nobody could ever join those servers. What is left here is what is actually this game's:
## the cvars an operator turns between rounds, the console commands, the map vote, and the rule
## that keeps enough people in a round for one to happen.
##
## [b]No `class_name`, and that is a requirement rather than a style.[/b]
## [method DotModuleHost.load_module] takes a PATH and constructs the module itself — it
## must, because that is the shape that lets an operator name one in a config file — and a
## module delivered inside a dot-cloud pack cannot have a `class_name` at all: a mounted
## pack's globals are not registered in the host.
##
## [codeblock]
## server.modules.load_module("res://game/mm_module.gd")
## [/codeblock]

# [b]No `const CHANNEL` here, and its absence is the point.[/b] [DotGameModule] already
# declares one and GDScript refuses to let a subclass redeclare it — which is the right
# refusal: a module logs through [method DotModule.log_info], which stamps the module's own
# name, so a second channel would split one module's records across two places an operator
# has to know to turn up separately.

## Seconds between checks of how many people are in the round.
const ROSTER_INTERVAL := 2.0

## Where the services keep punishments. Empty is [DotGameServices]'s own default,
## `user://murder_punishments.json` — the store a real server enforces.
##
## [b]Static, because nothing holds this module before it exists[/b]: dot-server constructs
## it from a path inside `load_module`, so there is no instance for a host to set a field on
## first. `examples/dedicated.tscn` points it at a directory of its own; before it could,
## every run appended the live tools' audit warnings to the real store, 106 of them by the
## time anybody counted.
static var punishments_file: String = ""

## The `mm_bots` cvar, held so the tick does not look it up sixty times a second.
var _bots: DotConVar = null

## dot-workbench over the config; the F9 panel off a dedicated server, the HTTP page only with `workbench.enabled`.
var workbench: DotGameWorkbench = null


## `mp_forcecamera`, kept so the deprecated `mm_spectate_camera` writes through it.
var _force_camera_cvar: Object = null

## How many stand-ins, from how many people: dot-server's one rule for every game. See
## [method _keep_the_round_full].
var _quota: DotBotQuota = null

var _since_roster_check: float = 0.0

## How many stand-ins this module has put in, so it can take them out again.
var _bot_ids: Array[StringName] = []

## The players' vote for the next map; null when it could not be built.
var vote: MmVote = null

## The drawn ballot's notice topic. The client shell draws one menu per topic.
const MAP_BALLOT_TOPIC := &"map_ballot"


func _module_name() -> String:
	return "murder"


## The rules a map's `cfg/game/game-murder-mystery/dot_map/map/<name>.yml` may set (see docs/map-config.md in dot-game).
func _map_config_keys() -> Dictionary:
	return MmMapConfig.KEYS


func _map_config_game() -> String:
	return MmMapConfig.GAME_ID


func _game_service() -> StringName:
	return MmGame.SERVICE


func _game_missing_hint() -> String:
	return (
		"create an MmGame, add it to the tree and let its _ready() register it under "
		+ "'%s' — a module cannot build the world, because the world outlives it"
		% String(MmGame.SERVICE)
	)


## The netcode's numbers, which are the game's and not the addon's.
##
## Tick rate from the world, so `sv_tickrate` reaches it: the server sets the engine's
## physics rate from that cvar at boot, the world is built after the server and reads it,
## and this reads the world. A number written here instead would be a netcode running at a
## rate the operator did not choose, silently.
func _net_config() -> DotNetConfig:
	var config := DotNetConfig.new()
	config.tick_rate = (game as MmGame).tick_rate
	config.snapshot_rate = MmGame.NET_SNAPSHOT_RATE
	config.world_extent = MmGame.NET_WORLD_EXTENT
	config.enable_prediction = true
	# On for the same reason as everywhere: a shot is aimed at bodies as the shooter drew them.
	# The rewind itself is MmGame's own trail (`unlag_tick_for`), since a stab and a shot are the
	# server's measurement, not dot-combat shots; this keeps dot-net's history in step.
	config.enable_lag_compensation = true
	# Everybody playing, and nothing else: the furniture is the map document, not entities, so
	# a snapshot is a full server's players and room to spare.
	config.max_entities_per_snapshot = 64
	return config


func _make_bridge() -> Node:
	return MmNetBridge.new()


## Chat, voice and moderation, over [DotGameServices].
##
## [b]The bridge is handed over as the link, and that is the whole of the wiring.[/b] A chat
## line goes out through `send_chat` and a voice frame through `send_voice`, both on this
## game's own wire. [DotGameModule] does the rest: it assigns the bridge's `voice_relay_fn`,
## checks `check_admission` before seating anybody, and tells the roster to follow this layer
## so a leaver is forgotten by the rate limiter and the voice router together.
func _make_services() -> Node:
	var services := MmServices.new()
	services.bridge = bridge
	services.punishments_file = punishments_file
	return services


## Profiles, avatars and admission: dot-platform's [DotPlatformIdentity] over this game's
## one-slot schema. [DotGameModule] builds it before the services and loads dot-platform's
## own module beside it.
##
## [b]Authentication is not here and was never this game's.[/b] Whether a player is proven
## to be somebody is the host's `dot_auth_server`, the same for every game it runs; what
## this layer does is everything after — a scoped profile, the name on it, and a face.
## With authentication off everybody is a guest with a profile of their own, which is what
## a LAN server is.
func _make_identity() -> Node:
	var identity_layer := DotPlatformIdentity.new()
	identity_layer.avatar_schema = MmAvatars.schema()
	identity_layer.stock_avatar_fn = MmAvatars.stock_avatar
	identity_layer.avatar_translate_fn = MmAvatars.from_site
	return identity_layer


func _game_load() -> DotResult:
	var world := game as MmGame

	if world == null:
		return DotResult.fail(DotError.CODE_STATE, "The registered game is not an MmGame.")

	# dot-game's "still loading": a seat behind its client's cover is neither hurt nor drawn
	# (see MmGame.harm_gate). Asked by player id, resolved to a peer through the bridge; a bot
	# or a seat the bridge does not hold has no peer and is never loading.
	world.harm_gate = func(player_id: StringName) -> bool:
		if bridge == null:
			return true
		var peer := int((bridge as MmNetBridge).peer_for_player(MmNetBridge.session_of(player_id)))
		return peer <= 0 or can_peer_be_harmed(peer)

	add_command("mm_status", _cmd_status, "Show the round, the map and who is alive")
	add_command("mm_roles", _cmd_roles, "Show who is what this round (the operator's console only)")
	add_command("mm_net", _cmd_net, "Show what the netcode is doing")
	var _rotation := world.load_rotation()
	add_cvar(
		"sv_map_rotation_file", world.config.map_rotation_file,
		"maps.yml: the maps that rotate, in named rotations. Unlisted maps stay installed."
	).changed.connect(
		func(_old: String, new_value: String) -> void:
			world.config.map_rotation_file = new_value.strip_edges()
			var _read := world.load_rotation()
			if vote != null:
				vote.refresh_maps()
	)
	# This game's own map commands are renameable from maps.yml's `commands:` block like
	# dot-vote's and dot-map's: roles `mm_maps`, `mm_reload`, `mm_map`, no prefix.
	for entry: Array in [
		["mm_maps", _cmd_maps, "List the maps, and any refused file", null],
		["mm_reload", _cmd_reload, "Read the map directory again (from the next map)", null],
		["mm_map", _cmd_map, "Play a map next: mm_map <id> (at the end of this round)", ""],
	]:
		var names := DotCommandNames.all_of("", _renames(world), {}, entry[0])
		for typed_name in names:
			if entry[3] == null:
				add_command(typed_name, entry[1], entry[2])
			else:
				add_command(typed_name, entry[1], entry[2], entry[3])
	add_command("mm_say", _cmd_say, "Say something to everybody, as the server")

	_wire_chat()
	_wire_identity()
	_wire_map(world)
	_wire_progress(world)
	_add_tunables(world)
	_build_vote(world)

	# dot-player-controller's mp_forceview (first or third person: the player's choice, or one
	# held) and mp_solidplayers (players and stand-ins block each other, 1 by default).
	# REPLICATED: the client places its own camera under the first and predicts its own
	# player under the second.
	var _views := world.view_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)
	var _bodies := world.body_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)
	# mm_ambient*: REPLICATED, because each client plays its own ambience under the server's intent; the directory cvar stays local.
	var _ambient := world.ambient_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED,
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	)
	var configured := _bind_config(world)
	if not configured.ok:
		return configured
	# Dead bodies: dot-player-char's sv_ragdoll* set. The server only picks each death's reaction
	# from them; REPLICATED, because the clients draw the bodies (see the client's netcode).
	var _ragdolls := world.ragdoll_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)
	# The map's toys: dot-props' sv_toys* set. REPLICATED, because a client hides the toys the
	# server took away and draws the rest.
	var _toys := world.toy_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)

	# mp_forcecamera, mp_freeroam, mp_freeroam_speed: dot-spectate's rules, so spectators
	# free-roam unless an operator says otherwise. REPLICATED, because each client flies its
	# own spectator camera under them (MmClient.toggle_roam).
	for made: Object in world.spectate_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	):
		if str(made.get(&"name")) == DotSpectatorRules.CVAR_FORCE_CAMERA:
			_force_camera_cvar = made

	_bots = add_cvar(
		"mm_bots", "1",
		"Automatic stand-ins: 1 keeps as many as bot_quota and bot_quota_mode say, 0 none at all."
	)

	# [b]How many is dot-server's [DotBotQuota], so `bot_quota` and `bot_quota_mode` mean the
	# same thing on every server in the family.[/b] The default is this game's own minimum
	# (`minimum_players`, from the config file) in fill mode, which is the rule it ran before
	# the policy was shared: stand-ins top the round up to that many players, a person who
	# joins takes a stand-in's place, and the stand-in comes back when they leave. `mm_bots`
	# stays the switch it always was, so a server config that sets it means what it meant.
	_quota = DotBotQuota.install(self, world.config.minimum_players)

	# [b]Started here and not in the world's own `_ready`.[/b] `start()` builds the map and puts
	# everybody on it, and a world that did that before the bridge existed would have built a
	# map with nothing listening to `world_rebuilt` — one the server knows about and no client
	# is ever told about. Invisible floors: a player stands on nothing and the server says they
	# are fine.
	var _delivered: int = await _add_delivered_maps(world)
	var _rotation_again := world.load_rotation()

	# The vote was built above, before these arrived; read without them, its list held only
	# the practice map and never opened a ballot. mm_reload refreshes it the same way.
	if vote != null:
		vote.refresh_maps()

	world.start()

	log_info("the map is up", world.describe())
	return DotResult.success(null)


## The maps the SERVER names for this game, fetched and added to the catalogue. Returns how
## many documents they held.
##
## [b]The server's list, not this game's.[/b] A map pack used to be a `server_dependencies`
## entry in `game.yml`, which travels in this game's own pack — so a new map meant a release
## of the game, and a server owner could not choose which maps to run. The owner names them
## now in their deployment's map config (dot-server-deploy's `cfg/content.yml`, which fills
## [member DotGameDescriptor.maps]); [DotGameContent] fetches each pack and hands back its
## `maps/` directory. A server that still names one under `server_dependencies` keeps working,
## because DotGameContent reads those too.
##
## [b]Still server-only.[/b] The server sends the map it is playing in MAP, so a client never
## needs a map file and none of these is in a client's content sync. With nothing named, this
## game plays its built-in map.
##
## [b]Called after EVERY catalogue load[/b], not only the first: `load_from` forgets everything
## read before, and a reload that did not come back here dropped every delivered map — which
## is what mg-wipeout and mg-deathrun did until the three were moved onto DotGameContent.
func _add_delivered_maps(world: MmGame) -> int:
	if server == null or world.catalogue == null:
		return 0

	var read := 0

	for root in await DotGameContent.map_dirs(server, "maps"):
		read += world.catalogue.add_directory(root)

	return read


## Who somebody is reaches the world: a face as they are seated, and the real name and face
## once dot-platform has them. All three events end in [method MmNetBridge.refresh_player].
func _wire_identity() -> void:
	var link := bridge as MmNetBridge

	if link == null:
		return

	link.avatar_fn = _avatar_for
	hook_post("player_admitted", _on_profile)
	hook_post("player_avatar_changed", _on_profile)
	hook_post("player_renamed", _on_profile)


## What a session looks like: what dot-platform resolved for them, or the stock person.
##
## [b]Through the platform module's `player_for`, and never the hub by a key made here.[/b]
## The hub keys a player by their scoped profile key, which only admission knows; a lookup
## by `u<session>` finds nobody, every time, and falls through to stock — which reads as
## "this player has no avatar" rather than as a wrong key. Duck-typed, because a server
## without dot-platform is a configuration.
func _avatar_for(session_id: int) -> DotAvatar:
	var session := server.session_by_userid(session_id) if server != null else null
	var platform: Object = server.modules.get_module("platform") \
		if server != null and server.modules != null else null

	if session != null and platform != null and platform.has_method("player_for"):
		var player: Variant = platform.call("player_for", session)

		if player is Object and (player as Object).get("avatar") is DotAvatar:
			return (player as Object).get("avatar") as DotAvatar

	if identity != null and identity.has_method("avatar_for"):
		return identity.call("avatar_for", String(MmNetBridge.player_key(session_id)))

	return null


func _on_profile(event: DotEvent) -> void:
	var session_id := event.get_int("userid")
	var session := server.session_by_userid(session_id) if server != null else null
	var link := bridge as MmNetBridge

	if session == null or link == null:
		return

	link.refresh_player(session_id, session.display_name, _avatar_for(session_id))


## The numbers an operator is actually going to want to change, as cvars.
##
## [b]Live, and each one writes through to the configuration the world already reads.[/b] A
## server owner finds their server's balance by moving one of them between rounds with people
## watching; a JSON file and a restart is a balance nobody tunes.
##
## [b]What is NOT here is anything the round has already decided.[/b] `mm_players_per_murderer`
## changes how many are drawn for the NEXT round; it does not make anybody a murderer now.
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
	var started := workbench.start()
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
##
## [b]Not `%g`, which GDScript's format strings do not have.[/b] It is accepted by the parser
## and fails at RUNTIME with "unsupported format character" — inside `_game_load`, which is
## the one place in the module sequence that unwinds everything above it. The symptom in
## game-buses-from-hell was a server whose netcode came up, logged that it was ready, and
## then reported that the game would not load.
static func _number(value: float) -> String:
	return "%d" % int(round(value)) if is_equal_approx(value, round(value)) else "%.3f" % value


## One cvar, its default taken from the configuration rather than written twice.
##
## [b]The default is the value the world was built with, and that is the whole point.[/b] A
## cvar declared with a literal default is a second copy of a number that
## `defaults < JSON < environment < argv` has already decided — so an operator who set
## `MM_ROUND_SECONDS=240` would see `mm_round_seconds` report 300 and, worse, would reset
## their own setting the moment anything wrote the value back.
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


## [b]Nothing to undo.[/b] The commands are the module's own and [DotModule] removes them;
## the netcode, the bridge and the roster are [DotGameModule]'s and it tears them down in
## the reverse order it built them. The world is NOT this module's to free: it was in the
## tree before the module loaded, and a server can unload and reload a game module without
## the map going away, which is what `module reload` is for.
func _game_unload() -> void:
	if workbench != null:
		workbench.queue_free()
		workbench = null

	if game != null and "block_rules" in game:
		game.set(&"block_rules", null)

	noblock = null

	if game != null and "harm_gate" in game:
		game.set(&"harm_gate", Callable())

	_bot_ids.clear()

	if vote != null:
		vote.queue_free()
		vote = null


## The server slept or woke. The vote's director follows it on its own (DotGameModule finds
## it); the map ballot's timer is this game's, so it starts again here on waking.
func _game_hibernation(hibernating: bool) -> void:
	if not hibernating and vote != null:
		vote.note_woke()


## Keeps enough people in the round for there to be one.
##
## [b]A murderer and somebody to murder, or nothing happens at all.[/b] A round ends the moment a side has
## nobody alive, and a side with nobody AT ALL satisfies that on the first tick — so a server
## with one person on it would start a round, end it and start another for as long as nobody
## else joined. Every one of those rounds is decided correctly, which is why nothing errors.
##
## A stand-in is removed the moment a person takes their place. They are here to make the
## game exist, not to take the fun half from the people who came to play it.
## A murderer plays no avatar action while a round runs: a dance would give them away to the
## bystanders watching for who acts strangely. Everybody else, and everybody between rounds, may.
func _avatar_action_veto(peer_id: int, _id: String) -> bool:
	var world := game as MmGame
	if world == null or bridge == null or world.phase != MmGame.Phase.PLAY:
		return false
	var who: MmPlayer = world.players.get(MmNetBridge.player_key((bridge as MmNetBridge).player_for_peer(peer_id)))
	return who != null and who.team == MmGame.MURDERERS


func _game_tick(_tick: int, delta: float) -> void:
	if vote != null:
		vote.advance(delta)

	_since_roster_check += delta

	if _since_roster_check < ROSTER_INTERVAL:
		return

	_since_roster_check = 0.0
	_keep_the_round_full()
	_note_pings()


## Each session's ping onto its player, for the Tab board. dot-server already keeps it.
func _note_pings() -> void:
	var world := game as MmGame
	if world == null or server == null:
		return
	for session in server.playing_sessions():
		var who: MmPlayer = world.players.get(MmNetBridge.player_key(session.userid))
		if who != null:
			who.ping_ms = session.ping_ms


func _keep_the_round_full() -> void:
	var world := game as MmGame

	if world == null or bridge == null or _quota == null:
		return

	# People only. A stand-in is not one, and neither is a bot somebody put in by hand through
	# the bridge (a test, an admin): those are never in `_bot_ids` either, so they are left
	# alone and outside the count. A leaver is gone from `players` the moment the bridge
	# removes them, so nobody half-disconnected is counted.
	var humans := 0

	for id: StringName in world.players:
		if not (world.players[id] as MmPlayer).is_bot:
			humans += 1

	# Forget any that have gone for some other reason — a round reset, an admin — so the
	# count below is of stand-ins that actually exist.
	for index in range(_bot_ids.size() - 1, -1, -1):
		if not world.players.has(_bot_ids[index]):
			_bot_ids.remove_at(index)

	# `mm_bots 0` takes the stand-ins out as well as not adding more: a switch that left the
	# ones already in until a map change would be an operator with no way to empty a server.
	var wanted := 0

	if _bots == null or _bots.get_bool():
		var slots: int = server.config.max_players if server != null and server.config != null else -1
		wanted = _quota.wanted(humans, slots)

	for _i in range(maxi(wanted - _bot_ids.size(), 0)):
		var bot: MmPlayer = bridge.call("add_bot", _bot_name(world))

		if bot == null:
			break

		_bot_ids.append(bot.player_id)

	# Newest first, so the stand-in a person replaces is the one that arrived last and the
	# ones that have been playing longest keep playing.
	while _bot_ids.size() > wanted:
		var leaving: StringName = _bot_ids.pop_back()
		bridge.call("remove_player", MmNetBridge.session_of(leaving))


## A stand-in's name: the game's list through dot-bot's [DotBotNames], never one already in
## [param world], so solo and a server name them alike and a scoreboard never has two Wrens.
static func _bot_name(world: MmGame) -> String:
	var taken: Array = []
	for id: StringName in world.players:
		taken.append((world.players[id] as MmPlayer).display_name)
	return DotBotNames.pick(taken, world.players.size(), MmGame.BOT_NAMES)


## Joins the bridge's chat seam to the services layer's router.
##
## [b]Here rather than in either of them, because this is the only object that holds
## both.[/b] The bridge knows what arrived on the wire and nothing about what a line means;
## the services layer knows the rules and nothing about the wire. That separation is why a
## client cannot send a line with somebody else's name on it: what crosses is a channel id
## and a string, and everything else is decided on this side.
func _wire_chat() -> void:
	if bridge == null or services == null:
		return

	bridge.connect("say_requested", _on_say_requested)
	services.connect("command_entered", _on_chat_command)

	var world := game as MmGame
	if world != null:
		world.bot_said.connect(_on_bot_said)


## A stand-in's line (mm_bot_chat.gd), to everybody, as "Name: text". Through the server's
## announcement rather than as a player, because a stand-in has no peer to say it from.
func _on_bot_said(player_id: StringName, text: String) -> void:
	var world := game as MmGame
	var chat: Object = services.get("chat") if services != null else null
	var who: MmPlayer = world.players.get(player_id) if world != null else null

	if chat == null or who == null:
		return

	var _said: Variant = chat.call("announce", "%s: %s" % [who.display_name, text], MmServices.CH_ALL)


## The players' vote for the next map, over dot-vote: `!vote`, `!rtv`, `!nominate`.
##
## [b]Opened [member MmVote.open_after_sec] into the last round on a map and applied when that
## round ends[/b]; see [code]game/mm_vote.gd[/code]. A server owner turns it off or reshapes it
## in `user://cfg/murder_vote.json` or `game.yml`'s `metadata: map_vote:`, keyed as dot-vote's
## [DotVoteRules]. A vote that cannot be built is a WARN and the rotation alone, never a server
## that will not start.
func _build_vote(world: MmGame) -> void:
	if world.catalogue == null:
		return

	vote = MmVote.new()
	vote.name = "MapVote"
	vote.maps_fn = func() -> Array:
		var out: Array = []

		for id in world.catalogue.playable(world.config.map_ids):
			# maps.yml's rotation decides the ballot; a map it leaves out is still installed.
			if not world.in_rotation(id):
				continue
			out.append([id, str((world.catalogue.maps.get(id, {}) as Dictionary).get("name", id))])

		return out
	vote.apply_fn = func(id: StringName) -> DotResult:
		world.next_map_id = id
		return DotResult.success(id)
	vote.due_fn = func() -> bool:
		return world.rounds_left_on_map() <= 1
	vote.voters_fn = func() -> Array:
		var out: Array = []

		for id: Variant in world.players:
			var player: MmPlayer = world.players[id]

			if player == null or player.is_bot:
				continue

			var userid := MmNetBridge.session_of(StringName(str(id)))

			if userid > 0:
				out.append(StringName(str(userid)))

		return out
	vote.announce_fn = func(line: String) -> void:
		var chat: Object = services.get("chat") if services != null else null

		if chat != null:
			var _said: Variant = chat.call("announce", line, MmServices.CH_ALL)
		elif server != null:
			server.broadcast_message(line)
	vote.is_admin_fn = func(voter: StringName) -> bool:
		var session := server.session_by_userid(String(voter).to_int()) if server != null else null
		return session != null and session.has_permission(DotAdminFlags.CHANGEMAP)
	vote.ballot_fn = func(state: Dictionary) -> void:
		if server == null:
			return

		for session in server.playing_sessions():
			var data := state.duplicate()
			data["you"] = str(session.userid)
			server.send_notice(session, DotNotice.make(
				&"", "", float(state.get("seconds", -1.0)), MAP_BALLOT_TOPIC, data
			))
	vote.people_fn = func(voter: StringName) -> Dictionary:
		var session := server.session_by_userid(String(voter).to_int()) if server != null else null

		if session == null:
			return {}

		var avatar: Variant = session.identity.get("avatar_url") if session.identity != null else ""
		return {"name": session.display_name, "avatar": avatar if avatar is String else ""}

	# Whether a round is live, for `time_up: finish_round`: warmup and the gap between rounds
	# have nothing to play out, so a limit that runs out there changes at once. No match is
	# "cannot tell", which holds as before.
	vote.round_in_progress_fn = func() -> bool:
		return world.match_node == null or world.match_node.is_live()

	add_child(vote)
	var ready := vote.setup()

	if not ready.ok:
		DotLog.result(CHANNEL, "the map vote; the rotation alone chooses", ready)
		vote.queue_free()
		vote = null
		return

	vote.commands_spec_fn = world.rotation_commands
	var commanded := vote.install_commands(self)
	DotLog.result(CHANNEL, "the map vote's commands", commanded)

	# The map menu (M), dot-vote's: a player holding the owner's `sv_map_menu_flag` changes the
	# map now, not after its rounds, and sees the same rows a solo player does. Read by name,
	# because a server on a dot-vote older than the menu has no `map_menu` and runs without it.
	var menu_half: Variant = vote.commands.get(&"map_menu") if vote.commands != null else null
	if menu_half is Object:
		(menu_half as Object).set(&"change_fn", world.change_map_now)
		(menu_half as Object).set(&"rows_fn", func(_rows: Array) -> Array: return world.map_rows())

	_tunable("mm_vote_after", vote.open_after_sec,
		"Seconds into the last round on a map before the vote for the next one opens",
		func(value: float) -> void:
			if vote != null:
				vote.open_after_sec = maxf(value, 0.0))

	world.world_rebuilt.connect(func() -> void:
		if vote != null and world.map != null:
			vote.note_map(world.map.id())
	)
	world.round_began.connect(func(_number: int, _map: StringName) -> void:
		if vote != null:
			vote.note_round_start()
	)
	world.match_node.round_ended.connect(func(_number: int, _winner: int, _outcome: int) -> void:
		if vote != null:
			vote.note_round_end()
	)

	if server != null:
		server.client_disconnected.connect(func(session: DotClientSession, _reason: String) -> void:
			if vote != null:
				vote.forget_voter(StringName(str(session.userid)))
		)


## The map is what a server listing prints, reported on every rebuild: the server forgets it
## whenever a game unloads, and a browser showing last round's map is a browser lying.
func _wire_map(world: MmGame) -> void:
	if world.map != null and not world.map.doc.is_empty():
		report_map(String(world.map.id()))

	world.world_rebuilt.connect(func() -> void:
		report_map(String(world.map.id()))
	)


## An achievement is told to the one person who earned it.
##
## [b]As a notice, which a client already draws in its chat box[/b], rather than a new event
## kind: an unlock is text for one player, which is exactly what a notice is — and a stand-in
## never earns one, because [MmProgress] does not count them.
func _wire_progress(world: MmGame) -> void:
	if bridge == null:
		return

	# What a player keeps is filed under their scoped profile key, so it outlives the
	# connection; see [MmProgress]. Nothing for a stand-in or a guest, who keep their seat's.
	if world.progress != null:
		world.progress.durable_key_fn = func(id: StringName) -> String:
			var session := server.session_by_userid(MmNetBridge.session_of(id)) \
				if server != null else null
			var platform: Object = server.modules.get_module("platform") \
				if server != null and server.modules != null else null

			if session == null or platform == null or not platform.has_method("player_for"):
				return ""

			var held: Variant = platform.call("player_for", session)
			return str((held as Object).call("key")) if held is Object else ""

	world.achievement_earned.connect(func(id: StringName, title: String, points: int) -> void:
		var peer_id: int = bridge.call("peer_for_player", MmNetBridge.session_of(id))

		if peer_id > 0:
			bridge.call("notice", peer_id, "Achievement: %s (+%d)" % [title, points])
	)


func _on_say_requested(peer_id: int, channel_id: StringName, text: String) -> void:
	var said: DotResult = services.call("say", peer_id, channel_id, text)

	if said.ok:
		return

	# Back to the one person who asked. A refusal broadcast would be a rate limit announced
	# to the server.
	bridge.call("notice", peer_id, said.error.message)


## A `!command` typed into chat. Run through the console as the person who typed it.
##
## [b]As THEM, not as the server.[/b] `run_command_as_uid` builds a context with that
## player's own flags, so `!kick` from somebody without the flag is refused by the same file
## that refuses it at the console — rather than by this function having an opinion.
func _on_chat_command(peer_id: int, command: String, args: PackedStringArray) -> void:
	if server == null:
		return

	var session := server.session_of(peer_id)

	if session == null:
		return

	for reply in server.run_command_as_uid(
		session.uid(), command, args, DotCmdContext.Source.CHAT
	):
		bridge.call("notice", peer_id, reply)


## Who is what this round, for the operator. Answered on the server's own console only: from a
## player's chat or an rcon session it would be the one thing this game keeps secret.
func _cmd_roles(ctx: DotCmdContext) -> void:
	var world := game as MmGame

	if world == null:
		ctx.reply("No world.")
		return

	if ctx.source != DotCmdContext.Source.CONSOLE and ctx.source != DotCmdContext.Source.INTERNAL:
		ctx.reply("Roles are secret; only the server's own console can list them.")
		return

	for id: StringName in world.players:
		var p: MmPlayer = world.players[id]
		var role := "murderer" if world.team_of(id) == MmGame.MURDERERS else (
			"gunner" if p.has_gun else ("bystander" if world.team_of(id) == MmGame.BYSTANDERS else "-"))
		ctx.reply("  %-10s %-18s %-10s %s" % [String(id), p.display_name, role, "alive" if p.is_alive() else "out"])


func _cmd_say(ctx: DotCmdContext) -> void:
	var text := ctx.rest()

	if text.strip_edges() == "":
		ctx.reply("Say what?")
		return

	if services == null or services.get("chat") == null:
		ctx.reply("This server has no chat.")
		return

	var announced: Variant = services.get("chat").call("announce", text, MmServices.CH_ALL)

	if announced is DotResult and not (announced as DotResult).ok:
		ctx.reply_error(announced)
		return

	ctx.reply("Said: %s" % text)


func _cmd_status(ctx: DotCmdContext) -> void:
	var world := game as MmGame

	if world == null:
		ctx.reply("No world.")
		return

	ctx.reply_lines(world.describe_lines())


func _cmd_net(ctx: DotCmdContext) -> void:
	if bridge == null:
		ctx.reply("No bridge; this server is not replicating anything.")
		return

	ctx.reply_lines(bridge.call("describe_lines"))

	if services != null:
		ctx.reply_lines(services.call("describe_lines"))


## maps.yml's `names:` for this game's own commands, role to name or list of names.
func _renames(world: MmGame) -> Dictionary:
	return (world.rotation_commands().get("names", {}) as Dictionary)


func _cmd_maps(ctx: DotCmdContext) -> void:
	var world := game as MmGame

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	ctx.reply_lines(world.catalogue.describe_lines(world.in_rotation))
	ctx.reply("playing: %s" % str(world.map_doc.get("id", "-")))


func _cmd_map(ctx: DotCmdContext) -> void:
	var world := game as MmGame
	var id := StringName(ctx.arg(0)) if ctx.argc() > 0 else &""

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	if id == &"" or not world.catalogue.playable(world.config.map_ids).has(id):
		ctx.reply("Which map? %s" % ", ".join(world.catalogue.playable(world.config.map_ids)))
		return

	world.next_map_id = id
	ctx.reply("%s is next, from the end of this round." % String(id))


func _cmd_reload(ctx: DotCmdContext) -> void:
	var world := game as MmGame

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	var loaded := world.catalogue.load_from(world.config.map_directory)
	loaded += await _add_delivered_maps(world)
	var _rotation := world.load_rotation()

	if vote != null:
		vote.refresh_maps()

	ctx.reply("%d documents read; %d refused. The next map draws from them." % [
		loaded, world.catalogue.refused.size()])


## This game's columns on the Tab board: the points, and the PUBLIC side (everybody in the round
## is the same), because the board is sent to every client.
func _game_board_fields(session: Object) -> Dictionary:
	var world := game as MmGame
	var who: MmPlayer = world.players.get(MmNetBridge.player_key(int(session.get(&"userid")))) if world != null and session != null else null

	if who == null:
		return {}

	return {"points": who.points, "team": MmNetBridge.public_side(world.team_of(who.player_id))}


func describe() -> Dictionary:
	var out := super.describe()
	var world := game as MmGame

	if world != null:
		out.merge({"round": world.round_number, "world": world.describe()}, true)

	return out
