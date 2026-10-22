extends Node

const MmAudio := preload("mm_audio.gd")
const MmBindings := preload("mm_bindings.gd")
const MmFigure := preload("mm_figure.gd")
const MmSettings := preload("mm_settings.gd")
const MmServices := preload("mm_services.gd")
const MmNetBridge := preload("net/mm_net_bridge.gd")

const MmConfig := preload("mm_config.gd")
const MmGame := preload("mm_game.gd")
const MmHud := preload("mm_hud.gd")
const MmPaths := preload("mm_paths.gd")
const MmPlayer := preload("mm_player.gd")
const MmWeapons := preload("mm_weapons.gd")

## One local player, a camera and a HUD over a [MmGame] — offline, or against a server.
##
## [b]One client for both, and the offline half is not a demo mode.[/b] It is the same world
## class with `authoritative` true, stand-ins on both sides, and nothing else different. What
## changes is where the answers come from, and the whole of that difference is [MmNetBridge].
##
## [b]Which half runs is decided by whether there is a link in the registry.[/b] A dot-server
## client publishes a [DotClientLink] under `dot_client_link` before the game scene loads; no
## link means nobody connected us to anything, and the honest answer is a playable round.
## `--offline` forces it.
##
## [b]First person for everybody[/b], because a murder round is about who you can see from
## where you are standing; F5 hangs the camera behind you instead, which is presentation only.
## The simulation is the same either way.

const CHANNEL := "mm.client"

## How far behind a player the camera hangs in third person.
const CHASE_BACK := 3.0
const CHASE_UP := 0.8

@export var config_file: String = "user://cfg/murder.json"
@export var force_offline: bool = false

## How many stand-ins an offline round gets.
@export_range(0, 12, 1) var offline_bots: int = 6

var game: MmGame = null
var player: MmPlayer = null
var camera: Camera3D = null

## Keeps the screen covered, and the local body and the input still, until the level, the
## player and the camera are all in. It is [member DotGameClient.gate].
var gate: DotLoadGate = null

## dot-game's client platform: the cover, settings and menu, console, HUD theme, Tab, M, the
## pointer and the input block. See [DotGameClient].
var platform: DotGameClient = null
var hud: MmHud = null
var board: DotMenuScoreboard = null
var chat: DotGameChatClient = null
var audio: MmAudio = null
var settings: MmSettings = null

## The player's console (the platform's).
var console: DotConsoleController = null

var net: DotNetManager = null
var bridge: MmNetBridge = null
var link: Node = null

## Whether the camera hangs behind the player. F5 swaps it.
var third_person: bool = false

var _offline: bool = true
var _sampler: DotFpsSampler = null
var _watch_id: int = -1
## The spectator's free camera while roaming, and the mouse motion not yet turned into a look.
var _free_cam: DotSpectatorFreeCam = null
var _roam_look: Vector2 = Vector2.ZERO
var _arm: DotCameraBoom = null
var _fade: DotCameraFade = null
var _rig_height: float = 0.0
var _started_msec: int = Time.get_ticks_msec()

## The last whole second of the grace a beep was played for.
var _beeped: int = -1



func _ready() -> void:
	# First, before anything can be drawn: the platform puts the loading cover up, held until the
	# player exists and the camera is current, finds the link and reports the cover to the server.
	platform = DotGameClient.new()
	platform.name = "Platform"
	platform.force_offline = force_offline
	platform.spawned_fn = func() -> bool: return player != null and camera != null and camera.is_inside_tree()
	platform.scoreboard_action = MmBindings.SCOREBOARD
	add_child(platform)
	gate = platform.gate

	var config := MmConfig.new()
	var loaded := config.load_layered(config_file)

	if not loaded.ok:
		DotLog.warn(CHANNEL, "falling back to defaults", {"why": loaded.error.message})

	link = platform.link as Node
	_offline = platform.offline

	game = MmGame.new()
	game.name = "World"
	game.config = config
	game.authoritative = _offline
	game.register_service = _offline
	game.tick_rate = int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 64))
	game.draw_world = true
	# Before the world is added: a server-less world lays its first map out in its own _ready.
	_hold_for_maps()
	add_child(game)
	_build_ragdolls()

	_sampler = DotFpsSampler.new(MmPlayer.tunables_for(config))
	MmPlayer.register_actions(_sampler)

	_build_hud()
	_build_chat()
	_build_audio()
	_build_settings()

	if _offline:
		_start_offline()
	else:
		DotLog.result(CHANNEL, "the netcode", _build_netcode())


## The load gate is [member DotGameClient.gate]: covered, and the local body and the input still,
## until the level is built, the local player exists and its camera is current.
##
## [b]Without it the first frames showed a half-built world.[/b] Offline the body spawned and
## fell in the tick the first map landed, a connected client drew a HUD with no player and no
## camera until JOIN, and a map change tore the level down in front of a body that kept
## falling. A frozen player is also skipped by [method MmPlayer.simulate], which the world
## calls by name and `process_mode` does not stop.


