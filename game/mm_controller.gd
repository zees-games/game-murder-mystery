extends DotFpsController

## The first-person controller, with this game's modifier: somebody held still ([member MmPlayer.held_until]) cannot walk,
## jump or crouch. [b]A modifier, not a check in the game's loop[/b]: it travels in the snapshot so a predicting client
## applies it on the same ticks as the server. Registered in [method _register_extensions] on every player, in the same order.

## Held still and unable to jump or crouch.
const HOLD := &"mm_hold"


func _register_extensions() -> void:
	var held := DotFpsModifier.make(HOLD)
	held.deny_move = true
	held.deny_jump = true
	held.deny_crouch = true
	held.max_speed_scale = 0.0
	var _id := motor.register_modifier(held)


## A person thrown by a toy (a trampoline, a bounce pad): which one, by its index in the map's
## toy box. Not during a replay, which is a tick already heard.
signal bounced(index: int)

## `func(feet: Vector3, velocity: Vector3) -> Dictionary`: the velocity a toy under the feet
## throws this person at, `{velocity, index}`, or empty. The game's ([method MmGame._launch]).
var launcher: Callable = Callable()


## The trampolines and pads, before the move: a pure function of where the toys stand, on
## every end that simulates this person, so a predicting client is thrown on the very tick the
## server throws it. AIR at once, as a jump leaves the ground, or the motor snaps them back.
func _on_pre_simulate(_tick: int, _delta: float) -> void:
	if not launcher.is_valid() or state.mode != DotFpsState.Mode.GROUND:
		return
	var thrown: Dictionary = launcher.call(state.position, state.velocity)
	if thrown.is_empty():
		return
	state.velocity = thrown["velocity"]
	state.mode = DotFpsState.Mode.AIR
	state.time_since_grounded = 1000.0
	if not is_replaying():
		bounced.emit(int(thrown["index"]))


## `func(feet: Vector3, delta: float, ground_id: int) -> Dictionary`: how far a turning
## roundabout under the feet carries this person this tick, `{offset, yaw, index}`, or empty.
## The game's ([method MmGame._carry], dot-props' `carry_for`).
var carrier: Callable = Callable()


## A roundabout's rider goes round with it, after the move, on every end that simulates this person (a rotation about
## the hub). A client uses the spin it measures from the poses shown. Written into the state as well as the body, since
## the next move starts from `state.position`. The view is not turned: a command's yaw is the player's.
func _on_post_simulate(_tick: int, delta: float) -> void:
	if not carrier.is_valid() or not state.is_grounded():
		return
	var carried: Dictionary = carrier.call(state.position, delta, state.ground_id)
	var offset: Vector3 = carried.get("offset", Vector3.ZERO)
	if offset == Vector3.ZERO:
		return
	state.position += offset
	if _body_node != null:
		_body_node.global_position = state.position
