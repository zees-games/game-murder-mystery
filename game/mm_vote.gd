extends DotVoteRoundGame

## The players choose the next map: dot-vote's [DotVoteRoundGame] with Murder Mystery's names. A ballot opens into the LAST round on a
## map ([member due_fn]) and applies at its end; the rest is dot-vote's settings (`user://cfg/murder_vote.json`, `game.yml` metadata
## `map_vote:`). This game offers its own maps only: no Workshop `map_kind` is accepted.

const CHANNEL := "murder.vote"

const METADATA_KEY := "map_vote"

## What the vote command is called: `!vote 2` in chat, `vote 2` in a console.
const COMMAND_NAMES := {"vote": "vote"}


func _init() -> void:
	channel = CHANNEL
	metadata_key = METADATA_KEY
	command_names = COMMAND_NAMES.duplicate()
	config_path = "user://cfg/murder_vote.json"
