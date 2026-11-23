extends RefCounted

## Murder Mystery's weapon pictures: weapon id to sprite tag; the rest is gs-ui's [GSWeaponIconStyle].

const GUN := &"gun"

const TAGS := {
	&"knife": &"knife", &"shiv": &"dagger", &"hatchet": &"hatchet", &"mallet": &"hammer",
	&"pickaxe": &"pickaxe", &"spade": &"axe", &"gun": &"pistol",
}

## The one instance the HUD and the console share.
static var shared: GSWeaponIconStyle = _make()


static func _make() -> GSWeaponIconStyle:
	var s := GSWeaponIconStyle.new()
	s.tags = TAGS
	return s
