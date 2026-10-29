extends Node3D

const MmPaths := preload("mm_paths.gd")

## What somebody ELSE looks like: one of the family's people (dot-player-char's
## [DotHumanoidFigure]), scaled to the player's hull, in this round's shirt, turned to where they
## are looking, with what is in their hand and the blood on them. Client side only.
##
## [b]Top level, and placed by its caller every frame.[/b] The player node is the simulation's
## and moves once a tick; `MmClient.present_frame` hands every body the position this frame
## draws, so nothing here computes one.
##
## [b]The shirt is a colour drawn per round, not a side.[/b] Everybody looks alike on purpose;
## see docs/design.md "Roles are secret". What gives a murderer away is a drawn weapon
## ([method hold]) and, near the end, blood ([method bleed]).

const MmWeapons := preload("mm_weapons.gd")

const CHANNEL := "mm.figure"

## The six people a player can be, by the blocky kit's atlas letters (the avatar documents name
## them). Only the letter is read: the people are coloured, not textured.
static var ATLASES: Array[String] = [
	MmPaths.rebase("res://assets/kenney/characters/Textures/texture-a.png"),
	MmPaths.rebase("res://assets/kenney/characters/Textures/texture-b.png"),
	MmPaths.rebase("res://assets/kenney/characters/Textures/texture-c.png"),
	MmPaths.rebase("res://assets/kenney/characters/Textures/texture-e.png"),
	MmPaths.rebase("res://assets/kenney/characters/Textures/texture-f.png"),
	MmPaths.rebase("res://assets/kenney/characters/Textures/texture-k.png"),
]

## How much of the shirt colour goes on the top: all of it.
const TEAM_TINT := 1.0

## Which atlas this figure wears, and the shirt colour on it. Read by the suite.
var atlas: String = ""
var team_colour: Color = Color.WHITE

## Whether the people's art loaded, or a capsule stands in.
var from_art: bool = false

## The clip playing, for the suite and for `describe()`.
var clip: StringName = &""

## The person, under this node.
var person: DotHumanoidFigure = null
## What the hand shows now (an MmPlayer ARMED_ value) and the weapon id, and the node drawn.
var armed: int = 0
var weapon_id: StringName = &""
var _held: Node3D = null

## How many blood spots are drawn, and the node holding them.
var blood: int = 0
var _blood: Node3D = null

## Where the spots go, on the torso and the legs, in the figure's space at a 1.8 m height
## (front is -z). The first few are the chest, so the first stage is the one seen face on.
const SPOTS := [
	Vector3(0.06, 1.18, -0.17), Vector3(-0.08, 1.05, -0.17), Vector3(0.1, 0.92, -0.16),
	Vector3(-0.02, 1.3, -0.15), Vector3(-0.12, 1.22, -0.16), Vector3(0.04, 0.98, 0.17),
	Vector3(0.12, 0.6, -0.12), Vector3(-0.1, 0.45, -0.12), Vector3(0.2, 1.1, -0.05),
	Vector3(-0.2, 1.0, -0.05), Vector3(0.0, 1.12, 0.17), Vector3(-0.06, 0.7, -0.12),
]


func _init() -> void:
	# The caller places it; see the class note.
	top_level = true


## Builds the figure to stand [param height] metres tall, feet at this node's origin, as the
## person [param atlas_path]'s letter is, wearing [param colour] on the top.
func build(height: float, atlas_path: String, colour: Color) -> void:
	atlas = atlas_path
	team_colour = colour
	clip = &""
	var look := DotHumanoidLook.from_letter(atlas_path)
	if look == null:
		DotLog.debug(CHANNEL, "no look for the atlas; stock look used", {"atlas": atlas_path})
		look = DotHumanoidLook.stock(hash(atlas_path))
	if colour != Color.WHITE:
		look = look.with_side(colour, TEAM_TINT)
	if person == null:
		person = DotHumanoidFigure.new()
		person.name = "Person"
		add_child(person)
	person.build(look, height)
	from_art = person.from_art
	# A rebuilt person has a new hand and a new torso: what hung off the old ones is redone.
	armed = -1
	_held = null
	_blood = null
	blood = 0


