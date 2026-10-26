extends CharacterBody3D

const MmConfig := preload("mm_config.gd")
const MmController := preload("mm_controller.gd")
const MmFigure := preload("mm_figure.gd")
const MmAvatars := preload("mm_avatars.gd")

## One person: how they move, what they carry, and how much blood is on them.
##
## [b]Everybody looks alike.[/b] A murderer, a gunner and a bystander are the same people in
## the same shirts (a colour drawn per player per round, [member shirt]); what tells them apart
## is what is in their hand ([member armed]) and, near the end, the blood on a murderer
## ([member blood]). Their real role ([member team]) is the server's, and a client is told only
## its own (see docs/design.md "Roles are secret").
##
## [b]Hit by rays and reach, not hitboxes.[/b] A stab is a distance and a cone from the
## murderer's eye; a shot is a ray against the players' standing capsules. Both are measured by
## the server, in [code]mm_game.gd[/code]. Health is dot-combat's, so dot-moderation's god,
## buddha and slap mean what they mean everywhere else.

## Metres above a player's feet that their eyes are.
const EYE_HEIGHT := 1.6

## A player's body hull, in metres: the family's.
const BODY_RADIUS := 0.35
const BODY_HEIGHT := 1.8
const BODY_CROUCH := 0.95
const BODY_STEP := 0.4

## The attack key (stab, or shoot) and the holster key, in the same buttons.
const ATTACK_BUTTON := DotFpsCommand.BUTTON_USER_1
const HOLSTER_BUTTON := DotFpsCommand.BUTTON_USER_2

## What somebody has in their hand, as everybody sees it: [member armed].
## The murderers' team id, as [constant MmGame.MURDERERS] (not preloaded here: the game
## preloads this file).
const MURDERER_TEAM := 2

const ARMED_NONE := 0
const ARMED_WEAPON := 1
const ARMED_GUN := 2

## The use key, in the movement command's buttons: one dot-player-controller leaves to games,
## so it rides in every input packet with the movement and needs no field of its own.
const USE_BUTTON := DotFpsCommand.BUTTON_USER_0

@export var player_id: StringName = &"local"
@export var display_name: String = "Player"
@export var samples_input: bool = false
@export var is_bot: bool = false

## What this player looks like, as a dot-user-avatar document; null is the stock person.
var avatar: DotAvatar = null

var config: MmConfig = null

var controller: MmController = null
var sampler: DotFpsSampler = null
## Offline only: the keys do not walk this body. Set while its owner flies the spectator's free
## camera, which takes the same keys.
var input_off: bool = false
var health: DotHealth = null

## Their role this round: [constant MmGame.BYSTANDERS] or [constant MmGame.MURDERERS]. The
## server's; on a client it is known for the local player alone (the ROLE event) and is 1 for
## everybody else.
var team: int = 0

var points: int = 0
var ping_ms: int = -1
var entity_id: int = 0

## How many times the server has moved them by hand: a spawn, a respawn. A predicting client
## reads a change as "snap, do not smooth".
var warps: int = 0

## Out of the round, watching: dead, or joined while it was being played.
var watching: bool = false

## The gun is theirs right now.
var has_gun: bool = false

## Whether a murderer's weapon is out. Holstered, nobody else sees it.
var weapon_drawn: bool = false

## Which weapon a murderer carries (an id in mm_weapons.gd), so a client draws the right one.
var weapon_id: StringName = &"knife"

## When the weapon came out, in simulated seconds: a stab lands only [member MmConfig.draw_seconds]
## after it.
var drawn_at: float = -1.0

## When they may attack again (a stab or a shot), in simulated seconds.
var ready_at: float = 0.0

## They dropped the gun this round (a miss, an innocent shot) and may not pick one up again.
var gun_banned: bool = false

## How much blood is on them, 0 for none: the murderer's, rising near the end and with each
## kill. On the wire for everybody.
var blood: int = 0

## Which shirt colour they wear this round, an index into [constant MmGame.SHIRTS]. Drawn
## per round so a shirt cannot be learned.
var shirt: int = 0

## Kills this round, and who killed them.
var kills: int = 0
var killed_by: StringName = &""

## When the last attack was made, in simulated seconds, for the swing and the muzzle on a
## client. -1 before any.
var attacked_at: float = -1.0

## How many attacks this player has made this match, four bits of it on the wire: a mirror that
## sees it change plays the swing or the shot. A count rather than a time, so a lost snapshot
## does not lose the swing.
var attacks: int = 0

## Seconds until the weapon or the gun is ready again, for the HUD. The server's number, copied.
var ready_in: float = 0.0

## Holding still, until this simulated time (-1 none). Not used by the rules today; kept for an
## admin's freeze.
var held_until: float = -1.0

