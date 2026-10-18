extends Node3D

const MmCatalogue := preload("mm_catalogue.gd")
const MmConfig := preload("mm_config.gd")
const MmMap := preload("mm_map.gd")
const MmMapDoc := preload("mm_map_doc.gd")
const MmPaths := preload("mm_paths.gd")
const MmPlayer := preload("mm_player.gd")
const MmProgress := preload("mm_progress.gd")
const MmProps := preload("mm_props.gd")
const MmRules := preload("mm_rules.gd")
const MmSpectate := preload("mm_spectate.gd")
const MmController := preload("mm_controller.gd")
const MmBots := preload("mm_bots.gd")
const MmWeapons := preload("mm_weapons.gd")

## The simulation. Headless, authoritative, and the only thing that decides anything.
##
## [b]A round is a grace and then the hunt.[/b] At the top of each round the server draws one or
## more murderers and hands one or more bystanders the gun; everybody else is unarmed. For
## [member MmConfig.grace_seconds] nobody can hurt anybody, and everybody scatters. Then the
## murderer may draw their weapon and stab whoever is in reach, and whoever holds the gun may
## shoot. A shot that misses drops the gun where the shooter stands, for another bystander to
## pick up. The murderers win when nobody else is left; everybody else wins when the murderers
## are dead or the clock runs out. Near the end the murderer starts to show blood.
##
## [b]Roles are secret.[/b] [member sides] holds the truth and lives on the server; dot-match
## sees everybody as one team on the wire, and a client is told only its own role. See
## docs/design.md "Roles are secret" and net/mm_net_bridge.gd.
##
## [b]What it owns and what it borrows.[/b] The round and the scoreboard are dot-match's
## (decided through [MmRules]); the draw is dot-team's [DotTeamRotation]; health is
## dot-combat's. The map, the weapons and the rules of this game are its own.
##
## [b]Every hit is measured by the server between bodies it simulates.[/b] A client cannot say
## "I stabbed them", only press the attack key; the server looks at where it has everybody on
## that tick (see [method _advance_weapons]).

const CHANNEL := "mm.game"

## Where this world publishes itself, so a module can find it. A registry name and not an
## autoload: a server and a client in one process are two of these.
const SERVICE := &"mm_game"

## Where a host that runs this game with no server (the client shell's Solo play) publishes
## the map packs it mounted for it. See [method solo_map_dirs].
const SOLO_SERVICE := &"dot_solo"

## Snapshots a second.
const NET_SNAPSHOT_RATE := 30

## How far a position may be from the origin, in metres, on the wire. Both ends read it here.
const NET_WORLD_EXTENT := 512.0

## The two sides, as dot-match keeps them on the server.
const BYSTANDERS := 1
const MURDERERS := 2

## The colours the round's end is announced in.
const TEAM_COLOURS: Array[Color] = [
	Color(0.3, 0.62, 1.0),
	Color(0.9, 0.12, 0.12),
]

const TEAM_NAMES: Array[String] = ["Bystanders", "Murderers"]

## The shirts, one drawn per player per round. Distinct enough to say "the one in green".
const SHIRTS: Array[Color] = [
	Color(0.85, 0.2, 0.2), Color(0.2, 0.45, 0.9), Color(0.2, 0.7, 0.3), Color(0.95, 0.8, 0.15),
	Color(0.6, 0.3, 0.8), Color(0.95, 0.5, 0.1), Color(0.1, 0.75, 0.75), Color(0.95, 0.45, 0.7),
	Color(0.45, 0.3, 0.15), Color(0.92, 0.92, 0.92), Color(0.2, 0.2, 0.22), Color(0.55, 0.75, 0.2),
]

## What the shirts are called, for a bot saying who it saw.
const SHIRT_NAMES: Array[String] = [
	"red", "blue", "green", "yellow", "purple", "orange", "teal", "pink", "brown", "white", "black", "lime",
]

## Which part of the round it is.
enum Phase {
	## Between rounds, or waiting for enough people.
	IDLE,
	## Everybody scatters; nobody can hurt anybody.
	GRACE,
	## The hunt.
	PLAY,
}

## Why somebody's health ran out.
const DIED_FELL := &"fell"
const DIED_SLAIN := &"slain"
const DIED_STABBED := &"stabbed"
const DIED_SHOT := &"shot"

## How high a standing body's capsule is hit by a shot, from the feet.
const HIT_HEIGHT := 1.85
const HIT_RADIUS := 0.4

signal player_added(player_id: StringName)
signal player_removed(player_id: StringName)
signal round_began(number: int, map_id: StringName)
signal world_clearing()
signal world_rebuilt()
signal round_over(number: int, winner: int, winner_name: String)
signal phase_changed(phase: int)
signal side_changed(player_id: StringName, side: int)
signal player_died(player_id: StringName, by: StringName, why: StringName)

## [param player_id]'s role was drawn: [param side], and whether they start with the gun.
## Server side; the bridge tells that one player alone.
signal role_drawn(player_id: StringName, side: int, gun: bool)

## A stab or a swing at the air by [param by]: drawn by everybody who can see them.
signal struck(by: StringName)

## A shot by [param by] from [param from] to [param to], hitting [param hit] (empty for none).
signal shot(by: StringName, from: Vector3, to: Vector3, hit: StringName)

## The gun was dropped at [param at] (drop [param drop_id]), or taken by [param by].
signal gun_dropped(drop_id: int, at: Vector3)
signal gun_taken(drop_id: int, by: StringName)

## [param player_id] holstered or drew their weapon. Server side.
signal weapon_changed(player_id: StringName, drawn: bool)

## Somebody used door [param index] on [param tick]: it is on its way to [param open].
signal door_used(index: int, open: bool, flip: bool, tick: int, by: StringName)

## Something a player asked for was refused, and why. Told to them alone.
signal refused(player_id: StringName, why: String)

## A stand-in said something in chat (mm_bot_chat.gd). The module sends it to every client; solo,
## the client prints it.
signal bot_said(player_id: StringName, text: String)

signal achievement_earned(player_id: StringName, title: String, points: int)

@export var config: MmConfig = null
@export var authoritative: bool = true
@export_range(1, 240, 1) var tick_rate: int = 64
@export var external_tick: bool = false
@export var register_service: bool = true

## Whether the map is drawn. A client sets it.
@export var draw_world: bool = false

var map: MmMap = null
var catalogue: MmCatalogue = null
var props_catalogue: MmProps = null
var combat: DotCombatManager = null
var match_node: DotMatch = null
var random: DotRandomManager = null
var physics: DotPhysicsLayout = null

## How a body falls when somebody dies: dot-player-char's rules, `mp_ragdoll*`.
var ragdoll_rules: DotPlayerRagdollRules = DotPlayerRagdollRules.new()

## The playground toys' rules, when a Playground map is played: dot-props'.
var toy_rules: DotPropToyRules = DotPropToyRules.new()