## A map is built: held from the moment the old one starts to go, released once the new one
## stands. [signal MmGame.world_clearing] and [signal MmGame.world_rebuilt] fire for the first
## map, a map change, and a map a server sent.
func _hold_for_maps() -> void:
	game.world_clearing.connect(func() -> void: gate.hold(&"map", "Loading the map"))
	game.world_rebuilt.connect(func() -> void: gate.release(&"map"))


## True while the load gate covers the screen: no input, no prediction sampling.
func _covered() -> bool:
	return gate != null and not gate.is_open()


# --- Offline ---------------------------------------------------------------

func _start_offline() -> void:
	for i in range(offline_bots):
		var bot := game.add_player(StringName("u%d" % (MmNetBridge.FIRST_BOT_SESSION + i)), _bot_name(i))
		bot.is_bot = true

	_adopt(game.add_player(&"local", "You", 0, true))
	_hear_the_world()

	game.achievement_earned.connect(func(id: StringName, title: String, points: int) -> void:
		if player != null and id == player.player_id and chat != null:
			chat.say_locally("Achievement: %s (+%d)" % [title, points], Color(0.98, 0.84, 0.40))
	)
	game.start()
	DotLog.result(CHANNEL, "chat, offline", chat.attach(null))


## A solo stand-in's name: the server's list, through dot-bot's pick, so solo and a server
## name them alike.
static func _bot_name(index: int) -> String:
	var taken: Array = []
	for i in range(index):
		taken.append(DotBotNames.pick(taken, i, MmGame.BOT_NAMES))
	return DotBotNames.pick(taken, index, MmGame.BOT_NAMES)


## Solo, `bot_difficulty` and every `bot_*` setting at the console, the names a server has, and
## `-- --bot_difficulty hard` at launch. Connected, the server's console holds them and a local
## copy would shadow it.
func _bind_bot_console() -> void:
	if not _offline or console == null or game == null:
		return
	var sources: Array = console.sources()
	if sources.is_empty() or not (sources[0] is DotConsoleLocal):
		return
	var _bound := DotBotSettings.of(game).bind_console(sources[0])
	var args := OS.get_cmdline_user_args()
	var index := args.find("--bot_difficulty")
	if index >= 0 and index + 1 < args.size():
		DotLog.result(CHANNEL, "bot difficulty from the command line", DotBotSettings.of(game).set_difficulty(args[index + 1]))


# --- Connected -------------------------------------------------------------

func _build_netcode() -> DotResult:
	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = false
	net.local_peer_id = multiplayer.get_unique_id() if multiplayer != null else 2
	net.auto_tick = false
	net.config_file = ""

	var net_config := DotNetConfig.new()
	net_config.tick_rate = game.tick_rate
	net_config.snapshot_rate = MmGame.NET_SNAPSHOT_RATE
	net_config.enable_prediction = true
	net_config.enable_lag_compensation = false
	net_config.max_entities_per_snapshot = 64
	net_config.world_extent = MmGame.NET_WORLD_EXTENT
	net.config = net_config
	add_child(net)

	var started := net.setup()

	if not started.ok:
		return started

	bridge = MmNetBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	var attached := bridge.attach(game, net)

	if not attached.ok:
		return attached

	bridge.open_link(link)
	# The server's mp_forceview and mp_solidplayers: this end places its own camera and
	# predicts its own player.
	var _view := game.view_rules.follow_cvars(link)
	var _solid := game.body_rules.follow_cvars(link)
	# The server's sv_ragdoll* set: this end draws the bodies.
	var _dead := game.ragdoll_rules.follow_cvars(link)
	# And sv_toys*: a client hides the toys a server took away.
	var _toys := game.toy_rules.follow_cvars(link)
	# And mp_forcecamera / mp_freeroam*: this end flies the spectator's free camera.
	var _spectate := game.spectate_rules.follow_cvars(link)
	net.messages.seal()

	bridge.hello_received.connect(_on_hello)
	bridge.roster_changed.connect(_on_roster_changed)
	bridge.phase_received.connect(_on_phase)
	bridge.round_changed.connect(_on_round)
	bridge.death_received.connect(_on_death)
	bridge.map_received.connect(_on_map)
	bridge.role_received.connect(_on_role)
	bridge.shot_received.connect(_on_shot)
	bridge.notice_received.connect(func(text: String) -> void:
		if chat != null:
			chat.notice(text)
		if audio != null:
			var _denied := audio.deny())
	if link != null and link.has_method("ping_ms"):
		bridge.rtt_source = func() -> float:
			return float(maxi(0, int(link.call("ping_ms"))))

	DotLog.result(CHANNEL, "chat and voice", chat.attach(bridge))

	if link != null and link.has_method("is_playing") and bool(link.call("is_playing")):
		_say_ready()
	elif link != null and link.has_signal("spawned"):
		link.connect("spawned", _say_ready, CONNECT_ONE_SHOT)

	return net.start()


func _say_ready() -> void:
	if bridge != null:
		bridge.ask_ready()


func _on_hello(session_id: int) -> void:
	_watch_id = session_id
	_adopt(game.players.get(MmNetBridge.player_key(session_id)))


func _on_roster_changed(session_id: int) -> void:
	if session_id == _watch_id and player == null:
		_adopt(game.players.get(MmNetBridge.player_key(session_id)))



