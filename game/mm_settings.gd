extends DotMenuGameSettings

const MmBindings := preload("mm_bindings.gd")

## A player's own settings and the menu that changes them: view turn rate, field of view,
## volumes, the window and the menu's look. dot-menu's `DotMenuGameSettings` with this game's spec:
## `sensitivity` is ACCOUNT, `field_of_view` SERVER_CLAMPED, the volumes this machine's.

const SCHEMA_VERSION := 1

## Where this game's own document lives. The shared account document is dot-settings'.
const SETTINGS_DIR := "user://murder_settings"

## The app's namespace. ACCOUNT settings are shared under dot-menu's `tmc_account`.
const APP_NAMESPACE := &"murder"

## The field of view the camera had before this existed, and still the default.
const DEFAULT_FOV := 92

## Stock keys nothing here applies: every sound is on the SFX bus, the client binds no
## effects, and the chat box has no switch.
const NOT_APPLIED: Array[StringName] = [
	&"ui_volume", &"shake_scale", &"allow_flashes", &"chat_window",
]


func _init() -> void:
	super(spec_for())


## The game's settings as data: names, field of view, extra settings, keys and the help screen's goal and rules.
static func spec_for() -> DotMenuGameSpec:
	var s := DotMenuGameSpec.new()
	s.schema_version = SCHEMA_VERSION
	s.brand_name = "Murder Mystery"
	s.settings_dir = SETTINGS_DIR
	s.app_namespace = APP_NAMESPACE
	s.default_fov = DEFAULT_FOV
	s.gore_text = "Blood splatters on the wall or floor where somebody is shot or stabbed."
	s.ambient_text = "Quiet sounds under the map."
	s.not_applied = NOT_APPLIED
	# The touch Menu button sits top right, clear of the thumbs.
	s.menu_button_corner = &"top_right"
	s.bindings_maker = func() -> DotMenuBindings: return MmBindings.make()
	s.help_about = "Somebody here is a murderer, and only they know it. One bystander has the gun. Everybody else has nothing but their eyes. The murderer wins when nobody else is left; the bystanders win when the murderer is dead or the clock runs out."
	s.help_cards = [
		["Bystander", "Stay with other people: the murderer wants you alone. Watch for a weapon in somebody's hand, and for blood on a shirt near the end of the round. If the gun is dropped, walk over it to pick it up."],
		["Gun", "One shot, then a few seconds to reload. Shoot a murderer and they are out. Miss, and the gun falls at your feet for somebody else; shoot an innocent, and you drop it for good."],
		["Murderer", "Your weapon is put away until you draw it, and anybody who sees it drawn knows what you are. Draw, strike at arm's length, and put it away again. Near the end of the round blood starts to show on you, a little more each time."],
	]
	s.help_sections = [["Mouse", [["Left", "Watch the next player while out"], ["Right", "Watch the one before"]], &"keys"]]
	return s
