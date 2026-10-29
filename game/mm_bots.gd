extends "mm_bots_walk.gd"

## The stand-ins, by role on dot-bot's settings: murderers that stalk, gunners that hunt, and
## bystanders that keep together. The map is surveyed once in `_prepare`. Nobody cheats: a bot
## knows another's weapon only by seeing it drawn ([method _sees]), a death only by seeing or
## hearing it, and a murderer knows only its fellow murderers.


## A new round or map: every bot forgets what it was doing.
func reset() -> void:
	_state.clear()
	_sounds.clear()
	_deaths.clear()
	chat.reset()
	doors_shut = 0
	longest_stuck = 0.0


func forget(player_id: StringName) -> void:
	_state.erase(player_id)


## Somebody died: a noise everybody near hears, and a body some bots may have seen fall.
func on_died(player_id: StringName, by: StringName, _why: StringName) -> void:
	var players: Dictionary = game.get("players")
	if not players.has(player_id):
		return
	var who: MmPlayer = players[player_id]
	var at := who.controller.state.position
	_sounds.append({"at": at, "loud": LOUD_DEATH, "by": player_id, "t": now()})
	_deaths.append({"at": at, "victim": player_id, "by": by, "t": now()})
	_state.erase(player_id)

	# Every bot that saw the killer at it suspects them for good; every bot that only saw the
	# body suspects whoever was nearest it.
	for id: StringName in players:
		var bot: MmPlayer = players[id]
		if not bot.is_bot or not bot.is_alive() or bot.watching or id == by:
			continue
		var state := _state_of(bot)
		var killer: MmPlayer = players.get(by)
		var heard := bot.controller.state.position.distance_to(at) < settings().profile.hearing
		var saw_body := _sees_point(bot, at + Vector3(0.0, 0.6, 0.0))
		if killer != null and killer.is_alive() and _sees(bot, killer) and saw_body:
			_suspect(state, by, 100.0)
			state["threat"] = killer.controller.state.position
			state["threat_at"] = now()
			_say(bot, &"witness", killer.display_name, true)
		elif saw_body or heard:
			state["threat"] = at
			state["threat_at"] = now()
			var nearest := _nearest_to(at, [player_id, id], players)
			if saw_body and nearest != null and nearest.controller.state.position.distance_to(at) < 6.0:
				_suspect(state, nearest.player_id, 35.0)
			_say(bot, &"body")


## What every stand-in presses this tick. Called by the game before the bodies move.
func drive() -> void:
	var players: Dictionary = game.get("players")
	var any := false

	for id: StringName in players:
		if (players[id] as MmPlayer).is_bot:
			any = true
			break

	if not any:
		return

	var phase: int = game.get("phase")

	if phase != 0:
		_prepare()

	_hear_steps(players)

	for id: StringName in players:
		var player: MmPlayer = players[id]

		if not player.is_bot:
			# A person's keys are the client's (or the bridge's) to set. Clearing them here, as
			# this loop did, ran after the client's physics tick and before the game's hands,
			# so a solo player's Q and click never reached the game.
			continue

		if not player.is_alive() or player.watching:
			player.wants_attack = false
			player.wants_holster = false
			continue

		var command := DotFpsCommand.new()
		command.yaw = player.controller.state.yaw
		command.pitch = player.controller.state.pitch
		var aim := _aim_of(player)
		aim.view_from(command.yaw, command.pitch)
		var state := _state_of(player)
		state["attack"] = false
		state["holster"] = false

		if phase != 0:
			_watch(player, state, players)
			if int(game.call("team_of", id)) == 2:
				_murder(player, command, state, players, phase)
			elif player.has_gun:
				_guard(player, command, state, players, phase)
			else:
				_keep_company(player, command, state, players)

		_step_round_people(player, command, players)
		player.controller.apply_command(command)
		player.wants_attack = bool(state["attack"])
		# The game toggles on the press, so a key still down from the last tick is no new press;
		# without the gap a murderer that holstered and wanted it out again next tick held the key
		# for the rest of the round and never drew.
		player.wants_holster = bool(state["holster"]) and not player.wants_holster
		# Pressed and let go on alternate ticks, so the game sees an edge each time.
		if bool(state.get("use_now", false)):
			state["use_now"] = false
			player.wants_use = not player.wants_use
		else:
			player.wants_use = _wants_door(player, command)

	# Sounds older than a second are gone; deaths older than half a minute too.
	var t := now()
	for i in range(_sounds.size() - 1, -1, -1):
		if t - float(_sounds[i]["t"]) > 1.0:
			_sounds.remove_at(i)
	for i in range(_deaths.size() - 1, -1, -1):
		if t - float(_deaths[i]["t"]) > 30.0:
			_deaths.remove_at(i)


