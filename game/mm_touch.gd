extends Control

const MmPlayer := preload("mm_player.gd")

## The on-screen buttons a phone needs: attack, use, draw or put away, and jump, as a dot-ui
## [DotTouchButtons]. Movement and looking are [DotFpsTouchSampler]'s two halves of the screen.

const EDGE_MARGIN := 24.0

## The shout band on a phone: below the clock, above the highest button (JUMP, top at y 121 at 667x375).
const SHOUT_TOP := 92.0
const SHOUT_BOTTOM := 117.0
const SHOUT_HALF_WIDTH := 320.0
const SHOUT_FONT := 18

## How far the role block (disc, weapon, cooldown) moves down so the shout's left end clears it.
const ROLE_DROP := 104.0

## Chat lines kept on a phone: the log is bottom left under the role block, and a tall one climbs into it.
const CHAT_LINES := 3

## Held now, read by the client each tick beside the keys.
var attack_held: bool = false
var use_held: bool = false
var holster_held: bool = false

var buttons: DotTouchButtons = null


## `--touch` forces them on so a desktop render shows the layout.
static func wanted() -> bool:
	return DotPlatform.has_touch() or "--touch" in OS.get_cmdline_user_args()


## Offsets are from the bottom-right corner, towards the middle (see [DotTouchButtons]).
static func layout() -> Array[Dictionary]:
	return [
		{"id": &"attack", "label": "HIT", "offset": Vector2(86, 100), "radius": 50.0},
		{"id": &"use", "label": "USE", "offset": Vector2(190, 70), "radius": 36.0},
		{"id": &"holster", "label": "DRAW", "offset": Vector2(176, 160), "radius": 32.0},
		{"id": &"jump", "label": "JUMP", "offset": Vector2(60, 200), "radius": 30.0},
	]


func build(sampler: DotFpsTouchSampler) -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	buttons = DotTouchButtons.new()
	buttons.name = "Buttons"
	buttons.only_on_touch = false
	buttons.margin = EDGE_MARGIN
	buttons.set_anchors_preset(Control.PRESET_FULL_RECT)
	buttons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	buttons.set_buttons(layout())
	buttons.button_down.connect(_on_button.bind(true, sampler))
	buttons.button_up.connect(_on_button.bind(false, sampler))
	add_child(buttons)
	sampler.ignore_fn = buttons.contains_point


func contains_point(screen_pos: Vector2) -> bool:
	return buttons != null and buttons.contains_point(screen_pos)


func _on_button(id: StringName, down: bool, sampler: DotFpsTouchSampler) -> void:
	match id:
		&"attack":
			attack_held = down
		&"use":
			use_held = down
		&"holster":
			holster_held = down
		&"jump":
			sampler.hold(DotFpsCommand.BUTTON_JUMP, down)
