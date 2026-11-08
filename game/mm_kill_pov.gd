extends RefCounted

const MmWeapons := preload("mm_weapons.gd")
const MmWeaponIcons := preload("mm_weapon_icons.gd")

## What the final killcam records of the killer's screen beyond the camera: the weapon in hand.
## The game has no magazine or aim-down-sights, so the rest of dot-replay's aux stays zero.

## Aux slot of the held weapon's id hash.
const WEAPON := 0

static var _names: Dictionary = {}


## The aux floats for [param p]: the gun if they carry it, else the blade they have drawn; zero when nothing is out.
static func aux_of(p: Object) -> Array:
	var id := &""
	if p != null:
		if bool(p.get(&"has_gun")):
			id = MmWeaponIcons.GUN
		elif bool(p.get(&"weapon_drawn")):
			id = StringName(p.get(&"weapon_id"))
	return [hash_of(id)]


static func hash_of(id: StringName) -> float:
	return float(int(String(id).hash() & 0xFFFFFF)) if id != &"" else 0.0


## The display name of the weapon an aux hash names, or empty.
static func weapon_name(hash_value: float) -> String:
	if _names.is_empty():
		var ids: Array[StringName] = MmWeapons.ids()
		ids.append(MmWeaponIcons.GUN)
		for id in ids:
			_names[int(hash_of(id))] = String(MmWeapons.entry(id)["name"]) if MmWeapons.known(id) else String(id).capitalize()
	return String(_names.get(int(hash_value), ""))
