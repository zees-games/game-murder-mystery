extends CanvasLayer

const MmGame := preload("mm_game.gd")
const MmPlayer := preload("mm_player.gd")
const MmBindings := preload("mm_bindings.gd")
const MmController := preload("mm_controller.gd")

## What a player needs on screen: the clock, how many are still alive, what this player is (and
## only this player: roles are secret), what they are holding, and when it is ready.
##
## [b]The role is drawn from this client's own knowledge.[/b] The disc and the line beside it
## read [code]game.team_of(player)[/code], which on a client is the ROLE the server sent this
## player alone (see mm_net_bridge.gd `local_role`); everybody else is a bystander on the wire,
## so nothing here can show somebody else's role.
##
## [b]The clock and the door prompt are dot-ui's glance pieces.[/b] The clock is a
## [DotScoreStrip] with everybody alive and the murderers left as its two side plates; the door
## prompt is a [DotKeyPrompt] under the crosshair with the use key drawn as a key.
##
## [b]The keys are read from the bindings, not written here.[/b] The hints in the corner say
## the key each action is on NOW, from the same table the menu's Controls page edits, so a
## rebound key is never a hint that lies.

const BLIND_FADE_SEC := 0.25
const BLIND_COLOUR := Color(0.01, 0.01, 0.015)

## The disc's colours, by what the player is.
const MURDERER_COLOUR := Color(0.78, 0.12, 0.12)
const MmWeaponIcons := preload("mm_weapon_icons.gd")
const GUNNER_COLOUR := Color(0.20, 0.45, 0.90)
const BYSTANDER_COLOUR := Color(0.32, 0.62, 0.36)

## Seconds left at which the clock turns red.
const LOW_CLOCK_SEC := 10.0

## The map name's pale blue, which is also the glance pieces' highlight.
const MAP_COLOUR := Color(0.80, 0.88, 0.98)


## This game's accent over whichever theme the player picked in the menu (its highlight and
## the plates' edge). The plates, the words and their outline are the theme's, dark by default,
## so a light or high-contrast theme can change them. Static so a render tool can use it.
static func piece_theme() -> Theme:
	var t := Theme.new()
	var type := DotHudPiece.THEME_TYPE
	t.set_color(&"plate_edge", type, Color(MAP_COLOUR, 0.3))
	t.set_color(&"highlight", type, MAP_COLOUR)
	return t


## The Escape menu, whose theme this HUD follows (dot-menu's `follow_hud`): the menu sets the
## theme on the HUD's root now and at every theme change, and applies the player's HUD size.
## Christian's first play test (2026-10-11) asked for a darker HUD a player can restyle in
## the menu. Duck-typed and called by name, for a client shell older than dot-menu 7.
var _menu: Object = null


func follow_menu(menu: Object) -> void:
	_menu = menu
	_follow()


func _follow() -> void:
	if _root != null and _menu != null and _menu.has_method(&"follow_hud"):
		_menu.call(&"follow_hud", _root, piece_theme())


var game: MmGame = null
var player: MmPlayer = null

## `func(action: StringName) -> String`: the key an action is on, from the bindings.
var key_fn: Callable = Callable()

## What a player who is out is looking at, and the keys that change it. Empty while playing.
var watching_label: Label = null

## An administrator's `blind`, over the world and under the HUD.
var blind_overlay: ColorRect = null

var _root: Control = null
## The clock, everybody alive and the murderers left either side of it, and the caption and map
## name under it.
var strip: DotScoreStrip = null
## "Open the pantry door" with the use key drawn as a key, while one is in reach.
var prompt: DotKeyPrompt = null
var _shout: Label = null
var _hints: Label = null
var _disc: Panel = null
var _disc_label: Label = null
var _as: Label = null
var _lock: Label = null
## The weapon or gun in hand as a sprite over the disc; hidden when it has none.
var weapon_icon: TextureRect = null
## The gun's or the weapon's readiness, under the disc's words.
var _meter_back: ColorRect = null
var _meter_fill: ColorRect = null
var _meter_label: Label = null
## The colour the disc was last drawn in, so a style is built only when it changes.
var _disc_colour: Color = Color(0, 0, 0, 0)
var _crosshair: DotCrosshair = null
var _shout_for: float = 0.0


func bind(p_game: MmGame, p_player: MmPlayer) -> void:
	game = p_game
	player = p_player

	if _root == null:
		_build()


