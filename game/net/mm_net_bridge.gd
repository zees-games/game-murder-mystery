extends "mm_net_bridge_events.gd"

## Joins an [MmGame] to a [DotNetManager]: the netcode seam, and the only file here that names
## both. The map crosses once in `MAP`; per tick only who is alive and what is in a hand
## ([MmPlayerNet]); no message carries anybody's role but its owner's (docs/design.md). The
## world ticks once per tick, in the first behaviour through ([method ensure_game_ticked]).


func _exit_tree() -> void:
	# The link and the runtime hold each other through broadcast; left, both outlive the process's exit.
	if profile_link != null:
		profile_link.release()
		profile_link = null


## [param p_game] and [param p_net], in the shape [DotGameNetcode] calls it.
func attach(p_game: Object, p_net: DotNetManager) -> DotResult:
	var world := p_game as MmGame

	if world == null or p_net == null:
		return DotResult.fail(DotError.CODE_INVALID, "A bridge needs a world and a manager.")

	if world.authoritative != p_net.is_server:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The world and the manager disagree about who is authoritative.",
			"world=%s net.is_server=%s" % [world.authoritative, p_net.is_server]
		)

	game = world
	net = p_net

	_entities = Node.new()
	_entities.name = "Entities"
	add_child(_entities)

	net.send_fn = _send

	var event := net.messages.register(
		MmEvent.NAME, MmEvent,
		DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_CLIENT
	)

	if not event.ok:
		return event

	var request := net.messages.register(
		MmRequest.NAME, MmRequest,
		DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_SERVER
	)

	if not request.ok:
		return request

	net.messages.on(MmEvent.NAME, _on_event)
	net.messages.on(MmRequest.NAME, _on_request)

	# Edited profiles reach every client, so a remote admin's panel shows what the server holds; edits themselves go through the remote workbench.
	profile_link = DotNetProfileLink.attach(net, world.ensure_runtime())

	# Both ends. The server's tick is `server_tick` and the client's is `client_tick`, which
	# simulates what it predicts and leaves the rest to interpolation. A world still running
	# its own `_physics_process` would move every player twice.
	game.external_tick = true

	# The old map's toys: the server's leave the registry before their nodes go; a client's
	# mirrors stay registered without them, and are handed the new map's when it is built.
	if net.is_server:
		game.world_clearing.connect(_release_toys)
	else:
		game.world_clearing.connect(_unpair_toys)
		game.world_rebuilt.connect(_pair_pending_toys)

	if net.is_server:
		_connect_server_signals()

	return DotResult.success(true)


func _connect_server_signals() -> void:
	game.player_added.connect(_on_player_added)
	game.player_removed.connect(_on_player_removed)
	game.world_rebuilt.connect(_on_world_rebuilt)
	game.round_began.connect(_on_round_began)
	game.round_over.connect(_on_round_over)
	game.phase_changed.connect(_on_phase_changed)
	game.player_died.connect(_on_player_died)
	game.side_changed.connect(func(id: StringName, side: int) -> void:
		_broadcast(MmEvents.Kind.TEAM, MmEvents.write_team(session_of(id), public_side(side)))
	)
	game.role_drawn.connect(func(id: StringName, _side: int, _gun: bool) -> void:
		_tell_role(session_of(id)))
	game.shot.connect(func(by: StringName, from: Vector3, to: Vector3, hit: StringName) -> void:
		_broadcast(MmEvents.Kind.SHOT, MmEvents.write_shot(session_of(by), from, to, hit != &"")))
	game.gun_dropped.connect(func(drop_id: int, at: Vector3) -> void:
		_broadcast(MmEvents.Kind.GUN, MmEvents.write_gun(drop_id, true, at)))
	game.gun_taken.connect(func(drop_id: int, _by: StringName) -> void:
		_broadcast(MmEvents.Kind.GUN, MmEvents.write_gun(drop_id, false, Vector3.ZERO)))
	game.door_used.connect(func(index: int, open: bool, flip: bool, tick: int, _by: StringName) -> void:
		_broadcast(MmEvents.Kind.DOOR, MmEvents.write_door(index, open, flip, tick)))
	# To the one who asked, never broadcast: a refusal is that person's business.
	game.refused.connect(func(id: StringName, why: String) -> void:
		var peer_id := peer_for_player(session_of(id))
		if peer_id > 0:
			notice(peer_id, why))
	if game.spectate != null:
		game.spectate.view_changed.connect(_on_spectate_changed)


