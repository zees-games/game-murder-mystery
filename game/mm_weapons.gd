extends RefCounted

## The murderer's melee weapons, and how each is drawn. The weapons are zee-gs-weapons': an id here IS a zee weapon id
## (knife, shiv, hatchet, mallet, pickaxe, spade) and the gun is zee's pistol, so the model, its size and its look come
## from `ZeeWeaponArtTable` and the game vendors the art with `zee-gs-weapons/tools/sync-art.sh`. What stays here is
## this game's own rule per weapon, a reach and a cooldown, picked by id (`mm_murderer_weapon`). [b]A weapon is drawn
## in the hand's space[/b] (x right, y up the blade, z forward; the gun's barrel along -z).

const MmPaths := preload("mm_paths.gd")

const DEFAULT := &"knife"

## The token for the gun in the figure, the first-person view and the kill cam; zee's art for it is [constant GUN_ART].
const GUN := &"gun"
const GUN_ART := &"pistol"

const TABLE := {
	&"knife": {"name": "Knife", "reach": 1.9, "cooldown": 0.9},
	&"shiv": {"name": "Shiv", "reach": 1.8, "cooldown": 1.0},
	&"hatchet": {"name": "Hatchet", "reach": 2.2, "cooldown": 1.3},
	&"mallet": {"name": "Mallet", "reach": 2.1, "cooldown": 1.2},
	&"pickaxe": {"name": "Pickaxe", "reach": 2.3, "cooldown": 1.25},
	&"spade": {"name": "Spade", "reach": 2.4, "cooldown": 1.1},
}

## Weapons longer than this lean their tip away from the crosshair in first person.
const LONG_REACH := 0.4

## Metres up the handle the first-person hand takes a melee weapon, before the weapon's own scale.
const GRIP_UP := 0.05
## The pistol's grip in the hand's space: the model's origin is its grip.
const GUN_GRIP := Vector3(0.0, 0.0, 0.0)


## The zee art for a weapon id of this game ("gun" is the pistol), or null when the addon has none.
static func art_of(id: StringName) -> ZeeWeaponArt:
	var art: Variant = ZeeWeaponArtTable.table().get(GUN_ART if id == GUN else id)
	return art as ZeeWeaponArt


## Where the first-person hands go, in the weapon's space: `grip` the firing hand's palm. Every weapon is held in one
## hand: a support hand on a long weapon crosses the view and fills the lower third.
static func grip_of(id: StringName) -> Dictionary:
	if id == GUN:
		return {"grip": GUN_GRIP}
	var art := art_of(id)
	return {"grip": Vector3(0.0, GRIP_UP * (art.world_scale if art != null else 1.0), 0.0)}


## Metres from the weapon's origin to its far end along y (the hand's space), 0 when the model is not there.
static func length_of(id: StringName) -> float:
	var art := art_of(id)
	if art == null or not art.has_model():
		return 0.0
	return ZeeModelCache.bounds(art.model_path).size.y * art.world_scale


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


## How a weapon is turned in the first-person view: a blade tilted up and in, a long one leaning
## its tip off the crosshair. The gun points straight ahead.
static func view_rotation(id: StringName) -> Vector3:
	if id == GUN:
		return Vector3.ZERO
	return Vector3(-PI / 2.6, 0.15, -0.4 if length_of(id) > LONG_REACH else 0.0)


## A node holding zee's model of [param id] ("gun" is the pistol) in the hand's space, [param scale] times the art's own
## third-person size. Empty (draws nothing, the weapon still works) when the art or the model is missing.
static func build(id: StringName, scale: float = 1.0) -> Node3D:
	var root := Node3D.new()
	root.name = "Held"
	var art := art_of(id)
	if art == null or not art.has_model():
		return root
	# The art is this game's copy: the table names `res://assets/...`, which a delivered pack lacks.
	ZeeModelCache.set_asset_root(MmPaths.root())
	var model := ZeeModelCache.instantiate(art.model_path)
	if model == null:
		return root
	# A melee model already points up +y, the hand's blade axis; a gun is turned so its barrel runs along -z.
	var basis := Basis.IDENTITY if id != GUN and art.model_forward == Vector3.UP else art.orientation()
	model.transform = Transform3D(basis.scaled(Vector3.ONE * art.world_scale * scale), Vector3.ZERO)
	_unshadow(model)
	root.add_child(model)
	return root


static func _unshadow(node: Node) -> void:
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_unshadow(child)
