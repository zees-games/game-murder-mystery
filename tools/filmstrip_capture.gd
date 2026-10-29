extends SceneTree

const MmConfig := preload("../game/mm_config.gd")
const MmPlayer := preload("../game/mm_player.gd")

## Plays one clip of tools/filmstrip_scenarios.json with a real MmPlayer on a flat floor and
## draws the third-person view for `--write-movie`; tools/filmstrip_run.sh runs it with `-- <clip>`.

const TICK_RATE := 60
const SETTLE_TICKS := 40
const VIEW := Vector2i(640, 480)
const BUTTONS := {"crouch": DotFpsCommand.BUTTON_CROUCH, "sprint": DotFpsCommand.BUTTON_SPRINT,
	"walk": DotFpsCommand.BUTTON_WALK, "jump": DotFpsCommand.BUTTON_JUMP}

var _clip: DotScenario = null
var _player: MmPlayer = null
var _cam: Camera3D = null
var _tick := 0
var _prev_time := 0.0
var _before := Vector3.INF
var _metrics := DotClipMetrics.new()
var _log: Array[String] = []
var _armed := false


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var clips := DotScenario.load_file("res://tools/filmstrip_scenarios.json")
	if args.is_empty() or not clips.has(args[0]):
		printerr("filmstrip: clip %s not in %s" % [str(args), str(clips.keys())])
		quit(2)
		return
	_clip = clips[args[0]]
	Engine.physics_ticks_per_second = TICK_RATE
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200.0, 1.0, 200.0)
	shape.shape = box
	floor_body.add_child(shape)
	floor_body.position = Vector3(0.0, -0.5, 0.0)
	var mesh := MeshInstance3D.new()
	var plane := BoxMesh.new()
	plane.size = box.size
	mesh.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.55, 0.5)
	plane.material = mat
	floor_body.add_child(mesh)
	root.add_child(floor_body)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, 30.0, 0.0)
	root.add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.7, 0.7, 0.75)
	root.add_child(env)

	_player = MmPlayer.new()
	_player.name = "You"
	_player.config = MmConfig.new()
	root.add_child(_player)
	if _clip.fields.get("armed", "") != "":
		_player.weapon_id = StringName(_clip.fields["armed"])
		_player.weapon_drawn = true
	_cam = Camera3D.new()
	_cam.fov = 50.0
	_cam.current = true
	root.add_child(_cam)


func _clip_time() -> float:
	return float(_tick - SETTLE_TICKS) / float(TICK_RATE)


func _physics_process(_delta: float) -> bool:
	if not _armed:
		_armed = true
		var spawn: Array = _clip.fields.get("spawn", [0.0, 0.05, 40.0])
		_player.place_at(Vector3(spawn[0], spawn[1], spawn[2]), float(_clip.fields.get("spawn_yaw", 0.0)))
	var time := _clip_time()
	var state := _clip.state_at(maxf(time, 0.0))
	var move: Array = state["move"]
	var cmd := DotFpsCommand.new()
	cmd.move = Vector2(float(move[0]), float(move[1]))
	cmd.yaw = float(_clip.fields.get("spawn_yaw", 0.0)) + float(state["yaw"])
	if time >= 0.0:
		for button: String in state["buttons"]:
			cmd.buttons |= int(BUTTONS.get(button, 0))
	_player.controller.apply_command(cmd)
	_before = _player.controller.state.position
	_player.simulate(_tick, 1.0 / float(TICK_RATE))
	if time >= 0.0:
		for step: Dictionary in _clip.events_between(maxf(_prev_time, -0.001), time):
			if String(step["event"]) == "strike":
				_player.attacks += 1
	_prev_time = time
	_tick += 1
	return false


func _process(_delta: float) -> bool:
	var time := _clip_time()
	if time >= _clip.duration:
		_report()
		return true
	var alpha := clampf(Engine.get_physics_interpolation_fraction(), 0.0, 1.0)
	var feet := _player.controller.state.position
	if _before.is_finite():
		feet = _before.lerp(feet, alpha)
	_player.present_body(false, feet, Color(0.3, 0.5, 0.85))
	_cam.global_position = feet + Vector3(2.6, 1.2, 0.0)
	_cam.look_at(feet + Vector3(0.0, 0.9, 0.0))
	if time >= 0.0 and _player.figure != null:
		_sample(time - (1.0 - alpha) / float(TICK_RATE), feet)
	return false


func _speed() -> float:
	var v := _player.controller.state.velocity
	return Vector2(v.x, v.z).length()


func _sample(time: float, feet: Vector3) -> void:
	var skeleton := _player.figure.find_children("*", "Skeleton3D", true, false).front() as Skeleton3D
	var sample := _metrics.pose_sample(time, skeleton, feet, _player.controller.state.is_grounded())
	var row := "%.2f pos=(%.1f,%.1f) root_v=%.2f clip=%s" % [time, feet.x, feet.z, _speed(), _player.figure.clip]
	for foot: Vector3 in sample.get("feet", []):
		row += "  h=%.3f" % (foot.y - feet.y)
	_log.append(row)
	var points: Array[Vector2] = []
	for spot in [feet, feet + Vector3(0.0, 1.7, 0.0)]:
		points.append(Vector2(-1.0, -1.0) if _cam.is_position_behind(spot) else _cam.unproject_position(spot) / Vector2(VIEW))
	sample["points"] = points
	sample["blocked"] = false
	_metrics.add(sample)


func _report() -> void:
	var limits := DotClipMetrics.limits_for("res://tools/filmstrip_thresholds.json", _clip.name)
	var text := DotClipMetrics.table(_clip.name, _metrics.evaluate(limits))
	print(text)
	DotClipMetrics.write_report("res://screenshots/filmstrip/%s_report.txt" % _clip.name, text, _log)