## A person's weight on a toy, in kilograms.
const PERSON_MASS := 70.0
var effects: DotFxManager = null
var spectate: MmSpectate = null
var progress: MmProgress = null

## Everybody in the world, by player id.
var players: Dictionary = {}

## dot-player-char's `mp_*` view and body rules.
var view_rules: DotPlayerViewRules = DotPlayerViewRules.new()
var body_rules: DotPlayerBodyRules = DotPlayerBodyRules.new()

## Each player's role, by id: the truth, on the server. On a client, the local player's alone.
var sides: Dictionary = {}

var next_map_id: StringName = &""

var round_number: int = 0

## Seconds into this phase, and into the hunt.
var phase_elapsed: float = 0.0
var play_elapsed: float = 0.0

var phase: int = Phase.IDLE

var map_doc: Dictionary = {}

var entities := DotEntityTable.new()

## What a client is told of the round: how many are alive, and how many murderers.
var remote_alive: int = -1
var remote_murderers: int = -1
var remote_playable: bool = false

## Who has been the murderer, for the draw's history.
var murderer_history: Dictionary = {}

## The guns on the floor: drop id to `{at: Vector3}`. Usually none or one.
var gun_drops: Dictionary = {}
var _next_drop_id: int = 1

## Who the murderers were, by display name, once the round is decided. Empty while it runs.
var revealed: PackedStringArray = PackedStringArray()

var _tick: int = 0
var _round_seed: int = 0
var _rounds_on_map: int = 0
var _map_unplayed: bool = false
var _decided: bool = false
var _winner: int = 0
var _winner_name: String = ""

## Players whose health ran out to a fall, put back on their feet at the top of the next tick.
var _to_respawn: Array[StringName] = []

## The stand-ins, by role ([code]mm_bots.gd[/code], on dot-bot).
var bots: MmBots = MmBots.new(self)

## What the stand-ins are called, solo and on a server alike; past the end dot-bot numbers them.
const BOT_NAMES := ["Pip", "Moss", "Juniper", "Quill", "Basil", "Wren", "Clover", "Sorrel", "Fern", "Rowan", "Hazel", "Linden"]


func _init() -> void:
	# People pass through people (see `_build_physics`): a doorway nobody can be pinned in.
	# An owner who wants bodies sets `mp_solidplayers 1`.
	body_rules.solid = false


func _ready() -> void:
	if config == null:
		config = MmConfig.new()

	var valid := config.validate()

	if not valid.ok:
		DotLog.error(CHANNEL, "the configuration is not usable", {"why": valid.error.message})
		return

	_round_seed = config.seed_value

	_build_physics()
	if not body_rules.changed.is_connected(_on_body_rules_changed):
		body_rules.changed.connect(_on_body_rules_changed)
	_apply_gravity()
	_build_random()
	_build_props()
	_build_map()
	_build_combat()
	_build_effects()
	_build_match()
	_build_spectate()
	_build_progress()

	if authoritative:
		catalogue = MmCatalogue.new()
		var _loaded := catalogue.load_from(config.map_directory)
		# The other games' packs, mounted beside this one's (see .gitignore's bootstrap links
		# and MmCatalogue.add_extra_directories).
		var _extra := catalogue.add_extra_directories(config.extra_map_directory)
		# Solo in the client shell: the map packs it mounted for this game.
		for root in solo_map_dirs("maps"):
			var _added := catalogue.add_directory(root)
		# Laid out now, not on the first round: a warmup on an empty world is
		# indistinguishable from a map that failed to load.
		_lay_out_map()

	if register_service:
		DotRegistry.register(SERVICE, self)

	DotLog.info(CHANNEL, "world ready", config.describe())


## The `<pack>/<subdir>` directories of the map packs a host running this game with no server
## has mounted for it: the client shell's Solo play, which fetches the packs a server owner
## would name (dot-server-deploy's `client/solo.json`) because a tab has no server to name
## them. Read the way the module reads its server's ([DotGameContent]). Empty everywhere else:
## a server, a suite, a run from the repository. Looked up by name and duck-typed, because a
## delivered game may not name a host's class.
static func solo_map_dirs(subdir: String) -> PackedStringArray:
	var host: Object = DotRegistry.get_service(SOLO_SERVICE)
	if host == null or not host.has_method(&"map_dirs"):
		return PackedStringArray()
	return host.call(&"map_dirs", subdir)


func _exit_tree() -> void:
	if register_service:
		DotRegistry.unregister_instance(SERVICE, self)


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


## Three layers: the building, the people, and the furniture.
##
## [b]People do not collide with people in the layout.[/b] Two players shoving is a race
## decided by who walked into whom, drawn in the past on every client; somebody who could be
## pinned in a corner by a murderer's body, or block a doorway with their own, would be
## playing a different game. So `mp_solidplayers` is 0 here by default (`_init`); the first
## play test's stand-in walking into the camera is handled by the camera fade, which hides a
## body at the lens. An owner who sets 1 gets each player's motor mask and hull; a touch is a
## distance the server measures (`tag_range` 1.2 m, past the 0.7 m two bodies keep), so
## tagging works either way.
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


func _build_match() -> void:
	match_node = DotMatch.new()
	match_node.name = "Match"
	match_node.register_service = false

	var match_config := DotMatchConfig.new()
	match_config.tick_rate = tick_rate
	match_config.auto_start = false
	match_config.log_transitions = false
	# Off: the roles are this game's to draw (see [method _draw_roles]).
	match_config.balance_between_rounds = false
	match_node.config = match_config

	var match_rules: DotMatchRules = MmRules.make()
	match_rules.intermission_sec = config.intermission_seconds
	match_rules.warmup_sec = config.warmup_seconds
	match_rules.countdown_sec = 0.0
	match_rules.team_based = true
	match_rules.min_players = 2
	match_rules.set(&"decision_fn", _decision)
	match_rules.time_limit_sec = config.grace_seconds + config.round_seconds + 60.0
	match_node.rules = match_rules

	# Scoped to the match node, which finds nothing: this game places its own players.
	match_node.spawns_ref = DotNodeRef.of_path(^".")
	add_child(match_node)

	match_node.round_started.connect(_on_round_started)
	match_node.round_ended.connect(_on_round_ended)

	var teams: Array[DotTeam] = [
		DotTeam.make(BYSTANDERS, TEAM_NAMES[0], TEAM_COLOURS[0]),
		DotTeam.make(MURDERERS, TEAM_NAMES[1], TEAM_COLOURS[1]),
	]
	match_node.teams.teams = teams
	match_node.teams.force_balance = false
	match_node.teams.allow_choice = false
	match_node.teams.max_difference = 0
	match_node.teams.reindex()


func _decision() -> Dictionary:
	return {"decided": _decided, "winner": _winner}