func _build() -> void:
	# A full-rect Control between the CanvasLayer and the labels: a CanvasLayer does not lay its
	# children out, so anchors on a Label parented straight to one resolve against nothing.
	_root = Control.new()
	_root.name = "Screen"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	blind_overlay = _cover("Blind", BLIND_COLOUR)

	# The glance pieces read their colours from the theme on the type DotHudPiece; set on
	# the root, every piece under it inherits them. See [method piece_theme].
	_root.theme = piece_theme()
	_follow()

	# Top centre, full width because the strip centres itself on its own middle. Its plates
	# span 388 pixels round the middle, clear of the key hints top left at 1280 x 720.
	strip = DotScoreStrip.new()
	strip.name = "Clock"
	strip.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	strip.offset_top = 14.0
	strip.offset_bottom = 94.0
	_root.add_child(strip)

	# Top left: the keys this side has, as the player has them bound.
	_hints = _label(15)
	_hints.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_hints.offset_left = 22.0
	_hints.offset_top = 18.0
	_hints.offset_right = 420.0
	_hints.offset_bottom = 260.0

	_shout = _label(40)
	_shout.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_shout.offset_top = 170.0
	_shout.offset_bottom = 240.0
	_shout.offset_left = -600.0
	_shout.offset_right = 600.0
	_shout.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_shout.add_theme_color_override("font_color", Color(0.99, 0.86, 0.40))

	# Bottom left: a disc in the role's colour with a letter on it, what you are, and what you
	# are holding.
	# Above the chat box, which also draws bottom-left.
	_disc = Panel.new()
	_disc.name = "Disc"
	_disc.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_disc.offset_left = 22.0
	_disc.offset_right = 102.0
	_disc.offset_top = -300.0
	_disc.offset_bottom = -220.0
	_disc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_disc)

	_disc_label = Label.new()
	_disc_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_disc_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_disc_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_disc_label.add_theme_font_size_override("font_size", 26)
	_disc_label.add_theme_color_override("font_color", Color.WHITE)
	_disc_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	_disc_label.add_theme_constant_override("outline_size", 4)
	_disc.add_child(_disc_label)

	weapon_icon = TextureRect.new()
	weapon_icon.name = "WeaponIcon"
	weapon_icon.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	weapon_icon.offset_left = 22.0
	weapon_icon.offset_right = 142.0
	weapon_icon.offset_top = -368.0
	weapon_icon.offset_bottom = -306.0
	weapon_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	weapon_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	weapon_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	weapon_icon.visible = false
	_root.add_child(weapon_icon)

	_as = _label(17)
	_as.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_as.offset_left = 112.0
	_as.offset_right = 600.0
	_as.offset_top = -296.0
	_as.offset_bottom = -266.0

	_lock = _label(15)
	_lock.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_lock.offset_left = 112.0
	_lock.offset_right = 600.0
	_lock.offset_top = -264.0
	_lock.offset_bottom = -240.0
	_lock.add_theme_color_override("font_color", Color(0.85, 0.92, 1.0))

	# How long until the gun or the weapon is ready again, under the disc's words.
	_meter_back = _bar(Color(0.0, 0.0, 0.0, 0.45))
	_meter_fill = _bar(Color(0.95, 0.80, 0.30, 0.95))
	_meter_label = _label(15)
	_meter_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_meter_label.offset_left = 322.0
	_meter_label.offset_right = 620.0
	_meter_label.offset_top = -241.0
	_meter_label.offset_bottom = -219.0

	watching_label = _label(20)
	watching_label.name = "Watching"
	watching_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	watching_label.offset_left = -520.0
	watching_label.offset_right = 520.0
	watching_label.offset_top = -140.0
	watching_label.offset_bottom = -104.0
	watching_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	watching_label.add_theme_color_override("font_color", Color(0.80, 0.90, 1.0))

	# What the use key would do, under the crosshair while a door is in reach.
	prompt = DotKeyPrompt.new()
	prompt.name = "DoorPrompt"
	prompt.font_size = 15
	prompt.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	prompt.offset_left = -240.0
	prompt.offset_right = 240.0
	prompt.offset_top = 14.0
	prompt.offset_bottom = 46.0
	prompt.visible = false
	_root.add_child(prompt)

	# A dot, as before: no arms, no outline, no spread.
	_crosshair = DotCrosshair.new()
	_crosshair.name = "Crosshair"
	_crosshair.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_crosshair.length = 0.0
	_crosshair.base_gap = 0.0
	_crosshair.top_arm = false
	_crosshair.dynamic = false
	_crosshair.outline = false
	_crosshair.dot_radius = 3.0
	_crosshair.colour = Color(1.0, 1.0, 1.0, 0.75)
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if DotAddonApi.build_level("dot_ui") >= 14:
		_crosshair.set(&"alive_source", func() -> bool: return player != null and player.is_alive())
	_root.add_child(_crosshair)


