extends "mm_module_config.gd"


## Joins the bridge's chat seam to the services layer's router.
##
## [b]Here rather than in either of them, because this is the only object that holds
## both.[/b] The bridge knows what arrived on the wire and nothing about what a line means;
## the services layer knows the rules and nothing about the wire. That separation is why a
## client cannot send a line with somebody else's name on it: what crosses is a channel id
## and a string, and everything else is decided on this side.
func _wire_chat() -> void:
	if bridge == null or services == null:
		return

	bridge.connect("say_requested", _on_say_requested)
	services.connect("command_entered", _on_chat_command)

	var world := game as MmGame
	if world != null:
		world.bot_said.connect(_on_bot_said)


## A stand-in's line (mm_bot_chat.gd), to everybody, as "Name: text". Through the server's
## announcement rather than as a player, because a stand-in has no peer to say it from.
func _on_bot_said(player_id: StringName, text: String) -> void:
	var world := game as MmGame
	var chat: Object = services.get("chat") if services != null else null
	var who: MmPlayer = world.players.get(player_id) if world != null else null

	if chat == null or who == null:
		return

	var _said: Variant = chat.call("announce", "%s: %s" % [who.display_name, text], MmServices.CH_ALL)


## The players' vote for the next map, over dot-vote: `!vote`, `!rtv`, `!nominate`.
##
## [b]Opened [member MmVote.open_after_sec] into the last round on a map and applied when that
## round ends[/b]; see [code]game/mm_vote.gd[/code]. A server owner turns it off or reshapes it
## in `user://cfg/murder_vote.json` or `game.yml`'s `metadata: map_vote:`, keyed as dot-vote's
## [DotVoteRules]. A vote that cannot be built is a WARN and the rotation alone, never a server
## that will not start.
func _build_vote(world: MmGame) -> void:
	if world.catalogue == null:
		return

	vote = MmVote.new()
	vote.name = "MapVote"
	_wire_vote_callbacks(world)
	# Whether a round is live, for `time_up: finish_round`: warmup and the gap between rounds
	# have nothing to play out, so a limit that runs out there changes at once. No match is
	# "cannot tell", which holds as before.
	vote.round_in_progress_fn = func() -> bool:
		return world.match_node == null or world.match_node.is_live()

	add_child(vote)
	var ready := vote.setup()

	if not ready.ok:
		DotLog.result(CHANNEL, "the map vote; the rotation alone chooses", ready)
		vote.queue_free()
		vote = null
		return

	vote.commands_spec_fn = world.rotation_commands
	var commanded := vote.install_commands(self)
	DotLog.result(CHANNEL, "the map vote's commands", commanded)

	# The map menu (M), dot-vote's: a player holding the owner's `sv_map_menu_flag` changes the
	# map now, not after its rounds, and sees the same rows a solo player does. Read by name,
	# because a server on a dot-vote older than the menu has no `map_menu` and runs without it.
	var menu_half: Variant = vote.commands.get(&"map_menu") if vote.commands != null else null
	if menu_half is Object:
		(menu_half as Object).set(&"change_fn", world.change_map_now)
		(menu_half as Object).set(&"rows_fn", func(_rows: Array) -> Array: return world.map_rows())

	_tunable("mm_vote_after", vote.open_after_sec,
		"Seconds into the last round on a map before the vote for the next one opens",
		func(value: float) -> void:
			if vote != null:
				vote.open_after_sec = maxf(value, 0.0))
	_wire_vote_events(world)