func _build_spectate() -> void:
	spectate = MmSpectate.new()
	spectate.name = "Spectate"
	spectate.players = players
	spectate.sides = sides
	spectate.phase_fn = func() -> int: return phase
	add_child(spectate)

	var ready_now := spectate.setup(authoritative, tick_rate, config.spectate_camera)

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


## Puts somebody in the world. [param wanted_side] is ignored but for a suite's 
## [constant MURDERERS], which makes them a murderer straight away.
##
## [b]Somebody who joins during the hunt watches until the next round.[/b] A newcomer with no
## role would be a free body for the murderer, and one handed a role would change a round that
## is half over. During the grace they are a bystander.
func add_player(
	player_id: StringName,
	display_name: String,
	wanted_side: int = 0,
	samples_input: bool = false
) -> MmPlayer:
	if players.has(player_id):
		return players[player_id]

	var side := MURDERERS if wanted_side == MURDERERS else BYSTANDERS

	var player := MmPlayer.new()
	player.name = "Player_%s" % String(player_id)
	player.player_id = player_id
	player.display_name = display_name
	player.samples_input = samples_input
	player.tick_rate = tick_rate
	player.config = config
	player.team = side
	player.weapon_id = weapon_id()
	player.shirt = (players.size() * 5 + 3) % SHIRTS.size()
	add_child(player)

	if physics != null:
		var applied := physics.apply_to(player, &"player")

		if not applied.ok:
			DotLog.warn(CHANNEL, "a player could not be put on its collision layer", {"why": applied.error.message})

		_apply_body_mask(player)

	var opened := entities.open(
		DotEntity.KIND_PLAYER, player, &"", player_id, float(_tick) / float(maxi(tick_rate, 1))
	)
	player.entity_id = (opened.value as DotEntityHandle).id if opened.ok else 0

	var health := DotHealth.new()
	health.name = "Health"
	health.max_health = config.player_health
	health.health = health.max_health
	player.add_child(health)
	player.health = health

	if combat != null:
		combat.register_health(player.entity_id, health)

	health.died.connect(func(damage: DotDamage) -> void: _on_player_died(player, damage))

	players[player_id] = player
	sides[player_id] = side

	player.controller.launcher = _launch
	var _b := player.controller.bounced.connect(_on_bounced)
	player.controller.carrier = _carry

	if match_node != null:
		var seated := match_node.add_player(String(player_id), display_name, _tick, side)

		if not seated.ok:
			DotLog.error(CHANNEL, "dot-match refused a player", {"id": String(player_id), "why": seated.error.message})

	place_one(player)

	if authoritative and phase == Phase.PLAY and wanted_side == 0:
		_bench(player)

	player.retune()
	DotLog.debug(CHANNEL, "player joined", {"id": String(player_id)})
	player_added.emit(player_id)
	return player


## Puts one player at a spawn point. Every map's points are one group here (see mm_map_doc.gd).
func place_one(player: MmPlayer) -> void:
	if map == null or map.doc.is_empty():
		return

	var spot := map.spawn(SPAWN_GROUP, players.size() - 1)
	player.place_at(spot[0], spot[1])

	if spectate != null:
		spectate.on_spawned(player.player_id)


## The spawn group every map is read into.
const SPAWN_GROUP := "players"


func _bench(player: MmPlayer) -> void:
	player.watching = true

	if player.health != null:
		player.health.invulnerable = true

	if spectate != null:
		spectate.on_died(player.player_id, &"", false, player.controller.state.position,
			map.kill_height() + 8.0, _tick)


func remove_player(player_id: StringName) -> void:
	if not players.has(player_id):
		return

	var player: MmPlayer = players[player_id]

	if authoritative and player.has_gun and player.is_alive():
		_drop_gun(player, player.controller.state.position)

	if combat != null and is_instance_valid(combat) and player.entity_id != 0:
		combat.forget(player.entity_id)
		var _closed := entities.close(player.entity_id, DotEntityTable.REASON_OWNER_LEFT)

	if match_node != null:
		match_node.remove_player(String(player_id))

	players.erase(player_id)
	sides.erase(player_id)
	bots.forget(player_id)
	_to_respawn.erase(player_id)

	player.queue_free()

	if spectate != null:
		spectate.on_left(player_id)

	if progress != null:
		progress.leave(player_id)

	player_removed.emit(player_id)

	if authoritative and phase != Phase.IDLE:
		_check_round()


func team_of(player_id: StringName) -> int:
	return int(sides.get(player_id, 0))


func side_name(side: int) -> String:
	if side == BYSTANDERS or side == MURDERERS:
		return TEAM_NAMES[side - 1]

	return "nobody"


func side_colour(side: int) -> Color:
	if side == BYSTANDERS or side == MURDERERS:
		return TEAM_COLOURS[side - 1]

	return Color(0.7, 0.7, 0.7)


## The shirt [param player] wears this round.
func shirt_colour(player: MmPlayer) -> Color:
	return SHIRTS[posmod(player.shirt, SHIRTS.size())]


func shirt_name(player: MmPlayer) -> String:
	return SHIRT_NAMES[posmod(player.shirt, SHIRT_NAMES.size())]


func players_on(side: int) -> Array[MmPlayer]:
	var out: Array[MmPlayer] = []

	for id: StringName in players:
		if int(sides.get(id, 0)) == side:
			out.append(players[id])

	return out


## How many of a side are up and in the round. On a client only the totals it was told:
## everybody alive (any side), and murderers alive.
func alive_on(side: int) -> int:
	if not authoritative:
		if side == MURDERERS and remote_murderers >= 0:
			return remote_murderers
		if side == BYSTANDERS and remote_alive >= 0:
			return maxi(remote_alive - maxi(remote_murderers, 0), 0)

	var total := 0

	for player in players_on(side):
		if player.is_alive() and not player.watching:
			total += 1

	return total


## Everybody still in the round, whatever their role.
func alive_total() -> int:
	return alive_on(BYSTANDERS) + alive_on(MURDERERS)


func sides_are_playable() -> bool:
	if not authoritative:
		return remote_playable

	return players.size() >= 2


func start() -> void:
	if not authoritative:
		return

	# Built again here: on a server nothing was listening when the world opened (the module
	# builds the bridge after), and a map built before it is a map no client is ever sent.
	var id := StringName(str(map_doc.get("id", "")))

	if not map_doc.is_empty() and catalogue != null and catalogue.playable(config.map_ids).has(id):
		var _rebuilt := build_map(map_doc)
		_place_everybody()
	else:
		_lay_out_map()

	match_node.start(_tick)


