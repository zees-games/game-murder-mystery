extends RefCounted

## The murderer's melee weapons, and how each is drawn. A table, not a resource per weapon: a
## weapon here is a reach, a cooldown and a shape, and the server owner picks one by id
## (`mm_murderer_weapon`). The gun is not here; there is one gun and the game knows it.
##
## [b]A shape is boxes in the hand's space[/b] (x right, y up the blade, z forward), so the
## figure and the first-person view draw the same thing with no model file to deliver.

const DEFAULT := &"knife"

const TABLE := {
	&"knife": {"name": "Knife", "reach": 1.9, "cooldown": 0.9, "parts": [
		[Vector3(0.0, 0.05, 0.0), Vector3(0.035, 0.11, 0.035), Color(0.12, 0.08, 0.05)],
		[Vector3(0.0, 0.2, 0.0), Vector3(0.012, 0.2, 0.045), Color(0.82, 0.84, 0.88)],
	]},
	&"cleaver": {"name": "Cleaver", "reach": 1.8, "cooldown": 1.0, "parts": [
		[Vector3(0.0, 0.05, 0.0), Vector3(0.035, 0.12, 0.035), Color(0.15, 0.1, 0.06)],
		[Vector3(0.0, 0.2, 0.04), Vector3(0.012, 0.19, 0.12), Color(0.75, 0.77, 0.8)],
	]},
	&"axe": {"name": "Axe", "reach": 2.2, "cooldown": 1.3, "parts": [
		[Vector3(0.0, 0.25, 0.0), Vector3(0.04, 0.55, 0.04), Color(0.45, 0.3, 0.16)],
		[Vector3(0.0, 0.48, 0.07), Vector3(0.02, 0.14, 0.14), Color(0.6, 0.62, 0.66)],
	]},
	&"bat": {"name": "Bat", "reach": 2.1, "cooldown": 1.2, "parts": [
		[Vector3(0.0, 0.3, 0.0), Vector3(0.06, 0.65, 0.06), Color(0.7, 0.55, 0.35)],
	]},
	&"sword": {"name": "Sword", "reach": 2.4, "cooldown": 1.1, "parts": [
		[Vector3(0.0, 0.05, 0.0), Vector3(0.035, 0.12, 0.035), Color(0.2, 0.12, 0.06)],
		[Vector3(0.0, 0.12, 0.0), Vector3(0.03, 0.025, 0.16), Color(0.7, 0.6, 0.2)],
		[Vector3(0.0, 0.45, 0.0), Vector3(0.012, 0.65, 0.05), Color(0.85, 0.87, 0.9)],
	]},
}

## The gun's shape, in the same space, its barrel along -z (the hand's forward).
const GUN_PARTS := [
	[Vector3(0.0, -0.03, 0.0), Vector3(0.035, 0.11, 0.05), Color(0.12, 0.12, 0.13)],
	[Vector3(0.0, 0.03, -0.07), Vector3(0.035, 0.05, 0.2), Color(0.18, 0.18, 0.2)],
]


## Where the first-person hands go, in the shape's space: `grip` the firing hand's palm and
## `support` the other hand (absent: one hand). Only the gun is spelled out; a melee weapon's
## grip is derived from its handle (the first part) by [method grip_of].
const GRIPS := {
	&"gun": {"grip": Vector3(0.0, -0.07, 0.02), "support": Vector3(-0.02, -0.08, -0.03)},
}

## Weapons longer than this lean their tip away from the crosshair in first person.
const LONG_REACH := 0.4


## The grip for [param id]: the gun's from the table, a melee weapon's on its handle, a hand's
## width above the pommel (or the middle of a short handle).
static func grip_of(id: StringName) -> Dictionary:
	if GRIPS.has(id):
		return GRIPS[id]
	var handle: Array = entry(id)["parts"][0]
	var size: Vector3 = handle[1]
	var at: Vector3 = handle[0]
	return {"grip": Vector3(at.x, at.y - size.y * 0.5 + minf(size.y * 0.5, 0.1), at.z)}


## Metres from the shape's origin to its farthest box edge along y.
static func length_of(id: StringName) -> float:
	var top := 0.0
	for part: Array in entry(id)["parts"]:
		top = maxf(top, (part[0] as Vector3).y + (part[1] as Vector3).y * 0.5)
	return top


static func ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for id: StringName in TABLE:
		out.append(id)
	return out


## The entry for [param id], or the knife's for an id nobody knows.
static func entry(id: StringName) -> Dictionary:
	return TABLE.get(id, TABLE[DEFAULT])


static func known(id: StringName) -> bool:
	return TABLE.has(id)


## A node of boxes for [param parts], unshaded where it has to read at a distance.
static func build(parts: Array, scale: float = 1.0) -> Node3D:
	var root := Node3D.new()
	root.name = "Held"
	for part: Array in parts:
		var box := BoxMesh.new()
		box.size = (part[1] as Vector3) * scale
		var mat := StandardMaterial3D.new()
		mat.albedo_color = part[2]
		mat.roughness = 0.5
		mat.metallic = 0.3 if (part[2] as Color).v > 0.6 else 0.0
		box.material = mat
		var mesh := MeshInstance3D.new()
		mesh.mesh = box
		mesh.position = (part[0] as Vector3) * scale
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mesh)
	return root
