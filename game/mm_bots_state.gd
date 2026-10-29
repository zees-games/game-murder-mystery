extends RefCounted

## The state of [code]mm_bots.gd[/code]: constants, variables, the map survey and the places a bot
## wanders to, split out so the stand-ins' file stays under the size gate. Path-based base, no class_name.

const MmPlayer := preload("mm_player.gd")
const MmBotChat := preload("mm_bot_chat.gd")

const CHANNEL := "mm.bots"


const LOUD_SPRINT := 0.45
const LOUD_RUN := 0.28
const LOUD_CROUCH := 0.06
## A scream: a death is heard across a few rooms.
const LOUD_DEATH := 1.0


const SURVEY_POINTS := 260
const SURVEY_PROPS := 160
const WATCHERS := 80
const ANNOTATE_STEPS_PER_TICK := 6
const DROP_MAX := 2.0
const LINK_SPACING := 6.0
const SWEEP_POINTS := 120


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


## Somebody with nobody else within this many metres is alone, to a murderer.
const ALONE := 9.0

## A third person within this many metres who can see the murderer spoils the moment.
const WITNESS_RANGE := 28.0

## Seconds left in the round under which a murderer stops waiting for a clean moment.
const DESPERATE := 45.0

## Seconds before the blood shows at which a murderer stops waiting.
const DESPERATE_LEAD := 20.0

## Suspicion, 0..100, at which a gunner shoots.
const SURE := 60.0

## Suspicion a gunner loses a second.
const FORGET_RATE := 2.0

## How far a bystander strays from the people it keeps with, and how often it picks a new place.
const COMPANY := 4.0
const REPICK := 5.0

## A bystander unarmed picks up a gun it can see within this many metres.
const FETCH_GUN := 25.0
## How long after a gun falls the bystanders know where, seen or not.
const FETCH_HEARD_FOR := 20.0

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


## A tunable from the game's config, or [param fallback] when the game has none (a suite's stub).
func _cfg(key: StringName, fallback: float) -> float:
	var config: Variant = game.get("config")
	return float(config.get(key)) if config != null and config.get(key) != null else fallback


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


func _before(state: Dictionary, key: String) -> bool:
	return now() < float(state.get(key, -INF))


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


## Turns toward [param point] at the bot's turn rate.
func _look(player: MmPlayer, command: DotFpsCommand, point: Vector3) -> void:
	var view := _aim_of(player).look_at_point(player.eye_position(), point, dt())
	command.yaw = view.x
	command.pitch = clampf(view.y, -60.0, 60.0)
	# The walk was worked out against the old view; keep it going the same way in the world.


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