## Opens the link under [param parent], whose NAME is half the RPC routing.
##
## A [DotServer] on one end and a [DotClientLink] on the other, both called `Server`, with
## this node under each: Godot routes an RPC by the receiver's node path, so a link opened
## anywhere else is addressed by a path the other end does not have and every message lands
## nowhere, with no error on either side.
func open_link(parent: Node) -> void:
	if parent == null or link != null:
		return

	link = MmNetLink.attached_to(parent, self, net != null and net.is_server)
	# Not parent.add_child: the link must sit under `Server` (RPCs route by path) yet die with
	# this bridge. A bare add_child left a second link after every module reload, Godot renamed
	# the live one `@Node@n`, and RPCs to real clients were lost silently. DotGameLink frees it
	# with the bridge, and without remove_child, which errors while the server tree tears down.
	DotGameLink.attach(link, parent, self, MmNetLink.NODE_NAME)


func _on_player_added(id: StringName) -> void:
	if net == null or not net.is_server:
		return

	var session_id := session_of(id)

	if _behaviours.has(session_id):
		return

	# [b]Every id on the wire is `u<session>`, and anything else parses back to zero.[/b] A
	# world that added a player called `bot` would replicate it under session 0 — which is
	# also dot-net's broadcast address — and a second one would silently replace the first
	# in this table. Refused with a line rather than accepted quietly: the symptom otherwise
	# is one stand-in playing and the other standing still for ever.
	if player_key(session_id) != id:
		DotLog.warn(CHANNEL, "a player whose id is not a session key is not replicated", {
			"id": String(id), "hint": "use add_bot() or MmNetBridge.player_key()",
		})
		return

	var player: MmPlayer = game.players.get(id)

	if player == null:
		return

	var identity := _build_entity(player, peer_for_player(session_id))
	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a player", {"error": str(registered.error)})
		return

	# Before the JOIN, so the first thing anybody hears about this person is their face.
	if player.avatar == null and avatar_fn.is_valid():
		var avatar: Variant = avatar_fn.call(session_id)
		player.avatar = avatar as DotAvatar if avatar is DotAvatar else null

	_broadcast(MmEvents.Kind.JOIN, _join_body(session_id))
	roster_changed.emit(session_id)


func _on_player_removed(id: StringName) -> void:
	var session_id := session_of(id)

	if _behaviours.has(session_id):
		# The game removed them itself; the entity and the LEAVE are still ours.
		_release_entity(session_id)
		_broadcast(MmEvents.Kind.LEAVE, MmEvents.write_player(session_id))
		roster_changed.emit(session_id)


## A new map: the whole document, to everybody, before anything that stands on it.
func _on_world_rebuilt() -> void:
	if net == null or not net.is_server or game.map == null or game.map.doc.is_empty():
		return

	var encoded := MmMapDoc.encode(game.map.doc)

	if encoded.size() > MmMapDoc.WIRE_LIMIT:
		# Sent anyway: a client on a native transport will take it, and the line says why a
		# browser does not. A WebSocket message past its outbound buffer is never delivered.
		DotLog.warn(CHANNEL, "a map is larger than a browser can be sent in one message", {
			"map": String(game.map.id()), "bytes": encoded.size(), "limit": MmMapDoc.WIRE_LIMIT,
		})

	_map_body = MmEvents.write_map(encoded)
	_broadcast(MmEvents.Kind.MAP, _map_body)
	_register_toys()


func _on_round_began(number: int, _layout_id: StringName) -> void:
	_broadcast(MmEvents.Kind.ROUND, MmEvents.write_round(number, true, 0))


func _on_round_over(number: int, winner: int, why: String) -> void:
	_broadcast(MmEvents.Kind.ROUND, MmEvents.write_round(number, false, winner, why))


func _on_phase_changed(phase: int) -> void:
	_broadcast(MmEvents.Kind.PHASE, MmEvents.write_phase(phase))


func _on_player_died(player_id: StringName, by: StringName, why: StringName) -> void:
	var who: MmPlayer = game.players.get(player_id) if game != null else null
	# [b]`by` is never sent.[/b] Who killed somebody is the one fact the round is about: a
	# DEATH that named the murderer would end the mystery on every client that read it. The
	# victim's own camera is told separately (SPECTATE carries the killer to that peer alone).
	# The way they died (stabbed, shot) is public: everybody nearby heard it.
	_broadcast(MmEvents.Kind.DEATH, MmEvents.write_death(
		session_of(player_id), 0, why,
		who.death if who != null else null
	))


