extends Control

const MmPlayer := preload("mm_player.gd")

## The on-screen buttons a phone needs: attack, use, draw or put away, and jump, through gs-mobile's
## [GSMobileControls]: a stick, drag-look and those buttons, driving the client's own [GSFpsTouchSampler]. Never auto-fires (see [method crosshair_kind]).

const EDGE_MARGIN := 24.0

const HOLSTER := &"holster"

## The shout band on a phone: below the clock, above the highest button (JUMP, top at y 121 at 667x375).
const SHOUT_TOP := 92.0
const SHOUT_BOTTOM := 117.0
const SHOUT_HALF_WIDTH := 320.0
const SHOUT_FONT := 18

## How far the role block (disc, weapon, cooldown) moves down so the shout's left end clears it.
const ROLE_DROP := 104.0

## Chat lines kept on a phone: the log is bottom left under the role block, and a tall one climbs into it.
const CHAT_LINES := 3

## Where the chat log goes on a phone, in the phone canvas's units (short side 720, see GSGameScreenFit): right of the stick and
## left of the buttons in landscape, above the stick in portrait where the buttons leave no room beside it.
const CANVAS_SHORT := 720.0
const CHAT_STICK_RIGHT := 464.0
const CHAT_BUTTONS_LEFT := 1060.0
const CHAT_PORTRAIT_LIFT := 270.0
const CHAT_MIN_WIDTH := 200.0
const CHAT_MAX_WIDTH := 460.0


## Chat box settings for a phone window of `window_px` real pixels: clear of the stick and the buttons, never over them.
static func chat_settings(window_px: Vector2) -> Dictionary:
	var out := {"max_lines": CHAT_LINES}
	var canvas := window_px * (CANVAS_SHORT / maxf(1.0, minf(window_px.x, window_px.y)))
	if canvas.x >= canvas.y:
		out["margin_left"] = CHAT_STICK_RIGHT
		out["width"] = clampf(CHAT_BUTTONS_LEFT - CHAT_STICK_RIGHT, CHAT_MIN_WIDTH, CHAT_MAX_WIDTH)
		out["margin_bottom"] = 12.0
	else:
		out["margin_left"] = 16.0
		out["width"] = clampf(canvas.x - 32.0, CHAT_MIN_WIDTH, CHAT_MAX_WIDTH)
		out["margin_bottom"] = CHAT_PORTRAIT_LIFT
	return out

## The server's touch rules, built in [MmGame]: auto-fire stays off (`sv_autofire 0`) unless an operator turns it on.
## Nobody is known to be an enemy here (roles are secret), so even then [method crosshair_kind] never allows a shot.
static func make_rules() -> GSMobileRules:
	var rules := GSMobileRules.new()
	rules.autofire = GSMobileRules.OFF
	return rules


var controls: GSMobileControls = null
## gs-mobile's buttons inside the overlay, for the shell's DPI fit.
var buttons: GSMobileButtons:
	get:
		return controls.buttons if controls != null else null

## Held now (a thumb), read by the client each tick beside the keys.
var attack_held: bool:
	get:
		return is_held(GSGameTouchLayout.FIRE)
var use_held: bool:
	get:
		return is_held(GSGameTouchLayout.USE)
var holster_held: bool:
	get:
		return is_held(HOLSTER)

var _menu_button: Control = null
var _host: Node = null
var _client: Object = null
var _made: Array[Dictionary] = []


## `--touch` forces them on so a desktop render shows the layout.
static func wanted() -> bool:
	return GSPlatform.has_touch() or "--touch" in OS.get_cmdline_user_args()


## gs-game's fps preset less what this game has no use for. Holster (draw or put away) takes the secondary slot.
static func touch_layout() -> GSGameTouchLayout:
	var res := GSGameTouchLayout.build(GSGameTouchLayout.FPS, {
		GSGameTouchLayout.ALT: null,
		GSGameTouchLayout.RELOAD: null,
		GSGameTouchLayout.NEXT: null,
		GSGameTouchLayout.PREV: null,
		GSGameTouchLayout.BOARD: null,
		GSGameTouchLayout.CHAT: null,
		GSGameTouchLayout.FIRE: {"label": "HIT"},
		HOLSTER: {"slot": &"secondary", "label": "DRAW"},
	})
	if not res.ok:
		push_error("game-murder-mystery touch layout refused: %s" % str(res.error))
		return GSGameTouchLayout.custom()
	return res.value


## The buttons as gs-mobile takes them: [method touch_layout]'s, with jump and duck held on the sampler.
static func layout() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for b: Dictionary in touch_layout().buttons():
		var made := b.duplicate()
		if made["id"] == GSGameTouchLayout.JUMP:
			made["hold"] = GSFpsCommand.BUTTON_JUMP
		elif made["id"] == GSGameTouchLayout.CROUCH:
			made["hold"] = GSFpsCommand.BUTTON_CROUCH
		out.append(made)
	return out


## Builds the overlay on [param sampler], following [param rules] (the server's). [param client] is the platform that
## fits the buttons to the screen.
func build(sampler: GSFpsTouchSampler, client: Object = null, rules: GSMobileRules = null, host: Node = null) -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_host = host
	controls = GSMobileControls.new()
	controls.name = "Controls"
	controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if rules != null:
		controls.rules = rules
	controls.ignore_fn = _on_menu_button
	_made = layout()
	controls.setup(sampler, _made)
	controls.crosshair_fn = crosshair_kind
	_client = client
	add_child(controls)


## The overlay's buttons exist once it is in the tree: the margin and the shell's DPI fit go on then.
func _ready() -> void:
	if controls == null or controls.buttons == null:
		return
	controls.buttons.margin = EDGE_MARGIN
	if _client != null and GSPlatform.has_touch() and _client.has_method(&"fit_touch_buttons"):
		_client.call(&"fit_touch_buttons", controls.buttons, _made)


## Whether a point is on a button, for the shell's own filters.
func contains_point(screen_pos: Vector2) -> bool:
	return controls != null and controls.buttons != null and controls.buttons.contains_point(screen_pos)


## A declared button held by a thumb.
func is_held(id: StringName) -> bool:
	return controls != null and controls.is_held(id)


## True when the overlay forwards [param event] itself, or [param event] is the mouse Godot emulates from a touch,
## which would turn the view or press Attack a second time.
func takes(event: InputEvent) -> bool:
	if controls == null or not controls.touch:
		return false
	return controls.takes(event) or (event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION)


## The overlay is up: Godot then also turns every touch into a left click, which must not read as the Attack key.
func active() -> bool:
	return controls != null and controls.touch


## Called every frame by the client: the overlay stands down while [param busy] (a menu, typing, the load cover).
func sync(busy: bool) -> void:
	if controls != null:
		controls.paused = busy


func describe() -> Dictionary:
	return controls.describe() if controls != null else {"built": false}


## What the crosshair is on, for auto-fire: never an enemy. Everybody is a bystander to everybody and a shot at one
## costs the gun (and with `innocent_kills_shooter`, the shooter), so no auto-fire press is ever safe.
static func crosshair_kind() -> int:
	return GSMobileAutoFire.TARGET_FRIEND


## Touches on the Menu button belong to the button, not to the stick or the look.
func _on_menu_button(at: Vector2) -> bool:
	if _menu_button == null or not is_instance_valid(_menu_button):
		_menu_button = _host.find_child("MenuButton", true, false) as Control if _host != null else null
	return _menu_button != null and _menu_button.is_visible_in_tree() and _menu_button.get_global_rect().has_point(at)