## What the vote asks of the world and the server.
func _wire_vote_callbacks(world: MmGame) -> void:
	vote.maps_fn = func() -> Array:
		var out: Array = []

		for id in world.catalogue.playable(world.config.map_ids):
			# maps.yml's rotation decides the ballot; a map it leaves out is still installed.
			if not world.in_rotation(id):
				continue
			out.append([id, str((world.catalogue.maps.get(id, {}) as Dictionary).get("name", id))])

		return out
	vote.apply_fn = func(id: StringName) -> DotResult:
		world.next_map_id = id
		return DotResult.success(id)
	vote.due_fn = func() -> bool:
		return world.rounds_left_on_map() <= 1
	vote.voters_fn = func() -> Array:
		var out: Array = []

		for id: Variant in world.players:
			var player: MmPlayer = world.players[id]

			if player == null or player.is_bot:
				continue

			var userid := MmNetBridge.session_of(StringName(str(id)))

			if userid > 0:
				out.append(StringName(str(userid)))

		return out
	vote.announce_fn = func(line: String) -> void:
		var chat: Object = services.get("chat") if services != null else null

		if chat != null:
			var _said: Variant = chat.call("announce", line, MmServices.CH_ALL)
		elif server != null:
			server.broadcast_message(line)
	vote.is_admin_fn = func(voter: StringName) -> bool:
		var session := server.session_by_userid(String(voter).to_int()) if server != null else null
		return session != null and session.has_permission(DotAdminFlags.CHANGEMAP)
	vote.ballot_fn = func(state: Dictionary) -> void:
		if server == null:
			return

		for session in server.playing_sessions():
			var data := state.duplicate()
			data["you"] = str(session.userid)
			server.send_notice(session, DotNotice.make(
				&"", "", float(state.get("seconds", -1.0)), MAP_BALLOT_TOPIC, data
			))
	vote.people_fn = func(voter: StringName) -> Dictionary:
		var session := server.session_by_userid(String(voter).to_int()) if server != null else null

		if session == null:
			return {}

		var avatar: Variant = session.identity.get("avatar_url") if session.identity != null else ""
		return {"name": session.display_name, "avatar": avatar if avatar is String else ""}


## What the world and the server tell the vote.
func _wire_vote_events(world: MmGame) -> void:
	world.world_rebuilt.connect(func() -> void:
		if vote != null and world.map != null:
			vote.note_map(world.map.id())
	)
	world.round_began.connect(func(_number: int, _map: StringName) -> void:
		if vote != null:
			vote.note_round_start()
	)
	world.match_node.round_ended.connect(func(_number: int, _winner: int, _outcome: int) -> void:
		if vote != null:
			vote.note_round_end()
	)

	if server != null:
		server.client_disconnected.connect(func(session: DotClientSession, _reason: String) -> void:
			if vote != null:
				vote.forget_voter(StringName(str(session.userid)))
		)


## The map is what a server listing prints, reported on every rebuild: the server forgets it
## whenever a game unloads, and a browser showing last round's map is a browser lying.
func _wire_map(world: MmGame) -> void:
	if world.map != null and not world.map.doc.is_empty():
		report_map(String(world.map.id()))

	world.world_rebuilt.connect(func() -> void:
		report_map(String(world.map.id()))
	)


## An achievement is told to the one person who earned it.
##
## [b]As a notice, which a client already draws in its chat box[/b], rather than a new event
## kind: an unlock is text for one player, which is exactly what a notice is — and a stand-in
## never earns one, because [MmProgress] does not count them.
func _wire_progress(world: MmGame) -> void:
	if bridge == null:
		return

	# What a player keeps is filed under their scoped profile key, so it outlives the
	# connection; see [MmProgress]. Nothing for a stand-in or a guest, who keep their seat's.
	if world.progress != null:
		world.progress.durable_key_fn = func(id: StringName) -> String:
			var session := server.session_by_userid(MmNetBridge.session_of(id)) \
				if server != null else null
			var platform: Object = server.modules.get_module("platform") \
				if server != null and server.modules != null else null

			if session == null or platform == null or not platform.has_method("player_for"):
				return ""

			var held: Variant = platform.call("player_for", session)
			return str((held as Object).call("key")) if held is Object else ""

	world.achievement_earned.connect(func(id: StringName, title: String, points: int) -> void:
		var peer_id: int = bridge.call("peer_for_player", MmNetBridge.session_of(id))

		if peer_id > 0:
			bridge.call("notice", peer_id, "Achievement: %s (+%d)" % [title, points])
	)


func _on_say_requested(peer_id: int, channel_id: StringName, text: String) -> void:
	var said: DotResult = services.call("say", peer_id, channel_id, text)

	if said.ok:
		return

	# Back to the one person who asked. A refusal broadcast would be a rate limit announced
	# to the server.
	bridge.call("notice", peer_id, said.error.message)