func _on_round_started(number: int) -> void:
	round_number = number
	_round_seed = config.seed_value + number * 7919
	random.reseed(_round_seed)

	# A new map once this one has had its rounds, or as soon as the players voted for one.
	if next_map_id != &"" or (_rounds_on_map >= config.rounds_per_map and not _map_unplayed):
		_lay_out_map()

	_map_unplayed = false
	_decided = false
	_winner = 0
	_winner_name = ""
	revealed = PackedStringArray()
	play_elapsed = 0.0
	bots.reset()
	_to_respawn.clear()
	_clear_drops()

	if map.doors != null:
		map.doors.reset()

	if map.toys != null:
		map.toys.reset()

	_place_everybody()
	_draw_roles()

	if progress != null:
		progress.on_round_began()

	_set_phase(Phase.GRACE)
	round_began.emit(number, map.id())

	DotLog.info(CHANNEL, "round began", {
		"number": number, "map": String(map.id()), "seed": _round_seed,
		"players": players.size(), "murderers": ", ".join(_names(players_on(MURDERERS))),
	})


func _on_round_ended(number: int, winner: int, _outcome: int) -> void:
	_set_phase(Phase.IDLE)
	_rounds_on_map += 1

	if not _decided:
		_winner_name = "the round ran out"
		revealed = _names(players_on(MURDERERS))

	if progress != null:
		progress.on_round_over(winner)

	round_over.emit(number, winner, _winner_name)
	DotLog.info(CHANNEL, "round over", {"number": number, "winner": _winner_name})


## player id -> &"murderer", &"gunner" or &"bystander": roles the next draws hand out instead
## of drawing them. Empty in play. With any entry, gunners are only the ones named.
var forced_roles: Dictionary = {}


## Who is the murderer and who has the gun this round, and everybody's shirt.
##
## The murderers by [DotTeamRotation] over a history, so the same person is not drawn three
## rounds running; the gunners at random from the rest. [member forced_roles] overrides the
## draw for the people it names (a suite, an operator's test), and the rest are drawn round it.
func _draw_roles() -> void:
	var keys: Array[StringName] = []

	for id: StringName in players:
		keys.append(id)

	keys.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))

	var want := config.murderers_for(keys.size())
	var picked: Dictionary = DotTeamRotation.pick(
		keys, want, DotTeamRotation.Mode.RANDOM, murderer_history, _round_seed, {}
	)
	var murderers: Array[StringName] = []

	for id: StringName in picked["picked"]:
		murderers.append(id)

	if not forced_roles.is_empty():
		murderers.clear()
		for id: StringName in keys:
			if forced_roles.get(id, &"") == &"murderer":
				murderers.append(id)
		# Nobody forced to be one: the draw's, less anybody forced to be something else.
		if murderers.is_empty():
			for id: StringName in picked["picked"]:
				if not forced_roles.has(id):
					murderers.append(id)

	DotTeamRotation.note(murderer_history, keys, murderers, round_number)

	var rest: Array[StringName] = []

	for id in keys:
		if not murderers.has(id):
			rest.append(id)

	var stream := random.stream(&"roles")
	var gunners: Array[StringName] = []
	var pool := rest.duplicate()

	if not forced_roles.is_empty():
		for id in rest:
			if forced_roles.get(id, &"") == &"gunner":
				gunners.append(id)
				pool.erase(id)
			elif forced_roles.has(id):
				pool.erase(id)

	for _i in range(maxi(config.gunners_for(keys.size(), rest.size()) - gunners.size(), 0)):
		if pool.is_empty() or not forced_roles.is_empty():
			break
		gunners.append(pool.pop_at(stream.next_range_i(0, pool.size() - 1)))

	# The shirts: a shuffled palette, so no two share one until there are more people than
	# colours.
	var palette: Array[int] = []

	for i in range(SHIRTS.size()):
		palette.append(i)

	for i in range(palette.size() - 1, 0, -1):
		var j := stream.next_range_i(0, i)
		var swap := palette[i]
		palette[i] = palette[j]
		palette[j] = swap

	var weapon := weapon_id()

	for index in range(keys.size()):
		var id := keys[index]
		var player: MmPlayer = players[id]
		player.shirt = palette[index % palette.size()]
		player.weapon_id = weapon
		_set_side(id, MURDERERS if murderers.has(id) else BYSTANDERS)
		player.has_gun = gunners.has(id)
		player.retune()
		role_drawn.emit(id, team_of(id), player.has_gun)


func _set_side(id: StringName, side: int) -> void:
	var player: MmPlayer = players.get(id)

	if player == null:
		return

	var was := int(sides.get(id, 0))
	sides[id] = side
	player.team = side

	if match_node != null and was != side:
		var _moved := match_node.switch_team(String(id), side, _tick)

	if was != side:
		side_changed.emit(id, side)


## The murderer's weapon this server carries: the configured id, or the knife.
func weapon_id() -> StringName:
	var id := StringName(config.murderer_weapon) if config != null else MmWeapons.DEFAULT
	return id if MmWeapons.known(id) else MmWeapons.DEFAULT


func melee_reach() -> float:
	return config.melee_range if config.melee_range > 0.0 else float(MmWeapons.entry(weapon_id())["reach"])


func melee_cooldown() -> float:
	return config.melee_cooldown if config.melee_cooldown > 0.0 else float(MmWeapons.entry(weapon_id())["cooldown"])


static func _names(of: Array[MmPlayer]) -> PackedStringArray:
	var out := PackedStringArray()
	for player in of:
		out.append(player.display_name)
	return out


## The next map, built.
## Every map this server plays, as the map menu (M) lists them: `{id, name, detail, current}`,
## the blurb under the name. Solo the client's list, online the server's (the module hands it
## to dot-vote's map menu), so both say the same.
func map_rows() -> Array:
	var out: Array = []
	if catalogue == null:
		return out
	var now := StringName(str(map_doc.get("id", "")))
	for id in catalogue.playable(config.map_ids):
		var doc: Dictionary = catalogue.maps.get(id, {})
		var row := {"id": String(id), "name": str(doc.get("name", id)), "current": id == now,
			"detail": str(doc.get("blurb", ""))}
		if doc.has("thumbnail"):
			row["thumbnail"] = str(doc["thumbnail"])
		out.append(row)
	return out


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
		doc = catalogue.next_map(
			config.map_ids, config.shuffle_maps, random.stream(&"map"),
			StringName(str(map_doc.get("id", "")))
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
		spectate.set_overviews(map.overview(), map.overview())

	world_rebuilt.emit()
	return built


## Everybody to a spawn point, at full health, empty handed.
func _place_everybody() -> void:
	var ids := players.keys()
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))

	# Shuffled with the round, so the murderer is not always the one by the stairs.
	var stream := random.stream(&"spawns")
	var offset := stream.next_range_i(0, 63)

	for index in range(ids.size()):
		var id: StringName = ids[index]
		var player: MmPlayer = players[id]
		player.reset_round()
		_heal(player)

		var spot := map.spawn(SPAWN_GROUP, index + offset)
		player.place_at(spot[0], spot[1])

		if spectate != null:
			spectate.on_spawned(player.player_id)


func _heal(player: MmPlayer) -> void:
	if player.health != null:
		player.health.max_health = config.player_health
		player.health.health = player.health.max_health
		player.health.alive = true
		player.health.invulnerable = false