func _adopt(candidate: MmPlayer) -> void:
	if candidate == null or player == candidate:
		return

	player = candidate
	gate.freeze(player)
	_build_camera()

	if settings != null:
		settings.bind_camera(camera)
		if player.sampler != null:
			settings.bind_look(player.sampler.tunables)

	if hud != null:
		hud.bind(game, player)


# --- What the world, or the server, says --------------------------------------

## Offline: the world is the authority, so its own signals are what happened. A connected
## client hears the same from the bridge and calls the same functions with the same arguments,
## so the two can only differ in where a fact came from.
func _hear_the_world() -> void:
	game.world_rebuilt.connect(func() -> void: _on_map(game.map.id()))
	game.phase_changed.connect(_on_phase)
	game.round_began.connect(func(n: int, _map: StringName) -> void: _on_round(n, true, 0))
	game.round_over.connect(func(n: int, winner: int, why: String) -> void: _on_round(n, false, winner, why))
	game.player_died.connect(func(id: StringName, by: StringName, why: StringName) -> void:
		_on_death(_session(id), _session(by) if by != &"" else 0, why))
	game.role_drawn.connect(func(id: StringName, side: int, gun: bool) -> void:
		if id == &"local":
			_on_role(side, gun, game.weapon_id()))
	game.shot.connect(func(by: StringName, from: Vector3, to: Vector3, hit: StringName) -> void:
		_on_shot(_session(by), from, to, hit != &""))
	game.bot_said.connect(func(id: StringName, text: String) -> void:
		var who: MmPlayer = game.players.get(id)
		if chat != null and who != null:
			chat.say_locally("%s: %s" % [who.display_name, text], Color(0.93, 0.94, 0.96)))
	game.refused.connect(func(id: StringName, why: String) -> void:
		if id == &"local" and chat != null:
			chat.notice(why)
			if audio != null:
				var _denied := audio.deny())


## The local world's ids are `local` for this keyboard and `u<session>` for everybody else.
func _session(id: StringName) -> int:
	return _watch_id if id == &"local" else MmNetBridge.session_of(id)


func _player_of(session_id: int) -> MmPlayer:
	if session_id == _watch_id and player != null:
		return player
	return game.players.get(MmNetBridge.player_key(session_id))


func _on_phase(phase: int) -> void:
	if hud == null or player == null:
		return

	match phase:
		MmGame.Phase.GRACE:
			if audio != null:
				var _heard := audio.on_start()
		MmGame.Phase.PLAY:
			if audio != null:
				var _heard := audio.on_armed()
			if game.effects != null:
				var _flashed := game.effects.flash(&"go")
			if is_murderer():
				hud.shout("%s to draw your %s. Nobody may see." % [_key(MmBindings.HOLSTER), game.weapon_name().to_lower()], 3.0)
			else:
				hud.shout("THE MURDERER IS ARMED" if not player.has_gun else "YOU HAVE THE GUN", 2.4)


## Whether this client's own player is a murderer this round. Only this client's own role is
## known here: everybody else is a bystander on the wire.
func is_murderer() -> bool:
	return player != null and game != null and game.team_of(player.player_id) == MmGame.MURDERERS


## This client's role arrived (the draw, or a reconnect mid-round).
func _on_role(side: int, gun: bool, _weapon_id: StringName) -> void:
	if hud == null:
		return
	if player != null:
		player.retune()
	if side == MmGame.MURDERERS:
		hud.shout("YOU ARE THE MURDERER — kill them all", 4.0)
	elif gun:
		hud.shout("YOU ARE A BYSTANDER WITH THE GUN — find the murderer", 4.0)
	else:
		hud.shout("YOU ARE A BYSTANDER — stay alive", 4.0)
	hud.role_changed()


## Somebody fired: a tracer from the gun to where the shot stopped, and the bang.
func _on_shot(session_id: int, from: Vector3, to: Vector3, hit: bool) -> void:
	var who := _player_of(session_id)
	if who != null and who.figure != null:
		who.figure.strike()
	if audio != null:
		var _bang := audio.on_shot(from, session_id == _watch_id)
	_tracer(from, to, hit)


## A thin bright box from [param from] to [param to] that fades in a fifth of a second.
func _tracer(from: Vector3, to: Vector3, hit: bool) -> void:
	if game == null or not game.draw_world or from.distance_to(to) < 0.05:
		return
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.025, 0.025, from.distance_to(to))
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.35, 0.25, 0.9) if hit else Color(1.0, 0.92, 0.6, 0.9)
	mesh.material = mat
	var line := MeshInstance3D.new()
	line.name = "Tracer"
	line.mesh = mesh
	line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	game.add_child(line)
	line.global_position = (from + to) * 0.5
	line.look_at_from_position(line.global_position, to, Vector3.UP if absf((to - from).normalized().y) < 0.99 else Vector3.RIGHT)
	var fade := line.create_tween()
	fade.tween_property(mat, "albedo_color:a", 0.0, 0.2)
	fade.tween_callback(line.queue_free)


