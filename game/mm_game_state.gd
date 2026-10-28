extends Node3D

## The state of [code]mm_game.gd[/code]: constants, signals and every variable, split out so the
## simulation file stays under the size gate. Path-based base, no class_name.

const MmAmbience := preload("mm_ambience.gd")
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

## Lag compensation: how far back (ms, `mm_max_unlag_ms`, 0 = present) a stab or shot looks at the
## other bodies, from [member MmPlayer.view_lag] capped here. The shooter is never moved; bots
## and local players send -1.
var max_unlag_ms: float = 1000.0

## Ticks of position kept per body: two seconds at 64.
const UNLAG_HISTORY := 128

## id -> [PackedVector3Array positions, PackedInt32Array ticks], a ring per body.
var _trail: Dictionary = {}

## The fractional tick [method body_position] looks back to while a stab or a shot is judged, or
## -1 for the present.
var _rewind_to: float = -1.0

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
## dot-spectate's `mp_forcecamera`, `mp_freeroam` and `mp_freeroam_speed`: one object shared with
## [MmSpectate]'s manager, bound by the module (REPLICATED) and followed by a client.
var spectate_rules: DotSpectatorRules = DotSpectatorRules.new()
var progress: MmProgress = null

## Everybody in the world, by player id.
var players: Dictionary = {}

## dot-player-char's `mp_*` view and body rules.
var view_rules: DotPlayerViewRules = DotPlayerViewRules.new()
var body_rules: DotPlayerBodyRules = DotPlayerBodyRules.new()

## `sv_falldamage*`: landing hard hurts. On in this game (dot-combat's default is off); the
## server applies it through [member combat], a client never does.
var fall_rules: DotFallDamageRules = make_fall_rules()
## The ambience cvars (`mm_ambient*`): bound by the module (REPLICATED), followed by a client through its link.
var ambient_rules: DotAmbienceRules = MmAmbience.make_rules()

## Binds [member config] to cvars, the cfg/ yml layers and the workbench; made by whoever builds the config.
var config_binder: DotGameConfigBinder = null

## The workbench's profile rows, made on first ask: the bridge's profile link must exist before the netcode seals, the workbench after.
var profile_runtime: DotProfileRuntime = null


func ensure_runtime() -> DotProfileRuntime:
	if profile_runtime == null:
		profile_runtime = DotProfileRuntime.new()
		# A method, not a lambda: a static may keep the runtime past the tree, and a lambda holds this script.
		profile_runtime.permit = _local_permit
	return profile_runtime

func _local_permit(actor: Variant, _flag: String) -> bool:
	return typeof(actor) == TYPE_STRING_NAME and actor == &"local"

## dot-team's block rules (`!block`, `!noblock`, `mp_teamblock`), set by the server module or `DotGameClient.add_noblock`. They feed [member body_rules]'s `pair_fn`.
var block_rules: Object = null:
	set(value):
		if block_rules != null and block_rules.is_connected(&"changed", body_rules.refresh):
			block_rules.disconnect(&"changed", body_rules.refresh)
		block_rules = value
		if block_rules != null and block_rules.has_signal(&"changed"):
			block_rules.connect(&"changed", body_rules.refresh)

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


## The server's maps.yml, or null when there is none (every map rotates, as it always did).
var rotation_file: DotMapRotationFile = null

## The catalogue as dot-map sees it (one [DotMapDef] per document, rebuilt by
## [method apply_rotation]) and the rotation over it. This game's own [MmCatalogue] holds
## documents, not defs; [DotMapRotationFile] marks defs, so the marks live here.
var map_rotation_defs: DotMapCatalogue = null

var map_rotation: DotMapRotation = null

## `func(player_id: StringName) -> bool`: whether a player may be hurt now, assigned by the
## module from dot-game's `can_peer_be_harmed`. Unset offline, in a suite and for a bot, so
## everybody can be harmed.
var harm_gate: Callable = Callable()


static func make_fall_rules() -> DotFallDamageRules:
	var rules := DotFallDamageRules.new()
	rules.enabled = true
	# Mild for a light-footed game: only a very long drop (about 40 m/s) kills outright.
	rules.lethal_speed = 40.0
	return rules