## The use, attack and holster keys, held this tick, and whether each was held the tick before:
## a press is the edge, made on the server from the held state.
var wants_use: bool = false
var use_was_held: bool = false
var wants_attack: bool = false

## How many ticks behind the present this person's client drew everybody else when it last sent
## a command, or -1 (a bot, a local player, nothing measured): what a stab or a shot of theirs is
## rewound by. Set by the net bridge; the game caps it.
var view_lag: float = -1.0
var attack_was_held: bool = false
var wants_holster: bool = false
var holster_was_held: bool = false

## An administrator's `blind` and `beacon`.
var blinded: bool = false
var beacon: bool = false

var beacon_marker: DotFxBeacon = null

## What other people see this player as. Client side.
var figure: MmFigure = null

## What is in their hand, as anybody else sees it.
func armed() -> int:
	if has_gun:
		return ARMED_GUN
	if weapon_drawn:
		return ARMED_WEAPON
	return ARMED_NONE

## How this player's body falls on their death: the server's pick ([method MmGame.decide_death]),
## carried on DEATH and set here before anybody hears of it. Null before a first death.
var death: DotPlayerDeath = null

var tick_rate: int = 64:
	set(value):
		tick_rate = value
		if controller != null:
			controller.tick_rate = value


func _ready() -> void:
	controller = MmController.new()
	controller.name = "Controller"
	controller.tick_rate = tick_rate
	# EXTERNAL even offline: the world owns the tick, which is the shape a dedicated server
	# needs and the one a predicting client replays.
	controller.drive = DotFpsController.Drive.EXTERNAL
	controller.tunables = tunables_for(config)
	controller.admin_abilities = true
	add_child(controller)

	if samples_input:
		sampler = DotFpsSampler.new(controller.tunables)
		register_actions(sampler)


## How a player moves. Static: a connected client builds a sampler before it has a player, and
## the two must agree. The same for both sides, so a predicting client never has to know which
## side somebody is on to move them.
static func tunables_for(config: MmConfig, speed_scale: float = 1.0) -> DotFpsTunables:
	var t := DotFpsTunables.with_profile("legacy")
	t.max_speed = (config.run_speed if config != null else 6.0) * speed_scale
	t.gravity = config.gravity if config != null else 20.0
	t.jump_height = config.jump_height if config != null else 1.15
	t.auto_hop = config.auto_bunny_hop if config != null else false
	var sprint := config.sprint_scale if config != null else 1.35
	t.can_sprint = sprint > 1.001
	t.sprint_speed_scale = maxf(sprint, 1.0)
	t.can_walk = true
	t.walk_speed_scale = 0.45
	t.can_crouch = true
	t.crouch_speed_scale = 0.45
	t.accelerate = 10.0
	t.friction = 6.0
	t.stop_speed = 2.5
	t.air_accelerate = config.air_accelerate if config != null else 20.0
	t.max_air_wish_speed = 1.2
	t.coyote_time = 0.1
	t.jump_buffer_time = 0.12
	t.max_slope_angle = 46.0
	t.radius = BODY_RADIUS
	t.stand_height = BODY_HEIGHT
	t.crouch_height = BODY_CROUCH
	t.step_height = BODY_STEP
	return t


## The movement actions. Shift sprints here (the controller's own default), because a chase is
## the game; the slow walk stays on its own key.
static func register_actions(p_sampler: DotFpsSampler = null) -> void:
	var _added := DotFpsSampler.register_default_actions(p_sampler)


## One simulated tick. On the server and offline; a client predicts through its behaviour.
func simulate(tick: int, delta: float) -> void:
	# The world calls this by name, so a body the load gate froze is skipped here.
	if is_inside_tree() and not can_process():
		return

	if sampler != null:
		# Settling under the cover runs the body with its input off (falls, lands, no keys).
		var gate := DotLoadGate.of(self) if is_inside_tree() else null
		# Sampled even when off, so presses latched meanwhile are consumed, not replayed later.
		var command := sampler.sample(delta)
		controller.apply_command(
			command if (gate == null or gate.is_open()) and not input_off else DotFpsCommand.new())

	controller.simulate_tick(tick, delta)
	global_position = controller.state.position


func delta_for_tick() -> float:
	return 1.0 / float(maxi(tick_rate, 1))


## The hull's height now.
func hull_height() -> float:
	return controller.tunables.stand_height if controller != null else BODY_HEIGHT


## Where this player's eyes are.
func eye_position() -> Vector3:
	var height := EYE_HEIGHT

	if controller != null and controller.state.crouch_fraction > 0.0:
		height = lerpf(EYE_HEIGHT, BODY_CROUCH - 0.15, controller.state.crouch_fraction)

	return controller.state.position + Vector3(0.0, height, 0.0)


## Which way they are looking, as a unit vector. From yaw and pitch, never a camera.
func aim_direction() -> Vector3:
	var view := Basis.from_euler(Vector3(
		deg_to_rad(controller.state.pitch), deg_to_rad(controller.state.yaw), 0.0
	))
	return -view.z


