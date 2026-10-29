extends "mm_client_build.gd"

## The Tab scoreboard and its portraits. Path-based base of [code]mm_client.gd[/code], no class_name.


## A player's face for the board: their figure's head, rendered once per skin. See
## mg-deathrun, where this came from.
func _portrait(atlas: String) -> Texture2D:
	if _portraits.has(atlas):
		return _portraits[atlas]

	var view := SubViewport.new()
	view.name = "Portrait%d" % _portraits.size()
	view.size = Vector2i(64, 64)
	view.own_world_3d = true
	view.transparent_bg = true
	view.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(view)

	var figure := MmFigure.new()
	view.add_child(figure)
	figure.build(1.8, atlas, Color.WHITE)
	figure.global_position = Vector3.ZERO

	var eye := Camera3D.new()
	eye.fov = 30.0
	view.add_child(eye)
	# The people's heads are big: the face is about 1.35 m up a 1.8 m person.
	eye.look_at_from_position(Vector3(0.0, 1.45, -2.0), Vector3(0.0, 1.35, 0.0), Vector3.UP)
	eye.current = true

	var texture := view.get_texture()
	_portraits[atlas] = texture
	return texture


func _face(who: MmPlayer) -> Texture2D:
	return _portrait(str(who.call("_atlas")))


func _decorate_row(row: Dictionary) -> void:
	if game == null:
		return
	var id := MmNetBridge.player_key(int(row.get("id", 0)))
	if not game.players.has(id):
		id = StringName(str(row.get("id", "")))
	var who: MmPlayer = game.players.get(id)
	if who == null:
		return
	row["avatar"] = _face(who)
	row["points"] = who.points
	# Alive or out, never the side: the board is public and roles are secret.
	row["team"] = BOARD_ALIVE if who.is_alive() and not who.watching else BOARD_OUT
	if int(row.get("ping", -1)) < 0 and who.ping_ms >= 0:
		row["ping"] = who.ping_ms
	if who == player:
		row["you"] = true


## The map in the header, and the living above the dead.
func _prepare_board(snap: Dictionary) -> void:
	if game == null:
		return
	snap["header"] = {"Map": str(game.map_doc.get("name", "")), "Round": str(game.round_number)}
	snap["teams"] = [
		{"id": BOARD_ALIVE, "name": "Alive", "color": Color(0.55, 0.82, 0.95)},
		{"id": BOARD_OUT, "name": "Out", "color": Color(0.6, 0.6, 0.62)},
	]
	add_bot_rows(snap, game)


## Online the board is dot-server's roster, which lists sessions only, so a stand-in needs a row
## of its own, keyed as `board_snapshot()` keys it. Static so a suite can run it on a world.
static func add_bot_rows(snap: Dictionary, world: MmGame) -> void:
	var rows: Array = snap.get("players", []) as Array
	var listed := {}
	for raw in rows:
		if raw is Dictionary:
			listed[str((raw as Dictionary).get("id", ""))] = true
			listed[String(MmNetBridge.player_key(int((raw as Dictionary).get("id", 0))))] = true
	for id in world.players:
		var who: MmPlayer = world.players[id]
		if not (who.is_bot or MmNetBridge.is_bot_key(id)) or listed.has(String(id)):
			continue
		listed[String(id)] = true
		rows.append({"id": String(id), "name": who.display_name, "seconds": 0, "ping": -1, "bot": true})
	snap["players"] = rows


func _dress_board() -> void:
	if board == null:
		return

	board.title_text = "Murder Mystery"
	board.columns = [
		{"key": &"avatar", "kind": DotMenuScoreboard.KIND_AVATAR, "width": 0.0},
		{"key": &"name", "title": "Player", "width": 3.0},
		{"key": &"points", "title": "Points", "kind": DotMenuScoreboard.KIND_NUMBER},
		{"key": &"seconds", "title": "Time", "kind": DotMenuScoreboard.KIND_DURATION},
		{"key": &"ping", "title": "Ping", "kind": DotMenuScoreboard.KIND_PING},
	]
	board.sort_by = &"points"
	board.decorate = _decorate_row
	board.prepare = _prepare_board


func _seconds_here() -> int:
	return int((Time.get_ticks_msec() - _started_msec) / 1000)


## The board offline: every player in the local world. Public so a suite can read it.
func board_snapshot() -> Dictionary:
	var rows: Array = []
	if game != null:
		for id in game.players:
			var who: MmPlayer = game.players[id]
			rows.append({"id": String(id), "name": who.display_name, "seconds": _seconds_here(), "ping": -1, "bot": who.is_bot})
	return {"server": {"name": "Murder Mystery", "game": "offline"}, "players": rows}
