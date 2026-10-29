extends "mm_module_vote.gd"

## This game, as a module a dedicated server loads. No `class_name`: a module in a dot-cloud pack
## cannot have one, and [method DotModuleHost.load_module] takes a PATH and constructs it.
## [DotGameModule] declares CHANNEL, so none here.

## Seconds between checks of how many people are in the round.
const ROSTER_INTERVAL := 2.0

## Where the services keep punishments; empty is `user://murder_punishments.json`. Static, because
## dot-server constructs the module from a path, so no instance exists for a host to set a field on.
static var punishments_file: String = ""

## The `mm_bots` cvar, held so the tick does not look it up sixty times a second.
var _bots: DotConVar = null

var _since_roster_check: float = 0.0

## How many stand-ins this module has put in, so it can take them out again.
var _bot_ids: Array[StringName] = []


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
## Tick rate comes from the world so `sv_tickrate` reaches it; a number written here would run
## the netcode at a rate the operator did not choose.
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


## Chat, voice and moderation, over [DotGameServices]; the bridge is handed over as the link
## and [DotGameModule] wires the voice relay, admission and the roster.
func _make_services() -> Node:
	var services := MmServices.new()
	services.bridge = bridge
	services.punishments_file = punishments_file
	return services


## Profiles, avatars and admission: dot-platform's [DotPlatformIdentity] over this game's
## one-slot schema, built before the services. Authentication is the host's `dot_auth_server`;
## with it off everybody is a guest with a profile of their own.
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
	_add_map_commands(world)
	add_command("mm_say", _cmd_say, "Say something to everybody, as the server")

	_wire_chat()
	_wire_identity()
	_wire_map(world)
	_wire_progress(world)
	_add_tunables(world)
	_build_vote(world)

	_bind_rule_cvars(world)
	var configured := _bind_config(world)
	if not configured.ok:
		return configured
	_bind_world_cvars(world)

	_bots = add_cvar(
		"mm_bots", "1",
		"Automatic stand-ins: 1 keeps as many as bot_quota and bot_quota_mode say, 0 none at all."
	)

	# [b]How many is dot-server's [DotBotQuota][/b], so `bot_quota` and `bot_quota_mode` mean the
	# same on every server. The default is this game's `minimum_players` in fill mode; `mm_bots`
	# stays the switch it was.
	_quota = DotBotQuota.install(self, world.config.minimum_players)

	# Started here, not in the world's `_ready`: `start()` builds the map, and one built before
	# the bridge existed would have nothing listening to `world_rebuilt`, so no client would
	# ever be told of it.
	var _delivered: int = await _add_delivered_maps(world)
	var _rotation_again := world.load_rotation()

	# The vote was built above, before these arrived; read without them, its list held only
	# the practice map and never opened a ballot. mm_reload refreshes it the same way.
	if vote != null:
		vote.refresh_maps()

	world.start()

	log_info("the map is up", world.describe())
	return DotResult.success(null)


## The map commands, renameable from maps.yml.
func _add_map_commands(world: MmGame) -> void:
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


func _bind_rule_cvars(world: MmGame) -> void:
	# sv_falldamage and its tunables: dot-combat's, on by default in this game. Server-side
	# only, so no REPLICATED: the damage is the server's and arrives as health.
	var _fall := world.fall_rules.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY)

	# mp_forceview and mp_solidplayers, REPLICATED: the client places its own camera under the
	# first and predicts its own player under the second.
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


func _bind_world_cvars(world: MmGame) -> void:
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


## What a session looks like: dot-platform's `player_for`, never the hub by a key made here (it
## keys by the scoped profile key only admission knows), or the stock person. Duck-typed.
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
