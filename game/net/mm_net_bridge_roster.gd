extends "mm_net_bridge_entities.gd"

## Seating and leaving in [code]mm_net_bridge.gd[/code]: who is admitted, told their role, and let go.
## Path-based base, no class_name.

## Puts a connected peer into the game. What [DotGameRoster] calls.
func add_player(peer_id: int, session_id: int, display_name: String) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server adds players.")

	if peer_id > 0:
		# FIRST, because `game.add_player` emits `player_added` and the handler has to be
		# able to find which peer this player belongs to.
		_player_of_peer[peer_id] = session_id
		_peer_of_player[session_id] = peer_id

	var player := game.add_player(player_key(session_id), display_name)

	if player == null:
		_player_of_peer.erase(peer_id)
		_peer_of_player.erase(session_id)
		return DotResult.fail(DotError.CODE_STATE, "The game refused the player.")

	if _ready_unseated.has(peer_id):
		_ready_unseated.erase(peer_id)
		_admit(peer_id)

	return DotResult.success(player)


## Somebody the world drives itself: a stand-in, or a test's player.
##
## [b]The same entity a peer gets, with a peer id of zero.[/b] A bot is replicated, scored
## and crushed exactly like a person — what it does not have is a socket — and that is the
## whole of the difference.
func add_bot(display_name: String, team: int = 0) -> MmPlayer:
	if net == null or not net.is_server or game == null:
		return null

	var session_id := _next_bot_session
	_next_bot_session += 1

	var player := game.add_player(player_key(session_id), display_name, team)

	if player == null:
		return null

	player.is_bot = true
	return player


func remove_peer(peer_id: int) -> void:
	_ready_unseated.erase(peer_id)

	if _player_of_peer.has(peer_id):
		remove_player(int(_player_of_peer[peer_id]))


## Removes a player whether or not a peer is behind it — a bot has none.
func remove_player(session_id: int) -> void:
	if not _behaviours.has(session_id):
		return

	var peer_id := peer_for_player(session_id)
	var was_ready := _ready_peers.has(peer_id)

	_player_of_peer.erase(peer_id)
	_peer_of_player.erase(session_id)
	_ready_peers.erase(peer_id)

	# Released BEFORE the game is told: `game.remove_player` emits `player_removed`, which
	# `_on_player_removed` answers by releasing the entity and broadcasting the LEAVE.
	# Releasing first empties `_behaviours`, so that handler finds nothing and this stays
	# the one place a leaving player is announced.
	_release_entity(session_id)
	game.remove_player(player_key(session_id))

	if net != null and peer_id > 0:
		if was_ready:
			net.remove_peer(peer_id)

		if net.interest != null:
			net.interest.forget_peer(peer_id)

	_broadcast(MmEvents.Kind.LEAVE, MmEvents.write_player(session_id))
	roster_changed.emit(session_id)


## Everything in the world, to one peer, once its own copy exists.
##
## [b]On READY and not on connect, and the difference is a whole join's worth of
## messages.[/b] dot-server's signon finishes and THEN the client builds its scene; a server
## that started talking at connect is one whose JOIN and MAP land on a node that does not
## exist yet and are lost, one "Node not found" per call.
func _admit(peer_id: int) -> void:
	if peer_id <= 0:
		return

	if not _player_of_peer.has(peer_id):
		_ready_unseated[peer_id] = true
		return

	_ready_peers[peer_id] = true

	if not net.peers().has(peer_id):
		net.add_peer(peer_id)

	if profile_link != null:
		profile_link.peer_joined(peer_id)

	var session_id := int(_player_of_peer[peer_id])

	_tell(peer_id, MmEvents.Kind.HELLO, MmEvents.write_hello(
		session_id,
		game.tick_rate,
		net.clock.tick,
		game.grace_limit(),
		game.round_limit(),
		game.config.gun_cooldown,
		game.melee_cooldown()
	))

	# The map, before anything that stands on it.
	if not _map_body.is_empty():
		_tell(peer_id, MmEvents.Kind.MAP, _map_body)

	if not _toys_body.is_empty():
		_tell(peer_id, MmEvents.Kind.TOYS, _toys_body)

	for other in _behaviours.keys():
		_tell(peer_id, MmEvents.Kind.JOIN, _join_body(int(other)))

	_tell(peer_id, MmEvents.Kind.PHASE, MmEvents.write_phase(game.phase))
	_tell(peer_id, MmEvents.Kind.CLOCK, _clock_body())

	# Their own role, if they have one this round (a reconnect), and the guns on the floor.
	_tell_role(session_id)

	for drop_id: int in game.gun_drops:
		_tell(peer_id, MmEvents.Kind.GUN, MmEvents.write_gun(drop_id, true, game.gun_drops[drop_id]["at"]))

	# Every door that has moved this round, with the tick it went: a joiner who was not told
	# would draw a door shut that is open, and predict themselves into it.
	if game.map != null and game.map.doors != null:
		var doors := game.map.doors

		for index in range(doors.count()):
			if int(doors.doors[index]["since"]) >= 0:
				_tell(peer_id, MmEvents.Kind.DOOR, MmEvents.write_door(
					index, doors.is_open(index), doors.is_flipped(index), int(doors.doors[index]["since"])))


func _join_body(session_id: int) -> PackedByteArray:
	var behaviour: MmPlayerNet = _behaviours.get(session_id)

	if behaviour == null or behaviour.identity == null or behaviour.player == null:
		return PackedByteArray()

	return MmEvents.write_join(
		session_id,
		behaviour.identity.net_id,
		behaviour.player.display_name,
		public_side(game.team_of(behaviour.player.player_id)),
		behaviour.player.avatar
	)


## Tells [param session_id]'s own peer their role, and nobody else. Nothing for a stand-in or a
## player sitting the round out.
func _tell_role(session_id: int) -> void:
	var id := player_key(session_id)
	var player: MmPlayer = game.players.get(id) if game != null else null
	var side := game.team_of(id) if game != null else 0

	if player == null or side <= 0 or game.phase == MmGame.Phase.IDLE:
		return

	var peer_id := peer_for_player(session_id)

	if peer_id > 0 and _ready_peers.has(peer_id):
		_tell(peer_id, MmEvents.Kind.ROLE, MmEvents.write_role(side, player.has_gun, player.weapon_id))


## Text for one player: a refusal, a rate limit, a command's reply.
##
## [b]To the one person who asked, and that is the whole reason this is a method.[/b] "You
## are talking too fast" and "you are gagged" are the two commonest things a server says,
## and both are nobody else's business — a broadcast refusal is a punishment announced to
## everybody.
func notice(peer_id: int, text: String) -> void:
	_tell(peer_id, MmEvents.Kind.NOTICE, MmEvents.write_notice(text))
