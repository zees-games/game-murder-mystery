extends "mm_net_bridge_roster.gd"

## What a client does with each event in [code]mm_net_bridge.gd[/code]: the server's word put on the mirrored
## world. Path-based base, no class_name.

func _on_event(message: DotNetMessage) -> void:
	var event := message as MmEvent

	if event == null or game == null or net == null or net.is_server:
		return

	var reader := event.reader()

	match event.kind:
		MmEvents.Kind.HELLO:
			_apply_hello(reader)
		MmEvents.Kind.MAP:
			_apply_map(reader)
		MmEvents.Kind.TOYS:
			_apply_toys(reader)
		MmEvents.Kind.JOIN:
			_apply_join(reader)
		MmEvents.Kind.LEAVE:
			_apply_leave(reader)
		MmEvents.Kind.TEAM:
			_apply_team(reader)
		MmEvents.Kind.CLOCK:
			_apply_clock(reader)
		MmEvents.Kind.ROUND:
			_apply_round(reader)
		MmEvents.Kind.PHASE:
			_apply_phase(reader)
		MmEvents.Kind.DEATH:
			_apply_death(reader)
		MmEvents.Kind.CHAT:
			var wire := MmEvents.read_chat(reader)

			if bool(wire["ok"]):
				chat_received.emit(wire)
		MmEvents.Kind.NOTICE:
			var text := MmEvents.read_notice(reader)

			if bool(text["ok"]):
				notice_received.emit(str(text["text"]))
		MmEvents.Kind.SPECTATE:
			_apply_spectate(reader)
		MmEvents.Kind.DOOR:
			_apply_door(reader)
		MmEvents.Kind.ROLE:
			_apply_role(reader)
		MmEvents.Kind.SHOT:
			var fired := MmEvents.read_shot(reader)

			if bool(fired["ok"]):
				shot_received.emit(int(fired["player_id"]), fired["from"], fired["to"], bool(fired["hit"]))
		MmEvents.Kind.GUN:
			_apply_gun(reader)


func _apply_leave(reader: DotNetReader) -> void:
	var session_id := MmEvents.read_player(reader)
	_release_entity(session_id)
	game.remove_player(player_key(session_id))
	roster_changed.emit(session_id)


func _apply_team(reader: DotNetReader) -> void:
	var side := MmEvents.read_team(reader)

	if bool(side["ok"]):
		var id := player_key(int(side["player_id"]))
		_adopt_side(id, int(side["team"]))

		roster_changed.emit(int(side["player_id"]))


func _apply_round(reader: DotNetReader) -> void:
	var round_info := MmEvents.read_round(reader)

	if not bool(round_info["ok"]):
		return

	game.round_number = int(round_info["round"])

	if not bool(round_info["began"]):
		# The round is over and so is the secret: the next draw sends a new ROLE.
		local_role = 0

	if bool(round_info["began"]):
		game.phase_elapsed = 0.0
		game.play_elapsed = 0.0

		# Every door home: the uses were last round's.
		if game.map != null and game.map.doors != null:
			game.map.doors.reset()

	round_changed.emit(
		int(round_info["round"]),
		bool(round_info["began"]),
		int(round_info["winner"]),
		str(round_info["why"])
	)


func _apply_phase(reader: DotNetReader) -> void:
	var moved := MmEvents.read_phase(reader)

	if bool(moved["ok"]):
		game.phase = int(moved["phase"])
		game.phase_elapsed = 0.0

		phase_received.emit(int(moved["phase"]))


func _apply_death(reader: DotNetReader) -> void:
	var death := MmEvents.read_death(reader)

	if bool(death["ok"]):
		# The fall goes on the player before anybody hears of the death, so the client
		# that draws it reads the server's pick.
		var fell: MmPlayer = game.players.get(player_key(int(death["player_id"]))) \
			if game != null else null
		if fell != null and death.has("death"):
			fell.death = death["death"]
		death_received.emit(
			int(death["player_id"]), int(death["by"]), death["why"]
		)