func _set_phase(to: int) -> void:
	if phase == to:
		return

	phase = to
	phase_elapsed = 0.0

	phase_changed.emit(to)
	DotLog.debug(CHANNEL, "the round changed phase", {"phase": Phase.keys()[to]})


func _advance_phase(delta: float) -> void:
	if phase == Phase.IDLE:
		return

	phase_elapsed += delta

	match phase:
		Phase.GRACE:
			if phase_elapsed >= grace_limit():
				play_elapsed = 0.0
				_set_phase(Phase.PLAY)
			else:
				_check_round()
		Phase.PLAY:
			play_elapsed += delta
			_advance_blood()
			_check_round()


## Rounds still to play on this map, this one included. 1 is the last.
func rounds_left_on_map() -> int:
	return maxi(config.rounds_per_map - _rounds_on_map, 1)


## How long the grace lasts: the map's, under the server's.
func grace_limit() -> float:
	var asked := float(map_doc.get("grace_seconds", 0.0))
	return minf(asked, config.grace_seconds) if asked > 0.0 else config.grace_seconds


## How long the hunt lasts: the map's, under the server's ceiling.
func round_limit() -> float:
	var asked := float(map_doc.get("round_seconds", 0.0))
	return minf(asked, config.round_seconds) if asked > 0.0 else config.round_seconds


## The murderers gone, everybody else gone, or the clock.
func _check_round() -> void:
	if not authoritative or _decided or phase == Phase.IDLE:
		return

	var murderers_left := alive_on(MURDERERS)
	var others_left := alive_on(BYSTANDERS)

	if murderers_left == 0 and others_left == 0:
		_decide(0, "nobody is left")
	elif murderers_left == 0:
		var why := "nobody was the murderer"
		if not players_on(MURDERERS).is_empty():
			why = "the murderer is dead" if players_on(MURDERERS).size() == 1 else "the murderers are dead"
		_decide(BYSTANDERS, why)
	elif others_left == 0:
		_decide(MURDERERS, "nobody is left alive")
	elif phase == Phase.PLAY and play_elapsed >= round_limit():
		_decide(BYSTANDERS, "time: %d survived" % others_left)


func _decide(winner: int, why: String) -> void:
	if _decided:
		return

	_decided = true
	_winner = winner
	revealed = _names(players_on(MURDERERS))
	var told := why

	if not revealed.is_empty():
		told += "; %s %s the murderer%s" % [
			", ".join(revealed), "was" if revealed.size() == 1 else "were", "" if revealed.size() == 1 else "s"]

	_winner_name = told

	for id: StringName in players:
		var player: MmPlayer = players[id]

		if winner != 0 and team_of(id) == winner:
			player.points += config.winner_points

		if team_of(id) == BYSTANDERS and player.is_alive() and not player.watching:
			player.points += config.survive_points

			if progress != null:
				progress.on_survived(id)

	if progress != null:
		progress.on_decided(winner)

	DotLog.info(CHANNEL, "the round is decided", {"winner": winner, "why": told})


## The blood on the murderers: none until [member MmConfig.blood_seconds] before the end, then
## rising in [member MmConfig.blood_stages] steps to the whole of it at the buzzer, with a step
## more for each kill when [member MmConfig.blood_per_kill].
func _advance_blood() -> void:
	var stages := config.blood_stages
	var timed := 0

	if config.blood_seconds > 0.0:
		var into := config.blood_seconds - (round_limit() - play_elapsed)
		if into > 0.0:
			timed = clampi(int(ceil(into / config.blood_seconds * float(stages))), 1, stages)

	for player in players_on(MURDERERS):
		var from_kills := player.kills if config.blood_per_kill and config.blood_seconds > 0.0 else 0
		player.blood = mini(timed + from_kills, stages)


## Everybody's hands, this tick: the holster key, the attack key, and the guns on the floor.
##
## [b]Edges, made here from the held state[/b], as the use key's are: the keys ride in every
## input packet, so a stab is never a round trip behind the key that made it.
func _advance_weapons() -> void:
	if not authoritative:
		return

	var now := _now()

	for id: StringName in players:
		var player: MmPlayer = players[id]
		var holster := player.wants_holster and not player.holster_was_held
		var attack := player.wants_attack and not player.attack_was_held
		player.holster_was_held = player.wants_holster
		player.attack_was_held = player.wants_attack
		player.ready_in = maxf(player.ready_at - now, 0.0)

		if not player.is_alive() or player.watching or phase == Phase.IDLE:
			continue

		if holster and team_of(id) == MURDERERS:
			set_weapon_drawn(id, not player.weapon_drawn)

		if attack:
			var _did := attack_now(id)

	_advance_pickups()


## Draws or holsters [param id]'s weapon. Refused in the grace, and for anybody but a murderer.
func set_weapon_drawn(id: StringName, drawn: bool) -> bool:
	var player: MmPlayer = players.get(id)

	if player == null or team_of(id) != MURDERERS or not player.is_alive() or player.watching:
		return false

	if drawn and phase != Phase.PLAY:
		refused.emit(id, "You cannot draw your %s yet." % weapon_name().to_lower())
		return false

	if player.weapon_drawn == drawn:
		return true

	player.weapon_drawn = drawn
	player.drawn_at = _now() if drawn else -1.0
	weapon_changed.emit(id, drawn)
	return true


func weapon_name() -> String:
	return str(MmWeapons.entry(weapon_id())["name"])


## The attack key for [param id]: a stab for a murderer with the weapon out, a shot for whoever
## holds the gun. Server side; what a suite and a bot call directly too.
func attack_now(id: StringName) -> bool:
	var player: MmPlayer = players.get(id)

	if player == null or not player.is_alive() or player.watching or phase != Phase.PLAY:
		return false

	var now := _now()

	if now < player.ready_at:
		return false

	if player.has_gun:
		_shoot(player)
		return true

	if team_of(id) == MURDERERS and player.weapon_drawn and now - player.drawn_at >= config.draw_seconds:
		_stab(player)
		return true

	return false


## A stab: the nearest living somebody within reach of the murderer's eye, inside the cone,
## with nothing solid between. A swing at nobody still costs the cooldown and is still seen.
func _stab(murderer: MmPlayer) -> void:
	murderer.ready_at = _now() + melee_cooldown()
	murderer.attacked_at = _now()
	murderer.attacks += 1
	var victim := stab_target(murderer)
	struck.emit(murderer.player_id)

	if victim != null:
		_kill(victim, murderer, DIED_STABBED)


