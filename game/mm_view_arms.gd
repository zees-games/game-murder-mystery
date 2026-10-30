extends Node3D

## Your own arms holding the knife or the gun in first person, on dot-player-char's
## DotPlayerViewArms. Absent on a shell older than that API: the bare weapon is drawn alone.

const MmWeapons := preload("mm_weapons.gd")

## dot-player-char API level that has the held-weapon mode.
const NEEDS_LEVEL := 8

var arms: DotPlayerViewArms = null
var _what := ""
var _grip: DotViewGrip = null


static func available() -> bool:
	return DotAddonApi.build_level("dot_player_char") >= NEEDS_LEVEL


## Holds [param weapon] (the view model, a node of boxes) as [param what] ("gun" or a weapon id);
## null or "" puts the arms away.
func hold(weapon: Node3D, what: String, look: DotHumanoidLook, height: float) -> void:
	if arms == null:
		if weapon == null:
			return
		top_level = true
		arms = DotPlayerViewArms.new()
		arms.name = "ViewArms"
		add_child(arms)
		arms.build(look, height)
	_what = what
	_grip = null
	if weapon != null and what != "":
		var spec := MmWeapons.grip_of(StringName(what))
		var grip: Vector3 = spec["grip"]
		_grip = DotViewGrip.two_hand(weapon, grip, spec["support"]) if spec.has("support") else DotViewGrip.one_hand(weapon, grip)
	arms.set_held(_grip)


## The pivot follows the eye by yaw only (under the pitch the arms would swing with the look);
## returns what the host adds to the weapon mount.
func follow(eye: Vector3, yaw: float, ground_speed: float, delta: float) -> Vector3:
	if arms == null:
		return Vector3.ZERO
	global_position = eye
	global_rotation = Vector3(0.0, yaw, 0.0)
	arms.tick(ground_speed, delta)
	return arms.sway()


func holding() -> bool:
	return arms != null and arms.shown and _grip != null and _grip.is_valid()


## Metres from each hand to its grip point plus the arms' palm_offset, or -1 when not holding.
func hand_error() -> float:
	return arms.hand_error(_grip) if holding() else -1.0