## A view changed on the server. Told to its owner and to nobody else.
##
## [b]To the one peer, because a camera is private.[/b] Who somebody is watching is a fact
## about them that nobody else has any business knowing — and a stand-in, whose peer is
## zero, is told nothing, which `_tell` guarantees rather than this.
func _on_spectate_changed(player_id: StringName) -> void:
	if game == null or game.spectate == null or game.spectate.manager == null:
		return

	var session_id := session_of(player_id)
	var peer_id := peer_for_player(session_id)

	if peer_id <= 0 or not _ready_peers.has(peer_id):
		return

	var view := game.spectate.manager.view(String(player_id))
	var target := session_of(StringName(view.target)) if view.target != "" else 0
	var killer := session_of(StringName(view.killer)) if view.killer != "" else 0

	_tell(peer_id, MmEvents.Kind.SPECTATE, MmEvents.write_spectate(
		session_id, int(view.mode), target, killer, view.death_position
	))


func server_tick(tick: int) -> void:
	_tick = tick
	_game_ticked_for = -1

	if net != null:
		# The toys where the physics left them, before the snapshot goes.
		for behaviour: MmToyNet in _toy_nets:
			behaviour.pull()

		_in_server_tick = true
		net.server_tick(tick)
		_in_server_tick = false

		for net_id in _unregistered_in_tick:
			if not net.registry.has(net_id):
				net.history.forget(net_id)

		_unregistered_in_tick.clear()

	# Belt and braces: `net.server_tick` drives the entities, and the first player behaviour
	# through calls `ensure_game_ticked`. A server with nobody on it has no behaviours at
	# all, and a world that only ticked when somebody was connected is a server whose round
	# clock stops between players — which looks like the server having hung.
	ensure_game_ticked(tick)

	if tick % CLOCK_EVERY == 0:
		_broadcast(MmEvents.Kind.CLOCK, _clock_body())


func ensure_game_ticked(tick: int) -> void:
	if _game_ticked_for == tick or game == null:
		return

	_game_ticked_for = tick

	for session_id in _behaviours:
		var behaviour: MmPlayerNet = _behaviours[session_id]

		# Only what a peer sent. A bot has no peer and is driven by the game itself, and an
		# empty command applied over the top of that would stand it still.
		if behaviour.player != null and behaviour.identity != null \
				and behaviour.identity.owner_peer_id > 0:
			behaviour.player.controller.apply_command(behaviour.last_move.duplicate_command())
			behaviour.player.wants_use = behaviour.last_move.is_pressed(MmPlayer.USE_BUTTON)
			behaviour.player.wants_attack = behaviour.last_move.is_pressed(MmPlayer.ATTACK_BUTTON)
			behaviour.player.wants_holster = behaviour.last_move.is_pressed(MmPlayer.HOLSTER_BUTTON)
			behaviour.player.view_lag = behaviour.last_view_lag

	game.tick_once(tick)


## How far behind [param tick] this client is drawing everybody else, in quarter ticks: what the
## server rewinds the other bodies by when this tick's stab or shot fires. Remote players are
## drawn at the receive timeline less the interpolation delay, and the command is for a tick ahead
## of the server by the input lead, so the difference is the lead, the flight time and the
## interpolation delay. -1 when there is nothing to measure against yet.
func view_lag_q(tick: int) -> int:
	if net == null or net.interpolator == null or not net.clock.is_synced():
		return -1

	var drawn := float(net.clock.received_tick()) - net.interpolator.delay_ticks()
	return clampi(int(roundf((float(tick) - drawn) * 4.0)), 0, MmNetCommand.MAX_VIEW_LAG_Q)


func client_tick(tick: int, command: DotFpsCommand) -> void:
	if net == null or net.is_server or game == null:
		return

	_tick = tick

	var packet := MmNetCommand.new()
	packet.tick = tick
	packet.delta = net.clock.tick_duration()
	packet.move = command if command != null else DotFpsCommand.new()
	packet.view_lag_q = view_lag_q(tick)

	# Into the local history BEFORE predicting: reconciliation replays it.
	net.local_inputs().push(packet)

	# The behaviour simulates from `last_move` on a fresh tick and on a replayed one alike —
	# the predictor's replay sets it through `_net_apply_input`, and this is the fresh tick's
	# equivalent.
	var mine: MmPlayerNet = _behaviours.get(local_player_id)

	if mine != null:
		mine.last_move = packet.move

	if link != null:
		var payload := net.encode_ack()
		var writer := DotNetWriter.new()
		DotNetInput.write_batch(writer, _input_copies(packet))
		payload.append_array(writer.to_bytes())
		link.send_input(payload)

	# One predicted player, and nothing else: everybody else is drawn from snapshots. The
	# doors first, posed for this tick, because the player is predicted against them.
	if _client_ticked_for != tick:
		_client_ticked_for = tick

		if game.map != null and game.map.doors != null:
			game.map.doors.pose_at(tick)

		for identity in net.registry.predicted():
			for behaviour in identity.behaviours:
				behaviour._net_simulate(tick, net.clock.tick_duration())

		# The clock a client shows, advanced between the twice-a-second messages that
		# correct it. Without this the round timer ticks in half-second steps.
		game.phase_elapsed += net.clock.tick_duration()

		if game.phase == MmGame.Phase.PLAY:
			game.play_elapsed += net.clock.tick_duration()


