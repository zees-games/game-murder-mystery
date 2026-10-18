extends RefCounted

const MmPlayer := preload("mm_player.gd")
const MmBotChat := preload("mm_bot_chat.gd")

## The stand-ins, by role, on dot-bot's settings: murderers that stalk, gunners that hunt, and
## bystanders that keep together.
##
## - [b]The map is surveyed once[/b] when it is built (`_prepare`): dot-bot's [DotBotNav] bakes
##   where a body can walk from the map's colliders, and dot-npc-ai's annotator scores places on
##   it. Those places are where a bot wanders to and where a murderer looks for somebody alone.
## - [b]A bystander keeps company[/b]: it walks towards the nearest knot of living people and
##   loiters there, and runs from anybody it sees with a weapon drawn or standing over a body it
##   saw fall. Unarmed and near a gun on the floor it goes and picks it up.
## - [b]A gunner hunts the suspicious[/b]: suspicion is what it has seen (a weapon drawn, blood,
##   the nearest person to a body that fell in view). Past [constant SURE] it turns on them, and
##   fires when dot-bot's aim says it is on target. A gunner with nobody suspected walks with the
##   group like anybody.
## - [b]A murderer keeps the weapon away while anybody else can see it[/b], picks a living
##   bystander with nobody else near ([constant ALONE]), walks to them with the crowd's pace,
##   draws only when no third person has it in view, and stabs at arm's length. Late in the round
##   it stops waiting for a clean moment. It knows who its fellow murderers are and never
##   targets them; it knows nothing else anybody else does not.
## - [b]Nobody cheats.[/b] A bot knows another's weapon only by seeing it drawn ([method _sees]:
##   cone, range, nothing solid between), and a death only when it saw it or heard it close.
## - [b]People do not collide with people,[/b] so a bot steps round anybody within a metre.
##   Doors, sticking and paths are dot-bot's and the shared walking code below.
## - [b]They talk[/b] (when `bot_chat`): canned lines from mm_bot_chat.gd, rationed.

const CHANNEL := "mm.bots"

# --- Hearing (footsteps and the noise of a death) ---------------------------------

const LOUD_SPRINT := 0.45
const LOUD_RUN := 0.28
const LOUD_CROUCH := 0.06
## A scream: a death is heard across a few rooms.
const LOUD_DEATH := 1.0

# --- The survey -------------------------------------------------------------------

const SURVEY_POINTS := 260
const SURVEY_PROPS := 160
const WATCHERS := 80
const ANNOTATE_STEPS_PER_TICK := 6
const DROP_MAX := 2.0
const LINK_SPACING := 6.0
const SWEEP_POINTS := 120

# --- Walking (shared with the other Dot bots' walking code) -------------------------

const SHUN_FOR := 30.0
const DETOUR_LOOK := 1.6
const DETOUR_SECONDS := 4.0
const DETOUR_AGAIN := 10.0
const STUCK_SECONDS := 0.6
const STUCK_LEFT := 1.5
const CORNER_CLOSE := 0.15
const DOOR_CLEAR := 1.4
const LINGER_SHUT := 5.0
const LINGER_GIVE_UP := 8.0
const SHUT_FAILED_FOR := 10.0
const FELT_WITHIN := 2.0

# --- The roles ----------------------------------------------------------------------

## Somebody with nobody else within this many metres is alone, to a murderer.
const ALONE := 9.0

## A third person within this many metres who can see the murderer spoils the moment.
const WITNESS_RANGE := 28.0

## Seconds left in the round under which a murderer stops waiting for a clean moment.
const DESPERATE := 45.0

## Suspicion, 0..100, at which a gunner shoots.
const SURE := 60.0

## Suspicion a gunner loses a second.
const FORGET_RATE := 2.0

## How far a bystander strays from the people it keeps with, and how often it picks a new place.
const COMPANY := 4.0
const REPICK := 5.0

## A bystander unarmed picks up a gun it can see within this many metres.
const FETCH_GUN := 25.0

## How long a bystander runs from what it saw.
const FLEE_FOR := 6.0
const FLEE_CLEAR := 12.0

var game: Node = null

var nav: DotBotNav = DotBotNav.new()

## Places on the map: the annotator's hiding spots, each `{at, ...}`. Where bots wander.
var spots: Array[Dictionary] = []

## Open floor places, the random survey's.
var sweep: Array[Dictionary] = []

var annotations: DotNpcAiNavAnnotations = null
var annotate_ms: float = 0.0
var annotate_cached: bool = false
var links_used: int = 0

var _annotator: DotNpcAiNavAnnotator = null
var _cached: DotNpcAiNavAnnotations = null
var _job: DotJob = null
var _job_done: bool = false
var _job_steps: int = 0
var _jump_feet: PackedVector3Array = PackedVector3Array()
var _watch_eyes: PackedVector3Array = PackedVector3Array()
var _surveyed: String = ""
var _baked: String = ""
var _survey_at: int = 0

## Per-bot state, by player id.
var _state: Dictionary = {}

## Noises in the last second: `{at, loud, by, t}`.
var _sounds: Array[Dictionary] = []

## Deaths this round a bot may have seen or heard: `{at, victim, by, t}` (`by` is the server's
## truth and is read only for the bot that SAW the stab, never for one that heard it).
var _deaths: Array[Dictionary] = []

var doors_shut: int = 0
var longest_stuck: float = 0.0
var longest_stuck_at: Vector3 = Vector3.ZERO
var longest_stuck_who: StringName = &""
var _door_rid_list: Array[RID] = []
var _door_rid_doors: Object = null
var survey_ms: float = 0.0

var chat: MmBotChat = MmBotChat.new()

## What the bots did, for `headless_bots`: stabs tried, shots fired, guns fetched, lines said.
var counts: Dictionary = {"stabs": 0, "shots": 0, "fetched": 0, "lines": 0, "draws": 0}


func _init(p_game: Node = null) -> void:
	game = p_game


func settings() -> DotBotSettings:
	return DotBotSettings.of(game)


func now() -> float:
	return float(int(game.get("_tick"))) / float(maxi(int(game.get("tick_rate")), 1))


func dt() -> float:
	return 1.0 / float(maxi(int(game.get("tick_rate")), 1))


