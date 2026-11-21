extends GSGameCheckSuite

const MmTouch := preload("../game/mm_touch.gd")
const MmHud := preload("../game/mm_hud.gd")

## The touch layout: dot-mobile's overlay drives the sampler and never auto-fires; the buttons fit a phone at three sizes without overlapping, and each GSTouchButtons is freed.
## Run: `godot --headless --path . res://examples/headless_touch.tscn`

const CHECKS := 25


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
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
		_check(ids.has(MmTouch.HOLSTER) and ids.has(GSGameTouchLayout.FIRE) and ids.has(GSGameTouchLayout.USE) and ids.has(GSGameTouchLayout.JUMP) and ids.has(GSGameTouchLayout.CROUCH), "%s: fire, use, holster, jump and crouch are laid out" % label, str(ids))
		for size: Vector2 in [Vector2(844, 390), Vector2(667, 375), Vector2(932, 430)]:
			var buttons := GSTouchButtons.new()
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
	_overlay()
	await _check_chat_clear_of_role()
	GSPlatform.touch_override = 0
	var off := GSTouchButtons.new()
	add_child(off)
	_check(not off.visible, "no touch: the buttons are hidden")
	off.free()
	GSPlatform.touch_override = -1
	_report(CHECKS)


## The chat log and the role block (disc, weapon, words, cooldown) share the bottom left; at the phone size they must not meet.
func _check_chat_clear_of_role() -> void:
	GSPlatform.touch_override = 1
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


## dot-mobile's overlay on the client's own sampler: touches, a menu, the buttons' actions, and auto-fire held off.
func _overlay() -> void:
	var rules := MmTouch.make_rules()
	_check(not rules.resolve(GSMobilePrefs.new(), true).autofire, "auto-fire is off for a touch player by default")
	_check(MmTouch.crosshair_kind() != GSMobileAutoFire.TARGET_ENEMY, "the crosshair is never an enemy: nobody is known to be one")
	GSPlatform.touch_override = 1
	var host := Control.new()
	host.size = Vector2(844, 390)
	add_child(host)
	var sampler := GSFpsTouchSampler.new(GSFpsTunables.new())
	var touch := MmTouch.new()
	touch.build(sampler, null, rules)
	host.add_child(touch)
	var controls := touch.controls
	_check(controls != null and controls.touch and controls.sampler == sampler, "the overlay drives the client's own sampler", str(touch.describe()))
	var ids: Array[StringName] = []
	for b: Dictionary in MmTouch.layout():
		ids.append(b["id"])
	_check(ids.has(MmTouch.HOLSTER) and ids.has(GSGameTouchLayout.FIRE) and ids.has(GSGameTouchLayout.USE), "the game's hit, use and draw buttons are declared")
	var tap := InputEventScreenTouch.new()
	tap.pressed = true
	var fake := InputEventMouseMotion.new()
	fake.device = InputEvent.DEVICE_ID_EMULATION
	_check(touch.takes(tap) and touch.takes(fake), "it takes touches and the mouse emulated from them")
	var pressed: Array[StringName] = []
	controls.button_pressed.connect(func(id: StringName) -> void: pressed.append(id))
	controls.buttons.button_down.emit(MmTouch.HOLSTER)
	controls.buttons.button_down.emit(GSGameTouchLayout.USE)
	_check(pressed.has(MmTouch.HOLSTER) and pressed.has(GSGameTouchLayout.USE), "draw and use reach the game's one-shot handlers", str(pressed))
	var jump_bit := 0
	for b: Dictionary in MmTouch.layout():
		if b["id"] == GSGameTouchLayout.JUMP:
			jump_bit = int(b.get("hold", 0))
	_check(jump_bit == GSFpsCommand.BUTTON_JUMP, "the jump button holds the sampler's jump bit", str(jump_bit))
	controls.buttons.button_up.emit(MmTouch.HOLSTER)
	controls.buttons.button_up.emit(GSGameTouchLayout.USE)
	touch.sync(true)
	_check(not controls.visible and not touch.active(), "a menu pauses it")
	_check(not touch.is_held(GSGameTouchLayout.FIRE), "auto-fire never holds the hit button")
	touch.sync(false)
	_check(touch.active(), "and closing the menu brings it back")
	_check(controls.buttons.margin == MmTouch.EDGE_MARGIN, "the buttons keep their edge margin")
	host.free()
	GSPlatform.touch_override = -1
