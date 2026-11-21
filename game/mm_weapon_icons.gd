extends RefCounted

## Murder Mystery's weapon pictures: weapon id to sprite tag; the rest is gs-ui's [GSWeaponIconStyle].

const GUN := &"gun"

const TAGS := {
	&"knife": &"knife", &"cleaver": &"hatchet", &"axe": &"axe", &"bat": &"hammer",
	&"sword": &"sword", &"gun": &"pistol",
}

## The one instance the HUD and the console share.
static var shared: GSWeaponIconStyle = _make()


static func _make() -> GSWeaponIconStyle:
	var s := GSWeaponIconStyle.new()
	s.tags = TAGS
	return s