## Every moving body makes footsteps: how loud is how it moves.
func _hear_steps(players: Dictionary) -> void:
	var t := now()
	if int(game.get("_tick")) % maxi(int(game.get("tick_rate")) / 4, 1) != 0:
		return
	for id: StringName in players:
		var body: MmPlayer = players[id]
		if not body.is_alive() or body.watching:
			continue
		var v := body.controller.state.velocity
		var speed := Vector2(v.x, v.z).length()
		if speed < 1.0:
			continue
		var loud := LOUD_RUN
		if body.controller.state.crouch_fraction > 0.5:
			loud = LOUD_CROUCH
		elif speed > body.controller.tunables.max_speed * 1.1:
			loud = LOUD_SPRINT
		_sounds.append({"at": body.controller.state.position, "loud": loud, "by": id, "t": t})


## Whether [param player] sees [param other]'s head or chest with its own eyes and settings.
## Nobody here hides, so a person is a person whether they stand still or not.
func _sees(player: MmPlayer, other: MmPlayer) -> bool:
	var eye := player.eye_position()
	var chest := other.controller.state.position + Vector3(0.0, 1.0, 0.0)
	if eye.distance_to(chest) < FELT_WITHIN and _los(eye, chest):
		return true
	return _sees_point(player, other.eye_position()) or _sees_point(player, chest)


func _sees_point(player: MmPlayer, point: Vector3) -> bool:
	var profile := settings().profile
	var forward := DotBotAim.direction(player.controller.state.yaw, player.controller.state.pitch)
	return DotBotHiding.sees(player.eye_position(), forward, profile.fov, profile.sight, point, _los)


## Suspicion from what this bot sees now: a drawn weapon is certain, blood is close to it.
## Suspicion fades slowly; a murderer's own suspects list stays empty.
func _watch(player: MmPlayer, state: Dictionary, players: Dictionary) -> void:
	var suspects: Dictionary = state["suspects"]
	var fade := FORGET_RATE * dt()
	for id: StringName in suspects.keys():
		var left := float(suspects[id]) - fade
		var who: MmPlayer = players.get(id)
		if left <= 0.0 or who == null or not who.is_alive():
			suspects.erase(id)
		else:
			suspects[id] = left

	if int(game.call("team_of", player.player_id)) == 2:
		return

	# A quarter of a second between looks is plenty, and spreads the cost.
	if (int(game.get("_tick")) + hash(String(player.player_id))) % maxi(int(game.get("tick_rate")) / 4, 1) != 0:
		return

	for id: StringName in players:
		var other: MmPlayer = players[id]
		if other == player or not other.is_alive() or other.watching:
			continue
		var armed := other.weapon_drawn
		var bloody := other.blood > 0
		if not armed and not bloody:
			continue
		if not _sees(player, other):
			continue
		if armed:
			if float(suspects.get(id, 0.0)) < 100.0:
				_say(player, &"witness", other.display_name, true)
			_suspect(state, id, 100.0)
			state["threat"] = other.controller.state.position
			state["threat_at"] = now()
		elif bloody:
			var before := float(suspects.get(id, 0.0))
			_suspect(state, id, before + 12.0 * float(other.blood))
			if before < SURE and float(suspects.get(id, 0.0)) >= SURE:
				_say(player, &"blood", other.display_name)