func _on_map(map_id: StringName) -> void:
	if ragdolls != null:
		# A body on the old map would hang in the new one's air.
		ragdolls.clear()

	# The new map's toys are heard: a bounce, a knock, a switch, a honk.
	if game.map != null and game.map.toys != null and not game.map.toys.sound.is_connected(_toy_sound):
		var _c := game.map.toys.sound.connect(_toy_sound)

	if audio != null:
		audio.on_map_doc(map_id, game.map_doc)

	var name_of := str(game.map_doc.get("name", ""))
	hud.shout(name_of, 3.0)

	if chat != null and name_of != "":
		var author := str(game.map_doc.get("author", ""))
		var blurb := str(game.map_doc.get("blurb", ""))
		chat.say_locally("%s%s%s" % [name_of, " by %s" % author if author != "" else "",
			" — %s" % blurb if blurb != "" else ""], Color(0.80, 0.90, 1.0))


func _on_round(number: int, began: bool, winner: int, why: String = "") -> void:
	if began:
		hud.shout("ROUND %d" % number, 2.0)
		return

	if audio != null and player != null:
		var _heard := audio.on_round_end(winner != 0 and game.team_of(player.player_id) == winner)

	# Everybody back to the public side: the round is over and the next draw is a new secret.
	if hud != null:
		hud.role_changed()

	var who := game.side_name(winner).to_upper() + " WIN" if winner != 0 else "DRAW"
	hud.shout("%s — %s" % [who, why] if why != "" else who, 4.0)

	if chat != null and why != "":
		chat.say_locally(why, Color(0.98, 0.86, 0.40))


func _on_death(session_id: int, _by: int, why: StringName) -> void:
	var who := _player_of(session_id)
	_fall(who)

	if audio != null and who != null and why != MmGame.DIED_FELL and why != MmGame.DIED_SHOT:
		var _heard := audio.on_stab(who.global_position, session_id == _watch_id)

	if session_id == _watch_id and hud != null:
		hud.shout("YOU DIED" if why != MmGame.DIED_FELL else "YOU FELL", 2.5)

	if chat == null or who == null:
		return

	# Who did it is never said: the server does not send it (see the bridge), and offline the
	# client says no more than a connected one would.
	match why:
		MmGame.DIED_FELL:
			chat.say_locally("%s fell" % who.display_name, Color(0.80, 0.82, 0.86))
		MmGame.DIED_SHOT:
			chat.say_locally("%s was shot" % who.display_name, Color(0.95, 0.75, 0.55))
		_:
			chat.say_locally("%s was killed" % who.display_name, Color(0.95, 0.55, 0.55))


# --- Dead bodies -----------------------------------------------------------

## Where the dead lie: dot-player-char's ragdolls under the game's (the server's) rules.
var ragdolls: DotPlayerRagdolls = null


func _build_ragdolls() -> void:
	ragdolls = DotPlayerRagdolls.new()
	ragdolls.name = "Ragdolls"
	ragdolls.rules = game.ragdoll_rules
	ragdolls.sound_fn = _ragdoll_sound
	add_child(ragdolls)


func _toy_sound(id: StringName, at: Vector3, strength: float) -> void:
	if audio != null:
		var _played := audio.on_toy(id, at, strength)


func _ragdoll_sound(id: StringName, at: Vector3, volume: float) -> void:
	if audio != null:
		var _played := audio.on_body(id, at, volume)


## [param who]'s body falls the way the server picked ([member MmPlayer.death]), copied from the
## figure this client draws; the figure itself stays hidden while they are dead
## ([method MmPlayer.present_body]). Nobody's figure, nothing: a first-person player who never
## had one drawn here. Called from [method _on_death], solo and connected alike.
func _fall(who: MmPlayer) -> void:
	if who == null or ragdolls == null or who.figure == null or not who.figure.is_inside_tree():
		return
	if game.physics != null:
		# The rooms and the props: a body lands on them and on nothing else (not on a person).
		game.ragdoll_rules.collision_mask = game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop")
	var velocity := who.controller.state.velocity if who.controller != null else Vector3.ZERO
	var _body := ragdolls.spawn(who.figure, who.death if who.death != null else DotPlayerDeath.new(), velocity)


# --- The camera ------------------------------------------------------------

func _build_camera() -> void:
	if camera != null or player == null:
		return

	camera = Camera3D.new()
	camera.name = "Eye"
	camera.fov = 90.0
	camera.current = true

	# Other players and stand-ins, handed over (their hulls are off while players pass
	# through each other): hidden at the lens, faded in third person between the camera and
	# you. It rides the camera wherever the camera goes.
	_fade = DotCameraFade.new()
	_fade.name = "Fade"
	_fade.bodies_fn = _other_players
	camera.add_child(_fade)

	if not game.view_rules.changed.is_connected(_on_view_rules_changed):
		game.view_rules.changed.connect(_on_view_rules_changed)
	third_person = game.view_rules.resolve(third_person)
	_place_camera()