## The duck-typed lookup other addons ask a carrier for.
func component(type_name: StringName) -> Object:
	match String(type_name):
		"DotPlayerController", "DotFpsController":
			return controller
		"DotHealth":
			return health
		_:
			return null


## Puts a player somewhere, facing somewhere, with nothing carried over.
func place_at(at: Vector3, yaw_degrees: float) -> void:
	warps += 1
	global_position = at
	controller.teleport(at, yaw_degrees, 0.0)

	if sampler != null:
		sampler.look_at_angles(yaw_degrees, 0.0)

	var facing := DotFpsCommand.new()
	facing.yaw = yaw_degrees
	controller.apply_command(facing)


## Back to the start of a round: empty hands, no blood, not watching, not held.
func reset_round() -> void:
	watching = false
	has_gun = false
	weapon_drawn = false
	drawn_at = -1.0
	ready_at = 0.0
	gun_banned = false
	blood = 0
	kills = 0
	killed_by = &""
	attacked_at = -1.0
	held_until = -1.0

	if controller != null:
		var _let_go := controller.remove_modifier(MmController.HOLD)


## The movement again from the configuration, at the murderer's pace for a murderer. Called
## when the role is drawn, on the server and (for its own player) on a client, so prediction
## and the server move them alike.
func retune() -> void:
	if controller == null:
		return

	# A fresh tunables object has the default mask (the world only), so the layers the game's
	# physics layout gave this player (furniture, toys' beds) must be carried across: without
	# this, everybody who was drawn a role walked through every prop.
	var mask := controller.tunables.collision_mask
	controller.tunables = tunables_for(config, _speed_scale())
	controller.set_collision_mask(mask)

	if sampler != null:
		sampler.tunables = controller.tunables


func _speed_scale() -> float:
	return config.murderer_speed_scale if config != null and team == MURDERER_TEAM else 1.0


func is_alive() -> bool:
	return health == null or health.alive


# --- Drawing (client side) --------------------------------------------------

## Draws an administrator's beacon at [param at]. Returns whether it pinged.
func present_beacon(delta: float, at: Vector3, local_view: bool, period: float) -> bool:
	if not beacon or not is_alive():
		if beacon_marker != null:
			beacon_marker.queue_free()
			beacon_marker = null
		return false

	if beacon_marker == null:
		beacon_marker = DotFxBeacon.new()
		beacon_marker.name = "Beacon"
		beacon_marker.period = period
		beacon_marker.colour = Color(0.98, 0.22, 0.86)
		beacon_marker.column_base = hull_height() + 0.4
		add_child(beacon_marker)

	beacon_marker.local_view = local_view
	beacon_marker.global_position = at
	return beacon_marker.advance(delta)


## Draws this player for one frame at [param at], in [param shirt_colour], with what is in
## their hand and the blood on them. Returns whether anything was shown.
func present_body(hidden: bool, at: Vector3, shirt_colour: Color) -> bool:
	var shown := not hidden and is_alive() and not watching

	if figure == null:
		if not shown:
			return false
		figure = MmFigure.new()
		figure.name = "Figure"
		add_child(figure)

	var atlas := _atlas()

	if figure.atlas != atlas or not figure.team_colour.is_equal_approx(shirt_colour):
		figure.build(BODY_HEIGHT, atlas, shirt_colour)

	figure.visible = shown

	if shown:
		figure.hold(armed(), weapon_id)
		figure.bleed(blood)
		if attacks != _attacks_drawn and armed() == ARMED_WEAPON:
			figure.strike()
		_attacks_drawn = attacks
		var velocity := controller.state.velocity
		figure.set_motion({
			"on_floor": controller.state.mode == DotFpsState.Mode.GROUND,
			"vertical": velocity.y,
			"crouched": controller.state.crouch_fraction > 0.5,
			# The view's pitch: the upper body and the head follow it.
			"aim": deg_to_rad(controller.state.pitch),
		})
		figure.pose(at, deg_to_rad(controller.state.yaw), Vector2(velocity.x, velocity.z).length())

	return shown


## The last [member attacks] the figure swung for.
var _attacks_drawn: int = 0


func _atlas() -> String:
	var index := MmAvatars.skin_index(avatar)

	if index < 0 or index >= MmFigure.ATLASES.size():
		index = MmAvatars.stock_index(player_id)

	return str(MmFigure.ATLASES[index])


func describe() -> Dictionary:
	return {
		"id": String(player_id),
		"side": team,
		"alive": is_alive(),
		"watching": watching,
		"armed": armed(),
		"gun": has_gun,
		"blood": blood,
		"kills": kills,
		"blinded": blinded,
		"beacon": beacon,
		"points": points,
	}