## Bakes and surveys the map now built, once per map. Only where bots run (the server, or solo).
func _prepare() -> void:
	var map: Node3D = game.get("map")
	var doc: Dictionary = game.get("map_doc")
	var key := "%s|%d" % [str(doc.get("id", "")), map.get_instance_id() if map != null else 0]

	if map == null or key == _surveyed:
		return

	if key != _baked:
		_baked = key
		spots.clear()
		sweep.clear()
		annotations = null
		_job = null
		_job_done = false
		# The walls, floors and furniture, never the doors: a door baked shut is a doorway the
		# mesh does not go through.
		var still: Array = [map.get("_solid"), map.get("_furniture")]
		# And round every toy that stands in the way (a swing's sweep, a see-saw, a trampoline):
		# a bot never paths across one. The loose toys are not in it; a bot walks through a
		# ball and pushes it, as anybody does.
		var toys: Variant = map.get("toys")
		if toys is DotPropToyBox:
			still.append_array((toys as DotPropToyBox).nav_bodies())
		var baked := nav.bake(map, {"radius": MmPlayer.BODY_RADIUS, "height": MmPlayer.BODY_CROUCH, "climb": MmPlayer.BODY_STEP}, 0, still)
		if not baked.ok:
			_surveyed = key
			DotLog.warn(CHANNEL, "no walkable mesh for the bots; they walk straight", {"map": str(doc.get("id", "")), "why": baked.error.message})
		# The navigation server takes the mesh in on a later frame; survey a quarter of a second
		# of game time on, always the same tick, so a round plays the same however the frames
		# fall (and later still only when the server is that slow).
		_survey_at = int(game.get("_tick")) + maxi(int(game.get("tick_rate")) / 4, 1)
		return

	if int(game.get("_tick")) < _survey_at or not nav.is_ready():
		return

	# The annotation is a job: stepped a fixed number of slices each tick (never by the clock, so
	# a seeded round plays the same), and the bots wait for it as they waited for the bake.
	if _job == null and not _job_done:
		_job = _begin_annotation(map, doc)
		_job_steps = 0
	if _job != null:
		var stepped := Time.get_ticks_usec()
		for _i in range(ANNOTATE_STEPS_PER_TICK):
			_job_steps += 1
			if not _job.step():
				break
		annotate_ms += (Time.get_ticks_usec() - stepped) / 1000.0
		if _job.state == DotJob.State.RUNNING or _job.state == DotJob.State.PENDING:
			return

	_surveyed = key
	var started := Time.get_ticks_usec()
	var random: DotRandomManager = game.get("random")
	var stream := random.stream_for(&"bot_survey", hash(str(doc.get("id", ""))) % 65536)

	annotations = _finish_annotation(doc)
	if annotations != null and not annotations.hiding.is_empty():
		spots = annotations.hiding_spots()
		sweep = _random_survey(map, stream, SWEEP_POINTS, SURVEY_PROPS / 3)
	else:
		# Nothing annotated (no mesh, or a map with no walls to hide by): the old random survey.
		spots = _random_survey(map, stream, SURVEY_POINTS, SURVEY_PROPS)
		sweep = []
	survey_ms = (Time.get_ticks_usec() - started) / 1000.0 + nav.bake_ms + annotate_ms
	DotLog.debug(CHANNEL, "surveyed the map for the bots", {
		"map": str(doc.get("id", "")), "spots": spots.size(), "nav_ms": snappedf(nav.bake_ms, 0.1), "ms": snappedf(survey_ms, 0.1),
		"links": links_used, "chokepoints": annotations.chokepoints.size() if annotations != null else 0, "cached": annotate_cached,
		"steps": _job_steps,
	})


## The old survey: random points over the mesh and points beside props, each scored by the
## share of random watchers that see it. Kept as the sweep's open-floor places and as the fallback
## when a map has no annotations.
func _random_survey(map: Node3D, stream: DotRandomStream, points: int, prop_count: int) -> Array[Dictionary]:
	var candidates := PackedVector3Array()

	for _i in range(points):
		candidates.append(nav.random_point(stream))

	# Beside furniture, where people hide: a point a little out from a side of the prop, put
	# on the walkable mesh.
	var props: Array = map.get("props")
	var step := maxi(1, props.size() / maxi(prop_count, 1))
	for i in range(0, props.size(), step):
		var prop: Dictionary = props[i]
		var frame: Transform3D = prop["transform"]
		var size: Vector3 = prop["size"]
		var side := Vector3(1.0, 0.0, 0.0).rotated(Vector3.UP, stream.next_range_f(0.0, TAU))
		var beside := frame.origin + side * (maxf(size.x, size.z) * 0.5 + 0.5)
		var on := nav.closest(beside)
		if on.distance_to(beside) < 0.8:
			candidates.append(on)

	var watchers := PackedVector3Array()
	for _i in range(WATCHERS):
		watchers.append(nav.random_point(stream) + Vector3(0.0, MmPlayer.EYE_HEIGHT, 0.0))

	return DotBotHiding.survey(candidates, watchers, _los)


## What the map means to somebody walking it: [DotNpcAiNavAnnotator] over the baked mesh, seeded
## with every spawn, the doors left out of its rays (the bake left them out), cached by key under
## `user://nav`. Returns the job to step, or null when the cache had it (or there is no mesh);
## [method _finish_annotation] then hands drop and jump-up links to the mesh as ride edges.
func _begin_annotation(map: Node3D, doc: Dictionary) -> DotJob:
	annotate_cached = false
	annotate_ms = 0.0
	links_used = 0
	_annotator = null
	_cached = null
	_job_done = true
	if nav.mesh == null or not nav.is_ready():
		return null

	var annotator := DotNpcAiNavAnnotator.new(nav.mesh, map.get_world_3d())
	annotator.agent_radius = MmPlayer.BODY_RADIUS
	annotator.stand_height = MmPlayer.BODY_HEIGHT
	annotator.crouch_height = MmPlayer.BODY_CROUCH
	annotator.eye_height = MmPlayer.EYE_HEIGHT
	annotator.climb = MmPlayer.BODY_STEP
	annotator.random_seed = hash(str(doc.get("id", ""))) % 65536 + 1
	annotator.exclude = _door_rids()
	# Fewer links than the default two metres apart: a camp's cabins on stilts gave four hundred,
	# and a way down every metre is not a hiding place anybody uses.
	annotator.link_spacing = LINK_SPACING
	# A way down of two metres at most: a four-metre drop off a landing was a rail the bot stood
	# at for twenty seconds (the ray at knee height does not see a rail), and nobody drops that
	# far to hide.
	annotator.drop_max = DROP_MAX
	var physics: Object = game.get("physics")
	if physics != null:
		annotator.collision_mask = int(physics.call("layer_mask", &"world")) | int(physics.call("layer_mask", &"prop"))
	var seeds := PackedVector3Array()
	for side: String in (doc.get("spawns", {}) as Dictionary):
		for i in range(((doc.get("spawns", {}) as Dictionary).get(side, []) as Array).size()):
			seeds.append(nav.closest((map.call("spawn", side, i) as Array)[0]))
	annotator.seeds = seeds
	_annotator = annotator

	var loaded := DotNpcAiNavAnnotations.load_file(_cache_path(), annotator.cache_key())
	if loaded.ok:
		_cached = loaded.value
		annotate_cached = true
		return null
	return annotator


func _cache_path() -> String:
	return "user://nav/%s.json" % _annotator.cache_key()


func _finish_annotation(doc: Dictionary) -> DotNpcAiNavAnnotations:
	if _annotator == null:
		return null
	var found: DotNpcAiNavAnnotations = _cached
	if found == null:
		if _annotator.state != DotJob.State.DONE or _annotator.result == null or not _annotator.result.ok:
			DotLog.warn(CHANNEL, "the map could not be annotated; the bots use a random survey", {"map": str(doc.get("id", ""))})
			return null
		found = _annotator.annotations
		var _saved := found.save(_cache_path())

	# Drops and short jumps up: the mesh does not join a table top to the floor, the bot can.
	# A gap is a running jump the stand-ins do not make.
	var ride := 0
	_jump_feet.clear()
	for link in found.links:
		var kind := int(link["kind"])
		if kind == DotNpcAiNavAnnotations.LINK_DROP or kind == DotNpcAiNavAnnotations.LINK_JUMP_UP:
			# Both ends on the mesh itself: a link end off it made the engine's path query fail.
			if nav.closest(link["from"]).distance_to(link["from"]) > 0.3 or nav.closest(link["to"]).distance_to(link["to"]) > 0.3:
				continue
			nav.add_ride(link["from"], link["to"], ride, 1.5)
			ride += 1
			if kind == DotNpcAiNavAnnotations.LINK_JUMP_UP:
				_jump_feet.append(link["from"])
	links_used = ride
	return found


