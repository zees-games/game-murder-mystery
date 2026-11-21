extends GSGameVisualQaCapture

## Visual QA for the people and what they hold (dot-game docs/visual-qa.md): one item per person
## (the six atlases, empty-handed) and per held thing (each melee weapon and the gun, on a person),
## each with a first-person camera (your own arms on the weapon, as MmClient draws them) and the
## two outside cameras. Clips are seeked frame by frame, so reruns draw the same pictures.
##
##   bash tools/visual_qa_shot.sh --only knife --clips walk,strike
##
## Items: person_a .. person_k, knife, cleaver, axe, bat, sword, gun.

const MmFigure := preload("res://game/mm_figure.gd")
const MmPlayer := preload("res://game/mm_player.gd")
const MmWeapons := preload("res://game/mm_weapons.gd")
const MmViewArms := preload("res://game/mm_view_arms.gd")
const MmClientPresent := preload("res://game/mm_client_present.gd")

## Where the own body lives: the first-person camera does not draw it, the outside ones do.
const BODY_LAYER := 1 << 10
const EYE_HEIGHT := 1.62
## Ground speed of each clip; the subject walks that fast along -Z so the feet have a floor to slide on.
const SPEEDS := {"idle": 0.0, "walk": 2.0, "run": 5.5, "strike": 0.0}
## bone_pop limit in the strike clip: a real strike turns the forearm about 1700 deg/s (dot-player-char's
## strike_turn_rate lets it through), ~117 deg in the 1/15 s window. Walk, run and idle keep the 90 default.
const STRIKE_POP_DEG := 130.0

var _figure: MmFigure = null
var _arms: MmViewArms = null
var _view_model: Node3D = null
var _speed := 0.0
var _start := Vector3.ZERO
var _t := 0.0
var _clip := ""


func _items() -> PackedStringArray:
	var items := PackedStringArray()
	for letter in _people():
		items.append("person_" + letter)
	for id in MmWeapons.ids():
		items.append(String(id))
	items.append("gun")
	return items


func _clips(item: String) -> PackedStringArray:
	if item.begins_with("person_") or item == "gun":
		return PackedStringArray(["idle", "walk", "run"])
	return PackedStringArray(["idle", "walk", "run", "strike"])


func _people() -> PackedStringArray:
	var letters := PackedStringArray()
	for path in MmFigure.ATLASES:
		letters.append(path.get_file().get_basename().trim_prefix("texture-"))
	return letters


func _build() -> void:
	super._build()
	first_person.cull_mask = 0xFFFFF & ~BODY_LAYER


func _stage(item: String, clip: String) -> GSResult:
	_clear()
	_clip = clip
	_speed = float(SPEEDS.get(clip, 0.0))
	_start = Vector3(0.0, 0.0, 6.0 if _speed > 0.0 else 0.0)
	var atlas_path: String = MmFigure.ATLASES[0]
	if item.begins_with("person_"):
		atlas_path = MmFigure.ATLASES[_people().find(item.trim_prefix("person_"))]
	_figure = MmFigure.new()
	root.add_child(_figure)
	_figure.build(MmPlayer.BODY_HEIGHT, atlas_path, Color(0.55, 0.62, 0.85))
	if not _figure.from_art:
		return GSResult.fail(GSError.CODE_INVALID, "the people's art did not load")
	var what := &""
	if item == "gun":
		what = &"gun"
		_figure.hold(MmPlayer.ARMED_GUN, &"")
	elif MmWeapons.known(StringName(item)):
		what = StringName(item)
		_figure.hold(MmPlayer.ARMED_WEAPON, what)
	_figure.global_position = _start
	GSGameVisualQaViews.tag_layers(_figure, BODY_LAYER)
	if what != &"":
		_hold_in_view(what)
	return GSResult.success(clip)


func _hold_in_view(what: StringName) -> void:
	var parts: Array = MmWeapons.GUN_PARTS if what == &"gun" else MmWeapons.entry(what)["parts"]
	_view_model = MmWeapons.build(parts, 1.0)
	_view_model.scale = Vector3.ONE * MmClientPresent.VIEW_SCALE
	first_person.add_child(_view_model)
	_view_model.rotation = MmWeapons.view_rotation(what)
	_arms = MmViewArms.new()
	root.add_child(_arms)
	_arms.hold(_view_model, String(what), _figure.person.look, MmPlayer.BODY_HEIGHT)
	# The arms blend in from an unposed state over their first ticks; let that finish before the first frame.
	for _i in 30:
		_arms.follow(_figure.global_position + Vector3(0.0, EYE_HEIGHT, 0.0), 0.0, 0.0, 1.0 / 60.0)
	GSGameVisualQaViews.tag_layers(_arms, 1 << 17)
	GSGameVisualQaViews.tag_layers(_view_model, 1 << 17)


func _clear() -> void:
	for node: Node in [_figure, _arms, _view_model]:
		if node != null and is_instance_valid(node):
			node.get_parent().remove_child(node)
			node.queue_free()
	_figure = null
	_arms = null
	_view_model = null


func _subject(_item: String) -> Node3D:
	return _figure


func _skeleton(_item: String) -> Skeleton3D:
	return _figure.person.skeleton() if _figure != null and _figure.person != null else null


func _seconds(_item: String, clip: String) -> float:
	return 1.5 if clip == "strike" else 2.0


func _drive(_item: String, clip: String, t: float, frame: int) -> void:
	_t = t
	if clip == "strike" and frame % int(fps * 0.75) == 0:
		_figure.strike()
	_figure.global_position = _start + Vector3(0.0, 0.0, -_speed * t)
	_figure.person.animate(_speed, 1.0 / float(fps))
	_figure.clip = _figure.person.clip
	# A swing can add nodes (trails) after the first tagging; keep them off the first-person camera.
	GSGameVisualQaViews.tag_layers(_figure, BODY_LAYER)


func _place_first_person(_item: String) -> void:
	var eye := _figure.global_position + Vector3(0.0, EYE_HEIGHT, 0.0)
	first_person.global_position = eye
	first_person.global_rotation = Vector3.ZERO
	if _arms == null:
		return
	# A jab forward after each attack, as MmClientPresent draws it: .
	var jab := 0.0
	if _clip == "strike":
		jab = maxf(0.0, 1.0 - fposmod(_t, 0.75) / 0.18) * MmClientPresent.JAB
	var sway := _arms.follow(eye, 0.0, _speed, 1.0 / float(fps))
	_view_model.position = MmClientPresent.VIEW_REST + Vector3(0.0, 0.0, -jab) + sway


## The first-person hand's distance to its grip: a hand off the handle shows here, not only in the frames.
## A strike's bone_pop is judged at [constant STRIKE_POP_DEG].
func _checks(_item: String, clip_id: String, rows: Array[Dictionary]) -> Array[Dictionary]:
	if clip_id == "strike":
		for row: Dictionary in rows:
			if row["check"] == "bone_pop" and not row.get("skip", false):
				row["pass"] = float(row["value"]) <= STRIKE_POP_DEG
				row["limit"] = "%.3f" % STRIKE_POP_DEG
				row["note"] = "%s (a strike)" % row.get("note", "")
	if _arms != null:
		var error := _arms.hand_error()
		rows.append({"check": "grip", "pass": error >= 0.0 and error < 0.06, "value": "%.3f" % error, "limit": "0.06", "note": "m from palm to grip point, first person"})
	return rows