func _apply_spectate(reader: DotNetReader) -> void:
	var view := MmEvents.read_spectate(reader)

	if bool(view["ok"]) and game.spectate != null:
		game.spectate.apply_view(
			player_key(int(view["viewer"])),
			int(view["mode"]),
			player_key(int(view["target"])) if int(view["target"]) != 0 else &"",
			player_key(int(view["killer"])) if int(view["killer"]) != 0 else &"",
			view["death_at"]
		)
		spectate_received.emit(
			int(view["viewer"]), int(view["mode"]), int(view["target"])
		)


func _apply_door(reader: DotNetReader) -> void:
	var door := MmEvents.read_door(reader)

	if bool(door["ok"]) and game.map != null and game.map.doors != null \
			and int(door["index"]) < game.map.doors.count():
		game.apply_door(int(door["index"]), bool(door["open"]), bool(door["flip"]), int(door["tick"]))
		door_received.emit(int(door["index"]), bool(door["open"]), int(door["tick"]))


func _apply_role(reader: DotNetReader) -> void:
	var role := MmEvents.read_role(reader)

	if bool(role["ok"]):
		local_role = int(role["side"])
		# The weapon is the server's setting, the same for every murderer: every mirror
		# draws it when somebody shows one.
		for each: MmPlayer in game.players.values():
			each.weapon_id = role["weapon_id"]
		var mine: MmPlayer = game.players.get(player_key(local_player_id))
		if mine != null:
			mine.has_gun = bool(role["gun"])
		_adopt_side(player_key(local_player_id), local_role)
		role_received.emit(local_role, bool(role["gun"]), role["weapon_id"])


func _apply_gun(reader: DotNetReader) -> void:
	var gun := MmEvents.read_gun(reader)

	if bool(gun["ok"]):
		if bool(gun["down"]):
			game.gun_drops[int(gun["drop_id"])] = {"at": gun["at"], "dropped_by": &"", "since": 0.0}
		else:
			game.gun_drops.erase(int(gun["drop_id"]))
		gun_received.emit(int(gun["drop_id"]), bool(gun["down"]), gun["at"])


## A side from the wire, put on a mirrored player. [b]This client's own player keeps the role its
## ROLE said[/b]: the wire's TEAM and JOIN are the public side, a bystander for everybody.
func _adopt_side(id: StringName, side: int) -> void:
	if id == player_key(local_player_id) and local_role > 0 and side > 0:
		side = local_role

	game.sides[id] = side

	if game.players.has(id):
		var player: MmPlayer = game.players[id]
		player.team = side
		player.retune()


func _apply_hello(reader: DotNetReader) -> void:
	var hello := MmEvents.read_hello(reader)

	if not bool(hello["ok"]):
		return

	local_player_id = int(hello["player_id"])

	# The server's tick rate, before anything derives from it: the clock converts its error and
	# lead through `tick_rate`, and a one-process suite cannot see a wrong one.
	_adopt_tick_rate(int(hello["tick_rate"]))

	var rtt := float(rtt_source.call()) if rtt_source.is_valid() else 0.0
	net.clock.sync_from_server(int(hello["server_tick"]), maxf(0.0, rtt))

	game.config.grace_seconds = float(hello["grace_seconds"])
	game.config.round_seconds = float(hello["round_seconds"])
	game.config.gun_cooldown = float(hello["gun_cooldown"])
	game.config.melee_cooldown = float(hello["melee_cooldown"])

	_claim_local_player()

	hello_received.emit(local_player_id)


## Puts the whole client (world, controllers and the ENGINE) on the server's rate: a client at
## 60 against 128 ran the ticks in bursts and the camera lurched. A server never calls this:
## adopting a peer's rate would be a client telling the server how fast to run.
func _adopt_tick_rate(rate: int) -> void:
	if net == null or net.is_server or game == null or rate <= 0 or rate == game.tick_rate:
		return

	var before := game.tick_rate

	if not game.set_tick_rate(rate):
		return

	net.config.tick_rate = game.tick_rate
	# The LIVE one, which is built from the config back at `setup()` and is therefore not
	# updated by writing the config alone.
	net.clock.tick_rate = game.tick_rate
	# dot-net API 7 has DotNetClock.adopt_tick_rate(), which also raises the engine's step cap.
	# A shell built before it gets the same rule here; remove this branch when the oldest shell is API 7.
	if DotAddonApi.build_level("dot_net") >= 7:
		DotNetClock.adopt_tick_rate(game.tick_rate)
	else:
		Engine.max_physics_steps_per_frame = maxi(Engine.max_physics_steps_per_frame, ceili(0.25 * float(game.tick_rate)))
		Engine.physics_ticks_per_second = game.tick_rate

	DotLog.info(CHANNEL, "adopted the server's tick rate", {
		"was": before, "now": game.tick_rate, "engine": Engine.physics_ticks_per_second,
	})