## A `!command` typed into chat. Run through the console as the person who typed it.
##
## [b]As THEM, not as the server.[/b] `run_command_as_uid` builds a context with that
## player's own flags, so `!kick` from somebody without the flag is refused by the same file
## that refuses it at the console — rather than by this function having an opinion.
func _on_chat_command(peer_id: int, command: String, args: PackedStringArray) -> void:
	if server == null:
		return

	var session := server.session_of(peer_id)

	if session == null:
		return

	for reply in server.run_command_as_uid(
		session.uid(), command, args, DotCmdContext.Source.CHAT
	):
		bridge.call("notice", peer_id, reply)


## Who is what this round, for the operator. Answered on the server's own console only: from a
## player's chat or an rcon session it would be the one thing this game keeps secret.
func _cmd_roles(ctx: DotCmdContext) -> void:
	var world := game as MmGame

	if world == null:
		ctx.reply("No world.")
		return

	if ctx.source != DotCmdContext.Source.CONSOLE and ctx.source != DotCmdContext.Source.INTERNAL:
		ctx.reply("Roles are secret; only the server's own console can list them.")
		return

	for id: StringName in world.players:
		var p: MmPlayer = world.players[id]
		var role := "murderer" if world.team_of(id) == MmGame.MURDERERS else (
			"gunner" if p.has_gun else ("bystander" if world.team_of(id) == MmGame.BYSTANDERS else "-"))
		ctx.reply("  %-10s %-18s %-10s %s" % [String(id), p.display_name, role, "alive" if p.is_alive() else "out"])


func _cmd_say(ctx: DotCmdContext) -> void:
	var text := ctx.rest()

	if text.strip_edges() == "":
		ctx.reply("Say what?")
		return

	if services == null or services.get("chat") == null:
		ctx.reply("This server has no chat.")
		return

	var announced: Variant = services.get("chat").call("announce", text, MmServices.CH_ALL)

	if announced is DotResult and not (announced as DotResult).ok:
		ctx.reply_error(announced)
		return

	ctx.reply("Said: %s" % text)


func _cmd_status(ctx: DotCmdContext) -> void:
	var world := game as MmGame

	if world == null:
		ctx.reply("No world.")
		return

	ctx.reply_lines(world.describe_lines())


func _cmd_net(ctx: DotCmdContext) -> void:
	if bridge == null:
		ctx.reply("No bridge; this server is not replicating anything.")
		return

	ctx.reply_lines(bridge.call("describe_lines"))

	if services != null:
		ctx.reply_lines(services.call("describe_lines"))


## maps.yml's `names:` for this game's own commands, role to name or list of names.
func _renames(world: MmGame) -> Dictionary:
	return (world.rotation_commands().get("names", {}) as Dictionary)


func _cmd_maps(ctx: DotCmdContext) -> void:
	var world := game as MmGame

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	ctx.reply_lines(world.catalogue.describe_lines(world.in_rotation))
	ctx.reply("playing: %s" % str(world.map_doc.get("id", "-")))


func _cmd_map(ctx: DotCmdContext) -> void:
	var world := game as MmGame
	var id := StringName(ctx.arg(0)) if ctx.argc() > 0 else &""

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	if id == &"" or not world.catalogue.playable(world.config.map_ids).has(id):
		ctx.reply("Which map? %s" % ", ".join(world.catalogue.playable(world.config.map_ids)))
		return

	world.next_map_id = id
	ctx.reply("%s is next, from the end of this round." % String(id))


func _cmd_reload(ctx: DotCmdContext) -> void:
	var world := game as MmGame

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	var loaded := world.catalogue.load_from(world.config.map_directory)
	loaded += await _add_delivered_maps(world)
	var _rotation := world.load_rotation()

	if vote != null:
		vote.refresh_maps()

	ctx.reply("%d documents read; %d refused. The next map draws from them." % [
		loaded, world.catalogue.refused.size()])


## This game's columns on the Tab board: the points, and the PUBLIC side (everybody in the round
## is the same), because the board is sent to every client.
func _game_board_fields(session: Object) -> Dictionary:
	var world := game as MmGame
	var who: MmPlayer = world.players.get(MmNetBridge.player_key(int(session.get(&"userid")))) if world != null and session != null else null

	if who == null:
		return {}

	return {"points": who.points, "team": MmNetBridge.public_side(world.team_of(who.player_id))}


func describe() -> Dictionary:
	var out := super.describe()
	var world := game as MmGame

	if world != null:
		out.merge({"round": world.round_number, "world": world.describe()}, true)

	return out