func _cover(cover_name: String, colour: Color) -> ColorRect:
	var rect := ColorRect.new()
	rect.name = cover_name
	rect.color = colour
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.modulate.a = 0.0
	rect.visible = false
	_root.add_child(rect)
	return rect


func _bar(colour: Color) -> ColorRect:
	var rect := ColorRect.new()
	rect.color = colour
	rect.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	rect.offset_left = 112.0
	rect.offset_right = 312.0
	rect.offset_top = -234.0
	rect.offset_bottom = -226.0
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.visible = false
	_root.add_child(rect)
	return rect


func _label(size: int) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_constant_override("outline_size", 6)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(label)
	return label


func set_watching(text: String) -> void:
	if watching_label != null:
		watching_label.text = text


## One line in the middle of the screen, for a few seconds.
func shout(text: String, seconds: float = 3.5) -> void:
	if _shout == null:
		return

	_shout.text = text
	_shout_for = seconds


## The role arrived or the round ended: redraw the disc now rather than at the next frame's
## colour check.
func role_changed() -> void:
	_disc_colour = Color(0, 0, 0, 0)


func _process(delta: float) -> void:
	present_blind(delta)

	if game == null or game.config == null or _root == null:
		return

	var role := role_of()
	var left := game.seconds_left()

	var caption := ""
	match game.phase:
		MmGame.Phase.GRACE:
			caption = "Weapons out in"
		MmGame.Phase.PLAY:
			caption = "Bystanders win in"
		_:
			caption = "waiting for players" if not game.sides_are_playable() else "between rounds"

	# The caption under the clock rather than over it, as the strip draws every game's: it
	# reads "Bystanders win in · The Mansion".
	var running := game.phase != MmGame.Phase.IDLE
	strip.show_clock(
		DotScoreStrip.clock_text(left) if running else "", running and left <= LOW_CLOCK_SEC,
		caption, str(game.map_doc.get("name", ""))
	)
	if running:
		strip.show_scores(
			game.alive_total(), game.alive_on(MmGame.MURDERERS), "ALIVE", "MURDERERS",
			BYSTANDER_COLOUR, MURDERER_COLOUR
		)
	else:
		strip.hide_scores()

	_draw_disc(role)
	_draw_weapon_icon(role)
	_draw_hints(role)
	_draw_meter(role)
	_draw_door_prompt()
	_crosshair.suppressed = player != null and player.watching

	if _shout_for > 0.0:
		_shout_for -= delta
		if _shout_for <= 0.0:
			_shout.text = ""


## What this player is: &"murderer", &"gunner", &"bystander", or &"" while not in a round.
func role_of() -> StringName:
	if player == null or not is_instance_valid(player) or game == null or game.phase == MmGame.Phase.IDLE:
		return &""
	var side := game.team_of(player.player_id)
	if side == MmGame.MURDERERS:
		return &"murderer"
	if side == MmGame.BYSTANDERS:
		return &"gunner" if player.has_gun else &"bystander"
	return &""


## The held weapon's sprite (`cl_weapon_icons`): the gun for a gunner, the murderer's weapon, dimmed while put away.
func _draw_weapon_icon(role: StringName) -> void:
	var sprite: Texture2D = null
	if player != null and player.is_alive() and not player.watching:
		if role == &"gunner":
			sprite = MmWeaponIcons.shared.texture(MmWeaponIcons.GUN)
		elif role == &"murderer":
			sprite = MmWeaponIcons.shared.texture(game.weapon_id())
	weapon_icon.texture = sprite
	weapon_icon.visible = sprite != null
	weapon_icon.modulate.a = 0.45 if role == &"murderer" and not player.weapon_drawn else 1.0
	MmWeaponIcons.shared.filter(weapon_icon, true)