## Hangs the camera where the view wants it: at the eyes, or on an arm behind a prop as far
## back as the prop is big.
func _place_camera() -> void:
	if camera == null or player == null:
		return

	if camera.get_parent() != null:
		camera.get_parent().remove_child(camera)

	if _arm != null and is_instance_valid(_arm):
		_arm.queue_free()
		_arm = null

	var eye := player.eye_position() - player.controller.state.position

	if not third_person:
		player.add_child(camera)
		_rig_height = eye.y
		camera.position = Vector3(0.0, eye.y, 0.0)
		camera.rotation = Vector3.ZERO
		if _fade != null:
			_fade.focus = null
		return

	# dot-core's boom, swept from the eye with the height above it added in the world's up:
	# a pivot above the head can be inside a tree's canopy (the play test, 0:33), and the
	# spring arm it replaced cast a ray from there and snapped to whatever it hit.
	_arm = DotCameraBoom.new()
	_arm.name = "Chase"
	_arm.spring_length = CHASE_BACK
	# Against the building and the furniture, never the player's own body.
	_arm.collision_mask = game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop") \
		if game.physics != null else 1
	_arm.add_excluded_object(player.get_rid())
	_arm.margin = 0.15
	_arm.lift = CHASE_UP
	_rig_height = eye.y
	player.add_child(_arm)
	_arm.add_child(camera)
	camera.position = Vector3.ZERO
	camera.rotation = Vector3.ZERO
	if _fade != null:
		_fade.focus = _arm


## Swaps the view, where the server's `mp_forceview` allows.
func toggle_view() -> void:
	var wanted := game.view_rules.toggled(third_person)
	if wanted == third_person:
		if hud != null and game.view_rules.refusal() != "":
			hud.shout(game.view_rules.refusal(), 1.6)
		return
	third_person = wanted
	_place_camera()

	if audio != null:
		var _heard := audio.click()


## Everybody but this player, for the camera fade.
func _other_players() -> Array:
	var out: Array = []
	if game == null:
		return out
	for id in game.players:
		var other: Node3D = game.players[id]
		if other != player and is_instance_valid(other):
			out.append(other)
	return out


## The server changed `mp_forceview`: the view it allows now.
func _on_view_rules_changed() -> void:
	var allowed := game.view_rules.resolve(third_person)
	if allowed != third_person:
		third_person = allowed
		if not is_spectating():
			_place_camera()


func _build_hud() -> void:
	hud = MmHud.new()
	hud.name = "Hud"
	hud.key_fn = _key
	add_child(hud)


## The key an action is on, as the player has it bound.
func _key(action: StringName) -> String:
	if settings != null and settings.bindings != null:
		var text := settings.bindings.key_for(action)
		if text != "":
			return text

	var row := MmBindings.make().row_for_action(action)
	return str(row.get("default", action))


# --- The Tab board ---------------------------------------------------------

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


## The board's two groups. Not the sides: who is the murderer is the round's secret.
const BOARD_ALIVE := 1
const BOARD_OUT := 3


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


## Online the board is dot-server's roster, which lists sessions only, and a stand-in is not
## one: the HUD counted four hidden while the board said nobody. Adds a row for each bot in
## the world that the roster does not carry, keyed as `board_snapshot()` keys it so
## `_decorate_row` finds its team, points and face. Static so a suite can run it on a world.
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


## The board offline: every player in the local world. Public so a suite can read it.
func board_snapshot() -> Dictionary:
	var rows: Array = []
	if game != null:
		for id in game.players:
			var who: MmPlayer = game.players[id]
			rows.append({"id": String(id), "name": who.display_name, "seconds": _seconds_here(), "ping": -1, "bot": who.is_bot})
	return {"server": {"name": "Murder Mystery", "game": "offline"}, "players": rows}


func _seconds_here() -> int:
	return int((Time.get_ticks_msec() - _started_msec) / 1000)


var _portraits: Dictionary = {}


func _face(who: MmPlayer) -> Texture2D:
	return _portrait(str(who.call("_atlas")))


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


# --- Chat, sound, settings ---------------------------------------------------

## dot-game's chat box and microphone, with this game's channels and voice format.
func _build_chat() -> void:
	chat = DotGameChatClient.new()
	chat.name = "Chat"
	chat.channels = [
		{"id": MmServices.CH_ALL, "label": "All", "colour": Color(0.93, 0.94, 0.96)},
		{"id": MmServices.CH_NEAR, "label": "Near", "colour": Color(0.82, 0.86, 0.72)},
	]
	chat.max_length = MmServices.chat_rules().max_length
	# No team key: this game has no team channel, because a team is a secret (mm_services.gd).
	chat.window_settings = {"team_action": &""}
	chat.voice_config = MmServices.voice_format()
	add_child(chat)


func _build_audio() -> void:
	audio = MmAudio.new()
	audio.name = "Sound"
	add_child(audio)

	var ready_now := audio.setup()

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "no sound", {"why": ready_now.error.message})
		remove_child(audio)
		audio.queue_free()
		audio = null