func _suspect(state: Dictionary, id: StringName, amount: float) -> void:
	var suspects: Dictionary = state["suspects"]
	suspects[id] = clampf(maxf(float(suspects.get(id, 0.0)), amount), 0.0, 100.0)


## The most suspected living somebody, as `[id, score]`, or `[&"", 0]`.
func _top_suspect(state: Dictionary) -> Array:
	var best: StringName = &""
	var score := 0.0
	var suspects: Dictionary = state["suspects"]
	for id: StringName in suspects:
		if float(suspects[id]) > score:
			score = float(suspects[id])
			best = id
	return [best, score]


func _say(player: MmPlayer, moment: StringName, name: String = "", always: bool = false) -> void:
	if game.get("config") == null or not bool(game.get("config").get("bot_chat")):
		return
	chat.per_bot = _cfg(&"bot_chat_pause", chat.per_bot)
	chat.chance = _cfg(&"bot_chat_chance", chat.chance)
	var text := chat.line(player.player_id, moment, now(), _state_of(player)["stream"], name, always)
	if text != "":
		counts["lines"] = int(counts["lines"]) + 1
		game.call("bot_say", player.player_id, text)


func _nearest_to(at: Vector3, skip: Array, players: Dictionary) -> MmPlayer:
	var best: MmPlayer = null
	var best_d := INF
	for id: StringName in players:
		var other: MmPlayer = players[id]
		if skip.has(id) or not other.is_alive() or other.watching:
			continue
		var d := other.controller.state.position.distance_to(at)
		if d < best_d:
			best_d = d
			best = other
	return best


## Living people other than [param player] (and other than the murderers, when [param innocent]).
func _others(player: MmPlayer, players: Dictionary, innocent: bool = false) -> Array[MmPlayer]:
	var out: Array[MmPlayer] = []
	for id: StringName in players:
		var other: MmPlayer = players[id]
		if other == player or not other.is_alive() or other.watching:
			continue
		if innocent and int(game.call("team_of", id)) == 2:
			continue
		out.append(other)
	return out


## Keeps with the nearest knot of people, runs from what it saw, fetches a gun on the floor.
func _keep_company(player: MmPlayer, command: DotFpsCommand, state: Dictionary, players: Dictionary) -> void:
	if not bool(state["said_start"]):
		state["said_start"] = true
		_say(player, &"start")

	if _flee(player, command, state):
		return

	if int(game.call("team_of", player.player_id)) != 2 and _fetch_gun(player, command, state):
		return

	_loiter(player, command, state, players, false)


## Runs from the last threat seen, for [constant FLEE_FOR] seconds. True while it is running.
func _flee(player: MmPlayer, command: DotFpsCommand, state: Dictionary) -> bool:
	var threat: Vector3 = state["threat"]
	if threat == Vector3.INF or now() - float(state["threat_at"]) > _cfg(&"bot_flee_seconds", FLEE_FOR):
		if state["mode"] == &"fleeing":
			state["mode"] = &""
			state["goal"] = Vector3.INF
		return false
	var at := player.controller.state.position
	if state["mode"] != &"fleeing" or Vector3(state["goal"]).distance_to(at) < 1.5:
		state["mode"] = &"fleeing"
		state["goal"] = _place_away_from(threat, at, state)
	_note_doorway(player, state, state["goal"])
	var _there := _walk_to(player, command, state, state["goal"], true)
	_unstick(player, command, state)
	return true