## Shows [param what] (an MmPlayer ARMED_ value) in the hand: the weapon [param weapon]'s
## shape, the gun, or nothing. A holstered weapon is nothing, which is the point.
func hold(what: int, weapon: StringName) -> void:
	if what == armed and weapon == weapon_id:
		return
	armed = what
	weapon_id = weapon
	if _held != null and is_instance_valid(_held):
		_held.queue_free()
	_held = null
	if person == null:
		return
	person.set_hold(DotHumanoidFigure.Hold.GUN if what == 2 else (
		DotHumanoidFigure.Hold.MELEE if what == 1 else DotHumanoidFigure.Hold.NONE))
	if what == 0:
		return
	var hand := person.attachment(&"right_hand")
	if hand == null:
		return
	_held = MmWeapons.build(MmWeapons.GUN_PARTS if what == 2 else MmWeapons.entry(weapon)["parts"])
	if what == 1:
		# A blade held forward of the fist, not up the forearm.
		_held.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
	hand.add_child(_held)


## A swing or a shot, drawn over whatever the legs do.
func strike() -> void:
	if person != null:
		person.swing(DotHumanoidClips.STAB if armed == 1 else &"")


## Draws [param stage] blood spots, growing from the chest out.
func bleed(stage: int) -> void:
	if stage == blood:
		return
	blood = stage
	if _blood != null and is_instance_valid(_blood):
		_blood.queue_free()
	_blood = null
	if stage <= 0 or person == null:
		return
	_blood = Node3D.new()
	_blood.name = "Blood"
	add_child(_blood)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.02, 0.02)
	mat.roughness = 0.35
	var spots := mini(stage * 3, SPOTS.size())
	for i in range(spots):
		var mesh := MeshInstance3D.new()
		var ball := SphereMesh.new()
		var size := 0.05 + 0.025 * float((i * 7) % 3)
		ball.radius = size
		ball.height = size * 2.0
		ball.radial_segments = 8
		ball.rings = 4
		ball.material = mat
		mesh.mesh = ball
		var at: Vector3 = SPOTS[i]
		mesh.position = at * (person.height / 1.8)
		# Flattened against the body: a stain, not a bead.
		mesh.scale = Vector3(1.0, 1.0, 0.25) if absf(at.z) > 0.1 else Vector3(0.25, 1.0, 1.0)
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_blood.add_child(mesh)


## What is in the hand now, for a death that drops it as a prop. Null when nothing is drawn.
func held_node() -> Node3D:
	return _held if _held != null and is_instance_valid(_held) else null


## The drawn model, for a death that breaks it apart or falls. Null before [method build].
func body_node() -> Node3D:
	return person


## How the player moves besides its ground speed: `on_floor`, `vertical`, `crouched` and the
## rest [DotHumanoidFigure.set_motion] reads.
func set_motion(motion: Dictionary) -> void:
	if person != null:
		person.set_motion(motion)


## Puts the figure where this frame draws its player, facing [param yaw_radians], moving at
## [param speed] metres a second over the ground.
func pose(at: Vector3, yaw_radians: float, speed: float) -> void:
	global_position = at
	rotation = Vector3(0.0, yaw_radians, 0.0)
	if person == null:
		return
	# Game time, as the body moves: a wall-clock step skated the feet (slow motion, fixed-rate frames).
	person.animate(speed, person.frame_delta())
	clip = person.clip


func describe() -> Dictionary:
	return {
		"art": from_art,
		"atlas": atlas.get_file(),
		"visible": visible,
		"clip": String(clip),
		"armed": armed,
		"blood": blood,
		"at": str(global_position.snapped(Vector3.ONE * 0.01)) if is_inside_tree() else "-",
	}