func _los(a: Vector3, b: Vector3) -> bool:
	return bool(game.call("_clear_between", a, b, true))


# --- The round ---------------------------------------------------------------------

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


# --- Every tick -----------------------------------------------------------------

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

		if not player.is_bot or not player.is_alive() or player.watching:
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
		player.wants_holster = bool(state["holster"])
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


func _state_of(player: MmPlayer) -> Dictionary:
	if not _state.has(player.player_id):
		var seed := hash(String(player.player_id))
		_state[player.player_id] = {
			"aim": DotBotAim.new(seed, settings()),
			"stream": DotRandomStream.new(seed, &"mm_bot"),
			"goal": Vector3.INF, "path": PackedVector3Array(), "corner": 0, "path_at": -INF,
			"mode": &"", "since": now(), "stuck": [player.controller.state.position, now()],
			"spot": {}, "threat": Vector3.INF, "threat_at": -INF, "moved_at": -INF,
			"target": StringName(), "picked_at": -INF, "suspects": {}, "said_start": false,
			"attack": false, "holster": false, "who": player.player_id,
		}
	return _state[player.player_id]


func _aim_of(player: MmPlayer) -> DotBotAim:
	return _state_of(player)["aim"]


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


# --- What everybody notices -------------------------------------------------------

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


# --- Bystanders -------------------------------------------------------------------

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
	if threat == Vector3.INF or now() - float(state["threat_at"]) > FLEE_FOR:
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
		if spot.distance_to(at) > FETCH_GUN or not _los(player.eye_position(), spot + Vector3(0.0, 0.2, 0.0)):
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


# --- Gunners ----------------------------------------------------------------------

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


# --- Murderers --------------------------------------------------------------------

## Stalks somebody alone, draws when nobody else is looking, stabs at arm's length.
func _murder(player: MmPlayer, command: DotFpsCommand, state: Dictionary, players: Dictionary, phase: int) -> void:
	if not bool(state["said_start"]):
		state["said_start"] = true
		_say(player, &"start")

	var at := player.controller.state.position
	var seconds_left := float(game.call("seconds_left"))
	var desperate := phase == 2 and seconds_left < DESPERATE

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
	var clean := witnesses == 0 or (desperate and witnesses <= 1)
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

	# Not clean: weapon away, and follow at a stroll, as though going the same way.
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
		if other.controller.state.position.distance_to(player.controller.state.position) > WITNESS_RANGE:
			continue
		if _los(other.eye_position(), player.eye_position()):
			count += 1
	return count


# --- Places -------------------------------------------------------------------------

func _stream(state: Dictionary) -> DotRandomStream:
	return state["stream"]


## Every place a bot can be sent: the survey's spots and its open floor.
func _places() -> Array[Dictionary]:
	if sweep.is_empty():
		return spots
	var all: Array[Dictionary] = spots.duplicate()
	all.append_array(sweep)
	return all


## A place within [param within] of [param at], or [param at] itself on a map with none.
func _wander_place(at: Vector3, state: Dictionary, within: float) -> Vector3:
	var near: Array[Vector3] = []
	for place: Dictionary in _places():
		var p: Vector3 = place["at"]
		if p.distance_to(at) < within and p.distance_to(at) > 3.0:
			near.append(p)
	if near.is_empty():
		return at
	return near[_stream(state).next_range_i(0, near.size() - 1)]


## A place within [param spread] of [param centre]: the nearest few, one at random.
func _place_near(centre: Vector3, spread: float, state: Dictionary) -> Vector3:
	var near: Array[Vector3] = []
	for place: Dictionary in _places():
		var p: Vector3 = place["at"]
		if p.distance_to(centre) < spread and absf(p.y - centre.y) < 2.0:
			near.append(p)
	if near.is_empty():
		return centre
	return near[_stream(state).next_range_i(0, near.size() - 1)]


## A place [constant FLEE_CLEAR] or more from [param threat], as near [param at] as can be,
## and not past the threat.
func _place_away_from(threat: Vector3, at: Vector3, state: Dictionary) -> Vector3:
	var best := Vector3.INF
	var best_cost := INF
	var away := Vector3(at.x - threat.x, 0.0, at.z - threat.z).normalized()
	for place: Dictionary in _places():
		var p: Vector3 = place["at"]
		if p.distance_to(threat) < FLEE_CLEAR:
			continue
		var toward := Vector3(p.x - at.x, 0.0, p.z - at.z)
		if away != Vector3.ZERO and toward.normalized().dot(away) < -0.2:
			continue
		var cost := p.distance_to(at) + _stream(state).next_range_f(0.0, 4.0)
		if cost < best_cost:
			best_cost = cost
			best = p
	if best == Vector3.INF:
		return at + away * FLEE_CLEAR
	return best


# --- Walking ---------------------------------------------------------------------

## Remembers the doorway the bot is in, and once it is through and clear of the panel's
## sweep, decides whether to shut the door behind it: always running from somebody behind it,
## and going to a place close beyond the door. A shut door is a wall to a bot's eye until it
## is opened, and opening it costs whoever follows the panel's swing.
func _note_doorway(player: MmPlayer, state: Dictionary, goal: Vector3) -> void:
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors") if map != null else null
	if doors == null or int(doors.call("count")) == 0:
		return
	var at := player.controller.state.position
	var through: int = state.get("door_through", -1)
	if through < 0:
		for index in range(int(doors.call("count"))):
			var panel: Vector3 = (doors.call("panel_transform", index, 0.0) as Transform3D).origin
			if Vector2(panel.x - at.x, panel.z - at.z).length() < 0.9 and absf(panel.y - at.y) < 2.0:
				state["door_through"] = index
				state["door_side"] = at
				return
		return
	var panel_at: Vector3 = (doors.call("panel_transform", through, 0.0) as Transform3D).origin
	var away := Vector2(panel_at.x - at.x, panel_at.z - at.z).length()
	if away < DOOR_CLEAR:
		return
	state["door_through"] = -1
	if away > DOOR_CLEAR + 1.5 or not bool(doors.call("is_open", through)):
		return
	# Through it, not back out the way it came in.
	var entered: Vector3 = state.get("door_side", at)
	if Vector2(entered.x - at.x, entered.z - at.z).length() < DOOR_CLEAR:
		return
	var threat: Vector3 = state["threat"]
	var chased: bool = state["mode"] == &"fleeing" and threat != Vector3.INF and threat.distance_to(at) > 3.0 \
		and threat.distance_to(panel_at) < threat.distance_to(at) + 1.0
	var settling: bool = state["mode"] == &"going" and goal.distance_to(at) < 9.0
	if chased or settling:
		state["shut"] = {"index": through, "until": now() + 1.2}