func _build_settings() -> void:
	settings = MmSettings.new()
	settings.name = "Settings"
	add_child(settings)
	platform.settings = settings
	# Not handed over: MmHud follows the menu's theme itself, below.
	platform.chat = chat
	platform.board_snapshot_fn = board_snapshot
	# M: the map list. Solo a choice changes the map here at once; connected the server decides,
	# by the owner's `sv_map_menu_flag`, and anybody without it gets a vote instead (dot-vote's
	# map menu, wired in [MmModule]).
	platform.maps_rows_fn = func() -> Array: return game.map_rows() if game != null else []
	platform.maps_change_fn = func(id: StringName) -> DotResult: return game.change_map_now(id)
	DotLog.result(CHANNEL, "the platform", platform.setup())
	# Walking is off while the cover is up, a menu is open or a line is typed: the sampler polls
	# the keyboard.
	platform.input_blocked_changed.connect(_suspend_input)
	_suspend_input(platform.is_input_blocked())

	settings = platform.settings as MmSettings
	console = platform.console as DotConsoleController

	if settings == null:
		return

	if _sampler != null:
		settings.bind_look(_sampler.tunables)

	if audio != null:
		settings.bind_audio(audio.manager)

	if settings.menu != null:
		# The HUD in the menu's theme and at the player's HUD size, live.
		if hud != null:
			hud.follow_menu(settings.menu)
		_bind_bot_console()
		board = platform.board as DotMenuScoreboard
		_dress_board()


func _suspend_input(suspended: bool) -> void:
	if _sampler != null:
		_sampler.suspended = suspended

	if player != null and player.sampler != null:
		player.sampler.suspended = suspended


## Whether the pointer is the game's: captured. A menu frees it and the platform takes it back.
func _pointer_ours() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


# --- The frame -------------------------------------------------------------

func _physics_process(delta: float) -> void:
	# The use key, held: the game makes the press from the edge, on the server or here.
	var use := _key_held(MmBindings.USE)
	var attack := _held(MmBindings.ATTACK) and not is_spectating()
	var holster := _key_held(MmBindings.HOLSTER)

	if _offline:
		if player != null:
			player.wants_use = use
			player.wants_attack = attack
			player.wants_holster = holster
			player.input_off = is_roaming()
		return

	if net == null or not net.is_running() or bridge == null:
		return

	var ticks := net.clock.advance(delta)

	# The clock has advanced; only the sampling waits, so the mouse does not pile up a turn
	# behind the cover and the server sees an idle body until it lifts.
	if _covered():
		return

	var move := _sampler.sample(delta) if _sampler != null else DotFpsCommand.new()
	move.set_button(MmPlayer.USE_BUTTON, use)
	move.set_button(MmPlayer.ATTACK_BUTTON, attack)
	move.set_button(MmPlayer.HOLSTER_BUTTON, holster)

	if is_roaming():
		# The roaming spectator flies a camera and does not walk the dead body about.
		move.move = Vector2.ZERO
		move.buttons = 0

	for i in range(ticks):
		if not net.clock.is_synced():
			continue

		bridge.client_tick(net.clock.input_tick() - (ticks - 1 - i), move)


## Whether [param action] is held now, by a player whose pointer is the game's.
func _held(action: StringName) -> bool:
	return _pointer_ours() and not _covered() and InputMap.has_action(action) and Input.is_action_pressed(action)


## Whether the keyboard action [param action] is held now. Unlike [method _held] this does not need
## the pointer captured: a browser captures it only on a click (and tab-away or Escape frees it),
## and a key is no click. Q gated on the capture did nothing for a solo player in a tab whose
## pointer lock was not held. The menu, the chat and the cover still block it through the platform.
func _key_held(action: StringName) -> bool:
	if _covered() or not InputMap.has_action(action) or not Input.is_action_pressed(action):
		return false

	return platform == null or not platform.is_input_blocked()


func _process(delta: float) -> void:
	var _shown := present_frame(net, game, player, not third_person, delta, -1.0, _watched_through_eyes())
	_present_hide()
	_present_guns()

	if camera == null or player == null:
		return

	if _drive_spectator_camera():
		_present_effects(delta)
		return

	var state := player.controller.state
	var pitch := deg_to_rad(state.pitch)
	var yaw := deg_to_rad(state.yaw)
	var rig: Node3D = _arm if _arm != null and is_instance_valid(_arm) else camera
	rig.rotation = Vector3(pitch, yaw, 0.0)

	var drawn := player.controller.render_state()
	var eye_height := _rig_height

	# First person follows a crouch down, as the server's eye does for the sight rule.
	if not third_person:
		eye_height = player.eye_position().y - state.position.y

	rig.global_position = drawn.position + Vector3(0.0, eye_height, 0.0)

	_present_view_model()
	_present_effects(delta)


## The last seconds of the grace, beeped.
func _present_hide() -> void:
	if game == null or game.phase != MmGame.Phase.GRACE:
		_beeped = -1
		return

	var second := int(ceilf(game.seconds_left()))

	if second != _beeped and second <= 5 and second > 0:
		_beeped = second

		if audio != null:
			var _heard := audio.on_countdown()


## What is in your own hand, in first person: the gun, or the weapon drawn. Rebuilt when it
## changes; nothing in third person, where the figure holds it.
var _view_model: Node3D = null
var _view_model_of: String = ""


