extends RefCounted

## Every key this game reads, as one [DotMenuBindings] table: the action, the setting that
## stores it, the words a player sees, the default, and the card it goes on.
##
## [b]A table, because four things read it:[/b] the client matches events against the actions,
## the settings document stores one binding per row, the menu's Controls page draws a key per
## row, and the help screen lists them with the key each is on now.
##
## [b]Short, on purpose.[/b] A murder round is walking about, looking and watching, all of which
## are the movement rows; what this game adds is the attack (the knife or the gun, whichever you
## hold), the holster, the doors, the view and the board.
##
## [b]H is help, in every game of the family[/b] (dot-menu adds the row), so nothing here
## may default to it.
##
## [b]Chat is two rows[/b] on dot-ui's chat window's own actions (Y to all, U to your side), so
## the help screen lists them and the Controls page moves them; until 2026-10-12 they were the
## window's defaults, on no page.

const ATTACK := &"mm_attack"
const HOLSTER := &"mm_holster"
const VIEW := &"mm_view"
const SCOREBOARD := &"mm_scoreboard"
const USE := &"mm_use"
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
	keys.add(SCOREBOARD, &"bind_scoreboard", "Scoreboard (hold)", "Tab", "General")
	return keys