## Turns to the door in `state.shut` and presses use until it is shut or the moment has passed.
## Returns true while it is at it.
func _shut_door(player: MmPlayer, command: DotFpsCommand, state: Dictionary) -> bool:
	var shut: Dictionary = state.get("shut", {})
	if shut.is_empty():
		return false
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors") if map != null else null
	var index: int = shut["index"]
	if doors == null or now() > float(shut["until"]) or not bool(doors.call("is_open", index)):
		if doors != null and not bool(doors.call("is_open", index)) and bool(shut.get("count", true)):
			doors_shut += 1
		if doors != null and bool(doors.call("is_open", index)):
			# The moment passed with it still open (out of reach, or somebody in its sweep).
			_note_shut_failed(state, index)
		state["shut"] = {}
		return false
	var panel_at: Vector3 = (doors.call("panel_transform", index, 0.0) as Transform3D).origin
	command.move = Vector2.ZERO
	command.set_button(DotFpsCommand.BUTTON_CROUCH, bool(state["crouch"]))
	_look(player, command, panel_at)
	var facing: int = doors.call("door_for", player.eye_position(), player.aim_direction())
	state["use_now"] = facing == index and not bool(doors.call("moving", index, int(game.get("_tick"))))
	return true


## A shut door the walk goes into that would swing into the bot itself (a door pinned to open
## one way, `away: false`, from the side it opens towards): the game refuses a use while anybody
## stands where the panel will pass, the opener too, so pressing from there does nothing. A
## person steps back first. Plans a point out of the swing, square to the door's middle, on the
## mesh; true when it did, and `_open_from_clear` walks there and opens it. Without it a bot
## fleeing a park cabin stood at its inward front door for eighteen seconds (`headless_bots`
## round 10).
func _plan_open_from_clear(player: MmPlayer, state: Dictionary, dir: Vector3) -> bool:
	if dir.length() < 0.01 or _before(state, "open_check"):
		return false
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors") if map != null else null
	if doors == null or int(doors.call("count")) == 0:
		return false
	var at := player.controller.state.position
	var index: int = doors.call("door_for", player.eye_position(), dir.normalized(), 1.6)
	if index < 0 or bool(doors.call("is_open", index)) or bool(doors.call("moving", index, int(game.get("_tick")))):
		return false
	var spec: Dictionary = ((doors.get("doors") as Array)[index] as Dictionary)["spec"]
	if str(spec["motion"]) != "swing":
		return false
	var flip := 1 if bool(doors.call("flips_for", index, player.eye_position())) else 0
	if not bool(doors.call("sweeps", index, at, MmPlayer.BODY_RADIUS, player.hull_height(), 0.0, 1.0, flip)):
		return false
	state["open_check"] = now() + 1.0
	var shut: Transform3D = doors.call("panel_transform", index, 0.0)
	var normal := shut.basis.z.normalized()
	normal.y = 0.0
	if normal.dot(at - shut.origin) < 0.0:
		normal = -normal
	var width := float((spec["size"] as Array)[0])
	var point := Vector3(shut.origin.x, at.y, shut.origin.z) + normal * (width + MmPlayer.BODY_RADIUS + 0.2)
	if nav.is_ready():
		var floor_at := nav.closest(point)
		if Vector2(floor_at.x - point.x, floor_at.z - point.z).length() > 0.5 or absf(floor_at.y - at.y) > MmPlayer.BODY_STEP + 0.1:
			_give_up_goal(player, state)
			return true
		point = floor_at
	if bool(doors.call("sweeps", index, point, MmPlayer.BODY_RADIUS, player.hull_height(), 0.0, 1.0, flip)):
		# No room on this side to stand clear of it (a cupboard's door): somewhere else.
		_give_up_goal(player, state)
		return true
	state["opening"] = {"index": index, "at": point, "until": now() + 3.0}
	return true


## The other half of the same: an open panel across the way with no room round it, and the bot
## standing in the arc it would sweep shutting. Plans a point out of that arc, back from the
## hinge, on the mesh; true when it did.
func _plan_shut_from_clear(player: MmPlayer, state: Dictionary, index: int) -> bool:
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors")
	var at := player.controller.state.position
	var f: float = doors.call("fraction", index, int(game.get("_tick")))
	var spec: Dictionary = ((doors.get("doors") as Array)[index] as Dictionary)["spec"]
	var hinge: Vector3 = (doors.call("panel_ends", index, f) as PackedVector3Array)[0]
	var out := Vector3(at.x - hinge.x, 0.0, at.z - hinge.z)
	if out.length() < 0.05:
		return false
	var width := float((spec["size"] as Array)[0])
	var point := Vector3(hinge.x, at.y, hinge.z) + out.normalized() * (width + MmPlayer.BODY_RADIUS + 0.25)
	if not nav.is_ready():
		return false
	var floor_at := nav.closest(point)
	if Vector2(floor_at.x - point.x, floor_at.z - point.z).length() > 0.5 or absf(floor_at.y - at.y) > MmPlayer.BODY_STEP + 0.1 \
			or bool(doors.call("sweeps", index, floor_at, MmPlayer.BODY_RADIUS, player.hull_height(), f, 0.0)):
		return false
	state["opening"] = {"index": index, "at": floor_at, "until": now() + 3.0, "open": false}
	return true


## Walks back to `state.opening`'s point, facing the door, and presses use once it is out of the
## swing: to open it, or (`open` false) to shut it. Returns true while it is at it.
func _open_from_clear(player: MmPlayer, command: DotFpsCommand, state: Dictionary) -> bool:
	var opening: Dictionary = state.get("opening", {})
	if opening.is_empty():
		return false
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors") if map != null else null
	var index: int = opening["index"]
	var want_open := bool(opening.get("open", true))
	if doors == null or now() > float(opening["until"]) or bool(doors.call("is_open", index)) == want_open:
		state["opening"] = {}
		state["path"] = PackedVector3Array()
		if doors != null and bool(doors.call("is_open", index)) != want_open:
			# It would not move (somebody else in its swing): somewhere else, or the next step
			# plans the same step back.
			state["open_check"] = now() + 2.0
			_give_up_goal(player, state)
			if not want_open:
				_note_shut_failed(state, index)
		return false
	var at := player.controller.state.position
	var tick := int(game.get("_tick"))
	var f: float = doors.call("fraction", index, tick)
	var panel_at: Vector3 = (doors.call("panel_transform", index, f) as Transform3D).origin
	_look(player, command, panel_at)
	var point: Vector3 = opening["at"]
	var in_swing: bool = doors.call("sweeps", index, at, MmPlayer.BODY_RADIUS, player.hull_height(), f, 0.0) if not want_open \
		else doors.call("sweeps", index, at, MmPlayer.BODY_RADIUS, player.hull_height(), 0.0, 1.0,
			1 if bool(doors.call("flips_for", index, player.eye_position())) else 0)
	if in_swing and Vector2(point.x - at.x, point.z - at.z).length() > 0.2:
		_walk(command, point - at)
		return true
	command.move = Vector2.ZERO
	# Out of the swing and pressing: a second of that without the door moving is somebody else
	# in its way, and the rest of the three seconds was a bot standing facing a door at the top
	# of a flats stair (`headless_bots` round 44).
	if not opening.has("pressing"):
		opening["pressing"] = now()
	elif now() - float(opening["pressing"]) > 1.0 and not bool(doors.call("moving", index, tick)):
		opening["until"] = now()
	var facing: int = doors.call("door_for", player.eye_position(), player.aim_direction())
	state["use_now"] = facing == index and not bool(doors.call("moving", index, int(game.get("_tick"))))
	return true