## Who a stab from [param murderer] would land on now, or null.
func stab_target(murderer: MmPlayer) -> MmPlayer:
	var eye := murderer.eye_position()
	var aim := murderer.aim_direction()
	var flat := Vector3(aim.x, 0.0, aim.z).normalized()
	var reach := melee_reach()
	var cone := cos(deg_to_rad(config.melee_cone))
	var best: MmPlayer = null
	var best_distance := INF

	for id: StringName in players:
		var other: MmPlayer = players[id]

		if other == murderer or not other.is_alive() or other.watching or team_of(id) == MURDERERS:
			continue

		var chest := other.controller.state.position + Vector3(0.0, 1.1, 0.0)
		var offset := chest - eye
		var distance := Vector2(offset.x, offset.z).length()

		if distance > reach or absf(offset.y) > 1.4:
			continue

		var toward := Vector3(offset.x, 0.0, offset.z).normalized()

		if distance > 0.45 and flat.dot(toward) < cone:
			continue

		if distance < best_distance and _clear_between(eye, chest):
			best = other
			best_distance = distance

	return best


## A shot, from the gunner's eye along their aim: the first body it passes through before a
## wall or a piece of furniture. A miss drops the gun; so does an innocent, by default.
func _shoot(gunner: MmPlayer) -> void:
	gunner.ready_at = _now() + config.gun_cooldown
	gunner.attacked_at = _now()
	gunner.attacks += 1
	var from := gunner.eye_position()
	var aim := gunner.aim_direction()
	var wall := _wall_along(from, aim, config.gun_range)
	var hit := shot_target(gunner, from, aim, wall)
	var to := from + aim * wall

	if hit != null:
		to = hit.controller.state.position + Vector3(0.0, 1.2, 0.0)

	shot.emit(gunner.player_id, from, to, hit.player_id if hit != null else &"")

	if hit == null:
		if progress != null:
			progress.on_missed(gunner.player_id)
		if config.drop_on_miss:
			_drop_gun(gunner, gunner.controller.state.position)
			gunner.gun_banned = true
		return

	var innocent := team_of(hit.player_id) != MURDERERS
	_kill(hit, gunner, DIED_SHOT)

	if not innocent:
		gunner.points += config.hero_points
		if progress != null:
			progress.on_hero(gunner.player_id)
		return

	if progress != null:
		progress.on_innocent(gunner.player_id)

	if config.drop_on_innocent and gunner.has_gun:
		_drop_gun(gunner, gunner.controller.state.position)
		gunner.gun_banned = true

	if config.innocent_kills_shooter and gunner.is_alive():
		_kill(gunner, null, DIED_SLAIN)


## The first living body the ray from [param from] along [param aim] passes within
## [constant HIT_RADIUS] of, before [param limit] metres. Standing capsules, measured here.
func shot_target(gunner: MmPlayer, from: Vector3, aim: Vector3, limit: float) -> MmPlayer:
	var best: MmPlayer = null
	var best_along := limit

	for id: StringName in players:
		var other: MmPlayer = players[id]

		if other == gunner or not other.is_alive() or other.watching:
			continue

		var feet := other.controller.state.position
		var height := lerpf(HIT_HEIGHT, MmPlayer.BODY_CROUCH, other.controller.state.crouch_fraction)
		var along := _ray_capsule(from, aim, feet, height, HIT_RADIUS)

		if along >= 0.0 and along < best_along:
			best = other
			best_along = along

	return best


## How far along the ray a vertical capsule from [param feet] up [param height] is first within
## [param radius], or -1. Sampled along the closest approach of the ray to the axis.
static func _ray_capsule(from: Vector3, dir: Vector3, feet: Vector3, height: float, radius: float) -> float:
	var top := feet + Vector3(0.0, height, 0.0)
	var closest := Geometry3D.get_closest_points_between_segments(from, from + dir * 1000.0, feet, top)
	var on_ray: Vector3 = closest[0]
	var on_axis: Vector3 = closest[1]

	if on_ray.distance_to(on_axis) > radius:
		return -1.0

	return maxf((on_ray - from).dot(dir) - radius * 0.5, 0.0)


## How far a shot goes before something solid: the walls and the furniture.
func _wall_along(from: Vector3, aim: Vector3, limit: float) -> float:
	var world := get_world_3d()

	if world == null:
		return limit

	var query := PhysicsRayQueryParameters3D.create(from, from + aim * limit)
	query.collision_mask = physics.layer_mask(&"world") | physics.layer_mask(&"prop") | physics.layer_mask(&"toy") \
		if physics != null else 1
	var hit := world.direct_space_state.intersect_ray(query)
	return from.distance_to(hit["position"]) if not hit.is_empty() else limit


## [param victim] killed by [param by] (null for nobody), as damage through dot-combat.
func _kill(victim: MmPlayer, by: MmPlayer, how: StringName) -> void:
	if combat == null or not victim.is_alive():
		return

	var hit := DotDamage.make(by.entity_id if by != null else 0, victim.entity_id, victim.health.max_health * 10.0, null)
	hit.tick = _tick
	hit.context = {"why": how}

	if by != null:
		hit.direction = (victim.controller.state.position - by.controller.state.position).normalized()

	var _applied := combat.apply_damage(hit)


## The gun out of [param holder]'s hands and onto the floor at [param at].
func _drop_gun(holder: MmPlayer, at: Vector3) -> void:
	if not holder.has_gun:
		return

	holder.has_gun = false

	# Below the map, it goes to a spawn point instead: a gun nobody can reach is a round with
	# no gun.
	if map != null and at.y < map.kill_height() + 1.0:
		at = map.spawn(SPAWN_GROUP, _next_drop_id)[0]

	var drop_id := _next_drop_id
	_next_drop_id += 1
	gun_drops[drop_id] = {"at": at + Vector3(0.0, 0.05, 0.0), "dropped_by": holder.player_id, "since": _now()}
	gun_dropped.emit(drop_id, gun_drops[drop_id]["at"])
	DotLog.debug(CHANNEL, "the gun was dropped", {"by": String(holder.player_id), "at": str(at.snapped(Vector3.ONE * 0.1))})


## A gun on the floor goes to the first living bystander who walks onto it and may hold one: not
## a murderer, not one who dropped a gun this round, not one who already has one.
func _advance_pickups() -> void:
	if gun_drops.is_empty():
		return

	for drop_id: int in gun_drops.keys():
		var at: Vector3 = gun_drops[drop_id]["at"]

		for id: StringName in players:
			var player: MmPlayer = players[id]

			if not may_pick_up(player):
				continue

			var feet := player.controller.state.position
			if Vector2(feet.x - at.x, feet.z - at.z).length() > config.pickup_range or absf(feet.y - at.y) > 1.2:
				continue

			gun_drops.erase(drop_id)
			player.has_gun = true
			player.ready_at = maxf(player.ready_at, _now() + 0.5)
			gun_taken.emit(drop_id, id)

			if progress != null:
				progress.on_picked_up(id)

			break


func may_pick_up(player: MmPlayer) -> bool:
	return player != null and player.is_alive() and not player.watching and not player.has_gun \
		and not player.gun_banned and team_of(player.player_id) != MURDERERS