## Walks to a gun on the floor it can see and is allowed to take. True while it is going.
func _fetch_gun(player: MmPlayer, command: DotFpsCommand, state: Dictionary) -> bool:
	if player.gun_banned or player.has_gun:
		return false
	var drops: Dictionary = game.get("gun_drops")
	var at := player.controller.state.position
	var best := Vector3.INF
	for drop_id: int in drops:
		var spot: Vector3 = drops[drop_id]["at"]
		# A gun that has just fallen is known about: the shot or the scream is heard, and the
		# room tells where. Only a long-lying one has to be seen to be remembered, and a gun
		# usually falls where the murderer is, out of every bystander's line of sight.
		var fresh := float(game.call("_now")) - float(drops[drop_id]["since"]) < FETCH_HEARD_FOR
		if spot.distance_to(at) > _cfg(&"bot_fetch_gun_range", FETCH_GUN) or not (fresh or _los(player.eye_position(), spot + Vector3(0.0, 0.2, 0.0))):
			continue
		if best == Vector3.INF or spot.distance_to(at) < best.distance_to(at):
			best = spot
	if best == Vector3.INF:
		return false
	if state["mode"] != &"fetching":
		state["mode"] = &"fetching"
		counts["fetched"] = int(counts["fetched"]) + 1
	state["goal"] = best
	_look(player, command, best)
	var _there := _walk_to(player, command, state, best, true, false)
	_unstick(player, command, state)
	return true


## Goes to where the people are and stays near them, wandering a little.
func _loiter(player: MmPlayer, command: DotFpsCommand, state: Dictionary, players: Dictionary, apart: bool) -> void:
	var at := player.controller.state.position
	var t := now()
	if t - float(state["picked_at"]) > REPICK or Vector3(state["goal"]) == Vector3.INF:
		state["picked_at"] = t + _stream(state).next_range_f(-1.5, 1.5)
		state["mode"] = &"company"
		var crowd := _crowd(player, players)
		if crowd == Vector3.INF:
			state["goal"] = _wander_place(at, state, 30.0)
			_say(player, &"alone")
		else:
			var spread := COMPANY * (2.0 if apart else 1.0)
			state["goal"] = _place_near(crowd, spread, state)
			if crowd.distance_to(at) > 12.0:
				_say(player, &"group")
	var goal: Vector3 = state["goal"]
	if goal.distance_to(at) > 1.0:
		var _there := _walk_to(player, command, state, goal, goal.distance_to(at) > 15.0)
		_unstick(player, command, state)
	else:
		# Standing about: look at whoever is nearest.
		var near := _nearest_to(at, [player.player_id], players)
		if near != null:
			_look(player, command, near.eye_position())


## The middle of the largest knot of living people this bot is not alone in, or INF.
## A body counts if it is within 10 m of another; the knot is the one with the most.
func _crowd(player: MmPlayer, players: Dictionary) -> Vector3:
	var others := _others(player, players)
	var best := Vector3.INF
	var best_n := 0
	var best_d := INF
	var at := player.controller.state.position
	for a: MmPlayer in others:
		var centre := Vector3.ZERO
		var n := 0
		for b: MmPlayer in others:
			if a.controller.state.position.distance_to(b.controller.state.position) < 10.0:
				centre += b.controller.state.position
				n += 1
		centre /= float(maxi(n, 1))
		var d := centre.distance_to(at)
		if n > best_n or (n == best_n and d < best_d):
			best = centre
			best_n = n
			best_d = d
	return best


## Hunts the most suspected; keeps with people otherwise.
func _guard(player: MmPlayer, command: DotFpsCommand, state: Dictionary, players: Dictionary, phase: int) -> void:
	if not bool(state["said_start"]):
		state["said_start"] = true
		_say(player, &"gun")

	var top := _top_suspect(state)
	var target: MmPlayer = players.get(top[0]) if top[0] != &"" else null
	var aim := _aim_of(player)

	if target == null or float(top[1]) < SURE * 0.5:
		aim.release()
		_loiter(player, command, state, players, true)
		return

	var at := player.controller.state.position
	var chest := target.controller.state.position + Vector3(0.0, 1.1, 0.0)
	var distance := player.eye_position().distance_to(chest)
	var seen := _sees(player, target)

	if float(top[1]) >= SURE and seen and phase == 2:
		state["mode"] = &"shooting"
		var _new := aim.engage(target.entity_id, player.eye_position(), chest, now())
		var view := aim.track(player.eye_position(), chest, target.controller.state.velocity, now(), dt())
		command.yaw = view.x
		command.pitch = clampf(view.y, -60.0, 60.0)
		var gun_range := float(game.get("config").get("gun_range"))
		# Close in when far, hold when near.
		if distance > minf(gun_range * 0.6, 22.0):
			var _there := _walk_to(player, command, state, target.controller.state.position, false, false, true)
		if player.ready_at <= float(game.call("_now")) and distance <= gun_range and aim.on_aim() and aim.trigger(now(), distance):
			state["attack"] = true
			counts["shots"] = int(counts["shots"]) + 1
			aim.note_shot(player.eye_position(), chest, now())
		return

	# Suspected but out of sight: go where they were last.
	aim.release()
	state["mode"] = &"tailing"
	if float(top[1]) >= SURE * 0.8 and _stream(state).next_unit() < 0.002:
		_say(player, &"suspect", target.display_name)
	var _there := _walk_to(player, command, state, target.controller.state.position, distance > 10.0, true, true)
	_unstick(player, command, state)
	if at.distance_to(target.controller.state.position) < 3.0:
		_look(player, command, target.eye_position())