func _before(state: Dictionary, key: String) -> bool:
	return now() < float(state.get(key, -INF))


## Walks [param player] along the mesh to [param goal]. Returns true when there.
func _walk_to(player: MmPlayer, command: DotFpsCommand, state: Dictionary, goal: Vector3, sprint: bool, look: bool = true, chaser: bool = false) -> bool:
	# Shutting a door that stands open across the way (see the detour below).
	if _shut_door(player, command, state):
		return false
	# Stepping back out of a shut door's swing to open it (see `_open_from_clear`).
	if _open_from_clear(player, command, state):
		return false
	var at := player.controller.state.position
	var flat := Vector2(goal.x - at.x, goal.z - at.z).length()
	if player.controller.has_modifier(MmPlayer.MmController.HOLD):
		# Held (an admin's freeze): going nowhere is the rule, not being stuck, and the
		# walk starts its count afresh when let go.
		state["stuck"] = [at, now()]
		state["linger_at"] = Vector3.INF
		return false

	if flat < 0.6 and absf(goal.y - at.y) < 1.2:
		state["path"] = PackedVector3Array()
		# There: whatever held it up on the way is over.
		state["stuck_at"] = Vector3.INF
		state["stuck_count"] = 0
		state["linger_at"] = Vector3.INF
		return true

	_note_lingering(state, at, now())

	var t := now()
	if _linger_by_door(player, state, at, t):
		return false
	var path: PackedVector3Array = state["path"]
	if path.is_empty() or (state["goal"] as Vector3).distance_to(goal) > 1.0 or t - float(state["path_at"]) > 3.0:
		path = nav.path(at, goal) if nav.is_ready() else PackedVector3Array()
		# A path that goes nowhere (it ends where the bot stands, well short of the goal) starts on
		# an island of the mesh: a stair's landing or a desk top it climbed or hopped onto. Straight
		# for the goal, which steps it off; following the path kept a bot on a school landing
		# beside an open door for half a minute (`headless_bots` round 11).
		if path.size() < 2 or (path.size() == 2 and Vector2(path[1].x - at.x, path[1].z - at.z).length() < 0.5 \
				and Vector2(goal.x - at.x, goal.z - at.z).length() > 2.0):
			path = PackedVector3Array([at, goal])
		state["path"] = path
		state["corner"] = 1
		state["goal"] = goal
		state["path_at"] = t

	var corner := _next_corner(state, at)

	# An open door's panel across the way (the mesh is baked without doors, so a path runs
	# through wherever a panel stands): round its free edge, then on. Without it a bot stood
	# pressed into the corner behind an open fire door for half a minute (`hns-bot-door-corner-1`)
	# and a bot spent a whole round against one at the top of a stair, then was caught in the
	# seek's first three seconds.
	var detour: PackedVector3Array = state.get("detour", PackedVector3Array())
	if detour.is_empty() and t >= float(state.get("detour_check", -INF)):
		var round_door := _door_detour(at, corner, chaser)
		detour = round_door[1]
		if detour.is_empty() and int(round_door[0]) >= 0:
			# A panel across the way with no floor round it: shut it, as a person would, and the
			# walk opens it again away from this side. Not while standing where it swings.
			var index := int(round_door[0])
			var map: Node3D = game.get("map")
			var doors: Object = map.get("doors")
			var f: float = doors.call("fraction", index, int(game.get("_tick")))
			if not _shut_failed(state, index) \
					and not bool(doors.call("sweeps", index, at, MmPlayer.BODY_RADIUS, player.hull_height(), f, 0.0)):
				state["shut"] = {"index": index, "until": t + 1.5, "count": false}
			elif not _shut_failed(state, index) and _plan_shut_from_clear(player, state, index):
				# Standing where it swings: a step back out of its way first, then shut it.
				state["detour_check"] = t + 1.0
				return false
			else:
				# It would not shut, or there is no floor to stand clear of it on: somewhere else,
				# by another way. Giving up every second while standing in the swing of a panel
				# across a manor landing kept a bot there for twenty seconds.
				_give_up_goal(player, state)
				state["detour_check"] = t + 1.0
				return false
			state["detour_check"] = t + 0.7
		elif not detour.is_empty():
			# Round the same panel again soon after: the way on goes back through it (the path
			# is baked as if the door were not there). Somewhere else, rather than circling it
			# (`headless_bots` round 3, a bot round a village door for half a minute).
			if int(round_door[0]) == int(state.get("detour_door", -1)) and t - float(state.get("detour_at", -INF)) < DETOUR_AGAIN:
				state["detour_door"] = -1
				_give_up_goal(player, state)
				state["detour"] = PackedVector3Array()
				return false
			state["detour_door"] = int(round_door[0])
			state["detour_at"] = t
			state["detour_until"] = t + DETOUR_SECONDS
			state["detour_pose"] = _door_fraction(int(round_door[0]))
	if not detour.is_empty():
		var round_index := int(state.get("detour_door", -1))
		if round_index >= 0 and absf(_door_fraction(round_index) - float(state.get("detour_pose", 0.0))) > 0.05:
			# The panel has moved since the way round it was planned (somebody was opening it):
			# planned on a door still swinging, a chaser pushed into where the panel came to rest
			# for four seconds at the school's fire door (`headless_bots` round 41). Again, now.
			detour = PackedVector3Array()
			state["detour_check"] = -INF
		elif t > float(state.get("detour_until", -INF)):
			detour = PackedVector3Array()
			state["detour_check"] = t + 1.0
		elif Vector2(detour[0].x - at.x, detour[0].z - at.z).length() < 0.35:
			detour.remove_at(0)
			if detour.is_empty():
				# Past it: a fresh path from here.
				state["path"] = PackedVector3Array()
		if not detour.is_empty():
			corner = detour[0]
	state["detour"] = detour
	var dir := Vector3(corner.x - at.x, 0.0, corner.z - at.z)
	if detour.is_empty() and _plan_open_from_clear(player, state, dir):
		return false

	# Stuck on something the mesh does not know (an open door's panel stands across a path baked
	# without doors): step round it, sideways and back, for a moment.
	if t < float(state.get("sidestep_until", -INF)) and dir.length() > 0.01:
		dir = dir.normalized().rotated(Vector3.UP, deg_to_rad(110.0) * float(state.get("sidestep_side", 1.0)))

	if look:
		_look(player, command, Vector3(corner.x, player.eye_position().y + (corner.y - at.y) * 0.5, corner.z))
	state["walk_dir"] = dir
	_walk(command, dir)
	command.set_button(DotFpsCommand.BUTTON_SPRINT, sprint)

	# A jump-up link (the annotator found a ledge within a body's jump): hop at its foot.
	if corner.y - at.y > MmPlayer.BODY_STEP + 0.05 and player.controller.state.is_grounded():
		for foot in _jump_feet:
			if Vector2(foot.x - at.x, foot.z - at.z).length() < 1.2 and absf(foot.y - at.y) < 0.6:
				command.set_button(DotFpsCommand.BUTTON_JUMP, true)
				break

	# A ceiling low ahead: crouch under it.
	if dir.length() > 0.01:
		var ahead := at + dir.normalized() * 0.6
		if not _los(ahead + Vector3(0.0, 0.5, 0.0), ahead + Vector3(0.0, MmPlayer.BODY_HEIGHT + 0.05, 0.0)):
			command.set_button(DotFpsCommand.BUTTON_CROUCH, true)

	_unstick(player, command, state)
	return false


