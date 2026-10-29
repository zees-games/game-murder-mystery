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


## Metres from each hand's finger bone to where the arms aim it (grip plus palm_offset), or -1 when not holding.
func hand_error() -> float:
	if not holding() or not (arms.arms() is DotHumanoidFigure):
		return -1.0
	var skeleton := (arms.arms() as DotHumanoidFigure).skeleton()
	if skeleton == null:
		return -1.0
	var worst := 0.0
	var palm: Vector3 = arms.get("palm_offset") if arms.get("palm_offset") != null else Vector3.ZERO
	var basis := arms.global_transform.basis
	var pairs := [["Middle1.R", _grip.grip_world() + basis * palm]]
	if _grip.is_two_hand():
		pairs.append(["Middle1.L", _grip.support_world() + basis * Vector3(-palm.x, palm.y, palm.z)])
	for pair: Array in pairs:
		var bone := skeleton.find_bone(pair[0])
		if bone < 0:
			return -1.0
		var at := skeleton.global_transform * skeleton.get_bone_global_pose(bone).origin
		worst = maxf(worst, at.distance_to(pair[1]))
	return worst
