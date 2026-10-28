extends RefCounted

## Every key this game reads, as one [DotMenuBindings] table: the action, its setting, the words
## a player sees, the default and the card. The client, settings, Controls page and help read it.
## H is help in every game (dot-menu adds the row), so nothing here defaults to it.

const ATTACK := &"mm_attack"
const HOLSTER := &"mm_holster"
const VIEW := &"mm_view"
const SCOREBOARD := &"mm_scoreboard"
const USE := &"mm_use"
## The spectator's free camera, on and off (`mp_freeroam`). Its flying keys are the movement keys.
const ROAM := &"mm_roam"
## dot-ui's chat window's actions, which dot-game's chat client leaves at their defaults.
const CHAT := &"chat_open"


static func make() -> DotMenuBindings:
	var keys := DotMenuBindings.new()
	keys.add_movement("Movement", "Ctrl", "Crouch")
	# dot-player-controller's own sprint and walk actions, as rows so the Controls page and the
	# help screen have them; until 2026-10-11 they were only the sampler's defaults.
	keys.add(&"dot_fps_sprint", &"bind_sprint", "Sprint", "Shift", "Movement")
	keys.add(&"dot_fps_walk", &"bind_walk", "Walk quietly", "Alt", "Movement")
	keys.add(USE, &"bind_use", "Open or shut a door", "E", "General")
	keys.add(ATTACK, &"bind_attack", "Stab or shoot", "Mouse 1", "Weapons")
	keys.add(HOLSTER, &"bind_holster", "Draw or put away the weapon (murderer)", "Q", "Weapons")
	keys.add(CHAT, &"bind_chat", "Chat", "Y", "Communication")
	keys.add(VIEW, &"bind_view", "First or third person", "F5", "General")
	keys.add(ROAM, &"bind_roam", "Free camera while out (move keys fly, Sprint fast, Walk slow)", "G", "General")
	keys.add(SCOREBOARD, &"bind_scoreboard", "Scoreboard (hold)", "Tab", "General")
	return keys