## `[door, points]`: two points round the free edge of the open door panel standing between
## [param at] and [param corner] (one this side of the edge, one past it on the far side), or
## `[-1, empty]` when no panel is in the way or there is no floor round its edge. A panel is in
## the way when the next stretch of the walk crosses it.
func _door_detour(at: Vector3, corner: Vector3, chaser: bool = false) -> Array:
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors") if map != null else null
	var none := [-1, PackedVector3Array()]
	if doors == null or int(doors.call("count")) == 0:
		return none
	var to := Vector2(corner.x - at.x, corner.z - at.z)
	if to.length() < 0.05:
		return none
	var a := Vector2(at.x, at.z)
	var heading := to.normalized()
	var b := a + heading * minf(to.length(), DETOUR_LOOK)
	var clear := MmPlayer.BODY_RADIUS + 0.08
	var tick := int(game.get("_tick"))
	var specs: Array = doors.get("doors")
	for index in range(specs.size()):
		var spec: Dictionary = (specs[index] as Dictionary)["spec"]
		if str(spec["motion"]) != "swing":
			continue
		var c: Array = spec["at"]
		if not _door_on_level(spec, at) or Vector2(float(c[0]) - at.x, float(c[2]) - at.z).length() > 3.5:
			continue
		var f: float = doors.call("fraction", index, tick)
		# Shut or nearly: a doorway, the use key's business.
		if f < 0.1:
			continue
		var ends: PackedVector3Array = doors.call("panel_ends", index, f)
		var h := Vector2(ends[0].x, ends[0].z)
		var e := Vector2(ends[1].x, ends[1].z)
		var length := h.distance_to(e)
		if length < 0.1:
			continue
		var along := (e - h) / length
		var normal := Vector2(-along.y, along.x)
		var side_a := normal.dot(a - h)
		var side_b := normal.dot(b - h)
		# The panel is in the way only when the walk crosses it: the corner on its far side and the
		# crossing on the panel itself, not at its hinge end (that is the doorway, and a body
		# rubbing the frame slides past). Walking alongside it on the corner's own side is not.
		var blocked := false
		if signf(side_a) != signf(normal.dot(Vector2(corner.x, corner.z) - h)) and signf(side_a) != signf(side_b) \
				and absf(side_a - side_b) > 0.001:
			var cross := a + (b - a) * (side_a / (side_a - side_b))
			var on := along.dot(cross - h)
			blocked = on > 0.1 and on < length + clear
		if not blocked:
			continue
		var near := signf(side_a) if side_a != 0.0 else 1.0
		var k := MmPlayer.BODY_RADIUS + 0.35
		var first := e + along * k + normal * near * 0.3
		# Past the tip by more than a body's radius: at 0.15 the line to this point passed 0.3 m from
		# it for a chaser coming back out of the pocket behind the panel, and clipped it (hs_village's
		# door 13, nine seconds against its free edge).
		var second := e + along * (MmPlayer.BODY_RADIUS + 0.12) - normal * near * k
		var out := PackedVector3Array([Vector3(first.x, at.y, first.y), Vector3(second.x, at.y, second.y)])
		# Room past the free edge for a body: a gap narrower than a body (the edge near a wall)
		# is no way round, and a bot tried it for a minute in a flat's corridor.
		var waist := Vector3(0.0, 0.6, 0.0)
		var edge := Vector3(e.x, at.y, e.y) + waist
		if not _los(edge, edge + Vector3(along.x, 0.0, along.y) * (k + MmPlayer.BODY_RADIUS)):
			return [index, PackedVector3Array()]
		# A chaser only: the gap between the free edge and a wall or fence on the detour's side
		# must take a body, or the first waypoint wedges it (hs_village's back door, 0.71 m from a
		# fence). A fleeing bot keeps the old behaviour: a door-only result there left it
		# wedged against the panel (hs_camp's boathouse door).
		if chaser:
			var pinch := edge + Vector3(-along.y, 0.0, along.x) * near * -1.0 * (MmPlayer.BODY_RADIUS * 2.0 + 0.05)
			if not _los(edge, pinch):
				return [index, PackedVector3Array()]
		if nav.is_ready():
			for i in range(out.size()):
				var floor_at := nav.closest(out[i])
				if Vector2(floor_at.x - out[i].x, floor_at.z - out[i].z).length() > 0.45 or absf(floor_at.y - at.y) > MmPlayer.BODY_STEP + 0.1:
					# No way round (the free edge is against a wall): the door, but no points.
					return [index, PackedVector3Array()]
				out[i] = floor_at
		return [index, out]
	return none


func _door_fraction(index: int) -> float:
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors") if map != null else null
	return float(doors.call("fraction", index, int(game.get("_tick")))) if doors != null else 0.0


func _next_corner(state: Dictionary, at: Vector3) -> Vector3:
	var path: PackedVector3Array = state["path"]
	var corner: int = state["corner"]
	# Passed when near it flat and on its level: on a switchback stair the corner of the flight
	# above is right over the bot's head, and skipping it sent bots round in circles.
	# A sharp turn (a doorway entered from along its wall) is passed only close to: passed at
	# half a metre, a bot cut the corner into the jamb and stood there (`headless_bots` round 13,
	# the manor's upstairs library door).
	while corner < path.size() - 1 and Vector2(path[corner].x - at.x, path[corner].z - at.z).length() < _pass_within(path, corner) \
			and absf(path[corner].y - at.y) < 0.9:
		# Not until the way to the next one is open to a body: passed early, a bot turning round
		# the end of a gallery's rail walked into the rail's end post and stood there thirteen
		# seconds (`headless_bots` round 7, the manor's landing).
		if Vector2(path[corner].x - at.x, path[corner].z - at.z).length() > CORNER_CLOSE and not _body_clear(at, path[corner + 1]):
			break
		corner += 1
	state["corner"] = corner
	return path[mini(corner, path.size() - 1)] if not path.is_empty() else at


