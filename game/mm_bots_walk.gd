extends "mm_bots_doors.gd"

## The walk of [code]mm_bots.gd[/code]: along the mesh, round a door's panel, out of a pocket. Path-based
## base, no class_name.

## Walks [param player] along the mesh to [param goal]. Returns true when there.
func _walk_to(player: MmPlayer, command: DotFpsCommand, state: Dictionary, goal: Vector3, sprint: bool, look: bool = true, chaser: bool = false) -> bool:
	# For the soak: a bot that did not ask to walk this tick (a murderer holding still within
	# reach of its target) is waiting, whatever its old goal says.
	state["walk_at"] = now()
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
	_refresh_path(state, at, goal, t)
	var corner := _next_corner(state, at)

	if _plan_detour(player, state, at, corner, chaser, t):
		return false
	_follow_detour(state, at, t)
	var detour: PackedVector3Array = state["detour"]
	if not detour.is_empty():
		corner = detour[0]
	var dir := Vector3(corner.x - at.x, 0.0, corner.z - at.z)
	if detour.is_empty() and _plan_open_from_clear(player, state, dir):
		return false

	# Stuck on something the mesh does not know (an open door's panel stands across a path baked
	# without doors): step round it, sideways and back, for a moment.
	if t < float(state.get("sidestep_until", -INF)) and dir.length() > 0.01:
		dir = dir.normalized().rotated(Vector3.UP, deg_to_rad(110.0) * float(state.get("sidestep_side", 1.0)))

	_step_toward(player, command, state, at, corner, dir, sprint, look)
	_unstick(player, command, state)
	return false


## A new path to [param goal] when there is none, the goal moved, or it is three seconds old.
func _refresh_path(state: Dictionary, at: Vector3, goal: Vector3, t: float) -> void:
	var path: PackedVector3Array = state["path"]
	if not path.is_empty() and (state["goal"] as Vector3).distance_to(goal) <= 1.0 and t - float(state["path_at"]) <= 3.0:
		return

	path = nav.path(at, goal) if nav.is_ready() else PackedVector3Array()
	# A path that goes nowhere (it ends where the bot stands, well short of the goal) starts on
	# an island of the mesh: a stair's landing or a desk top it climbed or hopped onto. Straight
	# for the goal, which steps it off; following the path kept a bot on a school landing
	# beside an open door for half a minute (`headless_bots` round 11).
	if path.size() < 2 or (path.size() == 2 and Vector2(path[1].x - at.x, path[1].z - at.z).length() < 0.5 \
			and Vector2(goal.x - at.x, goal.z - at.z).length() > 2.0):
		path = PackedVector3Array([at, goal])
	path = _off_mesh_start(state, at, goal, path)
	state["path"] = path
	state["corner"] = 1
	state["goal"] = goal
	state["path_at"] = t


## An open door's panel across the way (the mesh is baked without doors, so a path runs through
## wherever a panel stands): round its free edge, then on. Plans `state["detour"]`; true when the
## walk must stop this tick (a door to shut, a step back, or a goal given up).
func _plan_detour(player: MmPlayer, state: Dictionary, at: Vector3, corner: Vector3, chaser: bool, t: float) -> bool:
	var detour: PackedVector3Array = state.get("detour", PackedVector3Array())
	if not detour.is_empty() or t < float(state.get("detour_check", -INF)):
		state["detour"] = detour
		return false

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
			return true
		else:
			# It would not shut, or there is no floor to stand clear of it on: somewhere else,
			# by another way. Giving up every second while standing in the swing of a panel
			# across a manor landing kept a bot there for twenty seconds.
			_give_up_goal(player, state)
			state["detour_check"] = t + 1.0
			return true
		state["detour_check"] = t + 0.7
	elif not detour.is_empty():
		# Round the same panel again soon after: the way on goes back through it (the path is
		# baked as if the door were not there). Somewhere else, rather than circling it
		# (`headless_bots` round 3, a bot round a village door for half a minute).
		if int(round_door[0]) == int(state.get("detour_door", -1)) and t - float(state.get("detour_at", -INF)) < DETOUR_AGAIN:
			state["detour_door"] = -1
			_give_up_goal(player, state)
			state["detour"] = PackedVector3Array()
			return true
		state["detour_door"] = int(round_door[0])
		state["detour_at"] = t
		state["detour_until"] = t + DETOUR_SECONDS
		state["detour_pose"] = _door_fraction(int(round_door[0]))
	state["detour"] = detour
	return false


## Follows the detour: dropped when the panel has moved or the time is up, stepped on when its
## first point is reached, and a fresh path from here once it is done.
func _follow_detour(state: Dictionary, at: Vector3, t: float) -> void:
	var detour: PackedVector3Array = state["detour"]
	if detour.is_empty():
		return

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
	state["detour"] = detour


## Looks and walks toward [param corner], hopping at a jump-up link's foot and crouching under a
## low ceiling.
func _step_toward(player: MmPlayer, command: DotFpsCommand, state: Dictionary, at: Vector3, corner: Vector3, dir: Vector3, sprint: bool, look: bool) -> void:
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

	if dir.length() > 0.01:
		var ahead := at + dir.normalized() * 0.6
		if not _los(ahead + Vector3(0.0, 0.5, 0.0), ahead + Vector3(0.0, MmPlayer.BODY_HEIGHT + 0.05, 0.0)):
			command.set_button(DotFpsCommand.BUTTON_CROUCH, true)


## The mesh stops a body's radius short of a wall, so a bot pressed into a pocket (a corner
## between a wall and furniture, which a sidestep can leave it in) has its path start snapped to
## the nearest mesh, often the far side of that wall, and it pushes at the wall for the rest of the
## round (`mm_motel` soak, a cabin's corner, 90 s). Walk back to where the last good path began, then on.
func _off_mesh_start(state: Dictionary, at: Vector3, goal: Vector3, path: PackedVector3Array) -> PackedVector3Array:
	if path.size() < 2:
		return path
	var start := path[0]
	var gap := Vector2(start.x - at.x, start.z - at.z).length()
	if gap < 0.5 or absf(start.y - at.y) > MmPlayer.BODY_STEP or _body_clear(at, start):
		if gap < 0.5:
			state["safe_at"] = at
		return path
	var safe: Vector3 = state.get("safe_at", Vector3.INF)
	if safe == Vector3.INF or safe.distance_to(at) > 8.0 or not _los(at + Vector3(0.0, 0.5, 0.0), safe + Vector3(0.0, 0.5, 0.0)):
		return path
	var onward := nav.path(safe, goal)
	var out := PackedVector3Array([at, safe])
	for i in range(1, onward.size()):
		out.append(onward[i])
	return out


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