func receive_snapshot(payload: PackedByteArray) -> DotResult:
	if net == null or net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only a client receives these.")

	if rtt_source.is_valid():
		net.stats.note_rtt(float(rtt_source.call()))

	return net.receive_snapshot(payload)


## [param packet] and the commands before it from the local replay history, oldest first,
## for one input packet. See [constant INPUT_COPIES].
func _input_copies(packet: DotNetInput) -> Array:
	var batch: Array = Array(net.local_inputs().recent(INPUT_COPIES, packet.tick - 1))
	batch = batch.slice(maxi(0, batch.size() - (INPUT_COPIES - 1)))
	batch.append(packet)
	return batch


func receive_input(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server takes input.")

	if not _player_of_peer.has(peer_id):
		return DotResult.fail(DotError.CODE_FORBIDDEN, "That peer has no player.")

	if payload.size() <= ACK_BYTES:
		return DotResult.fail(DotError.CODE_PARSE, "Input packet is too short.")

	net.receive_ack_payload(peer_id, payload.slice(0, ACK_BYTES))

	# A batch: this tick's command and the ones before it (see [constant INPUT_COPIES]).
	# Copies of ticks already simulated are skipped rather than pushed, or each would count
	# as a late input; the packet's own tick is always pushed, so a late one still counts.
	var batch := DotNetInput.read_batch(
		DotNetReader.new(payload.slice(ACK_BYTES)),
		func() -> DotNetInput: return MmNetCommand.new()
	)
	if batch.is_empty():
		return DotResult.fail(DotError.CODE_PARSE, "Input packet carries no command.")
	var buffer := net.input_buffer_for(peer_id)
	var newest := batch[batch.size() - 1]
	var pushed := DotResult.success(false)
	for input in batch:
		if input != newest and input.tick <= buffer.last_consumed_tick():
			continue
		pushed = buffer.push(input)
	return pushed


## One routed line to one peer. What [DotGameServices] sends through, via the link.
func send_chat(peer_id: int, wire: Dictionary) -> void:
	_tell(peer_id, MmEvents.Kind.CHAT, MmEvents.write_chat(wire))


## A voice frame, in whichever direction.
##
## [b]Not a [MmEvent].[/b] Voice is fifty packets a second and every event here is reliable,
## so a talk spurt would put a hundred retransmittable messages in front of a shot. It also does not go through [DotNetManager]: the message registry seals a
## message set and hashes it, and adding a fifty-hertz opaque blob buys nothing — the packet
## has its own header, sequence and validation in [DotVoicePacket].
func receive_voice(peer_id: int, payload: PackedByteArray) -> DotResult:
	if payload.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "An empty voice frame.")

	if net != null and net.is_server:
		if peer_id <= 0 or player_for_peer(peer_id) == 0:
			# A peer with nobody in the world. Refused rather than relayed: the router
			# stamps the speaker from this id, so relaying one that belongs to nobody puts
			# a voice in the game with no name on it.
			return DotResult.fail(
				DotError.CODE_FORBIDDEN, "That peer has nobody in the world."
			)

		# [b]One path or the other, never both.[/b] [DotGameModule] assigns
		# `voice_relay_fn` to the services layer's `relay_voice`; a game that ALSO connected
		# `voice_requested` to the same router would relay every frame twice — a doubled
		# talk spurt, a doubled rate limit, and a sequence number the jitter buffer sees go
		# backwards.
		if voice_relay_fn.is_valid():
			voice_relay_fn.call(peer_id, payload)
		else:
			voice_requested.emit(peer_id, payload)

		return DotResult.success(null)

	voice_arrived.emit(payload)
	return DotResult.success(null)


