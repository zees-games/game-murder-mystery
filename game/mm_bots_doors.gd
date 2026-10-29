extends "mm_bots_state.gd"

## The doors of [code]mm_bots.gd[/code]: shutting, opening from clear of the swing, lingering by one and
## giving a goal up. Path-based base, no class_name.

## Remembers the doorway the bot is in and, once through and clear of the sweep, whether to shut
## the door behind it: when fleeing, or going to a place close beyond. A shut door is a wall to
## a follower's eye until opened.
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
	command.set_button(DotFpsCommand.BUTTON_CROUCH, bool(state.get("crouch", false)))
	_look(player, command, panel_at)
	var facing: int = doors.call("door_for", player.eye_position(), player.aim_direction())
	state["use_now"] = facing == index and not bool(doors.call("moving", index, int(game.get("_tick"))))
	return true


## A shut door that would swing into the bot (pinned to open one way, from the side it opens
## towards): the game refuses a use while anybody stands in the sweep, so a step back comes first.
## Plans a point out of the swing; true when it did, and `_open_from_clear` walks there.
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


func _door_fraction(index: int) -> float:
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors") if map != null else null
	return float(doors.call("fraction", index, int(game.get("_tick")))) if doors != null else 0.0


## A door this bot tried to shut and could not, for [constant SHUT_FAILED_FOR]: not tried again
## from here. Forgotten at every give-up, it was planned again at once (`headless_bots` round 44).
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


## Whether a door's panel is on the storey of somebody at [param at]: its foot within a step of
## their feet and its head above a crouched body's. A flat distance alone counted a door over a
## bot's head (`headless_bots` round 30).
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
	state["shunned_until"] = now() + _cfg(&"bot_shun_seconds", SHUN_FOR)
	state["path"] = PackedVector3Array()
	state["goal"] = _wander_place(at, state, 14.0)
	state["picked_at"] = now()


func _note_lingering(state: Dictionary, at: Vector3, t: float) -> void:
	var anchor: Vector3 = state.get("linger_at", Vector3.INF)
	# Walking is what is timed. A bot that stood still a while (a murderer biding its time, a
	# bystander at its goal) and walks off again has not been "stuck" there all along: without
	# this its old spot read as twelve seconds of lingering the moment it moved a step.
	var last := float(state.get("linger_last", t))
	state["linger_last"] = t
	if anchor == Vector3.INF or t - last > 1.0 or Vector2(at.x - anchor.x, at.z - anchor.z).length() > STUCK_LEFT:
		state["linger_at"] = at
		state["linger_since"] = t
		return
	var held := t - float(state["linger_since"])
	if held > longest_stuck and _open_door_near(anchor, 2.0):
		longest_stuck = held
		longest_stuck_at = anchor
		longest_stuck_who = state.get("who", &"")


## Circling one spot beside an open panel for [constant LINGER_SHUT] means the panel is in the way:
## shut it, then open it from its own side (a step back first if it swings there, else somewhere
## else). Once for each spot; true when it started any of them.
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