func _clear_drops() -> void:
	for drop_id: int in gun_drops.keys():
		gun_taken.emit(drop_id, &"")
	gun_drops.clear()


## Lets go of anybody whose hold has run out.
func _advance_holds() -> void:
	var now := _now()

	for id: StringName in players:
		var player: MmPlayer = players[id]

		if player.held_until >= 0.0 and now >= player.held_until:
			player.held_until = -1.0
			var _let_go := player.controller.remove_modifier(MmController.HOLD)


## Everybody's hand on the doors: a use is the use key going down in front of one, and then
## every door is posed for this tick, before anybody moves against it.
##
## [b]An edge, made here from the held state,[/b] as mg-deathrun makes its button presses: the
## key rides in every input packet, so a use is never a round trip behind the key that made it.
func _advance_doors() -> void:
	if map == null or map.doors == null or map.doors.count() == 0:
		return

	map.doors.pose_at(_tick)


## The use key going down, for everybody: on a toy looked at (a ray, so only the one in the
## middle of the view), else on the nearest door in reach.
func _advance_use() -> void:
	for id: StringName in players:
		var player: MmPlayer = players[id]
		var pressed := player.wants_use and not player.use_was_held
		player.use_was_held = player.wants_use

		if not pressed or not player.is_alive() or player.watching or map == null:
			continue

		# Held is held: somebody an admin froze does not open the door they are facing.
		if player.controller.has_modifier(MmController.HOLD):
			continue

		var toy := toy_aimed(player)

		if toy >= 0:
			var _played := use_toy(toy, id)
			continue

		if map.doors == null or map.doors.count() == 0:
			continue

		var index := map.doors.door_for(player.eye_position(), player.aim_direction())

		if index >= 0:
			var _used := use_door(index, id)


## Opens or shuts door [param index] for [param by], now, if it can be. What the use key does,
## and what a suite and a bot do directly.
func use_door(index: int, by: StringName) -> bool:
	if map == null or map.doors == null or index < 0 or index >= map.doors.count():
		return false

	if not config.doors_enabled:
		return false

	if map.doors.moving(index, _tick):
		return false

	# Nobody anywhere the panel will pass through: see MmDoors. Opening, it goes away from
	# whoever opened it.
	var from := map.doors.fraction(index, _tick)
	var to := 0.0 if map.doors.is_open(index) else 1.0
	var user := (players[by] as MmPlayer).eye_position() if players.has(by) else Vector3.INF
	var flip := map.doors.is_flipped(index)

	if to > 0.5 and user != Vector3.INF:
		flip = map.doors.flips_for(index, user)

	for id: StringName in players:
		var player: MmPlayer = players[id]

		if not player.is_alive() or player.watching:
			continue

		if map.doors.sweeps(index, player.controller.state.position, MmPlayer.BODY_RADIUS,
				player.hull_height(), from, to, 1 if flip else 0):
			if players.has(by) and not (players[by] as MmPlayer).is_bot:
				refused.emit(by, "Somebody is in the way of the %s." % map.doors.name_of(index))
			return false

	var open := to > 0.5
	map.doors.apply(index, open, flip, _tick)
	door_used.emit(index, open, flip, _tick, by)

	if progress != null and players.has(by):
		progress.on_door(by)

	DotLog.debug(CHANNEL, "a door was used", {
		"door": map.doors.name_of(index), "open": open, "by": String(by), "tick": _tick,
	})
	return true


## The toy [param player] is looking at within reach, or -1. Both ends: the client asks it
## for the use prompt.
func toy_aimed(player: MmPlayer) -> int:
	if map == null or map.toys == null or player == null:
		return -1
	return map.toys.aimed(player.eye_position(), player.aim_direction(), TOY_REACH)


## How far the use key reaches a toy: a ball at your feet, a switch at arm's length.
const TOY_REACH := 2.3


## Toy [param index] used by [param by]: a kick, a push, a switch, a honk. Server side.
func use_toy(index: int, by: StringName) -> bool:
	var player: MmPlayer = players.get(by)
	if map == null or map.toys == null or player == null:
		return false
	return map.toys.use(index, player.eye_position(), player.aim_direction())


## Everybody against the toys this tick, after they moved: a walk into a ball pushes it, weight
## on a see-saw tips it, and then the box's own tick (the awake cap, the lost sent home). A
## person is not a rigid body, so this is how one touches a toy at all. Server side.
func _advance_toys(delta: float) -> void:
	if map == null or map.toys == null or not authoritative:
		return

	for id: StringName in players:
		var player: MmPlayer = players[id]

		if not player.is_alive() or player.watching:
			continue

		var state := player.controller.state
		var _pushed := map.toys.push_from(state.position, state.velocity, MmPlayer.BODY_RADIUS, player.hull_height())

		if state.mode == DotFpsState.Mode.GROUND:
			var _bore := map.toys.stand_on(state.position, PERSON_MASS)

	map.toys.advance(delta)


## The trampolines and bounce pads, for every player's movement on both ends
## ([member MmController.launcher]): `{velocity, index}` or empty.
func _launch(feet: Vector3, velocity: Vector3) -> Dictionary:
	if map == null or map.toys == null:
		return {}
	return map.toys.launch_for(feet, velocity)


## A turning roundabout under a person, for their movement on both ends
## ([member MmController.carrier]): `{offset, yaw, index}` or empty.
func _carry(feet: Vector3, delta: float, ground_id: int) -> Dictionary:
	if map == null or map.toys == null:
		return {}
	return map.toys.carry_for(feet, delta, ground_id)


## A person thrown by a toy: its count goes up, which every client hears. Server side.
func _on_bounced(index: int) -> void:
	if authoritative and map != null and map.toys != null:
		map.toys.launched(index)


## A use the server made, applied on a client.
func apply_door(index: int, open: bool, flip: bool, tick: int) -> void:
	if map != null and map.doors != null:
		map.doors.apply(index, open, flip, tick)


func _physics_process(delta: float) -> void:
	if not authoritative or match_node == null or external_tick:
		return

	simulate(delta)


## One tick, counted by this world. What an offline client and the suite use.
func simulate(delta: float) -> void:
	_tick += 1
	_step(delta)


## One tick, numbered by the netcode. What the bridge uses.
func tick_once(tick: int) -> void:
	if match_node == null:
		return

	_tick = tick
	_step(delta_for_tick())


func current_tick() -> int:
	return _tick


## Simulated seconds, from the tick. What every timer in the game counts.
## A stand-in's chat line, from MmBots.
func bot_say(id: StringName, text: String) -> void:
	if players.has(id) and text != "":
		bot_said.emit(id, text)


func _now() -> float:
	return float(_tick) / float(maxi(tick_rate, 1))