func _draw_disc(role: StringName) -> void:
	var shown := player != null and player.is_alive() and not player.watching and role != &""
	_disc.visible = shown
	_as.text = ""
	_lock.text = ""

	if not shown:
		return

	var colour := BYSTANDER_COLOUR
	var letter := "B"
	match role:
		&"murderer":
			colour = MURDERER_COLOUR
			letter = "M"
			_as.text = "MURDERER"
			if game.phase == MmGame.Phase.GRACE:
				_lock.text = "your %s comes out when the grace ends" % game.weapon_name().to_lower()
			elif player.weapon_drawn:
				_lock.text = "%s DRAWN — anybody who sees it knows" % game.weapon_name()
			else:
				_lock.text = "%s put away" % game.weapon_name()
			if player.blood > 0:
				_lock.text += "   ·   blood shows (%d)" % player.blood
		&"gunner":
			colour = GUNNER_COLOUR
			letter = "G"
			_as.text = "BYSTANDER — YOU HAVE THE GUN"
			_lock.text = "one shot: a miss drops it" if game.config.drop_on_miss else "shoot the murderer"
		_:
			_as.text = "BYSTANDER"
			_lock.text = "stay alive; a dropped gun is anybody's" if player.gun_banned == false else "you may not pick up the gun again"

	if colour != _disc_colour:
		_disc_colour = colour
		var style := StyleBoxFlat.new()
		style.bg_color = colour
		style.set_corner_radius_all(40)
		style.border_color = Color(1, 1, 1, 0.85)
		style.set_border_width_all(3)
		_disc.add_theme_stylebox_override("panel", style)
	_disc_label.text = letter


func _draw_hints(role: StringName) -> void:
	if player == null or not player.is_alive() or player.watching or role == &"":
		_hints.text = ""
		return

	var lines := PackedStringArray()
	var moving := "Shift  Sprint    Ctrl  Crouch    %s  Doors" % _key(MmBindings.USE)

	match role:
		&"murderer":
			lines.append("Kill everybody. Don't get seen.")
			lines.append(moving)
			lines.append("%s  Draw / put away    %s  Stab" % [_key(MmBindings.HOLSTER), _key(MmBindings.ATTACK)])
		&"gunner":
			lines.append("Find the murderer. Shoot only when sure.")
			lines.append(moving)
			lines.append("%s  Shoot" % _key(MmBindings.ATTACK))
		_:
			lines.append("Stay alive. Watch who has a weapon out.")
			lines.append(moving)

	_hints.text = "\n".join(lines)


## The gun's or the weapon's cooldown, while it is not ready.
func _draw_meter(role: StringName) -> void:
	var span := 0.0
	var what := ""
	if role == &"gunner":
		span = game.config.gun_cooldown
		what = "Gun"
	elif role == &"murderer" and player.weapon_drawn:
		span = game.melee_cooldown()
		what = game.weapon_name()

	var shown := span > 0.0 and player != null and player.is_alive() and player.ready_in > 0.05
	_meter_back.visible = shown
	_meter_fill.visible = shown
	_meter_label.text = ""

	if not shown:
		return

	var ready := 1.0 - clampf(player.ready_in / span, 0.0, 1.0)
	_meter_fill.offset_right = 112.0 + 200.0 * ready
	_meter_label.text = "%s ready in %.1f s" % [what, player.ready_in]


## "Open the pantry door  [E]", while one is in reach and the key would do something.
func _draw_door_prompt() -> void:
	var words := _door_words()

	if words == "":
		prompt.clear()
	else:
		prompt.show_prompt(words, _key(MmBindings.USE))


## "Open the pantry door", "Kick the beach ball", or empty while nothing in reach would do
## anything. A toy looked at first, as the use key takes it first (`MmGame._advance_use`).
func _door_words() -> String:
	if player == null or not player.is_alive() or player.watching \
			or game.map == null or player.controller.has_modifier(MmController.HOLD):
		return ""

	var toy := game.toy_aimed(player)

	if toy >= 0:
		return game.map.toys.toy(toy).prompt()

	if game.map.doors == null or not game.config.doors_enabled:
		return ""

	var doors := game.map.doors
	var index := doors.door_for(player.eye_position(), player.aim_direction())

	if index < 0:
		return ""

	var name := str((doors.doors[index]["spec"] as Dictionary)["name"])
	var what := "Shut" if doors.is_open(index) else "Open"
	return "%s%s" % [what, " the " + name if name != "" else ""]


func _key(action: StringName) -> String:
	return str(key_fn.call(action)) if key_fn.is_valid() else String(action)


func present_blind(delta: float) -> void:
	if blind_overlay == null:
		return

	var step := maxf(delta, 0.0) / BLIND_FADE_SEC
	blind_overlay.modulate.a = move_toward(blind_overlay.modulate.a, 1.0 if is_blind() else 0.0, step)
	blind_overlay.visible = blind_overlay.modulate.a > 0.0


func is_blind() -> bool:
	return player != null and is_instance_valid(player) and player.blinded
