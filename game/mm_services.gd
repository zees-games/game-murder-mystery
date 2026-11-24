extends GSPlayerGameServices

const MmGame := preload("mm_game.gd")
const MmNetBridge := preload("net/mm_net_bridge.gd")

## Chat, voice and moderation, wired to this game's sides. Short because [GSGameServices] holds the rest: what is left
## is who can hear whom, and where somebody is standing. [b]No team channel, because a team is a secret[/b]: it would
## tell everybody who is on which side. So chat is everybody, near and whisper, and the router sees the public side ([method _team_of]).

# No `const CHANNEL`: [GSGameServices] declares one and GDScript refuses a redeclaration,
# which is the right refusal — one layer, one channel an operator can turn up.

const CH_ALL := &"all"
const CH_NEAR := &"near"
const CH_ADMIN := &"admin"
const CH_WHISPER := &"whisper"

## Metres a shout carries: about two rooms.
const PROXIMITY_RANGE := 20.0

func _services_name() -> String:
	return "murder"


func _chat_rules() -> Object:
	return chat_rules()


## The same rules, as a static a CLIENT can ask for without building a services layer. [b]Static because the other end
## must not instantiate this[/b]: a services layer is a [Node] with a store and a router, and a client calling `new()`
## would leak it and, inside a delivered pack, fail to compile (a base class in the HOST build). Measured in game-buses-from-hell.
static func chat_rules() -> GSChatRules:
	var rules := GSChatRules.new()
	rules.max_length = 140
	rules.refuse_over_length = false
	rules.allow_newlines = false
	rules.escape_markup = true
	rules.strip_invisible = true
	rules.collapse_whitespace = true
	rules.rate_per_minute = 22
	rules.burst = 4.0
	rules.flood_penalty_sec = 10.0
	rules.duplicate_window_sec = 8.0
	rules.duplicate_depth = 3
	rules.command_prefixes = PackedStringArray(["!", "/"])
	# An unclaimed `!command` is not broadcast: a player typing `!ban` at a server with no
	# such command would otherwise say "!ban" to everybody, which is worse than nothing
	# happening.
	rules.broadcast_unknown_commands = false
	rules.history_limit = 300
	return rules


func _chat_channels() -> Array:
	return chat_channels()


static func chat_channels() -> Array[GSChatChannel]:
	var out: Array[GSChatChannel] = []

	var everyone := GSChatChannel.make(CH_ALL, "All", GSChatChannel.Scope.EVERYONE)
	everyone.colour = Color(0.93, 0.94, 0.96)
	# Short, because a round is a few minutes: a backlog longer than the round is a
	# conversation from a game the new player was not in.
	everyone.backlog = 10
	everyone.history_limit = 200
	out.append(everyone)

	var near := GSChatChannel.make(CH_NEAR, "Near", GSChatChannel.Scope.RADIUS)
	near.prefix = "[near]"
	near.colour = Color(0.82, 0.86, 0.72)
	near.radius = PROXIMITY_RANGE
	near.backlog = 0
	near.history_limit = 80
	out.append(near)

	var admin := GSChatChannel.make(CH_ADMIN, "Admin", GSChatChannel.Scope.EVERYONE)
	admin.prefix = "[ADMIN]"
	admin.colour = Color(0.98, 0.72, 0.35)
	admin.admin_only = true
	# A gag is about a player's speech; an admin who has been gagged has a bigger problem
	# than chat.
	admin.ignores_gag = true
	admin.backlog = 0
	out.append(admin)

	var whisper := GSChatChannel.make(CH_WHISPER, "Whisper", GSChatChannel.Scope.DIRECT)
	whisper.prefix = "[w]"
	whisper.colour = Color(0.78, 0.71, 0.93)
	whisper.backlog = 0
	out.append(whisper)

	return out


## The voice format, which both ends must agree on exactly. Static, because the CLIENT builds one too, and a sample
## rate that differs is a stream of packets the router refuses for the wrong length, said to nobody.
## [method GSVoiceConfig.format_fingerprint] exists for that reason.
static func voice_format() -> GSVoiceConfig:
	var config := GSVoiceConfig.new()
	config.sample_rate = 16000
	config.frame_ms = 20.0
	config.codec_id = &"adpcm"
	# [b]Push to talk, because an open microphone in a quiet house is a footstep that tells a
	# murderer where you are.[/b]
	config.push_to_talk = true
	config.activation_rms = 0.02
	config.hangover_ms = 250.0
	config.jitter_ms = 60.0
	config.jitter_max_ms = 400.0
	config.proximity_range = PROXIMITY_RANGE
	config.max_bytes_per_second = 6144
	return config


func _voice_config() -> Object:
	return voice_format()


## Voice carries as far as a voice does: a room or two. Team voice would be a team channel,
## which this game cannot have (see the header).
func _voice_default_channel() -> int:
	return GSVoiceRouter.Channel.PROXIMITY


## Which side somebody is on, as the router may know it: the public side, the same for everybody in the round, so a team
## scope reaches the whole round and tells nobody anything. [b]Read off the game, not cached, because sides change
## between rounds[/b]: a cached team id would put a player in last round's conversation.
func _team_of(peer_id: int) -> int:
	var player := _player_of(peer_id)
	return MmNetBridge.public_side((game as MmGame).team_of(player.player_id)) if player != null else 0


## Where a body starts again is the game's; the rest of the admin set is [GSPlayerGameServices]'s.
func _mod_extra_abilities() -> Dictionary:
	return {
		"respawn": func(id: StringName, _args: Dictionary) -> GSResult:
			var p := _mod_player(id)
			var field := game as MmGame
			if p == null or field == null or field.map == null or field.map.doc.is_empty():
				return _mod_absent(id)
			var spot: Array = field.map.spawn(MmGame.SPAWN_GROUP, 0)
			p.reset_round()
			p.watching = false
			if p.health != null:
				p.health.health = p.health.max_health
				p.health.alive = true
				p.health.invulnerable = false
			p.place_at(spot[0], spot[1])
			if field.spectate != null:
				field.spectate.spawned(p.player_id)
			return GSResult.success(spot[0]),
	}


func _mod_unsupported() -> Dictionary:
	return {
		"give": "nobody here carries anything",
		"strip": "nobody here carries anything",
		"burn": "nothing here burns",
	}

