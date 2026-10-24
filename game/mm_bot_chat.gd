extends RefCounted

## What the stand-ins say in chat: canned lines by moment, a name filled in where one fits.
##
## [b]Rationed, or a lobby of bots is a wall of text.[/b] One line per bot every
## [member per_bot] seconds at most, one from anybody every [constant ANYBODY] seconds, and
## only some of the moments that could have one get it ([member chance]). A witness's warning
## is the exception to the chance (it always goes) but not to the spacing.
##
## [b]A murderer bot lies like anybody[/b]: it says what a bystander would, and never anything
## that gives it away. Its own lines are the bystanders' lines.

const ANYBODY := 2.5

## Seconds before one bot speaks again, and the chance it speaks when it may; the game sets both from its config.
var per_bot := 9.0
var chance := 0.45

const LINES := {
	&"start": ["good luck everyone", "stick together", "who has the gun?", "nobody go off alone", "here we go again"],
	&"group": ["over here", "come this way", "stay close", "safer in a group", "wait for me"],
	&"witness": ["%s has a knife!", "RUN, it's %s!", "%s is the murderer!", "I saw %s pull a weapon", "%s is armed, get away"],
	&"blood": ["%s is covered in blood", "why is %s bloody?", "look at %s's shirt"],
	&"body": ["did anyone see that?", "someone just died", "who was that?!", "there's a body here", "oh no"],
	&"suspect": ["I don't trust %s", "%s is acting weird", "keep an eye on %s", "where was %s just now?"],
	&"gun": ["I have the gun, stay near me", "I'll protect you", "I've got this"],
	&"pickup": ["got the gun", "I picked up the gun", "I'm armed now"],
	&"miss": ["missed!", "argh", "wrong one, sorry"],
	&"alone": ["where is everybody?", "hello?", "anyone?", "I'm all alone here"],
	&"innocent": ["it wasn't me", "I was with the others", "don't look at me"],
}

var _said_at: Dictionary = {}
var _any_at: float = -INF


## A line for [param moment] from [param who], with [param name] put in, or "" when the ration
## says not now. [param t] is the game's clock; [param stream] decides, so a seeded round says
## the same.
func line(who: StringName, moment: StringName, t: float, stream: DotRandomStream, name: String = "", always: bool = false) -> String:
	var pool: Array = LINES.get(moment, [])

	if pool.is_empty() or t - _any_at < ANYBODY or t - float(_said_at.get(who, -INF)) < per_bot:
		return ""

	if not always and stream.next_unit() > chance:
		return ""

	var text: String = pool[stream.next_range_i(0, pool.size() - 1)]

	if text.contains("%s"):
		if name == "":
			return ""
		text = text % name

	_said_at[who] = t
	_any_at = t
	return text


func reset() -> void:
	_said_at.clear()
	_any_at = -INF