## Stalks somebody alone, draws when nobody else is looking, stabs at arm's length.
func _murder(player: MmPlayer, command: DotFpsCommand, state: Dictionary, players: Dictionary, phase: int) -> void:
	if not bool(state["said_start"]):
		state["said_start"] = true
		_say(player, &"start")

	var at := player.controller.state.position
	var seconds_left := float(game.call("seconds_left"))
	# Before the blood shows, not after: from the first stage a gunner shoots the stained one on
	# sight, so a murderer that waited for a clean moment past it was shot never having struck.
	var blood_lead: float = float(game.get("config").blood_seconds) + DESPERATE_LEAD
	var desperate := phase == 2 and seconds_left < maxf(DESPERATE, blood_lead)

	if phase != 2:
		# The grace: be one of the crowd.
		_put_away(player, state)
		_loiter(player, command, state, players, false)
		return

	var target: MmPlayer = players.get(state["target"]) if state["target"] != &"" else null
	if target == null or not target.is_alive() or target.watching or now() - float(state.get("target_at", -INF)) > 20.0:
		target = _pick_victim(player, players, desperate)
		state["target"] = target.player_id if target != null else &""
		state["target_at"] = now()

	if target == null:
		_put_away(player, state)
		_loiter(player, command, state, players, false)
		return

	var chest := target.controller.state.position + Vector3(0.0, 1.1, 0.0)
	var distance := Vector2(chest.x - at.x, chest.z - at.z).length()
	var witnesses := _witnesses(player, target, players)
	# Desperate means it stops waiting for a clean moment (header, "Late in the round"). On an
	# open map the bystanders keep together in plain sight of one another, so a count of
	# witnesses never falls to one and a murderer that still waited for it watched them until
	# the clock ran out.
	var clean := witnesses == 0 or desperate
	var reach := float(game.call("melee_reach"))

	if clean and distance < 7.0:
		state["mode"] = &"striking"
		if not player.weapon_drawn:
			state["holster"] = true
			counts["draws"] = int(counts["draws"]) + 1
		_look(player, command, chest)
		var _there := _walk_to(player, command, state, target.controller.state.position, true, false, true)
		if distance < reach * 0.85 and player.weapon_drawn and player.ready_at <= float(game.call("_now")):
			state["attack"] = true
			counts["stabs"] = int(counts["stabs"]) + 1
		_unstick(player, command, state)
		return

	# Not clean: weapon away, and follow at a stroll, as though going the same way. Desperate, it
	# keeps the weapon out: holstering at 7 m and drawing again inside it, every frame, is the
	# draw count of a murderer that never gets to strike.
	if not desperate:
		_put_away(player, state)
	state["mode"] = &"stalking"
	if distance > 5.0:
		var _there := _walk_to(player, command, state, target.controller.state.position, distance > 18.0)
		_unstick(player, command, state)
	else:
		_look(player, command, target.eye_position())
	if witnesses > 0 and _stream(state).next_unit() < 0.0015:
		_say(player, &"innocent")


## Holsters the weapon if it is out.
func _put_away(player: MmPlayer, state: Dictionary) -> void:
	if player.weapon_drawn:
		state["holster"] = true


