extends RefCounted

## Murder Mystery's weapon pictures: weapon id to sprite tag; the rest is dot-ui's [DotWeaponIconStyle].

const GUN := &"gun"

const TAGS := {
	&"knife": &"knife", &"cleaver": &"hatchet", &"axe": &"axe", &"bat": &"hammer",
	&"sword": &"sword", &"gun": &"pistol",
}

## The one instance the HUD and the console share.
static var shared: DotWeaponIconStyle = _make()


static func _make() -> DotWeaponIconStyle:
	var s := DotWeaponIconStyle.new()
	s.tags = TAGS
	return s
