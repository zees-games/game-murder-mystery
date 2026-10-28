extends DotMenuSettings

const MmBindings := preload("mm_bindings.gd")

## A player's own settings and the menu that changes them: view turn rate, field of view,
## volumes, the window and the menu's look. dot-menu's `DotMenuSettings` with this game's schema:
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
	name = "Settings"
	directory = SETTINGS_DIR
	app_namespace = APP_NAMESPACE
	schema = schema_for()
	config = DotMenuConfig.new()
	config.brand_name = "Murder Mystery"
	# Help and Leave are dot-menu's stock: H opens help, Leave leaves the server or quits a
	# solo game. Every game in the family has both (the first play test found this one without
	# Leave).
	bindings = MmBindings.make()
	var _layered := config.load_layered()


## The document: this game's field of view first, so it keeps its own default, then the
## stock settings it applies.
static func schema_for() -> DotSettingsSchema:
	var s := DotSettingsSchema.new()
	s.version = SCHEMA_VERSION
	s.add(DotSettingsDef.integer(&"field_of_view", DEFAULT_FOV, 70, 120, &"video").with_scope(
		DotSettingsDef.Scope.SERVER_CLAMPED
	))
	s.add(DotSettingsDef.boolean(&"gore", true, &"video").with_description(
		"Blood splatters on the wall or floor where somebody is shot or stabbed."))
	s.add(DotSettingsDef.boolean(&"ambient", true, &"audio").with_description("Quiet sounds under the map."))
	s.add(DotSettingsDef.number(&"ambient_volume", 1.0, 0.0, 1.0, &"audio"))
	return DotMenuStock.declare(s, DotMenuStock.DEFAULT_GROUPS, null, NOT_APPLIED)


func setup(store: DotSettingsStore = null, with_menu: bool = true) -> DotResult:
	var made := super.setup(store, with_menu)
	if menu != null:
		DotMenuStock.add_gore_row(menu.page(&"video"))
	return made


## The help screen's goal and rules; the keys come from [MmBindings].
func _fill_help(help: DotMenuHelp) -> void:
	help.about = "Somebody here is a murderer, and only they know it. One bystander has the gun. Everybody else has nothing but their eyes. The murderer wins when nobody else is left; the bystanders win when the murderer is dead or the clock runs out."
	help.add_text("Bystander", "Stay with other people: the murderer wants you alone. Watch for a weapon in somebody's hand, and for blood on a shirt near the end of the round. If the gun is dropped, walk over it to pick it up.")
	help.add_text("Gun", "One shot, then a few seconds to reload. Shoot a murderer and they are out. Miss, and the gun falls at your feet for somebody else; shoot an innocent, and you drop it for good.")
	help.add_text("Murderer", "Your weapon is put away until you draw it, and anybody who sees it drawn knows what you are. Draw, strike at arm's length, and put it away again. Near the end of the round blood starts to show on you, a little more each time.")
	help.add_section("Mouse", [["Left", "Watch the next player while out"], ["Right", "Watch the one before"]], &"keys")