## The map, which on a client is a document it builds exactly as the server did.
# Refused with a line, never half built: a client a format behind answers no map and a WARN, not a map with holes.
func _apply_map(reader: DotNetReader) -> void:
	var told := MmEvents.read_map(reader)

	if not bool(told["ok"]) or game == null:
		return

	var decoded := MmMapDoc.decode(told["encoded"])

	if not decoded.ok:
		DotLog.warn(CHANNEL, "the server sent a map this build cannot build", {
			"why": decoded.error.message, "detail": decoded.error.detail,
		})
		return

	var built := game.build_map(decoded.value)

	if built.ok:
		map_received.emit(game.map.id())


func _apply_join(reader: DotNetReader) -> void:
	var join := MmEvents.read_join(reader)

	if not bool(join["ok"]):
		return

	var session_id := int(join["player_id"])
	var id := player_key(session_id)
	var player: MmPlayer = game.players.get(id)

	if player == null:
		player = game.add_player(id, str(join["name"]), int(join["team"]))

		if player == null:
			return

		# A client never samples: the client loop hands it commands, and the local player is
		# the only one whose commands exist at all.
		player.sampler = null
		player.samples_input = false

		# This client's own player is owned by this client: JOIN carries no owner, and a mirror built with owner 0
		# left `registry.predicted()` empty. HELLO precedes JOIN; [method _apply_hello] claims a player that got here first.
		var identity := _build_entity(player, _mirror_owner(session_id))
		var registered := net.registry.register(
			identity, int(join["net_id"]), net.clock.tick, net.config
		)

		if not registered.ok:
			DotLog.warn(CHANNEL, "could not mirror a player", {"error": str(registered.error)})
			return
	else:
		player.display_name = str(join["name"])

	# Both branches: a JOIN for somebody this client already has is the server saying who
	# they are NOW — see [method refresh_player].
	player.avatar = join["avatar"]
	_adopt_side(id, int(join["team"]))
	roster_changed.emit(session_id)


## Who owns a mirrored player on this client: this client if it is its own player, the server's 0 otherwise.
# Never the local peer for anybody else, or this client would predict a person whose keys it never had.
func _mirror_owner(session_id: int) -> int:
	if net == null or net.local_peer_id <= 0:
		return 0

	if local_player_id != 0 and session_id == local_player_id:
		return net.local_peer_id

	return 0


## The local player's mirror, claimed if it arrived before HELLO said whose it was.
# Belt and braces: a JOIN before HELLO would leave the local player unpredicted for the session ([method _apply_join]).
func _claim_local_player() -> void:
	var mine: MmPlayerNet = _behaviours.get(local_player_id)

	if mine == null or mine.identity == null or not mine.identity.is_registered():
		return

	var claimed := _mirror_owner(local_player_id)

	if claimed == 0 or mine.identity.owner_peer_id == claimed:
		return

	DotLog.debug(CHANNEL, "claimed the local player after HELLO", {
		"session": local_player_id, "net_id": mine.identity.net_id,
	})
	var _changed := net.registry.change_owner(mine.identity.net_id, claimed)


func _apply_clock(reader: DotNetReader) -> void:
	var clock := MmEvents.read_clock(reader)

	if not bool(clock["ok"]):
		return

	game.round_number = int(clock["round"])
	game.phase_elapsed = float(clock["elapsed"])
	game.play_elapsed = float(clock["play_elapsed"])
	game.phase = int(clock["phase"])
	game.remote_alive = int(clock["alive"])
	game.remote_murderers = int(clock["murderers"])
	game.remote_playable = bool(clock["playable"])