func _present_view_model() -> void:
	if camera == null or player == null:
		return
	var what := ""
	if not third_person and player.is_alive() and not is_spectating():
		match player.armed():
			MmPlayer.ARMED_GUN:
				what = "gun"
			MmPlayer.ARMED_WEAPON:
				what = String(player.weapon_id)
	if what != _view_model_of:
		_view_model_of = what
		if _view_model != null and is_instance_valid(_view_model):
			_view_model.queue_free()
		_view_model = null
		if what != "":
			var parts: Array = MmWeapons.GUN_PARTS if what == "gun" else MmWeapons.entry(StringName(what))["parts"]
			_view_model = MmWeapons.build(parts, 1.0)
			_view_model.name = "ViewModel"
			camera.add_child(_view_model)
			_view_model.position = Vector3(0.22, -0.2, -0.42)
			if what != "gun":
				_view_model.rotation = Vector3(-PI / 2.6, 0.15, 0.0)
	if _view_model != null:
		# A jab forward for a moment after each attack.
		var since := float(Time.get_ticks_msec()) / 1000.0 - _swing_at
		var jab := maxf(0.0, 1.0 - since / 0.18) * 0.18
		_view_model.position.z = -0.42 - jab
		if player.attacks != _swings_seen:
			_swings_seen = player.attacks
			_swing_at = float(Time.get_ticks_msec()) / 1000.0


var _swing_at: float = -10.0
var _swings_seen: int = 0


## Every gun on the floor, drawn turning slowly where it lies (`MmGame.gun_drops`, the server's
## and every client's alike).
var _gun_nodes: Dictionary = {}


func _present_guns() -> void:
	if game == null or not game.draw_world:
		return
	for drop_id: int in _gun_nodes.keys():
		if not game.gun_drops.has(drop_id):
			var gone: Node3D = _gun_nodes[drop_id]
			if is_instance_valid(gone):
				gone.queue_free()
			_gun_nodes.erase(drop_id)
	for drop_id: int in game.gun_drops:
		var node: Node3D = _gun_nodes.get(drop_id)
		if node == null or not is_instance_valid(node):
			node = MmWeapons.build(MmWeapons.GUN_PARTS, 2.0)
			node.name = "DroppedGun%d" % drop_id
			game.add_child(node)
			_gun_nodes[drop_id] = node
		node.global_position = (game.gun_drops[drop_id]["at"] as Vector3) + Vector3(0.0, 0.25 + 0.05 * sin(Time.get_ticks_msec() / 300.0), 0.0)
		node.rotation.y = Time.get_ticks_msec() / 800.0


func _present_effects(delta: float) -> void:
	if audio != null:
		audio.listen_from(camera.global_position)
		audio.keep_walkers(game.players.values())

	if game.effects != null:
		game.effects.viewer_position = camera.global_position
		game.effects.advance(delta)


# --- Watching, once out -----------------------------------------------------

func is_spectating() -> bool:
	return player != null and game != null and game.spectate != null \
		and game.spectate.is_spectating(player.player_id)


func _watched_through_eyes() -> MmPlayer:
	if not is_spectating():
		return null

	var mode := game.spectate.mode_of(player.player_id)

	if mode != DotSpectatorView.Mode.FIRST_PERSON and mode != DotSpectatorView.Mode.FREEZE_CAM:
		return null

	return game.players.get(game.spectate.watching(player.player_id))


func _drive_spectator_camera() -> bool:
	if not is_spectating():
		if camera.get_parent() == self:
			_place_camera()

		if hud != null:
			hud.set_watching("")

		return false

	if camera.get_parent() != self:
		camera.get_parent().remove_child(camera)
		add_child(camera)
		camera.current = true

		if _arm != null and is_instance_valid(_arm):
			_arm.queue_free()
			_arm = null

	# Chase and death cameras pulled out of the house by dot-spectate, given the level.
	var manager: DotSpectatorManager = game.spectate.manager
	if manager != null and manager.camera_world == null and game.physics != null:
		manager.camera_world = camera.get_world_3d()
		manager.camera_mask = game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop")

	var where := game.spectate.camera_for(player.player_id)

	if game.spectate.is_roaming(player.player_id):
		where = _fly_free_camera()
	else:
		_free_cam = null

	if where != Transform3D.IDENTITY:
		camera.global_transform = where

	if hud != null:
		game.spectate.roam_key = _key(MmBindings.ROAM)
		hud.set_watching(game.spectate.line_for(player.player_id))

	return true


## The free-roam key: into a free camera while out, and back onto a player from it. On a
## connected client the server decides (it owns the mode, and says no with a notice when
## `mp_freeroam 0` or `mp_forcecamera` forbids it); offline the local world is the server.
func toggle_roam() -> void:
	if not is_spectating():
		return

	_free_cam = null
	_roam_look = Vector2.ZERO

	if bridge != null:
		bridge.ask_roam()
		return

	var res := game.spectate.toggle_roam(player.player_id)

	if not res.ok and chat != null:
		chat.notice(res.error.message)


func is_roaming() -> bool:
	return game != null and game.spectate != null and player != null \
		and game.spectate.is_roaming(player.player_id)