func receive_event(payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")

	return net.receive(payload, 1)


func receive_request(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")

	return net.receive(payload, peer_id)


func _on_request(message: DotNetMessage) -> void:
	var ask := message as MmRequest

	if ask == null or net == null or not net.is_server:
		return

	# [b]From the message, which dot-net stamped from the TRANSPORT.[/b] A peer id inside a
	# body is a claim; `sender_peer_id` is what the socket said, which is the only version
	# of it a server may act on.
	var peer_id := ask.sender_peer_id

	match ask.kind:
		MmEvents.Ask.READY:
			_admit(peer_id)
		MmEvents.Ask.SAY:
			var said := MmEvents.read_say(ask.reader())

			if bool(said["ok"]):
				# Emitted rather than acted on: everything about what a line means is
				# [DotChatRouter]'s, and the router is the module's.
				say_requested.emit(
					peer_id, StringName(str(said["channel"])), str(said["text"])
				)
		MmEvents.Ask.SPECTATE:
			var step := MmEvents.read_ask_spectate(ask.reader())

			if bool(step["ok"]):
				_spectate_step(peer_id, int(step["direction"]))
		MmEvents.Ask.ROAM:
			_spectate_roam(peer_id)


## Somebody who is out asked to look at somebody else. The server's list, the server's rule.
##
## [b]A refusal goes back as a notice rather than being dropped.[/b] "This server only lets
## you watch your own side" is the answer to a key that did nothing, and a key that silently
## does nothing is reported as broken.
func _spectate_step(peer_id: int, direction: int) -> void:
	var session_id := player_for_peer(peer_id)

	if session_id == 0 or game.spectate == null:
		return

	var moved: DotResult = game.spectate.step(player_key(session_id), direction)

	if not moved.ok:
		notice(peer_id, moved.error.message)


## Somebody who is out pressed the free-roam key. The mode is the server's; the refusal
## ("Free roam is off on this server") goes back as a notice, like a refused step.
func _spectate_roam(peer_id: int) -> void:
	var session_id := player_for_peer(peer_id)

	if session_id == 0 or game.spectate == null:
		return

	var toggled: DotResult = game.spectate.toggle_roam(player_key(session_id))

	if not toggled.ok:
		notice(peer_id, toggled.error.message)


## Tells everybody who somebody is now: a profile that arrived after they were seated, a
## wardrobe change, an operator's rename. Server only.
##
## [b]Through JOIN, which a client already applies to a player it has.[/b] A second message
## for "this person changed" would be a second thing a joiner has to be told and a second
## order two of them can arrive in; a JOIN is idempotent and already carries all of it.
## An empty [param display_name] keeps the one they have.
func refresh_player(session_id: int, display_name: String, avatar: DotAvatar) -> bool:
	if net == null or not net.is_server or game == null:
		return false

	var player: MmPlayer = game.players.get(player_key(session_id))

	if player == null or not _behaviours.has(session_id):
		return false

	if display_name != "":
		player.display_name = display_name

	player.avatar = avatar
	_broadcast(MmEvents.Kind.JOIN, _join_body(session_id))
	return true


func ask_ready() -> void:
	_ask(MmEvents.Ask.READY, PackedByteArray([0]))


## Says something. The server decides what it means and who hears it.
func ask_say(channel_id: StringName, text: String) -> void:
	if text.strip_edges() == "":
		return

	_ask(MmEvents.Ask.SAY, MmEvents.write_say(channel_id, text))


## Out, and asking to watch somebody else: +1 next, -1 previous, 0 the other camera.
func ask_spectate(direction: int) -> void:
	_ask(MmEvents.Ask.SPECTATE, MmEvents.write_ask_spectate(direction))


func ask_roam() -> void:
	_ask(MmEvents.Ask.ROAM, MmEvents.write_ask_roam())


func send_voice(payload: PackedByteArray) -> void:
	if link != null and net != null and not net.is_server:
		link.send_voice(1, payload)


func _ask(kind: int, body: PackedByteArray) -> void:
	if net == null or net.is_server:
		return

	net.send(MmRequest.new(kind, body), 1)


func describe() -> Dictionary:
	var out := {
		"server": net != null and net.is_server,
		"players": _behaviours.size(),
		"ready_peers": _ready_peers.size(),
		"tick": _tick,
	}

	if not (net != null and net.is_server):
		out["local_player"] = local_player_id

	if link != null:
		out["link"] = link.describe()

	return out


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray([
		"bridge     %s" % ("server" if net != null and net.is_server else "client"),
		"players    %d" % _behaviours.size(),
		"peers      %d ready" % _ready_peers.size(),
		"tick       %d" % _tick,
	])

	if link != null:
		lines.append_array(link.describe_lines())

	return lines
