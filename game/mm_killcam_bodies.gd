extends RefCounted

## MmPlayer hooks for dot-replay's [DotKillcamHost]: how a drawn body is read and posed.

const MmFigure := preload("mm_figure.gd")
const MmPlayer := preload("mm_player.gd")

const SKIP_ACTIONS: PackedStringArray = ["dot_fps_jump", "mm_attack", "ui_cancel"]


## Gives [param host] the skip keys and body hooks.
static func configure(host: DotKillcamHost) -> void:
	host.log_channel = "mm.killcam"
	host.skip_actions = SKIP_ACTIONS
	host.skip_hint = "Jump or Attack to skip"
	host.state_fn = state_of
	host.place_body_fn = place_body
	host.restore_body_fn = restore_body


# [feet, yaw, pitch, alive, eye height]: where the body was drawn, not where the tick put it.
static func state_of(p: MmPlayer) -> Array:
	if p.controller == null:
		return []
	var st := p.controller.state
	var feet := p.global_position
	if p.figure != null and p.figure.visible:
		feet = p.figure.global_position
	return [feet, st.yaw, st.pitch, p.is_alive() and not p.watching, p.eye_position().y - st.position.y]


static func restore_body(p: MmPlayer, saved: Array) -> void:
	if p.figure != null:
		p.figure.visible = bool(saved[0])


static func place_body(p: MmPlayer, feet: Vector3, yaw: float, shown: bool, pitch: float, speed: float, touched: Dictionary) -> void:
	var figure := p.figure
	if figure == null:
		if not shown:
			return
		figure = MmFigure.new()
		figure.name = "Figure"
		p.add_child(figure)
		p.figure = figure
		figure.build(MmPlayer.BODY_HEIGHT, p.call(&"_atlas"), Color.WHITE)
		# A figure made for the replay goes back hidden.
		touched[p] = [false]
	elif not touched.has(p):
		touched[p] = [figure.visible]
	figure.visible = shown
	if not shown:
		return
	figure.set_motion({"on_floor": true, "aim": deg_to_rad(pitch)})
	figure.pose(feet, deg_to_rad(yaw), speed)