## One frame of the free camera: the mouse turn folded in, then the movement keys. Seeded
## from where the camera was on the first frame of a roam, so it starts where the spectator
## looked. The pose is kept in the manager too, so a later hand-over starts from it.
func _fly_free_camera() -> Transform3D:
	if _free_cam == null:
		_free_cam = DotSpectatorFreeCam.new()
		_free_cam.rules = game.spectate_rules
		_free_cam.seed_from(camera.global_transform)

	var sens := deg_to_rad(_sampler.tunables.mouse_sensitivity) if _sampler != null else 0.0025
	_free_cam.look(Vector2(-_roam_look.x, -_roam_look.y) * sens)
	_roam_look = Vector2.ZERO

	var move := Vector3.ZERO

	if _pointer_ours() and not _covered():
		move = Vector3(
			_strength(&"dot_fps_right") - _strength(&"dot_fps_left"),
			_strength(&"dot_fps_jump") - _strength(&"dot_fps_crouch"),
			_strength(&"dot_fps_forward") - _strength(&"dot_fps_back"),
		)

	var pose := _free_cam.step(
		move, _held(&"dot_fps_sprint"), _held(&"dot_fps_walk"), get_process_delta_time()
	)
	var _kept := game.spectate.manager.move_free(String(player.player_id), pose.origin, pose.basis)
	return pose


static func _strength(action: StringName) -> float:
	return Input.get_action_strength(action) if InputMap.has_action(action) else 0.0


func spectate_step(direction: int) -> void:
	if audio != null:
		var _heard := audio.click()

	if bridge != null:
		bridge.ask_spectate(direction)
		return

	if game == null or game.spectate == null or player == null:
		return

	var moved := game.spectate.step(player.player_id, direction)

	if not moved.ok and chat != null:
		chat.notice(moved.error.message)


## Everything a frame draws that a tick does not, in this order: the netcode's interpolation,
## then every player in their shirt (never a side's colour: that would be the secret), then
## every admin beacon. Returns how many are
## shown. Static so the net suite drives exactly this and not a copy of it.
##
## [param first_person] is whether [param own]'s camera is behind their eyes, which hides their
## own body.
static func present_frame(
	p_net: DotNetManager,
	p_game: MmGame,
	own: MmPlayer,
	first_person: bool,
	delta: float,
	alpha: float = -1.0,
	watched: MmPlayer = null
) -> int:
	var networked := p_net != null and p_net.is_running()

	if networked:
		p_net.interpolate_frame(alpha)

	# Your own player is drawn at the clock's render alpha, not the engine's fraction: the
	# clock stretches and shrinks its ticks while it settles on the server, so a physics frame
	# now and then runs no tick or two, and drawn at the engine's fraction the eye stood still
	# on one frame and moved double on the next. `DotFpsController.render_state` reads it from
	# `render_clock` (dot-player-controller); by name both ways, so a shell older than either
	# draws as before. Null offline, where every physics frame is one tick.
	if own != null and own.controller != null:
		own.controller.set(&"render_clock", p_net.clock if networked else null)

	if p_game == null:
		return 0

	var shown := 0
	var period := 2.0

	for key: StringName in p_game.players:
		var body: MmPlayer = p_game.players[key]

		if body == null or not is_instance_valid(body) or not body.is_inside_tree():
			continue

		var mine := body == own
		var at := drawn_position(body, networked and not mine)
		var colour := p_game.shirt_colour(body)
		var hidden := (mine and first_person) or body == watched

		if body.present_body(hidden, at, colour):
			shown += 1

		var _pinged := body.present_beacon(delta, at, mine and first_person, period)

	return shown


static func drawn_position(body: MmPlayer, remote: bool) -> Vector3:
	if remote or body.controller == null:
		return body.global_position

	return body.controller.render_state().position


func _unhandled_input(event: InputEvent) -> void:
	if _covered():
		return

	# Tab, M and a click taking the pointer back are the platform's (DotGameClient).
	if event.is_action_pressed("ui_cancel"):
		if settings != null:
			settings.open()
		return

	if event is InputEventKey and (event as InputEventKey).pressed and not event.is_echo():
		if _key_pressed(event):
			get_viewport().set_input_as_handled()
			return

	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton

		if is_spectating():
			if button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
				spectate_step(1)
			elif button.pressed and button.button_index == MOUSE_BUTTON_RIGHT:
				spectate_step(-1)
			return

	if player == null:
		return

	if is_roaming() and event is InputEventMouseMotion:
		# The free camera turns on the mouse, and the dead body's view stays put.
		if _pointer_ours():
			_roam_look += (event as InputEventMouseMotion).relative
		return

	if event is InputEventMouseMotion and _pointer_ours():
		if _offline and player.sampler != null:
			player.sampler.handle_event(event)
		elif _sampler != null:
			_sampler.handle_event(event)


## The game's own keys, from the bindings. True when one was used.
func _key_pressed(event: InputEvent) -> bool:
	if event.is_action_pressed(MmBindings.ROAM) and is_spectating():
		toggle_roam()
		return true

	if event.is_action_pressed(MmBindings.VIEW):
		if is_spectating():
			spectate_step(0)
		else:
			toggle_view()
		return true

	if player == null or not player.is_alive() or is_spectating():
		return false

	return false


func describe() -> Dictionary:
	var out := {
		"offline": _offline,
		"session": _watch_id,
		"player": player != null,
		"view": "third" if third_person else "first",
	}

	if bridge != null:
		out["bridge"] = bridge.describe()

	if chat != null:
		out["chat"] = chat.describe()

	if game != null:
		out["world"] = game.describe()

	return out