func _step(delta: float) -> void:
	_respawn_the_fallen()
	_advance_phase(delta)
	_advance_holds()
	_drive_bots()
	_advance_use()
	_advance_doors()

	for id: StringName in players:
		var player: MmPlayer = players[id]

		if player.is_alive() and not player.watching:
			player.simulate(_tick, delta)

	_advance_toys(delta)

	_watch_world()
	_advance_weapons()

	if combat != null:
		combat.tick(_tick, delta)

	if spectate != null:
		spectate.advance(_tick)

	if not sides_are_playable() and phase == Phase.IDLE:
		return

	match_node.tick(_tick)


## Somebody below the map has fallen. A height test, not a trigger volume: something falling
## fast crosses a thin trigger between two ticks without ever being inside it.
func _watch_world() -> void:
	if map == null or map.doc.is_empty():
		return

	for id: StringName in players:
		var player: MmPlayer = players[id]

		if not player.is_alive() or player.watching:
			continue

		if player.controller.state.position.y < map.kill_height():
			var fall := DotDamage.make(0, player.entity_id, player.health.max_health * 10.0, null)
			fall.tick = _tick
			fall.context = {"why": DIED_FELL}
			var _applied := combat.apply_damage(fall)


## A fall below the map is not the end of anybody: they start again at a spawn point, with what
## they carried.
func _respawn_the_fallen() -> void:
	if _to_respawn.is_empty():
		return

	var queue := _to_respawn.duplicate()
	_to_respawn.clear()

	for id: StringName in queue:
		var player: MmPlayer = players.get(id)

		if player == null:
			continue

		_heal(player)

		if player.watching:
			continue

		var spot := map.spawn(SPAWN_GROUP, _tick % 97)
		player.place_at(spot[0], spot[1])

		if spectate != null:
			spectate.on_spawned(id)


func delta_for_tick() -> float:
	return 1.0 / float(maxi(tick_rate, 1))


func set_tick_rate(rate: int) -> bool:
	if rate <= 0 or rate == tick_rate:
		return false

	tick_rate = rate

	for id: StringName in players:
		(players[id] as MmPlayer).tick_rate = rate

	if match_node != null and match_node.config != null:
		match_node.config.tick_rate = rate

	if map != null:
		map.tick_rate = rate

		if map.doors != null:
			map.doors.set_tick_rate(rate)

	return true


## Whether nothing solid is between two points: the walls, and with [param furniture] the
## map's props as well.
func _clear_between(from: Vector3, to: Vector3, furniture: bool = false) -> bool:
	var world := get_world_3d()

	if world == null:
		return true

	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = physics.layer_mask(&"world") if physics != null else 1

	if furniture and physics != null:
		# The toys too: somebody crouched behind a barrel or the roundabout is behind something.
		query.collision_mask |= physics.layer_mask(&"prop") | physics.layer_mask(&"toy")

	return world.direct_space_state.intersect_ray(query).is_empty()


## What every stand-in presses this tick: [code]mm_bots.gd[/code].
func _drive_bots() -> void:
	bots.drive()


func _on_player_died(player: MmPlayer, damage: DotDamage) -> void:
	var by := entities.key_for_id(damage.attacker)
	var why: StringName = damage.context.get("why", DIED_SLAIN)

	if not authoritative:
		player_died.emit(player.player_id, by, why)
		return

	# A fall is a respawn; see [method _respawn_the_fallen]. Anything else is out for the round.
	if why == DIED_FELL:
		if not _to_respawn.has(player.player_id):
			_to_respawn.append(player.player_id)
	else:
		player.killed_by = by
		player.weapon_drawn = false

		if player.has_gun:
			_drop_gun(player, player.controller.state.position)

		var killer: MmPlayer = players.get(by) if by != &"" else null

		if killer != null and killer != player:
			killer.kills += 1
			if team_of(by) == MURDERERS:
				killer.points += config.kill_points
			if match_node != null:
				var _fed := match_node.report_kill(String(by), String(player.player_id), why, _tick)

		if progress != null:
			progress.on_killed(player.player_id, by, why)

		# No killer for the camera: a freeze camera on whoever did it would show the dead the
		# murderer, and the dead can still type in all chat. See docs/design.md "Roles are secret".
		if spectate != null:
			spectate.on_died(
				player.player_id, &"", false,
				damage.point if damage.point != Vector3.ZERO else player.global_position,
				map.kill_height() + 8.0, _tick
			)

	if progress != null and why == DIED_FELL:
		progress.on_fell(player.player_id)

	# How the body falls, picked once, here, and carried on DEATH to every client.
	player.death = decide_death(player, damage)

	player_died.emit(player.player_id, by, why)
	bots.on_died(player.player_id, by, why)
	DotLog.debug(CHANNEL, "player died", {"id": String(player.player_id), "by": String(by), "why": String(why)})

	if why != DIED_FELL:
		_check_round()


## The fall a death gets: dot-player-char's reaction rule over the server's weights, seeded from
## the player and the tick. A stab or a shot pushes the body away from whoever did it (the
## direction `_kill` puts on the damage, or the attacker's position), and a fall pushes nothing.
func decide_death(player: MmPlayer, damage: DotDamage) -> DotPlayerDeath:
	var direction := damage.direction
	var attacker: MmPlayer = players.get(entities.key_for_id(damage.attacker)) if damage.attacker != 0 else null
	if direction.length_squared() < 0.0001 and attacker != null and attacker != player:
		direction = player.controller.state.position - attacker.controller.state.position
	return DotPlayerDeath.decide(
		ragdoll_rules.reactions(), damage.is_headshot(), damage.amount, direction,
		DotPlayerDeath.seed_of(player.entity_id, _tick)
	)


func seconds_left() -> float:
	match phase:
		Phase.GRACE:
			return maxf(grace_limit() - phase_elapsed, 0.0)
		Phase.PLAY:
			return maxf(round_limit() - play_elapsed, 0.0)
		_:
			return 0.0


func describe() -> Dictionary:
	return {
		"round": round_number,
		"phase": Phase.keys()[phase],
		"left": "%.0f s" % seconds_left(),
		"map": str(map_doc.get("id", "-")),
		"players": players.size(),
		"alive": alive_total(),
		"murderers": alive_on(MURDERERS),
		"guns down": gun_drops.size(),
		"decided": _winner_name if _decided else "-",
		"maps": catalogue.maps.size() if catalogue != null else 0,
		"phase_id": phase,
	}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["murder, round %d" % round_number])
	var facts := describe()

	for key: String in facts:
		lines.append("  %-12s %s" % [key, facts[key]])

	for id: StringName in players:
		var player: MmPlayer = players[id]
		lines.append("  %-10s %-18s %s%s%s" % [
			side_name(team_of(id)), player.display_name,
			"gun" if player.has_gun else ("drawn" if player.weapon_drawn else "-"),
			" blood %d" % player.blood if player.blood > 0 else "",
			"" if player.is_alive() else " (out)",
		])

	if map != null:
		lines.append_array(map.describe_lines())

	return lines