## Whether a body walking straight from [param at] to [param to] on one level meets no wall or
## furniture at the height of a rail's bars: three lines, its middle and either side. Not the
## doors: an open panel across the way is `_door_detour`'s, and counted here a corner beside one
## was never passed, because a body cannot come within reach of a corner on a panel's edge
## (`headless_bots` round 23, the school's gym doors).
func _body_clear(at: Vector3, to: Vector3) -> bool:
	if absf(to.y - at.y) > MmPlayer.BODY_STEP:
		return true
	var flat := Vector3(to.x - at.x, 0.0, to.z - at.z)
	if flat.length() < 0.05:
		return true
	var world := (game as Node3D).get_world_3d()
	if world == null:
		return true
	var space := world.direct_space_state
	var physics: DotPhysicsLayout = game.get("physics")
	var mask := physics.layer_mask(&"world") | physics.layer_mask(&"prop") if physics != null else 1
	var side := flat.normalized().cross(Vector3.UP) * MmPlayer.BODY_RADIUS
	for height in [0.47, 0.97]:
		var up := Vector3(0.0, height, 0.0)
		for off in [Vector3.ZERO, side, -side]:
			var query := PhysicsRayQueryParameters3D.create(at + up + off, Vector3(to.x, at.y, to.z) + up + off, mask, _door_rids())
			if not space.intersect_ray(query).is_empty():
				return false
	return true


## The doors' bodies, for a ray that looks past them; gathered once for each map.
func _door_rids() -> Array[RID]:
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors") if map != null else null
	if doors == null:
		return []
	var specs: Array = doors.get("doors")
	if _door_rid_list.size() != specs.size() or _door_rid_doors != doors:
		_door_rid_list.clear()
		_door_rid_doors = doors
		for door: Dictionary in specs:
			var body: Variant = door.get("body")
			if body is CollisionObject3D:
				_door_rid_list.append((body as CollisionObject3D).get_rid())
	return _door_rid_list


## How near a bot must come to corner [param i] of [param path] to count it passed: half a
## metre where the path runs on nearly straight, less where it turns sharply.
static func _pass_within(path: PackedVector3Array, i: int) -> float:
	if i <= 0 or i >= path.size() - 1:
		return 0.5
	var into := Vector2(path[i].x - path[i - 1].x, path[i].z - path[i - 1].z)
	var out := Vector2(path[i + 1].x - path[i].x, path[i + 1].z - path[i].z)
	if into.length() < 0.01 or out.length() < 0.01:
		return 0.5
	return 0.5 if absf(into.angle_to(out)) < deg_to_rad(45.0) else 0.3


## Moves along [param world_dir] (flat) whatever way the view is turned.
static func _walk(command: DotFpsCommand, world_dir: Vector3) -> void:
	var flat := Vector3(world_dir.x, 0.0, world_dir.z)
	if flat.length() < 0.01:
		command.move = Vector2.ZERO
		return
	flat = flat.normalized()
	var yaw := deg_to_rad(command.yaw)
	var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	command.move = Vector2(flat.dot(right), flat.dot(forward)).limit_length(1.0)


## Turns toward [param point] at the bot's turn rate.
func _look(player: MmPlayer, command: DotFpsCommand, point: Vector3) -> void:
	var view := _aim_of(player).look_at_point(player.eye_position(), point, dt())
	command.yaw = view.x
	command.pitch = clampf(view.y, -60.0, 60.0)
	# The walk was worked out against the old view; keep it going the same way in the world.


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


## Hops, then steps aside, then asks for somewhere else, when it has made no headway for
## [constant STUCK_SECONDS]. The count goes back to nothing only once the bot is
## [constant STUCK_LEFT] from where it first stuck: with a reset on any 0.35 m of movement, a
## step aside and back reset it every time, so "somewhere else" never came and a bot stood
## against an open fire door for the whole hide (`headless_bots` round 38).
func _unstick(player: MmPlayer, command: DotFpsCommand, state: Dictionary) -> void:
	var mark: Array = state["stuck"]
	var at := player.controller.state.position
	var t := now()
	if t - float(mark[1]) < STUCK_SECONDS:
		return
	var stuck := Vector2(at.x - (mark[0] as Vector3).x, at.z - (mark[0] as Vector3).z).length() < 0.3
	var first: Vector3 = state.get("stuck_at", Vector3.INF)
	if not stuck and first != Vector3.INF and Vector2(at.x - first.x, at.z - first.z).length() < STUCK_LEFT:
		# Moving, but round the same spot.
		state["stuck"] = [at, t]
		return
	# On the ground, or caught on an edge in the air without rising or falling: a bot pressed
	# into a door's jamb at the top of a camp cabin's steps hung a few centimetres up for half a
	# minute, never on the ground, so it was never stuck (`headless_bots` round 18).
	var hung := player.controller.state.mode == DotFpsState.Mode.AIR and absf(player.controller.state.velocity.y) < 1.0
	if stuck and (player.controller.state.mode == DotFpsState.Mode.GROUND or hung):
		if first == Vector3.INF:
			state["stuck_at"] = at
		# A panel it could not see coming: round it, before anything blinder.
		state["detour_check"] = -INF
		# Caught on a doorway's frame on the way through: square to the doorway's middle and
		# through, before a hop or a step aside.
		if int(state.get("stuck_count", 0)) == 0 and _through_doorway(state, at, t):
			state["stuck_count"] = 1
			state["stuck"] = [at, t]
			return
		var stream: DotRandomStream = state["stream"]
		# Every other time a hop (a kerb, a step), else a step aside. Never a hop at something
		# waist-high: that is a desk, and a bot hopped up on one stood there for half a minute
		# (`headless_bots` round 11, a school classroom).
		var ahead := _next_corner(state, at) - at
		ahead.y = 0.0
		var waist := at + Vector3(0.0, 0.6, 0.0)
		# Nor under a low ceiling (a crawl space): a hop there goes nowhere but into the floor above.
		var headroom := _los(at + Vector3(0.0, 0.5, 0.0), at + Vector3(0.0, MmPlayer.BODY_HEIGHT + 0.05, 0.0))
		var low_only := headroom and (ahead.length() < 0.01 or _los(waist, waist + ahead.normalized() * 0.8))
		# Or the next corner is a step or more up and close: a bot beside a stair's side edge (the
		# path cuts the flight's corner) pushed at a riser it can hop and sidestepped away from it
		# (`headless_bots` round 36, the camp cabin's steps, eight seconds).
		var up := _next_corner(state, at).y - at.y
		var hop_up := up > 0.3 and up < 0.8 and ahead.length() < 0.8 and headroom
		if (int(state.get("stuck_count", 0)) % 2 == 0 and low_only) or hop_up:
			command.set_button(DotFpsCommand.BUTTON_JUMP, true)
		else:
			state["sidestep_until"] = t + 0.7
			state["sidestep_side"] = 1.0 if stream.next_unit() < 0.5 else -1.0
		state["path"] = PackedVector3Array()
		state["stuck_count"] = int(state.get("stuck_count", 0)) + 1
		# Stuck three times on the way to one place: somewhere else.
		if int(state["stuck_count"]) >= 3:
			_give_up_goal(player, state)
	elif not stuck:
		state["stuck_count"] = 0
		state["stuck_at"] = Vector3.INF
	state["stuck"] = [at, t]