## Somebody worth going after: alone, near, and the gunner most of all when alone too.
func _pick_victim(player: MmPlayer, players: Dictionary, desperate: bool) -> MmPlayer:
	var at := player.controller.state.position
	var innocent := _others(player, players, true)
	var best: MmPlayer = null
	var best_cost := INF
	for who: MmPlayer in innocent:
		var company := 0
		for other: MmPlayer in innocent:
			if other != who and other.controller.state.position.distance_to(who.controller.state.position) < ALONE:
				company += 1
		var cost := at.distance_to(who.controller.state.position) + 25.0 * float(company)
		if who.has_gun:
			cost -= 10.0
		if not desperate and company > 1:
			cost += 60.0
		if cost < best_cost:
			best_cost = cost
			best = who
	return best


## How many living people other than [param player] and [param target] can see [param player]
## now. A fellow murderer is not a witness.
func _witnesses(player: MmPlayer, target: MmPlayer, players: Dictionary) -> int:
	var count := 0
	for other: MmPlayer in _others(player, players, true):
		if other == target:
			continue
		if other.controller.state.position.distance_to(player.controller.state.position) > _cfg(&"bot_witness_range", WITNESS_RANGE):
			continue
		if _los(other.eye_position(), player.eye_position()):
			count += 1
	return count


## Steps round anybody within a metre: people pass through people here, and a bot that walks
## through somebody walks through their camera.
func _step_round_people(player: MmPlayer, command: DotFpsCommand, players: Dictionary) -> void:
	if command.move.length() < 0.1:
		return
	var at := player.controller.state.position
	var yaw := deg_to_rad(command.yaw)
	var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var push := Vector3.ZERO
	for id: StringName in players:
		var other: MmPlayer = players[id]
		if other == player or not other.is_alive() or other.watching:
			continue
		var off := at - other.controller.state.position
		off.y = 0.0
		var d := off.length()
		if d < 1.1 and d > 0.001 and absf(at.y - other.controller.state.position.y) < 1.5:
			push += off / d * (1.1 - d)
	if push == Vector3.ZERO:
		return
	var world := forward * command.move.y + right * command.move.x
	# Aside, never back: two bots meeting in a doorway pushed each other back out of it, each
	# pressing in again, and a bot stood in a park cabin's doorway for sixteen seconds
	# (`headless_bots` round 28). People pass through people, so going on through is allowed.
	var heading := world.normalized()
	var against := push.dot(heading)
	if against < 0.0:
		push -= heading * against
	world += push * 2.0
	command.move = Vector2(world.dot(right), world.dot(forward)).limit_length(1.0)


## Opens a shut door it is walking into, and leaves open ones alone. Released between presses,
## so the game sees an edge.
func _wants_door(player: MmPlayer, command: DotFpsCommand) -> bool:
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors") if map != null else null
	if doors == null or int(doors.call("count")) == 0 or command.move.length() < 0.1 or player.wants_use:
		return false
	var yaw := deg_to_rad(command.yaw)
	var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var going := (forward * command.move.y + right * command.move.x).normalized()
	var index: int = doors.call("door_for", player.eye_position(), going, 1.6)
	return index >= 0 and not bool(doors.call("is_open", index)) and not bool(doors.call("moving", index, int(game.get("_tick"))))


func describe() -> Dictionary:
	return {"spots": spots.size(), "survey_ms": snappedf(survey_ms, 0.1), "nav": nav.describe(), "bots": _state.size(), "counts": counts}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["bots  %d places (%d open floor) in %.0f ms, %d links, annotated in %.0f ms%s" % [
		spots.size(), sweep.size(), survey_ms, links_used, annotate_ms, " (cached)" if annotate_cached else ""]])
	lines.append("  did   %s" % str(counts))
	lines.append_array(nav.describe_lines())
	for id: StringName in _state:
		var s: Dictionary = _state[id]
		lines.append("  %-10s %-9s goal %s" % [String(id), String(s["mode"]), str(s.get("goal", "-"))])
	return lines
