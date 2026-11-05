extends DotGameCheckSuite

const MmTouch := preload("../game/mm_touch.gd")
const MmHud := preload("../game/mm_hud.gd")

## The touch layout: the buttons fit a phone at three sizes without overlapping, and each DotTouchButtons is freed.
## Run: `godot --headless --path . res://examples/headless_touch.tscn`

const CHECKS := 14


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-murder-mystery: touch buttons")
	var sets: Dictionary = {"mm": MmTouch.touch_layout().buttons()}
	for label: String in sets:
		var layout: Array[Dictionary] = sets[label]
		var ids: Array[StringName] = []
		for b: Dictionary in layout:
			ids.append(b["id"])
		_check(ids.size() >= 4, "%s: the layout has its buttons" % label)
		_check(ids.has(MmTouch.HOLSTER) and ids.has(DotGameTouchLayout.FIRE) and ids.has(DotGameTouchLayout.USE) and ids.has(DotGameTouchLayout.JUMP) and ids.has(DotGameTouchLayout.CROUCH), "%s: fire, use, holster, jump and crouch are laid out" % label, str(ids))
		for size: Vector2 in [Vector2(844, 390), Vector2(667, 375), Vector2(932, 430)]:
			var buttons := DotTouchButtons.new()
			buttons.margin = MmTouch.EDGE_MARGIN
			buttons.size = size
			buttons.set_buttons(layout)
			add_child(buttons)
			_check(Rect2(Vector2.ZERO, size).encloses(buttons.footprint()), "%s: the cluster fits %dx%d" % [label, size.x, size.y], str(buttons.footprint()))
			var clash := ""
			for i in ids.size():
				for j in range(i + 1, ids.size()):
					var gap := buttons.centre_of(ids[i]).distance_to(buttons.centre_of(ids[j])) - buttons.radius_of(ids[i]) - buttons.radius_of(ids[j])
					if gap < 4.0:
						clash = "%s and %s" % [ids[i], ids[j]]
			_check(clash == "", "%s: no two buttons overlap at %dx%d" % [label, size.x, size.y], clash)
			var shout := Rect2(size.x * 0.5 - MmTouch.SHOUT_HALF_WIDTH, MmTouch.SHOUT_TOP, MmTouch.SHOUT_HALF_WIDTH * 2.0, MmTouch.SHOUT_BOTTOM - MmTouch.SHOUT_TOP)
			_check(not shout.intersects(buttons.footprint()), "%s: the shout clears every button at %dx%d" % [label, size.x, size.y], str(shout))
			buttons.free()
	await _check_chat_clear_of_role()
	DotPlatform.touch_override = 0
	var off := DotTouchButtons.new()
	add_child(off)
	_check(not off.visible, "no touch: the buttons are hidden")
	off.free()
	DotPlatform.touch_override = -1
	_report(CHECKS)


## The chat log and the role block (disc, weapon, words, cooldown) share the bottom left; at the phone size they must not meet.
func _check_chat_clear_of_role() -> void:
	DotPlatform.touch_override = 1
	var vp := SubViewport.new()
	vp.size = Vector2i(844, 390)
	add_child(vp)
	var hud := MmHud.new()
	vp.add_child(hud)
	hud.bind(null, null)
	hud.set_process(false)
	var layer := CanvasLayer.new()
	vp.add_child(layer)
	var screen := Control.new()
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(screen)
	var window: Control = load("res://addons/dot_ui/hud/dot_chat_window.gd").new()
	for key: String in ["max_lines"]:
		window.set(key, MmTouch.CHAT_LINES)
	screen.add_child(window)
	await get_tree().process_frame
	await get_tree().process_frame
	var chat := Rect2(window.position, window.size)
	_check(chat.size.y > 0.0 and chat.end.y <= 390.0, "touch 844x390: the chat panel is on screen", str(chat))
	var clash := ""
	for control: Control in [hud._disc, hud.weapon_icon, hud._as, hud._lock, hud._meter_back, hud._meter_label]:
		var r := Rect2(control.position, control.size)
		if r.intersects(chat):
			clash += "%s %s; " % [control.name, r]
	_check(clash == "", "touch 844x390: the chat panel %s clears the role label and its block" % str(chat), clash)
	vp.free()