## Stuck within a metre of an open doorway the walk goes through (the next corner is on its
## far side): two points, square to the doorway's middle on this side and past it on the far
## side, as the detour. The path is baked at exactly a body's radius from the frame, so a bot a
## little off it caught the jamb: a bot climbing a camp cabin's steps stood against one for
## twelve seconds (`headless_bots` round 12). Only once stuck: steering every path through every
## doorway's middle sent bots round in circles elsewhere. True when it set one.
func _through_doorway(state: Dictionary, at: Vector3, t: float) -> bool:
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors") if map != null else null
	if doors == null or not nav.is_ready():
		return false
	var corner := _next_corner(state, at)
	var tick := int(game.get("_tick"))
	var specs: Array = doors.get("doors")
	for index in range(specs.size()):
		var spec: Dictionary = (specs[index] as Dictionary)["spec"]
		if not _door_on_level(spec, at) or float(doors.call("fraction", index, tick)) < 0.9:
			continue
		var frame: Transform3D = doors.call("panel_transform", index, 0.0)
		var middle := Vector3(frame.origin.x, at.y, frame.origin.z)
		if Vector2(middle.x - at.x, middle.z - at.z).length() > 1.2:
			continue
		var normal := frame.basis.z
		normal.y = 0.0
		if normal.length() < 0.01:
			continue
		normal = normal.normalized()
		var here := normal.dot(at - middle)
		if signf(here) == signf(normal.dot(corner - middle)):
			continue
		var near := signf(here) if here != 0.0 else 1.0
		var out := PackedVector3Array([middle + normal * near * 0.6, middle - normal * near * 0.8])
		for i in range(out.size()):
			var floor_at := nav.closest(out[i])
			if Vector2(floor_at.x - out[i].x, floor_at.z - out[i].z).length() > 0.45 or absf(floor_at.y - at.y) > MmPlayer.BODY_STEP + 0.3:
				return false
			out[i] = floor_at
		state["detour"] = out
		state["detour_until"] = t + 3.0
		state["detour_door"] = -1
		state["sidestep_until"] = -INF
		return true
	return false


## Round and round one spot beside an open door's panel for [constant LINGER_SHUT]: whatever
## the walk is trying there is not getting it past (a free edge against a bench, a jamb's corner
## it keeps catching). The panel is the thing in the way, so the bot shuts it, as a person
## would, and the walk opens it again from its own side; standing where it swings, it steps
## back out of the way first, or with no floor for that goes somewhere else. Once for each
## spot. True when it started any of them.
func _linger_by_door(player: MmPlayer, state: Dictionary, at: Vector3, t: float) -> bool:
	var anchor: Vector3 = state.get("linger_at", Vector3.INF)
	var since := float(state.get("linger_since", t))
	if anchor == Vector3.INF or t - since < LINGER_SHUT:
		return false
	if float(state.get("linger_acted", -INF)) == since:
		# Shut it, or stepped back to, and still round the same spot: somewhere else, once.
		if t - since < LINGER_GIVE_UP or float(state.get("linger_gave", -INF)) == since or _open_door_index_near(anchor, 2.0) < 0:
			return false
		state["linger_gave"] = since
		_give_up_goal(player, state)
		state["detour"] = PackedVector3Array()
		return true
	var index := _open_door_index_near(anchor, 2.0)
	if index < 0:
		return false
	state["linger_acted"] = since
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors")
	var f: float = doors.call("fraction", index, int(game.get("_tick")))
	if not bool(doors.call("sweeps", index, at, MmPlayer.BODY_RADIUS, player.hull_height(), f, 0.0)):
		state["shut"] = {"index": index, "until": t + 1.5, "count": false}
		state["path"] = PackedVector3Array()
		state["detour"] = PackedVector3Array()
		return true
	if _shut_failed(state, index) or not _plan_shut_from_clear(player, state, index):
		_give_up_goal(player, state)
	return true


## A door this bot tried to shut and could not, for [constant SHUT_FAILED_FOR]: not tried again
## from here. Forgotten at every give-up, it was planned again at once, and a bot stood facing a
## door at the top of a flats stair for fifteen seconds, stepping back to shut it every three
## (`headless_bots` round 44).
func _note_shut_failed(state: Dictionary, index: int) -> void:
	state["shut_failed"] = index
	state["shut_failed_at"] = now()


func _shut_failed(state: Dictionary, index: int) -> bool:
	return int(state.get("shut_failed", -1)) == index and now() - float(state.get("shut_failed_at", -INF)) < SHUT_FAILED_FOR


## Measures, apart from what [method _unstick] does about it, how long a walking bot has been
## within [constant STUCK_LEFT] of one spot without getting there: the suite's number.
## Whether an open (or opening) door's panel is within [param reach] of [param at], flat.
func _open_door_near(at: Vector3, reach: float) -> bool:
	return _open_door_index_near(at, reach) >= 0


## The nearest open (or opening) door whose panel is within [param reach] of [param at], flat;
## -1 for none.
func _open_door_index_near(at: Vector3, reach: float) -> int:
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors") if map != null else null
	if doors == null:
		return -1
	var best := -1
	var nearest := reach
	var tick := int(game.get("_tick"))
	for index in range(int(doors.call("count"))):
		var f: float = doors.call("fraction", index, tick)
		if f < 0.1:
			continue
		if not _door_on_level((doors.get("doors") as Array)[index]["spec"], at):
			continue
		var ends: PackedVector3Array = doors.call("panel_ends", index, f)
		var p := Geometry2D.get_closest_point_to_segment(Vector2(at.x, at.z), Vector2(ends[0].x, ends[0].z), Vector2(ends[1].x, ends[1].z))
		var d := p.distance_to(Vector2(at.x, at.z))
		if d < nearest:
			nearest = d
			best = index
	return best


## Whether a door's panel is on the storey of somebody standing at [param at]: its foot within a
## step of their feet and its head above a crouched body's. Within a flat
## 2 m and 2.5 m up, a cabin's door counted for a bot in the crawl space under its floor,
## which went round a panel in the room over its head for fourteen seconds (`headless_bots`
## round 30, the camp).
static func _door_on_level(spec: Dictionary, at: Vector3) -> bool:
	var c: Array = spec["at"]
	var half := float((spec["size"] as Array)[1]) * 0.5
	return float(c[1]) - half - at.y < MmPlayer.BODY_STEP + 0.1 and float(c[1]) + half - at.y > MmPlayer.BODY_CROUCH


## Gives up on a goal it cannot reach: the way ahead is shunned for a while, and the next
## tick's role code picks somewhere else.
func _give_up_goal(player: MmPlayer, state: Dictionary) -> void:
	var at := player.controller.state.position
	state["stuck_count"] = 0
	state["stuck_at"] = Vector3.INF
	var ahead_path: PackedVector3Array = state["path"]
	var ahead_at := int(state.get("corner", 1))
	state["shunned"] = ahead_path[ahead_at] if ahead_at < ahead_path.size() else at
	state["shunned_until"] = now() + SHUN_FOR
	state["path"] = PackedVector3Array()
	state["goal"] = _wander_place(at, state, 14.0)
	state["picked_at"] = now()


func _note_lingering(state: Dictionary, at: Vector3, t: float) -> void:
	var anchor: Vector3 = state.get("linger_at", Vector3.INF)
	if anchor == Vector3.INF or Vector2(at.x - anchor.x, at.z - anchor.z).length() > STUCK_LEFT:
		state["linger_at"] = at
		state["linger_since"] = t
		return
	var held := t - float(state["linger_since"])
	if held > longest_stuck and _open_door_near(anchor, 2.0):
		longest_stuck = held
		longest_stuck_at = anchor
		longest_stuck_who = state.get("who", &"")


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
